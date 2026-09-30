import { readFile, writeFile } from 'node:fs/promises';

const script = await readFile(new URL('../bsv2.lua', import.meta.url), 'utf8');
const hourglass = await readFile(new URL('../romordial-hourglass.png', import.meta.url));
await writeFile(new URL('payload.mjs', import.meta.url),
  `export const script = ${JSON.stringify(script)};\nexport const hourglass = ${JSON.stringify(hourglass.toString('base64'))};\n`);
const worker = await readFile(new URL('worker.mjs', import.meta.url), 'utf8');
await writeFile(new URL('dashboard-worker.mjs', import.meta.url),
  `const script = ${JSON.stringify(script)};\nconst hourglass = ${JSON.stringify(hourglass.toString('base64'))};\n` +
  worker.replace("import { script, hourglass } from './payload.mjs';", ''));
