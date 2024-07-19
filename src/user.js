import { input } from '@inquirer/prompts';
import { $ } from "bun";
import { join } from 'path';
import chalk from 'chalk';
import { BASE_DIR } from '../utils';

export const ensureUser = async () => {
  const file = Bun.file(join(BASE_DIR, '_.json'));
  const user = await file.exists() ? JSON.parse(await file.text()) : {};

  if (!user.npub) {
    console.log(chalk.bold.bgGray('Welcome to zap.store!'));
    const path = await $`echo $PATH`.text();
    if (!path.includes(BASE_DIR)) {
      console.log();
      console.log(`For this to work you need to add "${BASE_DIR}" to your PATH`);
    }
    console.log();
    console.log('Please input your npub, we will use it to check your web of trust before installing any new packages');
    user.npub = await input({ message: 'npub:' });
    await Bun.write(join(BASE_DIR, '_.json'), JSON.stringify(user));
  }
  return user;
};