import 'package:interact_cli/interact_cli.dart';
import 'package:zapstore_cli/models/package.dart';

Future<void> remove(String name) async {
  final db = await loadPackages();
  if (db[name] != null && name != 'zapstore') {
    final removePackage = Confirm(
      prompt: 'Are you sure you want to remove all versions of package $name?',
      defaultValue: false,
    ).interact();

    if (removePackage) {
      // Remove link and executables
      await db[name]!.remove();
      print('Removed all versions of package $name');
    }
  } else {
    print('No packages to remove');
  }
}
