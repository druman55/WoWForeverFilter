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

-- Loads Friends.lua then UI.lua into one ns (the .toc order), so UI.FriendGameKeys
-- can resolve ns.Friends.PresenceGames. Returns UI, ns, Friends.
local function loadUIWithFriends(db)
    local ns = { db = db }
    loadModule("Friends", ns)
    local chunk, err = loadfile("ForeverFilter/UI.lua")
    if not chunk then error("cannot load ForeverFilter/UI.lua: " .. tostring(err)) end
    chunk("ForeverFilter", ns)
    return ns.UI, ns, ns.Friends
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
        local UI, ns = loadUI({ checkedGames = genStore() })
        ns.debug = debug
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
        local UI, ns = loadUI({})
        ns.debug = debug
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
        -- friends-list-filter 5.1: five game rows plus the Offline row (24 + 6 gap) and the 7 px divider.
        -- name-filter-input 2.7: plus the 48 px top area (Name row and heading).
        local withOffline = fiveRows + 24 + 6 + 7 + 48
        assert(heights[1][2] == withOffline, "SetHeight(" .. tostring(heights[1][2]) .. ") ~= " .. withOffline)

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

        -- friends-list-filter 5.1: with no friends only the Offline row remains, sized like any row
        -- (the stub string width is 400.2, so the width is 487 instead of the old empty-state 288).
        entries = {}
        ns.Friends.GetAll = function() return entries end
        mainFrame.calls = {}
        UI.Refresh()
        local w3 = callsOf(mainFrame, "SetWidth")
        assert(#w3 == 1 and w3[1][2] == 487, "offline-only width is " .. tostring(w3[1] and w3[1][2]))
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
            and ctx.windowShown

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
                     Text = true, text = true, Low = true, High = true, CloseButton = true,
                     offline = true }  -- row checkbox field; nil on game rows as in the client
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
    local UIoff, nsOff = loadUI({ showPlayerCounts = false })
    nsOff.debug = true
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
-- Feature: friends-list-filter, Property 1: Hiding nothing returns the input
-- Validates: Requirements 1.3, 2.6, 9.7
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 1: Hiding nothing returns the input", function()
    local UI = loadUI({})
    local kinds = { "bnet", "wow", "divider", "invite_header", "invite", "spacer" }
    local function isDivider(e) return e.kind == "divider" end

    for i = 1, ITERATIONS do
        local input = {}
        for j = 1, random(0, 40) do
            -- Bias toward dividers so leading, trailing, and repeated ones occur.
            local kind = (random() < 0.3) and "divider" or pick(kinds)
            input[j] = { kind = kind, id = j }
        end
        local snapshot = {}
        for j, e in ipairs(input) do snapshot[j] = e end

        local calls = 0
        local kept, hidden = UI.FilterElements(input, function() calls = calls + 1; return false end, isDivider)

        assert(hidden == 0, "iteration " .. i .. ": hidden count " .. tostring(hidden))
        assert(#kept == #input, "iteration " .. i .. ": length " .. #kept .. " vs " .. #input)
        for j = 1, #input do
            assert(kept[j] == input[j], "iteration " .. i .. ": element " .. j .. " differs")
        end
        assert(kept ~= input, "iteration " .. i .. ": input list returned, not a copy")
        assert(#input == #snapshot, "iteration " .. i .. ": input mutated")
        for j = 1, #snapshot do
            assert(input[j] == snapshot[j], "iteration " .. i .. ": input mutated at " .. j)
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 2: Filter keeps exactly the visible elements, in order
-- Validates: Requirements 3.3, 3.4, 5.4, 7.3, 9.6, 9.9, 10.13
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 2: Filter keeps exactly the visible elements, in order", function()
    local UI = loadUI({})
    local kinds = { "bnet", "wow", "divider", "invite_header", "invite", "spacer" }
    local function isDivider(e) return e.kind == "divider" end

    for i = 1, ITERATIONS do
        local input = {}
        for j = 1, random(0, 40) do
            local kind = (random() < 0.3) and "divider" or pick(kinds)
            input[j] = { kind = kind, id = j }
        end

        -- Deterministic predicate from element id; mode 1 hides everything.
        local mode = random(1, 3)
        local hideSet = {}
        for j = 1, #input do
            hideSet[j] = (mode == 1) or (mode == 2 and random() < 0.5) or (mode == 3 and random() < 0.2)
        end
        local function shouldHide(e) return hideSet[e.id] == true end

        local kept, hidden = UI.FilterElements(input, shouldHide, isDivider)

        -- Every kept element is an input element, and order is preserved.
        local last = 0
        for k, e in ipairs(kept) do
            assert(type(e) == "table" and input[e.id] == e, "iteration " .. i .. ": kept " .. k .. " not an input element")
            assert(e.id > last, "iteration " .. i .. ": order broken at " .. k)
            last = e.id
            if not isDivider(e) then
                assert(not shouldHide(e), "iteration " .. i .. ": kept hidden element " .. e.id)
            end
        end

        -- Every non-divider that is not hidden is kept.
        local keptById = {}
        for _, e in ipairs(kept) do keptById[e.id] = true end
        local expectedHidden = 0
        for j, e in ipairs(input) do
            if not isDivider(e) then
                if shouldHide(e) then
                    expectedHidden = expectedHidden + 1
                else
                    assert(keptById[j], "iteration " .. i .. ": visible element " .. j .. " dropped")
                end
            end
        end
        assert(hidden == expectedHidden, "iteration " .. i .. ": hidden " .. tostring(hidden) .. " vs " .. expectedHidden)
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 3: Filtering is idempotent
-- Validates: Requirements 9.8
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 3: Filtering is idempotent", function()
    local UI = loadUI({})
    local kinds = { "bnet", "wow", "divider", "invite_header", "invite", "spacer" }
    local function isDivider(e) return e.kind == "divider" end

    for i = 1, ITERATIONS do
        local input = {}
        for j = 1, random(0, 40) do
            local kind = (random() < 0.3) and "divider" or pick(kinds)
            input[j] = { kind = kind, id = j }
        end

        local mode = random(1, 4)
        local hideSet = {}
        for j = 1, #input do
            hideSet[j] = (mode == 1) or (mode == 2 and random() < 0.5) or (mode == 3 and random() < 0.2)
        end
        local function shouldHide(e) return hideSet[e.id] == true end

        local once = UI.FilterElements(input, shouldHide, isDivider)
        local twice, hiddenAgain = UI.FilterElements(once, shouldHide, isDivider)

        assert(hiddenAgain == 0, "iteration " .. i .. ": second pass hid " .. tostring(hiddenAgain))
        assert(#twice == #once, "iteration " .. i .. ": length " .. #twice .. " vs " .. #once)
        for j = 1, #once do
            assert(twice[j] == once[j], "iteration " .. i .. ": element " .. j .. " differs")
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 4: Dividers are tidy after hiding
-- Validates: Requirements 7.1, 7.2, 9.5
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 4: Dividers are tidy after hiding", function()
    local UI = loadUI({})
    local kinds = { "bnet", "wow", "invite_header", "invite", "spacer" }
    local function isDivider(e) return e.kind == "divider" end

    for i = 1, ITERATIONS do
        local input = {}
        for j = 1, random(1, 40) do
            local kind = (random() < 0.3) and "divider" or pick(kinds)
            input[j] = { kind = kind, id = j }
        end
        -- Guarantee at least one non-divider so the predicate can hide something.
        local nonDividers = {}
        for j, e in ipairs(input) do
            if not isDivider(e) then nonDividers[#nonDividers + 1] = j end
        end
        if #nonDividers == 0 then
            input[#input + 1] = { kind = pick(kinds), id = #input + 1 }
            nonDividers[1] = #input
        end

        local mode = random(1, 3)
        local hideSet = {}
        for j = 1, #input do
            hideSet[j] = (mode == 1) or (mode == 2 and random() < 0.5) or (mode == 3 and random() < 0.2)
        end
        hideSet[nonDividers[random(1, #nonDividers)]] = true
        local function shouldHide(e) return hideSet[e.id] == true end

        local kept, hidden = UI.FilterElements(input, shouldHide, isDivider)
        assert(hidden > 0, "iteration " .. i .. ": nothing hidden")

        for k, e in ipairs(kept) do
            if isDivider(e) then
                assert(k > 1, "iteration " .. i .. ": divider is first")
                assert(k < #kept, "iteration " .. i .. ": divider is last")
                assert(not isDivider(kept[k - 1]), "iteration " .. i .. ": adjacent dividers at " .. k)
                assert(not isDivider(kept[k + 1]), "iteration " .. i .. ": adjacent dividers at " .. k)
            end
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 5: Online friend decision
-- Validates: Requirements 2.1, 2.2, 9.1, 9.2, 9.3, 9.4
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 5: Online friend decision", function()
    local UI = loadUI({})
    local keys = { "WoW", "D3", "Pro", "S2", "BSAp", "ANBS", "x" }
    local junk = { 0, 1, "yes", {}, function() end }

    for i = 1, ITERATIONS do
        -- friendGames: key list, empty list, nil, or non-table.
        local friendGames
        local r = random(1, 6)
        if r == 1 then
            friendGames = {}
        elseif r == 2 then
            friendGames = nil
        elseif r == 3 then
            friendGames = pick({ "WoW", 5, true, false })
        else
            friendGames = {}
            for j = 1, random(1, 4) do friendGames[j] = pick(keys) end
        end

        -- isOnline: booleans (weighted toward true), nil, or other types.
        local isOnline
        local o = random(1, 6)
        if o <= 3 then isOnline = true
        elseif o == 4 then isOnline = false
        elseif o == 5 then isOnline = nil
        else isOnline = pick({ 0, 1, "true", {} }) end

        -- isChecked backed by a random map: booleans, missing, non-boolean values.
        local map = {}
        for _, k in ipairs(keys) do
            local m = random(1, 5)
            if m == 1 or m == 2 then map[k] = false
            elseif m == 3 then map[k] = true
            elseif m == 4 then map[k] = pick(junk)
            end
        end
        local function isChecked(key) return map[key] end

        local expected = isOnline == true
            and type(friendGames) == "table" and #friendGames > 0
        if expected then
            for _, k in ipairs(friendGames) do
                if map[k] ~= false then expected = false break end
            end
        end

        local actual = UI.ShouldHideFriend(friendGames, isOnline, isChecked)
        assert(actual == expected, "iteration " .. i .. ": expected " .. tostring(expected)
            .. " got " .. tostring(actual))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 6: Offline friend decision
-- Validates: Requirements 3.1, 10.11, 10.12, 10.14
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 6: Offline friend decision", function()
    local UI = loadUI({})
    local function gen()
        local r = random(1, 6)
        if r <= 2 then return true
        elseif r <= 4 then return false
        elseif r == 5 then return nil
        else return pick({ 0, 1, "true", "false", {}, function() end }) end
    end

    for i = 1, ITERATIONS do
        local isOnline, isChecked = gen(), gen()
        local expected = isOnline ~= true and isChecked == false
        local actual = UI.ShouldHideOfflineFriend(isOnline, isChecked)
        assert(actual == expected, "iteration " .. i .. ": expected " .. tostring(expected)
            .. " got " .. tostring(actual))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 7: Element decision keeps what the filter must keep
-- Validates: Requirements 3.3, 3.5, 4.3, 10.11, 10.12, 10.13, 10.15
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 7: Element decision keeps what the filter must keep", function()
    local UI = loadUI({})
    local keyPool = { "WoW", "D3", "Pro", "S2", "BSAp", "ANBS", "x" }
    local junk = { 0, 1, "yes", {}, function() end }

    for i = 1, ITERATIONS do
        -- isBnetFriend: mostly true, sometimes false, nil, or another type.
        local isBnetFriend
        local b = random(1, 6)
        if b <= 3 then isBnetFriend = true
        elseif b == 4 then isBnetFriend = false
        elseif b == 5 then isBnetFriend = nil
        else isBnetFriend = pick({ 0, 1, "true", {} }) end

        -- isOnline: true, false, or nil.
        local isOnline = pick({ true, false, nil, true, false })

        -- keys: key list, empty list, or nil.
        local keys
        local k = random(1, 5)
        if k == 1 then keys = {}
        elseif k == 2 then keys = nil
        else
            keys = {}
            for j = 1, random(1, 4) do keys[j] = pick(keyPool) end
        end

        local map = {}
        for _, key in ipairs(keyPool) do
            local m = random(1, 5)
            if m == 1 or m == 2 then map[key] = false
            elseif m == 3 then map[key] = true
            elseif m == 4 then map[key] = pick(junk)
            end
        end
        local function isChecked(key) return map[key] end

        local offlineChecked
        local oc = random(1, 4)
        if oc == 1 or oc == 2 then offlineChecked = false
        elseif oc == 3 then offlineChecked = true
        else offlineChecked = pick({ nil, 0, "no", {} }) end

        local actual = UI.ShouldHideBnetElement(isBnetFriend, isOnline, keys, isChecked, offlineChecked)

        local expected
        if isBnetFriend ~= true then
            expected = false
        elseif isOnline == nil then
            expected = false
        elseif isOnline == true then
            expected = UI.ShouldHideFriend(keys, true, isChecked)
        else
            expected = UI.ShouldHideOfflineFriend(false, offlineChecked)
        end

        assert(actual == expected, "iteration " .. i .. ": expected " .. tostring(expected)
            .. " got " .. tostring(actual))
        if isBnetFriend ~= true or isOnline == nil then
            assert(actual == false, "iteration " .. i .. ": must keep non-bnet or unknown-state element")
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 8: Friend game keys match the window's grouping keys
-- Validates: Requirements 2.3, 3.2
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 8: Friend game keys match the window's grouping keys", function()
    local UI, _, Friends = loadUIWithFriends({})

    local saved = {
        BNGetNumFriends = BNGetNumFriends,
        C_BattleNet = C_BattleNet,
    }

    local programs = { "WoW", "Pro", "D3", "BSAp", "App", "" }
    local projectIDs = { 0, 1, 2, 5, 11 }

    local function genAccount()
        return {
            isOnline = random() < 0.6,
            clientProgram = pick(programs), -- nil when the pick lands on the extra slot
            wowProjectID = pick(projectIDs),
        }
    end

    local function genAccountMaybeNil()
        local acc = genAccount()
        if random(1, 7) == 1 then acc.clientProgram = nil end
        if random(1, 6) == 1 then acc.wowProjectID = nil end
        return acc
    end

    local function setOf(list)
        local s, n = {}, 0
        for _, k in ipairs(list) do
            if not s[k] then s[k] = true; n = n + 1 end
        end
        return s, n
    end

    local ok, err = pcall(function()
        for i = 1, ITERATIONS do
            local accounts = {}
            for j = 1, random(0, 5) do accounts[j] = genAccountMaybeNil() end
            local primary = genAccountMaybeNil()

            BNGetNumFriends = function() return 1 end
            C_BattleNet = {
                GetFriendAccountInfo = function() return { accountName = "F", gameAccountInfo = primary } end,
                GetFriendNumGameAccounts = function() return #accounts end,
                GetFriendGameAccountInfo = function(_, gameIndex) return accounts[gameIndex] end,
            }

            local keys = UI.FriendGameKeys(accounts, primary)

            local expected = {}
            local rows = Friends.GroupByGame(Friends.GetAll())
            for _, row in ipairs(rows) do
                expected[#expected + 1] = UI.GameKey(row.game, row.wowProjectID)
            end

            local keySet, keyCount = setOf(keys)
            local expectedSet = setOf(expected)
            assert(keyCount == #keys, "iteration " .. i .. ": duplicate keys in result")
            for k in pairs(expectedSet) do
                assert(keySet[k], "iteration " .. i .. ": missing key " .. tostring(k))
            end
            for k in pairs(keySet) do
                assert(expectedSet[k], "iteration " .. i .. ": unexpected key " .. tostring(k))
            end

            -- Offline accounts contribute nothing: with no online account anywhere, no keys.
            local anyOnline = primary.isOnline
            for _, a in ipairs(accounts) do anyOnline = anyOnline or a.isOnline end
            if not anyOnline then
                assert(#keys == 0, "iteration " .. i .. ": keys from offline accounts")
            end

            -- Every key comes from an online account (list first, primary as fallback).
            -- App accounts map to "@apps" and only count when no Real_Game is online.
            local function keyOf(a)
                local pid = a.wowProjectID
                if not (type(pid) == "number" and pid > 0) then pid = nil end
                local code = a.clientProgram ~= "" and a.clientProgram or nil
                if Friends.IsAppClient(code) then return UI.APPS_KEY end
                return UI.GameKey(code, pid)
            end
            local onlineKeys = {}
            local sawOnlineInList = false
            local sawRealGame = false
            for _, a in ipairs(accounts) do
                if a.isOnline then
                    sawOnlineInList = true
                    if keyOf(a) ~= UI.APPS_KEY then sawRealGame = true; onlineKeys[keyOf(a)] = true end
                end
            end
            if not sawOnlineInList and primary.isOnline then
                onlineKeys[keyOf(primary)] = true
            elseif not sawRealGame then
                for _, a in ipairs(accounts) do
                    if a.isOnline then onlineKeys[keyOf(a)] = true; break end
                end
            end
            for _, k in ipairs(keys) do
                assert(onlineKeys[k], "iteration " .. i .. ": key " .. tostring(k) .. " not from an online account")
            end
        end
    end)

    BNGetNumFriends = saved.BNGetNumFriends
    C_BattleNet = saved.C_BattleNet
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 9: The Offline key never equals a game key
--
-- Validates: Requirements 10.17, 10.18
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 9: The Offline key never equals a game key", function()
    local UI = loadUI({})
    assert(UI.OFFLINE_KEY == "@offline", "unexpected OFFLINE_KEY " .. tostring(UI.OFFLINE_KEY))

    local function genGame()
        local r = random(6)
        if r == 1 then return nil end
        if r == 2 then return "" end
        if r == 3 then return random(0, 1000) end
        if r == 4 then return pick({ "WoW", "Pro", "D3", "BSAp", "App", "@offline", "offline", "@" }) end
        if r == 5 then return pick({ "Dïablo", "ワールド", "魔兽世界", "ü€", "\xF0\x9F\x8E\xAE" }) end
        local chars = {}
        for j = 1, random(1, 10) do chars[j] = string.char(random(32, 126)) end
        return table.concat(chars)
    end
    local function genProjectID()
        local r = random(4)
        if r == 1 then return nil end
        if r == 2 then return pick({ 0, 1, 2, 5, 11 }) end
        if r == 3 then return random(-1000, 1000) end
        return pick({ "", "1", "@offline", "x" })
    end

    for i = 1, ITERATIONS do
        local game, pid = genGame(), genProjectID()
        local key = UI.GameKey(game, pid)
        assert(key ~= UI.OFFLINE_KEY, "iteration " .. i .. ": GameKey(" .. tostring(game) .. ", "
            .. tostring(pid) .. ") equals the Offline key")
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 10: Offline checked state round trip, default, and isolation
--
-- Validates: Requirements 1.4, 10.8, 10.9
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 10: Offline checked state round trip, default, and isolation", function()
    local function deepEqual(a, b)
        if type(a) ~= "table" or type(b) ~= "table" then return rawequal(a, b) end
        for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end
    local function genNonBoolean()
        local r = random(5)
        if r == 1 then return random(-5, 5) end
        if r == 2 then return genString() end
        if r == 3 then return { random(1, 3), nested = { random(1, 3) } } end
        if r == 4 then return function() end end
        return random() + 0.5
    end
    local function genValue()
        if random() < 0.5 then return random() < 0.5 end
        return genNonBoolean()
    end

    for i = 1, ITERATIONS do
        local store = genStore()
        for _ = 1, random(0, 4) do store[genString() .. ":" .. random(0, 20)] = genValue() end
        local mode = random(3)
        local hasEntry = mode ~= 1
        if mode == 2 then store["@offline"] = genNonBoolean()
        elseif mode == 3 then store["@offline"] = random() < 0.5 end
        local db = { checkedGames = store }
        for _ = 1, random(0, 3) do db["extra" .. random(1, 9)] = genValue() end

        local UI = loadUI(db)
        local before = deepCopy(store)
        local dbBefore = deepCopy(db)
        local stored = before["@offline"]

        -- Default: missing or non-boolean reads as true; the read adds no entry and changes nothing.
        local expected = true
        if type(stored) == "boolean" then expected = stored end
        local got = UI.IsOfflineChecked()
        assert(got == expected, string.format("iteration %d: IsOfflineChecked with stored %s: got %s, expected %s",
            i, tostring(stored), tostring(got), tostring(expected)))
        assert(deepEqual(store, before), "iteration " .. i .. ": IsOfflineChecked changed checkedGames")
        assert(hasEntry or store["@offline"] == nil, "iteration " .. i .. ": IsOfflineChecked added an entry")

        -- Round trip and isolation.
        local b = random() < 0.5
        UI.SetOfflineChecked(b)
        assert(UI.IsOfflineChecked() == b, "iteration " .. i .. ": round trip returned the wrong value")
        assert(store["@offline"] == b and type(store["@offline"]) == "boolean",
            "iteration " .. i .. ": stored value is not the boolean written")
        for k, v in pairs(before) do
            if k ~= "@offline" then
                assert(deepEqual(store[k], v), "iteration " .. i .. ": other entry changed: " .. show(k))
            end
        end
        for k in pairs(store) do
            assert(k == "@offline" or before[k] ~= nil, "iteration " .. i .. ": unexpected new entry " .. show(k))
        end
        for k, v in pairs(dbBefore) do
            if k ~= "checkedGames" then
                assert(deepEqual(db[k], v), "iteration " .. i .. ": db field changed: " .. show(k))
            end
        end

        -- Every value written is a boolean: toggling back also stores a boolean.
        UI.SetOfflineChecked(not b)
        assert(store["@offline"] == (not b), "iteration " .. i .. ": second write not stored")
        assert(UI.IsOfflineChecked() == (not b))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 11: The failure latch only moves toward disabled and announces once
--
-- Validates: Requirements 6.6
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 11: The failure latch only moves toward disabled and announces once", function()
    local UI = loadUI({})
    local events = { "apply", "error", "blocked", "other" }

    for i = 1, ITERATIONS do
        local n = random(0, 30)
        local seq = {}
        for k = 1, n do seq[k] = events[random(#events)] end

        local state = { disabled = false, announced = false }
        local announces, announceAt, firstFailure = 0, nil, nil
        local wasDisabled = false
        for k, ev in ipairs(seq) do
            local before = { disabled = state.disabled, announced = state.announced }
            local newState, action = UI.NextFilterGuard(state, ev)
            assert(state.disabled == before.disabled and state.announced == before.announced,
                "iteration " .. i .. ": input state was mutated at event " .. k)
            assert(type(newState) == "table", "iteration " .. i .. ": no state returned at event " .. k)
            state = newState

            if (ev == "error" or ev == "blocked") and not firstFailure then firstFailure = k end
            if action == "announce" then
                announces = announces + 1
                announceAt = announceAt or k
            else
                assert(action == nil, "iteration " .. i .. ": unexpected action " .. show(action) .. " at event " .. k)
            end
            if wasDisabled then
                assert(state.disabled == true, "iteration " .. i .. ": latch re-enabled at event " .. k)
            end
            wasDisabled = state.disabled == true
        end

        assert((state.disabled == true) == (firstFailure ~= nil),
            "iteration " .. i .. ": disabled is " .. tostring(state.disabled) .. " but first failure is " .. tostring(firstFailure))
        assert(announces <= 1, "iteration " .. i .. ": announced " .. announces .. " times")
        assert(announceAt == firstFailure,
            "iteration " .. i .. ": announce at " .. tostring(announceAt) .. ", first failure at " .. tostring(firstFailure))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 12: Offline count
--
-- Validates: Requirements 10.6
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 12: Offline count", function()
    local Friends = loadFriends()
    local values = { true, false, "nil" }

    for i = 1, ITERATIONS do
        local n = random(0, 40)
        local entries, expected = {}, 0
        for k = 1, n do
            local v = pick(values)
            if v == "nil" then v = nil end
            entries[k] = { isOnline = v, name = "f" .. k }
            if v ~= true then expected = expected + 1 end
        end

        local got = Friends.CountOffline(entries)
        assert(got == expected,
            "iteration " .. i .. ": CountOffline returned " .. show(got) .. ", expected " .. expected)

        -- Fisher-Yates shuffle into a new list
        local shuffled = {}
        for k = 1, n do shuffled[k] = entries[k] end
        for k = n, 2, -1 do
            local j = random(k)
            shuffled[k], shuffled[j] = shuffled[j], shuffled[k]
        end
        local got2 = Friends.CountOffline(shuffled)
        assert(got2 == expected,
            "iteration " .. i .. ": CountOffline after shuffle returned " .. show(got2) .. ", expected " .. expected)
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 14: The Offline divider is shown iff a game row exists
--
-- Validates: Requirements 10.4
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 14: The Offline divider is shown iff a game row exists", function()
    local UI = loadUI({})

    local function gen()
        local r = random(7)
        if r == 1 then return random(0, 1000)
        elseif r == 2 then return -random(1, 1000)
        elseif r == 3 then return nil
        elseif r == 4 then return "str" .. random(0, 9)
        elseif r == 5 then return random() < 0.5
        elseif r == 6 then return {}
        else return (random() - 0.5) * 100 end
    end

    local function check(v, label)
        local expected = type(v) == "number" and v > 0
        local got = UI.OfflineDividerVisible(v)
        assert(got == expected,
            label .. ": OfflineDividerVisible(" .. show(v) .. ") returned " .. show(got) .. ", expected " .. tostring(expected))
    end

    check(0, "edge"); check(1, "edge"); check(-1, "edge"); check(nil, "edge")
    for i = 1, ITERATIONS do
        check(gen(), "iteration " .. i)
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, example tests for the pure layer
--
-- Validates: Requirements 2.3, 3.2, 3.4, 3.5, 7.1, 10.8, 10.15, 10.17
----------------------------------------------------------------------
property("Feature: friends-list-filter, Example tests for the pure layer", function()
    local UI = loadUIWithFriends({})
    local function isDivider(e) return e == "div" end

    -- Offline key
    assert(UI.OFFLINE_KEY == "@offline", "unexpected OFFLINE_KEY " .. tostring(UI.OFFLINE_KEY))

    -- Nothing hidden: a trailing divider built by Blizzard stays.
    local kept, hidden = UI.FilterElements({ "a", "b", "div" }, function() return false end, isDivider)
    assert(hidden == 0 and #kept == 3 and kept[3] == "div", "trailing divider not kept when nothing hidden")

    -- Favorites-only list, its one friend hidden: the divider that follows is dropped.
    kept, hidden = UI.FilterElements({ "fav", "div" }, function(e) return e == "fav" end, isDivider)
    assert(hidden == 1 and #kept == 0, "divider after the hidden favorite was kept")
    kept, hidden = UI.FilterElements({ "a", "fav", "div" }, function(e) return e == "fav" end, isDivider)
    assert(hidden == 1 and #kept == 1 and kept[1] == "a", "trailing divider kept after hiding the last friend")

    -- FriendState with nil accountInfo.
    local isOnline, keys = UI.FriendState(nil, nil)
    assert(isOnline == nil, "FriendState(nil) isOnline should be nil, got " .. show(isOnline))
    assert(type(keys) == "table" and #keys == 0, "FriendState(nil) should return an empty key list")

    -- FriendGameKeys for a friend online in the Battle.net app: the single key "@apps".
    local appKeys = UI.FriendGameKeys({ { isOnline = true, clientProgram = "BSAp" } }, nil)
    assert(#appKeys == 1 and appKeys[1] == "@apps", "BSAp key wrong: " .. show(appKeys[1]))
    appKeys = UI.FriendGameKeys({ { isOnline = true, clientProgram = "App" } }, nil)
    assert(#appKeys == 1 and appKeys[1] == "@apps", "App key wrong: " .. show(appKeys[1]))

    -- IsOfflineChecked with junk: true, and the junk stays.
    local junk = { "x" }
    local UI2, ns2 = loadUI({ checkedGames = { ["@offline"] = junk } })
    assert(UI2.IsOfflineChecked() == true, "junk in @offline should count as checked")
    assert(rawequal(ns2.db.checkedGames["@offline"], junk), "junk in @offline was replaced")
    local UI3, ns3 = loadUI({ checkedGames = { ["@offline"] = "no" } })
    assert(UI3.IsOfflineChecked() == true and ns3.db.checkedGames["@offline"] == "no", "string junk mishandled")

    -- Loading UI.lua creates no frames.
    -- Only the bare event frame (no name, no template) may exist; no window or widgets.
    local realCreateFrame, calls = CreateFrame, {}
    CreateFrame = function(...) calls[#calls + 1] = { ... }; return realCreateFrame(...) end
    local ok, err = pcall(loadUI, {})
    CreateFrame = realCreateFrame
    assert(ok, "UI.lua failed to load: " .. tostring(err))
    for _, c in ipairs(calls) do
        assert(c[1] == "Frame" and c[2] == nil and c[4] == nil,
            "UI.lua created a window or widget at load time: " .. tostring(c[1]) .. " " .. tostring(c[2]))
    end
    assert(#calls <= 1, "UI.lua created " .. #calls .. " frames at load time")
end)

----------------------------------------------------------------------
-- Loads UI.lua then Filter.lua into one ns. env may hold hooksecurefunc, CreateFrame,
-- FriendsListFrame and SocialUIFrame; they become globals until the returned restore() runs.
----------------------------------------------------------------------
local function loadFilter(env)
    env = env or {}
    local names = { "hooksecurefunc", "CreateFrame", "FriendsListFrame", "SocialUIFrame" }
    local saved = {}
    for _, n in ipairs(names) do
        saved[n] = _G[n]
        if n == "CreateFrame" and env[n] == nil then
            -- keep the harness stub
        else
            _G[n] = env[n]
        end
    end
    local function restore()
        for _, n in ipairs(names) do _G[n] = saved[n] end
    end
    local ns = { db = {} }
    local ok, err = pcall(function()
        for _, file in ipairs({ "Friends", "UI", "Filter" }) do
            local chunk, lerr = loadfile("ForeverFilter/" .. file .. ".lua")
            if not chunk then error("cannot load ForeverFilter/" .. file .. ".lua: " .. tostring(lerr)) end
            chunk("ForeverFilter", ns)
        end
    end)
    if not ok then restore(); error(err, 0) end
    return ns.Filter, ns, restore
end

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 13: Hook installation is idempotent
--
-- Validates: Requirements 6.8, 8.4
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 13: Hook installation is idempotent", function()
    for i = 1, ITERATIONS do
        local calls = {}
        local function hook(target, method, fn)
            calls[target] = (calls[target] or 0) + 1
            assert(method == "SetDataProvider", "hooked unexpected method " .. show(method))
            assert(type(fn) == "function", "hook callback is not a function")
        end

        -- Each ScrollBox: absent, present without SetDataProvider, or complete.
        local function genScrollBox()
            local r = random(3)
            if r == 1 then return nil end
            if r == 2 then return {} end
            return { SetDataProvider = function() end }
        end
        local classicBox, socialBox = genScrollBox(), genScrollBox()
        if classicBox and random() < 0.15 then socialBox = classicBox end -- shared table

        local function genFrames()
            local classic, social
            local r = random(3)
            if r > 1 then classic = { ScrollBox = classicBox } end
            r = random(4)
            if r == 2 then social = {}
            elseif r > 2 then social = { FriendsList = r == 3 and {} or { ScrollBox = socialBox } } end
            return classic, social
        end

        local classic, social = genFrames()
        local env = {
            hooksecurefunc = random() < 0.9 and hook or nil,
            FriendsListFrame = classic,
            SocialUIFrame = social,
        }
        local Filter, _, restore = loadFilter(env)
        local ok, err = pcall(function()
            for n = 1, random(1, 10) do
                Filter.Install()
                -- Frames may appear later, as when Blizzard_SocialUI loads on demand.
                if random() < 0.3 then
                    local c2, s2 = genFrames()
                    _G.FriendsListFrame, _G.SocialUIFrame = c2 or _G.FriendsListFrame, s2 or _G.SocialUIFrame
                end
            end
        end)
        restore()
        assert(ok, "iteration " .. i .. ": Install raised an error: " .. tostring(err))
        for target, count in pairs(calls) do
            assert(count == 1, "iteration " .. i .. ": hooksecurefunc called " .. count .. " times for one ScrollBox")
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Example tests: the classic hook
--
-- Validates: Requirements 1.1, 1.2, 1.3, 2.1, 2.2, 2.5, 2.6, 3.3, 3.4, 3.5, 4.1, 5.5, 5.6,
-- 6.2, 6.6, 6.8, 8.3, 8.5, 10.11, 10.12, 10.13, 10.15
----------------------------------------------------------------------
property("Feature: friends-list-filter, Example tests: the classic hook", function()
    local T_DIVIDER, T_WOW, T_BNET, T_INVITE_HEADER, T_INVITE = 1, 2, 3, 4, 5
    local SECRET = {}
    local globalNames = {
        "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue", "BNGetNumFriends", "BNRemoveFriend",
        "BNSetFriendNote", "BNSetFriendFavorite", "FriendsList_Update",
    }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end

    -- Runs body(h) with a fresh Filter, stub frames, a Blizzard-style provider and recorders.
    local function withHook(opts, body)
        opts = opts or {}
        local h = { printed = {}, counts = { bnGetNum = 0, mutate = 0, update = 0, friendInfo = 0 },
                    scrollCalls = {}, hooks = {}, frames = {}, shown = true }
        FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
        issecretvalue = function(v) return v == SECRET end
        print = function(...) h.printed[#h.printed + 1] = table.concat({ ... }, " ") end
        BNGetNumFriends = function() h.counts.bnGetNum = h.counts.bnGetNum + 1; return 5, 5 end
        local function mutator() h.counts.mutate = h.counts.mutate + 1 end
        BNRemoveFriend, BNSetFriendNote, BNSetFriendFavorite = mutator, mutator, mutator
        FriendsList_Update = function() h.counts.update = h.counts.update + 1 end

        -- friends[i] = { games = { {isOnline, clientProgram, wowProjectID}, ... }, primary = {...}, nilInfo = bool }
        h.friends = {}
        C_BattleNet = {
            GetFriendAccountInfo = function(i)
                h.counts.friendInfo = h.counts.friendInfo + 1
                if h.throwOnInfo then error("boom") end
                local f = h.friends[i]
                if not f or f.nilInfo then return nil end
                return { gameAccountInfo = f.primary or f.games[1] }
            end,
            GetFriendNumGameAccounts = function(i) return #h.friends[i].games end,
            GetFriendGameAccountInfo = function(i, j) return h.friends[i].games[j] end,
        }

        -- Provider clone with Blizzard DataProvider semantics.
        local function newProvider(list)
            local p = { collection = {}, flushes = 0, inserts = 0 }
            for i, e in ipairs(list) do p.collection[i] = e end
            function p:GetCollection() return self.collection end
            function p:GetSize() return #self.collection end
            function p:Flush() self.flushes = self.flushes + 1; self.collection = {} end
            function p:InsertTable(t)
                self.inserts = self.inserts + 1
                for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end
            end
            return p
        end
        h.newProvider = newProvider

        local scrollBox = setmetatable({}, { __index = function(_, name)
            return function() h.scrollCalls[#h.scrollCalls + 1] = name end
        end })
        function scrollBox:SetDataProvider(p)
            self.provider = p
            for _, fn in ipairs(h.hooks) do fn(self, p) end -- post-hook, as hooksecurefunc does
        end
        function scrollBox:GetDataProvider() return self.provider end
        h.scrollBox = scrollBox
        -- Blizzard's call: a fresh provider is built and set on the ScrollBox.
        function h.drive(p) scrollBox:SetDataProvider(p) end

        local env = {
            hooksecurefunc = function(target, method, fn)
                assert(target == scrollBox and method == "SetDataProvider", "unexpected hook target")
                h.hooks[#h.hooks + 1] = fn
            end,
            CreateFrame = function()
                local f = { events = {}, scripts = {} }
                function f:RegisterEvent(e) self.events[e] = true end
                function f:SetScript(n, fn) self.scripts[n] = fn end
                h.frames[#h.frames + 1] = f
                return f
            end,
            FriendsListFrame = (not opts.noFrame) and {
                ScrollBox = scrollBox, IsShown = function() return h.shown end,
            } or nil,
        }
        local Filter, ns, restore = loadFilter(env)
        h.Filter, h.ns, h.UI = Filter, ns, ns.UI
        ns.db = { checkedGames = {} }
        function h.fire(event, ...)
            for _, f in ipairs(h.frames) do
                if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
            end
        end
        function h.setChecked(key, v) ns.db.checkedGames[key] = v end
        function h.ids(list)
            local out = {}
            for i, e in ipairs(list) do out[i] = e.buttonType .. ":" .. tostring(e.id) end
            return table.concat(out, ",")
        end
        Filter.Install()

        local ok, err = pcall(body, h)
        restore()
        for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
        if not ok then error(err, 0) end
    end

    local function d3Online() return { { isOnline = true, clientProgram = "D3" } } end
    local function wowOnline() return { { isOnline = true, clientProgram = "WoW", wowProjectID = 1 } } end
    local function setupList(h)
        h.friends[1] = { games = d3Online() }
        h.friends[2] = { games = wowOnline() }
        h.friends[4] = { games = d3Online() }
        local list = {
            { buttonType = T_INVITE_HEADER, id = "h" }, { buttonType = T_INVITE, id = "i" },
            { buttonType = T_DIVIDER, id = "d" },
            { buttonType = T_BNET, id = 1 }, { buttonType = T_BNET, id = 2 },
            { buttonType = T_WOW, id = 9 }, { buttonType = T_BNET, id = 4 },
        }
        return list, h.UI.GameKey("D3")
    end

    -- One unchecked game removes only its friends; the rest and the leading divider stay.
    withHook({}, function(h)
        local list, d3 = setupList(h)
        local original = h.ids(list)
        h.setChecked(d3, false)
        local p = h.newProvider(list)
        h.drive(p)
        assert(h.ids(p:GetCollection()) == "4:h,5:i,1:d,3:2,2:9", "wrong result: " .. h.ids(p:GetCollection()))
        assert(#h.scrollCalls == 0, "scroll method called during edit: " .. tostring(h.scrollCalls[1]))
        assert(h.counts.bnGetNum == 0 and h.counts.mutate == 0, "BN stubs were touched")
        assert(BNGetNumFriends() == 5, "BNGetNumFriends result changed")

        -- Second hook call with the already filtered provider: same result, no further edits.
        local flushes, inserts = p.flushes, p.inserts
        h.drive(p)
        assert(h.ids(p:GetCollection()) == "4:h,5:i,1:d,3:2,2:9", "second call changed the list")
        assert(p.flushes == flushes and p.inserts == inserts, "second call edited the provider")

        -- Check the game again: Reapply restores the original list.
        h.setChecked(d3, true)
        h.Filter.Reapply()
        assert(h.ids(p:GetCollection()) == original, "Reapply did not restore: " .. h.ids(p:GetCollection()))
        assert(#h.scrollCalls == 0, "scroll method called during Reapply")

        -- Uncheck again, then hide the list frame: Reapply does nothing.
        h.setChecked(d3, false)
        h.shown = false
        flushes, inserts = p.flushes, p.inserts
        h.Filter.Reapply()
        assert(p.flushes == flushes and p.inserts == inserts, "Reapply edited a hidden list")
        assert(h.counts.update == 0, "FriendsList_Update was called")
        h.shown = true
        h.Filter.Reapply()
        assert(h.ids(p:GetCollection()) == "4:h,5:i,1:d,3:2,2:9", "Reapply with shown list did not filter")
        assert(h.counts.update == 0, "FriendsList_Update was called")
    end)

    -- Everything checked: no edit at all, content equals what Blizzard built.
    withHook({}, function(h)
        local list = setupList(h)
        local original = h.ids(list)
        local p = h.newProvider(list)
        h.drive(p)
        assert(p.flushes == 0 and p.inserts == 0, "provider edited with everything checked")
        assert(h.ids(p:GetCollection()) == original, "content changed with everything checked")
    end)

    -- Unreadable data keeps the friend: nil account info and a secret value.
    withHook({}, function(h)
        local _, d3 = setupList(h)
        h.friends[5] = { games = d3Online(), nilInfo = true }
        h.friends[6] = { games = { { isOnline = true, clientProgram = SECRET } } }
        h.setChecked(d3, false)
        local p = h.newProvider({ { buttonType = T_BNET, id = 5 }, { buttonType = T_BNET, id = 6 }, { buttonType = T_BNET, id = 1 } })
        h.drive(p)
        assert(h.ids(p:GetCollection()) == "3:5,3:6", "unreadable friends not kept: " .. h.ids(p:GetCollection()))
    end)

    -- Offline row: removes offline Battle.net friends when unchecked, keeps them when checked,
    -- and never touches a WoW character friend.
    withHook({}, function(h)
        h.friends[1] = { games = { { isOnline = false } } }
        h.friends[2] = { games = d3Online() }
        local list = {
            { buttonType = T_BNET, id = 1 }, { buttonType = T_BNET, id = 2 }, { buttonType = T_WOW, id = 7 },
        }
        local p = h.newProvider(list)
        h.setChecked(h.UI.OFFLINE_KEY, false)
        h.drive(p)
        assert(h.ids(p:GetCollection()) == "3:2,2:7", "offline friend not removed: " .. h.ids(p:GetCollection()))
        h.setChecked(h.UI.OFFLINE_KEY, true)
        h.Filter.Reapply()
        assert(h.ids(p:GetCollection()) == "3:1,3:2,2:7", "offline friend not restored: " .. h.ids(p:GetCollection()))
        local p2 = h.newProvider(list)
        h.drive(p2)
        assert(p2.flushes == 0 and p2.inserts == 0, "offline checked caused an edit")
    end)

    -- A throw inside shouldHide latches the guard and prints once.
    withHook({}, function(h)
        local list, d3 = setupList(h)
        h.setChecked(d3, false)
        h.throwOnInfo = true
        local p = h.newProvider(list)
        local ok = pcall(h.drive, p)
        assert(ok, "hook raised the error to the caller")
        assert(h.Filter.IsDisabled(), "guard not latched after an error")
        assert(#h.printed == 1, "expected one message, got " .. #h.printed)
        h.throwOnInfo = false
        local calls = h.counts.friendInfo
        h.drive(h.newProvider(list))
        h.Filter.Reapply()
        assert(h.counts.friendInfo == calls, "filter ran after the guard latched")
        assert(#h.printed == 1, "message printed more than once")
    end)

    -- ADDON_ACTION_BLOCKED naming ForeverFilter latches the guard; other addons do not.
    withHook({}, function(h)
        local list, d3 = setupList(h)
        h.setChecked(d3, false)
        h.fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "Func")
        assert(not h.Filter.IsDisabled(), "another addon's block latched the guard")
        h.fire("ADDON_ACTION_BLOCKED", "ForeverFilter", "Func")
        assert(h.Filter.IsDisabled(), "guard not latched by ADDON_ACTION_BLOCKED")
        assert(#h.printed == 1, "expected one message, got " .. #h.printed)
        local p = h.newProvider(list)
        local original = h.ids(list)
        h.drive(p)
        assert(p.flushes == 0 and p.inserts == 0 and h.ids(p:GetCollection()) == original, "filter ran after block")
    end)

    -- Install with FriendsListFrame = nil raises no error and hooks on a later ADDON_LOADED.
    withHook({ noFrame = true }, function(h)
        assert(#h.hooks == 0, "hooked with no frame")
        assert(pcall(h.Filter.Install), "Install raised with no frame")
        FriendsListFrame = { ScrollBox = h.scrollBox, IsShown = function() return true end }
        h.fire("ADDON_LOADED", "Blizzard_FriendsFrame")
        assert(#h.hooks == 1, "not hooked after ADDON_LOADED")
        h.fire("ADDON_LOADED", "Other")
        assert(#h.hooks == 1, "hooked twice")
    end)
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Example tests: the SocialUI hook and the source scan
--
-- Validates: Requirements 1.1, 5.1, 6.1, 6.2, 7.4
----------------------------------------------------------------------
property("Feature: friends-list-filter, Example tests: the SocialUI hook and the source scan", function()
    local globalNames = { "print", "C_BattleNet", "issecretvalue" }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end

    local function newNode(data)
        local node = { data = data, children = {} }
        function node:GetData() return self.data end
        function node:GetNodes() return self.children end
        function node:Remove(child)
            for i, c in ipairs(self.children) do
                if c == child then table.remove(self.children, i); return end
            end
        end
        function node:InsertNode(child, index) table.insert(self.children, index, child) end
        return node
    end

    local function nodeIds(header)
        local out = {}
        for i, c in ipairs(header:GetNodes()) do out[i] = tostring(c:GetData().friendIndex) end
        return table.concat(out, ",")
    end

    local hooks, shown = {}, true
    local scrollBox = {}
    function scrollBox:SetDataProvider(p)
        self.provider = p
        for _, fn in ipairs(hooks) do fn(self, p) end
    end
    function scrollBox:GetDataProvider() return self.provider end

    local friends = {
        [1] = { { isOnline = true, clientProgram = "D3" } },
        [2] = { { isOnline = true, clientProgram = "WoW", wowProjectID = 1 } },
        [3] = { { isOnline = true, clientProgram = "D3" } },
        [4] = { { isOnline = true, clientProgram = "D3" } },
    }
    issecretvalue = function() return false end
    print = function() end
    C_BattleNet = {
        GetFriendAccountInfo = function(i) return { gameAccountInfo = friends[i][1] } end,
        GetFriendNumGameAccounts = function(i) return #friends[i] end,
        GetFriendGameAccountInfo = function(i, j) return friends[i][j] end,
    }

    local env = {
        hooksecurefunc = function(target, method, fn)
            assert(target == scrollBox and method == "SetDataProvider", "unexpected hook target")
            hooks[#hooks + 1] = fn
        end,
        SocialUIFrame = { FriendsList = { ScrollBox = scrollBox, IsShown = function() return shown end } },
    }
    local Filter, ns, restore = loadFilter(env)
    local ok, err = pcall(function()
        ns.db = { checkedGames = {} }
        Filter.Install()
        assert(#hooks == 1, "SocialUI ScrollBox not hooked")

        local headerA = newNode({ headerText = "A" })
        local headerB = newNode({ headerText = "B" })
        local spacer = newNode({ spacer = true })
        local dataA, dataB = headerA:GetData(), headerB:GetData()
        local function friendNode(i) return newNode({ friendIndex = i }) end
        local n1, n2, n3, n4 = friendNode(1), friendNode(2), friendNode(3), friendNode(4)
        headerA.children = { n1, n2, n3 }
        headerB.children = { n4 }
        local root = newNode(nil)
        root.children = { headerA, spacer, headerB }
        local invalidates = 0
        local provider = {
            GetRootNode = function() return root end,
            Invalidate = function() invalidates = invalidates + 1 end,
        }

        local d3 = ns.UI.GameKey("D3")
        ns.db.checkedGames[d3] = false
        scrollBox:SetDataProvider(provider)

        assert(nodeIds(headerA) == "2", "header A wrong: " .. nodeIds(headerA))
        assert(nodeIds(headerB) == "", "header B wrong: " .. nodeIds(headerB))
        assert(#root.children == 3 and root.children[1] == headerA and root.children[2] == spacer
            and root.children[3] == headerB, "header or spacer nodes changed")
        assert(headerA:GetData() == dataA and headerB:GetData() == dataB
            and dataA.headerText == "A" and dataB.headerText == "B", "header data changed")
        assert(invalidates == 1, "Invalidate called " .. invalidates .. " times")

        ns.db.checkedGames[d3] = true
        Filter.Reapply()
        assert(nodeIds(headerA) == "1,2,3", "header A not restored: " .. nodeIds(headerA))
        assert(nodeIds(headerB) == "4", "header B not restored: " .. nodeIds(headerB))
        assert(headerA:GetNodes()[1] == n1 and headerA:GetNodes()[3] == n3 and headerB:GetNodes()[1] == n4,
            "restored nodes are not the original nodes")
        assert(not Filter.IsDisabled(), "guard latched")
    end)
    restore()
    for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
    if not ok then error(err, 0) end

    -- Source scan of Filter.lua.
    local fh = assert(io.open("ForeverFilter/Filter.lua", "rb"))
    local source = fh:read("*a")
    fh:close()
    for _, banned in ipairs({ "BNRemoveFriend", "RemoveFriend", "BNSetFriendNote", "BNSetFriendFavorite",
                              "FriendsList_Update(", "FriendsFrame_", ":Refresh(" }) do
        assert(not source:find(banned, 1, true), "Filter.lua contains " .. banned)
    end
    -- No assignment to a Blizzard global: every assigned root name must be a local or ns/Filter field.
    local locals = {}
    for line in source:gmatch("[^\n]+") do
        local decl = line:match("^%s*local%s+function%s+([%w_]+)")
        if decl then locals[decl] = true end
        local names = line:match("^%s*local%s+([%w_,%s]-)%s*=") or line:match("^%s*local%s+([%w_,%s]+)$")
        if names then for n in names:gmatch("[%w_]+") do locals[n] = true end end
        local params = line:match("function%s*[%w_.:]*%((.-)%)")
        if params then for n in params:gmatch("[%w_]+") do locals[n] = true end end
        local forVars = line:match("^%s*for%s+(.-)%s+in%s")
        if forVars then for n in forVars:gmatch("[%w_]+") do locals[n] = true end end
    end
    for line in source:gmatch("[^\n]+") do
        local code = line:gsub("%-%-.*$", "")
        if not code:match("^%s*local%s") then
            local root = code:match("^%s*([%a_][%w_]*)[%w_%.]*%s*=[^=]")
            if root then
                assert(locals[root] or root == "ns", "assignment to global " .. root .. ": " .. line)
            end
            local gfn = code:match("^%s*function%s+([%a_][%w_]*)%s*%(")
            assert(not gfn, "global function definition " .. tostring(gfn))
            assert(not code:find("_G%s*[%.%[]"), "_G access: " .. line)
        end
    end

    -- The TOC loads Filter.lua after UI.lua.
    local th = assert(io.open("ForeverFilter/ForeverFilter.toc", "rb"))
    local toc = th:read("*a")
    th:close()
    local uiPos = toc:find("\nUI.lua", 1, true)
    local filterPos = toc:find("\nFilter.lua", 1, true)
    assert(uiPos and filterPos and filterPos > uiPos, "Filter.lua is not listed after UI.lua in the TOC")
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Example tests for the window wiring
-- Validates: Requirements 2.4, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.10, 10.16
----------------------------------------------------------------------
local function flWindow(env, ctx, gameRows, offlineCount)
    env.ns.Friends = {
        GetAll = function() return {} end,
        GroupByGame = function() return gameRows end,
        CountOffline = function() return offlineCount end,
    }
    env.reapplies = {}
    env.ns.Filter = { Reapply = function() env.reapplies[#env.reapplies + 1] = true end }
    env.UI.Show()
    local checks = {}
    for _, f in ipairs(ctx.created) do
        if f.kind == "CheckButton" and f.template == "UICheckButtonTemplate" and f.shown then
            checks[#checks + 1] = f
        end
    end
    -- Header text of a row: the font string anchored to the row's checkbox.
    local function textOf(check)
        for _, fs in ipairs(env.fontStrings) do
            for _, c in ipairs(fs.calls) do
                if c[1] == "SetPoint" and c[3] == check then return rawget(fs, "text") end
            end
        end
    end
    return checks, textOf
end

local function flDivider(env)
    -- UI.lua stores the divider texture on the window frame.
    return rawget(env.win, "offlineDivider")
end

local function flLastHeight(win)
    local h
    for _, c in ipairs(win.calls) do
        if c[1] == "SetHeight" then h = c[2] end
    end
    return h
end

property("Feature: friends-list-filter, Example tests: Offline row, divider and empty state", function()
    local ROW_GAP, DIVIDER_H = 6, 7
    -- Only the Offline row: present with count 0, no divider, height counts the row.
    withOptions(function(env, ctx)
        env.ns.db.showPlayerCounts = false
        local checks, textOf = flWindow(env, ctx, {}, 0)
        assert(#checks == 1, "expected only the Offline row, got " .. #checks)
        assert(textOf(checks[1]) == "Offline", "label: " .. tostring(textOf(checks[1])))
        assert(checks[1].shown and checks[1].checked == true, "Offline row not shown/checked by default")
        assert(env.UI.OfflineDividerVisible(0) == false)
        for _, f in ipairs(env.fontStrings) do
            local t = rawget(f, "text")
            assert(not (type(t) == "string" and t:lower():find("no friends")), "empty-state message shown")
        end
        -- name-filter-input 2.7: the window includes the top area (Name row and heading, 48).
        local want = env.UI.ComputeWindowHeight(env.UI.RowHeight(nil) + 48, 1080, false)
        assert(flLastHeight(env.win) == want, "height " .. tostring(flLastHeight(env.win)) .. " vs " .. want)
        assert(want > 120 or want == 120)
    end)

    -- Counts on: the Offline label carries its count, even 0.
    withOptions(function(env, ctx)
        env.ns.db.showPlayerCounts = true
        local checks, textOf = flWindow(env, ctx, {}, 0)
        assert(textOf(checks[1]) == "Offline (0)", "label: " .. tostring(textOf(checks[1])))
    end)

    -- Game rows: Offline is last, divider sits directly above it and adds its height.
    withOptions(function(env, ctx)
        env.ns.db.showPlayerCounts = true
        local rows = { { game = "WoW", wowProjectID = 1, count = 2 }, { game = "D4", count = 1 } }
        local checks, textOf = flWindow(env, ctx, rows, 3)
        assert(#checks == 3, "expected 3 rows, got " .. #checks)
        assert(textOf(checks[3]) == "Offline (3)", "label: " .. tostring(textOf(checks[3])))
        assert(textOf(checks[1]) == "WoW (2)" and textOf(checks[2]) == "D4 (1)", "game labels")
        local rh = env.UI.RowHeight(nil)
        local div = flDivider(env)
        assert(div and div.shown, "divider not shown")
        local divY, offY
        for _, c in ipairs(div.calls) do
            if c[1] == "SetPoint" and c[2] == "TOPLEFT" then divY = c[6] end
        end
        for _, c in ipairs(checks[3].calls) do
            if c[1] == "SetPoint" and c[2] == "TOPLEFT" then offY = c[6] end
        end
        assert(divY == -(2 * (rh + ROW_GAP)), "divider y " .. tostring(divY))
        assert(offY == divY - DIVIDER_H, "offline y " .. tostring(offY) .. " divider y " .. tostring(divY))
        local area = 3 * rh + 2 * ROW_GAP + DIVIDER_H
        assert(flLastHeight(env.win) == env.UI.ComputeWindowHeight(area + 48, 1080, false), "height with divider")

        -- Counts off: no count on the Offline label.
        env.ns.db.showPlayerCounts = false
        env.win.shown = true
        env.UI.Show()
        assert(textOf(checks[3]) == "Offline", "label without counts: " .. tostring(textOf(checks[3])))
    end)

    -- No game rows afterwards: the divider is hidden.
    withOptions(function(env, ctx)
        local checks = flWindow(env, ctx, { { game = "WoW", wowProjectID = 1, count = 1 } }, 0)
        local div = flDivider(env)
        assert(div and div.shown, "divider not shown with a game row")
        env.ns.Friends.GroupByGame = function() return {} end
        env.UI.Show()
        assert(not div.shown, "divider still shown without game rows")
    end)
end)

property("Feature: friends-list-filter, Example tests: checkbox clicks call Reapply", function()
    withOptions(function(env, ctx)
        local db = env.ns.db
        local checks = flWindow(env, ctx, { { game = "WoW", wowProjectID = 1, count = 1 } }, 0)
        local gameCheck, offCheck = checks[1], checks[2]
        local order = {}
        local seenAtReapply
        env.ns.Filter.Reapply = function()
            order[#order + 1] = "Reapply"
            seenAtReapply = { game = env.UI.IsChecked("WoW", 1), offline = env.UI.IsOfflineChecked() }
        end

        gameCheck.checked = false
        gameCheck.scripts.OnClick(gameCheck)
        assert(#order == 1 and seenAtReapply.game == false, "game click: Reapply must follow SetChecked")
        assert(db.checkedGames[env.UI.OFFLINE_KEY] == nil, "game click wrote the Offline key")

        order = {}
        offCheck.checked = false
        offCheck.scripts.OnClick(offCheck)
        assert(#order == 1 and seenAtReapply.offline == false, "offline click: Reapply must follow the write")
        assert(db.checkedGames["@offline"] == false, "checkedGames[@offline] not written")

        -- ns.Filter nil: clicks still write and raise no error.
        env.ns.Filter = nil
        offCheck.checked = true
        local ok, err = pcall(offCheck.scripts.OnClick, offCheck)
        assert(ok, "offline click raised: " .. tostring(err))
        assert(db.checkedGames["@offline"] == true)
        gameCheck.checked = true
        ok, err = pcall(gameCheck.scripts.OnClick, gameCheck)
        assert(ok, "game click raised: " .. tostring(err))
        assert(env.UI.IsChecked("WoW", 1) == true)
    end)
end)

property("Feature: friends-list-filter, Example tests: Reset to defaults leaves the Offline state and skips Reapply", function()
    withOptions(function(env, ctx)
        local db = env.ns.db
        local checks = flWindow(env, ctx, { { game = "WoW", wowProjectID = 1, count = 1 } }, 0)
        env.UI.SetOfflineChecked(false)
        env.UI.Refresh()
        local gear = ctx.find("Button", env.win)
        gear.scripts.OnClick(gear)
        local p = ctx.parts()
        local before = optDeepCopy(db.checkedGames)
        env.reapplies = {}
        p.reset.scripts.OnClick(p.reset)
        assert(#env.reapplies == 0, "reset called Reapply")
        assert(optDeepEqual(db.checkedGames, before), "reset changed checkedGames")
        assert(db.checkedGames["@offline"] == false and checks[2].checked == false, "Offline state changed")
    end)
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 15: Presence games ignore apps when a real game is online
--
-- Validates: Requirements 11.1, 11.2, 11.3, 11.4
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 15: Presence games ignore apps when a real game is online", function()
    local Friends = loadFriends()
    local codes = { "WoW", "Pro", "D3", "Hero", "App", "BSAp", "CLNT", "", "nil" }
    local appCodes = { App = true, BSAp = true, CLNT = true }

    local function genInfo(tag)
        local code = pick(codes)
        if code == "nil" then code = nil end
        return { isOnline = random() < 0.6, clientProgram = code, tag = tag }
    end

    -- Expected result by the property text, for one account list.
    local function expectedFor(list)
        local real, firstApp = {}, nil
        for _, info in ipairs(list) do
            if info.isOnline then
                if appCodes[info.clientProgram] then
                    firstApp = firstApp or info
                else
                    real[#real + 1] = info
                end
            end
        end
        if #real > 0 then return real end
        if firstApp then return { firstApp } end
        return {}
    end

    for i = 1, ITERATIONS do
        local infos = {}
        local anyOnline = false
        for k = 1, random(0, 6) do
            infos[k] = genInfo("a" .. k)
            if infos[k].isOnline then anyOnline = true end
        end
        local primary = random() < 0.2 and nil or genInfo("primary")

        local expected
        if anyOnline then
            expected = expectedFor(infos)
        elseif primary and primary.isOnline then
            expected = expectedFor({ primary })
        else
            expected = {}
        end

        local got = Friends.PresenceGames(infos, primary)
        assert(type(got) == "table", "iteration " .. i .. ": result is not a table")
        assert(#got == #expected,
            "iteration " .. i .. ": got " .. #got .. " accounts, expected " .. #expected)
        for k = 1, #expected do
            assert(got[k] == expected[k],
                "iteration " .. i .. ": account " .. k .. " is " .. show(got[k] and got[k].tag)
                .. ", expected " .. show(expected[k].tag))
        end

        -- Outcome checks stated directly
        local hasReal = false
        for _, info in ipairs(got) do
            if not appCodes[info.clientProgram] then hasReal = true end
        end
        if hasReal then
            for _, info in ipairs(got) do
                assert(not appCodes[info.clientProgram] and info.isOnline,
                    "iteration " .. i .. ": app or offline account returned with a real game")
            end
        elseif #got > 0 then
            assert(#got == 1 and appCodes[got[1].clientProgram] and got[1].isOnline,
                "iteration " .. i .. ": app-only result is not one online app account")
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 16: Window and filter keys agree for every friend
--
-- Validates: Requirements 11.7, 11.8, 11.9
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 16: Window and filter keys agree for every friend", function()
    -- Friends.lua and UI.lua share one ns so UI.FriendGameKeys finds ns.Friends.
    local Friends, ns = loadFriends()
    ns.db = {}
    local chunk, err = loadfile("ForeverFilter/UI.lua")
    if not chunk then error("cannot load ForeverFilter/UI.lua: " .. tostring(err)) end
    chunk("ForeverFilter", ns)
    local UI = ns.UI

    local savedNum, savedBN = BNGetNumFriends, C_BattleNet
    local codes = { "WoW", "Pro", "D3", "Hero", "App", "BSAp", "CLNT", "", "nil" }
    local pids = { 1, 2, 5, 11, 14, 0, "nil" }

    local function genInfo()
        local code = pick(codes)
        if code == "nil" then code = nil end
        local pid = pick(pids)
        if pid == "nil" then pid = nil end
        return { isOnline = random() < 0.6, clientProgram = code, wowProjectID = pid }
    end

    local ok, perr = pcall(function()
        for i = 1, ITERATIONS do
            local friends = {}
            for f = 1, random(0, 8) do
                local accounts = {}
                for k = 1, random(0, 5) do accounts[k] = genInfo() end
                friends[f] = {
                    name = "friend" .. f,
                    accounts = accounts,
                    primary = random() < 0.2 and nil or genInfo(),
                }
            end

            BNGetNumFriends = function() return #friends end
            C_BattleNet = {
                GetFriendAccountInfo = function(idx)
                    local fr = friends[idx]
                    return { accountName = fr.name, gameAccountInfo = fr.primary }
                end,
                GetFriendNumGameAccounts = function(idx) return #friends[idx].accounts end,
                GetFriendGameAccountInfo = function(idx, g) return friends[idx].accounts[g] end,
            }

            local rows = Friends.GroupByGame(Friends.GetAll())
            local rowKeysByFriend = {}
            local appsFriends, otherFriends = {}, {}
            for _, row in ipairs(rows) do
                local key = UI.GameKey(row.game, row.wowProjectID)
                for _, name in ipairs(row.friends) do
                    rowKeysByFriend[name] = rowKeysByFriend[name] or {}
                    rowKeysByFriend[name][key] = true
                    if key == UI.APPS_KEY then
                        appsFriends[name] = true
                    else
                        otherFriends[name] = true
                    end
                end
            end

            for _, fr in ipairs(friends) do
                local keys = UI.FriendGameKeys(fr.accounts, fr.primary)
                local keySet, keyCount = {}, 0
                local hasReal = false
                for _, key in ipairs(keys) do
                    assert(not keySet[key], "iteration " .. i .. ": duplicate key " .. show(key))
                    keySet[key] = true
                    keyCount = keyCount + 1
                    if key ~= UI.APPS_KEY then hasReal = true end
                end

                local rowSet, rowCount = rowKeysByFriend[fr.name] or {}, 0
                for key in pairs(rowSet) do
                    rowCount = rowCount + 1
                    assert(keySet[key], "iteration " .. i .. ": " .. fr.name
                        .. " is in row " .. show(key) .. " but FriendGameKeys lacks it")
                end
                assert(rowCount == keyCount, "iteration " .. i .. ": " .. fr.name .. " has "
                    .. keyCount .. " filter keys but is in " .. rowCount .. " rows")

                if hasReal then
                    assert(not appsFriends[fr.name],
                        "iteration " .. i .. ": " .. fr.name .. " has a real game but is in the @apps row")
                end
                if appsFriends[fr.name] then
                    assert(not otherFriends[fr.name],
                        "iteration " .. i .. ": " .. fr.name .. " is in @apps and another row")
                end
            end
        end
    end)

    BNGetNumFriends, C_BattleNet = savedNum, savedBN
    if not ok then error(perr, 0) end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 17: Row counts follow the presence rule
--
-- Validates: Requirements 11.6, 11.7, 11.8
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 17: Row counts follow the presence rule", function()
    local Friends, ns = loadFriends()
    ns.db = {}
    local chunk, err = loadfile("ForeverFilter/UI.lua")
    if not chunk then error("cannot load ForeverFilter/UI.lua: " .. tostring(err)) end
    chunk("ForeverFilter", ns)
    local UI = ns.UI

    local savedNum, savedBN = BNGetNumFriends, C_BattleNet
    local codes = { "WoW", "Pro", "D3", "Hero", "App", "BSAp", "CLNT", "", "nil" }
    local pids = { 1, 2, 5, 11, 14, 0, "nil" }

    local function genInfo()
        local code = pick(codes)
        if code == "nil" then code = nil end
        local pid = pick(pids)
        if pid == "nil" then pid = nil end
        return { isOnline = random() < 0.6, clientProgram = code, wowProjectID = pid }
    end

    local ok, perr = pcall(function()
        for i = 1, ITERATIONS do
            local friends = {}
            for f = 1, random(0, 8) do
                local accounts = {}
                for k = 1, random(0, 5) do accounts[k] = genInfo() end
                friends[f] = {
                    name = "friend" .. f,
                    accounts = accounts,
                    primary = random() < 0.2 and nil or genInfo(),
                }
            end

            BNGetNumFriends = function() return #friends end
            C_BattleNet = {
                GetFriendAccountInfo = function(idx)
                    local fr = friends[idx]
                    return { accountName = fr.name, gameAccountInfo = fr.primary }
                end,
                GetFriendNumGameAccounts = function(idx) return #friends[idx].accounts end,
                GetFriendGameAccountInfo = function(idx, g) return friends[idx].accounts[g] end,
            }

            -- Expected counts per key from each friend's FriendGameKeys.
            local expected, appsOnly = {}, 0
            for _, fr in ipairs(friends) do
                local keys = UI.FriendGameKeys(fr.accounts, fr.primary)
                local onlyApps = #keys > 0
                for _, key in ipairs(keys) do
                    expected[key] = (expected[key] or 0) + 1
                    if key ~= UI.APPS_KEY then onlyApps = false end
                end
                if onlyApps then appsOnly = appsOnly + 1 end
            end

            local rows = Friends.GroupByGame(Friends.GetAll())
            local seen, rowKeys = {}, 0
            for _, row in ipairs(rows) do
                local key = UI.GameKey(row.game, row.wowProjectID)
                assert(not seen[key], "iteration " .. i .. ": duplicate row " .. show(key))
                seen[key] = true
                rowKeys = rowKeys + 1
                assert(row.count == (expected[key] or 0), "iteration " .. i .. ": row " .. show(key)
                    .. " count " .. show(row.count) .. ", expected " .. show(expected[key] or 0))
                if key == UI.APPS_KEY then
                    assert(row.count == appsOnly, "iteration " .. i .. ": @apps count "
                        .. show(row.count) .. ", expected " .. appsOnly .. " apps-only friends")
                end
            end
            for key, n in pairs(expected) do
                assert(seen[key], "iteration " .. i .. ": no row for key " .. show(key)
                    .. " (" .. n .. " friends)")
            end
            if not seen[UI.APPS_KEY] then
                assert(appsOnly == 0, "iteration " .. i .. ": no @apps row but " .. appsOnly .. " apps-only friends")
            end
        end
    end)

    BNGetNumFriends, C_BattleNet = savedNum, savedBN
    if not ok then error(perr, 0) end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 18: Hide decision with apps
--
-- Validates: Requirements 11.10, 11.11, 11.12, 11.19
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 18: Hide decision with apps", function()
    local _, ns = loadFriends()
    ns.db = {}
    local chunk, err = loadfile("ForeverFilter/UI.lua")
    if not chunk then error("cannot load ForeverFilter/UI.lua: " .. tostring(err)) end
    chunk("ForeverFilter", ns)
    local UI = ns.UI

    local codes = { "WoW", "Pro", "D3", "Hero", "App", "BSAp", "CLNT", "", "nil" }
    local pids = { 1, 2, 5, 11, 14, 0, "nil" }

    local function genInfo()
        local code = pick(codes)
        if code == "nil" then code = nil end
        local pid = pick(pids)
        if pid == "nil" then pid = nil end
        return { isOnline = random() < 0.6, clientProgram = code, wowProjectID = pid }
    end

    -- Every key a friend can produce, plus the apps key.
    local keyPool = { UI.APPS_KEY }
    for _, c in ipairs(codes) do
        for _, p in ipairs(pids) do
            keyPool[#keyPool + 1] = UI.GameKey(c ~= "nil" and c or nil, p ~= "nil" and p or nil)
        end
    end

    local junk = { "yes", 0, 1, {}, "false" }
    local function genValue()
        local r = random()
        if r < 0.35 then return true end
        if r < 0.7 then return false end
        if r < 0.85 then return nil end
        return pick(junk)
    end

    for i = 1, ITERATIONS do
        local checks = {}
        for _, key in ipairs(keyPool) do checks[key] = genValue() end
        -- Bias toward the cases that decide the outcome.
        if random() < 0.3 then checks[UI.APPS_KEY] = false end
        if random() < 0.3 then checks[UI.APPS_KEY] = true end

        local function isChecked(key)
            local v = checks[key]
            if type(v) == "boolean" then return v end
            return true
        end
        local offlineChecked = pick({ true, false })

        local accounts = {}
        for k = 1, random(0, 5) do accounts[k] = genInfo() end
        local accountInfo
        local shape = random(1, 10)
        if shape == 1 then
            accountInfo = nil
        elseif shape == 2 then
            accountInfo = { gameAccountInfo = nil }
        elseif shape == 3 then
            accountInfo = { gameAccountInfo = { isOnline = "yes" } }
        else
            accountInfo = { gameAccountInfo = genInfo() }
        end

        local isOnline, keys = UI.FriendState(accountInfo, accounts)
        local hide = UI.ShouldHideBnetElement(true, isOnline, keys, isChecked, offlineChecked)

        local expected
        if isOnline == nil then
            expected = false
        elseif isOnline == false then
            expected = (offlineChecked == false)
        else
            local hasReal, allRealUnchecked = false, true
            for _, key in ipairs(keys) do
                if key ~= UI.APPS_KEY then
                    hasReal = true
                    if isChecked(key) ~= false then allRealUnchecked = false end
                end
            end
            if hasReal then
                expected = allRealUnchecked
            elseif #keys > 0 then
                expected = (isChecked(UI.APPS_KEY) == false)
            else
                expected = false
            end
        end

        assert(hide == expected, "iteration " .. i .. ": keys " .. show(keys) .. ", online "
            .. show(isOnline) .. ", apps " .. show(checks[UI.APPS_KEY]) .. ": hide "
            .. show(hide) .. ", expected " .. show(expected))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 19: Apps checked state, legacy default, and isolation
--
-- Validates: Requirements 11.13, 11.14, 11.15, 11.16
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 19: Apps checked state, legacy default, and isolation", function()
    local function deepEqual(a, b)
        if type(a) ~= "table" or type(b) ~= "table" then return rawequal(a, b) end
        for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = deepCopy(x) end
        return c
    end
    local junk = { "yes", "false", 0, 1, {}, function() end }
    -- Booleans, missing entries, and junk.
    local function genEntry()
        local r = random()
        if r < 0.35 then return true end
        if r < 0.7 then return false end
        if r < 0.85 then return nil end
        return pick(junk)
    end

    for i = 1, ITERATIONS do
        local store = {}
        for _ = 1, random(0, 4) do store[genString() .. ":" .. random(0, 20)] = random() < 0.5 end
        for _, key in ipairs({ "@apps", "App:nil", "BSAp:nil", "CLNT:nil" }) do store[key] = genEntry() end
        -- Bias toward the legacy-false case.
        if random() < 0.25 then store["App:nil"] = false; store["BSAp:nil"] = false end
        local db = { checkedGames = store }
        for _ = 1, random(0, 3) do db["extra" .. random(1, 9)] = genEntry() end

        local UI = loadUI(db)
        local before = deepCopy(store)
        local dbBefore = deepCopy(db)
        local ctx = "iteration " .. i

        local expected
        if type(before["@apps"]) == "boolean" then
            expected = before["@apps"]
        else
            expected = not (before["App:nil"] == false and before["BSAp:nil"] == false)
        end
        local got = UI.IsAppsChecked()
        assert(got == expected, string.format("%s: IsAppsChecked got %s, expected %s", ctx, tostring(got), tostring(expected)))
        assert(deepEqual(store, before), ctx .. ": IsAppsChecked changed checkedGames")
        assert(deepEqual(db, dbBefore), ctx .. ": IsAppsChecked changed the db")

        local b = random() < 0.5
        UI.SetAppsChecked(b)
        assert(UI.IsAppsChecked() == b, ctx .. ": round trip returned the wrong value")
        assert(store["@apps"] == b, ctx .. ": stored value is not the boolean written")
        for k, v in pairs(before) do
            if k ~= "@apps" then
                assert(deepEqual(store[k], v), ctx .. ": other entry changed: " .. show(k))
            end
        end
        for k in pairs(store) do
            assert(k == "@apps" or before[k] ~= nil, ctx .. ": unexpected new entry " .. show(k))
        end
        for k, v in pairs(dbBefore) do
            if k ~= "checkedGames" then
                assert(deepEqual(db[k], v), ctx .. ": db field changed: " .. show(k))
            end
        end
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Property 20: The Apps key never equals another key
--
-- Validates: Requirements 11.18
----------------------------------------------------------------------
property("Feature: friends-list-filter, Property 20: The Apps key never equals another key", function()
    local UI = loadUI({})
    assert(UI.APPS_KEY ~= UI.OFFLINE_KEY, "APPS_KEY equals OFFLINE_KEY")

    local extra = { "", "é", "日本語", "ü:1", "@apps ", "@APPS", "@offline", "apps", "@", "App", "BSAp", "WoW" }
    local function genGame()
        local r = random()
        if r < 0.4 then return genString() end
        if r < 0.6 then return pick(extra) end
        if r < 0.8 then return random(-5, 100) end
        return nil
    end
    local function genPid()
        local r = random()
        if r < 0.5 then return random(0, 20) end
        if r < 0.75 then return genString() end
        return nil
    end

    for i = 1, ITERATIONS do
        local game, pid = genGame(), genPid()
        local key = UI.GameKey(game, pid)
        assert(key ~= UI.APPS_KEY, "iteration " .. i .. ": GameKey(" .. show(game) .. ", " .. show(pid) .. ") equals APPS_KEY")
        assert(key ~= UI.OFFLINE_KEY, "iteration " .. i .. ": GameKey(" .. show(game) .. ", " .. show(pid) .. ") equals OFFLINE_KEY")
        local appsKey = UI.GameKey("@apps", pid)
        assert(appsKey == UI.APPS_KEY, "iteration " .. i .. ": GameKey(\"@apps\", " .. show(pid) .. ") returned " .. show(appsKey))
    end
end)

----------------------------------------------------------------------
-- Feature: friends-list-filter, Example tests: app presence rules
--
-- Validates: Requirements 11.2, 11.3, 11.5, 11.6, 11.7, 11.8, 11.10, 11.11, 11.12, 11.14,
-- 11.15, 11.16, 11.17
----------------------------------------------------------------------
-- Stubs BNGetNumFriends and C_BattleNet from friends = { { name, accounts, primary }, ... },
-- runs fn, and restores both globals. A friend's primary defaults to its first account.
local function withBattleNetFriends(friends, fn)
    local savedNum, savedBN = BNGetNumFriends, C_BattleNet
    BNGetNumFriends = function() return #friends end
    C_BattleNet = {
        GetFriendAccountInfo = function(i)
            local f = friends[i]
            if not f then return nil end
            return { accountName = f.name, gameAccountInfo = f.primary or f.accounts[1] }
        end,
        GetFriendNumGameAccounts = function(i) return #friends[i].accounts end,
        GetFriendGameAccountInfo = function(i, j) return friends[i].accounts[j] end,
    }
    local ok, err = pcall(fn)
    BNGetNumFriends, C_BattleNet = savedNum, savedBN
    if not ok then error(err, 0) end
end

local function appAcct(code) return { isOnline = true, clientProgram = code } end
local function gameAcct(code, pid) return { isOnline = true, clientProgram = code, wowProjectID = pid } end

-- The wowProjectID that Games.lua names "World of Warcraft: Forever".
local WOW_FOREVER = 18

property("Feature: friends-list-filter, Example tests: app presence rules, listing and hide decisions", function()
    local db = { checkedGames = {} }
    local UI, ns, Friends = loadUIWithFriends(db)
    local Games = loadGames(ns)
    assert(Games.GetGameName("WoW", WOW_FOREVER) == "World of Warcraft: Forever", "18 is not WoW Forever in Games.lua")
    assert(Games.GetGameName("@apps") == "Battle.net", "GetGameName(@apps): " .. show(Games.GetGameName("@apps")))

    local wowKey = UI.GameKey("WoW", WOW_FOREVER)
    local hsKey, sc2Key = UI.GameKey("WTCG"), UI.GameKey("S2")
    local friends = {
        { name = "ForeverAndApp", accounts = { gameAcct("WoW", WOW_FOREVER), appAcct("App") } },
        { name = "DesktopOnly", accounts = { appAcct("App") } },
        { name = "MobileOnly", accounts = { appAcct("BSAp") } },
        { name = "DesktopAndMobile", accounts = { appAcct("App"), appAcct("BSAp") } },
        { name = "TwoGamesAndApp", accounts = { appAcct("App"), gameAcct("WTCG"), gameAcct("S2") } },
    }
    local function find(name)
        for i, f in ipairs(friends) do if f.name == name then return f, i end end
    end

    local function hidden(name)
        local f = find(name)
        local isOnline, keys = UI.FriendState({ gameAccountInfo = f.primary or f.accounts[1] }, f.accounts)
        local function isChecked(key)
            if key == UI.APPS_KEY then return UI.IsAppsChecked() end
            local v = db.checkedGames[key]
            if type(v) == "boolean" then return v end
            return true
        end
        return UI.ShouldHideBnetElement(true, isOnline, keys, isChecked, true)
    end
    local function setChecked(map) db.checkedGames = map end

    withBattleNetFriends(friends, function()
        -- Listing: every friend is online, rows are keyed like the filter keys.
        local rows = Friends.GroupByGame(Friends.GetAll(), Games.GetGameName)
        local listedUnder = {}
        local appsRows = 0
        for _, row in ipairs(rows) do
            local key = UI.GameKey(row.game, row.wowProjectID)
            if key == UI.APPS_KEY then appsRows = appsRows + 1 end
            assert(row.game ~= "App" and row.game ~= "BSAp" and row.game ~= "CLNT", "a raw app row exists: " .. show(row.game))
            for _, name in ipairs(row.friends) do
                listedUnder[name] = listedUnder[name] or {}
                listedUnder[name][key] = true
            end
        end
        assert(appsRows == 1, "expected one Battle.net row, got " .. appsRows)
        local function onlyUnder(name, ...)
            local want, n = {}, 0
            for _, k in ipairs({ ... }) do want[k] = true; n = n + 1 end
            local got, m = listedUnder[name] or {}, 0
            for k in pairs(got) do
                m = m + 1
                assert(want[k], name .. " is listed under unexpected row " .. show(k))
            end
            assert(m == n, name .. " is listed under " .. m .. " rows, expected " .. n)
        end
        onlyUnder("ForeverAndApp", wowKey)
        onlyUnder("DesktopOnly", UI.APPS_KEY)
        onlyUnder("MobileOnly", UI.APPS_KEY)
        onlyUnder("DesktopAndMobile", UI.APPS_KEY)
        onlyUnder("TwoGamesAndApp", hsKey, sc2Key)
        for _, row in ipairs(rows) do
            if UI.GameKey(row.game, row.wowProjectID) == UI.APPS_KEY then
                assert(row.count == 3, "Battle.net row count " .. row.count .. ", expected 3 (desktop, mobile, both once)")
            end
        end

        -- User scenario: WoW Forever unchecked, Battle.net row checked.
        setChecked({ [wowKey] = false, [UI.APPS_KEY] = true })
        assert(hidden("ForeverAndApp") == true, "WoW Forever + app friend not hidden when WoW Forever is unchecked")
        assert(hidden("DesktopOnly") == false and hidden("MobileOnly") == false
            and hidden("DesktopAndMobile") == false, "app-only friends hidden by the WoW Forever box")
        assert(hidden("TwoGamesAndApp") == false, "two-game friend hidden by the WoW Forever box")

        -- WoW Forever checked, Battle.net row unchecked: the game friend stays, app-only friends go.
        setChecked({ [wowKey] = true, [UI.APPS_KEY] = false })
        assert(hidden("ForeverAndApp") == false, "WoW Forever + app friend follows the app row")
        assert(hidden("DesktopOnly") == true and hidden("MobileOnly") == true
            and hidden("DesktopAndMobile") == true, "app-only friends kept with the Battle.net row unchecked")
        assert(hidden("TwoGamesAndApp") == false, "two-game friend follows the app row")

        -- Everything checked: nothing hidden.
        setChecked({ [wowKey] = true, [UI.APPS_KEY] = true })
        for _, f in ipairs(friends) do assert(hidden(f.name) == false, f.name .. " hidden with everything checked") end

        -- Hearthstone, StarCraft 2 and an app: hidden only when both games are unchecked.
        setChecked({ [hsKey] = false })
        assert(hidden("TwoGamesAndApp") == false, "hidden with only Hearthstone unchecked")
        setChecked({ [sc2Key] = false })
        assert(hidden("TwoGamesAndApp") == false, "hidden with only StarCraft 2 unchecked")
        setChecked({ [hsKey] = false, [sc2Key] = false })
        assert(hidden("TwoGamesAndApp") == true, "not hidden with both games unchecked")
        setChecked({ [hsKey] = false, [sc2Key] = false, [UI.APPS_KEY] = true })
        assert(hidden("TwoGamesAndApp") == true, "the Battle.net row kept a friend whose games are unchecked")
    end)
end)

property("Feature: friends-list-filter, Example tests: app presence rules, legacy entries", function()
    -- Only App:nil false: the Apps row is checked.
    local db = { checkedGames = { ["App:nil"] = false } }
    local UI = loadUI(db)
    assert(UI.IsAppsChecked() == true, "App:nil false alone must leave the Apps row checked")
    assert(db.checkedGames["App:nil"] == false and db.checkedGames["@apps"] == nil, "IsAppsChecked wrote or deleted")

    -- Only BSAp:nil false: checked as well.
    db = { checkedGames = { ["BSAp:nil"] = false } }
    UI = loadUI(db)
    assert(UI.IsAppsChecked() == true, "BSAp:nil false alone must leave the Apps row checked")

    -- Both false: unchecked, and neither entry is deleted by reading or writing the new state.
    db = { checkedGames = { ["App:nil"] = false, ["BSAp:nil"] = false, ["CLNT:nil"] = false } }
    UI = loadUI(db)
    assert(UI.IsAppsChecked() == false, "both legacy entries false must give an unchecked Apps row")
    assert(db.checkedGames["@apps"] == nil, "reading wrote @apps")
    UI.SetAppsChecked(true)
    assert(UI.IsAppsChecked() == true and db.checkedGames["@apps"] == true, "SetAppsChecked(true) not stored")
    UI.SetAppsChecked(false)
    assert(db.checkedGames["@apps"] == false, "SetAppsChecked(false) not stored")
    assert(db.checkedGames["App:nil"] == false and db.checkedGames["BSAp:nil"] == false
        and db.checkedGames["CLNT:nil"] == false, "a legacy entry was deleted or changed")

    -- A stored @apps boolean wins over the legacy entries.
    db = { checkedGames = { ["@apps"] = true, ["App:nil"] = false, ["BSAp:nil"] = false } }
    UI = loadUI(db)
    assert(UI.IsAppsChecked() == true, "@apps true must beat the legacy entries")
end)

property("Feature: friends-list-filter, Example tests: app presence rules, window row, click and Reset", function()
    local friends = {
        { name = "ForeverFriend", accounts = { gameAcct("WoW", WOW_FOREVER) } },
        { name = "DesktopOnly", accounts = { appAcct("App") } },
        { name = "MobileOnly", accounts = { appAcct("BSAp") } },
    }
    withBattleNetFriends(friends, function()
        withOptions(function(env, ctx)
            local db = env.ns.db
            db.showPlayerCounts = false
            loadModule("Friends", env.ns)
            loadModule("Games", env.ns)
            env.reapplies = {}
            env.ns.Filter = { Reapply = function() env.reapplies[#env.reapplies + 1] = true end }
            env.UI.Show()

            local checks = {}
            for _, f in ipairs(ctx.created) do
                if f.kind == "CheckButton" and f.template == "UICheckButtonTemplate" and f.shown then
                    checks[#checks + 1] = f
                end
            end
            local function textOf(check)
                for _, fs in ipairs(env.fontStrings) do
                    for _, c in ipairs(fs.calls) do
                        if c[1] == "SetPoint" and c[3] == check then return rawget(fs, "text") end
                    end
                end
            end
            local labels, appsCheck, battlenetRows = {}, nil, 0
            for _, c in ipairs(checks) do
                local t = textOf(c)
                labels[#labels + 1] = tostring(t)
                assert(not tostring(t):find("Mobile"), "a Battle.net Mobile row exists: " .. tostring(t))
                if t == "Battle.net" then battlenetRows = battlenetRows + 1; appsCheck = c end
            end
            assert(#checks == 3, "expected WoW Forever, Battle.net and Offline rows, got: " .. table.concat(labels, "; "))
            assert(battlenetRows == 1 and appsCheck, "expected one Battle.net row, got: " .. table.concat(labels, "; "))
            assert(appsCheck.checked == true, "Apps row not checked by default")

            -- Clicking the Apps row writes checkedGames["@apps"] and then calls Reapply.
            local seen
            env.ns.Filter.Reapply = function()
                env.reapplies[#env.reapplies + 1] = true
                seen = db.checkedGames["@apps"]
            end
            appsCheck.checked = false
            appsCheck.scripts.OnClick(appsCheck)
            assert(db.checkedGames["@apps"] == false, "click did not write checkedGames[@apps]")
            assert(#env.reapplies == 1 and seen == false, "click did not call Reapply after the write")
            for k in pairs(db.checkedGames) do
                assert(k == "@apps", "click wrote an extra key " .. show(k))
            end

            -- Reset to defaults leaves checkedGames["@apps"] unchanged and does not call Reapply.
            local gear = ctx.find("Button", env.win)
            gear.scripts.OnClick(gear)
            local p = ctx.parts()
            env.reapplies = {}
            p.reset.scripts.OnClick(p.reset)
            assert(db.checkedGames["@apps"] == false, "Reset changed checkedGames[@apps]")
            assert(#env.reapplies == 0, "Reset called Reapply")
        end)
    end)
end)

property("Feature: friends-list-filter, Example tests: app presence rules, classic hook", function()
    local T_DIVIDER, T_WOW, T_BNET = 1, 2, 3
    local globalNames = { "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue", "BNGetNumFriends" }
    local saved = {}
    for _, n in ipairs(globalNames) do saved[n] = _G[n] end

    local friends = {
        { accounts = { appAcct("BSAp") } },                              -- 1: mobile app only
        { accounts = { gameAcct("WoW", WOW_FOREVER), appAcct("App") } }, -- 2: WoW Forever and the app
        { accounts = { appAcct("App") } },                               -- 3: desktop app only
        { accounts = { gameAcct("D3"), appAcct("BSAp") } },              -- 4: Diablo III and the app
    }
    FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
    issecretvalue = function() return false end
    print = function() end
    BNGetNumFriends = function() return #friends, #friends end
    C_BattleNet = {
        GetFriendAccountInfo = function(i)
            local f = friends[i]
            return f and { gameAccountInfo = f.primary or f.accounts[1] } or nil
        end,
        GetFriendNumGameAccounts = function(i) return #friends[i].accounts end,
        GetFriendGameAccountInfo = function(i, j) return friends[i].accounts[j] end,
    }

    local hooks = {}
    local scrollBox = setmetatable({}, { __index = function() return function() end end })
    function scrollBox:SetDataProvider(p)
        self.provider = p
        for _, fn in ipairs(hooks) do fn(self, p) end
    end
    function scrollBox:GetDataProvider() return self.provider end
    local function newProvider()
        local p = { collection = {} }
        for i = 1, #friends do p.collection[i] = { buttonType = T_BNET, id = i } end
        function p:GetCollection() return self.collection end
        function p:GetSize() return #self.collection end
        function p:Flush() self.collection = {} end
        function p:InsertTable(t) for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end end
        return p
    end
    local function ids(p)
        local out = {}
        for i, e in ipairs(p:GetCollection()) do out[i] = tostring(e.id) end
        return table.concat(out, ",")
    end

    local Filter, ns, restore = loadFilter({
        hooksecurefunc = function(_, _, fn) hooks[#hooks + 1] = fn end,
        CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end,
        FriendsListFrame = { ScrollBox = scrollBox, IsShown = function() return true end },
    })
    ns.db = { checkedGames = {} }
    local ok, err = pcall(function()
        Filter.Install()
        local function run(map)
            ns.db.checkedGames = map
            local p = newProvider()
            scrollBox:SetDataProvider(p)
            return ids(p)
        end
        assert(run({}) == "1,2,3,4", "everything checked changed the list")
        -- Apps row unchecked: app-only friends go, friends in a game follow the game.
        local got = run({ ["@apps"] = false })
        assert(got == "2,4", "Apps row unchecked: " .. got)
        -- Apps row unchecked and WoW Forever unchecked: the WoW friend goes as well.
        got = run({ ["@apps"] = false, [ns.UI.GameKey("WoW", WOW_FOREVER)] = false })
        assert(got == "4", "Apps and WoW Forever unchecked: " .. got)
        -- WoW Forever unchecked, Battle.net row checked: only the WoW friend goes.
        got = run({ [ns.UI.GameKey("WoW", WOW_FOREVER)] = false, ["@apps"] = true })
        assert(got == "1,3,4", "WoW Forever unchecked, Battle.net checked: " .. got)
        -- Diablo III unchecked: the friend in Diablo III and the app goes.
        got = run({ [ns.UI.GameKey("D3")] = false })
        assert(got == "1,2,3", "Diablo III unchecked: " .. got)
        -- Legacy entries only (both false, no @apps): the Apps row shows unchecked, so app-only friends go.
        got = run({ ["App:nil"] = false, ["BSAp:nil"] = false })
        assert(got == "2,4", "legacy App:nil and BSAp:nil false: " .. got)
        -- Only one legacy entry false: the Apps row is checked, nothing goes.
        got = run({ ["App:nil"] = false })
        assert(got == "1,2,3,4", "legacy App:nil false alone: " .. got)
    end)
    restore()
    for _, n in ipairs(globalNames) do _G[n] = saved[n] end
    if not ok then error(err, 0) end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 1: NameQuery trims whitespace and rejects non-strings
-- Validates: Requirements 3.5, 3.6, 7.1, 7.2
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 1: NameQuery trims whitespace and rejects non-strings", function()
    local UI = loadUI({})
    local WS = { " ", "\t", "\n", "\r", "\v", "\f" }
    local WS_SET = {}
    for _, c in ipairs(WS) do WS_SET[c] = true end

    local function genPad()
        local t = {}
        for j = 1, random(0, 10) do t[j] = pick(WS) end
        return table.concat(t)
    end

    -- Core: any string that does not start or end with whitespace, interior whitespace allowed.
    local function genCore()
        local s = genString()
        local a, b = 1, #s
        while a <= b and WS_SET[s:sub(a, a)] do a = a + 1 end
        while b >= a and WS_SET[s:sub(b, b)] do b = b - 1 end
        s = s:sub(a, b)
        if random() < 0.3 and s ~= "" then
            s = s .. pick(WS) .. "x" .. pick(WS) .. "y"
        end
        return s
    end

    local nonStrings = { 0, 1.5, -3, true, false, {}, { "x" }, function() end }

    for i = 1, ITERATIONS do
        local core = genCore()
        local input = genPad() .. core .. genPad()
        local ok, got = pcall(UI.NameQuery, input)
        assert(ok, "NameQuery raised for " .. show(input) .. ": " .. tostring(got))
        assert(got == core, string.format("NameQuery(%s) = %s, expected %s", show(input), show(got), show(core)))

        -- Whitespace-only input gives "".
        local blank = genPad()
        assert(UI.NameQuery(blank) == "", "whitespace-only gave non-empty for " .. show(blank))

        -- Non-string input gives "" without raising.
        local v = pick(nonStrings)
        local ok2, got2 = pcall(UI.NameQuery, v)
        assert(ok2, "NameQuery raised for " .. type(v) .. ": " .. tostring(got2))
        assert(got2 == "", "non-string " .. type(v) .. " gave " .. show(got2))
    end

    assert(UI.NameQuery(nil) == "")
    assert(UI.NameQuery() == "")
    assert(UI.NameQuery("") == "")
    assert(UI.NameQuery("  a b  ") == "a b")
end)

----------------------------------------------------------------------
-- Generators for name matching: pattern characters, ASCII and non-ASCII letters.
----------------------------------------------------------------------
local NAME_PIECES = { "%", ".", "[", "]", "(", ")", "*", "+", "-", "?", "^", "$", "%a", "[a-z]", ".*",
    "É", "é", "a", "A", "b", "B", "z", "Z", "Ann", "bob", "#1234", " ", "0", "_" }

local function genNameText()
    local r = random()
    if r < 0.05 then return "" end
    local t = {}
    for i = 1, random(1, 5) do t[i] = pick(NAME_PIECES) end
    return table.concat(t)
end

-- A list with strings (some derived from a query), empty strings, non-strings and nil holes.
local function genNameList(query)
    local list = {}
    local n = random(0, 8)
    for i = 1, n do
        local r = random()
        if r < 0.45 then list[i] = genNameText()
        elseif r < 0.55 and type(query) == "string" then
            -- a name that contains the query, possibly with changed ASCII case
            local s = genNameText() .. query .. genNameText()
            if random() < 0.5 then s = s:upper() end
            list[i] = s
        elseif r < 0.62 then list[i] = ""
        elseif r < 0.72 then list[i] = pick({ 0, 1.5, -3, 42 })
        elseif r < 0.8 then list[i] = pick({ true, false })
        elseif r < 0.88 then list[i] = {}
        elseif r < 0.92 then list[i] = function() end
        end -- else leave a nil hole
    end
    return list
end

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 2: NameMatch is a plain, ASCII case-insensitive substring test
-- Validates: Requirements 3.2, 3.3, 3.4, 3.9, 7.3, 7.4, 7.5, 7.6, 7.8
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 2: NameMatch is a plain, ASCII case-insensitive substring test", function()
    local UI = loadUI({})

    -- Independent oracle: byte loops only, no string.find, no patterns.
    local function lowerAscii(s)
        local out = {}
        for i = 1, #s do
            local b = s:byte(i)
            if b >= 65 and b <= 90 then b = b + 32 end
            out[i] = string.char(b)
        end
        return table.concat(out)
    end
    local function contains(hay, needle)
        for start = 1, #hay - #needle + 1 do
            local same = true
            for k = 1, #needle do
                if hay:byte(start + k - 1) ~= needle:byte(k) then same = false; break end
            end
            if same then return true end
        end
        return false
    end
    local function oracle(query, list)
        if type(query) ~= "string" or query == "" or type(list) ~= "table" then return false end
        local q = lowerAscii(query)
        local top = 0
        for k in pairs(list) do
            if type(k) == "number" and k > top then top = k end
        end
        for i = 1, top do
            local name = list[i]
            if type(name) == "string" and name ~= "" and contains(lowerAscii(name), q) then
                return true
            end
        end
        return false
    end

    local function copyList(list)
        local c = {}
        for k, v in pairs(list) do c[k] = v end
        return c
    end

    for i = 1, ITERATIONS do
        local query = genNameText()
        local list = genNameList(query)
        local before = copyList(list)

        local ok, got = pcall(UI.NameMatch, query, list)
        assert(ok, "NameMatch raised for " .. show(query) .. ": " .. tostring(got))
        assert(type(got) == "boolean", "NameMatch returned " .. type(got))
        local want = oracle(query, list)
        assert(got == want, string.format("NameMatch(%s, ...) = %s, oracle %s", show(query), tostring(got), tostring(want)))

        -- Arguments unchanged.
        for k, v in pairs(before) do assert(rawequal(list[k], v), "list entry changed at " .. tostring(k)) end
        for k in pairs(list) do assert(before[k] ~= nil, "list gained key " .. tostring(k)) end

        -- Non-ASCII case differences do not match; ASCII case differences do.
        assert(UI.NameMatch("É", { "xéx" }) == false, "É matched é")
        assert(UI.NameMatch("é", { "xÉx" }) == false, "é matched É")

        -- A pattern-heavy query against a name built from it matches literally.
        local q2 = pick({ "%", ".", "[a-z]", "(", "a+", "^a", "a$", "-", "%a", ".*" })
        assert(UI.NameMatch(q2, { "pre" .. q2 .. "post" }) == true, "literal " .. q2 .. " not found")

        -- Non-table lists and non-string queries give false.
        local junk = pick({ 0, 1.5, true, false, "str", function() end })
        assert(UI.NameMatch(query, junk) == false, "non-table list gave true")
        assert(UI.NameMatch(junk, list) == false or type(junk) == "string", "non-string query gave true")
        assert(UI.NameMatch(nil, list) == false, "nil query gave true")
        assert(UI.NameMatch(query, nil) == false, "nil list gave true")
    end

    -- Edge cases.
    assert(UI.NameMatch("a", {}) == false)
    assert(UI.NameMatch("a", { 1, true, {} }) == false)
    assert(UI.NameMatch("", { "a" }) == false)
    assert(UI.NameMatch("A", { "a" }) == true)
    assert(UI.NameMatch("b", { nil, nil, "abc" }) == true, "nil hole stopped the scan")
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 3: A name matches itself
-- Validates: Requirements 7.7
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 3: A name matches itself", function()
    local UI = loadUI({})

    for i = 1, ITERATIONS do
        local name = genNameText()
        if name == "" then name = "x" .. name end

        assert(UI.NameMatch(name, { name }) == true, "name did not match itself: " .. show(name))

        -- Still matches when surrounded by other entries, junk and nil holes.
        local list = genNameList(nil)
        local pos = random(1, #list + 1)
        table.insert(list, pos, name)
        assert(UI.NameMatch(name, list) == true, "name did not match itself in a mixed list: " .. show(name))

        -- Also in its upper-case and lower-case ASCII forms.
        local asciiOnly = not name:find("[\128-\255]")
        if asciiOnly then
            assert(UI.NameMatch(name:upper(), { name }) == true, "upper-case name missed: " .. show(name))
            assert(UI.NameMatch(name:lower(), { name }) == true, "lower-case name missed: " .. show(name))
        end

        -- A trimmed query built from the name matches the name when it is non-empty.
        local q = UI.NameQuery(name)
        if q ~= "" then
            assert(UI.NameMatch(q, { name }) == true, "trimmed name missed: " .. show(name))
        end
    end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 4: NameMatch is invariant under ASCII case changes
-- Validates: Requirements 3.3, 7.8
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 4: NameMatch is invariant under ASCII case changes", function()
    local UI = loadUI({})

    -- Flips the case of random ASCII letters only; every other byte is kept.
    local function flipAscii(s)
        return (s:gsub("%a", function(c)
            if random() < 0.5 then
                return c:find("%u") and c:lower() or c:upper()
            end
        end))
    end

    local function flipList(list)
        local out = {}
        for i = 1, table.maxn(list) do
            local v = list[i]
            if type(v) == "string" then v = flipAscii(v) end
            out[i] = v
        end
        return out
    end

    for i = 1, ITERATIONS do
        local query = genNameText()
        local list = genNameList(query)
        local base = UI.NameMatch(query, list)

        local q2, l2 = flipAscii(query), flipList(list)
        assert(UI.NameMatch(q2, list) == base,
            "query case change altered result: " .. show(query) .. " -> " .. show(q2))
        assert(UI.NameMatch(query, l2) == base,
            "name case change altered result for query " .. show(query))
        assert(UI.NameMatch(q2, l2) == base,
            "both case changes altered result: " .. show(query) .. " -> " .. show(q2))
        assert(UI.NameMatch(query:upper(), list) == UI.NameMatch(query:lower(), list) or query:find("[\128-\255]"),
            "upper/lower query differ for ASCII query " .. show(query))
    end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 5: Whitespace around the query does not change the result
-- Validates: Requirements 7.9
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 5: Whitespace around the query does not change the result", function()
    local UI = loadUI({})
    local WS = { " ", "\t", "\n", "\r", "\v", "\f" }

    local function genPad()
        local t = {}
        for k = 1, random(1, 10) do t[k] = pick(WS) end
        return table.concat(t)
    end

    for i = 1, ITERATIONS do
        local q = genNameText()
        local list = genNameList(q)
        local padded = genPad() .. q .. genPad()

        local want = UI.NameMatch(UI.NameQuery(q), list)
        local got = UI.NameMatch(UI.NameQuery(padded), list)
        assert(got == want, string.format("padding changed result for %s: %s vs %s",
            show(q), tostring(got), tostring(want)))

        -- Padding on one side only.
        assert(UI.NameMatch(UI.NameQuery(genPad() .. q), list) == want, "leading padding changed result for " .. show(q))
        assert(UI.NameMatch(UI.NameQuery(q .. genPad()), list) == want, "trailing padding changed result for " .. show(q))
    end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 6: Invalid entries do not change the result
-- Validates: Requirements 3.9, 7.4
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 6: Invalid entries do not change the result", function()
    local UI = loadUI({})

    -- nil is represented by a skipped slot (a hole).
    local function genJunk()
        local r = random(6)
        if r == 1 then return nil
        elseif r == 2 then return ""
        elseif r == 3 then return pick({ 0, 1.5, -3, 42 })
        elseif r == 4 then return pick({ true, false })
        elseif r == 5 then return {}
        else return function() end end
    end

    -- Copies list, adding junk before, between and after the original entries.
    local function withJunk(list)
        local out, n = {}, 0
        local function addJunk()
            for _ = 1, random(0, 3) do
                n = n + 1
                out[n] = genJunk()
            end
        end
        addJunk()
        for i = 1, table.maxn(list) do
            n = n + 1
            out[n] = list[i]
            addJunk()
        end
        return out
    end

    for i = 1, ITERATIONS do
        local query = genNameText()
        local list = genNameList(query)
        local want = UI.NameMatch(query, list)
        local got = UI.NameMatch(query, withJunk(list))
        assert(got == want, string.format("junk changed result for %s: %s vs %s",
            show(query), tostring(got), tostring(want)))

        -- Junk only: never a match.
        local onlyJunk = {}
        for k = 1, random(0, 6) do onlyJunk[k] = genJunk() end
        assert(UI.NameMatch(query, onlyJunk) == false, "junk-only list matched " .. show(query))
    end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 7: The name decision hides unless the query is empty or a name matches
-- Validates: Requirements 3.1, 3.2, 3.6, 6.3
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 7: The name decision hides unless the query is empty or a name matches", function()
    local UI = loadUI({})

    -- Independent oracle: plain substring over ASCII-lowered valid entries.
    local function lower(s) return (s:gsub("%u", function(c) return c:lower() end)) end
    local function oracleMatch(q, list)
        local lq = lower(q)
        for i = 1, table.maxn(list) do
            local n = list[i]
            if type(n) == "string" and n ~= "" and lower(n):find(lq, 1, true) then return true end
        end
        return false
    end

    for i = 1, ITERATIONS do
        -- Empty and non-string queries never hide, whatever the names are.
        local list = genNameList(genNameText())
        local noQuery = pick({ "", "", false, 0, {}, true })
        assert(UI.NameFilterHides(nil, list) == false, "nil query hid")
        assert(UI.NameFilterHides(noQuery, list) == false, "empty/non-string query hid")
        assert(UI.NameFilterHides("", nil) == false, "empty query with nil names hid")
        assert(UI.NameFilterHides("", {}) == false, "empty query with no names hid")

        -- Non-empty query: hidden exactly when no name matches.
        local query = genNameText()
        if query == "" then query = "q" end
        local names = genNameList(query)
        local got = UI.NameFilterHides(query, names)
        assert(type(got) == "boolean", "result is not a boolean")
        local want = not oracleMatch(query, names)
        assert(got == want, string.format("query %s: got %s want %s", show(query), tostring(got), tostring(want)))
        assert(got == not UI.NameMatch(query, names), "disagrees with NameMatch")

        -- No usable names (nil, non-table, empty, junk only) hides a non-empty query.
        assert(UI.NameFilterHides(query, nil) == true, "nil names did not hide")
        assert(UI.NameFilterHides(query, "text") == true, "non-table names did not hide")
        assert(UI.NameFilterHides(query, { "", false, 7 }) == true, "junk-only names did not hide")

        -- A name containing the query keeps the friend.
        assert(UI.NameFilterHides(query, { "x" .. query .. "y" }) == false, "containing name hid")
    end
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Task 1.9: Example tests for matching
-- Validates: Requirements 3.3, 3.4, 7.5, 7.8, 7.10
----------------------------------------------------------------------
property("Feature: name-filter-input, Task 1.9: Example tests for matching", function()
    local UI = loadUI({})

    -- One case per pattern character. Each query is plain text: it matches a name that holds
    -- it literally, and does not match a name that a Lua pattern reading of it would match.
    local cases = {
        { char = "%", query = "%a",  hit = "50%a",  miss = "abc" },
        { char = ".", query = "a.c", hit = "xa.cx", miss = "abc" },
        { char = "[", query = "[a", hit = "x[ay",   miss = "a" },
        { char = "]", query = "a]", hit = "xa]y",   miss = "a" },
        { char = "(", query = "(a", hit = "x(ay",   miss = "a" },
        { char = ")", query = "a)", hit = "xa)y",   miss = "a" },
        { char = "*", query = "a*", hit = "xa*y",   miss = "aaa" },
        { char = "+", query = "a+", hit = "xa+y",   miss = "aaa" },
        { char = "-", query = "a-", hit = "xa-y",   miss = "aaa" },
        { char = "?", query = "a?", hit = "xa?y",   miss = "ab" },
        { char = "^", query = "^a", hit = "x^ay",   miss = "ab" },
        { char = "$", query = "a$", hit = "xa$y",   miss = "ba" },
    }
    for _, c in ipairs(cases) do
        assert(UI.NameMatch(c.char, { "x" .. c.char .. "y" }) == true, "lone " .. c.char .. " did not match itself")
        assert(UI.NameMatch(c.char, { "plain" }) == false, "lone " .. c.char .. " matched a name without it")
        assert(UI.NameMatch(c.query, { c.hit }) == true, "literal " .. c.query .. " did not match " .. c.hit)
        assert(UI.NameMatch(c.query, { c.miss }) == false, "pattern reading of " .. c.query .. " matched " .. c.miss)
        assert(UI.NameMatch(c.query, { "zzz", c.hit }) == true, c.query .. " missed a later name")
    end

    -- ASCII letters fold, non-ASCII letters do not.
    assert(UI.NameMatch("A", { "a" }) == true, "A did not match a")
    assert(UI.NameMatch("a", { "A" }) == true, "a did not match A")
    assert(UI.NameMatch("\195\137", { "\195\169" }) == false, "E-acute matched e-acute")
    assert(UI.NameMatch("\195\137", { "\195\137" }) == true, "E-acute did not match itself")

    -- A non-table list is never a match.
    for _, bad in ipairs({ "a", 1, true, false }) do
        assert(UI.NameMatch("a", bad) == false, "non-table list matched: " .. tostring(bad))
    end
    assert(UI.NameMatch("a", nil) == false, "nil list matched")
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 11: Typing never changes saved variables
--
-- Validates: Requirements 5.3, 5.4
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 11: Typing never changes saved variables", function()
    local function deepCopy(v, seen)
        if type(v) ~= "table" then return v end
        seen = seen or {}
        if seen[v] then return seen[v] end
        local c = {}
        seen[v] = c
        for k, x in pairs(v) do c[deepCopy(k, seen)] = deepCopy(x, seen) end
        return c
    end
    local function deepEqual(a, b)
        if type(a) ~= "table" or type(b) ~= "table" then return rawequal(a, b) end
        for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local function genDbValue(depth)
        local r = random()
        if depth < 2 and r < 0.3 then
            local t = {}
            for i = 1, random(0, 4) do t[genString() .. i] = genDbValue(depth + 1) end
            return t
        end
        if r < 0.5 then return random() < 0.5 end
        if r < 0.75 then return random(-100, 100) end
        return genString()
    end

    local savedGlobal = ForeverFilterDB
    for i = 1, ITERATIONS do
        local db = {
            checkedGames = { WoW = random() < 0.5, D3 = random() < 0.5 },
            offlineChecked = random() < 0.5,
            window = { left = random(0, 500), top = random(0, 500), scale = 1 },
            extra = genDbValue(0),
        }
        ForeverFilterDB = db
        local before = deepCopy(db)

        local UI, ns = loadUI(db)
        local calls = 0
        ns.Filter = { Reapply = function() calls = calls + 1 end }

        local nTyped = random(1, 6)
        for _ = 1, nTyped do
            local text
            local r = random()
            if r < 0.15 then text = pick({ nil, false, 0, {}, true })
            else text = genNameText() end
            UI.OnNameChanged(text)
        end

        assert(ForeverFilterDB == db, "ForeverFilterDB was replaced")
        assert(ns.db == db, "ns.db was replaced")
        assert(deepEqual(before, db), "saved variables changed by typing")
        assert(calls == nTyped, "Reapply not called once per change")

        -- Without a Filter module, typing still leaves the saved data alone.
        ns.Filter = nil
        UI.OnNameChanged(genNameText())
        assert(deepEqual(before, db), "saved variables changed when Filter is absent")
    end
    ForeverFilterDB = savedGlobal
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Example tests for the window
--
-- Validates: Requirements 1.1, 1.2, 2.1, 2.3, 2.4, 2.5, 2.6, 2.7, 5.1, 5.5
----------------------------------------------------------------------
property("Feature: name-filter-input, Example tests: Name label, edit box, heading, layout and session text", function()
    local saved = { CreateFrame = CreateFrame, UIParent = UIParent }

    -- Recording frame with script storage and edit box text state.
    local frames = {}
    local function recFrame(name, kind)
        local f = { calls = {}, name = name, kind = kind, scripts = {}, hooks = {}, text = "" }
        local fixed = {
            IsShown = true, GetLeft = 100, GetTop = 500, GetWidth = 300,
            GetHeight = 1080, GetStringHeight = 14, GetChecked = true, GetStringWidth = 100,
        }
        local absent = { TitleText = true, TitleContainer = true, InsetBg = true }
        setmetatable(f, { __index = function(t, key)
            if absent[key] then return nil end
            return function(self, ...)
                t.calls[#t.calls + 1] = { key, ... }
                if key == "CreateFontString" then return recFrame(nil, "FontString") end
                if key == "CreateTexture" then return recFrame() end
                if key == "SetText" then t.text = (...) end
                if key == "GetText" then return t.text end
                if key == "SetScript" then t.scripts[(...)] = select(2, ...) end
                if key == "HookScript" then
                    t.hooks[(...)] = t.hooks[(...)] or {}
                    table.insert(t.hooks[(...)], (select(2, ...)))
                end
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
    local function fire(f, event)
        if f.scripts[event] then f.scripts[event](f) end
        for _, h in ipairs(f.hooks[event] or {}) do h(f) end
    end
    local function hasText(t)
        for _, f in ipairs(frames) do
            if f.kind == "FontString" then
                for _, c in ipairs(callsOf(f, "SetText")) do
                    if c[2] == t then return true end
                end
            end
        end
        return false
    end

    local ok, err = pcall(function()
        local mainFrame, scroll, box, content
        CreateFrame = function(kindName, name, parent)
            local f = recFrame(name, kindName)
            if name == "ForeverFilterFrame" then mainFrame = f end
            if name == "ForeverFilterScrollFrame" then scroll = f end
            if kindName == "EditBox" and not box then box = f end
            if kindName == "Frame" and not name and scroll and parent == scroll and not content then content = f end
            return f
        end
        UIParent = recFrame("UIParent")
        UIParent.GetWidth = function() return 1920 end

        local UI, ns = loadUI({})
        loadFriends(ns)
        ns.Games = nil
        local entries = {} -- zero game rows
        ns.Friends.GetAll = function() return entries end
        ns.Filter = nil

        -- A fresh load starts with an empty query (session only).
        assert(UI.GetNameQuery() == "", "fresh load has a non-empty query")

        UI.Show()
        assert(mainFrame and box and scroll, "window, edit box or scroll frame was not created")

        -- Requirements 1.1, 1.2: label "Name", heading "Game Filter", also with zero game rows.
        assert(hasText("Name"), "no Name label")
        assert(hasText("Game Filter"), "no Game Filter heading with zero game rows")

        -- Requirement 2.1 and 2.3 (limits and initial text).
        local ml = callsOf(box, "SetMaxLetters")
        assert(#ml == 1 and ml[1][2] == 64, "SetMaxLetters(64) not called once")
        assert(box.text == "", "initial text is not empty: " .. tostring(box.text))
        assert(#callsOf(box, "SetAutoFocus") == 1 and callsOf(box, "SetAutoFocus")[1][2] == false,
            "SetAutoFocus(false) not called")

        -- Requirements 2.4, 2.5: Escape and Enter clear focus and keep the text.
        for _, event in ipairs({ "OnEscapePressed", "OnEnterPressed" }) do
            box.text = "keep me"
            box.calls = {}
            assert(type(box.scripts[event]) == "function", event .. " handler missing")
            box.scripts[event](box)
            assert(#callsOf(box, "ClearFocus") == 1, event .. " did not call ClearFocus once")
            assert(#callsOf(box, "SetText") == 0 and box.text == "keep me", event .. " changed the text")
        end
        box.text = ""

        -- Requirements 2.6, 2.7: window height is 66 + topArea + rowArea; scroll offset has the top area.
        local topArea = 28 + 20
        local rowArea
        local function checkLayout(label)
            local cs = callsOf(content, "SetHeight")
            rowArea = cs[#cs][2]
            local hs = callsOf(mainFrame, "SetHeight")
            assert(hs[#hs][2] == 66 + topArea + rowArea, string.format("%s: height %s ~= 66 + %d + %d",
                label, tostring(hs[#hs][2]), topArea, rowArea))
            local top
            for _, c in ipairs(callsOf(scroll, "SetPoint")) do
                if c[2] == "TOPLEFT" then top = c end
            end
            assert(top and top[6] == -(8 + topArea), label .. ": scroll top offset is " .. tostring(top and top[6]))
        end
        checkLayout("zero game rows")

        entries = {}
        for i = 1, 5 do entries[i] = { name = "F" .. i, isOnline = true, game = "G" .. i } end
        UI.Refresh()
        checkLayout("five game rows")

        -- Requirement 5.1: OnTextChanged calls Filter.Reapply once.
        local reapplies = 0
        ns.Filter = { Reapply = function() reapplies = reapplies + 1 end }
        box.text = "ann"
        box.scripts.OnTextChanged(box)
        assert(reapplies == 1, "Reapply called " .. reapplies .. " times")
        assert(UI.GetNameQuery() == "ann", "typed text not stored")

        -- Requirement 5.5: the text survives hide and show.
        fire(mainFrame, "OnHide")
        assert(box.text == "ann" and UI.GetNameQuery() == "ann", "text lost on hide")
        fire(mainFrame, "OnShow")
        assert(box.text == "ann" and UI.GetNameQuery() == "ann", "text lost on show")
        assert(#callsOf(box, "SetText") == 0 or box.text == "ann", "hide/show reset the edit box")

        -- A fresh load of UI.lua has an empty query again.
        local UI2 = loadUI({})
        assert(UI2.GetNameQuery() == "", "second fresh load has a non-empty query")
    end)

    CreateFrame = saved.CreateFrame
    UIParent = saved.UIParent
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 8: Filtering combines the game decision and the name decision
--
-- Validates: Requirements 3.1, 3.2, 3.7, 3.8, 4.1, 4.2, 4.3, 4.4, 4.5, 5.2, 6.1, 6.2, 6.3
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 8: Filtering combines the game decision and the name decision", function()
    local T_DIVIDER, T_WOW, T_BNET, T_INVITE_HEADER, T_INVITE = 1, 2, 3, 4, 5
    local SECRET = {}
    local globalNames = { "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue" }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end

    local namePool = { "Ann", "ann", "ANNA", "Bob#1234", "Zoë", "zoË", "a.b", "a%b", "[x]", "(y)", "^$", "a*b+c-d?",
        "Stormrage", "Area 52", "Raiding Karazhan", "Élan", "x" }
    local programs = { "WoW", "D3", "WTCG" }

    -- A name field: nil, empty, number, boolean, secret, or a string.
    local function genNameField()
        local r = random(20)
        if r <= 4 then return nil end
        if r == 5 then return "" end
        if r == 6 then return random(100) end
        if r == 7 then return true end
        if r == 8 then return SECRET end
        return pick(namePool)
    end

    local function genFriend()
        local f = { nilAccount = random() < 0.05, games = {} }
        f.online = random() < 0.7
        if f.online then
            for g = 1, random(1, 2) do
                f.games[g] = { isOnline = true, clientProgram = pick(programs) }
            end
        else
            f.games[1] = { isOnline = false, clientProgram = pick(programs) }
        end
        for _, info in ipairs(f.games) do
            info.characterName, info.realmName, info.richPresence = genNameField(), genNameField(), genNameField()
        end
        f.accountName, f.battleTag = genNameField(), genNameField()
        return f
    end

    local function lower(s) return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)) end
    local function readable(list, v)
        if type(v) == "string" and v ~= "" then list[#list + 1] = v end
    end
    local function friendNames(f)
        local names = {}
        if not f.nilAccount then readable(names, f.accountName); readable(names, f.battleTag) end
        for _, info in ipairs(f.games) do
            readable(names, info.characterName); readable(names, info.realmName); readable(names, info.richPresence)
        end
        return names
    end
    local function flipCase(s)
        return (s:gsub("%a", function(c) return random() < 0.5 and c:upper() or c:lower() end))
    end

    local ok, err = pcall(function()
        FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
        issecretvalue = function(v) return v == SECRET end
        print = function() end

        local friends
        C_BattleNet = {
            GetFriendAccountInfo = function(i)
                local f = friends[i]
                if not f or f.nilAccount then return nil end
                return { accountName = f.accountName, battleTag = f.battleTag, gameAccountInfo = f.games[1] }
            end,
            GetFriendNumGameAccounts = function(i) return #friends[i].games end,
            GetFriendGameAccountInfo = function(i, j) return friends[i].games[j] end,
        }

        local Filter, ns, restore = loadFilter({})
        local ok2, err2 = pcall(function()
            local UI = ns.UI
            local function newProvider(list)
                local p = { collection = {} }
                for i, e in ipairs(list) do p.collection[i] = e end
                function p:GetCollection() return self.collection end
                function p:GetSize() return #self.collection end
                function p:Flush() self.collection = {} end
                function p:InsertTable(t) for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end end
                return p
            end

            for i = 1, ITERATIONS do
                friends = {}
                for k = 1, random(0, 8) do friends[k] = genFriend() end

                -- Saved check state: each game and the Offline row unchecked with some probability.
                local checked = {}
                for _, prog in ipairs(programs) do
                    if random() < 0.4 then checked[UI.GameKey(prog)] = false end
                end
                if random() < 0.4 then checked[UI.OFFLINE_KEY] = false end
                ns.db = { checkedGames = checked }

                -- Element list: Battle.net friends, non-Battle.net friends, dividers and invites in random order.
                local elements = {}
                for k = 1, #friends do elements[#elements + 1] = { buttonType = T_BNET, id = k } end
                for k = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_WOW, id = 100 + k } end
                for _ = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_DIVIDER, id = "d" } end
                if random() < 0.3 then elements[#elements + 1] = { buttonType = T_INVITE_HEADER, id = "h" } end
                if random() < 0.3 then elements[#elements + 1] = { buttonType = T_INVITE, id = "i" } end
                for k = #elements, 2, -1 do
                    local j = random(k)
                    elements[k], elements[j] = elements[j], elements[k]
                end

                -- Query: empty, whitespace, a case-flipped piece of a real name, or random text.
                local query = ""
                local r = random()
                if r < 0.15 then
                    query = ""
                elseif r < 0.25 then
                    query = pick({ " ", "\t", "  \n" })
                elseif r < 0.7 and #friends > 0 then
                    local names = friendNames(friends[random(#friends)])
                    if #names > 0 then
                        local n = pick(names)
                        local a = random(#n)
                        query = flipCase(n:sub(a, random(a, #n)))
                    else
                        query = pick(namePool)
                    end
                else
                    query = pick(namePool)
                end
                query = pick({ "", " ", "\t" }) .. query .. pick({ "", " ", "  " })
                local trimmed = UI.NameQuery(query)

                local function gameHides(f)
                    if f.nilAccount then return false end
                    if not f.online then return checked[UI.OFFLINE_KEY] == false end
                    for _, info in ipairs(f.games) do
                        if checked[UI.GameKey(info.clientProgram)] ~= false then return false end
                    end
                    return true
                end
                local function oracle(q)
                    local hidden, pass = 0, {}
                    for idx, e in ipairs(elements) do
                        local hide = false
                        if e.buttonType == T_BNET then
                            local f = friends[e.id]
                            hide = gameHides(f)
                            if not hide and q ~= "" then
                                local found = false
                                for _, n in ipairs(friendNames(f)) do
                                    if lower(n):find(lower(q), 1, true) then found = true end
                                end
                                hide = not found
                            end
                        elseif e.buttonType == T_WOW then
                            hide = q ~= ""
                        end
                        pass[idx] = not hide
                        if hide then hidden = hidden + 1 end
                    end
                    local out = {}
                    if hidden == 0 then
                        for _, e in ipairs(elements) do out[#out + 1] = e end
                        return out
                    end
                    -- Dividers stay only between two kept friends (none leading, trailing, or doubled).
                    local kept = {}
                    for idx, e in ipairs(elements) do
                        if e.buttonType == T_DIVIDER or pass[idx] then kept[#kept + 1] = e end
                    end
                    for idx, e in ipairs(kept) do
                        if e.buttonType ~= T_DIVIDER then
                            out[#out + 1] = e
                        else
                            local before, after = false, false
                            for b = 1, idx - 1 do if kept[b].buttonType ~= T_DIVIDER then before = true end end
                            for a = idx + 1, #kept do if kept[a].buttonType ~= T_DIVIDER then after = true end end
                            local prev = out[#out]
                            if before and after and prev and prev.buttonType ~= T_DIVIDER then out[#out + 1] = e end
                        end
                    end
                    return out
                end
                local function same(a, b)
                    if #a ~= #b then return false end
                    for k = 1, #a do if a[k] ~= b[k] then return false end end
                    return true
                end
                local function desc(list)
                    local t = {}
                    for k, e in ipairs(list) do t[k] = e.buttonType .. ":" .. tostring(e.id) end
                    return table.concat(t, ",")
                end

                UI.SetNameText(query)
                local provider = newProvider(elements)
                Filter.run("classic", nil, provider)
                local expected = oracle(trimmed)
                assert(same(provider:GetCollection(), expected), string.format(
                    "iteration %d: query %s: got [%s], expected [%s]", i, show(query),
                    desc(provider:GetCollection()), desc(expected)))
                assert(not Filter.IsDisabled(), "iteration " .. i .. ": guard latched")

                -- Clearing the query leaves only the game decision.
                UI.SetNameText("")
                Filter.run("classic", nil, provider)
                local gameOnly = oracle("")
                assert(same(provider:GetCollection(), gameOnly), string.format(
                    "iteration %d: empty query: got [%s], expected [%s]", i,
                    desc(provider:GetCollection()), desc(gameOnly)))
            end
        end)
        restore()
        if not ok2 then error(err2, 0) end
    end)

    for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 9: A name filter error leaves the pass unfiltered by name and does not latch
--
-- Validates: Requirements 5.7, 6.4, 6.5
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 9: A name filter error leaves the pass unfiltered by name and does not latch", function()
    local T_DIVIDER, T_WOW, T_BNET = 1, 2, 3
    local globalNames = { "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue" }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end

    local namePool = { "Ann", "ann", "ANNA", "Bob#1234", "Zoë", "a.b", "a%b", "[x]", "Stormrage", "Area 52",
        "Raiding Karazhan", "Élan", "x" }
    local programs = { "WoW", "D3", "WTCG" }

    local function genNameField()
        local r = random(10)
        if r <= 2 then return nil end
        if r == 3 then return "" end
        return pick(namePool)
    end
    local function genFriend()
        local f = { games = {}, online = random() < 0.7 }
        if f.online then
            for g = 1, random(1, 2) do f.games[g] = { isOnline = true, clientProgram = pick(programs) } end
        else
            f.games[1] = { isOnline = false, clientProgram = pick(programs) }
        end
        for _, info in ipairs(f.games) do
            info.characterName, info.realmName, info.richPresence = genNameField(), genNameField(), genNameField()
        end
        f.accountName, f.battleTag = genNameField(), genNameField()
        return f
    end
    local function lower(s) return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)) end
    local function friendNames(f)
        local names = {}
        local function add(v) if type(v) == "string" and v ~= "" then names[#names + 1] = v end end
        add(f.accountName); add(f.battleTag)
        for _, info in ipairs(f.games) do add(info.characterName); add(info.realmName); add(info.richPresence) end
        return names
    end

    local ok, err = pcall(function()
        FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
        issecretvalue = function() return false end
        local printed = 0
        print = function() printed = printed + 1 end

        local friends
        local failOn = nil   -- "account" or "num": raise on the first such call of the pass
        local function maybeFail(which)
            if failOn == which then
                failOn = nil
                error("injected name read failure")
            end
        end
        C_BattleNet = {
            GetFriendAccountInfo = function(i)
                maybeFail("account")
                local f = friends[i]
                return { accountName = f.accountName, battleTag = f.battleTag, gameAccountInfo = f.games[1] }
            end,
            GetFriendNumGameAccounts = function(i) maybeFail("num"); return #friends[i].games end,
            GetFriendGameAccountInfo = function(i, j) return friends[i].games[j] end,
        }

        local Filter, ns, restore = loadFilter({})
        local ok2, err2 = pcall(function()
            local UI = ns.UI
            local function newProvider(list)
                local p = { collection = {} }
                for i, e in ipairs(list) do p.collection[i] = e end
                function p:GetCollection() return self.collection end
                function p:GetSize() return #self.collection end
                function p:Flush() self.collection = {} end
                function p:InsertTable(t) for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end end
                return p
            end

            for i = 1, ITERATIONS do
                friends = {}
                for k = 1, random(1, 8) do friends[k] = genFriend() end
                local checked = {}
                for _, prog in ipairs(programs) do
                    if random() < 0.4 then checked[UI.GameKey(prog)] = false end
                end
                if random() < 0.4 then checked[UI.OFFLINE_KEY] = false end
                ns.db = { checkedGames = checked }

                local elements = {}
                for k = 1, #friends do elements[#elements + 1] = { buttonType = T_BNET, id = k } end
                for k = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_WOW, id = 100 + k } end
                for _ = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_DIVIDER, id = "d" } end
                for k = #elements, 2, -1 do
                    local j = random(k)
                    elements[k], elements[j] = elements[j], elements[k]
                end

                -- Non-empty query: a piece of a real name when one exists, else a pool name.
                local query
                local names = friendNames(friends[random(#friends)])
                if #names > 0 and random() < 0.7 then
                    local n = pick(names)
                    local a = random(#n)
                    query = n:sub(a, random(a, #n))
                else
                    query = pick(namePool)
                end
                query = pick({ "", " " }) .. query .. pick({ "", "  " })
                local trimmed = UI.NameQuery(query)
                if trimmed == "" then query, trimmed = "x", "x" end

                local function gameHides(f)
                    if not f.online then return checked[UI.OFFLINE_KEY] == false end
                    for _, info in ipairs(f.games) do
                        if checked[UI.GameKey(info.clientProgram)] ~= false then return false end
                    end
                    return true
                end
                local function oracle(q)
                    local pass, hidden = {}, 0
                    for idx, e in ipairs(elements) do
                        local hide = false
                        if e.buttonType == T_BNET then
                            local f = friends[e.id]
                            hide = gameHides(f)
                            if not hide and q ~= "" then
                                local found = false
                                for _, n in ipairs(friendNames(f)) do
                                    if lower(n):find(lower(q), 1, true) then found = true end
                                end
                                hide = not found
                            end
                        elseif e.buttonType == T_WOW then
                            hide = q ~= ""
                        end
                        pass[idx] = not hide
                        if hide then hidden = hidden + 1 end
                    end
                    local out = {}
                    if hidden == 0 then
                        for _, e in ipairs(elements) do out[#out + 1] = e end
                        return out
                    end
                    local kept = {}
                    for idx, e in ipairs(elements) do
                        if e.buttonType == T_DIVIDER or pass[idx] then kept[#kept + 1] = e end
                    end
                    for idx, e in ipairs(kept) do
                        if e.buttonType ~= T_DIVIDER then
                            out[#out + 1] = e
                        else
                            local before, after = false, false
                            for b = 1, idx - 1 do if kept[b].buttonType ~= T_DIVIDER then before = true end end
                            for a = idx + 1, #kept do if kept[a].buttonType ~= T_DIVIDER then after = true end end
                            local prev = out[#out]
                            if before and after and prev and prev.buttonType ~= T_DIVIDER then out[#out + 1] = e end
                        end
                    end
                    return out
                end
                local function desc(list)
                    local t = {}
                    for k, e in ipairs(list) do t[k] = e.buttonType .. ":" .. tostring(e.id) end
                    return table.concat(t, ",")
                end
                local function check(label, expected, provider)
                    local got = provider:GetCollection()
                    local same = #got == #expected
                    if same then
                        for k = 1, #got do if got[k] ~= expected[k] then same = false end end
                    end
                    assert(same, string.format("iteration %d: %s: query %s: got [%s], expected [%s]",
                        i, label, show(query), desc(got), desc(expected)))
                end

                UI.SetNameText(query)
                local provider = newProvider(elements)

                -- Failing pass: the name read raises. Game decision only, no latch, no message.
                failOn = pick({ "account", "num" })
                Filter.run("classic", nil, provider)
                assert(failOn == nil, "iteration " .. i .. ": injected failure was not reached")
                check("failing pass", oracle(""), provider)
                assert(not Filter.IsDisabled(), "iteration " .. i .. ": guard latched by a name error")
                assert(printed == 0, "iteration " .. i .. ": announcement printed after a name error")

                -- Next pass with working reads filters by name again.
                Filter.run("classic", nil, provider)
                check("recovery pass", oracle(trimmed), provider)
                assert(not Filter.IsDisabled(), "iteration " .. i .. ": guard latched")
                assert(printed == 0, "iteration " .. i .. ": announcement printed")
            end
        end)
        restore()
        if not ok2 then error(err2, 0) end
    end)

    for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Feature: name-filter-input, Property 10: The name filter works while game filtering is disabled
--
-- Validates: Requirements 6.6
----------------------------------------------------------------------
property("Feature: name-filter-input, Property 10: The name filter works while game filtering is disabled", function()
    local T_DIVIDER, T_WOW, T_BNET = 1, 2, 3
    local globalNames = { "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue" }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end

    local namePool = { "Ann", "ann", "ANNA", "Bob#1234", "Zoë", "a.b", "a%b", "[x]", "Stormrage", "Area 52",
        "Raiding Karazhan", "Élan", "x" }
    local programs = { "WoW", "D3", "WTCG" }

    local function genNameField()
        local r = random(10)
        if r <= 2 then return nil end
        if r == 3 then return "" end
        return pick(namePool)
    end
    local function genFriend()
        local f = { games = {}, online = random() < 0.7 }
        if f.online then
            for g = 1, random(1, 2) do f.games[g] = { isOnline = true, clientProgram = pick(programs) } end
        else
            f.games[1] = { isOnline = false, clientProgram = pick(programs) }
        end
        for _, info in ipairs(f.games) do
            info.characterName, info.realmName, info.richPresence = genNameField(), genNameField(), genNameField()
        end
        f.accountName, f.battleTag = genNameField(), genNameField()
        return f
    end
    local function lower(s) return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)) end
    local function friendNames(f)
        local names = {}
        local function add(v) if type(v) == "string" and v ~= "" then names[#names + 1] = v end end
        add(f.accountName); add(f.battleTag)
        for _, info in ipairs(f.games) do add(info.characterName); add(info.realmName); add(info.richPresence) end
        return names
    end

    local ok, err = pcall(function()
        FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
        issecretvalue = function() return false end
        local printed = 0
        print = function() printed = printed + 1 end

        local friends
        local failAccount = false   -- GetFriendAccountInfo raises, which fails the game decision
        C_BattleNet = {
            GetFriendAccountInfo = function(i)
                if failAccount then error("injected game decision failure") end
                local f = friends[i]
                return { accountName = f.accountName, battleTag = f.battleTag, gameAccountInfo = f.games[1] }
            end,
            GetFriendNumGameAccounts = function(i) return #friends[i].games end,
            GetFriendGameAccountInfo = function(i, j) return friends[i].games[j] end,
        }

        local function newProvider(list)
            local p = { collection = {} }
            for i, e in ipairs(list) do p.collection[i] = e end
            function p:GetCollection() return self.collection end
            function p:GetSize() return #self.collection end
            function p:Flush() self.collection = {} end
            function p:InsertTable(t) for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end end
            return p
        end

        for i = 1, ITERATIONS do
            printed = 0
            failAccount = false
            -- A fresh Filter per iteration, because the guard latches for the session.
            local Filter, ns, restore = loadFilter({})
            local ok2, err2 = pcall(function()
                local UI = ns.UI
                friends = {}
                for k = 1, random(1, 8) do friends[k] = genFriend() end
                local checked = {}
                for _, prog in ipairs(programs) do
                    if random() < 0.6 then checked[UI.GameKey(prog)] = false end
                end
                if random() < 0.6 then checked[UI.OFFLINE_KEY] = false end
                ns.db = { checkedGames = checked }

                local elements = {}
                for k = 1, #friends do elements[#elements + 1] = { buttonType = T_BNET, id = k } end
                for k = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_WOW, id = 100 + k } end
                for _ = 1, random(0, 3) do elements[#elements + 1] = { buttonType = T_DIVIDER, id = "d" } end
                for k = #elements, 2, -1 do
                    local j = random(k)
                    elements[k], elements[j] = elements[j], elements[k]
                end

                -- Name decision only: the game decision is ignored while disabled.
                local function oracle(q)
                    local pass, hidden = {}, 0
                    for idx, e in ipairs(elements) do
                        local hide = false
                        if e.buttonType == T_BNET and q ~= "" then
                            local found = false
                            for _, n in ipairs(friendNames(friends[e.id])) do
                                if lower(n):find(lower(q), 1, true) then found = true end
                            end
                            hide = not found
                        elseif e.buttonType == T_WOW then
                            hide = q ~= ""
                        end
                        pass[idx] = not hide
                        if hide then hidden = hidden + 1 end
                    end
                    local out = {}
                    if hidden == 0 then
                        for _, e in ipairs(elements) do out[#out + 1] = e end
                        return out
                    end
                    local kept = {}
                    for idx, e in ipairs(elements) do
                        if e.buttonType == T_DIVIDER or pass[idx] then kept[#kept + 1] = e end
                    end
                    for idx, e in ipairs(kept) do
                        if e.buttonType ~= T_DIVIDER then
                            out[#out + 1] = e
                        else
                            local before, after = false, false
                            for b = 1, idx - 1 do if kept[b].buttonType ~= T_DIVIDER then before = true end end
                            for a = idx + 1, #kept do if kept[a].buttonType ~= T_DIVIDER then after = true end end
                            local prev = out[#out]
                            if before and after and prev and prev.buttonType ~= T_DIVIDER then out[#out + 1] = e end
                        end
                    end
                    return out
                end
                local function desc(list)
                    local t = {}
                    for k, e in ipairs(list) do t[k] = e.buttonType .. ":" .. tostring(e.id) end
                    return table.concat(t, ",")
                end
                local function check(label, query, expected, provider)
                    local got = provider:GetCollection()
                    local same = #got == #expected
                    if same then
                        for k = 1, #got do if got[k] ~= expected[k] then same = false end end
                    end
                    assert(same, string.format("iteration %d: %s: query %s: got [%s], expected [%s]",
                        i, label, show(query), desc(got), desc(expected)))
                end

                -- Latch the guard with a game decision error (empty query, so only the game decision runs).
                UI.SetNameText("")
                local provider = newProvider(elements)
                failAccount = true
                Filter.run("classic", nil, provider)
                failAccount = false
                assert(Filter.IsDisabled(), "iteration " .. i .. ": guard did not latch")
                assert(printed == 1, "iteration " .. i .. ": expected one announcement")

                -- A non-empty query still filters by name.
                local query
                local names = friendNames(friends[random(#friends)])
                if #names > 0 and random() < 0.7 then
                    local n = pick(names)
                    local a = random(#n)
                    query = n:sub(a, random(a, #n))
                else
                    query = pick(namePool)
                end
                query = pick({ "", " " }) .. query .. pick({ "", "  " })
                local trimmed = UI.NameQuery(query)
                if trimmed == "" then query, trimmed = "x", "x" end
                UI.SetNameText(query)
                Filter.run("classic", nil, provider)
                check("name query", query, oracle(trimmed), provider)

                -- Reapply on a shown list goes through the same path.
                -- Clearing the query restores the unfiltered list.
                UI.SetNameText("")
                Filter.run("classic", nil, provider)
                check("cleared query", "", oracle(""), provider)

                assert(Filter.IsDisabled(), "iteration " .. i .. ": guard cleared")
                assert(printed == 1, "iteration " .. i .. ": announcement count changed to " .. printed)
            end)
            restore()
            if not ok2 then error(err2, 0) end
        end
    end)

    for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Example tests for the name filter in Filter.lua (task 4.8)
--
-- Validates: Requirements 3.7, 4.4, 4.5, 5.6, 5.7, 6.4, 6.5, 6.6
----------------------------------------------------------------------
local function withNameFilterEnv(friends, extraEnv, fn)
    local T_DIVIDER, T_WOW, T_BNET = 1, 2, 3
    local globalNames = { "print", "C_BattleNet", "FRIENDS_BUTTON_TYPE_DIVIDER", "FRIENDS_BUTTON_TYPE_WOW",
        "FRIENDS_BUTTON_TYPE_BNET", "issecretvalue" }
    local savedGlobals = {}
    for _, n in ipairs(globalNames) do savedGlobals[n] = _G[n] end
    local ok, err = pcall(function()
        FRIENDS_BUTTON_TYPE_DIVIDER, FRIENDS_BUTTON_TYPE_WOW, FRIENDS_BUTTON_TYPE_BNET = T_DIVIDER, T_WOW, T_BNET
        issecretvalue = function() return false end
        local env = { printed = 0, failNum = false, failAccount = false }
        print = function() env.printed = env.printed + 1 end
        C_BattleNet = {
            GetFriendAccountInfo = function(i)
                if env.failAccount then error("injected game decision failure") end
                local f = friends[i]
                return { accountName = f.accountName, battleTag = f.battleTag, gameAccountInfo = f.games[1] }
            end,
            GetFriendNumGameAccounts = function(i)
                if env.failNum then
                    env.failNum = false
                    error("injected name read failure")
                end
                return #friends[i].games
            end,
            GetFriendGameAccountInfo = function(i, j) return friends[i].games[j] end,
        }
        function env.newProvider(list)
            local p = { collection = {} }
            for i, e in ipairs(list) do p.collection[i] = e end
            function p:GetCollection() return self.collection end
            function p:GetSize() return #self.collection end
            function p:Flush() self.collection = {} end
            function p:InsertTable(t) for _, e in ipairs(t) do self.collection[#self.collection + 1] = e end end
            return p
        end
        function env.ids(p)
            local out = {}
            for i, e in ipairs(p:GetCollection()) do out[i] = (e.buttonType == T_DIVIDER) and "d" or tostring(e.id) end
            return table.concat(out, ",")
        end
        env.T_DIVIDER, env.T_BNET = T_DIVIDER, T_BNET
        local Filter, ns, restore = loadFilter(extraEnv or {})
        local ok2, err2 = pcall(fn, Filter, ns, env)
        restore()
        if not ok2 then error(err2, 0) end
    end)
    for _, n in ipairs(globalNames) do _G[n] = savedGlobals[n] end
    if not ok then error(err, 0) end
end

local function nameFriend(account, character, realm, presence)
    return { accountName = account, battleTag = account .. "#1", online = true, games = {
        { isOnline = true, clientProgram = "WoW", characterName = character, realmName = realm, richPresence = presence },
    } }
end

property("Feature: name-filter-input, Example: realm-only and rich-presence-only matches keep the friend", function()
    local friends = {
        nameFriend("Alice", "Aa", "Stormrage", nil),
        nameFriend("Bruno", "Bb", nil, "In Stormwind"),
        nameFriend("Cleo", "Cc", "Area 52", "Raiding"),
    }
    withNameFilterEnv(friends, {}, function(Filter, ns, env)
        ns.db = { checkedGames = {} }
        local elements = {}
        for k = 1, #friends do elements[k] = { buttonType = env.T_BNET, id = k } end
        local p = env.newProvider(elements)
        ns.UI.SetNameText("RAGE")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1", "realm-only match: " .. env.ids(p))
        ns.UI.SetNameText("in storm")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "2", "rich-presence-only match: " .. env.ids(p))
    end)
end)

property("Feature: name-filter-input, Example: a SetDataProvider rebuild applies a non-empty query", function()
    local friends = {
        nameFriend("Alice", "Aa", "Stormrage", nil),
        nameFriend("Bruno", "Bb", "Area 52", nil),
    }
    local hooks = {}
    local scrollBox = setmetatable({}, { __index = function() return function() end end })
    function scrollBox:SetDataProvider(p)
        self.provider = p
        for _, fn in ipairs(hooks) do fn(self, p) end
    end
    function scrollBox:GetDataProvider() return self.provider end
    local extra = {
        hooksecurefunc = function(_, _, fn) hooks[#hooks + 1] = fn end,
        CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end,
        FriendsListFrame = { ScrollBox = scrollBox, IsShown = function() return true end },
    }
    withNameFilterEnv(friends, extra, function(Filter, ns, env)
        ns.db = { checkedGames = {} }
        Filter.Install()
        local function rebuilt()
            local p = env.newProvider({ { buttonType = env.T_BNET, id = 1 }, { buttonType = env.T_BNET, id = 2 } })
            scrollBox:SetDataProvider(p)
            return env.ids(p)
        end
        assert(rebuilt() == "1,2", "empty query changed the rebuilt list")
        ns.UI.SetNameText("rage")
        assert(rebuilt() == "1", "first rebuild with query: " .. rebuilt())
        assert(rebuilt() == "1", "second rebuild with query")
        ns.UI.SetNameText("")
        assert(rebuilt() == "1,2", "cleared query rebuild")
    end)
end)

property("Feature: name-filter-input, Example: a divider emptied by the name filter is removed and returns", function()
    local friends = {
        nameFriend("Alice", "Aa", nil, nil),
        nameFriend("Bruno", "Bb", nil, nil),
        nameFriend("Cleo", "Cc", nil, nil),
    }
    withNameFilterEnv(friends, {}, function(Filter, ns, env)
        ns.db = { checkedGames = {} }
        local p = env.newProvider({
            { buttonType = env.T_BNET, id = 1 }, { buttonType = env.T_DIVIDER, id = "d" },
            { buttonType = env.T_BNET, id = 2 }, { buttonType = env.T_BNET, id = 3 },
        })
        ns.UI.SetNameText("alice")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1", "divider should be removed: " .. env.ids(p))
        ns.UI.SetNameText("")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1,d,2,3", "divider should return: " .. env.ids(p))
        ns.UI.SetNameText("cleo")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "3", "divider with no friend before it: " .. env.ids(p))
        -- "#1" matches every BattleTag, so all friends and the divider are back.
        ns.UI.SetNameText("#1")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1,d,2,3", "all friends match: " .. env.ids(p))
    end)
end)

property("Feature: name-filter-input, Example: a name read error pass is unfiltered, the next pass filters, no latch", function()
    local friends = {
        nameFriend("Alice", "Aa", nil, nil),
        nameFriend("Bruno", "Bb", nil, nil),
    }
    withNameFilterEnv(friends, {}, function(Filter, ns, env)
        ns.db = { checkedGames = {} }
        local p = env.newProvider({ { buttonType = env.T_BNET, id = 1 }, { buttonType = env.T_BNET, id = 2 } })
        ns.UI.SetNameText("alice")
        env.failNum = true
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1,2", "failing pass should be unfiltered by name: " .. env.ids(p))
        assert(not Filter.IsDisabled(), "guard latched by a name error")
        assert(env.printed == 0, "message printed after a name error")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1", "next pass should filter: " .. env.ids(p))
        assert(not Filter.IsDisabled() and env.printed == 0, "guard latched or printed on the good pass")
    end)
end)

property("Feature: name-filter-input, Example: a game decision error latches once and a later name query still filters", function()
    local friends = {
        nameFriend("Alice", "Aa", nil, nil),
        nameFriend("Bruno", "Bb", nil, nil),
    }
    withNameFilterEnv(friends, {}, function(Filter, ns, env)
        ns.db = { checkedGames = {} }
        local p = env.newProvider({ { buttonType = env.T_BNET, id = 1 }, { buttonType = env.T_BNET, id = 2 } })
        ns.UI.SetNameText("")
        env.failAccount = true
        Filter.run("classic", nil, p)
        env.failAccount = false
        assert(Filter.IsDisabled(), "guard did not latch")
        assert(env.printed == 1, "expected one message, got " .. env.printed)
        ns.UI.SetNameText("bruno")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "2", "name query after latch: " .. env.ids(p))
        -- A later pass with a game error would not print again.
        env.failAccount = true
        Filter.run("classic", nil, p)
        env.failAccount = false
        assert(env.printed == 1, "message printed again: " .. env.printed)
        ns.UI.SetNameText("")
        Filter.run("classic", nil, p)
        assert(env.ids(p) == "1,2", "cleared query after latch: " .. env.ids(p))
    end)
end)


property("Follow-up: /ff debug is session-only and version falls back to dev", function()
    local saved = { SlashCmdList = SlashCmdList, strtrim = strtrim, print = print,
        GetAddOnMetadata = GetAddOnMetadata, C_AddOns = C_AddOns }
    SlashCmdList = {}
    strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    print = function() end
    C_AddOns = nil
    local function loadCore(version)
        GetAddOnMetadata = function() return version end
        local ns = {}
        local chunk = assert(loadfile("ForeverFilter/Core.lua"))
        chunk("ForeverFilter", ns)
        return ns
    end
    local ok, err = pcall(function()
        assert(loadCore("@project-version@").version == "dev", "token not replaced")
        assert(loadCore(nil).version == "dev", "missing version not dev")
        assert(loadCore("v1.2.3").version == "v1.2.3", "real version changed")

        local ns = loadCore("v1")
        ForeverFilterDB = { checkedGames = { WoW = true } }
        ns.db = ForeverFilterDB
        assert(not ns.debug, "debug not off at load")
        local before = ns.db.checkedGames
        SlashCmdList["FOREVERFILTER"]("debug")
        assert(ns.debug == true, "debug not toggled on")
        assert(ns.db.debug == nil, "debug saved to db")
        local n = 0
        for _ in pairs(ns.db) do n = n + 1 end
        assert(n == 1 and ns.db.checkedGames == before, "db changed by debug toggle")
        SlashCmdList["FOREVERFILTER"]("debug")
        assert(not ns.debug, "debug not toggled off")
    end)
    SlashCmdList, strtrim, print = saved.SlashCmdList, saved.strtrim, saved.print
    GetAddOnMetadata, C_AddOns = saved.GetAddOnMetadata, saved.C_AddOns
    ForeverFilterDB = nil
    if not ok then error(err, 0) end
end)

----------------------------------------------------------------------
-- Task 7: addon icon (friends list button, minimap button helpers)
----------------------------------------------------------------------
local function loadIcons(ns)
    ns = loadModule("Icons", ns)
    return ns.Icons, ns
end

property("Icons: openWithFriends preference parsing and default", function()
    local UI = loadUI({})
    assert(UI.ReadOpenWithFriends(nil) == true)
    assert(UI.ReadOpenWithFriends({}) == true)
    assert(UI.ReadOpenWithFriends({ openWithFriends = "no" }) == true)
    assert(UI.ReadOpenWithFriends({ openWithFriends = 0 }) == true)
    assert(UI.ReadOpenWithFriends({ openWithFriends = true }) == true)
    assert(UI.ReadOpenWithFriends({ openWithFriends = false }) == false)
end)

property("Icons: auto-open decision honours the preference", function()
    local UI = loadUI({})
    for i = 1, ITERATIONS do
        local pref = pick({ true, false, nil })
        local dismissed = random() < 0.3
        local shown = random() < 0.3
        local state, action = UI.NextSocialState({ dismissed = dismissed }, "social_shown",
            { windowShown = shown, openWithFriends = pref })
        local expect = (not shown) and (not dismissed) and pref ~= false
        assert((action == "show") == expect, "pref=" .. tostring(pref) .. " dismissed=" .. tostring(dismissed)
            .. " shown=" .. tostring(shown) .. " action=" .. tostring(action))
        assert(state.autoOpened == expect)
    end
end)

property("Icons: angle helpers range, wrap and invalid input", function()
    local Icons = loadIcons({})
    for i = 1, ITERATIONS do
        local a = (random() - 0.5) * 20000
        local n = Icons.NormalizeAngle(a)
        assert(n >= 0 and n < 360, "range " .. tostring(n))
        assert(math.abs(Icons.NormalizeAngle(a + 360) - n) < 1e-6 or math.abs(math.abs(Icons.NormalizeAngle(a + 360) - n) - 360) < 1e-6)
        local r = random(10, 120)
        local x, y = Icons.AngleToOffset(a, r)
        assert(math.abs(math.sqrt(x * x + y * y) - r) < 1e-6, "radius")
        -- cursor angle round trip
        local ang = random() * 359
        local cx, cy = 500 + math.cos(math.rad(ang)) * 50, 300 + math.sin(math.rad(ang)) * 50
        assert(math.abs(Icons.CursorToAngle(cx, cy, 500, 300) - ang) < 1e-6)
    end
    assert(Icons.NormalizeAngle(-90) == 270 and Icons.NormalizeAngle(360) == 0 and Icons.NormalizeAngle(725) == 5)
    for _, bad in ipairs({ "x", {}, true, 0 / 0, math.huge, -math.huge }) do
        assert(Icons.NormalizeAngle(bad) == 200, "invalid angle " .. tostring(bad))
    end
    local x, y = Icons.AngleToOffset(0, 80)
    assert(math.abs(x - 80) < 1e-9 and math.abs(y) < 1e-9)
    x, y = Icons.AngleToOffset(90, 80)
    assert(math.abs(x) < 1e-9 and math.abs(y - 80) < 1e-9)
    assert(Icons.CursorToAngle(1, 1, 1, 1) == 200 and Icons.CursorToAngle(nil, 1, 1, 1) == 200)
end)

property("Icons: minimap settings reading and writing", function()
    local Icons = loadIcons({})
    local a, h = Icons.ReadMinimapSettings(nil)
    assert(a == 200 and h == false)
    a, h = Icons.ReadMinimapSettings({ minimap = "x" })
    assert(a == 200 and h == false)
    a, h = Icons.ReadMinimapSettings({ minimap = { angle = "bad", hide = "yes" } })
    assert(a == 200 and h == false)
    a, h = Icons.ReadMinimapSettings({ minimap = { angle = 45, hide = true } })
    assert(a == 45 and h == true)
    a, h = Icons.ReadMinimapSettings({ minimap = { angle = -45 } })
    assert(a == 315 and h == false)
    local db = {}
    Icons.WriteMinimapSettings(db, 90, nil)
    assert(db.minimap.angle == 90 and db.minimap.hide == false)
    Icons.WriteMinimapSettings(db, nil, true)
    assert(db.minimap.angle == 90 and db.minimap.hide == true)
end)

property("Icons: friends list button click saves the preference and toggles the window", function()
    local saved = { CreateFrame = CreateFrame }
    local ok, err = pcall(function()
        local frames = {}
        CreateFrame = function(_, name)
            local f = { name = name, scripts = {}, shown = false, points = {} }
            function f:IsShown() return self.shown end
            function f:Show() self.shown = true end
            function f:Hide() self.shown = false end
            function f:SetScript(k, fn) self.scripts[k] = fn end
            function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
            f.GetFrameLevel = function() return 3 end
            f.CreateTexture = function() return CreateFrame("Texture") end
            f.CreateFontString = function() return CreateFrame("FontString") end
            f.GetWidth = function() return 100 end
            f.GetHeight = function() return 100 end
            f.GetScale = function() return 1 end
            f.GetStringHeight = function() return 12 end
            f.GetStringWidth = function() return 50 end
            local fields = { TitleText = true, TitleContainer = true, CloseButton = true, Inset = true }
            setmetatable(f, { __index = function(_, k)
                if fields[k] then return nil end
                return function() return CreateFrame("Frame") end
            end })
            frames[#frames + 1] = f
            return f
        end
        local db = {}
        local UI, ns = loadUI(db)
        loadIcons(ns)
        local close = { GetObjectType = function() return "Button" end }
        local parent = { CloseButton = close, GetFrameLevel = function() return 1 end }
        local b = ns.Icons.AttachFriendsButton(parent, "FriendsFrame")
        assert(b and b.name == "ForeverFilterToggleButtonFriendsFrame")
        assert(ns.Icons.AttachFriendsButton(parent, "FriendsFrame") == b, "created twice")
        local p = b.points[1]
        assert(p[1] == "RIGHT" and p[2] == close and p[3] == "LEFT", "anchor")
        -- No close button: falls back to the frame corner.
        local b2 = ns.Icons.AttachFriendsButton({ GetFrameLevel = function() return 1 end }, "SocialUIFrame")
        assert(b2.points[1][1] == "TOPRIGHT")
        b.scripts.OnClick()
        assert(db.openWithFriends == true, "open should save true")
        b.scripts.OnClick()
        assert(db.openWithFriends == false, "close should save false")
        b.scripts.OnClick()
        assert(db.openWithFriends == true)
        -- Closing the window with its own hide path does not change the preference.
        UI.Hide()
        assert(db.openWithFriends == true)
    end)
    CreateFrame = saved.CreateFrame
    assert(ok, err)
end)

----------------------------------------------------------------------
-- Window icon in the upper left (no portrait in BasicFrameTemplateWithInset)
----------------------------------------------------------------------
property("Window icon: texture path is set on creation and a missing portrait does not error", function()
    local saved = { CreateFrame = CreateFrame, UIParent = UIParent }
    local frames = {}
    local function recFrame(name)
        local f = { calls = {}, name = name }
        local absent = { TitleText = true, TitleContainer = true, InsetBg = true, CloseButton = true,
                         PortraitContainer = true, portrait = true, SetPortraitToAsset = true }
        setmetatable(f, { __index = function(t, key)
            if absent[key] then return nil end
            return function(self, ...)
                t.calls[#t.calls + 1] = { key, ... }
                if key == "CreateFontString" or key == "CreateTexture" then return recFrame() end
                if key == "GetFrameLevel" then return 1 end
                if key == "IsShown" then return true end
                if key == "GetWidth" then return 300 end
                if key == "GetHeight" then return 1080 end
                if key == "GetStringHeight" then return 14 end
                if key == "GetStringWidth" then return 100 end
            end
        end })
        frames[#frames + 1] = f
        return f
    end
    CreateFrame = function(_, name) return recFrame(name) end
    UIParent = recFrame("UIParent")
    UIParent.GetWidth = function() return 1920 end
    local ok, err = pcall(function()
        local UI = loadUI({})
        UI.Show()
        local want = "Interface\\AddOns\\ForeverFilter\\Textures\\ForeverFilter_64"
        assert(UI.ICON_TEXTURE == want, "icon path is " .. tostring(UI.ICON_TEXTURE))
        local found = false
        for _, f in ipairs(frames) do
            for _, c in ipairs(f.calls) do
                if c[1] == "SetTexture" and c[2] == want then found = true end
            end
        end
        assert(found, "icon texture path was never set")
    end)
    CreateFrame, UIParent = saved.CreateFrame, saved.UIParent
    assert(ok, err)
end)

----------------------------------------------------------------------
-- (append further properties above this line)
----------------------------------------------------------------------
print(string.format("%d/%d properties passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
