import 'package:collection/collection.dart';
import 'package:purplebase/purplebase.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:zapstore_cli/utils.dart';

Future<(App, Release, Set<FileMetadata>)> finalizeEvents({
  required App app,
  required Release release,
  required Set<FileMetadata> fileMetadatas,
  bool overwriteApp = false,
}) async {
  var nsec = env['NSEC'];

//           if (nsec == null) {
//             print('''\n
// ***********
// Please provide your nsec (in nsec or hex format) to sign the events.

// ${' It will be discarded IMMEDIATELY after signing! '.bold().onYellow().black()}

// For non-interactive use, pass the NSEC environment variable. More signing options coming soon.
// If unsure, run this program from source. See https://github.com/zapstore/zapstore-cli'
// ***********
// ''');
//             nsec ??= Password(prompt: 'nsec').interact();
//           }
  if (nsec == null) {
    // TODO: Allow no nsec and just output events for external signing
    print('Here I will print out events for you to sign');
    throw GracefullyAbortSignal();
  }

  if (nsec.startsWith('nsec')) {
    nsec = bech32Decode(nsec);
  }

  final pubkey = BaseEvent.getPublicKey(nsec);

  final signedFileMetadatas = fileMetadatas.map((fm) => fm.sign(nsec!)).toSet();

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

  final signedApp = app
      .copyWith(
        platforms: fileMetadatas.map((fm) => fm.platforms).flattened.toSet(),
        linkedReplaceableEvents: {
          release.getReplaceableEventLink(pubkey: pubkey)
        },
        // Always use the latest release timestamp
        createdAt: release.createdAt,
      )
      .sign(nsec);

  final signedRelease = release.copyWith(
    linkedEvents: signedFileMetadatas.map((fm) => fm.id.toString()).toSet(),
    linkedReplaceableEvents: {signedApp.getReplaceableEventLink()},
  ).sign(nsec);

  return (signedApp, signedRelease, signedFileMetadatas);
}
