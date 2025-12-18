import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:intl/intl.dart';
import 'package:models/models.dart';
import 'package:nip07_signer/main.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/publish/events.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/markdown.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

Future<void> install(
  String value, {
  bool skipWot = false,
  bool update = false,
  App? fromDiscover,
}) async {
  final db = await Package.loadAll();

  if (update && db[value] == null) {
    print('App $value not installed, nothing to update');
    exit(0);
  }

  App app;

  final spinner = CliSpin(
    text: fromDiscover == null ? 'Searching for $value...' : 'Loading...',
    spinner: CliSpinners.dots,
  ).start();

  if (fromDiscover != null) {
    app = fromDiscover;
  } else {
    final apps = await storage.query(
      RequestFilter<App>(
        search: value,
        tags: {
          '#f': {hostPlatform},
        },
      ).toRequest(),
      source: RemoteSource(),
    );

    if (apps.isEmpty) {
      spinner.fail('No packages found for $value');
      exit(0);
    }

    app = apps.first;

    if (apps.length > 1) {
      final packages = [
        for (final app in apps) '${app.name} [${app.identifier}]',
      ];

      final selection = Select(
        prompt: 'Which package?',
        options: packages,
      ).interact();

      app = apps[selection];
    }
  }

  final releases = await storage.query(app.latestRelease.req!);

  if (releases.isEmpty) {
    spinner.fail('No releases found');
    exit(0);
  }

  final fileMetadatas = await storage.query(
    RequestFilter<FileMetadata>(
      ids: releases.first.event.getTagSetValues('e'),
      tags: {
        '#f': {hostPlatform},
      },
    ).toRequest(),
  );

  if (fileMetadatas.isEmpty) {
    spinner.fail('No file metadatas found');
    exit(0);
  }

  final metadata = fileMetadatas[0];

  final signerPubkey = app.event.pubkey;

  final profiles = await storage.query(
    RequestFilter<Profile>(authors: {signerPubkey}).toRequest(),
    source: RemoteSource(group: 'vertex'),
  );
  final signerProfile = profiles.firstOrNull;

  final date = DateFormat('EEE, MMM d, yyyy').format(metadata.createdAt);
  spinner.success(
    '''Found ${app.identifier}@${metadata.version.bold()} (released $date)
  ${(app.summary ?? app.description).parseEmojis().gray()}
  ${'Signed by'.bold()}: ${formatProfile(signerProfile)}
''',
  );

  final installedPackage = db[app.identifier];

  var isUpdatable = false;
  var isAuthorTrusted = false;

  if (installedPackage != null) {
    if (installedPackage.version == metadata.version) {
      spinner.success(
        'Package ${app.identifier} is already up to date (version ${installedPackage.version.bold()})',
      );
      exit(0);
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
    } else {
      print(
        'Upgrading from installed version ${installedPackage.version.bold()}\n',
      );
    }
  }

  if (releases.first.releaseNotes != null) {
    final viewReleaseNotes = Confirm(
      prompt: 'See release notes for ${releases.first.version}?',
      defaultValue: true,
    ).interact();
    if (viewReleaseNotes) {
      print('\n${mdToTerminal(releases.first.releaseNotes!)}');
      if (!Confirm(prompt: 'Continue?', defaultValue: true).interact()) {
        exit(0);
      }
    }
  }

  if (!skipWot) {
    final checkSucceeded = await Future<bool>(() async {
      if (!isAuthorTrusted) {
        final wotSpinner = CliSpin(
          text: 'Checking web of trust...',
          spinner: CliSpinners.dots,
        ).start();

        late Signer signer;
        if (env['SIGN_WITH'] == null ||
            (signer = getSignerFromString(env['SIGN_WITH']!))
                is NpubFakeSigner) {
          wotSpinner.fail(
            'No signer, not possible to sign a request to the web of trust service, skipping check',
          );
          return false;
        }

        if (signer is NIP07Signer) {
          final ok =
              !stdin.hasTerminal ||
              Confirm(
                prompt:
                    'This will launch a server at localhost:17007 and open a browser window for signing with a NIP-07 extension. Okay?',
                defaultValue: true,
              ).interact();
          if (!ok) {
            wotSpinner.fail('Skipping check');
            return false;
          }
        }

        await signer.signIn();
        final pubkey = signer.pubkey;
        final partialRequest = PartialVerifyReputationRequest(
          source: pubkey,
          target: signerPubkey,
        );
        final signedRequest = await partialRequest.signWith(signer);
        await signer.signOut();

        final response = await signedRequest.run('vertex');

        if (response is DVMError?) {
          if (response?.status?.contains('credits') ?? false) {
            throw 'Unable to check followers';
          }
          throw response?.status ?? 'Error';
        }

        final pubkeys = (response as VerifyReputationResponse).pubkeys;

        final relevantProfiles = await storage.query(
          RequestFilter<Profile>(authors: pubkeys).toRequest(),
          source: RemoteSource(group: 'vertex'),
        );

        wotSpinner.success();

        print('Package signer: ${formatProfile(signerProfile)}\n');

        print('Relevant profiles who follow ${signerProfile?.name?.bold()}:');
        for (final profile in relevantProfiles) {
          print(' - ${formatProfile(profile)}');
        }
      } else {
        print(
          'Package signed by ${formatProfile(signerProfile)} who was previously trusted for this app',
        );
      }
      return true;
    });

    final installPackage = Confirm(
      prompt:
          '${!checkSucceeded ? 'Web of trust check did not succeed. ' : ''}Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} ${app.identifier}${isUpdatable ? ' to ${metadata.version}' : ''}?',
      defaultValue: false,
    ).interact();

    if (!installPackage) {
      exit(0);
    }
  }

  final installSpinner = CliSpin(
    text: 'Installing package ${app.identifier}...',
    spinner: CliSpinners.dots,
  ).start();

  final package =
      db[app.identifier] ??
      Package(
        identifier: app.identifier,
        pubkey: metadata.event.pubkey,
        version: metadata.version,
      );

  await package.installRemote(metadata, spinner: installSpinner);

  installSpinner.success(
    'Installed package ${app.identifier.bold()}@${metadata.version}',
  );
}
