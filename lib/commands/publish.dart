import 'dart:io';

import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/fetchers.dart';
import 'package:zapstore_cli/models.dart';
import 'package:zapstore_cli/utils.dart';

final fileRegex = RegExp(r'^[^\/<>|:&]*');

Future<void> publish(String? value) async {
  final doc = Map<String, dynamic>.from(
      loadYaml(await File('zapstore.yaml').readAsString()));

  final container = ProviderContainer();
  late final RelayMessageNotifier relay;
  try {
    relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    relay.initialize();

    for (final MapEntry(key: appAlias, value: appObj) in doc.entries) {
      for (final MapEntry(key: os, value: yamlApp) in appObj.entries) {
        if (value != null && value != appAlias) {
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
          name: yamlApp['name'],
          repository: yamlApp['repository'],
          pubkeys: {if (builderPubkeyHex != null) builderPubkeyHex},
        );
        final artifacts = Map<String, dynamic>.from(yamlApp['artifacts']);

        print('Releasing ${(app.name ?? appAlias).bold()} $os app...');

        try {
          final repoUrl = Uri.parse(app.repository!);

          Release release;
          Set<FileMetadata> fileMetadatas;
          if (repoUrl.host == 'github.com') {
            final fetcher = GithubFetcher(relay: relay);
            final repo = repoUrl.path.substring(1);
            (app, release, fileMetadatas) = await fetcher.fetch(
                app: app, repoName: repo, artifacts: artifacts);
          } else {
            throw 'Unsupported repository; service: ${repoUrl.host}';
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
            for (final BaseEvent e in [app, release, ...fileMetadatas]) {
              try {
                await relay.publish(e);
              } catch (e) {
                print(e.toString().bold().black().onYellow());
              }
              print('Published kind ${e.kind}: ${e.id.toString().bold()}');
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
