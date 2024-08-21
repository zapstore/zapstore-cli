import 'package:cli_spin/cli_spin.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils.dart';

Future<FileMetadata> parseApk(App app, FileMetadata fileMetadata) async {
  final apkSpinner = CliSpin(
    text: 'Parsing APK...',
    spinner: CliSpinners.dots,
  ).start();
  final apkPath = fileMetadata.transientData['apkPath'];
  final apkFolder = path.setExtension(apkPath, '');

  await runInShell('rm -fr $apkFolder');
  await runInShell('apktool decode -s -f -o $apkFolder $apkPath');

  var architectures = ['arm64-v8a'];
  try {
    final archs = await runInShell('ls $apkFolder/lib');
    architectures = archs.trim().split('\n');
  } catch (_) {
    // if lib/ is not present, leave default and do nothing else
  }

  // TODO: Which apksigner
  final rawSignatureHashes = await runInShell(
      'apksigner verify --print-certs $apkPath | grep SHA-256');
  final signatureHashes = [
    for (final sh in rawSignatureHashes.trim().split('\n'))
      sh.split(':').lastOrNull?.trim()
  ].nonNulls;

  final appIdentifier = await runInShell(
      "cat $apkFolder/AndroidManifest.xml | xq -q 'manifest' -a 'package'");
  if (appIdentifier != app.identifier) {
    throw 'Identifier mismatch: $appIdentifier != ${app.identifier}';
  }

  final apkToolYaml = await runInShell("cat $apkFolder/apktool.yml | sed '1d'");
  final yamlData = Map<String, dynamic>.from(loadYaml(apkToolYaml));

  final apkVersion = yamlData['versionInfo']?['versionName'];
  final apkVersionCode = yamlData['versionInfo']?['versionCode'];

  final minSdkVersion = yamlData['sdkInfo']?['minSdkVersion'];
  final targetSdkVersion = yamlData['sdkInfo']?['targetSdkVersion'];

  // TODO: Prevent XML image shit
  // TODO: Check appIcon, convert svg to png

  try {
    final iconPointer = await runInShell(
        "cat $apkFolder/AndroidManifest.xml | xq -q 'manifest application' -a 'android:icon'");
    if (iconPointer.startsWith('@mipmap')) {
      // final mipmapFolders = await runInShell("ls $apkFolder/res | grep mipmap");
      // final bestMipmapFolder = selectBestString(mipmapFolders.trim().split('\n'), [
      //   [/xxxhdpi/, 5],
      //   [/xxhdpi/, 4],
      //   [/xhdpi/, 3],
      //   [/hdpi/, 2],
      //   [/mdpi/, 1],
      // ]);
      // final iconBasename = iconPointer.replaceAll('@mipmap/', '').trim();
      // final iconFolder = path.join(apkFolder, 'res', 'xxxhdpi');
      // final iconName = await runInShell('ls $iconFolder/$iconBasename.*');
      // iconPath = join(iconFolder, _iconName.trim());
    }
  } catch (e) {
    // ignore
  }

  // final [_, iconHashName] = iconPath ? await renameToHash(iconPath) : [undefined, undefined];

  await runInShell('rm -fr $apkFolder');

  apkSpinner.success('Parsed APK');

  return fileMetadata.copyWith(
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
}
