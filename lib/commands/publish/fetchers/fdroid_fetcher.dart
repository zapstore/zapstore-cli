import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fetcher.dart';

class FDroidFetcher extends Fetcher {
  @override
  String get name => 'F-Droid fetcher';

  @override
  Future<PartialApp?> run({required String appIdentifier}) async {
    throw UnimplementedError();
  }
}
