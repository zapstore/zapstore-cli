import 'dart:async';
import 'dart:convert';

import 'package:models/models.dart';
import 'package:nip07_signer/main.dart';
import 'package:process_run/process_run.dart';
import 'package:riverpod/riverpod.dart';

Future<List<Model<dynamic>>> signModels({
  required List<PartialModel<dynamic>> partialModels,
  bool overwriteApp = false,
  required String signWith,
}) async {
  final container = ProviderContainer();
  final ref = container.read(refProvider);
  final signer = switch (signWith) {
    'NIP07' => NIP07Signer(ref),
    _ when signWith.startsWith('bunker://') =>
      NakNIP46Signer(ref, connectionString: signWith),
    _ => Bip340PrivateKeySigner(signWith, ref),
  };

  await signer.initialize();

  final signingPubkey = await signer.getPublicKey();

  final partialApp = partialModels.whereType<PartialApp>().first;
  final partialRelease = partialModels.whereType<PartialRelease>().first;
  final partialFileMetadatas =
      partialModels.whereType<PartialFileMetadata>().toSet();
  final partialBlossomAuthorizations =
      partialModels.whereType<PartialBlossomAuthorization>().toSet();

  for (final fm in partialFileMetadatas) {
    final eid = Utils.getEventId(fm.event, signingPubkey);
    print('setting $eid');
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
    ...partialBlossomAuthorizations
  ]);
  await signer.dispose();

  return signedModels;
}

class NakNIP46Signer extends Signer {
  final String connectionString;

  NakNIP46Signer(super.ref, {required this.connectionString});

  @override
  Future<String> getPublicKey() async {
    return '';
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
