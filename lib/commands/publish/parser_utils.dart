import 'dart:io';

import 'package:archive/archive.dart';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/parser/signatures.dart';
import 'package:zapstore_cli/utils.dart';

Future<(PartialFileMetadata, Set<PartialBlossomAuthorization>)>
    extractMetadataFromFile(
        String assetHash, Set<String> blossomServers) async {
  final metadata = PartialFileMetadata();

  String? identifier;

  final assetPath = getFilePathInTempDirectory(assetHash);
  final fileType = await detectFileType(assetPath);

  if (fileType == kAndroidMimeType) {
    final archive = await getArchive(assetPath, fileType!);

    var architectures = {'arm64-v8a'};
    try {
      architectures = archive.files
          .where((a) => a.name.startsWith('lib/'))
          .map((a) => a.name.split('/')[1])
          .toSet();
    } catch (_) {
      // If expected format is not there assume default
    }

    metadata.platforms = architectures.map((a) => 'android-$a').toSet();

    metadata.apkSignatureHashes = await getSignatureHashes(assetPath);
    if (metadata.apkSignatureHashes.isEmpty) {
      throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $assetPath';
    }

    final binaryManifestFile =
        archive.firstWhere((a) => a.name == 'AndroidManifest.xml');
    final rawAndroidManifest = AxmlParser.toXml(binaryManifestFile.content);
    final manifestDocument = parseHtmlDocument(rawAndroidManifest);

    identifier =
        manifestDocument.querySelector('manifest')!.attributes['package']!;

    final manifest = manifestDocument.querySelector('manifest')!;
    metadata.version = manifest.attributes['android:versionName'];

    metadata.versionCode = manifest.attributes['android:versionCode'];

    final usesSdk = manifest.querySelector('uses-sdk')!;
    metadata.minSdkVersion = usesSdk.attributes['android:minSdkVersion'];
    metadata.targetSdkVersion = usesSdk.attributes['android:targetSdkVersion'];

    metadata.mimeType = kAndroidMimeType;
    metadata.identifier = identifier;

    // For backwards-compatibility
    metadata.event.content = '${metadata.identifier}@${metadata.version}';
  } else {
    // CLI

    // Regular executable
    metadata.mimeType = fileType;

    // TODO: Check platforms
    metadata.platforms = {
      switch (fileType) {
        'application/x-mach-binary-arm64' => 'darwin-arm64',
        'application/x-elf-aarch64' => 'linux-aarch64',
        'application/x-elf-amd64' => 'linux-x86_64',
        _ => throw UnsupportedError('Bad platform: $fileType')
      }
    };
  }

  // Default mime type, we query by platform anyway
  metadata.mimeType ??= 'application/octet-stream';

  _validatePlatforms(metadata, hashPathMap[assetHash] ?? '');

  // TODO: Add executables - do we actually need this or we get multiple 1063s?
  // See in relay what current phoenixd has
  // final executables = assetEntry?.value?['executables'] ?? [];

  metadata.hash = assetHash;
  metadata.size = await File(getFilePathInTempDirectory(assetHash)).length();

  // Place first the original URL and leave Blossom servers as backup
  if (hashUrlMap.containsKey(assetHash)) {
    metadata.event.addTagValue('url', hashUrlMap[assetHash]);
  }
  for (final server in blossomServers) {
    metadata.event.addTagValue('url', path.join(server, assetHash));
  }

  final auth = {
    PartialBlossomAuthorization()
      // content should be the name of the original file
      ..content = 'Upload ${path.basename(assetPath)}'
      ..type = BlossomAuthorizationType.upload
      ..mimeType = metadata.mimeType!
      ..expiration = DateTime.now().add(Duration(days: 1))
      ..addHash(assetHash)
  };
  return (metadata, auth);
}

Future<Archive> getArchive(String assetPath, String fileType) async {
  final bytes = await File(assetPath).readAsBytes();
  return switch (fileType) {
    'application/gzip' =>
      TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes)),
    'application/zip' || kAndroidMimeType => ZipDecoder().decodeBytes(bytes),
    _ => throw UnsupportedError('')
  };
}

void _validatePlatforms(PartialFileMetadata metadata, String assetPath) {
  if (metadata.mimeType == kAndroidMimeType) {
    if (!metadata.platforms.contains('android-arm64-v8a')) {
      throw UnsupportedError(
          'APK $assetPath does not support arm64-v8a: ${metadata.platforms}');
    }
  } else if (!metadata.platforms
      .every((platform) => kZapstoreSupportedPlatforms.contains(platform))) {
    throw UnsupportedError(
        'asset has platforms ${metadata.platforms} but some are not in $kZapstoreSupportedPlatforms');
  }
}
