import 'package:purplebase/purplebase.dart';

typedef App = BaseApp;
typedef Release = BaseRelease;
typedef FileMetadata = BaseFileMetadata;

extension AppExtension on App {
  String? identifierWithVersion(String version) => '$identifier@$version';
}
