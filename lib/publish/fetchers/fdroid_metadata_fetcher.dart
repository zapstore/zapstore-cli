import 'package:cli_spin/cli_spin.dart';
import 'package:html2md/html2md.dart' as markdown;
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:universal_html/parsing.dart';
import 'package:zapstore_cli/publish/fetchers/metadata_fetcher.dart';
import 'package:zapstore_cli/utils/file_utils.dart';

class FDroidMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'F-Droid/Izzy fetcher';

  @override
  Future<void> run({required PartialApp app, CliSpin? spinner}) async {
    final fdroidUrl = 'https://f-droid.org/en/packages/${app.identifier}';
    var response = await http.get(Uri.parse(fdroidUrl));

    if (response.statusCode == 200) {
      return await _parseFdroid(response: response, app: app);
    }

    final izzyUrl =
        'https://apt.izzysoft.de/fdroid/index/apk/${app.identifier}';
    response = await http.get(Uri.parse(izzyUrl));
    if (response.statusCode == 200) {
      return await _parseIzzy(response: response, app: app);
    }

    throw 'HTTP status ${response.statusCode}';
  }

  Future<void> _parseFdroid({
    required http.Response response,
    required PartialApp app,
    CliSpin? spinner,
  }) async {
    final spinnerText = spinner?.text;
    final document = parseHtmlDocument(response.body);

    app.name ??= document.querySelector('.package-name')!.innerText.trim();
    app.summary ??= document
        .querySelector('.package-summary')!
        .innerText
        .trim();

    if (app.description == null) {
      final appDescription = document
          .querySelector('.package-description')!
          .innerHtml!
          .trim();
      app.description = markdown.convert(appDescription);
    }

    if (app.icons.isEmpty) {
      final iconUrls = document
          .querySelectorAll('.package-icon')
          .map((e) => e.attributes['src'])
          .nonNulls;
      final iconUrl = iconUrls.first;
      spinner?.text = '$spinnerText: $iconUrl';
      final iconHash = await fetchFile(iconUrl);
      app.addIcon(iconHash);
    }

    final imageUrls = document
        .querySelectorAll('.screenshot img')
        .map((e) => e.attributes['src'])
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        final imageHash = await fetchFile(imageUrl);
        app.addImage(imageHash);
      }
    }
  }

  Future<void> _parseIzzy({
    required http.Response response,
    required PartialApp app,
    CliSpin? spinner,
  }) async {
    final spinnerText = spinner?.text;
    final document = parseHtmlDocument(response.body);

    app.name ??= document.querySelector('#appdetails h2')!.innerText.trim();

    app.summary ??= document.querySelector('#summary')!.innerText.trim();

    if (app.description == null) {
      final appDescription = document
          .querySelector('#desc p')!
          .innerHtml!
          .trim();
      app.description = markdown.convert(appDescription);
    }

    if (app.icons.isEmpty) {
      final iconUrls = document
          .querySelectorAll('.appicon')
          .map((e) => 'https://apt.izzysoft.de/${e.attributes['src']}')
          .nonNulls;
      final iconUrl = iconUrls.first;
      spinner?.text = '$spinnerText: $iconUrl';
      final iconHash = await fetchFile(iconUrl);
      app.addIcon(iconHash);
    }

    final imageUrls = document
        .querySelectorAll('.screenshots img')
        .map((e) => 'https://apt.izzysoft.de/${e.attributes['src']}')
        .nonNulls;

    for (final imageUrl in imageUrls) {
      if (imageUrl.trim().isNotEmpty) {
        spinner?.text = '$spinnerText: $imageUrl';
        final imageHash = await fetchFile(imageUrl);
        app.addImage(imageHash);
      }
    }
  }
}
