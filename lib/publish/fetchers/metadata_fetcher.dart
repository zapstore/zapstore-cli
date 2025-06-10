import 'package:cli_spin/cli_spin.dart';
import 'package:models/models.dart';

abstract class MetadataFetcher {
  String get name;
  Future<void> run({required PartialApp app, CliSpin? spinner});
}
