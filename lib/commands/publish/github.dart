import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:zapstore_cli/models.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

Future<(App, Release, List<FileMetadata>)> parseFromGithub(
    String repoName, App app,
    {String? contentType}) async {
  final headers = Platform.environment['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${Platform.environment['GITHUB_TOKEN']}'}
      : <String, String>{};

  final repoUrl = 'https://api.github.com/repos/$repoName';

  final metadataSpinner = CliSpin(
    text: 'Downloading package...',
    spinner: CliSpinners.dots,
  ).start();

  final repoJson =
      await http.get(Uri.parse(repoUrl), headers: headers).getJson();
  metadataSpinner.success('Fetching metadata from Github');

  final packageSpinner = CliSpin(
    text: 'Fetching packages...',
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
    // TODO FINISH
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
    packageSpinner.fail();
    throw 'No packages in $repoName, I\'m done here';
  }

  final fileMetadatas = <FileMetadata>[];
  for (final regexpKey in (app.artifacts ?? {}).keys) {
    final r = RegExp(regexpKey);
    final asset = assets.firstWhereOrNull((a) => r.hasMatch(a['name']));

    if (asset == null) {
      throw 'No asset matching ${r.pattern}';
    }

    final packageUrl = asset['browser_download_url'];
    final value = app.artifacts![regexpKey];

    // Check if we already processed this release
    final container = ProviderContainer();
    // TODO: Organize relay init and so on
    final relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    relay.initialize();
    final metadataOnRelay =
        await relay.query(RelayRequest(kinds: {1063}, search: packageUrl));

    // Search is full-text (not exact) so we double-check
    final metadataOnRelayCheck =
        metadataOnRelay.firstWhereOrNull((m) => getTag(m, 'url') == packageUrl);
    if (metadataOnRelayCheck != null) {
      if (Platform.environment['OVERWRITE'] == null) {
        throw 'Metadata for latest $repoName release already in relay, nothing to do';
      }
    }

    final tempPackagePath =
        path.join(Directory.systemTemp.path, path.basename(packageUrl));
    await fetchFile(packageUrl, File(tempPackagePath), headers: headers);

    final (fileHash, filePath) = await renameToHash(tempPackagePath);
    final size = await runInShell('wc -c < $filePath');
    fileMetadatas.add(
      FileMetadata(
        urls: {packageUrl},
        hash: fileHash,
        mimeType: asset['content_type'],
        platforms: {value['platform']},
        size: int.tryParse(size),
        version: latestReleaseJson['tag_name'],
      ),
    );
  }

  packageSpinner.success('Fetched packages');

  final appFromGithub = App(
    identifier: app.identifier.isEmpty ? app.identifier : repoJson['name'],
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
    createdAt: DateTime.parse(latestReleaseJson['created_at']),
    content: latestReleaseJson['body'],
    identifier: '${repoJson['name']}@${latestReleaseJson['tag_name']}',
    url: latestReleaseJson['html_url'],
  );

  return (appFromGithub, release, fileMetadatas);
}
