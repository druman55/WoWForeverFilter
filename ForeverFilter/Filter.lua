-- Filter.lua: hides friends of unchecked games in Blizzard's friends list.
-- This is the only file that touches Blizzard frames. It uses hooksecurefunc
-- post-hooks and never replaces or assigns a Blizzard function or field.
local _, ns = ...

local Filter = {}
ns.Filter = Filter

-- Seam for the mirror-list fallback described in the design.
Filter.MODE = "provider"

local ADDON_NAME = "ForeverFilter"
local ANNOUNCE_TEXT = "Forever Filter: friends list filtering was turned off for this session because of an error."

-- Session state, never saved.
local hooked = {}                 -- set keyed by ScrollBox table
local snapshots = {}              -- per kind: classic, social
local guard = { disabled = false, announced = false }

-- Per-kind apply functions, filled in by later sections of this file.
local appliers = {}

Filter.snapshots = snapshots

local function announce()
    if type(print) == "function" then
        print(ANNOUNCE_TEXT)
    end
end

-- Feeds an event to the failure latch and prints the one-time message.
local function feedGuard(event)
    local newState, action = ns.UI.NextFilterGuard(guard, event)
    guard = newState
    if action == "announce" then
        announce()
    end
end

function Filter.IsDisabled()
    return guard.disabled == true
end

-- Runs apply for one list under pcall. A failure latches the guard.
local function run(kind, scrollBox, provider)
    local apply = appliers[kind]
    if type(apply) ~= "function" then
        return
    end
    if guard.disabled then
        -- Game filtering is off. Continue only for a name query or to
        -- restore a list we already filtered.
        local UI = ns.UI
        local query = type(UI) == "table" and type(UI.GetNameQuery) == "function" and UI.GetNameQuery() or ""
        if (query == nil or query == "") and not snapshots[kind] then
            return
        end
    end
    local ok = pcall(apply, scrollBox, provider, not guard.disabled)
    if not ok then
        feedGuard("error")
    end
end
Filter.run = run

-- Resolves the ScrollBox of each supported list. Missing frames give nil.
local function classicScrollBox()
    local frame = FriendsListFrame
    if type(frame) == "table" then
        return frame.ScrollBox
    end
    return nil
end

local function socialScrollBox()
    local frame = SocialUIFrame
    if type(frame) == "table" and type(frame.FriendsList) == "table" then
        return frame.FriendsList.ScrollBox
    end
    return nil
end

local function installOne(kind, scrollBox)
    if type(scrollBox) ~= "table" or hooked[scrollBox] then
        return
    end
    if type(hooksecurefunc) ~= "function" or type(scrollBox.SetDataProvider) ~= "function" then
        return
    end
    hooked[scrollBox] = kind
    hooksecurefunc(scrollBox, "SetDataProvider", function(self, provider)
        run(kind, self, provider)
    end)
end

-- Idempotent. Safe to call from PLAYER_LOGIN and ADDON_LOADED.
function Filter.Install()
    if Filter.MODE ~= "provider" then
        return
    end
    installOne("classic", classicScrollBox())
    installOne("social", socialScrollBox())
end

-- Registers a handler for a kind. Used by the apply sections of this file.
function Filter.SetApplier(kind, fn)
    appliers[kind] = fn
end

---------------------------------------------------------------------------
-- Classic friends list (flat DataProvider)
---------------------------------------------------------------------------

local function isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) == true
end

-- Reads checkedGames by the UI.IsChecked rule: missing or non-boolean is checked.
-- Never writes an entry.
local function readChecked(key)
    local db = ns.db
    if type(db) ~= "table" then
        db = ForeverFilterDB
    end
    local store = type(db) == "table" and db.checkedGames or nil
    if type(store) == "table" then
        local v = store[key]
        if type(v) == "boolean" then
            return v
        end
        -- Apps row without a stored boolean: unchecked only when both legacy
        -- app entries are false (same rule as UI.IsAppsChecked).
        if key == "@apps" and store["App:nil"] == false and store["BSAp:nil"] == false then
            return false
        end
    end
    return true
end

local function copyList(list)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    return out
end

local function sameList(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Copies the fields the decision needs, or returns nil when any is secret.
local function readGameInfo(info)
    if type(info) ~= "table" or isSecret(info) then
        return nil
    end
    local online, program, projectID = info.isOnline, info.clientProgram, info.wowProjectID
    if isSecret(online) or isSecret(program) or isSecret(projectID) then
        return nil
    end
    return { isOnline = online, clientProgram = program, wowProjectID = projectID }
end

---------------------------------------------------------------------------
-- Name filter: reading names and the per-pass decision
---------------------------------------------------------------------------

-- Skips nil, secret, non-string and empty values.
local function addName(names, v)
    if v ~= nil and not isSecret(v) and type(v) == "string" and v ~= "" then
        names[#names + 1] = v
    end
end

-- Friend names of one Battle.net friend. May raise; call only under pcall.
-- A secret or non-table account or game info is skipped as a whole.
local function readFriendNames(friendIndex)
    local names = {}
    local account = C_BattleNet.GetFriendAccountInfo(friendIndex)
    if type(account) == "table" and not isSecret(account) then
        addName(names, account.accountName)
        addName(names, account.battleTag)
    end
    local count = C_BattleNet.GetFriendNumGameAccounts(friendIndex)
    if type(count) == "number" and not isSecret(count) then
        for i = 1, count do
            local info = C_BattleNet.GetFriendGameAccountInfo(friendIndex, i)
            if type(info) == "table" and not isSecret(info) then
                addName(names, info.characterName)
                addName(names, info.realmName)
                addName(names, info.richPresence)
            end
        end
    end
    return names
end

-- Returns friendIndex -> true (hide) / false (keep), or nil when the name
-- filter does not apply to this pass (empty query or any error).
-- Never raises and never touches the guard.
local function buildNameHidden(friendIndexes)
    local UI = ns.UI
    if type(UI) ~= "table" or type(UI.GetNameQuery) ~= "function" then
        return nil
    end
    local query = UI.GetNameQuery()
    if query == nil or query == "" then
        return nil
    end
    local ok, result = pcall(function()
        local hidden = {}
        for _, idx in ipairs(friendIndexes) do
            hidden[idx] = UI.NameFilterHides(query, readFriendNames(idx))
        end
        return hidden
    end)
    if ok then
        return result
    end
    return nil
end

-- Exposed for the applier sections and tests.
Filter.readFriendNames = readFriendNames
Filter.buildNameHidden = buildNameHidden

-- Decides whether one friend (account info + game accounts) is hidden.
-- Any nil or secret value keeps the friend.
local function gameHides(friendIndex, offlineChecked)
    if type(friendIndex) ~= "number" or isSecret(friendIndex) then
        return false
    end
    local account = C_BattleNet.GetFriendAccountInfo(friendIndex)
    if type(account) ~= "table" or isSecret(account) then
        return false
    end
    local primary = readGameInfo(account.gameAccountInfo)
    if not primary or type(primary.isOnline) ~= "boolean" then
        return false
    end
    local gameInfos = {}
    local count = C_BattleNet.GetFriendNumGameAccounts(friendIndex)
    if isSecret(count) then
        return false
    end
    if type(count) == "number" then
        for i = 1, count do
            local info = C_BattleNet.GetFriendGameAccountInfo(friendIndex, i)
            if info ~= nil then
                local copy = readGameInfo(info)
                if not copy then
                    return false
                end
                gameInfos[#gameInfos + 1] = copy
            end
        end
    end
    local isOnline, keys = ns.UI.FriendState({ gameAccountInfo = primary }, gameInfos)
    return ns.UI.ShouldHideBnetElement(true, isOnline, keys, readChecked, offlineChecked)
end

local function classicIsDivider(e)
    return type(e) == "table" and e.buttonType == FRIENDS_BUTTON_TYPE_DIVIDER
end

local function applyClassic(_, provider, gameEnabled)
    if type(provider) ~= "table" or type(provider.GetCollection) ~= "function" then
        return
    end
    local current = provider:GetCollection() or {}

    -- Snapshot rule: keep it when this is the provider we already filtered.
    local snap = snapshots.classic
    if not (snap and snap.provider == provider and snap.sizeAfterEdit == provider:GetSize()) then
        snap = { provider = provider, elements = copyList(current), sizeAfterEdit = #current }
        snapshots.classic = snap
    end

    local offlineChecked = ns.UI.IsOfflineChecked()

    -- Name decision for the whole pass, computed under its own pcall.
    local ids = {}
    for _, e in ipairs(snap.elements) do
        if type(e) == "table" and e.buttonType == FRIENDS_BUTTON_TYPE_BNET
            and not isSecret(e.id) and type(e.id) == "number" then
            ids[#ids + 1] = e.id
        end
    end
    local nameHidden = buildNameHidden(ids)

    local function shouldHide(e)
        if type(e) ~= "table" then
            return false
        end
        if e.buttonType == FRIENDS_BUTTON_TYPE_BNET then
            if gameEnabled ~= false and gameHides(e.id, offlineChecked) then
                return true
            end
            if nameHidden ~= nil then
                local id = e.id
                if isSecret(id) or type(id) ~= "number" then
                    return true
                end
                return nameHidden[id] ~= false
            end
            return false
        end
        if FRIENDS_BUTTON_TYPE_WOW ~= nil and e.buttonType == FRIENDS_BUTTON_TYPE_WOW then
            return nameHidden ~= nil
        end
        return false
    end

    local kept = ns.UI.FilterElements(snap.elements, shouldHide, classicIsDivider)
    if sameList(kept, current) then
        return
    end
    provider:Flush()
    provider:InsertTable(kept)
    snap.sizeAfterEdit = provider:GetSize()
end

Filter.SetApplier("classic", applyClassic)

---------------------------------------------------------------------------
-- SocialUI friends list (tree data provider)
---------------------------------------------------------------------------

local function noDivider()
    return false
end

-- Header nodes carry data with headerText. Spacer and other nodes are skipped.
local function collectHeaders(provider)
    local root = provider:GetRootNode()
    if type(root) ~= "table" or type(root.GetNodes) ~= "function" then
        return nil
    end
    local headers = {}
    for _, node in ipairs(root:GetNodes() or {}) do
        local data = type(node) == "table" and type(node.GetData) == "function" and node:GetData() or nil
        if type(data) == "table" and data.headerText ~= nil
            and type(node.GetNodes) == "function"
            and type(node.Remove) == "function"
            and type(node.InsertNode) == "function" then
            headers[#headers + 1] = node
        end
    end
    return headers
end

local function totalChildren(headers)
    local n = 0
    for _, header in ipairs(headers) do
        n = n + #header:GetNodes()
    end
    return n
end

-- Whether a SocialUI node is a non-Battle.net friend. Returns false until the
-- SocialUI data shape for such friends is verified in game.
local function isNonBnetFriendNode(_)
    return false
end
Filter.isNonBnetFriendNode = isNonBnetFriendNode

local function applySocial(_, provider, gameEnabled)
    if type(provider) ~= "table" or type(provider.GetRootNode) ~= "function"
        or type(provider.Invalidate) ~= "function" then
        return
    end
    local headers = collectHeaders(provider)
    if not headers then
        return
    end

    -- Snapshot rule: keep it when this is the provider we already filtered.
    local snap = snapshots.social
    if not (snap and snap.provider == provider and snap.sizeAfterEdit == totalChildren(headers)) then
        snap = { provider = provider, headers = {}, sizeAfterEdit = 0 }
        for i, header in ipairs(headers) do
            snap.headers[i] = { header = header, nodes = copyList(header:GetNodes()) }
        end
        snapshots.social = snap
    end

    local offlineChecked = ns.UI.IsOfflineChecked()
    local function nodeData(node)
        return type(node) == "table" and type(node.GetData) == "function" and node:GetData() or nil
    end

    -- Name decision for the whole pass, computed under its own pcall.
    local ids = {}
    for _, entry in ipairs(snap.headers) do
        for _, node in ipairs(entry.nodes) do
            local data = nodeData(node)
            if type(data) == "table" and not isSecret(data.friendIndex)
                and type(data.friendIndex) == "number" then
                ids[#ids + 1] = data.friendIndex
            end
        end
    end
    local nameHidden = buildNameHidden(ids)

    local function shouldHide(node)
        local data = nodeData(node)
        if type(data) ~= "table" then
            return false
        end
        if Filter.isNonBnetFriendNode(data) then
            return nameHidden ~= nil
        end
        if data.friendIndex == nil then
            return false
        end
        if gameEnabled ~= false and gameHides(data.friendIndex, offlineChecked) then
            return true
        end
        if nameHidden ~= nil then
            local id = data.friendIndex
            if isSecret(id) or type(id) ~= "number" then
                return true
            end
            return nameHidden[id] ~= false
        end
        return false
    end

    local removedAny = false
    for _, entry in ipairs(snap.headers) do
        local header = entry.header
        local kept = ns.UI.FilterElements(entry.nodes, shouldHide, noDivider)
        local current = header:GetNodes()
        if not sameList(kept, current) then
            local keptSet = {}
            for _, node in ipairs(kept) do
                keptSet[node] = true
            end
            for _, node in ipairs(copyList(current)) do
                if not keptSet[node] then
                    header:Remove(node, true)
                    removedAny = true
                end
            end
            -- Put back friends that became visible, at their snapshot position.
            current = header:GetNodes()
            for i, node in ipairs(kept) do
                if current[i] ~= node then
                    header:InsertNode(node, i)
                    current = header:GetNodes()
                end
            end
        end
    end
    if removedAny then
        provider:Invalidate()
    end
    snap.sizeAfterEdit = totalChildren(headers)
end

Filter.SetApplier("social", applySocial)

---------------------------------------------------------------------------
-- Reapply: re-run the filter on the lists we already filtered
---------------------------------------------------------------------------

local function listFrameFor(kind)
    if kind == "classic" then
        return type(FriendsListFrame) == "table" and FriendsListFrame or nil
    end
    if type(SocialUIFrame) == "table" and type(SocialUIFrame.FriendsList) == "table" then
        return SocialUIFrame.FriendsList
    end
    return nil
end

local function reapplyOne(kind, scrollBox)
    local snap = snapshots[kind]
    if not snap or type(scrollBox) ~= "table" then
        return
    end
    local frame = listFrameFor(kind)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" or not frame:IsShown() then
        return
    end
    if type(scrollBox.GetDataProvider) ~= "function" then
        return
    end
    local provider = scrollBox:GetDataProvider()
    if provider == nil or provider ~= snap.provider then
        return
    end
    run(kind, scrollBox, provider)
end

function Filter.Reapply()
    if Filter.MODE ~= "provider" then
        return
    end
    if not snapshots.classic and not snapshots.social then
        return
    end
    reapplyOne("classic", classicScrollBox())
    reapplyOne("social", socialScrollBox())
end

if type(CreateFrame) == "function" then
    local installFrame = CreateFrame("Frame")
    installFrame:RegisterEvent("PLAYER_LOGIN")
    installFrame:RegisterEvent("ADDON_LOADED")
    installFrame:SetScript("OnEvent", function()
        Filter.Install()
    end)

    local blockedFrame = CreateFrame("Frame")
    blockedFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
    blockedFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    blockedFrame:SetScript("OnEvent", function(_, _, addonName)
        if addonName == ADDON_NAME then
            feedGuard("blocked")
        end
    end)
end
