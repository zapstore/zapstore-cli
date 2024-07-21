import 'package:zapstore_cli/main.dart';
import 'package:zapstore_cli/utils.dart';

void list() async {
  final db = await loadPackages();

  if (db.isEmpty) {
    print('No packages installed');
  }
  for (final MapEntry(:key, :value) in db.entries) {
    print(
        '${logger.ansi.emphasized(key)} ${value.map((e) => (e['enabled'] ?? false) ? '${logger.ansi.emphasized(e['version'])} (enabled)' : e['version']).toList().reversed.join(', ')}');
  }
}
