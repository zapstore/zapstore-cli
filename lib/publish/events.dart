import 'dart:async';
import 'dart:convert';

import 'package:cli_spin/cli_spin.dart';
import 'package:collection/collection.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:nip07_signer/main.dart';
import 'package:process_run/process_run.dart';
import 'package:riverpod/riverpod.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils/utils.dart';

Future<List<Model<dynamic>>> signModels({
  required Signer signer,
  required List<PartialModel<dynamic>> partialModels,
}) async {
  final kindsAmount = partialModels
      .map((m) => m.event.kind)
      .groupListsBy((k) => k)
      .entries
      .map((e) =>
          'kind ${e.key}: ${e.value.length} event${e.value.length > 1 ? 's' : ''}')
      .join(', ');

  final spinner = CliSpin(
    text: 'Signing with ${signer.runtimeType}: $kindsAmount...',
    spinner: CliSpinners.dots,
    isSilent: isDaemonMode,
  ).start();

  try {
    final partialApp = partialModels.whereType<PartialApp>().first;
    final partialRelease = partialModels.whereType<PartialRelease>().first;
    final partialFileMetadatas =
        partialModels.whereType<PartialFileMetadata>().toSet();
    final partialSoftwareAssets =
        partialModels.whereType<PartialSoftwareAsset>().toSet();
    final partialBlossomAuthorizations =
        partialModels.whereType<PartialBlossomAuthorization>().toSet();

    if (partialFileMetadatas.isEmpty) {
      throw "No file metadatas produced";
    }

    if (isNewFormat) {
      for (final a in partialSoftwareAssets) {
        final eid = Utils.getEventId(a.event, signer.pubkey);
        partialRelease.event.addTagValue('e', eid);
      }
    } else {
      for (final fm in partialFileMetadatas) {
        final eid = Utils.getEventId(fm.event, signer.pubkey);
        partialRelease.event.addTagValue('e', eid);
      }
      linkAppAndRelease(
          partialApp: partialApp,
          partialRelease: partialRelease,
          signingPubkey: signer.pubkey);
    }

    final signedModels = await signer.sign([
      partialApp,
      partialRelease,
      ...partialFileMetadatas,
      ...partialSoftwareAssets,
      ...partialBlossomAuthorizations,
    ]);

    spinner.success(
        'Signed ${signedModels.length} models with ${signer.runtimeType}');

    return signedModels;
  } catch (e) {
    spinner.fail(e.toString());
    rethrow;
  }
}

void linkAppAndRelease(
    {required PartialApp partialApp,
    required PartialRelease partialRelease,
    required String signingPubkey}) {
  partialRelease.event
      .addTagValue('a', partialApp.event.addressableIdFor(signingPubkey));
  partialApp.event
      .addTagValue('a', partialRelease.event.addressableIdFor(signingPubkey));
}

Signer getSignerFromString(String signWith) {
  final ref = container.read(refProvider);
  return switch (signWith) {
    'NIP07' => NIP07Signer(ref),
    _ when signWith.startsWith('bunker://') =>
      NakNIP46Signer(ref, connectionString: signWith),
    _ when signWith.startsWith('npub') => NpubFakeSigner(ref, pubkey: signWith),
    _ => (() {
        final nsec =
            signWith.startsWith('nsec') ? bech32Decode(signWith) : signWith;
        return Bip340PrivateKeySigner(nsec, ref);
      })(),
  };
}

Future<void> withSigner(Signer signer, Future Function(Signer) callback) async {
  if (signer is NIP07Signer) {
    final ok = isDaemonMode ||
        Confirm(
          prompt:
              'This will launch a server at localhost:17007 and open a browser window for signing with a NIP-07 extension. Okay?',
          defaultValue: true,
        ).interact();
    if (ok) {
      await signer.initialize();
    } else {
      print('kthxbye');
      throw GracefullyAbortSignal();
    }
  } else {
    await signer.initialize();
  }
  await callback(signer);
  await signer.dispose();
}

// Signers

/// This signer is fake because it does not sign
/// but we use it for convenience
class NpubFakeSigner extends Signer {
  final String _pubkey;

  NpubFakeSigner(super.ref, {required String pubkey})
      : _pubkey = Utils.hexFromNpub(pubkey);

  @override
  Future<void> initialize({bool active = true}) async {
    internalSetPubkey(_pubkey);
    super.initialize(active: active);
  }

  @override
  Future<List<E>> sign<E extends Model<dynamic>>(
      List<PartialModel<dynamic>> partialModels,
      {String? withPubkey}) async {
    throw UnimplementedError();
  }
}

class NakNIP46Signer extends Signer {
  final String connectionString;

  NakNIP46Signer(super.ref, {required this.connectionString});

  @override
  Future<void> initialize({bool active = true}) async {
    final note = await PartialNote('note to find out pubkey').signWith(this);
    final pubkey = note.event.pubkey;
    internalSetPubkey(pubkey);
    super.initialize(active: active);
  }

  @override
  Future<List<E>> sign<E extends Model<dynamic>>(
      List<PartialModel<dynamic>> partialModels,
      {String? withPubkey}) async {
    final result = await run('nak event --sec $connectionString',
        runInShell: true,
        verbose: false,
        stdin: Stream.value(utf8.encode(
            partialModels.map((p) => jsonEncode(p.toMap())).join('\n'))));
    return result.outText
        .split('\n')
        .map((line) {
          final map = jsonDecode(line) as Map<String, dynamic>;
          return Model.getConstructorForKind(map['kind'])!.call(map, ref);
        })
        .cast<E>()
        .toList();
  }
}

final refProvider = Provider((ref) => ref);
