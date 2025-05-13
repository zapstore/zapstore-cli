import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/parser/magic.dart';
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
      final artifact = key.toString().replaceAll('\$version', resolvedVersion!);
      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     artifactUrl: artifactUrl,
      //     // spinner: artifactSpinner,
      //   );
      // }

      // artifactSpinner.text = 'Fetching artifact $artifactUrl...';
      print('Fetching $artifact');

      final artifactHash = await fetchFile(
        artifact,
        // spinner: artifactSpinner,
      );

      final fm = PartialFileMetadata();
      fm.hash = artifactHash;
      fm.mimeType = detectFileType(getFilePathInTempDirectory(artifactHash));
      fm.url = key;

      artifactHashes.add(artifactHash);

      partialFileMetadatas.add(fm);
    }

    return super.applyMetadata();
  }
}
