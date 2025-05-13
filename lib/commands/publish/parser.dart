import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:json_path/json_path.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fastlane_fetcher.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fdroid_fetcher.dart';
import 'package:zapstore_cli/commands/publish/fetchers/playstore_fetcher.dart';
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
  final partialBlossomAuthorizations = <PartialBlossomAuthorization>{};

  final bool areFilesLocal;
  late final Set<String> blossomServers;

  String? resolvedVersion;

  final artifactHashes = <String>{};

  ArtifactParser(this.appMap, {this.areFilesLocal = true});

  Future<void> resolveVersion() async {
    blossomServers = {
      ...(appMap['blossom'] ?? {kZapstoreBlossomUrl})
    };

    // TODO: Rename artifacts to assets
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
          match = RegExp(attribute).firstMatch(raw);
        } else {
          final body = await response.stream.bytesToString();
          final jsonMatch = JsonPath(selector).read(body).firstOrNull?.value;
          if (jsonMatch != null) {
            match = RegExp(attribute).firstMatch(jsonMatch.toString());
          }
        }
      } else {
        // If versionSpec has 4 positions, it's an HTML endpoint
        final body = await response.stream.bytesToString();
        final elem = parseHtmlDocument(body).querySelector(selector.toString());
        if (elem != null) {
          final raw =
              attribute.isEmpty ? elem.text! : elem.attributes[attribute]!;
          match = RegExp(rest.first).firstMatch(raw);
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
  }

  Future<void> findHashes() async {
    for (final a in appMap['artifacts']) {
      // Replace all artifact paths with resolved version
      final artifact = resolvedVersion != null
          ? a.toString().replaceAll('\$version', resolvedVersion!)
          : a;
      final dir = Directory(path.dirname(artifact));
      final r = RegExp('^${path.basename(artifact)}\$');
      final apaths = dir
          .listSync()
          .where((e) => e is File && r.hasMatch(path.basename(e.path)))
          .map((e) => e.path);

      for (final artifactPath in apaths) {
        artifactHashes.add(await copyToHash(artifactPath));
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
      partialBlossomAuthorizations.addAll(bs);
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

    // All user provided assets should be renamed/copied (not moved)
    if (appMap['icon'] != null) {
      partialApp.addIcon(await copyToHash(appMap['icon']));
    }
    if (appMap['banner'] != null) {
      partialApp.banner = await copyToHash(appMap['banner']);
    }
    for (final image in appMap['images'] ?? []) {
      partialApp.addImage(await copyToHash(image));
    }

    // TODO: Look for release notes from file?
    // Or if no file, ask to paste .md contents
    partialRelease.event.content = '';
    partialRelease.identifier = '$identifier@$resolvedVersion';

    // App's platforms are the sum of file metadatas' platforms
    partialApp.platforms =
        partialFileMetadatas.map((fm) => fm.platforms).flattened.toSet();

    // Always use the latest release timestamp
    partialApp.event.createdAt = partialRelease.event.createdAt;
  }

  /// Fetches from Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    for (final m in appMap['remote_metadata']) {
      final fetcher = switch (m) {
        'playstore' => PlayStoreFetcher(),
        'fdroid' => FDroidFetcher(),
        'fastlane' => FastlaneFetcher(),
        _ => null,
      };

      if (fetcher == null) continue;

      CliSpin? extraMetadataSpinner;
      extraMetadataSpinner = CliSpin(
              text: 'Fetching extra metadata...',
              spinner: CliSpinners.dots,
              isEnabled: !isDaemonMode)
          .start();

      final metadataApp = await fetcher.run(
        appIdentifier: partialApp.identifier!,
      );

      if (metadataApp != null) {
        // All paths in metadataApp are just hashes, must add Blossom servers
        extraMetadataSpinner.success('[${fetcher.name}] Fetched metadata');
        partialApp.name ??= metadataApp.name;
        if (partialApp.description.isEmpty) {
          partialApp.description = metadataApp.description;
        }
        if (partialApp.icons.isEmpty && metadataApp.icons.isNotEmpty) {
          for (final s in blossomServers) {
            partialApp.addIcon('$s/${metadataApp.icons.first}');
          }
        }
        // TODO: Banner should be a Set
        partialApp.banner ??= metadataApp.banner;
        for (final i in metadataApp.images) {
          for (final s in blossomServers) {
            partialApp.addImage('$s/$i');
          }
        }
      } else {
        extraMetadataSpinner.fail(
            '[${fetcher.name}] ${partialApp.identifier} was not found, no extra metadata added');
      }
    }
  }

  Future<void> lastShit() async {
    // Here add final Blossom authorizations
    for (final hash in [
      ...partialApp.icons,
      if (partialApp.banner != null) partialApp.banner!,
      ...partialApp.images
    ]) {
      final auth = PartialBlossomAuthorization()
        ..content = 'Upload asset'
        ..type = BlossomAuthorizationType.upload
        ..expiration = DateTime.now().add(Duration(hours: 1))
        ..addHash(hash);
      partialBlossomAuthorizations.add(auth);
    }
  }

  // Helpers

  String? get sourceRepository => appMap['repository'];
  String? get releaseRepository => appMap['release_repository'];

  Future<(PartialFileMetadata, Set<PartialBlossomAuthorization>)> parseFile(
      String artifactHash) async {
    final metadata = PartialFileMetadata();

    String? identifier;

    final artifactPath = getFilePathInTempDirectory(artifactHash);
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
    _validatePlatforms(metadata, 'artifactPath');

    // TODO: Add executables
    // final executables = artifactEntry?.value?['executables'] ?? [];

    metadata.hash = artifactHash;
    metadata.url = '$kZapstoreBlossomUrl/$artifactHash';
    metadata.size =
        await File(getFilePathInTempDirectory(artifactHash)).length();

    final bs = {
      PartialBlossomAuthorization()
        // content should be the name of the original file
        ..content = 'Upload ${path.basename(artifactPath)}'
        ..type = BlossomAuthorizationType.upload
        ..mimeType = metadata.mimeType!
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

  void _validatePlatforms(PartialFileMetadata metadata, String artifactPath) {
    if (metadata.mimeType == kAndroidMimeType) {
      if (!metadata.platforms.contains('android-arm64-v8a')) {
        throw UnsupportedError(
            'APK $artifactPath does not support arm64-v8a: ${metadata.platforms}');
      }
    } else if (!metadata.platforms
        .every((platform) => kZapstoreSupportedPlatforms.contains(platform))) {
      throw UnsupportedError(
          'Artifact has platforms ${metadata.platforms} but some are not in $kZapstoreSupportedPlatforms');
    }
  }
}
