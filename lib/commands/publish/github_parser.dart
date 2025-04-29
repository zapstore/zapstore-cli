import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/utils.dart';

class GithubParser extends ArtifactParser {
  GithubParser(super.appMap);

  String get repositoryName =>
      Uri.parse(releaseRepository ?? sourceRepository!).path.substring(1);

  Map<String, String> get headers => env['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${env['GITHUB_TOKEN']}'}
      : <String, String>{};

  @override
  Future<void> initialize() async {
    final metadataSpinner = CliSpin(
      text: 'Fetching release...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    final latestReleaseUrl =
        'https://api.github.com/repos/$repositoryName/releases/latest';
    Map<String, dynamic>? latestReleaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    app.version =
        appMap['version'] ?? latestReleaseJson['tag_name']!.toString();

    // If there's a message it's an error (or no matching assets were found)
    if (latestReleaseJson['message'] != null ||
        !(latestReleaseJson['assets'] as Iterable)
            .any((a) => (appMap['artifacts'] as Iterable).any((e) {
                  final r =
                      regexpFromKey(e.replaceAll('\$version', app.version!));
                  return r.hasMatch(a['name']) ||
                      (a['label'] != null && r.hasMatch(a['label']));
                }))) {
      final response = await http.get(
          Uri.parse('https://api.github.com/repos/$repositoryName/releases'),
          headers: headers);
      final releases = jsonDecode(response.body);

      if (releases is Map && releases['message'] != null) {
        throw 'Error ${releases['message']} for $repositoryName';
      }
      releases as Iterable;
      if (releases.isEmpty) {
        throw 'No releases available';
      }

      latestReleaseJson = _findRelease(releases);
    }

    if (latestReleaseJson == null ||
        (latestReleaseJson['assets'] as Iterable).isEmpty) {
      final message = 'No packages in $repositoryName';
      if (isDaemonMode) {
        print(message);
      }
      metadataSpinner.fail(message);
      throw GracefullyAbortSignal();
    }

    metadataSpinner.success('Fetched release from Github');

    for (final key in appMap['artifacts']) {
      if (await File(key).exists()) {
        print('skipping as file exists');
        continue;
      }

      final assets = (latestReleaseJson['assets'] as Iterable).where((a) =>
          regexpFromKey(key).hasMatch(a['name']) ||
          (a['label'] != null && regexpFromKey(key).hasMatch(a['label'])));

      final packageSpinner = CliSpin(
        text: 'Fetching package...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

      if (assets.isEmpty) {
        final message = 'No asset matching $key';
        if (isDaemonMode) {
          print(message);
        }
        packageSpinner.fail(message);
        throw GracefullyAbortSignal();
      }

      for (final asset in assets) {
        final artifactUrl = asset['browser_download_url'];
        packageSpinner.text = 'Fetching package $artifactUrl...';

        // if (!overwriteRelease) {
        //   await checkReleaseOnRelay(
        //     version: version,
        //     artifactUrl: artifactUrl,
        //     spinner: packageSpinner,
        //   );
        // }

        final tempPackagePath = await fetchFile(artifactUrl,
            headers: headers, spinner: packageSpinner);
        final (fileHash, filePath, _) = await renameToHash(tempPackagePath);

        final fm = PartialFileMetadata();
        fm.path = filePath;
        fm.hash = fileHash;
        fm.mimeType = detectFileType(
                Uint8List.fromList(File(filePath).readAsBytesSync())) ??
            asset['content_type'];
        app.artifacts.add(fm);

        packageSpinner.success('Fetched package: $artifactUrl');
      }

      temp['created_at'] = DateTime.tryParse(latestReleaseJson['created_at']);

      // Since previous check was done on URL, check again now against hash
      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     artifactHash: fileHash,
      //     spinner: packageSpinner,
      //   );
      // }
    }
  }

  @override
  Future<void> applyRemoteMetadata() async {
    final repoUrl = 'https://api.github.com/repos/$repositoryName';
    final repoJson =
        await http.get(Uri.parse(repoUrl), headers: headers).getJson();

    appMap['description'] ??= repoJson['description'];

    // var app = await toApp();
    // app = app.copyWith(
    //   content: app.content.isNotEmpty ? app.content : repoJson['description'],
    //   identifier: app.identifier,
    //   name: app.name ?? repoJson['name'],
    //   url: app.url ??
    //       ((repoJson['homepage']?.isNotEmpty ?? false)
    //           ? repoJson['homepage']
    //           : null),
    //   license: app.license ?? repoJson['license']?['spdx_id'],
    //   tags: app.tags.isEmpty
    //       ? (repoJson['topics'] as Iterable).toSet().cast()
    //       : app.tags,
    //   pubkeys: app.pubkeys,
    // );

    // final release = Release(
    //   createdAt: fileMetadatas.first.createdAt,
    //   // content: latestReleaseJson['body'],
    //   identifier: fileMetadatas.first.content,
    //   // url: latestReleaseJson['html_url'],
    //   pubkeys: app.pubkeys,
    //   zapTags: app.zapTags,
    // );

    return super.applyRemoteMetadata();
  }

  Map<String, dynamic>? _findRelease(Iterable releases) {
    for (final r in releases) {
      for (final asset in r['assets']) {
        for (final e in appMap['artifacts']) {
          if (regexpFromKey(e.key).hasMatch(asset['name'])) {
            return r;
          }
        }
      }
    }
    return null;
  }
}
