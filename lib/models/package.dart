import 'dart:io';
import 'dart:math';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:process_run/process_run.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

class Package {
  final String name;
  final String pubkey;
  final Set<String> versions;
  final Set<String> binaries;
  String? enabledVersion;

  Package(
      {required this.name,
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
        name: name,
        pubkey: pubkey,
        versions: versions,
        binaries: binaries,
        enabledVersion: enabledVersion);
  }

  Directory get directory => Directory(path.join(kBaseDir, '$pubkey-$name'));

  Future<bool> skeletonExists() => directory.exists();

  Future<void> installFromUrl(FileMetadata meta, {CliSpin? spinner}) async {
    final downloadPath =
        path.join(Directory.systemTemp.path, path.basename(meta.urls.first));
    await fetchFile(meta.urls.first, File(downloadPath), spinner: spinner);
    await _installFromLocal(downloadPath, meta);
  }

  Future<void> _installFromLocal(String downloadPath, FileMetadata meta,
      {bool keepCopy = false}) async {
    final versionPath = path.join(directory.path, meta.version);
    await shell.run('mkdir -p $versionPath');

    final hash =
        await runInShell('cat $downloadPath | shasum -a 256 | head -c 64');

    if (hash != meta.hash) {
      await shell.run('rm -f $downloadPath');
      throw 'Hash mismatch! File server may be malicious, please report';
    }

    // Auto-extract
    if (['application/x-zip-compressed', 'application/zip', 'application/gzip']
        .contains(meta.mimeType)) {
      final extractDir = path.join(Directory.systemTemp.path,
          path.basenameWithoutExtension(downloadPath));

      final uncompress = meta.mimeType == 'application/gzip'
          ? 'tar zxf $downloadPath -C $extractDir'
          : 'unzip -d $extractDir $downloadPath';

      final mvs = {
        // Attempt to find declared binaries in meta, or default to package name
        for (final binaryPath in meta.tagMap['executable'] ?? {name})
          _installBinary(
              path.join(extractDir, binaryPath),
              path.join(
                versionPath,
                path.basename(binaryPath),
              ))
      }.join('\n');

      final cmd = '''
      mkdir -p $extractDir
      $uncompress
      $mvs
      rm -fr $extractDir $downloadPath
    ''';
      await shell.run(cmd);
    } else {
      final binaryPath = path.join(versionPath, name);
      final cmd = _installBinary(downloadPath, binaryPath, keepCopy: keepCopy);
      await shell.run(cmd);
    }
  }

  String _installBinary(String srcPath, String destPath,
      {bool keepCopy = false}) {
    return '''
      ${keepCopy ? 'cp' : 'mv'} $srcPath $destPath
      chmod +x $destPath
      ln -sf ${path.relative(destPath, from: kBaseDir)}
    ''';
  }

  Future<void> remove() async {
    await runInShell('rm -fr ${binaries.join(' ')} ${directory.path}',
        workingDirectory: kBaseDir);
  }

  Future<void> linkVersion(String version) async {
    await shell.run('ln -sf ${path.join('$pubkey-$name', version, name)}');
    enabledVersion = version;
  }

  @override
  String toString() {
    return '$name versions: $versions binaries: $binaries';
  }
}

Future<Map<String, Package>> loadPackages() async {
  final dir = Directory(kBaseDir);

  if (!await dir.exists()) {
    print('${'Welcome to zap.store!'.bold().white().onBlue()}\n');
    final setUp = Confirm(
      prompt:
          'This package requires creating the $kBaseDir directory. Proceed?',
    ).interact();

    if (!setUp) {
      print('Okay, fine');
      exit(0);
    }
    await run('mkdir -p $kBaseDir', verbose: false);
  }

  final systemPath = Platform.environment['PATH']!;
  if (!systemPath.contains(kBaseDir)) {
    print(
        '\nPlease run: ${'echo \'export PATH="$kBaseDir:\$PATH"\' >> ~/.bashrc'.bold()} or equivalent to add zap.store to your PATH');
    print(
        '\nAfter that, open a new shell and run this program with ${'zapstore'.white().onBlack()}');
    exit(0);
  }

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
    db[package.name] = package;
  }

  // If zapstore not in db, auto-install
  if (db['zapstore'] == null) {
    final zapstorePackage = Package(
        name: 'zapstore',
        pubkey: kZapstorePubkey,
        versions: {kVersion},
        binaries: {'zapstore'},
        enabledVersion: kVersion);

    final filePath = Platform.script.toFilePath();
    final hash = await runInShell('cat $filePath | shasum -a 256 | head -c 64');
    zapstorePackage._installFromLocal(
        filePath, FileMetadata(version: kVersion, hash: hash),
        keepCopy: true);
    zapstorePackage.linkVersion(kVersion);
    // Try again with zapstore installed
    return await loadPackages();
  }

  return db;
}

int compareVersions(String v1, String v2) {
  final v1Parts = v1
      .split('.')
      .map((e) => int.parse(e.replaceAll(RegExp(r'\D'), '')))
      .toList();
  final v2Parts = v2
      .split('.')
      .map((e) => int.parse(e.replaceAll(RegExp(r'\D'), '')))
      .toList();

  for (var i = 0; i < max(v1Parts.length, v2Parts.length); i++) {
    final v1Part = v1Parts[i];
    final v2Part = v2Parts[i];
    if (v1Part < v2Part) return -1;
    if (v1Part > v2Part) return 1;
  }

  return 0;
}
