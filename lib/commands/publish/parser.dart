import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:json_path/json_path.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fastlane_metadata_fetcher.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fdroid_metadata_fetcher.dart';
import 'package:zapstore_cli/commands/publish/fetchers/github_metadata_fetcher.dart';
import 'package:zapstore_cli/commands/publish/fetchers/playstore_metadata_fetcher.dart';
import 'package:zapstore_cli/commands/publish/parser_utils.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/utils.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:universal_html/parsing.dart';

class AssetParser {
  final Map appMap;

  final partialApp = PartialApp();
  final partialRelease = PartialRelease();
  final partialFileMetadatas = <PartialFileMetadata>{};
  final partialBlossomAuthorizations = <PartialBlossomAuthorization>{};

  final bool areFilesLocal;

  late String? resolvedVersion;
  late var assetHashes = <String>{};
  Set<String> get blossomServers => <String>{
        ...?appMap['blossom'] ?? {kZapstoreBlossomUrl}
      };

  AssetParser(this.appMap, {this.areFilesLocal = true});

  Future<List<PartialModel>> run() async {
    resolvedVersion = await resolveVersion();
    assetHashes = await resolveHashes();
    await applyFileMetadata();
    await applyRemoteMetadata();
    return [
      partialApp,
      partialRelease,
      ...partialFileMetadatas,
      ...partialBlossomAuthorizations
    ];
  }

  Future<String?> resolveVersion() async {
    String? version;

    // Usecase: configs may specify a version: 1.2.1
    // and have assets $version replaced: jq-$version-macos
    if (appMap['version'] is String) {
      version = appMap['version'];
    } else if (appMap['version'] is List) {
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

      version = match != null
          ? (match.groupCount > 0 ? match.group(1) : match.group(0))
          : null;
    }
    return version;
  }

  Future<Set<String>> resolveHashes() async {
    final assetHashes = <String>{};
    for (final definedAsset in appMap['assets']) {
      // Replace all asset paths with resolved version
      final asset = resolvedVersion != null
          ? definedAsset.toString().replaceAll('\$version', resolvedVersion!)
          : definedAsset;

      final dir = Directory(path.dirname(asset));
      final r = RegExp('^${path.basename(asset)}\$');

      final assetPaths = dir
          .listSync()
          .where((e) => e is File && r.hasMatch(path.basename(e.path)))
          .map((e) => e.path);

      for (final assetPath in assetPaths) {
        final hashesFromCompressed = await extractFromCompressedFile(assetPath);
        if (hashesFromCompressed != null) {
          // We only add hashes from inside a zip file
          assetHashes.addAll(hashesFromCompressed);
        } else {
          // Otherwise if it's a regular executable, rename and add
          assetHashes.add(await copyToHash(assetPath));
        }
      }
    }
    return assetHashes;
  }

  /// Applies metadata found in files (local or downloaded)
  @mustCallSuper
  Future<void> applyFileMetadata() async {
    String? identifier = appMap['identifier'];

    for (final hash in assetHashes) {
      final (partialFileMetadata, partialBlossomAuthorizations) =
          await extractMetadataFromFile(hash, blossomServers);

      identifier = _validatePropertyMatch(
          identifier, partialFileMetadata.identifier,
          type: 'identifier');
      resolvedVersion = _validatePropertyMatch(
          resolvedVersion, partialFileMetadata.version,
          type: 'version');

      partialFileMetadatas.add(partialFileMetadata);
      partialBlossomAuthorizations.addAll(partialBlossomAuthorizations);
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
    //     assetUrl: assetUrl,
    //     spinner: packageSpinner,
    //   );
    // }

    partialApp
      ..description = appMap['description'] ?? appMap['summary']
      ..summary = appMap['summary']
      ..repository = appMap['repository']
      ..license = appMap['license'];

    if (appMap['icon'] != null) {
      partialApp.addIcon(await copyToHash(appMap['icon']));
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

  /// Applies metadata from remote sources: Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    final metadataSources = appMap['metadata'] ?? [];

    for (final source in metadataSources) {
      final fetcher = switch (source) {
        'playstore' => PlayStoreMetadataFetcher(),
        'fdroid' => FDroidMetadataFetcher(),
        'fastlane' => FastlaneMetadataFetcher(),
        'github' => GithubMetadataFetcher(),
        _ => null,
      };

      if (fetcher == null) continue;

      CliSpin? extraMetadataSpinner;
      extraMetadataSpinner = CliSpin(
              text: 'Fetching extra metadata...',
              spinner: CliSpinners.dots,
              isEnabled: !isDaemonMode)
          .start();

      try {
        await fetcher.run(app: partialApp);
        extraMetadataSpinner.success('[${fetcher.name}] Fetched metadata');
      } catch (e) {
        extraMetadataSpinner.fail(
            '[${fetcher.name}] ${partialApp.identifier} was not found, no extra metadata added');
      }
    }

    // Generate Blossom authorizations (icons, images hold hashes until here)
    for (final i in [...partialApp.icons, ...partialApp.images]) {
      final auth = PartialBlossomAuthorization()
        ..content = 'Upload asset'
        ..type = BlossomAuthorizationType.upload
        ..expiration = DateTime.now().add(Duration(hours: 1))
        ..addHash(i);
      partialBlossomAuthorizations.add(auth);
    }

    // Adjust icon + image URLs with Blossom servers
    partialApp.icons = partialApp.icons
        .map((icon) => blossomServers.map((blossom) => '$blossom/$icon'))
        .expand((e) => e)
        .toSet();
    partialApp.images = partialApp.images
        .map((i) => blossomServers.map((blossom) => '$blossom/$i'))
        .expand((e) => e)
        .toSet();
  }

  // Helpers

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

  Future<Set<String>?> extractFromCompressedFile(String assetPath) async {
    final fileType = await detectFileType(assetPath);
    final okPlatforms = [
      'application/x-mach-binary-arm64',
      'application/x-elf-aarch64',
      'application/x-elf-amd64'
    ];
    final executableRegexps =
        <String>{...?appMap['executables']}.map(RegExp.new);
    final assetHashes = <String>{};

    if (['application/gzip', 'application/zip'].contains(fileType)) {
      final archive = await getArchive(assetPath, fileType!);

      for (final f in archive.files) {
        if (f.isFile) {
          for (final r in executableRegexps) {
            if (r.hasMatch(f.name)) {
              final bytes = f.readBytes()!;
              if (okPlatforms.contains(await detectBytesType(bytes))) {
                final hash = sha256.convert(bytes).toString().toLowerCase();
                await File(getFilePathInTempDirectory(hash))
                    .writeAsBytes(bytes);
                assetHashes.add(hash);
              }
            }
          }
        }
      }
      return assetHashes;
    }
    return null;
  }
}
