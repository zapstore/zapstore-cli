import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:universal_html/parsing.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/local_parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';

class WebParser extends RepositoryParser {
  final RelayMessageNotifier relay;

  WebParser({required this.relay});

  @override
  Future<(App, Release?, Set<FileMetadata>)> process({
    required App app,
    required bool overwriteRelease,
    String? releaseRepository,
    Map<String, dynamic>? artifacts,
    String? artifactContentType,
    YamlList? versionSpec,
  }) async {
    final packageSpinner = CliSpin(
      text: 'Fetching package...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    final [endpoint, selector, attribute, ...rest] = versionSpec!;
    final response = await http.get(Uri.parse(endpoint));

    late final RegExpMatch? match;
    if (rest.isEmpty) {
      // If versionSpec has 3 positions, it's a JSON endpoint
      final raw = await runInShell(
          "echo ''${jsonEncode(response.body)}'' | jq -r $selector");
      match = regexpFromKey(attribute).firstMatch(raw);
    } else {
      // If versionSpec has 4 positions, it's an HTML endpoint
      final elem =
          parseHtmlDocument(response.body).querySelectorAll(selector).first;
      final raw = attribute.isEmpty ? elem.text! : elem.attributes[attribute]!;

      match = regexpFromKey(rest.first).firstMatch(raw);
    }

    final version = match != null
        ? (match.groupCount > 0 ? match.group(1) : match.group(0))
        : null;

    if (version == null) {
      final message = 'could not match version for $selector';
      packageSpinner.fail(message);
      if (isDaemonMode) {
        print(message);
      }
      throw GracefullyAbortSignal();
    }

    final packageUrl = artifacts!.keys.first.replaceFirst('\$v', version);

    // TODO: Extract this code to utility and reuse
    // Check if we already processed this release
    final metadataOnRelayList =
        await relay.query<FileMetadata>(search: packageUrl);

    // Search is full-text (not exact) so we double-check
    // NOTE: We can't compare `version` to the `version` tag
    // as one comes from site metadata and the other from the APK
    // so we need to use `content`, where the version is always the site's
    final metadataOnRelay = metadataOnRelayList
        .firstWhereOrNull((m) => m.content.contains(version));
    if (metadataOnRelay != null) {
      if (!overwriteRelease) {
        if (isDaemonMode) {
          print('$version OK, skip');
        }
        packageSpinner
            .success('Latest $version release already in relay, nothing to do');
        throw GracefullyAbortSignal();
      }
    }

    packageSpinner.text = 'Fetching package $packageUrl...';

    final tempArtifactPath = await fetchFile(packageUrl,
        spinner: packageSpinner, keepExtension: true);
    final (artifactHash, newArtifactPath, _) =
        await renameToHash(tempArtifactPath);
    final size = await runInShell('wc -c < $newArtifactPath');

    final fileMetadata = FileMetadata(
      content: '${app.identifier} $version',
      createdAt: DateTime.now(),
      urls: {packageUrl},
      hash: artifactHash,
      size: int.tryParse(size),
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    fileMetadata.transientData['apkPath'] = newArtifactPath;

    packageSpinner.success('Fetched package: $packageUrl');

    final release = Release(
      createdAt: DateTime.now(),
      content: 'See $endpoint',
      identifier: '${app.name}@$version',
      url: endpoint,
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, {fileMetadata});
  }
}
