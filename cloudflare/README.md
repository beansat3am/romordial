# Private URL loader

The public `/loader.lua` contains bootstrap code only. `/script` and `/hourglass.png` require a valid bearer key. GitHub stays private; no GitHub token is shipped to users.

## Deploy

From this folder:

```powershell
npm install
npx wrangler login
node keys.mjs create owner
npx wrangler secret put ACCESS_KEYS_JSON --name romordial-loader
npm run deploy
```

Wrangler may ask to create the Worker when setting its first secret. If it requires an existing Worker, run `npm run deploy` first: without its secret all script/asset requests are denied.

For the secret value, paste the contents of `../.private-access/access-keys.json`. Never commit that folder or upload its files. It contains owner-only credentials.

## Share

Read the recipient's key from the local `keys.json`, then give them:

```lua
getgenv().ROMORDIAL_KEY = "RECIPIENT_KEY"
loadstring(game:HttpGet("https://YOUR-WORKER.workers.dev/loader.lua"))()
```

The worker hostname is assigned during deployment. Each person gets a separate key.

## Create or revoke keys

```powershell
node keys.mjs create friend 30
node keys.mjs revoke friend
npx wrangler secret put ACCESS_KEYS_JSON --name romordial-loader
```

Replace the secret with the updated hash records after each change. Revocation stops future downloads; it cannot take back previously downloaded source. Never put raw keys in GitHub, URLs, or the public loader.

## Updates and checks

Update `../bsv2.lua`, then deploy again. Everyone's existing loader fetches the new source. Run `npm run build` and `npm test` before deploying.

Cloudflare configuration reference: https://developers.cloudflare.com/workers/wrangler/configuration/
