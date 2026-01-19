import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:qr_terminal/qr_terminal.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/publish/events.dart';
import 'package:zapstore_cli/utils/event_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

Future<void> zap() async {
  requireSignWith();

  final db = await Package.loadAll();
  final apps = await storage.query(
    RequestFilter<App>(
      tags: {'#d': db.values.map((p) => p.identifier).toSet()},
    ).toRequest(),
    source: RemoteSource(relays: 'zapstore'),
  );

  final profiles = await storage.query(
    RequestFilter<Profile>(
      authors: apps.map((a) => a.event.pubkey).toSet(),
    ).toRequest(),
    source: RemoteSource(relays: 'vertex'),
  );

  final appIds = [
    for (final app in apps)
      '${app.name} [${app.identifier}] signed by ${formatProfile(profiles.firstWhereOrNull((p) => p.event.pubkey == app.event.pubkey), url: false)}',
  ];

  final selection = Select(
    prompt: 'These are your installed packages, select one to zap',
    options: appIds,
  ).interact();

  final app = apps.toList()[selection];
  final profile = profiles.firstWhere(
    (p) => p.event.pubkey == app.event.pubkey,
  );

  final response = Input(
    prompt: 'How many sats do you want to zap?',
  ).interact();
  final amountInSats = int.parse(response);

  final comment = Input(
    prompt: 'Add a comment for the package author',
  ).interact();

  final lnResponse = await fetchLightningAddress(profile);

  final signer = getSignerFromString(env['SIGN_WITH']!);

  final partialZapRequest = PartialZapRequest();
  partialZapRequest.event.addTagValue('e', app.event.id);
  partialZapRequest.event.addTagValue('p', app.event.pubkey);
  partialZapRequest.amount = amountInSats * 1000;
  partialZapRequest.relays = await storage.resolveRelays('social');
  partialZapRequest.comment = comment;

  final zapRequest = await partialZapRequest.signWith(signer);
  await zapRequest.save();

  var callbackUri = Uri.parse(lnResponse['callback']!);
  callbackUri = callbackUri.replace(
    queryParameters: {
      ...callbackUri.queryParameters,
      'amount': (amountInSats * 1000).toString(),
      'nostr': jsonEncode(zapRequest.toMap()),
    },
  );

  final invoiceResponse = await http.get(callbackUri);
  final invoiceMap = jsonDecode(invoiceResponse.body);

  final invoice = invoiceMap['pr'].toString();
  // Generate QR code
  generate(invoice.toUpperCase(), typeNumber: 13, small: true);

  Zap? zap;
  while (zap == null) {
    await Future.delayed(Duration(seconds: 2));
    final zaps = await storage.query(
      RequestFilter<Zap>(
        tags: {
          '#e': {app.event.id},
          '#p': {app.event.pubkey},
        },
        limit: 1,
      ).toRequest(),
      source: LocalAndRemoteSource(relays: 'social'),
    );
    if (zaps.isNotEmpty) {
      if (zaps.first.zapRequest.value == zapRequest) {
        zap = zaps.first;
      }
    }
  }

  print(
    'Zapped ${zap.recipient.value?.nameOrNpub} for ${zap.amount} sats!'.bold(),
  );
}

Future<Map<String, dynamic>> fetchLightningAddress(Profile p) async {
  final [userName, domainName] = p.lud16!.split('@');
  final lnurl = 'https://$domainName/.well-known/lnurlp/$userName';
  final response = await http.get(Uri.parse(lnurl));
  final map = jsonDecode(response.body);
  return map;
}
