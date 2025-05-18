import 'package:cli_spin/cli_spin.dart';
import 'package:zapstore_cli/models/package.dart';

Future<void> remove(String name) async {
  final spinner = CliSpin(
    text: 'Removing $name...',
    spinner: CliSpinners.dots,
  ).start();
  final db = await Package.loadAll();
  if (db[name] != null && name != 'zapstore') {
    // Remove link and executables
    await db[name]!.remove();
    spinner.success('Removed $name');
  } else {
    spinner.fail('No packages to remove');
  }
}
