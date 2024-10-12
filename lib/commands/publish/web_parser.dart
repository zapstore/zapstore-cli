import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
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
          parseHtmlDocument(response.body).querySelector(selector.toString());
      if (elem != null) {
        final raw =
            attribute.isEmpty ? elem.text! : elem.attributes[attribute]!;
        match = regexpFromKey(rest.first).firstMatch(raw);
      }
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

    final appIdWithVersion = app.identifierWithVersion(version);

    if (!overwriteRelease) {
      await checkReleaseOnRelay(
          relay: relay, appIdWithVersion: appIdWithVersion);
    }

    final packageUrl = artifacts!.keys.first.replaceAll('\$v', version);
    packageSpinner.text = 'Fetching package $packageUrl...';

    final tempArtifactPath =
        await fetchFile(packageUrl, spinner: packageSpinner);
    final (artifactHash, newArtifactPath, _) =
        await renameToHash(tempArtifactPath);
    final size = await runInShell('wc -c < $newArtifactPath');

    final fileMetadata = FileMetadata(
      content: appIdWithVersion,
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
      identifier: appIdWithVersion,
      url: endpoint,
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    return (app, release, {fileMetadata});
  }
}
