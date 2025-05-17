import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

class GithubParser extends AssetParser {
  GithubParser(super.appMap, {super.uploadToBlossom = false});

  Map<String, dynamic>? releaseJson;

  String get repositoryName =>
      Uri.parse(appMap['release_repository'] ?? appMap['repository']!)
          .path
          .substring(1);

  static Map<String, String> get headers => env['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${env['GITHUB_TOKEN']}'}
      : <String, String>{};

  @override
  Future<String?> resolveVersion() async {
    final metadataSpinner = CliSpin(
      text: 'Fetching release from Github...',
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
        final message = 'No assets in latest release for $repositoryName';
        if (isDaemonMode) {
          print(message);
        }
        metadataSpinner.fail(message);
        throw GracefullyAbortSignal();
      }
    }

    metadataSpinner.success('Fetched release from Github');

    return appMap['version'] ?? releaseJson!['tag_name']!.toString();
  }

  @override
  Future<Set<String>> resolveHashes() async {
    final assetHashes = <String>{};
    for (final key in appMap['assets']) {
      final assets = (releaseJson!['assets'] as Iterable).where((a) {
        final r = RegExp(key);
        return r.hasMatch(a['name']) ||
            (a['label'] != null && r.hasMatch(a['label']));
      });

      if (assets.isEmpty) {
        final message = 'No asset matching $key';
        stderr.writeln(message);
        throw GracefullyAbortSignal();
      }

      for (final asset in assets) {
        final assetSpinner = CliSpin(
          text: 'Fetching asset...',
          spinner: CliSpinners.dots,
          isSilent: isDaemonMode,
        ).start();

        final assetUrl = asset['browser_download_url'];

        if (!overwriteRelease) {
          await checkFuzzyEarly(assetUrl, resolvedVersion!);
        }

        assetSpinner.text = 'Fetching asset $assetUrl...';

        final fileHash =
            await fetchFile(assetUrl, headers: headers, spinner: assetSpinner);
        assetHashes.add(fileHash);

        assetSpinner.success('Fetched asset: $assetUrl');
      }
    }
    return assetHashes;
  }

  @override
  Future<void> applyFileMetadata() async {
    partialRelease.releaseNotes ??= releaseJson?['body'];

    partialRelease.event.createdAt =
        DateTime.tryParse(releaseJson?['created_at']) ?? DateTime.now();
    partialRelease.url = releaseJson?['html_url'];

    // Default to repo name if no identifier (if no metadatas are APKs)
    if (!partialFileMetadatas.any((m) => m.mimeType == kAndroidMimeType)) {
      identifier ??=
          partialApp.identifier ?? repositoryName.split('/').lastOrNull;
    }

    return super.applyFileMetadata();
  }

  Map<String, dynamic>? _findRelease(Iterable releases) {
    for (final r in releases) {
      for (final asset in r['assets']) {
        for (final e in appMap['assets']) {
          if (RegExp(e).hasMatch(asset['name'])) {
            return r;
          }
        }
      }
    }
    return null;
  }
}
