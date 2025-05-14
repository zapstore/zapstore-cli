import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils.dart';

class WebParser extends AssetParser {
  WebParser(super.appMap) : super(areFilesLocal: false);

  @override
  Future<Set<String>> resolveHashes() async {
    final assetHashes = <String>{};

    // Web parser cannot continue without a version
    if (resolvedVersion == null) {
      final message = 'Could not match version for ${appMap['version']}';
      if (isDaemonMode) {
        print(message);
        throw GracefullyAbortSignal();
      }
      throw message;
    }

    for (final key in appMap['assets']) {
      final assetUrl = key.toString().replaceAll('\$version', resolvedVersion!);

      // if (!overwriteRelease) {
      //   await checkReleaseOnRelay(
      //     version: version,
      //     assetUrl: assetUrl,
      //   );
      // }

      final assetSpinner = CliSpin(
        text: 'Fetching asset $assetUrl...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();
      final assetHash = await fetchFile(assetUrl, spinner: assetSpinner);
      assetHashes.add(assetHash);

      assetSpinner.success('Fetched asset: $assetUrl');
    }
    return assetHashes;
  }
}
