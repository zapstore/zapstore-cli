import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

class GithubParser extends AssetParser {
  GithubParser(super.appMap) {
    remoteMetadata ??= {'github'};
  }

  Map<String, dynamic>? releaseJson;

  static String getRepositoryName(String repository) =>
      Uri.parse(repository).path.substring(1);

  static Map<String, String> get headers => env['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${env['GITHUB_TOKEN']}'}
      : <String, String>{};

  late final Set<RegExp> assetRegexps;
  late final String repositoryName;

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
    repositoryName = getRepositoryName(
        appMap['release_repository'] ?? appMap['repository']!);

    final releasesUrl = 'https://api.github.com/repos/$repositoryName/releases';
    final latestReleaseUrl = '$releasesUrl/latest';
    releaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    // If there's a message it's an error (or no matching assets were found)
    final isFailure = releaseJson!['message'] != null ||
        !(releaseJson!['assets'] as Iterable).any((a) {
          return assetRegexps.any((r) {
            return r.hasMatch(_getNameFromAsset(a));
          });
        });
    if (isFailure) {
      // Get all releases and try again
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

    final version = releaseJson!['tag_name']!.toString();
    metadataSpinner.success('Fetched release ${version.bold()} from Github');

    return version;
  }

  @override
  Future<Set<String>> resolveHashes() async {
    final assetHashes = <String>{};
    final assets = [...releaseJson!['assets']];

    final someAssetHasArm64v8a =
        assets.any((a) => _getNameFromAsset(a).contains('arm64-v8a'));

    for (final r in assetRegexps) {
      final matchedAssets = assets.where((a) {
        final name = _getNameFromAsset(a);
        if (a['content_type'] == kAndroidMimeType && someAssetHasArm64v8a) {
          // On Android, Zapstore only supports arm64-v8a
          // If the developer uses "arm64-v8a" in any filename then assume
          // they publish split ABIs, so we discard non-arm64-v8a ones.
          // This is done to minimize the amount of universal builds
          // we don't want (as in the UI they would show up as variants,
          // but also to prevent downloading useless APKs).
          return name.contains('arm64-v8a') && r.hasMatch(name);
        }
        return r.hasMatch(name);
      });

      if (matchedAssets.isEmpty) {
        final message = 'No asset matching $r';
        stderr.writeln(message);
        throw GracefullyAbortSignal();
      }

      for (final asset in matchedAssets) {
        final assetUrl = asset['browser_download_url'];

        if (!overwriteRelease) {
          final publishedAt = DateTime.tryParse(releaseJson?['published_at']);
          await checkUrl(assetUrl, resolvedVersion!, publishedAt: publishedAt);
        }

        final assetSpinner = CliSpin(
          text: 'Fetching asset $assetUrl...',
          spinner: CliSpinners.dots,
          isSilent: isDaemonMode,
        ).start();

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

    return super.applyFileMetadata();
  }

  String _getNameFromAsset(Map m) {
    if (m.containsKey('label') && m['label'].toString().isNotEmpty) {
      return m['label'].toString();
    }
    return m['name']!.toString();
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
