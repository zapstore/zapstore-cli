import 'dart:async';
import 'dart:convert';

import 'package:models/models.dart';
import 'package:nip07_signer/main.dart';
import 'package:process_run/process_run.dart';
import 'package:riverpod/riverpod.dart';

Future<(App, Release, Set<FileMetadata>, Set<BlossomAuthorization>)>
    signModels({
  required List<PartialModel> partialModels,
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

  // TODO: Rethink the checking on relay, here signer.getPublicKey() is complex
  // if (!overwriteApp) {
  //   final pubkey = await signer.getPublicKey();

  //   // If we don't overwrite the app, get the latest copy from the relay
  //   final appsInRelay =
  //       await storage.query<App>(RequestFilter(remote: true, tags: {
  //     '#d': {app.identifier!},
  //   }, authors: {
  //     pubkey
  //   }));

  //   if (appsInRelay.isNotEmpty) {
  //     signedApp = appsInRelay.first;
  //   }
  // }

  final signedEvents = await signer.sign(partialModels);

  final signedApp = signedEvents.whereType<App>().first;
  final signedRelease = signedEvents.whereType<Release>().first;
  final signedFileMetadatas = signedEvents.whereType<FileMetadata>().toSet();
  final signedBlossomAuthorizations =
      signedEvents.whereType<BlossomAuthorization>().toSet();

  return (
    signedApp,
    signedRelease,
    signedFileMetadatas,
    signedBlossomAuthorizations
  );
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
