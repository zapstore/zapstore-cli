import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:html/parser.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';

class WebParser extends RepositoryParser {
  final RelayMessageNotifier relay;

  WebParser({required this.relay});

  @override
  Future<(App, Release, Set<FileMetadata>)> run({
    required App app,
    required bool overwriteApp,
    required bool overwriteRelease,
    String? url,
    Map<String, dynamic>? artifacts,
    String? artifactContentType,
  }) async {
    final metadataSpinner = CliSpin(
      text: 'Fetching metadata...',
      spinner: CliSpinners.dots,
    ).start();
    String? version;
    final response = await http.get(Uri.parse(url!));
    if (response.headers['content-type'] == 'application/json') {
      version = jsonDecode(response.body)['versionName'];
    } else {
      version = parse(response.body).querySelector('h3.title')?.text;
    }

    if (version == null) {
      throw 'failed getting version';
    }

    metadataSpinner.success('Fetched metadata from $url');
    print('got version $version');

    final fileMetadata = FileMetadata();

    final filePath = await fetchFile(
        'https://updates.signal.org/android/Signal-Android-website-prod-universal-release-$version.apk');
    print(filePath);

    // final fileMetadatas = <FileMetadata>{};
    // for (var MapEntry(key: regexpKey, :value) in artifacts!.entries) {
    //   regexpKey = regexpKey.replaceAll('%v', r'(\d+\.\d+(\.\d+)?)');
    //   final r = RegExp(regexpKey);
    //   final asset = assets.firstWhereOrNull((a) => r.hasMatch(a['name']));

    //   if (asset == null) {
    //     throw 'No asset matching ${r.pattern}';
    //   }

    //   final packageUrl = asset['browser_download_url'];

    //   final packageSpinner = CliSpin(
    //     text: 'Fetching package: $packageUrl...',
    //     spinner: CliSpinners.dots,
    //   ).start();

    //   // Check if we already processed this release
    //   final metadataOnRelay =
    //       await relay.query<FileMetadata>(search: packageUrl);

    //   // Search is full-text (not exact) so we double-check
    //   final metadataOnRelayCheck = metadataOnRelay
    //       .firstWhereOrNull((m) => m.urls.firstOrNull == packageUrl);
    //   if (metadataOnRelayCheck != null) {
    //     if (!overwriteRelease) {
    //       packageSpinner
    //           .fail('Latest $repoName release already in relay, nothing to do');
    //       throw GracefullyAbortSignal();
    //     }
    //   }

    //   final tempPackagePath = await fetchFile(packageUrl,
    //       headers: headers, spinner: packageSpinner);

    //   final match = r.firstMatch(asset['name']);
    //   final matchedVersion = (match?.groupCount ?? 0) > 0
    //       ? r.firstMatch(asset['name'])?.group(1)
    //       : latestReleaseJson['tag_name'];

    //   // Validate platforms
    //   final platforms = {...?value['platforms'] as Iterable?};
    //   if (!platforms
    //       .every((platform) => kSupportedPlatforms.contains(platform))) {
    //     throw 'Artifact ${asset['name']} has platforms $platforms but some are not in $kSupportedPlatforms';
    //   }

    //   final (fileHash, filePath, _) = await renameToHash(tempPackagePath);
    //   final size = await runInShell('wc -c < $filePath');
    //   final fileMetadata = FileMetadata(
    //       content: '${app.name} ${latestReleaseJson['tag_name']}',
    //       createdAt: DateTime.tryParse(latestReleaseJson['created_at']),
    //       urls: {packageUrl},
    //       mimeType: asset['content_type'],
    //       hash: fileHash,
    //       size: int.tryParse(size),
    //       platforms: platforms.toSet().cast(),
    //       version: latestReleaseJson['tag_name'],
    //       pubkeys: app.pubkeys,
    //       zapTags: app.zapTags,
    //       additionalEventTags: {
    //         for (final b in (value['executables'] ?? []))
    //           (
    //             'executable',
    //             matchedVersion != null
    //                 ? b.toString().replaceFirst('%v', matchedVersion)
    //                 : b
    //           ),
    //       });
    //   fileMetadata.transientData['apkPath'] = filePath;
    //   fileMetadatas.add(fileMetadata);
    //   packageSpinner.success('Fetched package: $packageUrl');
    // }

    final release = Release(
      createdAt: DateTime.now(),
      content: 'parsed from $url',
      identifier: '${app.name}@$version',
      url: url,
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, {fileMetadata});
  }
}

abstract class RepositoryParser {
  Future<(App, Release, Set<FileMetadata>)> run({
    required App app,
    required bool overwriteApp,
    required bool overwriteRelease,
  });
}
