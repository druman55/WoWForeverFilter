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
        subIcon = nonEmpty(gameInfo.subIcon),
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

-- Sentinel game value for friends who are online only in a Battle.net app.
Friends.APPS_GAME = "@apps"

-- True iff code is a Battle.net app client code.
function Friends.IsAppClient(code)
    return code == "App" or code == "BSAp" or code == "CLNT"
end

local function isOnlineInfo(info)
    return type(info) == "table" and info.isOnline == true
end

-- Picks the online game accounts that count for presence: every online
-- Real_Game account when any exists, else the first online App_Client account.
local function selectFrom(infos)
    local real, firstApp = {}, nil
    for _, info in ipairs(infos) do
        if isOnlineInfo(info) then
            if Friends.IsAppClient(info.clientProgram) then
                firstApp = firstApp or info
            else
                real[#real + 1] = info
            end
        end
    end
    if #real > 0 then
        return real
    end
    if firstApp then
        return { firstApp }
    end
    return {}
end

-- gameInfos: list of game account infos (nil and non-table entries tolerated).
-- primaryInfo: the account's primary game account info, used only when no
-- entry of gameInfos is online. Returns the infos that count, in input order.
function Friends.PresenceGames(gameInfos, primaryInfo)
    local list = {}
    if type(gameInfos) == "table" then
        -- Tolerate holes from nil entries.
        local max = 0
        for k in pairs(gameInfos) do
            if type(k) == "number" and k > max then
                max = k
            end
        end
        for i = 1, max do
            list[#list + 1] = gameInfos[i]
        end
    end

    local anyOnline = false
    for _, info in ipairs(list) do
        if isOnlineInfo(info) then
            anyOnline = true
            break
        end
    end
    if anyOnline then
        return selectFrom(list)
    end
    if isOnlineInfo(primaryInfo) then
        return selectFrom({ primaryInfo })
    end
    return {}
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
            local numAccounts = C_BattleNet.GetFriendNumGameAccounts(index) or 0

            local gameInfos = {}
            for gameIndex = 1, numAccounts do
                gameInfos[gameIndex] = C_BattleNet.GetFriendGameAccountInfo(index, gameIndex)
            end

            local present = Friends.PresenceGames(gameInfos, info.gameAccountInfo)
            for _, gameInfo in ipairs(present) do
                local entry = makeOnlineEntry(name, gameInfo)
                if Friends.IsAppClient(gameInfo.clientProgram) then
                    entry.game = Friends.APPS_GAME
                end
                entries[#entries + 1] = entry
            end

            if #present == 0 then
                entries[#entries + 1] = {
                    name = name,
                    isOnline = false,
                    game = nil,
                    wowProjectID = nil,
                    richPresence = nil,
                    characterName = nil,
                    subIcon = nil,
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

-- Number of entries with isOnline ~= true. GetAll makes one such entry per
-- friend that has no online game account.
function Friends.CountOffline(entries)
    if type(entries) ~= "table" then
        return 0
    end
    local count = 0
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and entry.isOnline ~= true then
            count = count + 1
        end
    end
    return count
end

-- Groups online entries by (game, wowProjectID). Returns a list of
-- { game, wowProjectID, subIcon, count, friends } ordered by
-- nameFn(game, wowProjectID) case-insensitively (or by game code when nameFn
-- is nil), then by game code, then by project ID (nil first). Friend counts
-- do not affect the order.
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
                row = { game = game, wowProjectID = pid, subIcon = nil, count = 0, friends = {}, seen = {} }
                byKey[key] = row
                rows[#rows + 1] = row
            end
            if row.subIcon == nil and e.subIcon ~= nil then
                row.subIcon = e.subIcon
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
        local na = nameFn and tostring(nameFn(a.game, a.wowProjectID)):lower() or a.game
        local nb = nameFn and tostring(nameFn(b.game, b.wowProjectID)):lower() or b.game
        if na ~= nb then
            return na < nb
        end
        if a.game ~= b.game then
            return a.game < b.game
        end
        -- project ID, nil first
        if a.wowProjectID == b.wowProjectID then
            return false
        end
        if a.wowProjectID == nil then
            return true
        end
        if b.wowProjectID == nil then
            return false
        end
        return a.wowProjectID < b.wowProjectID
    end)

    return rows
end
