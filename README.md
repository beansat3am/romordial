# romordial

Current bsv2 Lua script and its loading-screen asset.

## Load locally

Download `bsv2.lua` and `romordial-hourglass.png` into your executor's workspace, then run:

```lua
loadstring(readfile("bsv2.lua"))()
```

Alternatively run `loader.lua` for clearer loading errors. RightShift toggles the menu.

Features start disabled except Remove scoping. Enable Rage and Auto fire to use direct weapon firing. Visual effects are under Visuals → Effects.

## Private sharing

The access-key URL loader is deployed at `https://romordial-loader.asherethan24.workers.dev/loader.lua`.

```lua
getgenv().ROMORDIAL_KEY = "YOUR_INDIVIDUAL_KEY"
loadstring(game:HttpGet("https://romordial-loader.asherethan24.workers.dev/loader.lua"))()
```

Keys are managed locally; server configuration contains only key hashes. The public loader never contains a key or the game script. See `cloudflare/README.md` for creating/revoking keys and deploying updates. Updating GitHub alone does not update the Worker: redeploy after changing the source.

Invite selected GitHub accounts through the repository's Settings → Collaborators. They can download the files after accepting the invitation.

Private raw GitHub URLs require authentication. Do not embed GitHub access tokens in a loader. Use the key-controlled Worker or local loading.

## Verification

The source passed Luau compilation and local regression checks before packaging. Multiplayer hit registration, background firing, visual appearance, and FPS require in-game testing. Cosmetic ghosts do not establish hitbox desync or invulnerability.
