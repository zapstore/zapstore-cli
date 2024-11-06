import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:purplebase/purplebase.dart';
import 'package:universal_html/parsing.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/local_parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
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
    final artifactSpinner = CliSpin(
      text: 'Fetching artifact...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    final [endpoint, selector, attribute, ...rest] = versionSpec!;
    final request = http.Request('GET', Uri.parse(endpoint))
      ..followRedirects = false;

    final response = await http.Client().send(request);

    RegExpMatch? match;
    if (rest.isEmpty) {
      // If versionSpec has 3 positions, it's a: JSON endpoint (HTTP 2xx) or headers (HTTP 3xx)
      if (response.isRedirect) {
        final raw = response.headers[selector]!;
        match = regexpFromKey(attribute).firstMatch(raw);
      } else {
        final body = await response.stream.bytesToString();
        final file = File(path.join(
            Directory.systemTemp.path, path.basename(app.hashCode.toString())));
        await file.writeAsString(body);
        final raw = await runInShell("cat ${file.path} | jq -r '$selector'");
        match = regexpFromKey(attribute).firstMatch(raw);
      }
    } else {
      // If versionSpec has 4 positions, it's an HTML endpoint
      final body = await response.stream.bytesToString();
      final elem = parseHtmlDocument(body).querySelector(selector.toString());
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
      artifactSpinner.fail(message);
      if (isDaemonMode) {
        print(message);
      }
      throw GracefullyAbortSignal();
    }

    final artifactUrl = artifacts!.keys.first.replaceAll('\$v', version);

    if (!overwriteRelease) {
      await checkReleaseOnRelay(
        relay: relay,
        version: version,
        artifactUrl: artifactUrl,
        spinner: artifactSpinner,
      );
    }

    artifactSpinner.text = 'Fetching artifact $artifactUrl...';

    final tempArtifactPath =
        await fetchFile(artifactUrl, spinner: artifactSpinner);
    final (artifactHash, newArtifactPath, _) =
        await renameToHash(tempArtifactPath);
    final size = await runInShell('wc -c < $newArtifactPath');
    final appIdWithVersion = app.identifierWithVersion(version);

    final fileMetadata = FileMetadata(
      content: appIdWithVersion,
      createdAt: DateTime.now(),
      urls: {artifactUrl},
      hash: artifactHash,
      size: int.tryParse(size),
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    fileMetadata.transientData['apkPath'] = newArtifactPath;

    artifactSpinner.success('Fetched artifact: $artifactUrl');

    final release = Release(
      createdAt: DateTime.now(),
      content: 'See $endpoint',
      identifier: appIdWithVersion,
      url: endpoint,
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    if (appIdWithVersion == null) {
      release.transientData['releaseVersion'] = version;
    }

    return (app, release, {fileMetadata});
  }
}
