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
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';

final kBaseDir = path.join(env['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);
final hexRegexp = RegExp(r'^[a-fA-F0-9]{64}');

Future<Map<String, dynamic>> checkUser() async {
  final file = File(path.join(kBaseDir, '_.json'));
  final user = await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : <String, dynamic>{};

  if (user['npub'] == null) {
    print(
        '\nYour npub will be used to check your web of trust before installing any new packages'
            .bold());
    print(
        '\nIf you prefer to skip this, leave it blank and press enter to proceed to install');
    final npub = Input(
        prompt: 'npub',
        validator: (str) {
          try {
            if (str.trim().isEmpty) {
              return true;
            }
            str.trim().hexKey.npub;
            return true;
          } catch (e) {
            throw ValidationError('Invalid npub');
          }
        }).interact();
    if (npub.trim().isNotEmpty) {
      user['npub'] = npub.trim();
      file.writeAsString(jsonEncode(user));
    }
  }

  return user;
}

Future<void> checkReleaseOnRelay(
    {required RelayMessageNotifier relay,
    required String version,
    String? artifactUrl,
    String? artifactHash,
    CliSpin? spinner}) async {
  late final bool isReleaseOnRelay;
  if (artifactHash != null) {
    final artifacts = await relay.query<FileMetadata>(tags: {
      '#x': [artifactHash]
    });
    isReleaseOnRelay = artifacts.isNotEmpty;
  } else {
    final artifacts = await relay.query<FileMetadata>(
      search: artifactUrl!,
    );

    // Search is full-text (not exact) so we double-check
    isReleaseOnRelay = artifacts.any((r) {
      return r.urls.any((u) => u == artifactUrl);
    });
  }
  if (isReleaseOnRelay) {
    if (isDaemonMode) {
      print('  $version OK, skipping');
    }
    spinner?.success(
        'Latest $version release already in relay, nothing to do. Use --overwrite-release if you want to publish anyway.');
    throw GracefullyAbortSignal();
  }
}

String formatProfile(BaseUser user) {
  final name = user.name ?? '';
  return '${name.toString().bold()}${user.nip05?.isEmpty ?? false ? '' : ' (${user.nip05})'} - https://nostr.com/${user.npub}';
}

/// Returns the downloaded file path
Future<String> fetchFile(
  String url, {
  Map<String, String>? headers,
  CliSpin? spinner,
}) async {
  final file = File(path.join(Directory.systemTemp.path, path.basename(url)));
  await shell.run('rm -fr ${file.path}');
  final initialText = spinner?.text;
  final completer = Completer<String>();
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
    completer.complete(file.path);
  });
  return completer.future;
}

Future<String> uploadToBlossom(
    String artifactPath, String artifactHash, String artifactMimeType,
    {CliSpin? spinner}) async {
  var artifactUrl = 'https://cdn.zap.store/$artifactHash';
  final headResponse = await http.head(Uri.parse(artifactUrl));
  if (headResponse.statusCode != 200) {
    final bytes = await File(artifactPath).readAsBytes();
    final response = await http.post(
      Uri.parse('https://cdn.zap.store/upload'),
      body: bytes,
      headers: {
        'Content-Type': artifactMimeType,
        'X-Filename': path.basename(artifactPath),
      },
    );

    final responseMap = Map<String, dynamic>.from(jsonDecode(response.body));
    artifactUrl = responseMap['url'];

    if (response.statusCode != 200 || artifactHash != responseMap['sha256']) {
      throw 'Error uploading $artifactPath: status code ${response.statusCode}, hash: $artifactHash, server hash: ${responseMap['sha256']}';
    }
  }
  return artifactUrl;
}

extension R2 on Future<http.Response> {
  Future<Map<String, dynamic>> getJson() async {
    return Map<String, dynamic>.from(jsonDecode((await this).body));
  }
}

extension on int {
  String toMB() => '${(this / 1024 / 1024).toStringAsFixed(2)} MB';
}

/// Returns hash, hashed file path, mime type
Future<(String, String, String)> renameToHash(String filePath) async {
  // Get extension from an URI (helps removing bullshit URL params, etc)
  final ext = path.extension(Uri.parse(filePath).path);
  final hash = await computeHash(filePath);
  var mimeType = (await run('file -b --mime-type $filePath', verbose: false))
      .outText
      .split('\n')
      .first;
  var hashName = '$hash$ext';
  if (hash == hashName) {
    if (mimeType == 'application/octet-stream' &&
        filePath.endsWith('.tar.gz')) {
      mimeType = 'application/gzip';
    }
    final [t1, t2] = mimeType.split('/');
    if (t1.trim() == 'image') {
      hashName = '$hash.$t2';
    }
  }

  final destFilePath = env['BLOSSOM_DIR'] != null
      ? path.join(env['BLOSSOM_DIR']!, hashName)
      : path.join(Directory.systemTemp.path, hashName);
  await run('mv $filePath $destFilePath', verbose: false);
  return (hash, destFilePath, mimeType);
}

Future<String> runInShell(String cmd,
    {String? workingDirectory, bool verbose = false}) async {
  return (await run('''sh -c '$cmd' ''',
          workingDirectory: workingDirectory, verbose: verbose))
      .outText;
}

Future<String> computeHash(String filePath) async {
  return await runInShell(
      'cat $filePath | ${Platform.isLinux ? 'sha256sum' : 'shasum -a 256'} | head -c 64');
}

void printJsonEncodeColored(Object obj) {
  final prettyJson = JsonEncoder.withIndent('  ').convert(obj);
  final separator = '": ';
  prettyJson.split('\n').forEach((line) {
    if (line.contains(separator)) {
      final [prop, ...rest] = line.split(separator);
      print('${prop.green()}$separator${rest.join(separator).cyan()}');
    } else {
      print(line.cyan());
    }
  });
}

class GracefullyAbortSignal extends Error {}

const kAndroidMimeType = 'application/vnd.android.package-archive';

const kSupportedPlatforms = [
  'darwin-arm64',
  'darwin-x86_64',
  'linux-aarch64',
  'linux-x86_64',
  'android-arm64-v8a',
  'android-armeabi',
  'android-armeabi-v7a',
  'android-mips',
  'android-mips64',
  'android-x86_64',
];
