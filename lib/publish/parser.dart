import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:json_path/json_path.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/publish/blossom.dart';
import 'package:zapstore_cli/publish/fetchers/fdroid_metadata_fetcher.dart';
import 'package:zapstore_cli/publish/fetchers/github_metadata_fetcher.dart';
import 'package:zapstore_cli/publish/fetchers/gitlab_metadata_fetcher.dart';
import 'package:zapstore_cli/publish/fetchers/playstore_metadata_fetcher.dart';
import 'package:zapstore_cli/publish/parser_utils.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

class AssetParser {
  final Map appMap;

  final partialApp = PartialApp();
  final partialRelease = PartialRelease(newFormat: isNewNipFormat);
  final partialFileMetadatas = <PartialFileMetadata>{};
  final partialSoftwareAssets = <PartialSoftwareAsset>{};
  final partialBlossomAuthorizations = <PartialBlossomAuthorization>{};

  late String? resolvedVersion;
  late var assetHashes = <String>{};
  late final BlossomClient blossomClient;
  Set<String>? remoteMetadata;

  bool get isParsingLocalAssets => runtimeType == AssetParser;

  AssetParser(this.appMap) {
    partialApp.identifier =
        appMap['identifier'] ?? appMap['name']?.toString().toLowerCase();
    partialApp.name = appMap['name'];
    blossomClient = BlossomClient(
      servers: {...?appMap['blossom_servers'] ?? defaultBlossomServers},
    );
    remoteMetadata = appMap.containsKey('remote_metadata')
        ? {...appMap['remote_metadata']}
        : null;
  }

  Future<List<PartialModel>> run() async {
    // Find a version
    resolvedVersion = await resolveVersion();
    // Resolve hashes (filters out unwanted mime types)
    assetHashes = await resolveHashes();
    // Applies metadata found in assets
    await applyFileMetadata();
    // Applies metadata from configurable remote APIs
    await applyRemoteMetadata();

    await generateBlossomAuthorizations();

    if (!overwriteRelease) {
      await checkVersionOnRelays(
        partialApp.identifier!,
        partialRelease.version!,
        versionCode: partialFileMetadatas.firstOrNull?.versionCode,
      );
    }

    if (isNewNipFormat) {
      for (final m in partialFileMetadatas) {
        final a = PartialSoftwareAsset()
          ..urls = m.urls
          ..mimeType = m.mimeType
          ..hash = m.hash
          ..size = m.size
          ..repository = m.repository
          ..platforms = m.platforms
          ..executables = m.executables
          ..minOSVersion = m.minSdkVersion
          ..targetOSVersion = m.targetSdkVersion
          ..appIdentifier = m.appIdentifier
          ..version = m.version
          ..versionCode = m.versionCode
          ..apkSignatureHash = m.apkSignatureHash
          ..filename = m.transientData['filename'];
        partialSoftwareAssets.add(a);
      }
    }

    return [
      partialApp,
      partialRelease,
      if (isNewNipFormat) ...partialSoftwareAssets,
      if (!isNewNipFormat) ...partialFileMetadatas,
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

      final versionSpinner = CliSpin(
        text: 'Resolving version from spec...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

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
          final jsonMatch =
              JsonPath(selector).read(jsonDecode(body)).firstOrNull?.value;
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
      if (version != null) {
        versionSpinner.success('Resolved version: $version');
      } else {
        versionSpinner.fail('Could not resolve version');
      }
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

      final assetPaths = (await dir.list().toList())
          .where((e) => e is File && r.hasMatch(path.basename(e.path)))
          .map((e) => e.path);

      for (final assetPath in assetPaths) {
        if (await acceptAssetMimeType(assetPath)) {
          final hash = await copyToHash(assetPath);
          assetHashes.add(hash);
        }
      }
    }
    if (assetHashes.isEmpty) {
      throw UsageException('No matching assets: ${appMap['assets']}', '');
    }
    return assetHashes;
  }

  /// Applies metadata found in files (local or downloaded)
  @mustCallSuper
  Future<void> applyFileMetadata() async {
    final metadataSpinner = CliSpin(
      text: 'Extracting metadata from files...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    for (final assetHash in assetHashes) {
      final partialFileMetadata = await extractMetadataFromFile(
        assetHash,
        resolvedIdentifier: partialApp.identifier,
        resolvedVersion: resolvedVersion,
        executablePatterns:
            appMap['executables'] != null ? {...appMap['executables']} : null,
      );

      if (partialFileMetadata == null) {
        final assetPath = hashPathMap[assetHash];
        stderr.writeln(
            '⚠️  Ignoring asset $assetPath with architecture not in $kZapstoreSupportedPlatforms');
        continue;
      }

      // Place first the original URL and leave Blossom servers as backup
      if (hashPathMap.containsKey(assetHash) &&
          Uri.parse(hashPathMap[assetHash]!).scheme.startsWith('http')) {
        partialFileMetadata.event.addTagValue('url', hashPathMap[assetHash]);
      }

      // If there are Blossom servers configured,
      // add Blossom url tags for each server
      if (blossomClient.servers.isNotEmpty) {
        for (final server in blossomClient.servers) {
          partialFileMetadata.event
              .addTagValue('url', server.replace(path: assetHash).toString());
        }

        // Only upload if necessary
        final needsUpload = await blossomClient.needsUpload(assetHash);
        if (needsUpload) {
          final partialBlossomAuthorization = PartialBlossomAuthorization()
            // content should be the name of the original file
            ..content = 'Upload ${hashPathMap[assetHash]}'
            ..type = BlossomAuthorizationType.upload
            ..mimeType = partialFileMetadata.mimeType!
            ..expiration = DateTime.now().add(Duration(days: 1))
            ..hash = assetHash;
          partialBlossomAuthorizations.add(partialBlossomAuthorization);
        }
      }

      partialFileMetadatas.add(partialFileMetadata);
    }

    if (partialFileMetadatas.isEmpty) {
      throw "No file metadata events produced";
    }

    // On Android, Zapstore only supports arm64-v8a.
    // If there are multiple assets, check if we have an exclusive
    // split ABI build for arm64-v8a. If so, remove others.
    // This is done to minimize the amount of universal builds
    // (more storage, bandwidth, and more options
    // showing in the UI as variants, which confuse users)
    final hasMetadataWithArm64v8aOnly = partialFileMetadatas
        .any((m) => m.platforms.difference({'android-arm64-v8a'}).isEmpty);

    partialFileMetadatas.removeWhere((m) {
      final discard = m.mimeType == kAndroidMimeType &&
          hasMetadataWithArm64v8aOnly &&
          m.platforms.length > 1;
      if (discard && !isDaemonMode) {
        stderr.writeln(
            '⚠️ Discarding asset: ${hashPathMap[m.hash]} with multiple architectures');
      }
      return discard;
    });

    // The source of truth now for identifier/version
    // are the file metadatas, so ensure they are all
    // equal and then assign to main app and release identifiers
    final allIdentifiers =
        partialFileMetadatas.map((m) => m.appIdentifier).nonNulls.toSet();
    if (allIdentifiers.isEmpty) {
      throw 'Missing identifier. Did you add it to your config?';
    }
    final uniqueIdentifier =
        DeepCollectionEquality().equals(allIdentifiers, {allIdentifiers.first});
    if (!uniqueIdentifier) {
      throw 'Identifier should be unique: $allIdentifiers';
    }

    final allVersions =
        partialFileMetadatas.map((m) => m.version).nonNulls.toSet();
    if (allVersions.isEmpty) {
      throw 'Missing version. Did you add it to your config?';
    }

    final uniqueVersions =
        DeepCollectionEquality().equals(allVersions, {allVersions.first});
    if (!uniqueVersions) {
      throw 'Version should be unique: $allVersions';
    }

    // App
    partialApp.identifier = allIdentifiers.first;
    final nameInApk = partialFileMetadatas.first.transientData['appName'];
    partialApp.name ??= nameInApk;
    partialApp.url ??= appMap['homepage'];
    if (partialApp.tags.isEmpty) {
      partialApp.tags =
          (appMap['tags'] as String?)?.trim().split(' ').toSet() ?? {};
    }

    partialApp
      ..description = appMap['description'] ?? appMap['summary']
      ..summary = appMap['summary']
      ..repository = appMap['repository']
      ..license = appMap['license'];

    if (appMap['icon'] != null) {
      partialApp.addIcon(await copyToHash(appMap['icon']));
    } else {
      // Get extracted icon data from the first metadata (APK)
      final iconBase64 =
          partialFileMetadatas.first.transientData['iconBase64']?.toString();

      if (iconBase64 != null) {
        final bytes = base64Decode(iconBase64);
        final hash = sha256.convert(bytes).toString().toLowerCase();
        await File(getFilePathInTempDirectory(hash)).writeAsBytes(bytes);
        hashPathMap[hash] = '(icon from APK)';
        partialApp.addIcon(hash);
      }
    }

    for (final image in appMap['images'] ?? []) {
      partialApp.addImage(await copyToHash(image));
    }

    // App's platforms are the sum of file metadatas' platforms
    partialApp.platforms =
        partialFileMetadatas.map((fm) => fm.platforms).flattened.toSet();

    // Always use the release timestamp
    partialApp.event.createdAt = partialRelease.event.createdAt;

    // Release
    if (isNewNipFormat) {
      partialRelease.appIdentifier = partialApp.identifier;
      partialRelease.version = allVersions.first;
    }
    partialRelease.identifier = '${partialApp.identifier}@${allVersions.first}';

    final changelogFile = File(path.join(
        path.dirname(configPath), appMap['changelog'] ?? 'CHANGELOG.md'));
    // Only go ahead with parsing if either: is uploading local assets
    // or user has explicitly specified a changelog path
    final doParse = isParsingLocalAssets || appMap.containsKey('changelog');
    if (await changelogFile.exists() && doParse) {
      final md = await changelogFile.readAsString();

      // If changelog file was provided, it takes precedence
      if (appMap.containsKey('changelog')) {
        partialRelease.releaseNotes =
            extractChangelogSection(md, partialRelease.version!);
      }
      // Only change here if no notes, whether from the call before
      // or from another parser
      partialRelease.releaseNotes ??=
          extractChangelogSection(md, partialRelease.version!);
    }
    metadataSpinner.success('Extracted metadata from files');
  }

  /// Applies metadata from remote sources: Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    if (skipRemoteMetadata) return;

    for (final source in remoteMetadata ?? {}) {
      final fetcher = switch (source) {
        'playstore' => PlayStoreMetadataFetcher(),
        'fdroid' => FDroidMetadataFetcher(),
        'github' => GithubMetadataFetcher(),
        'gitlab' => GitlabMetadataFetcher(),
        _ => null,
      };

      if (fetcher == null) continue;

      CliSpin? extraMetadataSpinner;
      extraMetadataSpinner = CliSpin(
        text: 'Fetching remote metadata...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

      try {
        await fetcher.run(app: partialApp, spinner: extraMetadataSpinner);
        extraMetadataSpinner.success(
            'Fetched remote metadata for ${partialApp.identifier} [${fetcher.name}]');
      } catch (e) {
        extraMetadataSpinner.fail(
            'Failed to fetch remote metadata for ${partialApp.identifier}: $e [${fetcher.name}]');
      }
    }
  }

  // Generate Blossom authorizations (icons, images hold hashes until here)
  Future<void> generateBlossomAuthorizations() async {
    final allAssets = [...partialApp.icons, ...partialApp.images];
    if (allAssets.isEmpty) return;

    final spinner = CliSpin(
      text: 'Checking for existing assets...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    int i = 0;

    for (final hash in allAssets) {
      final originalFilePath = hashPathMap[hash]!;
      final needsUpload = await blossomClient.needsUpload(hash);
      i++;
      spinner.text =
          'Checking for existing asset ($i/${allAssets.length}): $originalFilePath';
      if (needsUpload) {
        final (mimeType, _, _) =
            await detectMimeTypes(getFilePathInTempDirectory(hash));
        final auth = PartialBlossomAuthorization()
          ..content = 'Upload asset $originalFilePath'
          ..type = BlossomAuthorizationType.upload
          ..mimeType = mimeType
          ..expiration = DateTime.now().add(Duration(hours: 1))
          ..hash = hash;
        partialBlossomAuthorizations.add(auth);
      }
    }

    // Adjust icon + image URLs with Blossom servers
    partialApp.icons = partialApp.icons
        .map((icon) => blossomClient.servers.map((blossom) => '$blossom/$icon'))
        .expand((e) => e)
        .toSet();

    partialApp.images = partialApp.images
        .map((i) => blossomClient.servers.map((blossom) => '$blossom/$i'))
        .expand((e) => e)
        .toSet();

    spinner.success('Checked for existing assets ($i/${allAssets.length})');
  }
}
