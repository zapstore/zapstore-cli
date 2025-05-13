import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/utils.dart';

class GithubParser extends AssetParser {
  GithubParser(super.appMap) : super(areFilesLocal: false);

  Map<String, dynamic>? releaseJson;

  String get repositoryName =>
      Uri.parse(releaseRepository ?? sourceRepository!).path.substring(1);

  Map<String, String> get headers => env['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${env['GITHUB_TOKEN']}'}
      : <String, String>{};

  @override
  Future<void> resolveVersion() async {
    final metadataSpinner = CliSpin(
      text: 'Fetching release...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    final latestReleaseUrl =
        'https://api.github.com/repos/$repositoryName/releases/latest';
    releaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    // If there's a message it's an error (or no matching assets were found)
    if (releaseJson!['message'] != null ||
        !(releaseJson!['assets'] as Iterable)
            .any((a) => <String>{...appMap['assets']}.any((e) {
                  final r = RegExp(e);
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

      releaseJson = _findRelease(releases);

      if (releaseJson == null || (releaseJson!['assets'] as Iterable).isEmpty) {
        final message = 'No packages in $repositoryName';
        if (isDaemonMode) {
          print(message);
        }
        metadataSpinner.fail(message);
        throw GracefullyAbortSignal();
      }
    }

    metadataSpinner.success('Fetched release from Github');

    resolvedVersion = appMap['version'] ?? releaseJson!['tag_name']!.toString();
  }

  @override
  Future<void> findHashes() async {
    for (final key in appMap['assets']) {
      final assets = (releaseJson!['assets'] as Iterable).where((a) {
        final r = RegExp(key);
        return r.hasMatch(a['name']) ||
            (a['label'] != null && r.hasMatch(a['label']));
      });

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
        final assetUrl = asset['browser_download_url'];
        packageSpinner.text = 'Fetching package $assetUrl...';

        // if (!overwriteRelease) {
        //   await checkReleaseOnRelay(
        //     version: version,
        //     assetUrl: assetUrl,
        //     spinner: packageSpinner,
        //   );
        // }

        final fileHash = await fetchFile(assetUrl,
            headers: headers, spinner: packageSpinner);

        final fm = PartialFileMetadata();
        fm.hash = fileHash;
        fm.url = assetUrl;
        fm.mimeType = detectFileType(getFilePathInTempDirectory(fileHash)) ??
            asset['content_type'];
        partialFileMetadatas.add(fm);

        assetHashes.add(fileHash);

        packageSpinner.success('Fetched package: $assetUrl');
      }
    }
  }

  @override
  Future<void> applyMetadata() async {
    if (partialRelease.event.content.isEmpty) {
      partialRelease.event.content = releaseJson?['body'] ?? '';
    }
    partialRelease.event.createdAt =
        DateTime.tryParse(releaseJson?['created_at']) ?? DateTime.now();
    partialRelease.url = releaseJson?['html_url'];
    return super.applyMetadata();
  }

  @override
  Future<void> applyRemoteMetadata() async {
    final repoUrl = 'https://api.github.com/repos/$repositoryName';
    final repoJson =
        await http.get(Uri.parse(repoUrl), headers: headers).getJson();

    if (partialApp.description.isEmpty) {
      partialApp.description = repoJson['description'];
    }
    partialApp.tags.addAll([...repoJson['topics']]);

    return super.applyRemoteMetadata();
  }

  Map<String, dynamic>? _findRelease(Iterable releases) {
    for (final r in releases) {
      for (final asset in r['assets']) {
        for (final e in appMap['assets']) {
          if (RegExp(e.key).hasMatch(asset['name'])) {
            return r;
          }
        }
      }
    }
    return null;
  }
}
