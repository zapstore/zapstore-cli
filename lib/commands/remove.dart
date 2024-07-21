import 'package:cli_dialog/cli_dialog.dart';
import 'package:process_run/process_run.dart';
import 'package:zapstore_cli/utils.dart';

Future<void> remove(String value) async {
  final db = await loadPackages();
  if (db[value] != null && value != 'zapstore') {
    final dialog = CLI_Dialog(
      booleanQuestions: [
        [
          'Are you sure you want to remove all versions of package $value? (You can choose to unlink it instead)',
          '_'
        ],
      ],
      trueByDefault: false,
    );
    final ok = dialog.ask()['_'] as bool;

    if (ok) {
      // Remove link and executables
      await run('sh -c "rm -f $value *-$value@-*"',
          workingDirectory: kBaseDir, verbose: false);
      print('Removed all versions of package $value');
    }
  } else {
    print('No packages to remove');
  }
}
