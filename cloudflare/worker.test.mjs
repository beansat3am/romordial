import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from './worker.mjs';

const key = 'test_only_abcdefghijklmnopqrstuvwxyz123456';
const hash = createHash('sha256').update(key).digest('hex');
const environment = record => ({ ACCESS_KEYS_JSON: JSON.stringify({ [hash]: record }) });
const request = (path, token = key, method = 'GET') => new Request(`https://example.workers.dev${path}`, {
  method, headers: token === null ? {} : { Authorization: `Bearer ${token}` },
});
test('script is denied without a valid active key', async () => {
  for (const env of [{}, { ACCESS_KEYS_JSON: 'bad-json' }, environment({ enabled: false, expiresAt: null }),
    environment({ enabled: true, expiresAt: Date.now() - 100 }), environment({ enabled: true })]) {
    const response = await worker.fetch(request('/script'), env);
    assert.equal(response.status, 401);
    assert.equal(await response.text(), 'Access denied');
  }
  const env = environment({ enabled: true, expiresAt: null });
  assert.equal((await worker.fetch(request('/script', null), env)).status, 401);
  assert.equal((await worker.fetch(request('/script', 'wrong-key'), env)).status, 401);
});
test('valid keys get current source and image with no caching', async () => {
  const env = environment({ enabled: true, expiresAt: Date.now() + 60000 });
  const response = await worker.fetch(request('/script'), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(await response.text(), /local Players/);
  const image = await worker.fetch(request('/hourglass.png'), env);
  assert.equal(image.headers.get('Content-Type'), 'image/png');
  assert.deepEqual([...new Uint8Array(await image.arrayBuffer()).slice(0, 4)], [137, 80, 78, 71]);
});
test('public loader contains no source or keys; other routes stay closed', async () => {
  const response = await worker.fetch(request('/loader.lua', null), {});
  const text = await response.text();
  assert.equal(response.status, 200);
  assert.match(text, /ROMORDIAL_KEY/);
  assert.ok(!text.includes(key) && !text.includes('local Players'));
  assert.equal((await worker.fetch(request('/unknown'), {})).status, 404);
  assert.equal((await worker.fetch(request('/script', key, 'POST'), {})).status, 405);
  assert.equal((await worker.fetch(request('/hourglass.png', null), {})).status, 401);
});
