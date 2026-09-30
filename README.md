# romordial

## Load the latest version

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/beansat3am/romordial/main/loader.lua"))()
```

No keys or manual downloads are required. The loader fetches the current script and loading-screen asset from this public repository. Updating `bsv2.lua` updates what users receive on their next launch, after GitHub cache propagation.

RightShift toggles the menu. Features start disabled except Remove scoping. Enable Rage and Auto fire for direct weapon firing. Visual effects are under Visuals → Effects.

## Local loading

Download `bsv2.lua` and `romordial-hourglass.png` into your executor workspace:

```lua
loadstring(readfile("bsv2.lua"))()
```

## Verification

Source compilation and local regression checks passed before publishing. In-game performance and server hit registration still require testing.

The `cloudflare` folder contains the earlier optional access-key server. The public GitHub loader does not use it.
