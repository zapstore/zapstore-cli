import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:html/parser.dart';
import 'package:purplebase/purplebase.dart';
import 'package:yaml/yaml.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/commands/publish/local_parser.dart';
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
    final metadataSpinner = CliSpin(
      text: 'Fetching metadata...',
      spinner: CliSpinners.dots,
    ).start();

    final [endpoint, selector, attribute, ...rest] = versionSpec!;
    final response = await http.get(Uri.parse(endpoint));

    late final String? version;
    if (rest.isEmpty) {
      // If versionSpec has 3 positions, it's a JSON endpoint
      final raw = jsonDecode(response.body)[selector].toString();
      final match = regexpFromKey(attribute).firstMatch(raw);
      version = match?.group(1) ?? match?.group(0);
    } else {
      // If versionSpec has 4 positions, it's an HTML endpoint
      final elem = parse(response.body).querySelectorAll(selector).first;
      final raw = attribute.isEmpty ? elem.text : elem.attributes[attribute]!;

      final match = regexpFromKey(rest.first).firstMatch(raw);
      version = match?.group(1) ?? match?.group(0);
    }

    if (version == null) {
      throw 'could not match version for $selector';
    }

    metadataSpinner.success('Fetched metadata from $version');

    final artifactUrl = artifacts!.keys.first.replaceFirst('\$v', version);

    final downloadSpinner = CliSpin(
      text: 'Downloading $artifactUrl...',
      spinner: CliSpinners.dots,
    ).start();

    final tempArtifactPath =
        await fetchFile(artifactUrl, spinner: downloadSpinner);
    final (artifactHash, newArtifactPath, _) =
        await renameToHash(tempArtifactPath);
    final size = await runInShell('wc -c < $newArtifactPath');

    final fileMetadata = FileMetadata(
      createdAt: DateTime.now(),
      urls: {artifactUrl},
      hash: artifactHash,
      size: int.tryParse(size),
      pubkeys: app.pubkeys,
      zapTags: app.zapTags,
    );

    fileMetadata.transientData['apkPath'] = newArtifactPath;

    downloadSpinner.success('Downloaded artifact');

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
