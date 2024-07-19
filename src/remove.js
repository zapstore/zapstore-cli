import { confirm } from '@inquirer/prompts';
import { $ } from "bun";
import { loadPackages } from '../utils';

export const remove = async (value) => {
  const db = await loadPackages();
  if (db[value]) {
    const ok = await confirm({
      message: `Are you sure you want to remove all versions of package ${value}? (You can choose to disable it instead)`,
      default: false
    });
    if (ok) {
      // Remove link and executables
      await $`rm ${value} *-${value}@-*`.quiet();
      console.log('Removed all versions of package', value);
    }
  } else {
    console.log('No packages to remove');
  }
};