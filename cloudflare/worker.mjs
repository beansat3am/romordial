import { script, hourglass } from './payload.mjs';

const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
function reply(body, status = 200, type = 'text/plain; charset=utf-8') {
  return new Response(body, { status, headers: { ...headers, 'Content-Type': type } });
}

function loader(base) {
  return `local base = ${JSON.stringify(base)}
local key = getgenv().ROMORDIAL_KEY
assert(type(key) == "string" and #key >= 32, "Set getgenv().ROMORDIAL_KEY first")
local send = request or http_request or (syn and syn.request)
assert(type(send) == "function", "Executor needs an HTTP request function")
local function fetch(path)
    local result = send({Url = base .. path, Method = "GET", Headers = {Authorization = "Bearer " .. key}})
    assert(result and result.StatusCode == 200, "romordial access denied or server unavailable")
    return result.Body
end
local source = fetch("/script")
if type(writefile) == "function" then
    pcall(function() writefile("romordial-hourglass.png", fetch("/hourglass.png")) end)
end
local run, compileError = loadstring(source)
assert(run, compileError)
run()
`;
}

export async function allowed(request, env, now = Date.now()) {
  const authorization = request.headers.get('Authorization') || '';
  if (!authorization.startsWith('Bearer ')) return false;
  const key = authorization.slice(7);
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(key)) return false;
  let records;
  try { records = JSON.parse(env.ACCESS_KEYS_JSON); } catch { return false; }
  if (!records || typeof records !== 'object' || Array.isArray(records)) return false;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  if (!Object.hasOwn(records, hash)) return false;
  const record = records[hash];
  if (!record || record.enabled !== true) return false;
  if (record.expiresAt !== null && (!Number.isFinite(record.expiresAt) || record.expiresAt <= now)) return false;
  return true;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET') return reply('Method not allowed', 405);
    if (url.pathname === '/loader.lua') return reply(loader(url.origin));
    if (url.pathname !== '/script' && url.pathname !== '/hourglass.png') return reply('Not found', 404);
    if (!await allowed(request, env)) return reply('Access denied', 401);
    if (url.pathname === '/script') return reply(script);
    const image = Uint8Array.from(atob(hourglass), character => character.charCodeAt(0));
    return reply(image, 200, 'image/png');
  }
};
