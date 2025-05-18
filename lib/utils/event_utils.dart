import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

String formatProfile(Profile profile) {
  final name = profile.name ?? '';
  return '${name.toString().bold()}${(profile.nip05 == null) ? '' : ' (${profile.nip05})'} - https://npub.world/${profile.npub}';
}

showInRelayWarning(String v1, String v2) {
  stderr.writeln(
      '⚠️  Release version ${v1.bold()} is on relays and you want to publish ${v2.bold()}. Use --overwrite-release to skip this check.');
  throw GracefullyAbortSignal();
}

showInRelayVersionCodeWarning(int v1, int v2) {
  stderr.writeln(
      '⚠️  Android version code ${v1.toString().bold()} is on relays and you want to publish ${v2.toString().bold()}. Use --overwrite-release to skip this check.');
  throw GracefullyAbortSignal();
}

Future<void> checkVersionOnRelays(String identifier, String version,
    {int? versionCode}) async {
  final releases = await storage.fetch<Release>(RequestFilter(
    remote: true,
    tags: {
      '#d': {'$identifier@$version'}
    },
    limit: 1,
  ));

  if (releases.isEmpty) return;

  if (versionCode != null) {
    // Query for Android metadatas to ensure version code is older than current
    final req = releases.first.fileMetadatas.req!.copyWith(tags: {
      'm': {kAndroidMimeType}
    });
    final fileMetadatas = await storage.fetch(req);
    if (fileMetadatas.isNotEmpty) {
      final maxVersionCode = fileMetadatas.fold(0,
          (acc, e) => acc > (e.versionCode ?? 0) ? acc : (e.versionCode ?? 0));
      if (maxVersionCode >= versionCode) {
        showInRelayVersionCodeWarning(maxVersionCode, versionCode);
      }
      return;
    }
  }

  if (canUpgrade(releases.first.version, version)) return;

  if (isDaemonMode) {
    print('  $version OK, skipping');
  } else {
    showInRelayWarning(releases.first.version, version);
  }
}

// Early check just with assetUrl to prevent downloads & processing
Future<void> checkFuzzyEarly(String assetUrl, String version) async {
  final assets = await storage.fetch<FileMetadata>(RequestFilter(
    remote: true,
    search: assetUrl,
    limit: 1,
  ));

  print('got assets ${assets.length}');

  final matchingAssets = assets.where((r) {
    return r.urls.any((u) => u == assetUrl);
  });

  if (matchingAssets.isNotEmpty) {
    showInRelayWarning(matchingAssets.first.version, version);
  }
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
