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
-- (append further properties above this line)
----------------------------------------------------------------------
print(string.format("%d/%d properties passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
