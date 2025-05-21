import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dotenv/dotenv.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tint/tint.dart';
import 'package:zapstore_cli/commands/discover.dart';
import 'package:zapstore_cli/commands/install.dart';
import 'package:zapstore_cli/commands/list.dart';
import 'package:zapstore_cli/commands/publish.dart';
import 'package:zapstore_cli/commands/remove.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';

const kVersion = '0.2.0-rc1'; // (!) Also update pubspec.yaml (!)

final DotEnv env = DotEnv(includePlatformEnvironment: true, quiet: true)
  ..load();

late final StorageNotifier storage;
late final ProviderContainer container;

void main(List<String> args) async {
  container = ProviderContainer(overrides: [
    storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
  ]);
  var wasError = false;
  try {
    storage = container.read(storageNotifierProvider.notifier);

    await Package.loadAll(fromCommand: false);

    await storage.initialize(StorageConfiguration(
      databasePath: path.join(kBaseDir, 'storage.db'),
      relayGroups: {
        'zapstore': kAppRelays,
        'vertex': {'wss://relay.vertexlab.io'},
      },
      defaultRelayGroup: 'zapstore',
    ));

    final runner = CommandRunner("zapstore",
        "$figure\nThe permissionless app store powered by your social network")
      ..addCommand(InstallCommand())
      ..addCommand(DiscoverCommand())
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

class DiscoverCommand extends Command {
  @override
  String get name => 'discover';

  @override
  String get description => 'Discover new packages';

  @override
  List<String> get aliases => ['d'];

  @override
  Future<void> run() async {
    await discover();
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
  Future<void> run() async {
    return list(argResults!.rest.firstOrNull);
  }
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

late final String configPath;
late bool overwriteRelease;
late final bool isDaemonMode;
late final bool swear;

class PublishCommand extends Command {
  PublishCommand() {
    argParser.addOption('config',
        abbr: 'c', help: 'Path to zapstore.yaml', defaultsTo: 'zapstore.yaml');
    argParser.addFlag('overwrite-release',
        help:
            'Publishes the release regardless of the latest version on relays',
        defaultsTo: false);
    argParser.addFlag('daemon-mode',
        abbr: 'd',
        help:
            'Run publish in daemon mode (non-interactively and without spinners)');
    argParser.addFlag('swear', help: 'Swear', defaultsTo: false);
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

    overwriteRelease = argResults!.flag('overwrite-release');

    isDaemonMode = argResults!.flag('daemon-mode');

    swear = argResults!.flag('swear');

    await Publisher().run();
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
