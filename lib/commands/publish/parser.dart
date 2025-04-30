import 'package:meta/meta.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/parser/signatures.dart';
import 'package:zapstore_cli/utils.dart';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';

class ArtifactParser {
  final Map appMap;
  final temp = <String, dynamic>{};

  late final PartialApp app;

  ArtifactParser(this.appMap) {
    app = PartialApp();
    // TODO: Restore version replacement
    // if (appMap['version'] is String) {
    //   int i = 0;
    //   for (final artifact in appMap['artifacts'].toList()) {
    //     appMap['artifacts'][i++] =
    //         artifact.toString().replaceAll('\$version', appMap['version']!);
    //   }
    // }
  }

  Future<void> initialize() async {
    for (final artifact in appMap['artifacts']) {
      final dir = Directory(path.dirname(artifact));
      final r = RegExp(path.basename(artifact));
      final as =
          dir.listSync().where((e) => e is File && r.hasMatch(e.path)).map((e) {
        return PartialFileMetadata()..path = e.path;
      });
      app.artifacts.addAll(as);
    }
  }

  /// Downloads (if necessary) and applies data in files,
  /// including APK data in the case of Android
  @mustCallSuper
  Future<void> applyMetadata() async {
    String? identifier = appMap['identifier'];
    String? version = appMap['version'] is String ? appMap['version'] : null;

    for (final pfm in app.artifacts) {
      final fm = await parseFile(pfm);

      identifier ??= fm.identifier;
      if (identifier == null) {
        throw 'Identifier is null';
      } else if (fm.identifier != null && fm.identifier != identifier) {
        throw '${fm.identifier} != $identifier - mismatching identifiers, abort';
      }

      version ??= fm.version;
      if (version == null) {
        throw 'Version is null';
      } else if (fm.version != null && fm.version != version) {
        throw '${fm.version} != $version - mismatching versions, abort';
      }

      app.artifacts.add(fm);
    }

    app.name ??= appMap['name']?.toString().toLowerCase();
    app.identifier = identifier ?? app.name;
    app.version = version;
    print('got app ${app.identifier}@${app.version}');

    app.url ??= appMap['homepage'];
    app.tags ??= (appMap['tags'] as String?)?.trim().split(' ').toSet();

    // TODO: If release is absent, skip to next
    // if (release == null) {
    //   print('No release, nothing to do');
    //   throw GracefullyAbortSignal();
    // }
    //     if (!overwriteRelease) {
    //   await checkReleaseOnRelay(
    //     version: version,
    //     artifactUrl: artifactUrl,
    //     spinner: packageSpinner,
    //   );
    // }

    app
      ..description = appMap['description'] ?? appMap['summary']
      ..summary = appMap['summary']
      ..repository = sourceRepository
      ..license = appMap['license'];
    if (appMap['icon'] != null) {
      app.icon = (await processImages([appMap['icon']])).first;
    }
    app.images = await processImages(appMap['images'] ?? []);
  }

  /// Fetches from Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    // TODO: Restore
    print('Would you like to pull extra metadata for this app?');
    // TODO: Also offer pulling Source Code (if github) and parsing Fastlane metadata

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

  Future<PartialFileMetadata> parseFile(PartialFileMetadata metadata) async {
    final artifactPath = metadata.path!;
    String? identifier;
    String? version;

    if (!await File(artifactPath).exists()) {
      throw 'No artifact file found at $artifactPath';
    }

    print('parsing $artifactPath');

    final fileType = detectFileType(artifactPath);
    if (fileType == kAndroidMimeType) {
      final artifactBytes = await File(artifactPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(artifactBytes);

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

      metadata.signatureHashes = await getSignatures(artifactPath);
      if (metadata.signatureHashes!.isEmpty) {
        throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $artifactPath';
      }

      final binaryManifestFile =
          archive.firstWhere((a) => a.name == 'AndroidManifest.xml');
      final rawAndroidManifest = AxmlParser.toXml(binaryManifestFile.content);
      final manifestDocument = parseHtmlDocument(rawAndroidManifest);

      identifier =
          manifestDocument.querySelector('manifest')!.attributes['package']!;

      final manifest = manifestDocument.querySelector('manifest')!;
      version = manifest.attributes['android:versionName'];

      metadata.versionCode = manifest.attributes['android:versionCode'];

      final usesSdk = manifest.querySelector('uses-sdk')!;
      metadata.minSdkVersion = usesSdk.attributes['android:minSdkVersion'];
      metadata.targetSdkVersion =
          usesSdk.attributes['android:targetSdkVersion'];

      metadata.mimeType = kAndroidMimeType;
      metadata.identifier = identifier;
    } else if (fileType == 'application/gzip') {
      final z =
          GZipDecoder().decodeBytes(File(metadata.path!).readAsBytesSync());
      final archive = TarDecoder().decodeBytes(z);
      // TODO: In this way detect executables!
      // And then pass through executables regex filter from config
      final w = archive.files
          .map((f) => f.isFile && f.size > 0 ? detectFileType(f.name) : '');
      print(w);
    }

    if (fileType != null && fileType.startsWith('')) {
      metadata.platforms = {
        switch (fileType) {
          'application/x-mach-binary-arm64' => 'darwin-arm64',
          'application/x-mach-binary-amd64' => 'darwin-x86_64',
          'application/x-elf-aarch64' => 'linux-aarch64',
          'application/x-elf-amd64' => 'linux-x86_64',
          _ => ''
        }
      };
    }

    // Rename to generic mime type, in any way we query by platform
    metadata.mimeType ??= 'application/octet-stream';

    // TODO: Check platforms are supported
    // final artifactEntry = artifacts.entries.firstWhereOrNull(
    //     (e) => regexpFromKey(e.key).hasMatch(path.basename(artifactPath)));

    // final match =
    //     regexpFromKey(artifactEntry?.key ?? '').firstMatch(artifactPath);

    // platforms ??= {...?artifactEntry?.value?['platforms'] as Iterable?};
    // if (!platforms
    //     .every((platform) => kSupportedPlatforms.contains(platform))) {
    //   throw 'Artifact $artifactPath has platforms $platforms but some are not in $kSupportedPlatforms';
    // }

    // TODO: Add executables
    // final executables = artifactEntry?.value?['executables'] ?? [];

    final tempArtifactPath =
        path.join(Directory.systemTemp.path, path.basename(artifactPath));
    await File(artifactPath).copy(tempArtifactPath);
    final (artifactHash, newArtifactPath, mimeType) =
        await renameToHash(tempArtifactPath);

    metadata.hash = artifactHash;
    metadata.url = 'https://cdn.zapstore.dev/$artifactHash';
    metadata.size = await File(newArtifactPath).length();

    metadata.version = version ?? appMap['version'];

    return metadata;
  }

  (App, Release, Set<FileMetadata>) get events {
    final fApp = App(
      content: app.description,
      summary: app.summary,
      identifier: app.identifier,
      icons: {app.icon}.nonNulls.toSet(),
      images: app.images,
      createdAt: DateTime.now(),
      license: app.license,
      platforms: app.artifacts
          .map((a) => a.platforms)
          .nonNulls
          .expand((e) => e)
          .toSet(),
      repository: app.repository,
      name: app.name,
      url: app.url,
      tags: app.tags,
    );

    final fFileMetadatas = app.artifacts.map((a) {
      return FileMetadata(
        // Use app's identifier/version
        content: '${app.identifier}@${app.version}',
        mimeType: a.mimeType,
        hash: a.hash,
        platforms: a.platforms,
        size: a.size,
        version: a.version,
        urls: {a.url}.nonNulls.toSet(),
        additionalEventTags: {
          // CLI-specific
          for (final e in a.executables) ('executable', e),
          // APK-specific
          ('version_code', a.versionCode),
          ('min_sdk_version', a.minSdkVersion),
          ('target_sdk_version', a.targetSdkVersion),
          for (final signatureHash in (a.signatureHashes ?? {}))
            ('apk_signature_hash', signatureHash),
        },
      );
    }).toSet();

    final fRelease = Release(
      content: 'Release notes here',
      identifier: fFileMetadatas.first.content,
      url: temp['url'],
      // TODO: Fix (need to get event ID)
      // linkedEvents: fFileMetadatas.map((f) => f.id.toString()).toSet(),
    );

    // TODO: Missing pubkey here
    // fApp.linkedReplaceableEvents.add(fRelease.getReplaceableEventLink());

    return (fApp, fRelease, fFileMetadatas);
  }
}

// extension on BaseEvent {
//   String getEventId(String pubkey) {
//     final data = [
//       0,
//       pubkey.toLowerCase(),
//       createdAt!.toInt(),
//       kind,
//       _tagList,
//       content
//     ];
//     final digest =
//         sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
//     return digest.toString();
//   }
// }

RegExp regexpFromKey(String key) {
  // %v matches 1.0 or 1.0.1, no groups are captured
  // TODO: No longer need to match %v
  key = key.replaceAll('%v', r'\d+\.\d+(?:\.\d+)?');
  return RegExp(key);
}
