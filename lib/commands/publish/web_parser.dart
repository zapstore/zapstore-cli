import 'dart:io';

import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';

class WebParser extends ArtifactParser {
  WebParser(super.appMap);

  @override
  Future<void> applyMetadata() async {
    String? version;
    if (appMap['version'] is List) {
      final versionSpec = appMap['version'] as List;

      final [endpoint, selector, attribute, ...rest] = versionSpec;
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
          final file = File(path.join(Directory.systemTemp.path,
              path.basename(response.hashCode.toString()))); // TODO: Use random
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

      version = match != null
          ? (match.groupCount > 0 ? match.group(1) : match.group(0))
          : null;

      if (version == null) {
        final message = 'could not match version for $selector';
        // artifactSpinner.fail(message);
        if (isDaemonMode) {
          print(message);
        }
        throw GracefullyAbortSignal();
      }
    } else if (appMap['version'] is String) {
      version = appMap['version'];
    }

    if (version == null) {
      throw 'No version bro!';
    }

    print('found web version $version');
    app.version = version;

    // Now with version, retrieve artifacts

    for (final key in appMap['artifacts']) {
      final artifactWithVersion =
          key.replaceAll('\$version', appMap['version']!);

      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     artifactUrl: artifactUrl,
      //     // spinner: artifactSpinner,
      //   );
      // }

      // artifactSpinner.text = 'Fetching artifact $artifactUrl...';

      final tempArtifactPath = await fetchFile(
        artifactWithVersion,
        // spinner: artifactSpinner,
      );
      final (artifactHash, newArtifactPath, _) =
          await renameToHash(tempArtifactPath);

      final fm = PartialFileMetadata();
      fm.path = artifactHash;
      fm.hash = newArtifactPath;
      app.artifacts.add(fm);
    }

    return super.applyMetadata();
  }
}
