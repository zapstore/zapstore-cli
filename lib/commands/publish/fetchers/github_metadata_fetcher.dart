import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/fetchers/metadata_fetcher.dart';
import 'package:zapstore_cli/commands/publish/github_parser.dart';
import 'package:zapstore_cli/utils.dart';

class GithubMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'Github metadata fetcher';

  @override
  Future<void> run({required PartialApp app}) async {
    final repoUrl = 'https://api.github.com/repos/${app.repository}';
    final repoJson = await http
        .get(Uri.parse(repoUrl), headers: GithubParser.headers)
        .getJson();

    if (app.description.isEmpty) {
      app.description = repoJson['description'];
    }
    app.tags.addAll([...repoJson['topics']]);
  }
}
