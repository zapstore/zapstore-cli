import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
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

  late final Set<RegExp> assetRegexps;

  @override
  Future<String?> resolveVersion() async {
    final metadataSpinner = CliSpin(
      text: 'Fetching release from Github...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    assetRegexps =
        (appMap.containsKey('assets') ? <String>{...appMap['assets']} : {'.*'})
            .map(RegExp.new)
            .toSet();

    final releasesUrl = 'https://api.github.com/repos/$repositoryName/releases';
    final latestReleaseUrl = '$releasesUrl/latest';
    releaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    // If there's a message it's an error (or no matching assets were found)
    final ok = releaseJson!['message'] != null ||
        !(releaseJson!['assets'] as Iterable).any((a) {
          return assetRegexps.any((r) {
            return r.hasMatch(a['name']) ||
                (a['label'] != null && r.hasMatch(a['label']));
          });
        });
    if (ok) {
      final response = await http.get(Uri.parse(releasesUrl), headers: headers);
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
    for (final r in assetRegexps) {
      final assets = (releaseJson!['assets'] as Iterable).where((a) {
        return r.hasMatch(a['name']) ||
            (a['label'] != null && r.hasMatch(a['label']));
      });

      if (assets.isEmpty) {
        final message = 'No asset matching $r';
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
          final publishedAt = DateTime.tryParse(releaseJson?['published_at']);
          await checkUrl(assetUrl, resolvedVersion!, publishedAt: publishedAt);
        }

        assetSpinner.text = 'Fetching asset $assetUrl...';

        final fileHash =
            await fetchFile(assetUrl, headers: headers, spinner: assetSpinner);
        final filePath = getFilePathInTempDirectory(fileHash);
        if (await acceptAsset(filePath)) {
          assetHashes.add(fileHash);
        }

        assetSpinner.success('Fetched asset: $assetUrl');
      }
    }
    return assetHashes;
  }

  @override
  Future<void> applyFileMetadata() async {
    partialRelease.releaseNotes ??= releaseJson?['body'];

    partialRelease.event.createdAt =
        DateTime.tryParse(releaseJson?['published_at']) ?? DateTime.now();
    partialRelease.url = releaseJson?['html_url'];

    // If no identifier set yet, apply repo name (may be overridden later)
    partialApp.identifier ??= repositoryName.split('/').lastOrNull;
    partialApp.name ??= releaseJson?['name'];

    return super.applyFileMetadata();
  }

  Map<String, dynamic>? _findRelease(Iterable releases) {
    for (final release in releases) {
      for (final asset in release['assets']) {
        for (final r in assetRegexps) {
          if (r.hasMatch(asset['name'])) {
            return release;
          }
        }
      }
    }
    return null;
  }
}
