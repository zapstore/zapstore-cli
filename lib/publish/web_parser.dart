import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:json_path/json_path.dart';
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/publish/parser.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';

class WebParser extends AssetParser {
  WebParser(super.appMap);

  @override
  Future<String?> resolveReleaseVersion() async {
    String? version;

    if (appMap['version'] is List) {
      final versionSpec = appMap['version'] as List;

      final versionSpinner = CliSpin(
        text: 'Resolving version from spec...',
        spinner: CliSpinners.dots,
        isSilent: isIndexerMode,
      ).start();

      final [endpoint, selector, attribute, ...rest] = versionSpec;

      RegExpMatch? match;
      if (rest.isEmpty) {
        // If versionSpec has 3 positions, it's a: JSON endpoint (HTTP 2xx) or headers (HTTP 3xx)
        // Do not follow redirect
        final request = http.Request('GET', Uri.parse(endpoint))
          ..followRedirects = false;
        final response = await http.Client().send(request);
        if (response.isRedirect) {
          final raw = response.headers[selector]!;
          match = RegExp(attribute).firstMatch(raw);
        } else {
          final body = await response.stream.bytesToString();
          final jsonMatch = JsonPath(
            selector,
          ).read(jsonDecode(body)).firstOrNull?.value;
          if (jsonMatch != null) {
            match = RegExp(attribute).firstMatch(jsonMatch.toString());
          }
        }
      } else {
        // If versionSpec has 4 positions, it's an HTML endpoint
        // Do follow redirect
        final request = http.Request('GET', Uri.parse(endpoint))
          ..followRedirects = true;
        final response = await http.Client().send(request);
        final body = await response.stream.bytesToString();
        final elem = parseHtmlDocument(body).querySelector(selector.toString());
        if (elem != null) {
          final raw = attribute.isEmpty
              ? elem.text!
              : elem.attributes[attribute]!;
          match = RegExp(rest.first).firstMatch(raw);
        }
      }

      version = match != null
          ? (match.groupCount > 0 ? match.group(1) : match.group(0))
          : null;
      if (version != null) {
        versionSpinner.success('Resolved version: $version');
      } else {
        versionSpinner.fail('Could not resolve version');
      }
    }

    if (!overwriteRelease) {
      // If it does not have a $version do not bother checking
      final r = _getFirstAssetWithVersion(version!);
      if (r != null) {
        await checkUrl(r, version);
      }
    }

    return version;
  }

  @override
  Future<Set<String>> resolveAssetHashes() async {
    final assetHashes = <String>{};

    // Web parser cannot continue without a version
    if (releaseVersion == null) {
      throw 'Could not match version with spec: ${appMap['version']}';
    }

    for (final key in appMap['assets']) {
      final assetUrl = key.toString().replaceAll('\$version', releaseVersion!);

      final assetSpinner = CliSpin(
        text: 'Fetching asset $assetUrl...',
        spinner: CliSpinners.dots,
        isSilent: isIndexerMode,
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

  @override
  Future<void> applyFileMetadata({String? defaultAppName}) {
    partialRelease.url = appMap['version']?[0];

    return super.applyFileMetadata();
  }

  String? _getFirstAssetWithVersion(String version) {
    final firstAssetUrl = (appMap['assets'] as List).first.toString();
    if (firstAssetUrl.contains('\$version')) {
      return firstAssetUrl.replaceAll('\$version', version);
    }
    return null;
  }
}
