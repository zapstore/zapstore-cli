import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils/utils.dart';

String getFilePathInTempDirectory(String name) {
  return path.join(kTempDir, path.basename(name));
}

/// Returns the hash of the downloaded file
Future<String> fetchFile(
  String url, {
  Map<String, String>? headers,
  CliSpin? spinner,
}) async {
  final initialText = spinner?.text;
  final completer = Completer<String>();

  StreamSubscription? sub;
  final client = http.Client();
  final buffer = BytesBuilder();

  final req = http.Request('GET', Uri.parse(url));
  if (headers != null) {
    req.headers.addAll(headers);
  }
  var response = await client.send(req);

  var downloadedBytes = 0;
  final totalBytes = response.contentLength!;

  sub = response.stream.listen((chunk) {
    final data = Uint8List.fromList(chunk);
    buffer.add(data);
    downloadedBytes += data.length;
    spinner?.text =
        '$initialText ${downloadedBytes.toMB()} (${(downloadedBytes / totalBytes * 100).floor()}%)';
  }, onError: (e) {
    throw e;
  }, onDone: () async {
    spinner?.text = '$initialText ${downloadedBytes.toMB()} (100%)';
    await sub?.cancel();
    client.close();

    final bytes = buffer.takeBytes();
    final hash = sha256.convert(bytes).toString().toLowerCase();

    final file = File(getFilePathInTempDirectory(hash));
    await deleteRecursive(file.path);
    await file.writeAsBytes(bytes);
    hashUrlMap[hash] = url;
    completer.complete(hash);
  });
  return completer.future;
}

Future<void> deleteRecursive(String path) async {
  final file = File(path);
  final dir = Directory(path);

  if (await file.exists()) {
    await file.delete();
  } else if (await dir.exists()) {
    dir.delete(recursive: true);
  }
}

Future<void> writeArchiveToDisk(Archive archive, {String outDir = '.'}) async {
  for (final file in archive) {
    final filename = path.join(outDir, file.name);

    if (file.isFile) {
      await File(filename).parent.create(recursive: true);
      await File(filename).writeAsBytes(file.content as List<int>);
    } else {
      Directory(filename).createSync(recursive: true);
    }
  }
}

/// Returns hash
Future<String> copyToHash(String filePath) async {
  // Get extension from an URI (helps removing bullshit URL params, etc)
  final hash = await computeHash(filePath);
  await File(filePath).copy(getFilePathInTempDirectory(hash));
  // final ext = path.extension(Uri.parse(filePath).path);
  hashPathMap[hash] = filePath;
  return hash;
}

Future<String> computeHash(String filePath) async {
  return sha256
      .convert(await File(filePath).readAsBytes())
      .toString()
      .toLowerCase();
}

extension on int {
  String toMB() => '${(this / 1024 / 1024).toStringAsFixed(2)} MB';
}
