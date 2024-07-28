import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:path/path.dart' as path;
import 'package:process_run/process_run.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:http/http.dart' as http;

Future<void> install(String value, {bool skipWot = false}) async {
  final db = await loadPackages();

  final hostPlatform =
      (await shell.run('uname -sm')).outText.toLowerCase().replaceAll(' ', '-');

  final spinner = CliSpin(
    text: 'Searching for $value...',
    spinner: CliSpinners.dots,
  ).start();

  final r1 = RelayRequest(
      kinds: {32267},
      search: value,
      tags: {
        '#f': [hostPlatform]
      });
  final apps = await queryZapstore(r1);

  if (apps.isEmpty) {
    spinner.fail('No packages found for $value');
    throw GracefullyAbortSignal();
  }

  var app = apps.first;

  if (apps.length > 1) {
    final packages = [
      for (final app in apps) '${getTag(app, 'name')} [${getTag(app, 'd')}]'
    ];

    final selection = Select(
      prompt: 'Which package?',
      options: packages,
    ).interact();

    app = apps[selection];
  }

  // TODO make this an App and use getLink()
  final aTag = '32267:${app['pubkey']}:${getTag(app, 'd')}';

  final r2 = RelayRequest(
      kinds: {30063},
      limit: 1,
      tags: {
        '#a': [aTag]
      });
  final releases = await queryZapstore(r2);

  if (releases.isEmpty) {
    spinner.fail('No releases found');
    throw GracefullyAbortSignal();
  }

  final eTags = (releases.first['tags'] as List)
      .where((t) => t[0] == 'e')
      .map((t) => t[1].toString());
  final r3 = RelayRequest(
      kinds: {1063},
      ids: eTags.toSet(),
      tags: {
        '#f': [hostPlatform]
      });

  final fileMetadatas = await queryZapstore(r3);

  if (fileMetadatas.isEmpty) {
    spinner.fail('No file metadatas found');
    throw GracefullyAbortSignal();
  }

  final meta = fileMetadatas[0];
  final appName = getTag(app, 'name');
  final packageUrl = getTag(meta, 'url');
  final appVersion = getTag(meta, 'version');
  // final appCreatedAt = meta.created_at;

  spinner.success('Found $appName@$appVersion');

  final appVersions = db[appName] as List?;

  var isUpdatable = false;
  var isAuthorTrusted = false;
  if (appVersions != null) {
    final appVersionInstalled =
        appVersions.firstWhereOrNull((v) => v['version'] == appVersion);
    if (appVersionInstalled != null) {
      if (appVersionInstalled['enabled'] ?? false) {
        spinner.success('Package $appName is already up to date');
      } else {
        final appFileName = buildAppName(appVersionInstalled['pubkey'], appName,
            appVersionInstalled['version']);
        await shell.run('ln -sf $appFileName $appName');
        spinner.success('Package $appName re-enabled');
      }
      exit(0);
    }

    isAuthorTrusted = appVersions.any((a) => meta['pubkey'] == a['pubkey']);

    isUpdatable = appVersions
        .every((a) => compareVersions(appVersion, a['version']) == 1);

    if (!isUpdatable) {
      final upToDate = appVersions
          .any((a) => compareVersions(appVersion, a['version']) == 0);
      if (upToDate) {
        print('Package already up to date $appName $appVersion');
        exit(0);
      }

      // Then there must be a -1 (downgrade)
      final higherVersion = appVersions.firstWhereOrNull(
          (a) => compareVersions(appVersion, a['version']) == -1);

      final installAnyway = Confirm(
        prompt:
            'Are you sure you want to downgrade $appName from ${higherVersion.version} to $appVersion?',
        defaultValue: false,
      ).interact();

      if (!installAnyway) {
        exit(0);
      }
    }
  }

  final packageBuilder = getTag(app, 'p');
  final builderNpub = packageBuilder.npub;
  final packageSigner = app['pubkey'].toString();
  final signerNpub = packageSigner.npub;

  if (!skipWot) {
    final container = ProviderContainer();
    final authorRelays = container.read(relayMessageNotifierProvider(
        ['wss://relay.nostr.band', 'wss://relay.primal.net']).notifier);
    authorRelays.initialize();
    if (!isAuthorTrusted) {
      final user = await ensureUser();

      final wotSpinner = CliSpin(
        text: 'Checking web of trust...',
        spinner: CliSpinners.dots,
      ).start();

      final trust = await http
          .get(Uri.parse(
              'https://trustgraph.live/api/fwf/${user['npub']}/$signerNpub'))
          .getJson();

      // Separate querying user from result
      final userFollows = trust.remove(user['npub']);

      final authors = [
        ...trust.keys.map((npub) => npub.hexKey),
        packageBuilder,
        packageSigner
      ];

      final r4 = RelayRequest(
        kinds: {0},
        authors: authors.toSet(),
      );
      final profileResponse = await authorRelays.query(r4);

      final profiles = {
        for (final profile in profileResponse)
          profile['pubkey'].toString().npub: jsonDecode(profile['content']),
      };

      final signerInfo = profiles[signerNpub];
      final signerText = signerInfo['display_name'] ?? signerInfo['name'];

      wotSpinner.success();

      print(
          'Package builder: ${formatProfile(profiles[builderNpub], builderNpub)}');
      print('Package signer: ${formatProfile(signerInfo, signerNpub)}\n');

      if (userFollows != null) {
        print(
            '${logger.ansi.blue}You${logger.ansi.none} follow ${logger.ansi.emphasized(signerText)}!\n');
      }

      print(
          '${userFollows != null ? 'Other profiles' : 'Profiles'} you follow who follow ${logger.ansi.emphasized(signerText)}:');
      for (final k in trust.keys) {
        print(' - ${formatProfile(profiles[k], k)}');
      }
      print('\n');

      final installPackage = Confirm(
        prompt:
            'Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} $appName${isUpdatable ? ' to $appVersion' : ''}?',
        defaultValue: false,
      ).interact();

      if (!installPackage) {
        exit(0);
      }
    } else {
      final r4 = await authorRelays
          .query(RelayRequest(kinds: {0}, authors: {packageSigner}));
      final signerInfo = r4.first;
      print(
          'Package signed by ${formatProfile(signerInfo, signerNpub)} who was previously trusted for this app');
    }
    await authorRelays.dispose();
  }

  final installSpinner = CliSpin(
    text: 'Installing package...',
    spinner: CliSpinners.dots,
  ).start();

  final appFileName = buildAppName(meta['pubkey'], appName, appVersion);
  final downloadPath =
      path.join(Directory.systemTemp.path, path.basename(packageUrl));
  await fetchFile(packageUrl, File(downloadPath), spinner: installSpinner);
  final appPath = path.join(kBaseDir, appFileName);

  final hash =
      await runInShell('cat $downloadPath | shasum -a 256 | head -c 64');

  if (hash != getTag(meta, 'x')) {
    await shell.run('rm -f $downloadPath');
    throw 'Hash mismatch! File server may be malicious, please report';
  }

  // Auto-extract
  if (downloadPath.endsWith('tar.gz')) {
    final extractDir = downloadPath.replaceFirst('.tar.gz', '');
    await shell.run('''
      mkdir -p $extractDir
      tar zxf $downloadPath -C $extractDir
      mv ${path.join(extractDir, appName)} $appPath
      rm -fr $extractDir $downloadPath
    ''');
  } else {
    await shell.run('mv $downloadPath $appPath');
  }

  await shell.run('chmod +x $appPath');
  await shell.run('ln -sf $appFileName $appName');

  installSpinner.success(
      'Installed package ${logger.ansi.emphasized(appName)}@$appVersion');
  exit(0);
}
