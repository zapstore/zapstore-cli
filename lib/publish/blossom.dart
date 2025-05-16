import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/utils/file_utils.dart';

class BlossomClient {
  final Set<String> servers;

  BlossomClient({this.servers = const {}});

  Future<Set<String>> upload(Set<BlossomAuthorization> authorizations) async {
    final urls = <String>{};

    for (final server in servers) {
      for (final authorization in authorizations) {
        final assetUrl = '$server/${authorization.hashes.first}';
        final assetHash = authorization.hashes.first;

        final uploadSpinner = CliSpin(
          text: 'Uploading asset: $assetHash...',
          spinner: CliSpinners.dots,
        ).start();

        try {
          final headResponse = await http.head(Uri.parse(assetUrl));

          if (headResponse.statusCode != 200) {
            final bytes =
                await File(getFilePathInTempDirectory(assetHash)).readAsBytes();
            final response = await http.put(
              Uri.parse('$server/upload'),
              body: bytes,
              headers: {
                'Content-Type': authorization.mimeType!,
                'Authorization': 'Nostr ${authorization.toBase64()}',
              },
            );

            // Returns a Blossom blob descriptor
            final responseMap =
                Map<String, dynamic>.from(jsonDecode(response.body));

            if (response.statusCode != 200 ||
                assetHash != responseMap['sha256']) {
              throw 'Error uploading: status code ${response.statusCode}, hash: $assetHash, server hash: ${responseMap['sha256']}; $responseMap';
            }
          }

          urls.add(assetUrl);
          uploadSpinner.success('Uploaded asset to $assetUrl');
        } catch (e) {
          uploadSpinner.fail(e.toString());
          rethrow;
        }
      }
    }
    return urls;
  }
}
