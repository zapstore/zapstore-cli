import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

abstract class Fetcher {
  Future<(App, Release, Set<FileMetadata>)> fetch({required App app});
}

class GithubFetcher extends Fetcher {
  final RelayMessageNotifier relay;

  GithubFetcher({required this.relay});

  @override
  Future<(App, Release, Set<FileMetadata>)> fetch(
      {required App app,
      String? repoName,
      Map<String, dynamic>? artifacts,
      String? contentType}) async {
    final headers = Platform.environment['GITHUB_TOKEN'] != null
        ? {'Authorization': 'Bearer ${Platform.environment['GITHUB_TOKEN']}'}
        : <String, String>{};

    final repoUrl = 'https://api.github.com/repos/$repoName';

    final metadataSpinner = CliSpin(
      text: 'Fetching metadata...',
      spinner: CliSpinners.dots,
    ).start();

    final repoJson =
        await http.get(Uri.parse(repoUrl), headers: headers).getJson();

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
    final packageAssetArray = contentType != null
        ? assets.where((a) {
            return a.content_type == contentType;
          })
        : assets;

    if (packageAssetArray.isEmpty) {
      metadataSpinner.fail('No packages in $repoName, I\'m done here');
      throw GracefullyAbortSignal();
    }

    metadataSpinner.success('Fetched metadata from Github');

    final fileMetadatas = <FileMetadata>{};
    for (var MapEntry(key: regexpKey, :value) in artifacts!.entries) {
      regexpKey = regexpKey.replaceAll('%v', r'(\d{0,3}\.\d{0,3}\.\d{0,3})');
      final r = RegExp(regexpKey);
      final asset = assets.firstWhereOrNull((a) => r.hasMatch(a['name']));
      final matchedVersion = r.firstMatch(asset['name'])?.group(1);

      if ((value['executables'] ?? []).isNotEmpty && matchedVersion == null) {
        throw Exception('Failed to match pattern for executables');
      }

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
        if (Platform.environment['OVERWRITE'] == null) {
          packageSpinner
              .fail('Latest $repoName release already in relay, nothing to do');
          throw GracefullyAbortSignal();
        }
      }

      final tempPackagePath =
          path.join(Directory.systemTemp.path, path.basename(packageUrl));
      await fetchFile(packageUrl, File(tempPackagePath),
          headers: headers, spinner: packageSpinner);

      final (fileHash, filePath) = await renameToHash(tempPackagePath);
      final size = await runInShell('wc -c < $filePath');
      fileMetadatas.add(
        FileMetadata(
            content: '${app.name} ${latestReleaseJson['tag_name']}',
            createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
            urls: {packageUrl},
            mimeType: asset['content_type'],
            hash: fileHash,
            size: int.tryParse(size),
            platforms: {value['platform']},
            version: latestReleaseJson['tag_name'],
            additionalEventTags: {
              //   ('version_code', 19),
              //   ('min_sdk_version', 1),
              //   ('target_sdk_version', 2),
              //   ('apk_signature_hash', '122fg435')
              for (final b in (value['executables'] ?? []))
                (
                  'executable',
                  b.toString().replaceFirst('%v', matchedVersion!)
                ),
            }),
      );
      packageSpinner.success('Fetched package: $packageUrl');
    }

    final appFromGithub = App(
      content: app.summary ?? repoJson['description'],
      identifier: app.identifier ?? repoJson['name'],
      name: app.name ?? repoJson['name'],
      summary: app.summary ?? repoJson['description'],
      url: app.url ?? repoJson['homepage'],
      repository: app.repository ?? 'https://github.com/$repoName',
      license: app.license ?? repoJson['license']?['spdx_id'],
      tags: app.tags.isEmpty
          ? (repoJson['topics'] as Iterable).toSet().cast()
          : app.tags,
    );

    final release = Release(
      createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
      content: latestReleaseJson['body'],
      identifier: '${repoJson['name']}@${latestReleaseJson['tag_name']}',
      url: latestReleaseJson['html_url'],
    );

    return (appFromGithub, release, fileMetadatas);
  }
}
