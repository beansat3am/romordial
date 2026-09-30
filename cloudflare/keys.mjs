import { randomBytes, createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';

const folder = new URL('../.private-access/', import.meta.url);
await mkdir(folder, { recursive: true });
const file = new URL('keys.json', folder);
let keys;
try { keys = JSON.parse(await readFile(file, 'utf8')); }
catch (error) { if (error.code !== 'ENOENT') throw error; keys = {}; }
const [command, label, days] = process.argv.slice(2);
if (!['create', 'revoke'].includes(command) || !/^[a-zA-Z0-9_-]{1,64}$/.test(label || '')) {
  throw new Error('Use: node keys.mjs create NAME [DAYS] | revoke NAME');
}
if (command === 'create') {
  if (Object.hasOwn(keys, label)) throw new Error('That name already exists');
  const duration = days === undefined ? null : Number(days);
  if (duration !== null && (!Number.isFinite(duration) || duration <= 0)) throw new Error('DAYS must be positive');
  keys[label] = { key: randomBytes(32).toString('base64url'), enabled: true,
    expiresAt: duration === null ? null : Date.now() + duration * 86400000 };
} else {
  if (!Object.hasOwn(keys, label)) throw new Error('Unknown name');
  keys[label].enabled = false;
}
const records = {};
for (const record of Object.values(keys)) {
  const hash = createHash('sha256').update(record.key).digest('hex');
  records[hash] = { enabled: record.enabled, expiresAt: record.expiresAt };
}
await writeFile(file, JSON.stringify(keys, null, 2));
await writeFile(new URL('access-keys.json', folder), JSON.stringify(records));
console.log('Saved local key records in .private-access. Update the Worker secret to apply them.');
