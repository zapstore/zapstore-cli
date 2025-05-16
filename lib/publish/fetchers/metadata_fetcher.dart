import 'package:models/models.dart';

abstract class MetadataFetcher {
  String get name;
  Future<void> run({required PartialApp app});
}
