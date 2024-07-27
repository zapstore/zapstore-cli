import 'package:interact_cli/interact_cli.dart';
import 'package:zapstore_cli/utils.dart';

Future<void> remove(String value) async {
  final db = await loadPackages();
  if (db[value] != null && value != 'zapstore') {
    final removePackage = Confirm(
      prompt:
          'Are you sure you want to remove all versions of package $value? (You can choose to unlink it instead)',
      defaultValue: false,
    ).interact();

    if (removePackage) {
      // Remove link and executables
      await runInShell('rm -f $value *-$value@-*', workingDirectory: kBaseDir);
      print('Removed all versions of package $value');
    }
  } else {
    print('No packages to remove');
  }
}
