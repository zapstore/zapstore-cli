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
import 'package:zapstore_cli/commands/zap.dart';
import 'package:zapstore_cli/models/package.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';

// (!) Also update pubspec.yaml AND zapstore.yaml (!)
const kVersion = '0.2.0-rc4';

final DotEnv env = DotEnv(includePlatformEnvironment: true, quiet: true)
  ..load();

late final StorageNotifier storage;
late final ProviderContainer container;

late final bool autoUpdate;

void main(List<String> args) async {
  container = ProviderContainer(overrides: [
    storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
  ]);
  var wasError = false;

  final runner = CommandRunner("zapstore",
      '$figure${kVersion.bold()}\n\nThe permissionless app store powered by your social network')
    ..addCommand(InstallCommand())
    ..addCommand(DiscoverCommand())
    ..addCommand(ZapCommand())
    ..addCommand(ListCommand())
    ..addCommand(RemoveCommand())
    ..addCommand(PublishCommand());
  runner.argParser.addFlag('version', abbr: 'v', negatable: false);

  final isDevBuild = path.basename(Platform.resolvedExecutable) == 'dart';
  runner.argParser.addFlag('auto-update',
      help: 'Auto-updates the currently installed zapstore',
      defaultsTo: !isDevBuild);

  final argResults = runner.argParser.parse(args);

  autoUpdate = argResults.flag('auto-update');

  if (argResults.flag('version')) {
    print('zapstore ${kVersion.bold()}\n\n(${Platform.resolvedExecutable})');
    return;
  }

  try {
    storage = container.read(storageNotifierProvider.notifier);

    await Package.loadAll(fromCommand: false);

    await storage.initialize(StorageConfiguration(
      databasePath: path.join(kBaseDir, 'zapstore.db'),
      relayGroups: {
        'zapstore': defaultAppRelays,
        'vertex': {'wss://relay.vertexlab.io'},
        'social': {'wss://relay.primal.net'}
      },
      defaultRelayGroup: 'zapstore',
    ));

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
    exit(wasError ? 1 : 0);
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

class ZapCommand extends Command {
  @override
  String get name => 'zap';

  @override
  String get description => 'Zap packages';

  @override
  Future<void> run() async {
    await zap();
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
late bool skipRemoteMetadata;
late bool overwriteRelease;
late final bool isDaemonMode;
late final bool honor;

bool get isNewFormat => env['NEW_FORMAT'] != null;

class PublishCommand extends Command {
  PublishCommand() {
    argParser.addOption('config',
        abbr: 'c',
        help: 'Path to the YAML config file',
        defaultsTo: 'zapstore.yaml');
    argParser.addFlag('skip-remote-metadata',
        help: 'Skip fetching remote metadata', defaultsTo: false);
    argParser.addFlag('overwrite-release',
        help:
            'Publishes the release regardless of the latest version on relays',
        defaultsTo: false);
    argParser.addFlag('daemon-mode',
        abbr: 'd',
        help:
            'Run publish in daemon mode (non-interactively and without spinners)');
    argParser.addFlag('honor',
        help: 'Indicate you will honor tags when external signing',
        defaultsTo: false);
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
    skipRemoteMetadata = argResults!.flag('skip-remote-metadata');

    isDaemonMode = argResults!.flag('daemon-mode');

    honor = argResults!.flag('honor');

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
