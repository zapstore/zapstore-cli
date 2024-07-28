import 'package:html/parser.dart';
import 'package:zapstore_cli/commands/publish/fetchers.dart';
import 'package:zapstore_cli/models.dart';

class PlayStoreFetcher extends Fetcher {
  // TODO: xq replace with => html
  // TODO: pandoc replace with => html2md

  // TODO: allow publish -a to pass local APKs, prompt for version
  // TODO: fix zapstore app to query platform: android-arm64-v8a in 32267 query (migrate db?)

  @override
  Future<(App, Release, Set<FileMetadata>)> fetch({required App app}) {
    var document =
        parse('<body>Hello world! <a href="www.html5rocks.com">HTML5 rocks!');
    print(document.outerHtml);
    throw UnimplementedError();
  }
}
