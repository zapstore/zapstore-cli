import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/publish/events.dart';
import 'package:zapstore_cli/publish/github_parser.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/html_preview.dart';
import 'package:zapstore_cli/publish/web_parser.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

class Publisher {
  late final AssetParser parser;
  late final List<PartialModel> partialModels;
  late final Signer signer;

  Future<void> run() async {
    // (1) Validate input and find an appropriate asset parser
    await _validateAndFindParser();

    // (2) Parse metadata and assets into partial models
    partialModels = await parser.run();

    if (!isDaemonMode) {
      final preview = Confirm(
        prompt: 'Preview the release in a web browser?',
        defaultValue: true,
      ).interact();

      if (preview) {
        final serverIsolate = await HtmlPreview.startServer(partialModels);

        final ok = Confirm(
          prompt: 'Is the HTML preview correct?',
          defaultValue: true,
        ).interact();

        serverIsolate.kill(priority: Isolate.immediate);

        if (!ok) {
          throw GracefullyAbortSignal();
        }
      }
    }

    // (3) Sign events
    signer = getSignerFromString(env['SIGN_WITH']!);

    _handleEventsToStdout();

    if (isNewFormat) {
      final assets = partialModels.whereType<PartialFileMetadata>().map((m) {
        final a = PartialSoftwareAsset()..appIdentifier = m.appIdentifier;
        // filename = m.transientData['filename']
        return a;
      });
      partialModels.addAll(assets);
    }

    late final List<Model<dynamic>> signedModels;
    await withSigner(signer, (signer) async {
      signedModels =
          await signModels(signer: signer, partialModels: partialModels);
    });

    final app = signedModels.whereType<App>().first;
    final release = signedModels.whereType<Release>().first;
    final fileMetadatas = signedModels.whereType<FileMetadata>().toSet();
    final authorizations =
        signedModels.whereType<BlossomAuthorization>().toList();

    // (5) Upload to Blossom
    await parser.blossomClient.upload(authorizations);

    // (6) Publish
    await _sendToRelays(app, release, fileMetadatas);
  }

  Future<void> _validateAndFindParser() async {
    final configYaml = File(configPath);
    late YamlMap yamlAppMap;

    if (!await configYaml.exists()) {
      throw UsageException('Config not found at $configPath',
          'Please create a zapstore.yaml config file in this directory or pass it using `-c`.');
    }

    try {
      yamlAppMap = loadYaml(await configYaml.readAsString()) as YamlMap;
    } catch (e) {
      throw UsageException(
          e.toString(), 'Provide a valid zapstore.yaml config file.');
    }

    requireSignWith();

    final appMap = {...yamlAppMap.value};
    if (appMap['artifacts'] is List) {
      final usage =
          'You are listing artifacts, update to the new format (artifacts is now assets).';
      throw UsageException('Wrong format', usage);
    }

    final assets = appMap['assets'] as List?;

    final hasRemoteAssets = assets != null &&
        assets.any((k) {
          // Paths with a scheme are fetched from the web
          return Uri.tryParse(k)?.hasScheme ?? false;
        });
    final hasLocalAssets = assets != null &&
        assets.any((k) {
          // Paths are considered local only when they have
          // a forward slash, if needed write: ./file.apk
          return k.toString().contains('/');
        });

    if (hasRemoteAssets) {
      parser = WebParser(appMap);
    } else if (hasLocalAssets) {
      parser = AssetParser(appMap);
    } else {
      // If paths do not have a scheme and do not contain slashes, try Github
      final repository = appMap['release_repository'] ?? appMap['repository'];
      if (repository != null) {
        final repositoryUri = Uri.parse(repository);
        if (repositoryUri.host != 'github.com') {
          throw 'Unsupported repository; service: ${repositoryUri.host}';
        }
        parser = GithubParser(appMap);
      } else {
        throw UsageException('No sources provided', '');
      }
    }
  }

  Future<void> _handleEventsToStdout() async {
    if (signer is! NpubFakeSigner) {
      return;
    }
    await signer.initialize();
    final partialBlossomAuthorizations =
        partialModels.whereType<PartialBlossomAuthorization>();
    final proceed =
        isDaemonMode || honor || Confirm(prompt: '''⚠️  Can't use npub to sign!

In order to send unsigned events to stdout you must:
  - Ensure the SIGN_WITH provided pubkey (${signer.pubkey}) matches the resulting pubkey from the signed events to honor `a` tags
${partialBlossomAuthorizations.isEmpty ? '' : ' - Perform the following Blossom actions to honor `url` tags'}
${partialBlossomAuthorizations.map((a) => a.event.content).map((a) => '   - $a to servers: ${parser.blossomClient.servers.join(', ')}').join('\n')}

The `--honor` argument can be used to hide this notice.

Okay?''', defaultValue: false).interact();

    if (!proceed) {
      throw GracefullyAbortSignal();
    }

    linkAppAndRelease(
        partialApp: partialModels.whereType<PartialApp>().first,
        partialRelease: partialModels.whereType<PartialRelease>().first,
        signingPubkey: signer.pubkey);

    for (final model in partialModels) {
      print(model);
    }
    throw GracefullyAbortSignal();
  }

  Future<void> _sendToRelays(App signedApp, Release signedRelease,
      Set<FileMetadata> signedFileMetadatas) async {
    var publishEvents = true;

    if (!isDaemonMode) {
      final relayUrls = storage.config.getRelays();

      final viewEvents = Select(
        prompt: 'Events signed! How do you want to proceed?',
        options: [
          'Inspect release and confirm before publishing to relays',
          'Publish release to ${relayUrls.join(', ')} now',
          'Exit without publishing'
        ],
      ).interact();

      if (viewEvents == 0) {
        stderr.writeln();
        stderr.writeln('App event (kind 32267)'.bold().black().onWhite());
        stderr.writeln();
        printJsonEncodeColored(signedApp.toMap());

        stderr.writeln();
        stderr.writeln('Release event (kind 30063)'.bold().black().onWhite());
        stderr.writeln();
        printJsonEncodeColored(signedRelease.toMap());
        stderr.writeln();
        stderr.writeln(
            'File metadata events (kind 1063)'.bold().black().onWhite());
        stderr.writeln();
        for (final m in signedFileMetadatas) {
          printJsonEncodeColored(m.toMap());
          stderr.writeln();
        }

        publishEvents = Confirm(
          prompt:
              'Scroll up to verify and press `y` to publish to ${relayUrls.join(', ')}',
          defaultValue: true,
        ).interact();
      } else if (viewEvents == 2) {
        throw GracefullyAbortSignal();
      }
    }

    if (publishEvents) {
      for (final Model model in [
        signedApp,
        signedRelease,
        ...signedFileMetadatas
      ]) {
        final kind = model.event.kind;

        final spinner = CliSpin(
          text: 'Publishing kind $kind...',
          spinner: CliSpinners.dots,
          isSilent: isDaemonMode,
        ).start();
        await storage.save({model});
        final statuses = await storage.publish({model});
        final status = statuses.first;
        if (status.accepted) {
          spinner.success(
              '${'Published'.bold()}: ${model.id.toString()} (kind $kind)');
        } else {
          spinner.fail(
              '${status.message.bold().black().onRed()}: ${model.id} (kind $kind)');
        }
      }
    }
  }
}

final fileRegex = RegExp(r'^[^\/<>|:&]*');
