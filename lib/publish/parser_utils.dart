import 'dart:io';

import 'package:archive/archive.dart';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:process_run/process_run.dart';
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/parser/signature_parser.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

Future<PartialFileMetadata?> extractMetadataFromFile(String assetHash,
    {String? resolvedIdentifier,
    String? resolvedVersion,
    Set<String>? executablePatterns}) async {
  final metadata = PartialFileMetadata();

  final assetPath = getFilePathInTempDirectory(assetHash);
  final (mimeType, internalMimeTypes, executablePaths) =
      await detectMimeTypes(assetPath, executablePatterns: executablePatterns);

  if (mimeType == kAndroidMimeType) {
    final assetBytes = await File(assetPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(assetBytes);

    final architectures = archive.files
        .where((a) => a.name.startsWith('lib/'))
        .map((a) => a.name.split('/')[1])
        .toSet();

    if (architectures.isEmpty) {
      // Set default
      architectures.add('arm64-v8a');
    }

    metadata.platforms = architectures.map((a) => 'android-$a').toSet();

    try {
      metadata.apkSignatureHashes = await getSignatureHashes(assetPath);
      if (metadata.apkSignatureHashes.isEmpty) {
        throw '';
      }
    } catch (e) {
      // Try with apksigner (if in path)
      final sigHash = await getSignatureHashFromApkSigner(assetPath);
      if (sigHash != null) {
        metadata.apkSignatureHashes = {sigHash};
      }
      throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $assetPath';
    }

    final binaryManifestFile =
        archive.firstWhere((a) => a.name == 'AndroidManifest.xml');
    final rawAndroidManifest = AxmlParser.toXml(binaryManifestFile.content);
    final manifestDocument = parseHtmlDocument(rawAndroidManifest);

    metadata.identifier =
        manifestDocument.querySelector('manifest')!.attributes['package']!;

    final manifest = manifestDocument.querySelector('manifest')!;
    metadata.version = manifest.attributes['android:versionName'];

    metadata.versionCode =
        int.tryParse(manifest.attributes['android:versionCode'] ?? '');

    final usesSdk = manifest.querySelector('uses-sdk')!;
    metadata.minSdkVersion = usesSdk.attributes['android:minSdkVersion'];
    metadata.targetSdkVersion = usesSdk.attributes['android:targetSdkVersion'];

    metadata.mimeType = kAndroidMimeType;

    // For backwards-compatibility
    metadata.event.content = '${metadata.identifier}@${metadata.version}';
  } else {
    // CLI
    metadata.identifier = resolvedIdentifier;
    metadata.version = resolvedVersion;

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
  final dir = Directory(env['ANDROID_SDK_ROOT']!);

  late final String apkSignerPath;
  final files = await dir.list(recursive: true).toList();
  for (final file in files) {
    if (file is File && path.basename(file.path) == 'apksigner') {
      apkSignerPath = file.path;
      break;
    }
  }

  final result = await run('$apkSignerPath verify --print-certs $apkPath',
      runInShell: true, verbose: false);
  return result.outText
      .split('\n')
      .where((l) => l.contains('SHA-256'))
      .map((l) => l.split('digest: ').lastOrNull?.trim())
      .firstOrNull;
}
