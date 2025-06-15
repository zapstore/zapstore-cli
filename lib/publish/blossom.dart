import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

class BlossomClient {
  final Set<Uri> servers;

  BlossomClient({required Set<String> servers})
      : servers = servers.map(Uri.parse).toSet() {
    if (this.servers.any((s) => s.scheme != 'https')) {
      throw UsageException(
          'One or more invalid Blossom server URLs: $servers', '');
    }
  }

  Future<bool> needsUpload(String assetHash) async {
    for (final server in servers) {
      final assetUploadUrl = '$server/$assetHash';
      // TODO: Do this in parallel, it's too slow
      final headResponse = await http.head(Uri.parse(assetUploadUrl));
      if (headResponse.statusCode != 200) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, String>> upload(
      List<BlossomAuthorization> authorizations) async {
    final hashUrlMap = <String, String>{};

    for (final server in servers) {
      for (final authorization in authorizations) {
        final assetHash = authorization.hash;
        final assetUploadUrl = '$server/$assetHash';
        final assetName = hashPathMap[assetHash];

        // TODO: Show upload %
        final uploadSpinner = CliSpin(
          text: 'Uploading $assetName ($assetHash)...',
          spinner: CliSpinners.dots,
        ).start();

        try {
          final headResponse = await http.head(Uri.parse(assetUploadUrl));

          if (headResponse.statusCode == 200) {
            uploadSpinner.success('File $assetName already exists at $server');
          } else {
            final bytes =
                await File(getFilePathInTempDirectory(assetHash)).readAsBytes();
            var mimeType = authorization.mimeType;
            if (mimeType == null) {
              (mimeType, _, _) = await detectBytesMimeType(bytes);
            }
            final response = await http.put(
              Uri.parse('$server/upload'),
              body: bytes,
              headers: {
                'Content-Type': mimeType!,
                'Authorization': 'Nostr ${authorization.toBase64()}',
              },
            );

            if (response.statusCode == 200) {
              // Returns a Blossom blob descriptor
              final responseMap =
                  Map<String, dynamic>.from(jsonDecode(response.body));
              if (assetHash != responseMap['sha256']) {
                throw 'Hash mismatch for $assetName despite successful upload: local hash: $assetHash, server hash: ${responseMap['sha256']}';
              }
              hashUrlMap[assetHash] = responseMap['url'];
              uploadSpinner
                  .success('Uploaded $assetName to ${responseMap['url']}');
            } else {
              switch (response.statusCode) {
                case HttpStatus.unauthorized:
                  uploadSpinner.fail(
                      'You are unauthorized to upload $assetName to $server');
                  throw GracefullyAbortSignal();
                case HttpStatus.unsupportedMediaType:
                  uploadSpinner.fail(
                      'Media type ($mimeType) for $assetName is unsupported by $server');
                  throw GracefullyAbortSignal();
                default:
                  throw 'Error uploading $assetName to $server: status code ${response.statusCode}, hash: $assetHash';
              }
            }
          }
        } catch (e) {
          uploadSpinner.fail(e.toString());
          rethrow;
        }
      }
    }
    return hashUrlMap;
  }
}
