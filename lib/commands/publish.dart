import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/apk.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/github.dart';
import 'package:zapstore_cli/commands/publish/local.dart';
import 'package:zapstore_cli/models.dart';
import 'package:zapstore_cli/utils.dart';

final fileRegex = RegExp(r'^[^\/<>|:&]*');

Future<void> publish(
    {String? appAlias,
    List<String> artifacts = const [],
    String? version}) async {
  final yamlFile = File('zapstore.yaml');
  if (!await yamlFile.exists()) {
    throw 'zapstore.yaml not found';
  }
  final doc =
      Map<String, dynamic>.from(loadYaml(await yamlFile.readAsString()));

  final container = ProviderContainer();
  late final RelayMessageNotifier relay;
  try {
    relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    relay.initialize(); // TODO await

    for (final MapEntry(key: yamlAppAlias, value: appObj) in doc.entries) {
      for (final MapEntry(key: os, value: yamlApp) in appObj.entries) {
        if (appAlias != null && appAlias != yamlAppAlias) {
          continue;
        }

        final id = yamlApp['identifier']?.toString();
        final builderNpub = yamlApp['builder']?.toString();
        final builderPubkeyHex = builderNpub?.hexKey;

        // Ensure identifier can be included in a filesystem path
        if (id == null || id.length > 255 || fileRegex.stringMatch(id) != id) {
          throw 'Invalid identifier $id';
        }

        var app = App(
          identifier: id,
          content: yamlApp['description'] ?? yamlApp['summary'],
          name: yamlApp['name'],
          summary: yamlApp['summary'],
          repository: yamlApp['repository'],
          pubkeys: {if (builderPubkeyHex != null) builderPubkeyHex},
          zapTags: {if (builderPubkeyHex != null) builderPubkeyHex},
        );
        final yamlArtifacts = Map<String, dynamic>.from(yamlApp['artifacts']);

        print('Publishing ${(app.name ?? yamlAppAlias).bold()} $os app...');

        try {
          final repoUrl = Uri.parse(app.repository!);

          Release release;
          Set<FileMetadata> fileMetadatas;

          if (artifacts.isNotEmpty) {
            (release, fileMetadatas) = await LocalParser(
                    app: app,
                    artifacts: artifacts,
                    version: version!,
                    relay: relay)
                .process(os: os, yamlArtifacts: yamlArtifacts);
          } else {
            if (repoUrl.host == 'github.com') {
              final githubFetcher = GithubParser(relay: relay);
              final repo = repoUrl.path.substring(1);
              (app, release, fileMetadatas) = await githubFetcher.fetch(
                app: app,
                os: os,
                repoName: repo,
                artifacts: yamlArtifacts,
              );
            } else {
              throw 'Unsupported repository; service: ${repoUrl.host}';
            }
          }

          if (os == 'android') {
            final newFileMetadatas = <FileMetadata>[];
            for (var fileMetadata in fileMetadatas) {
              newFileMetadatas.add(await parseApk(fileMetadata, '')); // TODO
            }
            print(newFileMetadatas);

            // final extraMetadata = Select(
            //   prompt: 'Would you like to pull extra metadata?',
            //   options: ['Play Store', 'F-Droid', 'None'],
            // ).interact();

            // if (extraMetadata == 0) {
            //   final playStoreFetcher = PlayStoreFetcher();
            //   (app, _, _) = await playStoreFetcher.fetch(app: app);
            // }
          }

          // sign

          print(
              'Please provide your nsec to sign the events, it will be discarded immediately after.'
                  .bold());
          var nsec = Platform.environment['NSEC'] ??
              Password(prompt: 'nsec').interact();

          if (nsec.startsWith('nsec')) {
            nsec = bech32Decode(nsec);
          }
          if (!hexRegexp.hasMatch(nsec)) {
            throw 'Bad nsec, or the input was cropped. Try again with a wider terminal.';
          }

          (app, release, fileMetadatas) = await finalizeEvents(
            app: app,
            release: release,
            fileMetadatas: fileMetadatas,
            nsec: nsec,
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
            print('\n');
            print('App event (kind 32267)'.bold().black().onWhite());
            print('\n');
            printJsonEncodeColored(app.toMap());
            print('\n');
            print('Release event (kind 30063)'.bold().black().onWhite());
            print('\n');
            printJsonEncodeColored(release.toMap());
            print('\n');
            print('File metadata events (kind 1063)'.bold().black().onWhite());
            print('\n');
            for (final m in fileMetadatas) {
              printJsonEncodeColored(m.toMap());
              print('\n');
            }
            publishEvents = Confirm(
              prompt:
                  'Scroll up to check the events and press `y` when you\'re ready to publish',
              defaultValue: true,
            ).interact();
          }

          if (publishEvents == false) {
            print('Events NOT published, exiting');
          } else {
            for (final BaseEvent event in [app, release, ...fileMetadatas]) {
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
              }
            }
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

abstract class RepositoryParser {
  Future<(App, Release, Set<FileMetadata>)> fetch({
    required App app,
    required String os,
  });
}
