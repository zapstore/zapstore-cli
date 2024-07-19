import chalk from "chalk";
import { loadPackages } from "../utils";

export const list = async () => {
  const db = await loadPackages();

  if (Object.keys(db).length === 0) {
    console.log('No packages installed');
  }
  for (const [k, v] of Object.entries(db)) {
    console.log(chalk.bold(k), v.map(e => e.enabled == true ? `${chalk.bold(e.version)} (enabled)` : e.version).reverse().join(', '));
  }
};