import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cli_dialog/cli_dialog.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:process_run/process_run.dart';
import 'package:path/path.dart' as path;
import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/main.dart';
import 'package:http/http.dart' as http;

final kBaseDir = path.join(Platform.environment['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);
final dialog = CLI_Dialog(questions: [
  ['npub:', 'npub']
]);

Future<Map<String, List<Map<String, dynamic>>>> loadPackages() async {
  final dir = Directory(kBaseDir);

  if (!await dir.exists()) {
    print(logger.ansi.emphasized('Welcome to zap.store!\n'));
    final dialog = CLI_Dialog(booleanQuestions: [
      ['This package requires creating the $kBaseDir directory. Proceed?', '_']
    ], trueByDefault: true);
    final setUp = dialog.ask()['_'];

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
      await shell.run('cp $thisExecutable $newName');
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
      .where((e) => e != '_.json');

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
    print(
        'Please input your npub, we will use it to check your web of trust before installing any new packages');

    user['npub'] = await dialog.ask()['npub'];
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

Future<void> fetchWithProgress(String url, File file, CliSpin spinner) async {
  final initialText = spinner.text;
  final completer = Completer();
  StreamSubscription? sub;
  final client = http.Client();
  final sink = file.openWrite();
  var downloadedBytes = 0;

  var response = await client.send(http.Request('GET', Uri.parse(url)));
  final totalBytes = response.contentLength!;

  sub = response.stream.listen((chunk) {
    final data = Uint8List.fromList(chunk);
    sink.add(data);
    downloadedBytes += data.length;
    spinner.text =
        '$initialText ${(downloadedBytes / totalBytes * 100).floor()}%';
  }, onError: (e) {
    throw e;
  }, onDone: () async {
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

String buildAppName(String pubkey, String name, String version) {
  return '$pubkey-$name@-$version';
}

(String, String, String) splitAppName(String str) {
  final [name, version] = str.substring(65).split('@-');
  return (str.substring(0, 64), name, version);
}
