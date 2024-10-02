import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dotenv/dotenv.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/commands/install.dart';
import 'package:zapstore_cli/commands/list.dart';
import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/commands/remove.dart';
import 'package:zapstore_cli/utils.dart';

const kVersion = '0.1.0'; // (!) Also update pubspec.yaml (!)

late final DotEnv env;

void main(List<String> args) async {
  env = DotEnv(includePlatformEnvironment: true)..load();

  var wasError = false;
  try {
    final runner = CommandRunner("zapstore",
        "$figure\nThe permissionless app store powered by your social network")
      ..addCommand(InstallCommand())
      ..addCommand(ListCommand())
      ..addCommand(RemoveCommand())
      ..addCommand(PublishCommand());
    runner.argParser.addFlag('version', abbr: 'v', negatable: false);
    final argResults = runner.argParser.parse(args);

    final version = argResults['version'];
    if (version) {
      print('zap.store $kVersion');
      return;
    }
    await runner.run(args);
  } on GracefullyAbortSignal {
    // silently exit with no error
  } catch (e, stack) {
    final first = e.toString().split('\n').first;
    final rest = e.toString().split('\n').sublist(1).join('\n');
    print('\n${'ERROR'.white().onRed()} ${first.bold()}\n$rest');
    if (e is! UsageException) {
      print(stack.toString().gray());
    }
    wasError = true;
    reset();
  } finally {
    exit(wasError ? 127 : 0);
  }
}

class InstallCommand extends Command {
  InstallCommand() {
    argParser.addFlag('trust',
        abbr: 't', help: 'Trust the signer, do not prompt for a WoT check.');
  }

  @override
  String get name => 'install';

  @override
  String get description => 'Install a package';

  @override
  List<String> get aliases => ['i'];

  @override
  Future<void> run() async {
    if (argResults!.rest.isEmpty) {
      usageException('Please provide a package to install');
    }
    final [value, ..._] = argResults!.rest;
    await install(value, skipWot: argResults!.flag('trust'));
  }
}

class ListCommand extends Command {
  @override
  String get name => 'list';

  @override
  String get description => 'List installed packages';

  @override
  List<String> get aliases => ['l'];

  @override
  Future<void> run() async => list();
}

class RemoveCommand extends Command {
  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a package';

  @override
  List<String> get aliases => ['r'];

  @override
  Future<void> run() async {
    if (argResults!.rest.isEmpty) {
      usageException('Please provide a package to remove');
    }
    final [value, ..._] = argResults!.rest;
    await remove(value);
  }
}

class PublishCommand extends Command {
  PublishCommand() {
    argParser.addMultiOption('artifact',
        abbr: 'a', help: 'Artifact to be uploaded');
    argParser.addOption('release-version', abbr: 'v', help: 'Release version');
    argParser.addOption('release-notes',
        abbr: 'n', help: 'File containing release notes');
    argParser.addOption('icon', help: 'Icon file');
    argParser.addMultiOption('image', abbr: 'i', help: 'Image file');

    argParser.addFlag('overwrite-app',
        help: 'Generate a new kind 32267 to publish', defaultsTo: false);
    argParser.addFlag('overwrite-release',
        help: 'Generate a new kind 30063 to publish', defaultsTo: false);
    argParser.addFlag('daemon',
        abbr: 'd', help: 'Run publish non-interactively');
  }

  @override
  String get name => 'publish';

  @override
  String get description => 'Publish a package';

  @override
  List<String> get aliases => ['p'];

  @override
  Future<void> run() async {
    final value = argResults!.rest.firstOrNull;
    final artifacts = argResults!.multiOption('artifact');
    final releaseVersion = argResults!.option('release-version');
    if (artifacts.isNotEmpty && releaseVersion == null) {
      usageException(
          'Please provide a release version when you pass local artifacts');
    }
    final releaseNotesFile = argResults!.option('release-notes');
    final icon = argResults!.option('icon');
    final images = argResults!.multiOption('image');

    String? releaseNotes;
    if (releaseNotesFile != null) {
      if (File(releaseNotesFile).existsSync()) {
        releaseNotes = File(releaseNotesFile).readAsStringSync();
      } else {
        usageException('Please provide a valid release notes file');
      }
    }

    await publish(
      requestedId: value,
      artifacts: artifacts,
      version: releaseVersion,
      releaseNotes: releaseNotes,
      icon: icon,
      images: images,
      overwriteApp: argResults!.flag('overwrite-app'),
      overwriteRelease: argResults!.flag('overwrite-release'),
      daemon: argResults!.flag('daemon'),
    );
  }
}

const figure = r'''
                     _                 
                    | |                
 ______ _ _ __   ___| |_ ___  _ __ ___ 
|_  / _` | '_ \ / __| __/ _ \| '__/ _ \
 / / (_| | |_) |\__ \ || (_) | | |  __/
/___\__,_| .__(_)___/\__\___/|_|  \___|
         | |                           
         |_|                                               
''';
