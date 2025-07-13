import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

class BlossomClient {
  final Uri server;

  BlossomClient(String server) : server = Uri.parse(server) {
    if (!this.server.scheme.startsWith('http')) {
      throw UsageException('Invalid Blossom server URL: $server', '');
    }
  }

  // Generate Blossom authorizations (icons, images hold hashes until here)
  Future<Set<PartialBlossomAuthorization>> generateAuthorizations(
    List<String> assetHashes,
  ) async {
    if (assetHashes.isEmpty) return {};
    final Set<PartialBlossomAuthorization> result = {};

    // Filter out remote URLs
    assetHashes = assetHashes
        .where((hash) => hashPathMap[hash]?.isHttpUri ?? false)
        .toList();

    if (assetHashes.isEmpty) return {};

    final spinner = CliSpin(
      text: 'Checking existing assets...',
      spinner: CliSpinners.dots,
      isSilent: isDaemonMode,
    ).start();

    int i = 0;

    for (final assetHash in assetHashes) {
      final originalFilePath = hashPathMap[assetHash]!;
      i++;
      spinner.text =
          'Checking existing asset ($i/${assetHashes.length}): $originalFilePath';
      final exists = await existsInBlossomServer(assetHash);
      if (!exists) {
        final (mimeType, _, _) = await detectMimeTypes(
          getFilePathInTempDirectory(assetHash),
        );
        final auth = PartialBlossomAuthorization()
          ..content = 'Upload asset $originalFilePath'
          ..type = BlossomAuthorizationType.upload
          ..mimeType = mimeType
          ..expiration = DateTime.now().add(Duration(hours: 1))
          ..hash = assetHash;

        result.add(auth);
      }
    }
    spinner.success('Checked for existing assets ($i/${assetHashes.length})');
    return result;
  }

  Future<bool> existsInBlossomServer(String assetHash) async {
    return http.head(Uri.parse('$server/$assetHash')).then((response) {
      return response.statusCode == 200;
    });
  }

  Future<Map<String, String>> upload(
    List<BlossomAuthorization> authorizations,
  ) async {
    final hashUrlMap = <String, String>{};

    for (final authorization in authorizations) {
      final assetHash = authorization.hash;

      final assetUploadUrl = '$server/$assetHash';
      final assetName = hashPathMap[assetHash];

      // TODO: Show upload %
      final uploadSpinner = CliSpin(
        text: 'Uploading $assetName ($assetHash)...',
        spinner: CliSpinners.dots,
        isSilent: isDaemonMode,
      ).start();

      final headResponse = await http.head(Uri.parse(assetUploadUrl));

      if (headResponse.statusCode == 200) {
        uploadSpinner.success('File $assetName already exists at $server');
      } else {
        final bytes = await File(
          getFilePathInTempDirectory(assetHash),
        ).readAsBytes();
        final response = await http.put(
          Uri.parse(path.join(server.toString(), 'upload')),
          body: bytes,
          headers: {
            if (authorization.mimeType != null)
              'Content-Type': authorization.mimeType!,
            'Authorization': 'Nostr ${authorization.toBase64()}',
          },
        );

        if (response.statusCode == 200) {
          // Returns a Blossom blob descriptor
          final responseMap = Map<String, dynamic>.from(
            jsonDecode(response.body),
          );
          if (assetHash != responseMap['sha256']) {
            throw 'Hash mismatch for $assetName despite successful upload: local hash: $assetHash, server hash: ${responseMap['sha256']}';
          }
          hashUrlMap[assetHash] = responseMap['url'];
          uploadSpinner.success('Uploaded $assetName to ${responseMap['url']}');
        } else {
          switch (response.statusCode) {
            case HttpStatus.unauthorized:
              uploadSpinner.fail(
                'You are unauthorized to upload $assetName to $server',
              );
              throw GracefullyAbortSignal();
            case HttpStatus.unsupportedMediaType:
              uploadSpinner.fail(
                'Media type (${authorization.mimeType}) for $assetName is unsupported by $server',
              );
              throw GracefullyAbortSignal();
            default:
              throw 'Error uploading $assetName to $server: status code ${response.statusCode}, hash: $assetHash';
          }
        }
      }
    }

    return hashUrlMap;
  }
}
