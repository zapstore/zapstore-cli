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
  final Set<String> versions;
  final Set<String> executables;
  String? enabledVersion;

  Package(
      {required this.identifier,
      required this.pubkey,
      this.versions = const {},
      this.executables = const {},
      required this.enabledVersion});

  factory Package.fromString(
      String key, Set<String> lines, Map<String, String> links) {
    final pubkey = key.substring(0, 64);
    final name = key.substring(65);
    final executables = <String>{};
    String? enabledVersion;
    final versions = lines.map((line) {
      final [_, version, executable] = line.substring(65).split('/');
      if (links[executable] == line) {
        executables.add(executable);
        enabledVersion ??= version;
      }
      return version;
    }).toSet();
    return Package(
        identifier: name,
        pubkey: pubkey,
        versions: versions,
        executables: executables,
        enabledVersion: enabledVersion);
  }

  Directory get directory =>
      Directory(path.join(kBaseDir, '$pubkey-$identifier'));

  Future<void> installRemote(FileMetadata metadata, {CliSpin? spinner}) async {
    final fileHash = await fetchFile(metadata.urls.first, spinner: spinner);
    final versionPath = path.join(directory.path, metadata.version);

    await Directory(versionPath).create(recursive: true);

    if (fileHash != metadata.hash) {
      throw 'Hash mismatch! $fileHash != ${metadata.hash}\nFile server may be compromised.';
    }

    final downloadPath = getFilePathInTempDirectory(fileHash);

    // Auto-extract
    if (kArchiveMimeTypes.contains(metadata.mimeType)) {
      final extractDir = getFilePathInTempDirectory(
          '${path.basenameWithoutExtension(downloadPath)}.tmp');

      await deleteRecursive(extractDir);
      await Directory(extractDir).create(recursive: true);

      // Extract compressed file
      final bytes = await File(downloadPath).readAsBytes();
      final (mimeType, _, _) = await detectBytesMimeType(bytes);
      final archive = getArchive(bytes, mimeType!);
      await writeArchiveToDisk(archive);

      for (final executablePath in metadata.executables) {
        await installExecutable(
            path.join(extractDir, executablePath),
            path.join(
              versionPath,
              path.basename(executablePath),
            ));
      }
      await deleteRecursive(extractDir);
      await deleteRecursive(downloadPath);
    } else {
      final binaryPath = path.join(versionPath, identifier);
      await installExecutable(downloadPath, binaryPath);
    }
  }

  Future<void> installExecutable(String srcPath, String destPath) async {
    await File(srcPath).rename(destPath);
    final target = path.relative(destPath, from: kBaseDir);
    final link = Link(path.join(kBaseDir, path.basename(target)));
    await link.delete();
    await link.create(target);
  }

  Future<void> remove() async {
    for (final e in [...executables, directory.path]) {
      await deleteRecursive(path.join(kBaseDir, e));
    }
  }

  Future<void> linkVersion(String version) async {
    final p = path.join('$pubkey-$identifier', version, identifier);
    await Link(identifier).create(p, recursive: true);
    enabledVersion = version;
  }

  @override
  String toString() {
    return '$identifier {versions: $versions binaries: $executables}';
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

    final links = await _listLinks(kBaseDir);

    final executablePaths = _listFilesAtDepth(Directory(kBaseDir), 1)
        .map((e) => path.relative(e, from: kBaseDir))
        .where((e) => startsWithHexRegexp.hasMatch(e));

    final db = <String, Package>{};
    final groupedExecutablePaths =
        executablePaths.groupSetsBy((e) => e.split('/').first);

    for (final e in groupedExecutablePaths.entries) {
      final package = Package.fromString(e.key, e.value, links);
      db[package.identifier] = package;
    }

    // If zapstore not in db, auto-install/update
    final kZapstoreId = 'zapstore';
    if (db[kZapstoreId] == null ||
        db[kZapstoreId]!.enabledVersion == null ||
        (db[kZapstoreId]!.enabledVersion != null &&
            canUpgrade(db[kZapstoreId]!.enabledVersion!, kVersion))) {
      final zapstorePackage = Package(
          identifier: kZapstoreId,
          pubkey: kZapstorePubkey,
          versions: {kVersion},
          executables: {kZapstoreId},
          enabledVersion: kVersion);

      final filePath = Platform.script.toFilePath();
      final hash = await copyToHash(filePath);

      final versionPath = path.join(zapstorePackage.directory.path, kVersion);
      final binaryPath = path.join(versionPath, kZapstoreId);
      await zapstorePackage.installExecutable(
          getFilePathInTempDirectory(hash), binaryPath);
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

Iterable<String> _listFilesAtDepth(Directory dir, int depth) sync* {
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is Directory) {
      yield* _listFilesAtDepth(entity, depth + 1);
    } else if (entity is File && depth == 3) {
      yield entity.path;
    }
  }
}
