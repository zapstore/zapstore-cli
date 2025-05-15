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
const kArchiveMimeTypes = [
  'application/zip',
  'application/gzip',
  'application/x-tar',
  'application/x-xz',
  'application/x-bzip2'
];

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

// Version comparison

// SPDX-License-Identifier: MIT
/// Version comparison helper.
///
/// canUpgrade(installed, current) → true  if `current` is newer than `installed`.
///
/// The rules implemented are a pragmatic superset of Semantic Versioning:
///
/// • Optional `v`/`V` prefix is ignored (e.g. `v1.2.3`).
/// • The core version is an arbitrary number of dot-separated numeric parts,
///   compared *numerically*, not lexicographically (1.2.10 > 1.2.3).
/// • A version containing a pre-release label (`-alpha`, `-beta.1`, `-rc`,
///   etc.) is considered *older* than the same version without one
///   (1.0.0 < 1.0.0-rc).
/// • When both versions have pre-release labels, they are compared component
///   by component, splitting on `.`:
///   – purely numeric identifiers are compared numerically;
///   – non-numeric identifiers are compared lexically (ASCII order);
///   – numeric identifiers have *lower* precedence than non-numeric ones
///     (SemVer rule 11).
/// • Build metadata introduced by `+` (e.g. `1.0.0+20180101`) never affects
///   ordering and is ignored.
///
/// The implementation is completely self-contained – no external packages.
bool canUpgrade(String installed, String current) {
  return _Version.parse(current).compareTo(_Version.parse(installed)) > 0;
}

/* -------------------------------------------------------------------------- */
/*                            Internal implementation                          */
/* -------------------------------------------------------------------------- */

class _Version implements Comparable<_Version> {
  _Version(this.parts, this.preRelease);

  /// Dot-separated numeric components of the core version.
  final List<int> parts;

  /// Pre-release identifiers, possibly empty.
  final List<_Identifier> preRelease;

  /* ------------------------------- parsing -------------------------------- */

  static final _coreRegex = RegExp(r'^v?', caseSensitive: false);

  static _Version parse(String input) {
    // 1. strip leading 'v' or 'V'
    input = input.replaceFirst(_coreRegex, '');

    // 2. drop build metadata (`+...`)
    final plus = input.indexOf('+');
    if (plus != -1) input = input.substring(0, plus);

    // 3. split pre-release (`-...`)
    String core;
    String? pre;
    final dash = input.indexOf('-');
    if (dash == -1) {
      core = input;
      pre = null;
    } else {
      core = input.substring(0, dash);
      pre = input.substring(dash + 1);
    }

    final parts = core.split('.').map(int.parse).toList(growable: false);

    final preParts = <_Identifier>[];
    if (pre != null) {
      for (final id in pre.split('.')) {
        preParts.add(_Identifier(id));
      }
    }

    return _Version(parts, preParts);
  }

  /* ----------------------------- comparison ------------------------------- */

  @override
  int compareTo(_Version other) {
    // 1. compare numeric dot parts
    final maxLen =
        parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < maxLen; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }

    // 2. handle pre-release vs stable
    final aHasPre = preRelease.isNotEmpty;
    final bHasPre = other.preRelease.isNotEmpty;
    if (aHasPre && !bHasPre) return -1; // pre-release < stable
    if (!aHasPre && bHasPre) return 1; // stable > pre-release

    // 3. both stable or both prerelease
    final maxPre = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;

    for (var i = 0; i < maxPre; i++) {
      final aId = i < preRelease.length ? preRelease[i] : _Identifier.empty;
      final bId =
          i < other.preRelease.length ? other.preRelease[i] : _Identifier.empty;

      final cmp = aId.compareTo(bId);
      if (cmp != 0) return cmp;
    }

    // versions are identical
    return 0;
  }

  @override
  String toString() {
    final core = parts.join('.');
    if (preRelease.isEmpty) return core;
    return '$core-${preRelease.join('.')}';
  }
}

/* -------------------------------------------------------------------------- */

class _Identifier implements Comparable<_Identifier> {
  _Identifier(String raw)
      : isNumeric = _numeric.hasMatch(raw),
        value = raw;

  static final _numeric = RegExp(r'^[0-9]+$');

  /// Special value for absent identifiers when lengths differ.
  static final empty = _Identifier('').._isEmpty = true;

  final bool isNumeric;
  final String value;
  bool _isEmpty = false;

  @override
  int compareTo(_Identifier other) {
    // Empty identifiers are considered lower
    if (_isEmpty && other._isEmpty) return 0;
    if (_isEmpty) return -1;
    if (other._isEmpty) return 1;

    // Numeric vs non-numeric
    if (isNumeric && other.isNumeric) {
      // numeric compare
      return int.parse(value).compareTo(int.parse(other.value));
    }
    if (isNumeric != other.isNumeric) {
      // numeric identifiers have lower precedence than non-numeric
      return isNumeric ? -1 : 1;
    }
    // Both non-numeric: lexicographic ASCII
    return value.compareTo(other.value);
  }

  @override
  String toString() => value;
}
