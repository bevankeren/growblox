-- Growblox workbench v0.5 | SPATIAL CORRIDOR | native input only
-- UI adapted from ../hush/UI_GUIDE.md and scripts/hush.luau.
-- Starts idle. Never changes ItemDB or clears on load. Probe instrumentation is scoped/restored.
local E = getgenv()
local previousResults = E.GrowbloxHub and E.GrowbloxHub.State.results or {}
local previousProgress = E.GrowbloxHub and E.GrowbloxHub.State.progress
local previousMovement = E.GrowbloxHub and E.GrowbloxHub.State.movement
local previousLoot = E.GrowbloxHub and E.GrowbloxHub.State.loot
if previousProgress and previousProgress.movementMode ~= "native-input" then previousProgress = nil end
if E.GrowbloxHub and E.GrowbloxHub.Unload then E.GrowbloxHub.Unload() end
local RS = game:GetService("ReplicatedStorage")
assert(game.PlaceId == 112863874972771, "Growblox client required")
local Net = require(RS.Shared.Net)
local DB = require(RS.Shared.ItemDB)
local Recipes = require(RS.Shared.Splice.Recipes)
local Splice = require(RS.Shared.Splice)
local S = {
    version = "0.5-spatial", live = true, running = false, busy = false,
    status = "Idle - preview before starting", results = previousResults, events = {},
    sent = 0, nativeCalls = 0, confirmed = 0, localCleared = 0, connections = {}, plan = nil,
    config = {interval = 0.24, limit = 0, radius = 2, background = true, autoPickup = true, onFull = "continue", pickupRadius = 2.2, pauseOnFocusLoss = false,
        verifyEvery = 20, alternative = "punch-burst"},
    progress = nil, blocked = {}, engine = "spatial-corridor-v2",
    loot = previousLoot and previousLoot.job == game.JobId and previousLoot or {
        job = game.JobId, blocks = 0, seeds = 0, gems = 0, attempts = 0, denied = 0, fullItems = {}, retryAt = {}},
    movement = {mode = "native-input", validated = false, jumpValidated = false, keys = {},
        reason = "Previous goTo/hover engine caused flying kick; removed. Re-test normal input before Start."},
    -- Restrict the prototype to natural tiles, never locks/furniture/trees.
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
local API = {State = S}
E.GrowbloxHub = API
local executorIdentity = type(getthreadidentity) == "function" and getthreadidentity() or 8
local function restoreExecutorContext()
    -- Native game RPC wrappers resume coroutines from a game-script thread.
    -- Restore only the context in which this executor script originally started.
    if type(setthreadidentity) == "function" then setthreadidentity(executorIdentity) end
end
if previousMovement and previousMovement.mode == "native-input" and previousMovement.validated
    and previousMovement.jumpValidated and previousMovement.job == game.JobId then
    for _, k in {"validated", "jumpValidated", "maxJumpHeight", "world", "job"} do S.movement[k] = previousMovement[k] end
    S.movement.reason = "Normal input calibration reused in the same server"
end

-- Anchor identity in the installed game's packet listener, not arbitrary GC clones.
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
local function position()
    -- Verified goTo upvalues 1/2 are the current tile-space player x/y.
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
local function status(message)
    S.status = message
    if S.label then pcall(function() S.label:SetText((tostring(message):match("^[^\r\n]+") or "Idle"):sub(1, 110)) end) end
end

-- ByteNet listen has no disposer; remove precisely our listener on Unload.
local function changed(p)
    if not S.live or p.w ~= Net.worldTag(world.name or "") then return end
    -- Wire layers: 1=foreground, 2=background; local API uses 0/1.
    if p.layer ~= 1 and p.layer ~= 2 then return end
    S.events[key(p.layer - 1, p.x, p.y)] = {id = p.id, at = os.clock(), world = world.name}
end
Net.tileChanged.listen(changed)
local inputService = game:GetService("UserInputService")
local virtualInput = game:GetService("VirtualInputManager")
local function inputKey(key, down)
    if S.movement.keys[key] == down then return end
    virtualInput:SendKeyEvent(down, key, false, game)
    S.movement.keys[key] = down
end
local function releaseMovement()
    for _, k in {Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Space} do
        pcall(function() virtualInput:SendKeyEvent(false, k, false, game) end)
        S.movement.keys[k] = false
    end
end
local function syncClearToggle(value)
    if not S.clearToggle then return end
    S.changingClearToggle = true
    pcall(function() S.clearToggle:SetValue(value) end)
    S.changingClearToggle = false
end
function API.Stop(reason)
    S.cancelAutoStart = true
    S.lastStopReason = type(reason) == "string" and reason or "manual pause"
    S.lastStopAt = os.clock()
    S.running = false
    S.generation = (S.generation or 0) + 1
    releaseMovement()
    if S.worker then pcall(task.cancel, S.worker); S.worker = nil end
    S.busy = false
    if S.progress and not S.progress.complete then S.progress.state = "Paused"; S.progress.finishedAt = os.clock() end
    if API.SaveCheckpoint then API.SaveCheckpoint() end
    status("Paused - Start / Resume continues from the live world")
    syncClearToggle(false)
end
function API.Unload()
    if API.StopRecording then API.StopRecording("script unload") end
    API.Stop("script reload/unload")
    S.live = false
    local listeners = Net.tileChanged.getListeners()
    local index = table.find(listeners, changed)
    if index then table.remove(listeners, index) end
    for _, c in S.connections do c:Disconnect() end
    if S.library then pcall(function() S.library:Unload() end) end
end
function API.Snapshot()
    local x, y = position()
    return {world = world.name, width = world.w, height = world.h, x = x, y = y,
        running = S.running, busy = S.busy, status = S.status,
        sent = S.sent, nativeCalls = S.nativeCalls, confirmed = S.confirmed, localCleared = S.localCleared, results = S.results,
        reach = controls.punchRange(), power = controls.handPower(), dig = controls.handDig(),
        progress = S.progress}
end
-- Explicit same-world re-entry used for authoritative verification.
-- EnterWorld may reset the player to spawn; never use it mid-navigation.
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
    return id == 0 or (d ~= nil and not d.solid and not d.hurts and d.kind ~= "seed")
end
local function canStand(x, y)
    return x >= 0 and x < world.w and y >= 1 and y < world.h
        and passable(tile(0, x, y)) and passable(tile(0, x, y - 1))
end
local function canMineFrom(px, py, x, y)
    local dx, dy = x + 0.5 - px, y + 0.5 - py
    if dx * dx + dy * dy > math.min(controls.punchRange() - 0.1, 2.2)^2 then return false end
    -- Conservative collision ray from the avatar's body, not through protected solids.
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
    assert(p.movementMode == "native-input" and p.engine == S.engine, "Old-engine checkpoint refused; preview again")
    assert(type(p.row) == "number" and type(p.nextX) == "number" and (p.direction == 1 or p.direction == -1), "Invalid checkpoint cursor")
    S.progress, p.state = p, "Paused"
    status("Checkpoint loaded - Start / Resume to continue")
    return {world = p.world, row = p.row, x = p.nextX, direction = p.direction}
end
local function active(generation)
    return S.live and S.running and S.generation == generation and world.name == S.boundWorld
        and inputService:GetFocusedTextBox() == nil and not game.Players.LocalPlayer:GetAttribute("Frozen")
end
local function supported(x, y)
    if not canStand(x, y) then return false end
    local d = DB[tile(0, x, y + 1) or 0]
    return d ~= nil and not d.hurts and (d.solid == true or d.platform == true)
end
local function grounded()
    local px, py = position()
    local sy = math.floor(py - 0.02)
    if math.abs(py - (sy + 1)) >= 0.18 or not canStand(math.floor(px), sy) then return false end
    -- Normal collisions can leave the center over a ledge while one foot is supported.
    for _, foot in {px - 0.2, px, px + 0.2} do
        local d = DB[tile(0, math.floor(foot), sy + 1) or 0]
        if d and not d.hurts and (d.solid == true or d.platform == true) then return true end
    end
    return false
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
    -- Check the launch/landing clearance and apex using the measured normal jump.
    -- Supported two-cell ledges were previously missing from the navigation graph.
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
    local sx, sy = math.floor(px), math.floor(py - 0.02)
    if not supported(sx, sy) then
        local anchored
        for _, foot in {px - 0.2, px + 0.2} do
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
        -- Brake/align with short real key pulses; never pin the position against inertia.
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
        S.progress.moves += 1
        local px, py = position()
        S.progress.distance += math.sqrt((px - fromX)^2 + (py - fromY)^2)
        if collectNearby and S.config.autoPickup then collectNearby(false) end
    end
    releaseMovement()
    if not waitGrounded(1.5, generation) then return false, "Did not land normally" end
    return true
end
-- Manual-demo engine: work from the cleared corridor, never pre-position ABOVE
-- every target. General graph search is reserved for entry and obstacle detours.
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
    if math.floor(px) ~= x or math.floor(py - 0.02) + 1 ~= y then return false end
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
    local ownSupport = tile(0, x, y) ~= 0 and math.floor(px) == x and math.floor(py - 0.02) + 1 == y
    if ownSupport and safeCornerDescent(x, y) then
        S.progress.phase = "corner-descent"
        return true
    end
    -- Normal case: punch the adjacent tile from BEHIND in the cleared row.
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
        local room = isGem and 65535 or math.max(0, 200 - (S.loot.counts[d.id] or 0))
        if not isGem and not S.loot.counts[d.id] and S.loot.used >= S.loot.capacity then room = 0 end
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
                local bucket = isGem and "gems" or (def and def.kind == "seed" and "seeds" or "blocks")
                S.loot[bucket] += got; claimed += got; gotGems = gotGems or isGem
                if not isGem then S.loot.counts[d.id] = (S.loot.counts[d.id] or 0) + got end
                -- Remove a client visual only after the server acknowledged this exact UID.
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
    if claimed > 0 then refreshLootInventory() end
    if gotGems then refreshGems() end
    if S.lootLabel then pcall(function() S.lootLabel:SetText(string.format("Picked: block %d | seed %d\nGems +%d | server %s", S.loot.blocks, S.loot.seeds, S.loot.gems, tostring(S.loot.serverGems or "-"))) end) end
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
        -- Live corrections are observed without re-entering/resetting the running world.
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
    -- Includes removals before a manual Pause, whose worker may have been cancelled mid-batch.
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
    for _ = 1, needed + 1 do
        if not active(generation) then return false, "Paused" end
        if tile(layer, x, y) ~= id then break end
        if not accessible(x, y) then return false, "Build permission changed" end
        local ax, ay = position()
        if not grounded() then return false, "Mining stopped because avatar left the ground" end
        if layer == 0 and math.floor(ax) == x and math.floor(ay - 0.02) + 1 == y and not safeCornerDescent(x, y) then
            return false, "Refusing to remove the support under the avatar; replan from the side"
        end
        if not canMineFrom(ax, ay, x, y) then return false, "Target moved out of normal reach" end
        hit(x, y)
        S.nativeCalls += 1; S.progress.hits += 1
        if tile(layer, x, y) == 0 then break end
        task.wait(math.max(0.24, S.config.interval))
    end
    if tile(layer, x, y) ~= 0 then return false, "Normal mining did not remove target" end
    local t = {x = x, y = y, layer = layer, before = id, after = 0}
    run.targets[#run.targets + 1] = t
    if layer == 0 then S.progress.foreground += 1 else S.progress.background += 1 end
    S.localCleared += 1
    task.wait(math.max(0.24, S.config.interval)) -- native cadence, not a cooldown bypass
    if not waitGrounded(2, generation) then return false, "Corner descent did not land normally" end
    t.afterSettled = tile(layer, x, y)
    if t.afterSettled ~= 0 then return false, "Tile was corrected after normal mining" end
    return true
end
local function clearCell(x, y, generation, run, stay)
    local fg = tile(0, x, y)
    if fg ~= 0 and not eligible(0, x, y) then
        S.progress.protected += 1
        return true -- locks/obsidian/bedrock/doors and their backgrounds stay intact
    end
    if fg == 0 and (not S.config.background or not eligible(1, x, y)) then return true end
    local reached, why = navigate(x, y, generation, stay)
    if not reached then
        if string.find(why or "", "No stand point", 1, true) then
            S.progress.unreachable = (S.progress.unreachable or 0) + 1
            S.progress.lastUnreachable = {x = x, y = y, reason = why}
            return true -- continue other reachable cells; final server count prevents false completion
        end
        return false, why
    end
    for layer = 0, (S.config.background and 1 or 0) do
        local ok, err = mineLayer(x, y, layer, generation, run)
        if not ok then return false, err end
    end
    -- Walk into the cell JUST cleared, on its remaining floor, like the demo.
    -- No per-cell graph search, center alignment loop, or fixed pickup sleep.
    if supported(x, y) then
        S.progress.phase = "advance-corridor"
        local px, py = position()
        local moved, why
        if math.abs(py - (y + 0.999)) <= 0.25 and math.abs(px - x - 0.5) <= 1.6 then
            moved, why = corridorStep(x, y, generation)
        else
            -- Newly opened cell can be one level below us: normal drop path,
            -- NOT a horizontal corridor command issued at the wrong height.
            local path, err = pathTo(x, y, true)
            if path then moved, why = follow(path, generation) else why = err end
        end
        if not moved then return false, why end
    end
    collectNearby(false)
    S.progress.cells += 1
    status(string.format("Row %d | x %d | %s\nFG %d | BG %d\nServer verified: %d", y, x, S.progress.direction == 1 and ">" or "<",
        S.progress.foreground, S.progress.background, S.progress.serverCleared))
    return true
end

-- Deliberately no Heartbeat position hold, goTo call, teleport or velocity override.
-- Validate real game input first; an untested movement replacement cannot start clearing.
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

-- Passive manual-farming recorder. No movement, take requests, chat capture, or blocked packets.
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

-- Explicit bounded experiments only, never called during loading/Preview.
-- mode=instant: one zero-id tile request, no hit prelude.
-- mode=rapid: native hit calls at 0.05s (client-side cooldown experiment).
-- mode=native/normal: native hit calls at 0.35s (baseline).
-- mode=multi: native hit calls for <=3 tiles in one tick, NOT one AoE packet.
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
        -- v1033: hit upvalue 5 changed from -10 to the exact last-hit clock in probes.
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
    S.config.background = true -- requested snake flow always clears the cave layer too
    local p = S.progress
    if region or not p or p.movementMode ~= "native-input" or p.engine ~= S.engine or p.world ~= world.name or p.job ~= game.JobId or not p.bounds or p.complete then
        local plan = API.Preview(region)
        p = {world = world.name, job = game.JobId, movementMode = "native-input", engine = S.engine, bounds = table.clone(plan.bounds),
            row = plan.bounds.y0, nextX = plan.bounds.x0, direction = 1, edgePending = false, rowEntered = false, startedAt = os.clock(),
            moves = 0, distance = 0, detours = 0, hits = 0, cells = 0, foreground = 0, background = 0,
            protected = 0, unreachable = 0, serverCleared = 0, serverRejected = 0, verifications = 0, turns = 0,
            turnLog = {}, initial = plan.counts.total, complete = false}
        S.progress = p
    elseif p.row > p.bounds.y1 then
        p.row, p.nextX, p.direction, p.edgePending = p.bounds.y0, p.bounds.x0, 1, false
    end
    local px, py = position()
    assert(grounded(), "Avatar must start on solid ground")
    S.blocked, S.boundWorld = {}, world.name
    S.generation = (S.generation or 0) + 1
    local generation = S.generation
    S.running, S.busy, p.state = true, true, "Running"
    p.finishedAt = nil
    syncClearToggle(true)
    p.lastError, S.lastStopReason = nil, nil
    S.worker = task.spawn(function()
        local run = {mode = "world-clear", protocol = "wire-layer-1-2", world = S.boundWorld,
            bounds = table.clone(p.bounds), targets = {}, started = os.clock()}
        S.results[#S.results + 1] = run
        local checked, reason, rejectedAtStart = 0, nil, p.serverRejected
        local ok, err = xpcall(function()
            while active(generation) and p.row <= p.bounds.y1 do
                if not p.rowEntered then
                    -- Fast-forward empty rows without sending any movement input.
                    while p.row <= p.bounds.y1 and not enterRow(p) do
                        p.row += 1; p.rowEntered = false
                    end
                    if p.row > p.bounds.y1 then break end
                end
                local x, y = p.nextX, p.row
                p.lastTarget = {x = x, y = y}
                local cleared, why = clearCell(x, y, generation, run, p.edgePending)
                if not cleared then error(why) end
                if p.edgePending then
                    -- Grounded pathfinding chooses a normal drop/jump at the corner; never force a descent.
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
                    p.row += 1; p.direction = -p.direction; p.rowEntered = false
                    p.nextX = p.direction == 1 and p.bounds.x0 or p.bounds.x1
                    p.edgePending = true
                    if p.row <= p.bounds.y1 then
                        p.turns += 1
                        if #p.turnLog < 30 then p.turnLog[#p.turnLog + 1] = {row = p.row, direction = p.direction, edgeX = p.nextX} end
                    end
                    checkpoint()
                end
                if S.config.limit > 0 and #run.targets >= S.config.limit then reason = "Run limit reached - resume continues this row"; break end
            end
            if active(generation) then
                collectNearby(true)
                p.remainingDrops = API.DropSummary()
                -- Stop movement before the final authoritative re-entry (which returns to spawn).
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
        status(not ok and tostring(err) or reason or "Paused")
    end)
    return {world = p.world, bounds = p.bounds, row = p.row, x = p.nextX, direction = p.direction}
end
API.Resume = API.Start

-- Alternative bounded tests: isolated hit closure with copied combat dispatch.
-- No changes to ItemDB, equipped items, original hit constants, or cooldowns.
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
                -- Confirmed Others.sendHit protocol: kind=6 and tile center x/y.
                -- Send only the missing hit preludes, then let native hit emit the final hit/removal.
                for _ = 1, DB[t.before].hits - 1 do
                    assert(S.live and world.name == bound and S.generation == generation and inRange(t.x, t.y), "Cancelled")
                    punch(t)
                    r.extraPackets += 1
                    if mode ~= "wire-batch" then task.wait(mode == "wire-paced" and 0.21 or 0.05) end
                end
            end
            if mode == "punch-burst" or mode == "punch-paced" or mode == "punch-multi" then
                -- Full-action trace exposed kind=1 punch-start, separate from kind=6 impact.
                -- Test ordered punch-start preludes rather than visual-only impact spam.
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
                    -- act's argument is input source; its cursor is upvalue 3, not the argument.
                    debug.setupvalue(action, 3, Vector2.new(px, py))
                    r.cursorScoped = debug.getupvalue(act, 3) ~= savedMouse
                    action(1)
                    -- This executor shares the cursor cell; restore before any deliberate yield.
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
    -- Defensive restoration even if an executor implements shared closure cells.
    if debug.getupvalue(hit, controlsIndex) ~= controls then debug.setupvalue(hit, controlsIndex, controls) end
    r.originalRestored = debug.getupvalue(hit, controlsIndex) == controls
    r.ok, r.error = ok, not ok and tostring(err) or nil
    r.elapsed = os.clock() - r.started
    S.results[#S.results + 1] = r
    S.busy = false
    if ok and S.live and world.name == bound then
        r.snapshotOK = API.VerifyServerWorld(bound)
        -- Repair optimistic client-only removals from the authoritative snapshot.
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

-- Same Alexandria initialization, tab/groupbox styling and button compatibility as Hush.
local function buildUI()
    local library = loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/Alexandria/main/Library.lua"))()
    S.library = library
    -- Saturated Halloween: chromatic purple surfaces, vivid magenta, no gray-lilac wash.
    S.theme = {name = "Witching Hour - Vivid", palette = {
        BackgroundColor = Color3.fromRGB(39, 15, 68),
        MainColor = Color3.fromRGB(63, 23, 105),
        SurfaceColor = Color3.fromRGB(87, 34, 137),
        AccentColor = Color3.fromRGB(242, 31, 190),
        DarkAccentColor = Color3.fromRGB(123, 50, 174),
        OutlineColor = Color3.fromRGB(171, 65, 220),
        InlineColor = Color3.fromRGB(75, 24, 115),
        HoverColor = Color3.fromRGB(111, 42, 168),
        FontColor = Color3.fromRGB(249, 240, 255),
        MutedFontColor = Color3.fromRGB(230, 181, 245),
        ToggleOffColor = Color3.fromRGB(86, 29, 126),
        RedColor = Color3.fromRGB(255, 122, 184),
        DestructiveColor = Color3.fromRGB(206, 45, 121),
    }}
    library.IsLightTheme = false
    for name, color in S.theme.palette do library.Scheme[name] = color end
    library:UpdateColorsUsingRegistry()
    -- Avoid the executor/cloneref TextService result mismatch observed in CreateWindow.
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
    local window = library:CreateWindow({Title = "Growblox | Witching Hour", Icon = "ghost",
        Footer = "v0.5 | Spatial navigation",
        Badge = "HALLOWEEN", Size = UDim2.fromOffset(660, 420), Center = true, AutoShow = true,
        Resizable = true, NotifySide = "Right", ToggleKeybind = Enum.KeyCode.RightShift})
    S.window = window
    local clear = window:AddTab("Auto Clear", "ghost")
    local cfg = window:AddTab("Settings", "settings")
    S.uiTabs = {"Auto Clear", "Settings"}
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
    local box = group(clear, "Left", "Auto Clear", "ghost")
    S.clearToggle = box:AddToggle("GBAutoClearWorld", {Text = "Auto Clear World", Default = false,
        Callback = function(enabled)
            if S.changingClearToggle then return end
            if not enabled then API.Stop("autoclear toggle OFF"); return end
            S.cancelAutoStart = false
            task.spawn(function()
                local ok, err = xpcall(function()
                    if not S.movement.validated or S.movement.world ~= world.name or S.movement.job ~= game.JobId then
                        local test = API.CalibrateGrounded()
                        assert(test.ok, test.error or "Calibration failed")
                        -- OFF pressed during calibration must cancel pending start.
                        if S.cancelAutoStart then return end
                    end
                    API.Start()
                end, debug.traceback)
                if not ok then status(tostring(err)); syncClearToggle(false) end
            end)
        end})
    local stats = group(clear, "Right", "Tracking", "activity")
    S.label = stats:AddLabel("Idle", true)
    S.trackingLabel = stats:AddLabel("FG 0 | BG 0\nCells 0 | Moves 0\nTime 00:00 | Rate 0/min", true)
    S.lootLabel = stats:AddLabel("Block 0 | Seed 0 | Gems 0", true)
    local settings = group(cfg, "Left", "Clear", "settings")
    settings:AddSlider("GBHitInterval", {Text = "Hit interval", Min = 0.24, Max = 1, Default = 0.24, Rounding = 2,
        Callback = function(v) S.config.interval = v end})
    settings:AddToggle("GBAutoPickup", {Text = "Pickup drops", Default = true,
        Callback = function(v) S.config.autoPickup = v end})
    settings:AddToggle("GBPauseFocus", {Text = "Pause on focus loss", Default = false,
        Callback = function(v) S.config.pauseOnFocusLoss = v end})
    S.limitOption = settings:AddSlider("GBLimit", {Text = "Tile limit (0 = all)", Min = 0, Max = 5000, Default = 0, Rounding = 0,
        Callback = function(v) S.config.limit = v end})
    button(settings, "Calibrate movement", API.CalibrateGrounded)
    button(settings, "Load checkpoint", API.LoadCheckpoint)
    local session = group(cfg, "Right", "Session", "moon")
    session:AddLabel("RightShift: menu | End: stop")
    button(session, "Unload", API.Unload)
    task.spawn(function()
        while S.live do
            local p = S.progress
            local elapsed = p and math.max(0, (p.finishedAt or os.clock()) - (p.startedAt or os.clock())) or 0
            local cells = p and p.cells or 0
            pcall(function()
                S.trackingLabel:SetText(string.format("FG %d | BG %d\nCells %d | Moves %d\nTime %02d:%02d | Rate %.1f/min\nRow %s | Target %s | Detours %d", p and p.foreground or 0,
                    p and p.background or 0, cells, p and p.moves or 0, math.floor(elapsed / 60), math.floor(elapsed % 60),
                    elapsed > 0 and cells * 60 / elapsed or 0, p and tostring(p.row) or "-", p and tostring(p.nextX) or "-", p and p.detours or 0))
            end)
            task.wait(0.5)
        end
    end)

end
S.connections[#S.connections + 1] = game:GetService("UserInputService").InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.End then API.Stop() end
end)
S.connections[#S.connections + 1] = inputService.WindowFocusReleased:Connect(function()
    -- VirtualInputManager targets Roblox, not OS keyboard input in other apps.
    if S.config.pauseOnFocusLoss then API.Stop("window focus lost") else releaseMovement() end
end)
local ok, err = xpcall(buildUI, debug.traceback)
S.uiReady, S.uiError = ok, not ok and tostring(err) or nil
if not ok then warn("[Growblox UI] " .. tostring(err)) end
return API
