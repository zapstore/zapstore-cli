import 'dart:io';

import 'package:archive/archive.dart';
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';
import 'package:zapstore_cli/parser/signatures.dart';
import 'package:zapstore_cli/utils.dart';

Future<FileMetadata> parseApk(String apkPath) async {
  final apkFile = File(apkPath);
  final apkBytes = apkFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(apkBytes);

  var architectures = {'arm64-v8a'};
  try {
    architectures = archive.files
        .where((a) => a.name.startsWith('lib/'))
        .map((a) => a.name.split('/')[1])
        .toSet();
  } catch (_) {
    // If expected format is not there assume default
  }

  final signatureHashes = await getSignatures(archive);
  if (signatureHashes.isEmpty) {
    throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $apkPath';
  }

  final binaryManifestFile =
      archive.firstWhere((a) => a.name == 'AndroidManifest.xml');
  final rawAndroidManifest = AxmlParser.toXml(binaryManifestFile.content);
  final manifestDocument = parseHtmlDocument(rawAndroidManifest);

  final identifier =
      manifestDocument.querySelector('manifest')!.attributes['package'];

  final manifest = manifestDocument.querySelector('manifest')!;
  final version = manifest.attributes['android:versionName'];
  final versionCode = manifest.attributes['android:versionCode'];

  final usesSdk = manifest.querySelector('uses-sdk')!;
  final minSdkVersion = usesSdk.attributes['android:minSdkVersion'];
  final targetSdkVersion = usesSdk.attributes['android:targetSdkVersion'];

  return FileMetadata(
    content: '$identifier@$version',
    version: version,
    platforms: architectures.map((a) => 'android-$a').toSet(),
    mimeType: kAndroidMimeType,
    additionalEventTags: {
      ('version_code', versionCode),
      ('min_sdk_version', minSdkVersion),
      ('target_sdk_version', targetSdkVersion),
      for (final signatureHash in signatureHashes)
        ('apk_signature_hash', signatureHash),
    },
  );
}
