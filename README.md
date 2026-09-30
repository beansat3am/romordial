# romordial

romordial is a Lua script for BloxStrike with combat controls, movement options, and customizable visuals. Its menu keeps settings for aiming, anti-aim, movement, and effects in separate sections.

## Features

- Ragebot controls with target priority, multipoint targeting, and adjustable rapid-fire rate.
- Anti-aim settings for yaw and pitch, with a ForceField ghost to visualize the configured pose.
- Bhop, view-angle movement, WASD air strafe, and quick peek.
- Customizable player, weapon, and viewmodel chams with color and material options.
- Bullet tracers, hit logs, backtrack visuals, character auras, and movement trails.
- A draggable keybind list, custom crosshair, scope removal, and saved configurations.

## Run the script

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/beansat3am/romordial/main/loader.lua"))()
```

Press **RightShift** to open or close the menu. The loader fetches the current script and hourglass asset from this repository, so no key or manual download is needed.
