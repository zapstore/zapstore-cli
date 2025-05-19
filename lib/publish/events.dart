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

Future<List<Model<dynamic>>> signModels({
  required Signer signer,
  required List<PartialModel<dynamic>> partialModels,
  required String signingPubkey,
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
    final partialBlossomAuthorizations =
        partialModels.whereType<PartialBlossomAuthorization>().toSet();

    if (partialFileMetadatas.isEmpty) {
      throw "No file metadatas produced";
    }

    for (final fm in partialFileMetadatas) {
      final eid = Utils.getEventId(fm.event, signingPubkey);
      partialRelease.event.addTagValue('e', eid);
    }
    partialRelease.event
        .addTagValue('a', partialApp.event.addressableIdFor(signingPubkey));
    partialApp.event
        .addTagValue('a', partialRelease.event.addressableIdFor(signingPubkey));

    final signedModels = await signer.sign([
      partialApp,
      partialRelease,
      ...partialFileMetadatas,
      ...partialBlossomAuthorizations,
    ]);

    spinner.success('Signed ${signedModels.length} models');

    return signedModels;
  } catch (e) {
    spinner.fail(e.toString());
    rethrow;
  }
}

Signer? getSignerFromString(String? signWith) {
  if (signWith == null) return null;
  final ref = container.read(refProvider);
  return switch (signWith) {
    'NIP07' => NIP07Signer(ref),
    _ when signWith.startsWith('bunker://') =>
      NakNIP46Signer(ref, connectionString: signWith),
    _ => Bip340PrivateKeySigner(signWith, ref),
  };
}

Future<void> withSigner(Signer signer, Future Function(Signer) callback) async {
  if (signer is NIP07Signer) {
    final ok = Confirm(
      prompt: 'Server running at port 17007, open browser in window?',
      defaultValue: false,
    ).interact();
    if (ok) {
      await signer.initialize(port: 17007);
    }
  } else {
    await signer.initialize();
  }
  await callback(signer);
  await signer.dispose();
}

class NakNIP46Signer extends Signer {
  final String connectionString;

  NakNIP46Signer(super.ref, {required this.connectionString});

  @override
  Future<String> getPublicKey() async {
    final note = await PartialNote('note to find out pubkey').signWith(this);
    return note.event.pubkey;
  }

  @override
  Future<Signer> initialize() async {
    return this;
  }

  @override
  Future<List<E>> sign<E extends Model<dynamic>>(
      List<PartialModel<dynamic>> partialModels,
      {String? withPubkey}) async {
    final result = await run('nak event --connect $connectionString',
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
