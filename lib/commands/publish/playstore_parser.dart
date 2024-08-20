import 'dart:io';

import 'package:cli_spin/cli_spin.dart';
import 'package:html/parser.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:html2md/html2md.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils.dart';

class PlayStoreParser {
  Future<App> run({required App app, CliSpin? spinner}) async {
    final url =
        'https://play.google.com/store/apps/details?id=${app.identifier}';

    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 404) {
      spinner?.fail();
      return app;
    }

    final imageHashNames = [];

    final document = parse(response.body);

    if (app.name == null) {
      final appName = document.querySelector('h1[itemprop=name]')!.text.trim();
      print(appName);
      app = app.copyWith(name: appName);
    }

    if (app.summary == null) {
      final appDescription =
          document.querySelector('div[data-g-id=description]')!.text.trim();
      final markdownAppDescription = convert(appDescription);
      app = app.copyWith(content: markdownAppDescription);
    }

    final iconUrls = document
        .querySelectorAll('img[itemprop=image]')
        .map((e) => e.attributes['src'])
        .nonNulls;
    final iconUrl = iconUrls.first;
    print(iconUrls);

    String iconPath;
    if (iconUrl.trim().isNotEmpty) {
      iconPath = path.join('', path.basename(iconUrl));
      final response = await http.get(Uri.parse(iconUrl));
      await File(iconPath).writeAsBytes(response.bodyBytes);
      // TODO upload to blossom server
    }

    final imageUrls = document
        .querySelectorAll('img[data-screenshot-index]')
        .map((e) => e.attributes['src'])
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        final tempImagePath =
            path.join(Directory.systemTemp.path, path.basename(imageUrl));
        final response = await http.get(Uri.parse(imageUrl));
        await File(tempImagePath).writeAsBytes(response.bodyBytes);
        final (_, imageHashName, _) = await renameToHash(tempImagePath);
        imageHashNames.add(imageHashName);
        // TODO upload blossom
      }
    }

    spinner?.success('Fetched metadata from Google Play Store');

    return app;
  }
}
