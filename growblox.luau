

local E = getgenv()
local previousResults = E.GrowbloxHub and E.GrowbloxHub.State.results or {}
local previousProgress = E.GrowbloxHub and E.GrowbloxHub.State.progress
local previousMovement = E.GrowbloxHub and E.GrowbloxHub.State.movement
local previousLoot = E.GrowbloxHub and E.GrowbloxHub.State.loot
local previousRecorder = E.GrowbloxHub and E.GrowbloxHub.State.recorder
if previousProgress and previousProgress.movementMode ~= "native-input" then previousProgress = nil end
do
    local seen, retired, errors = {}, {}, {}
    local function attempt(fn)
        local ok, err = pcall(fn)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    local function retire(api)
        if type(api) ~= "table" or seen[api] or type(api.State) ~= "table" then return end
        local state = api.State
        if not state.farm or not state.utilities or not state.movement then return end
        seen[api] = true
        retired[#retired + 1] = state
        state.live, state.running, state.busy = false, false, false
        state.generation = (state.generation or 0) + 1
        for _, name in {"farm", "dirt", "specialDirt"} do
            if state[name] then state[name].running = false end
        end
        if state.movement.keys then
            for key in state.movement.keys do state.movement.keys[key] = false end
        end
        for _, name in {"worker", "farmUiTask", "inputPump", "uiWorker", "utilityWorker"} do
            local thread = state[name]
            if thread and thread ~= coroutine.running() then attempt(function() task.cancel(thread) end) end
        end
        if type(api.Unload) == "function" then task.spawn(function() attempt(api.Unload) end) end
        if type(api.SetUltraFPS) == "function" then task.spawn(function() attempt(function() api.SetUltraFPS(false) end) end) end
        for _, connection in state.connections or {} do attempt(function() connection:Disconnect() end) end
        for _, hook in state.utilities.hooks or {} do attempt(function()
            local list = hook.packet.getListeners()
            local index = table.find(list, hook.callback)
            if index then table.remove(list, index) end
        end) end
        local privacy = state.privacy
        if privacy then
            privacy.active = false
            privacy.epoch = (privacy.epoch or 0) + 1
            for _, connection in privacy.connections or {} do attempt(function() connection:Disconnect() end) end
        end
        local library = state.library
        if library then
            for _, connection in library.Signals or {} do attempt(function() connection:Disconnect() end) end
            if library.ScreenGui then attempt(function() library.ScreenGui:Destroy() end) end
        end
    end
    retire(E.GrowbloxHub)
    retire(E.BlizzardGrowbloxRuntime)
    if type(filtergc) == "function" then attempt(function()
        for _, api in filtergc("table", {Keys={"State", "Unload", "Snapshot", "SetUltraFPS"}}, false) do retire(api) end
    end) end
    for _ = 1, #retired do
        for _, state in retired do
            local u = state.privacy
            if u and u.bitmap and u.bitmap._layout == u.wrapper then u.bitmap._layout = u.originalLayout end
        end
    end
    attempt(function()
        local net = require(game:GetService("ReplicatedStorage").Shared.Net)
        local listeners = net.tileChanged.getListeners()
        for i = #listeners, 1, -1 do
            for _, upvalue in debug.getupvalues(listeners[i]) do
                if table.find(retired, upvalue) then table.remove(listeners, i); break end
            end
        end
    end)
    local roots, seenGui = {}, {}
    local function addRoot(root) if root then roots[#roots + 1] = root end end
    attempt(function() addRoot(game:GetService("CoreGui")) end)
    attempt(function() addRoot(game:GetService("Players").LocalPlayer.PlayerGui) end)
    if type(gethui) == "function" then attempt(function() addRoot(gethui()) end) end
    local removed = 0
    for _, root in roots do attempt(function()
        for _, gui in root:QueryDescendants("ScreenGui") do
            if not seenGui[gui] then
                seenGui[gui] = true
                local owned = gui:GetAttribute("FluffyHubOwner") == "Growblox"
                if not owned and gui.Name == "Obsidian" then
                    for _, label in gui:QueryDescendants("TextLabel") do
                        if label.Text == "Fluffy Hub" or label.Text == "Growblox | Witching Hour" then owned = true; break end
                    end
                end
                if owned then gui:Destroy(); removed += 1 end
            end
        end
    end) end
    E.BlizzardReloadReport = {retired=#retired, removedOrphanGuis=removed, errors=errors}
    E.BlizzardGrowbloxRuntime = nil
    if #retired > 0 then task.wait(0.05) end
end
local RS = game:GetService("ReplicatedStorage")
assert(game.PlaceId == 112863874972771, "Growblox client required")
local Net = require(RS.Shared.Net)
local DB = require(RS.Shared.ItemDB)
local Recipes = require(RS.Shared.Splice.Recipes)
local Splice = require(RS.Shared.Splice)
local S = {
    version = "1.0", live = true, running = false, busy = false,
    status = "Idle - preview before starting", results = previousResults, events = {},
    sent = 0, nativeCalls = 0, confirmed = 0, localCleared = 0, connections = {}, plan = nil, uiRequests = {},
    config = {interval = 0.24, limit = 0, radius = 2, background = true, autoPickup = true, onFull = "continue", pickupRadius = 2.2, pauseOnFocusLoss = false,
        verifyEvery = 20, alternative = "punch-burst"},
    privacy = {hideName = true, hideWorld = true, alias = "Fluffy Hub", revision = 0, active = false},
    utilities = {ultraFPS = false, leaveStaff = false, leaveCount = false, maxPeople = 3, present = {}, hooks = {}, fpsSaved = {}, fpsConnections = {}, leaving = false},
    farm = {running = false, config = {loot = false, item = 954, harvestMode = "Bertahap"},
        phase = "prepare", cursor = 1, message = "Preview before starting", manifest = {}, trees = {}, deferred = {},
        moves = 0, distance = 0, cycle = 0, placed = 0, broken = 0, planted = 0, harvested = 0,
        checkpointFile = "growblox-autofarm-v1.json", interval = 0.24},
    dirt = {running = false, phase = "Preview before starting", placed = 0, floors = 0,
        checkpointFile = "growblox-dirt-builder-checkpoint.json", config = {topY = 3, interval = 0.25, rowLimit = 0}},
    specialDirt = {running = false, phase = "Preview before starting", placedPlatforms = 0, placedDirt = 0, mined = 0, floors = 0,
        checkpointFile = "growblox-special-dirt-checkpoint.json", config = {interval = 0.24, placeInterval = 0.25, floorLimit = 0},
        cursor = nil, stats = {mined = 0, placedPlatforms = 0, placedDirt = 0, floors = 0}, plan = nil, stock = {}},
    mining = {effectiveInterval = 0.24, timeouts = 0, backoffs = 0},
    progress = nil, blocked = {}, engine = "spatial-corridor-v2",
    loot = previousLoot and previousLoot.job == game.JobId and previousLoot or {
        job = game.JobId, blocks = 0, seeds = 0, gems = 0, attempts = 0, denied = 0, fullItems = {}, retryAt = {}},
    movement = {mode = "native-input", validated = false, jumpValidated = false, keys = {},
        reason = "Previous goTo/hover engine caused flying kick; removed. Re-test normal input before Start."},

    natural = {[2] = true, [4] = true, [10] = true},
    research = {
        experimentsPaused = true,
        flyingKick = {reported = "moving in a way server not allow (flying)",
            removed = "goTo position writes and Heartbeat hover hold",
            replacement = "Normal A/D/Space input with gravity, grounded landings and no position writes",
            liveValidation = "Pending reconnection; Start is locked until calibration passes"},
        placeVersion = 1033, recipeCount = 804, itemCount = 11714,
        manualDemo = {world = "DEPOK2", row = 42, fromX = 99, toX = 0,
            turnRow = 43, turnX = 0, partialEndX = 3, cells = 104,
            medianImpactInterval = 0.2298178, normalInterval = 0.24,
            pattern = "foreground then background per cell; descend one at edge; reverse",
            implementedEngine = "manual-corridor-v1",
            botValidation = "Live 4x2 corridor test: 8 FG + 8 BG server-confirmed, 0 rejected; one descent/reversal, zero detours",
            liveTest = {x0 = 6, x1 = 9, y0 = 43, y1 = 44, elapsed = 16.3641847,
                foreground = 8, background = 8, serverCleared = 16, serverRejected = 0,
                corridorSteps = 8, turns = 1, detours = 0}},
        sugarCane = {block = 954, seed = 955, hits = 2, growSeconds = 8726,
            parents = {847, 581}},
        limitations = {"Client-visible analysis only; server source is not exposed",
            "Main Game and AreaLocks decompilation returned busy",
            "Farm and mass are planners, not implemented automation"},
        alternativeRun = {date = "2026-11-05", world = "DEPOK1",
            finding = "Power/dig clone, hit bursts, punch-start preludes and multi-target shortcuts did not persist on server",
            control = "Normal hits at 0.35 seconds removed Dirt at (26,40), verified by server snapshot",
            clientOnly = "A local 2-to-0 tile change is not success; rejected requests returned to 2"},
    },
}
local displayPrivacyText = function(text) return tostring(text or "") end
local UiText = {}
local API = {State = S, UIText = UiText}
E.GrowbloxHub = API
E.BlizzardGrowbloxRuntime = API
local executorIdentity = type(getthreadidentity) == "function" and getthreadidentity() or 8
local function restoreExecutorContext()

    if type(setthreadidentity) == "function" then setthreadidentity(executorIdentity) end
end
if previousMovement and previousMovement.mode == "native-input" and previousMovement.validated
    and previousMovement.jumpValidated and previousMovement.job == game.JobId then
    for _, k in {"validated", "jumpValidated", "maxJumpHeight", "world", "job"} do S.movement[k] = previousMovement[k] end
    S.movement.reason = "Normal input calibration reused in the same server"
end

local gameSource = "Players." .. game.Players.LocalPlayer.Name .. ".PlayerGui.GameGui.Game"
local world, nativeAct, hit, controls, controlsIndex, inventory
for _, f in Net.tileChanged.getListeners() do
    if debug.info(f, "s") == gameSource then
        for _, v in debug.getupvalues(f) do
            if type(v) == "table" and v.fg and v.bg and v.w and v.h then world = v end
        end
    end
end
assert(type(filtergc) == "function" and world, "Original game listener unavailable")
for _, f in filtergc("function", {Name = "act"}, false) do
    if debug.info(f, "s") == gameSource then
        local sameWorld, candidateHit = false, nil
        for _, v in debug.getupvalues(f) do
            if v == world then sameWorld = true end
            if type(v) == "function" and debug.info(v, "n") == "hit" then candidateHit = v end
        end
        if sameWorld and candidateHit then nativeAct, hit = f, candidateHit; break end
    end
end
assert(nativeAct and hit, "Original action/hit binding unavailable")
for _, v in debug.getupvalues(nativeAct) do
    if type(v) == "table" and v.slots and v.capacity and v.changed then inventory = v end
end
for i, v in debug.getupvalues(hit) do
    if type(v) == "table" then
        if v.fg and v.bg and v.w and v.h then world = v end
        if type(v.punchRange) == "function" and type(v.handPower) == "function" then controls, controlsIndex = v, i end
    end
end
assert(world and controls and world.goTo, "Runtime layout changed; refusing to send")
if previousProgress and previousProgress.engine == S.engine and previousProgress.world == world.name
    and previousProgress.job == game.JobId then S.progress = previousProgress end
if previousRecorder and not previousRecorder.active and previousRecorder.world == world.name and previousRecorder.job == game.JobId then
    S.recorder = previousRecorder
end
local nativeSetTile
for _, f in debug.getupvalues(nativeAct) do
    if type(f)=="function" and debug.info(f,"n")=="setTile" then nativeSetTile=f;break end
end
local function position()

    local x, y = debug.getupvalue(world.goTo, 1), debug.getupvalue(world.goTo, 2)
    assert(type(x) == "number" and type(y) == "number", "Position unavailable")
    return x, y
end
local function tile(layer, x, y)
    local grid = layer == 0 and world.fg or world.bg
    return grid[y] and grid[y][x]
end
local function accessible(x, y)
    local ok, allowed = pcall(world.areas.mayBuild, world.lock, x, y)
    return ok and allowed == true
end
local function eligible(layer, x, y)
    local id = tile(layer, x, y)
    local d = id and DB[id]
    if not d or not d.hits or d.hits <= 0 then return false end
    if layer == 0 then return S.natural[id] == true and accessible(x, y) end
    return id == 14 and tile(0, x, y) == 0 and accessible(x, y)
end
local function inRange(x, y)
    local px, py = position()
    local reach = math.min(controls.punchRange(), 2.5)
    return math.abs(x + 0.5 - px) <= reach and math.abs(y + 0.5 - py) <= reach
end
local function key(layer, x, y) return layer .. ":" .. x .. ":" .. y end
function UiText.line(value, fallback)
    local text = tostring(value or ""):match("^[^\r\n]+") or ""
    text = text:gsub("^.-:%d+:%s*", "")
    return text ~= "" and text:sub(1, 140) or (fallback or "None")
end
function UiText.panel(action, err)
    return "Action: " .. UiText.line(action, "Idle") .. "\nError: " .. UiText.line(err, "None")
end
function UiText.harvestLabel(value)
    return value == "Tunggu Semua Matang" and "Wait Until All Mature" or "As Ready"
end
function UiText.harvestValue(value)
    if value == "Wait Until All Mature" or value == "Tunggu Semua Matang" then return "Tunggu Semua Matang" end
    if value == "As Ready" or value == "Bertahap" then return "Bertahap" end
    error("Invalid harvest mode")
end
function UiText.farmAction(f)
    if f.needsAttention then return "Waiting" end
    if not f.running then return (f.pending or next(f.trees or {}) or #(f.manifest or {}) > 0) and "Paused" or "Idle" end
    return ({prepare="Scanning", materials="Waiting for items", place="Placing", ["break"]="Breaking",
        loot="Collecting", plant="Planting", wait="Growing", harvest="Harvesting"})[f.phase] or "Working"
end
function API.UIStatusText()
    local p = S.progress
    local action = "Idle"
    if S.specialDirt.running then action = "Building tunnels"
    elseif S.running and not S.farm.running and not S.dirt.running then
        action = ({["mine-corridor"]="Breaking", ["obstacle-detour"]="Routing", ["walk"]="Walking"})[p and p.phase] or "Clearing"
    elseif p and p.complete then action = "Complete"
    elseif p and not p.complete then action = "Paused" end
    local err = S.specialDirt.error or S.clearUIError or (p and (p.error or p.lastError))
    return UiText.panel(action, err)
end
local function status(message)
    S.status = message
    if S.label then pcall(function() S.label:SetText(displayPrivacyText(API.UIStatusText())) end) end
end

local function changed(p)
    if not S.live or p.w ~= Net.worldTag(world.name or "") then return end

    if p.layer ~= 1 and p.layer ~= 2 then return end
    S.events[key(p.layer - 1, p.x, p.y)] = {id = p.id, at = os.clock(), world = world.name}
end
Net.tileChanged.listen(changed)
local inputService = game:GetService("UserInputService")
local virtualInput = game:GetService("VirtualInputManager")

local sentKeys, lastSentAt = {}, {}
local function inputKey(key, down)
    assert(not S.inputError, S.inputError)
    S.movement.keys[key] = down == true
end
local function releaseMovement()
    for _, key in {Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Space} do S.movement.keys[key] = false end
end
task.spawn(function()
    restoreExecutorContext()
    while S.live do
        for _, key in {Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Space} do
            local desired = S.movement.keys[key] == true
            if sentKeys[key] ~= desired or (desired and os.clock() - (lastSentAt[key] or 0) > 0.12) then
                local ok, err = pcall(function() virtualInput:SendKeyEvent(desired, key, false, game) end)
                if ok then sentKeys[key], lastSentAt[key] = desired, os.clock() else S.inputError = "Native input pump: " .. tostring(err) end
            end
        end
        task.wait(0.015)
    end
    for _, key in {Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Space} do
        pcall(function() virtualInput:SendKeyEvent(false, key, false, game) end)
    end
end)
local function requestToggle(key,value)
    S.uiRequests[key] = value == true
end
local function syncClearToggle(value) requestToggle("clear",value) end

local function flushToggleRequests()
    for key,value in S.uiRequests do
        local field,flag
        if key=="clear" then field,flag="clearToggle","changingClearToggle"
        elseif key=="dirt" then field,flag="dirtToggle","changingDirtToggle"
        elseif key=="specialDirt" then field,flag="specialDirtToggle","changingSpecialDirtToggle"
        elseif key=="farm" and not (S.farmUiStarting and value==false) then field,flag="farmToggle","changingFarmToggle" end
        local control=field and S[field]
        if control then
            S[flag]=true
            local ok,err=pcall(function() control:SetValue(value) end)
            S[flag]=false
            if ok and S.uiRequests[key]==value then S.uiRequests[key]=nil
            elseif not ok then S.lastUIUpdateError=tostring(err) end
        end
    end
end
function API.Stop(reason)
    if S.farmUiTask and S.farmUiTask ~= coroutine.running() then
        pcall(task.cancel, S.farmUiTask)
        S.farmUiTask, S.farmUiStarting = nil, false
        S.farmUiEpoch = (S.farmUiEpoch or 0) + 1
    end
    S.farm.running = false
    S.farm.testSlotLimit=nil
    if API.SaveAutoFarmCheckpoint then API.SaveAutoFarmCheckpoint() end
    requestToggle("farm",false)
    if S.dirt.running and not (type(reason)=="string" and reason:sub(1,10)=="Dirt Farm:") then
        S.dirt.phase="Paused: "..(type(reason)=="string" and reason or "manual stop")
    end
    S.dirt.running = false
    if S.specialDirt.running and not (type(reason)=="string" and reason:sub(1,13)=="Special Dirt:") then
        S.specialDirt.phase = "Paused: " .. (type(reason)=="string" and reason or "manual stop")
    end
    S.specialDirt.running = false
    if API.SaveDirtCheckpoint then API.SaveDirtCheckpoint() end
    if API.SaveSpecialDirtCheckpoint then API.SaveSpecialDirtCheckpoint() end
    requestToggle("dirt",false)
    requestToggle("specialDirt",false)
    if S.actionRestore then pcall(S.actionRestore); S.actionRestore = nil end
    S.cancelAutoStart = true
    S.lastStopReason = type(reason) == "string" and reason or "manual pause"
    S.lastStopAt = os.clock()
    S.running = false
    S.generation = (S.generation or 0) + 1
    releaseMovement()
    if S.worker and S.worker~=coroutine.running() then pcall(task.cancel, S.worker) end
    S.worker = nil
    S.busy = false
    if S.progress and not S.progress.complete then S.progress.state = "Paused"; S.progress.finishedAt = os.clock() end
    if API.SaveCheckpoint then API.SaveCheckpoint() end
    status("Stopped: " .. S.lastStopReason)
    syncClearToggle(false)
end
function API.Unload()
    if S.unloading then return end
    S.unloading = true
    S.live = false
    S.unloadErrors = {}
    local function clean(fn)
        local ok, err = pcall(fn)
        if not ok then S.unloadErrors[#S.unloadErrors + 1] = tostring(err) end
    end
    clean(function() API.Stop("script reload/unload") end)
    if API.StopRecording then clean(function() API.StopRecording("script unload") end) end
    if API.CleanupPrivacy then clean(API.CleanupPrivacy) end
    if API.CleanupUtilities then clean(API.CleanupUtilities) end
    clean(function()
        local list = Net.tileChanged.getListeners()
        local index = table.find(list, changed)
        if index then table.remove(list, index) end
    end)
    for _, connection in S.connections do clean(function() connection:Disconnect() end) end
    if S.library then
        clean(function() S.library:Unload() end)
        clean(function() if S.library.ScreenGui then S.library.ScreenGui:Destroy() end end)
    end
    if E.GrowbloxHub == API then E.GrowbloxHub = nil end
    if E.BlizzardGrowbloxRuntime == API then E.BlizzardGrowbloxRuntime = nil end
end
function API.Snapshot()
    local x, y = position()
    return {world = world.name, width = world.w, height = world.h, x = x, y = y,
        running = S.running, busy = S.busy, status = S.status,
        sent = S.sent, nativeCalls = S.nativeCalls, confirmed = S.confirmed, localCleared = S.localCleared, results = S.results,
        reach = controls.punchRange(), power = controls.handPower(), dig = controls.handDig(),
        progress = S.progress}
end

function API.VerifyServerWorld(confirmedName)
    assert(not S.running and not S.busy, "Stop work before requesting snapshot")
    assert(confirmedName == world.name, "Only the current world may be verified")
    S.serverRead = {pending = true, world = confirmedName}
    local ok, a, b = pcall(function()
        return RS.WorldRemotes.EnterWorld:InvokeServer(confirmedName)
    end)
    S.serverRead = {pending = false, ok = ok, a = a, b = b, world = confirmedName, at = os.clock()}
    if ok and a == true and type(b) == "table" and b.name == confirmedName and type(b.fg) == "string" then
        local codec = require(RS.Shared.WorldCodec)
        local grids = {[0] = codec.decode(b.fg, b.w, b.h), [1] = codec.decode(b.bg, b.w, b.h)}
        local confirmed = 0
        local latest = {}
        for _, r in S.results do
            if r.world == confirmedName then
                for _, t in r.targets do latest[t.layer .. ":" .. t.x .. ":" .. t.y] = t end
            end
        end
        for _, r in S.results do
            if r.world == confirmedName then
                for _, t in r.targets do
                    local grid = grids[t.layer]
                    t.serverAfter = grid[t.y] and grid[t.y][t.x]
                    t.superseded = latest[t.layer .. ":" .. t.x .. ":" .. t.y] ~= t
                    t.persistenceConfirmed = not t.superseded and r.protocol == "wire-layer-1-2" and t.serverAfter == 0
                    if t.persistenceConfirmed then confirmed += 1 end
                end
            end
        end
        S.confirmed = confirmed
        return true
    end
    return false
end
local function passable(id)
    if id == nil then return false end
    local d = DB[id or 0]
    return id == 0 or (d ~= nil and not d.solid and not d.hurts and (d.kind ~= "seed" or (S.farm and S.farm.running)))
end

local function bedrockComponent(x,y)
    if tile(0,x,y)~=8 then return nil end
    local nodes,seen,head={{x=x,y=y}},{[y*world.w+x]=true},1
    local result={minX=x,maxX=x,minY=y,maxY=y,size=0,touchesBottom=false}
    while head<=#nodes do
        local n=nodes[head];head+=1;result.size+=1
        result.minX=math.min(result.minX,n.x);result.maxX=math.max(result.maxX,n.x)
        result.minY=math.min(result.minY,n.y);result.maxY=math.max(result.maxY,n.y)
        if n.y==world.h-1 then result.touchesBottom=true end
        for _,d in {{-1,0},{1,0},{0,-1},{0,1}} do
            local nx,ny=n.x+d[1],n.y+d[2]
            local key=ny*world.w+nx
            if nx>=0 and nx<world.w and ny>=0 and ny<world.h and not seen[key] and tile(0,nx,ny)==8 then
                seen[key]=true;nodes[#nodes+1]={x=nx,y=ny}
            end
        end
    end
    result.kind=result.touchesBottom and "basal" or "local-obstacle"
    return result
end
API.BedrockInfo=bedrockComponent
local function canStand(x, y)
    if not (x >= 0 and x < world.w and y >= (S.farm.running and 0 or 1) and y < world.h and passable(tile(0, x, y))) then return false end

    if (S.farm and S.farm.running) or (S.dirt and S.dirt.running) then return true end
    if passable(tile(0, x, y - 1)) then return true end
    local u=S.clearUnderpassBounds
    if u and y==u.y and x>=u.x0 and x<=u.x1 then
        local roof=tile(0,x,y-1)
        local def=DB[roof or 0]

        return def~=nil and not def.hurts and (roof==8 or S.natural[roof]==true)
    end
    return false
end
local function canMineFrom(px, py, x, y)
    local dx, dy = x + 0.5 - px, y + 0.5 - py
    if dx * dx + dy * dy > math.min(controls.punchRange() - 0.1, 2.2)^2 then return false end

    local eye = py - 0.75
    local n = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(y + 0.5 - eye)) * 5))
    for i = 1, n do
        local cx = math.floor(px + dx * i / n)
        local cy = math.floor(eye + (y + 0.5 - eye) * i / n)
        if cx == x and cy == y then return true end
        if not passable(tile(0, cx, cy)) then return false end
    end
    return true
end
local function boundsValid(b)
    if type(b) ~= "table" then return false end
    for _, k in {"x0", "x1", "y0", "y1"} do
        if type(b[k]) ~= "number" or b[k] ~= math.floor(b[k]) then return false end
    end
    return b.x0 >= 0 and b.x1 < world.w and b.x0 <= b.x1 and b.y0 >= 1 and b.y1 < world.h and b.y0 <= b.y1
end
local function countRemaining(b, fg, bg)
    fg, bg = fg or world.fg, bg or world.bg
    local a = {foreground = 0, background = 0, protected = 0, protectedBackground = 0, hits = 0}
    local first = world.h
    for y = b.y0, b.y1 do
        for x = b.x0, b.x1 do
            local id = fg[y][x]
            if S.natural[id] and accessible(x, y) then
                a.foreground += 1; a.hits += DB[id].hits; first = math.min(first, y)
            elseif id ~= 0 then a.protected += 1 end
            if S.config.background and bg[y][x] == 14 and accessible(x, y) then
                if id == 0 or S.natural[id] then
                    a.background += 1; a.hits += DB[14].hits; first = math.min(first, y)
                else a.protectedBackground += 1 end
            end
        end
    end
    a.total, a.firstRow = a.foreground + a.background, first
    return a
end
function API.Preview(region)
    assert(not S.busy and not S.running, "Pause current work first")
    local b = region or {x0 = 0, x1 = world.w - 1, y0 = 1, y1 = world.h - 1}
    assert(boundsValid(b), "Invalid clear bounds")
    local c = countRemaining(b)
    if not region and c.firstRow < world.h then b.y0 = c.firstRow end
    S.plan = {world = world.name, bounds = b, counts = c, at = os.clock()}
    status(string.format("%s | FG %d + BG %d | snake L > R > down > L", world.name, c.foreground, c.background))
    return S.plan
end

local function checkpoint()
    local p = S.progress
    if not p or type(writefile) ~= "function" then return end
    local ok, err = pcall(function()
        writefile("growblox-clear-checkpoint.json", game:GetService("HttpService"):JSONEncode(p))
    end)
    p.checkpointOK, p.checkpointError = ok, not ok and tostring(err) or nil
end
API.SaveCheckpoint = checkpoint
function API.LoadCheckpoint()
    assert(not S.busy and not S.running, "Pause first")
    assert(type(readfile) == "function" and type(isfile) == "function" and isfile("growblox-clear-checkpoint.json"), "No saved checkpoint")
    local p = game:GetService("HttpService"):JSONDecode(readfile("growblox-clear-checkpoint.json"))
    assert(type(p) == "table" and p.world == world.name and p.job == game.JobId and boundsValid(p.bounds), "Checkpoint does not match this world/server")
    assert(p.movementMode == "native-input" and p.engine == S.engine and p.routeVersion == 3 and p.mode == "world-clear", "Old row cursor refused; preview live remaining tiles again")
    assert(type(p.row) == "number" and type(p.nextX) == "number" and (p.direction == 1 or p.direction == -1), "Invalid checkpoint cursor")
    S.progress, p.state = p, "Paused"
    status("Checkpoint loaded - Start / Resume to continue")
    return {world = p.world, row = p.row, x = p.nextX, direction = p.direction}
end
local function sessionAlive(generation)
    return S.live and E.BlizzardGrowbloxRuntime == API and S.running and S.generation == generation and world.name == S.boundWorld
end
local function active(generation)
    if not sessionAlive(generation) then return false end

    local waiting = false
    while inputService:GetFocusedTextBox() ~= nil or game.Players.LocalPlayer:GetAttribute("Frozen") do
        if not sessionAlive(generation) then return false end
        releaseMovement()
        if not waiting then
            waiting = true
            if S.progress then S.progress.state = "Waiting" end
            status("Waiting: close chat/menu or wait until unfrozen")
        end
        task.wait(0.15)
    end
    if waiting and S.progress then S.progress.state = "Running" end
    return sessionAlive(generation)
end
local function recoverableFailure(reason)
    local message = tostring(reason)
    for _, fragment in {"landing", "land normally", "ground", "falling", "Corridor", "Route blocked", "movement stalled", "replan", "out of normal reach", "out of mining range", "Mining timeout"} do
        if string.find(string.lower(message), string.lower(fragment), 1, true) then return true end
    end
    return false
end
local function supported(x, y)
    if not canStand(x, y) then return false end
    local d = DB[tile(0, x, y + 1) or 0]
    return d ~= nil and not d.hurts and (d.solid == true or d.platform == true)
end

local function contactFloor(py)
    local fy=math.floor(py+0.5)
    if fy<1 or fy>=world.h or math.abs(py-fy)>0.12 then return nil end
    return fy
end
local function supportContact(px,py)
    local fy=contactFloor(py)
    if not fy then return nil end
    for _,foot in {px,px-0.30,px+0.30} do
        local x=math.floor(foot)
        if x>=0 and x<world.w and passable(tile(0,x,fy-1)) then
            local d=DB[tile(0,x,fy) or 0]
            if d and not d.hurts and (d.solid==true or d.platform==true) then return fy,x end
        end
    end
    return nil
end
local function avatarSupportAt(x,y)
    local px,py=position()
    if contactFloor(py)~=y or x<0 or x>=world.w then return false end
    local d=DB[tile(0,x,y) or 0]
    if not d or d.hurts or not (d.solid==true or d.platform==true) or not passable(tile(0,x,y-1)) then return false end
    for _,foot in {px,px-0.30,px+0.30} do if math.floor(foot)==x then return true end end
    return false
end
local function grounded()
    local px,py=position()
    return supportContact(px,py)~=nil
end
local function waitGrounded(timeout, generation)
    local began = os.clock()
    repeat
        if generation and not active(generation) then return false end
        if grounded() then return true end
        task.wait(0.04)
    until os.clock() - began > timeout
    return false
end
local function jumpArcClear(sx, sy, nx, ny)
    if not S.movement.jumpValidated then return false end
    local height = S.movement.maxJumpHeight or 0
    if height < 1 or sy - ny > height - 0.05 or ny - sy > 2 then return false end

    local apex = sy + 0.99 - height - 0.05
    local function bodyClear(px, py)
        for bodyY = math.floor(py - 1.8), math.floor(py - 0.03) do
            if not passable(tile(0, math.floor(px), bodyY)) then return false end
        end
        return true
    end
    for i = 0, 12 do
        local t = i / 12
        if not bodyClear(sx + 0.5, sy + 0.99 + (apex - sy - 0.99) * t) then return false end
        if not bodyClear(sx + 0.5 + (nx - sx) * t, apex) then return false end
        if not bodyClear(nx + 0.5, apex + (ny + 0.99 - apex) * t) then return false end
    end
    return true
end
local function pathTo(x, y, exact)
    local px, py = position()
    local floorY=supportContact(px,py)
    if not floorY then return nil, "Avatar has no physical foot contact; waiting for normal landing" end
    local sx, sy = math.floor(px), floorY-1
    if not supported(sx, sy) then
        local anchored
        for _, foot in {px - 0.30, px + 0.30} do
            if supported(math.floor(foot), sy) then sx, anchored = math.floor(foot), true; break end
        end
        if not anchored then return nil, "Avatar is not grounded; no flying route will be generated" end
    end
    local nodes, seen, head = {{x = sx, y = sy, parent = 0}}, {[sy * world.w + sx] = true}, 1
    local found
    while head <= #nodes do
        local n = nodes[head]
        local cutsOwnSupport = tile(0, x, y) ~= 0 and n.x == x and n.y + 1 == y
        if (exact and n.x == x and n.y == y) or (not exact and not cutsOwnSupport and canMineFrom(n.x + 0.5, n.y + 0.99, x, y)) then
            found = head; break
        end
        local function push(nx, ny, mode)
            local k = ny * world.w + nx
            if not seen[k] and supported(nx, ny) then
                seen[k] = true
                nodes[#nodes + 1] = {x = nx, y = ny, parent = head, mode = mode}
            end
        end
        for _, dir in {-1, 1} do
            local nx = n.x + dir
            if supported(nx, n.y) then push(nx, n.y, "walk")
            elseif canStand(nx, n.y) then
                for drop = 1, world.h - n.y - 1 do
                    if not canStand(nx, n.y + drop) then break end
                    if supported(nx, n.y + drop) then push(nx, n.y + drop, "drop"); break end
                end
            end
            for gap = 1, 2 do
                for delta = -2, 2 do
                    local jx, jy = n.x + dir * gap, n.y + delta
                    local needsJump = delta < 0 or (gap == 2 and not supported(n.x + dir, n.y))
                    if needsJump and supported(jx, jy) and jumpArcClear(n.x, n.y, jx, jy) then push(jx, jy, "jump") end
                end
            end
        end
        head += 1
    end
    if not found then return nil, "No collision-free detour around protected tiles" end
    local reversed, path = {}, {}
    while found > 0 do
        local n = nodes[found]
        reversed[#reversed + 1] = {x = n.x, y = n.y, mode = n.mode}
        found = n.parent
    end
    if math.abs(px - (sx + 0.5)) > 0.16 then path[#path + 1] = {x = sx, y = sy, mode = "walk"} end
    for i = #reversed - 1, 1, -1 do path[#path + 1] = reversed[i] end
    local compact = {}
    for _, node in path do
        local prev, before = compact[#compact], compact[#compact - 1]
        if prev and before and node.mode == "walk" and prev.mode == "walk"
            and before.y == prev.y and node.y == prev.y
            and (node.x - prev.x) * (prev.x - before.x) > 0 then
            compact[#compact] = node
        else compact[#compact + 1] = node end
    end
    return compact
end
function API.PlanRoute(x, y, exact)
    return pathTo(x, y, exact == true)
end
local collectNearby
local function follow(path, generation)
    local metrics = S.dirt.running and S.dirt or (S.farm.running and S.farm or S.progress)
    for _, n in path do
        if not active(generation) then releaseMovement(); return false, "Paused" end
        if not supported(n.x, n.y) then releaseMovement(); return false, "Landing support changed; replan" end
        local gx, gy = n.x + 0.5, n.y + 0.99
        local fromX, fromY = position()
        local began = os.clock()
        if n.mode == "jump" then inputKey(Enum.KeyCode.Space, true) end
        local arrived = false
        local lastX, lastY, lastProgress = fromX, fromY, os.clock()
        repeat
            if not active(generation) then releaseMovement(); return false, "Paused" end
            local px, py = position()
            local dx = gx - px
            if math.abs(px - lastX) + math.abs(py - lastY) > 0.06 then
                lastX, lastY, lastProgress = px, py, os.clock()
            elseif os.clock() - lastProgress > 1.2 then
                releaseMovement(); return false, "Route blocked: no physical progress"
            end
            inputKey(Enum.KeyCode.A, dx < -0.16)
            inputKey(Enum.KeyCode.D, dx > 0.16)
            if os.clock() - began > 0.08 then inputKey(Enum.KeyCode.Space, false) end
            if math.abs(dx) <= 0.18 and math.abs(py - gy) <= 0.2 and grounded() then arrived = true; break end
            task.wait(0.04)
        until os.clock() - began > math.max(3, 2 + math.abs(gx - fromX) / 2 + math.sqrt(math.max(0, gy - fromY)) * 0.6)
        releaseMovement()
        if not arrived then return false, "Normal-input movement stalled; paused without forcing position" end
        task.wait(0.14)

        for _ = 1, 6 do
            if not active(generation) then releaseMovement(); return false, "Paused" end
            local px, py = position()
            if grounded() and math.abs(px - gx) <= 0.2 and math.abs(py - gy) <= 0.2 then break end
            if not waitGrounded(1.5, generation) then return false, "Normal landing not reached" end
            px, py = position()
            if math.abs(py - gy) > 0.25 then return false, "Landed on another level; replan" end
            inputKey(Enum.KeyCode.A, px > gx)
            inputKey(Enum.KeyCode.D, px < gx)
            task.wait(0.035)
            releaseMovement()
            task.wait(0.1)
        end
        local alignedX, alignedY = position()
        if not grounded() or math.abs(alignedX - gx) > 0.35 or math.abs(alignedY - gy) > 0.25 then return false, "Landing drift; replan" end
        metrics.moves += 1
        local px, py = position()
        metrics.distance += math.sqrt((px - fromX)^2 + (py - fromY)^2)
        if collectNearby and S.config.autoPickup and (not S.farm.running or S.farm.config.loot) then
            local got = collectNearby(false)
            if S.farm.running then S.farm.collected += got end
        end
    end
    releaseMovement()
    if not waitGrounded(1.5, generation) then return false, "Did not land normally" end
    return true
end

local function rowFrontier(y, bounds)
    local first, last
    for x = bounds.x0, bounds.x1 do
        if eligible(0, x, y) or eligible(1, x, y) then
            first = first or x; last = x
        end
    end
    if not first then return nil end
    local px = position()
    if math.abs(px - (first + 0.5)) <= math.abs(px - (last + 0.5)) then return first, 1 end
    return last, -1
end
function API.SpatialPlan(y, bounds)
    local b = bounds or (S.progress and S.progress.bounds) or {x0 = 0, x1 = world.w - 1, y0 = 1, y1 = world.h - 1}
    local x, direction = rowFrontier(y, b)
    if not x then return {empty = true, row = y} end
    local path, err = pathTo(x, y, false)
    return {row = y, x = x, direction = direction, waypoints = path and #path,
        first = path and path[1], last = path and path[#path], error = err}
end
local function enterRow(p)
    local x, direction = rowFrontier(p.row, p.bounds)
    p.entryX = x
    if x then p.nextX, p.direction = x, direction end
    p.rowEntered = true
    return x ~= nil
end
local function safeCornerDescent(x, y)
    local p = S.progress
    if not p or (x ~= p.bounds.x0 and x ~= p.bounds.x1 and x ~= p.entryX) then return false end
    local px, py = position()
    if not avatarSupportAt(x,y) then return false end
    local below = DB[tile(0, x, y + 1) or 0]
    return eligible(0, x, y) and passable(tile(0, x, y - 1)) and below ~= nil
        and not below.hurts and (below.solid == true or below.platform == true)
end
local function corridorStep(x, y, generation)
    if not supported(x, y) then return false, "Corridor has no safe floor" end
    local startX, startY = position()
    local began = os.clock()
    repeat
        if not active(generation) then releaseMovement(); return false, "Paused" end
        local px, py = position()
        if math.abs(py - (y + 0.999)) > 0.25 then releaseMovement(); return false, "Corridor level changed" end
        if math.abs(px - (x + 0.5)) <= 0.18 then
            releaseMovement()
            S.progress.moves += 1
            S.progress.corridorSteps = (S.progress.corridorSteps or 0) + 1
            S.progress.distance += math.abs(px - startX)
            return true
        end
        inputKey(Enum.KeyCode.A, px > x + 0.5)
        inputKey(Enum.KeyCode.D, px < x + 0.5)
        task.wait(0.025)
    until os.clock() - began > 1.5
    releaseMovement()
    return false, "Normal corridor walk stalled"
end
local function navigate(x, y, generation, stay)
    releaseMovement()
    if not waitGrounded(2, generation) then return false, "Waiting for normal landing" end
    local px, py = position()
    local ownSupport = tile(0, x, y) ~= 0 and avatarSupportAt(x,y)
    if ownSupport and safeCornerDescent(x, y) then
        S.progress.phase = "corner-descent"
        return true
    end

    if not ownSupport and canMineFrom(px, py, x, y) then
        S.progress.phase = "mine-corridor"
        return true
    end
    local behind = x - S.progress.direction
    if supported(behind, y) and canMineFrom(behind + 0.5, y + 0.999, x, y) then
        local bx, by = position()
        if math.abs(by - (y + 0.999)) <= 0.25 and math.abs(bx - behind - 0.5) <= 1.6 then
            local moved = corridorStep(behind, y, generation)
            if moved then return true end
        end
    end
    S.progress.phase = "obstacle-detour"
    for _ = 1, 3 do
        local path, err = pathTo(x, y, false)
        if not path then return false, "No stand point for tile " .. x .. "," .. y .. ": " .. tostring(err) end
        S.progress.detours += 1
        local moved, why = follow(path, generation)
        if moved then
            local ax, ay = position()
            if canMineFrom(ax, ay, x, y) then return true end
        end
        if not active(generation) then return false, "Paused" end
        S.progress.replans = (S.progress.replans or 0) + 1
        if not waitGrounded(2, generation) then return false, why or "Landing failed" end
    end
    return false, "Obstacle has no reachable mining stance"
end
local function refreshLootInventory()
    local data = Net.call("GetInventory")
    restoreExecutorContext()
    assert(type(data) == "table" and type(data.slots) == "table", "Inventory refresh unavailable")
    local counts, slots = {}, {}
    for _, pair in data.slots do
        local id, amount = tonumber(pair.id or pair[1]), tonumber(pair.n or pair[2])
        if id and amount then counts[id] = amount; slots[#slots + 1] = {id = id, n = amount} end
    end
    S.loot.counts, S.loot.capacity, S.loot.used, S.loot.snapshotAt = counts, data.capacity or 54, #slots, os.clock()
    if inventory then
        for _, id in {18, 32} do if not counts[id] then table.insert(slots, 1, {id = id, n = 1}) end end
        inventory.slots, inventory.capacity = slots, data.capacity or inventory.capacity
        inventory.changed:Fire()
    end
    return counts
end
local function refreshGems()
    local gems = Net.call("GetGems")
    restoreExecutorContext()
    if type(gems) == "number" then
        S.loot.serverGems = gems
        for _, f in filtergc("function", {Name = "setGems"}, false) do
            if debug.info(f, "s") == "Players." .. game.Players.LocalPlayer.Name .. ".PlayerGui.GameGui.ChatUI" then pcall(f, gems); break end
        end
    end
end
function API.DropSummary()
    local counts = {blocks = 0, seeds = 0, gems = 0, objects = 0, fullStacks = {}}
    for _, d in world.dropList() do
        local def = DB[d.id]
        local kind = def and def.kind == "gem" and "gems" or (def and def.kind == "seed" and "seeds" or "blocks")
        counts[kind] += d.n or 0; counts.objects += 1
    end
    for id in S.loot.fullItems do counts.fullStacks[#counts.fullStacks + 1] = {id = id, name = DB[id] and DB[id].name} end
    return counts
end
collectNearby = function(force)
    if not S.config.autoPickup or (not force and S.loot.lastScan and os.clock() - S.loot.lastScan < 0.2) then return 0 end
    S.loot.lastScan = os.clock()
    local px, py = position()
    local nearby = {}
    for _, d in world.dropList() do
        if not d.pending and type(d.uid) == "number" and (S.loot.retryAt[d.uid] or 0) <= os.clock()
            and (d.x - px)^2 + (d.y - py)^2 <= S.config.pickupRadius^2 then nearby[#nearby + 1] = d end
    end
    if #nearby == 0 then return 0 end
    if not S.loot.counts or os.clock() - (S.loot.snapshotAt or 0) > 5 then refreshLootInventory() end
    table.sort(nearby, function(a, b)
        local function priority(d) return DB[d.id] and DB[d.id].kind == "gem" and 0 or (DB[d.id] and DB[d.id].kind == "seed" and 1 or 2) end
        return priority(a) < priority(b)
    end)
    local claimed, gotGems = 0, false
    for i, d in nearby do
        if i > 16 or not S.live then break end
        local def = DB[d.id]
        local isGem = def and def.kind == "gem"
        if isGem then
            -- Anti-magnet fix for autoclear: gems require native physical avatar touch, not remote takeDrop packet
            local curX, curY = position()
            local dx = d.x - curX
            if math.abs(dx) > 0.35 and math.abs(d.y - curY) < 1.8 then
                local key = dx > 0 and Enum.KeyCode.D or Enum.KeyCode.A
                inputKey(key, true)
                local began = os.clock()
                repeat
                    task.wait(0.02)
                    curX = position()
                until math.abs(curX - d.x) <= 0.35 or os.clock() - began > 0.35
                releaseMovement()
            end
            task.wait(0.04)
            S.loot.gems += (d.n or 1)
            claimed += (d.n or 1)
            gotGems = true
            local list = world.dropList()
            local index = table.find(list, d)
            if index then
                if d.frame then pcall(function() d.frame:Destroy() end) end
                table.remove(list, index)
            end
        else
            -- Normal inventory item (seed or block): takeDrop packet still works
            local room = math.max(0, 200 - (S.loot.counts[d.id] or 0))
            if not S.loot.counts[d.id] and S.loot.used >= S.loot.capacity then room = 0 end
            local want = math.min(d.n or 1, room)
            if want <= 0 then
                S.loot.fullItems[d.id] = true
                S.loot.retryAt[d.uid] = os.clock() + 15
            else
                local beforeN = d.n or 1
                S.loot.attempts += 1
                local got = world.takeDrop(d.uid, want)
                restoreExecutorContext()
                assert(type(got) == "number", "Unexpected native takeDrop reply")
                if got > 0 then
                    local bucket = def and def.kind == "seed" and "seeds" or "blocks"
                    S.loot[bucket] += got; claimed += got
                    S.loot.counts[d.id] = (S.loot.counts[d.id] or 0) + got

                    if got >= beforeN then
                        local list = world.dropList()
                        local index = table.find(list, d)
                        if index then
                            if d.frame then pcall(function() d.frame:Destroy() end) end
                            table.remove(list, index)
                        end
                    elseif d.n == beforeN then d.n = beforeN - got end
                    S.loot.retryAt[d.uid] = os.clock() + 1
                else S.loot.denied += 1; S.loot.retryAt[d.uid] = os.clock() + 1 end
            end
        end
    end
    if claimed > 0 then refreshLootInventory() end
    if gotGems then refreshGems() end
    if S.lootLabel then pcall(function() S.lootLabel:SetText(string.format("Blocks: %d | Seeds: %d\nGems: +%d", S.loot.blocks, S.loot.seeds, S.loot.gems)) end) end
    return claimed
end
function API.CollectNearby()
    assert(not S.running and not S.busy, "Pause first")
    return collectNearby(true)
end
local function originalTileListener()
    for _, f in Net.tileChanged.getListeners() do if debug.info(f, "s") == gameSource then return f end end
end
local function verifyRun(run, final)
    if not final then

        for _, t in run.targets do
            if not t.settledChecked then
                t.afterSettled, t.settledChecked = tile(t.layer, t.x, t.y), true
                if t.afterSettled ~= 0 then return false, "Server corrected a mined tile; pause for replan" end
            end
        end
        checkpoint()
        return true
    end
    local ok, accepted, data = pcall(function() return RS.WorldRemotes.EnterWorld:InvokeServer(S.boundWorld) end)
    if not ok or accepted ~= true or type(data) ~= "table" or data.name ~= S.boundWorld then return false, "Server snapshot unavailable" end
    if not S.live or world.name ~= S.boundWorld then return false, "World changed during verification" end
    local codec = require(RS.Shared.WorldCodec)
    local grids = {[0] = codec.decode(data.fg, data.w, data.h), [1] = codec.decode(data.bg, data.w, data.h)}
    local fix = originalTileListener()
    for _, t in run.targets do
        if not t.checked then
            t.serverAfter = grids[t.layer][t.y][t.x]
            t.checked, t.persistenceConfirmed = true, t.serverAfter == 0
            if t.persistenceConfirmed then S.progress.serverCleared += 1
            else
                S.progress.serverRejected += 1
                S.blocked[key(t.layer, t.x, t.y)] = "Server rejected removal"
                if fix then pcall(fix, {w = Net.worldTag(data.name), layer = t.layer + 1, x = t.x, y = t.y, id = t.serverAfter, flip = false}) end
            end
        end
    end
    S.progress.serverRemaining = countRemaining(S.progress.bounds, grids[0], grids[1]).total

    S.progress.serverCleared = math.max(0, S.progress.initial - S.progress.serverRemaining)
    S.progress.verifications += 1
    S.serverRead = {ok = true, a = true, b = data, at = os.clock(), world = data.name}
    checkpoint()
    return true
end
local function mineLayer(x, y, layer, generation, run)
    if not eligible(layer, x, y) then return true end
    if S.blocked[key(layer, x, y)] then return false, S.blocked[key(layer, x, y)] end
    releaseMovement()
    if not waitGrounded(2, generation) then return false, "Mining paused until normal landing" end
    local id, needed = tile(layer, x, y), DB[tile(layer, x, y)].hits
    local px, py = position()
    if not canMineFrom(px, py, x, y) then return false, "Target out of mining range" end
    local maxCalls = needed * 3 + 3
    for attempt = 1, maxCalls do
        if not active(generation) then return false, "Paused" end
        if tile(layer, x, y) ~= id then break end
        if not accessible(x, y) then return false, "Build permission changed" end
        local ax, ay = position()
        if not grounded() then return false, "Mining stopped because avatar left the ground" end
        if layer == 0 and avatarSupportAt(x,y) and not safeCornerDescent(x, y) then
            return false, "Refusing to remove the support under the avatar; replan from the side"
        end
        if not canMineFrom(ax, ay, x, y) then return false, "Target moved out of normal reach" end
        hit(x, y)
        S.nativeCalls += 1; S.progress.hits += 1
        if tile(layer, x, y) == 0 then break end
        if attempt >= needed + 1 then

            S.mining.effectiveInterval = math.min(0.6, math.max(0.35, S.mining.effectiveInterval + 0.05))
            S.mining.backoffs += 1
        end
        task.wait(math.max(0.24, S.config.interval, S.mining.effectiveInterval))
    end
    if tile(layer, x, y) ~= 0 then
        S.mining.timeouts += 1
        return false, "Mining timeout: tile still present after normal paced hits"
    end
    local t = {x = x, y = y, layer = layer, before = id, after = 0}
    run.targets[#run.targets + 1] = t
    if layer == 0 then S.progress.foreground += 1 else S.progress.background += 1 end
    S.localCleared += 1
    task.wait(math.max(0.35, S.config.interval, S.mining.effectiveInterval))
    if not waitGrounded(2, generation) then return false, "Corner descent did not land normally" end
    t.afterSettled = tile(layer, x, y)
    if t.afterSettled ~= 0 then return false, "Tile was corrected after normal mining" end
    return true
end
local function openSpawnUnderpass(tx,ty,generation,run)
    local px,py=position()
    local p=S.progress
    local obstacle
    for y=math.max(0,ty-2),math.min(world.h-1,ty+1) do
        for x=math.max(p.bounds.x0,math.min(math.floor(px),tx)-1),math.min(p.bounds.x1,math.max(math.floor(px),tx)+1) do
            if math.abs(x-tx)<=4 and tile(0,x,y)==8 then
                local c=bedrockComponent(x,y)
                if not c.touchesBottom and c.size<=12 and c.maxY+1<=p.bounds.y1 then obstacle=c;break end
            end
        end
        if obstacle then break end
    end
    if not obstacle then return false,"No local bedrock pedestal near target" end
    local tunnelY=obstacle.maxY+1
    local u={x0=math.max(p.bounds.x0,obstacle.minX-2),x1=math.min(p.bounds.x1,obstacle.maxX+2),y=tunnelY,row=ty}
    S.clearUnderpassBounds,p.underpass=u,u
    p.phase="spawn-underpass (same row)"
    p.detours=(p.detours or 0)+1
    local savedRow,savedX=p.row,p.nextX
    for _=1,8 do
        if not active(generation) then return false,"Paused" end
        local ax,ay=position()
        if canMineFrom(ax,ay,tx,ty) then return true end
        local route=pathTo(tx,ty,false)
        if route then
            local moved=follow(route,generation)
            if moved then return true end
        end
        local best,score
        for x=u.x0,u.x1 do
            local id=tile(0,x,tunnelY)
            local below=DB[tile(0,x,tunnelY+1) or 0]
            local ownSupport=avatarSupportAt(x,tunnelY)
            if eligible(0,x,tunnelY) and DB[id] and not DB[id].hurts and not ownSupport
                and below and not below.hurts and (below.solid or below.platform)
                and canMineFrom(ax,ay,x,tunnelY) then
                local cost=math.abs(x-tx)+math.abs(x+0.5-ax)*0.1
                if not score or cost<score then best,score=x,cost end
            end
        end
        if not best then return false,"No safe local access cell; row retained" end
        local first=#run.targets+1
        local ok,err=mineLayer(best,tunnelY,0,generation,run)
        if not ok then return false,err end
        if S.config.background and eligible(1,best,tunnelY) then
            ok,err=mineLayer(best,tunnelY,1,generation,run)
            if not ok then return false,err end
        end
        for i=first,#run.targets do run.targets[i].detourForRow=ty end
        p.localDetourCells=(p.localDetourCells or 0)+1
        assert(p.row==savedRow and p.nextX==savedX,"Detour changed the requested row cursor")
        local path,why=pathTo(best,tunnelY,true)
        if not path then return false,why end
        local moved,failure=follow(path,generation)
        if not moved then return false,failure end
    end
    return false,"Local detour budget reached; row retained"
end
local function rowPending(y,bounds)
    local targets={}
    for x=bounds.x0,bounds.x1 do
        if eligible(0,x,y) or eligible(1,x,y) then targets[#targets+1]=x end
    end
    return targets
end
function API.ClearRowStatus(y)
    local b=S.progress and S.progress.bounds or {x0=0,x1=world.w-1}
    return {row=y,pending=rowPending(y,b)}
end
local function clearCell(x, y, generation, run, stay)
    local fg = tile(0, x, y)
    if fg ~= 0 and not eligible(0, x, y) then
        S.progress.protected += 1
        return true
    end
    if fg == 0 and (not S.config.background or not eligible(1, x, y)) then return true end
    local reached, why = navigate(x, y, generation, stay)
    local usedUnderpass=false
    if not reached then
        if string.find(why or "", "No stand point", 1, true) then
            local opened,detourError=openSpawnUnderpass(x,y,generation,run)
            if opened then usedUnderpass=true;reached,why=navigate(x,y,generation,stay)
            else why=detourError or why end
        end
        if not reached then
            S.progress.lastUnreachable={x=x,y=y,reason=why}
            return false,"Row blocked at "..x..","..y..": "..tostring(why)
        end
    end
    for layer = 0, (S.config.background and 1 or 0) do
        local ok, err = mineLayer(x, y, layer, generation, run)
        if not ok then return false, err end
    end

    if supported(x, y) then
        S.progress.phase = "advance-corridor"
        local px, py = position()
        local moved, why
        if math.abs(py - (y + 0.999)) <= 0.25 and math.abs(px - x - 0.5) <= 1.6 then
            moved, why = corridorStep(x, y, generation)
        else

            local path, err = pathTo(x, y, true)
            if path then moved, why = follow(path, generation) else why = err end
        end
        if not moved and not (usedUnderpass and grounded()) then return false, why end
    end
    collectNearby(false)
    S.progress.cells += 1
    status(string.format("Row %d | x %d | %s\nFG %d | BG %d\nServer verified: %d", y, x, S.progress.direction == 1 and ">" or "<",
        S.progress.foreground, S.progress.background, S.progress.serverCleared))
    return true
end

function API.CalibrateGrounded()
    assert(not S.running and not S.busy, "Pause first")
    assert(inputService:GetFocusedTextBox() == nil, "Close the focused text box first")
    S.generation = (S.generation or 0) + 1
    local generation, name = S.generation, world.name
    S.busy, S.movement.validated, S.movement.jumpValidated = true, false, false
    local test = {mode = "native-input", world = name, job = game.JobId}
    local ok, err = xpcall(function()
        assert(waitGrounded(2), "Stand on solid ground before calibration")
        local px, py = position()
        test.fromX, test.fromY = px, py
        local keycode = px - math.floor(px) < 0.5 and Enum.KeyCode.D or Enum.KeyCode.A
        inputKey(keycode, true)
        task.wait(0.04)
        releaseMovement()
        task.wait(0.12)
        assert(S.live and S.generation == generation and world.name == name, "Calibration cancelled")
        local ax, ay = position()
        test.walkDelta = math.abs(ax - px)
        assert(test.walkDelta > 0.02 and test.walkDelta < 0.9 and math.abs(ay - py) < 0.25 and grounded(), "Normal walk input was not validated; no automation started")
        test.walkValidated = true
        local _, baseY = position()
        local minY, began, landed = baseY, os.clock(), false
        inputKey(Enum.KeyCode.Space, true)
        task.wait(0.07)
        inputKey(Enum.KeyCode.Space, false)
        repeat
            assert(S.live and S.generation == generation and world.name == name, "Calibration cancelled")
            local _, y = position()
            minY = math.min(minY, y)
            if minY < baseY - 0.25 and grounded() and math.abs(y - baseY) < 0.2 then landed = true; break end
            task.wait(0.04)
        until os.clock() - began > 2.5
        test.maxJumpHeight, test.jumpValidated = baseY - minY, landed
        assert(landed, "Normal Space jump/landing not validated; inspect bindings after reconnect")
        S.movement.maxJumpHeight, S.movement.jumpValidated = test.maxJumpHeight, true
        S.movement.world, S.movement.job, S.movement.validated = name, game.JobId, true
    end, debug.traceback)
    releaseMovement()
    S.busy = false
    test.ok, test.error = ok, not ok and tostring(err) or nil
    S.navigationTest = test
    status(ok and "Normal walk/jump validated; Preview then Start" or tostring(err))
    return test
end
API.NavigationProbe = API.CalibrateGrounded

local function recordEvent(kind, payload)
    local r = S.recorder
    if not r or not r.active then return end
    if #r.events >= 30000 then r.overflow = true; return end
    r.events[#r.events + 1] = {t = os.clock() - r.started, kind = kind, data = payload}
    r.counts[kind] = (r.counts[kind] or 0) + 1
end
local function flushRecording(r)
    if type(writefile) ~= "function" then r.diskError = "writefile unavailable; recording retained in memory"; return end
    local lines = {}
    for i = r.written + 1, #r.events do lines[#lines + 1] = game:GetService("HttpService"):JSONEncode(r.events[i]) end
    if #lines == 0 then return end
    local ok, err = pcall(function()
        if type(appendfile) == "function" then appendfile(r.file, table.concat(lines, "\n") .. "\n")
        else
            local all = {}; for _, e in r.events do all[#all + 1] = game:GetService("HttpService"):JSONEncode(e) end
            writefile(r.file, table.concat(all, "\n") .. "\n")
        end
    end)
    if ok then r.written = #r.events else r.diskError = tostring(err) end
end
function API.StopRecording(reason)
    local r = S.recorder
    if not r or not r.active then return end
    recordEvent("stop", {reason = reason or "user", world = world.name})
    r.active, r.elapsed = false, os.clock() - r.started
    for _, hook in r.hooks do if hook.packet.send == hook.wrapper then hook.packet.send = hook.original end end
    for _, c in r.connections do c:Disconnect() end
    for _, entry in r.listeners do
        local listeners = entry.packet.getListeners()
        local index = table.find(listeners, entry.callback)
        if index then table.remove(listeners, index) end
    end
    flushRecording(r)
    status("Recording saved: " .. #r.events .. " events")
end
function API.RecordingStatus()
    local r = S.recorder
    if not r then return {active = false} end
    return {active = r.active, world = r.world, file = r.file, events = #r.events,
        written = r.written, counts = r.counts, elapsed = r.active and os.clock() - r.started or r.elapsed,
        diskError = r.diskError, overflow = r.overflow, autoClear = S.running}
end
function API.StartRecording()
    if S.recorder and S.recorder.active then return API.RecordingStatus() end
    API.Stop("manual farming demonstration")
    local r = {active = true, world = world.name, job = game.JobId, started = os.clock(), events = {},
        counts = {}, hooks = {}, connections = {}, listeners = {}, written = 0,
        file = "growblox-farm-demo-" .. tostring(DateTime.now().UnixTimestampMillis) .. ".jsonl"}
    S.recorder = r
    if type(writefile) == "function" then pcall(writefile, r.file, "") end
    recordEvent("start", {world = world.name, job = game.JobId, placeVersion = game.PlaceVersion,
        width = world.w, height = world.h, sampleHz = 10})
    for _, name in {"move", "act", "tile", "take", "harvest", "splice"} do
        local packet = Net[name]
        if packet and type(packet.send) == "function" then
            local original = packet.send
            local wrapper = function(payload)
                pcall(function()
                    local data = {packet = name}
                    if type(payload) == "table" then
                        for k, v in payload do if type(v) == "number" or type(v) == "boolean" then data[k] = v end end
                        if name == "tile" then data.before = tile(payload.layer - 1, payload.x, payload.y) end
                    elseif type(payload) == "number" then data.value = payload end
                    recordEvent("outgoing", data)
                end)
                return original(payload)
            end
            r.hooks[#r.hooks + 1] = {packet = packet, original = original, wrapper = wrapper}
            packet.send = wrapper
        end
    end
    for _, name in {"tileChanged", "dropAdded", "dropTaken", "took", "treeChanged"} do
        local packet = Net[name]
        if packet and packet.listen then
            local callback = function(payload)
                pcall(function()
                    local data = {packet = name}
                    if type(payload) == "table" then for k, v in payload do if type(v) == "number" or type(v) == "boolean" then data[k] = v end end end
                    recordEvent("incoming", data)
                end)
            end
            packet.listen(callback)
            r.listeners[#r.listeners + 1] = {packet = packet, callback = callback}
        end
    end
    local function inputEvent(input, down)
        if inputService:GetFocusedTextBox() then return end
        if table.find({Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.Space,
            Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down}, input.KeyCode)
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            recordEvent("input", {key = input.KeyCode.Name, type = input.UserInputType.Name, down = down})
        end
    end
    r.connections[#r.connections + 1] = inputService.InputBegan:Connect(function(i) inputEvent(i, true) end)
    r.connections[#r.connections + 1] = inputService.InputEnded:Connect(function(i) inputEvent(i, false) end)
    if inventory then r.connections[#r.connections + 1] = inventory.changed.Event:Connect(function()
        local slots = {}; for _, v in inventory.slots do slots[#slots + 1] = {id = v.id, n = v.n} end
        recordEvent("inventory", {selected = inventory.selected, slots = slots})
    end) end
    task.spawn(function()
        local lastFlush, cache = os.clock(), {}
        while r.active and S.live and world.name == r.world and game.JobId == r.job do
            local x, y = position()
            recordEvent("position", {x = x, y = y, selected = inventory and inventory.selected})
            for cy = math.max(0, math.floor(y) - 3), math.min(world.h - 1, math.floor(y) + 3) do
                for cx = math.max(0, math.floor(x) - 3), math.min(world.w - 1, math.floor(x) + 3) do
                    for layer = 0, 1 do
                        local k, id = key(layer, cx, cy), tile(layer, cx, cy)
                        if cache[k] ~= nil and cache[k] ~= id then recordEvent("grid", {x = cx, y = cy, layer = layer, before = cache[k], after = id}) end
                        cache[k] = id
                    end
                end
            end
            if os.clock() - lastFlush >= 2 then flushRecording(r); lastFlush = os.clock() end
            if r.overflow or os.clock() - r.started >= 900 then break end
            task.wait(0.1)
        end
        if r.active then API.StopRecording("time/world/safety limit") end
    end)
    status("RECORDING manual farming | autoclear OFF")
    return API.RecordingStatus()
end

local function waitAck(t, began, timeout, generation)
    repeat
        local event = S.events[key(t.layer, t.x, t.y)]
        if event and event.at >= began and event.id == 0 then return true end
        if not S.live or world.name ~= S.boundWorld or S.generation ~= generation then return false end
        task.wait(0.04)
    until os.clock() - began >= timeout
    return false
end
local function sendBreak(t)
    Net.tile.send({layer = t.layer + 1, x = t.x, y = t.y, id = 0, flip = false})
    S.sent += 1
end
local function punch(t)
    Net.act.send({kind = 6, x = t.x + 0.5, y = t.y + 0.5})
    S.sent += 1
end

function API.Probe(mode, targets)
    assert(not S.research.experimentsPaused or mode == "normal" or mode == "native", "Experiments paused; focus Auto Clear World")
    assert(not S.running and not S.busy, "Another operation is active")
    assert(table.find({"native", "instant", "normal", "rapid", "multi", "cooldown", "multi-cooldown"}, mode), "Unknown mode")
    assert(#targets >= 1 and #targets <= ((mode == "multi" or mode == "multi-cooldown") and 3 or 1), "Probe target cap")
    local bound = world.name
    for _, t in targets do
        t.layer = t.layer or 0
        assert(eligible(t.layer, t.x, t.y) and inRange(t.x, t.y), "Natural accessible in-range tile required")
        t.before = tile(t.layer, t.x, t.y)
    end
    local generation = S.generation
    local result = {mode = mode, protocol = "wire-layer-1-2", world = bound, targets = {}, started = os.clock()}
    local bypass = mode == "cooldown" or mode == "multi-cooldown"
    local oldTime
    if bypass then

        oldTime = debug.getupvalue(hit, 5)
        assert(type(oldTime) == "number" and oldTime <= os.clock() + 1, "Cooldown layout changed")
    end
    S.busy, S.boundWorld = true, bound
    local ok, err = xpcall(function()
        local starts = {}
        for i, t in targets do
            starts[i] = os.clock()
            if mode ~= "instant" then
                for _ = 1, DB[t.before].hits do
                    assert(S.live and world.name == bound and S.generation == generation, "Probe cancelled")
                    if tile(t.layer, t.x, t.y) ~= t.before then break end
                    if bypass then debug.setupvalue(hit, 5, -10) end
                    hit(t.x, t.y)
                    S.nativeCalls += 1
                    if not bypass and mode ~= "multi" then task.wait(mode == "rapid" and 0.05 or 0.35) end
                end
            end
            assert(S.live and world.name == bound and S.generation == generation, "Probe cancelled")
            if mode == "instant" then starts[i] = os.clock(); sendBreak(t) end
        end
        for i, t in targets do
            local ack = waitAck(t, starts[i], 2, generation)
            result.targets[i] = {x = t.x, y = t.y, layer = t.layer, before = t.before,
                after = tile(t.layer, t.x, t.y), serverConfirmed = ack,
                observedSeconds = os.clock() - starts[i]}
        end
    end, debug.traceback)
    if bypass then
        debug.setupvalue(hit, 5, oldTime)
        result.cooldownRestored = debug.getupvalue(hit, 5) == oldTime
    end
    result.ok, result.error = ok, not ok and tostring(err) or nil
    result.elapsed = os.clock() - result.started
    S.results[#S.results + 1] = result
    S.busy = false
    status(ok and ("Probe done: " .. mode .. " | verify server snapshot") or tostring(err))
    return result
end

function API.Start(region)
    assert(not S.busy and not S.running, "Already running")
    assert(not (S.recorder and S.recorder.active), "Stop demonstration recording before autoclear")
    assert(S.movement.validated and S.movement.jumpValidated and S.movement.world == world.name and S.movement.job == game.JobId,
        "Start locked: validate normal walk/jump after reconnect; old flying movement is disabled")
    S.config.background = true
    local p = S.progress
    if region or not p or p.routeVersion ~= 3 or p.mode ~= "world-clear" or p.movementMode ~= "native-input" or p.engine ~= S.engine or p.world ~= world.name or p.job ~= game.JobId or not p.bounds or p.complete then
        local plan = API.Preview(region)
        p = {world = world.name, job = game.JobId, mode = "world-clear", routeVersion = 3, movementMode = "native-input", engine = S.engine, bounds = table.clone(plan.bounds),
            row = plan.bounds.y0, nextX = plan.bounds.x0, direction = 1, edgePending = false, rowEntered = false, startedAt = os.clock(),
            moves = 0, distance = 0, detours = 0, hits = 0, cells = 0, foreground = 0, background = 0,
            protected = 0, unreachable = 0, serverCleared = 0, serverRejected = 0, verifications = 0, turns = 0,
            turnLog = {}, initial = plan.counts.total, complete = false}
        S.progress = p
    elseif p.row > p.bounds.y1 then
        p.row, p.nextX, p.direction, p.edgePending = p.bounds.y0, p.bounds.x0, 1, false
        p.rowEntered=false;p.rowRescans=0
    end
    S.clearUnderpassBounds=p.underpass
    local px, py = position()
    assert(grounded(), "Avatar must start on solid ground")
    S.blocked, S.boundWorld = {}, world.name
    S.generation = (S.generation or 0) + 1
    local generation = S.generation
    S.running, S.busy, p.state = true, true, "Running"
    p.finishedAt = nil
    syncClearToggle(true)
    p.lastError = nil
    S.worker = task.spawn(function()
        local run = {mode = "world-clear", protocol = "wire-layer-1-2", world = S.boundWorld,
            bounds = table.clone(p.bounds), targets = {}, started = os.clock()}
        S.results[#S.results + 1] = run
        local checked, reason, rejectedAtStart = 0, nil, p.serverRejected
        local ok, err = xpcall(function()
            while active(generation) and p.row <= p.bounds.y1 do
                if not p.rowEntered then

                    while p.row <= p.bounds.y1 and not enterRow(p) do
                        p.row += 1; p.rowEntered = false
                    end
                    if p.row > p.bounds.y1 then break end
                end
                local x, y = p.nextX, p.row
                p.lastTarget = {x = x, y = y}
                local cleared, why
                for attempt = 1, 4 do
                    cleared, why = clearCell(x, y, generation, run, p.edgePending)
                    if cleared then break end
                    if not sessionAlive(generation) then return end
                    if not recoverableFailure(why) or attempt == 4 then error(why) end
                    releaseMovement()
                    p.recoveries = (p.recoveries or 0) + 1
                    p.lastRecovery = tostring(why)
                    p.state = "Recovering"
                    status(string.format("Recovering %d/3: %s", attempt, tostring(why)))

                    waitGrounded(6, generation)
                    if not active(generation) then return end
                    task.wait(0.25 * attempt)
                    p.state = "Running"
                end
                if p.edgePending then

                    p.edgePending = false
                end
                p.nextX += p.direction
                local edge = p.nextX < p.bounds.x0 or p.nextX > p.bounds.x1
                if #run.targets - checked >= S.config.verifyEvery or edge then
                    local verified, failure = verifyRun(run, false)
                    if not verified then error(failure) end
                    checked = #run.targets
                    if p.serverRejected > rejectedAtStart then error("Server rejected a removal; paused rather than retry flooding") end
                end
                if edge then
                    local pending=rowPending(p.row,p.bounds)
                    if #pending>0 then
                        p.rowRescans=(p.rowRescans or 0)+1
                        assert(p.rowRescans<=2,"Current row still has targets; refusing to descend")
                        local px=position()
                        local left,right=pending[1],pending[#pending]
                        p.direction=math.abs(px-left-0.5)<=math.abs(px-right-0.5) and 1 or -1
                        p.nextX=p.direction==1 and left or right
                        p.rowEntered=true;p.edgePending=false
                        p.phase="recheck same row"
                    else
                    p.rowRescans=0;p.underpass=nil;S.clearUnderpassBounds=nil
                    p.row += 1; p.direction = -p.direction; p.rowEntered = false
                    p.nextX = p.direction == 1 and p.bounds.x0 or p.bounds.x1
                    p.edgePending = true
                    if p.row <= p.bounds.y1 then
                        p.turns += 1
                        if #p.turnLog < 30 then p.turnLog[#p.turnLog + 1] = {row = p.row, direction = p.direction, edgeX = p.nextX} end
                    end
                    end
                    checkpoint()
                end
                if S.config.limit > 0 and #run.targets >= S.config.limit then reason = "Run limit reached - resume continues this row"; break end
            end
            if active(generation) then
                collectNearby(true)
                p.remainingDrops = API.DropSummary()

                S.running = false
                releaseMovement()
                local verified, failure = verifyRun(run, true)
                if not verified then error(failure) end
                if p.row > p.bounds.y1 and p.serverRemaining == 0 then
                    p.complete, p.state = true, "Complete"
                    reason = "Complete: foreground + cave cleared; protected tiles preserved"
                elseif not reason then reason = "Paused with remaining targets: " .. tostring(p.serverRemaining) end
            end
        end, debug.traceback)
        S.running, S.busy, S.worker = false, false, nil
        syncClearToggle(false)
        releaseMovement()
        p.finishedAt = os.clock()
        run.ok, run.error, run.elapsed = ok, not ok and tostring(err) or nil, os.clock() - run.started
        if not p.complete then p.state = ok and (p.unreachable > 0 and "Blocked" or "Paused") or "Blocked" end
        p.lastError = not ok and tostring(err) or nil
        checkpoint()
        local gateReason = world.name ~= S.boundWorld and "World changed" or "Session interrupted"
        local stopReason = not ok and (tostring(err):match("^[^\r\n]+") or tostring(err)) or reason or gateReason
        S.lastStopReason, S.lastStopAt = stopReason, os.clock()
        p.stopReason = stopReason
        status((p.complete and "Complete: " or "Stopped: ") .. stopReason)
    end)
    return {world = p.world, bounds = p.bounds, row = p.row, x = p.nextX, direction = p.direction}
end
API.Resume = API.Start

function API.ProbeAlternative(mode, targets)
    assert(not S.research.experimentsPaused, "Experiments paused; focus Auto Clear World")
    assert(not S.busy and not S.running, "Another operation is active")
    assert(table.find({"power-clone", "dig-clone", "multi-power", "wire-burst", "wire-batch", "wire-paced", "act-native", "act-power", "punch-burst", "punch-paced", "punch-multi"}, mode), "Unknown alternative")
    assert(#targets >= 1 and #targets <= ((mode == "multi-power" or mode == "wire-batch" or mode == "punch-multi") and 3 or 1), "Target cap")
    assert(type(clonefunction) == "function", "clonefunction unavailable")
    local bound, generation = world.name, S.generation
    for _, t in targets do
        t.layer = t.layer or 0
        assert(t.layer == 0 and eligible(0, t.x, t.y) and inRange(t.x, t.y), "Natural accessible foreground only")
        t.before = tile(0, t.x, t.y)
    end
    local r = {mode = mode, protocol = "wire-layer-1-2", world = bound,
        started = os.clock(), targets = {}, nativeCalls = 0, extraPackets = 0, trace = {}}
    S.busy, S.boundWorld = true, bound
    local originalActSend, originalTileSend = Net.act.send, Net.tile.send
    local actionCleanup = {}
    local ok, err = xpcall(function()
        if mode == "act-native" or mode == "act-power" then
            Net.act.send = function(p)
                r.trace[#r.trace + 1] = {packet = "act", kind = p.kind, x = p.x, y = p.y, at = os.clock() - r.started}
                return originalActSend(p)
            end
            Net.tile.send = function(p)
                assert(p.id == 0 and p.x == targets[1].x and p.y == targets[1].y, "Refusing non-target tile mutation")
                r.trace[#r.trace + 1] = {packet = "tile", layer = p.layer, id = p.id, x = p.x, y = p.y, at = os.clock() - r.started}
                return originalTileSend(p)
            end
        end
        for i, t in targets do
            assert(S.live and world.name == bound and S.generation == generation and inRange(t.x, t.y), "Cancelled/world changed")
            local copied = table.clone(controls)
            if mode == "dig-clone" then
                copied.handDig = function() return 1 end
            elseif mode ~= "act-native" then
                local power = DB[t.before].hits
                copied.handPower = function() return power end
            end
            local alternate = clonefunction(hit)
            debug.setupvalue(alternate, controlsIndex, copied)
            if debug.getupvalue(hit, controlsIndex) ~= controls then
                debug.setupvalue(hit, controlsIndex, controls)
                error("clone shares combat upvalue; original restored, no hit sent")
            end
            assert(debug.getupvalue(alternate, controlsIndex) == copied, "Clone setup failed")
            if mode == "wire-burst" or mode == "wire-batch" or mode == "wire-paced" then

                for _ = 1, DB[t.before].hits - 1 do
                    assert(S.live and world.name == bound and S.generation == generation and inRange(t.x, t.y), "Cancelled")
                    punch(t)
                    r.extraPackets += 1
                    if mode ~= "wire-batch" then task.wait(mode == "wire-paced" and 0.21 or 0.05) end
                end
            end
            if mode == "punch-burst" or mode == "punch-paced" or mode == "punch-multi" then

                for _ = 1, DB[t.before].hits do
                    assert(S.live and world.name == bound and S.generation == generation and inRange(t.x, t.y), "Cancelled")
                    Net.act.send({kind = 1, x = t.x + 0.5, y = t.y + 0.5})
                    r.extraPackets += 1
                    S.sent += 1
                    if mode ~= "punch-multi" then task.wait(mode == "punch-paced" and 0.23 or 0.05) end
                end
            end
            local started = os.clock()
            if mode == "act-native" or mode == "act-power" then
                local act = nativeAct
                local action = clonefunction(act)
                local copiedWorld = table.clone(world)
                local worldIndex, hitIndex, inv
                for index, value in debug.getupvalues(act) do
                    if value == world then worldIndex = index end
                    if value == hit then hitIndex = index end
                    if type(value) == "table" and value.slots and value.capacity then inv = value end
                end
                assert(worldIndex and hitIndex and inv and inv.selected == 18, "Native action requires selected Fist and matching layout")
                local savedMouse = debug.getupvalue(act, 3)
                actionCleanup[#actionCleanup + 1] = {f = act, worldIndex = worldIndex, hitIndex = hitIndex, mouse = savedMouse}
                debug.setupvalue(action, worldIndex, copiedWorld)
                debug.setupvalue(action, hitIndex, alternate)
                if debug.getupvalue(act, worldIndex) ~= world or debug.getupvalue(act, hitIndex) ~= hit then
                    debug.setupvalue(act, worldIndex, world); debug.setupvalue(act, hitIndex, hit)
                    error("Action clone aliases original; restored")
                end
                for _ = 1, (mode == "act-native" and DB[t.before].hits or 1) do
                    if tile(0, t.x, t.y) ~= t.before then break end
                    assert(S.live and world.name == bound and S.generation == generation and inRange(t.x, t.y), "Cancelled")
                    if mode == "act-power" then copiedWorld.punchReady = 0 end
                    local px = (t.x + 0.5 - debug.getupvalue(act, 2)) * debug.getupvalue(act, 4)
                    local py = (t.y + 0.5 - debug.getupvalue(act, 5)) * debug.getupvalue(act, 4)

                    debug.setupvalue(action, 3, Vector2.new(px, py))
                    r.cursorScoped = debug.getupvalue(act, 3) ~= savedMouse
                    action(1)

                    debug.setupvalue(act, 3, savedMouse)
                    r.nativeCalls += 1
                    if mode == "act-native" then task.wait(0.35) end
                end
            else
                alternate(t.x, t.y)
                r.nativeCalls += 1
            end
            r.targets[i] = {x = t.x, y = t.y, layer = 0, before = t.before,
                after = tile(0, t.x, t.y), callSeconds = os.clock() - started}
        end
        r.dispatchSeconds = os.clock() - r.started
        task.wait(0.45)
        for _, t in r.targets do t.afterSettled = tile(0, t.x, t.y) end
    end, debug.traceback)
    Net.act.send, Net.tile.send = originalActSend, originalTileSend
    r.sendersRestored = Net.act.send == originalActSend and Net.tile.send == originalTileSend
    r.actionRestored = true
    for _, entry in actionCleanup do
        debug.setupvalue(entry.f, entry.worldIndex, world)
        debug.setupvalue(entry.f, entry.hitIndex, hit)
        debug.setupvalue(entry.f, 3, entry.mouse)
        r.actionRestored = r.actionRestored and debug.getupvalue(entry.f, entry.worldIndex) == world
            and debug.getupvalue(entry.f, entry.hitIndex) == hit and debug.getupvalue(entry.f, 3) == entry.mouse
    end

    if debug.getupvalue(hit, controlsIndex) ~= controls then debug.setupvalue(hit, controlsIndex, controls) end
    r.originalRestored = debug.getupvalue(hit, controlsIndex) == controls
    r.ok, r.error = ok, not ok and tostring(err) or nil
    r.elapsed = os.clock() - r.started
    S.results[#S.results + 1] = r
    S.busy = false
    if ok and S.live and world.name == bound then
        r.snapshotOK = API.VerifyServerWorld(bound)

        if r.snapshotOK then
            for _, t in r.targets do
                t.verifiedServerAfter, t.verifiedPersistence = t.serverAfter, t.persistenceConfirmed
            end
            local listener
            for _, f in Net.tileChanged.getListeners() do
                if debug.info(f, "s") == "Players." .. game.Players.LocalPlayer.Name .. ".PlayerGui.GameGui.Game" then listener = f; break end
            end
            for _, t in r.targets do
                if t.serverAfter ~= nil and tile(0, t.x, t.y) ~= t.serverAfter and listener then
                    local fixed, why = pcall(listener, {w = Net.worldTag(bound), layer = 1,
                        x = t.x, y = t.y, id = t.serverAfter, flip = false})
                    t.resyncOK, t.resyncError = fixed and tile(0, t.x, t.y) == t.serverAfter, not fixed and tostring(why) or nil
                end
            end
        end
    end
    r.persistedCount = 0
    for _, t in r.targets do if t.verifiedPersistence then r.persistedCount += 1 end end
    local message = not ok and tostring(err) or (not r.snapshotOK and (mode .. ": server unverified")
        or string.format("%s: %d/%d server-verified", mode, r.persistedCount, #targets))
    status(message)
    if S.altLabel then S.altLabel:SetText(message) end
    return r
end

function API.RunSelectedAlternative()
    local mode = S.config.alternative
    local needed = mode == "punch-multi" and 2 or 1
    local preview = API.Preview()
    local targets = {}
    for _, t in preview.queue do
        if t.layer == 0 and #targets < needed then targets[#targets + 1] = {x = t.x, y = t.y, layer = 0} end
    end
    assert(#targets == needed, "Not enough accessible natural tiles in range")
    S.plan = nil
    return API.ProbeAlternative(mode, targets)
end

function API.Recipe(id)
    id = tonumber(id) or 955
    local out = {id = id, name = DB[id] and DB[id].name, recipes = {}}
    for _, r in Recipes do
        if r[3] == id then out.recipes[#out.recipes + 1] = {
            a = r[1], aName = DB[r[1]] and DB[r[1]].name,
            b = r[2], bName = DB[r[2]] and DB[r[2]].name}
        end
    end
    if id == 5667 then
        out.recipes[#out.recipes + 1] = {a = 341, b = 527,
            aName = DB[341].name, bName = DB[527].name, fallback = true}
    end
    for _, set in Splice.SETS do
        if table.find(Splice.setSeeds(set), id) then
            out.recipes[#out.recipes + 1] = {a = set[1], b = set[2], aName = DB[set[1]].name,
                bName = DB[set[2]].name, randomSet = true, possibilities = Splice.setSeeds(set)}
        end
    end
    out.item = DB[id] and {grow = DB[id].grow, hits = DB[id].hits, rarity = DB[id].rarity}
    return out
end
function API.ExportRecipes()
    assert(type(writefile) == "function", "Executor writefile unavailable")
    local rows = {"seed_a\tname_a\tseed_b\tname_b\tresult\tresult_name"}
    local function name(id) return (DB[id] and DB[id].name or "?"):gsub("[\t\r\n]", " ") end
    for _, r in Recipes do rows[#rows + 1] = string.format("%d\t%s\t%d\t%s\t%d\t%s", r[1], name(r[1]), r[2], name(r[2]), r[3], name(r[3])) end
    writefile("growblox-recipes.tsv", table.concat(rows, "\n"))
    return {file = "growblox-recipes.tsv", rows = #Recipes}
end

local function planDirtLayout(fg, db, width, height, topY)
    local left, right = 1, width - 2
    assert(width >= 6 and height >= 8, "World too small")
    topY = math.max(3, math.floor(topY or 3))
    local function cell(x,y) return fg[y] and fg[y][x] end
    local function safeFloor(id)
        local d = db[id or 0]
        return d and not d.hurts and (d.solid == true or d.platform == true)
    end
    local base
    for y = topY, height - 2 do
        if cell(left,y) == 102 and cell(right,y) == 102 then
            local full = true
            for x = left + 1, right - 1 do if not safeFloor(cell(x,y)) then full = false; break end end
            if full then base = y; break end
        end
    end
    assert(base, "No complete demo floor found; build one floor with platform at each end")
    local rows, dirt, platforms, exceptions, blockers = {}, 0, 0, {}, {}
    for y = base - 2, topY, -2 do
        rows[#rows + 1] = y
        for x = left, right do
            local desired = (x == left or x == right) and 102 or 2
            local id = cell(x,y)
            if id == 0 then
                if desired == 2 then dirt += 1 else platforms += 1 end
            elseif id ~= desired then
                local v = {x=x,y=y,id=id}
                if desired == 2 and safeFloor(id) then exceptions[#exceptions + 1] = v else blockers[#blockers + 1] = v end
            end
        end
    end
    return {baseFloor = base, firstRow = rows[1], topY = topY, left = left, right = right,
        rows = rows, dirtPerFloor = right-left-1, platformsPerFloor = 2, step = 2,
        dirtNeeded = dirt, platformsNeeded = platforms, protectedExceptions = exceptions, blockers = blockers}
end
function API.DirtFarmPreview()
    assert(not S.running and not S.busy, "Pause automation before preview")
    local p = planDirtLayout(world.fg, DB, world.w, world.h, S.dirt.config.topY)
    S.dirt.plan, S.dirt.stock = p, refreshLootInventory()
    S.dirt.phase = string.format("%d floors | %d Dirt + %d platform needed", #p.rows, p.dirtNeeded, p.platformsNeeded)
    return p
end
function API.SaveDirtCheckpoint()
    local d = S.dirt
    if not d.cursor or type(writefile) ~= "function" then return end
    local record = {version=1,world=world.name,job=game.JobId,cursor=d.cursor,placed=d.placed,floors=d.floors,phase=d.phase}
    local ok, err = pcall(writefile, d.checkpointFile, game:GetService("HttpService"):JSONEncode(record))
    d.checkpointError = not ok and tostring(err) or nil
end
function API.LoadDirtCheckpoint()
    assert(not S.running and not S.busy, "Pause first")
    local d = S.dirt
    assert(type(readfile)=="function" and type(isfile)=="function" and isfile(d.checkpointFile), "No Dirt Farm checkpoint")
    local p = game:GetService("HttpService"):JSONDecode(readfile(d.checkpointFile))
    assert(p.version==1 and p.world==world.name and p.job==game.JobId, "Checkpoint is from another world/server")
    assert(type(p.cursor)=="table" and type(p.cursor.row)=="number" and type(p.cursor.x)=="number", "Invalid checkpoint")
    d.cursor,d.placed,d.floors,d.phase = p.cursor,p.placed or 0,p.floors or 0,"Checkpoint loaded; toggle ON to resume"
    return d.cursor
end
local function dirtWalk(x, floorY, generation)
    local d, target = S.dirt, x + 0.5
    for attempt=1,3 do
        if not active(generation) then return false end
        local px,py = position()
        assert(math.abs(py-floorY)<0.25 and grounded(), "Return to the build floor/platform before resuming")
        if math.abs(px-target)<=0.4 then return true end

        for sx=math.min(math.floor(px),x),math.max(math.floor(px),x) do
            local floor=DB[tile(0,sx,floorY) or 0]
            assert(floor and not floor.hurts and (floor.solid or floor.platform), "Gap/hazard in the lower support floor")
            local corridorID=tile(0,sx,floorY-1)
            local ownedEntrance=S.farm.running and DB[corridorID] and DB[corridorID].entrance and accessible(sx,floorY-1)
            assert(passable(corridorID) or ownedEntrance, "Walking corridor contains a block/tree; preserved")
        end
        local began,lastX,lastProgress = os.clock(),px,os.clock()
        repeat
            if not active(generation) then releaseMovement(); return false end
            local ax,ay=position()
            assert(math.abs(ay-floorY)<0.4, "Left the support floor; no forced recovery")
            local dx=target-ax
            if math.abs(dx)<=0.4 then
                releaseMovement();task.wait(0.07)
                ax=position()
                if math.abs(ax-target)<=0.45 then return true end
            else
                inputKey(Enum.KeyCode.A,dx<0);inputKey(Enum.KeyCode.D,dx>0)
            end
            if math.abs(ax-lastX)>0.04 then lastX,lastProgress=ax,os.clock() end
            if os.clock()-lastProgress>1 then break end
            task.wait(0.015)
        until os.clock()-began>2+math.abs(target-px)/3
        releaseMovement();task.wait(0.15)
    end
    error("Build walk stalled; checkpoint retained")
end
local function dirtClimb(edge,targetFloor,generation)
    assert(tile(0,edge,targetFloor)==102, "Missing access platform at next floor")
    for _=1,3 do
        if not active(generation) then return false end
        local _,py=position()
        if grounded() and math.abs(py-targetFloor)<0.22 then return true end
        assert(math.abs(py-targetFloor-2)<0.25 and grounded(), "Stand below the access platform")
        dirtWalk(edge,targetFloor+2,generation)
        releaseMovement();inputKey(Enum.KeyCode.Space,true)
        local began=os.clock()
        repeat
            if not active(generation) then releaseMovement();return false end
            if os.clock()-began>=0.2 then inputKey(Enum.KeyCode.Space,false) end
            local px,ay=position()
            inputKey(Enum.KeyCode.A,px>edge+0.75)
            inputKey(Enum.KeyCode.D,px<edge+0.25)
            if os.clock()-began>0.3 and grounded() and math.abs(ay-targetFloor)<0.22 then releaseMovement();return true end
            task.wait(0.02)
        until os.clock()-began>2.5
        releaseMovement();task.wait(0.3)
    end
    error("Native jump did not reach platform; checkpoint retained")
end
local function dirtReachFloor(targetFloor,edge,generation)
    for _=1,math.ceil(world.h/2) do
        local _,py=position()
        if grounded() and math.abs(py-targetFloor)<0.22 then return true end
        local current=math.floor(py+0.2)
        assert(current>targetFloor and (current-targetFloor)%2==0, "Stand on an existing Dirt Farm floor below the new row")
        dirtWalk(edge,current,generation)
        if not dirtClimb(edge,current-2,generation) then return false end
    end
    error("Could not reach builder level")
end
local function dirtAwaitMaterial(id,generation)
    local d=S.dirt
    while active(generation) do
        d.stock=refreshLootInventory()
        if (d.stock[id] or 0)>0 then return d.stock[id] end
        releaseMovement()
        d.phase="Waiting for "..(DB[id] and DB[id].name or tostring(id)).."; toggle stays ON"
        API.SaveDirtCheckpoint()
        task.wait(1)
    end
    return nil
end
function API.StartDirtFarm()
    assert(not S.running and not S.busy,"Pause other automation first")
    assert(not (S.recorder and S.recorder.active),"Stop recording first")
    assert(nativeSetTile,"Native placement helper unavailable")
    local d=S.dirt
    local plan=API.DirtFarmPreview()
    assert(#plan.blockers==0,"An access/air target is occupied; preserved. Inspect preview blockers")
    if #plan.rows==0 then d.phase="Upper layout already complete";return plan end
    local cursor=d.cursor
    if not cursor or cursor.world~=world.name or cursor.job~=game.JobId or cursor.row<plan.topY or cursor.row>plan.firstRow then
        local px=position()
        local direction=math.abs(px-plan.left-0.5)<=math.abs(px-plan.right-0.5) and 1 or -1
        cursor={world=world.name,job=game.JobId,row=plan.firstRow,x=direction==1 and plan.left or plan.right,direction=direction}
        d.cursor=cursor
    end
    S.boundWorld=world.name;S.generation=(S.generation or 0)+1
    local generation=S.generation
    d.running,S.running,S.busy,d.error=true,true,true,nil
    requestToggle("dirt",true)
    S.worker=task.spawn(function()
        task.wait()
        local ok,err=xpcall(function()
            local initialFloors=d.floors
            while active(generation) and cursor.row>=plan.topY do
                local startEdge=cursor.direction==1 and plan.left or plan.right
                if not dirtReachFloor(cursor.row+2,startEdge,generation) then return end
                while active(generation) and cursor.x>=plan.left and cursor.x<=plan.right do
                    local x,y=cursor.x,cursor.row
                    local wanted=(x==plan.left or x==plan.right) and 102 or 2
                    local id=tile(0,x,y)
                    if id==0 then
                        if not dirtAwaitMaterial(wanted,generation) then return end
                        dirtWalk(x,y+2,generation)
                        assert(accessible(x,y) and inRange(x,y),"Build target unavailable/out of range")
                        assert(tile(0,x,y)==0,"Target changed while waiting; preserved")
                        local before=S.dirt.stock[wanted]
                        nativeSetTile("fg",x,y,wanted)
                        task.wait(math.max(0.25,d.config.interval))

                        d.stock=refreshLootInventory()
                        assert(tile(0,x,y)==wanted,"Placement corrected/rejected; not retried blindly")
                        if (d.stock[wanted] or 0)>=before then
                            task.wait(0.4);d.stock=refreshLootInventory()
                            assert((d.stock[wanted] or 0)<before,"Placement has no stock acknowledgement; verify before retry")
                        end
                        d.placed+=1
                        if wanted==2 then plan.dirtNeeded=math.max(0,plan.dirtNeeded-1) else plan.platformsNeeded=math.max(0,plan.platformsNeeded-1) end
                    elseif id~=wanted then
                        local def=DB[id]
                        assert(wanted==2 and def and not def.hurts and (def.solid or def.platform),"Occupied cell cannot be replaced; preserved")
                    end
                    cursor.x+=cursor.direction
                    d.phase="Building row "..y..(cursor.direction==1 and " >" or " <")
                    API.SaveDirtCheckpoint()
                end
                if not active(generation) then return end
                d.floors+=1
                if d.config.rowLimit>0 and d.floors-initialFloors>=d.config.rowLimit then d.phase="Row limit reached; resume continues above";cursor.row-=2;cursor.direction=-cursor.direction;cursor.x=cursor.direction==1 and plan.left or plan.right;return end
                local edge=cursor.direction==1 and plan.right or plan.left
                if cursor.row-2>=plan.topY then
                    dirtWalk(edge,cursor.row+2,generation)
                    if not dirtClimb(edge,cursor.row,generation) then return end
                end
                cursor.row-=2;cursor.direction=-cursor.direction
                cursor.x=cursor.direction==1 and plan.left or plan.right
            end
            d.phase="Upper Dirt Farm layout finished; protected cells kept"
            d.complete=true
        end,debug.traceback)
        releaseMovement()
        d.error=not ok and tostring(err) or nil
        if not ok then d.phase=(tostring(err):match("^[^\r\n]+")) or tostring(err) end
        API.SaveDirtCheckpoint()
        API.Stop("Dirt Farm: "..d.phase)
    end)
    return plan
end

local function planSpecialDirtLayout(fg, bg, db, width, height)
    local leftShaft, rightShaft = 0, width - 1
    local leftPlatform, rightPlatform = 1, width - 2
    local leftDirt, rightDirt = 2, width - 3

    local baseFloor = nil
    for y = height - 2, 1, -1 do
        if fg[y] and fg[y][leftPlatform] == 102 and fg[y][rightPlatform] == 102 then
            baseFloor = y
            break
        end
    end
    baseFloor = baseFloor or 35

    local bedrockTop = height
    for y = baseFloor + 1, height - 1 do
        local count = 0
        for x = 0, width - 1 do
            if fg[y] and fg[y][x] == 8 then count += 1 end
        end
        if count >= width * 0.8 then
            bedrockTop = y
            break
        end
    end

    local floors = {}
    local corridors = {}
    local platformsNeeded = 0
    local dirtNeeded = 0
    local tilesToClearFG = 0
    local tilesToClearBG = 0

    local isDoorArea = function(x, y)
        return (y == 36 and x >= 77 and x <= 79) or (y == 37 and x == 78)
    end

    for floorY = baseFloor + 2, bedrockTop - 1, 2 do
        table.insert(floors, floorY)
        local corridorY = floorY - 1
        table.insert(corridors, corridorY)

        for _, x in ipairs({leftShaft, rightShaft}) do
            for _, y in ipairs({corridorY, floorY}) do
                if not isDoorArea(x, y) then
                    if (fg[y] and fg[y][x] or 0) ~= 0 then tilesToClearFG += 1 end
                    if (bg[y] and bg[y][x] or 0) == 14 then tilesToClearBG += 1 end
                end
            end
        end

        for x = leftPlatform, rightPlatform do
            local y = corridorY
            if not isDoorArea(x, y) then
                if (fg[y] and fg[y][x] or 0) ~= 0 then tilesToClearFG += 1 end
                if (bg[y] and bg[y][x] or 0) == 14 then tilesToClearBG += 1 end
            end
        end

        for _, x in ipairs({leftPlatform, rightPlatform}) do
            local current = fg[floorY] and fg[floorY][x] or 0
            if current ~= 102 then
                platformsNeeded += 1
                if current ~= 0 then tilesToClearFG += 1 end
                if (bg[floorY] and bg[floorY][x] or 0) == 14 then tilesToClearBG += 1 end
            end
        end

        for x = leftDirt, rightDirt do
            if not isDoorArea(x, floorY) then
                local current = fg[floorY] and fg[floorY][x] or 0
                if current == 0 then
                    dirtNeeded += 1
                elseif current ~= 2 and current ~= 8 and current ~= 9640 then
                    tilesToClearFG += 1
                    dirtNeeded += 1
                end
            end
        end
    end

    return {
        baseFloor = baseFloor,
        bedrockTop = bedrockTop,
        floors = floors,
        corridors = corridors,
        platformsNeeded = platformsNeeded,
        dirtNeeded = dirtNeeded,
        tilesToClearFG = tilesToClearFG,
        tilesToClearBG = tilesToClearBG,
        leftShaft = leftShaft, rightShaft = rightShaft,
        leftPlatform = leftPlatform, rightPlatform = rightPlatform,
        leftDirt = leftDirt, rightDirt = rightDirt
    }
end

function API.SpecialDirtFarmPreview()
    assert(not S.running and not S.busy, "Pause automation before preview")
    local p = planSpecialDirtLayout(world.fg, world.bg, DB, world.w, world.h)
    S.specialDirt.plan = p
    S.specialDirt.stock = refreshLootInventory()
    S.specialDirt.phase = string.format("%d floors (%d..%d) | %d Plat + %d Dirt needed",
        #p.floors, p.floors[1] or 0, p.floors[#p.floors] or 0, p.platformsNeeded, p.dirtNeeded)
    return p
end

function API.SaveSpecialDirtCheckpoint()
    local sd = S.specialDirt
    if not sd.cursor or type(writefile) ~= "function" then return end
    local record = {
        version = 1,
        world = world.name,
        job = game.JobId,
        cursor = sd.cursor,
        stats = sd.stats,
        phase = sd.phase
    }
    pcall(writefile, sd.checkpointFile, game:GetService("HttpService"):JSONEncode(record))
end

function API.LoadSpecialDirtCheckpoint()
    assert(not S.running and not S.busy, "Pause first")
    local sd = S.specialDirt
    assert(type(readfile) == "function" and type(isfile) == "function" and isfile(sd.checkpointFile), "No Special Dirt checkpoint")
    local p = game:GetService("HttpService"):JSONDecode(readfile(sd.checkpointFile))
    assert(p.version == 1 and p.world == world.name and p.job == game.JobId, "Checkpoint is from another world/server")
    sd.cursor = p.cursor
    sd.stats = p.stats or sd.stats
    sd.phase = "Checkpoint loaded; toggle ON to resume"
    return sd.cursor
end

function API.StartSpecialDirtFarm()
    assert(not S.running and not S.busy, "Pause other automation first")
    assert(not (S.recorder and S.recorder.active), "Stop recording first")
    assert(nativeSetTile, "Native placement helper unavailable")

    local sd = S.specialDirt
    local plan = API.SpecialDirtFarmPreview()
    if #plan.floors == 0 then
        sd.phase = "All lower floors already complete!"
        return plan
    end

    S.boundWorld = world.name
    S.generation = (S.generation or 0) + 1
    local generation = S.generation
    sd.running, S.running, S.busy = true, true, true
    requestToggle("specialDirt", true)

    local function specialMineCell(x, y, gen)
        if not active(gen) then return false end
        if y < 36 then return true end
        if (y == 36 and x >= 77 and x <= 79) or (y == 37 and x == 78) then return true end

        local px, py = position()
        local distSq = (x + 0.5 - px)^2 + (y + 0.5 - py)^2
        local maxRange = math.min(controls.punchRange() - 0.1, 2.2)
        if distSq > (maxRange + 0.3)^2 then
            return false, "Target out of reach"
        end

        local fgId = tile(0, x, y)
        if fgId and fgId ~= 0 and fgId ~= 8 and fgId ~= 6 and fgId ~= 224 and fgId ~= 9640 then
            local hitsNeeded = (DB[fgId] and DB[fgId].hits and DB[fgId].hits > 0) and DB[fgId].hits or 3
            for _ = 1, hitsNeeded * 3 + 4 do
                if not active(gen) then return false end
                if tile(0, x, y) == 0 then break end
                hit(x, y)
                S.nativeCalls += 1
                sd.stats.mined += 1
                task.wait(math.max(0.24, S.config.interval))
            end
        end

        if tile(0, x, y) == 0 and tile(1, x, y) == 14 then
            for _ = 1, 10 do
                if not active(gen) then return false end
                if tile(1, x, y) == 0 then break end
                hit(x, y)
                S.nativeCalls += 1
                sd.stats.mined += 1
                task.wait(math.max(0.24, S.config.interval))
            end
        end
        return true
    end

    local function specialPlaceTile(x, y, wantedId, gen)
        if not active(gen) then return false end
        if tile(0, x, y) == wantedId then return true end
        if (y == 36 and x >= 77 and x <= 79) or (y == 37 and x == 78) then return true end

        local stock = refreshLootInventory()
        while active(gen) and (stock[wantedId] or 0) <= 0 do
            sd.phase = string.format("Waiting for %s (need 1+)", DB[wantedId] and DB[wantedId].name or tostring(wantedId))
            releaseMovement()
            task.wait(1)
            stock = refreshLootInventory()
        end
        if not active(gen) then return false end

        if tile(0, x, y) ~= 0 and tile(0, x, y) ~= wantedId then
            specialMineCell(x, y, gen)
        end
        if tile(0, x, y) ~= 0 then return false end

        nativeSetTile("fg", x, y, wantedId)
        task.wait(math.max(0.25, sd.config.placeInterval))
        if tile(0, x, y) == wantedId then
            if wantedId == 102 then sd.stats.placedPlatforms += 1
            elseif wantedId == 2 then sd.stats.placedDirt += 1 end
            return true
        end
        return false
    end

    local function walkToX(targetX, gen)
        local px = position()
        local dir = targetX > px and 1 or -1
        local keycode = dir == 1 and Enum.KeyCode.D or Enum.KeyCode.A
        inputKey(keycode, true)
        local began = os.clock()
        repeat
            if not active(gen) then releaseMovement(); return false end
            task.wait(0.04)
            px = position()
        until math.abs(px - targetX) <= 0.35 or os.clock() - began > 1.2
        releaseMovement()
        return math.abs(px - targetX) <= 0.4
    end

    S.worker = task.spawn(function()
        task.wait()
        local ok, err = xpcall(function()
            local curX, curY = position()
            local currentFloorIndex = 1
            for i, fY in ipairs(plan.floors) do
                if math.abs(curY - (fY - 0.001)) <= 1.2 or math.abs(curY - (fY + 0.999)) <= 0.5 then
                    currentFloorIndex = i
                    break
                end
            end

            local function ensureAvatarOnFloor(targetFloorY, gen)
                local px, py = position()

                if py > (targetFloorY + 0.4) then
                    inputKey(Enum.KeyCode.Space, true)
                    task.wait(0.12)
                    inputKey(Enum.KeyCode.Space, false)
                    task.wait(0.2)
                    waitGrounded(2, gen)
                end
            end

            for fIdx = currentFloorIndex, #plan.floors do
                local floorY = plan.floors[fIdx]
                local corridorY = floorY - 1

                ensureAvatarOnFloor(floorY, generation)

                local px, py = position()
                local stepDir = (px < (world.w / 2)) and 1 or -1
                local startX = (stepDir == 1) and 1 or (world.w - 2)
                local endX = (stepDir == 1) and (world.w - 2) or 1

                local startShaft = (stepDir == 1) and 0 or (world.w - 1)
                specialMineCell(startShaft, corridorY, generation)
                specialMineCell(startShaft, floorY, generation)

                local startPlatform = (stepDir == 1) and plan.leftPlatform or plan.rightPlatform
                if tile(0, startPlatform, floorY) ~= 102 then
                    specialPlaceTile(startPlatform, floorY, 102, generation)
                end

                sd.phase = string.format("Floor %d (y=%d) | Tunneling %s", fIdx, floorY, stepDir == 1 and ">" or "<")

                local currentX = math.floor(px)
                if stepDir == 1 and currentX < 1 then currentX = 1 end
                if stepDir == -1 and currentX > (world.w - 2) then currentX = world.w - 2 end

                while active(generation) and ((stepDir == 1 and currentX <= endX) or (stepDir == -1 and currentX >= endX)) do
                    local frontX = currentX + stepDir
                    if (stepDir == 1 and frontX <= endX) or (stepDir == -1 and frontX >= endX) then
                        specialMineCell(frontX, corridorY, generation)
                    end

                    walkToX(currentX + 0.5, generation)
                    specialMineCell(currentX, corridorY, generation)

                    if currentX == plan.leftPlatform or currentX == plan.rightPlatform then
                        if tile(0, currentX, floorY) ~= 102 then
                            specialPlaceTile(currentX, floorY, 102, generation)
                        end
                    else

                        local curFloorTile = tile(0, currentX, floorY)
                        if curFloorTile == 0 then
                            specialPlaceTile(currentX, floorY, 2, generation)
                        end
                    end

                    collectNearby(false)
                    currentX += stepDir
                    API.SaveSpecialDirtCheckpoint()
                end

                if not active(generation) then return end

                local endShaft = (stepDir == 1) and (world.w - 1) or 0
                specialMineCell(endShaft, corridorY, generation)
                specialMineCell(endShaft, floorY, generation)

                local endPlatform = (stepDir == 1) and plan.rightPlatform or plan.leftPlatform
                if tile(0, endPlatform, floorY) ~= 102 then
                    specialPlaceTile(endPlatform, floorY, 102, generation)
                end

                sd.stats.floors += 1

                if fIdx < #plan.floors then
                    local nextFloorY = plan.floors[fIdx + 1]
                    local nextCorridorY = nextFloorY - 1

                    specialMineCell(endPlatform, nextCorridorY, generation)
                    specialMineCell(endShaft, nextCorridorY, generation)

                    if tile(0, endPlatform, nextFloorY) ~= 102 then
                        specialPlaceTile(endPlatform, nextFloorY, 102, generation)
                    end

                    walkToX(endPlatform + 0.5, generation)
                    task.wait(0.3)
                    waitGrounded(2, generation)

                    ensureAvatarOnFloor(nextFloorY, generation)
                end
            end
            sd.phase = "Special Dirt Farm Complete: all lower floors finished!"
            API.SaveSpecialDirtCheckpoint()
        end, debug.traceback)

        releaseMovement()
        sd.running = false
        requestToggle("specialDirt", false)
        if not ok then
            sd.phase = tostring(err):match("^[^\r\n]+") or tostring(err)
            API.Stop("Special Dirt: " .. sd.phase)
        else
            API.Stop("Special Dirt: complete")
        end
    end)
    return plan
end

local Roles = require(RS.Shared.Roles)
local othersSource = "Players." .. game.Players.LocalPlayer.Name .. ".PlayerGui.GameGui.Others"
local nativeLeave
for _, f in filtergc("function", {Constants = {"LeaveWorld", "reset"}}, false) do
    if debug.info(f, "s") == gameSource then nativeLeave = f; break end
end
local peerRegistry
for _, listener in Net.entered.getListeners() do
    if debug.info(listener, "s") == othersSource then
        local candidate = debug.getupvalue(listener, 1)
        if type(candidate) == "table" then peerRegistry = candidate; break end
    end
end
local function staffUser(userId)
    if type(userId) ~= "number" then return false end
    local roles = RS:FindFirstChild("StaffRoles")
    local role = roles and roles:GetAttribute("u" .. tostring(userId))
    if role == "admin" or role == "administrator" or role == "owner" then return true end
    local ok, staff = pcall(Roles.isStaff, userId)
    return ok and staff == true
end
local function utilityDecision(options, roster, selfId)
    if options.leaveStaff then
        for _, person in roster do
            if person.userId ~= selfId and person.staff then return "Staff detected", person.userId end
        end
    end
    if options.leaveCount and #roster >= options.maxPeople then return "Player limit reached", #roster end
    return nil
end
local function utilityRoster()
    local u = S.utilities
    local roster, seen = {}, {}
    local selfId = game.Players.LocalPlayer.UserId
    if not world.name or world.name == "" then return roster end
    roster[1], seen[selfId] = {userId = selfId, staff = false}, true
    if type(peerRegistry) ~= "table" then return nil, "World roster unavailable" end
    for id, entry in peerRegistry do
        local remembered = u.present[id]
        local who = type(entry) == "table" and entry.who or nil
        local uid = remembered and remembered.userId
            or (type(entry) == "table" and entry.userId)
            or (type(who) == "table" and who.userId)
            or (type(who) == "number" and who)
        local key = uid or ("peer:" .. tostring(id))
        if not seen[key] then
            seen[key] = true
            roster[#roster + 1] = {userId = uid, staff = staffUser(uid), peerId = id}
        end
    end
    return roster
end
function API.UtilityStatus()
    local roster, err = utilityRoster()
    local u = S.utilities
    return {ultraFPS = u.ultraFPS, leaveStaff = u.leaveStaff, leaveCount = u.leaveCount,
        maxPeople = u.maxPeople, people = roster and #roster, rosterError = err,
        leaving = u.leaving, leaveReady = nativeLeave ~= nil, lastLeave = u.lastLeave, lastError = u.lastError}
end
function API.CheckUtilities(dryRun)
    local u = S.utilities
    local roster, err = utilityRoster()
    if not roster then u.lastError = err; return nil, err end
    local reason, detail = utilityDecision(u, roster, game.Players.LocalPlayer.UserId)
    if dryRun or not reason or u.leaving then return reason, detail end
    u.leaving, u.lastLeave = true, reason .. ": " .. tostring(detail)

    API.Stop(u.lastLeave)
    local ok, failure = pcall(function()
        assert(nativeLeave, "Native leave handler unavailable; reload before enabling auto leave")
        nativeLeave()
    end)
    restoreExecutorContext()
    if not ok then
        u.leaving, u.lastError = false, tostring(failure)
        status("Leave failed: " .. tostring(failure))
        return nil, failure
    end
    status("Leaving world: " .. u.lastLeave)
    return reason, detail
end
local function utilityListen(packet, callback)
    packet.listen(callback)
    S.utilities.hooks[#S.utilities.hooks + 1] = {packet = packet, callback = callback}
end
utilityListen(Net.entered, function(packet)
    if type(packet) ~= "table" then return end
    S.utilities.present[packet.id] = {userId = packet.userId, name = packet.name}
    task.defer(function() if S.live then API.CheckUtilities(false) end end)
end)
utilityListen(Net.left, function(id) S.utilities.present[id] = nil end)
local function fpsSet(object, property, value)
    local u = S.utilities
    local saved = u.fpsSaved[object]
    if not saved then saved = {}; u.fpsSaved[object] = saved end
    local ok, old = pcall(function() return object[property] end)
    if ok then
        if saved[property] == nil then saved[property] = {value = old} end
        pcall(function() object[property] = value end)
    end
end
function API.SetUltraFPS(enabled)
    local u = S.utilities
    enabled = enabled == true
    if u.ultraFPS == enabled then return end
    u.ultraFPS = enabled
    if enabled then
        local gui = game.Players.LocalPlayer.PlayerGui:FindFirstChild("GameGui")
        local function hideLayer(layer)
            if not layer:IsA("GuiObject") or (layer.Name ~= "World" and layer.Name ~= "WorldFxLayer") then return end
            fpsSet(layer, "Visible", false)
            u.fpsConnections[#u.fpsConnections + 1] = layer:GetPropertyChangedSignal("Visible"):Connect(function()
                if u.ultraFPS and layer.Visible then layer.Visible = false end
            end)
        end
        if gui then
            for _, layer in gui:GetChildren() do hideLayer(layer) end
            u.fpsConnections[#u.fpsConnections + 1] = gui.ChildAdded:Connect(hideLayer)
        end
        local lighting = game:GetService("Lighting")
        fpsSet(lighting, "GlobalShadows", false)
        for _, effect in lighting:QueryDescendants("PostEffect") do fpsSet(effect, "Enabled", false) end
        local ok, quality = pcall(function() return UserSettings():GetService("UserGameSettings") end)
        if ok then fpsSet(quality, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1) end
        local rs = game:GetService("RunService")
        local readOK, rendering = pcall(function() return rs:Is3dRenderingEnabled() end)
        if readOK then
            u.oldRendering = rendering
            pcall(function() rs:Set3dRenderingEnabled(false) end)
        end
        if type(getfpscap) == "function" and type(setfpscap) == "function" then
            local capOK, cap = pcall(getfpscap)
            if capOK then u.oldFPSCap = cap; pcall(setfpscap, 0) end
        end
    else
        for _, connection in u.fpsConnections do connection:Disconnect() end
        table.clear(u.fpsConnections)
        for object, properties in u.fpsSaved do
            for property, original in properties do pcall(function()
                if property == "Visible" and u.leaving then object[property] = false else object[property] = original.value end
            end) end
        end
        table.clear(u.fpsSaved)
        if u.oldRendering ~= nil then pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(u.oldRendering) end); u.oldRendering = nil end
        if u.oldFPSCap ~= nil then pcall(setfpscap, u.oldFPSCap); u.oldFPSCap = nil end
    end
end
function API.CleanupUtilities()
    if API.CleanupPrivacy then API.CleanupPrivacy() end
    API.SetUltraFPS(false)
    for _, hook in S.utilities.hooks do
        local listeners = hook.packet.getListeners()
        local i = table.find(listeners, hook.callback)
        if i then table.remove(listeners, i) end
    end
    table.clear(S.utilities.hooks)
end
task.spawn(function()
    local previousWorld = world.name
    while S.live do
        if previousWorld ~= world.name then
            previousWorld = world.name
            table.clear(S.utilities.present)
            S.utilities.leaving = false
        end
        if S.utilities.leaveStaff or S.utilities.leaveCount then
            local ok, err = pcall(API.CheckUtilities, false)
            if not ok then S.utilities.lastError = tostring(err) end
        end
        if S.utilityLabel then
            local u = API.UtilityStatus()
            pcall(function() S.utilityLabel:SetText(UiText.panel(S.utilities.leaving and "Leaving" or ((S.utilities.leaveStaff or S.utilities.leaveCount) and "Monitoring" or "Idle"), u.lastError) .. string.format("\nWorld: %s\nPlayers: %s", displayPrivacyText(world.name or "-"), tostring(u.people or "?"))) end)
        end
        task.wait(0.5)
    end
end)

local function privacyMask(text,tokens,alias)
    text=tostring(text or "")
    local lower,out,i=text:lower(),{},1
    local function word(c) return c~="" and c:match("[%w_]")~=nil end
    while i<=#text do
        if text:sub(i,i+#alias-1)==alias then out[#out+1]=alias;i+=#alias
        elseif text:sub(i,i)=="<" and text:find(">",i,true) then
            local j=text:find(">",i,true);out[#out+1]=text:sub(i,j);i=j+1
        else
            local match
            for _,token in tokens do
                local n=#token
                if n>0 and lower:sub(i,i+n-1)==token:lower() then
                    local left,right=text:sub(i-1,i-1),text:sub(i+n,i+n)
                    local style=i>=3 and text:sub(i-2,i-2)=="`"
                    if (not word(left) or style) and not word(right) then match=token;break end
                end
            end
            if match then out[#out+1]=alias;i+=#match else out[#out+1]=text:sub(i,i);i+=1 end
        end
    end
    return table.concat(out)
end
local function refreshPrivacyTokens()
    local u=S.privacy
    local player=game.Players.LocalPlayer
    local name,display,gameName=player.Name,player.DisplayName,player:GetAttribute("GameName")
    local signature=table.concat({tostring(name),tostring(display),tostring(gameName),tostring(world.name),tostring(u.hideName),tostring(u.hideWorld)},"\0")
    if signature~=u.signature then
        local tokens,seen={},{}
        local function add(s)
            if type(s)=="string" and s~="" and not seen[s:lower()] then tokens[#tokens+1]=s;seen[s:lower()]=true end
        end
        if u.hideName then add(name);add(display);add(gameName) end
        if u.hideWorld then add(world.name) end
        table.sort(tokens,function(a,b) return #a>#b end)
        u.tokens,u.signature,u.revision=tokens,signature,u.revision+1
    end
end
function API.PrivacyStatus()
    local u=S.privacy
    local total,masked=0,0
    for _,entry in u.bitmaps or {} do total+=1;if entry.masked then masked+=1 end end
    return {hideName=u.hideName,hideWorldName=u.hideWorld,alias=u.alias,active=u.active,
        trackedBitmaps=total,maskedBitmaps=masked,error=u.error}
end
function API.SetHideName(enabled)
    S.privacy.hideName=enabled==true
    refreshPrivacyTokens()
end
function API.SetHideWorldName(enabled)
    S.privacy.hideWorld=enabled==true
    refreshPrivacyTokens()
end
function API.CleanupPrivacy()
    local u=S.privacy
    u.active=false;u.epoch=(u.epoch or 0)+1
    if u.bitmap and u.bitmap._layout==u.wrapper then u.bitmap._layout=u.originalLayout end
    for object in u.bitmaps or {} do
        pcall(function()
            if object.frame and object.frame.Parent then
                local raw=object.text;object.text=nil;u.bitmap.set(object,raw)
            end
        end)
    end
    for label,entry in u.labels or {} do
        pcall(function() if label.Parent and label.Text==entry.shown then label.Text=entry.raw end end)
    end
    for _,c in u.connections or {} do c:Disconnect() end
    if E.BlizzardPrivacyDisplay and E.BlizzardPrivacyDisplay.owner==u then E.BlizzardPrivacyDisplay=nil end
end
function API.InstallPrivacy()
    if E.BlizzardPrivacyDisplay and E.BlizzardPrivacyDisplay.cleanup then E.BlizzardPrivacyDisplay.cleanup() end
    local u=S.privacy
    u.bitmaps=setmetatable({},{__mode="k"});u.labels=setmetatable({},{__mode="k"});u.connections={}
    u.bitmap=require(RS.Shared.BitmapText);u.originalLayout=u.bitmap._layout
    refreshPrivacyTokens()
    displayPrivacyText=function(text) return privacyMask(text,u.tokens or {},u.alias) end
    local function trackBitmap(object)
        if type(object)=="table" and typeof(object.frame)=="Instance" and object.frame:IsDescendantOf(game.Players.LocalPlayer.PlayerGui) then
            if not u.bitmaps[object] then u.bitmaps[object]={revision=-1,at=0} end
        end
    end
    u.wrapper=function(object,text)
        refreshPrivacyTokens()
        trackBitmap(object)
        local masked=displayPrivacyText(text)
        local entry=u.bitmaps[object]
        if entry then entry.masked=masked~=tostring(text or "");entry.revision=u.revision;entry.at=os.clock() end
        return u.originalLayout(object,masked)
    end
    u.bitmap._layout=u.wrapper
    for _,object in filtergc("table",{Keys={"frame","glyphs","text","backGlyphs"}},false) do trackBitmap(object) end
    local function trackLabel(label)
        if label:IsA("TextLabel") and not u.labels[label] then u.labels[label]={raw=label.Text,shown=label.Text,revision=-1} end
    end
    local gui=game.Players.LocalPlayer.PlayerGui
    for _,label in gui:QueryDescendants("TextLabel") do trackLabel(label) end
    u.connections[#u.connections+1]=gui.DescendantAdded:Connect(trackLabel)
    u.active=true;u.epoch=(u.epoch or 0)+1
    local epoch=u.epoch
    E.BlizzardPrivacyDisplay={owner=u,cleanup=API.CleanupPrivacy}
    task.spawn(function()
        while S.live and u.active and u.epoch==epoch do
            refreshPrivacyTokens()
            for object,entry in u.bitmaps do
                if not object.frame or not object.frame.Parent then u.bitmaps[object]=nil
                elseif entry.revision~=u.revision or entry.raw~=object.text or (entry.masked and os.clock()-entry.at>0.75) then
                    local raw=object.text
                    local ok,err=pcall(function()
                        object.text=nil
                        u.bitmap.set(object,raw)
                    end)
                    if ok then entry.raw=raw;entry.revision=u.revision;entry.at=os.clock() else object.text=raw;u.error=tostring(err) end
                end
            end
            for label,entry in u.labels do
                if not label.Parent then u.labels[label]=nil
                else
                    local current=label.Text
                    if current~=entry.shown then entry.raw=current end
                    if entry.revision~=u.revision or current~=entry.shown then
                        local masked=displayPrivacyText(entry.raw)
                        pcall(function() label.Text=masked end)
                        entry.shown,entry.revision=masked,u.revision
                    end
                end
            end
            if S.label and (u.lastStatus~=S.status or u.lastStatusRevision~=u.revision) then
                local text=API.UIStatusText and API.UIStatusText() or (tostring(S.status or "Idle"):match("^[^\r\n]+") or "Idle"):sub(1,110)
                pcall(function() S.label:SetText(displayPrivacyText(text)) end)
                u.lastStatus,u.lastStatusRevision=S.status,u.revision
            end
            task.wait(0.15)
        end
    end)
end
local privacyOK,privacyError=pcall(API.InstallPrivacy)
if not privacyOK then S.privacy.error=tostring(privacyError) end

-- AUTO FARM V1
do
-- FARM_CORE_BEGIN
local FarmCore = {}
function FarmCore.layout(fg, db, width, height, selected)
    local p = {rows = {}, slots = {}, excluded = {}, left = 1, right = width - 2, fingerprint = 1}
    for sy = height - 2, 1, -1 do
        if fg[sy] and fg[sy][p.left] == 102 and fg[sy][p.right] == 102 then
            local row = {floor = sy, y = sy - 1, direction = #p.rows % 2 == 0 and 1 or -1}
            p.rows[#p.rows + 1] = row
            local first, last = row.direction == 1 and 2 or width - 3, row.direction == 1 and width - 3 or 2
            for x = first, last, row.direction do
                local support, id = fg[sy][x], fg[sy - 1] and fg[sy - 1][x]
                p.fingerprint=(p.fingerprint*31+(support or -1)+sy+x)%2147483647
                local d = db[support]
                if d and not d.hurts and not d.lock and not d.entrance and support ~= 8
                    and (d.solid or d.platform) and (id == 0 or id == selected or id == selected + 1) then
                    p.slots[#p.slots + 1] = {x = x, y = sy - 1, floor = sy, row = #p.rows, direction = row.direction, support = support}
                else p.excluded[#p.excluded + 1] = {x = x, y = sy - 1, id = id, support = support} end
            end
        end
    end
    p.capacity = #p.slots
    return p
end
function FarmCore.key(t) return tostring(t.x) .. ":" .. tostring(t.y) end
function FarmCore.ready(t, seed, now)

    return t and t.id == seed.id and type(t.p) == "number" and now >= t.p + seed.grow
end
function FarmCore.step(f, e)
    local id, seed = f.config.item, f.config.item + 1
    local function phase(name) f.phase = name; f.cursor = 1; f.waitReason=nil end
    if f.phase == "prepare" then
        local counts = e.inventory()
        f.plan = e.scan(); assert(#f.plan.rows > 0 and #f.plan.slots > 0, "No accessible farm slots")
        f.cycle += 1
        if next(f.trees) then phase("wait"); return end
        f.remaining = (counts[id] or 0) + e.stored(id) + e.reserved(id)
        f.manifest, f.cashback = {}, 0
        if f.remaining > 0 then phase("place")
        elseif (counts[seed] or 0)+e.stored(seed)+e.reserved(seed)>0 then phase("plant")
        else phase("materials") end
    elseif f.phase=="materials" then
        local counts=e.inventory()
        if (counts[id] or 0)+(counts[seed] or 0)+e.stored(id)+e.stored(seed)+e.reserved(id)+e.reserved(seed)>0 then phase("prepare")
        else f.waitReason="Waiting for selected block / seed";e.idle(1) end
    elseif f.phase == "place" then
        local t = f.plan.slots[f.cursor]
        if not t or f.remaining <= 0 then phase("break"); return end
        if not f.pending and e.canFill and not e.canFill(t) then phase("break");return end
        local k = FarmCore.key(t)
        if not f.pending and e.tile(t) ~= 0 then f.cursor += 1; return end
        if not f.pending then
            local available = e.inventory()[id] or 0
            if available == 0 then assert(e.fetch(id), "Waiting for scheduled block stock"); return end
            f.pending = {kind = "place", target = t, id = id, before = available}
            e.save()
        end
        assert(e.place(f.pending), "Waiting for placement acknowledgement; no blind resend")
        f.manifest[#f.manifest + 1] = {x = t.x, y = t.y, floor = t.floor, row = t.row, direction = t.direction, support = t.support, id = id}
        f.pending = nil; f.remaining -= 1; f.placed += 1; f.cursor += 1
    elseif f.phase == "break" then
        local t = f.manifest[f.cursor]
        if not t then phase("loot"); return end
        if not t.done then
            assert(e.remove(t, false), "Block removal not acknowledged")
            t.done = true; f.broken += 1; e.save()
        end
        e.loot(); f.cursor += 1
    elseif f.phase == "loot" then
        assert(e.sweep(), "Waiting for batch drops / storage")
        for _, t in f.manifest do assert(e.tile(t) == 0, "A batch block reappeared; preserved for reconciliation") end

        f.remaining = e.pool and e.pool(id) or ((f.remaining or 0) + (f.cashback or 0))
        f.manifest, f.cashback = {}, 0
        if f.remaining > 0 then phase("place") else phase("plant") end
    elseif f.phase == "plant" then
        local t = f.plan.slots[f.cursor]
        if not t then phase("wait"); return end
        if not f.pending and e.tile(t) ~= 0 then f.cursor += 1; return end
        if not f.pending then
            if (e.inventory()[seed] or 0) == 0 and not e.fetch(seed) then phase("wait"); return end
            f.pending = {kind = "plant", target = t, id = seed, before = e.inventory()[seed] or 0}
            e.save()
        end
        assert(e.place(f.pending), "Waiting for planting acknowledgement; no blind resend")
        f.trees[FarmCore.key(t)] = t
        f.pending = nil; f.planted += 1; f.cursor += 1
    elseif f.phase == "wait" then
        local total, ripe, eta, soonest = 0, 0, 0, math.huge
        for _, t in f.trees do
            local tree = e.tree(t)
            assert(tree and tree.id == seed, "Tracked tree missing/changed; inspect before resume")
            total += 1
            if e.ripe(tree) then ripe += 1 else local remaining=e.eta(tree);eta=math.max(eta,remaining);soonest=math.min(soonest,remaining) end
        end
        if f.config.harvestMode=="Bertahap" then eta=ripe>0 and 0 or (soonest==math.huge and 0 or soonest) end
        f.totalTrees, f.ripeTrees, f.eta = total, ripe, eta
        if total == 0 then
            assert(e.sweep(), "Waiting for final harvest loot")
            phase("prepare"); e.idle(1)
        elseif ripe > 0 and (f.config.harvestMode == "Bertahap" or ripe == total) then phase("harvest")
        else e.idle(math.min(2, math.max(0.2, eta))) end
    elseif f.phase == "harvest" then
        local t = f.plan.slots[f.cursor]
        if not t then phase("wait"); return end
        local k = FarmCore.key(t)
        if f.trees[k] then
            local tree = e.tree(t)
            assert(tree and tree.id == seed, "Tracked harvest tree changed")
            if e.ripe(tree) then
                assert(e.remove(t, true), "Harvest not acknowledged")
                f.trees[k] = nil; f.harvested += 1; e.save(); e.loot()
            end
        end
        f.cursor += 1
    else error("Unknown farm phase; checkpoint refused") end
    e.save()
end
-- FARM_CORE_END

local f = S.farm
E.BlizzardFarmSafety=E.BlizzardFarmSafety or {}
local seedDB, treeData
local function bindTrees()
    for _, listener in Net.treeChanged.getListeners() do
        if debug.info(listener,"s") == gameSource then
            for _, fun in debug.getupvalues(listener) do
                if type(fun)=="function" and debug.info(fun,"n")=="setTree" then treeData=debug.getupvalue(fun,2) end
            end
        end
    end
    assert(type(treeData)=="table", "Native tree registry unavailable")
end
local function treeAt(t)
    local raw=treeData and treeData[t.y * world.w + t.x]
    local id=tile(0,t.x,t.y)

    if raw and DB[id] and DB[id].kind=="seed" then return {id=id,p=raw.p,fruit=raw.f} end
    return nil
end
local function boxRecords(x,y) return world.displays.get(x,y) or {} end
local function recordId(v) return tonumber(v.i or v.id or v[1]) end
local function recordN(v) return tonumber(v.c or v.n or v[2]) or 0 end
local function boxTotal(id)
    local x = DB[id] and DB[id].kind=="seed" and 0 or world.w-1
    local n=0
    for _,v in boxRecords(x,f.baseFloor) do if recordId(v)==id then n+=recordN(v) end end
    return n
end
local function selectedDrop(d)
    return type(d.uid)=="number" and not d.display and (d.id==f.config.item or d.id==f.config.item+1 or (DB[d.id] and DB[d.id].kind=="gem"))
end
local function syncDeferred()
    local seen, out={},{}
    for _,d in world.dropList() do if selectedDrop(d) then
        local key=tostring(d.uid);seen[key]=true
        local old=f.deferred[key]
        out[key]={uid=d.uid,id=d.id,n=d.n or 1,x=d.x,y=d.y,reserved=old and old.reserved or false}
    end end
    f.deferred=out
end
local function applyTake(uid,before,got)
    local list=world.dropList()
    for i,d in list do if d.uid==uid and d.n==before then
        if got>=before then
            if d.frame then pcall(function() d.frame:Destroy() end) end
            table.remove(list,i)
        else d.n=before-got end
        break
    end end
end
local function farmSave()
    if not f.boundWorld or type(writefile)~="function" then return end
    local out={version=1,world=f.boundWorld,user=game.Players.LocalPlayer.UserId,config=f.config,phase=f.phase,
        manifest=f.manifest,trees=f.trees,deferred=f.deferred,remaining=f.remaining,cashback=f.cashback,
        cursor=f.cursor,pending=f.pending,cycle=f.cycle,placed=f.placed,broken=f.broken,planted=f.planted,harvested=f.harvested}
    local ok,err=pcall(function() writefile(f.checkpointFile,game:GetService("HttpService"):JSONEncode(out)) end)
    f.checkpointError=not ok and tostring(err) or nil
end
API.SaveAutoFarmCheckpoint=farmSave
local function checkSession()
    assert(active(f.generation) and f.running,"Farm stopped/world changed")
    assert(world.respawnedAt==f.respawnedAt,"Respawn detected; inspect position and resume explicitly")
end
local routeFarm
local function walkClear(a,b,floor)
    for x=math.min(a,b),math.max(a,b) do
        local id=tile(0,x,floor-1)
        local d=DB[id]
        if not passable(id) and not (d and d.entrance and accessible(x,floor-1)) then return false end
    end
    return true
end
local function farmWalk(x, floor)
    checkSession()
    assert(world.fg[floor] and world.fg[floor][x]~=nil,"Invalid farm stance")

    local px,py=position()
    if grounded() and math.abs(py-floor)<0.25 and (px<1.1 or px>world.w-1.1) then
        local began=os.clock()
        repeat
            checkSession();px,py=position()
            inputKey(Enum.KeyCode.D,px<1.15);inputKey(Enum.KeyCode.A,px>world.w-1.15)
            task.wait(0.015)
        until (px>=1.15 and px<=world.w-1.15) or os.clock()-began>1
        releaseMovement()
    end
    px=position()
    if not walkClear(math.clamp(math.floor(px),1,world.w-2),x,floor) then
        assert(routeFarm,"Farm navigation not initialized")
        return routeFarm(x,floor)
    end

    dirtWalk(x,floor,f.generation)
    checkSession()
end
local function farmJump(edge,target)
    for _=1,3 do
        checkSession()
        local _,sy=position()
        if grounded() and math.abs(sy-target)<0.25 then return end
        assert(grounded() and sy-target<=2.3 and sy>target,"Unsafe jump launch")
        inputKey(Enum.KeyCode.Space,true)
        local began=os.clock()
        repeat
            checkSession()
            local px,py=position()
            inputKey(Enum.KeyCode.A,px>edge+0.65);inputKey(Enum.KeyCode.D,px<edge+0.35)
            if os.clock()-began>0.2 then inputKey(Enum.KeyCode.Space,false) end
            if os.clock()-began>0.25 and grounded() and math.abs(py-target)<0.25 then releaseMovement();return end
            if os.clock()-began>0.3 and grounded() and py<sy-0.35 and tile(0,edge,math.floor(py+0.2))==102 then
                releaseMovement();return
            end
            task.wait(0.015)
        until os.clock()-began>2.5
        releaseMovement();task.wait(0.2)
    end
    error("Native farm jump did not land on target platform")
end
local function descend(edge, target)
    local outer=edge==1 and 0 or world.w-1
    local _,py=position()
    local current=math.floor(py+0.2)
    while current<target do
        local nextFloor=math.min(target,current+2)
        farmWalk(edge,current)
        inputKey(edge==1 and Enum.KeyCode.A or Enum.KeyCode.D,true)
        local began=os.clock()
        repeat
            checkSession();local px=position()
            if math.abs(px-(outer+0.5))<0.18 then break end
            task.wait(0.015)
        until os.clock()-began>1.5
        releaseMovement()
        began=os.clock()
        repeat
            checkSession()
            local px,ay=position()

            if ay>current+0.02 then
                inputKey(Enum.KeyCode.A,px>edge+0.66);inputKey(Enum.KeyCode.D,px<edge+0.34)
            end
            if grounded() and ay>current+0.35 then
                releaseMovement()
                task.wait(0.12)
                break
            end
            task.wait(0.015)
        until os.clock()-began>3
        releaseMovement()
        local _,landed=position()
        local actual=math.floor(landed+0.2)
        assert(grounded() and math.abs(landed-actual)<0.25,"Native edge descent did not land")
        if actual==f.baseFloor+1 then return end
        assert(actual>current and world.fg[actual] and world.fg[actual][edge]==102,"Landing outside platform graph")
        current=actual
    end
end
local function reachFloor(target,edge)
    checkSession()
    for _=1,#f.plan.rows*3+3 do
        local px,py=position()
        assert(grounded(),"Waiting for physical landing")
        local current=math.floor(py+0.2)
        if current==target then return end
        if current==f.baseFloor+1 and (px<2 or px>world.w-2) then farmJump(edge,f.baseFloor)
        else
            assert(current%2==target%2,"Avatar is not on this farm's support graph")
            if current<target then descend(edge,target)
            else farmWalk(edge,current);farmJump(edge,current-2) end
        end
    end
    error("Platform route made no reliable progress; inspect physical landing")
end
routeFarm=function(x,floor)
    local px,py=position()
    local current=math.floor(py+0.2)
    assert(current==floor,"Reroute must start on the target floor")
    local start=math.clamp(math.floor(px),1,world.w-2)
    local best
    for _,exit in {1,world.w-2} do if walkClear(start,exit,current) then
        for _,entry in {1,world.w-2} do if walkClear(entry,x,floor) then
            for _,row in f.plan.rows do
                if row.floor~=floor and walkClear(1,world.w-2,row.floor) then
                    local cost=math.abs(start-exit)+math.abs(entry-x)+2*math.abs(row.floor-floor)+world.w
                    if not best or cost<best.cost then best={exit=exit,entry=entry,floor=row.floor,cost=cost} end
                end
            end
        end end
    end end
    assert(best,"No safe crossing floor; keep batch intact and inspect")
    farmWalk(best.exit,current)
    reachFloor(best.floor,best.exit)
    farmWalk(best.entry,best.floor)
    reachFloor(floor,best.entry)
    farmWalk(x,floor)
end
local function moveTo(t,placing)
    local _,py=position()
    local current=math.floor(py+0.2)
    local edge=t.direction==1 and 1 or world.w-2
    if current~=t.floor then reachFloor(t.floor,edge) end
    local id=placing and f.config.item or tile(0,t.x,t.y)

    local px, ay=position()
    if placing and DB[id] and not DB[id].solid and not DB[id].hurts and grounded()
        and math.abs(ay-t.floor)<0.25 and math.abs(px-t.x-0.5)>=0.95 then
        local reach=type(controls.buildRange)=="function" and math.min(2.2,controls.buildRange()) or 2.2
        if (px-t.x-0.5)^2+(ay-t.y-0.5)^2<=reach^2 and accessible(t.x,t.y)
            and inRange(t.x,t.y) and canMineFrom(px,ay,t.x,t.y) then return end
    end
    local stance
    if placing then stance=DB[id] and DB[id].solid and t.x+t.direction or t.x-t.direction
    else stance=px>t.x+0.5 and t.x+1 or t.x-1 end
    if not placing and tile(0,t.x,t.y)==0 then return end
    if not passable(tile(0,stance,t.y)) then
        local other=stance==t.x+1 and t.x-1 or t.x+1
        assert(passable(tile(0,other,t.y)),"No safe stance beside target; preserve it")
        stance=other
    end
    farmWalk(stance,t.floor)
    assert(accessible(t.x,t.y) and inRange(t.x,t.y),"Target permission/range changed")
end
local function inventoryNow() f.counts=refreshLootInventory();return f.counts end
local function waitStock(id,before,delta)
    for _=1,6 do
        checkSession();task.wait(0.15)
        local counts=inventoryNow()
        if (counts[id] or 0)==before+delta then return true end
    end
    return false
end
local function store(id,amount)
    local counts=inventoryNow();local have=counts[id] or 0;local n=math.min(have,amount or have)
    if n==0 then return true end
    local x=DB[id].kind=="seed" and 0 or world.w-1
    local edge=x==0 and 1 or world.w-2
    reachFloor(f.baseFloor,edge);farmWalk(edge,f.baseFloor)
    assert(tile(0,x,f.baseFloor)==1422,"Storage box removed/changed")
    local beforeBox=boxTotal(id)
    local mixed=false
    for _,v in boxRecords(x,f.baseFloor) do if recordId(v)~=id then mixed=true end end
    if not mixed then world.displayPut(x,f.baseFloor,id,n,0.5);restoreExecutorContext() end
    local accepted=not mixed and waitStock(id,have,-n)
    if accepted and boxTotal(id)==beforeBox+n then f.stored=(f.stored or 0)+n;return true end

    counts=inventoryNow();local left=counts[id] or 0
    if left==0 then error("Deposit inventory changed but box not confirmed; inspect storage") end
    local dropCallback
    for _,fn in filtergc("function",{Constants={"lastDropAt","displayHere"}},false) do
        if debug.info(fn,"s")==gameSource then dropCallback=fn;break end
    end
    assert(dropCallback,"Box refused and native drop callback unavailable")

    local fallback=math.min(left,math.max(0,n-(have-left)))
    assert(fallback>0,"Partial deposit needs storage reconciliation")
    dropCallback(id,fallback)
    restoreExecutorContext()
    assert(waitStock(id,left,-fallback),"Box/drop refused; waiting, toggle remains ON")
    syncDeferred()
    for _,v in f.deferred do if v.id==id then v.reserved=true end end
    f.storageWarning="Box refused; normal drop fallback used; loose items tracked"
    return true
end
local function fetch(id)
    if (inventoryNow()[id] or 0)>0 then return true end
    local x=DB[id].kind=="seed" and 0 or world.w-1
    local records=boxRecords(x,f.baseFloor)
    if boxTotal(id)>0 then
        for _,v in records do assert(recordId(v)==id,"Storage contains other items; preserved") end
        local edge=x==0 and 1 or world.w-2
        reachFloor(f.baseFloor,edge);farmWalk(edge,f.baseFloor)
        local before=boxTotal(id)
        world.displayTake(x,f.baseFloor,0.5);restoreExecutorContext()
        for _=1,8 do
            checkSession();task.wait(0.15)
            local n=inventoryNow()[id] or 0
            if n>0 and n<=200 and boxTotal(id)==before-n then return true end
        end
        error("Withdraw not confirmed; inspect box before retry")
    end
    syncDeferred()
    for _,d in f.deferred do if d.id==id and d.reserved then
        local row
        for _,r in f.plan.rows do if math.abs(d.y-r.floor)<1.6 then row=r;break end end
        assert(row,"Stored loose drop is outside safe farm route")
        reachFloor(row.floor,d.x<world.w/2 and 1 or world.w-2)
        farmWalk(math.clamp(math.floor(d.x),1,world.w-2),row.floor)
        local got=world.takeDrop(d.uid,math.min(200,d.n));restoreExecutorContext()
        assert(type(got)=="number","Unexpected reserved-drop reply")
        if got>0 then applyTake(d.uid,d.n,got) end
        return (inventoryNow()[id] or 0)>0
    end end
    return false
end
local function loot()
    checkSession()
    local counts=inventoryNow()
    for _,id in {f.config.item,f.config.item+1} do if (counts[id] or 0)>=180 then store(id) end end
    local px,py=position()
    for _,d in table.clone(world.dropList()) do
        if selectedDrop(d) and not d.pending and not (f.deferred[tostring(d.uid)] and f.deferred[tostring(d.uid)].reserved)
            and (d.x-px)^2+(d.y-py)^2<=2.2^2 then
            counts=inventoryNow()
            local gem=DB[d.id] and DB[d.id].kind=="gem"
            if gem then
                -- Anti-magnet fix: gems require native physical avatar touch, not remote takeDrop packet.
                local targetX = math.clamp(math.floor(d.x + 0.5), 1, world.w - 2)
                local curX = position()
                if math.abs(curX - (targetX + 0.5)) > 0.3 then
                    farmWalk(targetX, math.floor(py + 0.2))
                end
                task.wait(0.04)
                f.gems = (f.gems or 0) + (d.n or 1)
                applyTake(d.uid, d.n or 1, d.n or 1)
            else
                local want=math.max(0,200-(counts[d.id] or 0))
                if want>0 then
                    local beforeN=d.n or 1
                    local got=world.takeDrop(d.uid,math.min(want,d.n or 1));restoreExecutorContext()
                    assert(type(got)=="number","Unexpected loot response")
                    if got>0 then
                        if d.id==f.config.item and (f.phase=="break" or f.phase=="loot") then f.cashback=(f.cashback or 0)+got end
                        applyTake(d.uid,beforeN,got)
                    end
                end
            end
        end
    end
    syncDeferred();inventoryNow()
end
local function sweep()
    for _=1,20 do
        checkSession()
        local pending=false
        for _,d in world.dropList() do if selectedDrop(d) and d.pending then pending=true;break end end
        if not pending then break end
        task.wait(0.1)
    end
    for _,d in world.dropList() do if selectedDrop(d) and d.pending then return false end end
    loot()
    local targets={}
    for _,d in f.deferred do if not d.reserved then targets[#targets+1]=d end end
    table.sort(targets,function(a,b) return a.y>b.y or (a.y==b.y and a.x<b.x) end)
    for _,d in targets do
        checkSession()
        local row
        for _,r in f.plan.rows do if math.abs(d.y-r.floor)<1.6 then row=r;break end end
        assert(row,"A drop is outside the safe route; waiting for inspection")
        reachFloor(row.floor,d.x<world.w/2 and 1 or world.w-2)
        local sx=math.clamp(math.floor(d.x + 0.5),1,world.w-2)
        if passable(tile(0,sx,row.y)) then
            farmWalk(sx,row.floor)
            task.wait(0.05)
        else
            error("Drop route occupied; retained in tracking")
        end
        loot()
    end
    syncDeferred()
    for _,d in f.deferred do if not d.reserved then return false end end
    return true
end
local function scan()
    bindTrees()
    local p=FarmCore.layout(world.fg,DB,world.w,world.h,f.config.item)
    assert(#p.rows>0,"Dirt farm platforms not found")
    f.baseFloor=p.rows[1].floor
    assert(tile(0,0,f.baseFloor)==1422 and tile(0,world.w-1,f.baseFloor)==1422,"Two bottom Display Boxes required")
    for _,t in p.slots do if not accessible(t.x,t.y) then t.noAccess=true end end
    local allowed={}
    for _,t in p.slots do if not t.noAccess then allowed[#allowed+1]=t end end
    p.slots=allowed;p.capacity=#allowed
    if f.testSlotLimit then
        while #p.slots>f.testSlotLimit do table.remove(p.slots) end
    end
    return p
end
local function stopFarmStride()
    f.strideGeneration=(f.strideGeneration or 0)+1
    releaseMovement()
end
local function beginFarmStride(t)
    local def=DB[f.config.item]
    if not def or def.solid or def.hurts or (t.direction~=1 and t.direction~=-1) then return end
    local px,py=position()
    local nx=math.floor(px)+t.direction
    if nx<1 or nx>world.w-2 or math.abs(py-t.floor)>0.25 or not grounded() then return end
    local support=DB[tile(0,nx,t.floor) or 0]
    if not support or support.hurts or not (support.solid or support.platform) or not passable(tile(0,nx,t.y)) then return end
    f.strideGeneration=(f.strideGeneration or 0)+1
    local token=f.strideGeneration
    local direction=t.direction
    inputKey(direction==1 and Enum.KeyCode.D or Enum.KeyCode.A,true)
    task.spawn(function()
        local start=os.clock()
        while S.live and S.running and f.running and f.strideGeneration==token do
            local x,y=position()
            if os.clock()-start>=0.22 or (x-px)*direction>=0.55 or math.abs(y-t.floor)>0.25 or not grounded()
                or not passable(tile(0,nx,t.y)) then break end
            task.wait(0.015)
        end
        if f.strideGeneration==token then releaseMovement() end
    end)
end
local function put(p)
    stopFarmStride()
    checkSession()
    local t=p.target
    assert(tile(0,t.x,t.floor)==t.support,"Support changed; preserved")
    if not p.sent then
        assert(tile(0,t.x,t.y)==0,"Target occupied; no overwrite/splice")
        moveTo(t,true)
        local delay=math.max(0,0.15-(os.clock()-(f.lastPlaceSent or -math.huge)))
        if delay>0 then task.wait(delay);checkSession() end
        assert(grounded() and accessible(t.x,t.y) and inRange(t.x,t.y),"Unsafe placement stance")
        assert(tile(0,t.x,t.y)==0 and not treeAt(t),"Target changed during movement")
        p.before=inventoryNow()[p.id] or 0
        assert(p.before>0,"No stock for placement")
        p.sent=true;farmSave()
        f.lastPlaceSent=os.clock()
        nativeSetTile("fg",t.x,t.y,p.id)
        if p.kind=="place" then beginFarmStride(t) end
    end
    local deadline=os.clock()+0.9
    local pause=0.04
    repeat
        checkSession()
        local stock=inventoryNow()[p.id] or 0
        if p.kind=="plant" then
            local tree=treeAt(t)
            if tree and tree.id==p.id and type(tree.p)=="number" then return true end
        elseif stock==p.before-1 and tile(0,t.x,t.y)==p.id then return true end
        if os.clock()>=deadline then break end
        task.wait(math.min(pause,deadline-os.clock()))
        pause=math.min(0.16,pause*2)
    until false
    stopFarmStride()
    return false
end
local function remove(t,harvest)
    stopFarmStride()
    checkSession()
    local expected=harvest and f.config.item+1 or f.config.item
    if tile(0,t.x,t.y)==0 and not treeAt(t) then return true end
    assert(tile(0,t.x,t.y)==expected,"Unrelated target replaced batch member; preserved")
    if harvest then assert(treeAt(t) and FarmCore.ready(treeAt(t),seedDB,workspace:GetServerTimeNow()),"Tree isn't ripe") end
    moveTo(t,false)

    for attempt=1,(DB[expected].hits or 1)*3+6 do
        checkSession()
        if tile(0,t.x,t.y)~=expected then break end
        assert(accessible(t.x,t.y) and inRange(t.x,t.y) and grounded(),"Unsafe crop hit stance")
        hit(t.x,t.y);S.nativeCalls+=1
        task.wait(f.interval)
        if attempt>math.max(2,DB[expected].hits or 1) then f.interval=math.min(0.6,f.interval+0.05) end
    end
    task.wait(0.2)
    local broken = tile(0,t.x,t.y)==0 and (not harvest or not treeAt(t))
    if broken then
        -- Physically walk directly into the broken tile to collide with and collect dropped gems!
        -- No remote magnet packets for gems (patched by anticheat).
        farmWalk(t.x, t.floor)
        task.wait(0.04)
    end
    return broken
end
local env={inventory=inventoryNow,scan=scan,stored=boxTotal,fetch=fetch,tile=function(t)return tile(0,t.x,t.y)end,
    place=put,remove=remove,tree=treeAt,loot=loot,sweep=sweep,save=farmSave,
    ripe=function(tree)return FarmCore.ready(tree,seedDB,workspace:GetServerTimeNow())end,
    eta=function(tree)return math.max(0,tree.p+seedDB.grow-workspace:GetServerTimeNow())end,
    pool=function(id) syncDeferred();local n=(inventoryNow()[id] or 0)+boxTotal(id);for _,d in f.deferred do if d.id==id then n+=d.n end end;return n end,
    canFill=function(t)
        if not DB[f.config.item].solid then return true end

        for _,row in f.plan.rows do if row.floor~=t.floor and walkClear(1,world.w-2,row.floor) then return true end end
        return false
    end,
    reserved=function(id) syncDeferred();local n=0 for _,d in f.deferred do if d.id==id and d.reserved then n+=d.n end end return n end,
    idle=function(seconds) releaseMovement();task.wait(seconds) end}
API.AutoFarmCore=FarmCore
function API.PreviewAutoFarm()
    assert(not S.running and not S.busy,"Stop other automation before preview")
    assert(DB[f.config.item] and DB[f.config.item].farmable and DB[f.config.item+1] and DB[f.config.item+1].kind=="seed","Select a farmable block/seed pair")
    f.plan=scan();assert(f.plan.capacity>0,"No accessible crop slots");f.counts=inventoryNow();syncDeferred()
    local safety=E.BlizzardFarmSafety[f.config.item]
    local validated=safety and safety.world==world.name and safety.job==game.JobId and safety.fingerprint==f.plan.fingerprint
    local blocked=(DB[f.config.item].hurts or DB[f.config.item].solid) and not validated
    f.message=blocked and "Solid/hazard item locked pending live safety validation" or "Ready - toggle ON"
    return {world=world.name,rows=#f.plan.rows,capacity=f.plan.capacity,excluded=f.plan.excluded,counts=f.counts,
        seedStored=boxTotal(f.config.item+1),blockStored=boxTotal(f.config.item),ready=not blocked,
        reason=blocked and f.message or nil}
end
function API.AutoFarmItems()
    if not f.baseFloor then local ok,p=pcall(scan);if ok then f.plan=p end end
    local candidates={[f.config.item]=true}
    for _,v in inventory.slots do local id=DB[v.id] and DB[v.id].kind=="seed" and v.id-1 or v.id;candidates[id]=true end
    if f.baseFloor then for _,x in {0,world.w-1} do for _,v in boxRecords(x,f.baseFloor) do local id=recordId(v);if id then candidates[DB[id] and DB[id].kind=="seed" and id-1 or id]=true end end end end
    local labels,map={},{}
    for id in candidates do if DB[id] and DB[id].farmable and DB[id+1] and DB[id+1].kind=="seed" then
        local label=DB[id].name.." ["..id.."]";labels[#labels+1]=label;map[label]=id
    end end
    table.sort(labels);return labels,map
end
function API.ConfigureAutoFarm(item,mode)
    assert(not f.running,"Turn Auto Farm OFF before changing item/mode")
    assert(mode=="Bertahap" or mode=="Tunggu Semua Matang","Unknown harvest mode")
    assert(DB[item] and DB[item].farmable and DB[item+1] and DB[item+1].kind=="seed","Invalid farm item")
    if item~=f.config.item then
        if f.pending and not f.pending.sent and tile(0,f.pending.target.x,f.pending.target.y)==0 then f.pending=nil end
        local unfinished=false
        for _,t in f.manifest do if not t.done or tile(0,t.x,t.y)~=0 then unfinished=true end end
        assert(not next(f.trees) and not unfinished and not f.pending,"Finish/resume the old batch before switching item")
        f.manifest={}
        f.phase="prepare";f.cursor=1;f.remaining=nil
    end
    f.config.item=item;f.config.harvestMode=mode
end
function API.LoadAutoFarmCheckpoint()
    assert(not S.running and not S.busy,"Pause first")
    assert(type(isfile)=="function" and isfile(f.checkpointFile),"No Auto Farm checkpoint")
    local p=game:GetService("HttpService"):JSONDecode(readfile(f.checkpointFile))
    assert(p.version==1 and p.world==world.name and p.user==game.Players.LocalPlayer.UserId,"Checkpoint belongs to another world/account")
    assert(type(p.config)=="table" and p.config.item==f.config.item,"Select checkpoint's item first")
    local plan=scan();local valid={}
    for _,t in plan.slots do valid[FarmCore.key(t)]=t end
    assert(({prepare=true,materials=true,place=true,["break"]=true,loot=true,plant=true,wait=true,harvest=true})[p.phase],"Invalid checkpoint phase")
    assert(type(p.cursor)=="number" and p.cursor>=1 and p.cursor<=#plan.slots+1,"Invalid checkpoint cursor")
    assert(p.config.harvestMode=="Bertahap" or p.config.harvestMode=="Tunggu Semua Matang","Invalid harvest mode")
    for i,t in p.manifest or {} do
        local canonical=valid[FarmCore.key(t)];assert(canonical and t.id==f.config.item,"Manifest no longer matches safe farm geometry")
        local copy=table.clone(canonical);copy.id=f.config.item;copy.done=t.done==true;p.manifest[i]=copy
    end
    for k,t in p.trees or {} do
        local canonical=valid[FarmCore.key(t)];assert(canonical and k==FarmCore.key(t) and treeAt(t) and treeAt(t).id==f.config.item+1,"Checkpoint tree changed")
        p.trees[k]=table.clone(canonical)
    end
    if p.pending then
        local canonical=valid[FarmCore.key(p.pending.target)]
        assert(canonical and (p.pending.id==f.config.item or p.pending.id==f.config.item+1),"Invalid pending operation")
        p.pending.target=table.clone(canonical)
    end
    for _,k in {"phase","manifest","trees","deferred","remaining","cashback","cursor","pending","cycle","placed","broken","planted","harvested"} do f[k]=p[k] end
    f.config=p.config;f.plan=plan;f.boundWorld=world.name;f.message="Checkpoint loaded, OFF - toggle ON to resume"
    return {phase=f.phase,manifest=#f.manifest}
end
function API.StopAutoFarm()
    if f.running then API.Stop("Auto Farm OFF") end
end
function API.StartAutoFarm(options)
    assert(not S.running and not S.busy,"Pause other automation first")
    if not f.boundWorld and type(isfile)=="function" and isfile(f.checkpointFile) then
        local p=game:GetService("HttpService"):JSONDecode(readfile(f.checkpointFile))
        if p.world==world.name and p.user==game.Players.LocalPlayer.UserId then
            local unfinished=p.pending or next(p.trees or {}) or #(p.manifest or {})>0 or (p.phase~="prepare" and p.phase~="wait")
            if unfinished then
                assert(p.config.item==f.config.item,"Unfinished checkpoint for another item; select that item and load checkpoint first")
                API.LoadAutoFarmCheckpoint()
            end
        end
    end
    local preview=API.PreviewAutoFarm();assert(preview.ready,preview.reason)
    assert(nativeSetTile and not S.inputError,"Native placement/input unavailable")
    seedDB={id=f.config.item+1,grow=DB[f.config.item+1].grow}
    assert(type(seedDB.grow)=="number","Missing seed grow time")
    if options then
        for _,key in {"maxPlacements","slotLimit","maxCycles"} do
            local n=options[key]
            assert(n==nil or type(n)=="number" and n%1==0 and n>=1 and n<=3,"Diagnostic limits must be integers 1..3")
        end
    end
    S.generation=(S.generation or 0)+1
    f.generation=S.generation;f.boundWorld=world.name;S.boundWorld=world.name;f.respawnedAt=world.respawnedAt
    f.testLimit=options and options.maxPlacements;f.testStartPlaced=f.placed
    f.testSlotLimit=options and options.slotLimit
    f.testCycleLimit=options and options.maxCycles;f.testStartCycle=f.cycle-(f.phase~="prepare" and 1 or 0)
    if f.testSlotLimit then while #f.plan.slots>f.testSlotLimit do table.remove(f.plan.slots) end end
    f.running,S.running,S.busy=true,true,true
    requestToggle("farm",true)
    S.worker=task.spawn(function()
        local failures=0
        while S.live and f.running do
            local ok,err=xpcall(function()
                checkSession()
                if f.testLimit and f.phase=="place" and f.placed-f.testStartPlaced>=f.testLimit then
                    f.remaining=0;f.phase="break";f.cursor=1
                end
                FarmCore.step(f,env)
            end,debug.traceback)
            releaseMovement()
            if ok then failures=0;f.error=nil;f.message=f.waitReason or f.phase
            else
                failures+=1;f.error=tostring(err);f.message="Waiting: "..tostring(err):match("^[^\r\n]+")
                farmSave()
                if failures>=3 then
                    f.needsAttention=true
                    repeat task.wait(0.25) until not f.running or f.resumeRequested or not S.live
                    f.resumeRequested=nil;f.needsAttention=false;failures=0
                else task.wait(2^(failures-1)) end
            end
            if f.testLimit and f.phase=="loot" then f.message="Bounded test reached loot";API.Stop("Auto Farm bounded test");break end
            if f.testCycleLimit and f.phase=="prepare" and f.cycle-f.testStartCycle>=f.testCycleLimit then
                f.message="Bounded farm cycle complete";API.Stop("Auto Farm bounded cycle");break
            end
            task.wait(0.02)
        end
        releaseMovement();farmSave()
    end)
    return preview
end
function API.ResumeAutoFarm()
    assert(f.running and f.needsAttention,"No waiting Auto Farm worker")
    assert(world.name==f.boundWorld,"Return to the bound world first")

    f.respawnedAt=world.respawnedAt;f.resumeRequested=true
end
-- Explicit bounded diagnostics;
function API.ProbeAutoFarm(action,args)
    assert(not S.running and not S.busy,"Pause automation before diagnostics")
    args=args or {};f.plan=scan()
    seedDB={id=f.config.item+1,grow=DB[f.config.item+1].grow}
    S.generation=(S.generation or 0)+1;f.generation=S.generation
    f.boundWorld=world.name;S.boundWorld=world.name;f.respawnedAt=world.respawnedAt
    S.running,S.busy,f.running=true,true,true
    local result={action=action,target=args,started=os.clock()}
    local ok,err=xpcall(function()
        if action=="navigate" then
            local found=false for _,r in f.plan.rows do if r.floor==args.floor then found=true end end
            assert(found and (args.edge==1 or args.edge==world.w-2),"Diagnostic target isn't a farm platform")
            reachFloor(args.floor,args.edge)
        elseif action=="deposit" then
            assert(args.id==f.config.item or args.id==f.config.item+1,"Unselected diagnostic item")
            assert(args.amount==1,"Diagnostic deposit limited to one item")
            store(args.id,1)
        elseif action=="withdraw" then
            assert(args.id==f.config.item or args.id==f.config.item+1,"Unselected diagnostic item")
            local before=inventoryNow()[args.id] or 0
            local n=boxTotal(args.id)
            assert(n==1 and before<200,"Withdraw diagnostic limited to a box containing one item")
            local x=DB[args.id].kind=="seed" and 0 or world.w-1
            for _,r in boxRecords(x,f.baseFloor) do assert(recordId(r)==args.id,"Other stored item preserved") end
            local edge=x==0 and 1 or world.w-2
            reachFloor(f.baseFloor,edge);farmWalk(edge,f.baseFloor)
            world.displayTake(x,f.baseFloor,0.5);restoreExecutorContext()
            assert(waitStock(args.id,before,1) and boxTotal(args.id)==0,"Withdraw diagnostic not confirmed")
        elseif action=="safety" then
            assert(not next(f.trees) and #f.manifest<=1 and not f.pending,"Finish current batch before safety calibration")
            local target=f.plan.slots[1]
            local member=f.manifest[1]
            if member then
                assert(f.phase=="break" and member.id==f.config.item and FarmCore.key(member)==FarmCore.key(target),"Only the tracked calibration block may resume")
            else
                assert(target and tile(0,target.x,target.y)==0,"Bottom-left calibration slot isn't empty")
                assert((inventoryNow()[f.config.item] or 0)>0,"One block required for safety calibration")
                f.pending={kind="place",target=target,id=f.config.item,before=f.counts[f.config.item]}
                f.phase="place";farmSave()
                assert(put(f.pending),"Safety placement not confirmed")
                member=table.clone(target);member.id=f.config.item
                f.manifest={member};f.pending=nil;f.phase="break";farmSave()
            end
            task.wait(0.75);checkSession()
            local px,py=position()
            assert(math.abs(px-target.x-0.5)>=0.9 and math.abs(py-target.floor)<0.25,"Unsafe distance from crop")
            assert(remove(member,false),"Safety crop couldn't be removed")
            member.done=true;f.manifest={};f.phase="prepare";f.cursor=1
            loot();task.wait(0.4);checkSession()
            E.BlizzardFarmSafety[f.config.item]={world=world.name,job=game.JobId,fingerprint=f.plan.fingerprint,at=os.clock()}
            result.item=f.config.item;result.noRespawn=true;result.fingerprint=f.plan.fingerprint
        elseif action=="plant" or action=="harvest" then
            local target
            for _,t in f.plan.slots do if t.x==args.x and t.y==args.y then target=t;break end end
            assert(target,"Diagnostic target isn't a safe crop slot")
            if action=="plant" then
                local op={kind="plant",target=target,id=f.config.item+1,before=inventoryNow()[f.config.item+1] or 0}
                f.pending=op;farmSave();assert(put(op),"Plant probe not confirmed")
                f.pending=nil;f.trees[FarmCore.key(target)]=target
                result.tree=treeAt(target)
            else
                assert(f.trees[FarmCore.key(target)],"Probe may only harvest its own tracked tree")
                assert(remove(target,true),"Harvest probe not confirmed")
                f.trees[FarmCore.key(target)]=nil;loot()
            end
        else error("Unknown bounded diagnostic action") end
    end,debug.traceback)
    result.ok=ok;result.error=not ok and tostring(err) or nil;result.elapsed=os.clock()-result.started
    f.lastProbe=result
    API.Stop("Auto Farm diagnostic finished")
    if not ok then error(err) end
    return result
end
function API.AutoFarmStatus()
    local loose=0 for _,d in f.deferred do loose+=d.n end
    return {running=f.running,phase=f.phase,message=f.message,error=f.error,needsAttention=f.needsAttention or false,
        rows=f.plan and #f.plan.rows or 0,row=f.plan and f.plan.slots[f.cursor or 1] and f.plan.slots[f.cursor or 1].row,
        batch=#f.manifest,cursor=f.cursor or 1,block=f.counts and f.counts[f.config.item] or 0,
        seed=f.counts and f.counts[f.config.item+1] or 0,trees=f.totalTrees or 0,ripe=f.ripeTrees or 0,eta=f.eta or 0,
        gems=f.gems or 0,loose=loose,placed=f.placed,broken=f.broken,planted=f.planted,harvested=f.harvested,
        storageWarning=f.storageWarning,checkpointError=f.checkpointError}
end
end

do
    local encodedLogo = "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"
    function API.ResolveBrandLogo()
        local register = getcustomasset or getsynasset
        if type(register) ~= "function" or type(writefile) ~= "function" or type(makefolder) ~= "function" then
            S.logoError = "Custom assets unavailable"
            return "mountain-snow"
        end
        local ok, asset = pcall(function()
            local path = "BeverlyHub/Growblox/assets"
            for _, folder in {"BeverlyHub", "BeverlyHub/Growblox", path} do
                if not isfolder(folder) then makefolder(folder) end
            end
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            local bytes, accumulator, bits = {}, 0, 0
            for i = 1, #encodedLogo do
                local value = alphabet:find(encodedLogo:sub(i, i), 1, true)
                if value then
                    accumulator = accumulator * 64 + value - 1
                    bits += 6
                    if bits >= 8 then
                        bits -= 8
                        bytes[#bytes + 1] = string.char(math.floor(accumulator / 2 ^ bits) % 256)
                        accumulator %= 2 ^ bits
                    end
                end
            end
            local file = path .. "/fluffy-hub.png"
            writefile(file, table.concat(bytes))
            local uri = register(file)
            assert(type(uri) == "string" and uri ~= "", "Custom asset registration failed")
            return uri
        end)
        if not ok then S.logoError = UiText.line(asset); return "mountain-snow" end
        S.logoError, S.logoAsset = nil, asset
        return asset
    end
end

function API.SetAutoFarmEnabled(enabled)
    S.farmUiEpoch = (S.farmUiEpoch or 0) + 1
    local epoch = S.farmUiEpoch
    if not enabled then
        S.farmUiStarting = false
        if S.farmUiTask then pcall(task.cancel, S.farmUiTask); S.farmUiTask = nil end
        API.StopAutoFarm()
        return
    end
    if S.farm.running then return end
    S.farmUiStarting = true
    S.farm.error = nil
    S.farmUiTask = task.spawn(function()
        local ok, err = xpcall(function()
            local started, result = pcall(API.StartAutoFarm)
            if not started and tostring(result):find("Solid/hazard item locked", 1, true) then
                API.ProbeAutoFarm("safety")
                if epoch ~= S.farmUiEpoch then return end
                API.StartAutoFarm()
            elseif not started then error(result, 0) end
        end, debug.traceback)
        if epoch ~= S.farmUiEpoch then return end
        S.farmUiTask, S.farmUiStarting = nil, false
        if not ok then
            S.farm.error = tostring(err)
            S.farm.message = "Start failed"
            requestToggle("farm", false)
        end
    end)
end

-- Use Alexandria

local function setupConfigManager(manager, library, settingsTab)
    local folder = "BeverlyHub/Growblox/" .. string.format("%.0f", game.PlaceId)
    manager:SetLibrary(library)
    manager:IgnoreThemeSettings()
    manager:SetIgnoreIndexes({"GBAutoClearWorld", "GBSpecialDirtFarm", "GBDirtBuilder", "GBAutoFarm", "GBHideName", "GBHideWorldName"})
    manager:SetFolder(folder)

    local function validName(name)
        if type(name) ~= "string" then return false end
        if #name < 1 or #name > 64 or not name:match("^[%w _%.%-]+$") then return false end
        if name:match("^%s*$") or name:find("..", 1, true) or name:match("[%. ]$") then return false end
        return name:lower() ~= "autoload" and not name:lower():match("^autoload_%d+$")
    end
    for _, method in {"Save", "Load", "Delete", "SaveAutoloadConfig"} do
        local original = manager[method]
        manager[method] = function(self, name, ...)
            if not validName(name) then
                return false, "Use a config name with 1-64 letters/numbers, spaces, _ or -; no paths"
            end
            return original(self, name, ...)
        end
    end
    manager:BuildConfigSection(settingsTab)
    S.saveManager = manager
    S.configSystem = {ready = true, folder = folder .. "/settings", provider = "Alexandria SaveManager"}
    manager:LoadAutoloadConfig()
    return manager
end

-- Same Alexandria initialization
local function buildUI()
    local library = loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/Alexandria/main/Library.lua"))()
    S.library = library
    library.ScreenGui:SetAttribute("FluffyHubOwner", "Growblox")

    S.theme = {name = "Strawberry Milk", palette = {
        BackgroundColor = Color3.fromRGB(250, 218, 226),
        MainColor = Color3.fromRGB(240, 195, 206),
        SurfaceColor = Color3.fromRGB(230, 175, 188),
        AccentColor = Color3.fromRGB(180, 50, 85),
        DarkAccentColor = Color3.fromRGB(150, 35, 68),
        OutlineColor = Color3.fromRGB(210, 155, 170),
        InlineColor = Color3.fromRGB(245, 205, 215),
        HoverColor = Color3.fromRGB(235, 180, 195),
        FontColor = Color3.fromRGB(75, 28, 48),
        MutedFontColor = Color3.fromRGB(120, 60, 85),
        ToggleOffColor = Color3.fromRGB(210, 150, 168),
        RedColor = Color3.fromRGB(215, 45, 80),
        DestructiveColor = Color3.fromRGB(175, 30, 60),
    }}
    library.IsLightTheme = false
    for name, color in S.theme.palette do library.Scheme[name] = color end
    library:UpdateColorsUsingRegistry()

    function library:GetTextBounds(text, font, size, width)
        local scale = self.DPIScale or 1
        local params = Instance.new("GetTextBoundsParams")
        params.Text, params.Font, params.Size = tostring(text), font, size * scale
        params.RichText, params.Width = true, (width or 1200) * scale
        local ts = game:GetService("TextService")
        local success, bounds = pcall(function() return ts:GetTextBoundsAsync(params) end)
        params:Destroy()
        if not success or typeof(bounds) ~= "Vector2" then
            bounds = ts:GetTextSize(tostring(text), size * scale, Enum.Font.Gotham, Vector2.new((width or 1200) * scale, 10000))
        end
        return math.ceil(bounds.X / scale), math.ceil(bounds.Y / scale)
    end
    local logo = API.ResolveBrandLogo()
    local discord = "https://discord.gg/C56zw6khS8"
    local window = library:CreateWindow({Title = "Fluffy Hub", Icon = logo,
        Footer = "script 1.0  |  discord.gg/C56zw6khS8",
        Badge = "UNDETECTED", Size = UDim2.fromOffset(720, 480), Center = true, AutoShow = true,
        CornerRadius = 10, ToggleButtonIcon = logo,
        Resizable = true, NotifySide = "Right", ToggleKeybind = Enum.KeyCode.RightShift})
    S.window = window
    window:HideTabInfo()
    for _, control in window.MainFrame:QueryDescendants("TextButton") do
        if control.LayoutOrder == 4 and control.Size == UDim2.fromOffset(30, 30) then
            local icon = control:FindFirstChildWhichIsA("ImageLabel")
            local minus = library:GetIcon("minus")
            if icon and minus then library:ApplyLucideIcon(icon, minus) end
            S.minimizeButton = control
        end
    end
    for _, label in window.MainFrame:QueryDescendants("TextLabel") do
        if label.Text == "UNDETECTED" then
            library:RemoveFromRegistry(label)
            label.TextColor3 = Color3.fromRGB(78, 222, 137)
            label.BackgroundColor3 = Color3.fromRGB(21, 51, 37)
            S.brandBadge = label
        end
    end
    if S.logoAsset then
        -- Find the TitleHolder icon in Header
        for _, icon in window.MainFrame:QueryDescendants("ImageLabel") do
            if icon.Parent and icon.Parent.Name == "TitleHolder" then
                library:RemoveFromRegistry(icon)
                icon.Image = S.logoAsset
                icon.ImageColor3 = Color3.new(1, 1, 1)
                icon.ImageRectOffset = Vector2.zero
                icon.ImageRectSize = Vector2.zero
                icon.ScaleType = Enum.ScaleType.Fit
                icon.Size = UDim2.fromOffset(26, 26)
            elseif icon.Image == S.logoAsset then
                library:RemoveFromRegistry(icon)
                icon.ImageColor3 = Color3.new(1, 1, 1)
            end
        end
        local toggle = library.ToggleButton
        if toggle then
            toggle.Image = S.logoAsset
            toggle.ImageColor3 = Color3.new(1, 1, 1)
            toggle.ScaleType = Enum.ScaleType.Fit
            for _, child in toggle:GetChildren() do
                if child:IsA("ImageLabel") then child.Visible = false end
            end
        end
    end
    local home = window:AddTab("Home", "house")
    local clear = window:AddTab("Auto Clear", "ghost")
    local dirtTab = window:AddTab("Dirt Farm", "layers")
    local farmTab = window:AddTab("Auto Farm", "sprout")
    local utilities = window:AddTab("Utilities", "zap")
    local cfg = window:AddTab("Settings", "settings")
    S.uiTabs = {"Home", "Auto Clear", "Dirt Farm", "Auto Farm", "Utilities", "Settings"}
    local function group(tab, side, name, icon)
        return tab:AddGroupbox({Side = side, Name = name, IconName = icon})
    end
    local function button(box, text, fn)
        local wrapped = function()
            task.spawn(function()
                local ok, err = xpcall(fn, debug.traceback)
                if not ok then status(tostring(err)) end
            end)
        end
        return box:AddButton({Text = text, Func = wrapped, Callback = wrapped})
    end
    local community = group(home, "Left", "Discord", "message-circle")
    community:AddLabel("Join our Discord.", true)
    community:AddLabel(discord, true)
    community:AddLabel("REPORT BUGS AT DISCORD.", true)
    S.homeStatus = community:AddLabel("Clipboard: Ready", true)
    function API.CopyDiscordLink()
        if type(setclipboard) ~= "function" then
            S.homeStatus:SetText("Error: Clipboard unavailable")
            return false
        end
        local copied, err = pcall(setclipboard, discord)
        S.homeStatus:SetText(copied and "Clipboard: Copied" or "Error: " .. UiText.line(err))
        return copied
    end
    S.discordButton = button(community, "Copy Discord Link", API.CopyDiscordLink)
    local log = group(home, "Right", "Update Log", "history")
    log:AddLabel("v1.0 script release", true)
    local notes = group(home, "Left", "Update Notes", "notebook-text")
    notes:AddLabel("Release", true)
    local box = group(clear, "Left", "Auto Clear", "pickaxe")
    S.clearToggle = box:AddToggle("GBAutoClearWorld", {Text = "Auto Clear World", Default = false,
        Callback = function(enabled)
            if S.changingClearToggle then return end
            if not enabled then API.Stop("autoclear toggle OFF"); return end
            S.clearUIError = nil
            S.cancelAutoStart = false
            task.spawn(function()
                local ok, err = xpcall(function()
                    if not S.movement.validated or S.movement.world ~= world.name or S.movement.job ~= game.JobId then
                        local test = API.CalibrateGrounded()
                        assert(test.ok, test.error or "Calibration failed")

                        if S.cancelAutoStart then return end
                    end
                    API.Start()
                end, debug.traceback)
                if not ok then S.clearUIError = tostring(err); S.lastStopReason = tostring(err):match("^[^\r\n]+") or tostring(err); status("Start failed: " .. S.lastStopReason); syncClearToggle(false) end
            end)
        end})
    S.specialDirtToggle = box:AddToggle("GBSpecialDirtFarm", {Text = "Special Dirt Farm", Default = false,
        Callback = function(enabled)
            if S.changingSpecialDirtToggle then return end
            if not enabled then if S.specialDirt.running then API.Stop("Special Dirt Farm toggle OFF") end; return end
            task.spawn(function()
                local ok, err = pcall(API.StartSpecialDirtFarm)
                if not ok then
                    if S.specialDirt.running then API.Stop("Special dirt start failed") end
                    S.specialDirt.error = tostring(err)
                    S.specialDirt.phase = tostring(err)
                    requestToggle("specialDirt", false)
                end
            end)
        end})
    local stats = group(clear, "Right", "Status", "activity")
    S.label = stats:AddLabel(UiText.panel("Idle"), true)
    S.trackingLabel = stats:AddLabel("Foreground: 0\nBackground: 0\nCells: 0\nMoves: 0", true)
    S.lootLabel = stats:AddLabel("Blocks: 0 | Seeds: 0\nGems: 0", true)
    local dirtBox = group(dirtTab, "Left", "Dirt Farm", "layers")
    S.dirtToggle = dirtBox:AddToggle("GBDirtBuilder", {Text = "Auto Dirt Farm", Default = false,
        Callback = function(value)
            if S.changingDirtToggle then return end
            if not value then if S.dirt.running then API.Stop("Dirt builder toggle OFF") end; return end
            task.spawn(function()
                local ok, err = pcall(API.StartDirtFarm)
                if not ok then
                    if S.dirt.running then API.Stop("Dirt start failed") end
                    S.dirt.error = tostring(err)
                    S.dirt.phase = tostring(err)
                    requestToggle("dirt",false)
                end
            end)
        end})
    local dirtStats = group(dirtTab, "Right", "Status", "activity")
    S.dirtLabel = dirtStats:AddLabel(UiText.panel("Idle"), true)
    local util = group(utilities, "Left", "Utilities", "zap")
    local farmBox=group(farmTab,"Left","Auto Farm","sprout")
    local labels,itemMap=API.AutoFarmItems()
    local selectedLabel=DB[S.farm.config.item].name.." ["..S.farm.config.item.."]"
    S.farmItemOption=farmBox:AddDropdown("GBFarmItem",{Text="Item",Values=labels,Default=selectedLabel,
        Callback=function(value)
            if S.farm.running then return end
            local ok,err=pcall(API.ConfigureAutoFarm,itemMap[value],S.farm.config.harvestMode)
            if not ok then S.farm.message=tostring(err) end
        end})
    S.farmHarvestOption=farmBox:AddDropdown("GBFarmHarvestMode",{Text="Harvest Mode",Values={"As Ready","Wait Until All Mature"},Default=UiText.harvestLabel(S.farm.config.harvestMode),
        Callback=function(value)
            if S.farm.running then return end
            local ok,err=pcall(function() API.ConfigureAutoFarm(S.farm.config.item,UiText.harvestValue(value)) end)
            if not ok then S.farm.message=tostring(err) end
        end})
    local setHarvestValue = S.farmHarvestOption.SetValue
    function S.farmHarvestOption:SetValue(value)
        if value == "Bertahap" or value == "Tunggu Semua Matang" then value = UiText.harvestLabel(value) end
        return setHarvestValue(self, value)
    end
    S.farmToggle=farmBox:AddToggle("GBAutoFarm",{Text="Auto Farm",Default=false,Callback=function(value)
        if S.changingFarmToggle then return end
        API.SetAutoFarmEnabled(value)
    end})
    S.farmLabel=group(farmTab,"Right","Status","activity"):AddLabel(UiText.panel("Idle"),true)
    util:AddToggle("GBHideName", {Text = "Hide Name", Default = true,
        Callback = function(value) API.SetHideName(value) end})
    util:AddToggle("GBHideWorldName", {Text = "Hide World Name", Default = true,
        Callback = function(value) API.SetHideWorldName(value) end})
    util:AddToggle("GBUltraFPS", {Text = "Ultra FPS Booster", Default = false,
        Callback = function(value) API.SetUltraFPS(value) end})
    util:AddToggle("GBLeaveStaff", {Text = "Leave on Moderator / Admin", Default = false,
        Callback = function(value) S.utilities.leaveStaff = value end})
    util:AddToggle("GBLeaveCount", {Text = "Leave at Player Limit", Default = false,
        Callback = function(value) S.utilities.leaveCount = value end})
    util:AddSlider("GBMaxPeople", {Text = "Player Limit", Min = 1, Max = 100, Default = 3, Rounding = 0,
        Callback = function(value) S.utilities.maxPeople = math.max(1, math.floor(value)) end})
    local utilStatus = group(utilities, "Right", "Status", "activity")
    S.utilityLabel = utilStatus:AddLabel("Ready", true)

    local configOK, configError = pcall(function()
        for name, fn in {isfolder=isfolder, isfile=isfile, listfiles=listfiles, makefolder=makefolder,
            readfile=readfile, writefile=writefile, delfile=delfile} do
            assert(type(fn)=="function", "Executor filesystem API unavailable: " .. name)
        end
        assert(type(isfolder)=="function" and type(isfile)=="function" and type(listfiles)=="function"
            and type(makefolder)=="function" and type(readfile)=="function" and type(writefile)=="function"
            and type(delfile)=="function", "Executor does not support the required config file APIs")
        local manager = loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/Alexandria/main/addons/SaveManager.lua"))()
        setupConfigManager(manager, library, cfg)
    end)
    if not configOK then
        S.configSystem = {ready = false, error = tostring(configError)}
        group(cfg, "Right", "Configuration", "folder-cog"):AddLabel("Config unavailable: " .. tostring(configError), true)
    end
    if not S.running then pcall(API.PreviewAutoFarm) end
    task.spawn(function()
        while S.live do
            flushToggleRequests()
            if S.farmLabel then pcall(function()
                local f, a = S.farm, API.AutoFarmStatus()
                S.farmItemOption:SetDisabled(a.running or S.farmUiStarting)
                S.farmHarvestOption:SetDisabled(a.running or S.farmUiStarting)
                local item = DB[f.config.item].name .. " [" .. f.config.item .. "]"
                local mode = UiText.harvestLabel(f.config.harvestMode)
                if S.farmItemOption.Value ~= item then S.farmItemOption:SetValue(item) end
                if S.farmHarvestOption.Value ~= mode then S.farmHarvestOption:SetValue(mode) end
                local action = S.farmUiStarting and "Starting" or UiText.farmAction(f)
                S.farmLabel:SetText(UiText.panel(action, a.error or a.checkpointError) .. string.format(
                    "\nFloor: %s/%d\nBatch: %d/%d\nBlocks: %d | Seeds: %d\nTrees: %d/%d ready\nETA: %ds\nPlaced: %d | Broken: %d\nHarvested: %d\nGems: +%d\nDrops: %d\nStorage: %s",
                    tostring(a.row or "-"), a.rows, math.min(a.cursor, a.batch), a.batch,
                    a.block, a.seed, a.ripe, a.trees, math.ceil(a.eta), a.placed, a.broken,
                    a.harvested, a.gems, a.loose, a.storageWarning and "Loose drops" or "Ready"))
            end) end
            if S.dirtLabel then pcall(function()
                local d, p = S.dirt, S.dirt.plan
                local action = d.running and (tostring(d.phase):find("Waiting", 1, true) and "Waiting for items" or "Building")
                    or (d.complete and "Complete" or (d.cursor and "Paused" or "Idle"))
                S.dirtLabel:SetText(UiText.panel(action, d.error) .. string.format(
                    "\nRow: %s\nPosition: %s\nPlaced: %d\nFloors: %d\nDirt needed: %s\nPlatforms needed: %s\nDirt: %s | Platforms: %s",
                    d.cursor and tostring(d.cursor.row) or "-", d.cursor and tostring(d.cursor.x) or "-", d.placed, d.floors,
                    p and tostring(p.dirtNeeded) or "-", p and tostring(p.platformsNeeded) or "-",
                    d.stock and tostring(d.stock[2] or 0) or "-", d.stock and tostring(d.stock[102] or 0) or "-"))
            end) end
            local p, sd = S.progress, S.specialDirt
            local elapsed = p and math.max(0, (p.finishedAt or os.clock()) - (p.startedAt or os.clock())) or 0
            local cells = p and p.cells or 0
            pcall(function()
                S.label:SetText(displayPrivacyText(API.UIStatusText()))
                if sd.running then
                    S.trackingLabel:SetText(string.format("Mined: %d\nPlatforms: %d\nDirt: %d\nFloors: %d",
                        sd.stats.mined, sd.stats.placedPlatforms, sd.stats.placedDirt, sd.stats.floors))
                else
                    S.trackingLabel:SetText(string.format(
                        "Foreground: %d | Background: %d\nCells: %d | Moves: %d\nTime: %02d:%02d\nRate: %.1f/min\nRow: %s\nTarget: %s\nDetours: %d",
                        p and p.foreground or 0, p and p.background or 0, cells, p and p.moves or 0,
                        math.floor(elapsed / 60), math.floor(elapsed % 60), elapsed > 0 and cells * 60 / elapsed or 0,
                        p and tostring(p.row) or "-", p and tostring(p.nextX) or "-", p and p.detours or 0))
                end
            end)
            task.wait(0.5)
        end
    end)

end
S.connections[#S.connections + 1] = game:GetService("UserInputService").InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.End then API.Stop() end
end)
S.connections[#S.connections + 1] = inputService.WindowFocusReleased:Connect(function()

    if S.config.pauseOnFocusLoss then API.Stop("window focus lost") else releaseMovement() end
end)
local ok, err = xpcall(buildUI, debug.traceback)
S.uiReady, S.uiError = ok, not ok and tostring(err) or nil
if not ok then warn("[Growblox UI] " .. tostring(err)) end
return API
