import 'package:cli_spin/cli_spin.dart';
import 'package:models/models.dart';
import 'package:universal_html/parsing.dart';
import 'package:http/http.dart' as http;
import 'package:html2md/html2md.dart' as markdown;
import 'package:zapstore_cli/publish/fetchers/metadata_fetcher.dart';
import 'package:zapstore_cli/utils/file_utils.dart';

class PlayStoreMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'Google Play Store metadata fetcher';

  @override
  Future<void> run({required PartialApp app, CliSpin? spinner}) async {
    final spinnerText = spinner?.text;
    final url =
        'https://play.google.com/store/apps/details?id=${app.identifier}';

    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 404) {
      throw 'not found';
    }

    final document = parseHtmlDocument(response.body);

    app.name ??= document.querySelector('[itemprop="name"]')!.innerText.trim();

    if (app.description == null) {
      final appDescription = document
          .querySelector('[data-g-id="description"]')!
          .innerHtml!
          .trim();
      app.description = markdown.convert(appDescription);
    }

    if (app.icons.isEmpty) {
      final iconUrls = document
          .querySelectorAll('img[itemprop="image"]')
          .map((e) => e.attributes['src'])
          .nonNulls;
      final iconUrl = stripDimensions(iconUrls.first);
      spinner?.text = '$spinnerText: $iconUrl';
      final iconHash = await fetchFile(iconUrl);
      app.addIcon(iconHash);
    }

    final imageUrls = document
        .querySelectorAll('img[data-screenshot-index]')
        .map((e) => e.attributes['src'])
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        spinner?.text = '$spinnerText: ${stripDimensions(imageUrl)}';
        final imageHash = await fetchFile(stripDimensions(imageUrl));
        app.addImage(imageHash);
      }
    }
  }

  String stripDimensions(String url) {
    final uri = Uri.parse(url);
    final p = uri.path.split('=').firstOrNull ?? uri.path;
    return uri.replace(path: p).toString();
  }
}
