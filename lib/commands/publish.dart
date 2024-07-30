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
        var app = App(
            identifier: yamlApp['identifier'],
            name: yamlApp['name'],
            repository: yamlApp['repository']);
        final artifacts = Map<String, dynamic>.from(yamlApp['artifacts']);

        print('Releasing ${(app.name ?? appAlias).bold()} $os app...');

        try {
          // TODO: For `identifier` check https://www.cyberciti.biz/faq/linuxunix-rules-for-naming-file-and-directory-names/
          // TODO: Validate `platform` is present always

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
              'Please provide your nsec to sign and publish the events, it will be immediately discarded.\n(Ctrl+C to abort.)\n'
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
              nsec: nsec);

          // print([app, release, fileMetadatas]);
          // continue;

          for (final BaseEvent e in [app, release, ...fileMetadatas]) {
            try {
              await relay.publish(e);
            } catch (e) {
              print(e.toString().bold().black().onYellow());
            }
            print('Published kind ${e.kind}: ${e.id.toString().bold()}');
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
