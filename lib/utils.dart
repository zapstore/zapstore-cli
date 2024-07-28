import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:process_run/process_run.dart';
import 'package:path/path.dart' as path;
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;

final kBaseDir = path.join(Platform.environment['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);
final hexRegexp = RegExp(r'^[a-fA-F0-9]{64}');

Future<Map<String, List<Map<String, dynamic>>>> loadPackages() async {
  final dir = Directory(kBaseDir);

  if (!await dir.exists()) {
    print(logger.ansi.emphasized('Welcome to zap.store!\n'));
    final setUp = Confirm(
      prompt:
          'This package requires creating the $kBaseDir directory. Proceed?',
    ).interact();

    if (!setUp) {
      print('Okay, fine');
      exit(0);
    }
    await run('mkdir -p $kBaseDir', verbose: false);

    // Ensure zapstore is copied over to base dir
    final thisExecutable = Platform.environment['_'];
    final file = File(path.join(kBaseDir, 'zapstore'));
    if (!await file.exists()) {
      final newName = buildAppName(kZapstorePubkey, 'zapstore', kVersion);
      await run('cp $thisExecutable ${path.join(kBaseDir, newName)}',
          verbose: false);
      await shell.run('ln -sf $newName zapstore');
    }
  }

  final systemPath = Platform.environment['PATH']!;
  if (!systemPath.contains(kBaseDir)) {
    print(
        '\nPlease run: ${logger.ansi.emphasized('echo \'export PATH="$kBaseDir:\$PATH"\' >> ~/.bashrc')} or equivalent to add zap.store to your PATH');
    print(
        '\nAfter that, open a new shell and run this program with ${logger.ansi.emphasized('zapstore')}');
    exit(0);
  }

  final links =
      (await shell.run('find . -type l')).outLines.map((e) => e.substring(2));
  final programs = (await shell.run('find . -type f'))
      .outLines
      .map((e) => e.substring(2))
      .where((e) => hexRegexp.hasMatch(e));

  final db = <String, List<Map<String, dynamic>>>{};
  for (final p in programs) {
    final (pubkey, name, version) = splitAppName(p);
    db[name] ??= [];
    db[name]!.add({
      'pubkey': pubkey,
      'version': version,
    });
  }

  // Determine which versions are enabled
  for (final link in links) {
    final file = (await shell.run('readlink $link')).outText;
    if (file.trim().isNotEmpty) {
      final (_, _, version) = splitAppName(file.trim());
      db[link]?.firstWhereOrNull((a) => a['version'] == version)?['enabled'] =
          true;
    }
  }

  return db;
}

Future<Map<String, dynamic>> ensureUser() async {
  final file = File(path.join(kBaseDir, '_.json'));
  final user = await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : <String, dynamic>{};

  if (user['npub'] == null) {
    print(logger.ansi.emphasized(
        'Your npub will be used it to check your web of trust before installing any new packages'));
    user['npub'] = Input(prompt: 'npub').interact();
    file.writeAsString(jsonEncode(user));
  }

  return user;
}

String getTag(event, tagName) {
  return (event['tags'] as List)
          .firstWhereOrNull((t) => t.first == tagName)?[1]
          .toString() ??
      '';
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

String formatProfile(Map<String, dynamic> p, String k) {
  final name = ((p['display_name']?.isNotEmpty ?? false)
          ? p['display_name']
          : p['name']) ??
      '';
  final nip05 = (p['nip05']?.isNotEmpty ?? false) ? '(${p['nip05']}) ' : '';
  return '${logger.ansi.emphasized(name)} $nip05- https://nostr.com/$k';
}

Future<void> fetchFile(String url, File file,
    {Map<String, String>? headers, CliSpin? spinner}) async {
  final initialText = spinner?.text;
  final completer = Completer();
  StreamSubscription? sub;
  final client = http.Client();
  final sink = file.openWrite();

  final req = http.Request('GET', Uri.parse(url));
  if (headers != null) {
    req.headers.addAll(headers);
  }
  var response = await client.send(req);

  var downloadedBytes = 0;
  final totalBytes = response.contentLength!;

  // final progress = Progress(
  //   length: totalBytes,
  //   size: 0.25,
  //   rightPrompt: (current) =>
  //       ' ${(current / 1024 / 1024).toStringAsFixed(2)}MB (${(current / totalBytes * 100).floor()}%)',
  // ).interact();

  sub = response.stream.listen((chunk) {
    final data = Uint8List.fromList(chunk);
    sink.add(data);
    // progress.increase(data.length);
    downloadedBytes += data.length;
    spinner?.text =
        '$initialText ${downloadedBytes.toMB()} (${(downloadedBytes / totalBytes * 100).floor()}%)';
  }, onError: (e) {
    throw e;
  }, onDone: () async {
    spinner?.text = '$initialText ${downloadedBytes.toMB()} (100%)';
    // progress.done();
    await sub?.cancel();
    await sink.close();
    client.close();
    completer.complete();
  });
  return completer.future;
}

Future<List<Map<String, dynamic>>> queryZapstore(RelayRequest req) async {
  final response = await http.post(
    Uri.parse('https://relay.zap.store/'),
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: jsonEncode(req.toMap()),
  );
  return List<Map<String, dynamic>>.from(jsonDecode(response.body));
}

Future<void> publishToZapstore(BaseEvent event) async {
  await http.post(
    Uri.parse('https://relay.zap.store/'),
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: jsonEncode(["EVENT", event.toMap()]),
  );
}

String buildAppName(String pubkey, String name, String version) {
  return '$pubkey-$name@-$version';
}

(String, String, String) splitAppName(String str) {
  final [name, version] = str.substring(65).split('@-');
  return (str.substring(0, 64), name, version);
}

extension R2 on Future<http.Response> {
  Future<Map<String, dynamic>> getJson() async {
    return Map<String, dynamic>.from(jsonDecode((await this).body));
  }
}

extension on int {
  String toMB() => '${(this / 1024 / 1024).toStringAsFixed(2)} MB';
}

Future<(String, String)> renameToHash(String filePath) async {
  final ext = path.extension(filePath);
  final hash = await runInShell('cat $filePath | shasum -a 256 | head -c 64');
  var hashName = '$hash$ext';
  if (hash == hashName) {
    final mimeType =
        (await run('file -b --mime-type $filePath', verbose: false))
            .outText
            .split('\n')
            .first;
    final [t1, t2] = mimeType.split('/');
    if (t1.trim() == 'image') {
      hashName = '$hash.$t2';
    }
  }

  final destFilePath = Platform.environment['BLOSSOM_DIR'] != null
      ? path.join(Platform.environment['BLOSSOM_DIR']!, hashName)
      : path.join(Directory.systemTemp.path, hashName);
  await run('mv $filePath $destFilePath', verbose: false);
  return (hash, destFilePath);
}

Future<String> runInShell(String cmd, {String? workingDirectory}) async {
  return (await run('sh -c "$cmd"',
          workingDirectory: workingDirectory, verbose: false))
      .outText;
}

class GracefullyAbortSignal extends Error {}
