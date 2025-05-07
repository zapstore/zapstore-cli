import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:json_path/json_path.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/main.dart';
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

  final partialApp = PartialApp();
  final partialRelease = PartialRelease();
  final partialFileMetadatas = <PartialFileMetadata>{};
  final blossomAuthorizations = <PartialBlossomAuthorization>{};

  final bool areFilesLocal;

  String? resolvedVersion;

  final artifactHashes = <String>{};

  ArtifactParser(this.appMap, {this.areFilesLocal = true});

  Future<void> resolveVersion() async {
    // Usecase: configs may specify a version: 1.2.1
    // and have artifacts $version replaced: jq-$version-macos
    if (appMap['version'] is String) {
      resolvedVersion = appMap['version'];
    }
    if (appMap['version'] is List) {
      final versionSpec = appMap['version'] as List;

      final [endpoint, selector, attribute, ...rest] = versionSpec;
      final request = http.Request('GET', Uri.parse(endpoint))
        ..followRedirects = false;

      final response = await http.Client().send(request);

      RegExpMatch? match;
      if (rest.isEmpty) {
        // If versionSpec has 3 positions, it's a: JSON endpoint (HTTP 2xx) or headers (HTTP 3xx)
        if (response.isRedirect) {
          final raw = response.headers[selector]!;
          match = regexpFromKey(attribute).firstMatch(raw);
        } else {
          final body = await response.stream.bytesToString();
          final jsonMatch = JsonPath(selector).read(body).firstOrNull?.value;
          if (jsonMatch != null) {
            match = regexpFromKey(attribute).firstMatch(jsonMatch.toString());
          }
        }
      } else {
        // If versionSpec has 4 positions, it's an HTML endpoint
        final body = await response.stream.bytesToString();
        final elem = parseHtmlDocument(body).querySelector(selector.toString());
        if (elem != null) {
          final raw =
              attribute.isEmpty ? elem.text! : elem.attributes[attribute]!;
          match = regexpFromKey(rest.first).firstMatch(raw);
        }
      }

      resolvedVersion = match != null
          ? (match.groupCount > 0 ? match.group(1) : match.group(0))
          : null;

      if (resolvedVersion == null) {
        final message = 'could not match version for $selector';
        // artifactSpinner.fail(message);
        if (isDaemonMode) {
          print(message);
        }
        throw GracefullyAbortSignal();
      }
    } else if (appMap['version'] is String) {
      resolvedVersion = appMap['version'];
    }

    // Replace all artifacts with resolved version
    (<String>[...appMap['artifacts']]).forEachIndexed((i, a) {
      appMap['artifacts'][i] = a.replaceAll('\$version', resolvedVersion!);
      // print('replacgin $a = $resolvedVersion');
    });
  }

  Future<void> findHashes() async {
    for (final artifact in appMap['artifacts']) {
      final dir = Directory(path.dirname(artifact));
      final r = RegExp('^${path.basename(artifact)}\$');
      final apaths = dir
          .listSync()
          .where((e) => e is File && r.hasMatch(path.basename(e.path)))
          .map((e) => e.path);

      for (final artifactPath in apaths) {
        final tempArtifactPath = getFileInTemp(artifactPath);
        await File(artifactPath).copy(tempArtifactPath);
        final (artifactHash, _) = await renameToHash(tempArtifactPath);
        artifactHashes.add(artifactHash);
      }
    }
  }

  /// Downloads (if necessary) and applies data in files,
  /// including APK data in the case of Android
  @mustCallSuper
  Future<void> applyMetadata() async {
    String? identifier = appMap['identifier'];

    for (final pfm in artifactHashes) {
      final (fm, bs) = await parseFile(pfm);

      identifier =
          _validatePropertyMatch(identifier, fm.identifier, type: 'identifier');
      resolvedVersion =
          _validatePropertyMatch(resolvedVersion, fm.version, type: 'version');

      partialFileMetadatas.add(fm);
      blossomAuthorizations.addAll(bs);
    }

    partialApp.name ??= appMap['name']?.toString().toLowerCase();
    partialApp.identifier = identifier ?? partialApp.name;
    partialRelease.identifier = '$identifier@$resolvedVersion';

    partialApp.url ??= appMap['homepage'];
    if (partialApp.tags.isEmpty) {
      partialApp.tags =
          (appMap['tags'] as String?)?.trim().split(' ').toSet() ?? {};
    }

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

    partialApp
      ..description = appMap['description'] ?? appMap['summary']
      ..summary = appMap['summary']
      ..repository = sourceRepository
      ..license = appMap['license'];
    if (appMap['icon'] != null) {
      final icon = (await renameToHashes([appMap['icon']])).first;
      partialApp.addIcon(icon);
    }
    for (final image in await renameToHashes(appMap['images'] ?? [])) {
      partialApp.addImage(image);
    }

    // TODO: Look for release notes from file?
    partialRelease.event.content = '';
    partialRelease.identifier = '$identifier@$resolvedVersion';

    // TODO: Perform all this earlier
    partialApp.platforms =
        partialFileMetadatas.map((fm) => fm.platforms).flattened.toSet();
    // partialApp.event.setTagValue('a', partialRelease.event.addressableId);

    // Always use the latest release timestamp, but do earlier
    partialApp.event.createdAt = partialRelease.event.createdAt;

    // TODO: How can I link models at this stage if I need ID and for that pubkey
    for (final fm in partialFileMetadatas) {
      // partialRelease.linkModel(fm);
    }
    // partialRelease.linkModel(signedApp);
  }

  /// Fetches from Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    // TODO: Restore
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

  String? get sourceRepository => appMap['repository'];
  String? get releaseRepository => appMap['release_repository'];

  Future<(PartialFileMetadata, Set<PartialBlossomAuthorization>)> parseFile(
      String artifactHash) async {
    final metadata = PartialFileMetadata();

    String? identifier;

    final artifactPath = getFileInTemp(artifactHash);
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

      metadata.apkSignatureHashes = await getSignatureHashes(artifactPath);
      if (metadata.apkSignatureHashes.isEmpty) {
        throw 'No APK certificate signatures found, to check run: apksigner verify --print-certs $artifactPath';
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
      metadata.targetSdkVersion =
          usesSdk.attributes['android:targetSdkVersion'];

      metadata.mimeType = kAndroidMimeType;
      metadata.identifier = identifier;

      // For backwards-compatibility
      metadata.event.content = '${metadata.identifier}@${metadata.version}';
    } else {
      // CLI
      metadata.version = resolvedVersion;

      if (fileType == 'application/gzip') {
        final bytes =
            GZipDecoder().decodeBytes(File(artifactPath).readAsBytesSync());
        final archive = TarDecoder().decodeBytes(bytes);
        // TODO: In this way detect executables!
        // And then pass through executables regex filter from config
        final w = archive.files
            .map((f) => f.isFile && f.size > 0 ? detectFileType(f.name) : '');
        print(w);
      } else if (fileType == 'application/zip') {}
    }

    // If platforms were not set, we are dealing with a binary
    if (metadata.platforms.isEmpty) {
      metadata.platforms = {
        switch (fileType) {
          'application/x-mach-binary-arm64' => 'darwin-arm64',
          'application/x-mach-binary-amd64' => 'darwin-x86_64',
          'application/x-elf-aarch64' => 'linux-aarch64',
          'application/x-elf-amd64' => 'linux-x86_64',
          _ => throw UnsupportedError('Bad platform: $fileType')
        }
      };
    }

    // Default mime type, we query by platform anyway
    metadata.mimeType ??= 'application/octet-stream';

    // TODO: Should get the original name to inform the user
    _verifyPlatforms(metadata, 'artifactPath');

    // TODO: Add executables
    // final executables = artifactEntry?.value?['executables'] ?? [];

    metadata.hash = artifactHash;
    metadata.url = '$kZapstoreBlossomUrl/$artifactHash';
    metadata.size = await File(getFileInTemp(artifactHash)).length();

    final bs = {
      PartialBlossomAuthorization()
        // content should be the name of the original file
        ..content = 'Upload ${path.basename(artifactPath)}'
        ..type = BlossomAuthorizationType.upload
        ..expiration = DateTime.now().add(Duration(days: 1))
        ..addHash(artifactHash)
    };

    return (metadata, bs);
  }

  String _validatePropertyMatch(String? s1, String? s2,
      {required String type}) {
    s1 ??= s2;
    if (s1 == null || s1.isEmpty) {
      throw 'Please provide $type in the config';
    } else if (s2 != null && s1 != s2) {
      throw '$s1 != $s2 - mismatching $type, abort';
    }
    return s1;
  }

  void _verifyPlatforms(PartialFileMetadata metadata, String artifactPath) {
    if (metadata.mimeType == kAndroidMimeType) {
      if (!metadata.platforms.contains('android-arm64-v8a')) {
        throw UnsupportedError('APK $artifactPath does not support arm64-v8a');
      }
    }
    if (metadata.platforms
        .any((platform) => !kZapstoreSupportedPlatforms.contains(platform))) {
      throw UnsupportedError(
          'Artifact has platforms ${metadata.platforms} but some are not in $kZapstoreSupportedPlatforms');
    }
  }
}

RegExp regexpFromKey(String key) {
  // %v matches 1.0 or 1.0.1, no groups are captured
  // TODO: No longer need to match %v
  key = key.replaceAll('%v', r'\d+\.\d+(?:\.\d+)?');
  return RegExp(key);
}
