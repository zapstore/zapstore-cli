import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/commands/install.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils/utils.dart';

Future<void> discover() async {
  final db = await Package.loadAll();

  final spinner = CliSpin(
    text: 'Finding great packages...',
    spinner: CliSpinners.dots,
  ).start();

  final apps = await storage.query(
    RequestFilter<App>(
      limit: 30,
      tags: {
        '#f': {hostPlatform},
      },
    ).toRequest(),
  );

  if (apps.isEmpty) {
    spinner.fail('No packages found');
    exit(0);
  }

  spinner.success('Found some cool stuff\n');

  final appsNotInstalled = apps
      .where((app) => !db.containsKey(app.identifier))
      .toList();

  final appIds = [
    for (final app in appsNotInstalled) '${app.name} [${app.identifier}]',
  ];

  final selection = Select(
    prompt: 'Select a package to install',
    options: appIds,
  ).interact();

  final app = appsNotInstalled[selection];

  await install('', fromDiscover: app, skipWot: true);
}
