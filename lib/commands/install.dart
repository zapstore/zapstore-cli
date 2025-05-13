import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:process_run/process_run.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

Future<void> install(String value, {bool skipWot = false}) async {
  final db = await loadPackages();

  final pv = Platform.version.split('on').lastOrNull?.trim();

  final hostPlatform = switch (pv) {
    '"macos_arm64"' => 'darwin-arm64',
    '"linux_arm64"' => 'linux-aarch64',
    '"linux_amd64"' => 'linux-amd64',
    _ => throw UnsupportedError('$pv'),
  };

  final spinner = CliSpin(
    text: 'Searching for $value...',
    spinner: CliSpinners.dots,
  ).start();

  final apps = await storage.query<App>(RequestFilter(remote: true, tags: {
    '#f': {hostPlatform}
  }));

  if (apps.isEmpty) {
    spinner.fail('No packages found for $value');
    throw GracefullyAbortSignal();
  }

  var app = apps.first;

  if (apps.length > 1) {
    final packages = [
      for (final app in apps) '${app.name} [${app.event.identifier}]'
    ];

    final selection = Select(
      prompt: 'Which package?',
      options: packages,
    ).interact();

    app = apps[selection];
  }

  final releases = await storage.query<Release>(RequestFilter(
    remote: true,
    tags: app.event.addressableIdTagMap,
    limit: 1,
  ));

  if (releases.isEmpty) {
    spinner.fail('No releases found');
    throw GracefullyAbortSignal();
  }

  final fileMetadatas = await storage.query<FileMetadata>(RequestFilter(
    remote: true,
    ids: releases.first.event.getTagSetValues('e'),
    tags: {
      '#f': {hostPlatform}
    },
  ));

  if (fileMetadatas.isEmpty) {
    spinner.fail('No file metadatas found');
    throw GracefullyAbortSignal();
  }

  final meta = fileMetadatas[0];

  spinner.success(
      'Found ${app.event.identifier}@${meta.version?.bold()} (released on ${meta.createdAt.toIso8601String()})\n  ${app.summary ?? app.description}');

  final installedPackage = db[app.id];

  var isUpdatable = false;
  var isAuthorTrusted = false;
  if (installedPackage != null) {
    final appVersionInstalled =
        installedPackage.versions.firstWhereOrNull((v) => v == meta.version);
    if (appVersionInstalled != null) {
      if (appVersionInstalled == installedPackage.enabledVersion) {
        spinner
            .success('Package ${app.event.identifier} is already up to date');
      } else {
        installedPackage.linkVersion(meta.version!);
        spinner.success('Package ${app.event.identifier} re-enabled');
      }
      exit(0);
    }

    isAuthorTrusted = installedPackage.pubkey == meta.event.pubkey;

    isUpdatable = installedPackage.versions
        .every((version) => compareVersions(meta.version!, version) == 1);

    if (!isUpdatable) {
      final upToDate = installedPackage.versions
          .any((version) => compareVersions(meta.version!, version) == 0);
      if (upToDate) {
        print(
            'Package already up to date ${app.event.identifier} ${meta.version}');
        exit(0);
      }

      // Then there must be a -1 (downgrade)
      final higherVersion = installedPackage.versions.firstWhereOrNull(
          (version) => compareVersions(meta.version!, version) == -1);

      final installAnyway = Confirm(
        prompt:
            'Are you sure you want to downgrade ${app.event.identifier} from $higherVersion to ${meta.version}?',
        defaultValue: false,
      ).interact();

      if (!installAnyway) {
        exit(0);
      }
    }
  }

  final packageDeveloper = app.event.pubkey;
  final developerNpub = Utils.npubFromHex(packageDeveloper);
  final packageSigner = app.event.pubkey;
  final signerNpub = Utils.npubFromHex(packageSigner);

  if (!skipWot) {
    if (!isAuthorTrusted) {
      final user = await checkUser();

      if (user['npub'] != null) {
        final wotSpinner = CliSpin(
          text: 'Checking web of trust...',
          spinner: CliSpinners.dots,
        ).start();

        late final Map<String, dynamic> trust;

        try {
          trust = await http
              .get(Uri.parse(
                  'https://trustgraph.live/api/fwf/${user['npub']}/$signerNpub'))
              .getJson();
        } catch (e) {
          wotSpinner.fail(
              'Error returned from web of trust service, please try again later or re-run with -t to skip this check.');
          throw GracefullyAbortSignal();
        }

        // Separate querying user from result
        final userFollows = trust.remove(user['npub']);

        final authors = {
          ...trust.keys.map((npub) => Utils.hexFromNpub(npub)),
          packageDeveloper,
          packageSigner
        };

        final users = await storage.query<Profile>(RequestFilter(
            authors: authors, remote: true, relayGroup: 'social'));

        final signerUser = users.firstWhereOrNull((e) => e.npub == signerNpub)!;
        final developerUser =
            users.firstWhereOrNull((e) => e.npub == developerNpub)!;

        wotSpinner.success();

        print('Package developer: ${formatProfile(developerUser)}');
        print('Package signer: ${formatProfile(signerUser)}\n');

        if (userFollows != null) {
          print('You follow ${signerUser.name!.toString().bold()}!\n');
        }

        print(
            '${userFollows != null ? 'Other profiles' : 'Profiles'} you follow who follow ${signerUser.name!.bold()}:');
        for (final k in trust.keys) {
          print(
              ' - ${formatProfile(users.firstWhereOrNull((e) => e.npub == k)!)}');
        }
        print('\n');

        final installPackage = Confirm(
          prompt:
              'Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} ${app.event.identifier}${isUpdatable ? ' to ${meta.version}' : ''}?',
          defaultValue: false,
        ).interact();

        if (!installPackage) {
          exit(0);
        }
      } else {
        print('Skipping web of trust check...\n');
      }
    } else {
      final users = await storage.query<Profile>(RequestFilter(
          authors: {packageSigner}, remote: true, relayGroup: 'social'));
      print(
          'Package signed by ${formatProfile(users.first)} who was previously trusted for this app');
    }
  }

  // On first install, check if other executables are present in PATH
  if (db[app.event.identifier] == null) {
    FileMetadata;
    final presentInPath =
        (meta.executables.isEmpty ? {app.event.identifier} : meta.executables)
            .map((e) {
      final p = whichSync(path.basename(e));
      return p != null ? path.basename(e) : null;
    }).nonNulls;

    if (presentInPath.isNotEmpty) {
      final installAnyway = Confirm(
        prompt:
            'The executables $presentInPath already exist in PATH, likely from another package manager. Would you like to continue installation?',
        defaultValue: true,
      ).interact();
      if (!installAnyway) {
        exit(0);
      }
    }
  }

  final installSpinner = CliSpin(
    text: 'Installing package ${app.event.identifier}...',
    spinner: CliSpinners.dots,
  ).start();

  final package = db[app.event.identifier] ??
      Package(
          identifier: app.event.identifier,
          pubkey: meta.event.pubkey,
          versions: {meta.version!},
          enabledVersion: meta.version!);

  await package.installFromUrl(meta, spinner: installSpinner);

  installSpinner.success(
      'Installed package ${app.event.identifier.bold()}@${meta.version}');
}
