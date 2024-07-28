import 'package:tint/tint.dart';
import 'package:zapstore_cli/utils.dart';

void list() async {
  final db = await loadPackages();

  if (db.isEmpty) {
    print('No packages installed');
  }
  for (final MapEntry(:key, :value) in db.entries) {
    print(
        '${key.bold()} ${value.map((e) => (e['enabled'] ?? false) ? '${e['version'].toString().bold()} (enabled)' : e['version']).toList().reversed.join(', ')}');
  }
}
