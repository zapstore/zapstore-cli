import 'package:tint/tint.dart';
import 'package:zapstore_cli/models/package.dart';

void list() async {
  final db = await Package.loadAll();

  if (db.isEmpty) {
    print('No packages installed');
  }
  for (final MapEntry(:key, value: package) in db.entries) {
    print(
        '${key.bold()} ${package.versions.map((v) => v == package.enabledVersion ? '${v.bold()} (enabled)' : v).toList().reversed.join(', ')}');
  }
}
