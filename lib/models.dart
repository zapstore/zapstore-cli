import 'package:purplebase/purplebase.dart';

class App extends BaseApp {
  final Map<String, dynamic>? artifacts;

  App(
      {this.artifacts,
      super.content,
      super.createdAt,
      super.pubkeys,
      super.tags,
      super.identifier,
      super.name,
      super.summary,
      super.repository,
      super.icons,
      super.images,
      super.url,
      super.license});
}

class Release = BaseRelease with NostrMixin;
class FileMetadata = BaseFileMetadata with NostrMixin;
