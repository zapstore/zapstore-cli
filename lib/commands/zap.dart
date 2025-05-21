import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:qr_terminal/qr_terminal.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/publish/events.dart';

Future<void> zap() async {
  final db = await Package.loadAll();
  final apps = await storage.fetch(RequestFilter<App>(
      relayGroup: 'zapstore',
      remote: true,
      tags: {'#d': db.values.map((p) => p.identifier).toSet()}));

  final profiles = await storage.fetch(RequestFilter<Profile>(
      authors: apps.map((a) => a.event.pubkey).toSet(),
      relayGroup: 'vertex',
      remote: true));

  final appIds = [
    for (final app in apps)
      '${app.name} [${app.identifier}] by ${profiles.firstWhere((p) => p.event.pubkey == app.event.pubkey).nameOrNpub}'
  ];

  final selection = Select(
    prompt: 'Select a package to zap',
    options: appIds,
  ).interact();

  final app = apps.toList()[selection];
  final profile =
      profiles.firstWhere((p) => p.event.pubkey == app.event.pubkey);

  final response = Input(
    prompt: 'How many sats do you want to zap?',
  ).interact();
  final amountInSats = int.parse(response);

  final comment = Input(
    prompt: 'Add a comment for the package author',
  ).interact();

  final lnResponse = await fetchLightningAddress(profile);

  final signer = getSignerFromString(env['SIGN_WITH'])!;

  final partialZapRequest = PartialZapRequest();
  partialZapRequest.event.addTagValue('e', app.event.id);
  partialZapRequest.event.addTagValue('p', app.event.pubkey);
  partialZapRequest.amount = amountInSats * 1000;
  partialZapRequest.relays = storage.config.getRelays(relayGroup: 'social');
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
    final zaps = await storage.query(RequestFilter<Zap>(
      relayGroup: 'social',
      remote: true,
      tags: {
        '#e': {app.event.id},
        '#p': {app.event.pubkey}
      },
      limit: 1,
    ));
    if (zaps.isNotEmpty) {
      if (zaps.first.zapRequest.value == zapRequest) {
        zap = zaps.first;
      }
    }
  }

  print('Zapped ${zap.recipient.value?.nameOrNpub} for ${zap.amount} sats!'
      .bold());
}

Future<Map<String, dynamic>> fetchLightningAddress(Profile p) async {
  final [userName, domainName] = p.lud16!.split('@');
  final lnurl = 'https://$domainName/.well-known/lnurlp/$userName';
  final response = await http.get(Uri.parse(lnurl));
  final map = jsonDecode(response.body);
  return map;
}
