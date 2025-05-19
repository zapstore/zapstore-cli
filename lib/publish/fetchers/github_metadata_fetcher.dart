import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/publish/fetchers/metadata_fetcher.dart';
import 'package:zapstore_cli/publish/github_parser.dart';
import 'package:zapstore_cli/utils/utils.dart';

class GithubMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'Github metadata fetcher';

  @override
  Future<void> run({required PartialApp app}) async {
    final repositoryEndpoint =
        'https://api.github.com/repos/${GithubParser.getRepositoryName(app.repository!)}';
    final repoJson = await http
        .get(Uri.parse(repositoryEndpoint), headers: GithubParser.headers)
        .getJson();

    app.description ??= repoJson['description'];

    app.tags.addAll([...repoJson['topics']]);
  }
}
