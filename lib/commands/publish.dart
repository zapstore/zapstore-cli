import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/apk.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/local_parser.dart';
import 'package:zapstore_cli/commands/publish/playstore_parser.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';

final fileRegex = RegExp(r'^[^\/<>|:&]*');

Future<void> publish(
    {String? requestedId,
    List<String> artifacts = const [],
    String? requestedVersion,
    String? releaseNotes,
    required bool overwriteApp,
    required bool overwriteRelease}) async {
  final yamlFile = File('zapstore.yaml');
  if (!await yamlFile.exists()) {
    throw UsageException('zapstore.yaml not found',
        'Please create a zapstore.yaml file in this directory. See https://zap.store for documentation.');
  }
  final doc =
      Map<String, dynamic>.from(loadYaml(await yamlFile.readAsString()));

  final container = ProviderContainer();
  late final RelayMessageNotifier relay;
  try {
    relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    await relay.initialize();

    for (final MapEntry(key: id, value: appObj) in doc.entries) {
      for (final MapEntry(key: os, value: yamlApp) in appObj.entries) {
        if (requestedId != null && requestedId != id) {
          continue;
        }

        final builderNpub = yamlApp['builder']?.toString();
        final builderPubkeyHex = builderNpub?.hexKey;

        // Ensure identifier can be included in a filesystem path
        if (id.length > 255 || fileRegex.stringMatch(id) != id) {
          throw 'Invalid identifier $id';
        }

        var app = App(
          identifier: id,
          content: yamlApp['description'] ?? yamlApp['summary'],
          name: yamlApp['name'],
          summary: yamlApp['summary'],
          repository: yamlApp['repository'],
          license: yamlApp['license'],
          pubkeys: {if (builderPubkeyHex != null) builderPubkeyHex},
          zapTags: {if (builderPubkeyHex != null) builderPubkeyHex},
        );

        var yamlArtifacts = <String, dynamic>{};
        if (yamlApp['artifacts'] is YamlList) {
          for (final a in yamlApp['artifacts']) {
            yamlArtifacts[a] = {};
          }
        } else if (yamlApp['artifacts'] is YamlMap) {
          yamlArtifacts = Map<String, dynamic>.from(yamlApp['artifacts']);
        } else {
          throw 'Invalid artifacts format, it must be a list or a map:\n${yamlApp['artifacts']}';
        }

        print('Publishing ${(app.name ?? id).bold()} $os app...');

        if (overwriteApp == false) {
          // We check for apps with this same identifier (of any author, for simplicity)
          // NOTE: This logic is rerun during event signing once we know the author's pubkey
          // This allows us to be roughly correct about the correct overwriteApp value,
          // which will trigger fetching app information through the appropriate parser below.
          final appsWithIdentifier = await relay.query<App>(
            tags: {
              '#d': [app.identifier]
            },
          );
          // If none were found (first time publishing), we ignore the
          // overwrite argument and set it to true
          if (appsWithIdentifier.isEmpty) {
            overwriteApp = true;
          }
        }

        try {
          Release release;
          Set<FileMetadata> fileMetadatas;

          if (artifacts.isNotEmpty) {
            final parser = LocalParser(
                app: app,
                artifacts: artifacts,
                requestedVersion: requestedVersion,
                relay: relay);

            (app, release, fileMetadatas) = await parser.process(
              os: os,
              overwriteRelease: overwriteRelease,
              yamlArtifacts: yamlArtifacts,
              releaseNotes: releaseNotes,
            );
          } else {
            // TODO: Should be able to run both local AND Github/other parsers
            if (app.repository == null) {
              throw UsageException('No sources provided',
                  'Use the -a option or configure a repository in zapstore.yaml');
            }
            final repoUrl = Uri.parse(app.repository!);
            if (repoUrl.host == 'github.com') {
              final githubParser = GithubParser(relay: relay);
              final repo = repoUrl.path.substring(1);
              (app, release, fileMetadatas) = await githubParser.run(
                app: app,
                os: os,
                repoName: repo,
                artifacts: yamlArtifacts,
                overwriteApp: overwriteApp,
                overwriteRelease: overwriteRelease,
              );
            } else {
              throw 'Unsupported repository; service: ${repoUrl.host}';
            }
          }

          if (os == 'android') {
            final newFileMetadatas = <FileMetadata>{};
            for (var fileMetadata in fileMetadatas) {
              final (appFromApk, releaseFromApk, newFileMetadata) =
                  await parseApk(app, release, fileMetadata);
              // App from APK has the updated identifier
              app = appFromApk;
              release = releaseFromApk;
              final icon = newFileMetadata.transientData['iconBlossomUrl'];
              if (icon != null) {
                app = app.copyWith(icons: {icon});
              }
              newFileMetadatas.add(newFileMetadata);
            }
            fileMetadatas = newFileMetadatas;

            if (overwriteApp) {
              final extraMetadata = Select(
                prompt: 'Would you like to pull extra metadata for this app?',
                options: ['Play Store', 'F-Droid', 'None'],
              ).interact();

              final extraMetadataSpinner = CliSpin(
                text: 'Fetching extra metadata...',
                spinner: CliSpinners.dots,
              ).start();

              if (extraMetadata == 0) {
                final playStoreParser = PlayStoreParser();
                app = await playStoreParser.run(
                    app: app, spinner: extraMetadataSpinner);
              } else if (extraMetadata == 1) {
                extraMetadataSpinner
                    .fail('F-Droid is not yet supported, sorry');
              }
            }
          }

          // sign

          print(
              'Please provide your nsec (or via the NSEC env var) to sign the events, it will be discarded IMMEDIATELY after. More signing options are coming soon. If unsure, run this program from source.'
                  .bold());
          var nsec = Platform.environment['NSEC'] ??
              Password(prompt: 'nsec').interact();

          if (nsec.startsWith('nsec')) {
            nsec = bech32Decode(nsec);
          }
          if (!hexRegexp.hasMatch(nsec)) {
            throw 'Bad nsec, or the input was cropped. Try again with a wider terminal.';
          }

          var (signedApp, signedRelease, signedFileMetadatas) =
              await finalizeEvents(
            app: app,
            release: release,
            fileMetadatas: fileMetadatas,
            nsec: nsec,
            overwriteApp: overwriteApp,
            relay: relay,
          );

          print('\n');
          final viewEvents = Select(
            prompt: 'Events signed! How do you want to proceed?',
            options: [
              'Inspect the events and confirm before publishing to relays',
              'Publish the events to relays now'
            ],
          ).interact();

          var publishEvents = true;
          if (viewEvents == 0) {
            if (signedApp != null) {
              print('\n');
              print('App event (kind 32267)'.bold().black().onWhite());
              print('\n');
              printJsonEncodeColored(signedApp.toMap());
            }
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
          }

          var showWhitelistMessage = false;
          if (publishEvents == false) {
            print('Events NOT published, exiting');
          } else {
            for (final BaseEvent event in [
              if (signedApp != null) signedApp,
              signedRelease,
              ...signedFileMetadatas
            ]) {
              try {
                final spinner = CliSpin(
                  text: 'Publishing kind ${event.kind}...',
                  spinner: CliSpinners.dots,
                ).start();
                await relay.publish(event);
                spinner.success(
                    '${'Published'.bold()}: ${event.id.toString()} (kind ${event.kind})');
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
        } on GracefullyAbortSignal {
          continue;
        }
      }
    }
  } catch (e) {
    rethrow;
  } finally {
    await relay.dispose();
    container.dispose();
  }
}
