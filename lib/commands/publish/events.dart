import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models/nostr.dart';

Future<(App?, Release, Set<FileMetadata>)> finalizeEvents({
  required App app,
  required Release release,
  required Set<FileMetadata> fileMetadatas,
  required String nsec,
  bool overwriteApp = false,
  required RelayMessageNotifier relay,
}) async {
  if (fileMetadatas.isEmpty) {
    throw 'No artifacts to process';
  }

  final signedFileMetadatas = fileMetadatas.map((fm) => fm.sign(nsec)).toSet();

  // Get pubkey from any file metadata we just signed
  final pubkey = signedFileMetadatas.first.pubkey;
  // Find app with this identifier for this pubkey
  final appInRelay = (await relay.query<App>(
    tags: {
      '#d': [app.identifier]
    },
    authors: {pubkey},
  ))
      .firstOrNull;

  App? signedApp;
  // If not found (first time publishing), we ignore the
  // overwrite argument and sign anyway
  if (overwriteApp || appInRelay == null) {
    signedApp = app
        .copyWith(
            platforms:
                fileMetadatas.map((fm) => fm.platforms).flattened.toSet())
        .sign(nsec);
  }

  final signedRelease = release.copyWith(
    linkedEvents: signedFileMetadatas.map((fm) => fm.id.toString()).toSet(),
    linkedReplaceableEvents: {
      (signedApp ?? appInRelay!).getReplaceableEventLink()
    },
  ).sign(nsec);

  return (signedApp, signedRelease, signedFileMetadatas);
}
