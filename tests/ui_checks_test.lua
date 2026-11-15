-- Plain Lua 5.1 property-test harness for ForeverFilter/UI.lua.
-- Run from the workspace root:  lua tests/ui_checks_test.lua
-- Append new properties by calling property(name, fn) before the summary.

----------------------------------------------------------------------
-- WoW environment stubs
----------------------------------------------------------------------
local function stubFrame()
    local f = {}
    return setmetatable(f, { __index = function() return function() return f end end })
end

CreateFrame = function() return stubFrame() end
tinsert = table.insert
UISpecialFrames = {}
UIParent = stubFrame()
C_Timer = { After = function() end }

----------------------------------------------------------------------
-- Load UI.lua
----------------------------------------------------------------------
local function loadUI(db)
    local ns = { db = db }
    local chunk, err = loadfile("ForeverFilter/UI.lua")
    if not chunk then
        error("cannot load ForeverFilter/UI.lua: " .. tostring(err))
    end
    chunk("ForeverFilter", ns)
    return ns.UI, ns
end

----------------------------------------------------------------------
-- Seeded generators and loop helper
----------------------------------------------------------------------
local SEED = tonumber(os.getenv("FF_TEST_SEED")) or 12345
local ITERATIONS = 200
math.randomseed(SEED)
local random = math.random

local function pick(list) return list[random(#list)] end

local function genString()
    local fixed = { "", "WoW", "|", "?", "nil", "D3", "Pro", "WTCG", "BSAp", "App", "w", "WOW", "||c", "a:b" }
    if random() < 0.5 then return pick(fixed) end
    local n = random(0, 6)
    local chars = {}
    for i = 1, n do chars[i] = string.char(random(32, 126)) end
    return table.concat(chars)
end

-- nil or any string, biased toward "WoW".
local function genGame()
    local r = random()
    if r < 0.15 then return nil end
    if r < 0.45 then return "WoW" end
    return genString()
end

-- nil, number, or string project ID.
local function genProjectID()
    local r = random()
    if r < 0.2 then return nil end
    if r < 0.6 then return pick({ 1, 2, 5, 11, 14, 19, 0, -1, 1.5 }) end
    if r < 0.8 then return random(0, 30) end
    return pick({ "1", "2", "nil", "", "|", "WoW", "11" }) 
end

----------------------------------------------------------------------
-- Property runner
----------------------------------------------------------------------
local failures, total = 0, 0

local function property(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. "\n     " .. tostring(err) .. "\n     seed=" .. SEED)
    end
end

local function show(v) return type(v) == "string" and string.format("%q", v) or tostring(v) end

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 1: Game key derivation
-- Validates: Requirements 1.6, 6.6, 7.1, 7.2, 7.3, 7.4, 7.5
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 1: Game key derivation", function()
    local UI = loadUI({})

    -- Normalized pair, as Friends.GroupByGame groups: project ID only counts for WoW.
    local function normalized(game, pid)
        local g = game or "?"
        local p = "nil"
        if g == "WoW" then p = tostring(pid) end
        return g .. "\0" .. p
    end

    local seen = {}
    for i = 1, ITERATIONS do
        local game, pid = genGame(), genProjectID()
        local ok, key = pcall(UI.GameKey, game, pid)
        assert(ok, "GameKey raised for " .. show(game) .. ", " .. show(pid) .. ": " .. tostring(key))

        local g = game or "?"
        local expected = g .. ":" .. (g == "WoW" and tostring(pid) or "nil")
        assert(key == expected, string.format("key %s ~= expected %s for (%s, %s)",
            show(key), show(expected), show(game), show(pid)))

        seen[#seen + 1] = { game = game, pid = pid, key = key }

        -- Pairwise: equal keys iff equal normalized pairs (against a random earlier input).
        local other = seen[random(#seen)]
        local sameKey = key == other.key
        local samePair = normalized(game, pid) == normalized(other.game, other.pid)
        assert(sameKey == samePair, string.format(
            "(%s,%s) vs (%s,%s): keys equal=%s, pairs equal=%s",
            show(game), show(pid), show(other.game), show(other.pid), tostring(sameKey), tostring(samePair)))
    end

    -- Explicit edge cases.
    assert(UI.GameKey(nil, nil) == "?:nil")
    assert(UI.GameKey("WoW", nil) == "WoW:nil")
    assert(UI.GameKey("WoW", 11) == "WoW:11")
    assert(UI.GameKey("D3", 11) == "D3:nil")
    assert(UI.GameKey("D3", 11) == UI.GameKey("D3", nil))
    assert(UI.GameKey("WoW", 11) ~= UI.GameKey("WoW", 14))
end)

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 2: Check state lookup with default
-- Validates: Requirements 1.3, 1.7, 2.1, 2.2, 5.7, 5.8, 6.3
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 2: Check state lookup with default", function()
    local function genJunk()
        local r = random(5)
        if r == 1 then return random(-5, 5) end
        if r == 2 then return genString() end
        if r == 3 then return {} end
        if r == 4 then return function() end end
        return random() + 0.5
    end

    -- Boolean, junk, or nil (missing).
    local function genValue()
        local r = random()
        if r < 0.35 then return random() < 0.5 end
        if r < 0.7 then return genJunk() end
        return nil
    end

    for i = 1, ITERATIONS do
        -- Pool of (game, pid) inputs; the saved table gets values under some of their keys.
        local pool, store = {}, {}
        for j = 1, random(1, 8) do
            local g, p = genGame(), genProjectID()
            pool[j] = { g, p }
        end
        local UI = loadUI({ checkedGames = store })
        for _, e in ipairs(pool) do
            local v = genValue()
            if v ~= nil then store[UI.GameKey(e[1], e[2])] = v end
        end

        -- Snapshot (raw identity) before lookups.
        local before, count = {}, 0
        for k, v in pairs(store) do before[k] = v; count = count + 1 end

        -- Look up pool inputs plus fresh random ones.
        local inputs = {}
        for _, e in ipairs(pool) do inputs[#inputs + 1] = e end
        for j = 1, 4 do inputs[#inputs + 1] = { genGame(), genProjectID() } end

        for _, e in ipairs(inputs) do
            local key = UI.GameKey(e[1], e[2])
            local stored = before[key]
            local expected = true
            if type(stored) == "boolean" then expected = stored end
            local ok, got = pcall(UI.IsChecked, e[1], e[2])
            assert(ok, "IsChecked raised for " .. show(e[1]) .. ", " .. show(e[2]) .. ": " .. tostring(got))
            assert(got == expected, string.format("IsChecked(%s,%s) key %s stored %s: got %s, expected %s",
                show(e[1]), show(e[2]), show(key), tostring(stored), tostring(got), tostring(expected)))
        end

        -- Unchanged entries, none added.
        local after = 0
        for k, v in pairs(store) do
            after = after + 1
            assert(rawequal(before[k], v), "entry changed for key " .. show(k))
        end
        assert(after == count, string.format("entry count changed: %d -> %d", count, after))
    end

    -- Explicit examples.
    local UI2, ns2 = loadUI({})
    assert(UI2.IsChecked("WoW", 1) == true)
    assert(next(ns2.db.checkedGames) == nil, "lookup on fresh db must add no entry")
    local UI3 = loadUI({ checkedGames = { ["WoW:1"] = false, ["D3:nil"] = "no" } })
    assert(UI3.IsChecked("WoW", 1) == false)
    assert(UI3.IsChecked("D3", nil) == true)
end)

----------------------------------------------------------------------
-- Shared generator: a saved table with boolean and junk values under random keys.
----------------------------------------------------------------------
local function genStore()
    local store = {}
    for _ = 1, random(0, 8) do
        local k = (random() < 0.8) and (genGame() or "?") .. ":" .. tostring(genProjectID()) or genString()
        local r = random(4)
        if r == 1 then store[k] = true
        elseif r == 2 then store[k] = false
        elseif r == 3 then store[k] = genString()
        else store[k] = random(-3, 3) end
    end
    return store
end

local function snapshot(t)
    local s = {}
    for k, v in pairs(t) do s[k] = v end
    return s
end

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 3: Set then get with isolation
-- Validates: Requirements 1.4, 1.5, 1.6, 2.3, 2.4, 5.1, 5.2
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 3: Set then get with isolation", function()
    for i = 1, ITERATIONS do
        local store = genStore()
        local UI = loadUI({ checkedGames = store })
        local game, pid, value = genGame(), genProjectID(), random() < 0.5
        local key = UI.GameKey(game, pid)
        local before = snapshot(store)

        UI.SetChecked(game, pid, value)

        assert(store[key] == value, string.format("stored %s ~= %s for key %s",
            tostring(store[key]), tostring(value), show(key)))
        assert(UI.IsChecked(game, pid) == value, "IsChecked did not return the set value")
        for k, v in pairs(before) do
            if k ~= key then assert(rawequal(store[k], v), "other entry changed: " .. show(k)) end
        end
        for k in pairs(store) do
            assert(k == key or before[k] ~= nil, "unexpected new entry: " .. show(k))
        end

        -- Same game, different WoW project IDs are independent.
        local a, b = random(0, 30), random(0, 30)
        if a ~= b then
            local UI2, ns2 = loadUI({})
            local va, vb = random() < 0.5, random() < 0.5
            UI2.SetChecked("WoW", a, va)
            UI2.SetChecked("WoW", b, vb)
            assert(UI2.IsChecked("WoW", a) == va, "WoW project " .. a .. " affected by " .. b)
            assert(UI2.IsChecked("WoW", b) == vb, "WoW project " .. b .. " affected by " .. a)
            UI2.SetChecked("WoW", a, not va)
            assert(UI2.IsChecked("WoW", b) == vb, "setting " .. a .. " changed " .. b)
        end
    end
end)

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 4: Double toggle restores the effective state
-- Validates: Requirements 5.6
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 4: Double toggle restores the effective state", function()
    for i = 1, ITERATIONS do
        local UI = loadUI({ checkedGames = genStore() })
        local game, pid = genGame(), genProjectID()
        local original = UI.IsChecked(game, pid)

        UI.SetChecked(game, pid, not UI.IsChecked(game, pid))
        assert(UI.IsChecked(game, pid) == (not original), "first toggle did not flip state")
        UI.SetChecked(game, pid, not UI.IsChecked(game, pid))
        assert(UI.IsChecked(game, pid) == original, string.format(
            "double toggle gave %s, original %s for (%s, %s)",
            tostring(UI.IsChecked(game, pid)), tostring(original), show(game), show(pid)))
    end
end)

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 5: Store repair and field preservation
-- Validates: Requirements 6.1, 6.2, 6.4, 6.5
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 5: Store repair and field preservation", function()
    local function genJunk()
        local r = random(6)
        if r == 1 then return random(-5, 5) end
        if r == 2 then return genString() end
        if r == 3 then return random() < 0.5 end
        if r == 4 then return function() end end
        if r == 5 then return { genString() } end
        return random() + 0.5
    end

    -- A database table with arbitrary extra fields and some checkedGames shape.
    local function genDB()
        local db = {}
        for _ = 1, random(0, 6) do
            local k = pick({ "debug", "version", "x", "other", genString(), random(1, 5) })
            if k ~= "checkedGames" then db[k] = genJunk() end
        end
        local shape = random(3)
        if shape == 2 then db.checkedGames = genJunk() end
        if shape == 3 then db.checkedGames = genStore() end
        return db
    end

    for i = 1, ITERATIONS do
        local db = genDB()
        local before = snapshot(db)
        local mode = random(3) -- 1: ns.db is the table; 2: ns.db nil, global present; 3: ns.db nil, global absent
        local active, decoy

        if mode == 1 then
            decoy = (random() < 0.5) and { keep = genJunk() } or nil
            ForeverFilterDB = decoy
            active = db
        elseif mode == 2 then
            ForeverFilterDB = db
            active = db
        else
            ForeverFilterDB = nil
            active = nil
        end

        local UI = loadUI(mode == 1 and db or nil)
        local g, p = genGame(), genProjectID()
        for _ = 1, random(1, 4) do
            local ok, err
            if random() < 0.5 then
                ok, err = pcall(UI.IsChecked, g, p)
            else
                ok, err = pcall(UI.SetChecked, g, p, random() < 0.5)
            end
            assert(ok, "raised (mode " .. mode .. "): " .. tostring(err))
        end

        if mode == 3 then
            active = ForeverFilterDB
            assert(type(active) == "table", "global ForeverFilterDB not created")
        end
        assert(type(active.checkedGames) == "table", "checkedGames is not a table (mode " .. mode .. ")")

        for k, v in pairs(before) do
            if k ~= "checkedGames" then
                assert(rawequal(active[k], v), "field changed: " .. show(k))
            end
        end
        for k in pairs(active) do
            assert(k == "checkedGames" or before[k] ~= nil, "unexpected new field: " .. show(k))
        end
        if mode == 1 then
            assert(ForeverFilterDB == decoy, "global ForeverFilterDB touched while ns.db was a table")
        end
        if type(before.checkedGames) == "table" then
            assert(rawequal(active.checkedGames, before.checkedGames), "valid checkedGames table was replaced")
        end
    end
    ForeverFilterDB = nil
end)

----------------------------------------------------------------------
-- Feature: game-filter-checkboxes, Property 6: Header text is independent of the check state
-- Validates: Requirements 3.2, 4.1, 4.3, 8.1, 8.2, 8.3, 8.4, 8.10
----------------------------------------------------------------------
property("Feature: game-filter-checkboxes, Property 6: Header text is independent of the check state", function()
    -- Numeric project IDs are integers here (the code formats them with %d).
    local function genRowProjectID()
        local r = random()
        if r < 0.3 then return nil end
        if r < 0.8 then return random(0, 30) end
        return pick({ "1", "nil", "", "WoW" })
    end

    local function stubFormat(game, pid)
        return "<" .. tostring(game) .. "|" .. tostring(pid) .. ">"
    end

    for i = 1, ITERATIONS do
        local debug = random() < 0.5
        local UI, ns = loadUI({ debug = debug or nil, checkedGames = genStore() })
        local withGames = random() < 0.5
        if withGames then
            ns.Games = { FormatGame = function(game, pid) return stubFormat(game, pid) end }
        else
            ns.Games = nil
        end

        local row = { game = genGame(), wowProjectID = genRowProjectID(), count = random(0, 500) }
        local label
        if withGames then
            label = stubFormat(row.game, row.wowProjectID)
        else
            label = (row.game == nil or row.game == "") and "?" or tostring(row.game)
        end

        local ctx = string.format("(game=%s, pid=%s, count=%d, debug=%s, games=%s)",
            show(row.game), show(row.wowProjectID), row.count, tostring(debug), tostring(withGames))

        local text = UI.HeaderText(row)
        assert(type(text) == "string", "not a string " .. ctx)

        local suffix = " (" .. row.count .. ")"
        assert(#text >= #suffix and text:sub(-#suffix) == suffix, "bad suffix: " .. show(text) .. " " .. ctx)
        assert(text:sub(1, #label) == label, "label missing: " .. show(text) .. " " .. ctx)

        -- Whatever sits between the label and the count must be exactly the expected debug id text.
        local middle = text:sub(#label + 1, #text - #suffix)
        local expectedMiddle = ""
        if debug then
            if type(row.wowProjectID) == "number" then
                expectedMiddle = " [id: " .. row.wowProjectID .. "]"
            elseif row.game == "WoW" then
                expectedMiddle = " [id: none]"
            end
        end
        assert(middle == expectedMiddle, string.format("debug text %s ~= %s %s",
            show(middle), show(expectedMiddle), ctx))

        -- Independent of the check state.
        for _ = 1, random(1, 3) do
            UI.SetChecked(row.game, row.wowProjectID, random() < 0.5)
            assert(UI.HeaderText(row) == text, "header changed after SetChecked " .. ctx)
        end
    end
end)

----------------------------------------------------------------------
-- (append further properties above this line)
----------------------------------------------------------------------
print(string.format("%d/%d properties passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
