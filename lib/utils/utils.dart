import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_emoji/dart_emoji.dart';
import 'package:process_run/process_run.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:zapstore_cli/main.dart';

final kTempDir = Directory.systemTemp.path;

final kBaseDir = Platform.isWindows
    ? path.join(env['USERPROFILE']!, '.zapstore')
    : path.join(env['HOME']!, '.zapstore');
final shell = Shell(workingDirectory: kBaseDir, verbose: false);

final startsWithHexRegexp = RegExp(r'^[a-fA-F0-9]{64}');

final hashUrlMap = <String, String>{};
final hashPathMap = <String, String>{};

String get hostPlatform {
  final platformVersion = Platform.version.split('on').lastOrNull?.trim();

  return switch (platformVersion) {
    '"macos_arm64"' => 'darwin-arm64',
    '"linux_arm64"' => 'linux-aarch64',
    '"linux_amd64"' => 'linux-amd64',
    _ => throw UnsupportedError('$platformVersion'),
  };
}

extension HttpResponseExtension on Future<http.Response> {
  Future<Map<String, dynamic>> getJson() async {
    return Map<String, dynamic>.from(jsonDecode((await this).body));
  }
}

final emojiParser = EmojiParser();

extension StringExtension on String {
  String parseEmojis() {
    return replaceAllMapped(EmojiParser.REGEX_NAME, (m) {
      return emojiParser.hasName(m[1]!) ? emojiParser.get(m[1]!).code : m[0]!;
    });
  }
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

final kZapstoreSupportedMimeTypes = [
  kMacOSArm64,
  kLinuxAmd64,
  kLinuxArm64,
  kAndroidMimeType
];

final kZapstoreAcceptedMimeTypes = [
  ...kZapstoreSupportedMimeTypes,
  ...kArchiveMimeTypes,
  kAndroidMimeType,
];

const kLinux = 'application/x-executable';
const kMacOS = 'application/x-mach-binary';
const kLinuxAmd64 = '$kLinux; format=elf; arch=x86-64';
const kLinuxArm64 = '$kLinux; format=elf; arch=arm';
const kMacOSAmd64 = '$kMacOS; arch=x86-64';
const kMacOSArm64 = '$kMacOS; arch=arm64';

const kZapstorePubkey =
    '78ce6faa72264387284e647ba6938995735ec8c7d5c5a65737e55130f026307d';
const kAppRelays = {'wss://relay.zapstore.dev'};
// const kAppRelays = {'ws://localhost:3000'};

const kZapstoreBlossomUrl = 'https://bcdn.zapstore.dev';
