import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
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
import 'package:zapstore_cli/utils/version_utils.dart';

class AssetParser {
  final Map appMap;

  final partialApp = PartialApp();
  final partialRelease = PartialRelease(newFormat: isNewNipFormat);
  final partialFileMetadatas = <PartialFileMetadata>{};
  final partialSoftwareAssets = <PartialSoftwareAsset>{};

  late String? releaseVersion;
  late var assetHashes = <String>{};
  late final BlossomClient blossomClient;
  Set<String>? remoteMetadata;

  bool get isParsingLocalAssets => runtimeType == AssetParser;

  AssetParser(this.appMap) {
    partialApp.identifier =
        appMap['identifier'] ?? appMap['name']?.toString().toLowerCase();
    partialApp.name = appMap['name'];
    blossomClient = BlossomClient(
      appMap['blossom_server'] ?? defaultBlossomServer,
    );
    remoteMetadata = appMap.containsKey('remote_metadata')
        ? {...appMap['remote_metadata']}
        : null;
  }

  Future<List<PartialModel>> run() async {
    // Find a release version
    releaseVersion = await resolveReleaseVersion();

    // Resolve asset hashes (filters out unwanted platforms and mime types)
    assetHashes = await resolveAssetHashes();

    // Applies metadata found in assets
    await applyFileMetadata();

    // Applies metadata from configurable remote APIs
    await applyRemoteMetadata();

    // Generate Blossom authorizations only if needed
    final assets = [...assetHashes, ...partialApp.icons, ...partialApp.images];
    final partialBlossomAuthorizations = await blossomClient
        .generateAuthorizations(assets);

    // Adjust Blossom servers for all assets
    updateBlossomUrls();

    if (!overwriteRelease) {
      await checkVersionOnRelays(
        partialApp.identifier!,
        partialRelease.version!,
        versionCode: partialFileMetadatas.firstOrNull?.versionCode,
      );
    }

    // Translate to new NIP format
    if (isNewNipFormat) {
      for (final m in partialFileMetadatas) {
        final partialSoftwareAsset = PartialSoftwareAsset()
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
        partialSoftwareAssets.add(partialSoftwareAsset);
      }
    }

    return [
      partialApp,
      partialRelease,
      if (isNewNipFormat) ...partialSoftwareAssets,
      if (!isNewNipFormat) ...partialFileMetadatas,
      ...partialBlossomAuthorizations,
    ];
  }

  Future<String?> resolveReleaseVersion() async {
    if (appMap['version'] is String) {
      return appMap['version'];
    }
    return null;
  }

  Future<Set<String>> resolveAssetHashes() async {
    final assetHashes = <String>{};
    for (final definedAsset in appMap['assets']) {
      // Replace all asset paths with resolved version
      final asset = releaseVersion != null
          ? definedAsset.toString().replaceAll('\$version', releaseVersion!)
          : definedAsset;

      final dir = Directory(
        path.join(path.dirname(configPath), path.dirname(asset)),
      );
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
        hasVersionInConfig: appMap['version'] is String,
        executablePatterns: appMap['executables'] != null
            ? {...appMap['executables']}
            : null,
      );

      if (partialFileMetadata == null) {
        final assetPath = hashPathMap[assetHash];
        stderr.writeln(
          '⚠️  Ignoring asset $assetPath with architecture not in $kZapstoreSupportedPlatforms',
        );
        continue;
      }

      // If no identifier was set, default to app identifier
      partialFileMetadata.appIdentifier ??= partialApp.identifier;
      if (partialFileMetadata.appIdentifier == null) {
        throw 'Missing identifier. Did you add it to your config?';
      }

      // If no version was set, default to release version
      partialFileMetadata.version ??= releaseVersion;
      if (partialFileMetadata.version == null) {
        throw 'Missing version. Did you add it to your config?';
      }

      // Place first the original URL, Blossom servers will be added
      if (hashPathMap.containsKey(assetHash) &&
          Uri.parse(hashPathMap[assetHash]!).scheme.startsWith('http')) {
        partialFileMetadata.event.addTagValue('url', hashPathMap[assetHash]);
      }

      // Inherit createdAt from release
      partialFileMetadata.event.createdAt = partialRelease.event.createdAt;

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
    final hasMetadataWithArm64v8aOnly = partialFileMetadatas.any(
      (m) => m.platforms.difference({'android-arm64-v8a'}).isEmpty,
    );

    partialFileMetadatas.removeWhere((m) {
      final discard =
          m.mimeType == kAndroidMimeType &&
          hasMetadataWithArm64v8aOnly &&
          m.platforms.length > 1;
      if (discard && !isDaemonMode) {
        stderr.writeln(
          '⚠️ Discarding asset: ${hashPathMap[m.hash]} with multiple architectures',
        );
      }
      return discard;
    });

    // App
    partialApp.identifier ??= partialFileMetadatas.first.appIdentifier;

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

    if (overwriteApp) {
      // If overwriteApp is false, don't even bother working on icon/images
      // (Rest of properties may be necessary for partial release, etc)
      if (appMap['icon'] != null) {
        final iconHash = await _resolveImageHash(appMap['icon']);
        partialApp.addIcon(iconHash);
      } else {
        // Get extracted icon data from the first metadata (APK)
        final iconBase64 = partialFileMetadatas
            .first
            .transientData['iconBase64']
            ?.toString();

        if (iconBase64 != null) {
          final bytes = base64Decode(iconBase64);
          final hash = sha256.convert(bytes).toString().toLowerCase();
          await File(getFilePathInTempDirectory(hash)).writeAsBytes(bytes);
          hashPathMap[hash] = '(icon from APK)';
          partialApp.addIcon(hash);
        }
      }

      for (final imagePath in appMap['images'] ?? []) {
        final imageHash = await _resolveImageHash(imagePath);
        partialApp.addImage(imageHash);
      }
    }

    // App's platforms are the sum of file metadatas' platforms
    partialApp.platforms = partialFileMetadatas
        .map((fm) => fm.platforms)
        .flattened
        .toSet();

    // Always use the release timestamp
    partialApp.event.createdAt = partialRelease.event.createdAt;

    // Release
    if (isNewNipFormat) {
      partialRelease.appIdentifier = partialApp.identifier;
      partialRelease.version = releaseVersion;
    }
    partialRelease.identifier = '${partialApp.identifier}@$releaseVersion';

    final changelogFile = File(
      path.join(
        path.dirname(configPath),
        appMap['changelog'] ?? 'CHANGELOG.md',
      ),
    );
    // Only go ahead with parsing if either: is uploading local assets
    // or user has explicitly specified a changelog path
    final doParse = isParsingLocalAssets || appMap.containsKey('changelog');
    if (await changelogFile.exists() && doParse) {
      final md = await changelogFile.readAsString();

      // If changelog file was provided, it takes precedence
      if (appMap.containsKey('changelog')) {
        partialRelease.releaseNotes = extractChangelogSection(
          md,
          partialRelease.version!,
        );
      }
      // Only change here if no notes, whether from the call before
      // or from another parser
      partialRelease.releaseNotes ??= extractChangelogSection(
        md,
        partialRelease.version!,
      );
    }
    metadataSpinner.success('Extracted metadata from files');
  }

  /// Applies metadata from remote sources: Github, Play Store, etc
  @mustCallSuper
  Future<void> applyRemoteMetadata() async {
    if (!overwriteApp) return;

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
          'Fetched remote metadata for ${partialApp.identifier} [${fetcher.name}]',
        );
      } catch (e) {
        extraMetadataSpinner.fail(
          'Failed to fetch remote metadata for ${partialApp.identifier}: $e [${fetcher.name}]',
        );
      }
    }
  }

  void updateBlossomUrls() {
    for (final partialFileMetadata in partialFileMetadatas) {
      partialFileMetadata.event.addTagValue(
        'url',
        blossomClient.server
            .replace(path: partialFileMetadata.hash!)
            .toString(),
      );
    }

    partialApp.icons = partialApp.icons
        .map((hash) => '${blossomClient.server}/$hash')
        .toSet();
    partialApp.images = partialApp.images
        .map((hash) => '${blossomClient.server}/$hash')
        .toSet();
  }

  Future<String> _resolveImageHash(String imagePath) async {
    if (imagePath.isHttpUri) {
      return await fetchFile(imagePath, spinner: null);
    }
    final assetPath = path.join(path.dirname(configPath), imagePath);
    return await copyToHash(assetPath);
  }
}
