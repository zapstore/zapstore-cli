import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils.dart';

Future<Set<String>> getSignatures(Archive archive) async {
  ArchiveFile? certFile;

  for (final file in archive.files) {
    if (file.isFile && file.name.startsWith('META-INF/')) {
      final filename = file.name.toUpperCase();
      if (filename.endsWith('.RSA') || filename.endsWith('.DSA')) {
        certFile = file;
        break;
      }
    }
  }

  if (certFile == null) {
    throw 'Error: No .RSA or .DSA file found in META-INF/';
  }

  final outputFile = File(path.join(Directory.systemTemp.path,
      '${path.basename(archive.hashCode.toString())}.sig'));
  outputFile.writeAsBytesSync(certFile.content);
  final result = await runInShell(
      'openssl pkcs7 -in ${outputFile.absolute.path} -inform DER -print_certs | openssl x509 -fingerprint -sha256 -noout');
  return result.split('\n').map((l) {
    final [_, hash] = l.split('=');
    return hash.replaceAll(':', '').toLowerCase();
  }).toSet();
}
