import 'package:zapstore_cli/models/package.dart';

Future<void> remove(String name) async {
  final db = await Package.loadAll();
  if (db[name] != null && name != 'zapstore') {
    // Remove link and executables
    await db[name]!.remove();
    print('Removed $name');
  } else {
    print('No packages to remove');
  }
}
