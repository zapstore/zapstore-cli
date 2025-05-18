import 'package:collection/collection.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/models/package.dart';

void list([String? filter]) async {
  final db = await Package.loadAll();

  if (db.isEmpty) {
    print('No packages installed');
  }

  final regexp = filter != null ? RegExp(filter) : null;

  final orderedEntries = db.entries
      .where((e) => regexp?.hasMatch(e.key) ?? true)
      .sortedBy((e) => e.key);
  for (final MapEntry(:key, value: package) in orderedEntries) {
    print('${key.bold()}: ${package.version}');
  }
}
