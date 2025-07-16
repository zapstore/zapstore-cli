import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

Future<App?> getAppFromRelay(String identifier) async {
  final apps = await storage.query(
    RequestFilter<App>(
      tags: {
        '#d': {identifier},
      },
    ).toRequest(),
    source: RemoteSource(),
  );
  return apps.firstOrNull;
}

Future<void> checkVersionOnRelays(
  String identifier,
  String version, {
  int? versionCode,
}) async {
  final releases = await storage.query(
    RequestFilter<Release>(
      tags: {
        '#d': {'$identifier@$version'},
      },
      limit: 1,
    ).toRequest(),
    source: RemoteSource(),
  );

  if (releases.isEmpty) return;

  // Android specific: Query to ensure version code is older than current
  if (versionCode != null &&
      (releases.first.fileMetadatas.req?.filters.isNotEmpty ?? false)) {
    final req = releases.first.fileMetadatas.req!.filters.first
        .copyWith(
          tags: {
            'm': {kAndroidMimeType},
          },
        )
        .toRequest();

    final fileMetadatas = await storage.query(req, source: RemoteSource());
    if (fileMetadatas.isNotEmpty) {
      final maxVersionCode = fileMetadatas.fold(
        0,
        (acc, e) => acc > (e.versionCode ?? 0) ? acc : (e.versionCode ?? 0),
      );
      if (maxVersionCode >= versionCode) {
        exitWithVersionCodeWarning(
          releases.first.appIdentifier,
          maxVersionCode,
          versionCode,
        );
      }
      return;
    }
  }

  if (canUpgrade(releases.first.version, version)) return;

  exitWithWarning(
    releases.first.appIdentifier,
    releases.first.version,
    version,
  );
}

// Early check just with assetUrl to prevent downloads & processing
Future<void> checkUrl(
  String releaseUrl,
  String releaseVersion, {
  DateTime? publishedAt,
}) async {
  // TODO: If any relay does not have the latest release, publish to it now
  final releases = await storage.query(
    RequestFilter<Release>(
      tags: {
        '#r': {releaseUrl},
      },
      limit: 1,
    ).toRequest(),
    source: RemoteSource(),
  );

  // Remove millisecond precision that nostr does not have,
  // and default to zero
  publishedAt = publishedAt?.copyWith(millisecond: 0) ?? DateTime.utc(0);

  if (releases.isNotEmpty) {
    // Figure out if current publishing date is more recent
    if (releases.first.createdAt.isBefore(publishedAt)) {
      // Do not exit with warning, continue processing
      // and set overwriteRelease to skip next check
      overwriteRelease = true;
      return;
    }

    exitWithWarning(
      releases.first.appIdentifier,
      releases.first.version,
      releaseVersion,
    );
  } else {
    // If not found, continue processing but trigger a next check
    overwriteRelease = false;
  }
}

String formatProfile(Profile? profile, {bool url = true}) {
  if (profile == null) {
    return '(Could not load user)';
  }
  final name = profile.name ?? '';
  return '${name.toString().bold()}${(profile.nip05 == null) ? '' : ' (${profile.nip05})'}${url ? ' - https://npub.world/${profile.npub}' : ''}';
}

void exitWithWarning(String identifier, String v1, String v2) {
  if (!isIndexerMode) {
    final msg =
        '⚠️  ${identifier.bold()}: Release version ${v1.bold()} is on relays and you want to publish ${v2.bold()}. Use --overwrite-release to skip this check.';
    stderr.writeln(msg);
  } else {
    print(
      '${DateTime.now().timestamp}: $identifier: release $v2 already in relay',
    );
  }
  throw GracefullyAbortSignal();
}

void exitWithVersionCodeWarning(String identifier, int v1, int v2) {
  if (!isIndexerMode) {
    final msg =
        '⚠️  ${identifier.bold()}: Android version code ${v1.toString().bold()} is on relays and you want to publish ${v2.toString().bold()}. Use --overwrite-release to skip this check.';
    stderr.writeln(msg);
  } else {
    print(
      '${DateTime.now().timestamp}: $identifier: release $v2 (version code) already in relay',
    );
  }
  throw GracefullyAbortSignal();
}

void printJsonEncodeColored(Object obj) {
  final prettyJson = JsonEncoder.withIndent('  ').convert(obj);
  final separator = '": ';
  prettyJson.split('\n').forEach((line) {
    if (line.contains(separator)) {
      final [prop, ...rest] = line.split(separator);
      stderr.writeln('${prop.green()}$separator${rest.join(separator).cyan()}');
    } else {
      stderr.writeln(line.cyan());
    }
  });
}
