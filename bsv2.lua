--!nolint DeprecatedApi
-- Blowstrike's stack checks inspect caller environments for executor globals.
-- Hide those keys before requiring game modules; keep other globals available.
local _getgenv = getgenv
do
    local TRAPPED = {
        getgenv = true, getrenv = true, getsenv = true,
        hookfunction = true, hookmetamethod = true, hookmetatable = true,
        replaceclosure = true, newcclosure = true,
        getreg = true, getgc = true, getinstances = true, getnilinstances = true,
        checkcaller = true,
    }
    local real = getfenv(1)
    local shim = setmetatable({}, {
        __index = function(_, k) if TRAPPED[k] then return nil end; return real[k] end,
        __newindex = function(_, k, v) real[k] = v end,
    })
    setfenv(1, shim)
end

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Workspace          = game:GetService("Workspace")

local LocalPlayer        = Players.LocalPlayer

-- Missing game modules leave their dependent features unavailable.
local CharacterResolver, BulletClass
do
    local ok1, mod1 = pcall(require, ReplicatedStorage:FindFirstChild("Components")
        and ReplicatedStorage.Components:FindFirstChild("Common")
        and ReplicatedStorage.Components.Common:FindFirstChild("CharacterResolver"))
    if ok1 then CharacterResolver = mod1 end
    local ok2, mod2 = pcall(require, ReplicatedStorage:FindFirstChild("Components")
        and ReplicatedStorage.Components:FindFirstChild("Weapon")
        and ReplicatedStorage.Components.Weapon:FindFirstChild("Classes")
        and ReplicatedStorage.Components.Weapon.Classes:FindFirstChild("Bullet"))
    if ok2 then BulletClass = mod2 end
end
local _bsGameLoaded = CharacterResolver ~= nil and BulletClass ~= nil
local SpectateController
do
    local controllers = ReplicatedStorage:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("SpectateController")
    local ok, mod = false, nil
    if module then ok, mod = pcall(require, module) end
    if ok and type(mod) == "table" and type(mod.GetPlayer) == "function" then SpectateController = mod end
end

local State = {
    debugPrint = false,  -- flip true for [bs] print output from features
    _menuOpen = false,
}

local function dbg(...) if State.debugPrint then print("[bs]", ...) end end

-- Forward declarations for helpers read before their feature block runs.
type ThirdPersonState = { active: boolean, fp: CFrame?, tp: CFrame? }
local Shared = {
    tpState = nil :: ThirdPersonState?,
    armLookOverride = nil :: ((Vector3) -> ())?,
    rageVisualTarget = nil :: (() -> (Vector3?, any))?,
    antiAimVisualPitch = nil :: number?,
    fxColor = nil :: ((number, boolean?) -> Color3)?,
    pushVisualImpact = nil :: ((Vector3?, boolean) -> ())?,
}

-- Ordered UserIds are stored as a string so the existing config serializer
-- can persist the target list without saving live Player instances.
local function focusTargetIds()
    local ids, seen = {}, {}
    local raw = type(State.rageFocusIds) == "string" and State.rageFocusIds or ""
    for token in raw:gmatch("%d+") do
        local id = tonumber(token)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

local function saveFocusTargetIds(ids)
    local strings = {}
    for _, id in ipairs(ids) do strings[#strings + 1] = tostring(id) end
    State.rageFocusIds = table.concat(strings, ",")
end

-- Configs store scalar state, colors, and key codes; underscore keys are transient.
local HttpSvc = game:GetService("HttpService")
local CONFIG_DIR = "bs_configs"
local function configPath(name)
    return CONFIG_DIR .. "/" .. tostring(name or "default") .. ".json"
end
local function encodeValue(v)
    if typeof(v) == "Color3" then
        return { __t = "Color3", r = v.R, g = v.G, b = v.B }
    elseif typeof(v) == "EnumItem" and tostring(v.EnumType) == tostring(Enum.KeyCode) then
        return { __t = "KeyCode", n = v.Name }
    elseif typeof(v) == "Vector3" then
        return { __t = "Vector3", x = v.X, y = v.Y, z = v.Z }
    elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
        return v
    end
    return nil  -- skip functions, threads, tables of instances, etc.
end
local function decodeValue(v)
    if type(v) == "table" and v.__t then
        if v.__t == "Color3" then return Color3.new(v.r, v.g, v.b) end
        if v.__t == "KeyCode" then return Enum.KeyCode[v.n] or Enum.KeyCode.Unknown end
        if v.__t == "Vector3" then return Vector3.new(v.x, v.y, v.z) end
        return nil
    end
    return v
end
Shared.saveConfig = function(name)
    if type(writefile) ~= "function" then return false, "no writefile" end
    local out = {}
    for k, v in pairs(State) do
        if type(k) == "string" and not k:match("^_") then
            local enc = encodeValue(v)
            if enc ~= nil then out[k] = enc end
        end
    end
    if type(isfolder) == "function" and type(makefolder) == "function"
        and not isfolder(CONFIG_DIR) then
        pcall(makefolder, CONFIG_DIR)
    end
    local ok, err = pcall(function()
        writefile(configPath(name), HttpSvc:JSONEncode(out))
    end)
    return ok, err
end
Shared.loadConfig = function(name)
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return false, "no readfile"
    end
    local path = configPath(name)
    if not isfile(path) then return false, "not found" end
    local ok, decoded = pcall(function()
        return HttpSvc:JSONDecode(readfile(path))
    end)
    if not ok or type(decoded) ~= "table" then return false, "bad json" end
    for k, v in pairs(decoded) do
        if k == "tungAuraEnable" or k == "tungCostumeEnable"
            or k == "colTungAura" or k == "hudKillEffect" then continue end
        local val = decodeValue(v)
        if val ~= nil then State[k] = val end
    end
    return true
end
Shared.listConfigs = function()
    if type(listfiles) ~= "function" or type(isfolder) ~= "function" then return {} end
    if not isfolder(CONFIG_DIR) then return {} end
    local names = {}
    for _, path in ipairs(listfiles(CONFIG_DIR)) do
        local n = path:match("([^\\/]+)%.json$")
        if n then names[#names + 1] = n end
    end
    table.sort(names)
    return names
end
Shared.deleteConfig = function(name)
    if type(delfile) ~= "function" or type(isfile) ~= "function" then return false end
    local path = configPath(name)
    if not isfile(path) then return false end
    return pcall(delfile, path)
end

-- Reloading undoes hooks and connections from the previous run.
local _teardowns = {}
if type(_getgenv().__bs_unload) == "function" then pcall(_getgenv().__bs_unload) end
_getgenv().__bs_unload = function()
    for i = #_teardowns, 1, -1 do
        pcall(_teardowns[i])
        _teardowns[i] = nil
    end
    print("[bs] unloaded")
end
_G.__bs_add_teardown = function(fn) _teardowns[#_teardowns + 1] = fn end

local finishLoadingScreen
local loadingStartedAt = os.clock()
do
    local lighting = game:GetService("Lighting")
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local tweenService = game:GetService("TweenService")
    local closed = false

    local old = playerGui:FindFirstChild("bs_loading")
    if old then old:Destroy() end
    old = lighting:FindFirstChild("bs_loading_blur")
    if old then old:Destroy() end
    old = lighting:FindFirstChild("bs_loading_gray")
    if old then old:Destroy() end

    local blur = Instance.new("BlurEffect")
    blur.Name = "bs_loading_blur"
    blur.Size = 32
    blur.Parent = lighting
    local gray = Instance.new("ColorCorrectionEffect")
    gray.Name = "bs_loading_gray"
    gray.Saturation = -1
    gray.Brightness = -0.12
    gray.Parent = lighting

    local gui = Instance.new("ScreenGui")
    gui.Name = "bs_loading"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 10020
    gui.Parent = playerGui

    local shade = Instance.new("Frame")
    shade.Size = UDim2.fromScale(1, 1)
    shade.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    shade.BackgroundTransparency = 0.28
    shade.BorderSizePixel = 0
    shade.Parent = gui

    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(306, 142)
    panel.BackgroundColor3 = Color3.fromRGB(19, 19, 19)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 4)
    panelCorner.Parent = panel
    local border = Instance.new("UIStroke")
    border.Color = Color3.fromRGB(55, 55, 55)
    border.Thickness = 1
    border.Parent = panel

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 40)
    header.BackgroundColor3 = Color3.fromRGB(29, 29, 29)
    header.BorderSizePixel = 0
    header.Parent = panel
    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 4)
    headerCorner.Parent = header
    local divider = Instance.new("Frame")
    divider.Position = UDim2.fromOffset(0, 39)
    divider.Size = UDim2.new(1, 0, 0, 1)
    divider.BackgroundColor3 = Color3.fromRGB(109, 77, 92)
    divider.BorderSizePixel = 0
    divider.Parent = header

    local brand = Instance.new("TextLabel")
    brand.Size = UDim2.new(1, -32, 0, 32)
    brand.Position = UDim2.fromOffset(16, 4)
    brand.BackgroundTransparency = 1
    brand.Font = Enum.Font.Gotham
    brand.Text = "romordial"
    brand.TextColor3 = Color3.fromRGB(188, 151, 169)
    brand.TextSize = 17
    brand.TextXAlignment = Enum.TextXAlignment.Left
    brand.Parent = header

    local icon
    if type(getcustomasset) == "function" then
        local ok, asset = pcall(getcustomasset, "romordial-hourglass.png")
        if ok and type(asset) == "string" then
            icon = Instance.new("ImageLabel")
            icon.Position = UDim2.fromOffset(17, 47)
            icon.Size = UDim2.fromOffset(68, 86)
            icon.BackgroundTransparency = 1
            icon.Image = asset
            icon.Parent = panel
        end
    end
    if not icon then
        icon = Instance.new("TextLabel")
        icon.Position = UDim2.fromOffset(17, 57)
        icon.Size = UDim2.fromOffset(68, 64)
        icon.BackgroundTransparency = 1
        icon.Font = Enum.Font.Gotham
        icon.Text = "⧖"
        icon.TextColor3 = Color3.fromRGB(231, 231, 231)
        icon.TextSize = 46
        icon.Parent = panel
    end

    local status = Instance.new("TextLabel")
    status.Size = UDim2.fromOffset(180, 24)
    status.Position = UDim2.fromOffset(100, 67)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.GothamMedium
    status.Text = "Loading..."
    status.TextColor3 = Color3.fromRGB(218, 218, 218)
    status.TextSize = 12
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Parent = panel

    local track = Instance.new("Frame")
    track.Position = UDim2.fromOffset(100, 99)
    track.Size = UDim2.fromOffset(174, 2)
    track.BackgroundColor3 = Color3.fromRGB(49, 49, 49)
    track.BorderSizePixel = 0
    track.ClipsDescendants = true
    track.Parent = panel
    local fill = Instance.new("Frame")
    fill.Position = UDim2.fromOffset(0, 0)
    fill.Size = UDim2.fromOffset(46, 2)
    fill.BackgroundColor3 = Color3.fromRGB(188, 151, 169)
    fill.BorderSizePixel = 0
    fill.Parent = track
    local progress = tweenService:Create(fill,
        TweenInfo.new(1.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { Position = UDim2.fromOffset(128, 0) })
    progress:Play()

    finishLoadingScreen = function()
        if closed then return end
        closed = true
        progress:Cancel()
        gui:Destroy()
        blur:Destroy()
        gray:Destroy()
    end
    _G.__bs_add_teardown(finishLoadingScreen)
    task.delay(12, finishLoadingScreen)
    task.wait()
end

-- ESP uses Drawing primitives; chams use one Highlight per character.
do
    local PlayersSvc = game:GetService("Players")

    State.visualsEnable    = false
    State.visualsTeamCheck = false
    State.espBox       = false  -- chams mark the body; the ESP is text + health
    State.espSkeleton  = false
    State.espHealth    = false
    State.espName      = false
    State.espDistance  = false
    State.espWeapon    = false
    State.espPing      = false
    State.backtrackVisual = false
    State.chamsEnable       = false
    State.chamsThroughWalls = false
    State.chamsEnemy        = false
    State.chamsTeammates    = false
    State.chamsSelf         = false
    State.chamsWeapon       = false
    State.desyncGhost       = false
    State.desyncGhostOpacity = 0.75
    State.desyncGhostOffset = 4
    State.colDesyncGhost    = Color3.fromRGB(83, 229, 255)
    State.chamsStyle        = "glow"
    State.chamsFillOpacity  = 0.7
    State.chamsAnimation    = false
    State.chamsAnimationMode = "pulse"
    State.chamsAnimationSpeed = 1.5
    State.chamsAnimationStrength = 0.65
    State.colChamAnimation = Color3.fromRGB(91, 212, 232)
    State.weaponChamFillOpacity = 0.2
    State.weaponMaterial    = "original"
    State.weaponMaterialTint = false
    State.weaponMaterialHideTextures = false
    State.weaponMaterialThirdPerson = false
    State.chamsOutlineOpacity = 0.95
    State.chamsSceneTint    = false
    State.chamsTintStrength = 0.3
    State.colChamVisible    = Color3.fromRGB(224, 88, 226)
    State.colChamHidden     = Color3.fromRGB(95, 72, 244)
    State.colChamTeammate   = Color3.fromRGB(117, 126, 246)
    State.colChamSelf       = Color3.fromRGB(181, 103, 238)
    State.colChamWeapon     = Color3.fromRGB(237, 72, 208)
    State.colChamStale      = Color3.fromRGB(142, 105, 190)
    State.colChamOutline    = Color3.fromRGB(243, 221, 255)
    State.colChamTint       = Color3.fromRGB(173, 130, 237)
    State.auraEnable        = false
    State.auraStyle         = "electric"
    State.auraIntensity     = 0.6
    State.moveTrail         = false
    State.moveTrailLifetime = 0.35
    State.colMoveTrail      = Color3.fromRGB(188, 151, 169)
    State.espHideWhenDead   = false   -- 2D ESP off while spectating (chams stay)

    State.colVisible = Color3.fromRGB(120, 255, 120)  -- enemy in your line of sight
    State.colHidden  = Color3.fromRGB(255, 90, 90)    -- enemy behind cover
    State.colAlly    = Color3.fromRGB(120, 200, 255)  -- teammates
    State.colText    = Color3.fromRGB(230, 232, 245)  -- ESP name text
    local COL_TEXT     = Color3.fromRGB(230, 232, 245)  -- HUD / defaults
    local COL_STALE    = Color3.fromRGB(170, 170, 185)  -- last-known position (server stopped sending)
    local COL_TEXT_DIM = Color3.fromRGB(175, 178, 195)
    local COL_PING_OK  = Color3.fromRGB(140, 220, 150)
    local COL_PING_MID = Color3.fromRGB(235, 200, 110)
    local COL_PING_BAD = Color3.fromRGB(240, 110, 110)

    -- Blowstrike's "Ping" remotes are map markers, not player latency.
    local function pingOf(plr)
        local v = plr:GetAttribute("Ping")
        if type(v) ~= "number" then
            local ls = plr:FindFirstChild("leaderstats")
            local st = ls and ls:FindFirstChild("Ping")
            v = st and tonumber(st.Value)
            if v then return math.floor(v) end
            local ok, s = pcall(function() return plr:GetNetworkPing() end)
            if not ok or type(s) ~= "number" or s <= 0 then return nil end
            return math.floor(s * 1000)
        end
        return math.floor(v)
    end

    local function isEnemyOf(plr)
        -- Team filtering changes who is drawn, not who counts as an enemy.
        if plr == LocalPlayer then return false end
        if workspace:GetAttribute("Gamemode") == "Deathmatch" then return true end
        -- Blowstrike keeps teams in a player attribute, not Roblox Teams.
        local ma, pa = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
        if ma ~= nil and pa ~= nil then return ma ~= pa end
        local mt, pt = LocalPlayer.Team, plr.Team
        if mt and pt and mt == pt then return false end
        return true
    end

    -- Ignore other characters and invisible clips when checking line of sight.
    local _losParams
    -- Invisible clip walls and other players' bodies don't block sight, so
    -- the ray skips past them (up to 4 re-casts) instead of calling it cover.
    local function computeCharVisible(char, camPos, targetPos)
        _losParams = _losParams or RaycastParams.new()
        _losParams.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = { LocalPlayer.Character or LocalPlayer }
        for _ = 1, 5 do
            _losParams.FilterDescendantsInstances = ignore
            local hit = Workspace:Raycast(camPos, targetPos - camPos, _losParams)
            if not hit then return true end  -- nothing in the way
            local inst = hit.Instance
            if inst:IsDescendantOf(char) then return true end
            -- Walk up: weapon/accessory models nest inside the character.
            local model = inst:FindFirstAncestorOfClass("Model")
            while model and not PlayersSvc:GetPlayerFromCharacter(model) do
                model = model:FindFirstAncestorOfClass("Model")
            end
            if model then
                ignore[#ignore + 1] = model
            elseif inst.Transparency >= 0.95 then
                ignore[#ignore + 1] = inst
            else
                return false
            end
        end
        return false
    end
    local visibilityCache = setmetatable({}, { __mode = "k" })
    local function isCharVisible(char, camPos, targetPos)
        local now = os.clock()
        local cached = visibilityCache[char]
        if cached and now - cached.at < 0.12
            and (camPos - cached.camPos).Magnitude < 2
            and (targetPos - cached.targetPos).Magnitude < 2 then
            return cached.visible
        end
        local visible = computeCharVisible(char, camPos, targetPos)
        visibilityCache[char] = {
            at = now, camPos = camPos, targetPos = targetPos, visible = visible,
        }
        return visible
    end

    -- RemoteCharacters.PresentedFrame marks live poses; missing updates leave frozen shells.
    -- Without its entries table, liveness stays unknown rather than guessed.
    local presentEntries, _lastEntryScan = nil, -math.huge
    local function findPresentEntries()
        if presentEntries or os.clock() - _lastEntryScan < 1 then return presentEntries end
        _lastEntryScan = os.clock()  -- table is empty until someone spawns; retry each second
        pcall(function()
            local RC = require(ReplicatedStorage.Controllers.CharacterController.RemoteCharacters)
            local getups = debug.getupvalues or getupvalues
            for _, up in pairs(getups(RC.Present)) do
                if type(up) == "table" then
                    for k, e in pairs(up) do
                        if typeof(k) == "Instance" and k:IsA("Player")
                            and type(e) == "table" and e.PresentedFrame ~= nil then
                            presentEntries = up
                            return
                        end
                    end
                end
            end
        end)
        return presentEntries
    end

    local liveInfo = {}  -- [player] = { stamp, pos, at }
    local STALE_AFTER = 0.3
    local function staleSeconds(plr, hrp, now)
        local info = liveInfo[plr]
        if not info then info = { at = now }; liveInfo[plr] = info end
        local entries = findPresentEntries()
        local e = entries and entries[plr]
        if not e then return 0 end  -- no game data: don't guess (a moved-check greys out campers)
        if e.PresentedFrame ~= info.stamp then info.stamp = e.PresentedFrame; info.at = now end
        local age = now - info.at
        return age > STALE_AFTER and age or 0
    end

    -- RemoteCharacters hides shells that never got a pose (setEntryVisible
    -- false): they sit at a meaningless spot, so draw nothing for them.
    local function hiddenByGame(plr)
        local entries = findPresentEntries()
        local e = entries and entries[plr]
        return e ~= nil and e.Visible == false
    end
    Shared.hiddenByGame = hiddenByGame
    -- (entriesTable, entryOrNil). Dead players are REMOVED from the table,
    -- so "table readable but no entry" means not a live character.
    Shared.presentEntry = function(plr)
        local entries = findPresentEntries()
        return entries, entries and entries[plr]
    end
    Shared.staleSeconds = staleSeconds

    -- Weapon name from the game's own source: Player.CurrentEquipped is a
    -- JSON blob with a Name field (see RemoteCharacters.decodeCurrentEquipped).
    local HttpService = game:GetService("HttpService")
    local weaponCache = {}  -- [raw json] = name
    local function weaponName(plr)
        local raw = plr:GetAttribute("CurrentEquipped")
        if type(raw) ~= "string" or raw == "" then return "" end
        local hit = weaponCache[raw]
        if hit == nil then
            local ok, t = pcall(HttpService.JSONDecode, HttpService, raw)
            hit = ok and type(t) == "table" and type(t.Name) == "string" and t.Name or ""
            weaponCache[raw] = hit
        end
        return hit
    end

    -- Root joints can freeze apart from the animated body, so omit them.
    local MAX_BONES = 16
    local jointCache = setmetatable({}, { __mode = "k" })
    local partCache = setmetatable({}, { __mode = "k" })
    local function watchDescendants(cache, char, accepts)
        local entry = cache[char]
        if entry then return entry.list end
        entry = { list = {} }
        local function add(inst)
            if accepts(inst) then entry.list[#entry.list + 1] = inst end
        end
        for _, inst in ipairs(char:GetDescendants()) do add(inst) end
        entry.added = char.DescendantAdded:Connect(add)
        entry.removing = char.DescendantRemoving:Connect(function(inst)
            for i = #entry.list, 1, -1 do
                if entry.list[i] == inst then table.remove(entry.list, i); break end
            end
        end)
        cache[char] = entry
        return entry.list
    end
    local function skeletonJoints(char)
        local joints = watchDescendants(jointCache, char, function(m)
            return m:IsA("Motor6D") and m.Part0 and m.Part1
                and m.Part0.Name ~= "HumanoidRootPart" and m.Part1.Name ~= "HumanoidRootPart"
        end)
        return joints
    end

    -- Root and camera parts can freeze away from the animated body.
    local function bodyParts(char)
        return watchDescendants(partCache, char, function(p)
            return p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" and p.Name ~= "CameraPart"
        end)
    end

    -- World-aligned AABB of the body, as (CFrame, size). Ignores parts more
    -- than 6 studs from the anchor (dropped guns, stray accessories).
    local function bodyBounds(char, anchor)
        local ap = anchor.Position
        local minV, maxV
        for _, p in ipairs(bodyParts(char)) do
            if p.Parent then
                local pos = p.Position
                if (pos - ap).Magnitude < 6 then
                    local h = p.Size / 2
                    local lo, hi = pos - h, pos + h
                    minV = minV and minV:Min(lo) or lo
                    maxV = maxV and maxV:Max(hi) or hi
                end
            end
        end
        if not minV then
            -- Nothing usable: standard 4x5.5x2 body hanging below the head.
            return CFrame.new(ap - Vector3.new(0, 2.25, 0)), Vector3.new(4, 5.5, 2)
        end
        return CFrame.new((minV + maxV) / 2), maxV - minV
    end

    -- Character Highlights need a world parent to render reliably.
    local chamsFolder = Instance.new("Folder")
    chamsFolder.Name = "bs_chams"
    chamsFolder.Parent = Workspace

    local chamsByChar = {}  -- [character] = Highlight
    local weaponCham, weaponChamModel, weaponChamConn
    local weaponHighlightsMuted = {}
    local sceneTintEffect
    local weaponInventoryOk, WeaponInventory = pcall(require,
        ReplicatedStorage.Controllers.InventoryController)
    local auraByChar = {}   -- [character] = { attachment, emitter }
    local chamErrorLogged = false

    local function removeAura(char)
        local aura = auraByChar[char]
        if aura then aura.attachment:Destroy(); auraByChar[char] = nil end
    end

    local function ensureAura(char, pivot, color)
        if not State.auraEnable then removeAura(char); return end
        local anchor = char:FindFirstChild("HumanoidRootPart") or pivot
        local aura = auraByChar[char]
        if aura and aura.attachment.Parent ~= anchor then removeAura(char); aura = nil end
        if not aura then
            local attachment = Instance.new("Attachment")
            attachment.Name = "bs_aura"
            attachment.Parent = anchor
            local emitter = Instance.new("ParticleEmitter")
            emitter.Name = "bs_aura_sparks"
            emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
            emitter.Rate = 14
            emitter.Lifetime = NumberRange.new(0.55, 0.9)
            emitter.Speed = NumberRange.new(0.6, 1.5)
            emitter.SpreadAngle = Vector2.new(180, 180)
            emitter.RotSpeed = NumberRange.new(-90, 90)
            emitter.Drag = 1
            emitter.LightEmission = 0.9
            emitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(0.2, 0.28),
                NumberSequenceKeypoint.new(1, 0),
            })
            emitter.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.35),
                NumberSequenceKeypoint.new(1, 1),
            })
            emitter.Parent = attachment
            local glow = Instance.new("ParticleEmitter")
            glow.Name = "bs_aura_glow"
            glow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
            glow.Rate = 5
            glow.Lifetime = NumberRange.new(0.9, 1.4)
            glow.Speed = NumberRange.new(0.1, 0.45)
            glow.SpreadAngle = Vector2.new(180, 180)
            glow.LightEmission = 1
            glow.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.2),
                NumberSequenceKeypoint.new(0.4, 0.95),
                NumberSequenceKeypoint.new(1, 0),
            })
            glow.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.8),
                NumberSequenceKeypoint.new(0.4, 0.7),
                NumberSequenceKeypoint.new(1, 1),
            })
            glow.Parent = attachment
            local light = Instance.new("PointLight")
            light.Name = "bs_aura_light"
            light.Range = 8
            light.Brightness = 0.45
            light.Shadows = false
            light.Parent = attachment
            aura = { attachment = attachment, emitter = emitter, glow = glow, light = light }
            auraByChar[char] = aura
        end
        local style = State.auraStyle
        if style ~= "embers" and style ~= "frost" then
            style = "electric"
        end
        local intensity = math.clamp(tonumber(State.auraIntensity) or 0.6, 0.25, 1)
        if aura.style ~= style or aura.intensity ~= intensity then
            aura.style, aura.intensity = style, intensity
            if style == "embers" then
                aura.emitter.Rate = math.floor(20 * intensity)
                aura.emitter.Speed = NumberRange.new(0.8, 1.8)
                aura.emitter.Lifetime = NumberRange.new(0.65, 1.1)
                aura.emitter.Drag = 0.5
                aura.glow.Rate = math.floor(7 * intensity)
                aura.glow.Size = NumberSequence.new(0.65)
            elseif style == "frost" then
                aura.emitter.Rate = math.floor(15 * intensity)
                aura.emitter.Speed = NumberRange.new(0.15, 0.55)
                aura.emitter.Lifetime = NumberRange.new(1, 1.5)
                aura.emitter.Drag = 1.5
                aura.glow.Rate = math.floor(5 * intensity)
                aura.glow.Size = NumberSequence.new(0.9)
            else
                aura.emitter.Rate = math.floor(18 * intensity)
                aura.emitter.Speed = NumberRange.new(0.6, 1.5)
                aura.emitter.Lifetime = NumberRange.new(0.55, 0.9)
                aura.emitter.Drag = 1
                aura.glow.Rate = math.floor(6 * intensity)
                aura.glow.Size = NumberSequence.new(0.95)
            end
            aura.light.Brightness = 0.15 + 0.25 * intensity
        end
        local tint = style == "embers" and color:Lerp(Color3.fromRGB(255, 125, 48), 0.65)
            or style == "frost" and color:Lerp(Color3.fromRGB(130, 225, 255), 0.65)
            or color
        if aura.color ~= tint then
            aura.color = tint
            aura.emitter.Color = ColorSequence.new(tint)
            aura.glow.Color = ColorSequence.new(tint)
            aura.light.Color = tint
        end
        if not aura.emitter.Enabled then aura.emitter.Enabled = true end
        if not aura.glow.Enabled then aura.glow.Enabled = true end
    end

    local pitchPoseChar, pitchPoseGeneration
    local pitchPoseMotors = {}
    local function restorePitchPose()
        for _, entry in ipairs(pitchPoseMotors) do
            if entry.motor.Parent then entry.motor.C0 = entry.base end
        end
        table.clear(pitchPoseMotors)
        pitchPoseChar, pitchPoseGeneration = nil, nil
    end
    local function updatePitchPose(char)
        local tp = Shared.tpState
        local pitch = Shared.antiAimVisualPitch
        if not char or not State.antiAimEnable or type(pitch) ~= "number"
            or not tp or not tp.active then
            restorePitchPose()
            return
        end
        local generation = char:GetAttribute("CharacterGeneration")
        if pitchPoseChar ~= char or pitchPoseGeneration ~= generation then
            restorePitchPose()
            for name, degrees in pairs({ RightShoulder = 30, LeftShoulder = 30, Waist = 36, Neck = 60 }) do
                local motor = char:FindFirstChild(name, true)
                if motor and motor:IsA("Motor6D") then
                    pitchPoseMotors[#pitchPoseMotors + 1] = {
                        motor = motor, base = motor.C0, angle = math.rad(degrees),
                    }
                end
            end
            pitchPoseChar, pitchPoseGeneration = char, generation
        end
        pitch = math.clamp(pitch, -1, 1)
        for _, entry in ipairs(pitchPoseMotors) do
            if entry.motor.Parent then
                local pose = entry.base * CFrame.Angles(pitch * entry.angle, 0, 0)
                if entry.motor.C0 ~= pose then entry.motor.C0 = pose end
            end
        end
    end

    local gameHlCache = setmetatable({}, { __mode = "k" })
    local mutedHighlights = setmetatable({}, { __mode = "k" }) -- [Highlight] = Enabled before we muted it
    local outsideHl, outsideDirty, outsideRevision = {}, true, 0
    local outsideConns = {}
    local cameraConns = {}
    local outsideAdorneeConns = setmetatable({}, { __mode = "k" })
    local function invalidateOutside(inst)
        if inst:IsA("Highlight") then
            outsideDirty = true
            outsideRevision = outsideRevision + 1
        end
    end
    local function watchOutside(root, recursive, conns)
        if not root then return end
        local added = recursive and root.DescendantAdded or root.ChildAdded
        local removed = recursive and root.DescendantRemoving or root.ChildRemoved
        conns[#conns + 1] = added:Connect(invalidateOutside)
        conns[#conns + 1] = removed:Connect(invalidateOutside)
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    watchOutside(pg, true, outsideConns)
    watchOutside(Workspace, false, outsideConns)
    local function watchCamera()
        for _, conn in ipairs(cameraConns) do conn:Disconnect() end
        table.clear(cameraConns)
        watchOutside(Workspace.CurrentCamera, true, cameraConns)
        outsideDirty = true
        outsideRevision = outsideRevision + 1
    end
    watchCamera()
    outsideConns[#outsideConns + 1] = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
    if not pg then
        outsideConns[#outsideConns + 1] = LocalPlayer.ChildAdded:Connect(function(child)
            if child.Name == "PlayerGui" then
                watchOutside(child, true, outsideConns)
                outsideDirty = true
                outsideRevision = outsideRevision + 1
            end
        end)
    end
    local function outsideHighlights()
        if not outsideDirty then return outsideHl end
        outsideDirty = false
        outsideHl = {}
        local function scan(list)
            for _, d in ipairs(list) do
                if d:IsA("Highlight") and not d:IsDescendantOf(chamsFolder) then
                    if not outsideAdorneeConns[d] then
                        outsideAdorneeConns[d] = d:GetPropertyChangedSignal("Adornee"):Connect(function()
                            outsideDirty = true
                            outsideRevision = outsideRevision + 1
                        end)
                    end
                    if d.Adornee then outsideHl[#outsideHl + 1] = d end
                end
            end
        end
        pcall(function()
            local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
            if playerGui then scan(playerGui:GetDescendants()) end
            local cam = Workspace.CurrentCamera
            if cam then scan(cam:GetDescendants()) end
            scan(Workspace:GetChildren())
        end)
        return outsideHl
    end

    local function gameHighlights(char)
        local c = gameHlCache[char]
        if c and not c.dirty and c.revision == outsideRevision then return c.list end
        if not c then
            c = { dirty = true }
            c.added = char.DescendantAdded:Connect(function(inst)
                if inst:IsA("Highlight") then c.dirty = true end
            end)
            c.removing = char.DescendantRemoving:Connect(function(inst)
                if inst:IsA("Highlight") then c.dirty = true end
            end)
            gameHlCache[char] = c
        end
        local list = {}
        pcall(function()
            for _, d in ipairs(char:GetDescendants()) do
                if d:IsA("Highlight") then list[#list + 1] = d end
            end
            for _, h in ipairs(outsideHighlights()) do
                if h.Adornee == char then list[#list + 1] = h end
            end
        end)
        c.list, c.dirty, c.revision = list, false, outsideRevision
        return list
    end
    local function restoreGameHighlights(char)
        local c = gameHlCache[char]
        if not c then return end
        for _, h in ipairs(c.list) do
            local was = mutedHighlights[h]
            if was ~= nil then
                pcall(function() h.Enabled = was end)
                mutedHighlights[h] = nil
            end
        end
    end

    local function chamOpacity(fillOverride)
        local fill = math.clamp(tonumber(fillOverride)
            or tonumber(State.chamsFillOpacity) or 0.7, 0, 1)
        local outline = math.clamp(tonumber(State.chamsOutlineOpacity) or 0.95, 0, 1)
        if State.chamsStyle == "outline" then fill = 0
        elseif State.chamsStyle == "soft" then fill = fill * 0.55 end
        return fill, outline
    end

    local chamPhase = setmetatable({}, { __mode = "k" })
    local function animatedChamColor(base, adornee, now)
        if not State.chamsAnimation or typeof(base) ~= "Color3" then return base end
        if not adornee then return base end
        local speed = math.clamp(tonumber(State.chamsAnimationSpeed) or 1.5, 0.25, 5)
        local strength = math.clamp(tonumber(State.chamsAnimationStrength) or 0.65, 0, 1)
        local phase = chamPhase[adornee]
        if not phase then
            local name = adornee and adornee.Name or ""
            phase = 0
            for i = 1, #name do phase = phase + string.byte(name, i) * 0.031 end
            chamPhase[adornee] = phase
        end
        local wave = (math.sin(now * speed * math.pi * 2 + phase) + 1) * 0.5
        if State.chamsAnimationMode == "gradient" then
            local accent = State.colChamAnimation
            if typeof(accent) ~= "Color3" then return base end
            return base:Lerp(accent, wave * strength)
        end
        return base:Lerp(Color3.new(1, 1, 1), wave * strength * 0.4)
    end

    local function paintCham(hl, fill, outline, throughWalls, fillOverride)
        local fillOpacity, outlineOpacity = chamOpacity(fillOverride)
        if State.chamsAnimation then
            local now = os.clock()
            fill = animatedChamColor(fill, hl.Adornee, now)
            outline = animatedChamColor(outline, hl.Adornee, now)
        end
        local depth = throughWalls and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded
        if not hl.Enabled then hl.Enabled = true end
        if hl.FillColor ~= fill then hl.FillColor = fill end
        if hl.OutlineColor ~= outline then hl.OutlineColor = outline end
        if hl.FillTransparency ~= 1 - fillOpacity then
            hl.FillTransparency = 1 - fillOpacity
        end
        if hl.OutlineTransparency ~= 1 - outlineOpacity then
            hl.OutlineTransparency = 1 - outlineOpacity
        end
        if hl.DepthMode ~= depth then hl.DepthMode = depth end
    end

    -- Roblox renders one Highlight per adornee; recolor it for visible and hidden states.
    local function ensureCham(char, isEnemy, visible, stale)
        if not State.chamsEnable then return end
        if not chamsFolder:IsDescendantOf(Workspace) then
            chamsFolder.Parent = Workspace
        end
        local hl = chamsByChar[char]
        if not hl then
            hl = Instance.new("Highlight")
            hl.Name = "bs_cham"
            hl.Adornee = char
            hl.OutlineTransparency = 0
            local ok = pcall(function() hl.Parent = chamsFolder end)
            if not ok or not hl.Parent then
                -- Restore the world parent if another script removed it.
                pcall(function() chamsFolder.Parent = Workspace end)
                pcall(function() hl.Parent = chamsFolder end)
            end
            if not hl.Parent then
                if not chamErrorLogged then
                    chamErrorLogged = true
                    warn("[bs] chams could not attach to Workspace")
                end
                pcall(function() hl:Destroy() end)
                return
            end
            chamsByChar[char] = hl
            dbg("cham created for", char.Name, "→ parent =", chamsFolder.Parent
                and chamsFolder.Parent:GetFullName() or "nil")
        end

        local fill
        if stale then
            fill = State.colChamStale
        elseif char == LocalPlayer.Character then
            fill = State.colChamSelf
        elseif not isEnemy then
            fill = State.colChamTeammate
        elseif visible then
            fill = State.colChamVisible
        else
            fill = State.colChamHidden
        end
        local out = State.colChamOutline
        local tp = Shared.tpState
        local selfMaterial = char == LocalPlayer.Character and tp and tp.active
            and State.chamsWeapon and State.weaponMaterialThirdPerson
            and State.weaponMaterial ~= "original"
        -- pcall so one locked/orphaned Highlight can't spam the console;
        -- drop it and let the next frame rebuild it.
        local ok, chamError = pcall(function()
            paintCham(hl, fill, out, State.chamsThroughWalls ~= false,
                selfMaterial and State.weaponChamFillOpacity or nil)
        end)
        if not ok or not hl.Parent then
            if not ok and not chamErrorLogged then
                chamErrorLogged = true
                warn("[bs] chams update failed: " .. tostring(chamError))
            end
            pcall(function() hl:Destroy() end)
            chamsByChar[char] = nil
            return
        end
        -- The game's own teammate Highlight lives in every T/CT character;
        -- only one Highlight renders per adornee, so switch the game's off.
        for _, h in ipairs(gameHighlights(char)) do
            if mutedHighlights[h] == nil then mutedHighlights[h] = h.Enabled end
            if h.Enabled then pcall(function() h.Enabled = false end) end
        end
    end

    local function removeCham(char)
        local hl = chamsByChar[char]
        if hl then pcall(function() hl:Destroy() end) end
        chamsByChar[char] = nil
        restoreGameHighlights(char)
    end

    local weaponMaterials = {
        neon = Enum.Material.Neon,
        forcefield = Enum.Material.ForceField,
        glass = Enum.Material.Glass,
        metal = Enum.Material.Metal,
        ["smooth plastic"] = Enum.Material.SmoothPlastic,
        wood = Enum.Material.Wood,
        ["diamond plate"] = Enum.Material.DiamondPlate,
    }
    local weaponPartState, weaponSurfaceState = {}, {}
    local materialMode, materialTint, materialColor, materialHideTextures
    local materialErrorLogged = false
    local function restoreWeaponSurfaces()
        for surface, parent in pairs(weaponSurfaceState) do
            if parent and parent.Parent then
                pcall(function() surface.Parent = parent end)
            end
            weaponSurfaceState[surface] = nil
        end
    end
    local function restoreWeaponAppearance()
        restoreWeaponSurfaces()
        for part, original in pairs(weaponPartState) do
            if part.Parent then
                pcall(function()
                    part.Material = original.material
                    part.MaterialVariant = original.variant
                    part.Color = original.color
                end)
            end
            weaponPartState[part] = nil
        end
        materialMode, materialTint, materialColor, materialHideTextures = nil, nil, nil, nil
    end
    local function applyWeaponAppearance(inst)
        local selected = weaponMaterials[State.weaponMaterial]
        if not selected then return end
        if inst:IsA("BasePart") then
            local original = weaponPartState[inst]
            if not original then
                original = {
                    material = inst.Material,
                    variant = inst.MaterialVariant,
                    color = inst.Color,
                }
                weaponPartState[inst] = original
            end
            if inst.MaterialVariant ~= "" then inst.MaterialVariant = "" end
            if inst.Material ~= selected then inst.Material = selected end
            local color = State.weaponMaterialTint and State.colChamWeapon or original.color
            if inst.Color ~= color then inst.Color = color end
        elseif inst:IsA("SurfaceAppearance") and State.weaponMaterialHideTextures then
            if weaponSurfaceState[inst] == nil then
                weaponSurfaceState[inst] = inst.Parent
                inst.Parent = nil
            end
        end
    end
    local function safeWeaponAppearance(inst)
        local ok, err = pcall(applyWeaponAppearance, inst)
        if not ok and not materialErrorLogged then
            materialErrorLogged = true
            warn("[bs] weapon material unavailable: " .. tostring(err))
        end
    end
    local function syncWeaponAppearance(model)
        local mode = State.weaponMaterial
        local tint = State.weaponMaterialTint == true
        local color = State.colChamWeapon
        local hide = State.weaponMaterialHideTextures == true
        if mode == materialMode and tint == materialTint and color == materialColor
            and hide == materialHideTextures then return end
        if not weaponMaterials[mode] then
            restoreWeaponAppearance()
            materialMode, materialTint, materialColor, materialHideTextures = mode, tint, color, hide
            return
        end
        if not hide then restoreWeaponSurfaces() end
        for _, inst in ipairs(model:GetDescendants()) do
            safeWeaponAppearance(inst)
        end
        materialMode, materialTint, materialColor, materialHideTextures = mode, tint, color, hide
    end
    local thirdPersonParts, thirdPersonSurfaces = {}, {}
    local thirdPersonModel, thirdPersonConn
    local thirdPersonMode, thirdPersonTint, thirdPersonColor, thirdPersonHideTextures
    local thirdPersonMaterialError = false
    local function restoreThirdPersonSurfaces()
        for surface, parent in pairs(thirdPersonSurfaces) do
            if parent and parent.Parent then
                pcall(function() surface.Parent = parent end)
            end
            thirdPersonSurfaces[surface] = nil
        end
    end
    local function restoreThirdPersonAppearance()
        if thirdPersonConn then thirdPersonConn:Disconnect(); thirdPersonConn = nil end
        restoreThirdPersonSurfaces()
        for part, original in pairs(thirdPersonParts) do
            if part.Parent then
                pcall(function()
                    part.Material = original.material
                    part.MaterialVariant = original.variant
                    part.Color = original.color
                end)
            end
            thirdPersonParts[part] = nil
        end
        thirdPersonModel = nil
        thirdPersonMode, thirdPersonTint, thirdPersonColor, thirdPersonHideTextures = nil, nil, nil, nil
    end
    local function applyThirdPersonPart(inst)
        local selected = weaponMaterials[State.weaponMaterial]
        if not selected then return end
        if inst:IsA("BasePart") then
            if inst.Name == "pivot" or inst.Name == "HumanoidRootPart"
                or inst.Name == "CameraPart" then return end
            local original = thirdPersonParts[inst]
            if not original then
                original = {
                    material = inst.Material,
                    variant = inst.MaterialVariant,
                    color = inst.Color,
                }
                thirdPersonParts[inst] = original
            end
            if inst.MaterialVariant ~= "" then inst.MaterialVariant = "" end
            if inst.Material ~= selected then inst.Material = selected end
            local color = State.weaponMaterialTint and State.colChamWeapon or original.color
            if inst.Color ~= color then inst.Color = color end
        elseif inst:IsA("SurfaceAppearance") and State.weaponMaterialHideTextures then
            if thirdPersonSurfaces[inst] == nil then
                thirdPersonSurfaces[inst] = inst.Parent
                inst.Parent = nil
            end
        end
    end
    local function safeThirdPersonPart(inst)
        local ok, err = pcall(applyThirdPersonPart, inst)
        if not ok and not thirdPersonMaterialError then
            thirdPersonMaterialError = true
            warn("[bs] third-person material unavailable: " .. tostring(err))
        end
    end
    local function updateThirdPersonAppearance()
        local tp = Shared.tpState
        local model = LocalPlayer.Character
        if not State.chamsEnable or not State.chamsWeapon
            or not State.weaponMaterialThirdPerson or not tp or not tp.active
            or not weaponMaterials[State.weaponMaterial]
            or not model or not model.Parent then
            if thirdPersonModel then restoreThirdPersonAppearance() end
            return
        end
        if model ~= thirdPersonModel then
            restoreThirdPersonAppearance()
            thirdPersonModel = model
            thirdPersonConn = model.DescendantAdded:Connect(safeThirdPersonPart)
        end
        local mode = State.weaponMaterial
        local tint = State.weaponMaterialTint == true
        local color = State.colChamWeapon
        local hide = State.weaponMaterialHideTextures == true
        if mode == thirdPersonMode and tint == thirdPersonTint
            and color == thirdPersonColor and hide == thirdPersonHideTextures then return end
        if not hide then restoreThirdPersonSurfaces() end
        for _, inst in ipairs(model:GetDescendants()) do
            safeThirdPersonPart(inst)
        end
        thirdPersonMode, thirdPersonTint, thirdPersonColor, thirdPersonHideTextures = mode, tint, color, hide
    end
    local function restoreWeaponHighlights()
        if weaponChamConn then weaponChamConn:Disconnect(); weaponChamConn = nil end
        for hl, oldValue in pairs(weaponHighlightsMuted) do
            if hl.Parent then pcall(function() hl.Enabled = oldValue end) end
            weaponHighlightsMuted[hl] = nil
        end
    end
    local function removeWeaponCham()
        if weaponCham then pcall(function() weaponCham:Destroy() end) end
        weaponCham, weaponChamModel = nil, nil
        restoreWeaponHighlights()
        restoreWeaponAppearance()
    end
    local function muteWeaponHighlight(inst)
        if inst:IsA("Highlight") and inst ~= weaponCham then
            if weaponHighlightsMuted[inst] == nil then
                weaponHighlightsMuted[inst] = inst.Enabled
            end
            if inst.Enabled then inst.Enabled = false end
        end
    end
    local function updateWeaponCham()
        if not State.chamsEnable or not State.chamsWeapon or not weaponInventoryOk
            or type(WeaponInventory) ~= "table"
            or type(WeaponInventory.peekCurrentEquippedForMovement) ~= "function" then
            removeWeaponCham()
            return
        end
        local ok, weapon = pcall(WeaponInventory.peekCurrentEquippedForMovement)
        local model = ok and type(weapon) == "table" and weapon.Viewmodel
            and weapon.Viewmodel.Model
        if typeof(model) ~= "Instance" or not model.Parent then
            removeWeaponCham()
            return
        end
        if model ~= weaponChamModel or not weaponCham or not weaponCham.Parent then
            removeWeaponCham()
            if not chamsFolder:IsDescendantOf(Workspace) then
                chamsFolder.Parent = Workspace
            end
            local hl = Instance.new("Highlight")
            hl.Name = "bs_weapon_cham"
            hl.Adornee = model
            local attached = pcall(function() hl.Parent = chamsFolder end)
            if not attached or not hl.Parent then
                pcall(function() hl:Destroy() end)
                return
            end
            weaponCham, weaponChamModel = hl, model
            for _, inst in ipairs(model:GetDescendants()) do
                muteWeaponHighlight(inst)
            end
            weaponChamConn = model.DescendantAdded:Connect(function(inst)
                muteWeaponHighlight(inst)
                safeWeaponAppearance(inst)
            end)
        end
        syncWeaponAppearance(model)
        for hl in pairs(weaponHighlightsMuted) do
            if not hl.Parent then
                weaponHighlightsMuted[hl] = nil
            elseif hl.Enabled then
                hl.Enabled = false
            end
        end
        local tp = Shared.tpState
        local properties = type(weapon.Properties) == "table" and weapon.Properties or nil
        local scoped = properties and properties.AimingOptions == "SniperScope"
            and State.hudScopeLines and (weapon.IsAiming or weapon.IsSniperScoped)
        if (tp and tp.active) or scoped then
            if weaponCham.Enabled then weaponCham.Enabled = false end
            return
        end
        local painted, err = pcall(paintCham, weaponCham, State.colChamWeapon,
            State.colChamOutline, State.chamsThroughWalls ~= false,
            State.weaponChamFillOpacity)
        if not painted then
            if not chamErrorLogged then
                chamErrorLogged = true
                warn("[bs] weapon chams update failed: " .. tostring(err))
            end
            removeWeaponCham()
        end
    end
    local function updateChamSceneTint()
        if not State.chamsEnable or not State.chamsSceneTint then
            if sceneTintEffect then sceneTintEffect:Destroy(); sceneTintEffect = nil end
            return
        end
        if sceneTintEffect and not sceneTintEffect.Parent then
            sceneTintEffect:Destroy()
            sceneTintEffect = nil
        end
        if not sceneTintEffect then
            sceneTintEffect = Instance.new("ColorCorrectionEffect")
            sceneTintEffect.Name = "bs_cham_tint"
            sceneTintEffect.Parent = game:GetService("Lighting")
        end
        local strength = math.clamp(tonumber(State.chamsTintStrength) or 0.3, 0, 0.8)
        local color = Color3.new(1, 1, 1):Lerp(State.colChamTint, strength)
        if sceneTintEffect.TintColor ~= color then sceneTintEffect.TintColor = color end
        if not sceneTintEffect.Enabled then sceneTintEffect.Enabled = true end
    end

    -- Drawing objects live outside the GUI tree and need explicit cleanup.
    local Drawing = _G.Drawing or Drawing  -- executor global; check both spellings
    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then
        warn("[bs] Drawing API missing on this executor — ESP disabled")
        Drawing = nil
    end

    local espByPlayer = {}  -- [player] = { box, boxOutline, hpBg, hpFill, name, dist, weapon }

    local function newDraw(kind, props)
        local d = Drawing.new(kind)
        for k, v in pairs(props) do d[k] = v end
        return d
    end

    local backtrackHistory = {}
    local backtrackDrawings = {}
    local backtrackTick = 0
    local backtrackWasOn = false
    local backtrackColor = Color3.fromRGB(204, 137, 158)
    local function hideBacktrack(plr)
        local set = backtrackDrawings[plr]
        if set then
            for _, square in ipairs(set) do square.Visible = false end
        end
    end
    local function removeBacktrack(plr)
        local set = backtrackDrawings[plr]
        if set then
            for _, square in ipairs(set) do pcall(function() square:Remove() end) end
        end
        backtrackDrawings[plr] = nil
        backtrackHistory[plr] = nil
    end
    local function backtrackSet(plr)
        local set = backtrackDrawings[plr]
        if set then return set end
        set = {}
        for i = 1, 3 do
            set[i] = newDraw("Square", {
                Thickness = 1, Filled = false, Color = backtrackColor,
                Transparency = 0.78 - (i - 1) * 0.22,
                Visible = false, ZIndex = 3,
            })
        end
        backtrackDrawings[plr] = set
        return set
    end
    local backtrackConn = RunService.RenderStepped:Connect(function()
        if not Drawing or not State.backtrackVisual then
            if backtrackWasOn then
                for plr in pairs(backtrackDrawings) do hideBacktrack(plr) end
                table.clear(backtrackHistory)
                backtrackWasOn = false
            end
            return
        end
        backtrackWasOn = true
        local now = os.clock()
        if now - backtrackTick < 1 / 15 then return end
        backtrackTick = now
        local cam = Workspace.CurrentCamera
        if not cam then return end
        for _, plr in ipairs(PlayersSvc:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local head = char and char:FindFirstChild("Head")
                local active = isEnemyOf(plr) and head and head:IsA("BasePart")
                    and char.Parent and char:GetAttribute("Dead") ~= true
                    and not hiddenByGame(plr)
                if not active then
                    backtrackHistory[plr] = nil
                    hideBacktrack(plr)
                else
                    local entry = backtrackHistory[plr]
                    if not entry or entry.char ~= char then
                        entry = { char = char, samples = {} }
                        backtrackHistory[plr] = entry
                    end
                    local samples = entry.samples
                    table.insert(samples, 1, { pos = head.Position, height = head.Size.Y })
                    if #samples > 6 then table.remove(samples) end
                    local set = backtrackSet(plr)
                    for i = 1, 3 do
                        local sample = samples[i * 2]
                        local square = set[i]
                        if sample and (head.Position - sample.pos).Magnitude > 0.35 then
                            local point, onScreen = cam:WorldToViewportPoint(sample.pos)
                            if onScreen and point.Z > 0 then
                                local top = cam:WorldToViewportPoint(
                                    sample.pos + Vector3.new(0, sample.height * 0.5, 0))
                                local halfHeight = math.clamp(math.abs(point.Y - top.Y), 4, 28)
                                square.Position = Vector2.new(point.X - halfHeight * 0.7,
                                    point.Y - halfHeight)
                                square.Size = Vector2.new(halfHeight * 1.4, halfHeight * 2)
                                square.Visible = true
                            else
                                square.Visible = false
                            end
                        else
                            square.Visible = false
                        end
                    end
                end
            end
        end
    end)

    -- TextBounds isn't on every executor's Drawing Text; estimate if missing.
    local function textWidth(d)
        local ok, tb = pcall(function() return d.TextBounds end)
        if ok and typeof(tb) == "Vector2" and tb.X > 0 then return tb.X end
        return #d.Text * d.Size * 0.5
    end

    local espAnchors = {}
    local function makeESPSet(plr)
        if not Drawing then return nil end
        local box = newDraw("Square", {
            Thickness = 1, Filled = false, Color = State.colHidden,
            Transparency = 1, Visible = false, ZIndex = 2,
        })
        local boxOutline = newDraw("Square", {
            Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0),
            Transparency = 1, Visible = false, ZIndex = 1,
        })
        local hpBg = newDraw("Square", {
            Thickness = 1, Filled = true, Color = Color3.new(0, 0, 0),
            Transparency = 0.7, Visible = false, ZIndex = 3,
        })
        local hpFill = newDraw("Square", {
            Thickness = 1, Filled = true, Color = Color3.fromRGB(90, 220, 120),
            Transparency = 1, Visible = false, ZIndex = 4,
        })
        local function txt()
            return newDraw("Text", {
                Text = "", Size = 13, Color = COL_TEXT, Center = true,
                Outline = true, OutlineColor = Color3.new(0, 0, 0),
                Font = 2,  -- Plex; 0=UI, 1=System, 2=Plex, 3=Monospace
                Visible = false, ZIndex = 5,
            })
        end
        local set = {
            box = box, boxOutline = boxOutline,
            hpBg = hpBg, hpFill = hpFill,
            name = txt(), dist = txt(), weapon = txt(), ping = txt(),
        }
        -- name/ping are placed as a left-aligned pair; weapon line is centred.
        set.name.Center = false
        set.ping.Center = false
        set.ping.Size = 12
        set.dist.Center = false
        set.weapon.Size = 12
        set.weapon.Color = COL_TEXT_DIM
        -- Flat keys (bone1..boneN) so every hide/remove loop over the set covers them.
        for i = 1, MAX_BONES do
            set["bone" .. i] = newDraw("Line", {
                Thickness = 1, Color = COL_TEXT, Transparency = 1, Visible = false, ZIndex = 3,
            })
        end
        espByPlayer[plr] = set
        return set
    end

    local function removeESP(plr)
        local set = espByPlayer[plr]
        if set then
            for _, d in pairs(set) do pcall(function() d:Remove() end) end
        end
        espByPlayer[plr] = nil
        espAnchors[plr] = nil
    end

    local function placeEspLabels(cam)
        if not cam or not State.visualsEnable then return end
        for plr, anchor in pairs(espAnchors) do
            local set = espByPlayer[plr]
            local pivot = anchor.pivot
            if set and pivot and pivot.Parent
                and (set.name.Visible or set.ping.Visible or set.weapon.Visible or set.hpBg.Visible) then
                local headSP = cam:WorldToViewportPoint(
                    pivot.Position + Vector3.new(0, pivot.Size.Y / 2 + 0.25, 0))
                if headSP.Z > 0 then
                    local cx, labelTop = headSP.X, headSP.Y
                    local barY = labelTop - (set.hpBg.Visible and 6 or 0)
                    local lineY = barY - 16
                    local x0 = cx - (anchor.nameW + anchor.gap + anchor.pingW) / 2
                    if set.name.Visible then set.name.Position = Vector2.new(x0, lineY) end
                    if set.ping.Visible then
                        set.ping.Position = Vector2.new(x0 + anchor.nameW + anchor.gap, lineY)
                    end
                    if set.hpBg.Visible then
                        local barX = cx - anchor.barW / 2
                        set.hpBg.Position = Vector2.new(barX - 1, barY - 1)
                        set.hpFill.Position = Vector2.new(barX, barY)
                    end
                    if set.weapon.Visible then
                        local footSP = cam:WorldToViewportPoint(
                            pivot.Position + Vector3.new(0, anchor.footOffsetY, 0))
                        if footSP.Z > 0 then
                            set.weapon.Position = Vector2.new(cx, footSP.Y + 3)
                        end
                    end
                end
            end
        end
    end

    -- RenderStepped sees the final camera frame, including spectator updates.
    local _tickCount = 0
    local UPDATE_CONN
    local nextVisualUpdate = 0
    local visualsWereActive = false
    local BOX_SIGNS = { -1, 1 }
    UPDATE_CONN = RunService.RenderStepped:Connect(function()
        placeEspLabels(Workspace.CurrentCamera)
        local updateAt = os.clock()
        if updateAt < nextVisualUpdate then return end
        nextVisualUpdate = updateAt + 1 / 30
        _tickCount = _tickCount + 1
        -- Spectating may replace CurrentCamera, so do not cache it.
        local Cam = Workspace.CurrentCamera
        local camCF = Cam and Cam.CFrame or CFrame.identity
        -- Dead-player 2D projections can use a stale camera; world chams remain valid.
        local myChar = LocalPlayer.Character
        local myHP = myChar and myChar:GetAttribute("Health")
        -- Blowstrike doesn't clear your character on death; it flips the
        -- IsSpectating attribute on the player instead.
        local spectating = LocalPlayer:GetAttribute("IsSpectating") == true
        local spectated = spectating and SpectateController and select(2, pcall(SpectateController.GetPlayer)) or nil
        local localDead = spectating or (not myChar) or (not myChar:FindFirstChild("HumanoidRootPart"))
            or (myChar:GetAttribute("Dead") == true) or (type(myHP) == "number" and myHP <= 0)
        local espSuppressed = State.espHideWhenDead and localDead
        local enabled = State.visualsEnable
        local chamsEnabled = State.chamsEnable
        local auraEnabled = State.auraEnable
        if auraEnabled and not localDead and myChar then
            local selfPivot = myChar:FindFirstChild("HumanoidRootPart")
            if selfPivot then ensureAura(myChar, selfPivot, State.colAlly) end
        elseif myChar then
            removeAura(myChar)
        end
        updatePitchPose(not localDead and myChar or nil)
        updateThirdPersonAppearance()
        updateWeaponCham()
        updateChamSceneTint()
        if myChar then
            if chamsEnabled and State.chamsSelf and not localDead then
                ensureCham(myChar, false, true, false)
            elseif chamsByChar[myChar] then
                removeCham(myChar)
            end
        end
        if not (enabled or chamsEnabled) then
            if visualsWereActive then
                for _, s in pairs(espByPlayer) do
                    for _, d in pairs(s) do d.Visible = false end
                end
                for char in pairs(chamsByChar) do removeCham(char) end
                visualsWereActive = false
            end
            for char in pairs(auraByChar) do
                if char ~= myChar then removeAura(char) end
            end
            return
        end
        visualsWereActive = true
        local seen, drawn = 0, 0
        -- Global kill switch: hide EVERY drawing while dead, chams keep going.
        if espSuppressed then
            for _, s in pairs(espByPlayer) do
                for _, d in pairs(s) do d.Visible = false end
            end
        end
        for _, plr in ipairs(PlayersSvc:GetPlayers()) do
          -- Hide the spectated body's Highlight when it sits on the camera.
          local skip = plr == LocalPlayer or plr == spectated
          if plr == spectated and plr.Character then
              removeCham(plr.Character)
              removeAura(plr.Character)
              local s = espByPlayer[plr]
              if s then for _, d in pairs(s) do d.Visible = false end end
          end
          if not skip then
            seen = seen + 1
            local set = espByPlayer[plr]
            -- HRP may replicate after the rest of an enemy character.
            local char = (enabled or chamsEnabled) and plr.Character or nil
            if char and not char.Parent then char = nil end
            -- Draw everyone; team check just skips ally chams/box if on.
            local enemy = isEnemyOf(plr)
            local show = char and (enemy or not State.visualsTeamCheck
                or (chamsEnabled and State.chamsTeammates))
            local function hideEsp(s)
                if not s then return end
                for _, d in pairs(s) do d.Visible = false end
            end
            if show and hiddenByGame(plr) then show = false end
            if not show then
                hideEsp(set)
                -- Otherwise a cham outlives "visuals off", a team swap, or a hidden shell.
                if plr.Character then removeCham(plr.Character); removeAura(plr.Character) end
            else
              -- Anchor on the Head: it's part of the animated body the chams
              -- paint. HumanoidRootPart can sit frozen far from the body.
              local pivot = char:FindFirstChild("Head")
                  or char:FindFirstChild("HumanoidRootPart")
                  or char:FindFirstChildWhichIsA("BasePart")
              if not pivot or char:GetAttribute("Dead") == true then
                  hideEsp(set)
                  removeCham(char)
                  removeAura(char)
              else
                local enemyFlag = enemy
                -- Line of sight from your head, not the third-person camera.
                local tpS = Shared.tpState
                local losFrom = (tpS and tpS.active and tpS.fp or camCF).Position
                local visible = isCharVisible(char, losFrom, pivot.Position)
                local stale = staleSeconds(plr, pivot, os.clock())

                if chamsEnabled and ((enemyFlag and State.chamsEnemy)
                    or (not enemyFlag and State.chamsTeammates)) then
                    ensureCham(char, enemyFlag, visible, stale > 0)
                else
                    removeCham(char)
                end
                removeAura(char)

                if enabled and (enemyFlag or not State.visualsTeamCheck)
                    and not set then set = makeESPSet(plr) end
                local function hideSet(s)
                    if not s then return end
                    for _, d in pairs(s) do d.Visible = false end
                end

                if not enabled or not Drawing or not set
                    or (not enemyFlag and State.visualsTeamCheck) then
                    -- Drawing missing; nothing to render.
                elseif espSuppressed then
                    hideSet(set)
                else
                    -- Box = world AABB of the body parts (the same parts the
                    -- chams paint), then project its 8 corners.
                    local cf, size = bodyBounds(char, pivot)
                    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
                    local anyOn = false
                    local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
                    for _, sx in ipairs(BOX_SIGNS) do
                    for _, sy in ipairs(BOX_SIGNS) do
                    for _, sz in ipairs(BOX_SIGNS) do
                        local wp = cf:PointToWorldSpace(Vector3.new(sx * hx, sy * hy, sz * hz))
                        local sp, on = Cam:WorldToViewportPoint(wp)
                        if sp.Z > 0 then
                            anyOn = anyOn or on
                            if sp.X < minX then minX = sp.X end
                            if sp.Y < minY then minY = sp.Y end
                            if sp.X > maxX then maxX = sp.X end
                            if sp.Y > maxY then maxY = sp.Y end
                        end
                    end end end
                    if not anyOn then
                        hideSet(set)
                    else
                        drawn = drawn + 1
                        local left, top = minX, minY
                        local width, height = maxX - minX, maxY - minY
                        if width < 4 then width = 4 end
                        if height < 4 then height = 4 end
                        local posV = Vector2.new(left, top)
                        local sizeV = Vector2.new(width, height)
                        -- Grey, translucent ESP marks a stale last-known pose.
                        local boxColor
                        if stale > 0 then
                            boxColor = COL_STALE
                        elseif not enemyFlag then
                            boxColor = State.colAlly
                        else
                            boxColor = visible and State.colVisible or State.colHidden
                        end
                        local alpha = stale > 0 and 0.45 or 1

                        -- Anchor labels to the head and feet; animated limbs make AABB labels jitter.
                        local cx = left + width / 2
                        local labelTop, footY = top, top + height
                        local headSP = Cam:WorldToViewportPoint(pivot.Position + Vector3.new(0, pivot.Size.Y / 2 + 0.25, 0))
                        if headSP.Z > 0 then cx, labelTop = headSP.X, headSP.Y end
                        local footSP = Cam:WorldToViewportPoint(Vector3.new(pivot.Position.X, cf.Position.Y - size.Y / 2, pivot.Position.Z))
                        if footSP.Z > 0 then footY = footSP.Y end
                        local textCol = stale > 0 and COL_STALE or State.colText

                        if State.espBox then
                            set.box.Position = posV
                            set.box.Size = sizeV
                            set.box.Color = boxColor
                            set.box.Transparency = alpha
                            set.box.Visible = true
                            set.boxOutline.Position = posV
                            set.boxOutline.Size = sizeV
                            set.boxOutline.Transparency = alpha
                            set.boxOutline.Visible = true
                        else
                            set.box.Visible = false
                            set.boxOutline.Visible = false
                        end

                        local barY = labelTop - 6
                        if State.espHealth then
                            -- Missing Health attribute = not replicated yet = full.
                            local mx = tonumber(char:GetAttribute("MaxHealth")) or 100
                            if mx <= 0 then mx = 100 end
                            local hp = tonumber(char:GetAttribute("Health")) or mx
                            local ratio = math.clamp(hp / mx, 0, 1)
                            local barW = math.clamp(width, 36, 70)
                            local barX = cx - barW / 2
                            set.hpBg.Position = Vector2.new(barX - 1, barY - 1)
                            set.hpBg.Size = Vector2.new(barW + 2, 5)
                            set.hpBg.Transparency = 0.6 * alpha
                            set.hpBg.Visible = true
                            set.hpFill.Position = Vector2.new(barX, barY)
                            set.hpFill.Size = Vector2.new(math.max(barW * ratio, 1), 3)
                            -- red (0%) -> yellow -> green (100%)
                            set.hpFill.Color = Color3.fromHSV(ratio * 0.33, 0.8, 1)
                            set.hpFill.Transparency = alpha
                            set.hpFill.Visible = true
                        else
                            set.hpBg.Visible = false
                            set.hpFill.Visible = false
                            barY = labelTop
                        end

                        local lineY = barY - 16
                        local nameW, pingW = 0, 0
                        if State.espName then
                            local nm = plr.DisplayName or plr.Name
                            set.name.Text = stale > 0 and ("%s [%ds]"):format(nm, math.floor(stale)) or nm
                            set.name.Color = textCol
                            set.name.Transparency = alpha
                            nameW = textWidth(set.name)
                        end
                        local ms = State.espPing and pingOf(plr) or nil
                        if ms then
                            set.ping.Text = ("%dms"):format(ms)
                            set.ping.Color = ms < 80 and COL_PING_OK or (ms < 160 and COL_PING_MID or COL_PING_BAD)
                            set.ping.Transparency = alpha
                            pingW = textWidth(set.ping)
                        end
                        local gap = (nameW > 0 and pingW > 0) and 5 or 0
                        local x0 = cx - (nameW + gap + pingW) / 2
                        local anchor = espAnchors[plr]
                        if not anchor then anchor = {}; espAnchors[plr] = anchor end
                        anchor.pivot = pivot
                        anchor.footOffsetY = cf.Position.Y - size.Y / 2 - pivot.Position.Y
                        anchor.nameW, anchor.pingW, anchor.gap = nameW, pingW, gap
                        anchor.barW = math.clamp(width, 36, 70)
                        set.name.Position = Vector2.new(x0, lineY)
                        set.name.Visible = State.espName == true
                        set.ping.Position = Vector2.new(x0 + nameW + gap, lineY)
                        set.ping.Visible = ms ~= nil

                        local weapon = State.espWeapon and weaponName(plr) or ""
                        local distTxt = State.espDistance
                            and ("%dm"):format(math.floor((camCF.Position - pivot.Position).Magnitude)) or ""
                        local foot = (weapon ~= "" and distTxt ~= "") and (weapon .. "  ·  " .. distTxt) or (weapon .. distTxt)
                        set.weapon.Text = foot
                        set.weapon.Position = Vector2.new(cx, footY + 3)
                        set.weapon.Transparency = alpha
                        set.weapon.Visible = foot ~= ""
                        set.dist.Visible = false

                        local used = 0
                        if State.espSkeleton then
                            for _, m in ipairs(skeletonJoints(char)) do
                                local p0, p1 = m.Part0, m.Part1
                                if p0 and p1 and p0.Parent and p1.Parent then
                                    local a, aOn = Cam:WorldToViewportPoint(p0.Position)
                                    local b, bOn = Cam:WorldToViewportPoint(p1.Position)
                                    if a.Z > 0 and b.Z > 0 and (aOn or bOn) then
                                        used = used + 1
                                        local ln = set["bone" .. used]
                                        ln.From = Vector2.new(a.X, a.Y)
                                        ln.To = Vector2.new(b.X, b.Y)
                                        ln.Color = boxColor
                                        ln.Transparency = alpha
                                        ln.Visible = true
                                    end
                                end
                            end
                        end
                        for i = used + 1, MAX_BONES do set["bone" .. i].Visible = false end
                    end
                end
              end -- close hrp-else
            end -- close show-else
          end -- close if not skip
        end -- close for
        if State.debugPrint and _tickCount % 120 == 0 then
            print(("[bs] visuals tick — enabled=%s seen=%d drawn=%d")
                :format(tostring(enabled), seen, drawn))
        end
    end)

    -- Disconnect player listeners on reload so they do not stack.
    local conns = {}
    local function dropCharacterCaches(char)
        for _, cache in ipairs({ jointCache, partCache, gameHlCache }) do
            local entry = cache[char]
            if entry then
                if entry.added then entry.added:Disconnect() end
                if entry.removing then entry.removing:Disconnect() end
                cache[char] = nil
            end
        end
    end
    conns[#conns + 1] = PlayersSvc.PlayerRemoving:Connect(function(plr)
        removeESP(plr)
        removeBacktrack(plr)
        liveInfo[plr] = nil
        local c = plr.Character
        if c then removeCham(c); removeAura(c); dropCharacterCaches(c) end
    end)
    local moveTrail, moveTrailAnchor, moveTrailEnds
    local trailPosition, trailGeneration
    local trailElapsed = 0
    local function clearMoveTrail()
        if moveTrail then moveTrail:Destroy() end
        if moveTrailEnds then
            for _, attachment in ipairs(moveTrailEnds) do attachment:Destroy() end
        end
        moveTrail, moveTrailAnchor, moveTrailEnds = nil, nil, nil
        trailPosition, trailGeneration = nil, nil
    end
    local function ensureMoveTrail(anchor)
        if moveTrail and moveTrailAnchor == anchor then return end
        if moveTrail then clearMoveTrail() end
        local left = Instance.new("Attachment")
        left.Name = "bs_move_trail_left"
        left.Position = Vector3.new(-0.48, -0.35, 0.6)
        left.Parent = anchor
        local right = Instance.new("Attachment")
        right.Name = "bs_move_trail_right"
        right.Position = Vector3.new(0.48, -0.35, 0.6)
        right.Parent = anchor
        local trail = Instance.new("Trail")
        trail.Name = "bs_move_trail"
        trail.Attachment0 = left
        trail.Attachment1 = right
        trail.FaceCamera = true
        trail.LightEmission = 0.65
        trail.MinLength = 0.05
        trail.MaxLength = 12
        trail.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.2),
            NumberSequenceKeypoint.new(0.45, 0.5),
            NumberSequenceKeypoint.new(1, 1),
        })
        trail.WidthScale = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        })
        trail.Color = ColorSequence.new(State.colMoveTrail)
        trail.Lifetime = math.clamp(tonumber(State.moveTrailLifetime) or 0.35, 0.15, 0.8)
        trail.Enabled = false
        trail.Parent = anchor
        moveTrail, moveTrailAnchor, moveTrailEnds = trail, anchor, { left, right }
    end
    conns[#conns + 1] = RunService.Heartbeat:Connect(function(dt)
        trailElapsed = trailElapsed + dt
        if trailElapsed < 0.05 then return end
        local sampleDt = trailElapsed
        trailElapsed = 0
        if not State.moveTrail then
            if moveTrail then clearMoveTrail() end
            return
        end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local anchor = char and (char:FindFirstChild("UpperTorso")
            or char:FindFirstChild("Torso") or char:FindFirstChild("LowerTorso")
            or char:FindFirstChild("Head") or root)
        local hp = char and tonumber(char:GetAttribute("Health"))
        if not anchor or char:GetAttribute("Dead") == true
            or (hp and hp <= 0) or LocalPlayer:GetAttribute("IsSpectating") == true then
            if moveTrail then clearMoveTrail() end
            return
        end
        local generation = char:GetAttribute("CharacterGeneration")
        if moveTrailAnchor ~= anchor or trailGeneration ~= generation then
            clearMoveTrail()
            ensureMoveTrail(anchor)
            trailGeneration = generation
        end
        local position = (root or anchor).Position
        local displacement = trailPosition and (position - trailPosition).Magnitude or 0
        trailPosition = position
        -- This character is moved by CFrame, so physics velocity can remain zero.
        local active = displacement / sampleDt > 1
        if displacement > 20 then
            moveTrail:Clear()
            active = false
        end
        if active then
            ensureMoveTrail(anchor)
            moveTrail.Lifetime = math.clamp(tonumber(State.moveTrailLifetime) or 0.35, 0.15, 0.8)
            if typeof(State.colMoveTrail) == "Color3" then
                moveTrail.Color = ColorSequence.new(State.colMoveTrail)
            end
            moveTrail.Enabled = true
        elseif moveTrail then
            moveTrail.Enabled = false
        end
    end)
    local function watchCharacter(plr)
        conns[#conns + 1] = plr.CharacterRemoving:Connect(function(c)
            if plr == LocalPlayer then clearMoveTrail() end
            removeCham(c)
            removeAura(c)
            dropCharacterCaches(c)
        end)
    end
    for _, plr in ipairs(PlayersSvc:GetPlayers()) do watchCharacter(plr) end
    conns[#conns + 1] = PlayersSvc.PlayerAdded:Connect(watchCharacter)

    -- The game exposes spectator count, not spectator identities.
    State.hudWatermark = false
    State.hudKeybinds  = false
    State.hudKeybindX  = 18
    State.hudKeybindY  = 120
    State.hudSpecs     = false
    State.hudHitlog    = false
    State.hudTracers   = false
    State.hudHitMarker = false
    State.hudHitSound  = false
    State.colHitBody   = Color3.fromRGB(188, 151, 169)
    State.colHitHead   = Color3.fromRGB(242, 210, 151)
    State.grenadePreview = false
    State.grenadeThrowSpeed = 105
    local hudLines = {}
    -- Lower-center toast stack. Entries are client-side shot results.
    local HITLOG_MAX  = 5
    local HITLOG_LIFE = 4.5
    local hitlog      = {}
    local addHitToast, showHitMarker
    Shared.pushHit = function(name, part, dist, silent, worldPos, wall)
        local e = {
            at = os.clock(),
            name = tostring(name or "?"),
            part = tostring(part or "?"),
            dist = tonumber(dist) or 0,
            silent = silent == true,
            wall = wall == true,
            worldPos = typeof(worldPos) == "Vector3" and worldPos or nil,
        }
        table.insert(hitlog, 1, e)
        if addHitToast then addHitToast(e) end
        if showHitMarker then showHitMarker(e) end
        while #hitlog > HITLOG_MAX do
            local old = table.remove(hitlog)
            if old.toast then old.toast:Destroy() end
        end
        -- Hit feedback reads Shared.lastHit, including its world position and age.
        Shared.lastHit = e
    end
    Shared.pushDrop = function(reason)
        Shared.lastDrop = { at = os.clock(), reason = tostring(reason or "?") }
    end
    local hitGui = Instance.new("ScreenGui")
    hitGui.Name = "AetherHitlogs"
    hitGui.ResetOnSpawn = false
    hitGui.IgnoreGuiInset = true
    hitGui.DisplayOrder = 9998
    hitGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    local hitStack = Instance.new("Frame")
    hitStack.Name = "ToastStack"
    hitStack.Size = UDim2.fromOffset(370, 290)
    hitStack.AnchorPoint = Vector2.new(0.5, 1)
    hitStack.Position = UDim2.new(0.5, 0, 1, -108)
    hitStack.BackgroundTransparency = 1
    hitStack.Parent = hitGui
    local function ui(class, props, parent)
        local inst = Instance.new(class)
        for key, value in pairs(props) do inst[key] = value end
        inst.Parent = parent
        return inst
    end
    local marker = ui("CanvasGroup", {
        Name = "HitMarker", Size = UDim2.fromOffset(46, 46),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundTransparency = 1, GroupTransparency = 1, Visible = false,
    }, hitGui)
    local bodyMark = ui("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    }, marker)
    local headMark = ui("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    }, marker)
    local bodyStrokes, headStrokes = {}, {}
    local function markerStroke(parent, x, y, width, height, rotation)
        return ui("Frame", {
            Size = UDim2.fromOffset(width, height),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(x, y),
            Rotation = rotation or 0,
            BorderSizePixel = 0,
        }, parent)
    end
    for _, stroke in ipairs({
        { 15, 15, 45 }, { 31, 31, 45 },
        { 31, 15, -45 }, { 15, 31, -45 },
    }) do
        bodyStrokes[#bodyStrokes + 1] = markerStroke(bodyMark,
            stroke[1], stroke[2], 9, 2, stroke[3])
    end
    for _, stroke in ipairs({
        { 15, 12, 7, 2 }, { 12, 15, 2, 7 },
        { 31, 12, 7, 2 }, { 34, 15, 2, 7 },
        { 15, 34, 7, 2 }, { 12, 31, 2, 7 },
        { 31, 34, 7, 2 }, { 34, 31, 2, 7 },
    }) do
        headStrokes[#headStrokes + 1] = markerStroke(headMark,
            stroke[1], stroke[2], stroke[3], stroke[4])
    end
    local SoundService = game:GetService("SoundService")
    local bodySound = ui("Sound", {
        Name = "bs_body_hit", SoundId = "rbxassetid://12221990",
        Volume = 0.18, PlaybackSpeed = 0.85,
    }, SoundService)
    local headSound = ui("Sound", {
        Name = "bs_head_hit", SoundId = "rbxassetid://12221990",
        Volume = 0.23, PlaybackSpeed = 1.45,
    }, SoundService)
    local markerAt, lastMarkerSoundAt = -math.huge, -math.huge
    showHitMarker = function(e)
        if State._menuOpen then return end
        local isHead = e.part:lower():find("head", 1, true) ~= nil
        if Shared.pushVisualImpact then Shared.pushVisualImpact(e.worldPos, isHead) end
        local now = os.clock()
        if State.hudHitMarker or (State.fxEnable and State.fxHitMarkers) then
            local cam = Workspace.CurrentCamera
            local point = cam and cam.ViewportSize * 0.5 or Vector2.new(960, 540)
            if cam and e.worldPos then
                local projected, onScreen = cam:WorldToViewportPoint(e.worldPos)
                if onScreen and projected.Z > 0 then
                    point = Vector2.new(projected.X, projected.Y)
                end
            end
            marker.Position = UDim2.fromOffset(point.X, point.Y)
            bodyMark.Visible, headMark.Visible = not isHead, isHead
            local pieces = isHead and headStrokes or bodyStrokes
            local color = isHead and State.colHitHead or State.colHitBody
            if State.fxEnable and State.fxHitMarkers and Shared.fxColor then
                color = Shared.fxColor(now, isHead)
            end
            if typeof(color) ~= "Color3" then color = Color3.fromRGB(235, 225, 230) end
            for _, piece in ipairs(pieces) do piece.BackgroundColor3 = color end
            marker.GroupTransparency = 0
            marker.Visible = true
            markerAt = now
        end
        if State.hudHitSound and now - lastMarkerSoundAt >= 0.065 then
            lastMarkerSoundAt = now
            local sound = isHead and headSound or bodySound
            sound:Stop()
            sound:Play()
        end
    end
    local tracerPool = {}
    local tracerIndex, lastTracerAt = 0, -math.huge
    local TRACER_LIFE, TRACER_LIMIT = 0.22, 10
    Shared.pushTracer = function(origin, direction, distance, hit)
        if not (Drawing and (State.hudTracers or (State.fxEnable and State.fxTracers)))
            or typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3"
            or direction.Magnitude < 0.001 then return end
        local now = os.clock()
        if now - lastTracerAt < 0.025 then return end
        lastTracerAt = now
        tracerIndex = tracerIndex % TRACER_LIMIT + 1
        local tracer = tracerPool[tracerIndex]
        if not tracer then
            tracer = {
                edge = newDraw("Line", {
                    Thickness = 4, Color = Color3.fromRGB(24, 24, 24),
                    Transparency = 1, Visible = false, ZIndex = 7,
                }),
                core = newDraw("Line", {
                    Thickness = 2, Color = Color3.fromRGB(188, 151, 169),
                    Transparency = 1, Visible = false, ZIndex = 8,
                }),
            }
            tracerPool[tracerIndex] = tracer
        end
        local aim = direction.Unit
        local length = math.clamp(tonumber(distance) or 180, 2, hit and 750 or 180)
        tracer.from = origin + aim * 0.5
        tracer.to = origin + aim * length
        tracer.at = now
    end
    conns[#conns + 1] = RunService.RenderStepped:Connect(function()
        local now = os.clock()
        local cam = Workspace.CurrentCamera
        for _, tracer in ipairs(tracerPool) do
            local age = now - tracer.at
            local life = State.fxEnable and 0.35 or TRACER_LIFE
            if not (State.hudTracers or (State.fxEnable and State.fxTracers)) or not cam or age >= life then
                tracer.edge.Visible = false
                tracer.core.Visible = false
            else
                local start, startOn = cam:WorldToViewportPoint(tracer.from)
                local finish, finishOn = cam:WorldToViewportPoint(tracer.to)
                if start.Z > 0 and finish.Z > 0 and (startOn or finishOn) then
                    local viewport = cam.ViewportSize
                    local from = Vector2.new(math.clamp(start.X, -48, viewport.X + 48),
                        math.clamp(start.Y, -48, viewport.Y + 48))
                    local to = Vector2.new(math.clamp(finish.X, -48, viewport.X + 48),
                        math.clamp(finish.Y, -48, viewport.Y + 48))
                    local alpha = math.clamp(1 - age / life, 0, 1)
                    if State.fxEnable and Shared.fxColor then
                        tracer.core.Color = Shared.fxColor(now)
                        tracer.edge.Color = Shared.fxColor(now, true)
                        tracer.edge.Thickness = 6
                    else
                        tracer.core.Color = Color3.fromRGB(188, 151, 169)
                        tracer.edge.Color = Color3.fromRGB(24, 24, 24)
                        tracer.edge.Thickness = 4
                    end
                    tracer.edge.From, tracer.edge.To = from, to
                    tracer.core.From, tracer.core.To = from, to
                    tracer.edge.Transparency = alpha * (State.fxEnable and 0.3 or 0.65)
                    tracer.core.Transparency = alpha
                    tracer.edge.Visible = true
                    tracer.core.Visible = true
                else
                    tracer.edge.Visible = false
                    tracer.core.Visible = false
                end
            end
        end
    end)
    local bindGui = ui("ScreenGui", {
        Name = "AetherKeybinds", ResetOnSpawn = false,
        IgnoreGuiInset = true, DisplayOrder = 10000,
    }, LocalPlayer.PlayerGui)
    local bindPanel = ui("Frame", {
        Name = "KeybindPanel", Size = UDim2.fromOffset(180, 42),
        Position = UDim2.fromOffset(State.hudKeybindX, State.hudKeybindY),
        BackgroundColor3 = Color3.fromRGB(34, 34, 35),
        BorderSizePixel = 0, Active = false,
    }, bindGui)
    ui("UICorner", { CornerRadius = UDim.new(0, 3) }, bindPanel)
    ui("UIStroke", { Color = Color3.fromRGB(48, 45, 47), Thickness = 1 }, bindPanel)
    local bindHeader = ui("Frame", {
        Name = "DragHandle", Size = UDim2.new(1, 0, 0, 19),
        BackgroundTransparency = 1, Active = false,
    }, bindPanel)
    ui("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Font = Enum.Font.Gotham, Text = "keybinds", TextSize = 11,
        TextColor3 = Color3.fromRGB(223, 220, 222),
        TextXAlignment = Enum.TextXAlignment.Center,
    }, bindHeader)
    local dragHint = ui("TextLabel", {
        Size = UDim2.fromOffset(34, 19), Position = UDim2.new(1, -40, 0, 0),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham,
        Text = "drag", TextSize = 9,
        TextColor3 = Color3.fromRGB(150, 137, 145),
        TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
    }, bindHeader)
    ui("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 18),
        BackgroundColor3 = Color3.fromRGB(132, 74, 89), BorderSizePixel = 0,
    }, bindPanel)
    local bindDefinitions = {
        { label = "Third person", key = "tpKey", enabled = "tpEnable" },
        { label = "Rage", key = "rageKeyEnable", enabled = "rageEnable" },
        { label = "Silent aim", key = "rageKeySilent", enabled = "rageSilent" },
        { label = "Auto fire", key = "rageKeyAutoFire", enabled = "rageAutoFire" },
        { label = "Rapid fire", key = "rageKeyRapidFire", enabled = "rageRapidFire" },
        { label = "Anti-aim", key = "antiAimKey", enabled = "antiAimEnable" },
        { label = "Auto peek", key = "moveAutoPeekKey", enabled = "moveAutoPeek" },
    }
    local bindRows = {}
    for i, definition in ipairs(bindDefinitions) do
        local row = ui("Frame", {
            Name = "Bind" .. i, Size = UDim2.new(1, -12, 0, 17),
            BackgroundTransparency = 1, Visible = false,
        }, bindPanel)
        local name = ui("TextLabel", {
            Size = UDim2.new(1, -52, 1, 0), BackgroundTransparency = 1,
            Font = Enum.Font.Gotham, Text = definition.label, TextSize = 11,
            TextColor3 = Color3.fromRGB(220, 216, 218),
            TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        local key = ui("TextLabel", {
            Size = UDim2.fromOffset(50, 17), Position = UDim2.new(1, -50, 0, 0),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            TextSize = 10, TextColor3 = Color3.fromRGB(191, 137, 151),
            TextXAlignment = Enum.TextXAlignment.Right,
        }, row)
        bindRows[i] = { frame = row, name = name, key = key }
    end
    local bindEmpty = ui("TextLabel", {
        Name = "NoActiveBinds", Size = UDim2.new(1, -12, 0, 17),
        Position = UDim2.fromOffset(6, 22), BackgroundTransparency = 1,
        Font = Enum.Font.Gotham, Text = "enable a bound feature", TextSize = 10,
        TextColor3 = Color3.fromRGB(145, 139, 142),
        TextXAlignment = Enum.TextXAlignment.Left,
    }, bindPanel)
    local dragging, dragStart, panelStart = false, nil, nil
    local function clampBindPosition(x, y)
        local camera = Workspace.CurrentCamera
        local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
        return math.clamp(x, 0, math.max(0, viewport.X - 180)),
            math.clamp(y, 0, math.max(0, viewport.Y - bindPanel.AbsoluteSize.Y))
    end
    conns[#conns + 1] = bindHeader.InputBegan:Connect(function(input)
        if not State._menuOpen or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = true
        dragStart = input.Position
        panelStart = bindPanel.AbsolutePosition
    end)
    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
        if not dragging or not State._menuOpen or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local x, y = clampBindPosition(panelStart.X + input.Position.X - dragStart.X,
            panelStart.Y + input.Position.Y - dragStart.Y)
        bindPanel.Position = UDim2.fromOffset(x, y)
        State.hudKeybindX, State.hudKeybindY = x, y
    end)
    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    local nextBindUpdate = 0
    conns[#conns + 1] = RunService.Heartbeat:Connect(function()
        local now = os.clock()
        if now < nextBindUpdate then return end
        nextBindUpdate = now + 0.2
        bindGui.Enabled = State.hudKeybinds == true
        if not bindGui.Enabled then return end
        local menuOpen = State._menuOpen == true
        if not menuOpen then dragging = false end
        bindPanel.Active = menuOpen
        bindHeader.Active = menuOpen
        dragHint.Visible = menuOpen
        local visible = 0
        for i, definition in ipairs(bindDefinitions) do
            local key = State[definition.key]
            local hasKey = State[definition.enabled] == true
                and typeof(key) == "EnumItem" and key ~= Enum.KeyCode.Unknown
            local row = bindRows[i]
            row.frame.Visible = hasKey
            if hasKey then
                visible = visible + 1
                row.frame.Position = UDim2.fromOffset(6, 21 + (visible - 1) * 17)
                row.key.Text = key.Name == "RightShift" and "RSHIFT" or key.Name:upper()
            end
        end
        bindEmpty.Visible = visible == 0
        bindPanel.Size = UDim2.fromOffset(180, 24 + math.max(visible, 1) * 17)
        if not dragging then
            local x, y = clampBindPosition(tonumber(State.hudKeybindX) or 18,
                tonumber(State.hudKeybindY) or 120)
            State.hudKeybindX, State.hudKeybindY = x, y
            bindPanel.Position = UDim2.fromOffset(x, y)
        end
    end)
    addHitToast = function(e)
        local accent = Color3.fromRGB(188, 151, 169)
        local card = ui("CanvasGroup", {
            Name = "HitToast", Size = UDim2.fromOffset(326, 48),
            AnchorPoint = Vector2.new(0.5, 1),
            Position = UDim2.new(0.5, 0, 1, 54),
            BackgroundColor3 = Color3.fromRGB(30, 30, 30),
            BorderSizePixel = 0, GroupTransparency = 1,
        }, hitStack)
        ui("UICorner", { CornerRadius = UDim.new(0, 5) }, card)
        ui("UIStroke", { Color = Color3.fromRGB(52, 52, 52), Thickness = 1 }, card)
        ui("Frame", {
            Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 24),
            BackgroundColor3 = Color3.fromRGB(76, 58, 67), BorderSizePixel = 0,
        }, card)
        ui("TextLabel", {
            Size = UDim2.new(1, -100, 0, 18), Position = UDim2.fromOffset(10, 3),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            Text = e.name, TextTruncate = Enum.TextTruncate.AtEnd,
            TextSize = 12, TextColor3 = Color3.fromRGB(224, 224, 224),
            TextXAlignment = Enum.TextXAlignment.Left,
        }, card)
        ui("TextLabel", {
            Size = UDim2.new(1, -20, 0, 16), Position = UDim2.fromOffset(10, 28),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham,
            Text = ("%s  ·  %d studs%s"):format(e.part, math.floor(e.dist + 0.5), e.wall and "  ·  WALL" or ""),
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextSize = 11, TextColor3 = Color3.fromRGB(173, 173, 173),
            TextXAlignment = Enum.TextXAlignment.Left,
        }, card)
        ui("TextLabel", {
            Size = UDim2.fromOffset(80, 18), Position = UDim2.new(1, -90, 0, 3),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            Text = e.silent and "silent" or "direct", TextSize = 10,
            TextColor3 = accent, TextXAlignment = Enum.TextXAlignment.Right,
        }, card)
        e.progress = ui("Frame", {
            Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
            BackgroundColor3 = accent, BorderSizePixel = 0,
        }, card)
        e.toast = card
    end
    conns[#conns + 1] = RunService.RenderStepped:Connect(function(dt)
        if marker.Visible then
            local markerAge = os.clock() - markerAt
            if markerAge >= 0.28 or not (State.hudHitMarker or (State.fxEnable and State.fxHitMarkers))
                or State._menuOpen then
                marker.Visible = false
            else
                marker.GroupTransparency = math.clamp((markerAge - 0.08) / 0.2, 0, 1)
            end
        end
        if #hitlog == 0 then return end
        local now = os.clock()
        for i = #hitlog, 1, -1 do
            local e = hitlog[i]
            if now - e.at >= HITLOG_LIFE then
                if e.toast then e.toast:Destroy() end
                table.remove(hitlog, i)
            end
        end
        for i, e in ipairs(hitlog) do
            local card = e.toast
            if card then
                local age = now - e.at
                local targetY = -(i - 1) * 54
                local pos = card.Position.Y.Offset
                card.Position = UDim2.new(0.5, 0, 1, pos + (targetY - pos) * math.min(1, dt * 18))
                card.GroupTransparency = State.hudHitlog and math.clamp(
                    math.max(1 - age * 8, (age - HITLOG_LIFE + 0.55) / 0.55), 0, 1) or 1
                card.Visible = State.hudHitlog == true and State._menuOpen ~= true
                e.progress.Size = UDim2.new(math.clamp(1 - age / HITLOG_LIFE, 0, 1), 0, 0, 1)
            end
        end
    end)
    if Drawing then
        for i = 1, 2 do
            hudLines[i] = newDraw("Text", {
                Text = "", Size = 14, Color = COL_TEXT, Center = false,
                Outline = true, OutlineColor = Color3.new(0, 0, 0),
                Font = 2, Visible = false, ZIndex = 6,
            })
        end
        local fps, fpsFrames, fpsAt = 0, 0, os.clock()
        local nextHudUpdate = 0
        conns[#conns + 1] = RunService.RenderStepped:Connect(function()
            fpsFrames = fpsFrames + 1
            local now = os.clock()
            if now - fpsAt >= 0.5 then
                fps = math.floor(fpsFrames / (now - fpsAt) + 0.5)
                fpsFrames, fpsAt = 0, now
            end
            if now < nextHudUpdate then return end
            nextHudUpdate = now + 0.2
            local rows = {}
            if State.hudWatermark then
                local okPing, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
                rows[#rows + 1] = ("romordial  |  %d fps  |  %d ms"):format(fps,
                    okPing and math.floor(ping * 1000) or 0)
            end
            if State.hudSpecs then
                rows[#rows + 1] = ("spectators: %d"):format(tonumber(LocalPlayer:GetAttribute("Spectators")) or 0)
            end
            for i, line in ipairs(hudLines) do
                if rows[i] then
                    line.Text = rows[i]
                    line.Position = Vector2.new(12, 60 + (i - 1) * 16)
                    line.Visible = true
                else
                    line.Visible = false
                end
            end
        end)
    end

    (function()
    local grenadePath, grenadeMarker, grenadeLabel = {}, {}, nil
    local grenadePreviewVisible, grenadeDrawingUnavailable = false, false
    local grenadePreviewAt = 0
    local grenadeTargetPoints, grenadeDisplayPoints, grenadeLanded
    local grenadeProjected, grenadePointVisible = {}, {}
    local function hideGrenadePreview()
        grenadeTargetPoints, grenadeDisplayPoints, grenadeLanded = nil, nil, nil
        grenadePreviewAt = 0
        if not grenadePreviewVisible then return end
        grenadePreviewVisible = false
        for _, line in ipairs(grenadePath) do line.Visible = false end
        for _, line in ipairs(grenadeMarker) do line.Visible = false end
        if grenadeLabel then grenadeLabel.Visible = false end
    end
    local function ensureGrenadeDrawings()
        if grenadeDrawingUnavailable or not Drawing then return false end
        if grenadeLabel then return true end
        local ok = pcall(function()
            local accent = Color3.fromRGB(188, 151, 169)
            for i = 1, 36 do
                grenadePath[i] = newDraw("Line", {
                    Thickness = 2, Color = accent, Transparency = 0.85,
                    Visible = false, ZIndex = 9,
                })
            end
            for i = 1, 2 do
                grenadeMarker[i] = newDraw("Line", {
                    Thickness = 2, Color = accent, Transparency = 1,
                    Visible = false, ZIndex = 10,
                })
            end
            grenadeLabel = newDraw("Text", {
                Text = "", Size = 12, Color = accent, Center = true,
                Outline = true, OutlineColor = Color3.new(0, 0, 0),
                Font = 2, Visible = false, ZIndex = 10,
            })
        end)
        if not ok then grenadeDrawingUnavailable = true end
        return ok
    end
    local function grenadeTrajectory(cam, char, root, weapon)
        local tp = Shared.tpState
        local aim = tp and tp.active and tp.fp or cam.CFrame
        local props = weapon.Properties
        local configuredSpeed = math.clamp(tonumber(State.grenadeThrowSpeed) or 105, 50, 180)
        local listedSpeed = tonumber(props.ThrowSpeed)
            or tonumber(props.ProjectileSpeed) or tonumber(props.ThrowVelocity)
        local speed = listedSpeed and listedSpeed >= 40 and listedSpeed <= 220
            and listedSpeed or configuredSpeed
        local start = aim.Position + aim.LookVector * 2
            + aim.RightVector * 0.3 - aim.UpVector * 0.4
        local velocity = aim.LookVector * speed + Vector3.new(0, speed * 0.18, 0)
            + root.AssemblyLinearVelocity * 0.4
        local gravityScale = tonumber(props.GravityScale)
        if not gravityScale or gravityScale < 0.3 or gravityScale > 2.5 then
            gravityScale = 1
        end
        local acceleration = Vector3.new(0, -Workspace.Gravity * gravityScale, 0)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { char, cam }
        local points = { start }
        local position, landed = start, false
        local dt = 0.08
        for _ = 1, 36 do
            local nextVelocity = velocity + acceleration * dt
            local displacement = (velocity + nextVelocity) * (dt * 0.5)
            local hit = Workspace:Raycast(position, displacement, params)
            if hit then
                position = hit.Position + hit.Normal * 0.04
                points[#points + 1] = position
                local normalSpeed = nextVelocity:Dot(hit.Normal)
                if normalSpeed < 0 then
                    local rebound = nextVelocity - hit.Normal * (1.4 * normalSpeed)
                    local normal = hit.Normal * rebound:Dot(hit.Normal)
                    velocity = normal * 0.65 + (rebound - normal) * 0.7
                else
                    velocity = nextVelocity
                end
                if hit.Normal.Y > 0.55 and velocity.Magnitude < 18 then
                    landed = true
                    break
                end
            else
                position += displacement
                velocity = nextVelocity
                points[#points + 1] = position
            end
        end
        while #points < 37 do points[#points + 1] = position end
        return points, landed
    end
    conns[#conns + 1] = RunService.RenderStepped:Connect(function(dt)
        if not State.grenadePreview or State._menuOpen or not Drawing
            or not weaponInventoryOk or type(WeaponInventory) ~= "table" then
            hideGrenadePreview()
            return
        end
        local now = os.clock()
        local cam = Workspace.CurrentCamera
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not cam or not root or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true then
            hideGrenadePreview()
            return
        end
        if now >= grenadePreviewAt then
            grenadePreviewAt = now + 1 / 12
            local okWeapon, weapon = pcall(WeaponInventory.peekCurrentEquippedForMovement)
            local props = okWeapon and type(weapon) == "table" and weapon.Properties
            if type(props) ~= "table" or props.Slot ~= "Grenade"
                or props.Class == "C4" or not ensureGrenadeDrawings() then
                hideGrenadePreview()
                return
            end
            local okPath, points, landed = pcall(grenadeTrajectory, cam, char, root, weapon)
            if not okPath then hideGrenadePreview(); return end
            grenadeTargetPoints, grenadeLanded = points, landed
            if not grenadeDisplayPoints then
                grenadeDisplayPoints = table.clone(points)
            end
        end
        if not grenadeTargetPoints or not grenadeDisplayPoints then return end
        local smoothing = 1 - math.exp(-math.min(tonumber(dt) or 0.016, 0.1) * 24)
        local tp = Shared.tpState
        local aim = tp and tp.active and tp.fp or cam.CFrame
        for i, target in ipairs(grenadeTargetPoints) do
            local current = grenadeDisplayPoints[i] or target
            local position = i == 1
                and (aim.Position + aim.LookVector * 2
                    + aim.RightVector * 0.3 - aim.UpVector * 0.4)
                or current:Lerp(target, smoothing)
            grenadeDisplayPoints[i] = position
            local screen, onScreen = cam:WorldToViewportPoint(position)
            grenadeProjected[i] = screen
            grenadePointVisible[i] = onScreen == true and screen.Z > 0
        end
        grenadePreviewVisible = true
        for i, line in ipairs(grenadePath) do
            local ap, bp = grenadeProjected[i], grenadeProjected[i + 1]
            line.Visible = grenadePointVisible[i] == true
                and grenadePointVisible[i + 1] == true
                and math.abs(ap.X - bp.X) + math.abs(ap.Y - bp.Y) > 0.8
            if line.Visible then
                line.From = Vector2.new(ap.X, ap.Y)
                line.To = Vector2.new(bp.X, bp.Y)
                line.Transparency = 0.55 + 0.4 * (i / 36)
            end
        end
        local screen = grenadeProjected[#grenadeTargetPoints]
        local visible = grenadePointVisible[#grenadeTargetPoints] == true
        for i, line in ipairs(grenadeMarker) do
            line.Visible = visible
            if visible then
                local sign = i == 1 and 1 or -1
                line.From = Vector2.new(screen.X - 6, screen.Y - 6 * sign)
                line.To = Vector2.new(screen.X + 6, screen.Y + 6 * sign)
            end
        end
        grenadeLabel.Visible = visible
        if visible then
            grenadeLabel.Text = grenadeLanded and "EST. LAND" or "EST. PATH"
            grenadeLabel.Position = Vector2.new(screen.X, screen.Y + 11)
        end
    end)
    _G.__bs_add_teardown(function()
        for _, d in ipairs(grenadePath) do pcall(function() d:Remove() end) end
        for _, d in ipairs(grenadeMarker) do pcall(function() d:Remove() end) end
        if grenadeLabel then pcall(function() grenadeLabel:Remove() end) end
    end)
    end)()

    _G.__bs_add_teardown(function()
        if UPDATE_CONN then UPDATE_CONN:Disconnect() end
        clearMoveTrail()
        backtrackConn:Disconnect()
        for plr in pairs(backtrackDrawings) do removeBacktrack(plr) end
        for _, c in ipairs(conns) do c:Disconnect() end
        for _, d in ipairs(hudLines)    do pcall(function() d:Remove() end) end
        for _, tracer in ipairs(tracerPool) do
            pcall(function() tracer.edge:Remove(); tracer.core:Remove() end)
        end
        bodySound:Destroy()
        headSound:Destroy()
        hitGui:Destroy()
        bindGui:Destroy()
        for _, set in pairs(espByPlayer) do
            for _, d in pairs(set) do pcall(function() d:Remove() end) end
        end
        for char in pairs(chamsByChar) do removeCham(char) end
        removeWeaponCham()
        restoreThirdPersonAppearance()
        restorePitchPose()
        if sceneTintEffect then sceneTintEffect:Destroy(); sceneTintEffect = nil end
        for char in pairs(auraByChar) do removeAura(char) end
        for char in pairs(jointCache) do dropCharacterCaches(char) end
        for char in pairs(partCache) do dropCharacterCaches(char) end
        for char in pairs(gameHlCache) do dropCharacterCaches(char) end
        for _, c in ipairs(outsideConns) do c:Disconnect() end
        for _, c in ipairs(cameraConns) do c:Disconnect() end
        for _, c in pairs(outsideAdorneeConns) do c:Disconnect() end
        if chamsFolder then chamsFolder:Destroy() end
    end)
    print("[bs] visuals loaded")
end

-- Cosmetic effects use fixed pools and never participate in game raycasts.
do
    State.fxEnable = false
    State.fxHalo = false
    State.fxOrbits = false
    State.fxTargetRing = false
    State.fxImpacts = false
    State.fxTracers = false
    State.fxHitMarkers = false
    State.fxRainbow = false
    State.fxSpeed = 1
    State.fxRadius = 2.5
    State.colFxPrimary = Color3.fromRGB(235, 105, 190)
    State.colFxSecondary = Color3.fromRGB(95, 205, 245)
    local folder, halo, orbits
    local attached, nextWorldUpdate = false, 0
    local effectCharacter, effectGeneration
    local impacts, impactIndex = {}, 0
    local targetOuter, targetInner
    local targetPart, targetPoint, targetLocalPoint
    local nextTargetScan = 0

    Shared.fxColor = function(now, secondary)
        if State.fxRainbow then
            local speed = math.clamp(tonumber(State.fxSpeed) or 1, 0.25, 3)
            return Color3.fromHSV((now * 0.12 * speed + (secondary and 0.18 or 0)) % 1, 0.65, 1)
        end
        local color = secondary and State.colFxSecondary or State.colFxPrimary
        return typeof(color) == "Color3" and color or Color3.fromRGB(235, 105, 190)
    end

    local function effectPart(name, size)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.Anchored = true
        part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
        part.CastShadow = false
        part.Material = Enum.Material.Neon
        part.Transparency = 0.2
        part.Parent = folder
        return part
    end

    local function buildWorldEffects()
        if folder then return end
        folder = Instance.new("Folder")
        folder.Name = "bs_visual_pack"
        halo, orbits = {}, {}
        for i = 1, 16 do
            halo[i] = effectPart("halo_segment", Vector3.new(0.045, 0.045, 0.34))
        end
        for i = 1, 3 do
            local part = effectPart("orbit_orb", Vector3.new(0.18, 0.18, 0.18))
            part.Shape = Enum.PartType.Ball
            local a = Instance.new("Attachment")
            a.Position = Vector3.new(0, 0.08, 0)
            a.Parent = part
            local b = Instance.new("Attachment")
            b.Position = Vector3.new(0, -0.08, 0)
            b.Parent = part
            local trail = Instance.new("Trail")
            trail.Attachment0, trail.Attachment1 = a, b
            trail.FaceCamera = true
            trail.Lifetime = 0.45
            trail.MinLength = 0.05
            trail.LightEmission = 1
            trail.WidthScale = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0),
            })
            trail.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1),
            })
            trail.Enabled = false
            trail.Parent = part
            orbits[i] = { part = part, trail = trail }
        end
    end

    local function detachWorldEffects()
        if folder and attached then
            for _, orbit in ipairs(orbits) do
                orbit.trail.Enabled = false
                orbit.trail:Clear()
            end
            folder.Parent = nil
            attached = false
        end
    end

    local function circle(thickness)
        if not Drawing then return nil end
        local ok, result = pcall(Drawing.new, "Circle")
        if not ok then return nil end
        result.Filled = false
        result.NumSides = 48
        result.Thickness = thickness
        result.Transparency = 1
        result.Visible = false
        result.ZIndex = 9
        return result
    end

    Shared.pushVisualImpact = function(point, headshot)
        if not State.fxEnable or not State.fxImpacts or State._menuOpen
            or typeof(point) ~= "Vector3" then return end
        local nextIndex = impactIndex % 6 + 1
        local entry = impacts[nextIndex]
        if not entry then
            local outer, inner = circle(2), circle(1)
            if not outer or not inner then
                if outer then outer:Remove() end
                if inner then inner:Remove() end
                return
            end
            entry = { outer = outer, inner = inner }
            impacts[nextIndex] = entry
        end
        impactIndex = nextIndex
        entry.point, entry.at, entry.headshot = point, os.clock(), headshot
    end

    local connection = RunService.RenderStepped:Connect(function()
        local now = os.clock()
        local camera = Workspace.CurrentCamera
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local alive = root ~= nil and char:GetAttribute("Dead") ~= true
            and LocalPlayer:GetAttribute("IsSpectating") ~= true
        local enabled = State.fxEnable == true and alive and camera ~= nil
        local generation = char and char:GetAttribute("CharacterGeneration")
        if effectCharacter ~= char or effectGeneration ~= generation then
            detachWorldEffects()
            effectCharacter, effectGeneration = char, generation
        end
        local speed = math.clamp(tonumber(State.fxSpeed) or 1, 0.25, 3)
        local primary, secondary = Shared.fxColor(now), Shared.fxColor(now, true)
        if enabled and (State.fxHalo or State.fxOrbits) then
            if now >= nextWorldUpdate then
                nextWorldUpdate = now + 1 / 30
                buildWorldEffects()
                local phase = now * speed * 2
                local head = char:FindFirstChild("Head")
                local center = (head and head.Position or root.Position + Vector3.new(0, 2, 0))
                    + Vector3.new(0, 0.85, 0)
                for i, part in ipairs(halo) do
                    part.Transparency = State.fxHalo and (0.2 + 0.1 * math.sin(phase + i * 0.4)) or 1
                    if State.fxHalo then
                        local angle = (i - 1) * math.pi / 8 + phase * 0.3
                        local position = center + Vector3.new(math.cos(angle) * 0.85, 0, math.sin(angle) * 0.85)
                        part.CFrame = CFrame.new(position) * CFrame.Angles(0, -angle, 0)
                        local color = i % 4 == 0 and secondary or primary
                        if part.Color ~= color then part.Color = color end
                    end
                end
                local radius = math.clamp(tonumber(State.fxRadius) or 2.5, 1, 5)
                for i, orbit in ipairs(orbits) do
                    orbit.part.Transparency = State.fxOrbits and 0.1 or 1
                    if State.fxOrbits then
                        local angle = phase + (i - 1) * math.pi * 2 / 3
                        orbit.part.CFrame = CFrame.new(root.Position + Vector3.new(
                            math.cos(angle) * radius, 0.2 + math.sin(angle * 2) * 1.1,
                            math.sin(angle) * radius))
                        local color = i == 2 and secondary or primary
                        if orbit.part.Color ~= color then
                            orbit.part.Color = color
                            orbit.trail.Color = ColorSequence.new(color, secondary)
                        end
                    elseif orbit.trail.Enabled then
                        orbit.trail:Clear()
                    end
                    orbit.trail.Enabled = State.fxOrbits == true
                end
                if not attached then folder.Parent = Workspace; attached = true end
            end
        else
            detachWorldEffects()
        end

        local screenEffects = enabled and not State._menuOpen
        if screenEffects and State.fxTargetRing and State.rageEnable and Shared.rageVisualTarget then
            if now >= nextTargetScan then
                nextTargetScan = now + 0.15
                local ok, point, part = pcall(Shared.rageVisualTarget)
                targetPoint, targetPart, targetLocalPoint = nil, nil, nil
                if ok and typeof(point) == "Vector3" then
                    targetPoint = point
                    if typeof(part) == "Instance" and part:IsA("BasePart") then
                        targetPart, targetLocalPoint = part, part.CFrame:PointToObjectSpace(point)
                    end
                end
            end
            local point = targetPoint
            if targetPart then
                point = targetPart.Parent and targetPart.CFrame:PointToWorldSpace(targetLocalPoint) or nil
            end
            if point then
                if not targetOuter then targetOuter = circle(2) end
                if not targetInner then targetInner = circle(1) end
                local projected, onScreen = camera:WorldToViewportPoint(point)
                local visible = onScreen and projected.Z > 0
                for i, drawing in ipairs({ targetOuter, targetInner }) do
                    drawing.Visible = visible
                    if visible then
                        drawing.Position = Vector2.new(projected.X, projected.Y)
                        drawing.Radius = i == 1 and (16 + math.sin(now * speed * 4) * 3) or 7
                        drawing.Color = i == 1 and primary or secondary
                        drawing.Transparency = i == 1 and 0.9 or 0.55
                    end
                end
            else
                if targetOuter then targetOuter.Visible = false end
                if targetInner then targetInner.Visible = false end
            end
        else
            targetPoint, targetPart, targetLocalPoint = nil, nil, nil
            if targetOuter then targetOuter.Visible = false end
            if targetInner then targetInner.Visible = false end
        end
        for _, entry in ipairs(impacts) do
            local age = now - entry.at
            local visible = screenEffects and State.fxImpacts == true and age < 0.45
            local projected
            if visible then
                local point, onScreen = camera:WorldToViewportPoint(entry.point)
                projected, visible = point, onScreen and point.Z > 0
            end
            entry.outer.Visible, entry.inner.Visible = visible, visible
            if visible then
                local position = Vector2.new(projected.X, projected.Y)
                entry.outer.Position, entry.inner.Position = position, position
                entry.outer.Radius = 5 + age * (entry.headshot and 70 or 50)
                entry.inner.Radius = 3 + age * 32
                entry.outer.Color, entry.inner.Color = primary, secondary
                entry.outer.Transparency = 1 - age / 0.45
                entry.inner.Transparency = (1 - age / 0.45) * 0.6
            end
        end
    end)
    _G.__bs_add_teardown(function()
        connection:Disconnect()
        if folder then folder:Destroy() end
        if targetOuter then targetOuter:Remove() end
        if targetInner then targetInner:Remove() end
        for _, entry in ipairs(impacts) do entry.outer:Remove(); entry.inner:Remove() end
        Shared.fxColor, Shared.pushVisualImpact = nil, nil
    end)
end

do
    State.hudSnow = false
    State.hudCrosshairInfo = false
    State.hudCrosshairMode = "both"
    State.hudSpinCrosshair = false
    State.hudHideGameCrosshair = false
    State.hudCrosshairSpeed = 120
    State.hudScopeLines = false
    State.hudRemoveScope = true
    local menuBlur = Instance.new("BlurEffect")
    menuBlur.Name = "bs_menu_blur"
    menuBlur.Size = 0
    menuBlur.Parent = game:GetService("Lighting")

    local gui = Instance.new("ScreenGui")
    gui.Name = "bs_screen_fx"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 9996
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    local snow = Instance.new("Frame")
    snow.Name = "Snow"
    snow.Size = UDim2.fromScale(1, 1)
    snow.BackgroundTransparency = 1
    snow.ClipsDescendants = true
    snow.Visible = false
    snow.Parent = gui
    local flakes = {}
    for i = 1, 58 do
        local dot = Instance.new("Frame")
        local radius = math.random(2, 6)
        dot.Size = UDim2.fromOffset(radius, radius)
        dot.BackgroundColor3 = i % 5 == 0 and Color3.fromRGB(175, 200, 255)
            or Color3.fromRGB(236, 242, 255)
        dot.BackgroundTransparency = math.random(20, 55) / 100
        dot.BorderSizePixel = 0
        dot.Parent = snow
        local round = Instance.new("UICorner")
        round.CornerRadius = UDim.new(1, 0)
        round.Parent = dot
        flakes[i] = {
            dot = dot, x = math.random(), y = math.random(),
            speed = math.random(35, 110), drift = math.random(-22, 22),
            phase = math.random() * math.pi * 2,
        }
    end

    local reticle = Instance.new("Frame")
    reticle.Name = "SpinCrosshair"
    reticle.AnchorPoint = Vector2.new(0.5, 0.5)
    reticle.Size = UDim2.fromOffset(52, 52)
    reticle.BackgroundTransparency = 1
    reticle.Visible = false
    reticle.Parent = gui
    local spinner = Instance.new("Frame")
    spinner.Name = "Orbit"
    spinner.Size = UDim2.fromScale(1, 1)
    spinner.BackgroundTransparency = 1
    spinner.Parent = reticle
    local ticks = {}
    for index = 1, 4 do
        local tick = Instance.new("Frame")
        tick.Name = "Tick" .. index
        tick.AnchorPoint = Vector2.new(0.5, 0.5)
        tick.Size = UDim2.fromOffset(index % 2 == 0 and 9 or 2, index % 2 == 0 and 2 or 9)
        tick.Position = ({ UDim2.fromOffset(26, 3), UDim2.fromOffset(49, 26),
            UDim2.fromOffset(26, 49), UDim2.fromOffset(3, 26) })[index]
        tick.BorderSizePixel = 0
        tick.Parent = spinner
        ticks[index] = tick
    end
    local sights = {}
    for index = 1, 4 do
        local sight = Instance.new("Frame")
        sight.Name = "Sight" .. index
        sight.AnchorPoint = Vector2.new(0.5, 0.5)
        sight.Size = UDim2.fromOffset(index % 2 == 0 and 5 or 1, index % 2 == 0 and 1 or 5)
        sight.Position = ({ UDim2.fromOffset(26, 17), UDim2.fromOffset(35, 26),
            UDim2.fromOffset(26, 35), UDim2.fromOffset(17, 26) })[index]
        sight.BackgroundColor3 = Color3.fromRGB(223, 223, 225)
        sight.BorderSizePixel = 0
        sight.Parent = reticle
        sights[index] = sight
    end
    local dot = Instance.new("Frame")
    dot.Name = "CenterDot"
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.Position = UDim2.fromScale(0.5, 0.5)
    dot.Size = UDim2.fromOffset(3, 3)
    dot.BorderSizePixel = 0
    dot.Parent = reticle
    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot
    local scopeLines = Instance.new("Frame")
    scopeLines.Name = "ScopeLines"
    scopeLines.Size = UDim2.fromScale(1, 1)
    scopeLines.BackgroundTransparency = 1
    scopeLines.Visible = false
    scopeLines.Parent = gui
    local scopeColor = Color3.fromRGB(191, 178, 184)
    local scopeSegments = {
        { UDim2.new(0, 0, 0.5, 0), UDim2.new(0.5, -11, 0, 1) },
        { UDim2.new(0.5, 11, 0.5, 0), UDim2.new(0.5, -11, 0, 1) },
        { UDim2.new(0.5, 0, 0, 0), UDim2.new(0, 1, 0.5, -11) },
        { UDim2.new(0.5, 0, 0.5, 11), UDim2.new(0, 1, 0.5, -11) },
    }
    for index, segment in ipairs(scopeSegments) do
        local line = Instance.new("Frame")
        line.Name = "Line" .. index
        line.Position = segment[1]
        line.Size = segment[2]
        line.BackgroundColor3 = scopeColor
        line.BackgroundTransparency = 0.18
        line.BorderSizePixel = 0
        line.Parent = scopeLines
    end
    local targetLabel = Instance.new("TextLabel")
    targetLabel.Name = "TargetLabel"
    targetLabel.AnchorPoint = Vector2.new(0.5, 0)
    targetLabel.Size = UDim2.fromOffset(190, 20)
    targetLabel.BackgroundTransparency = 1
    targetLabel.Font = Enum.Font.GothamMedium
    targetLabel.TextSize = 11
    targetLabel.TextStrokeTransparency = 0.55
    targetLabel.TextXAlignment = Enum.TextXAlignment.Center
    targetLabel.Visible = false
    targetLabel.Parent = gui

    local playerGui = gui.Parent
    local hiddenCrosshairs = {}
    local hiddenScopes = {}
    local mouseIconBefore = nil
    local invOk, scopeInventory = pcall(require, ReplicatedStorage.Controllers.InventoryController)
    local scopeActive = false
    local scopedWeapon = nil
    local normalFov = 70
    local function scopedSniper(includeIdle)
        if not (State.hudScopeLines or State.hudRemoveScope) or not invOk or not scopeInventory then return nil end
        local char = LocalPlayer.Character
        if not char or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true then return nil end
        local ok, weapon = pcall(scopeInventory.peekCurrentEquippedForMovement)
        local props = ok and type(weapon) == "table" and weapon.Properties
        local aiming = weapon and (weapon.IsAiming == true
            or weapon.IsSniperScoped == true or weapon.IsScoped == true
            or weapon.IsScoping == true)
        if not aiming then
            aiming = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
                or LocalPlayer:GetAttribute("IsSniperScoped") == true
        end
        if type(props) == "table" and (props.AimingOptions == "SniperScope"
            or State.hudRemoveScope and props.AimingOptions == "AutomaticScope")
            and (aiming or includeIdle and State.hudRemoveScope)
            and weapon.IsDestroyed ~= true then return weapon end
        return nil
    end
    local scopeActions = game:GetService("ContextActionService")
    local removeScopeAction = "bs_remove_scope"
    scopeActions:BindActionAtPriority(removeScopeAction, function()
        if State.hudRemoveScope and scopedSniper(true) then return Enum.ContextActionResult.Sink end
        return Enum.ContextActionResult.Pass
    end, false, 3000, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)
    local function clearScopeState(weapon)
        if not State.hudRemoveScope or not weapon then return end
        if weapon.IsAiming then weapon.IsAiming = false end
        if weapon.IsSniperScoped then weapon.IsSniperScoped = false end
        if weapon.IsScoped then weapon.IsScoped = false end
        if weapon.IsScoping then weapon.IsScoping = false end
        if LocalPlayer:GetAttribute("IsSniperScoped") == true then
            LocalPlayer:SetAttribute("IsSniperScoped", false)
        end
    end
    local scopeFovBind = "bs_scope_fov"
    local watchedCamera, fovConn, writingFov
    local scopeReleasedAt = -math.huge
    local mouseSenseOk, normalMouseSense = pcall(function()
        return UserInputService.MouseDeltaSensitivity
    end)
    if not mouseSenseOk then normalMouseSense = nil end
    local writingMouseSense = false
    local function holdNormalMouseSense()
        if not scopeActive or not normalMouseSense or writingMouseSense then return end
        local ok, current = pcall(function() return UserInputService.MouseDeltaSensitivity end)
        if ok and type(current) == "number"
            and math.abs(current - normalMouseSense) > 0.001 then
            writingMouseSense = true
            pcall(function() UserInputService.MouseDeltaSensitivity = normalMouseSense end)
            writingMouseSense = false
        end
    end
    local mouseSenseConn
    if mouseSenseOk then
        local ok, conn = pcall(function()
            return UserInputService:GetPropertyChangedSignal("MouseDeltaSensitivity"):Connect(
                holdNormalMouseSense)
        end)
        if ok then mouseSenseConn = conn end
    end
    local function holdNormalFov(cam)
        if scopeActive and not writingFov and math.abs(cam.FieldOfView - normalFov) > 0.01 then
            writingFov = true
            cam.FieldOfView = normalFov
            writingFov = false
        end
    end
    RunService:BindToRenderStep(scopeFovBind, Enum.RenderPriority.Last.Value, function()
        local cam = Workspace.CurrentCamera
        local wasScoped = scopeActive
        scopedWeapon = cam and scopedSniper() or nil
        scopeActive = scopedWeapon ~= nil
        clearScopeState(scopedWeapon)
        if wasScoped and not scopeActive then scopeReleasedAt = os.clock() end
        if not cam then return end
        if watchedCamera ~= cam then
            if fovConn then fovConn:Disconnect() end
            watchedCamera = cam
            fovConn = cam:GetPropertyChangedSignal("FieldOfView"):Connect(function()
                holdNormalFov(cam)
            end)
        end
        if scopeActive then
            holdNormalFov(cam)
            holdNormalMouseSense()
        elseif cam.FieldOfView > 55 then
            normalFov = math.max(normalFov, cam.FieldOfView)
        end
        if not scopeActive and mouseSenseOk and os.clock() - scopeReleasedAt > 0.35 then
            local ok, current = pcall(function() return UserInputService.MouseDeltaSensitivity end)
            if ok and type(current) == "number" and current > 0 then
                normalMouseSense = current
            end
        end
    end)
    local hiddenScopeParts = {}
    local hiddenScopeModel = nil
    local function setScopeViewmodelHidden(hide)
        local model = hide and scopedWeapon and scopedWeapon.Viewmodel
            and scopedWeapon.Viewmodel.Model
        if typeof(model) ~= "Instance" then model = nil end
        if model ~= hiddenScopeModel then
            for part, transparency in pairs(hiddenScopeParts) do
                if part.Parent then part.LocalTransparencyModifier = transparency end
                hiddenScopeParts[part] = nil
            end
            hiddenScopeModel = model
            if model then
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        hiddenScopeParts[part] = part.LocalTransparencyModifier
                    end
                end
            end
        end
        if model then
            for part in pairs(hiddenScopeParts) do
                if part.Parent then
                    if part.LocalTransparencyModifier ~= 1 then
                        part.LocalTransparencyModifier = 1
                    end
                else hiddenScopeParts[part] = nil end
            end
        end
    end
    local function crosshairObject(obj)
        if obj == gui or obj:IsDescendantOf(gui) then return false end
        local name = obj.Name:lower()
        if name:find("scope", 1, true) then return false end
        return name:find("crosshair", 1, true) ~= nil
            or name:find("cross_hair", 1, true) ~= nil
            or name:find("reticle", 1, true) ~= nil
    end
    local function hideGameCrosshair(obj)
        if crosshairObject(obj) then
            if obj:IsA("ScreenGui") then
                if hiddenCrosshairs[obj] == nil then hiddenCrosshairs[obj] = obj.Enabled end
                obj.Enabled = false
            elseif obj:IsA("GuiObject") then
                if hiddenCrosshairs[obj] == nil then hiddenCrosshairs[obj] = obj.Visible end
                obj.Visible = false
            end
        end
    end
    local function hideGameCrosshairs()
        for _, obj in ipairs(playerGui:GetDescendants()) do hideGameCrosshair(obj) end
    end
    local function hideGameScope(obj)
        if obj == gui or obj:IsDescendantOf(gui)
            or obj:FindFirstAncestor("aether") then return end
        local name = obj.Name:lower()
        local namedScope = name:find("scope", 1, true)
            or name:find("sniper", 1, true)
            or name:find("aimoverlay", 1, true)
        local backdrop = false
        local cam = Workspace.CurrentCamera
        if cam and obj:IsA("GuiObject") then
            local size, viewport = obj.AbsoluteSize, cam.ViewportSize
            local center = obj.AbsolutePosition + size * 0.5
            local centered = math.abs(center.X - viewport.X * 0.5) < viewport.X * 0.15
                and math.abs(center.Y - viewport.Y * 0.5) < viewport.Y * 0.15
            local width = size.X / math.max(viewport.X, 1)
            local height = size.Y / math.max(viewport.Y, 1)
            local edgeMask = width * height > 0.035
                and width > 0.16 and height > 0.16
            if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                backdrop = obj.ImageTransparency < 0.95
                    and (edgeMask or (centered and width > 0.32 and height > 0.55))
            elseif obj:IsA("Frame") and obj.BackgroundTransparency < 0.5 then
                local color = obj.BackgroundColor3
                backdrop = color.R < 0.18 and color.G < 0.18 and color.B < 0.18
                    and (edgeMask or (centered and width > 0.24 and height > 0.7))
            end
        end
        if not namedScope and not backdrop then return end
        if namedScope and cam and obj:IsA("GuiObject") then
            local parent = obj.Parent
            if parent and parent:IsA("GuiObject") and not parent:IsDescendantOf(gui) then
                local size, viewport = parent.AbsoluteSize, cam.ViewportSize
                local center = parent.AbsolutePosition + size * 0.5
                local width = size.X / math.max(viewport.X, 1)
                local height = size.Y / math.max(viewport.Y, 1)
                if width > 0.2 and height > 0.2 and width < 0.95 and height < 0.95
                    and math.abs(center.X - viewport.X * 0.5) < viewport.X * 0.2
                    and math.abs(center.Y - viewport.Y * 0.5) < viewport.Y * 0.2 then
                    obj = parent
                end
            end
        end
        if obj:IsA("ScreenGui") then
            if hiddenScopes[obj] == nil then hiddenScopes[obj] = obj.Enabled end
            if obj.Enabled then obj.Enabled = false end
        elseif obj:IsA("GuiObject") then
            if hiddenScopes[obj] == nil then hiddenScopes[obj] = obj.Visible end
            if obj.Visible then obj.Visible = false end
        end
    end
    local function restoreGameScope()
        for obj, oldValue in pairs(hiddenScopes) do
            if obj.Parent then
                if obj:IsA("ScreenGui") then obj.Enabled = oldValue
                elseif obj:IsA("GuiObject") then obj.Visible = oldValue end
            end
            hiddenScopes[obj] = nil
        end
    end
    local pendingScopeGui = {}
    local scopeGuiScheduled = false
    local crosshairConn = playerGui.DescendantAdded:Connect(function(obj)
        if State.hudHideGameCrosshair and (reticle.Visible or scopeActive) then
            hideGameCrosshair(obj)
        end
        if scopeActive then
            hideGameScope(obj)
            if obj:IsA("ImageLabel") or obj:IsA("ImageButton") or obj:IsA("Frame") then
                pendingScopeGui[obj] = true
                if not scopeGuiScheduled then
                    scopeGuiScheduled = true
                    task.delay(0.08, function()
                        scopeGuiScheduled = false
                        for pending in pairs(pendingScopeGui) do
                            if scopeActive and pending.Parent then hideGameScope(pending) end
                            pendingScopeGui[pending] = nil
                        end
                    end)
                end
            end
        end
    end)
    local function restoreGameCrosshairs()
        for obj, oldValue in pairs(hiddenCrosshairs) do
            if obj.Parent then
                if obj:IsA("ScreenGui") then obj.Enabled = oldValue
                elseif obj:IsA("GuiObject") then obj.Visible = oldValue end
            end
            hiddenCrosshairs[obj] = nil
        end
        if mouseIconBefore ~= nil then
            UserInputService.MouseIconEnabled = mouseIconBefore
            mouseIconBefore = nil
        end
    end

    local info = Instance.new("Frame")
    info.Name = "CrosshairInfo"
    info.AnchorPoint = Vector2.new(0.5, 0)
    info.Position = UDim2.new(0.5, 0, 0.5, 30)
    info.Size = UDim2.fromOffset(230, 28)
    info.BackgroundColor3 = Color3.fromRGB(34, 34, 34)
    info.BackgroundTransparency = 0
    info.BorderSizePixel = 0
    info.Visible = false
    info.Parent = gui
    local infoCorner = Instance.new("UICorner")
    infoCorner.CornerRadius = UDim.new(0, 3)
    infoCorner.Parent = info
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(52, 52, 52)
    stroke.Thickness = 1
    stroke.Parent = info
    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(1, 0, 0, 1)
    accent.BackgroundColor3 = Color3.fromRGB(76, 58, 67)
    accent.BorderSizePixel = 0
    accent.Parent = info
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -12, 1, -4)
    label.Position = UDim2.fromOffset(6, 2)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextColor3 = Color3.fromRGB(224, 224, 224)
    label.TextSize = 10
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Text = ""
    label.Parent = info

    local function enemy(plr)
        if plr == LocalPlayer then return false end
        if Workspace:GetAttribute("Gamemode") == "Deathmatch" then return true end
        local a, b = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
        if a ~= nil and b ~= nil then return a ~= b end
        return LocalPlayer.Team == nil or plr.Team == nil or LocalPlayer.Team ~= plr.Team
    end
    local function targetText(cam)
        local mid = cam.ViewportSize * 0.5
        local best, bestPx = nil, 90
        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr.Character
            local head = char and char:FindFirstChild("Head")
            if enemy(plr) and head and char:GetAttribute("Dead") ~= true
                and not (Shared.hiddenByGame and Shared.hiddenByGame(plr))
                and not (Shared.staleSeconds and Shared.staleSeconds(plr, head, os.clock()) > 0) then
                local sp, on = cam:WorldToViewportPoint(head.Position)
                if on and sp.Z > 0 then
                    local dx, dy = sp.X - mid.X, sp.Y - mid.Y
                    local px = math.sqrt(dx * dx + dy * dy)
                    if px < bestPx then best, bestPx = plr, px end
                end
            end
        end
        if not best then return nil end
        local char = best.Character
        local head = char and char:FindFirstChild("Head")
        if not head then return nil end
        local hp = math.max(0, math.floor((tonumber(char:GetAttribute("Health")) or 100) + 0.5))
        local dist = math.floor((cam.CFrame.Position - head.Position).Magnitude + 0.5)
        return ("@%s  ·  %d hp  ·  %d studs"):format(best.Name, hp, dist)
    end

    local scanAt, cachedTarget = 0, nil
    local targetScanAt, targetPoint, targetPart, targetLocalPoint = 0, nil, nil, nil
    local crosshairWasHidden = false
    local scopeWasHidden = false
    local scopeRescanAt
    local scopeVisualBind = "bs_scope_visual"
    RunService:BindToRenderStep(scopeVisualBind, Enum.RenderPriority.Last.Value + 100, function()
        if scopeActive then
            local now = os.clock()
            local entering = not scopeWasHidden
            if entering or scopeRescanAt and now >= scopeRescanAt then
                for _, obj in ipairs(playerGui:GetDescendants()) do hideGameScope(obj) end
                scopeRescanAt = entering and now + 0.08 or nil
                scopeWasHidden = true
            end
            for obj in pairs(hiddenScopes) do
                if not obj.Parent then hiddenScopes[obj] = nil
                elseif obj:IsA("ScreenGui") then
                    if obj.Enabled then obj.Enabled = false end
                elseif obj:IsA("GuiObject") and obj.Visible then
                    obj.Visible = false
                end
            end
        elseif scopeWasHidden then
            restoreGameScope()
            scopeWasHidden = false
            scopeRescanAt = nil
        end
    end)
    local snowAt, snowElapsed = 0, 0
    local reticleIdleColor = Color3.fromRGB(191, 188, 192)
    local reticleLockColor = Color3.fromRGB(215, 155, 183)
    local reticleColor = nil
    local conn = RunService.RenderStepped:Connect(function(dt)
        local now = os.clock()
        local blurTarget = State._menuOpen and 8 or 0
        if menuBlur.Size ~= blurTarget then
            local nextSize = menuBlur.Size + (blurTarget - menuBlur.Size) * math.min(1, dt * 12)
            menuBlur.Size = math.abs(nextSize - blurTarget) < 0.05 and blurTarget or nextSize
        end
        local cam = Workspace.CurrentCamera
        if not cam then
            snow.Visible = false; info.Visible = false; reticle.Visible = false
            targetLabel.Visible = false; scopeLines.Visible = false
            setScopeViewmodelHidden(false)
            restoreGameCrosshairs(); restoreGameScope()
            crosshairWasHidden = false
            scopeWasHidden = false
            return
        end
        local scopeSize = UDim2.fromOffset(cam.ViewportSize.X, cam.ViewportSize.Y)
        if scopeLines.Size ~= scopeSize then scopeLines.Size = scopeSize end
        local showScopeLines = scopeActive and not State.hudRemoveScope
        if scopeLines.Visible ~= showScopeLines then scopeLines.Visible = showScopeLines end
        setScopeViewmodelHidden(showScopeLines)
        snow.Visible = State.hudSnow == true and State._menuOpen == true
        if snow.Visible then
            snowElapsed = snowElapsed + dt
            if now - snowAt >= 1 / 30 then
                snowAt = now
                local vp = cam.ViewportSize
                local step = math.min(snowElapsed, 0.1)
                snowElapsed = 0
                for _, flake in ipairs(flakes) do
                    flake.y = flake.y + flake.speed * step / math.max(vp.Y, 1)
                    flake.x = flake.x + (flake.drift + math.sin(now + flake.phase) * 8)
                        * step / math.max(vp.X, 1)
                    if flake.y > 1.02 then flake.y = -0.02; flake.x = math.random() end
                    if flake.x > 1.02 then flake.x = -0.02 end
                    if flake.x < -0.02 then flake.x = 1.02 end
                    flake.dot.Position = UDim2.fromScale(flake.x, flake.y)
                end
            end
        else
            snowElapsed = 0
        end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local alive = root and char:GetAttribute("Dead") ~= true
            and LocalPlayer:GetAttribute("IsSpectating") ~= true
        local showReticle = State.hudSpinCrosshair == true and alive
            and (not scopeActive or State.hudRemoveScope)
        local reticlePosition = cam.ViewportSize * 0.5
        local lockedName = nil
        if showReticle and State.rageEnable and Shared.rageVisualTarget then
            if now - targetScanAt >= 0.12 then
                targetScanAt = now
                local ok, point, part = pcall(Shared.rageVisualTarget)
                targetPoint, targetPart, targetLocalPoint = nil, nil, nil
                if ok and typeof(point) == "Vector3" then
                    targetPoint = point
                    if typeof(part) == "Instance" and part:IsA("BasePart") then
                        targetPart = part
                        targetLocalPoint = part.CFrame:PointToObjectSpace(point)
                    end
                end
            end
            local point = targetPoint
            if targetPart and targetPart.Parent and targetLocalPoint then
                point = targetPart.CFrame:PointToWorldSpace(targetLocalPoint)
            end
            if point then
                local screen, onScreen = cam:WorldToViewportPoint(point)
                if onScreen and screen.Z > 0 then
                    reticlePosition = Vector2.new(screen.X, screen.Y)
                    local model = targetPart and targetPart:FindFirstAncestorOfClass("Model")
                    local player = model and Players:GetPlayerFromCharacter(model)
                    lockedName = player and player.DisplayName or "TARGET"
                end
            end
        else
            targetPoint, targetPart, targetLocalPoint = nil, nil, nil
        end
        reticle.Visible = showReticle == true
        targetLabel.Visible = reticle.Visible and lockedName ~= nil
        if reticle.Visible then
            local color = lockedName and reticleLockColor or reticleIdleColor
            reticle.Position = UDim2.fromOffset(reticlePosition.X, reticlePosition.Y)
            spinner.Rotation = (spinner.Rotation + math.min(dt, 0.05)
                * math.clamp(tonumber(State.hudCrosshairSpeed) or 120, 30, 360)) % 360
            if reticleColor ~= color then
                reticleColor = color
                dot.BackgroundColor3 = color
                for _, tick in ipairs(ticks) do tick.BackgroundColor3 = color end
                for _, sight in ipairs(sights) do sight.BackgroundColor3 = color end
            end
            if lockedName then
                targetLabel.Position = UDim2.fromOffset(reticlePosition.X,
                    math.min(reticlePosition.Y + 29, cam.ViewportSize.Y - 24))
                targetLabel.TextColor3 = color
                local lockText = "LOCK  " .. lockedName
                if targetLabel.Text ~= lockText then targetLabel.Text = lockText end
            end
        end
        if State.hudHideGameCrosshair and (reticle.Visible or scopeActive) then
            if not crosshairWasHidden then
                hideGameCrosshairs()
                crosshairWasHidden = true
            end
            for obj in pairs(hiddenCrosshairs) do
                if obj.Parent then
                    if obj:IsA("ScreenGui") then
                        if obj.Enabled then obj.Enabled = false end
                    elseif obj:IsA("GuiObject") and obj.Visible then
                        obj.Visible = false
                    end
                end
            end
            if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
                if mouseIconBefore == nil then mouseIconBefore = UserInputService.MouseIconEnabled end
                UserInputService.MouseIconEnabled = false
            elseif mouseIconBefore ~= nil then
                UserInputService.MouseIconEnabled = mouseIconBefore
                mouseIconBefore = nil
            end
        else
            if crosshairWasHidden then
                restoreGameCrosshairs()
                crosshairWasHidden = false
            end
        end
        if State.hudCrosshairInfo ~= true or (scopeActive and not State.hudRemoveScope)
            or not root or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true then
            info.Visible = false
            return
        end
        local mode = State.hudCrosshairMode or "both"
        if mode ~= "movement" and now - scanAt >= 0.1 then
            scanAt = now
            cachedTarget = targetText(cam)
        end
        local v = root.AssemblyLinearVelocity
        local speed = math.floor(math.sqrt(v.X * v.X + v.Z * v.Z) + 0.5)
        local side = UserInputService:IsKeyDown(Enum.KeyCode.A) and "A"
            or (UserInputService:IsKeyDown(Enum.KeyCode.D) and "D" or "-")
        local movement = ("speed %d  ·  strafe %s"):format(speed, side)
        if mode == "target" then
            label.Text = cachedTarget or "no target"
        elseif mode == "movement" then
            label.Text = movement
        else
            label.Text = (cachedTarget or "no target") .. "\n" .. movement
        end
        local infoHeight = mode == "both" and 32 or 22
        info.Size = UDim2.fromOffset(230, infoHeight)
        info.Position = UDim2.fromOffset(
            math.clamp(reticlePosition.X, 119, math.max(119, cam.ViewportSize.X - 119)),
            math.min(reticlePosition.Y + (lockedName and 52 or 29),
                math.max(0, cam.ViewportSize.Y - infoHeight - 8)))
        info.Visible = true
    end)
    _G.__bs_add_teardown(function()
        conn:Disconnect()
        RunService:UnbindFromRenderStep(scopeFovBind)
        RunService:UnbindFromRenderStep(scopeVisualBind)
        scopeActions:UnbindAction(removeScopeAction)
        if fovConn then fovConn:Disconnect() end
        if mouseSenseConn then mouseSenseConn:Disconnect() end
        setScopeViewmodelHidden(false)
        crosshairConn:Disconnect()
        restoreGameCrosshairs()
        restoreGameScope()
        scopeActive = false
        table.clear(pendingScopeGui)
        menuBlur:Destroy()
        gui:Destroy()
    end)
end

-- Third-person camera writes run after the game's camera update and revert before its next frame.
-- Collision checks use Workspace:Raycast because the game's raycast inspects caller environments.
do
    local Lighting = game:GetService("Lighting")
    State.worldFullbright = false
    State.worldNoFog      = false
    State.worldTime       = false
    State.worldClock      = 14
    State.worldAmbient    = false
    State.colAmbient      = Color3.fromRGB(150, 150, 170)
    State.worldNoSmoke    = false
    State.worldNeon       = false
    State.worldNeonStrength = 0.85
    State.colNeonSky      = Color3.fromRGB(109, 28, 221)
    State.colNeonWorld    = Color3.fromRGB(27, 164, 239)
    State.tpEnable        = false
    State.tpKey           = Enum.KeyCode.V
    State.tpDistance      = 8
    State.tpHeight        = 1.5
    State.tpSide          = 1.5

    -- [inst] = { [prop] = { v = gameValue } }  (boxed so false/nil survive)
    local saved = {}
    local function apply(want)
        for inst, props in pairs(want) do
            local s = saved[inst]
            if not s then s = {}; saved[inst] = s end
            for prop, val in pairs(props) do
                if s[prop] == nil then s[prop] = { v = inst[prop] } end
                if inst[prop] ~= val then inst[prop] = val end
            end
        end
        for inst, props in pairs(saved) do
            for prop, box in pairs(props) do
                if not (want[inst] and want[inst][prop] ~= nil) then
                    if inst.Parent then pcall(function() inst[prop] = box.v end) end
                    props[prop] = nil
                end
            end
            if next(props) == nil then saved[inst] = nil end
        end
    end

    local neonAtmo, neonGrade
    local function lightingBase(prop)
        local props = saved[Lighting]
        return props and props[prop] and props[prop].v or Lighting[prop]
    end
    local nextLightUpdate = 0
    local lightConn = RunService.RenderStepped:Connect(function()
        local updateAt = os.clock()
        if updateAt < nextLightUpdate then return end
        nextLightUpdate = updateAt + 0.1
        local want = {}
        local L = {}
        local neon = State.worldNeon == true
        local strength = math.clamp(tonumber(State.worldNeonStrength) or 0.85, 0, 1)
        local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
        if neon then
            if not atmo then
                neonAtmo = Instance.new("Atmosphere")
                neonAtmo.Name = "bs_neon_atmosphere"
                neonAtmo.Parent = Lighting
                atmo = neonAtmo
            end
            local sky = State.colNeonSky
            local world = State.colNeonWorld
            L.Ambient = lightingBase("Ambient"):Lerp(world:Lerp(Color3.new(0, 0, 0), 0.62), strength)
            L.OutdoorAmbient = lightingBase("OutdoorAmbient"):Lerp(world, strength)
            L.ColorShift_Top = lightingBase("ColorShift_Top"):Lerp(world, strength)
            L.ColorShift_Bottom = lightingBase("ColorShift_Bottom"):Lerp(sky, strength)
            L.FogColor = lightingBase("FogColor"):Lerp(sky, strength)
            L.FogStart = lightingBase("FogStart") * (1 - strength) + 220 * strength
            L.FogEnd = lightingBase("FogEnd") * (1 - strength) + 1600 * strength
            L.Brightness = lightingBase("Brightness") * (1 - strength) + 2.3 * strength
            L.ClockTime = lightingBase("ClockTime") * (1 - strength) + 18.5 * strength
            if atmo then
                local prior = saved[atmo]
                local baseColor = prior and prior.Color and prior.Color.v or atmo.Color
                local baseDecay = prior and prior.Decay and prior.Decay.v or atmo.Decay
                want[atmo] = {
                    Color = baseColor:Lerp(sky, strength),
                    Decay = baseDecay:Lerp(sky:Lerp(world, 0.25), strength),
                    Density = 0.12 + 0.22 * strength,
                    Haze = 0.4 + 1.2 * strength,
                    Glare = 0.08,
                }
            end
            if not neonGrade or not neonGrade.Parent then
                if neonGrade then neonGrade:Destroy() end
                neonGrade = Instance.new("ColorCorrectionEffect")
                neonGrade.Name = "bs_neon_grade"
                neonGrade.Parent = Lighting
            end
            neonGrade.TintColor = Color3.new(1, 1, 1):Lerp(world, 0.2 * strength)
            neonGrade.Saturation = 0.35 * strength
            neonGrade.Contrast = 0.15 * strength
            neonGrade.Brightness = 0.015 * strength
        else
            if neonGrade then neonGrade:Destroy(); neonGrade = nil end
        end
        if State.worldFullbright then
            L.Brightness = 2
            L.GlobalShadows = false
            L.Ambient = Color3.fromRGB(180, 180, 180)
            L.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
        end
        if State.worldAmbient then
            L.Ambient = State.colAmbient
            L.OutdoorAmbient = State.colAmbient
        end
        if State.worldTime then
            L.ClockTime = tonumber(State.worldClock) or 14
        end
        if State.worldNoFog then
            L.FogStart = 1e6
            L.FogEnd = 1e6
            if atmo then
                want[atmo] = want[atmo] or {}
                want[atmo].Density = 0
                want[atmo].Haze = 0
            end
        end
        if next(L) then want[Lighting] = L end
        apply(want)
        if not neon and neonAtmo then
            neonAtmo:Destroy()
            neonAtmo = nil
        end
    end)

    -- Smoke grenades: Workspace.Debris.VoxelSmoke_* folders of SmokeVoxel
    -- parts (+ any emitters). Hidden locally; the parts stay in place.
    local hiddenSmoke = {}  -- [inst] = { prop, original }
    local function hideSmoke(inst)
        if hiddenSmoke[inst] then return end
        if inst:IsA("BasePart") then
            hiddenSmoke[inst] = { "LocalTransparencyModifier", inst.LocalTransparencyModifier }
            inst.LocalTransparencyModifier = 1
        elseif inst:IsA("ParticleEmitter") or inst:IsA("Smoke") or inst:IsA("Beam") then
            hiddenSmoke[inst] = { "Enabled", inst.Enabled }
            inst.Enabled = false
        end
    end
    local lastSmokeScan = 0
    local smokeConn = RunService.Heartbeat:Connect(function()
        local now = os.clock()
        if now - lastSmokeScan < 0.5 then return end
        lastSmokeScan = now
        if State.worldNoSmoke then
            local debris = Workspace:FindFirstChild("Debris")
            if debris then
                for _, f in ipairs(debris:GetChildren()) do
                    if f.Name:match("^VoxelSmoke_") then
                        for _, d in ipairs(f:GetDescendants()) do hideSmoke(d) end
                    end
                end
            end
        elseif next(hiddenSmoke) then
            for inst, rec in pairs(hiddenSmoke) do
                if inst.Parent then pcall(function() inst[rec[1]] = rec[2] end) end
            end
            table.clear(hiddenSmoke)
        end
    end)

    local okInv, InventoryController = pcall(require, ReplicatedStorage.Controllers.InventoryController)
    local tp: ThirdPersonState = { active = false, fp = nil, tp = nil }
    Shared.tpState = tp

    local shownChar, hiddenVM = {}, {}  -- [BasePart] = original LocalTransparencyModifier
    local shownModel, hiddenModel
    local nextCharScan, nextVMScan = 0, 0
    local function setCharacterShown(show)
        local char = LocalPlayer.Character
        if show and char then
            if shownModel ~= char then
                for p, orig in pairs(shownChar) do
                    if p.Parent then p.LocalTransparencyModifier = orig end
                end
                table.clear(shownChar)
                shownModel, nextCharScan = char, 0
            end
            local now = os.clock()
            if now >= nextCharScan then
                nextCharScan = now + 0.5
                for _, p in ipairs(char:GetDescendants()) do
                    if p:IsA("BasePart") and p.Name ~= "CameraPart" and p.Name ~= "HumanoidRootPart"
                        and shownChar[p] == nil then
                        shownChar[p] = p.LocalTransparencyModifier
                    end
                end
            end
            for p in pairs(shownChar) do
                if p.Parent then
                    local target = 0
                    if p.LocalTransparencyModifier ~= target then
                        p.LocalTransparencyModifier = target
                    end
                else
                    shownChar[p] = nil
                end
            end
        elseif not show then
            for p, orig in pairs(shownChar) do
                if p.Parent then p.LocalTransparencyModifier = orig end
            end
            table.clear(shownChar)
            shownModel = nil
        end
    end
    local function setViewmodelHidden(hide)
        local w = okInv and InventoryController and InventoryController.peekCurrentEquippedForMovement()
        local model = type(w) == "table" and w.Viewmodel and w.Viewmodel.Model
        if hide and typeof(model) == "Instance" then
            if hiddenModel ~= model then
                for p, orig in pairs(hiddenVM) do
                    if p.Parent then p.LocalTransparencyModifier = orig end
                end
                table.clear(hiddenVM)
                hiddenModel, nextVMScan = model, 0
            end
            local now = os.clock()
            if now >= nextVMScan then
                nextVMScan = now + 0.5
                for _, p in ipairs(model:GetDescendants()) do
                    if p:IsA("BasePart") and hiddenVM[p] == nil then
                        hiddenVM[p] = p.LocalTransparencyModifier
                    end
                end
            end
            for p in pairs(hiddenVM) do
                if p.Parent then
                    if p.LocalTransparencyModifier ~= 1 then p.LocalTransparencyModifier = 1 end
                else
                    hiddenVM[p] = nil
                end
            end
        elseif not hide or hiddenModel then
            for p, orig in pairs(hiddenVM) do
                if p.Parent then p.LocalTransparencyModifier = orig end
            end
            table.clear(hiddenVM)
            hiddenModel = nil
        end
    end

    local camParams = RaycastParams.new()
    camParams.FilterType = Enum.RaycastFilterType.Exclude
    local function thirdPersonCFrame(fp, cam)
        local desired = fp * CFrame.new(tonumber(State.tpSide) or 0, tonumber(State.tpHeight) or 0, tonumber(State.tpDistance) or 8)
        local ignore = { cam }
        if LocalPlayer.Character then ignore[#ignore + 1] = LocalPlayer.Character end
        local debris = Workspace:FindFirstChild("Debris")
        if debris then ignore[#ignore + 1] = debris end
        camParams.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(fp.Position, desired.Position - fp.Position, camParams)
        if hit then
            desired = CFrame.new(hit.Position + (fp.Position - hit.Position).Unit * 0.5) * fp.Rotation
        end
        return desired
    end

    local BIND_TP = "bs_thirdperson"
    RunService:BindToRenderStep(BIND_TP, Enum.RenderPriority.Camera.Value + 3, function()
        local alive = LocalPlayer:GetAttribute("IsSpectating") ~= true
            and LocalPlayer.Character ~= nil
            and LocalPlayer.Character:GetAttribute("Dead") ~= true
        local cam = Workspace.CurrentCamera
        if not (State.tpEnable and alive and cam) then
            if tp.active then
                tp.active, tp.fp, tp.tp = false, nil, nil
                setCharacterShown(false)
                setViewmodelHidden(false)
            end
            return
        end
        local fp = cam.CFrame  -- the game's first-person write from Camera+1
        local tpCF = thirdPersonCFrame(fp, cam)
        tp.fp, tp.tp, tp.active = fp, tpCF, true
        cam.CFrame = tpCF
        setCharacterShown(true)
        setViewmodelHidden(true)
    end)

    -- Restore first person before delayed weapon callbacks run; camera updates reject large jumps.
    local afterRender = RunService.PreSimulation or RunService.Stepped
    local fpRestoreConn = afterRender:Connect(function()
        if tp.active and tp.fp and tp.tp then
            local cam = Workspace.CurrentCamera
            if cam and (cam.CFrame.Position - tp.tp.Position).Magnitude < 0.01 then
                cam.CFrame = tp.fp
            end
        end
    end)
    -- Aim from the head toward the third-person crosshair hit to avoid near-wall parallax.
    local aimParams = RaycastParams.new()
    aimParams.FilterType = Enum.RaycastFilterType.Exclude
    Shared.tpAimFrom = function(fpCF)
        local cam = Workspace.CurrentCamera
        local tpCF = thirdPersonCFrame(fpCF, cam)
        local ignore = { cam }
        if LocalPlayer.Character then ignore[#ignore + 1] = LocalPlayer.Character end
        local debris = Workspace:FindFirstChild("Debris")
        if debris then ignore[#ignore + 1] = debris end
        aimParams.FilterDescendantsInstances = ignore
        local look = tpCF.LookVector
        local hit = Workspace:Raycast(tpCF.Position, look * 1000, aimParams)
        local point = hit and hit.Position or (tpCF.Position + look * 1000)
        -- Crosshair on something between the camera and your head: keep the
        -- plain first-person aim instead of shooting backwards.
        if (point - fpCF.Position):Dot(look) <= 0.5 then return fpCF end
        return CFrame.lookAt(fpCF.Position, point)
    end

    Shared.firstPersonNow = function()
        if tp.active and tp.fp and tp.tp then
            local cam = Workspace.CurrentCamera
            if cam and (cam.CFrame.Position - tp.tp.Position).Magnitude < 0.01 then
                cam.CFrame = tp.fp
            end
        end
    end

    _G.__bs_add_teardown(function()
        fpRestoreConn:Disconnect()
        lightConn:Disconnect()
        smokeConn:Disconnect()
        pcall(RunService.UnbindFromRenderStep, RunService, BIND_TP)
        tp.active = false
        setCharacterShown(false)
        setViewmodelHidden(false)
        apply({})
        if neonGrade then neonGrade:Destroy(); neonGrade = nil end
        if neonAtmo then neonAtmo:Destroy(); neonAtmo = nil end
        for inst, rec in pairs(hiddenSmoke) do
            if inst.Parent then pcall(function() inst[rec[1]] = rec[2] end) end
        end
    end)
    print("[bs] world loaded")
end

-- Shot hooks use the game's raycast path, which checks caller environments.
-- Weapon.Properties is guarded by the game; change instance state instead.
local function isSniperWeapon(w)
    local props = type(w) == "table" and w.Properties
    return type(props) == "table"
        and (props.AimingOptions == "SniperScope" or props.MuzzleType == "Sniper")
end
do
    State.rageEnable   = false
    State.rageSilent   = false
    State.rageAutoFire = false
    State.rageAutowall = false  -- shoot targets the game's own penetration reaches
    State.rageInfPen   = false  -- pretend the gun's Penetration is huge, so autowall walks past every wall
    State.rageNoSpread = false  -- zero the spread cone on every shot (works without "enable")
    State.rageNoRecoil = false  -- no camera kick or recoil climb, so shots stay on the crosshair
    State.rageRapidFire = false -- use rageRapidRate for the client shooting gate
    State.rageRapidRate = 19 -- leave room below ShootWeapon's 20 requests/second limit
    State.rageInfiniteAmmo = false -- reload when a magazine empties; keep client/server rounds in sync
    State.rageInfReserve = false -- replenish spare rounds at reload; magazine rounds still count down
    State.rageFastReload = false -- request a full magazine reload immediately
    State.rageBacktrack = false -- try a recent replicated enemy pose when the current pose cannot be hit
    State.rageBacktrackMs = 120
    State.rageResolver = false
    State.rageResolverMisses = 2
    State.rageRapidMult = 1.5   -- legacy config value
    State.moveBhop      = false -- auto-bhop: pulse Jump each frame while space is held
    State.moveStrafe    = false -- WASD velocity steering plus automatic air strafe
    State.moveAutoPeek  = false
    State.moveAutoPeekKey = Enum.KeyCode.LeftAlt
    State.moveAutoPeekSpeed = 105
    State.moveViewBhop  = false
    State.moveAirBoost  = false
    State.moveAirSpeed  = 90
    State.moveBhopSpeed = 140
    State.rageShotLog  = false  -- print one console line per bullet (debugging misses)
    -- Keybinds. Enum.KeyCode.Unknown means "no bind"; pressing an Unknown
    -- key does nothing, so this is the safe empty default.
    State.rageKeyEnable    = Enum.KeyCode.Unknown
    State.rageKeySilent    = Enum.KeyCode.Unknown
    State.rageKeyAutoFire  = Enum.KeyCode.Unknown
    State.rageKeyRapidFire = Enum.KeyCode.Unknown
    State.rageHitbox   = "head"   -- head | body | multipoint
    State.ragePriority = "angle"  -- angle | distance | health | threat
    State.rageFocusIds = ""       -- ordered UserIds; listed enemies win, then normal enemy targeting
    State.rageMpAuto   = false     -- multipoint scale follows distance
    State.rageMpScale  = 0.7      -- manual multipoint scale when auto is off
    State.rageMpAll    = false    -- also use scaled points in head/body modes
    State.rageFov      = 180      -- degrees from crosshair; 180 = anywhere
    State.rageMaxDist  = 1000

    local okRc, Raycast = pcall(require, ReplicatedStorage.Shared.Raycast)
    local okIg, GetRayIgnore = pcall(require, ReplicatedStorage.Components.Common.GetRayIgnore)
    local okInv, InventoryController = pcall(require, ReplicatedStorage.Controllers.InventoryController)
    local okCC, CameraController = pcall(require, ReplicatedStorage.Controllers.CameraController)
    if not (BulletClass and type(BulletClass._performRaycast) == "function" and okRc and okIg) then
        warn("[bs] ragebot: Bullet/Raycast modules missing, ragebot disabled")
    else
        local origPerform = BulletClass._performRaycast
        local HITBOXES = {
            head       = { "Head" },
            body       = { "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart" },
            multipoint = { "Head", "UpperTorso", "Torso", "LowerTorso" },
        }
        local RESOLVED_PARTS = { "UpperTorso", "Torso", "LowerTorso", "Head" }
        local resolverByPlayer = setmetatable({}, { __mode = "k" })
        local resolverCheckAt = 0
        local resolverConn = RunService.Heartbeat:Connect(function()
            if not (State.rageResolver and State.rageEnable) then
                table.clear(resolverByPlayer)
                return
            end
            local now = os.clock()
            if now < resolverCheckAt then return end
            resolverCheckAt = now + 0.1
            for plr, record in pairs(resolverByPlayer) do
                local pending = record.pending
                if pending then
                    if plr.Character ~= pending.char or not pending.char.Parent then
                        record.pending = nil
                    else
                        local health = tonumber(pending.char:GetAttribute("Health"))
                        if health and health < pending.health then
                            record.pending = nil
                            if pending.part == "Head" then
                                record.headMisses, record.bodyUntil = 0, 0
                            else
                                record.bodyUntil = math.max(record.bodyUntil or 0, now + 2)
                            end
                        elseif now - pending.at >= 0.9 then
                            record.pending = nil
                            if pending.part == "Head" then
                                record.headMisses = math.min((record.headMisses or 0) + 1, 4)
                                if record.headMisses >= math.clamp(tonumber(State.rageResolverMisses) or 2, 1, 4) then
                                    record.bodyUntil = now + 3
                                end
                            else
                                record.bodyUntil = 0
                                record.headMisses = 0
                            end
                        end
                    end
                end
            end
        end)
        local function resolverShot(plr, char, part)
            if not State.rageResolver or not plr or not char or not part then return end
            if part ~= "Head" and part ~= "UpperTorso"
                and part ~= "Torso" and part ~= "LowerTorso" then return end
            local health = tonumber(char:GetAttribute("Health"))
            if not health or health <= 0 then return end
            local record = resolverByPlayer[plr]
            if not record then
                record = { headMisses = 0, bodyUntil = 0 }
                resolverByPlayer[plr] = record
            end
            if not record.pending then
                record.pending = { at = os.clock(), char = char, part = part, health = health }
            end
        end
        _G.__bs_add_teardown(function()
            resolverConn:Disconnect()
            table.clear(resolverByPlayer)
        end)
        local function isRageEnemy(plr)
            if plr == LocalPlayer then return false end
            if workspace:GetAttribute("Gamemode") == "Deathmatch" then return true end
            local ma, pa = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
            -- No team = spectator / not in the round: never a target.
            if pa == nil then return false end
            if ma ~= nil then return ma ~= pa end
            return true
        end

        -- Alive = not flagged Dead, health above 0 if replicated, and (when
        -- the game's live-character table is readable) actually in it.
        local function isLiveTarget(plr, char)
            if char:GetAttribute("Dead") == true then return false end
            -- The server rejects damage while Invincible is set.
            if char:GetAttribute("Invincible") == true then return false end
            local hp = char:GetAttribute("Health")
            if type(hp) == "number" and hp <= 0 then return false end
            if Shared.presentEntry then
                local entries, e = Shared.presentEntry(plr)
                if entries and (not e or e.Visible == false or e.Shell ~= char) then return false end
            end
            return true
        end

        local function localAlive()
            if LocalPlayer:GetAttribute("IsSpectating") == true then return false end
            local c = LocalPlayer.Character
            return c ~= nil and c.Parent ~= nil and c:GetAttribute("Dead") ~= true
        end

        -- Keep a short ring of positions that the game actually presented.
        -- Historical shots are only attempted when no current hit exists.
        local poseHistory = setmetatable({}, { __mode = "k" })
        local captureAt = 0
        local captureConn = RunService.Heartbeat:Connect(function()
            if not (State.rageBacktrack and State.rageEnable) then
                table.clear(poseHistory)
                return
            end
            local now = os.clock()
            if now - captureAt < 1 / 30 then return end
            captureAt = now
            for _, plr in ipairs(Players:GetPlayers()) do
                local char = plr.Character
                if char and char.Parent and isRageEnemy(plr) and isLiveTarget(plr, char)
                    and not (Shared.hiddenByGame and Shared.hiddenByGame(plr)) then
                    local head = char:FindFirstChild("Head")
                    if head and (not Shared.staleSeconds or Shared.staleSeconds(plr, head, now) == 0) then
                        local points = {}
                        for _, name in ipairs({ "Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart" }) do
                            local part = char:FindFirstChild(name)
                            if part and part:IsA("BasePart") then
                                points[name] = { part = part, position = part.Position }
                            end
                        end
                        local entries = poseHistory[plr]
                        if not entries then entries = {}; poseHistory[plr] = entries end
                        entries[#entries + 1] = { at = now, char = char, points = points }
                        while #entries > 8 or (#entries > 0 and now - entries[1].at > 0.24) do
                            table.remove(entries, 1)
                        end
                    end
                end
            end
        end)
        _G.__bs_add_teardown(function() captureConn:Disconnect(); table.clear(poseHistory) end)

        -- Target checks use plain raycasts; shot hooks use the game's guarded raycast.
        local plainParams = RaycastParams.new()
        plainParams.FilterType = Enum.RaycastFilterType.Exclude
        pcall(function() plainParams.CollisionGroup = "Bullet" end)
        -- Match the game's ignored parts so target checks agree with real shots.
        local function castSkips(inst)
            if inst.Name == "CollisionCapsule" then return true end
            if inst:FindFirstAncestorWhichIsA("Accessory") then return true end
            if inst:HasTag("CharacterAccessory") then return true end
            local viz = inst:FindFirstAncestor("RaycastVisualizers")
            return viz ~= nil
        end
        local function plainCast(origin, dir, _, ignore)
            local list = table.clone(ignore)
            for _ = 1, 16 do
                plainParams.FilterDescendantsInstances = list
                local r = Workspace:Raycast(origin, dir, plainParams)
                if not r then return {} end
                if not castSkips(r.Instance) then
                    return { instance = r.Instance, position = r.Position }
                end
                list[#list + 1] = r.Instance
            end
            return {}
        end

        -- Track cumulative material depth using the game's penetration allowances.
        local VARIANT_PEN = { ["Sandy Brick"] = 0, IndoorWall = 0 }
        local MATERIAL_PEN = {
            [Enum.Material.Plastic] = 10, [Enum.Material.SmoothPlastic] = 10,
            [Enum.Material.Wood] = 10, [Enum.Material.WoodPlanks] = 10,
            [Enum.Material.Cardboard] = 10, [Enum.Material.Glass] = 25,
            [Enum.Material.Fabric] = 25,
        }  -- every other material: 0
        local MAP_MIN_PEN = { Reactor = -1 }
        local function mapMinPen(v)
            if v ~= 0 then return v end
            local m = Workspace:GetAttribute("Map")
            return type(m) == "string" and MAP_MIN_PEN[m] or v
        end
        local function penMaterial(inst)
            local p = inst.Parent
            if p and p:HasTag("BreakableDoor") then return Enum.Material.Metal end
            return inst.Material
        end
        local function plainThrough(start, dir, pen, ignore, target)
            local unit = dir.Unit
            local params = RaycastParams.new()
            params.FilterDescendantsInstances = ignore
            pcall(function() params.CollisionGroup = "Bullet" end)
            local inc = RaycastParams.new()
            inc.FilterType = Enum.RaycastFilterType.Include
            pcall(function() inc.CollisionGroup = "Bullet" end)
            local hits, byMat, byVariant = {}, {}, {}
            -- This tracer is for target selection only. Stop as soon as the
            -- chosen character is reached; the shot uses the game tracer.
            for _ = 1, 24 do
                local r = Workspace:Raycast(start, unit * 1000, params)
                if not r then break end
                params:AddToFilter(r.Instance)
                hits[#hits + 1] = { instance = r.Instance, position = r.Position }
                if target and r.Instance:IsDescendantOf(target) then break end
                inc.FilterDescendantsInstances = { r.Instance }
                local far = r.Position + unit * 1000
                local back = Workspace:Raycast(far, r.Position - far, inc)
                if not back then break end
                local depth = (r.Position - back.Position).Magnitude
                local variant = back.Instance.MaterialVariant
                if variant ~= "" and VARIANT_PEN[variant] ~= nil then
                    byVariant[variant] = (byVariant[variant] or 0) + depth
                    if byVariant[variant] > mapMinPen(VARIANT_PEN[variant]) + pen then break end
                else
                    local m = penMaterial(back.Instance)
                    byMat[m] = (byMat[m] or 0) + depth
                    if byMat[m] > mapMinPen(MATERIAL_PEN[m] or 0) + pen then break end
                end
                hits[#hits + 1] = { instance = back.Instance, position = back.Position }
                start = back.Position
            end
            return hits
        end

        local gameTracer  = { cast = Raycast.cast, through = Raycast.castThrough }
        local plainTracer = { cast = plainCast,    through = plainThrough }

        -- Direct and wall-pass checks share the same hit tuple.
        local function traceTo(origin, aimPos, char, range, ignore, tracer, pen, wallPass, expectedPart)
            local delta = aimPos - origin
            local dist = delta.Magnitude
            if dist < 0.01 or dist > range then return nil end
            local look = delta / dist
            local hit = tracer.cast(origin, look * range, nil, ignore)
            if not hit.instance then return nil end
            local direct = hit.instance:IsDescendantOf(char)
            if not wallPass then
                if direct and (not expectedPart or hit.instance == expectedPart) then return hit, look, nil end
                return nil
            end
            if direct then return nil end
            local through = tracer.through(hit.position + look * -0.001, look * (pen + 0.001), pen, ignore, char)
            for _, h in ipairs(through) do
                if h.instance and h.instance:IsDescendantOf(char) then
                    if not expectedPart or h.instance == expectedPart then return h, look, through end
                    return nil
                end
            end
            return nil
        end

        -- Shrink edge aim points with distance to reduce misses from movement and latency.
        local function multipointScale(dist)
            if State.rageMpAuto then
                return math.clamp(0.9 - dist / 250, 0.45, 0.9)
            end
            return math.clamp(tonumber(State.rageMpScale) or 0.7, 0.05, 1)
        end
        local MP_DIRS = {
            Vector3.new(0, 1, 0), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
            Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), Vector3.new(0, -1, 0),
        }
        local function aimPoints(part, origin, multipoint)
            local pts = { part.Position }
            if not multipoint then return pts end
            local s = multipointScale((part.Position - origin).Magnitude)
            local half = part.Size * 0.5 * s
            for _, d in ipairs(MP_DIRS) do
                pts[#pts + 1] = part.CFrame:PointToWorldSpace(d * half)
            end
            return pts
        end

        -- Try direct points before wall penetration; lower scores rank first.
        local function scoreTarget(plr, char, centre, camLook, origin, angle, dist)
            local mode = State.ragePriority or "angle"
            if mode == "distance" then return dist end
            if mode == "health" then
                local hp = tonumber(char:GetAttribute("Health")) or 100
                return hp
            end
            if mode == "threat" then
                local hp = tonumber(char:GetAttribute("Health")) or 100
                return dist / math.max(1, hp)
            end
            return angle  -- default: closest to crosshair
        end

        local backParams = RaycastParams.new()
        backParams.FilterType = Enum.RaycastFilterType.Exclude
        pcall(function() backParams.CollisionGroup = "Bullet" end)
        local function historicalLaneClear(origin, point, char, ignore)
            local exclusions = {}
            for _, inst in ipairs(ignore or {}) do exclusions[#exclusions + 1] = inst end
            exclusions[#exclusions + 1] = char
            backParams.FilterDescendantsInstances = exclusions
            local delta = point - origin
            return delta.Magnitude > 0.05
                and Workspace:Raycast(origin, delta * 0.99, backParams) == nil
        end

        local function pickTarget(origin, camLook, range, ignore, tracer, pen, fovOverride)
            local fov = fovOverride or State.rageFov
            local fovCos = math.cos(math.rad(fov))
            local mode = State.rageHitbox
            local parts = HITBOXES[mode] or HITBOXES.head
            local multipoint = mode == "multipoint" or State.rageMpAll == true
            local maxDist = math.min(range, tonumber(State.rageMaxDist) or range)
            local bestHit, bestLook, bestThrough, bestScore = nil, nil, nil, math.huge
            local bestRank = math.huge
            local focusIds = focusTargetIds()
            local focusRanks = {}
            for rank, id in ipairs(focusIds) do focusRanks[id] = rank end
            local fallbackRank = #focusIds + 1
            local now = os.clock()
            local candidates = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                local char = plr.Character
                local rank = focusRanks[plr.UserId] or fallbackRank
                if rank ~= nil and char and char.Parent and isRageEnemy(plr) and isLiveTarget(plr, char) then
                    local head = char:FindFirstChild("Head")
                    -- A frozen shell isn't where the server has them; shots there are wasted.
                    local stale = head and Shared.staleSeconds and Shared.staleSeconds(plr, head, now) or 0
                    local centre = head or char:FindFirstChildWhichIsA("BasePart")
                    if stale == 0 and centre then
                        local d = centre.Position - origin
                        local mag = d.Magnitude
                        local angle = mag > 0.01 and math.deg(math.acos(math.clamp(camLook:Dot(d / mag), -1, 1))) or 0
                        local score = scoreTarget(plr, char, centre, camLook, origin, angle, mag)
                        if angle <= fov and mag <= maxDist then
                            candidates[#candidates + 1] = {
                                player = plr, char = char, rank = rank, score = score,
                            }
                        end
                    end
                end
            end
            table.sort(candidates, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                if a.score ~= b.score then return a.score < b.score end
                return a.player.UserId < b.player.UserId
            end)
            for _, candidate in ipairs(candidates) do
                local char = candidate.char
                local found
                local orderedParts = parts
                local resolved = resolverByPlayer[candidate.player]
                if State.rageResolver and (mode == "head" or mode == "multipoint")
                    and resolved and now < (resolved.bodyUntil or 0) then
                    orderedParts = RESOLVED_PARTS
                end
                for pass = 1, ((State.rageAutowall or State.rageInfPen) and 2 or 1) do
                    local wallPass = pass == 2
                    for _, name in ipairs(orderedParts) do
                        local part = char:FindFirstChild(name)
                        if part and part:IsA("BasePart") then
                            for _, pt in ipairs(aimPoints(part, origin, multipoint)) do
                                local delta = pt - origin
                                local pointInFov = delta.Magnitude > 0.01
                                    and math.clamp(camLook:Dot(delta / delta.Magnitude), -1, 1) >= fovCos
                                local hit, look, through
                                if pointInFov then
                                    hit, look, through = traceTo(origin, pt, char, maxDist, ignore, tracer, pen, wallPass, part)
                                end
                                if hit then found = { hit, look, through }; break end
                            end
                        end
                        if found then break end
                    end
                    if found then break end
                end
                if found then
                    return found[1], found[2], found[3]
                end
            end
            if not bestHit and State.rageBacktrack then
                local window = math.clamp(tonumber(State.rageBacktrackMs) or 120, 50, 200) / 1000
                for _, plr in ipairs(Players:GetPlayers()) do
                    local char = plr.Character
                    local rank = focusRanks[plr.UserId] or fallbackRank
                    local entries = poseHistory[plr]
                    if rank ~= nil and entries and char and char.Parent
                        and isRageEnemy(plr) and isLiveTarget(plr, char) then
                        for index = #entries, 1, -1 do
                            local record = entries[index]
                            local age = now - record.at
                            if record.char == char and age >= 0.03 and age <= window then
                                local orderedParts = parts
                                local resolved = resolverByPlayer[plr]
                                if State.rageResolver and (mode == "head" or mode == "multipoint")
                                    and resolved and now < (resolved.bodyUntil or 0) then
                                    orderedParts = RESOLVED_PARTS
                                end
                                for _, name in ipairs(orderedParts) do
                                    local point = record.points[name]
                                    if point and point.part.Parent and point.part:IsDescendantOf(char) then
                                        local delta = point.position - origin
                                        local dist = delta.Magnitude
                                        if dist > 0.05 and dist <= maxDist then
                                            local look = delta / dist
                                            local angle = math.deg(math.acos(math.clamp(camLook:Dot(look), -1, 1)))
                                            local score = scoreTarget(plr, char, point.part, camLook, origin, angle, dist)
                                            if angle <= fov and (rank < bestRank or rank == bestRank and score < bestScore)
                                                and historicalLaneClear(origin, point.position, char, ignore) then
                                                local hit = {
                                                    instance = point.part, position = point.position,
                                                    material = point.part.Material, normal = -look,
                                                    backtracked = true,
                                                }
                                                bestHit, bestLook = hit, look
                                                bestThrough = { hit }
                                                bestScore, bestRank = score, rank
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return bestHit, bestLook, bestThrough
        end

        local INF_PEN = 1000
        -- Keep target checks and shot raycasts on the same penetration value.
        local function effectivePen(base)
            if State.rageInfPen then return INF_PEN end
            return tonumber(base) or 0
        end
        local function equippedPenetration()
            local w = okInv and InventoryController and InventoryController.peekCurrentEquippedForMovement()
            local props = type(w) == "table" and w.Properties
            return effectivePen(type(props) == "table" and props.Penetration or 0)
        end
        local function equippedRange()
            local w = okInv and InventoryController and InventoryController.peekCurrentEquippedForMovement()
            local props = type(w) == "table" and w.Properties
            return type(props) == "table" and tonumber(props.Range) or 500
        end
        local function targetView()
            local cam = Workspace.CurrentCamera
            if not cam then return nil end
            local tp = Shared.tpState
            if tp and tp.active and tp.fp then
                local fp = Shared.tpAimFrom and Shared.tpAimFrom(tp.fp) or tp.fp
                return fp.Position, fp.LookVector
            end
            local vp = cam.ViewportSize * 0.5
            local ray = cam:ViewportPointToRay(vp.X, vp.Y)
            return ray.Origin, ray.Direction.Unit
        end
        Shared.rageVisualTarget = function()
            if not State.rageEnable or not localAlive() then return nil end
            local origin, look = targetView()
            if not origin then return nil end
            local pen = equippedPenetration()
            local hit = pickTarget(origin, look, equippedRange(), GetRayIgnore(), plainTracer, pen)
            return hit and hit.position, hit and hit.instance
        end
        Shared.rageHasTarget = function()
            local origin, look = targetView()
            if not origin then return false end
            local pen = equippedPenetration()
            return pickTarget(origin, look, equippedRange(), GetRayIgnore(), plainTracer, pen) ~= nil
        end

        -- Mirrors Bullet._performRaycast (dump line 191) with the spread cone
        -- replaced by the exact direction to the target (so: no spread).
        local function silentRaycast(bullet)
            local cam = Workspace.CurrentCamera
            local vp = cam.ViewportSize * 0.5
            local ray = cam:ViewportPointToRay(vp.X, vp.Y)
            local origin = ray.Origin
            local ignore = GetRayIgnore()
            local pen = effectivePen(bullet.Properties.Penetration or 0)
            local range = bullet.Properties.Range or 500
            local hit, look, through = pickTarget(origin, ray.Direction.Unit, range, ignore, gameTracer, pen)
            if not hit then return nil end
            local result = {
                Distance = (hit.position - origin).Magnitude,
                Origin = origin,
                Direction = look,
                Hits = {},
                Backtracked = hit.backtracked == true,
            }
            -- Infinite penetration sends the selected character's real entry hit.
            -- Reusing a through-chain index here could mark that entry as an exit
            -- after wall entries were removed, and could include another player.
            if State.rageInfPen then
                if not hit.instance or not hit.material then return nil end
                result.Hits[1] = {
                    Position = hit.position,
                    Instance = hit.instance,
                    Material = hit.material.Name,
                    Normal = hit.normal or -look,
                    Exit = false,
                }
                return result
            end
            -- Same call the game makes; reuse it if autowall already ran it.
            through = through or Raycast.castThrough(hit.position + look * -0.001, look * (pen + 0.001), pen, ignore)
            for i = 1, #through do
                local h = through[i]
                if h.instance and h.material then
                    result.Hits[#result.Hits + 1] = {
                        Position = h.position,
                        Instance = h.instance,
                        Material = h.material.Name,
                        Normal = h.normal or Vector3.new(0, 0, 0),
                        Exit = i % 2 == 0,
                    }
                end
            end
            return result
        end

        BulletClass._performRaycast = function(self, spread)
            -- Shots use the first-person origin even while third person is visible.
            local cam = Workspace.CurrentCamera
            local tp = Shared.tpState
            local restore = cam and cam.CFrame
            local speedRestore = self.CharacterSpeed
            local result
            local silent = false
            local ok, shotErr = pcall(function()
                if tp and tp.active and tp.fp then
                    local holdsTP = tp.tp and (cam.CFrame.Position - tp.tp.Position).Magnitude < 0.01
                    local fpCF = holdsTP and tp.fp or cam.CFrame
                    cam.CFrame = Shared.tpAimFrom and Shared.tpAimFrom(fpCF) or fpCF
                end
                if State.rageEnable and State.rageSilent and localAlive() then
                    result = silentRaycast(self)
                    silent = result ~= nil
                end
            -- Zero spread still follows camera kick; remove kick and recoil for this raycast.
                if State.rageNoSpread and not silent then
                    local CC = okCC and CameraController
                    local kick = CC and CC.getWeaponKickRotation and CC.getWeaponKickRotation() or Vector3.zero
                    local rec  = CC and CC.getWeaponRecoil       and CC.getWeaponRecoil()       or Vector3.zero
                    local total = kick + rec
                    if total.Magnitude > 1e-5 then
                        cam.CFrame = cam.CFrame * CFrame.Angles(-total.X, -total.Y, -total.Z)
                    end
                    if type(self.Spread) == "table" and type(self.Spread.setPosition) == "function" then
                        pcall(self.Spread.setPosition, self.Spread, 0)
                    end
                    if speedRestore ~= nil then self.CharacterSpeed = 0 end
                end
                if not result then
                    result = origPerform(self, State.rageNoSpread and 0 or spread)
                end
                -- Align the next valid movement command with the bullet path.
                -- The fire remote and movement channel have separate timing.
                if result and Shared.armLookOverride
                    and (silent or State.antiAimEnable) then
                    Shared.armLookOverride(result.Direction)
                end
            end)
            if speedRestore ~= nil then self.CharacterSpeed = speedRestore end
            if restore and cam then cam.CFrame = restore end
            if not ok then error(shotErr, 0) end
            if result and Shared.autoPeekShot then pcall(Shared.autoPeekShot) end
            -- pcall: a logging error must never break the shot (the casts are
            -- already done, so this sits outside the stack-walk window).
            pcall(function()
                -- Hitlogs reflect the client raycast; the server may reject a shot.
                local hitPlr, hitPart, wall, hitPos, hitPlayer, hitChar
                for i, h in ipairs(result and result.Hits or {}) do
                    local m = h.Instance and h.Instance:FindFirstAncestorOfClass("Model")
                    while m and not Players:GetPlayerFromCharacter(m) do
                        m = m:FindFirstAncestorOfClass("Model")
                    end
                    if m then
                        hitPlr, hitPart, wall, hitPos = m.Name, h.Instance.Name, i > 1, h.Position
                        hitPlayer, hitChar = Players:GetPlayerFromCharacter(m), m
                        break
                    end
                end
                if silent and hitPlayer then resolverShot(hitPlayer, hitChar, hitPart) end
                if hitPlr and Shared.pushHit then
                    Shared.pushHit(hitPlr,
                        (wall and (hitPart .. " (wallbang)") or hitPart)
                            .. (result.Backtracked and " (BT)" or ""),
                        result and result.Distance or 0, silent, hitPos, wall)
                end
                if result and Shared.pushTracer then
                    Shared.pushTracer(result.Origin, result.Direction, result.Distance,
                        #(result.Hits or {}) > 0)
                end
                if State.rageShotLog then
                    local tpOn = tp and tp.active and "on" or "off"
                    print(("[bs shot] %s  hit=%s%s%s  spread=%s  hits=%d  dist=%.0f  thirdperson=%s"):format(
                        silent and "SILENT" or "normal",
                        hitPlr and (hitPlr .. "." .. hitPart) or "nothing",
                        wall and " (wallbang)" or "",
                        result and result.Backtracked and " (BT)" or "",
                        State.rageNoSpread and "0" or ("%.2f"):format(tonumber(spread) or 0),
                        result and #result.Hits or 0, result and result.Distance or 0, tpOn))
                end
            end)
            return result
        end
        _G.__bs_add_teardown(function() BulletClass._performRaycast = origPerform end)

        -- Shot angles are applied to sampled commands without moving the camera.
        -- Recoil hooks leave CameraController.updateCamera untouched.
        if okCC and type(CameraController) == "table"
            and type(CameraController.weaponKick) == "function"
            and type(CameraController.setWeaponRecoil) == "function" then
            local origKick, origSetRecoil = CameraController.weaponKick, CameraController.setWeaponRecoil
            -- Silent shots suppress both kick and recoil climb.
            local function suppress()
                if State.rageNoRecoil then return true end
                if State.rageEnable and State.rageSilent then return true end
                return false
            end
            CameraController.weaponKick = function(rot, pos)
                if Shared.firstPersonNow then Shared.firstPersonNow() end
                if suppress() then return end  -- no kick, and no updateCamera call
                return origKick(rot, pos)
            end
            CameraController.setWeaponRecoil = function(profile, mult)
                if suppress() and type(profile) == "table" then
                    profile = { Damper = profile.Damper, Speed = profile.Speed, Value = Vector3.new(0, 0, 0) }
                end
                return origSetRecoil(profile, mult)
            end
            -- toWeaponFirePosition can still snap the camera when recoil springs are zero.
            if type(CameraController.toWeaponFirePosition) == "function" then
                local origToFire = CameraController.toWeaponFirePosition
                CameraController.toWeaponFirePosition = function(...)
                    if suppress() then return end
                    return origToFire(...)
                end
                _G.__bs_add_teardown(function()
                    CameraController.toWeaponFirePosition = origToFire
                end)
            end
            _G.__bs_add_teardown(function()
                CameraController.weaponKick = origKick
                CameraController.setWeaponRecoil = origSetRecoil
            end)
        else
            warn("[bs] CameraController not found: no recoil unavailable")
        end

        -- AUTO FIRE: invoke the equipped weapon without synthetic mouse input.
        local function equippedWeapon()
            if not okInv or not InventoryController then return nil end
            local w = InventoryController.peekCurrentEquippedForMovement()
            return type(w) == "table" and w or nil
        end
        local function rapidGap()
            local rate = math.clamp(math.floor(tonumber(State.rageRapidRate) or 19), 1, 19)
            return 1 / rate
        end
        local lastRapidRelease = setmetatable({}, { __mode = "k" })
        Shared.releaseRapidGate = function(w, now)
            if not (State.rageRapidFire and w and w.Player == LocalPlayer)
                or w.IsReloading or now - (lastRapidRelease[w] or -math.huge) < rapidGap()
                or now - (Shared.rapidShotAt or -math.huge) < rapidGap() then return end
            if w.ShootDelayThread then
                pcall(task.cancel, w.ShootDelayThread)
                w.ShootDelayThread = nil
            end
            w.IsShooting = false
            w.NextShotDue = 0
            lastRapidRelease[w] = now
        end
        local function gap(w)
            local props = w and w.Properties
            local modes = props and props.FireModes
            local primary = type(modes) == "table" and modes.Primary
            local interval = tonumber(primary and primary.FireRate)
                or tonumber(props and props.FireRate) or 0.1
            if State.rageRapidFire then return rapidGap() end
            return math.max(1 / 18, interval + 0.015)
        end
        local lastFireByWeapon = setmetatable({}, { __mode = "k" })
        local retryAtByWeapon = setmetatable({}, { __mode = "k" })
        local lastFireErrorLog = -math.huge
        local lastBlockedShotLog = -math.huge
        local lastReloadAttempt = 0
        local getIdentity = type(getthreadidentity) == "function" and getthreadidentity
            or (type(getidentity) == "function" and getidentity or nil)
        local setIdentity = type(setthreadidentity) == "function" and setthreadidentity
            or (type(setidentity) == "function" and setidentity or nil)
        local directFireUnavailable = false
        local gameFocused = true
        local focusLostConn = UserInputService.WindowFocusReleased:Connect(function()
            gameFocused = false
        end)
        local focusGainedConn = UserInputService.WindowFocused:Connect(function()
            gameFocused = true
        end)
        local function fireWeapon(w)
            if type(w.shoot) ~= "function" then return false, "weapon has no shoot method" end
            local oldIdentity
            if getIdentity and setIdentity then
                local got, identity = pcall(getIdentity)
                if got and type(identity) == "number" and identity ~= 2
                    and pcall(setIdentity, 2) then
                    oldIdentity = identity
                end
            end
            local ok, result = pcall(w.shoot, w, "Primary")
            if oldIdentity then pcall(setIdentity, oldIdentity) end
            return ok, result
        end
        local function gunReady(w)
            return w and w.Bullet ~= nil and w.IsReloading ~= true
                and w.IsShooting ~= true
                and (tonumber(w.Rounds) or 1) > 0
        end
        local function reloadEmptyWeapon(w, now)
            if not w or tonumber(w.Rounds) ~= 0 or w.IsReloading then return end
            local canRefillReserve = State.rageInfReserve and type(w.Properties) == "table"
                and (tonumber(w.Properties.Capacity) or 0) > 0
            if (tonumber(w.Capacity) or 0) <= 0 and not canRefillReserve
                and Workspace:GetAttribute("Gamemode") ~= "Deathmatch" then return end
            -- The reload wrapper clears a leftover shooting gate for manual R
            -- and auto-fire alike, including a canceled delayed shot thread.
            if type(w.reload) ~= "function" then return end
            if now - lastReloadAttempt < 0.25 then return end
            lastReloadAttempt = now
            task.spawn(function() pcall(w.reload, w) end)
        end
        -- Only repair a gate that missed its scheduled reset. Clearing it
        -- before NextShotDue is what let rapid fire outrun server cadence.
        local function recoverStaleGate(w, now)
            if not w or not w.IsShooting then return end
            local due = tonumber(w.NextShotDue)
            if not due or now < due + 0.05 then return end
            if w.ShootDelayThread then
                pcall(task.cancel, w.ShootDelayThread)
                w.ShootDelayThread = nil
            end
            w.IsShooting = false
            w.NextShotDue = nil
        end
        -- Keep sniper scope fields set through the weapon call.
        local function forceScoped(w)
            if not w or not w.Properties then return function() end end
            if w.Properties.AimingOptions ~= "SniperScope" then return function() end end
            local wasAiming = w.IsAiming
            local wasScoped = w.IsSniperScoped
            local wasAttr = LocalPlayer:GetAttribute("IsSniperScoped")
            w.IsAiming = true
            w.IsSniperScoped = true
            pcall(LocalPlayer.SetAttribute, LocalPlayer, "IsSniperScoped", true)
            return function()
                w.IsAiming = wasAiming
                w.IsSniperScoped = wasScoped
                pcall(LocalPlayer.SetAttribute, LocalPlayer, "IsSniperScoped", wasAttr)
            end
        end
        local fireConn = RunService.Heartbeat:Connect(function()
            local now = os.clock()
            if State.rageRapidFire and not State.rageAutoFire then
                Shared.releaseRapidGate(equippedWeapon(), now)
            end
            if not (State.rageEnable and State.rageAutoFire) then return end
            if directFireUnavailable then return end
            if gameFocused and (State._menuOpen or UserInputService:GetFocusedTextBox()) then return end
            local w = equippedWeapon()
            recoverStaleGate(w, now)
            if w and tonumber(w.Rounds) == 0 then
                reloadEmptyWeapon(w, now)
            end
            if w and (now < (retryAtByWeapon[w] or 0)
                or now - (lastFireByWeapon[w] or -math.huge) < gap(w)) then
                if Shared.pushDrop then Shared.pushDrop("rate") end
                return
            end
            if State.rageRapidFire and Shared.releaseRapidGate then
                Shared.releaseRapidGate(w, now)
            end
            if not localAlive() then
                if Shared.pushDrop then Shared.pushDrop("dead") end
                return
            end
            if not gunReady(w) then
                if Shared.pushDrop then Shared.pushDrop("gun") end
                return
            end
            if not Shared.rageHasTarget() then
                if Shared.pushDrop then Shared.pushDrop("no target") end
                return
            end
            if w then
                local restoreScope = forceScoped(w)
                local seqBefore = w.ShotSeq
                local fired, fireErr = fireWeapon(w)
                restoreScope()
                if fired and (seqBefore == nil or w.ShotSeq ~= seqBefore) then
                    lastFireByWeapon[w] = now
                    retryAtByWeapon[w] = nil
                else
                    retryAtByWeapon[w] = now + math.min(0.03, gap(w))
                end
                if not fired and now - lastFireErrorLog > 2 then
                    lastFireErrorLog = now
                    warn("[bs] direct auto fire failed: " .. tostring(fireErr))
                end
                if not fired and tostring(fireErr):find("Cannot require a non-RobloxScript module", 1, true) then
                    directFireUnavailable = true
                end
                if fired then
                    if seqBefore ~= nil then
                        task.delay(0.15, function()
                            if w.ShotSeq ~= seqBefore then
                                lastFireByWeapon[w] = math.max(lastFireByWeapon[w] or -math.huge, now)
                            elseif os.clock() - lastBlockedShotLog > 2 then
                                lastBlockedShotLog = os.clock()
                                warn(("[bs] direct fire made no shot (rounds=%s, reload=%s, shooting=%s, pen=%s, rapid=%s)"):format(
                                    tostring(w.Rounds), tostring(w.IsReloading), tostring(w.IsShooting),
                                    tostring(State.rageInfPen), tostring(State.rageRapidFire)))
                            end
                        end)
                    end
                end
            end
        end)
        _G.__bs_add_teardown(function()
            fireConn:Disconnect()
            focusLostConn:Disconnect()
            focusGainedConn:Disconnect()
            Shared.releaseRapidGate = nil
        end)
        print("[bs] ragebot loaded (direct weapon auto fire)")
    end
end

-- Clear a stale shooting gate before reload; the game's reload method otherwise exits.
do
    local module = ReplicatedStorage:FindFirstChild("Components")
    module = module and module:FindFirstChild("Weapon")
    local ok, WeaponClass = false, nil
    if module then ok, WeaponClass = pcall(require, module) end
    if ok and type(WeaponClass) == "table"
        and type(WeaponClass.reload) == "function"
        and type(WeaponClass.shoot) == "function" then
        local originalReload, originalShoot = WeaponClass.reload, WeaponClass.shoot
        local unloaded = false
        local database = ReplicatedStorage:FindFirstChild("Database")
        local security = database and database:FindFirstChild("Security")
        local remotesModule = security and security:FindFirstChild("Remotes")
        local remotesOk, Remotes = false, nil
        if remotesModule then remotesOk, Remotes = pcall(require, remotesModule) end
        local common = ReplicatedStorage.Components:FindFirstChild("Common")
        local actionModule = common and common:FindFirstChild("ReplicateCharacterAction")
        local actionOk, ReplicateCharacterAction = false, nil
        if actionModule then actionOk, ReplicateCharacterAction = pcall(require, actionModule) end
        local function ownWeapon(w)
            return type(w) == "table" and w.Player == LocalPlayer
        end
        local function replenishReserve(w)
            if not (ownWeapon(w) and State.rageInfReserve) then return end
            local props = w.Properties
            local maxReserve = type(props) == "table" and tonumber(props.Capacity)
            local current = tonumber(w.Capacity)
            if maxReserve and maxReserve > 0 and current and current < maxReserve then
                w.Capacity = maxReserve
            end
        end
        local function instantMagazineReload(w)
            if not (ownWeapon(w) and State.rageFastReload and remotesOk) then return false end
            local props = w.Properties
            local send = Remotes and Remotes.Inventory and Remotes.Inventory.ReloadWeapon
                and Remotes.Inventory.ReloadWeapon.Send
            if type(props) ~= "table" or type(send) ~= "function"
                or tonumber(props.ReloadAnimationCount) ~= 1
                or w.IsReloading or w.IsDestroyed or w.IsAdjustingSuppressor
                or props.RechargeTime then return false end
            if w.WeaponEquippedTick and tick() - w.WeaponEquippedTick <= 1 then return false end
            local magazine = tonumber(props.Rounds)
            local rounds = tonumber(w.Rounds)
            local capacity = tonumber(w.Capacity) or 0
            local deathmatch = Workspace:GetAttribute("Gamemode") == "Deathmatch"
            if not magazine or not rounds or magazine <= rounds
                or (capacity <= 0 and not deathmatch) then return false end
            local load = deathmatch and magazine - rounds
                or math.min(magazine - rounds, capacity)
            if load <= 0 then return false end
            -- Use the same request and pre-reload counts as the game's MagIn
            -- marker, then update the local weapon once the send succeeds.
            if actionOk and type(ReplicateCharacterAction) == "function" then
                pcall(ReplicateCharacterAction, "Reload")
            end
            local sent, sendErr = pcall(send, {
                Identifier = w.Identifier, Rounds = rounds, Capacity = capacity,
            })
            if not sent then
                warn("[bs] instant reload request failed: " .. tostring(sendErr))
                return false
            end
            w.Rounds = rounds + load
            if deathmatch then
                w.Capacity = tonumber(props.Capacity) or capacity
            else
                w.Capacity = capacity - load
            end
            w.IsReloading = false
            w.CurrentReloadIdentity = nil
            return true
        end
        WeaponClass.reload = function(self, ...)
            if ownWeapon(self) and not self.IsReloading and self.IsShooting then
                if self.ShootDelayThread then
                    pcall(task.cancel, self.ShootDelayThread)
                    self.ShootDelayThread = nil
                end
                self.IsShooting = false
                self.NextShotDue = nil
            end
            replenishReserve(self)
            if instantMagazineReload(self) then return true end
            local result = table.pack(pcall(originalReload, self, ...))
            if not result[1] then error(result[2], 0) end
            return table.unpack(result, 2, result.n)
        end

        local lastShootErrorLog = -math.huge
        WeaponClass.shoot = function(self, ...)
            local shotAt = os.clock()
            if ownWeapon(self) and State.rageRapidFire then
                local rate = math.clamp(math.floor(tonumber(State.rageRapidRate) or 19), 1, 19)
                if shotAt - (Shared.rapidShotAt or -math.huge) < 1 / rate then return end
            end
            if Shared.releaseRapidGate then Shared.releaseRapidGate(self, shotAt) end
            local roundsBefore = tonumber(self.Rounds)
            local seqBefore = self.ShotSeq
            -- Manual sniper shots need the same scoped packet flag as auto fire.
            -- Restore the weapon/UI state before the next render frame.
            local sniperShot = ownWeapon(self) and (State.rageEnable or State.rageRapidFire)
                and type(self.Properties) == "table"
                and self.Properties.AimingOptions == "SniperScope"
            local wasAiming, wasScoped, wasAttr
            if sniperShot then
                wasAiming = self.IsAiming
                wasScoped = self.IsSniperScoped
                wasAttr = LocalPlayer:GetAttribute("IsSniperScoped")
                self.IsAiming = true
                self.IsSniperScoped = true
                pcall(LocalPlayer.SetAttribute, LocalPlayer, "IsSniperScoped", true)
            end
            local result = table.pack(pcall(originalShoot, self, ...))
            if sniperShot then
                self.IsAiming = wasAiming
                self.IsSniperScoped = wasScoped
                pcall(LocalPlayer.SetAttribute, LocalPlayer, "IsSniperScoped", wasAttr)
            end
            if not result[1] then
                if ownWeapon(self) then
                    if seqBefore == self.ShotSeq and roundsBefore
                        and tonumber(self.Rounds) and self.Rounds < roundsBefore then
                        self.Rounds = roundsBefore
                    end
                    if self.ShootDelayThread then
                        pcall(task.cancel, self.ShootDelayThread)
                        self.ShootDelayThread = nil
                    end
                    self.IsShooting = false
                    self.NextShotDue = nil
                    local now = os.clock()
                    if now - lastShootErrorLog > 2 then
                        lastShootErrorLog = now
                        warn(("[bs] shot error (pen=%s rapid=%s): %s"):format(
                            tostring(State.rageInfPen), tostring(State.rageRapidFire), tostring(result[2])))
                    end
                end
                error(result[2], 0)
            end
            if ownWeapon(self) and self.ShotSeq ~= seqBefore then
                Shared.rapidShotAt = shotAt
            end
            if ownWeapon(self) and (State.rageInfiniteAmmo or State.rageRapidFire)
                and tonumber(self.Rounds) == 0 and not self.IsReloading then
                task.defer(function()
                    if not unloaded and not self.IsDestroyed and not self.IsReloading
                        and tonumber(self.Rounds) == 0 then
                        pcall(self.reload, self)
                    end
                end)
            end
            return table.unpack(result, 2, result.n)
        end

        _G.__bs_add_teardown(function()
            unloaded = true
            WeaponClass.reload, WeaponClass.shoot = originalReload, originalShoot
        end)
        print("[bs] reload recovery and ammo controls loaded")
    else
        warn("[bs] Weapon class unavailable: reload and ammo controls disabled")
    end
end

do
    local peekRoot, peekOrigin, peekMarker
    local returning, arrived = false, false
    local function clearPeek()
        peekRoot, peekOrigin = nil, nil
        returning, arrived = false, false
        if peekMarker then peekMarker:Destroy(); peekMarker = nil end
    end
    local function markPeek(root)
        peekRoot, peekOrigin = root, root.Position
        returning, arrived = false, false
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character }
        local hit = Workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
        local ground = hit and hit.Position or root.Position - Vector3.new(0, 3, 0)
        local marker = Instance.new("Part")
        marker.Name = "bs_auto_peek_origin"
        marker.Shape = Enum.PartType.Cylinder
        marker.Size = Vector3.new(0.08, 2.2, 2.2)
        marker.CFrame = CFrame.new(ground + Vector3.new(0, 0.08, 0))
            * CFrame.Angles(0, 0, math.pi * 0.5)
        marker.Anchored = true
        marker.CanCollide = false
        marker.CanTouch = false
        marker.CanQuery = false
        marker.CastShadow = false
        marker.Material = Enum.Material.Neon
        marker.Color = Color3.fromRGB(188, 151, 169)
        marker.Transparency = 0.5
        marker.Parent = Workspace
        peekMarker = marker
    end
    Shared.autoPeekShot = function()
        if peekOrigin and State.moveAutoPeek and not returning then
            returning, arrived = true, false
            if peekMarker then peekMarker.Transparency = 0.15 end
        end
    end
    Shared.autoPeekWish = function()
        if not returning or not peekRoot or not peekOrigin then return nil end
        local delta = peekOrigin - peekRoot.Position
        local horizontal = Vector3.new(delta.X, 0, delta.Z)
        if arrived and horizontal.Magnitude > 2.5 then arrived = false end
        if arrived then return Vector3.zero end
        if horizontal.Magnitude < 1.4 then return Vector3.zero end
        return horizontal.Unit
    end
    local peekConn = RunService.Heartbeat:Connect(function()
        local key = State.moveAutoPeekKey
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not State.moveAutoPeek or typeof(key) ~= "EnumItem"
            or key == Enum.KeyCode.Unknown or not root
            or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true
            or State._menuOpen or UserInputService:GetFocusedTextBox()
            or not UserInputService:IsKeyDown(key) then
            if peekOrigin then clearPeek() end
            return
        end
        if not peekOrigin or peekRoot ~= root then
            clearPeek()
            markPeek(root)
            return
        end
        if not returning then return end
        local wish = Shared.autoPeekWish()
        if not wish then return end
        if wish.Magnitude < 0.01 then
            arrived = true
            if peekMarker then peekMarker.Transparency = 0.5 end
        end
        if root.Anchored then return end
        local velocity = root.AssemblyLinearVelocity
        local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
        local speed = math.clamp(tonumber(State.moveAutoPeekSpeed) or 105, 40, 180)
        local distance = (Vector3.new(peekOrigin.X, 0, peekOrigin.Z)
            - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
        local target = wish * math.min(speed, distance * 10)
        if (target - horizontal).Magnitude > 0.5 then
            root.AssemblyLinearVelocity = Vector3.new(target.X, velocity.Y, target.Z)
        end
    end)
    _G.__bs_add_teardown(function()
        peekConn:Disconnect()
        clearPeek()
        Shared.autoPeekShot = nil
        Shared.autoPeekWish = nil
    end)
end

do
    State.autoBuyEnable = false
    State.autoBuySlot = "1"
    State.autoBuySlot1 = ""
    State.autoBuySlot2 = ""
    State.autoBuySlot3 = ""
    for i = 1, 3 do
        State["autoBuyPrimary" .. i] = "none"
        State["autoBuySecondary" .. i] = "none"
    end

    local slotFile = "bs_configs/autobuy_slots.json"
    local function selectedSlot()
        return math.clamp(tonumber(State.autoBuySlot) or 1, 1, 3)
    end
    local function slotKey(slot)
        return "autoBuySlot" .. tostring(slot)
    end
    local function choiceKey(kind, slot)
        return "autoBuy" .. kind .. tostring(slot)
    end
    local function choice(kind, slot)
        local value = State[choiceKey(kind, slot)]
        return type(value) == "string" and value ~= "" and value or "none"
    end
    local function syncChoices()
        local slot = selectedSlot()
        State._autoBuyPrimaryChoice = choice("Primary", slot)
        State._autoBuySecondaryChoice = choice("Secondary", slot)
    end
    local function validPurchase(value)
        if type(value) ~= "table" or type(value.Name) ~= "string"
            or type(value.Path) ~= "string" or type(value.Equipment) ~= "boolean"
            or value.Name == "" then return nil end
        return { Name = value.Name, Equipment = value.Equipment, Path = value.Path }
    end
    local function decodeSlot(slot)
        local raw = State[slotKey(slot)]
        if type(raw) ~= "string" or raw == "" then return {} end
        local ok, entries = pcall(HttpSvc.JSONDecode, HttpSvc, raw)
        if not ok or type(entries) ~= "table" then return {} end
        local clean = {}
        for _, entry in ipairs(entries) do
            local purchase = validPurchase(entry)
            if purchase then clean[#clean + 1] = purchase end
            if #clean >= 6 then break end
        end
        return clean
    end
    local function saveSlots()
        if type(writefile) ~= "function" then return false, "no writefile" end
        if type(isfolder) == "function" and type(makefolder) == "function"
            and not isfolder(CONFIG_DIR) then pcall(makefolder, CONFIG_DIR) end
        local slots = {}
        for i = 1, 3 do
            slots[i] = {
                recorded = decodeSlot(i),
                primary = choice("Primary", i),
                secondary = choice("Secondary", i),
            }
        end
        return pcall(writefile, slotFile, HttpSvc:JSONEncode({ version = 2, slots = slots }))
    end
    if type(isfile) == "function" and type(readfile) == "function"
        and isfile(slotFile) then
        local ok, slots = pcall(function()
            return HttpSvc:JSONDecode(readfile(slotFile))
        end)
        if ok and type(slots) == "table" then
            if type(slots.slots) == "table" then slots = slots.slots end
            for i = 1, 3 do
                if type(slots[i]) == "table" then
                    local clean = {}
                    for _, entry in ipairs(slots[i].recorded or slots[i]) do
                        local purchase = validPurchase(entry)
                        if purchase then clean[#clean + 1] = purchase end
                        if #clean >= 6 then break end
                    end
                    State[slotKey(i)] = HttpSvc:JSONEncode(clean)
                    for _, spec in ipairs({ { "Primary", "primary" }, { "Secondary", "secondary" } }) do
                        local value = slots[i][spec[2]]
                        if type(value) == "string" and value ~= "" then
                            State[choiceKey(spec[1], i)] = value
                        end
                    end
                end
            end
        end
    end
    syncChoices()

    local controllers = ReplicatedStorage:FindFirstChild("Controllers")
    local dataModule = controllers and controllers:FindFirstChild("DataController")
    local inventoryModule = controllers and controllers:FindFirstChild("InventoryController")
    local dataOk, DataController = false, nil
    local inventoryOk, InventoryController = false, nil
    if dataModule then dataOk, DataController = pcall(require, dataModule) end
    if inventoryModule then inventoryOk, InventoryController = pcall(require, inventoryModule) end
    local database = ReplicatedStorage:FindFirstChild("Database")
    local custom = database and database:FindFirstChild("Custom")
    local weapons = custom and custom:FindFirstChild("Weapons")
    local catalog, catalogAt, catalogTeam = nil, -math.huge, nil
    local function weaponSlot(name)
        local module = weapons and weapons:FindFirstChild(name)
        if not module then return nil end
        local ok, props = pcall(require, module)
        if ok and type(props) == "table" and props.Class == "Weapon"
            and (props.Slot == "Primary" or props.Slot == "Secondary")
            and (tonumber(props.Cost) or 0) > 0 then return props.Slot end
        return nil
    end
    local function getCatalog(force)
        local team = LocalPlayer:GetAttribute("Team")
        if not force and catalog and catalogTeam == team and os.clock() - catalogAt < 1 then
            return catalog
        end
        local fresh = { Primary = {}, Secondary = {} }
        catalog, catalogAt, catalogTeam = fresh, os.clock(), team
        if not (dataOk and inventoryOk and weapons and type(DataController.Get) == "function"
            and type(InventoryController.GetEquippedInventoryItem) == "function") then return fresh end
        local ok, loadouts = pcall(DataController.Get, LocalPlayer, "Loadout")
        local active = ok and type(loadouts) == "table" and loadouts[team]
        if type(active) ~= "table" then return fresh end
        local function walk(node, path, depth)
            if depth > 6 then return end
            if path:match("%.Options%.[^.]+$") then
                local found, item = pcall(InventoryController.GetEquippedInventoryItem,
                    LocalPlayer, path)
                local name = found and type(item) == "table" and item.Name
                local slot = type(name) == "string" and weaponSlot(name)
                if slot and not fresh[slot][name] then
                    fresh[slot][name] = { Name = name, Equipment = false, Path = path }
                end
            end
            if type(node) == "table" then
                for key, value in pairs(node) do
                    walk(value, path == "" and tostring(key) or path .. "." .. tostring(key), depth + 1)
                end
            end
        end
        walk(active, type(active.Loadout) == "table" and "" or "Loadout", 0)
        return fresh
    end

    local remotesModule = ReplicatedStorage:FindFirstChild("Database")
    remotesModule = remotesModule and remotesModule:FindFirstChild("Security")
    remotesModule = remotesModule and remotesModule:FindFirstChild("Remotes")
    local okRemotes, remotes = false, nil
    if remotesModule then okRemotes, remotes = pcall(require, remotesModule) end
    local buyPacket = okRemotes and remotes and remotes.Inventory
        and remotes.Inventory.BuyMenuPurchase
    local originalSend = buyPacket and buyPacket.Send
    local recording, recordingSlot, recorded = false, nil, {}
    local replaying, unloaded, generation = false, false, 0
    local lastAutoBuyAt = -math.huge
    local statusText, statusAt = nil, -math.huge
    local function reportStatus(message)
        statusText, statusAt = message, os.clock()
    end
    local wrappedSend
    if type(originalSend) == "function" then
        wrappedSend = function(value)
            if recording and not replaying and #recorded < 6 then
                local purchase = validPurchase(value)
                if purchase then recorded[#recorded + 1] = purchase end
            end
            return originalSend(value)
        end
        local hooked = pcall(function() buyPacket.Send = wrappedSend end)
        if not hooked then wrappedSend = nil end
    end
    local ready = type(originalSend) == "function"
    local recordingReady = wrappedSend ~= nil

    local function gunOptions(kind)
        local options = { "none" }
        for name in pairs(getCatalog()[kind]) do options[#options + 1] = name end
        table.sort(options, function(a, b)
            if a == "none" then return true end
            if b == "none" then return false end
            return a:lower() < b:lower()
        end)
        return options
    end
    Shared.autoBuyPrimaryOptions = function() return gunOptions("Primary") end
    Shared.autoBuySecondaryOptions = function() return gunOptions("Secondary") end
    Shared.autoBuySetSlot = function()
        syncChoices()
    end
    Shared.autoBuyChoose = function(kind, name)
        if kind ~= "Primary" and kind ~= "Secondary" then return false end
        if name ~= "none" and not getCatalog()[kind][name] then
            reportStatus("gun not in current loadout")
            return false
        end
        State[choiceKey(kind, selectedSlot())] = name
        syncChoices()
        local saved = saveSlots()
        reportStatus(saved and "gun saved" or "gun set for this session")
        return true
    end
    Shared.autoBuyRefresh = function()
        local found = getCatalog(true)
        local count = 0
        for _ in pairs(found.Primary) do count = count + 1 end
        for _ in pairs(found.Secondary) do count = count + 1 end
        reportStatus(count > 0 and ("%d guns found"):format(count) or "loadout not ready")
        return count > 0
    end

    Shared.autoBuyStatus = function()
        if not ready then return "buy API unavailable" end
        if recording then return ("recording %d/6"):format(#recorded) end
        if statusText and os.clock() - statusAt < 4 then return statusText end
        local slot = selectedSlot()
        local count = #decodeSlot(slot)
        if choice("Primary", slot) ~= "none" then count = count + 1 end
        if choice("Secondary", slot) ~= "none" then count = count + 1 end
        return ("slot %d · %d selected"):format(slot, count)
    end
    Shared.autoBuyRecordStart = function()
        if not recordingReady then reportStatus("recording unavailable"); return false end
        recording, recordingSlot, recorded = true, selectedSlot(), {}
        return true
    end
    Shared.autoBuyRecordStop = function()
        if not recording then reportStatus("not recording"); return false end
        recording = false
        if #recorded == 0 then reportStatus("no buys captured"); return false end
        State[slotKey(recordingSlot)] = HttpSvc:JSONEncode(recorded)
        local saved = saveSlots()
        reportStatus(saved and ("saved %d buys"):format(#recorded) or "session only")
        recorded = {}
        return true
    end
    Shared.autoBuyClear = function()
        if recording and recordingSlot == selectedSlot() then recording = false end
        local slot = selectedSlot()
        State[slotKey(slot)] = ""
        State[choiceKey("Primary", slot)] = "none"
        State[choiceKey("Secondary", slot)] = "none"
        syncChoices()
        saveSlots()
        reportStatus("slot cleared")
    end
    Shared.autoBuyNow = function()
        if not ready then reportStatus("buy API unavailable"); return false end
        if recording then reportStatus("stop recording first"); return false end
        if replaying then return false end
        local slot = selectedSlot()
        local available = getCatalog(true)
        local primary = choice("Primary", slot)
        local secondary = choice("Secondary", slot)
        local items = {}
        for _, spec in ipairs({ { "Primary", primary }, { "Secondary", secondary } }) do
            local selected = spec[2] ~= "none" and available[spec[1]][spec[2]]
            if selected then items[#items + 1] = selected end
        end
        for _, purchase in ipairs(decodeSlot(slot)) do
            local kind = purchase.Equipment and nil or weaponSlot(purchase.Name)
            if (kind ~= "Primary" or primary == "none")
                and (kind ~= "Secondary" or secondary == "none") then
                items[#items + 1] = purchase
            end
            if #items >= 6 then break end
        end
        if #items == 0 then
            reportStatus((primary ~= "none" or secondary ~= "none")
                and "selected guns unavailable on this team" or "empty slot")
            return false
        end
        if os.clock() - lastAutoBuyAt < 3 then return false end
        local char = LocalPlayer.Character
        if not char or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true then
            reportStatus("not in round")
            return false
        end
        generation = generation + 1
        local run = generation
        lastAutoBuyAt = os.clock()
        replaying = true
        reportStatus(("buying %d items"):format(#items))
        task.spawn(function()
            for i, purchase in ipairs(items) do
                if unloaded or run ~= generation or char ~= LocalPlayer.Character
                    or char:GetAttribute("Dead") == true then break end
                pcall(originalSend, purchase)
                if i < #items then task.wait(0.42) end
            end
            replaying = false
        end)
        return true
    end
    local charConn
    local function scheduleAutoBuy()
        generation = generation + 1
        local queued = generation
        task.delay(1.1, function()
            if not unloaded and queued == generation and State.autoBuyEnable then
                Shared.autoBuyNow()
            end
        end)
    end
    local function watchCharacter(char)
        if charConn then charConn:Disconnect() end
        local wasDead = char:GetAttribute("Dead") == true
        charConn = char:GetAttributeChangedSignal("Dead"):Connect(function()
            local dead = char:GetAttribute("Dead") == true
            if dead then generation = generation + 1 end
            if wasDead and not dead then scheduleAutoBuy() end
            wasDead = dead
        end)
    end
    if LocalPlayer.Character then watchCharacter(LocalPlayer.Character) end
    local addedConn = LocalPlayer.CharacterAdded:Connect(function(char)
        watchCharacter(char)
        scheduleAutoBuy()
    end)
    _G.__bs_add_teardown(function()
        unloaded = true
        generation = generation + 1
        if charConn then charConn:Disconnect() end
        addedConn:Disconnect()
        if wrappedSend and buyPacket.Send == wrappedSend then
            pcall(function() buyPacket.Send = originalSend end)
        end
        Shared.autoBuyStatus = nil
        Shared.autoBuyRecordStart = nil
        Shared.autoBuyRecordStop = nil
        Shared.autoBuyClear = nil
        Shared.autoBuyNow = nil
        Shared.autoBuyPrimaryOptions = nil
        Shared.autoBuySecondaryOptions = nil
        Shared.autoBuySetSlot = nil
        Shared.autoBuyChoose = nil
        Shared.autoBuyRefresh = nil
    end)
end

-- Character input controls are independent of Bullet/Raycast loading.
-- PrepareInputFrame runs once per frame; SampleInput can run several times.
do
    State.antiAimEnable = false
    State.antiAimMode = "jitter" -- jitter | backward | spin | desync
    State.antiAimJitterAngle = 135
    State.antiAimJitterDelay = 30
    State.antiAimSpinSpeed = 720
    State.antiAimDesyncAngle = 110
    State.antiAimDesyncSide = "left" -- left | right | alternate
    State.antiAimSwitchDelay = 100
    State.antiAimPitchMode = "down" -- off | up | down | jitter | down jitter
    State.antiAimPitchAmount = 1 -- VerticalLook is the view direction's Y component
    State.antiAimKey = Enum.KeyCode.Unknown
    local classes = ReplicatedStorage:FindFirstChild("Classes")
    local characterModule = classes and classes:FindFirstChild("Character")
    -- A logical `and` expression would discard pcall's module return value.
    local ok, CharacterClass = false, nil
    if characterModule then ok, CharacterClass = pcall(require, characterModule) end
    local movementV2 = ReplicatedStorage:FindFirstChild("MovementV2")
    local kinematicsModule = movementV2 and movementV2:FindFirstChild("RuntimeKinematics")
    local kinOk, RuntimeKinematics = false, nil
    if kinematicsModule then kinOk, RuntimeKinematics = pcall(require, kinematicsModule) end
    local pendingYaw, pendingPitch, pendingCharacter, pendingGeneration
    local jitterSide = 1
    local pitchJitterSide = 1
    local nextJitterFlip = 0
    local jumpPressed = false
    local inputFrame, jumpPulseFrame = 0, -1
    local strafeSide, nextAutoFlip, mouseTurn = 1, 0, 0
    local moveErrorLogged = false
    local movementOwner, movementOwnerChar
    local boostUnavailableLogged = false
    local mouseConn = RunService.RenderStepped:Connect(function()
        if State.moveStrafe then
            mouseTurn = mouseTurn + UserInputService:GetMouseDelta().X
        end
    end)
    _G.__bs_add_teardown(function() mouseConn:Disconnect() end)

    local function movementState(self)
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if kinOk and RuntimeKinematics and type(RuntimeKinematics.resolve) == "function" and root then
            local resolved, velocity, _, _, _, grounded = pcall(RuntimeKinematics.resolve, char, root)
            if resolved and type(grounded) == "boolean" then
                return grounded, typeof(velocity) == "Vector3" and velocity or Vector3.zero
            end
        end
        return self.OnGround == true, root and root.AssemblyLinearVelocity or Vector3.zero
    end

    local boostConn = RunService.Heartbeat:Connect(function()
        if Shared.autoPeekWish and Shared.autoPeekWish() ~= nil then return end
        if not State.moveAirBoost then return end
        local bhopping = State.moveBhop
            and UserInputService:IsKeyDown(Enum.KeyCode.Space)
        if not State.moveStrafe and not bhopping then return end
        local char = LocalPlayer.Character
        if not movementOwner or movementOwnerChar ~= char or not char
            or char:GetAttribute("Dead") == true then return end
        local side = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
            - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
        local forward = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
            - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
        if side == 0 and forward == 0 then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        local cam = Workspace.CurrentCamera
        if not root or not cam or movementState(movementOwner) then return end
        if root.Anchored then
            if not boostUnavailableLogged then
                boostUnavailableLogged = true
                warn("[bs] direct air boost unavailable on anchored character; input strafe remains active")
            end
            return
        end
        local cameraRight = cam.CFrame.RightVector
        local right = Vector3.new(cameraRight.X, 0, cameraRight.Z)
        if right.Magnitude < 0.01 then return end
        right = right.Unit
        local look = Vector3.new(right.Z, 0, -right.X)
        local wish = right * side + look * forward
        if wish.Magnitude < 0.01 then return end
        local speed = bhopping
            and math.clamp(tonumber(State.moveBhopSpeed) or 140, 60, 240)
            or math.clamp(tonumber(State.moveAirSpeed) or 90, 30, 180)
        local ok, err = pcall(function()
            local current = root.AssemblyLinearVelocity
            local horizontal = Vector3.new(current.X, 0, current.Z)
            local target = wish.Unit * math.max(speed, math.min(horizontal.Magnitude, 240))
            if (target - horizontal).Magnitude > 0.1 then
                root.AssemblyLinearVelocity = Vector3.new(target.X, current.Y, target.Z)
            end
        end)
        if not ok and not boostUnavailableLogged then
            boostUnavailableLogged = true
            warn("[bs] direct air boost unavailable; input strafe remains active: " .. tostring(err))
        end
    end)
    _G.__bs_add_teardown(function() boostConn:Disconnect() end)

    Shared.armLookOverride = function(dir)
        if typeof(dir) ~= "Vector3" or dir.Magnitude < 0.01 then return end
        local aim = CFrame.lookAt(Vector3.zero, dir.Unit)
        local _, yaw = aim:ToEulerAnglesYXZ()
        local char = LocalPlayer.Character
        pendingYaw, pendingPitch, pendingCharacter = yaw, dir.Unit.Y, char
        pendingGeneration = char and char:GetAttribute("CharacterGeneration")
    end

    if ok and type(CharacterClass) == "table"
        and type(CharacterClass.PrepareInputFrame) == "function"
        and type(CharacterClass.SampleInput) == "function" then
        local origPrep = CharacterClass.PrepareInputFrame
        local origSample = CharacterClass.SampleInput
        CharacterClass.PrepareInputFrame = function(self, ...)
            local a, b, c, d = origPrep(self, ...)
            movementOwner, movementOwnerChar = self, LocalPlayer.Character
            inputFrame = inputFrame + 1
            return a, b, c, d
        end

        CharacterClass.SampleInput = function(self, ...)
            local sampleContext = ...
            local sampleState = type(sampleContext) == "table" and sampleContext.State
            -- Ladder velocity uses a full pitch/yaw basis, unlike planar WASD.
            local onLadder = type(sampleState) == "table" and sampleState.MovementMode == 1
            local autoJump = not onLadder and State.moveBhop
                and UserInputService:IsKeyDown(Enum.KeyCode.Space)
            local originalJump = self.JumpInputDown
            if autoJump then
                local grounded = movementState(self)
                if grounded then
                    if jumpPulseFrame ~= inputFrame then
                        jumpPulseFrame = inputFrame
                        jumpPressed = not jumpPressed
                    end
                else
                    jumpPressed = false
                end
                self.JumpInputDown = false
                self.JumpPulsePending = jumpPressed
            else
                jumpPressed = false
                jumpPulseFrame = -1
            end
            local cmd = origSample(self, ...)
            if autoJump then self.JumpInputDown = originalJump end
            if type(cmd) ~= "table" then
                Shared.antiAimDesyncYaw = nil
                Shared.antiAimVisualPitch = nil
                return cmd
            end
            if onLadder then
                pendingYaw, pendingPitch, pendingCharacter, pendingGeneration = nil, nil, nil, nil
                Shared.antiAimDesyncYaw = nil
                Shared.antiAimVisualPitch = nil
                return cmd
            end
            local char = LocalPlayer.Character
            local shotYaw, shotPitch
            if pendingYaw ~= nil and type(cmd.LookYaw) == "number" then
                if pendingCharacter == char and char and not self.IsDestroyed
                    and pendingGeneration == char:GetAttribute("CharacterGeneration")
                    and char:GetAttribute("Dead") ~= true
                    and LocalPlayer:GetAttribute("IsSpectating") ~= true then
                    shotYaw, shotPitch = pendingYaw, pendingPitch
                end
                pendingYaw, pendingPitch, pendingCharacter, pendingGeneration = nil, nil, nil, nil
            end

            -- Keep the command in sync with the pulse supplied to SampleInput.
            if autoJump and type(cmd.Buttons) == "number" then
                cmd.Buttons = jumpPressed
                    and bit32.bor(cmd.Buttons, 1)
                    or bit32.band(cmd.Buttons, bit32.bnot(1))
            end

            if (State.moveStrafe or State.moveBhop) and typeof(cmd.Move) == "Vector2" then
                local moveOk, moveResult = pcall(function()
                    local grounded, velocity = movementState(self)
                    if grounded then return nil end -- keep the game's ground controls
                    local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
                    local right = UserInputService:IsKeyDown(Enum.KeyCode.D)
                    local forward = UserInputService:IsKeyDown(Enum.KeyCode.W)
                    local back = UserInputService:IsKeyDown(Enum.KeyCode.S)
                    local manualSide = (right and 1 or 0) - (left and 1 or 0)
                    local manualForward = (back and 1 or 0) - (forward and 1 or 0)
                    local dx = mouseTurn
                    mouseTurn = 0
                    local viewDelta = math.atan2(
                        math.sin((self.CurrentFrameLookYaw or 0)
                            - (self.PreviousFrameLookYaw or 0)),
                        math.cos((self.CurrentFrameLookYaw or 0)
                            - (self.PreviousFrameLookYaw or 0)))
                    local viewForward = manualSide == 0 and forward and not back
                        and State.moveViewBhop and shotYaw == nil
                        and math.abs(viewDelta) > 0.0005
                    if manualSide ~= 0 or viewForward then
                        if manualSide ~= 0 then
                            strafeSide = manualSide
                            nextAutoFlip = 0
                        elseif viewForward then
                            strafeSide = viewDelta > 0 and -1 or 1
                        end
                        local manual = Vector2.new(manualSide, manualForward)
                        manual = manual.Magnitude > 1 and manual.Unit or manual
                        local yaw = tonumber(cmd.LookYaw) or self.CurrentFrameLookYaw or 0
                        local c, s = math.cos(yaw), math.sin(yaw)
                        local wish = Vector3.new(
                            c * manual.X + s * manual.Y, 0,
                            -s * manual.X + c * manual.Y)
                        local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
                        local speed = horizontal.Magnitude
                        local along = horizontal.X * wish.X + horizontal.Z * wish.Z
                        if speed > 0.9 and along >= 0.9 then
                            local velocityDir = horizontal.Unit
                            local tangent = wish - velocityDir * (along / speed)
                            if tangent.Magnitude < 0.001 then
                                tangent = Vector3.new(-velocityDir.Z, 0, velocityDir.X)
                                    * strafeSide
                            else
                                tangent = tangent.Unit
                            end
                            local parallel = math.min(0.9 / speed, 0.92)
                            local steer = velocityDir * parallel
                                + tangent * math.sqrt(1 - parallel * parallel)
                            return Vector2.new(c * steer.X - s * steer.Z,
                                s * steer.X + c * steer.Z)
                        end
                        return manual
                    elseif manualForward ~= 0 then
                        return nil -- S and W without view-angle bhop use native input
                    elseif State.moveStrafe and shotYaw == nil then
                        local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
                        local speed = horizontal.Magnitude
                        if math.abs(dx) > 0.1 then
                            strafeSide = dx > 0 and 1 or -1
                            nextAutoFlip = os.clock() + 0.09
                        elseif speed > 1 and os.clock() >= nextAutoFlip then
                            strafeSide = -strafeSide
                            nextAutoFlip = os.clock() + 0.09
                        end
                        local yaw = tonumber(cmd.LookYaw) or self.CurrentFrameLookYaw or 0
                        local wish
                        if speed < 1 then
                            local sideYaw = yaw + strafeSide * math.pi * 0.5
                            wish = Vector3.new(-math.sin(sideYaw), 0, -math.cos(sideYaw))
                        else
                            -- Perpendicular input gives the full air impulse;
                            -- aiming at cap/speed sat on the cap and stalled.
                            local angle = math.pi * 0.5 * strafeSide
                            local c, s = math.cos(angle), math.sin(angle)
                            local dir = horizontal.Unit
                            wish = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
                        end
                        local c, s = math.cos(yaw), math.sin(yaw)
                        local wx, wz = wish.X, -wish.Z
                        local x = c * wx + s * wz
                        local y = -(-s * wx + c * wz)
                        local move = Vector2.new(x, y)
                        return move.Magnitude > 1 and move.Unit or move
                    end
                    return nil
                end)
                if moveOk and typeof(moveResult) == "Vector2" then
                    cmd.Move = moveResult
                elseif not moveOk and not moveErrorLogged then
                    moveErrorLogged = true
                    warn("[bs] strafe error; using native movement: " .. tostring(moveResult))
                end
            end
            local returnWish = Shared.autoPeekWish and Shared.autoPeekWish()
            if typeof(returnWish) == "Vector3" then
                local yaw = tonumber(cmd.LookYaw) or self.CurrentFrameLookYaw or 0
                local c, s = math.cos(yaw), math.sin(yaw)
                cmd.Move = Vector2.new(c * returnWish.X - s * returnWish.Z,
                    s * returnWish.X + c * returnWish.Z)
            end
            local antiActive = State.antiAimEnable and shotYaw == nil
                and char and not self.IsDestroyed
                and char:GetAttribute("Dead") ~= true
                and LocalPlayer:GetAttribute("IsSpectating") ~= true
            local offset, fakePitch
            if antiActive then
                local mode = State.antiAimMode
                local pitchMode = State.antiAimPitchMode
                if mode == "jitter" or pitchMode == "jitter" or pitchMode == "down jitter" then
                    local now = os.clock()
                    if now >= nextJitterFlip then
                        jitterSide, pitchJitterSide = -jitterSide, -pitchJitterSide
                        nextJitterFlip = now + math.clamp(tonumber(State.antiAimJitterDelay) or 30, 0, 300) / 1000
                    end
                end
                if mode == "backward" then
                    offset = math.pi
                elseif mode == "spin" then
                    local speed = math.clamp(tonumber(State.antiAimSpinSpeed) or 720, 90, 1440)
                    offset = math.rad((os.clock() * speed) % 360)
                elseif mode == "desync" then
                    local angle = math.clamp(tonumber(State.antiAimDesyncAngle) or 110, 15, 180)
                    local side = State.antiAimDesyncSide
                    if side == "alternate" then
                        local delay = math.clamp(tonumber(State.antiAimSwitchDelay) or 100, 20, 600) / 1000
                        side = math.floor(os.clock() / delay) % 2 == 0 and "left" or "right"
                    end
                    offset = math.rad(angle) * (side == "right" and 1 or -1)
                else
                    local angle = math.clamp(tonumber(State.antiAimJitterAngle) or 135, 90, 180)
                    offset = math.rad(angle) * jitterSide
                end
                local amount = math.clamp(tonumber(State.antiAimPitchAmount) or 0.85, 0.2, 1)
                if pitchMode == "up" then fakePitch = amount
                elseif pitchMode == "down" then fakePitch = -amount
                elseif pitchMode == "jitter" then
                    fakePitch = amount * pitchJitterSide
                elseif pitchMode == "down jitter" then
                    fakePitch = -amount * (pitchJitterSide < 0 and 1 or 0.65)
                end
            end
            -- Preserve world travel for shot overrides as well as anti-aim.
            if type(cmd.LookYaw) == "number" and (shotYaw ~= nil or offset ~= nil) then
                local finalYaw = shotYaw or (cmd.LookYaw + offset)
                local delta = finalYaw - cmd.LookYaw
                if typeof(cmd.Move) == "Vector2" then
                    local c, s = math.cos(delta), math.sin(delta)
                    local x, y = cmd.Move.X, cmd.Move.Y
                    cmd.Move = Vector2.new(c * x - s * y, s * x + c * y)
                end
                cmd.LookYaw = math.atan2(math.sin(finalYaw), math.cos(finalYaw))
            end
            Shared.antiAimDesyncYaw = antiActive and State.antiAimMode == "desync" and offset
                and cmd.LookYaw or nil
            Shared.antiAimVisualPitch = fakePitch
            if shotPitch ~= nil then
                cmd.VerticalLook = shotPitch
            elseif fakePitch ~= nil then
                cmd.VerticalLook = fakePitch
            end
            return cmd
        end

        _G.__bs_add_teardown(function()
            pendingYaw, pendingPitch, pendingCharacter, pendingGeneration = nil, nil, nil, nil
            Shared.antiAimDesyncYaw = nil
            Shared.antiAimVisualPitch = nil
            Shared.armLookOverride = nil
            CharacterClass.SampleInput = origSample
            CharacterClass.PrepareInputFrame = origPrep
        end)
        print("[bs] movement v10 command-sampled angles loaded; kinematics:", kinOk and "on" or "fallback")
    else
        warn("[bs] Character input module unavailable: movement controls disabled")
    end
end

do
    local ghost, sourceChar, sourceParts, outline
    local ghostColor, ghostOpacity, ghostScale
    local lastValidYawAt = 0
    local nextUpdate = 0

    local function clearGhost()
        if ghost then ghost:Destroy() end
        ghost, sourceChar, sourceParts, outline = nil, nil, nil, nil
        ghostColor, ghostOpacity, ghostScale = nil, nil, nil
        lastValidYawAt = 0
    end

    local function buildGhost(char)
        clearGhost()
        local model = Instance.new("Model")
        model.Name = "bs_desync_pose"
        local pairsList = {}
        local headCopy
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart"
                and part.Transparency < 1 and #pairsList < 32 then
                local ok, copy = pcall(function() return part:Clone() end)
                if ok and copy then
                    for _, child in ipairs(copy:GetDescendants()) do
                        if not child:IsA("SpecialMesh") then child:Destroy() end
                    end
                    copy.Anchored = true
                    copy.CanCollide = false
                    copy.CanTouch = false
                    copy.CanQuery = false
                    copy.CastShadow = false
                    copy.Material = Enum.Material.ForceField
                    copy.Transparency = 0.55
                    copy.LocalTransparencyModifier = 0
                    pcall(function() copy.TextureID = "" end)
                    for _, child in ipairs(copy:GetChildren()) do
                        if child:IsA("SpecialMesh") then
                            pcall(function() child.TextureId = "" end)
                        end
                    end
                    copy.Parent = model
                    if part.Name == "Head" then headCopy = copy end
                    pairsList[#pairsList + 1] = { part, copy, copy:FindFirstChildOfClass("SpecialMesh") }
                end
            end
        end
        if #pairsList == 0 then model:Destroy(); return end
        local hl = Instance.new("Highlight")
        hl.Name = "bs_desync_outline"
        hl.Adornee = model
        hl.FillTransparency = 0.85
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = model
        local tag = Instance.new("BillboardGui")
        tag.Name = "bs_desync_tag"
        tag.Adornee = headCopy or pairsList[1][2]
        tag.AlwaysOnTop = true
        tag.Size = UDim2.fromOffset(88, 20)
        tag.StudsOffsetWorldSpace = Vector3.new(0, 1.25, 0)
        tag.Parent = model
        local textLabel = Instance.new("TextLabel")
        textLabel.Size = UDim2.fromScale(1, 1)
        textLabel.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
        textLabel.BackgroundTransparency = 0.2
        textLabel.BorderSizePixel = 0
        textLabel.Font = Enum.Font.Code
        textLabel.TextSize = 11
        textLabel.Text = "FAKE ANGLE"
        textLabel.TextColor3 = Color3.fromRGB(83, 229, 255)
        textLabel.Parent = tag
        model.Parent = Workspace
        ghost, sourceChar, sourceParts, outline = model, char, pairsList, hl
    end

    local connection = RunService.RenderStepped:Connect(function()
        if not State.desyncGhost or not State.antiAimEnable
            or State.antiAimMode ~= "desync" then
            if ghost then clearGhost() end
            return
        end
        local char = LocalPlayer.Character
        local yaw = Shared.antiAimDesyncYaw
        local now = os.clock()
        if not char or char:GetAttribute("Dead") == true
            or LocalPlayer:GetAttribute("IsSpectating") == true then
            if ghost then clearGhost() end
            return
        end
        if type(yaw) ~= "number" then
            if ghost and ghost.Parent and now - lastValidYawAt > 0.15 then
                ghost.Parent = nil
            end
            return
        end
        lastValidYawAt = now
        if now < nextUpdate then return end
        nextUpdate = now + 1 / 30
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then clearGhost(); return end
        if sourceChar ~= char or not ghost then buildGhost(char) end
        if not ghost then return end
        lastValidYawAt = now
        if not ghost.Parent then
            local attached = pcall(function() ghost.Parent = Workspace end)
            if not attached then buildGhost(char) end
        end
        if not ghost then return end
        local color = typeof(State.colDesyncGhost) == "Color3"
            and State.colDesyncGhost or Color3.fromRGB(83, 229, 255)
        local opacity = math.clamp(tonumber(State.desyncGhostOpacity) or 0.75, 0.1, 0.9)
        if color ~= ghostColor or opacity ~= ghostOpacity then
            for _, pair in ipairs(sourceParts) do
                pair[2].Color = color
                pair[2].Transparency = 1 - opacity
            end
            outline.FillColor = color
            outline.OutlineColor = color
            local tag = ghost:FindFirstChild("bs_desync_tag")
            local label = tag and tag:FindFirstChildOfClass("TextLabel")
            if label then label.TextColor3 = color end
            ghostColor, ghostOpacity = color, opacity
        end
        local tp = Shared.tpState
        local thirdPerson = tp and tp.active
        local scale = thirdPerson and 1 or 0.35
        if ghostScale ~= scale then
            for _, pair in ipairs(sourceParts) do
                pair[2].Size = pair[1].Size * scale
                local originalMesh = pair[1]:FindFirstChildOfClass("SpecialMesh")
                if pair[3] and originalMesh then
                    pair[3].Scale = originalMesh.Scale * scale
                end
            end
            ghostScale = scale
        end
        local offset = math.clamp(tonumber(State.desyncGhostOffset) or 4, 3, 6)
        local camera = Workspace.CurrentCamera
        local cameraFrame = camera and camera.CFrame
        local right = cameraFrame and cameraFrame.RightVector or Vector3.xAxis
        local center
        if thirdPerson then
            local lateral = Vector3.new(right.X, 0, right.Z)
            center = root.Position + (lateral.Magnitude > 0.01
                and lateral.Unit * offset or Vector3.zero)
        elseif cameraFrame then
            center = cameraFrame.Position + cameraFrame.LookVector * 6
                + right * (2 + offset) - cameraFrame.UpVector * 0.8
        else
            center = root.Position + Vector3.new(offset, 0, 0)
        end
        local fakeRoot = CFrame.new(center) * CFrame.Angles(0, yaw, 0)
        for _, pair in ipairs(sourceParts) do
            local original, copy = pair[1], pair[2]
            if original.Parent and copy.Parent then
                local relative = root.CFrame:ToObjectSpace(original.CFrame)
                copy.CFrame = fakeRoot * CFrame.new(relative.Position * scale) * relative.Rotation
            else
                copy.Transparency = 1
            end
        end
    end)
    _G.__bs_add_teardown(function()
        connection:Disconnect()
        clearGhost()
    end)
end

do
    local PlayerGui    = LocalPlayer:WaitForChild("PlayerGui")

    local old = PlayerGui:FindFirstChild("aether")
    if old then old:Destroy() end

    local T = {
        bgWindow      = Color3.fromRGB(24, 24, 24),
        bgSidebar     = Color3.fromRGB(30, 30, 30),
        bgContent     = Color3.fromRGB(22, 22, 22),
        bgColumnTint  = Color3.fromRGB(34, 34, 34),
        bgPill        = Color3.fromRGB(26, 26, 26),
        bgPillActive  = Color3.fromRGB(43, 43, 43),
        bgRowActive   = Color3.fromRGB(39, 39, 39),
        border        = Color3.fromRGB(52, 52, 52),
        accent        = Color3.fromRGB(188, 151, 169),
        accentDim     = Color3.fromRGB(76, 58, 67),
        text          = Color3.fromRGB(224, 224, 224),
        textDim       = Color3.fromRGB(173, 173, 173),
        textMuted     = Color3.fromRGB(150, 150, 150),
        textSection   = Color3.fromRGB(214, 214, 214),
        brand         = Color3.fromRGB(239, 239, 239),
        winSize       = Vector2.new(850, 598),
        sidebarWidth  = 144,
        topBarHeight  = 52,
        corner        = UDim.new(0, 5),
        cornerSmall   = UDim.new(0, 3),
        cornerBox     = UDim.new(0, 3),
        fontRegular   = Enum.Font.Gotham,
        fontMedium    = Enum.Font.GothamMedium,
        fontBold      = Enum.Font.GothamBold,
        textSize      = 12,
        textSizeSm    = 11,
        textSizeBrand = 17,
    }

    local function new(class, props, children)
        local inst = Instance.new(class)
        for k, v in pairs(props or {}) do inst[k] = v end
        for _, c in ipairs(children or {}) do c.Parent = inst end
        return inst
    end
    local function corner(r) return new("UICorner", { CornerRadius = r or T.corner }) end
    local function strokeI(c, t) return new("UIStroke", {
        Color = c or T.border, Thickness = t or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }) end
    local function pad(v)
        local p = Instance.new("UIPadding")
        local u = UDim.new(0, v)
        p.PaddingTop, p.PaddingRight, p.PaddingBottom, p.PaddingLeft = u, u, u, u
        return p
    end
    local function vlist(gap) return new("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        Padding = UDim.new(0, gap or 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }) end
    local function hlist(gap) return new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, gap or 4),
        VerticalAlignment = Enum.VerticalAlignment.Top,
        SortOrder = Enum.SortOrder.LayoutOrder,
    }) end

    local function ensureState(key, default)
        if State[key] == nil then State[key] = default end
        return State[key]
    end

    local ScreenGui = new("ScreenGui", {
        Name = "aether",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        DisplayOrder = 9999,
        Parent = PlayerGui,
    })
    _G.__bs_add_teardown(function() ScreenGui:Destroy() end)

    local Root = new("Frame", {
        Size = UDim2.fromOffset(T.winSize.X, T.winSize.Y),
        Position = UDim2.new(0.5, -T.winSize.X/2, 0.5, -T.winSize.Y/2),
        Visible = false,
        BackgroundColor3 = T.bgWindow,
        BorderSizePixel = 0,
        Parent = ScreenGui,
    }, { corner(), strokeI(T.border, 1) })
    local uiScale = new("UIScale", { Parent = Root })
    local function fitWindow()
        local cam = Workspace.CurrentCamera
        local viewport = cam and cam.ViewportSize or Vector2.new(1280, 720)
        local scale = math.min(1, (viewport.X - 32) / T.winSize.X, (viewport.Y - 32) / T.winSize.Y)
        if uiScale.Scale ~= scale then uiScale.Scale = scale end
        local centered = UDim2.new(0.5, -T.winSize.X * scale / 2, 0.5, -T.winSize.Y * scale / 2)
        if not Root:GetAttribute("Dragged") and Root.Position ~= centered then Root.Position = centered end
    end
    fitWindow()
    local nextFit = 0
    local viewportConn = RunService.RenderStepped:Connect(function()
        if not Root.Visible then return end
        local now = os.clock()
        if now < nextFit then return end
        nextFit = now + 0.25
        fitWindow()
    end)
    _G.__bs_add_teardown(function() viewportConn:Disconnect() end)
    local TopBar = new("Frame", {
        Size = UDim2.new(1, 0, 0, T.topBarHeight),
        BackgroundColor3 = T.bgSidebar,
        BorderSizePixel = 0,
        Parent = Root,
    })
    new("TextLabel", {
        Size = UDim2.fromOffset(240, 35),
        Position = UDim2.fromOffset(15, 8),
        BackgroundTransparency = 1,
        Font = T.fontRegular,
        Text = "romordial",
        TextColor3 = T.accent,
        TextSize = 21,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = TopBar,
    })
    local SearchBox = new("TextBox", {
        Size = UDim2.fromOffset(186, 28),
        Position = UDim2.new(1, -198, 0, 11),
        BackgroundColor3 = T.bgPill,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Font = T.fontRegular,
        PlaceholderText = "Search settings...",
        PlaceholderColor3 = T.textMuted,
        Text = "",
        TextColor3 = T.text,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = TopBar,
    }, { corner(T.cornerBox), strokeI(T.border, 1), pad(8) })
    new("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = T.accentDim, BorderSizePixel = 0, Parent = TopBar,
    })

    local Sidebar = new("Frame", {
        Size = UDim2.new(0, T.sidebarWidth, 1, -118),
        Position = UDim2.fromOffset(0, T.topBarHeight),
        BackgroundColor3 = T.bgSidebar,
        BorderSizePixel = 0,
        Parent = Root,
    })
    local PillRow = new("Frame", {
        Size = UDim2.new(1, 0, 1, -12),
        Position = UDim2.fromOffset(0, 8),
        BackgroundTransparency = 1,
        Parent = Sidebar,
    }, { vlist(1) })
    new("Frame", {
        Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0),
        BackgroundColor3 = T.border, BorderSizePixel = 0, Parent = Sidebar,
    })

    local Content = new("Frame", {
        Size = UDim2.new(1, -T.sidebarWidth, 1, -118),
        Position = UDim2.fromOffset(T.sidebarWidth, T.topBarHeight),
        BackgroundColor3 = T.bgContent,
        BorderSizePixel = 0,
        Parent = Root,
    })
    local Body = new("Frame", {
        Size = UDim2.new(1, -26, 1, -26),
        Position = UDim2.fromOffset(13, 13),
        BackgroundTransparency = 1,
        Parent = Content,
    }, { hlist(14) })

    local BottomBar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 66),
        Position = UDim2.new(0, 0, 1, -66),
        BackgroundColor3 = T.bgSidebar,
        BorderSizePixel = 0,
        Parent = Root,
    })
    new("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = T.accentDim,
        BorderSizePixel = 0,
        Parent = BottomBar,
    })
    local TabList = new("Frame", {
        Size = UDim2.new(1, -20, 1, -7),
        Position = UDim2.fromOffset(10, 5),
        BackgroundTransparency = 1,
        Parent = BottomBar,
    }, { new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }) })

    local function makeCheckRow(parent, def)
        if def.key and State[def.key] ~= nil then
            def.initial = State[def.key] == true
        end
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, def.header and 31 or 25),
            BackgroundColor3 = T.bgColumnTint,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            LayoutOrder = def._order or 0,
        })
        if def.header and not def.key then
            new("TextLabel", {
                Size = UDim2.new(1, -4, 0, 20),
                Position = UDim2.fromOffset(3, 3),
                BackgroundTransparency = 1,
                Font = T.fontBold,
                Text = def.label:upper(),
                TextColor3 = def.dim and T.textMuted or T.textSection,
                TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Left,
                Parent = row,
            })
            new("Frame", {
                Size = UDim2.new(1, -4, 0, 1),
                Position = UDim2.new(0, 2, 1, -2),
                BackgroundColor3 = T.border,
                BackgroundTransparency = 0.2,
                BorderSizePixel = 0,
                Parent = row,
            })
            row.Parent = parent
            return row
        end
        local TRACK_W, TRACK_H = 13, 13
        local track = new("TextButton", {
            Size = UDim2.fromOffset(TRACK_W, TRACK_H),
            Position = UDim2.new(0, 4, 0.5, -TRACK_H / 2),
            BackgroundColor3 = T.bgPill,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Parent = row,
        }, { strokeI(T.border, 1) })
        local fill = new("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Font = T.fontBold,
            Text = "✓",
            TextColor3 = T.accent,
            TextSize = 12,
            Visible = def.initial == true,
            Parent = track,
        })
        local label = new("TextButton", {
            Size = UDim2.new(1, -29, 1, 0),
            Position = UDim2.fromOffset(26, 0),
            BackgroundTransparency = 1,
            Font = T.fontRegular,
            Text = def.label,
            TextColor3 = def.dim and T.textMuted or (def.initial and T.text or T.textDim),
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            AutoButtonColor = false,
            Parent = row,
        })
        local value
        if def.key then value = State[def.key] == true else value = def.initial == true end
        local function paint()
            fill.Visible = value
            track.BackgroundColor3 = value and T.accentDim or T.bgPill
            label.TextColor3 = def.dim and T.textMuted or (value and T.text or T.textDim)
        end
        paint()
        local function toggle()
            value = not value
            if def.key then State[def.key] = value end
            paint()
            if def.onChange then def.onChange(value) end
        end
        track.MouseButton1Click:Connect(toggle)
        label.MouseButton1Click:Connect(toggle)
        row.Parent = parent
        return row
    end

    -- Round slider readouts so fractional steps do not show float artifacts.
    local function fmtNum(v)
        if v == math.floor(v) then return tostring(v) end
        return (("%.2f"):format(v):gsub("0$", ""))
    end

    local function makeSliderRow(parent, def)
        local wrap = new("Frame", {
            Size = UDim2.new(1, 0, 0, 54),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 1,
            LayoutOrder = def._order or 0,
        })
        new("TextLabel", {
            Size = UDim2.new(1, -62, 0, 32),
            Position = UDim2.fromOffset(3, 3),
            BackgroundTransparency = 1,
            Font = T.fontRegular,
            Text = def.label,
            TextColor3 = T.textDim,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = wrap,
        })
        local initial = math.clamp(tonumber(State[def.key]) or def.min, def.min, def.max)
        State[def.key] = initial
        local valueText = new("TextLabel", {
            Size = UDim2.fromOffset(46, 16),
            Position = UDim2.new(1, -49, 0, 3),
            BackgroundTransparency = 1,
            Font = T.fontMedium,
            Text = fmtNum(initial),
            TextColor3 = T.accent,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Right,
            Parent = wrap,
        })
        local TRACK_H = 3
        local track = new("Frame", {
            Size = UDim2.new(1, -16, 0, TRACK_H),
            Position = UDim2.new(0, 8, 1, -(TRACK_H + 9)),
            BackgroundColor3 = T.bgPill,
            BorderSizePixel = 0,
            Parent = wrap,
        })
        local pct = (initial - def.min) / (def.max - def.min)
        local fill = new("Frame", {
            Size = UDim2.fromScale(pct, 1),
            BackgroundColor3 = T.accent,
            BorderSizePixel = 0,
            Parent = track,
        })
        local KNOB = 8
        local knob = new("Frame", {
            Size = UDim2.fromOffset(KNOB, KNOB),
            Position = UDim2.new(pct, -KNOB / 2, 0.5, -KNOB / 2),
            BackgroundColor3 = T.brand,
            BorderSizePixel = 0,
            ZIndex = 2,
            Parent = track,
        }, { corner(UDim.new(1, 0)), strokeI(T.accent, 1) })
        local dragging = false
        local function setFromX(px)
            if track.AbsoluteSize.X <= 0 then return end
            local rel = math.clamp((px - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
            local val = def.min + rel * (def.max - def.min)
            if def.step and def.step > 0 then
                val = def.min + math.floor((val - def.min) / def.step + 0.5) * def.step
            end
            val = math.clamp(val, def.min, def.max)
            local newPct = (val - def.min) / (def.max - def.min)
            fill.Size = UDim2.fromScale(newPct, 1)
            knob.Position = UDim2.new(newPct, -KNOB / 2, 0.5, -KNOB / 2)
            valueText.Text = fmtNum(val)
            State[def.key] = val
        end
        local hitArea = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 20),
            Position = UDim2.new(0, 0, 0.5, -10),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 3,
            Parent = track,
        })
        hitArea.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true; setFromX(input.Position.X)
            end
        end)
        -- Global input hooks die with the row (rows are rebuilt per tab switch).
        local moveConn = UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                setFromX(input.Position.X)
            end
        end)
        local endConn = UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end)
        wrap.Destroying:Connect(function() moveConn:Disconnect(); endConn:Disconnect() end)
        wrap.Parent = parent
        return wrap
    end

    local function makeButtonRow(parent, def)
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, def.status and 49 or 29),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 1,
            LayoutOrder = def._order or 0,
        })
        local status
        if def.status then
            status = new("TextLabel", {
                Size = UDim2.new(1, -8, 0, 18),
                Position = UDim2.fromOffset(4, 0),
                BackgroundTransparency = 1,
                Font = T.fontRegular,
                Text = def.status() or "",
                TextColor3 = T.textDim,
                TextSize = T.textSize,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = row,
            })
        end
        local btn = new("TextButton", {
            Size = UDim2.new(1, -8, 0, 26),
            Position = UDim2.fromOffset(4, status and 21 or 1),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 0,
            BorderSizePixel = 0,
            Font = T.fontMedium,
            Text = def.label,
            TextColor3 = T.text,
            TextSize = T.textSize,
            TextTruncate = Enum.TextTruncate.AtEnd,
            AutoButtonColor = true,
            Parent = row,
        }, { corner(T.cornerSmall) })
        btn.MouseButton1Click:Connect(function()
            if def.onClick then
                local ok, msg = pcall(def.onClick)
                if status and def.status then
                    status.Text = def.status() or (ok and "ok" or ("err: " .. tostring(msg)))
                end
            end
        end)
        row.Parent = parent
        return row
    end

    local activeDropdown
    local function makeDropdownRow(parent, def)
        local options = type(def.options) == "function" and def.options() or def.options
        if type(options) ~= "table" or #options == 0 then options = { "none" } end
        local menuHeight = math.min(#options, 7) * 26 + 4
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, 62),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 1,
            LayoutOrder = def._order or 0,
        })
        new("TextLabel", {
            Size = UDim2.new(1, -8, 0, 30),
            Position = UDim2.fromOffset(4, 1),
            BackgroundTransparency = 1,
            Font = T.fontRegular,
            Text = def.label,
            TextColor3 = T.textDim,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = row,
        })
        local current = tostring(State[def.key] or options[1])
        local btn = new("TextButton", {
            Size = UDim2.new(1, -8, 0, 23),
            Position = UDim2.fromOffset(4, 35),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 0,
            BorderSizePixel = 0,
            Font = T.fontMedium,
            Text = "  " .. current .. "   ▾",
            TextColor3 = T.text,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            AutoButtonColor = false,
            Parent = row,
        }, { corner(T.cornerSmall), strokeI(T.border, 1) })
        local menu = new("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, menuHeight),
            Position = UDim2.fromOffset(0, 0),
            BackgroundColor3 = T.bgPill,
            BorderSizePixel = 0,
            CanvasSize = UDim2.fromOffset(0, #options * 26 + 4),
            ScrollBarThickness = #options > 7 and 3 or 0,
            ScrollBarImageColor3 = T.textDim,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            Visible = false,
            ZIndex = 50,
            Parent = Root,
        }, { corner(T.cornerSmall), strokeI(T.border, 1), pad(2) })
        new("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            Padding = UDim.new(0, 0),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = menu,
        })
        for _, opt in ipairs(options) do
            local item = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 26),
                BackgroundTransparency = 1,
                Font = T.fontRegular,
                Text = "  " .. opt,
                TextColor3 = T.textDim,
                TextSize = T.textSize,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                AutoButtonColor = true,
                ZIndex = 51,
                Parent = menu,
            })
            item.MouseButton1Click:Connect(function()
                btn.Text = "  " .. opt .. "   ▾"
                State[def.key] = opt
                menu.Visible = false
                if activeDropdown == menu then activeDropdown = nil end
                if def.onChange then def.onChange(opt) end
            end)
        end
        btn.MouseButton1Click:Connect(function()
            if not menu.Visible then
                if activeDropdown and activeDropdown ~= menu then activeDropdown.Visible = false end
                local scale = uiScale.Scale
                local x = (btn.AbsolutePosition.X - Root.AbsolutePosition.X) / scale
                local top = (btn.AbsolutePosition.Y - Root.AbsolutePosition.Y) / scale
                local below = top + btn.AbsoluteSize.Y / scale + 2
                local y = below + menuHeight > T.winSize.Y - 70
                    and top - menuHeight - 2 or below
                menu.Size = UDim2.fromOffset(btn.AbsoluteSize.X / scale, menuHeight)
                menu.Position = UDim2.fromOffset(x, math.max(T.topBarHeight + 2, y))
                activeDropdown = menu
            else
                activeDropdown = nil
            end
            menu.Visible = not menu.Visible
        end)
        row.Destroying:Connect(function()
            if activeDropdown == menu then activeDropdown = nil end
            menu:Destroy()
        end)
        row.Parent = parent
        return row
    end

    local PALETTE = {
        Color3.fromRGB(255, 70, 70),   Color3.fromRGB(255, 140, 60),  Color3.fromRGB(255, 215, 70),  Color3.fromRGB(170, 255, 80),
        Color3.fromRGB(90, 235, 120),  Color3.fromRGB(60, 220, 190),  Color3.fromRGB(70, 210, 255),  Color3.fromRGB(90, 150, 255),
        Color3.fromRGB(70, 90, 255),   Color3.fromRGB(140, 90, 255),  Color3.fromRGB(190, 90, 255),  Color3.fromRGB(255, 80, 220),
        Color3.fromRGB(255, 130, 170), Color3.fromRGB(245, 245, 250), Color3.fromRGB(170, 172, 185), Color3.fromRGB(90, 92, 105),
    }
    local function makeColorRow(parent, def)
        local CLOSED_H, OPEN_H = 32, 107
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, CLOSED_H),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 1,
            ClipsDescendants = true,
            LayoutOrder = def._order or 0,
        })
        new("TextLabel", {
            Size = UDim2.new(1, -50, 0, CLOSED_H),
            Position = UDim2.fromOffset(7, 0),
            BackgroundTransparency = 1,
            Font = T.fontRegular,
            Text = def.label,
            TextColor3 = T.textDim,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = row,
        })
        local swatch = new("TextButton", {
            Size = UDim2.fromOffset(28, 18),
            Position = UDim2.new(1, -35, 0, 4),
            BackgroundColor3 = State[def.key] or Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Parent = row,
        }, { corner(UDim.new(0, 3)), strokeI(T.border, 1) })
        local grid = new("Frame", {
            Size = UDim2.new(1, -16, 0, 2 * 18),
            Position = UDim2.fromOffset(7, 39),
            BackgroundTransparency = 1,
            Parent = row,
        })
        new("UIGridLayout", {
            CellSize = UDim2.new(1 / 8, -3.5, 0, 14),
            CellPadding = UDim2.fromOffset(4, 4),
            FillDirectionMaxCells = 8,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = grid,
        })
        local function hexColor(color)
            return string.format("#%02X%02X%02X",
                math.floor(color.R * 255 + 0.5),
                math.floor(color.G * 255 + 0.5),
                math.floor(color.B * 255 + 0.5))
        end
        local hexBox = new("TextBox", {
            Size = UDim2.new(1, -14, 0, 22),
            Position = UDim2.fromOffset(7, 77),
            BackgroundColor3 = T.bgPillActive,
            BorderSizePixel = 0,
            ClearTextOnFocus = false,
            Font = Enum.Font.Code,
            Text = hexColor(State[def.key] or Color3.new(1, 1, 1)),
            TextColor3 = T.text,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = row,
        }, { corner(UDim.new(0, 3)), strokeI(T.border, 1) })
        local open = false
        local function setOpen(v)
            open = v
            local height = open and OPEN_H or CLOSED_H
            local delta = height - row.Size.Y.Offset
            row.Size = UDim2.new(1, 0, 0, height)
            local card = parent.Parent
            card.Size = UDim2.new(1, 0, 0, card.Size.Y.Offset + delta)
        end
        local function setColor(color)
            State[def.key] = color
            swatch.BackgroundColor3 = color
            hexBox.Text = hexColor(color)
        end
        for i, c in ipairs(PALETTE) do
            local cell = new("TextButton", {
                BackgroundColor3 = c,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = true,
                LayoutOrder = i,
                Parent = grid,
            }, { corner(UDim.new(0, 3)) })
            cell.MouseButton1Click:Connect(function()
                setColor(c)
                setOpen(false)
            end)
        end
        hexBox.FocusLost:Connect(function()
            local hex = hexBox.Text:gsub("^#", "")
            if hex:match("^%x%x%x%x%x%x$") then
                setColor(Color3.fromRGB(
                    tonumber(hex:sub(1, 2), 16),
                    tonumber(hex:sub(3, 4), 16),
                    tonumber(hex:sub(5, 6), 16)))
            else
                hexBox.Text = hexColor(State[def.key] or Color3.new(1, 1, 1))
            end
        end)
        swatch.MouseButton1Click:Connect(function() setOpen(not open) end)
        row.Parent = parent
        return row
    end

    -- _bindListening prevents the new key press from triggering its action.
    local function makeKeybindRow(parent, def)
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, 47),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 1,
            LayoutOrder = def._order or 0,
        })
        new("TextLabel", {
            Size = UDim2.new(1, -8, 0, 18),
            Position = UDim2.fromOffset(4, 0),
            BackgroundTransparency = 1,
            Font = T.fontRegular,
            Text = def.label,
            TextColor3 = T.textDim,
            TextSize = T.textSize,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = row,
        })
        local function keyName()
            local k = State[def.key]
            return typeof(k) == "EnumItem" and k.Name or "none"
        end
        local btn = new("TextButton", {
            Size = UDim2.new(1, -8, 0, 24),
            Position = UDim2.fromOffset(4, 21),
            BackgroundColor3 = T.bgPill,
            BackgroundTransparency = 0,
            BorderSizePixel = 0,
            Font = T.fontMedium,
            Text = "[" .. keyName() .. "]",
            TextColor3 = T.text,
            TextSize = T.textSize,
            TextTruncate = Enum.TextTruncate.AtEnd,
            AutoButtonColor = false,
            Parent = row,
        }, { corner(T.cornerSmall) })
        local listenConn
        btn.MouseButton1Click:Connect(function()
            if listenConn then return end
            btn.Text = "[...]"
            State._bindListening = true
            listenConn = UserInputService.InputBegan:Connect(function(input)
                if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
                if input.KeyCode ~= Enum.KeyCode.Escape then State[def.key] = input.KeyCode end
                btn.Text = "[" .. keyName() .. "]"
                listenConn:Disconnect(); listenConn = nil
                -- Clear after this input finishes dispatching to other handlers.
                task.defer(function() State._bindListening = false end)
            end)
        end)
        row.Destroying:Connect(function()
            if listenConn then listenConn:Disconnect(); State._bindListening = false end
        end)
        row.Parent = parent
        return row
    end

    local function makeColumn(parent, title, height)
        local card = new("Frame", {
            Size = UDim2.new(1, 0, 0, height),
            BackgroundColor3 = T.bgColumnTint,
            BorderSizePixel = 0,
            Parent = parent,
        }, { corner(UDim.new(0, 8)), strokeI(T.border, 1) })
        new("TextLabel", {
            Size = UDim2.new(1, -20, 0, 29),
            Position = UDim2.fromOffset(11, 0),
            BackgroundTransparency = 1,
            Font = T.fontMedium,
            Text = title or "Settings",
            TextColor3 = T.text,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = card,
        })
        new("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            Position = UDim2.fromOffset(0, 30),
            BackgroundColor3 = T.accentDim,
            BorderSizePixel = 0,
            Parent = card,
        })
        local col = new("Frame", {
            Size = UDim2.new(1, -14, 0, 0),
            Position = UDim2.fromOffset(7, 36),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            AutomaticSize = Enum.AutomaticSize.Y,
            Parent = card,
        }, { pad(3), vlist(2) })
        return col
    end

    -- Forward declaration lets tab callbacks capture the local function.
    local renderBody

    local Tabs = {
        { icon = "•", label = "rage",
          subs = {
              { name = "aimbot", cols = {
                  { rows = {
                      { label = "enable",      key = "rageEnable",   initial = ensureState("rageEnable", false) == true },
                      { label = "silent aim",  key = "rageSilent",   initial = ensureState("rageSilent", true) == true },
                      { label = "auto fire",   key = "rageAutoFire", initial = ensureState("rageAutoFire", false) == true },
                      { label = "autowall",    key = "rageAutowall", initial = ensureState("rageAutowall", false) == true },
                      { label = "inf penetration", key = "rageInfPen",   initial = ensureState("rageInfPen", false) == true },
                      { label = "no spread",   key = "rageNoSpread", initial = ensureState("rageNoSpread", false) == true },
                      { label = "no recoil",   key = "rageNoRecoil", initial = ensureState("rageNoRecoil", false) == true },
                      { label = "rapid fire",  key = "rageRapidFire", initial = ensureState("rageRapidFire", false) == true },
                      { label = "rapid packets/s", kind = "slider", key = "rageRapidRate", min = 1, max = 19, step = 1 },
                      { label = "auto reload (reliable ammo)", key = "rageInfiniteAmmo", initial = ensureState("rageInfiniteAmmo", false) == true },
                      { label = "infinite reserves", key = "rageInfReserve", initial = ensureState("rageInfReserve", false) == true },
                      { label = "instant magazine reload", key = "rageFastReload", initial = ensureState("rageFastReload", false) == true },
                      { label = "magazines still reload", header = true, dim = true },
                      { label = "backtrack", key = "rageBacktrack", initial = ensureState("rageBacktrack", false) == true },
                      { label = "shot log",    key = "rageShotLog",  initial = ensureState("rageShotLog", false) == true },
                      { label = "",            header = true },
                      { label = "keybinds",    header = true },
                      { label = "enable",      kind = "keybind", key = "rageKeyEnable" },
                      { label = "silent aim",  kind = "keybind", key = "rageKeySilent" },
                      { label = "auto fire",   kind = "keybind", key = "rageKeyAutoFire" },
                      { label = "rapid fire",  kind = "keybind", key = "rageKeyRapidFire" },
                  } },
                  { rows = {
                      { label = "hitbox", kind = "dropdown", key = "rageHitbox", options = { "head", "body", "multipoint" } },
                      { label = "priority", kind = "dropdown", key = "ragePriority", options = { "angle", "distance", "health", "threat" } },
                      { label = "multipoint all", key = "rageMpAll", initial = ensureState("rageMpAll", false) == true },
                      { label = "auto scale",   key = "rageMpAuto",  initial = ensureState("rageMpAuto", true) == true },
                      { label = "point scale", kind = "slider", key = "rageMpScale", min = 0.05, max = 1, step = 0.05 },
                      { label = "fov", kind = "slider", key = "rageFov", min = 1, max = 180, step = 1 },
                      { label = "max distance", kind = "slider", key = "rageMaxDist", min = 50, max = 1000, step = 10 },
                      { label = "backtrack window (ms)", kind = "slider", key = "rageBacktrackMs", min = 50, max = 200, step = 10 },
                      { label = "adaptive resolver", key = "rageResolver", initial = ensureState("rageResolver", false) == true },
                      { label = "head misses before body", kind = "slider", key = "rageResolverMisses", min = 1, max = 4, step = 1 },
                  } },
              } },
              { name = "targets", dynamicTargets = true, cols = { { rows = {} }, { rows = {} } } },
              { name = "anti-aim", cols = {
                  { rows = {
                      { label = "orientation", header = true },
                      { label = "enable", key = "antiAimEnable", initial = ensureState("antiAimEnable", false) == true },
                      { label = "mode", kind = "dropdown", key = "antiAimMode", options = { "jitter", "backward", "spin", "desync" } },
                      { label = "jitter angle", kind = "slider", key = "antiAimJitterAngle", min = 90, max = 180, step = 5 },
                      { label = "jitter delay (ms)", kind = "slider", key = "antiAimJitterDelay", min = 0, max = 300, step = 10 },
                      { label = "spin speed (deg/s)", kind = "slider", key = "antiAimSpinSpeed", min = 90, max = 1440, step = 30 },
                      { label = "desync angle", kind = "slider", key = "antiAimDesyncAngle", min = 15, max = 180, step = 5 },
                      { label = "desync side", kind = "dropdown", key = "antiAimDesyncSide", options = { "left", "right", "alternate" } },
                      { label = "side switch delay (ms)", kind = "slider", key = "antiAimSwitchDelay", min = 20, max = 600, step = 10 },
                      { label = "pitch", kind = "dropdown", key = "antiAimPitchMode", options = { "off", "up", "down", "jitter", "down jitter" } },
                      { label = "pitch amount", kind = "slider", key = "antiAimPitchAmount", min = 0.2, max = 1, step = 0.1 },
                  } },
                  { rows = {
                      { label = "controls", header = true },
                      { label = "toggle key", kind = "keybind", key = "antiAimKey" },
                      { label = "backward: 180° from camera", header = true, dim = true },
                      { label = "jitter: alternating sides", header = true, dim = true },
                      { label = "spin: continuous rotation", header = true, dim = true },
                      { label = "desync: steady body angle, camera stays free", header = true, dim = true },
                      { label = "pose preview in Visuals > Chams", header = true, dim = true },
                      { label = "silent shots face target for one tick", header = true, dim = true },
                      { label = "WASD direction is corrected", header = true, dim = true },
                  } },
              } },
          } },
        { icon = "•", label = "visuals",
          subs = {
              { name = "players", cols = {
                  { rows = {
                      { label = "enable",       key = "visualsEnable",    initial = ensureState("visualsEnable", false) == true },
                      { label = "ignore team",  key = "visualsTeamCheck", initial = ensureState("visualsTeamCheck", true) == true },
                      { label = "",             header = true },
                      { label = "esp",          header = true },
                      { label = "name",         key = "espName",      initial = ensureState("espName", true)     == true },
                      { label = "health bar",   key = "espHealth",    initial = ensureState("espHealth", true)   == true },
                      { label = "weapon",       key = "espWeapon",    initial = ensureState("espWeapon", true)   == true },
                      { label = "ping",         key = "espPing",      initial = ensureState("espPing", true)     == true },
                      { label = "distance",     key = "espDistance",  initial = ensureState("espDistance", false) == true },
                      { label = "box",          key = "espBox",       initial = ensureState("espBox", false)     == true },
                      { label = "skeleton",     key = "espSkeleton",  initial = ensureState("espSkeleton", false) == true },
                      { label = "backtrack ghosts", key = "backtrackVisual", initial = ensureState("backtrackVisual", false) == true },
                      { label = "hide when dead", key = "espHideWhenDead", initial = ensureState("espHideWhenDead", true) == true },
                  } },
                  { rows = {
                      { label = "chams",         header = true },
                      { label = "enable",        key = "chamsEnable",       initial = ensureState("chamsEnable", false) == true },
                      { label = "through walls", key = "chamsThroughWalls", initial = ensureState("chamsThroughWalls", true) == true },
                      { label = "enemies", key = "chamsEnemy", initial = ensureState("chamsEnemy", true) == true },
                      { label = "teammates", key = "chamsTeammates", initial = ensureState("chamsTeammates", true) == true },
                      { label = "my player", key = "chamsSelf", initial = ensureState("chamsSelf", true) == true },
                      { label = "my weapon", key = "chamsWeapon", initial = ensureState("chamsWeapon", true) == true },
                      { label = "ForceField ghost", key = "desyncGhost", initial = ensureState("desyncGhost", false) == true },
                      { label = "ghost opacity", kind = "slider", key = "desyncGhostOpacity", min = 0.1, max = 0.9, step = 0.05 },
                      { label = "preview offset", kind = "slider", key = "desyncGhostOffset", min = 3, max = 6, step = 0.25 },
                      { label = "ghost color", kind = "color", key = "colDesyncGhost" },
                      { label = "weapon material", kind = "dropdown", key = "weaponMaterial", options = { "original", "neon", "forcefield", "glass", "metal", "smooth plastic", "wood", "diamond plate" } },
                      { label = "material in third person", key = "weaponMaterialThirdPerson", initial = ensureState("weaponMaterialThirdPerson", true) == true },
                      { label = "tint weapon material", key = "weaponMaterialTint", initial = ensureState("weaponMaterialTint", true) == true },
                      { label = "hide skin texture", key = "weaponMaterialHideTextures", initial = ensureState("weaponMaterialHideTextures", false) == true },
                      { label = "weapon cham fill", kind = "slider", key = "weaponChamFillOpacity", min = 0, max = 1, step = 0.05 },
                      { label = "style", kind = "dropdown", key = "chamsStyle", options = { "glow", "soft", "outline" } },
                      { label = "fill opacity", kind = "slider", key = "chamsFillOpacity", min = 0, max = 1, step = 0.05 },
                      { label = "outline opacity", kind = "slider", key = "chamsOutlineOpacity", min = 0, max = 1, step = 0.05 },
                      { label = "animated chams", header = true },
                      { label = "enable animation", key = "chamsAnimation", initial = ensureState("chamsAnimation", false) == true },
                      { label = "animation", kind = "dropdown", key = "chamsAnimationMode", options = { "pulse", "gradient" } },
                      { label = "speed", kind = "slider", key = "chamsAnimationSpeed", min = 0.25, max = 5, step = 0.25 },
                      { label = "strength", kind = "slider", key = "chamsAnimationStrength", min = 0, max = 1, step = 0.05 },
                      { label = "gradient color", kind = "color", key = "colChamAnimation" },
                      { label = "scene tint", key = "chamsSceneTint", initial = ensureState("chamsSceneTint", false) == true },
                      { label = "tint strength", kind = "slider", key = "chamsTintStrength", min = 0, max = 0.8, step = 0.05 },
                      { label = "cham colors", header = true },
                      { label = "visible enemy", kind = "color", key = "colChamVisible" },
                      { label = "hidden enemy", kind = "color", key = "colChamHidden" },
                      { label = "teammate", kind = "color", key = "colChamTeammate" },
                      { label = "my player", kind = "color", key = "colChamSelf" },
                      { label = "my weapon", kind = "color", key = "colChamWeapon" },
                      { label = "stale player", kind = "color", key = "colChamStale" },
                      { label = "outline", kind = "color", key = "colChamOutline" },
                      { label = "scene tint", kind = "color", key = "colChamTint" },
                      { label = "my aura", key = "auraEnable", initial = ensureState("auraEnable", true) == true },
                      { label = "aura style", kind = "dropdown", key = "auraStyle", options = { "electric", "embers", "frost" } },
                      { label = "aura intensity", kind = "slider", key = "auraIntensity", min = 0.25, max = 1, step = 0.05 },
                      { label = "movement trail", header = true },
                      { label = "enable", key = "moveTrail", initial = ensureState("moveTrail", false) == true },
                      { label = "trail length", kind = "slider", key = "moveTrailLifetime", min = 0.15, max = 0.8, step = 0.05 },
                      { label = "trail color", kind = "color", key = "colMoveTrail" },
                      { label = "", header = true },
                      { label = "colors", header = true },
                      { label = "visible",       kind = "color", key = "colVisible" },
                      { label = "behind wall",   kind = "color", key = "colHidden" },
                      { label = "teammates",     kind = "color", key = "colAlly" },
                      { label = "esp text",      kind = "color", key = "colText" },
                  } },
              } },
              { name = "hud", cols = {
                  { rows = {
                      { label = "watermark",  key = "hudWatermark", initial = ensureState("hudWatermark", true) == true },
                      { label = "keybinds",   key = "hudKeybinds",  initial = ensureState("hudKeybinds", true)  == true },
                      { label = "spectators", key = "hudSpecs",     initial = ensureState("hudSpecs", true)     == true },
                      { label = "hitlog",     key = "hudHitlog",    initial = ensureState("hudHitlog", true)    == true },
                      { label = "bullet tracers", key = "hudTracers", initial = ensureState("hudTracers", true) == true },
                      { label = "hit markers", header = true },
                      { label = "enable", key = "hudHitMarker", initial = ensureState("hudHitMarker", false) == true },
                      { label = "hit sounds", key = "hudHitSound", initial = ensureState("hudHitSound", false) == true },
                      { label = "body color", kind = "color", key = "colHitBody" },
                      { label = "head color", kind = "color", key = "colHitHead" },
                  } },
                  { rows = {
                      { label = "screen effects", header = true },
                      { label = "menu snowfall", key = "hudSnow", initial = ensureState("hudSnow", true) == true },
                      { label = "spinning crosshair", key = "hudSpinCrosshair", initial = ensureState("hudSpinCrosshair", true) == true },
                      { label = "scope lines / no zoom", key = "hudScopeLines", initial = ensureState("hudScopeLines", true) == true },
                      { label = "remove scoping", key = "hudRemoveScope", initial = ensureState("hudRemoveScope", true) == true },
                      { label = "hide game crosshair", key = "hudHideGameCrosshair", initial = ensureState("hudHideGameCrosshair", true) == true },
                      { label = "spin speed", kind = "slider", key = "hudCrosshairSpeed", min = 30, max = 360, step = 15 },
                      { label = "under-crosshair info", key = "hudCrosshairInfo", initial = ensureState("hudCrosshairInfo", false) == true },
                      { label = "info content", kind = "dropdown", key = "hudCrosshairMode", options = { "both", "target", "movement" } },
                      { label = "grenade helper", header = true },
                      { label = "trajectory preview", key = "grenadePreview", initial = ensureState("grenadePreview", false) == true },
                      { label = "throw speed", kind = "slider", key = "grenadeThrowSpeed", min = 50, max = 180, step = 5 },
                      { label = "arc and landing are estimates", header = true, dim = true },
                  } },
              } },
              { name = "effects", cols = {
                  { rows = {
                      { label = "visual pack", key = "fxEnable", initial = false },
                      { label = "enable full pack", kind = "button", onClick = function()
                          State.fxEnable, State.fxHalo, State.fxOrbits = true, true, true
                          State.fxTargetRing, State.fxImpacts = true, true
                          State.fxTracers, State.fxHitMarkers = true, true
                          renderBody()
                      end },
                      { label = "halo", key = "fxHalo", initial = false },
                      { label = "orbit trails", key = "fxOrbits", initial = false },
                      { label = "target ring", key = "fxTargetRing", initial = false },
                      { label = "shot impact rings", key = "fxImpacts", initial = false },
                      { label = "colored tracers", key = "fxTracers", initial = false },
                      { label = "colored hit markers", key = "fxHitMarkers", initial = false },
                      { label = "animation speed", kind = "slider", key = "fxSpeed", min = 0.25, max = 3, step = 0.25 },
                      { label = "orbit radius", kind = "slider", key = "fxRadius", min = 1, max = 5, step = 0.25 },
                      { label = "rainbow colors", key = "fxRainbow", initial = false },
                      { label = "primary color", kind = "color", key = "colFxPrimary" },
                      { label = "secondary color", kind = "color", key = "colFxSecondary" },
                  } },
              } },
              { name = "world", cols = {
                  { rows = {
                      { label = "lighting",      header = true },
                      { label = "fullbright",    key = "worldFullbright", initial = ensureState("worldFullbright", false) == true },
                      { label = "no fog",        key = "worldNoFog",      initial = ensureState("worldNoFog", false) == true },
                      { label = "remove smoke",  key = "worldNoSmoke",    initial = ensureState("worldNoSmoke", false) == true },
                      { label = "custom time",   key = "worldTime",       initial = ensureState("worldTime", false) == true },
                      { label = "time of day", kind = "slider", key = "worldClock", min = 0, max = 24, step = 0.5 },
                      { label = "custom ambient", key = "worldAmbient",   initial = ensureState("worldAmbient", false) == true },
                      { label = "ambient color", kind = "color", key = "colAmbient" },
                  } },
                  { rows = {
                      { label = "third person",  header = true },
                      { label = "enable",        key = "tpEnable",        initial = ensureState("tpEnable", false) == true },
                      { label = "toggle key", kind = "keybind", key = "tpKey" },
                      { label = "distance", kind = "slider", key = "tpDistance", min = 3, max = 20, step = 0.5 },
                      { label = "height",   kind = "slider", key = "tpHeight",   min = 0, max = 5,  step = 0.5 },
                      { label = "side",     kind = "slider", key = "tpSide",     min = -3, max = 3, step = 0.5 },
                  } },
                  { title = "Neon look", rows = {
                      { label = "violet sky / cyan world", key = "worldNeon", initial = ensureState("worldNeon", true) == true },
                      { label = "strength", kind = "slider", key = "worldNeonStrength", min = 0, max = 1, step = 0.05 },
                      { label = "sky color", kind = "color", key = "colNeonSky" },
                      { label = "world color", kind = "color", key = "colNeonWorld" },
                  } },
              } },
          } },
        { icon = "•", label = "movement",
          subs = {
              { name = "movement", cols = {
                  { rows = {
                      { label = "bhop / strafe",  header = true },
                      { label = "auto bhop",      key = "moveBhop",   initial = ensureState("moveBhop", false) == true },
                      { label = "rage WASD movement", key = "moveStrafe", initial = ensureState("moveStrafe", false) == true },
                      { label = "view-angle bhop (hold W)", key = "moveViewBhop", initial = ensureState("moveViewBhop", true) == true },
                      { label = "direct air boost", key = "moveAirBoost", initial = ensureState("moveAirBoost", true) == true },
                      { label = "bhop speed", kind = "slider", key = "moveBhopSpeed", min = 60, max = 240, step = 5 },
                      { label = "air speed", kind = "slider", key = "moveAirSpeed", min = 30, max = 180, step = 5 },
                      { label = "auto peek", header = true },
                      { label = "enable", key = "moveAutoPeek", initial = ensureState("moveAutoPeek", false) == true },
                      { label = "hold key", kind = "keybind", key = "moveAutoPeekKey" },
                      { label = "return speed", kind = "slider", key = "moveAutoPeekSpeed", min = 40, max = 180, step = 5 },
                      { label = "hold to mark · shoot to return", header = true, dim = true },
                  } },
              } },
          } },
        { icon = "•", label = "config",
          subs = {
              { name = "config", cols = {
                  { rows = {
                      { label = "default slot", header = true },
                      { label = "save default", kind = "button", onClick = function()
                          local ok, err = Shared.saveConfig("default")
                          if not ok then warn("[bs] save failed:", err) end
                      end },
                      { label = "load default", kind = "button", onClick = function()
                          local ok, err = Shared.loadConfig("default")
                          if not ok then warn("[bs] load failed:", err) end
                          if Root and Root.Visible then renderBody() end
                      end },
                  } },
                  { rows = {
                      { label = "extra slots", header = true },
                      { label = "save slot 2", kind = "button", onClick = function()
                          Shared.saveConfig("slot2")
                      end },
                      { label = "load slot 2", kind = "button", onClick = function()
                          Shared.loadConfig("slot2")
                          if Root and Root.Visible then renderBody() end
                      end },
                      { label = "save slot 3", kind = "button", onClick = function()
                          Shared.saveConfig("slot3")
                      end },
                      { label = "load slot 3", kind = "button", onClick = function()
                          Shared.loadConfig("slot3")
                          if Root and Root.Visible then renderBody() end
                      end },
                  } },
              } },
              { name = "auto buy", cols = {
                  { title = "Loadout", rows = {
                      { label = "buy each round", key = "autoBuyEnable", initial = ensureState("autoBuyEnable", false) == true },
                      { label = "slot", kind = "dropdown", key = "autoBuySlot", options = { "1", "2", "3" },
                        onChange = function()
                            Shared.autoBuySetSlot()
                            if Root and Root.Visible then renderBody() end
                        end },
                      { label = "primary gun", kind = "dropdown", key = "_autoBuyPrimaryChoice",
                        options = Shared.autoBuyPrimaryOptions,
                        onChange = function(name) Shared.autoBuyChoose("Primary", name) end },
                      { label = "pistol", kind = "dropdown", key = "_autoBuySecondaryChoice",
                        options = Shared.autoBuySecondaryOptions,
                        onChange = function(name) Shared.autoBuyChoose("Secondary", name) end },
                      { label = "refresh guns", kind = "button", status = Shared.autoBuyStatus,
                        onClick = function()
                            local found = Shared.autoBuyRefresh()
                            if Root and Root.Visible then renderBody() end
                            return found
                        end },
                      { label = "buy now", kind = "button", status = Shared.autoBuyStatus,
                        onClick = Shared.autoBuyNow },
                      { label = "server checks cash and buy time", header = true, dim = true },
                  } },
                  { title = "Extra items", rows = {
                      { label = "record extra items", kind = "button", status = Shared.autoBuyStatus,
                        onClick = Shared.autoBuyRecordStart },
                      { label = "buy items in the normal B menu", header = true, dim = true },
                      { label = "stop and save", kind = "button", status = Shared.autoBuyStatus,
                        onClick = Shared.autoBuyRecordStop },
                      { label = "clear selected slot", kind = "button", status = Shared.autoBuyStatus,
                        onClick = Shared.autoBuyClear },
                      { label = "up to six purchases per slot", header = true, dim = true },
                  } },
              } },
          } },
    }

    do
        local byKey = {}
        for _, tab in ipairs(Tabs) do
            for _, sub in ipairs(tab.subs) do
                for _, col in ipairs(sub.cols) do
                    for _, row in ipairs(col.rows) do
                        if row.key then byKey[row.key] = row end
                    end
                end
            end
        end
        local function rows(keys)
            local result = {}
            for _, key in ipairs(keys) do
                local row = byKey[key]
                if row then result[#result + 1] = row end
            end
            return result
        end
        local function page(name, columns)
            return { name = name, cols = columns }
        end
        local function card(title, keys)
            return { title = title, rows = rows(keys) }
        end

        local targets = Tabs[1].subs[2]
        local antiAim = Tabs[1].subs[3]
        Tabs[1].subs = {
            page("aimbot", {
                card("Aim", { "rageEnable", "rageSilent", "rageAutoFire", "rageNoSpread", "rageNoRecoil" }),
                card("Target selection", { "rageHitbox", "ragePriority", "rageMpAll", "rageMpAuto", "rageMpScale", "rageFov", "rageMaxDist", "rageBacktrack", "rageBacktrackMs" }),
                card("Resolver", { "rageResolver", "rageResolverMisses" }),
                card("Aim binds", { "rageKeyEnable", "rageKeySilent", "rageKeyAutoFire" }),
            }),
            targets,
            page("fire & ammo", {
                card("Shot path", { "rageAutowall", "rageInfPen", "rageRapidFire", "rageRapidRate", "rageKeyRapidFire" }),
                card("Ammo", { "rageInfiniteAmmo", "rageInfReserve", "rageFastReload" }),
                card("Shot feedback", { "rageShotLog" }),
            }),
            antiAim,
        }

        Tabs[2].subs = {
            page("esp", {
                card("Players", { "visualsEnable", "visualsTeamCheck", "espHideWhenDead", "backtrackVisual" }),
                card("ESP details", { "espName", "espHealth", "espWeapon", "espPing", "espDistance", "espBox", "espSkeleton" }),
                card("ESP colors", { "colVisible", "colHidden", "colAlly", "colText" }),
            }),
            page("chams", {
                card("Models", { "chamsEnable", "chamsThroughWalls", "chamsEnemy", "chamsTeammates", "chamsSelf", "chamsWeapon", "chamsStyle", "chamsFillOpacity", "chamsOutlineOpacity" }),
                card("Desync pose", { "desyncGhost", "desyncGhostOpacity", "desyncGhostOffset", "colDesyncGhost" }),
                card("Animation", { "chamsAnimation", "chamsAnimationMode", "chamsAnimationSpeed", "chamsAnimationStrength", "colChamAnimation" }),
                card("Cham colors", { "colChamVisible", "colChamHidden", "colChamTeammate", "colChamSelf", "colChamWeapon", "colChamStale", "colChamOutline" }),
            }),
            page("self / weapon", {
                card("Weapon finish", { "weaponMaterial", "weaponMaterialThirdPerson", "weaponMaterialTint", "weaponMaterialHideTextures", "weaponChamFillOpacity" }),
                card("Aura", { "auraEnable", "auraStyle", "auraIntensity" }),
                card("Movement trail", { "moveTrail", "moveTrailLifetime", "colMoveTrail" }),
            }),
            page("effects", {
                { title = "Visual pack", rows = {
                    byKey.fxEnable,
                    { label = "enable full pack", kind = "button", onClick = function()
                        State.fxEnable, State.fxHalo, State.fxOrbits = true, true, true
                        State.fxTargetRing, State.fxImpacts = true, true
                        State.fxTracers, State.fxHitMarkers = true, true
                        renderBody()
                    end },
                    byKey.fxRainbow, byKey.colFxPrimary, byKey.colFxSecondary,
                } },
                card("Character effects", { "fxHalo", "fxOrbits", "fxSpeed", "fxRadius" }),
                card("Combat effects", { "fxTargetRing", "fxImpacts", "fxTracers", "fxHitMarkers" }),
            }),
            page("hud", {
                card("Indicators", { "hudWatermark", "hudKeybinds", "hudSpecs" }),
                card("Shots", { "hudHitlog", "hudTracers", "hudHitMarker", "hudHitSound", "colHitBody", "colHitHead" }),
                card("Menu", { "hudSnow" }),
            }),
            page("view", {
                card("Crosshair & scope", { "hudSpinCrosshair", "hudCrosshairSpeed", "hudHideGameCrosshair", "hudRemoveScope", "hudScopeLines", "hudCrosshairInfo", "hudCrosshairMode" }),
                card("Third person", { "tpEnable", "tpKey", "tpDistance", "tpHeight", "tpSide" }),
            }),
            page("world", {
                card("Lighting", { "worldFullbright", "worldNoFog", "worldNoSmoke", "worldTime", "worldClock", "worldAmbient", "colAmbient" }),
                card("Neon look", { "worldNeon", "worldNeonStrength", "colNeonSky", "colNeonWorld" }),
                card("Scene tint", { "chamsSceneTint", "chamsTintStrength", "colChamTint" }),
            }),
        }

        Tabs[3].subs = {
            page("movement", {
                card("Air movement", { "moveBhop", "moveStrafe", "moveViewBhop", "moveAirBoost", "moveBhopSpeed", "moveAirSpeed" }),
                card("Quick peek", { "moveAutoPeek", "moveAutoPeekKey", "moveAutoPeekSpeed" }),
            }),
        }

        local configPage = Tabs[4].subs[1]
        local buyPage = Tabs[4].subs[2]
        Tabs[4].subs = { configPage }
        Tabs[5] = { icon = "•", label = "utility", subs = {
            page("grenades", {
                card("Trajectory", { "grenadePreview", "grenadeThrowSpeed" }),
            }),
            buyPage,
        } }
    end

    local activeTab = 2
    local activeSub = 1
    local searchQuery = ""

    local sidebarButtons, pillButtons = {}, {}

    local function clearChildren(f)
        for _, c in ipairs(f:GetChildren()) do
            if not (c:IsA("UIListLayout") or c:IsA("UIPadding") or c:IsA("UICorner") or c:IsA("UIStroke")) then
                c:Destroy()
            end
        end
    end

    renderBody = function()
        clearChildren(Body)
        local sub = Tabs[activeTab].subs[activeSub]
        if not sub then return end
        if sub.dynamicTargets then
            local ids = focusTargetIds()
            local selected = { { label = "focus order (top first)", header = true } }
            local available = { { label = "players in server", header = true } }
            local players = Players:GetPlayers()
            local byId, selectedIds = {}, {}
            for _, player in ipairs(players) do byId[player.UserId] = player end
            for rank, id in ipairs(ids) do
                selectedIds[id] = true
                local player = byId[id]
                local label = player and ("#%d  @%s  ·  remove"):format(rank, player.Name)
                    or ("#%d  offline #%d  ·  remove"):format(rank, id)
                selected[#selected + 1] = { label = label, kind = "button", onClick = function()
                    local nextIds = focusTargetIds()
                    for index, savedId in ipairs(nextIds) do
                        if savedId == id then table.remove(nextIds, index); break end
                    end
                    saveFocusTargetIds(nextIds)
                    renderBody()
                end }
            end
            if #ids == 0 then
                selected[#selected + 1] = { label = "empty: normal enemy targeting", header = true }
            else
                selected[#selected + 1] = { label = "listed enemies first, then others", header = true }
                selected[#selected + 1] = { label = "clear target list", kind = "button", onClick = function()
                    saveFocusTargetIds({})
                    renderBody()
                end }
            end
            table.sort(players, function(a, b) return a.Name:lower() < b.Name:lower() end)
            local availableCount = 0
            for _, player in ipairs(players) do
                if player ~= LocalPlayer and not selectedIds[player.UserId] then
                    availableCount = availableCount + 1
                    local id, name = player.UserId, player.Name
                    available[#available + 1] = { label = "+  @" .. name, kind = "button", onClick = function()
                        local nextIds = focusTargetIds()
                        for _, savedId in ipairs(nextIds) do
                            if savedId == id then return end
                        end
                        nextIds[#nextIds + 1] = id
                        saveFocusTargetIds(nextIds)
                        renderBody()
                    end }
                end
            end
            if availableCount == 0 then
                available[#available + 1] = { label = "no other players to add", header = true }
            end
            sub.cols = {
                { title = "Focus order", rows = selected },
                { title = "Players in server", rows = available },
            }
        end
        local titles = { "General", "Options", "More" }
        local columnCount = #sub.cols > 3 and 2 or math.max(1, #sub.cols)
        local stacks = {}
        for columnIndex = 1, columnCount do
            stacks[columnIndex] = new("ScrollingFrame", {
                Size = UDim2.new(1 / columnCount, -14 * (columnCount - 1) / columnCount, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollingDirection = Enum.ScrollingDirection.Y,
                ScrollBarThickness = 3,
                ScrollBarImageColor3 = T.textMuted,
                VerticalScrollBarInset = Enum.ScrollBarInset.Always,
                LayoutOrder = columnIndex,
                Parent = Body,
            }, { pad(2), vlist(14) })
            stacks[columnIndex]:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
                if activeDropdown then
                    activeDropdown.Visible = false
                    activeDropdown = nil
                end
            end)
        end
        for columnIndex, colDef in ipairs(sub.cols) do
            local stack = stacks[(columnIndex - 1) % columnCount + 1]
            for _, cardDef in ipairs(colDef.cards or { colDef }) do
                local rows = {}
                for _, rowDef in ipairs(cardDef.rows) do
                    if searchQuery == "" or rowDef.label:lower():find(searchQuery, 1, true) then
                        rows[#rows + 1] = rowDef
                    end
                end
                if searchQuery == "" or #rows > 0 then
                    local height = 48
                    for _, rowDef in ipairs(rows) do
                        if rowDef.label == "" then height = height + 6
                        elseif rowDef.kind == "slider" then height = height + 54
                        elseif rowDef.kind == "dropdown" then height = height + 62
                        elseif rowDef.kind == "keybind" then height = height + 47
                        elseif rowDef.kind == "button" then height = height + (rowDef.status and 49 or 29)
                        elseif rowDef.kind == "color" then height = height + 32
                        elseif rowDef.header then height = height + 31
                        else height = height + 25 end
                    end
                    height = height + math.max(0, #rows - 1) * 2
                    local minimum = searchQuery == "" and (cardDef.minHeight or 0) or 0
                    local col = makeColumn(stack, cardDef.title or colDef.title or titles[columnIndex],
                        math.max(height, minimum, 92))
                    for i, rowDef in ipairs(rows) do
                        rowDef._order = i
                        if rowDef.label == "" then
                            new("Frame", {
                                Size = UDim2.new(1, 0, 0, 6),
                                BackgroundTransparency = 1,
                                LayoutOrder = i,
                                Parent = col,
                            })
                        elseif rowDef.kind == "slider" then
                            makeSliderRow(col, rowDef)
                        elseif rowDef.kind == "dropdown" then
                            makeDropdownRow(col, rowDef)
                        elseif rowDef.kind == "color" then
                            makeColorRow(col, rowDef)
                        elseif rowDef.kind == "keybind" then
                            makeKeybindRow(col, rowDef)
                        elseif rowDef.kind == "button" then
                            makeButtonRow(col, rowDef)
                        else
                            makeCheckRow(col, rowDef)
                        end
                    end
                end
            end
        end
    end
    local searchConn = SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        searchQuery = SearchBox.Text:lower():match("^%s*(.-)%s*$") or ""
        renderBody()
    end)
    _G.__bs_add_teardown(function() searchConn:Disconnect() end)

    local function renderPills()
        clearChildren(PillRow)
        pillButtons = {}
        for i, sub in ipairs(Tabs[activeTab].subs) do
            local isActive = i == activeSub
            local visualNames = { esp = "ESP", hud = "HUD" }
            local displayName = activeTab == 2 and (visualNames[sub.name] or sub.name) or sub.name
            local btn = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 37),
                BackgroundColor3 = isActive and T.bgRowActive or T.bgSidebar,
                BackgroundTransparency = isActive and 0 or 1,
                BorderSizePixel = 0,
                Font = T.fontMedium,
                Text = "   " .. displayName,
                TextColor3 = isActive and T.text or T.textMuted,
                TextSize = T.textSize,
                TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = false,
                LayoutOrder = i,
                Parent = PillRow,
            })
            if isActive then
                new("Frame", {
                    Size = UDim2.new(0, 2, 1, 0),
                    BackgroundColor3 = T.accent,
                    BorderSizePixel = 0,
                    Parent = btn,
                })
            end
            pillButtons[i] = btn
            btn.MouseButton1Click:Connect(function()
                activeSub = i
                renderPills()
                renderBody()
            end)
        end
    end

    local function renderSidebar()
        clearChildren(TabList)
        sidebarButtons = {}
        local initials = { rage = "◎", visuals = "◐", movement = "➤", config = "⚙", utility = "U" }
        for i, tab in ipairs(Tabs) do
            local isActive = i == activeTab
            local row = new("Frame", {
                Size = UDim2.fromOffset(128, 55),
                BackgroundColor3 = isActive and T.bgRowActive or T.bgSidebar,
                BackgroundTransparency = isActive and 0 or 1,
                BorderSizePixel = 0,
                LayoutOrder = i,
                Parent = TabList,
            }, { corner(UDim.new(0, 8)) })
            new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 30),
                Position = UDim2.fromOffset(0, 1),
                BackgroundTransparency = 1,
                Font = T.fontMedium,
                Text = initials[tab.label] or "·",
                TextColor3 = isActive and T.text or T.textMuted,
                TextSize = 22,
                Parent = row,
            })
            new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 17),
                Position = UDim2.fromOffset(0, 33),
                BackgroundTransparency = 1,
                Font = T.fontRegular,
                Text = tab.label,
                TextColor3 = isActive and T.text or T.textMuted,
                TextSize = 11,
                Parent = row,
            })

            local btn = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                Parent = row,
            })
            sidebarButtons[i] = btn
            btn.MouseButton1Click:Connect(function()
                activeTab = i
                activeSub = 1
                SearchBox.Text = ""
                renderSidebar()
                renderPills()
                renderBody()
            end)
        end
    end

    renderSidebar()
    renderPills()
    renderBody()

    local function refreshTargetList()
        if Root.Visible and activeTab == 1 and activeSub == 2 then
            renderBody()
        end
    end
    local joinedConn = Players.PlayerAdded:Connect(refreshTargetList)
    local leftConn = Players.PlayerRemoving:Connect(function()
        task.defer(refreshTargetList)
    end)
    _G.__bs_add_teardown(function()
        joinedConn:Disconnect()
        leftConn:Disconnect()
    end)

    do
        local dragging, startInput, startPos
        TopBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                Root:SetAttribute("Dragged", true)
                startInput = input.Position
                startPos = Root.Position
            end
        end)
        -- Disconnect UIS handlers on reload to avoid stacking listeners.
        local moveConn = UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local d = (input.Position - startInput) / uiScale.Scale
                Root.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y
                )
            end
        end)
        local endConn = UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end)
        _G.__bs_add_teardown(function()
            moveConn:Disconnect()
            endConn:Disconnect()
        end)
    end

    -- RightShift is consumed by Blowstrike, so this toggle ignores gpe.
    local BINDS = {
        { key = "tpKey",            target = "tpEnable" },
        { key = "rageKeyEnable",    target = "rageEnable" },
        { key = "rageKeySilent",    target = "rageSilent" },
        { key = "rageKeyAutoFire",  target = "rageAutoFire" },
        { key = "rageKeyRapidFire", target = "rageRapidFire" },
        { key = "antiAimKey",       target = "antiAimEnable" },
    }
    local toggleConn = UserInputService.InputBegan:Connect(function(input)
        if State._bindListening then return end  -- this press is being bound
        if UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.RightShift then
            Root.Visible = not Root.Visible
            -- Rows read State on build; rebuild so key toggles show correctly.
            if Root.Visible then renderBody() end
            return
        end
        for _, b in ipairs(BINDS) do
            local k = State[b.key]
            if typeof(k) == "EnumItem" and k ~= Enum.KeyCode.Unknown and input.KeyCode == k then
                State[b.target] = not State[b.target]
                break
            end
        end
    end)
    _G.__bs_add_teardown(function() toggleConn:Disconnect() end)

    -- CameraController's force-lock override frees the mouse while the menu is open.
    local okCCM, CCM = pcall(require, ReplicatedStorage.Controllers.CameraController)
    local KEY = "aether"
    local function setForceLock(on)
        if okCCM and CCM and type(CCM.setForceLockOverride) == "function" then
            pcall(CCM.setForceLockOverride, KEY, on)
        else
            -- Without the override API, apply mouse state on menu changes.
            if on then
                UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                UserInputService.MouseIconEnabled = true
            end
        end
    end
    local mouseState = false
    local function syncMouse()
        local want = Root.Visible == true
        State._menuOpen = want
        if want ~= mouseState then
            mouseState = want
            setForceLock(want)
        end
    end
    syncMouse()
    local mouseWatch = Root:GetPropertyChangedSignal("Visible"):Connect(syncMouse)
    _G.__bs_add_teardown(function()
        mouseWatch:Disconnect()
        State._menuOpen = false
        setForceLock(false)
    end)

    print("[aether] menu built. Root.Visible =", Root.Visible, "Parent =",
        Root.Parent and Root.Parent.Name)
end

local loadingTimeLeft = 1.2 - (os.clock() - loadingStartedAt)
if loadingTimeLeft > 0 then task.wait(loadingTimeLeft) end
finishLoadingScreen()
print(("[bs] loaded — all features off; game modules: %s. RightShift opens the menu."):format(
    _bsGameLoaded and "available" or "unavailable (menu preview mode)"))
return State
