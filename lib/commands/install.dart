import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:process_run/process_run.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

Future<void> install(String value, {bool skipWot = false}) async {
  final container = ProviderContainer();
  RelayMessageNotifier? relay;
  try {
    final db = await loadPackages();

    final hostPlatform = (await shell.run('uname -sm'))
        .outText
        .toLowerCase()
        .replaceAll(' ', '-');

    final spinner = CliSpin(
      text: 'Searching for $value...',
      spinner: CliSpinners.dots,
    ).start();

    relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    await relay!.initialize();

    final apps = await relay.query<App>(search: value, tags: {
      '#f': [hostPlatform]
    });

    if (apps.isEmpty) {
      spinner.fail('No packages found for $value');
      throw GracefullyAbortSignal();
    }

    var app = apps.first;

    if (apps.length > 1) {
      final packages = [
        for (final app in apps) '${app.name} [${app.identifier}]'
      ];

      final selection = Select(
        prompt: 'Which package?',
        options: packages,
      ).interact();

      app = apps[selection];
    }

    final releases = await relay.query<Release>(limit: 1, tags: {
      '#a': [app.getReplaceableEventLink().formatted]
    });

    if (releases.isEmpty) {
      spinner.fail('No releases found');
      throw GracefullyAbortSignal();
    }

    final fileMetadatas = await relay.query<FileMetadata>(
      ids: releases.first.linkedEvents,
      tags: {
        '#f': [hostPlatform]
      },
    );

    if (fileMetadatas.isEmpty) {
      spinner.fail('No file metadatas found');
      throw GracefullyAbortSignal();
    }

    final meta = fileMetadatas[0];

    spinner.success(
        'Found ${app.identifier}@${meta.version?.bold()} (released on ${meta.createdAt!.toIso8601String()})');

    final installedPackage = db[app.identifier];

    var isUpdatable = false;
    var isAuthorTrusted = false;
    if (installedPackage != null) {
      final appVersionInstalled =
          installedPackage.versions.firstWhereOrNull((v) => v == meta.version);
      if (appVersionInstalled != null) {
        if (appVersionInstalled == installedPackage.enabledVersion) {
          spinner.success('Package ${app.identifier} is already up to date');
        } else {
          installedPackage.linkVersion(meta.version!);
          spinner.success('Package ${app.identifier} re-enabled');
        }
        exit(0);
      }

      isAuthorTrusted = installedPackage.pubkey == meta.pubkey;

      isUpdatable = installedPackage.versions
          .every((version) => compareVersions(meta.version!, version) == 1);

      if (!isUpdatable) {
        final upToDate = installedPackage.versions
            .any((version) => compareVersions(meta.version!, version) == 0);
        if (upToDate) {
          print('Package already up to date ${app.identifier} ${meta.version}');
          exit(0);
        }

        // Then there must be a -1 (downgrade)
        final higherVersion = installedPackage.versions.firstWhereOrNull(
            (version) => compareVersions(meta.version!, version) == -1);

        final installAnyway = Confirm(
          prompt:
              'Are you sure you want to downgrade ${app.identifier} from $higherVersion to ${meta.version}?',
          defaultValue: false,
        ).interact();

        if (!installAnyway) {
          exit(0);
        }
      }
    }

    final packageBuilder = app.pubkeys.firstOrNull ?? app.pubkey;
    final builderNpub = packageBuilder.npub;
    final packageSigner = app.pubkey;
    final signerNpub = packageSigner.npub;

    if (!skipWot) {
      final authorRelays = container.read(relayMessageNotifierProvider(
          ['wss://relay.nostr.band', 'wss://relay.primal.net']).notifier);
      await authorRelays.initialize();

      if (!isAuthorTrusted) {
        final user = await checkUser();

        if (user['npub'] != null) {
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

          final authors = {
            ...trust.keys.map((npub) => npub.hexKey),
            packageBuilder,
            packageSigner
          };

          final users = await authorRelays.query<BaseUser>(authors: authors);

          final signerUser =
              users.firstWhereOrNull((e) => e.npub == signerNpub)!;
          final builderUser =
              users.firstWhereOrNull((e) => e.npub == builderNpub)!;

          wotSpinner.success();

          print('Package builder: ${formatProfile(builderUser)}');
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
                'Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} ${app.identifier}${isUpdatable ? ' to ${meta.version}' : ''}?',
            defaultValue: false,
          ).interact();

          if (!installPackage) {
            exit(0);
          }
        } else {
          print('Skipping web of trust check...\n');
        }
      } else {
        final users =
            await authorRelays.query<BaseUser>(authors: {packageSigner});
        print(
            'Package signed by ${formatProfile(users.first)} who was previously trusted for this app');
      }
      await authorRelays.dispose();
    }

    // On first install, check if other executables are present in PATH
    if (db[app.identifier!] == null) {
      final presentInPath = (meta.tagMap['executables'] ??
              meta.tagMap['executable'] ??
              {app.identifier!})
          .map((e) {
        final p = whichSync(path.basename(e));
        return p != null ? path.basename(e) : null;
      }).nonNulls;

      final installAnyway = Confirm(
        prompt:
            'The executables $presentInPath already exist in PATH, likely from another package manager. Would you like to continue installation?',
        defaultValue: true,
      ).interact();
      if (!installAnyway) {
        exit(0);
      }
    }

    final installSpinner = CliSpin(
      text: 'Installing package ${app.identifier}...',
      spinner: CliSpinners.dots,
    ).start();

    final package = db[app.identifier] ??
        Package(
            identifier: app.identifier!,
            pubkey: meta.pubkey,
            versions: {meta.version!},
            enabledVersion: meta.version!);

    await package.installFromUrl(meta, spinner: installSpinner);

    installSpinner
        .success('Installed package ${app.identifier!.bold()}@${meta.version}');
  } catch (e) {
    rethrow;
  } finally {
    await relay?.dispose();
    container.dispose();
  }
}
