import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/blossom.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/commands/publish/web_parser.dart';
import 'package:zapstore_cli/utils.dart';

class Publisher {
  final blossom = BlossomClient(servers: {kZapstoreBlossomUrl});

  Future<void> run() async {
    // (1) Find parser
    final parser = await _findParser();

    // (2) Parse: Produces initial app, release, metadatas
    final partialModels = await parser.run();

    // (3) Sign events and Blossom authorizations

    final signWith = env['SIGN_WITH'];

    if (signWith == null) {
      stderr.writeln(
          '⚠️  ${'Nothing to sign with, returning unsigned events'.bold()}');
      for (final model in partialModels) {
        print(model);
      }
      return;
    }

    final signedModels = await signModels(
      partialModels: partialModels,
      signWith: signWith,
    );

    // (4) Upload to Blossom
    await blossom
        .upload(signedModels.whereType<BlossomAuthorization>().toSet());

    // (5) Publish
    await _sendToRelays(
        signedModels.whereType<App>().first,
        signedModels.whereType<Release>().first,
        signedModels.whereType<FileMetadata>().toSet());
  }

  Future<AssetParser> _findParser() async {
    final configYaml = File(configPath);

    if (!await configYaml.exists()) {
      throw UsageException('Config not found at $configPath',
          'Please create a zapstore.yaml file in this directory or pass it using `-c`.');
    }

    final yamlAppMap = loadYaml(await configYaml.readAsString()) as YamlMap;

    // (1) Validate input and determine parser
    final appMap = {...yamlAppMap.value};
    if (!appMap.containsKey('assets')) {
      final usage = appMap['artifacts'] is List
          ? 'You are listing artifacts, update to the new format (artifacts -> assets).'
          : 'You must have an asset list in your config file.';
      throw UsageException('Asset list not found', usage);
    }

    final assets = appMap['assets'] as List;

    late final AssetParser parser;

    final hasRemoteAssets = assets.any((k) {
      // Paths with a scheme are fetched from the web
      return Uri.tryParse(k)?.hasScheme ?? false;
    });
    final hasLocalAssets = assets.any((k) {
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
    return parser;
  }

  Future<void> _sendToRelays(App signedApp, Release signedRelease,
      Set<FileMetadata> signedFileMetadatas) async {
    var publishEvents = true;

    if (!isDaemonMode) {
      final viewEvents = Select(
        prompt: 'Events signed! How do you want to proceed?',
        options: [
          'Inspect the events and confirm before publishing to relays',
          'Publish the events to relays now',
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
              'Scroll up to check the events and press `y` when you\'re ready to publish',
          defaultValue: true,
        ).interact();
      }
    }

    var showWhitelistMessage = false;
    if (publishEvents) {
      for (final Model model in [
        signedApp,
        signedRelease,
        ...signedFileMetadatas
      ]) {
        final kind = model.event.kind;
        try {
          final spinner = CliSpin(
            text: 'Publishing kind $kind...',
            spinner: CliSpinners.dots,
            isSilent: isDaemonMode,
          ).start();
          await storage.save({model}, publish: true);
          spinner.success(
              '${'Published'.bold()}: ${model.id.toString()} (kind $kind)');
          if (isDaemonMode) {
            print('Published kind $kind');
          }
        } catch (e) {
          stderr.writeln(
              '${e.toString().bold().black().onRed()}: ${model.id} (kind $kind)');
          if (e.toString().contains('not accepted')) {
            showWhitelistMessage = true;
          }
        }
      }
    } else {
      stderr
          .writeln('No events published nor Blossom assets uploaded, exiting');
    }

    if (showWhitelistMessage) {
      stderr.writeln(
          '\n${'Your npub is not whitelisted on the relay'.bold()}! If you want to self-publish your app, reach out.\n');
    }
  }
}

/// We check for apps with this same identifier (of any author, for simplicity)
/// NOTE: This logic is rerun during event signing once we know the author's pubkey
/// This allows us to be roughly correct about the correct overwriteApp value,
/// which will trigger fetching app information through the appropriate parser below.
Future<bool> ensureOverwriteApp(bool overwriteApp, String appIdentifier) async {
  final appsWithIdentifier =
      await storage.query<App>(RequestFilter(remote: true, tags: {
    '#d': {appIdentifier}
  }));

  // If none were found (first time publishing), we ignore the
  // overwrite argument and set it to true
  if (appsWithIdentifier.isEmpty) {
    print('First time publishing? Creating an app event (kind 32267)');
    overwriteApp = true;
  }
  return overwriteApp;
}

// enum SupportedOS {
//   cli,
//   android;

//   static SupportedOS from(dynamic value) {
//     return SupportedOS.values.firstWhere((os) => os.name == value.toString());
//   }
// }

final fileRegex = RegExp(r'^[^\/<>|:&]*');
