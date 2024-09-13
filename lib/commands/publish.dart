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
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/commands/publish/web_parser.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';

final fileRegex = RegExp(r'^[^\/<>|:&]*');

Future<void> publish({
  String? requestedId,
  required List<String> artifacts,
  String? version,
  String? releaseNotes,
  required bool overwriteApp,
  required bool overwriteRelease,
  required bool daemon,
  String? icon,
  required List<String> images,
}) async {
  final yamlFile = File('zapstore.yaml');

  if (!await yamlFile.exists()) {
    throw UsageException('zapstore.yaml not found',
        'Please create a zapstore.yaml file in this directory. See https://zap.store for documentation.');
  }

  final doc =
      Map<String, YamlMap>.from(loadYaml(await yamlFile.readAsString()));

  final container = ProviderContainer();
  late final RelayMessageNotifier relay;
  try {
    relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    await relay.initialize();

    for (final MapEntry(key: id, value: appObj) in doc.entries) {
      for (final MapEntry(:key, value: yamlApp) in appObj.entries) {
        if (requestedId != null && requestedId != id) {
          continue;
        }
        final os = SupportedOS.from(key);

        final builderNpub = yamlApp['builder']?.toString();
        final builderPubkeyHex = builderNpub?.hexKey;

        // Ensure identifier can be included in a filesystem path
        if (id.length > 255 || fileRegex.stringMatch(id) != id) {
          throw 'Invalid identifier $id';
        }

        var app = App(
          identifier: os == SupportedOS.android ? null : id,
          content: yamlApp['description'] ?? yamlApp['summary'],
          name: yamlApp['name'],
          summary: yamlApp['summary'],
          repository: yamlApp['repository'],
          icons: {
            if (icon != null) ...await _processImages([icon])
          },
          images: await _processImages(images),
          license: yamlApp['license'],
          pubkeys: {if (builderPubkeyHex != null) builderPubkeyHex},
          zapTags: {if (builderPubkeyHex != null) builderPubkeyHex},
        );

        var yamlArtifacts = <String, YamlMap>{};
        if (yamlApp['artifacts'] is YamlList) {
          for (final a in yamlApp['artifacts']) {
            yamlArtifacts[a] = YamlMap();
          }
        } else if (yamlApp['artifacts'] is YamlMap) {
          yamlArtifacts = Map<String, YamlMap>.from(yamlApp['artifacts']);
        }

        print('Publishing ${(app.name ?? id).bold()} $os app...');

        var _overwriteApp = overwriteApp;
        if (app.identifier != null) {
          _overwriteApp =
              await ensureOverwriteApp(_overwriteApp, relay, app.identifier!);
        }

        try {
          Release? release;
          Set<FileMetadata> fileMetadatas;

          if (artifacts.isNotEmpty) {
            final parser = LocalParser(
                app: app,
                artifacts: artifacts,
                version: version!,
                relay: relay);

            (app, release, fileMetadatas) = await parser.process(
              overwriteRelease: overwriteRelease,
              yamlArtifacts: yamlArtifacts,
              releaseNotes: releaseNotes,
            );
          } else if (yamlApp['web'] != null) {
            await WebParser(relay: relay).run(
                app: app,
                url: yamlApp['web'],
                overwriteApp: overwriteApp,
                overwriteRelease: overwriteRelease);
            exit(0);
          } else {
            final repository = app.repository ?? yamlApp['release_repository'];
            if (repository == null) {
              if (daemon) {
                print('No sources provided, skipping');
                continue;
              } else {
                throw UsageException('No sources provided, ',
                    'Use the -a argument or add a repository in zapstore.yaml');
              }
            }

            final repoUrl = Uri.parse(repository!);
            if (repoUrl.host == 'github.com') {
              final githubParser = GithubParser(relay: relay);
              (app, release, fileMetadatas) = await githubParser.process(
                app: app,
                artifacts: yamlArtifacts,
                releaseRepository: yamlApp['release_repository'],
                overwriteRelease: overwriteRelease,
              );
            } else {
              throw 'Unsupported repository; service: ${repoUrl.host}';
            }
          }

          if (os == SupportedOS.android) {
            if (release != null) {
              final newFileMetadatas = <FileMetadata>{};
              for (var fileMetadata in fileMetadatas) {
                final (appFromApk, releaseFromApk, newFileMetadata) =
                    await parseApk(app, release!, fileMetadata);
                // App from APK has the updated identifier (and release)
                app = appFromApk;
                release = releaseFromApk;
                newFileMetadatas.add(newFileMetadata);
              }
              fileMetadatas = newFileMetadatas;
            }
            if (app.identifier != null) {
              _overwriteApp = await ensureOverwriteApp(
                  _overwriteApp, relay, app.identifier!);
            }

            if (_overwriteApp) {
              var extraMetadata = 0;
              CliSpin? extraMetadataSpinner;

              if (!daemon) {
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
                final playStoreParser = PlayStoreParser();
                app = await playStoreParser.run(
                    app: app, spinner: extraMetadataSpinner);
              } else if (extraMetadata == 1) {
                extraMetadataSpinner
                    ?.fail('F-Droid is not yet supported, sorry');
              }
            }
          }

          // sign

          var nsec = env['NSEC'];

          if (!daemon && nsec == null) {
            print('''\n
***********
Please provide your nsec (in nsec or hex format) to sign the events.

${' It will be discarded IMMEDIATELY after signing! '.bold().onYellow().black()}

For non-interactive use, pass the NSEC environment variable. More signing options coming soon.
If unsure, run this program from source. See https://github.com/zapstore/zapstore-cli'
***********
''');
            nsec ??= Password(prompt: 'nsec').interact();
          }

          if (nsec!.startsWith('nsec')) {
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
            overwriteApp: _overwriteApp,
            relay: relay,
          );

          var publishEvents = true;

          if (!daemon) {
            final hasApp = signedApp != null && signedApp.identifier != null;
            final hasRelease = signedRelease != null;

            if (!hasApp && !hasRelease) {
              continue;
            }

            print('\n');
            final viewEvents = Select(
              prompt: 'Events signed! How do you want to proceed?',
              options: [
                'Inspect the events and confirm before publishing to relays',
                'Publish the events to relays now',
                'Continue without publishing'
              ],
            ).interact();

            if (viewEvents == 0) {
              if (hasApp && _overwriteApp) {
                print('\n');
                print('App event (kind 32267)'.bold().black().onWhite());
                print('\n');
                printJsonEncodeColored(signedApp.toMap());
              }
              if (hasRelease) {
                print('\n');
                print('Release event (kind 30063)'.bold().black().onWhite());
                print('\n');
                printJsonEncodeColored(signedRelease.toMap());
                print('\n');
                print('File metadata events (kind 1063)'
                    .bold()
                    .black()
                    .onWhite());
                print('\n');
                for (final m in signedFileMetadatas) {
                  printJsonEncodeColored(m.toMap());
                  print('\n');
                }
              }
              publishEvents = Confirm(
                prompt:
                    'Scroll up to check the events and press `y` when you\'re ready to publish',
                defaultValue: true,
              ).interact();
            } else if (viewEvents == 2) {
              continue;
            }
          }

          var showWhitelistMessage = false;
          if (publishEvents == false) {
            print('Events NOT published, exiting');
          } else {
            for (final BaseEvent event in [
              if (signedApp != null) signedApp,
              if (signedRelease != null) signedRelease,
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

/// We check for apps with this same identifier (of any author, for simplicity)
/// NOTE: This logic is rerun during event signing once we know the author's pubkey
/// This allows us to be roughly correct about the correct overwriteApp value,
/// which will trigger fetching app information through the appropriate parser below.
Future<bool> ensureOverwriteApp(
    bool overwriteApp, RelayMessageNotifier relay, String appIdentifier) async {
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
    return SupportedOS.values
        .firstWhere((_) => _.toString() == value.toString());
  }

  static Iterable<String> get all {
    return SupportedOS.values.map((_) => _.toString());
  }

  @override
  String toString() {
    return super.toString().split('.').last;
  }
}

Future<Set<String>> _processImages(List<String> imagePaths) async {
  final imageBlossomUrls = <String>{};
  for (final imagePath in imagePaths) {
    final (imageHash, newImagePath, imageMimeType) =
        await renameToHash(imagePath);
    final imageBlossomUrl =
        await uploadToBlossom(newImagePath, imageHash, imageMimeType);
    imageBlossomUrls.add(imageBlossomUrl);
  }
  return imageBlossomUrls;
}
