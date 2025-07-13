import 'dart:io';

import 'package:apk_parser/apktool_dart.dart';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:process_run/process_run.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

Future<PartialFileMetadata?> extractMetadataFromFile(String assetHash,
    {String? resolvedIdentifier,
    bool hasVersionInConfig = false,
    String? resolvedVersion,
    Set<String>? executablePatterns}) async {
  final metadata = PartialFileMetadata();

  final assetPath = getFilePathInTempDirectory(assetHash);
  final (mimeType, internalMimeTypes, executablePaths) =
      await detectMimeTypes(assetPath, executablePatterns: executablePatterns);

  if (mimeType == kAndroidMimeType) {
    if (hasVersionInConfig) {
      throw UnsupportedError(
          'Versions are automatically extracted from APKs, remove `version` from your config file at $configPath');
    }
    final parser = ApkParser();
    final analysis =
        await parser.analyzeApk(assetPath, requiredArchitecture: 'arm64-v8a');

    if (analysis == null) {
      return null;
    }

    metadata.platforms =
        analysis.architectures.map((a) => 'android-$a').toSet();

    try {
      metadata.apkSignatureHash = analysis.certificateHashes.first;
    } catch (e) {
      // Try with apksigner (if in path)
      final sigHash = await getSignatureHashFromApkSigner(assetPath);
      if (sigHash != null) {
        metadata.apkSignatureHash = sigHash;
      } else {
        throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $assetPath';
      }
    }

    metadata.version = analysis.versionName;
    metadata.versionCode = int.tryParse(analysis.versionCode);
    metadata.minSdkVersion = analysis.minSdkVersion;
    metadata.targetSdkVersion = analysis.targetSdkVersion;
    metadata.appIdentifier = analysis.package;
    metadata.mimeType = kAndroidMimeType;

    // Add app-level data to transient
    metadata.transientData['iconBase64'] = analysis.iconBase64;
    metadata.transientData['appName'] = analysis.appName;
    metadata.transientData['filename'] = hashPathMap.containsKey(assetHash)
        ? path.basename(hashPathMap[assetHash]!)
        : null;
  } else {
    // CLI
    if (resolvedVersion == null) {
      throw 'Missing version. Did you add it to your config?';
    }
    metadata.version = resolvedVersion;
    metadata.appIdentifier = resolvedIdentifier;

    metadata.platforms = {
      for (final type in [mimeType, ...?internalMimeTypes])
        switch (type) {
          kMacOSArm64 => 'darwin-arm64',
          kLinuxArm64 => 'linux-aarch64',
          kLinuxAmd64 => 'linux-x86_64',
          _ => null,
        }
    }.nonNulls.toSet();

    // Rewrite proper mime types for Linux and Mac
    if ([kLinuxAmd64, kLinuxArm64].contains(mimeType)) {
      metadata.mimeType = kLinux;
    }
    if (mimeType == kMacOSArm64) {
      metadata.mimeType = kMacOS;
    }

    if (executablePaths != null) {
      metadata.executables = executablePaths;
    }
  }

  // Default mime type
  metadata.mimeType ??= mimeType ?? 'application/octet-stream';

  if (!_validatePlatforms(metadata, hashPathMap[assetHash] ?? '')) {
    return null;
  }

  metadata.hash = assetHash;
  metadata.size = await File(getFilePathInTempDirectory(assetHash)).length();

  return metadata;
}

bool _validatePlatforms(PartialFileMetadata metadata, String assetPath) {
  if (metadata.mimeType == kAndroidMimeType) {
    if (!metadata.platforms.contains('android-arm64-v8a')) {
      return false;
    }
  } else if (!metadata.platforms
      .every((platform) => kZapstoreSupportedPlatforms.contains(platform))) {
    return false;
  }
  return true;
}

Future<String?> getSignatureHashFromApkSigner(String apkPath) async {
  var apkSignerPath = await which('apksigner');

  if (apkSignerPath == null && env['ANDROID_SDK_ROOT'] != null) {
    final dir = Directory(env['ANDROID_SDK_ROOT']!);

    final files = await dir.list(recursive: true).toList();
    for (final file in files) {
      if (file is File && path.basename(file.path) == 'apksigner') {
        apkSignerPath = file.path;
        break;
      }
    }
  } else {
    throw 'Missing apksigner';
  }

  final result = await run('$apkSignerPath verify --print-certs $apkPath',
      runInShell: true, verbose: false);
  return result.outText
      .split('\n')
      .where((l) => l.contains('SHA-256'))
      .map((l) => l.split('digest: ').lastOrNull?.trim())
      .firstOrNull;
}
