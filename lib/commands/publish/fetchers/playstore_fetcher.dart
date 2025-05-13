import 'package:models/models.dart';
import 'package:universal_html/parsing.dart';
import 'package:http/http.dart' as http;
import 'package:html2md/html2md.dart' as markdown;
import 'package:zapstore_cli/commands/publish/fetchers/fetcher.dart';
import 'package:zapstore_cli/utils.dart';

class PlayStoreFetcher extends Fetcher {
  @override
  String get name => 'Google Play Store fetcher';

  @override
  Future<PartialApp?> run({required String appIdentifier}) async {
    final app = PartialApp();
    final url = 'https://play.google.com/store/apps/details?id=$appIdentifier';

    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 404) {
      return null;
    }

    final document = parseHtmlDocument(response.body);

    app.name = document.querySelector('[itemprop="name"]')!.innerText.trim();

    final appDescription =
        document.querySelector('[data-g-id="description"]')!.innerHtml!.trim();
    app.description = markdown.convert(appDescription);

    final iconUrls = document
        .querySelectorAll('img[itemprop="image"]')
        .map((e) => e.attributes['src'])
        .nonNulls;
    final iconUrl = iconUrls.first;
    final iconHash = await fetchFile(iconUrl);
    app.addIcon(iconHash);

    // TODO: Banner

    final imageUrls = document
        .querySelectorAll('img[data-screenshot-index]')
        .map((e) => e.attributes['src'])
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        final imageHash = await fetchFile(imageUrl);
        app.addImage(imageHash);
      }
    }
    return app;
  }
}
