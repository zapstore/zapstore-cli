import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:process_run/process_run.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';
import 'package:http/http.dart' as http;
import 'package:tint/tint.dart';

final kBaseDir = path.join(Platform.environment['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);
final hexRegexp = RegExp(r'^[a-fA-F0-9]{64}');

Future<Map<String, dynamic>> ensureUser() async {
  final file = File(path.join(kBaseDir, '_.json'));
  final user = await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : <String, dynamic>{};

  if (user['npub'] == null) {
    print(
        'Your npub will be used it to check your web of trust before installing any new packages'
            .bold());
    user['npub'] = Input(prompt: 'npub').interact();
    file.writeAsString(jsonEncode(user));
  }

  return user;
}

String formatProfile(BaseUser user) {
  final name = user.name ?? '';
  return '${name.toString().bold()}${user.nip05?.isEmpty ?? false ? '' : ' (${user.nip05})'} - https://nostr.com/${user.npub}';
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
  final hash = await computeHash(filePath);
  var hashName = '$hash$ext';
  if (hash == hashName) {
    var mimeType = (await run('file -b --mime-type $filePath', verbose: false))
        .outText
        .split('\n')
        .first;
    if (mimeType == 'application/octet-stream' &&
        filePath.endsWith('.tar.gz')) {
      mimeType = 'application/gzip';
    }
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

Future<String> runInShell(String cmd,
    {String? workingDirectory, bool verbose = false}) async {
  return (await run('sh -c "$cmd"',
          workingDirectory: workingDirectory, verbose: verbose))
      .outText;
}

Future<String> computeHash(String filePath) async {
  return await runInShell(
      'cat $filePath | ${Platform.isLinux ? 'sha256sum' : 'shasum -a 256'} | head -c 64');
}

void printJsonEncodeColored(Object obj) {
  final prettyJson = JsonEncoder.withIndent('  ').convert(obj);

  prettyJson.split('\n').forEach((line) {
    if (line.contains('":')) {
      final [prop, ...rest] = line.split('":');
      print('${prop.green()}:${rest.join(':').blue()}');
    } else {
      print(line.blue());
    }
  });
}

class GracefullyAbortSignal extends Error {}
