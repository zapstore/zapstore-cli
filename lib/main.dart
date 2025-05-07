import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dotenv/dotenv.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/commands/install.dart';
import 'package:zapstore_cli/commands/list.dart';
import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/commands/remove.dart';
import 'package:zapstore_cli/utils.dart';
import 'package:path/path.dart' as path;

const kVersion = '0.2.0'; // (!) Also update pubspec.yaml (!)

final DotEnv env = DotEnv(includePlatformEnvironment: true, quiet: true)
  ..load();

late final StorageNotifier storage;

void main(List<String> args) async {
  final container = ProviderContainer();
  var wasError = false;
  try {
    storage = container.read(storageNotifierProvider.notifier);
    await storage.initialize(StorageConfiguration(
      relayGroups: {
        'zapstore': kAppRelays,
        'social': {'wss://relay.nostr.band', 'wss://relay.primal.net'}
      },
      defaultRelayGroup: 'zapstore',
    ));

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
      print('zapstore-cli $kVersion');
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
    storage.dispose();
    container.dispose();
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

late final bool isDaemonMode;
// TODO: Add pointer to CHANGELOG.md in config yaml
// String? releaseNotes;
late String configPath;
late bool overwriteApp;
late bool overwriteRelease;

class PublishCommand extends Command {
  PublishCommand() {
    argParser.addOption('config',
        abbr: 'c', help: 'Path to zapstore.yaml', defaultsTo: 'zapstore.yaml');
    argParser.addMultiOption('artifact',
        abbr: 'a',
        help: 'Artifact to be uploaded (can be used multiple times)');
    argParser.addOption('release-notes',
        abbr: 'n', help: 'File containing release notes');

    argParser.addFlag('overwrite-app',
        help: 'Generate a new kind 32267 to publish', defaultsTo: false);
    argParser.addFlag('overwrite-release',
        help: 'Generate a new kind 30063 to publish', defaultsTo: false);
    argParser.addFlag('daemon-mode',
        abbr: 'd',
        help:
            'Run publish in daemon mode (non-interactively and without spinners)');
  }

  @override
  String get name => 'publish';

  @override
  String get description => 'Publish a package';

  @override
  List<String> get aliases => ['p'];

  @override
  Future<void> run() async {
    configPath = argResults!.option('config')!;

    // Load env next to config file
    env.load([path.join(path.dirname(configPath), '.env')]);

    // Set daemon mode
    isDaemonMode = argResults!.flag('daemon-mode');

    overwriteApp = argResults!.flag('overwrite-app');
    overwriteRelease = argResults!.flag('overwrite-release');

    await Publisher().initialize();
  }
}

const figure = r'''

 _____                _                 
/ _  / __ _ _ __  ___| |_ ___  _ __ ___ 
\// / / _` | '_ \/ __| __/ _ \| '__/ _ \
 / //\ (_| | |_) \__ \ || (_) | | |  __/
/____/\__,_| .__/|___/\__\___/|_|  \___|
           |_|                          

''';
