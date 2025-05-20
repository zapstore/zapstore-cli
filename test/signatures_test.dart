import 'dart:io';

import 'package:test/test.dart';
import 'package:zapstore_cli/parser/signature_parser.dart';
import 'package:zapstore_cli/publish/parser_utils.dart';

void main() {
  final apkPaths = Map<String, String?>.fromEntries(
      Directory('test/assets/apks')
          .listSync()
          .whereType<File>()
          .map((f) => MapEntry(f.path, null)));

  test('certs test', () async {
    for (final apkPath in apkPaths.keys) {
      apkPaths[apkPath] = await getSignatureHashFromApkSigner(apkPath);
    }

    for (final e in apkPaths.entries) {
      final hashes = await getSignatureHashes(e.key);
      expect(hashes, contains(e.value));
    }
  });
}
