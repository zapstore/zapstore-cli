import 'package:cli_spin/cli_spin.dart';
import 'package:http/http.dart' as http;
import 'package:models/models.dart';
import 'package:zapstore_cli/publish/fetchers/metadata_fetcher.dart';
import 'package:zapstore_cli/publish/gitlab_parser.dart';
import 'package:zapstore_cli/utils/utils.dart';

class GitlabMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'Gitlab metadata fetcher';

  @override
  Future<void> run({required PartialApp app, CliSpin? spinner}) async {
    final repositoryEndpoint =
        'https://gitlab.com/api/v4/projects/${GitlabParser.getRepositoryName(app.repository!)}';
    final repoJson = await http.get(Uri.parse(repositoryEndpoint)).getJson();

    app.description ??= repoJson['description'];
    app.license ??= repoJson['license'];

    app.tags.addAll({...repoJson['topics'], ...repoJson['tag_list']});
  }
}
