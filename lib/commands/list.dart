import 'package:collection/collection.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/models/package.dart';

void list() async {
  final db = await Package.loadAll();

  if (db.isEmpty) {
    print('No packages installed');
  }

  final orderedEntries = db.entries.sortedBy((e) => e.key);
  for (final MapEntry(:key, value: package) in orderedEntries) {
    print('${key.bold()}: ${package.version}');
  }
}
