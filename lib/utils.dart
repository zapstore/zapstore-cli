import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_spin/cli_spin.dart';
import 'package:crypto/crypto.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:process_run/process_run.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';

final kTempDir = Directory.systemTemp.path;

String getFilePathInTempDirectory(String name) {
  return path.join(kTempDir, path.basename(name));
}

final kBaseDir = Platform.isWindows
    ? path.join(env['USERPROFILE']!, '.zapstore')
    : path.join(env['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);
final hexRegexp = RegExp(r'^[a-fA-F0-9]{64}');

final hashUrlMap = <String, String>{};
final hashPathMap = <String, String>{};

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
            Utils.npubFromHex(Utils.hexFromNpub(str.trim()));
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
    {required String version,
    String? assetUrl,
    String? assetHash,
    CliSpin? spinner}) async {
  late final bool isReleaseOnRelay;
  if (assetHash != null) {
    final assets =
        await storage.query<FileMetadata>(RequestFilter(remote: true, tags: {
      '#x': {assetHash}
    }));

    isReleaseOnRelay = assets.isNotEmpty;
  } else {
    final assets = await storage.query<FileMetadata>(RequestFilter(
      remote: true,
      search: assetUrl!,
    ));

    // Search is full-text (not exact) so we double-check
    isReleaseOnRelay = assets.any((r) {
      return r.urls.any((u) => u == assetUrl);
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

String formatProfile(Profile profile) {
  final name = profile.name ?? '';
  return '${name.toString().bold()}${profile.nip05?.isEmpty ?? false ? '' : ' (${profile.nip05})'} - https://nostr.com/${profile.npub}';
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

extension R2 on Future<http.Response> {
  Future<Map<String, dynamic>> getJson() async {
    return Map<String, dynamic>.from(jsonDecode((await this).body));
  }
}

extension on int {
  String toMB() => '${(this / 1024 / 1024).toStringAsFixed(2)} MB';
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

/// Returns the subsection that follows the heading matching [version].
///
/// * [markdown] – entire contents of `CHANGELOG.md`.
/// * [version]  – the literal version label to look for, e.g. `"1.2.0"` or
///                `"Unreleased"`.
///
/// The function looks for a level-2 heading of the canonical form
///
///     ## [<version>] - YYYY-MM-DD
///
/// or
///
///     ## [<version>]
///
/// If the heading is found, the text from that heading (inclusive) up to—but
/// not including—the next level-2 heading is returned.
/// If the heading is not present, the whole provided Markdown is returned.
String? extractVersionSection(String markdown, String version) {
  // Build a regex that matches the exact version inside the square brackets.
  final headingPattern = RegExp(
      r'^##\s*$$\s*' + RegExp.escape(version) + r'\s*$$.*$',
      multiLine: true);

  final match = headingPattern.firstMatch(markdown);
  if (match == null) return markdown;

  final start = match.start;

  // Look for the next level-2 heading after the one we just found.
  final nextHeadingPattern = RegExp(r'^##\s*\[.*$', multiLine: true);
  final nextMatch =
      nextHeadingPattern.firstMatch(markdown.substring(match.end));

  final end = nextMatch == null ? markdown.length : match.end + nextMatch.start;

  return markdown.substring(start, end).trimRight();
}

void printJsonEncodeColored(Object obj) {
  final prettyJson = JsonEncoder.withIndent('  ').convert(obj);
  final separator = '": ';
  prettyJson.split('\n').forEach((line) {
    if (line.contains(separator)) {
      final [prop, ...rest] = line.split(separator);
      stderr.writeln('${prop.green()}$separator${rest.join(separator).cyan()}');
    } else {
      stderr.writeln(line.cyan());
    }
  });
}

class GracefullyAbortSignal extends Error {}

const kAndroidMimeType = 'application/vnd.android.package-archive';

const kZapstoreSupportedPlatforms = [
  'darwin-arm64',
  'linux-aarch64',
  'linux-x86_64',
  'android-arm64-v8a',
];

const kZapstorePubkey =
    '78ce6faa72264387284e647ba6938995735ec8c7d5c5a65737e55130f026307d';
const kAppRelays = {'wss://relay.zapstore.dev'};
// const kAppRelays = {'ws://localhost:3000'};

const kZapstoreBlossomUrl = 'https://bcdn.zapstore.dev';
