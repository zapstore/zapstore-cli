import 'package:collection/collection.dart';
import 'package:zapstore_cli/models.dart';

Future<(App, Release, Set<FileMetadata>)> finalizeEvents(
    {required App app,
    required Release release,
    required Set<FileMetadata> fileMetadatas,
    required String nsec}) async {
  final pubkeys = app.pubkeys;
  final zapTags = app.pubkeys;

  final signedFileMetadatas = fileMetadatas
      .map((fm) => fm.copyWith(pubkeys: pubkeys, zapTags: zapTags).sign(nsec))
      .toSet();

  final signedApp = app
      .copyWith(
          platforms: fileMetadatas.map((fm) => fm.platforms).flattened.toSet())
      .sign(nsec);

  final signedRelease = release
      .copyWith(
        linkedEvents: signedFileMetadatas.map((fm) => fm.id.toString()).toSet(),
        linkedReplaceableEvents: {signedApp.getReplaceableEventLink()},
        pubkeys: pubkeys,
        zapTags: zapTags,
      )
      .sign(nsec);

  return (signedApp, signedRelease, signedFileMetadatas);
}
