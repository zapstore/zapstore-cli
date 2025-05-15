import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:process_run/process_run.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

class Package {
  final String identifier;
  final String pubkey;
  final Set<String> versions;
  final Set<String> binaries;
  String? enabledVersion;

  Package(
      {required this.identifier,
      required this.pubkey,
      this.versions = const {},
      this.binaries = const {},
      required this.enabledVersion});

  factory Package.fromString(
      String key, Set<String> lines, Map<String, String> links) {
    final pubkey = key.substring(0, 64);
    final name = key.substring(65);
    final binaries = <String>{};
    String? enabledVersion;
    final versions = lines.map((line) {
      final [_, version, binary] = line.substring(65).split('/');
      if (links[binary] == line) {
        binaries.add(binary);
        enabledVersion ??= version;
      }
      return version;
    }).toSet();
    return Package(
        identifier: name,
        pubkey: pubkey,
        versions: versions,
        binaries: binaries,
        enabledVersion: enabledVersion);
  }

  Directory get directory =>
      Directory(path.join(kBaseDir, '$pubkey-$identifier'));

  Future<bool> skeletonExists() => directory.exists();

  Future<void> installFromUrl(FileMetadata meta, {CliSpin? spinner}) async {
    final downloadHash = await fetchFile(meta.urls.first, spinner: spinner);
    await _installFromLocal(downloadHash, meta);
  }

  Future<void> _installFromLocal(String fileHash, FileMetadata metadata,
      {bool keepCopy = false}) async {
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
      // TODO: Uncompress: 'tar zxf $downloadPath -C $extractDir'

      for (final executablePath in metadata.executables) {
        await _installBinary(
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
      await _installBinary(downloadPath, binaryPath, keepCopy: keepCopy);
    }
  }

  Future<void> _installBinary(String srcPath, String destPath,
      {bool keepCopy = false}) async {
    if (keepCopy) {
      await File(srcPath).rename(destPath);
    } else {
      await File(srcPath).copy(destPath);
    }
    final target = path.relative(destPath, from: kBaseDir);
    final linkName = path.basename(target);
    await Link(linkName).create(target, recursive: true);
  }

  Future<void> remove() async {
    for (final e in [...binaries, directory.path]) {
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
    return '$identifier versions: $versions binaries: $binaries';
  }
}

Future<Map<String, Package>> loadPackages() async {
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

// TODO: Fix and use _findLinks
  _findLinks(kBaseDir);
  final links = {
    for (final link in (await shell.run('find . -maxdepth 1 -type l')).outLines)
      link.substring(2): (await shell.run('readlink $link')).outText
  };

  final binaryFullPaths =
      (await shell.run('find . -mindepth 3 -maxdepth 3 -type f'))
          .outLines
          .map((e) => e.substring(2))
          .where((e) => hexRegexp.hasMatch(e));

  final db = <String, Package>{};
  final groupedBinaryFullPaths =
      binaryFullPaths.groupSetsBy((e) => e.split('/').first);

  for (final key in groupedBinaryFullPaths.keys) {
    final package =
        Package.fromString(key, groupedBinaryFullPaths[key]!, links);
    db[package.identifier] = package;
  }

  // If zapstore not in db, auto-install/update
  if (db['zapstore'] == null ||
      db['zapstore']!.enabledVersion == null ||
      (db['zapstore']!.enabledVersion != null &&
          !canUpgrade(db['zapstore']!.enabledVersion!, kVersion))) {
    final zapstorePackage = Package(
        identifier: 'zapstore',
        pubkey: kZapstorePubkey,
        versions: {kVersion},
        binaries: {'zapstore'},
        enabledVersion: kVersion);

    final filePath = Platform.script.toFilePath();
    final hash = await computeHash(filePath);
    await zapstorePackage._installFromLocal(
        filePath,
        (PartialFileMetadata()
              ..version = kVersion
              ..hash = hash)
            .dummySign(),
        keepCopy: true);
    await zapstorePackage.linkVersion(kVersion);
    // Try again with zapstore installed/updated
    print('Successfully updated zapstore to ${kVersion.bold()}!\n'.green());
    return await loadPackages();
  }

  return db;
}

Future<void> _findLinks(String dirPath) async {
  await Directory(dirPath)
      .list(recursive: false)
      .where((entity) => FileSystemEntity.isLinkSync(entity.path))
      .toList();
}
