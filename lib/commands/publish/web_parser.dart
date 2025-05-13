import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/parser/magic.dart';
import 'package:zapstore_cli/utils.dart';

class WebParser extends AssetParser {
  WebParser(super.appMap) : super(areFilesLocal: false);

  @override
  Future<void> findHashes() async {
    if (resolvedVersion == null) {
      throw 'No version bro!';
    }

    partialRelease.identifier = '';
    partialRelease.version = resolvedVersion;

    for (final key in appMap['assets']) {
      final asset = key.toString().replaceAll('\$version', resolvedVersion!);
      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     assetUrl: assetUrl,
      //   );
      // }

      // TODO: Make spinner and pass to fetchFile
      print('Fetching $asset');
      final assetHash = await fetchFile(asset);

      final fm = PartialFileMetadata();
      fm.hash = assetHash;
      fm.mimeType = detectFileType(getFilePathInTempDirectory(assetHash));
      fm.url = key;

      assetHashes.add(assetHash);

      partialFileMetadatas.add(fm);
    }

    return super.applyMetadata();
  }
}
