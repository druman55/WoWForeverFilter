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

-- Friends.lua and Games.lua load into one shared ns (pass an existing ns to share).
local function loadModule(file, ns)
    ns = ns or {}
    local chunk, err = loadfile("ForeverFilter/" .. file .. ".lua")
    if not chunk then
        error("cannot load ForeverFilter/" .. file .. ".lua: " .. tostring(err))
    end
    chunk("ForeverFilter", ns)
    return ns
end

local function loadFriends(ns)
    ns = loadModule("Friends", ns)
    return ns.Friends, ns
end

local function loadGames(ns)
    ns = loadModule("Games", ns)
    return ns.Games, ns
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

-- Friend entries as Friends.GetAll produces them (project IDs are positive numbers or nil).
local function genEntry()
    local game
    local r = random()
    if r < 0.1 then game = nil
    elseif r < 0.5 then game = "WoW"
    elseif r < 0.9 then game = pick({ "D3", "Pro", "WTCG", "S2", "BSAp", "App" })
    else game = genString() end

    local subIcon
    r = random()
    if r < 0.4 then subIcon = nil
    elseif r < 0.5 then subIcon = ""
    elseif r < 0.9 then subIcon = pick({ "WoW_Classic", "WoW_Era", "WoW_Retail", genString() })
    else subIcon = random(0, 9) end

    return {
        name = (random() < 0.1) and nil or pick({ "Ann", "bob", "Cy", genString() }),
        isOnline = random() < 0.85,
        game = game,
        wowProjectID = (random() < 0.4) and nil or pick({ 1, 2, 5, 11, 14, 19, random(1, 30) }),
        subIcon = subIcon,
    }
end

local function genEntries()
    local list = {}
    for i = 1, random(0, 14) do list[i] = genEntry() end
    return list
end

-- Name function with few distinct names that differ only in letter case. Memoized per key.
local function genCollidingNameFn()
    local names = { "alpha", "Alpha", "ALPHA", "beta", "Beta", "gamma" }
    local memo = {}
    return function(game, pid)
        local k = tostring(game) .. ":" .. tostring(pid)
        if memo[k] == nil then memo[k] = pick(names) end
        return memo[k]
    end
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
            before = {} -- the generated db is not used; the global is created fresh
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
-- Feature: game-list-polish, Property 1: Rows are ordered by name, then game code, then project ID
-- Validates: Requirements 1.1, 1.2, 1.4, 1.5
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 1: Rows are ordered by name, then game code, then project ID", function()
    local Friends, ns = loadFriends()
    local Games = loadGames(ns)

    -- Independent order: returns true when row a must come strictly before row b.
    local function before(nameFn, a, b)
        local na = nameFn and tostring(nameFn(a.game, a.wowProjectID)):lower() or a.game
        local nb = nameFn and tostring(nameFn(b.game, b.wowProjectID)):lower() or b.game
        if na ~= nb then return na < nb end
        if a.game ~= b.game then return a.game < b.game end
        local pa, pb = a.wowProjectID, b.wowProjectID
        if pa == nil then return pb ~= nil end
        if pb == nil then return false end
        return pa < pb
    end

    for i = 1, ITERATIONS do
        local entries = genEntries()
        local mode = random(3)
        local nameFn
        if mode == 1 then nameFn = Games.GetGameName
        elseif mode == 2 then nameFn = genCollidingNameFn()
        else nameFn = nil end

        local ok, rows = pcall(Friends.GroupByGame, entries, nameFn)
        assert(ok, "GroupByGame raised (mode " .. mode .. "): " .. tostring(rows))

        for j = 1, #rows - 1 do
            local a, b = rows[j], rows[j + 1]
            assert(before(nameFn, a, b) and not before(nameFn, b, a), string.format(
                "rows %d/%d out of order (mode %d): (%s,%s) then (%s,%s)", j, j + 1, mode,
                show(a.game), show(a.wowProjectID), show(b.game), show(b.wowProjectID)))
        end
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 2: Row order does not depend on counts or on other rows
-- Validates: Requirements 1.3, 1.6
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 2: Row order does not depend on counts or on other rows", function()
    local Friends, ns = loadFriends()
    local Games = loadGames(ns)

    local function keyOf(row) return tostring(row.game) .. ":" .. tostring(row.wowProjectID) end

    local function keys(rows)
        local list = {}
        for j, row in ipairs(rows) do list[j] = keyOf(row) end
        return list
    end

    local function describe(list) return "[" .. table.concat(list, ", ") .. "]" end

    for i = 1, ITERATIONS do
        local entries = genEntries()
        local mode = random(3)
        local nameFn
        if mode == 1 then nameFn = Games.GetGameName
        elseif mode == 2 then nameFn = genCollidingNameFn()
        else nameFn = nil end

        local ok, base = pcall(Friends.GroupByGame, entries, nameFn)
        assert(ok, "GroupByGame raised (mode " .. mode .. "): " .. tostring(base))
        local baseKeys = keys(base)

        -- Adding friends to existing groups: clone online entries under fresh friend names.
        local more = {}
        for j, e in ipairs(entries) do more[j] = e end
        for j, e in ipairs(entries) do
            if e.isOnline then
                for k = 1, random(0, 3) do
                    more[#more + 1] = {
                        name = "extra" .. j .. "_" .. k,
                        isOnline = true,
                        game = e.game,
                        wowProjectID = e.wowProjectID,
                        subIcon = e.subIcon,
                    }
                end
            end
        end
        local ok2, grown = pcall(Friends.GroupByGame, more, nameFn)
        assert(ok2, "GroupByGame raised on grown list (mode " .. mode .. "): " .. tostring(grown))
        local grownKeys = keys(grown)
        assert(#grownKeys == #baseKeys and describe(grownKeys) == describe(baseKeys), string.format(
            "adding friends changed row keys (mode %d): %s -> %s", mode, describe(baseKeys), describe(grownKeys)))

        -- Removing a random subset: survivors keep their relative order.
        local kept = {}
        for _, e in ipairs(entries) do
            if random() < 0.6 then kept[#kept + 1] = e end
        end
        local ok3, reduced = pcall(Friends.GroupByGame, kept, nameFn)
        assert(ok3, "GroupByGame raised on reduced list (mode " .. mode .. "): " .. tostring(reduced))
        local reducedKeys = keys(reduced)

        local inReduced = {}
        for _, k in ipairs(reducedKeys) do inReduced[k] = true end
        local expected = {}
        for _, k in ipairs(baseKeys) do
            if inReduced[k] then expected[#expected + 1] = k end
        end
        assert(describe(expected) == describe(reducedKeys), string.format(
            "removing entries reordered rows (mode %d): full %s, reduced %s", mode,
            describe(baseKeys), describe(reducedKeys)))
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 3: Grouping keys are unchanged and rows carry the first sub-icon
-- Validates: Requirements 4.2, 4.3, 5.1
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 3: Grouping keys are unchanged and rows carry the first sub-icon", function()
    local Friends, ns = loadFriends()
    local Games = loadGames(ns)
    local UI = loadUI({})

    -- Independent key: project ID only counts for WoW.
    local function expectedKey(game, pid)
        local g = game or "?"
        return g .. ":" .. (g == "WoW" and tostring(pid) or "nil")
    end

    for i = 1, ITERATIONS do
        local entries = genEntries()
        -- Add entries that differ from an existing one only in subIcon.
        for j = 1, #entries do
            if random() < 0.4 then
                local e = entries[j]
                entries[#entries + 1] = {
                    name = e.name, isOnline = e.isOnline, game = e.game, wowProjectID = e.wowProjectID,
                    subIcon = pick({ "WoW_Classic", "WoW_Era", "WoW_Retail", "", 3 }),
                }
            end
        end
        -- Shuffle so clones land anywhere in input order.
        for j = #entries, 2, -1 do
            local k = random(j)
            entries[j], entries[k] = entries[k], entries[j]
        end

        local nameFn = (random() < 0.5) and Games.GetGameName or nil
        local ok, rows = pcall(Friends.GroupByGame, entries, nameFn)
        assert(ok, "GroupByGame raised: " .. tostring(rows))

        -- Expected key set and first non-nil subIcon per key, from input order.
        local wantKeys, wantIcon = {}, {}
        for _, e in ipairs(entries) do
            if e.isOnline then
                local k = expectedKey(e.game, e.wowProjectID)
                wantKeys[k] = true
                if wantIcon[k] == nil and e.subIcon ~= nil then wantIcon[k] = e.subIcon end
            end
        end

        local gotKeys, count = {}, 0
        for _, row in ipairs(rows) do
            local k = UI.GameKey(row.game, row.wowProjectID)
            assert(k == expectedKey(row.game, row.wowProjectID), "GameKey mismatch for row " .. tostring(k))
            assert(not gotKeys[k], "duplicate row key " .. tostring(k))
            gotKeys[k] = true
            count = count + 1
            assert(wantKeys[k], "unexpected row key " .. tostring(k))
            assert(row.subIcon == wantIcon[k], string.format("row %s subIcon %s, expected %s",
                k, show(row.subIcon), show(wantIcon[k])))
        end
        local wantCount = 0
        for k in pairs(wantKeys) do
            wantCount = wantCount + 1
            assert(gotKeys[k], "missing row for key " .. tostring(k))
        end
        assert(count == wantCount, "row count " .. count .. " ~= " .. wantCount)
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 4: Friends provider records only non-empty string sub-icons
-- Validates: Requirements 4.1
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 4: Friends provider records only non-empty string sub-icons", function()
    local Friends = loadFriends()

    local saved = {
        BNGetNumFriends = BNGetNumFriends,
        C_BattleNet = C_BattleNet,
    }

    local function genSubIcon()
        local r = random(5)
        if r == 1 then return nil end
        if r == 2 then return "" end
        if r == 3 then return pick({ "WoW_Classic", "WoW_Era", "WoW_Retail", genString() }) end
        if r == 4 then return pick({ random(0, 9), true, false, {}, function() end }) end
        return genString()
    end

    local ok, err = pcall(function()
        for i = 1, ITERATIONS do
            local values = {}
            for j = 1, random(1, 6) do values[j] = { v = genSubIcon() } end

            BNGetNumFriends = function() return #values end
            C_BattleNet = {
                GetFriendAccountInfo = function(index) return { accountName = "F" .. index } end,
                GetFriendNumGameAccounts = function() return 1 end,
                GetFriendGameAccountInfo = function(index)
                    return { isOnline = true, clientProgram = "WoW", wowProjectID = 1, subIcon = values[index].v }
                end,
            }

            local entries = Friends.GetAll()
            assert(#entries == #values, "entry count " .. #entries .. " ~= " .. #values)
            for _, e in ipairs(entries) do
                local index = tonumber(e.name:match("^F(%d+)$"))
                local input = values[index].v
                local expected = (type(input) == "string" and input ~= "") and input or nil
                assert(e.subIcon == expected, string.format("subIcon %s for input %s, expected %s",
                    show(e.subIcon), show(input), show(expected)))
            end
        end
    end)

    BNGetNumFriends = saved.BNGetNumFriends
    C_BattleNet = saved.C_BattleNet
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 5: Title icon calls receive the game code and the row sub-icon
-- Validates: Requirements 4.4, 4.5, 4.8
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 5: Title icon calls receive the game code and the row sub-icon", function()
    local Games = loadGames()

    local saved = {
        C_Texture = C_Texture,
        Enum = Enum,
        BNet_GetClientEmbeddedTexture = BNet_GetClientEmbeddedTexture,
    }

    local VERSION = { "small-version" }
    local calls -- recorded calls: { fn = name, n = argcount, args = {...} }
    local readyResult

    local function record(name, ...)
        calls[#calls + 1] = { fn = name, n = select("#", ...), args = { ... } }
    end

    local function install()
        C_Texture = {
            IsTitleIconTextureReady = function(...)
                record("ready", ...)
                return readyResult
            end,
            GetTitleIconTexture = function(game, version, callback, ...)
                record("get", game, version, callback, ...)
                local sub = ...
                callback(true, "tex:" .. tostring(game) .. ":" .. tostring(sub))
            end,
        }
        Enum = { TitleIconVersion = { Small = VERSION } }
        BNet_GetClientEmbeddedTexture = function(texture) return "|T" .. texture .. "|t" end
    end

    local function callsOf(name)
        local list = {}
        for _, c in ipairs(calls) do
            if c.fn == name then list[#list + 1] = c end
        end
        return list
    end

    local function genSubIconArg()
        local r = random(4)
        if r == 1 then return nil end
        if r == 2 then return "WoW_Classic" end
        if r == 3 then return "WoW_Era" end
        return "sub" .. random(1, 50)
    end

    local ok, err = pcall(function()
        for i = 1, ITERATIONS do
            local game = pick({ "WoW", "D3", "Pro", "WTCG", "S2", "App" })
            local sub = genSubIconArg()
            local expectedN = (sub == nil) and 3 or 4 -- get: game, version, callback[, sub]
            local expectedReadyN = (sub == nil) and 2 or 3

            -- Ready path: both calls receive the game code, version, and sub-icon (trailing arg omitted when nil).
            readyResult = true
            calls = {}
            install()
            local markup = Games.GetIconMarkup(game, 14, sub)
            local readyCalls, getCalls = callsOf("ready"), callsOf("get")
            assert(#readyCalls == 1, "expected 1 ready call, got " .. #readyCalls)
            assert(#getCalls == 1, "expected 1 get call, got " .. #getCalls)
            local r, g = readyCalls[1], getCalls[1]
            assert(r.args[1] == game and r.args[2] == VERSION, "ready got wrong game/version")
            assert(r.n == expectedReadyN, string.format("ready arg count %d, expected %d (sub=%s)", r.n, expectedReadyN, show(sub)))
            assert(r.args[3] == sub, "ready sub-icon " .. show(r.args[3]) .. " ~= " .. show(sub))
            assert(g.args[1] == game and g.args[2] == VERSION, "get got wrong game/version")
            assert(g.n == expectedN, string.format("get arg count %d, expected %d (sub=%s)", g.n, expectedN, show(sub)))
            assert(g.args[4] == sub, "get sub-icon " .. show(g.args[4]) .. " ~= " .. show(sub))
            assert(markup == "|Ttex:" .. game .. ":" .. tostring(sub) .. "|t", "unexpected markup " .. show(markup))

            -- Not-ready path: the warm-up request also carries the sub-icon.
            readyResult = false
            calls = {}
            install()
            local m2, pending = Games.GetIconMarkup(game, 14, sub)
            assert(m2 == nil and pending == true, "not-ready should be nil, pending")
            local warm = callsOf("get")
            assert(#warm == 1 and warm[1].args[1] == game and warm[1].args[4] == sub
                and warm[1].n == expectedN, "warm-up call did not carry game and sub-icon")

            -- Two distinct sub-icons are each requested and yield different markup.
            local a, b = "subA" .. random(1, 9), "subB" .. random(1, 9)
            readyResult = true
            calls = {}
            install()
            local ma = Games.GetIconMarkup("WoW", 14, a)
            local mb = Games.GetIconMarkup("WoW", 14, b)
            local seen = {}
            for _, c in ipairs(callsOf("get")) do seen[c.args[4]] = true end
            assert(seen[a] and seen[b], "both sub-icons must be requested")
            assert(ma ~= nil and mb ~= nil and ma ~= mb, "markup should differ for different sub-icon textures")
        end
    end)

    C_Texture = saved.C_Texture
    Enum = saved.Enum
    BNet_GetClientEmbeddedTexture = saved.BNet_GetClientEmbeddedTexture
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 6: Icon routes fall back in order and are deterministic
-- Validates: Requirements 4.6, 4.7, 4.10
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 6: Icon routes fall back in order and are deterministic", function()
    local Games = loadGames()

    local saved = {
        C_Texture = C_Texture,
        Enum = Enum,
        BNet_GetClientEmbeddedTexture = BNet_GetClientEmbeddedTexture,
        BNet_GetClientEmbeddedAtlas = BNet_GetClientEmbeddedAtlas,
    }

    local VERSION = { "small-version" }

    -- Reference implementation of the route selection.
    local function oracle(cfg, game, size)
        if type(game) ~= "string" or game == "" then return nil, false end
        size = tonumber(size) or 14
        local pending = false
        if cfg.titleApi then
            if not cfg.ready then
                pending = true
            elseif cfg.success then
                return "|Ttex:" .. game .. ":" .. size .. "|t", false
            end
        end
        if cfg.atlas then
            return "|A:" .. game .. ":" .. size .. "|a", pending
        end
        return nil, pending
    end

    local function install(cfg)
        C_Texture = {
            GetAtlasInfo = function(name)
                if cfg.atlas then return { name = name } end
                return nil
            end,
        }
        Enum = nil
        BNet_GetClientEmbeddedTexture = nil
        BNet_GetClientEmbeddedAtlas = function(game, w, h) return "|A:" .. game .. ":" .. w .. "|a" end
        if cfg.titleApi then
            C_Texture.IsTitleIconTextureReady = function() return cfg.ready end
            C_Texture.GetTitleIconTexture = function(game, _, callback)
                if cfg.ready then callback(cfg.success, "tex:" .. game) end
            end
            Enum = { TitleIconVersion = { Small = VERSION } }
            BNet_GetClientEmbeddedTexture = function(texture, _, _, w) return "|T" .. texture .. ":" .. w .. "|t" end
        end
    end

    local function genSub()
        local r = random(4)
        if r == 1 then return nil end
        if r == 2 then return "" end
        if r == 3 then return 42 end
        return "sub" .. random(1, 20)
    end

    local ok, err = pcall(function()
        for i = 1, ITERATIONS do
            local cfg = {
                titleApi = random() < 0.7,
                ready = random() < 0.6,
                success = random() < 0.6,
                atlas = random() < 0.5,
            }
            local game = genGame()
            local size = pick({ 14, 16, 20 })
            local sub = genSub()
            install(cfg)

            local m, p = Games.GetIconMarkup(game, size, sub)
            local em, ep = oracle(cfg, game, size)
            local label = string.format("cfg={api=%s,ready=%s,ok=%s,atlas=%s} game=%s sub=%s",
                tostring(cfg.titleApi), tostring(cfg.ready), tostring(cfg.success), tostring(cfg.atlas),
                show(game), show(sub))
            assert(m == em, label .. ": markup " .. show(m) .. " ~= " .. show(em))
            assert(p == ep, label .. ": pending " .. tostring(p) .. " ~= " .. tostring(ep))
            if cfg.titleApi and cfg.ready and not cfg.success and type(game) == "string" and game ~= "" then
                assert(p == false, label .. ": ready title icon must not be pending")
            end

            -- Deterministic: identical inputs, identical results.
            local m2, p2 = Games.GetIconMarkup(game, size, sub)
            assert(m2 == m and p2 == p, label .. ": results differ between identical calls")

            -- Non-WoW code with a nil sub-icon selects the same route as before the change
            -- (an empty or non-string sub-icon is treated as absent).
            if game ~= "WoW" then
                local m3, p3 = Games.GetIconMarkup(game, size)
                local m4, p4 = Games.GetIconMarkup(game, size, "")
                assert(m3 == em and p3 == ep, label .. ": nil sub-icon route changed")
                assert(m4 == m3 and p4 == p3, label .. ": empty sub-icon differs from nil")
            end
        end
    end)

    C_Texture = saved.C_Texture
    Enum = saved.Enum
    BNet_GetClientEmbeddedTexture = saved.BNet_GetClientEmbeddedTexture
    BNet_GetClientEmbeddedAtlas = saved.BNet_GetClientEmbeddedAtlas
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 7: Header text requests a 20 px icon with the row sub-icon
-- Validates: Requirements 3.1, 4.4, 5.2
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 7: Header text requests a 20 px icon with the row sub-icon", function()
    for i = 1, ITERATIONS do
        local debug = random() < 0.5
        local UI, ns = loadUI({ debug = debug or nil })
        local calls = {}
        local pendingResult = random() < 0.5
        ns.Games = {
            FormatGame = function(...)
                calls[#calls + 1] = { n = select("#", ...), ... }
                return "LBL", pendingResult
            end,
        }

        local pid = random(0, 30)
        if random() < 0.3 then pid = nil end
        local sub = pick({ "", "sub" .. random(1, 20), "classic" })
        if random() < 0.3 then sub = nil end
        local row = { game = genGame(), wowProjectID = pid, subIcon = sub, count = random(0, 500) }
        local ctx = string.format("(game=%s, pid=%s, sub=%s, count=%d, debug=%s)",
            show(row.game), show(pid), show(sub), row.count, tostring(debug))

        local text, pending = UI.HeaderText(row)
        assert(#calls == 1, "FormatGame call count " .. #calls .. " " .. ctx)
        local c = calls[1]
        assert(c[1] == row.game, "game arg " .. ctx)
        assert(c[2] == row.wowProjectID, "wowProjectID arg " .. ctx)
        assert(c[3] == 20, "size arg " .. show(c[3]) .. " " .. ctx)
        assert(c[4] == row.subIcon, "subIcon arg " .. ctx)
        assert(pending == pendingResult, "pending not passed through " .. ctx)

        local expectedMiddle = ""
        if debug then
            if type(pid) == "number" then
                expectedMiddle = " [id: " .. pid .. "]"
            elseif row.game == "WoW" then
                expectedMiddle = " [id: none]"
            end
        end
        local expected = "LBL" .. expectedMiddle .. " (" .. row.count .. ")"
        assert(text == expected, string.format("text %s ~= %s %s", show(text), show(expected), ctx))
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 8: Window height is the clamped content height
-- Validates: Requirements 2.1, 2.2, 2.3
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 8: Window height is the clamped content height", function()
    local UI = loadUI({})
    for i = 1, ITERATIONS do
        local rowArea = random() < 0.2 and 0 or random(0, 5000) + (random() < 0.5 and 0.5 or 0)
        local screen = random() < 0.2 and random(1, 200) or random(200, 4000) + (random() < 0.5 and 0.5 or 0)
        local ctx = string.format("(rowArea=%s, screen=%s)", show(rowArea), show(screen))

        local expected = math.min(math.max(120, math.floor(0.8 * screen)), math.max(120, 66 + rowArea))
        local h = UI.ComputeWindowHeight(rowArea, screen, false)
        assert(h == expected, string.format("height %s ~= %s %s", show(h), show(expected), ctx))
        assert(h >= 120, "below minimum " .. ctx)

        local e = UI.ComputeWindowHeight(rowArea, screen, true)
        assert(e == 120, "empty state height " .. show(e) .. " " .. ctx)
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 9: Row height is never smaller than the checkbox or the text
-- Validates: Requirements 3.3, 3.4
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 9: Row height is never smaller than the checkbox or the text", function()
    local UI = loadUI({})
    local CHECK_SIZE = 24
    for i = 1, ITERATIONS do
        local r = random()
        local sh
        if r < 0.1 then sh = nil
        elseif r < 0.2 then sh = 0
        elseif r < 0.4 then sh = random() * 0.999
        elseif r < 0.7 then sh = random(1, 60) + (random() < 0.5 and random() or 0)
        else sh = random(60, 5000) end
        local ctx = "(stringHeight=" .. show(sh) .. ")"

        local h = UI.RowHeight(sh)
        assert(type(h) == "number", "not a number " .. ctx)
        assert(h >= CHECK_SIZE, "below checkbox size " .. show(h) .. " " .. ctx)
        if type(sh) == "number" and sh >= 1 then
            assert(h >= sh, "below text height " .. show(h) .. " " .. ctx)
        end
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 10: Icon retries are bounded
-- Validates: Requirements 4.9
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 10: Icon retries are bounded", function()
    local UI = loadUI({})
    for i = 1, ITERATIONS do
        -- Single-call semantics
        local budget = random(0, 6)
        for _, pending in ipairs({ true, false }) do
            local sched, left = UI.NextRetry(pending, budget)
            local ctx = string.format("(pending=%s, budget=%d)", tostring(pending), budget)
            assert(sched == (pending and budget > 0), "schedule mismatch " .. ctx)
            assert(left == (sched and budget - 1 or budget), "budget mismatch " .. ctx)
        end

        -- Refresh loop: pending stays true for a random number of refreshes
        local start = random(0, 6)
        local pendingRefreshes = random(0, 20)
        local left, retries = start, 0
        for r = 1, pendingRefreshes do
            local sched, newLeft = UI.NextRetry(true, left)
            left = newLeft
            if sched then retries = retries + 1 end
            assert(left >= 0, "budget negative")
        end
        assert(retries == math.min(start, pendingRefreshes),
            string.format("retries %d (start=%d, refreshes=%d)", retries, start, pendingRefreshes))
        assert(retries <= start, "retries exceed budget")

        -- Nothing pending: never schedules, budget unchanged
        local sched, unchanged = UI.NextRetry(false, start)
        assert(sched == false and unchanged == start, "scheduled with nothing pending")
    end
    -- Concrete: budget 3 yields exactly 3 retries
    local left, n = 3, 0
    for _ = 1, 10 do
        local s, l = UI.NextRetry(true, left)
        left = l
        if s then n = n + 1 end
    end
    assert(n == 3 and left == 0, "budget 3 should yield exactly 3 retries")
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Example tests for UI.Refresh
-- Validates: Requirements 2.1, 2.3, 2.5, 2.6, 3.2, 5.3
----------------------------------------------------------------------
property("Feature: game-list-polish, Example tests: UI.Refresh sizing, anchoring, font and no-Games fallback", function()
    local saved = { CreateFrame = CreateFrame, UIParent = UIParent }

    -- Recording frame: every method call is logged; a few getters return fixed values.
    local frames = {}
    local function recFrame(name)
        local f = { calls = {}, name = name }
        local fixed = {
            IsShown = true, GetLeft = 100, GetTop = 500, GetWidth = 300,
            GetHeight = 1080, GetStringHeight = 14, GetChecked = true, GetStringWidth = 400.2,
        }
        local absent = { TitleText = true, TitleContainer = true, InsetBg = true }
        setmetatable(f, { __index = function(t, key)
            if absent[key] then return nil end
            return function(self, ...)
                t.calls[#t.calls + 1] = { key, ... }
                if key == "CreateFontString" or key == "CreateTexture" then return recFrame() end
                return fixed[key]
            end
        end })
        frames[#frames + 1] = f
        return f
    end
    local function callsOf(f, method)
        local out = {}
        for _, c in ipairs(f.calls) do
            if c[1] == method then out[#out + 1] = c end
        end
        return out
    end

    local ok, err = pcall(function()
        -- Pure examples.
        local UI0 = loadUI({})
        assert(UI0.ComputeWindowHeight(0, 1080, true) == 120, "empty state height is not 120")
        local fiveRows = 66 + 5 * 24 + 4 * 6
        assert(UI0.ComputeWindowHeight(5 * 24 + 4 * 6, 1080, false) == fiveRows,
            "five rows on 1080 px: expected " .. fiveRows)
        assert(fiveRows == 210, "test arithmetic changed")

        -- Refresh with recording stubs and no ns.Games.
        local mainFrame
        CreateFrame = function(_, name)
            local f = recFrame(name)
            if name == "ForeverFilterFrame" then mainFrame = f end
            return f
        end
        UIParent = recFrame("UIParent")
        UIParent.GetWidth = function() return 1920 end

        local UI, ns = loadUI({})
        loadFriends(ns)
        ns.Games = nil
        local entries = {}
        for i = 1, 5 do
            entries[i] = { name = "F" .. i, isOnline = true, game = "G" .. i }
        end
        ns.Friends.GetAll = function() return entries end

        UI.Show()
        assert(mainFrame, "main frame was not created")

        -- Requirement 2.1/2.3: one SetHeight with the computed height.
        local heights = callsOf(mainFrame, "SetHeight")
        assert(#heights == 1, "SetHeight called " .. #heights .. " times")
        assert(heights[1][2] == fiveRows, "SetHeight(" .. tostring(heights[1][2]) .. ") ~= " .. fiveRows)

        -- Requirement 2.5: re-anchored by TOPLEFT after the height change.
        local points = callsOf(mainFrame, "SetPoint")
        local lastPoint = points[#points]
        assert(lastPoint and lastPoint[2] == "TOPLEFT", "last anchor is " .. tostring(lastPoint and lastPoint[2]))
        assert(#callsOf(mainFrame, "ClearAllPoints") >= 1, "window was not cleared before re-anchoring")

        -- Requirement 3.2: header font size 14.
        local sawFont14 = false
        local texts = {}
        for _, f in ipairs(frames) do
            for _, c in ipairs(callsOf(f, "SetFont")) do
                if c[3] == 14 then sawFont14 = true end
            end
            for _, c in ipairs(callsOf(f, "SetText")) do texts[#texts + 1] = c[2] end
        end
        assert(sawFont14, "SetFont was never called with size 14")

        -- Requirement 5.3: one row per group with the raw game code when ns.Games is nil.
        for i = 1, 5 do
            local want = "G" .. i .. " (1)"
            local found = false
            for _, t in ipairs(texts) do if t == want then found = true end end
            assert(found, "no header text " .. want)
        end

        -- Requirements 6.1, 6.5: window width is set once from the widest header (400.2 -> 487).
        local widths = callsOf(mainFrame, "SetWidth")
        assert(#widths == 1, "SetWidth called " .. #widths .. " times on the window")
        assert(widths[1][2] == 487, "SetWidth(" .. tostring(widths[1][2]) .. ") ~= 487")
        assert(widths[1][2] == UI.ComputeWindowWidth({ 400.2 }, 1920, false), "width differs from ComputeWindowWidth")
        local hw = UI.HeaderWidth(487)
        local headerCount = 0
        for _, f in ipairs(frames) do
            if #callsOf(f, "SetFont") > 0 and #callsOf(f, "SetText") > 0 and f ~= mainFrame then
                local ws = callsOf(f, "SetWidth")
                if #ws > 0 and ws[#ws][2] == hw then headerCount = headerCount + 1 end
            end
        end
        assert(headerCount >= 5, "only " .. headerCount .. " headers received HeaderWidth(487)")

        -- Requirement 2.6: a second Refresh keeps one SetHeight, one SetWidth, no SetSize.
        mainFrame.calls = {}
        UI.Refresh()
        assert(#callsOf(mainFrame, "SetHeight") == 1, "second Refresh: SetHeight count")
        local w2 = callsOf(mainFrame, "SetWidth")
        assert(#w2 == 1 and w2[1][2] == 487, "second Refresh: SetWidth count/value")
        assert(#callsOf(mainFrame, "SetSize") == 0, "SetSize was called on the window")
        local p2 = callsOf(mainFrame, "SetPoint")
        assert(p2[#p2] and p2[#p2][2] == "TOPLEFT", "second Refresh: not re-anchored with TOPLEFT")

        -- Requirement 6.3: empty state uses the minimum width (15% of 1920 = 288).
        entries = {}
        ns.Friends.GetAll = function() return entries end
        mainFrame.calls = {}
        UI.Refresh()
        local w3 = callsOf(mainFrame, "SetWidth")
        assert(#w3 == 1 and w3[1][2] == 288, "empty state width is " .. tostring(w3[1] and w3[1][2]))
        local p3 = callsOf(mainFrame, "SetPoint")
        assert(p3[#p3] and p3[#p3][2] == "TOPLEFT", "empty state: not re-anchored with TOPLEFT")
        assert(#callsOf(mainFrame, "SetSize") == 0, "empty state: SetSize was called")

        -- social-menu-attach Requirement 3.6: resizing never writes or changes the moved flag.
        assert(ns.db.window == nil, "Refresh created window settings")
        ns.db.window = { moved = false, left = 7, top = 9 }
        mainFrame.calls = {}
        entries = { { name = "F1", isOnline = true, game = "G1" } }
        ns.Friends.GetAll = function() return entries end
        UI.Refresh()
        assert(#callsOf(mainFrame, "SetHeight") == 1, "resize did not happen")
        local win = ns.db.window
        assert(win.moved == false and win.left == 7 and win.top == 9, "Refresh changed the window settings")
        ns.db.window = { moved = true, left = 7, top = 9 }
        UI.Refresh()
        win = ns.db.window
        assert(win.moved == true and win.left == 7 and win.top == 9, "Refresh changed the saved position")
    end)

    do
        local UI = loadUI({})
        assert(UI.ComputeWindowWidth({}, 1920, true) == 288, "empty: expected 288")
        assert(UI.ComputeWindowWidth({ 200 }, 1920, false) == 288, "{200}: expected 288")
        assert(UI.ComputeWindowWidth({ 400.2 }, 1920, false) == 487, "{400.2}: expected 487")
        assert(UI.ComputeWindowWidth({ 5000 }, 1920, false) == 960, "{5000}: expected 960")
    end
    CreateFrame = saved.CreateFrame
    UIParent = saved.UIParent
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 11: Window width is the clamped widest-row width
-- Validates: Requirements 6.1, 6.2, 6.3, 6.7
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 11: Window width is the clamped widest-row width", function()
    local UI = loadUI({})

    local function genWidths()
        local list = {}
        for j = 1, random(0, 8) do
            local r = random()
            if r < 0.3 then list[j] = random(0, 600)
            elseif r < 0.7 then list[j] = random() * 1500
            elseif r < 0.85 then list[j] = random(0, 5000)
            else list[j] = 0 end
        end
        return list
    end

    local function expected(widths, screen)
        local minW = math.floor(screen * 0.15)
        local maxW = math.max(minW, math.floor(screen * 0.5))
        local widest = 0
        for _, w in ipairs(widths) do if w > widest then widest = w end end
        return math.min(math.max(minW, 60 + 26 + math.ceil(widest)), maxW), minW, maxW
    end

    for i = 1, ITERATIONS do
        local widths = genWidths()
        local screen = pick({ 640, 800, 1024, 1280, 1920, 2560, 3840, random(100, 4000), random() * 3000 + 1 })

        local got = UI.ComputeWindowWidth(widths, screen, false)
        local want, minW, maxW = expected(widths, screen)
        assert(got == want, string.format("width %s ~= %s (screen=%s, %d widths)",
            tostring(got), tostring(want), tostring(screen), #widths))
        assert(got >= minW and got <= maxW, "result outside [minW, maxW]")

        local empty = UI.ComputeWindowWidth(widths, screen, true)
        assert(empty == minW, string.format("empty width %s ~= minW %s", tostring(empty), tostring(minW)))

        -- Missing or non-positive screen width behaves like 1024.
        local ref = UI.ComputeWindowWidth(widths, 1024, false)
        local refEmpty = UI.ComputeWindowWidth(widths, 1024, true)
        for _, bad in ipairs({ -1, 0, -500.5 }) do
            assert(UI.ComputeWindowWidth(widths, bad, false) == ref, "bad screen " .. bad .. " differs from 1024")
            assert(UI.ComputeWindowWidth(widths, bad, true) == refEmpty, "bad screen (empty) " .. bad)
        end
        assert(UI.ComputeWindowWidth(widths, nil, false) == ref, "nil screen differs from 1024")
        assert(UI.ComputeWindowWidth(widths, nil, true) == refEmpty, "nil screen (empty) differs from 1024")
    end

    -- Empty list and design examples.
    assert(UI.ComputeWindowWidth({}, 1920, false) == 288)
    assert(UI.ComputeWindowWidth({}, 1920, true) == 288)
    assert(UI.ComputeWindowWidth({ 400.2 }, 1920, false) == 60 + 26 + 401)
    assert(UI.ComputeWindowWidth({ 5000 }, 1920, false) == 960)
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 12: Window width depends only on the widest row
-- Validates: Requirements 6.1, 6.4
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 12: Window width depends only on the widest row", function()
    local UI = loadUI({})

    local function genWidths()
        local list = {}
        for j = 1, random(0, 8) do
            if random() < 0.5 then list[j] = random(0, 800) else list[j] = random() * 1200 end
        end
        return list
    end

    local function widestOf(list)
        local m = 0
        for _, w in ipairs(list) do if w > m then m = w end end
        return m
    end

    for i = 1, ITERATIONS do
        local widths = genWidths()
        local screen = pick({ 800, 1024, 1920, 2560, random(100, 4000) })
        local base = UI.ComputeWindowWidth(widths, screen, false)
        local widest = widestOf(widths)

        -- Permutation (Fisher-Yates shuffle of a copy).
        local shuffled = {}
        for j, w in ipairs(widths) do shuffled[j] = w end
        for j = #shuffled, 2, -1 do
            local k = random(1, j)
            shuffled[j], shuffled[k] = shuffled[k], shuffled[j]
        end
        assert(UI.ComputeWindowWidth(shuffled, screen, false) == base, "permutation changed width")

        -- Extra widths not larger than the widest leave the result unchanged.
        local extended = {}
        for j, w in ipairs(widths) do extended[j] = w end
        for _ = 1, random(0, 5) do
            extended[#extended + 1] = random() * widest
        end
        assert(UI.ComputeWindowWidth(extended, screen, false) == base, "smaller extra widths changed width")

        -- Adding a larger width never decreases the result.
        local bigger = {}
        for j, w in ipairs(widths) do bigger[j] = w end
        bigger[#bigger + 1] = widest + random() * 2000 + 0.01
        assert(UI.ComputeWindowWidth(bigger, screen, false) >= base, "larger width decreased result")
    end
end)

----------------------------------------------------------------------
-- Feature: game-list-polish, Property 13: Unclamped widths fit the header exactly
-- Validates: Requirements 6.1, 6.2, 6.6, 3.4
----------------------------------------------------------------------
property("Feature: game-list-polish, Property 13: Unclamped widths fit the header exactly", function()
    local UI = loadUI({})

    for i = 1, ITERATIONS do
        local screen = pick({ 800, 1024, 1920, 2560, 3840, random(300, 4000), random() * 3000 + 300 })
        local minW = math.floor(screen * 0.15)
        local maxW = math.max(minW, math.floor(screen * 0.5))

        -- Choose a text width whose unclamped window width lies in [minW, maxW].
        local lo = math.max(0, minW - 86)
        local hi = maxW - 86
        if hi >= lo then
            local text = lo + random() * (hi - lo)
            if random() < 0.3 then text = math.floor(text) end
            if 86 + math.ceil(text) >= minW and 86 + math.ceil(text) <= maxW then
                local w = UI.ComputeWindowWidth({ text }, screen, false)
                assert(w == 86 + math.ceil(text), "window width not unclamped: " .. tostring(w))
                assert(UI.HeaderWidth(w) >= text,
                    string.format("header %s < text %s (screen=%s)", tostring(UI.HeaderWidth(w)), tostring(text), tostring(screen)))
            end
        end

        -- HeaderWidth inverse and floor, for any window width.
        local ww = pick({ random(-100, 5000), random() * 5000, 87, 86, 0 })
        local hw = UI.HeaderWidth(ww)
        assert(hw >= 1, "HeaderWidth < 1 for " .. tostring(ww))
        if ww >= 87 then
            assert(hw + 26 + 60 == ww, string.format("HeaderWidth(%s)=%s not inverse", tostring(ww), tostring(hw)))
        end
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 1: Right side when the window fits on the right
-- Validates: Requirements 2.2, 2.4, 2.7
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 1: Right side when the window fits on the right", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP
    local TOL = 1e-9

    for i = 1, ITERATIONS do
        local uiW = 800 + random() * 2200
        local uiH = 500 + random() * 1500
        local w = 50 + random() * math.min(600, uiW - gap - 100)
        local h = 50 + random() * (uiH - 50) -- never taller than the screen
        local socialScale = 0.4 + random() * 1.4
        local uiScale = 0.4 + random() * 1.4
        local k = socialScale / uiScale

        -- Force the right position to fit: gap <= rightLeft <= uiW - w (with a margin for rounding).
        local rightLeft = gap + random() * (uiW - w - gap - 1e-6)
        local socialRight = (rightLeft - gap) / k
        local socialLeft = socialRight - (50 + random() * 500)
        -- Scaled top from well above to well below the screen, so vertical clamping occurs.
        local scaledTop = -300 + random() * (uiH + 600)
        local socialTop = scaledTop / k

        local ctx = string.format("socialLeft=%s socialRight=%s socialTop=%s sScale=%s uiScale=%s ui=%sx%s w=%s h=%s",
            tostring(socialLeft), tostring(socialRight), tostring(socialTop), tostring(socialScale),
            tostring(uiScale), tostring(uiW), tostring(uiH), tostring(w), tostring(h))

        local left, top, side = UI.ComputeAttachPosition(socialLeft, socialRight, socialTop,
            socialScale, uiScale, uiW, uiH, w, h, gap)

        assert(side == "right", "side " .. tostring(side) .. " ~= right: " .. ctx)
        local expectedLeft = socialRight * socialScale / uiScale + gap
        assert(math.abs(left - expectedLeft) <= TOL, string.format("left %s ~= %s: %s",
            tostring(left), tostring(expectedLeft), ctx))

        -- Minimal vertical shift: top edge at most uiH, bottom edge (top - h) at least 0.
        local expectedTop = socialTop * socialScale / uiScale
        if expectedTop > uiH then expectedTop = uiH end
        if expectedTop - h < 0 then expectedTop = h end
        assert(math.abs(top - expectedTop) <= TOL, string.format("top %s ~= %s: %s",
            tostring(top), tostring(expectedTop), ctx))
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 2: Left side when the window does not fit on the right but fits on the left
-- Validates: Requirements 2.3, 2.5, 2.7
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 2: Left side when the window does not fit on the right but fits on the left", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP
    local TOL = 1e-9

    for i = 1, ITERATIONS do
        local uiW = 800 + random() * 2200
        local uiH = 500 + random() * 1500
        local w = 50 + random() * math.min(600, uiW - gap - 100)
        local h = 50 + random() * (uiH - 50)
        local socialScale = 0.4 + random() * 1.4
        local uiScale = 0.4 + random() * 1.4
        local k = socialScale / uiScale

        -- Left position fits: 0 <= leftLeft <= uiW - w (margin for rounding).
        local leftLeft = 1e-6 + random() * (uiW - w - 2e-6)
        local scaledLeft = leftLeft + gap + w
        -- Social frame reaches far enough right that the right position cannot fit.
        local scaledRight = math.max(scaledLeft + 50, uiW - w - gap + 1) + random() * 100
        local socialLeft = scaledLeft / k
        local socialRight = scaledRight / k
        local scaledTop = -300 + random() * (uiH + 600)
        local socialTop = scaledTop / k

        local ctx = string.format("socialLeft=%s socialRight=%s socialTop=%s sScale=%s uiScale=%s ui=%sx%s w=%s h=%s",
            tostring(socialLeft), tostring(socialRight), tostring(socialTop), tostring(socialScale),
            tostring(uiScale), tostring(uiW), tostring(uiH), tostring(w), tostring(h))

        local left, top, side = UI.ComputeAttachPosition(socialLeft, socialRight, socialTop,
            socialScale, uiScale, uiW, uiH, w, h, gap)

        assert(side == "left", "side " .. tostring(side) .. " ~= left: " .. ctx)
        local expectedLeft = socialLeft * socialScale / uiScale - gap - w
        assert(math.abs(left - expectedLeft) <= TOL, string.format("left %s ~= %s: %s",
            tostring(left), tostring(expectedLeft), ctx))

        local expectedTop = socialTop * socialScale / uiScale
        if expectedTop > uiH then expectedTop = uiH end
        if expectedTop - h < 0 then expectedTop = h end
        assert(math.abs(top - expectedTop) <= TOL, string.format("top %s ~= %s: %s",
            tostring(top), tostring(expectedTop), ctx))
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 3: Neither side fits gives a clamped right position
-- Validates: Requirements 2.6, 2.8
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 3: Neither side fits gives a clamped right position", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP
    local TOL = 1e-9

    for i = 1, ITERATIONS do
        local uiW = 800 + random() * 2200
        local uiH = 500 + random() * 1500
        local w, scaledLeft, scaledRight
        if random() < 0.4 then
            -- Window wider than the screen: no position can fit.
            w = uiW * (1 + random() * 0.5) + 1e-3
            scaledLeft = -200 + random() * (uiW + 400)
            scaledRight = scaledLeft + 50 + random() * 500
        else
            -- Window wider than half the screen with the social frame in the middle:
            -- the right edge overflows and the left edge underflows.
            w = uiW * (0.55 + random() * 0.45)
            scaledLeft = random() * math.min(w + gap - 1e-3, uiW)
            scaledRight = math.max(scaledLeft + 50, uiW - w - gap + 1) + random() * 100
        end
        local h = (random() < 0.3) and (uiH * (1 + random() * 0.5) + 1e-3) or (50 + random() * (uiH - 50))
        local socialScale = 0.4 + random() * 1.4
        local uiScale = 0.4 + random() * 1.4
        local k = socialScale / uiScale
        local socialLeft = scaledLeft / k
        local socialRight = scaledRight / k
        local scaledTop = -300 + random() * (uiH + 600)
        local socialTop = scaledTop / k

        local ctx = string.format("socialLeft=%s socialRight=%s socialTop=%s sScale=%s uiScale=%s ui=%sx%s w=%s h=%s",
            tostring(socialLeft), tostring(socialRight), tostring(socialTop), tostring(socialScale),
            tostring(uiScale), tostring(uiW), tostring(uiH), tostring(w), tostring(h))

        -- Independent check that neither side fits.
        local rightLeft = socialRight * socialScale / uiScale + gap
        local leftLeft = socialLeft * socialScale / uiScale - gap - w
        assert(not (rightLeft >= 0 and rightLeft + w <= uiW), "generator: right fits: " .. ctx)
        assert(not (leftLeft >= 0 and leftLeft + w <= uiW), "generator: left fits: " .. ctx)

        local left, top, side = UI.ComputeAttachPosition(socialLeft, socialRight, socialTop,
            socialScale, uiScale, uiW, uiH, w, h, gap)

        assert(side == "clamped", "side " .. tostring(side) .. " ~= clamped: " .. ctx)
        local expectedLeft, expectedTop = UI.ClampToScreen(rightLeft,
            socialTop * socialScale / uiScale, w, h, uiW, uiH)
        assert(math.abs(left - expectedLeft) <= TOL, string.format("left %s ~= %s: %s",
            tostring(left), tostring(expectedLeft), ctx))
        assert(math.abs(top - expectedTop) <= TOL, string.format("top %s ~= %s: %s",
            tostring(top), tostring(expectedTop), ctx))
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 4: Clamping keeps the window on screen with minimal shift
-- Validates: Requirements 2.6, 2.7, 2.8, 3.4
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 4: Clamping keeps the window on screen with minimal shift", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP
    local TOL = 1e-9

    for i = 1, ITERATIONS do
        local screenW = 400 + random() * 2600
        local screenH = 300 + random() * 1700
        -- Sizes up to 1.5x the screen, so some windows are larger than it.
        local w = 20 + random() * (screenW * 1.5 - 20)
        local h = 20 + random() * (screenH * 1.5 - 20)
        -- Positions on every side: left of, inside, and right of the screen (same vertically).
        local left = -1.5 * screenW + random() * 3.5 * screenW
        local top = -1.0 * screenH + random() * 3.0 * screenH

        local ctx = string.format("left=%s top=%s w=%s h=%s screen=%sx%s", tostring(left), tostring(top),
            tostring(w), tostring(h), tostring(screenW), tostring(screenH))

        local l, t = UI.ClampToScreen(left, top, w, h, screenW, screenH)

        -- Horizontal axis.
        if w > screenW then
            assert(l == 0, "oversized width must align to left edge: " .. ctx)
        else
            assert(l >= -TOL and l + w <= screenW + TOL, "window not inside horizontally: " .. ctx)
            local inside = left >= 0 and left + w <= screenW
            if inside then
                assert(l == left, "inside position changed horizontally: " .. ctx)
            else
                local dist = (left < 0) and -left or (left + w - screenW)
                assert(math.abs(math.abs(l - left) - dist) <= TOL, string.format(
                    "horizontal shift %s ~= distance %s: %s", tostring(math.abs(l - left)), tostring(dist), ctx))
            end
        end

        -- Vertical axis: the window spans [top - h, top].
        if h > screenH then
            assert(t == screenH, "oversized height must align to top edge: " .. ctx)
        else
            assert(t - h >= -TOL and t <= screenH + TOL, "window not inside vertically: " .. ctx)
            local inside = top <= screenH and top - h >= 0
            if inside then
                assert(t == top, "inside position changed vertically: " .. ctx)
            else
                local dist = (top > screenH) and (top - screenH) or (h - top)
                assert(math.abs(math.abs(t - top) - dist) <= TOL, string.format(
                    "vertical shift %s ~= distance %s: %s", tostring(math.abs(t - top)), tostring(dist), ctx))
            end
        end
    end

    -- For attached results on the right or left, the clamp leaves the returned left unchanged.
    local checked = 0
    for i = 1, ITERATIONS do
        local uiW = 800 + random() * 2200
        local uiH = 500 + random() * 1500
        local w = 50 + random() * (uiW * 0.7)
        local h = 50 + random() * (uiH * 1.4)
        local socialScale = 0.4 + random() * 1.4
        local uiScale = 0.4 + random() * 1.4
        local k = socialScale / uiScale
        local scaledLeft = random() * uiW
        local scaledRight = scaledLeft + 50 + random() * 400
        local socialLeft, socialRight = scaledLeft / k, scaledRight / k
        local socialTop = (-300 + random() * (uiH + 600)) / k

        local left, top, side = UI.ComputeAttachPosition(socialLeft, socialRight, socialTop,
            socialScale, uiScale, uiW, uiH, w, h, gap)
        local rightLeft = socialRight * k + gap
        local leftLeft = socialLeft * k - gap - w
        local ctx = string.format("side=%s ui=%sx%s w=%s h=%s", tostring(side), tostring(uiW), tostring(uiH),
            tostring(w), tostring(h))
        if side == "right" then
            checked = checked + 1
            assert(math.abs(left - rightLeft) <= TOL, "clamp changed right left: " .. ctx)
        elseif side == "left" then
            checked = checked + 1
            assert(math.abs(left - leftLeft) <= TOL, "clamp changed left left: " .. ctx)
        end
    end
    assert(checked > 0, "generator never produced a right or left result")

    -- Explicit examples.
    local l, t = UI.ClampToScreen(-10, 50, 100, 40, 800, 600)
    assert(l == 0 and t == 50, "left overflow example")
    l, t = UI.ClampToScreen(750, 700, 100, 40, 800, 600)
    assert(l == 700 and t == 600, "right and top overflow example")
    l, t = UI.ClampToScreen(5, 10, 900, 700, 800, 600)
    assert(l == 0 and t == 600, "oversized window example")
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 5: Unusable social geometry yields no attach position
-- Validates: Requirements 2.9
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 5: Unusable social geometry yields no attach position", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP

    local function genJunk(isScale)
        local r = random(isScale and 9 or 7)
        if r == 1 then return nil end
        if r == 2 then return genString() end
        if r == 3 then return {} end
        if r == 4 then return math.huge end
        if r == 5 then return -math.huge end
        if r == 6 then return 0 / 0 end
        if r == 7 then return random() < 0.5 end
        if r == 8 then return 0 end
        return -(random() * 5 + 0.01)
    end

    -- Argument positions of ComputeAttachPosition (gap is fixed inside ResolvePlacement).
    local SCALE = { [4] = true, [5] = true }

    for i = 1, ITERATIONS do
        local uiW, uiH = 800 + random() * 1800, 600 + random() * 1000
        local w, h = 100 + random() * 300, 100 + random() * 300
        local args = {
            random() * uiW, random() * uiW, random() * uiH, 0.5 + random() * 2, 0.5 + random() * 2,
            uiW, uiH, w, h, gap,
        }
        local sound = { UI.ComputeAttachPosition(args[1], args[2], args[3], args[4], args[5],
            args[6], args[7], args[8], args[9], args[10]) }
        assert(sound[1] ~= nil, "generator: valid inputs gave nil")

        -- Replace one to three arguments with junk (scales may also get 0 or negatives).
        local bad = {}
        for j = 1, 10 do bad[j] = args[j] end
        local badCount = random(1, 3)
        local first
        for _ = 1, badCount do
            local idx = random(10)
            first = first or idx
            bad[idx] = genJunk(SCALE[idx])
        end
        -- Rebuild with explicit nils preserved (select-based call, no table holes).
        local ctx = string.format("(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
            show(bad[1]), show(bad[2]), show(bad[3]), show(bad[4]), show(bad[5]),
            show(bad[6]), show(bad[7]), show(bad[8]), show(bad[9]), show(bad[10]))

        local ok, l, t, side = pcall(UI.ComputeAttachPosition,
            bad[1], bad[2], bad[3], bad[4], bad[5], bad[6], bad[7], bad[8], bad[9], bad[10])
        assert(ok, "ComputeAttachPosition raised " .. tostring(l) .. " " .. ctx)
        assert(l == nil and t == nil and side == nil, "expected nil, got " .. show(l) .. " " .. ctx)

        -- ResolvePlacement with a non-moved db falls back to default (gap is not a parameter).
        local db = pick({ {}, { window = { moved = false, left = 1, top = 2 } }, { window = "x" } })
        local social = { left = bad[1], right = bad[2], top = bad[3], scale = bad[4], uiScale = bad[5] }
        local ok2, kind, rl, rt, rside = pcall(UI.ResolvePlacement, db, social, bad[8], bad[9], bad[6], bad[7])
        if bad[10] == args[10] then
            assert(ok2, "ResolvePlacement raised " .. tostring(kind) .. " " .. ctx)
            assert(kind == "default" and rl == nil and rt == nil and rside == nil,
                "expected default, got " .. show(kind) .. " " .. ctx)
        end
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 6: Placement choice
-- Validates: Requirements 2.1, 3.3, 3.4, 5.3, 5.4
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 6: Placement choice", function()
    local UI = loadUI({})
    local gap = UI.ATTACH_GAP

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    local function genJunkNumber()
        return pick({ math.huge, -math.huge, 0 / 0, "x", {}, true })
    end

    for i = 1, ITERATIONS do
        local screenW, screenH = 800 + random() * 1800, 600 + random() * 1000
        local w, h = 100 + random() * 500, 100 + random() * 500

        -- Settings: moved (valid) or not moved (several shapes), plus an unrelated field.
        local moved = random() < 0.5
        local db = { debug = random() < 0.5, checkedGames = genStore() }
        local sl, st = (random() - 0.5) * 3000, (random() - 0.5) * 2000
        if moved then
            db.window = { moved = true, left = sl, top = st }
        else
            db.window = pick({
                false,
                { moved = false, left = sl, top = st },
                { moved = "yes", left = sl, top = st },
                { moved = true, left = genJunkNumber(), top = st },
                "x",
            })
            if db.window == false then db.window = nil end
        end

        -- Social geometry: nil, usable on the right, usable on the left, or junk.
        local kind = random(4)
        local social
        local scale, uiScale = 0.5 + random() * 2, 0.5 + random() * 2
        if kind == 2 then
            local sw = 200 + random() * 200
            local left = random() * 300
            social = { left = left, right = left + sw, top = 300 + random() * 500, scale = scale, uiScale = uiScale }
        elseif kind == 3 then
            local sw = 200 + random() * 200
            local right = (screenW - random() * 300) * uiScale / scale
            social = { left = right - sw, right = right, top = 300 + random() * 500, scale = scale, uiScale = uiScale }
        elseif kind == 4 then
            social = { left = genJunkNumber(), right = random() * 500, top = random() * 500, scale = scale, uiScale = uiScale }
            if random() < 0.5 then social = { left = 1, right = 2, top = 3 } end
            if random() < 0.2 then social = "junk" end
        end

        local before = deepCopy(db)
        local ok, rk, rl, rt, rside = pcall(UI.ResolvePlacement, db, social, w, h, screenW, screenH)
        assert(ok, "ResolvePlacement raised: " .. tostring(rk))
        assert(deepEqual(before, db), "db changed by ResolvePlacement")

        if moved then
            local el, et = UI.ClampToScreen(sl, st, w, h, screenW, screenH)
            assert(rk == "saved", "expected saved, got " .. show(rk))
            assert(rl == el and rt == et and rside == nil, string.format(
                "saved position (%s, %s, %s) ~= clamped (%s, %s)", show(rl), show(rt), show(rside), show(el), show(et)))
        else
            local usable = type(social) == "table"
            local al, at, aside
            if usable then
                al, at, aside = UI.ComputeAttachPosition(social.left, social.right, social.top,
                    social.scale, social.uiScale, screenW, screenH, w, h, gap)
            end
            if al ~= nil then
                assert(rk == "attached", "expected attached, got " .. show(rk))
                assert(rl == al and rt == at and rside == aside, string.format(
                    "attached (%s, %s, %s) ~= (%s, %s, %s)", show(rl), show(rt), show(rside), show(al), show(at), show(aside)))
            else
                assert(rk == "default" and rl == nil and rt == nil and rside == nil,
                    "expected default, got " .. show(rk))
            end
        end
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 7: Saved position round trip with field preservation
-- Validates: Requirements 3.2, 7.1, 7.4
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 7: Saved position round trip with field preservation", function()
    local UI = loadUI({})

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    for i = 1, ITERATIONS do
        -- Random extra fields (anything but "window"), optionally with a stale window entry.
        local db = {}
        for _ = 1, random(0, 6) do
            local k = pick({ "debug", "version", "x", "checkedGames", genString(), random(1, 5) })
            if k ~= "window" then
                db[k] = pick({ random(-5, 5), genString(), random() < 0.5, genStore(), { nested = { genString() } } })
            end
        end
        if random() < 0.5 then
            db.window = pick({ { moved = false, left = 1, top = 2 }, "x", { moved = true, left = 5, top = 6 } })
        end

        local others = deepCopy(db)
        others.window = nil

        local left, top = (random() - 0.5) * 6000, (random() - 0.5) * 4000
        if random() < 0.2 then left = random(-3000, 3000) end
        if random() < 0.2 then top = random(-3000, 3000) end

        local ok, err = pcall(UI.WriteWindowSettings, db, left, top)
        assert(ok, "WriteWindowSettings raised: " .. tostring(err))

        local moved, rl, rt = UI.ReadWindowSettings(db)
        assert(moved == true, "moved ~= true after write")
        assert(rl == left and rt == top, string.format("read (%s, %s) ~= written (%s, %s)",
            show(rl), show(rt), show(left), show(top)))

        local after = deepCopy(db)
        after.window = nil
        assert(deepEqual(others, after), "fields other than window changed by WriteWindowSettings")
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 8: Settings validation and read purity
-- Validates: Requirements 7.2, 7.3, 7.5
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 8: Settings validation and read purity", function()
    local UI = loadUI({})

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    local function isFiniteNumber(v)
        return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    end

    local function genCoord()
        local r = random(10)
        if r <= 4 then return (random() - 0.5) * 6000 end
        if r == 5 then return random(-3000, 3000) end
        if r == 6 then return 0 / 0 end
        if r == 7 then return math.huge end
        if r == 8 then return -math.huge end
        if r == 9 then return pick({ "10", "", "x", true, false }) end
        return pick({ {}, function() end, nil })
    end

    local function genMoved()
        return pick({ true, true, true, false, "true", 1, 0, "", {}, nil })
    end

    local function genWindow()
        local r = random(8)
        if r == 1 then return nil end
        if r == 2 then return pick({ "x", 5, true, false, function() end }) end
        local w = { moved = genMoved(), left = genCoord(), top = genCoord() }
        if random() < 0.3 then w.extra = genString() end
        return w
    end

    local function genDb()
        if random() < 0.1 then return pick({ "str", 7, true, false }) end
        local db = {}
        for _ = 1, random(0, 4) do
            local k = pick({ "debug", "version", "x", "checkedGames", genString() })
            if k ~= "window" then
                db[k] = pick({ random(-5, 5), genString(), random() < 0.5, genStore() })
            end
        end
        db.window = genWindow()
        return db
    end

    for i = 1, ITERATIONS do
        local db = genDb()
        local before = deepCopy(db)
        local dbGlobalBefore = ForeverFilterDB

        local ok, moved, left, top = pcall(UI.ReadWindowSettings, db)
        assert(ok, "ReadWindowSettings raised: " .. tostring(moved))

        local w = type(db) == "table" and db.window or nil
        local expectMoved = type(w) == "table" and w.moved == true
            and isFiniteNumber(w.left) and isFiniteNumber(w.top)

        assert(moved == expectMoved, string.format("moved %s, expected %s", tostring(moved), tostring(expectMoved)))
        if expectMoved then
            assert(left == w.left and top == w.top, string.format("read (%s, %s) ~= stored (%s, %s)",
                show(left), show(top), show(w.left), show(w.top)))
        else
            assert(moved == false, "moved must be boolean false when invalid")
        end

        assert(deepEqual(before, db), "db changed by ReadWindowSettings")
        assert(ForeverFilterDB == dbGlobalBefore, "ReadWindowSettings created or replaced ForeverFilterDB")
    end

    -- Explicit cases.
    assert(UI.ReadWindowSettings(nil) == false)
    assert(UI.ReadWindowSettings({}) == false)
    assert(UI.ReadWindowSettings({ window = "x" }) == false)
    assert(UI.ReadWindowSettings({ window = { moved = 1, left = 1, top = 1 } }) == false)
    assert(UI.ReadWindowSettings({ window = { moved = true, left = 0 / 0, top = 1 } }) == false)
    assert(UI.ReadWindowSettings({ window = { moved = true, left = 1, top = math.huge } }) == false)
    assert(UI.ReadWindowSettings({ window = { moved = true, left = 1, top = 2 } }) == true)
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 9: Reset clears only the window settings
-- Validates: Requirements 6.1
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 9: Reset clears only the window settings", function()
    local UI = loadUI({})

    local function genWindow()
        local r = random(4)
        if r == 1 then return nil end
        if r == 2 then return pick({ "x", 5, true, false }) end
        return {
            moved = pick({ true, true, false, "true", 1 }),
            left = pick({ random(-3000, 3000), (random() - 0.5) * 6000, 0 / 0, math.huge, "10" }),
            top = pick({ random(-3000, 3000), (random() - 0.5) * 6000, 0 / 0, -math.huge, "x" }),
        }
    end

    for i = 1, ITERATIONS do
        local db = {}
        for _ = 1, random(0, 6) do
            local k = pick({ "debug", "version", "x", "checkedGames", genString() })
            if k ~= "window" then
                db[k] = pick({ random(-5, 5), genString(), random() < 0.5, genStore() })
            end
        end
        db.window = genWindow()
        -- Force a valid saved position on some iterations.
        if random() < 0.4 then
            db.window = { moved = true, left = random(-500, 500), top = random(-500, 500) }
        end

        local before = {}
        for k, v in pairs(db) do
            if k ~= "window" then before[k] = v end
        end

        local ok, err = pcall(UI.ResetWindowSettings, db)
        assert(ok, "ResetWindowSettings raised: " .. tostring(err))

        assert(UI.ReadWindowSettings(db) == false, "moved is not false after reset")
        assert(db.window == nil, "window settings not cleared")
        for k, v in pairs(before) do
            assert(rawequal(db[k], v), "non-window field changed: " .. show(k))
        end
        for k in pairs(db) do
            assert(before[k] ~= nil, "unexpected field after reset: " .. show(k))
        end
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 10: Social menu transition decisions
-- Validates: Requirements 1.1, 1.2, 4.1, 4.2, 4.6, 5.1
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 10: Social menu transition decisions", function()
    local UI = loadUI({})
    local events = { "social_shown", "social_hidden", "manual_show" }

    for i = 1, ITERATIONS do
        local state = { autoOpened = random() < 0.5, dismissed = random() < 0.5 }
        local ctx = { windowShown = random() < 0.5, anySocialOpen = random() < 0.5 }
        local event = pick(events)

        local stateBefore = { autoOpened = state.autoOpened, dismissed = state.dismissed }
        local ctxBefore = { windowShown = ctx.windowShown, anySocialOpen = ctx.anySocialOpen }

        local newState, action = UI.NextSocialState(state, event, ctx)

        local where = string.format("event=%s autoOpened=%s dismissed=%s windowShown=%s anySocialOpen=%s",
            event, tostring(state.autoOpened), tostring(state.dismissed),
            tostring(ctx.windowShown), tostring(ctx.anySocialOpen))

        local expectShow = event == "social_shown" and not ctx.windowShown and not state.dismissed
        local expectHide = event == "social_hidden" and not ctx.anySocialOpen
            and state.autoOpened and ctx.windowShown

        assert((action == "show") == expectShow, "show decision wrong: " .. where)
        assert((action == "hide") == expectHide, "hide decision wrong: " .. where)
        assert(action == nil or action == "show" or action == "hide", "unexpected action: " .. where)
        if action == nil then
            assert(not expectShow and not expectHide, "missing action: " .. where)
        end

        if action == "show" then
            assert(newState.autoOpened == true, "autoOpened not set on show: " .. where)
        end
        if event == "manual_show" then
            assert(action == nil, "manual_show returned an action: " .. where)
            assert(newState.autoOpened == false and newState.dismissed == false,
                "manual_show did not clear flags: " .. where)
        end

        -- Inputs are not mutated, and the result is a distinct table.
        assert(state.autoOpened == stateBefore.autoOpened and state.dismissed == stateBefore.dismissed,
            "input state mutated: " .. where)
        assert(ctx.windowShown == ctxBefore.windowShown and ctx.anySocialOpen == ctxBefore.anySocialOpen,
            "ctx mutated: " .. where)
        assert(newState ~= state, "returned the input state table: " .. where)
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Property 11: Session state invariants over event sequences
-- Validates: Requirements 4.3, 4.4, 4.5
----------------------------------------------------------------------
property("Feature: social-menu-attach, Property 11: Session state invariants over event sequences", function()
    local UI = loadUI({})
    local steps = { "social_open", "social_close", "user_close", "ff_show", "ff_hide" }

    for i = 1, ITERATIONS do
        local state = { autoOpened = false, dismissed = false }
        local windowShown = false
        local social = { false, false } -- FriendsFrame, SocialUIFrame
        local log = {}

        local function anySocialOpen() return social[1] or social[2] end

        local function apply(event, ctx)
            local newState, action = UI.NextSocialState(state, event, ctx)
            state = newState
            return action
        end

        -- Hiding the window fires its OnHide, which applies window_hidden.
        local function hideWindow()
            if not windowShown then return end
            windowShown = false
            apply("window_hidden", { anySocialOpen = anySocialOpen() })
        end

        for step = 1, random(1, 40) do
            local s = pick(steps)
            local idx = random(2)
            log[#log + 1] = s .. (s:find("^social") and idx or "")
            local userClosedWithSocial = false

            if s == "social_open" then
                if not social[idx] then
                    social[idx] = true
                    local action = apply("social_shown", { windowShown = windowShown })
                    if action == "show" then windowShown = true end
                end
            elseif s == "social_close" then
                if social[idx] then
                    social[idx] = false
                    local action = apply("social_hidden",
                        { anySocialOpen = anySocialOpen(), windowShown = windowShown })
                    if action == "hide" then hideWindow() end
                end
            elseif s == "user_close" then
                if windowShown then
                    userClosedWithSocial = anySocialOpen()
                    hideWindow()
                end
            elseif s == "ff_show" then
                apply("manual_show", {})
                windowShown = true
            else -- ff_hide
                hideWindow()
            end

            local where = string.format("after [%s]: autoOpened=%s dismissed=%s windowShown=%s social=%s/%s",
                table.concat(log, ","), tostring(state.autoOpened), tostring(state.dismissed),
                tostring(windowShown), tostring(social[1]), tostring(social[2]))

            if not anySocialOpen() then
                assert(state.dismissed == false, "dismissed set with no social frame open " .. where)
            end
            if not windowShown then
                assert(state.autoOpened == false, "autoOpened set with window hidden " .. where)
            end
            if userClosedWithSocial then
                assert(not windowShown and state.dismissed == true,
                    "user close with social open did not dismiss " .. where)
            end
        end
    end
end)

----------------------------------------------------------------------
-- Feature: social-menu-attach, Example tests for the frame wiring
-- Validates: Requirements 1.3, 1.4, 1.5, 1.6, 2.4, 2.5, 2.6, 2.9, 2.10, 2.11, 3.5, 5.6, 6.2, 6.3,
--            8.1, 8.3, 8.6, 9.1, 9.3, 10.5
----------------------------------------------------------------------
local function wiringEnv(winW, winH)
    local saved = {
        CreateFrame = CreateFrame, UIParent = UIParent, C_Timer = C_Timer,
        UISpecialFrames = UISpecialFrames, print = print,
    }
    local env = { log = {}, timers = {}, printed = {}, violations = {}, stubs = {}, fontStrings = {} }

    -- Text/text: so checkbox label code falls back to CreateFontString; CloseButton is set per test.
    local absent = { TitleText = true, TitleContainer = true, InsetBg = true,
                     Text = true, text = true, Low = true, High = true, CloseButton = true }
    local newFrame
    local function runHooks(self, name)
        local hs = rawget(self, "hooks")
        local list = hs and hs[name]
        if list then for _, fn in ipairs(list) do fn(self) end end
    end
    local impl = {
        Show = function(self)
            self.shown = true
            local s = self.scripts.OnShow
            if s then s(self) end
            runHooks(self, "OnShow")
        end,
        Hide = function(self)
            local was = self.shown
            self.shown = false
            local s = self.scripts.OnHide
            if was and s then s(self) end
            if was then runHooks(self, "OnHide") end
        end,
        HookScript = function(self, name, fn)
            local hs = rawget(self, "hooks")
            if not hs then hs = {}; rawset(self, "hooks", hs) end
            hs[name] = hs[name] or {}
            table.insert(hs[name], fn)
        end,
        SetValue = function(self, v)
            rawset(self, "value", v)
            local s = self.scripts.OnValueChanged
            if s then s(self, v) end
        end,
        GetValue = function(self) return rawget(self, "value") end,
        SetChecked = function(self, v) rawset(self, "checked", v and true or false) end,
        GetChecked = function(self) return rawget(self, "checked") or false end,
        SetText = function(self, v) rawset(self, "text", v) end,
        GetText = function(self) return rawget(self, "text") end,
        IsShown = function(self) return self.shown end,
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        SetPoint = function(self, ...)
            if rawget(self, "isWindow") then env.log[#env.log + 1] = { "SetPoint", ... } end
        end,
        ClearAllPoints = function(self)
            if rawget(self, "isWindow") then env.log[#env.log + 1] = { "ClearAllPoints" } end
        end,
        SetWidth = function(self, v) self.w = v end,
        SetHeight = function(self, v) self.h = v end,
        SetSize = function(self, a, b) self.w, self.h = a, b end,
        GetWidth = function(self) return self.w end,
        GetHeight = function(self) return self.h end,
        GetLeft = function(self) return rawget(self, "left") end,
        GetTop = function(self) return rawget(self, "top") end,
        GetEffectiveScale = function() return 1 end,
        SetScale = function(self, v) rawset(self, "scale", v) end,
        GetScale = function(self) return rawget(self, "scale") or 1 end,
        CreateFontString = function(self)
            local fs = newFrame()
            rawset(fs, "owner", self)
            env.fontStrings[#env.fontStrings + 1] = fs
            return fs
        end,
        CreateTexture = function() return newFrame() end,
    }
    newFrame = function(name)
        local f = { name = name, calls = {}, shown = false, scripts = {}, w = 0, h = 0 }
        return setmetatable(f, { __index = function(t, k)
            if absent[k] then return nil end
            return function(self, ...)
                t.calls[#t.calls + 1] = { k, ... }
                local fn = impl[k]
                if fn then return fn(self, ...) end
            end
        end })
    end

    UIParent = newFrame("UIParent")
    UIParent.w, UIParent.h = 1920, 1080
    CreateFrame = function(_, name)
        local f = newFrame(name)
        if name == "ForeverFilterFrame" then
            env.win = f
            f.isWindow = true
        end
        return f
    end
    C_Timer = { After = function(delay, cb) env.timers[#env.timers + 1] = { delay = delay, cb = cb } end }
    UISpecialFrames = {}
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        env.printed[#env.printed + 1] = table.concat(parts, " ")
    end

    -- These wiring tests assert scale-1 geometry, so pin the saved scale to 1.
    local UI, ns = loadUI({ windowScale = 1 })
    env.UI, env.ns = UI, ns
    local origRefresh = UI.Refresh
    UI.Refresh = function()
        env.log[#env.log + 1] = { "Refresh" }
        origRefresh()
        env.win.w, env.win.h = winW, winH
    end
    UI.LookupFrame = function(name) return env.stubs[name] end

    -- Social frame stub: only these members exist; any other access raises and is recorded.
    function env.social(left, right, top)
        local s = { left = left, right = right, top = top, scale = 1, shown = true, hooks = {}, hookCount = {} }
        rawset(s, "GetLeft", function(self) return self.left end)
        rawset(s, "GetRight", function(self) return self.right end)
        rawset(s, "GetTop", function(self) return self.top end)
        rawset(s, "GetEffectiveScale", function(self) return self.scale end)
        rawset(s, "IsShown", function(self) return self.shown end)
        rawset(s, "HookScript", function(self, ev, fn)
            self.hooks[ev] = fn
            self.hookCount[ev] = (self.hookCount[ev] or 0) + 1
        end)
        return setmetatable(s, { __index = function(_, k)
            env.violations[#env.violations + 1] = tostring(k)
            error("unexpected access to social frame member " .. tostring(k), 2)
        end })
    end

    function env.points()
        local out = {}
        for _, e in ipairs(env.log) do
            if e[1] == "SetPoint" then out[#out + 1] = e end
        end
        return out
    end

    function env.restore()
        CreateFrame, UIParent, C_Timer = saved.CreateFrame, saved.UIParent, saved.C_Timer
        UISpecialFrames, print = saved.UISpecialFrames, saved.print
    end
    return env
end

local function withWiring(winW, winH, fn)
    local env = wiringEnv(winW, winH)
    local ok, err = pcall(fn, env)
    env.restore()
    assert(ok, err)
end

property("Feature: social-menu-attach, Example tests: hooks installed once, missing frames tolerated", function()
    withWiring(300, 400, function(env)
        local UI = env.UI
        -- Frames missing: no error, nothing hooked.
        UI.TryHookSocialFrames()
        UI.TryHookSocialFrames()

        env.stubs.FriendsFrame = env.social(100, 485, 900)
        env.stubs.SocialUIFrame = env.social(100, 560, 900)
        UI.TryHookSocialFrames()
        UI.TryHookSocialFrames()
        for name, s in pairs(env.stubs) do
            assert(s.hookCount.OnShow == 1, name .. " OnShow hooked " .. tostring(s.hookCount.OnShow) .. " times")
            assert(s.hookCount.OnHide == 1, name .. " OnHide hooked " .. tostring(s.hookCount.OnHide) .. " times")
            assert(type(s.hooks.OnShow) == "function" and type(s.hooks.OnHide) == "function")
        end
        assert(#env.violations == 0, "unexpected social frame access: " .. table.concat(env.violations, ","))
    end)
end)

property("Feature: social-menu-attach, Example tests: auto-open refreshes then places once beside the social frame", function()
    withWiring(300, 400, function(env)
        local UI = env.UI
        local social = env.social(100, 485, 900)
        env.stubs.FriendsFrame = social
        UI.TryHookSocialFrames()

        social.hooks.OnShow()
        local win = env.win
        assert(win and win.shown, "window was not opened by the social OnShow hook")

        local refreshAt
        for i, e in ipairs(env.log) do
            if e[1] == "Refresh" then refreshAt = i end
        end
        assert(refreshAt, "Refresh was not called")
        local after = {}
        for i = refreshAt + 1, #env.log do
            if env.log[i][1] == "SetPoint" then after[#after + 1] = env.log[i] end
        end
        assert(#after == 1, "expected one anchor after Refresh, got " .. #after)
        local p = after[1]
        assert(p[2] == "TOPLEFT" and p[3] == UIParent and p[4] == "BOTTOMLEFT", "wrong anchor")
        -- Stub near the left edge: window to the right of the stub (right edge 485 + gap 4).
        assert(p[5] == 489 and p[6] == 900, "placed at " .. tostring(p[5]) .. "," .. tostring(p[6]))
        assert(#env.timers == 1 and env.timers[1].delay == 0, "deferred placement not scheduled")
        assert(env.ns.db.window == nil, "placement wrote window settings")

        -- Requirement 5.6.
        local found = false
        for _, n in ipairs(UISpecialFrames) do if n == "ForeverFilterFrame" then found = true end end
        assert(found, "UISpecialFrames lacks ForeverFilterFrame")
        assert(#env.violations == 0, "unexpected social frame access: " .. table.concat(env.violations, ","))
    end)
end)

property("Feature: social-menu-attach, Example tests: side choice and clamping", function()
    local function placeFor(winW, left, right)
        local result
        withWiring(winW, 400, function(env)
            local social = env.social(left, right, 900)
            env.stubs.FriendsFrame = social
            env.UI.TryHookSocialFrames()
            social.hooks.OnShow()
            local pts = env.points()
            local p = pts[#pts]
            assert(p and p[2] == "TOPLEFT", "no TOPLEFT anchor")
            result = { left = p[5], top = p[6] }
        end)
        return result
    end

    -- Near the right edge: no room on the right, so the window goes left of the stub.
    local r = placeFor(300, 1500, 1885)
    assert(r.left == 1196, "left-side placement at " .. tostring(r.left))
    assert(r.left + 300 <= 1500, "window overlaps the stub")

    -- Wider than both gaps: ends inside the screen.
    local c = placeFor(1000, 600, 985)
    assert(c.left >= 0 and c.left + 1000 <= 1920, "clamped placement outside screen: " .. tostring(c.left))
    assert(c.top <= 1080 and c.top - 400 >= 0, "clamped top outside screen: " .. tostring(c.top))
end)

property("Feature: social-menu-attach, Example tests: deferred placement and error containment", function()
    -- Deferred placement runs while the social frame is shown, and is skipped once it is hidden.
    withWiring(300, 400, function(env)
        local social = env.social(100, 485, 900)
        env.stubs.FriendsFrame = social
        env.UI.TryHookSocialFrames()
        social.hooks.OnShow()
        local n = #env.points()
        env.timers[1].cb()
        assert(#env.points() == n + 1, "deferred placement did not re-place while social shown")
        social.shown = false
        env.timers[1].cb()
        assert(#env.points() == n + 1, "deferred placement ran with the social frame hidden")
        assert(#env.violations == 0, "unexpected social frame access: " .. table.concat(env.violations, ","))
    end)

    -- A throwing GetRight: callback stays silent, window shown at the default position.
    withWiring(300, 400, function(env)
        local social = env.social(100, 485, 900)
        rawset(social, "GetRight", function() error("boom") end)
        env.stubs.FriendsFrame = social
        env.UI.TryHookSocialFrames()
        local ok, err = pcall(social.hooks.OnShow)
        assert(ok, "hook callback raised: " .. tostring(err))
        assert(env.win and env.win.shown, "window not shown")
        for _, p in ipairs(env.points()) do
            assert(p[2] ~= "TOPLEFT", "window was placed despite unusable geometry ")
        end
        assert(#env.printed == 0, "callback printed: " .. tostring(env.printed[1]))
        env.timers[1].cb()
        for _, p in ipairs(env.points()) do
            assert(p[2] ~= "TOPLEFT", "deferred placement moved the window despite unusable geometry")
        end
    end)
end)

property("Feature: social-menu-attach, Example tests: drag handler and UI.ResetPosition", function()
    -- Drag: unregisters client persistence and writes the position.
    withWiring(300, 400, function(env)
        local social = env.social(100, 485, 900)
        env.stubs.FriendsFrame = social
        env.UI.TryHookSocialFrames()
        social.hooks.OnShow()
        local win = env.win
        assert(env.ns.db.window == nil, "window settings written before any drag")

        win.left, win.top = 321, 654
        win.calls = {}
        win.scripts.OnDragStop(win)
        local sawUserPlaced, sawStop = false, false
        for _, c in ipairs(win.calls) do
            if c[1] == "SetUserPlaced" and c[2] == false then sawUserPlaced = true end
            if c[1] == "StopMovingOrSizing" then sawStop = true end
        end
        assert(sawStop, "StopMovingOrSizing not called")
        assert(sawUserPlaced, "SetUserPlaced(false) not called")
        local w = env.ns.db.window
        assert(w and w.moved == true and w.left == 321 and w.top == 654, "position not saved")

        -- A saved position wins over attaching on the next placement.
        env.UI.PlaceWindow()
        local pts = env.points()
        assert(pts[#pts][5] == 321 and pts[#pts][6] == 654, "saved position not used")

        -- ResetPosition while shown: clears settings, re-places beside the social frame, confirms.
        local before = #env.points()
        env.UI.ResetPosition()
        assert(env.ns.db.window == nil, "reset left window settings")
        local after = env.points()
        assert(#after == before + 1 and after[#after][5] == 489, "reset did not re-place the shown window")
        assert(#env.printed == 1, "reset printed " .. #env.printed .. " lines")

        -- ResetPosition while hidden: clears settings, no placement.
        env.UI.WriteWindowSettings(env.ns.db, 5, 6)
        win:Hide()
        local hiddenBefore = #env.points()
        env.UI.ResetPosition()
        assert(env.ns.db.window == nil, "hidden reset left window settings")
        assert(#env.points() == hiddenBefore, "hidden reset placed the window")
        assert(#env.printed == 2, "hidden reset printed " .. #env.printed .. " lines total")
    end)

    -- ResetPosition before the window was ever created.
    withWiring(300, 400, function(env)
        env.UI.WriteWindowSettings(env.ns.db, 5, 6)
        env.UI.ResetPosition()
        assert(env.ns.db.window == nil and env.win == nil, "reset before creation misbehaved")
    end)
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 1: Snap always produces a valid, stable scale
-- Validates: Requirements 3.4, 3.5, 3.7, 3.8
----------------------------------------------------------------------
property("Feature: options-panel, Property 1: Snap always produces a valid, stable scale", function()
    local UI = loadUI({})
    local nan = 0 / 0
    local function genSnapInput()
        local r = random(12)
        if r == 1 then return -1 + random() * 4 end
        if r == 2 then return 0.5 + random(0, 20) * 0.05 end
        if r == 3 then return 0.5 + random(0, 20) * 0.05 + (random() - 0.5) * 0.001 end
        if r == 4 then return pick({ 0.5, 1.5, 0.85, 0, -0, 0.4999999, 1.5000001, 0.525, 0.575 }) end
        if r == 5 then return (random() < 0.5 and -1 or 1) * 10 ^ random(6, 300) end
        if r == 6 then return nan end
        if r == 7 then return pick({ math.huge, -math.huge }) end
        if r == 8 then return pick({ "0.85", "1", "", "abc" }) end
        if r == 9 then return random() < 0.5 end
        if r == 10 then return {} end
        if r == 11 then return nil end
        return random(-5, 5)
    end

    for i = 1, ITERATIONS do
        local v = genSnapInput()
        local ctx = "(v=" .. show(v) .. ")"
        local s = UI.SnapScale(v)
        assert(UI.IsValidScale(s), "snap result invalid " .. show(s) .. " " .. ctx)
        local again = UI.SnapScale(s)
        assert(again == s, "snap not idempotent " .. show(s) .. " -> " .. show(again) .. " " .. ctx)
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
            assert(s == UI.DEFAULT_SCALE, "non-finite input gave " .. show(s) .. " " .. ctx)
        end
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 2: Snap picks the nearest step inside the range
-- Validates: Requirements 3.3, 3.6
----------------------------------------------------------------------
property("Feature: options-panel, Property 2: Snap picks the nearest step inside the range", function()
    local UI = loadUI({})
    local function genFinite()
        local r = random(7)
        if r == 1 then return -1 + random() * 4 end
        if r == 2 then return 0.5 + random(0, 20) * 0.05 end
        if r == 3 then return 0.5 + random(0, 20) * 0.05 + (random() - 0.5) * 0.001 end
        if r == 4 then return 0.5 + (random(0, 19) + 0.5) * 0.05 end -- halfway between steps
        if r == 5 then return pick({ 0.5, 1.5, 0.4999999, 1.5000001, 0.525, 0.575 }) end
        if r == 6 then return (random() < 0.5 and -1 or 1) * 10 ^ random(2, 300) end
        return random(-5, 5)
    end

    for i = 1, ITERATIONS do
        local v = genFinite()
        local ctx = "(v=" .. show(v) .. ")"
        local s = UI.SnapScale(v)
        local clamped = math.min(math.max(v, 0.5), 1.5)
        assert(math.abs(s - clamped) <= UI.SCALE_STEP / 2 + 1e-9,
            "result " .. show(s) .. " too far from clamped input " .. show(clamped) .. " " .. ctx)
        local n = (s - 0.5) / 0.05
        assert(math.abs(n - math.floor(n + 0.5)) <= 1e-9, "result off the grid " .. show(s) .. " " .. ctx)
        if v < 0.5 then assert(s == 0.5, "below range gave " .. show(s) .. " " .. ctx) end
        if v > 1.5 then assert(s == 1.5, "above range gave " .. show(s) .. " " .. ctx) end
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 3: Slider offset mapping round trip
-- Validates: Requirements 3.1, 3.12
----------------------------------------------------------------------
property("Feature: options-panel, Property 3: Slider offset mapping round trip", function()
    local UI = loadUI({})
    local nan = 0 / 0

    for i = 1, ITERATIONS do
        -- Good width: result equals the snapped linear mapping.
        local width = random(1, 1000)
        local offset = -width + random() * 3 * width
        if random() < 0.1 then offset = 0 end
        local ctx = "(offset=" .. show(offset) .. ", width=" .. show(width) .. ")"
        local got = UI.SliderValueFromOffset(offset, width)
        local want = UI.SnapScale(0.5 + offset / width)
        assert(got == want, "mapping " .. show(got) .. " ~= " .. show(want) .. " " .. ctx)
        assert(UI.IsValidScale(got), "mapping result invalid " .. show(got) .. " " .. ctx)

        -- Each grid value maps back to itself through its own offset.
        local g = UI.SnapScale(0.5 + random(0, 20) * 0.05)
        local gOffset = (g - 0.5) * width
        local back = UI.SliderValueFromOffset(gOffset, width)
        assert(back == g, "grid " .. show(g) .. " round-tripped to " .. show(back) .. " (width=" .. show(width) .. ")")

        -- Bad width gives the default scale.
        local bad = pick({ 0, -random(1, 1000), nan, math.huge, -math.huge })
        local badGot = UI.SliderValueFromOffset(offset, bad)
        assert(badGot == UI.DEFAULT_SCALE,
            "bad width " .. show(bad) .. " gave " .. show(badGot) .. " " .. ctx)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 4: Slider write and read round trip
-- Validates: Requirements 4.1, 4.3, 4.7, 4.8, 4.9
----------------------------------------------------------------------
property("Feature: options-panel, Property 4: Slider write and read round trip", function()
    local UI = loadUI({})
    local nan = 0 / 0

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    local function genRaw()
        local r = random(10)
        if r == 1 then return -1 + random() * 4 end
        if r == 2 then return 0.5 + random(0, 20) * 0.05 end
        if r == 3 then return 0.5 + random(0, 20) * 0.05 + (random() - 0.5) * 0.001 end
        if r == 4 then return pick({ 0.5, 1.5, 0.85, 0.4999999, 1.5000001 }) end
        if r == 5 then return (random() < 0.5 and -1 or 1) * 10 ^ random(6, 300) end
        if r == 6 then return nan end
        if r == 7 then return pick({ math.huge, -math.huge }) end
        if r == 8 then return pick({ "0.85", "", "abc" }) end
        if r == 9 then return pick({ true, false, {} }) end
        return random(-5, 5)
    end

    local function genDb()
        local db = {}
        if random() < 0.7 then db.window = { point = "TOPLEFT", left = random(0, 2000), top = random(0, 2000) } end
        if random() < 0.7 then db.checkedGames = { [random(1, 50)] = true, ["g" .. random(1, 9)] = false } end
        if random() < 0.5 then db.showPlayerCounts = random() < 0.5 end
        if random() < 0.3 then db.debug = random() < 0.5 end
        for _ = 1, random(0, 4) do db["extra" .. random(1, 20)] = pick({ 1, "x", true, {} }) end
        if random() < 0.4 then db.windowScale = pick({ 0.5, 1.2, 99, -1, "bad", true }) end
        return db
    end

    for i = 1, ITERATIONS do
        local db = genDb()
        local raw = genRaw()
        local hadScale = db.windowScale ~= nil
        local before = deepCopy(db)
        before.windowScale = nil
        local ctx = "(raw=" .. show(raw) .. ")"

        local snapped = UI.SnapScale(raw)
        assert(UI.WriteScale(db, snapped) == true, "WriteScale refused snapped value " .. show(snapped) .. " " .. ctx)
        assert(UI.ReadScale(db) == snapped, "ReadScale " .. show(UI.ReadScale(db)) .. " ~= " .. show(snapped) .. " " .. ctx)

        local after = deepCopy(db)
        after.windowScale = nil
        assert(deepEqual(before, after), "fields other than windowScale changed " .. ctx)

        -- A db without windowScale has none before the write (reads give the default).
        if not hadScale then
            local fresh = deepCopy(before)
            assert(fresh.windowScale == nil, "fresh db has windowScale")
            assert(UI.ReadScale(fresh) == UI.DEFAULT_SCALE, "fresh db did not read default")
            assert(fresh.windowScale == nil, "ReadScale wrote to db")
        end
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 5: Count setting round trip, default, and isolation
-- Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 5.9
----------------------------------------------------------------------
property("Feature: options-panel, Property 5: Count setting round trip, default, and isolation", function()
    local UI = loadUI({})
    local nan = 0 / 0

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    local function genNonBoolean()
        local r = random(8)
        if r == 1 then return random(-5, 5) end
        if r == 2 then return random() * 100 end
        if r == 3 then return pick({ "true", "false", "", "abc" }) end
        if r == 4 then return {} end
        if r == 5 then return nan end
        if r == 6 then return pick({ math.huge, -math.huge }) end
        if r == 7 then return function() end end
        return nil
    end

    local function genDb()
        local db = {}
        if random() < 0.7 then db.window = { point = "TOPLEFT", left = random(0, 2000), top = random(0, 2000) } end
        if random() < 0.7 then db.checkedGames = { [random(1, 50)] = true, ["g" .. random(1, 9)] = false } end
        if random() < 0.5 then db.windowScale = pick({ 0.5, 0.85, 1.2, 99, "bad" }) end
        if random() < 0.3 then db.debug = random() < 0.5 end
        for _ = 1, random(0, 4) do db["extra" .. random(1, 20)] = pick({ 1, "x", true, {} }) end
        local r = random(3)
        if r == 1 then db.showPlayerCounts = random() < 0.5
        elseif r == 2 then db.showPlayerCounts = genNonBoolean() end
        return db
    end

    for i = 1, ITERATIONS do
        local db = genDb()
        local b = random() < 0.5
        local ctx = "(b=" .. show(b) .. ", stored=" .. show(db.showPlayerCounts) .. ")"

        -- Boolean round trip; every other field is unchanged.
        local before = deepCopy(db)
        before.showPlayerCounts = nil
        assert(UI.WriteShowCounts(db, b) == true, "WriteShowCounts refused boolean " .. ctx)
        assert(UI.ReadShowCounts(db) == b, "ReadShowCounts did not return " .. show(b) .. " " .. ctx)
        local after = deepCopy(db)
        after.showPlayerCounts = nil
        assert(deepEqual(before, after), "fields other than showPlayerCounts changed " .. ctx)

        -- A nil or non-boolean stored value reads as true and the read does not write.
        local bad = genDb()
        local stored = genNonBoolean()
        bad.showPlayerCounts = stored
        local badBefore = deepCopy(bad)
        local sctx = "(stored=" .. show(stored) .. ")"
        assert(UI.ReadShowCounts(bad) == true, "non-boolean stored value did not read true " .. sctx)
        assert(deepEqual(badBefore, bad), "ReadShowCounts changed the db " .. sctx)

        -- A non-boolean write returns false and changes nothing.
        local value = genNonBoolean()
        local wctx = "(value=" .. show(value) .. ")"
        local target = genDb()
        local targetBefore = deepCopy(target)
        assert(UI.WriteShowCounts(target, value) == false, "WriteShowCounts accepted non-boolean " .. wctx)
        assert(deepEqual(targetBefore, target), "failed WriteShowCounts changed the db " .. wctx)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 6: Header text with and without the count
-- Validates: Requirements 6.1, 6.2, 6.7, 6.9
----------------------------------------------------------------------
property("Feature: options-panel, Property 6: Header text with and without the count", function()
    local UI = loadUI({})

    local function genText()
        local r = random(4)
        if r == 1 then
            return pick({ "", " ", "(", ")", "(3)", "World of Warcraft", "Diablo 3", "Caf\195\169",
                "\227\131\135\227\130\163\227\130\162\227\131\150\227\131\173", "|cff00ff00x|r", "Game 2", "x (12)", "[id: 7]" })
        end
        local parts = {}
        for _ = 1, random(0, 8) do
            parts[#parts + 1] = pick({ "a", "Z", " ", "(", ")", "0", "9", "\195\169", "\226\130\172", "|", "[", "]", ":" })
        end
        if r == 3 then parts[#parts + 1] = tostring(random(0, 999)) end
        if r == 4 then parts[#parts + 1] = " (" .. random(0, 99) end
        return table.concat(parts)
    end

    for i = 1, ITERATIONS do
        local label, debugId = genText(), genText()
        local count = pick({ 0, 1, 1000000, random(0, 1000000) })
        local ctx = "(label=" .. show(label) .. ", debugId=" .. show(debugId) .. ", count=" .. count .. ")"

        local withCount = UI.FormatHeader(label, debugId, count, true)
        local without = UI.FormatHeader(label, debugId, count, false)

        assert(withCount == label .. debugId .. " (" .. count .. ")", "true result wrong " .. ctx .. " got " .. show(withCount))
        assert(without == label .. debugId, "false result wrong " .. ctx .. " got " .. show(without))
        assert(withCount:sub(1, #without) == without, "false result is not a prefix of true result " .. ctx)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 7: Layout without the strip is unchanged
-- Validates: Requirements 2.6, 2.9, 8.2, 8.4
----------------------------------------------------------------------
property("Feature: options-panel, Property 7: Layout without the strip is unchanged", function()
    local UI = loadUI({})

    for i = 1, ITERATIONS do
        local rowArea = pick({ 0, 5000, random(0, 5000), random() * 5000 })
        local screenH = pick({ 480, 4320, random(480, 4320), 480 + random() * 3840 })
        local screenW = pick({ 480, 4320, random(480, 4320), 480 + random() * 3840 })
        local widths = {}
        for j = 1, random(0, 20) do widths[j] = random() * 1500 end
        local isEmpty = random() < 0.5
        local ctx = string.format("(rowArea=%s, screenH=%s, screenW=%s, #widths=%d, isEmpty=%s)",
            show(rowArea), show(screenH), show(screenW), #widths, tostring(isEmpty))

        local oldH = UI.ComputeWindowHeight(rowArea, screenH, isEmpty)
        local oldW = UI.ComputeWindowWidth(widths, screenW, isEmpty)

        for _, zero in ipairs({ 0, false }) do
            local v = zero or nil
            local h = UI.ComputeWindowHeightWithStrip(rowArea, screenH, isEmpty, v)
            local w = UI.ComputeWindowWidthWithStrip(widths, screenW, isEmpty, v)
            assert(h == oldH, "height with stripHeight " .. show(v) .. " differs: " .. show(h) .. " ~= " .. show(oldH) .. " " .. ctx)
            assert(w == oldW, "width with stripMinWidth " .. show(v) .. " differs: " .. show(w) .. " ~= " .. show(oldW) .. " " .. ctx)
        end
        assert(UI.ComputeWindowHeightWithStrip(rowArea, screenH, isEmpty) == oldH, "missing stripHeight differs " .. ctx)
        assert(UI.ComputeWindowWidthWithStrip(widths, screenW, isEmpty) == oldW, "missing stripMinWidth differs " .. ctx)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 8: Layout with the strip
-- Validates: Requirements 2.3, 2.6, 2.7
----------------------------------------------------------------------
property("Feature: options-panel, Property 8: Layout with the strip", function()
    local UI = loadUI({})

    for i = 1, ITERATIONS do
        local rowArea = pick({ 0, 5000, random(0, 5000), random() * 5000 })
        local screenH = pick({ 480, 4320, random(480, 4320), 480 + random() * 3840 })
        local screenW = pick({ 480, 4320, random(480, 4320), 480 + random() * 3840 })
        local widths = {}
        for j = 1, random(0, 20) do widths[j] = random() * 1500 end
        local isEmpty = random() < 0.5
        -- Scales on the grid (0.50 to 1.50) and off it.
        local scale = pick({ 0.5, 1.5, 0.5 + random(0, 20) * 0.05, 0.5 + random() })
        local h = UI.StripHeight(scale)
        local minW = UI.StripMinWidth(scale)
        local ctx = string.format("(rowArea=%s, screenH=%s, screenW=%s, #widths=%d, isEmpty=%s, scale=%s)",
            show(rowArea), show(screenH), show(screenW), #widths, tostring(isEmpty), show(scale))

        local oldH = UI.ComputeWindowHeight(rowArea, screenH, isEmpty)
        local oldW = UI.ComputeWindowWidth(widths, screenW, isEmpty)
        local newH = UI.ComputeWindowHeightWithStrip(rowArea, screenH, isEmpty, h)
        local newW = UI.ComputeWindowWidthWithStrip(widths, screenW, isEmpty, minW)
        local maxH = math.max(120, math.floor(0.8 * screenH))

        assert(newH >= oldH, "height below old height: " .. show(newH) .. " < " .. show(oldH) .. " " .. ctx)
        assert(newH <= maxH, "height above cap: " .. show(newH) .. " > " .. show(maxH) .. " " .. ctx)
        if not isEmpty then
            local want = 66 + rowArea + h
            if want <= maxH then
                local expected = math.max(120, want)
                assert(math.abs(newH - expected) < 1e-9,
                    "height not 66 + rowArea + h: " .. show(newH) .. " ~= " .. show(expected) .. " " .. ctx)
            end
        end
        assert(newW >= oldW, "width below old width: " .. show(newW) .. " < " .. show(oldW) .. " " .. ctx)
        assert(newW >= minW, "width below StripMinWidth: " .. show(newW) .. " < " .. show(minW) .. " " .. ctx)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 9: Strip dimensions keep the slider on screen
-- Validates: Requirements 2.8, 2.9, 3.11
----------------------------------------------------------------------
property("Feature: options-panel, Property 9: Strip dimensions keep the slider on screen", function()
    local UI = loadUI({})
    local nan = 0 / 0
    local inf = math.huge
    local function finitePositive(x)
        return type(x) == "number" and x == x and x > 0 and x < inf
    end
    local function genScale()
        return pick({ 0.5, 1.5, 0.5 + random(0, 20) * 0.05, 0.5 + random() })
    end
    local defH = UI.StripHeight(UI.DEFAULT_SCALE)
    local defW = UI.StripMinWidth(UI.DEFAULT_SCALE)

    for i = 1, ITERATIONS do
        local a, b = genScale(), genScale()
        if a > b then a, b = b, a end
        local ctx = string.format("(a=%s, b=%s)", show(a), show(b))
        local ha, hb = UI.StripHeight(a), UI.StripHeight(b)
        local wa, wb = UI.StripMinWidth(a), UI.StripMinWidth(b)

        assert(finitePositive(ha) and finitePositive(hb), "StripHeight not positive finite " .. ctx)
        assert(finitePositive(wa) and finitePositive(wb), "StripMinWidth not positive finite " .. ctx)
        assert(hb <= ha, "StripHeight increased with scale: " .. show(hb) .. " > " .. show(ha) .. " " .. ctx)
        assert(wa * a >= 140 + 2 * 18 - 1e-9, "StripMinWidth * scale below 176 at a " .. ctx)
        assert(wb * b >= 140 + 2 * 18 - 1e-9, "StripMinWidth * scale below 176 at b " .. ctx)

        local bad = pick({
            nil, nan, inf, -inf, 0, -1, "1", true, {},
            0.5 - random() * 0.49, 1.5 + 1e-6 + random() * 100, -random() * 100,
        })
        local ctxBad = "(value=" .. show(bad) .. ")"
        assert(UI.StripHeight(bad) == defH, "StripHeight out of range differs from default " .. ctxBad)
        assert(UI.StripMinWidth(bad) == defW, "StripMinWidth out of range differs from default " .. ctxBad)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Property 10: Reset to defaults
-- Validates: Requirements 5.9, 7.2, 7.3, 7.4, 7.6
----------------------------------------------------------------------
property("Feature: options-panel, Property 10: Reset to defaults", function()
    local UI = loadUI({})
    local nan = 0 / 0

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end

    local function genAny()
        local r = random(8)
        if r == 1 then return random(-5, 5) end
        if r == 2 then return random() * 100 end
        if r == 3 then return pick({ "true", "false", "", "abc" }) end
        if r == 4 then return {} end
        if r == 5 then return nan end
        if r == 6 then return pick({ math.huge, -math.huge }) end
        if r == 7 then return random() < 0.5 end
        return nil
    end

    local function genDb()
        local db = {}
        db.window = { point = "TOPLEFT", left = random(0, 2000), top = random(0, 2000) }
        db.checkedGames = { [random(1, 50)] = true, ["g" .. random(1, 9)] = false }
        if random() < 0.8 then
            db.windowScale = pick({ 0.5, 0.85, 1.2, 1.5, 99, -1, "bad", nan, math.huge, {}, true, 0.5 + random() })
        end
        if random() < 0.8 then
            db.showPlayerCounts = random() < 0.5 and (random() < 0.5) or genAny()
        end
        if random() < 0.5 then db.debug = random() < 0.5 end
        for _ = 1, random(0, 4) do db["extra" .. random(1, 20)] = pick({ 1, "x", true, {} }) end
        return db
    end

    for i = 1, ITERATIONS do
        local db = genDb()
        local ctx = "(scale=" .. show(db.windowScale) .. ", counts=" .. show(db.showPlayerCounts) .. ")"
        local expected = deepCopy(db)
        expected.windowScale = nil
        expected.showPlayerCounts = nil

        UI.ResetOptions(db)
        assert(UI.ReadScale(db) == UI.DEFAULT_SCALE, "ReadScale not default after reset " .. ctx)
        assert(UI.ReadShowCounts(db) == true, "ReadShowCounts not true after reset " .. ctx)
        assert(db.windowScale == nil and db.showPlayerCounts == nil, "settings not removed " .. ctx)
        assert(deepEqual(expected, db), "fields other than the two settings changed " .. ctx)

        -- A second call leaves the db unchanged.
        UI.ResetOptions(db)
        assert(deepEqual(expected, db), "second ResetOptions changed the db " .. ctx)

        -- A non-table db is ignored without error.
        local junk = genAny()
        UI.ResetOptions(junk)
        UI.ResetOptions(nil)
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Task 1.14: Example tests for the pure layer
-- Validates: Requirements 3.1, 3.3, 6.1, 6.6, 6.7, 6.8, 8.4, 9.2, 9.4
----------------------------------------------------------------------
property("Feature: options-panel, Task 1.14: Example tests for the pure layer", function()
    local UI = loadUI({})

    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    -- Constants.
    assert(UI.SCALE_STEP == 0.05, "SCALE_STEP ~= 0.05")
    assert(UI.DEFAULT_SHOW_COUNTS == true, "DEFAULT_SHOW_COUNTS ~= true")

    -- The 21 grid values are valid, and 0.85 is among them.
    local hasDefault = false
    for n = 0, 20 do
        local v = math.floor((0.5 + n * 0.05) * 100 + 0.5) / 100
        assert(UI.IsValidScale(v), "grid value not valid: " .. v)
        if v == 0.85 then hasDefault = true end
    end
    assert(hasDefault, "0.85 not on the grid")

    assert(UI.SnapScale(0.73) == 0.75, "SnapScale(0.73) ~= 0.75")

    -- HeaderText at the default setting equals the pre-change string.
    local row = { game = "D3", count = 3 }
    local expected = "D3 (3)"
    local UInil, nsNil = loadUI(nil)
    assert(nsNil.db == nil)
    assert(UInil.HeaderText(row) == expected, "HeaderText with ns.db nil: " .. show((UInil.HeaderText(row))))
    local UIempty = loadUI({})
    assert(UIempty.HeaderText(row) == expected, "HeaderText with empty db: " .. show((UIempty.HeaderText(row))))

    -- Counts off with debug on: the id text stays, the count goes.
    local UIoff = loadUI({ showPlayerCounts = false, debug = true })
    local wowRow = { game = "WoW", wowProjectID = 11, count = 3 }
    local text = UIoff.HeaderText(wowRow)
    assert(text == "WoW [id: 11]", "counts off + debug: " .. show(text))
    assert(not text:find("%(3%)"), "count still present")
    local noneText = UIoff.HeaderText({ game = "WoW", count = 3 })
    assert(noneText == "WoW [id: none]", "counts off + debug, no id: " .. show(noneText))

    -- GroupByGame output does not depend on the count setting.
    local Friends, nsF = loadFriends()
    local Games = loadGames(nsF)
    local entries = {
        { name = "Ann", isOnline = true, game = "WoW", wowProjectID = 1, subIcon = "WoW_Retail" },
        { name = "Bob", isOnline = true, game = "WoW", wowProjectID = 11 },
        { name = "Cy", isOnline = true, game = "D3" },
        { name = "Di", isOnline = false, game = "WTCG" },
    }
    nsF.db = nil
    local without = Friends.GroupByGame(entries, Games.GetGameName)
    nsF.db = { showPlayerCounts = false }
    local withOff = Friends.GroupByGame(entries, Games.GetGameName)
    nsF.db = { showPlayerCounts = true }
    local withOn = Friends.GroupByGame(entries, Games.GetGameName)
    assert(deepEqual(without, withOff), "GroupByGame changed with counts off")
    assert(deepEqual(without, withOn), "GroupByGame changed with counts on")

    -- UI.lua loads with showPlayerCounts undefined and creates no window frames at load time.
    local created = {}
    local savedCreateFrame = CreateFrame
    CreateFrame = function(kind, name, ...)
        created[#created + 1] = { kind = kind, name = name }
        return stubFrame()
    end
    local ok, err = pcall(loadUI, {})
    CreateFrame = savedCreateFrame
    assert(ok, "UI.lua failed to load: " .. tostring(err))
    for _, c in ipairs(created) do
        assert(c.name ~= "ForeverFilterFrame", "window frame created at load")
        assert(c.kind == "Frame", "non-event frame created at load: " .. tostring(c.kind))
    end
end)

----------------------------------------------------------------------
-- Feature: options-panel, Example tests for the frame wiring
-- Validates: Requirements 1.1, 1.2, 1.4, 1.5, 1.6, 1.7, 2.3, 2.4, 2.5, 2.10, 2.11, 2.12, 3.2, 3.10,
--            3.11, 4.2, 4.3, 4.5, 4.6, 5.6, 5.7, 5.8, 5.9, 6.3, 7.1, 7.2, 7.3, 7.4, 7.5, 8.5
----------------------------------------------------------------------
local function optDeepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not optDeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function optDeepCopy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = optDeepCopy(x) end
    return c
end

-- Runs fn(env, ctx) with the wiring harness plus a recording CreateFrame and a GameTooltip stub.
local function withOptions(fn, opts)
    opts = opts or {}
    withWiring(300, 400, function(env)
        local savedTooltip = GameTooltip
        local ctx = { created = {}, tips = {}, refreshes = 0 }
        local base = CreateFrame
        CreateFrame = function(kind, name, parent, template)
            if kind == "Slider" and opts.failSlider then error("no slider template") end
            local f = base(kind, name, parent, template)
            f.kind, f.template, f.parentFrame = kind, template, parent
            ctx.created[#ctx.created + 1] = f
            if name == "ForeverFilterFrame" then
                rawset(f, "CloseButton", base("Button", "close"))
            end
            return f
        end
        GameTooltip = {
            SetOwner = function() end,
            SetText = function(_, t) ctx.tips[#ctx.tips + 1] = t end,
            Show = function() end,
            Hide = function() end,
        }
        function ctx.find(kind, parent, template)
            for _, f in ipairs(ctx.created) do
                if f.kind == kind and (parent == nil or f.parentFrame == parent)
                    and (template == nil or f.template == template) then
                    return f
                end
            end
        end
        function ctx.refreshCount()
            local n = 0
            for _, e in ipairs(env.log) do if e[1] == "Refresh" then n = n + 1 end end
            return n
        end
        function ctx.parts()
            local win = env.win
            local strip = ctx.find("Frame", win)
            local p = { strip = strip, slider = ctx.find("Slider"),
                        check = ctx.find("CheckButton", strip), reset = ctx.find("Button", strip) }
            for _, fs in ipairs(env.fontStrings) do
                if rawget(fs, "owner") == p.slider and fs.text ~= "Scale" then p.valueText = fs end
                if rawget(fs, "owner") == p.check then p.checkText = fs end
            end
            return p
        end
        local ok, err = pcall(fn, env, ctx)
        CreateFrame, GameTooltip = base, savedTooltip
        assert(ok, err)
    end)
end

property("Feature: options-panel, Example tests: gear button, tooltip, toggle and lazy strip", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        assert(gear, "gear button not created as a child of the window")
        local anchored = false
        for _, c in ipairs(gear.calls) do
            if c[1] == "SetPoint" and c[2] == "RIGHT" and c[3] == win.CloseButton and c[4] == "LEFT" then
                anchored = true
            end
        end
        assert(anchored, "gear not anchored RIGHT to CloseButton LEFT")
        for _, c in ipairs(win.CloseButton.calls) do
            assert(c[1] ~= "SetPoint" and c[1] ~= "ClearAllPoints", "CloseButton was repositioned")
        end

        gear.scripts.OnEnter(gear)
        assert(ctx.tips[#ctx.tips] == "Options", "tooltip text is " .. tostring(ctx.tips[#ctx.tips]))

        assert(ctx.find("Slider") == nil and ctx.find("Frame", win) == nil, "strip created before first click")

        local r0 = ctx.refreshCount()
        gear.scripts.OnClick(gear)
        local strip = ctx.find("Frame", win)
        assert(strip and strip.shown, "first click did not show the strip")
        assert(ctx.refreshCount() == r0 + 1, "first click did not refresh")
        gear.scripts.OnClick(gear)
        assert(not strip.shown, "second click did not hide the strip")
        assert(ctx.refreshCount() == r0 + 2, "second click did not refresh")
    end)
end)

property("Feature: options-panel, Example tests: missing slider template leaves the window working", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        local ok, err = pcall(gear.scripts.OnClick, gear)
        assert(ok, "click raised: " .. tostring(err))
        ok, err = pcall(gear.scripts.OnClick, gear)
        assert(ok, "second click raised: " .. tostring(err))
        assert(win.shown, "window no longer shown")
        local strip = ctx.find("Frame", win)
        assert(strip == nil or not strip.shown, "strip left shown after failed creation")
        assert(#env.printed == 0, "printed: " .. tostring(env.printed[1]))
        assert(pcall(env.UI.Refresh), "Refresh failed after a failed strip creation")
    end, { failSlider = true })
end)

property("Feature: options-panel, Example tests: window hide and show close the strip", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        gear.scripts.OnClick(gear)
        local strip = ctx.find("Frame", win)
        assert(strip.shown)
        win:Hide()
        assert(not strip.shown, "strip still shown after the window hid")
        win:Show()
        assert(not strip.shown, "strip shown after the window re-opened")
        gear.scripts.OnClick(gear)
        assert(strip.shown, "state was not reset: click did not open the strip")
    end)
end)

property("Feature: options-panel, Example tests: opening and closing keeps window settings and TOPLEFT", function()
    withOptions(function(env, ctx)
        env.UI.WriteWindowSettings(env.ns.db, 321, 654)
        local before = optDeepCopy(env.ns.db.window)
        env.UI.Show()
        local win = env.win
        win.left, win.top = 321, 654
        local gear = ctx.find("Button", win)
        for i = 1, 2 do
            gear.scripts.OnClick(gear)
            local pts = env.points()
            local p = pts[#pts]
            assert(p[2] == "TOPLEFT" and p[3] == UIParent and p[4] == "BOTTOMLEFT" and p[5] == 321 and p[6] == 654,
                "TOPLEFT moved on toggle " .. i)
            assert(optDeepEqual(env.ns.db.window, before), "window settings changed on toggle " .. i)
        end
    end)
end)

property("Feature: options-panel, Example tests: slider writes snapped value and applies scale", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        gear.scripts.OnClick(gear)
        local p = ctx.parts()
        local mn, mx, step
        for _, c in ipairs(p.slider.calls) do
            if c[1] == "SetMinMaxValues" then mn, mx = c[2], c[3] end
            if c[1] == "SetValueStep" then step = c[2] end
        end
        assert(mn == 0.5 and mx == 1.5 and step == 0.05, "slider range/step wrong")

        local windowBefore = optDeepCopy(env.ns.db.window)
        p.slider.scripts.OnValueChanged(p.slider, 0.73)
        assert(env.ns.db.windowScale == 0.75, "wrote " .. tostring(env.ns.db.windowScale))
        local sawScale = false
        for _, c in ipairs(win.calls) do
            if c[1] == "SetScale" and c[2] == 0.75 then sawScale = true end
        end
        assert(sawScale and win.scale == 0.75, "SetScale(0.75) not applied")
        assert(optDeepEqual(env.ns.db.window, windowBefore), "window settings changed")
        assert(p.valueText and p.valueText.text == "0.75", "value text is " .. tostring(p.valueText and p.valueText.text))
    end)
end)

property("Feature: options-panel, Example tests: syncing does not write or apply, /ff scale updates slider", function()
    withOptions(function(env, ctx)
        env.ns.db.windowScale = nil
        env.UI.Show()
        local win = env.win
        local function scaleCalls()
            local n = 0
            for _, c in ipairs(win.calls) do if c[1] == "SetScale" then n = n + 1 end end
            return n
        end
        local gear = ctx.find("Button", win)
        local n0 = scaleCalls()
        gear.scripts.OnClick(gear)
        local p = ctx.parts()
        assert(p.slider.value == 0.85, "slider not synced to default on open: " .. tostring(p.slider.value))
        assert(rawget(env.ns.db, "windowScale") == nil, "sync wrote the scale setting")
        assert(scaleCalls() == n0, "sync called ApplyScale")
        assert(p.check.checked == true, "checkbox not synced to default")

        env.UI.HandleScaleCommand("0.7")
        assert(p.slider.value == 0.7, "slider not updated by /ff scale: " .. tostring(p.slider.value))
        assert(p.valueText.text == "0.7", "value text is " .. tostring(p.valueText.text))
        assert(env.ns.db.windowScale == 0.7)
    end)
end)

property("Feature: options-panel, Example tests: dragging skips PlaceWindow until mouse up", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local placed = 0
        local orig = env.UI.PlaceWindow
        env.UI.PlaceWindow = function(...) placed = placed + 1; return orig(...) end
        local gear = ctx.find("Button", win)
        gear.scripts.OnClick(gear)
        local p = ctx.parts()

        p.slider.scripts.OnValueChanged(p.slider, 1.2)
        assert(placed == 1, "non-drag change placed " .. placed .. " times")

        p.slider.scripts.OnMouseDown(p.slider)
        p.slider.scripts.OnValueChanged(p.slider, 1.3)
        p.slider.scripts.OnValueChanged(p.slider, 1.4)
        assert(placed == 1, "PlaceWindow ran while dragging")
        p.slider.scripts.OnMouseUp(p.slider)
        assert(placed == 2, "mouse up placed " .. (placed - 1) .. " times")
    end)
end)

property("Feature: options-panel, Example tests: slider is counter-scaled at each window scale", function()
    withOptions(function(env, ctx)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        gear.scripts.OnClick(gear)
        local p = ctx.parts()
        for _, s in ipairs({ 0.5, 0.85, 1.5 }) do
            env.UI.HandleScaleCommand(tostring(s))
            assert(math.abs(win.scale - s) < 1e-9, "window scale " .. tostring(win.scale))
            assert(math.abs(p.slider.scale - 1 / s) < 1e-9, "slider scale " .. tostring(p.slider.scale) .. " at " .. s)
        end
    end)
end)

property("Feature: options-panel, Example tests: checkbox, reset button, labels and /ff reset", function()
    withOptions(function(env, ctx)
        local db = env.ns.db
        db.checkedGames = { WoW = true }
        db.windowScale = 1.2
        env.UI.WriteWindowSettings(db, 11, 22)
        env.UI.Show()
        local win = env.win
        local gear = ctx.find("Button", win)
        gear.scripts.OnClick(gear)
        local p = ctx.parts()

        -- Opening sets controls from the db; labels are set.
        assert(p.slider.value == 1.2, "slider not set from db")
        assert(p.check.checked == true, "checkbox not set from db")
        assert(p.checkText and p.checkText.text == "Show player counts", "checkbox label")
        assert(p.reset and p.reset.text == "Reset to defaults", "reset label")

        local games = optDeepCopy(db.checkedGames)
        local windowBefore = optDeepCopy(db.window)

        local r0 = ctx.refreshCount()
        p.check.checked = false
        p.check.scripts.OnClick(p.check)
        assert(db.showPlayerCounts == false, "count setting not written")
        assert(optDeepEqual(db.checkedGames, games), "checkedGames changed")
        assert(ctx.refreshCount() == r0 + 1, "checkbox did not refresh")

        -- /ff reset leaves both settings unchanged.
        env.UI.ResetPosition()
        assert(db.showPlayerCounts == false and db.windowScale == 1.2, "ResetPosition changed the options")

        -- Reset to defaults.
        windowBefore = optDeepCopy(db.window)
        r0 = ctx.refreshCount()
        p.reset.scripts.OnClick(p.reset)
        assert(rawget(db, "windowScale") == nil and rawget(db, "showPlayerCounts") == nil, "settings not removed")
        assert(win.scale == 0.85, "window scale " .. tostring(win.scale))
        assert(p.slider.value == 0.85, "slider not reset")
        assert(p.check.checked == true, "checkbox not reset")
        assert(optDeepEqual(db.window, windowBefore), "reset changed window settings")
        assert(optDeepEqual(db.checkedGames, games), "reset changed checkedGames")
        assert(ctx.refreshCount() > r0, "reset did not refresh")
    end)
end)

----------------------------------------------------------------------
-- (append further properties above this line)
----------------------------------------------------------------------
print(string.format("%d/%d properties passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
