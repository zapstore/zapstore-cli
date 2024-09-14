import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';

class GithubParser extends RepositoryParser {
  final RelayMessageNotifier relay;

  GithubParser({required this.relay});

  @override
  Future<(App, Release, Set<FileMetadata>)> run({
    required App app,
    required String os,
    required bool overwriteApp,
    required bool overwriteRelease,
    String? repoName,
    Map<String, dynamic>? artifacts,
    String? artifactContentType,
  }) async {
    final headers = Platform.environment['GITHUB_TOKEN'] != null
        ? {'Authorization': 'Bearer ${Platform.environment['GITHUB_TOKEN']}'}
        : <String, String>{};

    final metadataSpinner = CliSpin(
      text: 'Fetching metadata...',
      spinner: CliSpinners.dots,
    ).start();

    final latestReleaseUrl =
        'https://api.github.com/repos/$repoName/releases/latest';
    var latestReleaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    // If there's a message it's an error
    if (latestReleaseJson['message'] != null) {
      final rs = await http
          .get(Uri.parse('https://api.github.com/repos/$repoName/releases'),
              headers: headers)
          .getJson();
      if (rs['message'] != null || rs.isEmpty) {
        throw 'Error ${rs['message']} for $repoName, I\'m done here';
      }
      // TODO: Finish this
      // rs.sort((a, b) => b.created_at.localeCompare(a.created_at));
      // latestReleaseJson = rs.first;
    }

    final assets = latestReleaseJson['assets'] as Iterable;
    final packageAssetArray = artifactContentType != null
        ? assets.where((a) {
            return a.content_type == artifactContentType;
          })
        : assets;

    if (packageAssetArray.isEmpty) {
      metadataSpinner.fail('No packages in $repoName, I\'m done here');
      throw GracefullyAbortSignal();
    }

    metadataSpinner.success('Fetched metadata from Github');

    final fileMetadatas = <FileMetadata>{};
    for (var MapEntry(key: regexpKey, :value) in artifacts!.entries) {
      regexpKey = regexpKey.replaceAll('%v', r'(\d+\.\d+(\.\d+)?)');
      final r = RegExp(regexpKey);
      final asset = assets.firstWhereOrNull((a) => r.hasMatch(a['name']));

      if (asset == null) {
        throw 'No asset matching ${r.pattern}';
      }

      final packageUrl = asset['browser_download_url'];

      final packageSpinner = CliSpin(
        text: 'Fetching package: $packageUrl...',
        spinner: CliSpinners.dots,
      ).start();

      // Check if we already processed this release
      final metadataOnRelay =
          await relay.query<FileMetadata>(search: packageUrl);

      // Search is full-text (not exact) so we double-check
      final metadataOnRelayCheck = metadataOnRelay
          .firstWhereOrNull((m) => m.urls.firstOrNull == packageUrl);
      if (metadataOnRelayCheck != null) {
        if (!overwriteRelease) {
          packageSpinner
              .fail('Latest $repoName release already in relay, nothing to do');
          throw GracefullyAbortSignal();
        }
      }

      final tempPackagePath = await fetchFile(packageUrl,
          headers: headers, spinner: packageSpinner);

      final match = r.firstMatch(asset['name']);
      final matchedVersion = (match?.groupCount ?? 0) > 0
          ? r.firstMatch(asset['name'])?.group(1)
          : latestReleaseJson['tag_name'];

      // Validate platforms
      final platforms = {...?value['platforms'] as Iterable?};
      if (!platforms
          .every((platform) => kSupportedPlatforms.contains(platform))) {
        throw 'Artifact ${asset['name']} has platforms $platforms but some are not in $kSupportedPlatforms';
      }

      final (fileHash, filePath, _) = await renameToHash(tempPackagePath);
      final size = await runInShell('wc -c < $filePath');
      final fileMetadata = FileMetadata(
          content: '${app.name} ${latestReleaseJson['tag_name']}',
          createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
          urls: {packageUrl},
          mimeType: asset['content_type'],
          hash: fileHash,
          size: int.tryParse(size),
          platforms: platforms.toSet().cast(),
          version: latestReleaseJson['tag_name'],
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
      fileMetadata.transientData['apkPath'] = filePath;
      fileMetadatas.add(fileMetadata);
      packageSpinner.success('Fetched package: $packageUrl');
    }

    if (overwriteApp) {
      final repoUrl = 'https://api.github.com/repos/$repoName';
      final repoJson =
          await http.get(Uri.parse(repoUrl), headers: headers).getJson();

      app = app.copyWith(
        content: app.content ?? repoJson['description'] ?? repoJson['name'],
        identifier: app.identifier ?? repoJson['name'],
        name: app.name ?? repoJson['name'],
        url: app.url ??
            ((repoJson['homepage']?.isNotEmpty ?? false)
                ? repoJson['homepage']
                : null),
        repository: app.repository ?? 'https://github.com/$repoName',
        license: app.license ?? repoJson['license']?['spdx_id'],
        tags: app.tags.isEmpty
            ? (repoJson['topics'] as Iterable).toSet().cast()
            : app.tags,
        pubkeys: app.pubkeys,
        zapTags: app.zapTags,
      );
    }

    final release = Release(
      createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
      content: latestReleaseJson['body'],
      identifier: '${app.identifier}@${latestReleaseJson['tag_name']}',
      url: latestReleaseJson['html_url'],
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, fileMetadatas);
  }
}

abstract class RepositoryParser {
  Future<(App, Release, Set<FileMetadata>)> run({
    required App app,
    required String os,
    required bool overwriteApp,
    required bool overwriteRelease,
  });
}
