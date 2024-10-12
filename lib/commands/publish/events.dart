import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/models/nostr.dart';

Future<(App, Release, Set<FileMetadata>)> finalizeEvents({
  required App app,
  required Release release,
  required Set<FileMetadata> fileMetadatas,
  required String nsec,
  bool overwriteApp = false,
  required RelayMessageNotifier relay,
}) async {
  final pubkey = BaseEvent.getPublicKey(nsec);

  final signedFileMetadatas = fileMetadatas.map((fm) => fm.sign(nsec)).toSet();

  if (!overwriteApp) {
    // If we don't overwrite the app, get the latest copy from the relay
    final appInRelay = (await relay.query<App>(
      tags: {
        '#d': [app.identifier]
      },
      authors: {pubkey},
    ))
        .firstOrNull;

    if (appInRelay != null) {
      app = appInRelay;
    }
  }

  final signedApp = app.copyWith(
    platforms: fileMetadatas.map((fm) => fm.platforms).flattened.toSet(),
    linkedReplaceableEvents: {release.getReplaceableEventLink(pubkey: pubkey)},
  ).sign(nsec);

  final signedRelease = release.copyWith(
    linkedEvents: signedFileMetadatas.map((fm) => fm.id.toString()).toSet(),
    linkedReplaceableEvents: {signedApp.getReplaceableEventLink()},
  ).sign(nsec);

  return (signedApp, signedRelease, signedFileMetadatas);
}
