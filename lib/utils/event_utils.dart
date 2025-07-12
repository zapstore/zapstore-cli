import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

String formatProfile(Profile? profile, {bool url = true}) {
  if (profile == null) {
    return '(Could not load user)';
  }
  final name = profile.name ?? '';
  return '${name.toString().bold()}${(profile.nip05 == null) ? '' : ' (${profile.nip05})'}${url ? ' - https://npub.world/${profile.npub}' : ''}';
}

Future<void> checkVersionOnRelays(String identifier, String version,
    {int? versionCode}) async {
  final releases = await storage.query(RequestFilter<Release>(
    tags: {
      '#d': {'$identifier@$version'}
    },
    limit: 1,
  ).toRequest());

  if (releases.isEmpty) return;

  // Android specific: Query to ensure version code is older than current
  if (versionCode != null &&
      (releases.first.fileMetadatas.req?.filters.isNotEmpty ?? false)) {
    final req = releases.first.fileMetadatas.req!.filters.first.copyWith(tags: {
      'm': {kAndroidMimeType}
    }).toRequest();
    final fileMetadatas = await storage.query(req);
    if (fileMetadatas.isNotEmpty) {
      final maxVersionCode = fileMetadatas.fold(0,
          (acc, e) => acc > (e.versionCode ?? 0) ? acc : (e.versionCode ?? 0));
      if (maxVersionCode >= versionCode) {
        exitWithVersionCodeWarning(maxVersionCode, versionCode);
      }
      return;
    }
  }

  if (canUpgrade(releases.first.version, version)) return;

  exitWithWarning(releases.first.version, version);
}

// Early check just with assetUrl to prevent downloads & processing
Future<void> checkUrl(String assetUrl, String version,
    {DateTime? publishedAt}) async {
  final assets = await storage.query(RequestFilter<FileMetadata>(
    search: assetUrl,
    limit: 1,
  ).toRequest());

  final matchingAssets = assets.where((r) {
    return r.urls.any((u) => u == assetUrl);
  });

  if (matchingAssets.isNotEmpty) {
    // Figure out if current publishing timestamp is more recent
    if (publishedAt != null) {
      final maxExistingPublishedAt = matchingAssets.fold(
          0,
          (acc, e) =>
              acc > e.createdAt.toSeconds() ? acc : e.createdAt.toSeconds());
      if (maxExistingPublishedAt < publishedAt.toSeconds()) {
        // Do not exit with warning, continue processing
        // and set overwriteRelease to skip next check
        overwriteRelease = true;
        return;
      }
    }
    exitWithWarning(matchingAssets.first.version, version);
  }
}

void exitWithWarning(String v1, String v2) {
  final msg =
      '⚠️  Release version ${v1.bold()} is on relays and you want to publish ${v2.bold()}. Use --overwrite-release to skip this check.';
  if (isDaemonMode) {
    print(msg);
  }
  stderr.writeln(msg);
  throw GracefullyAbortSignal();
}

void exitWithVersionCodeWarning(int v1, int v2) {
  stderr.writeln(
      '⚠️  Android version code ${v1.toString().bold()} is on relays and you want to publish ${v2.toString().bold()}. Use --overwrite-release to skip this check.');
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
