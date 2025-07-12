import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';

class WebParser extends AssetParser {
  WebParser(super.appMap);

  @override
  Future<Set<String>> resolveAssetHashes() async {
    final assetHashes = <String>{};

    // Web parser cannot continue without a version
    if (resolvedVersion == null) {
      throw 'Could not match version for ${appMap['version']}';
    }

    for (final key in appMap['assets']) {
      final assetUrl = key.toString().replaceAll('\$version', resolvedVersion!);

      if (!overwriteRelease) {
        await checkUrl(assetUrl, resolvedVersion!);
      }

      final assetSpinner = CliSpin(
        text: 'Fetching asset $assetUrl...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

      final assetHash = await fetchFile(assetUrl, spinner: assetSpinner);
      final assetPath = getFilePathInTempDirectory(assetHash);
      if (await acceptAssetMimeType(assetPath)) {
        assetHashes.add(assetHash);
        assetSpinner.success('Fetched asset: $assetUrl');
      } else {
        assetSpinner.fail('Asset $assetUrl rejected: Bad MIME type');
      }
    }
    return assetHashes;
  }
}
