import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/utils.dart';

class BlossomClient {
  final Set<String> servers;

  BlossomClient({this.servers = const {}});

  Future<void> uploadMany(Set<BlossomAuthorization> authorizations) async {
    for (final a in authorizations) {
      final artifactHash = a.hashes.first;

      final uploadSpinner = CliSpin(
        text: 'Uploading artifact: $artifactHash...',
        spinner: CliSpinners.dots,
      ).start();

      String artifactUrl = '';
      try {
        artifactUrl = await upload(a, spinner: uploadSpinner);
        uploadSpinner.success('Uploaded artifact to $artifactUrl');
      } catch (e) {
        uploadSpinner.fail(e.toString());
        rethrow;
      }
    }
  }

  Future<String> upload(BlossomAuthorization authorization,
      {CliSpin? spinner}) async {
    // TODO: Use all servers
    final artifactUrl = '${servers.first}/${authorization.hashes.first}';
    final artifactHash = authorization.hashes.first;
    final headResponse = await http.head(Uri.parse(artifactUrl));

    if (headResponse.statusCode != 200) {
      final bytes =
          await File(getFilePathInTempDirectory(artifactHash)).readAsBytes();
      final response = await http.put(
        Uri.parse('${servers.first}/upload'),
        body: bytes,
        headers: {
          'Content-Type': authorization.mimeType!,
          'Authorization': 'Nostr ${authorization.toBase64()}',
        },
      );

      // Returns a Blossom blob descriptor
      final responseMap = Map<String, dynamic>.from(jsonDecode(response.body));

      if (response.statusCode != 200 || artifactHash != responseMap['sha256']) {
        throw 'Error uploading: status code ${response.statusCode}, hash: $artifactHash, server hash: ${responseMap['sha256']}; $responseMap';
      }
    }
    return artifactUrl;
  }
}
