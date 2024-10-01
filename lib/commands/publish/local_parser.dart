import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

class LocalParser {
  final App app;
  final List<String> artifacts;
  final String version;
  final RelayMessageNotifier relay;
  LocalParser(
      {required this.app,
      required this.artifacts,
      required this.version,
      required this.relay});

  Future<(App, Release, Set<FileMetadata>)> process({
    required bool overwriteRelease,
    String? releaseNotes,
    required Map<String, YamlMap> yamlArtifacts,
  }) async {
    final releaseCreatedAt = DateTime.now();

    final fileMetadatas = <FileMetadata>{};
    for (final artifactPath in artifacts) {
      if (!await File(artifactPath).exists()) {
        throw 'No artifact file found at $artifactPath';
      }

      final uploadSpinner = CliSpin(
        text: 'Uploading artifact: $artifactPath...',
        spinner: CliSpinners.dots,
      ).start();

      final tempArtifactPath =
          path.join(Directory.systemTemp.path, path.basename(artifactPath));
      await File(artifactPath).copy(tempArtifactPath);
      final (artifactHash, newArtifactPath, mimeType) =
          await renameToHash(tempArtifactPath);

      // Check if we already processed this release
      final metadataOnRelay = await relay.query<FileMetadata>(tags: {
        '#x': [artifactHash]
      });

      if (metadataOnRelay.isNotEmpty) {
        if (!overwriteRelease) {
          uploadSpinner.fail(
              'Artifact with hash $artifactHash is already in relay, nothing to do');
          throw GracefullyAbortSignal();
        }
      }

      String artifactUrl;
      try {
        artifactUrl = await uploadToBlossom(
            newArtifactPath, artifactHash, mimeType,
            spinner: uploadSpinner);
      } catch (e) {
        uploadSpinner.fail(e.toString());
        continue;
      }

      // Validate platforms
      final yamlArtifact = yamlArtifacts.entries.firstWhereOrNull(
          (e) => regexpFromKey(e.key).hasMatch(path.basename(artifactPath)));

      final match = yamlArtifact != null
          ? regexpFromKey(yamlArtifact.key).firstMatch(artifactPath)
          : null;

      final platforms = {...?yamlArtifact?.value['platforms'] as Iterable?};
      if (!platforms
          .every((platform) => kSupportedPlatforms.contains(platform))) {
        throw 'Artifact $artifactPath has platforms $platforms but some are not in $kSupportedPlatforms';
      }

      final size = await runInShell('wc -c < $newArtifactPath');

      final fileMetadata = FileMetadata(
        content: '${app.name} $version',
        createdAt: releaseCreatedAt,
        urls: {artifactUrl},
        mimeType: mimeType,
        hash: artifactHash,
        size: int.tryParse(size),
        platforms: platforms.toSet().cast(),
        version: version,
        pubkeys: app.pubkeys,
        zapTags: app.zapTags,
        additionalEventTags: {
          for (final e in (yamlArtifact?.value['executables'] ?? []))
            ('executable', replaceInExecutable(e, match)),
        },
      );
      fileMetadata.transientData['apkPath'] = newArtifactPath;
      fileMetadatas.add(fileMetadata);
      uploadSpinner.success('Uploaded artifact: $artifactPath to $artifactUrl');
    }

    final release = Release(
      createdAt: releaseCreatedAt,
      content: releaseNotes ?? '${app.name} $version',
      identifier: '${app.identifier}@$version',
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, fileMetadatas);
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
