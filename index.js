import { install } from './src/install';
import { list } from './src/list';
import { disable, enable } from './src/enable';
import { remove } from './src/remove';
import { Command } from "commander";
import figlet from "figlet";

const program = new Command();

program
  .name('zapstore')
  .description(`${figlet.textSync("zap.store")}\nThe permissionless app store powered by your social network`)
  .version('0.0.1');

program.command('install')
  .alias('i')
  .description('Install a package')
  .argument('<package>', 'Package name')
  .action(async (value) => await install(value));

program.command('remove')
  .alias('r')
  .description('Remove a package')
  .argument('<package>', 'Package name')
  .action(async (value) => await remove(value));

program.command('enable')
  .alias('e')
  .description('Enable a package')
  .argument('<package>', 'Package name')
  .action(async (value) => await enable(value));

program.command('disable')
  .alias('d')
  .description('Disable a package')
  .argument('<package>', 'Package name')
  .action(async (value) => await disable(value));

program.command('list')
  .alias('l')
  .description('List installed packages')
  .action(async () => await list());

await program.parseAsync(process.argv);