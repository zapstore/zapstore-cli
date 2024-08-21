import 'package:cli_spin/cli_spin.dart';
import 'package:html/parser.dart';
import 'package:zapstore_cli/models/nostr.dart';
import 'package:http/http.dart' as http;
import 'package:html2md/html2md.dart';
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

    final document = parse(response.body);

    if (app.name == null) {
      final appName = document.querySelector('h1[itemprop=name]')!.text.trim();
      app = app.copyWith(name: appName);
    }

    if (app.content == null || app.content!.isEmpty) {
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
    final iconPath = await fetchFile(iconUrl);
    final (iconHash, newIconPath, iconMimeType) = await renameToHash(iconPath);
    final iconBlossomUrl =
        await uploadToBlossom(newIconPath, iconHash, iconMimeType);

    final imageBlossomUrls = <String>{};
    final imageUrls = document
        .querySelectorAll('img[data-screenshot-index]')
        .map((e) => e.attributes['src'])
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        final imagePath = await fetchFile(imageUrl);
        final (imageHash, newImagePath, imageMimeType) =
            await renameToHash(imagePath);
        final imageBlossomUrl =
            await uploadToBlossom(newImagePath, imageHash, imageMimeType);
        imageBlossomUrls.add(imageBlossomUrl);
      }
    }

    spinner?.success('Fetched metadata from Google Play Store');

    return app.copyWith(icons: {iconBlossomUrl}, images: imageBlossomUrls);
  }
}
