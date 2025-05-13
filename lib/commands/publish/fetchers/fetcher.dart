import 'package:models/models.dart';

abstract class Fetcher {
  String get name;
  Future<PartialApp?> run({required String appIdentifier});
}
