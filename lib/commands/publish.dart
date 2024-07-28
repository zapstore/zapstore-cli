import 'dart:io';

import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/events.dart';
import 'package:zapstore_cli/commands/publish/fetchers.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models.dart';
import 'package:zapstore_cli/utils.dart';

Future<void> publish(String? value) async {
  final doc = Map<String, dynamic>.from(
      loadYaml(await File('zapstore.yaml').readAsString()));

  for (final MapEntry(key: appAlias, value: appObj) in doc.entries) {
    for (final MapEntry(key: os, value: app) in appObj.entries) {
      if (value != null && value != appAlias) {
        continue;
      }
      switch (os) {
        case 'cli':
          await cli(
              app: App(
                  identifier: app['identifier'],
                  name: app['name'],
                  repository: app['repository']),
              artifacts: Map<String, dynamic>.from(app['artifacts']),
              appAlias: appAlias);
          break;
        case 'android':
          break;
        default:
      }
      // print('$appAlias $os $app');
    }
  }
}

Future<void> cli(
    {required App app,
    required String appAlias,
    required Map<String, dynamic> artifacts}) async {
  print('Releasing ${logger.ansi.emphasized(app.name ?? appAlias)} CLI app...');

  // TODO: For `identifier` check https://www.cyberciti.biz/faq/linuxunix-rules-for-naming-file-and-directory-names/
  // TODO: Validate `platform` is present always

  final repoUrl = Uri.parse(app.repository!);

  Release release;
  Set<FileMetadata> fileMetadatas;
  if (repoUrl.host == 'github.com') {
    final fetcher = GithubFetcher();
    final repo = repoUrl.path.substring(1);
    (app, release, fileMetadatas) =
        await fetcher.fetch(app: app, repoName: repo, artifacts: artifacts);
  } else {
    throw 'Unsupported repository; service: ${repoUrl.host}';
  }

  // sign

  print(logger.ansi.emphasized(
      'Please provide your nsec to sign and publish the events, it will be immediately discarded.\n(Ctrl+C to abort.)\n'));
  var nsec =
      Platform.environment['NSEC'] ?? Password(prompt: 'nsec').interact();

  if (nsec.startsWith('nsec')) {
    nsec = bech32Decode(nsec);
  }
  if (!hexRegexp.hasMatch(nsec)) {
    throw 'Bad nsec';
  }

  (app, release, fileMetadatas) = await finalizeEvents(
      app: app, release: release, fileMetadatas: fileMetadatas, nsec: nsec);

  print('app -----');
  print(app);
  print('release -----');
  print(release);
  for (final f in fileMetadatas) {
    print('fm -----');
    print(f);
  }

  final container = ProviderContainer();
  final relay = container
      .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
  relay.initialize();
  for (final BaseEvent e in [app, release, ...fileMetadatas]) {
    print('publishing ${e.id}');
    await relay.publish(e);
  }
  await relay.dispose();
}
