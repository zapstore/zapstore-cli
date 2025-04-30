import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:process_run/process_run.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils.dart';

Future<Set<String>> getSignatures(String apkPath) async {
  var apksignerPath = whichSync('apksigner');
  final sdkRoot = env['ANDROID_SDK_ROOT'];

  if (apksignerPath == null) {
    if (sdkRoot == null) {
      throw '''APK parsing requires apksigner (from Android Tools) and it could not be found.
    Make sure you either have it in \$PATH or \$ANDROID_SDK_ROOT set.
    ''';
    } else {
      final f = await findFileRecursive(Directory(sdkRoot), 'apksigner');
      apksignerPath = f?.path;
    }
  }

  final rawSignatureHashes = await runInShell(
      '$apksignerPath verify --print-certs $apkPath | grep SHA-256');
  final signatureHashes = [
    for (final sh in rawSignatureHashes.trim().split('\n'))
      sh.split(':').lastOrNull?.trim()
  ].nonNulls.toSet();
  return signatureHashes;
}

Future<File?> findFileRecursive(Directory directory, String fileName) async {
  try {
    // List directory contents recursively. followLinks: false prevents potential
    // infinite loops if there are circular symbolic links.
    await for (final FileSystemEntity entity
        in directory.list(recursive: true, followLinks: false)) {
      // Check if the entity is a File and if its basename matches the target fileName.
      // Using p.basename ensures it works correctly across different platforms.
      if (entity is File && path.basename(entity.path) == fileName) {
        // File found, return it.
        return entity;
      }
    }
  } catch (e) {
    // Handle potential errors like permission issues during listing.
    print('Error searching directory ${directory.path}: $e');
    // Optionally, rethrow the error or handle it differently.
    return null; // Return null indicating search failed or was incomplete due to error.
  }

  // If the loop completes without finding the file, return null.
  return null;
}

Future<Set<String>> zgetSignatures(Archive archive) async {
  ArchiveFile? certFile;

  for (final file in archive.files) {
    if (file.isFile && file.name.startsWith('META-INF/')) {
      final filename = file.name.toUpperCase();
      if (filename.endsWith('.RSA') ||
          filename.endsWith('.DSA') ||
          filename.endsWith('.EC')) {
        certFile = file;
        break;
      }
    }
  }

  if (certFile == null) {
    throw 'Error: No certificate file found in META-INF/';
  }

  final outputFile = File(path.join(Directory.systemTemp.path,
      '${path.basename(archive.hashCode.toString())}.sig'));
  outputFile.writeAsBytesSync(certFile.content);
  //
  final result = await runInShell(
      'openssl pkcs7 -in ${outputFile.absolute.path} -inform DER -print_certs | openssl x509 -fingerprint -sha256 -noout');
  return result.split('\n').map((l) {
    final [_, hash] = l.split('=');
    return hash.replaceAll(':', '').toLowerCase();
  }).toSet();
}
