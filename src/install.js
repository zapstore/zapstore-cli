import ora from 'ora';
import { $ } from "bun";
import chalk from 'chalk';
import { join, basename } from 'path';
import { validateEvent } from 'nostr-tools';
import { SimplePool } from "nostr-tools/pool";
import { select, confirm } from '@inquirer/prompts';
import { decode, npubEncode } from 'nostr-tools/nip19';
import { BASE_DIR, formatProfile, getTag, loadPackages, compareVersions, fetchWithProgress } from '../utils';
import { ensureUser } from './user';

export const install = async (value) => {
  const db = await loadPackages();
  const user = await ensureUser();

  const pool = new SimplePool();
  const PROFILE_RELAYS = ['wss://relay.damus.io', 'wss://relay.nostr.band', 'wss://relay.primal.net'];
  const ZAPSTORE_HTTP_RELAY = 'https://relay.zap.store';

  const _hostPlatform = await $`uname -sm`.text();
  const hostPlatform = _hostPlatform.trim().toLowerCase().replace(' ', '-');

  const spinner = ora({ text: `Searching for ${value}...`, spinner: 'balloon' }).start();
  const r = await fetch(ZAPSTORE_HTTP_RELAY, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ kinds: [32267], search: value, '#f': [hostPlatform] })
  });
  const apps = await r.json();

  if (apps.length == 0) {
    spinner.fail(`No apps found for ${value}`);
    process.exit(0);
  }

  let packageIndex = 0;
  if (apps.length > 1) {
    const choices = apps.map((e, i) => ({
      name: getTag(e, 'name'),
      value: i
    }));

    packageIndex = await select({
      message: 'Choose from:',
      choices: choices
    });
  }

  const app = apps[packageIndex];
  const appName = getTag(app, 'name');

  const aTag = `32267:${app.pubkey}:${getTag(app, 'd')}`;
  const r2 = await fetch(ZAPSTORE_HTTP_RELAY, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ kinds: [30063], '#a': [aTag], limit: 1 })
  });
  const releases = await r2.json();
  if (releases.length === 0) {
    spinner.fail('No releases found');
    process.exit(0);
  }

  const eTags = releases[0].tags.filter(t => t[0] == 'e').map(t => t[1]);
  const r3 = await fetch(ZAPSTORE_HTTP_RELAY, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ kinds: [1063], 'ids': eTags, '#f': [hostPlatform] })
  });
  const fileMetadatas = await r3.json();

  if (fileMetadatas.length === 0) {
    spinner.fail('No releases found');
    process.exit(0);
  }

  // Validate nostr events
  for (const e of [app, releases[0], ...fileMetadatas]) {
    validateEvent(e);
  }

  const meta = fileMetadatas[0];
  const packageUrl = getTag(meta, 'url');
  const appVersion = getTag(meta, 'version');
  // const appCreatedAt = meta.created_at;

  spinner.succeed(`Found ${appName}@${appVersion}`);

  const appVersions = db[appName];

  let isUpdatable = false;
  let isAuthorTrusted = false;
  if (appVersions) {
    const appVersionInstalled = appVersions.find(v => v.version == appVersion);
    if (appVersionInstalled) {
      if (appVersionInstalled.enabled) {
        spinner.succeed(`Package ${chalk.bold(appName)} is already up to date`);
      } else {
        const appFileName = `${appVersionInstalled.pubkey}-${appName}@-${appVersionInstalled.version}`;
        await $`ln -sf $PATH $NAME`.env({ PATH: appFileName, NAME: appName }).quiet();
        spinner.succeed(`Package ${appName} re-enabled`);
      }
      process.exit(0);
    }

    isAuthorTrusted = appVersions.some(a => meta.pubkey === a.pubkey);

    isUpdatable = appVersions.every(a => compareVersions(appVersion, a.version) == 1);

    if (!isUpdatable) {
      const upToDate = appVersions.some(a => compareVersions(appVersion, a.version) == 0);
      if (upToDate) {
        console.log('Package already up to date', appName, appVersion);
        process.exit(0);
      }

      // Then there must be a -1 (downgrade)
      const higherVersion = appVersions.find(a => compareVersions(appVersion, a.version) == -1);
      const installAnyway = await confirm({
        message: `Are you sure you want to downgrade ${appName} from ${higherVersion.version} to ${appVersion}?`,
        default: false
      });
      if (!installAnyway) {
        process.exit(0);
      }
    }
  }

  const packageBuilder = getTag(app, 'p');
  const builderNpub = npubEncode(packageBuilder);
  const packageSigner = app.pubkey;
  const signerNpub = npubEncode(packageSigner);

  if (!isAuthorTrusted) {
    const wotSpinner = ora({ text: `Checking web of trust...`, spinner: 'balloon' }).start();
    const trust = await (await fetch(`https://trustgraph.live/api/fwf/${user.npub}/${signerNpub}`)).json();
    // Separate querying user from result
    const userFollows = delete trust[user.npub];

    const authors = [...Object.keys(trust).map(npub => decode(npub).data), packageBuilder, packageSigner];
    const r4 = await pool.querySync(PROFILE_RELAYS, { kinds: [0], authors });

    const profiles = {};
    for (const e of r4) {
      profiles[npubEncode(e.pubkey)] = JSON.parse(e.content);
    }
    const signerInfo = profiles[signerNpub];
    const signerText = chalk.bold(signerInfo.display_name || signerInfo.name);

    wotSpinner.succeed();

    console.log();
    console.log(`Package builder: ${formatProfile(profiles[builderNpub], builderNpub)}`);
    console.log(`Package signer: ${formatProfile(signerInfo, signerNpub)}`);
    console.log();

    if (userFollows) {
      console.log(`You follow ${signerText}!`);
      console.log();
    }
    console.log(`${userFollows ? 'Other profiles' : 'Profiles'} you follow who follow ${signerText}:`);
    for (const k of Object.keys(trust)) {
      console.log(` - ${formatProfile(profiles[k], k)}`);
    }
    console.log();

    const installPackage = await confirm({
      message: `Are you sure you trust the signer and want to ${isUpdatable ? 'update' : 'install'} ${appName}${isUpdatable ? ` to ${appVersion}` : ''}?`,
      default: false
    });

    if (!installPackage) {
      process.exit(0);
    }
  } else {
    const r4 = await pool.querySync(PROFILE_RELAYS, { kinds: [0], authors: [packageSigner] });
    const signerInfo = r4.find(e => e.pubkey === packageSigner);
    console.log('si', signerInfo, r4);
    console.log(`Package signed by ${formatProfile(signerInfo, signerNpub)} who was previously trusted for this app`);
  }

  const installSpinner = ora({ text: `Downloading package...`, spinner: 'balloon' }).start();
  const appFileName = `${meta.pubkey}-${appName}@-${appVersion}`;
  const downloadPath = join(BASE_DIR, basename(packageUrl));
  await Bun.write(downloadPath, await fetchWithProgress(packageUrl, installSpinner));
  const appPath = join(BASE_DIR, appFileName);

  const hash = await $`cat $NAME | shasum -a 256 | head -c 64`.env({ NAME: downloadPath }).text();
  if (hash.trim() !== getTag(meta, 'x')) {
    await $`rm -f $PATH`.env({ PATH: downloadPath }).quiet();
    throw 'Hash mismatch! File server may be malicious, please report';
  }

  // Auto-extract
  if (downloadPath.endsWith('tar.gz')) {
    const extractDir = downloadPath.replace('.tar.gz', '');
    await $`mkdir -p $EXTRACT`.env({ EXTRACT: extractDir }).quiet();
    await $`tar zfx $PATH -C $EXTRACT`.env({ PATH: downloadPath, EXTRACT: extractDir }).quiet();
    await $`mv $SRC $DEST`.env({ SRC: join(extractDir, appName), DEST: appPath });
    await $`rm -fr $EXTRACT $FILE`.env({ EXTRACT: extractDir, FILE: downloadPath });
  } else {
    await $`mv $SRC $DEST`.env({ SRC: downloadPath, DEST: appPath });
  }

  await $`chmod +x $PATH`.env({ PATH: appPath }).quiet();
  await $`ln -sf $PATH $NAME`.env({ PATH: appFileName, NAME: appName }).quiet();
  console.log();

  installSpinner.succeed(`Installed package ${chalk.bold(appName)}@${appVersion}`);
  process.exit(0);
};