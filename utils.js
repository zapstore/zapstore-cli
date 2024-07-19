import { $ } from "bun";
import { homedir } from "os";
import { join, basename } from 'path';
import chalk from 'chalk';

export const BASE_DIR = join(homedir(), '.zapstore');

export async function loadPackages() {
  // Ensure presence of zapstore directory
  await $`mkdir -p $DIR`.env({ DIR: BASE_DIR }).quiet();
  $.cwd(BASE_DIR);

  // Ensure zapstore is copied over to base dir
  const thisExecutable = Bun.env._;
  const file = Bun.file(join(BASE_DIR, 'zapstore'));
  if (!await file.exists()) {
    const newPath = join(BASE_DIR, '78ce6faa72264387284e647ba6938995735ec8c7d5c5a65737e55130f026307d-zapstore@-0.0.1');
    await $`cp $SRC $DEST`.env({ SRC: thisExecutable, DEST: newPath }).quiet();
    await $`ln -sf $PATH $NAME`.env({ PATH: newPath, NAME: 'zapstore' }).quiet();
  }

  const _links = await $`find . -type l`.text();
  const links = _links.trim() && _links.trim().split('\n').map(e => e.slice(2));

  const _programs = await $`find . -type f`.text();
  const programs = _programs.trim() && _programs.trim().split('\n').map(e => e.slice(2)).filter(e => e != '_.json') || [];

  const db = {};
  for (const p of programs) {
    const [name, version] = p.slice(65).split('@-');
    db[name] ??= [];
    db[name].push({
      pubkey: p.slice(0, 64),
      version,
    });
  }

  // Determine which versions are enabled
  for (const link of links) {
    const file = await $`readlink $PATH`.env({ PATH: link }).text();
    if (file.trim()) {
      const [_, version] = file.trim().slice(65).split('@-');
      const a = db[link] && db[link].find(a => a.version == version);
      if (a) {
        a.enabled = true;
      }
    }
  }

  return db;
}

export function compareVersions(v1, v2) {
  const v1Parts = v1.split('.').map(Number);
  const v2Parts = v2.split('.').map(Number);

  for (let i = 0; i < Math.max(v1Parts.length, v2Parts.length); i++) {
    const v1Part = v1Parts[i] || 0;
    const v2Part = v2Parts[i] || 0;
    if (v1Part < v2Part) return -1;
    if (v1Part > v2Part) return 1;
  }

  return 0;
}

export function formatProfile(p, k) {
  return `${chalk.bold(p.display_name || p.name)} ${p.nip05 ? `(${p.nip05}) ` : ''}- https://nostr.com/${k}`;
}

export function getTag(event, tagName) {
  const tag = event.tags.find(t => t[0] == tagName);
  return tag && tag[1];
}

export async function fetchWithProgress(url, spinner) {
  const response = await fetch(url);

  // Ensure the response is OK and has Content-Length
  if (!response.ok) {
    throw new Error('Network response was not ok');
  }

  const contentLength = response.headers.get('Content-Length');
  if (!contentLength) {
    throw new Error('Content-Length response header is missing');
  }

  const total = parseInt(contentLength, 10);
  let loaded = 0;

  const reader = response.body.getReader();
  const chunks = [];

  // Read the stream
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    if (value instanceof Uint8Array) {
      chunks.push(value);
    }

    loaded += value.byteLength;
    const progress = (loaded / total) * 100;

    spinner.text = `Downloading package... ${progress.toFixed(2)}%`;
  }

  const data = new Uint8Array(loaded);
  let position = 0;

  for (const chunk of chunks) {
    data.set(chunk, position);
    position += chunk.length;
  }
  return data;
}