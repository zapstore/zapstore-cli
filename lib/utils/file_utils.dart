import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cli_spin/cli_spin.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/utils/utils.dart';

import 'dart:ffi';
import 'package:ffi/ffi.dart';

String getFilePathInTempDirectory(String hash) {
  return path.join(kTempDir, path.basename(hash));
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

  var uri = Uri.parse(url);
  // Workaround for github.com so often not resolving
  if (uri.host == 'github.com') {
    try {
      await InternetAddress.lookup('github.com').timeout(Duration(seconds: 3));
    } catch (_) {
      uri = uri.replace(host: '140.82.121.4');
    }
  }

  final req = http.Request('GET', uri);
  if (headers != null) {
    req.headers.addAll(headers);
  }
  var response = await client.send(req);

  var downloadedBytes = 0;
  final totalBytes = response.contentLength!;

  sub = response.stream.listen(
    (chunk) {
      final data = Uint8List.fromList(chunk);
      buffer.add(data);
      downloadedBytes += data.length;
      spinner?.text =
          '$initialText ${downloadedBytes.toMB()} (${(downloadedBytes / totalBytes * 100).floor()}%)';
    },
    onError: (e) {
      throw e;
    },
    onDone: () async {
      spinner?.text = '$initialText ${downloadedBytes.toMB()} (100%)';
      await sub?.cancel();
      client.close();

      final bytes = buffer.takeBytes();
      final hash = sha256.convert(bytes).toString().toLowerCase();

      final file = File(getFilePathInTempDirectory(hash));
      await deleteRecursive(file.path);
      await file.writeAsBytes(bytes);
      hashPathMap[hash] = url;
      completer.complete(hash);
    },
  );
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
  hashPathMap[hash] = filePath;
  return hash;
}

Future<String> computeHash(String filePath) async {
  return sha256
      .convert(await File(filePath).readAsBytes())
      .toString()
      .toLowerCase();
}

extension IntExt on int {
  String toMB() => '${(this / 1024 / 1024).toStringAsFixed(2)} MB';
}

extension StringExt on String {
  bool get isHttpUri => Uri.tryParse(this)?.scheme.startsWith('http') ?? false;
}

/* -----------------------------------------------------------
 * Low-level binding to C-function  int chmod(const char*, int);
 * ----------------------------------------------------------*/

typedef _ChmodC = Int32 Function(Pointer<Utf8> path, Int32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

class Posix {
  late final _ChmodDart _chmod;

  Posix() {
    final lib = _loadLibc();
    _chmod = lib.lookupFunction<_ChmodC, _ChmodDart>('chmod');
  }

  DynamicLibrary _loadLibc() {
    if (Platform.isLinux) return DynamicLibrary.open('libc.so.6');
    if (Platform.isMacOS) return DynamicLibrary.open('libc.dylib');
    throw UnsupportedError('POSIX chmod not available on this OS');
  }

  /// Direct wrapper around the C `chmod`.
  int chmod(String path, int mode) {
    final p = path.toNativeUtf8();
    final rc = _chmod(p, mode);
    malloc.free(p);
    return rc;
  }
}

/* -----------------------------------------------------------
 * Public helper: add execute bit for owner/group/others
 * (exactly what `chmod +x` does).
 * ----------------------------------------------------------*/

void makeExecutable(String path) {
  if (Platform.isWindows) return; // nothing to do on Windows

  const int execBits = 0x49; // 0o111  -> S_IXUSR|S_IXGRP|S_IXOTH
  final current = File(path).statSync().mode;
  final wanted = current | execBits; // keep existing perms, add +x

  final rc = Posix().chmod(path, wanted);
  if (rc != 0) {
    throw FileSystemException('chmod failed with code $rc', path);
  }
}
