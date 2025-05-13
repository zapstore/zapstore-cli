import 'package:models/models.dart';
import 'package:zapstore_cli/commands/publish/fetchers/fetcher.dart';
import 'package:zapstore_cli/utils.dart';

class FastlaneFetcher extends Fetcher {
  @override
  String get name => 'Remote Fastlane Git fetcher';

  @override
  Future<PartialApp?> run({required String appIdentifier}) async {
    throw UnimplementedError();
  }
}

getScript(String repository) {
  final uri = Uri.parse(repository);
  final tmpDir = getFilePathInTempDirectory(uri.path);
  return '''
git init $tmpDir
cd $tmpDir
git config core.sparseCheckout true
echo "fastlane/" >> .git/info/sparse-checkout
git remote add origin $repository
git fetch --depth 1 origin HEAD
git checkout FETCH_HEAD
''';
}
