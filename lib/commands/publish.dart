import 'dart:io';

import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/github.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models.dart';

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
              App(
                  artifacts: Map<String, dynamic>.from(app['artifacts']),
                  identifier: app['identifier'],
                  name: app['name'],
                  repository: app['repository']),
              appAlias);
          break;
        case 'android':
          break;
        default:
      }
      // print('$appAlias $os $app');
    }
  }
}

Future<void> cli(App app, appAlias) async {
  print('Releasing ${logger.ansi.emphasized(app.name ?? appAlias)} CLI app...');

  // TODO: For `identifier` check https://www.cyberciti.biz/faq/linuxunix-rules-for-naming-file-and-directory-names/
  // TODO: Validate `platform` is present always

  final repoUrl = Uri.parse(app.repository!);

  App app2;
  Release release;
  List<FileMetadata> fileMetadatas;
  if (repoUrl.host == 'github.com') {
    final repo = repoUrl.path.substring(1);
    (app2, release, fileMetadatas) = await parseFromGithub(repo, app);
    print(app2.toMap());
    print('----');
    print(release.toMap());
    print('----');
    for (final f in fileMetadatas) {
      print(f.toMap());
    }
  } else {
    throw 'Unsupported repository; service: ${repoUrl.host}';
  }

  // sign

  print(logger.ansi.emphasized(
      'Please provide your nsec to sign the events. It is kept in memory for signing and will be immediately discarded'));
  final nsec = Password(prompt: 'nsec').interact();
  for (final BaseEvent e in [app, release, ...fileMetadatas]) {
    e.sign(nsec);
  }
  // print(app);
  // print(release);
}
