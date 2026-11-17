local _, ns = ...

local UI = {}
ns.UI = UI

local FRAME_WIDTH, FRAME_HEIGHT = 360, 400
local LINE_HEIGHT = 16
local ROW_GAP = 6
local CHECK_SIZE = 24
local CHECK_GAP = 2
local ICON_SIZE = 20
local HEADER_FONT_SIZE = 14
local MIN_WINDOW_HEIGHT = 120
local MAX_HEIGHT_FRACTION = 0.8
local CHROME_HEIGHT = 66
local NAME_FRAME_HEIGHT = 30  -- name filter window height
local NAME_FRAME_GAP = 2      -- gap between the name window and what it sits above
local NAME_MAX_LETTERS = 64
local OFFLINE_DIVIDER_HEIGHT = 1 + ROW_GAP  -- divider line plus the gap below it
local ICON_RETRIES = 3
local WIDTH_CHROME = 60
local MIN_WIDTH_FRACTION = 0.15
local MAX_WIDTH_FRACTION = 0.5
local SCREEN_WIDTH_FALLBACK = 1024

local REFRESH_DELAY = 0.5
local FRIEND_EVENTS = {
    "BN_FRIEND_INFO_CHANGED",
    "BN_FRIEND_ACCOUNT_ONLINE",
    "BN_FRIEND_ACCOUNT_OFFLINE",
    "BN_FRIEND_LIST_SIZE_CHANGED",
}

local frame, scrollFrame, content
local optionsButton, optionsStrip
local windowIcon

local WINDOW_ICON_SIZE = 36
UI.ICON_TEXTURE = "Interface\\AddOns\\ForeverFilter\\Textures\\ForeverFilter_64"
-- Session state for the options strip, not saved.
local optionsOpen = false
local sliderDragging = false  -- used by the slider handlers
local syncing = false         -- used by the slider sync code
local nameText = ""           -- raw text of the Name input, session only, never saved
local lines = {}
local refreshPending = false
local retriesLeft = ICON_RETRIES

local function val(v)
    if v == nil or v == "" then
        return "?"
    end
    return tostring(v)
end

-- Same key as Friends.GroupByGame: project ID only counts for WoW.
function UI.GameKey(game, projectID)
    if game == "@apps" then return UI.APPS_KEY end
    local g = game or "?"
    local pid = nil
    if g == "WoW" then
        pid = projectID
    end
    return g .. ":" .. tostring(pid)
end

-- Pure: window width fits the widest header, clamped to 15%-50% of the screen.
function UI.ComputeWindowWidth(textWidths, screenWidth, isEmpty)
    local screen = (type(screenWidth) == "number" and screenWidth > 0) and screenWidth or SCREEN_WIDTH_FALLBACK
    local minW = math.floor(screen * MIN_WIDTH_FRACTION)
    local maxW = math.max(minW, math.floor(screen * MAX_WIDTH_FRACTION))
    if isEmpty then return minW end
    local widest = 0
    for _, w in ipairs(textWidths or {}) do
        if type(w) == "number" and w > widest then widest = w end
    end
    local want = WIDTH_CHROME + CHECK_SIZE + CHECK_GAP + math.ceil(widest)
    return math.min(maxW, math.max(minW, want))
end

UI.ATTACH_GAP = 4

local function isFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

UI.DEFAULT_SCALE = 0.85
UI.MIN_SCALE = 0.5
UI.MAX_SCALE = 1.5

-- Pure: true for a finite number from MIN_SCALE to MAX_SCALE inclusive.
function UI.IsValidScale(v)
    return isFinite(v) and v >= UI.MIN_SCALE and v <= UI.MAX_SCALE
end

-- Pure: v when valid, else DEFAULT_SCALE.
function UI.NormalizeScale(v)
    if UI.IsValidScale(v) then return v end
    return UI.DEFAULT_SCALE
end

UI.SCALE_STEP = 0.05
UI.DEFAULT_SHOW_COUNTS = true
UI.DEFAULT_ALWAYS_SHOW_NAME_FILTER = true

local SLIDER_SCREEN_WIDTH = 140   -- on-screen width of the slider
local SLIDER_MARGIN       = 18    -- on-screen left and right margin of the slider
local SLIDER_SLOT         = 36    -- on-screen height of the label and slider rows
local STRIP_ROWS_HEIGHT   = 86    -- window units: two checkbox rows, reset row, padding
local STRIP_MIN_CONTENT   = 250   -- window units: checkbox row and reset button width

-- Pure: nearest multiple of SCALE_STEP within MIN_SCALE..MAX_SCALE, rounded to 2 decimals.
-- DEFAULT_SCALE for a non-number, NaN or infinity.
function UI.SnapScale(v)
    if not isFinite(v) then return UI.DEFAULT_SCALE end
    if v < UI.MIN_SCALE then v = UI.MIN_SCALE end
    if v > UI.MAX_SCALE then v = UI.MAX_SCALE end
    local n = math.floor((v - UI.MIN_SCALE) / UI.SCALE_STEP + 0.5)
    local r = UI.MIN_SCALE + n * UI.SCALE_STEP
    r = math.floor(r * 100 + 0.5) / 100
    if r < UI.MIN_SCALE then r = UI.MIN_SCALE end
    if r > UI.MAX_SCALE then r = UI.MAX_SCALE end
    return r
end

-- Pure: pointer offset along the slider (0 at left end, width at right end) to a snapped value.
-- DEFAULT_SCALE when width is not a positive finite number.
function UI.SliderValueFromOffset(offset, width)
    if not (isFinite(width) and width > 0) then return UI.DEFAULT_SCALE end
    if not isFinite(offset) then return UI.DEFAULT_SCALE end
    return UI.SnapScale(UI.MIN_SCALE + (offset / width) * (UI.MAX_SCALE - UI.MIN_SCALE))
end

-- Pure: parses the text after "scale". Returns "show"|"reset"|"set"|"error", value.
function UI.ParseScaleArg(text)
    if type(text) ~= "string" then return "error" end
    text = text:match("^%s*(.-)%s*$"):lower()
    if text == "" then return "show" end
    if text == "reset" then return "reset" end
    if not (text:match("^%d+%.?%d*$") or text:match("^%.%d+$")) then return "error" end
    local n = tonumber(text)
    if UI.IsValidScale(n) then return "set", n end
    return "error"
end

-- Pure: minimal shift that puts the window inside [0, screenW] x [0, screenH].
-- TOPLEFT is (left, top) measured from the bottom-left of the screen.
-- An axis where the window is larger than the screen aligns to the left/top edge.
function UI.ClampToScreen(left, top, w, h, screenW, screenH)
    local l, t = left, top
    if w > screenW then
        l = 0
    elseif l < 0 then
        l = 0
    elseif l + w > screenW then
        l = screenW - w
    end
    if h > screenH then
        t = screenH
    elseif t > screenH then
        t = screenH
    elseif t - h < 0 then
        t = h
    end
    return l, t
end

-- Pure: side and TOPLEFT of the window beside the social menu.
-- Returns left, top, side ("right", "left" or "clamped"), or nil for unusable input.
function UI.ComputeAttachPosition(socialLeft, socialRight, socialTop, socialScale, uiScale,
                                  uiWidth, uiHeight, w, h, gap)
    if not (isFinite(socialLeft) and isFinite(socialRight) and isFinite(socialTop)
        and isFinite(socialScale) and isFinite(uiScale) and isFinite(uiWidth)
        and isFinite(uiHeight) and isFinite(w) and isFinite(h) and isFinite(gap)
        and socialScale > 0 and uiScale > 0) then
        return nil
    end
    local k = socialScale / uiScale
    local rightLeft = socialRight * k + gap
    local leftLeft = socialLeft * k - gap - w
    local top = socialTop * k
    local function fits(x)
        return x >= 0 and x + w <= uiWidth
    end
    local left, side
    if fits(rightLeft) then
        left, side = rightLeft, "right"
    elseif fits(leftLeft) then
        left, side = leftLeft, "left"
    else
        left, side = rightLeft, "clamped"
    end
    left, top = UI.ClampToScreen(left, top, w, h, uiWidth, uiHeight)
    return left, top, side
end

-- Pure: header width for a given window width.
function UI.HeaderWidth(windowWidth)
    return math.max(1, windowWidth - WIDTH_CHROME - CHECK_SIZE - CHECK_GAP)
end

-- Pure: window height clamped between MIN_WINDOW_HEIGHT and 80% of the screen.
function UI.ComputeWindowHeight(rowArea, screenHeight, isEmpty)
    if isEmpty then return MIN_WINDOW_HEIGHT end
    local screen = (type(screenHeight) == "number" and screenHeight > 0) and screenHeight or FRAME_HEIGHT
    local maxH = math.max(MIN_WINDOW_HEIGHT, math.floor(screen * MAX_HEIGHT_FRACTION))
    local want = CHROME_HEIGHT + math.max(0, tonumber(rowArea) or 0)
    return math.min(maxH, math.max(MIN_WINDOW_HEIGHT, want))
end

-- Pure: options strip height in window units for a window scale.
function UI.StripHeight(scale)
    return STRIP_ROWS_HEIGHT + SLIDER_SLOT / UI.NormalizeScale(scale)
end

-- Pure: smallest window width (window units) at which the open strip fits.
function UI.StripMinWidth(scale)
    local s = UI.NormalizeScale(scale)
    return math.max(STRIP_MIN_CONTENT, math.ceil((SLIDER_SCREEN_WIDTH + 2 * SLIDER_MARGIN) / s))
end

-- Pure: window height with the options strip. A nil or 0 stripHeight gives ComputeWindowHeight.
function UI.ComputeWindowHeightWithStrip(rowArea, screenHeight, isEmpty, stripHeight)
    if type(stripHeight) ~= "number" or stripHeight == 0 then
        return UI.ComputeWindowHeight(rowArea, screenHeight, isEmpty)
    end
    if not isEmpty then
        return UI.ComputeWindowHeight(math.max(0, tonumber(rowArea) or 0) + stripHeight, screenHeight, false)
    end
    local screen = (type(screenHeight) == "number" and screenHeight > 0) and screenHeight or FRAME_HEIGHT
    local maxH = math.max(MIN_WINDOW_HEIGHT, math.floor(screen * MAX_HEIGHT_FRACTION))
    return math.min(maxH, MIN_WINDOW_HEIGHT + stripHeight)
end

-- Pure: window width with the options strip. A nil or 0 stripMinWidth gives ComputeWindowWidth.
function UI.ComputeWindowWidthWithStrip(textWidths, screenWidth, isEmpty, stripMinWidth)
    local w = UI.ComputeWindowWidth(textWidths, screenWidth, isEmpty)
    if type(stripMinWidth) ~= "number" or stripMinWidth == 0 then return w end
    return math.max(w, stripMinWidth)
end

-- Pure: row height is the larger of the checkbox and the header text.
function UI.RowHeight(stringHeight)
    local h = LINE_HEIGHT
    if type(stringHeight) == "number" and stringHeight >= 1 then
        h = stringHeight
    end
    return math.max(CHECK_SIZE, h)
end

-- Pure: returns schedule, newRetriesLeft.
function UI.NextRetry(pending, retriesLeft)
    if pending == true and retriesLeft > 0 then
        return true, retriesLeft - 1
    end
    return false, retriesLeft
end

-- Returns the saved check-state table, creating or repairing it.
local function getStore()
    local db = ns.db
    if type(db) ~= "table" then
        db = ForeverFilterDB
        if type(db) ~= "table" then
            ForeverFilterDB = {}
            db = ForeverFilterDB
        end
    end
    if type(db.checkedGames) ~= "table" then
        db.checkedGames = {}
    end
    return db.checkedGames
end

-- Missing or non-boolean entries count as checked. Never adds an entry.
function UI.IsChecked(game, projectID)
    if game == "@apps" then return UI.IsAppsChecked() end
    local v = getStore()[UI.GameKey(game, projectID)]
    if type(v) == "boolean" then
        return v
    end
    return true
end

function UI.SetChecked(game, projectID, checked)
    if game == "@apps" then return UI.SetAppsChecked(checked) end
    getStore()[UI.GameKey(game, projectID)] = checked and true or false
end

-- Reserved key of the Battle.net apps row (same value as Friends.APPS_GAME).
UI.APPS_KEY = "@apps"

-- A boolean under APPS_KEY wins. Otherwise the row is unchecked only when both
-- legacy app keys are false. Never writes or deletes an entry.
function UI.IsAppsChecked()
    local store = getStore()
    local v = store[UI.APPS_KEY]
    if type(v) == "boolean" then
        return v
    end
    if store["App:nil"] == false and store["BSAp:nil"] == false then
        return false
    end
    return true
end

function UI.SetAppsChecked(checked)
    getStore()[UI.APPS_KEY] = checked and true or false
end

-- Reserved key of the Offline row. Every game key contains ":", so it never collides.
UI.OFFLINE_KEY = "@offline"

-- Missing or non-boolean entries count as checked. Never adds an entry.
function UI.IsOfflineChecked()
    local v = getStore()[UI.OFFLINE_KEY]
    if type(v) == "boolean" then
        return v
    end
    return true
end

function UI.SetOfflineChecked(checked)
    getStore()[UI.OFFLINE_KEY] = checked and true or false
end

-- The divider above the Offline row shows only when a game row exists.
function UI.OfflineDividerVisible(gameRowCount)
    return type(gameRowCount) == "number" and gameRowCount > 0
end

-- True iff the friend is online, has games, and every game key is unchecked.
function UI.ShouldHideFriend(friendGames, isOnline, isChecked)
    if isOnline ~= true then return false end
    if type(friendGames) ~= "table" or type(isChecked) ~= "function" then return false end
    local any = false
    for _, key in ipairs(friendGames) do
        any = true
        if isChecked(key) ~= false then return false end
    end
    return any
end

-- True iff the friend is not online and the Offline row is unchecked.
function UI.ShouldHideOfflineFriend(isOnline, isChecked)
    return isOnline ~= true and isChecked == false
end

-- Returns the input with leading and trailing whitespace removed, "" for non-strings.
function UI.NameQuery(input)
    if type(input) ~= "string" then return "" end
    return (input:match("^%s*(.-)%s*$")) or ""
end

-- ASCII-only lowercase: only A-Z change, every other byte is untouched.
function UI.AsciiLower(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end))
end

-- True when query occurs (plain text, ASCII case-insensitive) in a non-empty string entry.
function UI.NameMatch(query, names)
    if type(query) ~= "string" or query == "" or type(names) ~= "table" then return false end
    local q = UI.AsciiLower(query)
    for i = 1, table.maxn(names) do
        local name = names[i]
        if type(name) == "string" and name ~= "" and UI.AsciiLower(name):find(q, 1, true) then
            return true
        end
    end
    return false
end

-- Name decision for one friend: false for an empty query, else hidden unless a name matches.
function UI.NameFilterHides(query, names)
    if type(query) ~= "string" or query == "" then return false end
    return not UI.NameMatch(query, names)
end

-- Stores the raw name text. Non-strings become "".
function UI.SetNameText(text)
    if type(text) ~= "string" then text = "" end
    nameText = text
end

-- The trimmed name query for the current session text.
function UI.GetNameQuery()
    return UI.NameQuery(nameText)
end

-- Name input changed: store the text and reapply the filter. No Refresh, no saved data.
function UI.OnNameChanged(text)
    UI.SetNameText(text)
    if ns.Filter and ns.Filter.Reapply then
        ns.Filter.Reapply()
    end
end

-- Element decision: unknown or non-Battle.net elements are always kept.
function UI.ShouldHideBnetElement(isBnetFriend, isOnline, keys, isChecked, offlineChecked)
    if isBnetFriend ~= true then return false end
    if isOnline == nil then return false end
    if isOnline == true then
        return UI.ShouldHideFriend(keys, true, isChecked)
    end
    if isOnline == false then
        return UI.ShouldHideOfflineFriend(false, offlineChecked)
    end
    return false
end

local function nonEmptyString(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- Game key of one online game account, same rules as Friends.GetAll + Friends.GroupByGame.
local function keyOfGameInfo(info)
    local game = nonEmptyString(info.clientProgram)
    local pid = info.wowProjectID
    if not (type(pid) == "number" and pid > 0) then pid = nil end
    return UI.GameKey(game, pid)
end

-- Game keys of one friend, first-seen order, no duplicates. Uses every online
-- game account; falls back to primaryInfo when none qualifies.
function UI.FriendGameKeys(gameInfos, primaryInfo)
    local keys, seen = {}, {}
    local F = ns.Friends
    if type(F) ~= "table" or type(F.PresenceGames) ~= "function" then return keys end
    for _, info in ipairs(F.PresenceGames(gameInfos, primaryInfo) or {}) do
        if type(info) == "table" then
            local key
            if F.IsAppClient(nonEmptyString(info.clientProgram)) then
                key = UI.APPS_KEY
            else
                key = keyOfGameInfo(info)
            end
            if not seen[key] then
                seen[key] = true
                keys[#keys + 1] = key
            end
        end
    end
    return keys
end

-- Returns isOnline (true, false or nil when unknown) and the friend's game keys.
function UI.FriendState(accountInfo, gameInfos)
    if type(accountInfo) ~= "table" then return nil, {} end
    local primary = accountInfo.gameAccountInfo
    if type(primary) ~= "table" or type(primary.isOnline) ~= "boolean" then
        return nil, {}
    end
    local keys = UI.FriendGameKeys(gameInfos, primary)
    return (primary.isOnline or #keys > 0), keys
end

-- Returns kept (a new list), hiddenCount. shouldHide is only called for non-dividers.
-- With nothing hidden the input is copied as is. Otherwise hidden elements are dropped
-- and dividers that lead, trail, or follow another divider are dropped too.
function UI.FilterElements(elements, shouldHide, isDivider)
    local kept, hidden = {}, 0
    for _, e in ipairs(elements or {}) do
        if isDivider(e) or not shouldHide(e) then
            kept[#kept + 1] = e
        else
            hidden = hidden + 1
        end
    end
    if hidden == 0 then return kept, 0 end

    -- afterCount[i]: true when a non-divider exists at a position after i.
    local n = #kept
    local nonDividerAfter = {}
    local seen = false
    for i = n, 1, -1 do
        nonDividerAfter[i] = seen
        if not isDivider(kept[i]) then seen = true end
    end

    local result, seenBefore, lastIsDivider = {}, false, false
    for i = 1, n do
        local e = kept[i]
        if isDivider(e) then
            if seenBefore and nonDividerAfter[i] and not lastIsDivider then
                result[#result + 1] = e
                lastIsDivider = true
            end
        else
            result[#result + 1] = e
            seenBefore = true
            lastIsDivider = false
        end
    end
    return result, hidden
end

-- Failure latch for the friends list filter. state = { disabled, announced }.
-- "error" and "blocked" disable filtering; the first one returns action "announce".
-- Never mutates its input.
function UI.NextFilterGuard(state, event)
    local disabled = type(state) == "table" and state.disabled == true
    local announced = type(state) == "table" and state.announced == true
    if event == "error" or event == "blocked" then
        local action = nil
        if not announced then action = "announce" end
        return { disabled = true, announced = true }, action
    end
    return { disabled = disabled, announced = announced }, nil
end

-- Returns the saved-variables table (ns.db, else ForeverFilterDB, created if missing).
-- Creates no window settings.
local function getDb()
    local db = ns.db
    if type(db) ~= "table" then
        db = ForeverFilterDB
        if type(db) ~= "table" then
            ForeverFilterDB = {}
            db = ForeverFilterDB
        end
    end
    return db
end

-- Pure read: returns moved, left, top. moved is true only for boolean true
-- plus finite left and top. Never writes to db.
function UI.ReadWindowSettings(db)
    local w = type(db) == "table" and db.window or nil
    if type(w) == "table" and w.moved == true and isFinite(w.left) and isFinite(w.top) then
        return true, w.left, w.top
    end
    return false, nil, nil
end

function UI.WriteWindowSettings(db, left, top)
    db.window = { moved = true, left = left, top = top }
end

function UI.ResetWindowSettings(db)
    db.window = nil
end

-- Pure: reads db.windowScale through NormalizeScale; never writes.
function UI.ReadScale(db)
    if type(db) ~= "table" then return UI.DEFAULT_SCALE end
    return UI.NormalizeScale(db.windowScale)
end

-- Current saved window scale (default when unset or invalid).
function UI.GetScale()
    return UI.ReadScale(getDb())
end

-- Stores a valid scale; returns true on success, false otherwise.
function UI.WriteScale(db, v)
    if type(db) ~= "table" then return false end
    if not UI.IsValidScale(v) then return false end
    db.windowScale = v
    return true
end

function UI.ResetScale(db)
    if type(db) ~= "table" then return end
    db.windowScale = nil
end

-- Pure read: the boolean in db.showPlayerCounts, else DEFAULT_SHOW_COUNTS. Never writes.
function UI.ReadShowCounts(db)
    if type(db) == "table" and type(db.showPlayerCounts) == "boolean" then
        return db.showPlayerCounts
    end
    return UI.DEFAULT_SHOW_COUNTS
end

-- Stores a boolean; returns true on success, false (no change) otherwise.
function UI.WriteShowCounts(db, b)
    if type(db) ~= "table" or type(b) ~= "boolean" then return false end
    db.showPlayerCounts = b
    return true
end

function UI.ResetShowCounts(db)
    if type(db) ~= "table" then return end
    db.showPlayerCounts = nil
end

-- Pure read: the boolean in db.alwaysShowNameFilter, else DEFAULT_ALWAYS_SHOW_NAME_FILTER. Never writes.
function UI.ReadAlwaysShowNameFilter(db)
    if type(db) == "table" and type(db.alwaysShowNameFilter) == "boolean" then
        return db.alwaysShowNameFilter
    end
    return UI.DEFAULT_ALWAYS_SHOW_NAME_FILTER
end

-- Stores a boolean; returns true on success, false (no change) otherwise.
function UI.WriteAlwaysShowNameFilter(db, b)
    if type(db) ~= "table" or type(b) ~= "boolean" then return false end
    db.alwaysShowNameFilter = b
    return true
end

-- Pure: the name window shows with the games window, or with a social frame when the option is on.
function UI.NameFilterVisible(alwaysShow, socialOpen, gamesShown)
    if gamesShown == true then return true end
    return alwaysShow == true and socialOpen == true
end

-- Removes windowScale, showPlayerCounts and alwaysShowNameFilter only.
function UI.ResetOptions(db)
    if type(db) ~= "table" then return end
    db.windowScale = nil
    db.showPlayerCounts = nil
    db.alwaysShowNameFilter = nil
end

-- Pure: header text, with the " (count)" suffix only when showCounts is true.
function UI.FormatHeader(label, debugId, count, showCounts)
    local text = tostring(label) .. tostring(debugId or "")
    if not showCounts then return text end
    local n = 0
    if isFinite(count) and count > 0 then
        n = math.floor(count)
    end
    return string.format("%s (%d)", text, n)
end

-- Pure unit conversion between frame units and UIParent units.
function UI.FrameToUIParent(v, scale)
    return v * scale
end

function UI.UIParentToFrame(v, scale)
    return v / scale
end

-- Pure: returns kind ("saved", "attached", "default"), left, top, side.
function UI.ResolvePlacement(db, social, w, h, screenW, screenH)
    local moved, sl, st = UI.ReadWindowSettings(db)
    if moved then
        local l, t = UI.ClampToScreen(sl, st, w, h, screenW, screenH)
        return "saved", l, t, nil
    end
    if type(social) == "table" then
        local l, t, side = UI.ComputeAttachPosition(social.left, social.right, social.top,
            social.scale, social.uiScale, screenW, screenH, w, h, UI.ATTACH_GAP)
        if l ~= nil then
            return "attached", l, t, side
        end
    end
    return "default", nil, nil, nil
end

-- Pure: placement at a scale. Returns kind, offsetX, offsetY (frame units), side.
function UI.ComputeScaledPlacement(db, social, w, h, scale, screenW, screenH)
    local s = UI.NormalizeScale(scale)
    local kind, left, top, side = UI.ResolvePlacement(db, social, w * s, h * s, screenW, screenH)
    if kind == "default" then
        return "default"
    end
    return kind, left / s, top / s, side
end

-- Pure: the "open with friends list" preference. true unless db.openWithFriends is boolean false.
function UI.ReadOpenWithFriends(db)
    if type(db) == "table" and db.openWithFriends == false then
        return false
    end
    return true
end

-- Pure: state = { autoOpened, dismissed }. Returns newState, action ("show", "hide" or nil).
-- Never mutates state or ctx.
function UI.NextSocialState(state, event, ctx)
    local s = type(state) == "table" and state or {}
    local c = type(ctx) == "table" and ctx or {}
    local autoOpened, dismissed = s.autoOpened == true, s.dismissed == true
    local action = nil

    if event == "social_shown" then
        -- ctx.openWithFriends == false (the saved preference) turns auto-open off.
        -- ctx.freshOpen == true: no other social frame was open, so a stale dismissal never overrides the preference.
        if c.windowShown ~= true and (not dismissed or c.freshOpen == true) and c.openWithFriends ~= false then
            autoOpened = true
            action = "show"
        end
    elseif event == "social_hidden" then
        if c.anySocialOpen ~= true then
            dismissed = false
            if c.windowShown == true then
                action = "hide"
            end
        end
    elseif event == "window_hidden" then
        autoOpened = false
        if c.anySocialOpen == true then
            dismissed = true
        end
    elseif event == "manual_show" then
        autoOpened = false
        dismissed = false
    end

    return { autoOpened = autoOpened, dismissed = dismissed }, action
end

-- Session state, not saved.
local socialState = { autoOpened = false, dismissed = false }
-- Hooked social frames: name -> frame object.
local hooked = {}

local function countSocialOpen()
    local n = 0
    for _, f in pairs(hooked) do
        if type(f) == "table" and type(f.IsShown) == "function" then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then n = n + 1 end
        end
    end
    return n
end

local function anySocialOpen()
    for _, f in pairs(hooked) do
        if type(f) == "table" and type(f.IsShown) == "function" then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then
                return true
            end
        end
    end
    return false
end

-- Read-only: returns { left, right, top, scale } of the first shown hooked frame, or nil.
local function readSocialGeometry()
    for _, f in pairs(hooked) do
        if type(f) == "table" and type(f.IsShown) == "function" then
            local okShown, shown = pcall(f.IsShown, f)
            if okShown and shown then
                local okL, left = pcall(f.GetLeft, f)
                local okR, right = pcall(f.GetRight, f)
                local okT, top = pcall(f.GetTop, f)
                local okS, scale = pcall(f.GetEffectiveScale, f)
                if okL and okR and okT and okS
                    and isFinite(left) and isFinite(right) and isFinite(top) and isFinite(scale) then
                    return { left = left, right = right, top = top, scale = scale }
                end
                return nil
            end
        end
    end
    return nil
end

function UI.PlaceWindow()
    if not frame or not UIParent then
        return
    end
    local social = readSocialGeometry()
    if social then
        social.uiScale = UIParent:GetEffectiveScale()
    end
    local s = frame:GetScale()
    local kind, left, top = UI.ComputeScaledPlacement(getDb(), social, frame:GetWidth(), frame:GetHeight(),
        s, UIParent:GetWidth(), UIParent:GetHeight())
    if kind == "saved" or kind == "attached" then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
end

-- Options strip functions, defined after ApplyScale below.
local layoutOptions, syncOptions

-- Applies the saved scale to the window, keeping its TOPLEFT at the same UIParent
-- point (clamped to the screen). Never writes window settings and never shows the window.
local function ApplyScale()
    if not frame then
        return
    end
    local oldScale = frame:GetScale()
    local left, top = frame:GetLeft(), frame:GetTop()
    local captured = type(left) == "number" and type(top) == "number"
    if captured then
        left = UI.FrameToUIParent(left, oldScale)
        top = UI.FrameToUIParent(top, oldScale)
    end
    local s = UI.GetScale()
    frame:SetScale(s)
    if captured and UIParent then
        left, top = UI.ClampToScreen(left, top, frame:GetWidth() * s, frame:GetHeight() * s,
            UIParent:GetWidth(), UIParent:GetHeight())
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            UI.UIParentToFrame(left, s), UI.UIParentToFrame(top, s))
    end
    if optionsStrip then
        layoutOptions()
        syncOptions()
    end
    if frame:IsShown() then
        -- While the slider thumb is held, moving the window would move the slider away from the pointer.
        if not sliderDragging then
            UI.PlaceWindow()
        end
        -- Strip height and minimum width depend on the scale.
        if optionsOpen then
            UI.Refresh()
        end
    end
end

-- Options strip (created on first use). Controls are plain, non-secure frames.
local STRIP_TOP = 24          -- window units: strip distance below the top of the window
local SLIDER_LABEL_ROOM = 16  -- on-screen room above the slider for the label row
local optionsFailed = false
local scaleSlider, scaleValueText, countCheck, nameCheck, resetButton

local function formatScaleText(v)
    local text = string.format("%.2f", v)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

layoutOptions = function()
    if not (frame and optionsStrip and scaleSlider) then
        return
    end
    local s = frame:GetScale()
    if not (type(s) == "number" and s > 0) then
        s = 1
    end
    scaleSlider:SetScale(1 / s)
    scaleSlider:ClearAllPoints()
    scaleSlider:SetPoint("TOPLEFT", frame, "TOPLEFT", SLIDER_MARGIN, -(STRIP_TOP * s + SLIDER_LABEL_ROOM))
    scaleSlider:SetWidth(SLIDER_SCREEN_WIDTH)
    local slot = SLIDER_SLOT / s
    countCheck:ClearAllPoints()
    countCheck:SetPoint("TOPLEFT", optionsStrip, "TOPLEFT", 8, -slot)
    nameCheck:ClearAllPoints()
    nameCheck:SetPoint("TOPLEFT", optionsStrip, "TOPLEFT", 8, -(slot + 26))
    resetButton:ClearAllPoints()
    resetButton:SetPoint("TOPLEFT", optionsStrip, "TOPLEFT", 12, -(slot + 54))
end

syncOptions = function()
    if not (optionsStrip and scaleSlider) then
        return
    end
    syncing = true
    local v = UI.GetScale()
    scaleSlider:SetValue(v)
    scaleValueText:SetText(formatScaleText(v))
    countCheck:SetChecked(UI.ReadShowCounts(getDb()))
    nameCheck:SetChecked(UI.ReadAlwaysShowNameFilter(getDb()))
    syncing = false
end

local function createOptions()
    local parent = frame.InsetBg or frame
    local strip = CreateFrame("Frame", nil, frame)
    strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    strip:SetHeight(1)
    strip:Hide()
    optionsStrip = strip

    local slider
    local okT, created = pcall(CreateFrame, "Slider", nil, strip, "OptionsSliderTemplate")
    if okT and created then
        slider = created
        for _, name in ipairs({ "Text", "Low", "High" }) do
            local part = slider[name]
            if part and part.SetText then
                part:SetText("")
            end
        end
    else
        slider = CreateFrame("Slider", nil, strip)
        slider:SetOrientation("HORIZONTAL")
        slider:SetHeight(17)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    slider:SetMinMaxValues(UI.MIN_SCALE, UI.MAX_SCALE)
    slider:SetValueStep(UI.SCALE_STEP)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end

    local label = slider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)
    label:SetText("Scale")
    scaleValueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scaleValueText:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", 0, 2)
    scaleValueText:SetText(formatScaleText(UI.GetScale()))

    slider:SetScript("OnMouseDown", function()
        sliderDragging = true
    end)
    slider:SetScript("OnMouseUp", function()
        sliderDragging = false
        UI.PlaceWindow()
    end)
    slider:SetScript("OnValueChanged", function(_, raw)
        if syncing then
            return
        end
        local v = UI.SnapScale(raw)
        UI.WriteScale(getDb(), v)
        ApplyScale()
        scaleValueText:SetText(formatScaleText(v))
    end)
    scaleSlider = slider

    local check = CreateFrame("CheckButton", nil, strip, "UICheckButtonTemplate")
    check:SetSize(CHECK_SIZE, CHECK_SIZE)
    local checkText = check.Text or check.text
    if not checkText then
        checkText = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        checkText:SetPoint("LEFT", check, "RIGHT", CHECK_GAP, 0)
    end
    checkText:SetText("Show player counts")
    check:SetScript("OnClick", function(self)
        UI.WriteShowCounts(getDb(), self:GetChecked() and true or false)
        UI.Refresh()
    end)
    countCheck = check

    local nameBox = CreateFrame("CheckButton", nil, strip, "UICheckButtonTemplate")
    nameBox:SetSize(CHECK_SIZE, CHECK_SIZE)
    local nameBoxText = nameBox.Text or nameBox.text
    if not nameBoxText then
        nameBoxText = nameBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameBoxText:SetPoint("LEFT", nameBox, "RIGHT", CHECK_GAP, 0)
    end
    nameBoxText:SetText("Always Show Name Filter")
    nameBox:SetScript("OnClick", function(self)
        UI.WriteAlwaysShowNameFilter(getDb(), self:GetChecked() and true or false)
        pcall(UI.UpdateNameFrame)
    end)
    nameCheck = nameBox

    local reset = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetText("Reset to defaults")
    reset:SetScript("OnClick", function()
        UI.ResetOptions(getDb())
        ApplyScale()
        syncOptions()
        pcall(UI.UpdateNameFrame)
        UI.Refresh()
    end)
    resetButton = reset
end

-- Creates the strip once. Returns true when it exists; false (silently) when creation failed.
local function ensureOptions()
    if optionsStrip and not optionsFailed then
        return true
    end
    if optionsFailed or not frame then
        return false
    end
    local ok = pcall(createOptions)
    if not ok then
        optionsFailed = true
        if optionsStrip then
            pcall(optionsStrip.Hide, optionsStrip)
        end
        optionsStrip, scaleSlider, scaleValueText, countCheck, nameCheck, resetButton = nil, nil, nil, nil, nil, nil
        return false
    end
    layoutOptions()
    return true
end

function UI.ToggleOptions()
    if not ensureOptions() then
        return
    end
    optionsOpen = not optionsOpen
    if optionsOpen then
        layoutOptions()
        optionsStrip:Show()
        syncOptions()
    else
        optionsStrip:Hide()
    end
    if frame:IsShown() then
        UI.Refresh()
    end
end

local function scaleRangeText()
    return string.format("%g to %g", UI.MIN_SCALE, UI.MAX_SCALE)
end

function UI.HandleScaleCommand(argText)
    local kind, value = UI.ParseScaleArg(argText)
    if kind == "show" then
        print(string.format("Forever Filter: window scale is %g (allowed %s, default %g).",
            UI.GetScale(), scaleRangeText(), UI.DEFAULT_SCALE))
    elseif kind == "set" then
        UI.WriteScale(getDb(), value)
        ApplyScale()
        print(string.format("Forever Filter: window scale set to %g.", value))
    elseif kind == "reset" then
        UI.ResetScale(getDb())
        ApplyScale()
        print(string.format("Forever Filter: window scale reset to %g.", UI.DEFAULT_SCALE))
    else
        print(string.format("Forever Filter: scale must be a number from %s.", scaleRangeText()))
    end
end

UI.SOCIAL_FRAME_NAMES = { "FriendsFrame", "SocialUIFrame" }

-- Name filter window: a small frame with one edit box and a grey placeholder.
local nameFrame, nameInput, namePlaceholder

local function updatePlaceholder()
    if not (namePlaceholder and nameInput) then return end
    local text = nameInput:GetText()
    local focused = nameInput.HasFocus and nameInput:HasFocus()
    if (text == nil or text == "") and not focused then
        namePlaceholder:Show()
    else
        namePlaceholder:Hide()
    end
end

local function createNameFrame()
    local okF, f = pcall(CreateFrame, "Frame", "ForeverFilterNameFrame", UIParent, "BackdropTemplate")
    if not (okF and f) then
        f = CreateFrame("Frame", "ForeverFilterNameFrame", UIParent)
    end
    f:SetHeight(NAME_FRAME_HEIGHT)
    f:SetFrameStrata("MEDIUM")
    pcall(function()
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            f:SetBackdropColor(0, 0, 0, 0.8)
        end
    end)
    f:Hide()
    nameFrame = f

    local okE, box = pcall(CreateFrame, "EditBox", nil, f, "InputBoxTemplate")
    if not (okE and box) then
        box = CreateFrame("EditBox", nil, f)
        box:SetFontObject("ChatFontNormal")
    end
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -4)
    box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 4)
    box:SetAutoFocus(false)
    box:SetMaxLetters(NAME_MAX_LETTERS)
    box:SetText(nameText)
    box:SetScript("OnTextChanged", function(self)
        updatePlaceholder()
        UI.OnNameChanged(self:GetText())
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusGained", updatePlaceholder)
    box:SetScript("OnEditFocusLost", updatePlaceholder)
    nameInput = box

    namePlaceholder = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    namePlaceholder:SetPoint("LEFT", box, "LEFT", 0, 0)
    namePlaceholder:SetText("Filter Friends")
    updatePlaceholder()
end

-- First shown hooked social frame, in SOCIAL_FRAME_NAMES order.
local function firstShownSocialFrame()
    for _, name in ipairs(UI.SOCIAL_FRAME_NAMES) do
        local f = hooked[name]
        if type(f) == "table" and type(f.IsShown) == "function" then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then return f end
        end
    end
    return nil
end

-- Anchors the name window above the first shown social frame, else above the games window.
local function anchorNameFrame()
    if not nameFrame then return end
    local target = firstShownSocialFrame()
    if not target and frame and frame:IsShown() then
        target = frame
    end
    if not target then return end
    pcall(function()
        nameFrame:ClearAllPoints()
        nameFrame:SetPoint("BOTTOMLEFT", target, "TOPLEFT", 0, NAME_FRAME_GAP)
        -- Width in the target's own units, scale relative to UIParent (the name window's parent).
        local w, s
        if target == frame then
            w, s = target:GetWidth(), target:GetScale()
        else
            local l, r = target:GetLeft(), target:GetRight()
            if isFinite(l) and isFinite(r) then w = r - l end
            local eff, ui = target:GetEffectiveScale(), UIParent:GetEffectiveScale()
            if isFinite(eff) and isFinite(ui) and ui > 0 then s = eff / ui end
        end
        if isFinite(w) and w > 0 then nameFrame:SetWidth(w) end
        if isFinite(s) and s > 0 then nameFrame:SetScale(s) end
    end)
end

-- Shows or hides the name window per UI.NameFilterVisible. Hiding keeps the text and the filter.
function UI.UpdateNameFrame()
    local visible = UI.NameFilterVisible(UI.ReadAlwaysShowNameFilter(getDb()), anySocialOpen(),
        frame ~= nil and frame:IsShown() == true)
    if visible then
        if not nameFrame then createNameFrame() end
        anchorNameFrame()
        nameFrame:Show()
        updatePlaceholder()
    elseif nameFrame then
        nameFrame:Hide()
    end
end

-- Set while our own code hides the window (friends list closing), so the OnHide safety net never saves.
local internalHide = false

local function escapeIsDown()
    if type(IsKeyDown) ~= "function" then return false end
    local ok, down = pcall(IsKeyDown, "ESCAPE")
    return ok and down == true
end

-- The player closed the games window: remember it (same value the icon button saves).
function UI.SaveWindowClosedChoice()
    getDb().openWithFriends = false
end

-- Hide for our own reasons (friends list closed). Never saves the preference.
function UI.HideInternal()
    internalHide = true
    pcall(UI.Hide)
    internalHide = false
end

local function create()
    frame = CreateFrame("Frame", "ForeverFilterFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetScale(UI.GetScale())
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("TOP", UIParent, "CENTER", 0, FRAME_HEIGHT / 2)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false)
        local left, top = self:GetLeft(), self:GetTop()
        if type(left) == "number" and type(top) == "number" then
            local s = self:GetScale()
            UI.WriteWindowSettings(getDb(), UI.FrameToUIParent(left, s), UI.FrameToUIParent(top, s))
        end
    end)
    frame:Hide()

    local title = frame.TitleText or frame.TitleContainer and frame.TitleContainer.TitleText
    if title then
        title:SetText("Forever Filter")
    end

    -- Addon icon in the upper left, where a portrait would sit. The window template
    -- (BasicFrameTemplateWithInset) has no portrait, so use a texture on a holder frame
    -- raised above the inset. Every step is guarded so a missing piece never errors.
    pcall(function()
        local portrait = frame.PortraitContainer and frame.PortraitContainer.portrait or frame.portrait
        if portrait and portrait.SetTexture then
            portrait:SetTexture(UI.ICON_TEXTURE)
            return
        end
        if frame.SetPortraitToAsset then
            frame:SetPortraitToAsset(UI.ICON_TEXTURE)
            return
        end
        local holder = CreateFrame("Frame", nil, frame)
        holder:SetSize(WINDOW_ICON_SIZE, WINDOW_ICON_SIZE)
        holder:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, 4)
        if holder.SetFrameLevel and frame.GetFrameLevel then
            holder:SetFrameLevel((frame:GetFrameLevel() or 0) + 5)
        end
        local icon = holder:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(holder)
        icon:SetTexture(UI.ICON_TEXTURE)
        windowIcon = icon
    end)

    -- Gear button left of the close button; opens the options strip.
    optionsButton = CreateFrame("Button", nil, frame)
    optionsButton:SetSize(20, 20)
    if frame.CloseButton then
        optionsButton:SetPoint("RIGHT", frame.CloseButton, "LEFT", -2, 0)
    else
        optionsButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -4)
    end
    local gearOk = pcall(function()
        optionsButton:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
        optionsButton:SetPushedTexture("Interface\\Buttons\\UI-OptionsButton")
        optionsButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        local normal = optionsButton:GetNormalTexture()
        if normal and normal.SetTexCoord then normal:SetTexCoord(0, 1, 0, 1) end
    end)
    if not gearOk then
        local text = optionsButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("CENTER")
        text:SetText("...")
    end
    optionsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Options")
        GameTooltip:Show()
    end)
    optionsButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    optionsButton:SetScript("OnClick", function()
        if UI.ToggleOptions then
            UI.ToggleOptions()
        end
    end)

    scrollFrame = CreateFrame("ScrollFrame", "ForeverFilterScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame.InsetBg or frame, "TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame.InsetBg or frame, "BOTTOMRIGHT", -28, 8)

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(FRAME_WIDTH - 60, 1)
    scrollFrame:SetScrollChild(content)

    -- Thin line above the Offline row, shown only when game rows exist.
    frame.offlineDivider = content:CreateTexture(nil, "ARTWORK")
    frame.offlineDivider:SetHeight(1)
    frame.offlineDivider:SetColorTexture(1, 1, 1, 0.2)
    frame.offlineDivider:Hide()

    tinsert(UISpecialFrames, "ForeverFilterFrame")

    -- Friend events are only listened to while the window is shown.
    frame:SetScript("OnEvent", function()
        UI.RequestRefresh()
    end)
    frame:SetScript("OnShow", function(self)
        for _, event in ipairs(FRIEND_EVENTS) do
            self:RegisterEvent(event)
        end
    end)
    frame:SetScript("OnHide", function(self)
        for _, event in ipairs(FRIEND_EVENTS) do
            self:UnregisterEvent(event)
        end
        socialState = UI.NextSocialState(socialState, "window_hidden", { anySocialOpen = anySocialOpen() })
        -- Safety net: a hide that is not one of our internal paths and not Escape, while a
        -- social frame is open, is the player closing the window (its X). Same saved value
        -- as the icon button closing it.
        pcall(function()
            if not internalHide and not escapeIsDown() and anySocialOpen() then
                UI.SaveWindowClosedChoice()
            end
        end)
    end)
    -- The window's own X is an explicit choice: remember it. Escape and hiding with the
    -- friends list do not go through this button. The template's close button is the
    -- parentKey child CloseButton (UIPanelCloseButtonDefaultAnchors, OnClick =
    -- UIPanelCloseButton_OnClick -> HideUIPanel(parent)); the global-name lookup covers
    -- templates that name it "$parentCloseButton" instead of keying it.
    pcall(function()
        local candidates = { rawget(frame, "CloseButton") or frame.CloseButton }
        local g = UI.LookupFrame("ForeverFilterFrameCloseButton")
        if g ~= nil then candidates[#candidates + 1] = g end
        local seen = {}
        for _, close in ipairs(candidates) do
            if type(close) == "table" and not seen[close] and type(close.HookScript) == "function" then
                seen[close] = true
                local ok = pcall(close.HookScript, close, "OnClick", function()
                    UI.SaveWindowClosedChoice()
                end)
                if not ok then
                    pcall(close.HookScript, close, "PreClick", function()
                        UI.SaveWindowClosedChoice()
                    end)
                end
            end
        end
    end)
    -- The strip is closed whenever the window hides, so it is closed on the next show.
    frame:HookScript("OnHide", function()
        optionsOpen = false
        sliderDragging = false
        if optionsStrip then
            optionsStrip:Hide()
        end
        pcall(UI.UpdateNameFrame)
    end)
    frame:HookScript("OnShow", function()
        optionsOpen = false
        if optionsStrip then
            optionsStrip:Hide()
        end
        pcall(UI.UpdateNameFrame)
    end)
end

local function getRow(i)
    local row = lines[i]
    if not row then
        local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        check:SetSize(CHECK_SIZE, CHECK_SIZE)
        check:SetScript("OnClick", function(self)
            if self.offline then
                UI.SetOfflineChecked(self:GetChecked())
            else
                UI.SetChecked(self.game, self.projectID, self:GetChecked())
            end
            if ns.Filter and ns.Filter.Reapply then
                ns.Filter.Reapply()
            end
        end)
        local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local fontPath = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
        header:SetFont(fontPath or STANDARD_TEXT_FONT, HEADER_FONT_SIZE, "")
        header:SetJustifyH("LEFT")
        header:SetWidth(content:GetWidth() - CHECK_SIZE - CHECK_GAP)
        row = { check = check, header = header }
        lines[i] = row
    end
    return row
end

function UI.HeaderText(row)
    local Games = ns.Games
    local label
    local pending = false
    if Games and Games.FormatGame then
        label, pending = Games.FormatGame(row.game, row.wowProjectID, ICON_SIZE, row.subIcon)
        pending = pending and true or false
    else
        label = val(row.game)
    end
    local debugId = ""
    if ns.debug then
        if type(row.wowProjectID) == "number" then
            debugId = string.format(" [id: %d]", row.wowProjectID)
        elseif row.game == "WoW" then
            debugId = " [id: none]"
        end
    end
    return UI.FormatHeader(label, debugId, row.count, UI.ReadShowCounts(ns.db)), pending
end

function UI.Refresh()
    if not frame or not frame:IsShown() then
        return
    end

    local entries = (ns.Friends and ns.Friends.GetAll and ns.Friends.GetAll()) or {}
    local nameFn = ns.Games and ns.Games.GetGameName or nil
    local rows = (ns.Friends and ns.Friends.GroupByGame and ns.Friends.GroupByGame(entries, nameFn)) or {}

    -- The Offline row is always present, so the list is never empty.
    local gameRowCount = #rows
    local offlineCount = (ns.Friends and ns.Friends.CountOffline and ns.Friends.CountOffline(entries)) or 0
    local all = {}
    for i, row in ipairs(rows) do all[i] = row end
    all[#all + 1] = { offline = true, count = offlineCount }
    local isEmpty = false

    local scale = frame:GetScale()
    local stripH = optionsOpen and UI.StripHeight(scale) or 0
    local stripW = optionsOpen and UI.StripMinWidth(scale) or 0

    local screenWidth = UIParent:GetWidth()
    local maxWindowWidth = UI.ComputeWindowWidth({ math.huge }, screenWidth, false)

    -- Pass 1 (width): measure each header at the widest allowed width.
    local anyPending = false
    local textWidths = {}
    for i, row in ipairs(all) do
        local r = getRow(i)
        r.header:SetWidth(UI.HeaderWidth(maxWindowWidth))
        local text, pending
        if row.offline then
            text = UI.FormatHeader("Offline", "", row.count, UI.ReadShowCounts(ns.db))
        else
            text, pending = UI.HeaderText(row)
        end
        r.header:SetText(text)
        if pending then
            anyPending = true
        end
        textWidths[#textWidths + 1] = r.header:GetStringWidth()
    end
    local windowWidth = UI.ComputeWindowWidthWithStrip(textWidths, screenWidth, isEmpty, stripW)
    local headerWidth = UI.HeaderWidth(windowWidth)

    local left, top = frame:GetLeft(), frame:GetTop()
    frame:SetWidth(windowWidth)
    content:SetWidth(windowWidth - WIDTH_CHROME)

    -- Pass 2 (height): lay out rows using heights measured at the final width.
    local y = 0
    local dividerShown = UI.OfflineDividerVisible(gameRowCount)
    frame.offlineDivider:Hide()
    for i, row in ipairs(all) do
        local r = lines[i]
        if row.offline and dividerShown then
            frame.offlineDivider:ClearAllPoints()
            frame.offlineDivider:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            frame.offlineDivider:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
            frame.offlineDivider:Show()
            y = y + OFFLINE_DIVIDER_HEIGHT
        end
        r.check.offline = row.offline and true or nil
        r.check.game, r.check.projectID = row.game, row.wowProjectID
        r.check:ClearAllPoints()
        r.check:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        if row.offline then
            r.check:SetChecked(UI.IsOfflineChecked())
        else
            -- The "@apps" row is an ordinary game row: IsChecked routes it to IsAppsChecked.
            r.check:SetChecked(UI.IsChecked(row.game, row.wowProjectID))
        end
        r.check:Show()

        r.header:SetWidth(headerWidth)
        r.header:ClearAllPoints()
        r.header:SetPoint("LEFT", r.check, "RIGHT", CHECK_GAP, 0)
        r.header:Show()

        local h = r.header:GetStringHeight()
        if not h or h < 1 then
            h = LINE_HEIGHT
        end
        y = y + UI.RowHeight(h) + ROW_GAP
    end
    local rowArea = y - ROW_GAP
    for i = #all + 1, #lines do
        lines[i].header:SetText("")
        lines[i].header:Hide()
        lines[i].check:Hide()
    end
    content:SetHeight(math.max(1, rowArea))

    local windowHeight = UI.ComputeWindowHeightWithStrip(rowArea, UIParent:GetHeight(), isEmpty, stripH)
    frame:SetHeight(windowHeight)
    if optionsStrip then
        optionsStrip:SetHeight(math.max(1, stripH))
    end
    scrollFrame:ClearAllPoints()
    scrollFrame:SetPoint("TOPLEFT", frame.InsetBg or frame, "TOPLEFT", 8, -(8 + stripH))
    scrollFrame:SetPoint("BOTTOMRIGHT", frame.InsetBg or frame, "BOTTOMRIGHT", -28, 8)
    if left and top then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    if CHROME_HEIGHT + stripH + rowArea <= windowHeight then
        scrollFrame:SetVerticalScroll(0)
    end
    -- The name window follows the games window width when it is anchored above it.
    if nameFrame and nameFrame:IsShown() then
        UI.UpdateNameFrame()
    end

    local schedule, newLeft = UI.NextRetry(anyPending, retriesLeft)
    retriesLeft = newLeft
    if schedule then
        UI.RequestRefresh()
    end
end

-- Collapses bursts of friend events into one refresh after REFRESH_DELAY.
function UI.RequestRefresh()
    if refreshPending then
        return
    end
    refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        refreshPending = false
        if frame and frame:IsShown() then
            UI.Refresh()
        end
    end)
end

local function openWindow()
    if not frame then
        create()
    end
    retriesLeft = ICON_RETRIES
    frame:Show()
    UI.Refresh()
    UI.PlaceWindow()
end

function UI.Show()
    socialState = UI.NextSocialState(socialState, "manual_show", {})
    openWindow()
end

function UI.ResetPosition()
    UI.ResetWindowSettings(getDb())
    if frame and frame:IsShown() then
        UI.PlaceWindow()
    end
    print("Forever Filter: window position reset.")
end

function UI.Hide()
    if frame then
        frame:Hide()
    end
end

-- /ff and the minimap button. Counts as an explicit choice (saved) only while a social frame is open.
function UI.Toggle()
    local opening = not (frame and frame:IsShown())
    if anySocialOpen() then
        getDb().openWithFriends = opening
    end
    if opening then
        UI.Show()
    else
        UI.Hide()
    end
end

-- Friends list button click: toggles the window and saves the choice
-- (opening saves true, closing saves false) in ForeverFilterDB.openWithFriends.
function UI.ToggleFromFriendsButton()
    if frame and frame:IsShown() then
        UI.SaveWindowClosedChoice()
        UI.Hide()
    else
        getDb().openWithFriends = true
        UI.Show()
    end
end

-- Replaceable global lookup so tests can inject stub frames.
function UI.LookupFrame(name)
    local g = _G
    if type(g) ~= "table" then return nil end
    return g[name]
end

local SOCIAL_FRAME_NAMES = UI.SOCIAL_FRAME_NAMES

local function windowIsShown()
    return frame ~= nil and frame:IsShown() == true
end

local function onSocialShown()
    pcall(function()
        local wasShown = windowIsShown()
        local newState, action = UI.NextSocialState(socialState, "social_shown",
            { windowShown = wasShown, openWithFriends = UI.ReadOpenWithFriends(getDb()),
              freshOpen = countSocialOpen() <= 1 })
        socialState = newState
        pcall(UI.UpdateNameFrame)
        if action == "show" then
            openWindow()
        elseif wasShown then
            local moved = UI.ReadWindowSettings(getDb())
            if not moved then
                UI.PlaceWindow()
            end
        end
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0, function()
                pcall(function()
                    if windowIsShown() and anySocialOpen() then
                        UI.PlaceWindow()
                    end
                end)
            end)
        end
    end)
end

local function onSocialHidden()
    pcall(function()
        local newState, action = UI.NextSocialState(socialState, "social_hidden",
            { anySocialOpen = anySocialOpen(), windowShown = windowIsShown() })
        socialState = newState
        if action == "hide" then
            UI.HideInternal()
        end
        pcall(UI.UpdateNameFrame)
    end)
end

-- Installs OnShow/OnHide post-hooks once per social frame that exists. Safe to repeat.
function UI.TryHookSocialFrames()
    for _, name in ipairs(SOCIAL_FRAME_NAMES) do
        if not hooked[name] then
            local f = UI.LookupFrame(name)
            if type(f) == "table" and type(f.HookScript) == "function" then
                hooked[name] = f
                f:HookScript("OnShow", onSocialShown)
                f:HookScript("OnHide", onSocialHidden)
            end
        end
        -- Icon button: created once per frame by Icons.lua; every lookup is guarded.
        local f = hooked[name]
        local icons = ns.Icons
        if f and type(icons) == "table" and type(icons.AttachFriendsButton) == "function" then
            pcall(icons.AttachFriendsButton, f, name)
        end
    end
end

if type(CreateFrame) == "function" then
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:SetScript("OnEvent", function(_, event)
        UI.TryHookSocialFrames()
        if event == "PLAYER_LOGIN" and anySocialOpen() then
            onSocialShown()
        end
    end)
end