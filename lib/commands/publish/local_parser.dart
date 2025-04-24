import 'dart:io';

import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/commands/publish/apk.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

abstract class ArtifactParser {}

class LocalParser extends ArtifactParser {
  Future<(App, Release, Set<FileMetadata>)> process({
    required YamlMap appMap,
    required List<String> artifacts,
    required bool overwriteRelease,
    String? releaseNotes,
    required SupportedOS os,
  }) async {
    var identifier = appMap['id']?.toString();
    var version = appMap['version']?.toString();
    final fileMetadatas = <FileMetadata>{};

    final releaseCreatedAt = DateTime.now();

    for (final artifactPath in artifacts) {
      if (!await File(artifactPath).exists()) {
        throw 'No artifact file found at $artifactPath';
      }

      switch (os) {
        case SupportedOS.android:
          fileMetadatas.add(await parseApk(artifactPath));
        case SupportedOS.cli:
          if (!appMap.containsKey('artifacts')) {
            throw 'CLI apps must contain artifacts in YAML config file';
          }
          // Check platforms are supported
          final artifactsYamlMap = appMap['artifacts'] as YamlMap;
          final artifactYaml = artifactsYamlMap.entries.firstWhereOrNull((e) =>
              regexpFromKey(e.key).hasMatch(path.basename(artifactPath)));

          final match = artifactYaml != null
              ? regexpFromKey(artifactYaml.key).firstMatch(artifactPath)
              : null;

          final platforms = {...?artifactYaml?.value['platforms'] as Iterable?};
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
          final size = await runInShell('wc -c < $newArtifactPath');

          final appIdWithVersion = '${identifier!}@${version!}';
          final fileMetadata = FileMetadata(
            content: appIdWithVersion,
            createdAt: releaseCreatedAt,
            urls: {artifactUrl},
            mimeType: mimeType,
            hash: artifactHash,
            size: int.tryParse(size),
            platforms: platforms.toSet().cast(),
            version: version,
            pubkeys: {appMap.developerPubkey}.nonNulls.toSet(),
            additionalEventTags: {
              for (final e in (artifactYaml?.value['executables'] ?? []))
                ('executable', replaceInExecutable(e, match)),
            },
          );
          fileMetadatas.add(fileMetadata);
      }
    }

    if (os == SupportedOS.android) {
      final versionsFromApk =
          fileMetadatas.map((m) => m.content).nonNulls.toSet();
      final hasOneVersionFromApk = versionsFromApk.length == 1;
      if (!hasOneVersionFromApk) {
        throw 'All APKs MUST coincide in identifier and version';
      }
      [identifier, version] = fileMetadatas.first.content.split('@');
    }

    final app = await appMap.toApp();

    final release = Release(
      createdAt: releaseCreatedAt,
      content: releaseNotes ?? '${app.name} $version',
      identifier: fileMetadatas.first.content,
      pubkeys: app.pubkeys,
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
