local _, ns = ...

local Friends = {}
ns.Friends = Friends

local function displayName(info)
    local name = info.accountName
    if type(name) ~= "string" or name == "" then
        name = info.battleTag
    end
    if type(name) ~= "string" or name == "" then
        name = "?"
    end
    return name
end

local function nonEmpty(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function positiveNumber(value)
    if type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

local function makeOnlineEntry(name, gameInfo)
    return {
        name = name,
        isOnline = true,
        game = nonEmpty(gameInfo.clientProgram),
        wowProjectID = positiveNumber(gameInfo.wowProjectID),
        richPresence = nonEmpty(gameInfo.richPresence),
        characterName = nonEmpty(gameInfo.characterName),
    }
end

local function sortKey(entry)
    return (entry.name or "?"):lower()
end

local function compareEntries(a, b)
    if a.isOnline ~= b.isOnline then
        return a.isOnline
    end
    local ka, kb = sortKey(a), sortKey(b)
    if ka ~= kb then
        return ka < kb
    end
    return (a.game or "") < (b.game or "")
end

-- Returns a list of entries: one per online game account, or one offline
-- entry (game = nil) per friend with no online game account.
function Friends.GetAll()
    local entries = {}
    local count = BNGetNumFriends and BNGetNumFriends() or 0

    for index = 1, count do
        local info = C_BattleNet and C_BattleNet.GetFriendAccountInfo(index)
        if info then
            local name = displayName(info)
            local added = false
            local numAccounts = C_BattleNet.GetFriendNumGameAccounts(index) or 0

            for gameIndex = 1, numAccounts do
                local gameInfo = C_BattleNet.GetFriendGameAccountInfo(index, gameIndex)
                if gameInfo and gameInfo.isOnline then
                    entries[#entries + 1] = makeOnlineEntry(name, gameInfo)
                    added = true
                end
            end

            -- Fall back to the primary game account if the list gave nothing.
            if not added and info.gameAccountInfo and info.gameAccountInfo.isOnline then
                entries[#entries + 1] = makeOnlineEntry(name, info.gameAccountInfo)
                added = true
            end

            if not added then
                entries[#entries + 1] = {
                    name = name,
                    isOnline = false,
                    game = nil,
                    wowProjectID = nil,
                    richPresence = nil,
                    characterName = nil,
                }
            end
        end
    end

    table.sort(entries, compareEntries)
    return entries
end

-- Returns { [gameCode] = count } for online entries. A missing game code is
-- counted under "?".
function Friends.CountByGame(entries)
    local counts = {}
    for _, entry in ipairs(entries or {}) do
        if entry.isOnline then
            local game = entry.game or "?"
            counts[game] = (counts[game] or 0) + 1
        end
    end
    return counts
end

-- Groups online entries by (game, wowProjectID). Returns a list of
-- { game, wowProjectID, count, friends } ordered by count descending, then by
-- nameFn(game, wowProjectID) case-insensitively (or by game code when nameFn
-- is nil), then by game code, then by project ID (nil first).
function Friends.GroupByGame(entries, nameFn)
    local rows, byKey = {}, {}

    for _, e in ipairs(entries or {}) do
        if e.isOnline then
            local game = e.game or "?"
            local pid = nil
            if game == "WoW" then
                pid = e.wowProjectID
            end
            local key = game .. ":" .. tostring(pid)
            local row = byKey[key]
            if not row then
                row = { game = game, wowProjectID = pid, count = 0, friends = {}, seen = {} }
                byKey[key] = row
                rows[#rows + 1] = row
            end
            local name = e.name or "?"
            if not row.seen[name] then
                row.seen[name] = true
                row.friends[#row.friends + 1] = name
                row.count = row.count + 1
            end
        end
    end

    for _, row in ipairs(rows) do
        row.seen = nil
        table.sort(row.friends, function(a, b)
            local la, lb = tostring(a):lower(), tostring(b):lower()
            if la ~= lb then
                return la < lb
            end
            return tostring(a) < tostring(b)
        end)
    end

    table.sort(rows, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        local na = nameFn and tostring(nameFn(a.game, a.wowProjectID)):lower() or a.game
        local nb = nameFn and tostring(nameFn(b.game, b.wowProjectID)):lower() or b.game
        if na ~= nb then
            return na < nb
        end
        if a.game ~= b.game then
            return a.game < b.game
        end
        return (a.wowProjectID or 0) < (b.wowProjectID or 0)
    end)

    return rows
end
