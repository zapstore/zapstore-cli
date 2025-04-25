import 'package:meta/meta.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';
import 'package:zapstore_cli/parser/signatures.dart';

abstract class ArtifactParser {
  App app = App();
  Release? release = Release();
  final fileMetadatas = <FileMetadata>{};

  final Map appMap;
  final SupportedOS os;

  ArtifactParser(this.appMap, this.os);

  Future<void> initialize() async {
    if (os == SupportedOS.cli && !appMap.containsKey('artifacts')) {
      throw 'CLI apps must contain artifacts in YAML config file';
    }
  }

  /// Downloads (if necessary) and applies data in files,
  /// including APK data in the case of Android
  @mustCallSuper
  Future<void> applyMetadata() async {
    // TODO: Once we have the version (here?), do release.content ??= '${app.name} $version'

    for (final artifactPath in appMap['artifacts'].keys) {
      if (!await File(artifactPath).exists()) {
        throw 'No artifact file found at $artifactPath';
      }

      switch (os) {
        case SupportedOS.android:
          final filem = await parseFile(artifactPath);
          print(filem);
          fileMetadatas.add(filem);
        case SupportedOS.cli:
          fileMetadatas.add(await parseFile(artifactPath));
      }
    }

    // Check versions okay
    final versionsFromMetadata =
        fileMetadatas.map((m) => m.content).nonNulls.toSet();
    final hasOneVersionFromMetadata = versionsFromMetadata.length == 1;
    if (!hasOneVersionFromMetadata) {
      throw 'All file metadatas MUST coincide in identifier and version: Has $versionsFromMetadata';
    }
    // Overwrite identifier/version with ones from APK

    // TODO: If release is absent, skip to next
    // if (release == null) {
    //   print('No release, nothing to do');
    //   throw GracefullyAbortSignal();
    // }
    final [identifier, version] = fileMetadatas.first.content.split('@');
    app = App(
      identifier: identifier,
      content: appMap['description'] ?? appMap['summary'],
      name: appMap['name'],
      summary: appMap['summary'],
      repository: sourceRepository,
      icons: {
        if (appMap['icon'] != null) ...await processImages(appMap['icon'])
      },
      images: await processImages(appMap['images'] ?? []),
      license: appMap['license'],
      pubkeys: {if (developerPubkey != null) developerPubkey!},
    );

    release = Release(
      createdAt: fileMetadatas.first.createdAt,
      content: releaseNotes,
      identifier: fileMetadatas.first.content,
      pubkeys: app.pubkeys,
    );
  }

  /// Fetches from Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    // TODO: Restore
    print('Would you like to pull extra metadata for this app?');
    // if (os == SupportedOS.android) {
    //   var extraMetadata = 0;
    //   CliSpin? extraMetadataSpinner;

    //   if (!isDaemonMode) {
    //     extraMetadata = Select(
    //       prompt: 'Would you like to pull extra metadata for this app?',
    //       options: ['Play Store', 'F-Droid', 'None'],
    //     ).interact();

    //     extraMetadataSpinner = CliSpin(
    //       text: 'Fetching extra metadata...',
    //       spinner: CliSpinners.dots,
    //     ).start();
    //   }

    //   if (extraMetadata == 0) {
    //     final playStoreParser = PlayStoreParser();
    //     app = await playStoreParser.run(
    //       app: app,
    //       originalName: appMap['name'],
    //       spinner: extraMetadataSpinner,
    //     );
    //   } else if (extraMetadata == 1) {
    //     extraMetadataSpinner?.fail('F-Droid is not yet supported, sorry');
    //   }
    // }
  }

  // Helpers

  String? get developerPubkey => (appMap['developer']?.toString())?.hexKey;
  String? get sourceRepository => appMap['repository'];
  String? get releaseRepository => appMap['release_repository'];

  Future<FileMetadata> parseFile(String artifactPath) async {
    Set<String>? platforms;
    Set<String>? signatureHashes;
    String? identifier;
    String? version;
    String? versionCode;
    String? minSdkVersion;
    String? targetSdkVersion;

    if (os == SupportedOS.android) {
      final apkFile = File(artifactPath);
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

      platforms = architectures.map((a) => 'android-$a').toSet();
      if (appMap['artifacts'].isEmpty) {
        appMap['artifacts'] = {
          artifactPath: {'platforms': platforms}
        };
      }

      signatureHashes = await getSignatures(archive);
      if (signatureHashes.isEmpty) {
        throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $artifactPath';
      }

      final binaryManifestFile =
          archive.firstWhere((a) => a.name == 'AndroidManifest.xml');
      final rawAndroidManifest = AxmlParser.toXml(binaryManifestFile.content);
      final manifestDocument = parseHtmlDocument(rawAndroidManifest);

      identifier =
          manifestDocument.querySelector('manifest')!.attributes['package'];

      final manifest = manifestDocument.querySelector('manifest')!;
      version = manifest.attributes['android:versionName'];
      versionCode = manifest.attributes['android:versionCode'];

      final usesSdk = manifest.querySelector('uses-sdk')!;
      minSdkVersion = usesSdk.attributes['android:minSdkVersion'];
      targetSdkVersion = usesSdk.attributes['android:targetSdkVersion'];
    }
    print('**** $identifier $version');

    // Check platforms are supported
    final artifactYaml = (appMap['artifacts'] as Map).entries.firstWhereOrNull(
        (e) => regexpFromKey(e.key).hasMatch(path.basename(artifactPath)));

    final match = artifactYaml != null
        ? regexpFromKey(artifactYaml.key).firstMatch(artifactPath)
        : null;

    platforms ??= {...?artifactYaml?.value['platforms'] as Iterable?};
    if (!platforms
        .every((platform) => kSupportedPlatforms.contains(platform))) {
      throw 'Artifact $artifactPath has platforms $platforms but some are not in $kSupportedPlatforms';
    }

    final tempArtifactPath =
        path.join(Directory.systemTemp.path, path.basename(artifactPath));
    await File(artifactPath).copy(tempArtifactPath);
    final (artifactHash, newArtifactPath, mimeType) =
        await renameToHash(tempArtifactPath);

    final artifactUrl = 'https://cdn.zapstore.dev/$artifactHash';
    final size = await File(newArtifactPath).length();

    final fm = FileMetadata(
      content: version != null ? '$identifier:$version' : null,
      createdAt: DateTime.now(),
      urls: {artifactUrl},
      mimeType: mimeType,
      hash: artifactHash,
      size: size,
      platforms: platforms.toSet().cast(),
      version: version,
      pubkeys: {developerPubkey}.nonNulls.toSet(),
      additionalEventTags: {
        for (final e in (artifactYaml?.value['executables'] ?? []))
          ('executable', replaceInExecutable(e, match)),
        ('version_code', versionCode),
        ('min_sdk_version', minSdkVersion),
        ('target_sdk_version', targetSdkVersion),
        for (final signatureHash in signatureHashes!)
          ('apk_signature_hash', signatureHash),
      },
    );
    print(fm.toMap());
    return fm;
  }
}

String replaceInExecutable(String e, RegExpMatch? match) {
  if (match == null) return e;
  for (var i = 1; i <= match.groupCount; i++) {
    e = e.replaceAll('\$$i', match.group(i)!);
  }
  return e;
}

RegExp regexpFromKey(String key) {
  // %v matches 1.0 or 1.0.1, no groups are captured
  key = key.replaceAll('%v', r'\d+\.\d+(?:\.\d+)?');
  return RegExp(key);
}
