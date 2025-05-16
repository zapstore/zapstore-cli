import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/file_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils/version_utils.dart';

class Package {
  final String identifier;
  final String pubkey;
  final String version;
  final Set<String> executables;

  Package(
      {required this.identifier,
      required this.pubkey,
      required this.version,
      this.executables = const {}});

  Directory get directory =>
      Directory(path.join(kBaseDir, '$pubkey-$identifier'));

  Future<void> installRemote(FileMetadata metadata, {CliSpin? spinner}) async {
    final fileHash = await fetchFile(metadata.urls.first, spinner: spinner);
    final versionPath = path.join(directory.path, metadata.version);

    await Directory(versionPath).create(recursive: true);

    if (fileHash != metadata.hash) {
      throw 'Hash mismatch! $fileHash != ${metadata.hash}\nFile server may be compromised.';
    }

    final filePath = getFilePathInTempDirectory(fileHash);

    // Extract compressed file
    if (kArchiveMimeTypes.contains(metadata.mimeType)) {
      final bytes = await File(filePath).readAsBytes();
      final (mimeType, _, _) = await detectBytesMimeType(bytes);
      final archive = getArchive(bytes, mimeType!);
      await writeArchiveToDisk(archive, outDir: versionPath);

      for (final executablePath in metadata.executables) {
        await linkExecutable(versionPath, executablePath);
      }
      await deleteRecursive(filePath);
    } else {
      final executablePath = path.join(versionPath, identifier);
      await File(filePath).rename(executablePath);
      await linkExecutable(versionPath, executablePath);
    }
    await removeOldVersions(version);
  }

  Future<void> linkExecutable(String versionPath, String executablePath) async {
    final link = Link(path.join(kBaseDir, path.basename(executablePath)));
    if (await link.exists()) {
      await link.delete();
    }
    await link.create(
        path.relative(path.join(versionPath, executablePath), from: kBaseDir));
    makeExecutable(link.path);
  }

  Future<void> remove() async {
    for (final e in [...executables, directory.path]) {
      await deleteRecursive(path.join(kBaseDir, e));
    }
  }

  Future<void> removeOldVersions(String newVersion) async {
    final oldDirs = (await directory.list().toList())
        .where((e) => e is Directory && path.basename(e.path) != newVersion);
    for (final dir in oldDirs) {
      await deleteRecursive(path.join(kBaseDir, dir.path));
    }
  }

  @override
  String toString() {
    return '$identifier {version: $version, executables: $executables}';
  }

  static Future<Map<String, Package>> loadAll() async {
    final dir = Directory(kBaseDir);
    final systemPath = env['PATH']!;

    if (!systemPath.contains(kBaseDir) || !await dir.exists()) {
      print('${'Welcome to zapstore!'.bold().white().onBlue()}\n');

      if (!await dir.exists()) {
        final setUp = Confirm(
          prompt:
              'This program requires creating the $kBaseDir directory. Proceed?',
        ).interact();

        if (setUp) {
          await Directory(kBaseDir).create(recursive: true);
        } else {
          print('Okay, good luck.');
          exit(0);
        }
      }

      if (!systemPath.contains(kBaseDir)) {
        print('''\n
Make sure ${kBaseDir.bold()} is in your PATH

You can run ${'echo \'export PATH="$kBaseDir:\$PATH"\' >> ~/.bashrc'.bold()} or equivalent.
This will make programs installed by zapstore available in your system.

After that, open a new shell and re-run this program.
''');
        exit(0);
      }
    }

    final db = <String, Package>{};

    final links = await _listLinks(kBaseDir);
    final groupedByPackage = links.entries
        .groupSetsBy((e) => path.split(e.value).take(2).join(path.separator));

    for (final e in groupedByPackage.entries) {
      final [pubkeyIdentifier, version] = e.key.split(path.separator);
      final pubkey = pubkeyIdentifier.substring(0, 64);
      final identifier = pubkeyIdentifier.substring(65);
      final executables = e.value.map((v) => v.key).toSet();
      final package = Package(
          identifier: identifier,
          pubkey: pubkey,
          version: version,
          executables: executables);
      db[package.identifier] = package;
    }

    // If zapstore not in db, auto-install/update
    final kZapstoreId = 'zapstore';
    if (db[kZapstoreId] == null ||
        canUpgrade(db[kZapstoreId]!.version, kVersion)) {
      final zapstorePackage = Package(
          identifier: kZapstoreId,
          pubkey: kZapstorePubkey,
          version: kVersion,
          executables: {kZapstoreId});

      final filePath = Platform.script.toFilePath();
      final hash = await copyToHash(filePath);

      final versionPath = path.join(zapstorePackage.directory.path, kVersion);
      final executablePath = path.join(versionPath, kZapstoreId);
      await File(getFilePathInTempDirectory(hash)).rename(executablePath);
      await zapstorePackage.linkExecutable(versionPath, executablePath);
      // Try again with zapstore installed/updated
      print('Successfully updated zapstore to ${kVersion.bold()}!\n'.green());
      return await loadAll();
    }
    return db;
  }
}

Future<Map<String, String>> _listLinks(String dir) async {
  final links = <String, String>{};

  for (final entity in await Directory(dir).list(followLinks: false).toList()) {
    if (entity is Link) {
      links[path.relative(entity.path, from: dir)] = await entity.target();
    }
  }
  return links;
}
