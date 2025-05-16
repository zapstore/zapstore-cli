import 'dart:convert';
import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/utils.dart';

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
