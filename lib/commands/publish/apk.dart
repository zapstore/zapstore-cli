import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:html/parser.dart';
import 'package:process_run/process_run.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils.dart';

Future<(App, Release, FileMetadata)> parseApk(
    App app, Release release, FileMetadata fileMetadata) async {
  final apkSpinner = CliSpin(
    text: 'Parsing APK...',
    spinner: CliSpinners.dots,
  ).start();
  final apkPath = fileMetadata.transientData['apkPath'];
  final apkFolder = path.setExtension(apkPath, '');

  await runInShell('rm -fr $apkFolder');
  if (whichSync('apktool') == null) {
    throw 'APK parsing requires apktool and it could not be found.\n\nTo install run ${'zapstore install apktool'.bold()}';
  }
  await runInShell('apktool decode -s -f -o $apkFolder $apkPath');

  var architectures = ['arm64-v8a'];
  try {
    final archs = await runInShell('ls $apkFolder/lib');
    architectures = archs.trim().split('\n');
  } catch (_) {
    // if lib/ is not present, leave default and do nothing else
  }

  var apksignerPath = Platform.environment['APKSIGNER_PATH'];
  if (whichSync('apksigner') == null && apksignerPath == null) {
    throw 'APK parsing requires apksigner (from Android Tools) and it could not be found.\n\nIt is likely installed in your system, find it and re-run specifying the full path:\n\n${'APKSIGNER_PATH=/path/to/apksigner zapstore publish myapp'.bold()}';
  }
  apksignerPath ??= 'apksigner';

  final rawSignatureHashes = await runInShell(
      '$apksignerPath verify --print-certs $apkPath | grep SHA-256');
  final signatureHashes = [
    for (final sh in rawSignatureHashes.trim().split('\n'))
      sh.split(':').lastOrNull?.trim()
  ].nonNulls;

  final rawAndroidManifest =
      await File(path.join(apkFolder, 'AndroidManifest.xml')).readAsString();
  final androidManifest = parse(rawAndroidManifest);

  final appIdentifier =
      androidManifest.querySelector('manifest')!.attributes['package'];
  app = app.copyWith(identifier: appIdentifier);
  release = release.copyWith(
      identifier: '$appIdentifier@${release.identifier!.split('@').last}');

  final rawApktoolYaml =
      await File(path.join(apkFolder, 'apktool.yml')).readAsString();
  final yamlData = Map<String, dynamic>.from(loadYaml(rawApktoolYaml));

  final apkVersion = yamlData['versionInfo']?['versionName']?.toString();
  final apkVersionCode = yamlData['versionInfo']?['versionCode']?.toString();

  final minSdkVersion = yamlData['sdkInfo']?['minSdkVersion']?.toString();
  final targetSdkVersion = yamlData['sdkInfo']?['targetSdkVersion']?.toString();

  if (app.icons.isEmpty) {
    try {
      final iconPointer = androidManifest
          .querySelector('manifest application')
          ?.attributes['android:icon'];
      if (iconPointer != null && iconPointer.startsWith('@mipmap')) {
        Directory? iconFolder;
        for (final s in ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi']) {
          final folder = Directory(path.join(apkFolder, 'res', 'mipmap-$s'));
          if (await folder.exists()) {
            iconFolder = folder;
            break;
          }
        }

        if (iconFolder != null) {
          final iconBasename = iconPointer.replaceAll('@mipmap/', '').trim();
          final iconName =
              await runInShell('ls ${iconFolder.path}/$iconBasename.*');
          final iconPath = path.join(iconFolder.path, iconName);
          final (iconHash, newIconPath, iconMimeType) =
              await renameToHash(iconPath);
          final iconBlossomUrl =
              await uploadToBlossom(newIconPath, iconHash, iconMimeType);
          app = app.copyWith(icons: {iconBlossomUrl});
        }
      }
    } catch (e) {
      // Ignore, we'll move on without icon
    }
  }

  await runInShell('rm -fr $apkFolder');

  apkSpinner.success('Parsed APK');

  fileMetadata = fileMetadata.copyWith(
    content: '$appIdentifier ${release.identifier!.split('@').last}',
    version: apkVersion,
    platforms: architectures.map((a) => 'android-$a').toSet(),
    mimeType: 'application/vnd.android.package-archive',
    additionalEventTags: {
      ('version_code', apkVersionCode),
      ('min_sdk_version', minSdkVersion),
      ('target_sdk_version', targetSdkVersion),
      for (final signatureHash in signatureHashes)
        ('apk_signature_hash', signatureHash),
      // Keep for backward compatibility
      for (final a in architectures) ('arch', a),
    },
  );

  return (app, release, fileMetadata);
}
