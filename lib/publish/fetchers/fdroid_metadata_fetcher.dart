import 'package:models/models.dart';
import 'package:zapstore_cli/publish/fetchers/metadata_fetcher.dart';

class FDroidMetadataFetcher extends MetadataFetcher {
  @override
  String get name => 'F-Droid fetcher';

  @override
  Future<PartialApp?> run({required PartialApp app}) async {
    throw UnimplementedError();
  }
}
