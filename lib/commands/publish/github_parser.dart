import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';

class GithubParser extends ArtifactParser {
  GithubParser(super.appMap, super.os);

  String get repositoryName =>
      Uri.parse(releaseRepository ?? sourceRepository!).path.substring(1);

  Map<String, String> get headers => env['GITHUB_TOKEN'] != null
      ? {'Authorization': 'Bearer ${env['GITHUB_TOKEN']}'}
      : <String, String>{};

  Future<(App, Release?, Set<FileMetadata>)> process({
    required YamlMap appMap,
  }) async {
    final metadataSpinner = CliSpin(
      text: 'Fetching metadata...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    final latestReleaseUrl =
        'https://api.github.com/repos/$repositoryName/releases/latest';
    Map<String, dynamic>? latestReleaseJson =
        await http.get(Uri.parse(latestReleaseUrl), headers: headers).getJson();

    // If there's a message it's an error (or no matching assets were found)
    final artifacts = appMap['artifacts'] as YamlMap?;
    if (latestReleaseJson['message'] != null ||
        !(latestReleaseJson['assets'] as Iterable)
            .any((a) => artifacts!.entries.any((e) {
                  final r = regexpFromKey(e.key);
                  return r.hasMatch(a['name']) ||
                      (a['label'] != null && r.hasMatch(a['label']));
                }))) {
      final response = await http.get(
          Uri.parse('https://api.github.com/repos/$repositoryName/releases'),
          headers: headers);
      final releases = jsonDecode(response.body);

      if (releases is Map && releases['message'] != null) {
        throw 'Error ${releases['message']} for $repositoryName, I\'m done here';
      }
      releases as Iterable;
      if (releases.isEmpty) {
        throw 'No releases available';
      }

      latestReleaseJson = _findRelease(releases, artifacts!);
    }

    if (latestReleaseJson == null ||
        (latestReleaseJson['assets'] as Iterable).isEmpty) {
      final message = 'No packages in $repositoryName, I\'m done here';
      if (isDaemonMode) {
        print(message);
      }
      metadataSpinner.fail(message);
      throw GracefullyAbortSignal();
    }

    metadataSpinner.success('Fetched metadata from Github');

    final version = latestReleaseJson['tag_name']!.toString();
    // // TODO: Get from  APK - what if its CLI app?
    // final appIdWithVersion =
    //     'appid@1.1.1'; // app.identifierWithVersion(version);

    final fileMetadatas = <FileMetadata>{};
    for (var MapEntry(:key, :value) in artifacts!.entries) {
      final r = regexpFromKey(key);

      final asset = (latestReleaseJson['assets'] as Iterable).firstWhereOrNull(
          (a) =>
              r.hasMatch(a['name']) ||
              (a['label'] != null && r.hasMatch(a['label'])));

      final packageSpinner = CliSpin(
        text: 'Fetching package...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

      if (asset == null) {
        final message = 'No asset matching ${r.pattern}';
        if (isDaemonMode) {
          print(message);
        }
        packageSpinner.fail(message);
        throw GracefullyAbortSignal();
      }

      final artifactUrl = asset['browser_download_url'];
      packageSpinner.text = 'Fetching package $artifactUrl...';

      if (!overwriteRelease) {
        await checkReleaseOnRelay(
          version: version,
          artifactUrl: artifactUrl,
          spinner: packageSpinner,
        );
      }

      final tempPackagePath = await fetchFile(artifactUrl,
          headers: headers, spinner: packageSpinner);

      // Validate platforms
      final platforms = {...?value['platforms'] as Iterable?};
      if (!platforms
          .every((platform) => kSupportedPlatforms.contains(platform))) {
        throw 'Package ${asset['name']} has platforms $platforms but some are not in $kSupportedPlatforms';
      }

      final match = r.firstMatch(asset['name']);

      final (fileHash, filePath, _) = await renameToHash(tempPackagePath);
      final size = await File(filePath).length();

      // Since previous check was done on URL, check again now against hash
      if (!overwriteRelease) {
        await checkReleaseOnRelay(
          version: version,
          artifactHash: fileHash,
          spinner: packageSpinner,
        );
      }

      fileMetadatas.add(fileMetadata);
      packageSpinner.success('Fetched package: $artifactUrl');
    }

    return (app, release, fileMetadatas);
  }

  @override
  Future<void> applyMetadata() async {
    //     platforms = architectures.map((a) => 'android-$a').toSet();
    // if (appMap['artifacts'].isEmpty) {
    //   appMap['artifacts'] = {
    //     artifactPath: {'platforms': platforms}
    //   };
    // }

    final fileMetadata = FileMetadata(
      // content: appIdWithVersion, // TODO:
      createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
      urls: {artifactUrl},
      mimeType: asset['content_type'],
      hash: fileHash,
      size: size,
      platforms: platforms.toSet().cast(),
      version: version,
      pubkeys: {developerPubkey}.nonNulls.toSet(),
      additionalEventTags: {
        // `executables` is the YAML array, `executable` the (multiple) tag
        for (final e in (value['executables'] ?? []))
          ('executable', replaceInExecutable(e, match)),
      },
    );

    return super.applyMetadata();
  }

  @override
  Future<void> applyRemoteMetadata() async {
    final repoUrl = 'https://api.github.com/repos/$repositoryName';
    final repoJson =
        await http.get(Uri.parse(repoUrl), headers: headers).getJson();

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

    final release = Release(
      createdAt: fileMetadatas.first.createdAt,
      // content: latestReleaseJson['body'],
      identifier: fileMetadatas.first.content,
      // url: latestReleaseJson['html_url'],
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return super.applyRemoteMetadata();
  }
}

Map<String, dynamic>? _findRelease(Iterable releases, YamlMap artifacts) {
  for (final r in releases) {
    for (final asset in r['assets']) {
      for (final e in artifacts.entries) {
        if (regexpFromKey(e.key).hasMatch(asset['name'])) {
          return r;
        }
      }
    }
  }
  return null;
}
