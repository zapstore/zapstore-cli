import 'package:json_path/json_path.dart';
import 'package:models/models.dart';
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils.dart';

class WebParser extends ArtifactParser {
  WebParser(super.appMap) : super(areFilesLocal: false);

  @override
  Future<void> findHashes() async {
    if (resolvedVersion == null) {
      throw 'No version bro!';
    }

    partialRelease.identifier = '';
    partialRelease.version = resolvedVersion;

    for (final key in appMap['artifacts']) {
      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     artifactUrl: artifactUrl,
      //     // spinner: artifactSpinner,
      //   );
      // }

      // artifactSpinner.text = 'Fetching artifact $artifactUrl...';
      print('Fetching $key');

      final tempArtifactPath = await fetchFile(
        key,
        // spinner: artifactSpinner,
      );
      final (artifactHash, mimeType) = await renameToHash(tempArtifactPath);

      final fm = PartialFileMetadata();
      fm.hash = artifactHash;
      fm.mimeType = mimeType;
      fm.url = key;

      artifactHashes.add(artifactHash);

      partialFileMetadatas.add(fm);
    }

    return super.applyMetadata();
  }
}
