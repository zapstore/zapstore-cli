import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/local_parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/commands/publish/web_parser.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';

/// Publish: a [configPath] may have multiple appIds,
/// if the command specified `zapstore publish myapp`
/// via [onlyPublishAppId] then only process myapp and ignore the rest
Future<void> publish({
  required String configPath,
  required List<String> artifacts,
  required bool overwriteApp,
  required bool overwriteRelease,
  String? onlyPublishAppId,
  String? releaseNotes,
}) async {
  // - Load zapstore.yaml
  // - Initialize relay
  // - Loop through entries
  //   - Determine publishing method
  //   - Process with appropriate parser
  //   - If Android
  //     -

  // Upload Blossom
  Future<void> _uploadToBlossom() async {
    // TODO: Also upload images
    // await uploadToBlossom(newImagePath, imageHash, imageMimeType);

    for (final artifactPath in artifacts) {
      // TODO: Check if its in filemetadata x

      final uploadSpinner = CliSpin(
        text: 'Uploading artifact: $artifactPath...',
        spinner: CliSpinners.dots,
      ).start();

      final tempArtifactPath =
          path.join(Directory.systemTemp.path, path.basename(artifactPath));
      await File(artifactPath).copy(tempArtifactPath);
      final (artifactHash, newArtifactPath, mimeType) =
          await renameToHash(tempArtifactPath);

      if (!overwriteRelease) {
        await checkReleaseOnRelay(
          version: '1.1.1', // TODO: Version
          artifactHash: artifactHash,
          spinner: uploadSpinner,
        );
      }

      String artifactUrl = '';
      try {
        artifactUrl = await uploadToBlossom(
            newArtifactPath, artifactHash, mimeType,
            spinner: uploadSpinner);
        uploadSpinner
            .success('Uploaded artifact: $artifactPath to $artifactUrl');
      } catch (e) {
        uploadSpinner.fail(e.toString());
        rethrow;
      }

      // Ensure the file was fully uploaded
      // TODO: Test this
      final tempPackagePath =
          await fetchFile(artifactUrl, spinner: uploadSpinner);
      final computedHash = await computeHash(tempPackagePath);
      if (computedHash != artifactHash) {
        throw 'File was not correctly uploaded as hashes mismatch. Try again with --overwrite-release';
      }
    }
  }

  // Process item closure
  Future<void> processItem(
      {required YamlMap appMap, required SupportedOS os}) async {
    // Normalize artifacts section as a YamlMap (it could be a List)
    if (appMap['artifacts'] is YamlList) {
      final map = YamlMap();
      for (final a in appMap['artifacts']) {
        map[a] = YamlMap();
      }
      appMap['artifacts'] = map;
    }

    print('Publishing ${(appMap['name']!.toString()).bold()} $os app...');

    // TODO: Rethink "overwriting" app (only case would be re-pull from Play Store)

    // (1) Determine publishing method and ensure necessary data is okay
    late final PublishingMethod method;
    if (artifacts.isNotEmpty) {
      method = PublishingMethod.local;
    } else if (appMap.containsKey('version')) {
      // A version is needed to do web extraction, so assume web
      method = PublishingMethod.web;
    } else {
      // If no artifacts and no version, try github
      final repository = appMap['release_repository'] ?? appMap['repository'];
      if (repository == null) {
        if (isDaemonMode) {
          print('No sources provided, skipping');
          // Skips to the next entry in zapstore.yaml
          throw GracefullyAbortSignal();
        } else {
          throw UsageException('No sources provided',
              'Use the -a argument or add a repository in zapstore.yaml');
        }
      }
      final repositoryUri = Uri.parse(repository);
      if (repositoryUri.host != 'github.com') {
        throw 'Unsupported repository; service: ${repositoryUri.host}';
      }
      method = PublishingMethod.github;
    }

    // (2) Parse: Produces initial app, release, metadatas
    final (app, release, fileMetadatas) = switch (method) {
      PublishingMethod.local => await LocalParser().process(
          artifacts: artifacts,
          appMap: appMap,
          overwriteRelease: overwriteRelease,
          os: os,
        ),
      PublishingMethod.web => await WebParser().process(
          appMap: appMap,
          overwriteRelease: overwriteRelease,
        ),
      PublishingMethod.github => await GithubParser().process(
          releaseRepository: appMap['release_repository'],
          appMap: appMap,
          overwriteRelease: overwriteRelease,
        ),
    };

    // If release is absent, skip to next
    if (release == null) {
      print('No release, nothing to do');
      throw GracefullyAbortSignal();
    }

    // (3) If Android, check for extra metadata on Play Store, F-Droid, etc
    // This may update the app
    if (os == SupportedOS.android) {
      var extraMetadata = 0;
      CliSpin? extraMetadataSpinner;

      if (!isDaemonMode) {
        extraMetadata = Select(
          prompt: 'Would you like to pull extra metadata for this app?',
          options: ['Play Store', 'F-Droid', 'None'],
        ).interact();

        extraMetadataSpinner = CliSpin(
          text: 'Fetching extra metadata...',
          spinner: CliSpinners.dots,
        ).start();
      }

      if (extraMetadata == 0) {
        // TODO: Restore
        // final playStoreParser = PlayStoreParser();
        // app = await playStoreParser.run(
        //   app: app,
        //   originalName: appMap['name'],
        //   spinner: extraMetadataSpinner,
        // );
      } else if (extraMetadata == 1) {
        extraMetadataSpinner?.fail('F-Droid is not yet supported, sorry');
      }
    }

    // (4) Sign

    var (signedApp, signedRelease, signedFileMetadatas) = await finalizeEvents(
      app: app,
      release: release,
      fileMetadatas: fileMetadatas,
    );

    // (5) Publish and upload

    var publishEvents = true;

    if (!isDaemonMode) {
      print('\n');
      final viewEvents = Select(
        prompt: 'Events signed! How do you want to proceed?',
        options: [
          'Inspect the events and confirm before publishing to relays',
          'Publish the events to relays now',
          'Skip without publishing'
        ],
      ).interact();

      if (viewEvents == 0) {
        print('\n');
        print('App event (kind 32267)'.bold().black().onWhite());
        print('\n');
        printJsonEncodeColored(signedApp.toMap());

        print('\n');
        print('Release event (kind 30063)'.bold().black().onWhite());
        print('\n');
        printJsonEncodeColored(signedRelease.toMap());
        print('\n');
        print('File metadata events (kind 1063)'.bold().black().onWhite());
        print('\n');
        for (final m in signedFileMetadatas) {
          printJsonEncodeColored(m.toMap());
          print('\n');
        }

        publishEvents = Confirm(
          prompt:
              'Scroll up to check the events and press `y` when you\'re ready to publish',
          defaultValue: true,
        ).interact();
      } else if (viewEvents == 2) {
        throw GracefullyAbortSignal();
      }
    }

    var showWhitelistMessage = false;
    if (publishEvents == false) {
      print('No events published nor Blossom artifacts uploaded, exiting');
    } else {
      for (final BaseEvent event in [
        signedApp,
        signedRelease,
        ...signedFileMetadatas
      ]) {
        try {
          final spinner = CliSpin(
            text: 'Publishing kind ${event.kind}...',
            spinner: CliSpinners.dots,
            isSilent: isDaemonMode,
          ).start();
          await relay.publish(event);
          spinner.success(
              '${'Published'.bold()}: ${event.id.toString()} (kind ${event.kind})');
          if (isDaemonMode) {
            print('Published kind ${event.kind}');
          }
          if (method == PublishingMethod.local) {
            await _uploadToBlossom();
          }
        } catch (e) {
          print(
              '${e.toString().bold().black().onRed()}: ${event.id} (kind ${event.kind})');
          if (e.toString().contains('not accepted')) {
            showWhitelistMessage = true;
          }
        }
      }
    }

    if (showWhitelistMessage) {
      print(
          '\n${'Your npub is not whitelisted on the relay'.bold()}! If you want to self-publish your app, reach out.\n');
    }
  }

  // Now load YAML and loop

  final configYaml = File(configPath);

  if (!await configYaml.exists()) {
    throw UsageException('Config not found at $configPath',
        'Please create a zapstore.yaml file in this directory or pass it using `-c`. See https://zapstore.dev for documentation.');
  }

  final doc =
      Map<String, YamlMap>.from(loadYaml(await configYaml.readAsString()));

  for (final MapEntry(key: id, value: appObj) in doc.entries) {
    for (final MapEntry(key: osString, value: appMap as YamlMap)
        in appObj.entries) {
      if (onlyPublishAppId != null && onlyPublishAppId != id) {
        // Skip if unspecified in CLI
        continue;
      }
      try {
        await processItem(
          appMap: appMap,
          os: SupportedOS.from(osString),
        );
      } on GracefullyAbortSignal {
        continue;
      }
    }
  }
}

/// We check for apps with this same identifier (of any author, for simplicity)
/// NOTE: This logic is rerun during event signing once we know the author's pubkey
/// This allows us to be roughly correct about the correct overwriteApp value,
/// which will trigger fetching app information through the appropriate parser below.
Future<bool> ensureOverwriteApp(bool overwriteApp, String appIdentifier) async {
  final appsWithIdentifier = await relay.query<App>(
    tags: {
      '#d': [appIdentifier]
    },
  );
  // If none were found (first time publishing), we ignore the
  // overwrite argument and set it to true
  if (appsWithIdentifier.isEmpty) {
    print('First time publishing? Creating an app event (kind 32267)');
    overwriteApp = true;
  }
  return overwriteApp;
}

enum SupportedOS {
  cli,
  android;

  static SupportedOS from(dynamic value) {
    return SupportedOS.values.firstWhere((os) => os.name == value.toString());
  }
}

final fileRegex = RegExp(r'^[^\/<>|:&]*');

enum PublishingMethod { local, web, github }
