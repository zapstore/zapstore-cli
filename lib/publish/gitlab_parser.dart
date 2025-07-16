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

class GitlabParser extends AssetParser {
  GitlabParser(super.appMap) {
    remoteMetadata ??= {'gitlab'};
  }

  Map<String, dynamic>? releaseJson;

  static String getRepositoryName(String repository) =>
      Uri.encodeComponent(Uri.parse(repository).path.substring(1));

  late final Set<RegExp> assetRegexps;
  late final String repositoryName;

  @override
  Future<String?> resolveReleaseVersion() async {
    final metadataSpinner = CliSpin(
      text: 'Fetching release from Gitlab...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    assetRegexps =
        (appMap.containsKey('assets') ? <String>{...appMap['assets']} : {'.*'})
            .map(RegExp.new)
            .toSet();
    repositoryName = getRepositoryName(
      appMap['release_repository'] ?? appMap['repository']!,
    );

    final latestReleaseUrl =
        'https://gitlab.com/api/v4/projects/$repositoryName/releases/permalink/latest';

    releaseJson = await http.get(Uri.parse(latestReleaseUrl)).getJson();

    final version = releaseJson!['tag_name']!.toString();

    metadataSpinner.success('Fetched release ${version.bold()} from Gitlab');

    if (!overwriteRelease) {
      final publishedAt = DateTime.tryParse(releaseJson!['released_at']);
      await checkUrl(
        releaseJson!['_links']['self'],
        version,
        publishedAt: publishedAt,
      );
    }

    return version;
  }

  @override
  Future<Set<String>> resolveAssetHashes() async {
    final assetHashes = <String>{};
    final assets =
        <String, dynamic>{...releaseJson!['assets']}['links'] as Iterable;

    final someAssetHasArm64v8a = assets.any(
      (a) => a['name'].contains('arm64-v8a'),
    );

    for (final r in assetRegexps) {
      final matchedAssets = assets.where((a) {
        if (a['url'].toString().endsWith('.apk') && someAssetHasArm64v8a) {
          // On Android, Zapstore only supports arm64-v8a
          // If the developer uses "arm64-v8a" in any filename then assume
          // they publish split ABIs, so we discard non-arm64-v8a ones.
          // This is done to minimize the amount of universal builds
          // we don't want (as in the UI they would show up as variants,
          // but also to prevent downloading useless APKs).
          return a['name'].contains('arm64-v8a') && r.hasMatch(a['name']);
        }
        return r.hasMatch(a['name']);
      });

      if (matchedAssets.isEmpty) {
        final message = 'No asset matching $r';
        stderr.writeln(message);
        throw GracefullyAbortSignal();
      }

      for (final asset in matchedAssets) {
        final assetUrl = asset['direct_asset_url'] ?? asset['url'];

        final assetSpinner = CliSpin(
          text: 'Fetching asset $assetUrl...',
          spinner: CliSpinners.dots,
          isSilent: isDaemonMode,
        ).start();

        final fileHash = await fetchFile(assetUrl, spinner: assetSpinner);
        final filePath = getFilePathInTempDirectory(fileHash);
        if (await acceptAssetMimeType(filePath)) {
          assetHashes.add(fileHash);
        }

        assetSpinner.success('Fetched asset: $assetUrl');
      }
    }
    return assetHashes;
  }

  @override
  Future<void> applyFileMetadata({String? defaultAppName}) async {
    partialRelease.releaseNotes ??= releaseJson?['description'];

    partialRelease.event.createdAt =
        DateTime.tryParse(releaseJson?['released_at']) ?? DateTime.now();

    partialRelease.url = releaseJson?['_links']?['self'];
    // Add an r (queryable) tag, regardless of NIP format
    partialRelease.event.setTagValue('r', partialRelease.url);

    partialRelease.commitId = releaseJson?['commit']?['id'];

    await super.applyFileMetadata(
      defaultAppName: repositoryName.split('%2F').lastOrNull,
    );
  }
}
