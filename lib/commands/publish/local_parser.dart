import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:purplebase/purplebase.dart';
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
    required String os,
    required bool overwriteRelease,
    required Map<String, dynamic> yamlArtifacts,
  }) async {
    final releaseCreatedAt = DateTime.now();

    final fileMetadatas = <FileMetadata>{};
    for (var MapEntry(key: regexpKey, :value) in yamlArtifacts.entries) {
      regexpKey = regexpKey.replaceAll('%v', r'(\d+\.\d+(\.\d+)?)');
      final r = RegExp(regexpKey);
      final artifactPath =
          artifacts.firstWhereOrNull((a) => r.hasMatch(path.basename(a)));

      if (artifactPath == null) {
        final continueWithout = Confirm(
                prompt:
                    'No artifact matching $regexpKey. Edit zapstore.yaml if necessary. Continue?')
            .interact();
        if (continueWithout) {
          continue;
        } else {
          throw GracefullyAbortSignal();
        }
      }

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

      final match = r.firstMatch(artifactPath);
      final matchedVersion = (match?.groupCount ?? 0) > 0
          ? r.firstMatch(artifactPath)?.group(1)
          : version;

      // Validate platforms
      final platforms = {...?value['platforms'] as Iterable?};
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
            for (final b in (value['executables'] ?? []))
              (
                'executable',
                matchedVersion != null
                    ? b.toString().replaceFirst('%v', matchedVersion)
                    : b
              ),
          });
      fileMetadata.transientData['apkPath'] = newArtifactPath;
      fileMetadatas.add(fileMetadata);
      uploadSpinner.success('Uploaded artifact: $artifactPath to $artifactUrl');
    }

    final release = Release(
      createdAt: releaseCreatedAt,
      content: '${app.name} $version',
      identifier: '${app.identifier}@$version',
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, fileMetadatas);
  }
}
