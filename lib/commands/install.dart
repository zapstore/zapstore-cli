import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:intl/intl.dart';
import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/publish/events.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

Future<void> install(String value,
    {bool skipWot = false, App? fromDiscover}) async {
  final db = await Package.loadAll();

  App app;

  final spinner = CliSpin(
    text: fromDiscover == null ? 'Searching for $value...' : 'Loading...',
    spinner: CliSpinners.dots,
  ).start();

  if (fromDiscover != null) {
    app = fromDiscover;
  } else {
    final apps = await storage
        .fetch<App>(RequestFilter(remote: true, search: value, tags: {
      '#f': {hostPlatform}
    }));

    if (apps.isEmpty) {
      spinner.fail('No packages found for $value');
      throw GracefullyAbortSignal();
    }

    app = apps.first;

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
  }

  final releases =
      await storage.fetch(app.latestRelease.req!.copyWith(remote: true));

  if (releases.isEmpty) {
    spinner.fail('No releases found');
    throw GracefullyAbortSignal();
  }

  final fileMetadatas = await storage.fetch<FileMetadata>(RequestFilter(
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

  final metadata = fileMetadatas[0];

  final date = DateFormat('EEE, MMM d, yyyy').format(metadata.createdAt);
  spinner.success(
      '''Found ${app.identifier}@${metadata.version.bold()} (released $date)
  ${(app.summary ?? app.description).parseEmojis()}
''');

  final installedPackage = db[app.identifier];

  var isUpdatable = false;
  var isAuthorTrusted = false;

  if (installedPackage != null) {
    if (installedPackage.version == metadata.version) {
      spinner.success(
          'Package ${app.identifier} is already up to date (version ${installedPackage.version.bold()})');
      throw GracefullyAbortSignal();
    }

    isAuthorTrusted = installedPackage.pubkey == metadata.event.pubkey;

    isUpdatable = canUpgrade(installedPackage.version, metadata.version);

    if (!isUpdatable) {
      // Then it must be a downgrade
      final installAnyway = Confirm(
        prompt:
            'Are you sure you want to downgrade ${app.identifier} from ${installedPackage.version} to ${metadata.version}?',
        defaultValue: false,
      ).interact();

      if (!installAnyway) {
        exit(0);
      }
    }
  }

  final signerPubkey = app.event.pubkey;

  if (!skipWot) {
    if (!isAuthorTrusted) {
      final wotSpinner = CliSpin(
        text: 'Checking web of trust...',
        spinner: CliSpinners.dots,
      ).start();

      final signer = signerFromString(env['SIGN_WITH']!);
      await signer.initialize();
      final pubkey = await signer.getPublicKey();
      final partialRequest =
          PartialVerifyReputationRequest(source: pubkey, target: signerPubkey);
      final signedRequest = await partialRequest.signWith(signer);
      await signer.dispose();

      final response = await signedRequest.run('vertex');

      if (response is DVMError?) {
        if (response?.status?.contains('credits') ?? false) {
          throw 'Unable to check followers';
        }
        throw response?.status ?? 'Error';
      }

      final pubkeys = (response as VerifyReputationResponse).pubkeys;

      final authors = {...pubkeys, signerPubkey};

      final users = await storage.fetch<Profile>(
          RequestFilter(authors: authors, remote: true, relayGroup: 'vertex'));

      final signerUser =
          users.firstWhereOrNull((e) => e.pubkey == signerPubkey)!;

      wotSpinner.success();

      print('Package signer: ${formatProfile(signerUser)}\n');

      print('Relevant profiles who follow ${signerUser.name!.bold()}:');
      for (final k in pubkeys) {
        if (k != signerPubkey) {
          print(' - ${formatProfile(users.firstWhere((e) => e.pubkey == k))}');
        }
      }
      print('');

      final installPackage = Confirm(
        prompt:
            'Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} ${app.identifier}${isUpdatable ? ' to ${metadata.version}' : ''}?',
        defaultValue: false,
      ).interact();

      if (!installPackage) {
        exit(0);
      }
    } else {
      final users = await storage.query<Profile>(RequestFilter(
          authors: {signerPubkey}, remote: true, relayGroup: 'vertex'));
      print(
          'Package signed by ${formatProfile(users.first)} who was previously trusted for this app');
    }
  }

  final installSpinner = CliSpin(
    text: 'Installing package ${app.identifier}...',
    spinner: CliSpinners.dots,
  ).start();

  final package = db[app.identifier] ??
      Package(
          identifier: app.identifier,
          pubkey: metadata.event.pubkey,
          version: metadata.version);

  await package.installRemote(metadata, spinner: installSpinner);

  installSpinner.success(
      'Installed package ${app.identifier.bold()}@${metadata.version}');
}
