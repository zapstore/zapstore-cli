import 'dart:io';

import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/commands/publish/parser.dart';

class LocalParser extends ArtifactParser {
  LocalParser(super.appMap, super.os);

  @override
  Future<void> applyMetadata() async {
    await super.applyMetadata();
  }
}
