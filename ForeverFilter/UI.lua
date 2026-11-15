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
    local v = getStore()[UI.GameKey(game, projectID)]
    if type(v) == "boolean" then
        return v
    end
    return true
end

function UI.SetChecked(game, projectID, checked)
    getStore()[UI.GameKey(game, projectID)] = checked and true or false
end

local function create()
    frame = CreateFrame("Frame", "ForeverFilterFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("TOP", UIParent, "CENTER", 0, FRAME_HEIGHT / 2)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    local title = frame.TitleText or frame.TitleContainer and frame.TitleContainer.TitleText
    if title then
        title:SetText("Forever Filter")
    end

    scrollFrame = CreateFrame("ScrollFrame", "ForeverFilterScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame.InsetBg or frame, "TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame.InsetBg or frame, "BOTTOMRIGHT", -28, 8)

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(FRAME_WIDTH - 60, 1)
    scrollFrame:SetScrollChild(content)

    frame.noFriends = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.noFriends:SetPoint("TOPLEFT", 0, 0)
    frame.noFriends:SetText("No Battle.net friends found.")
    frame.noFriends:Hide()

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
    end)
end

local function getRow(i)
    local row = lines[i]
    if not row then
        local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        check:SetSize(CHECK_SIZE, CHECK_SIZE)
        check:SetScript("OnClick", function(self)
            UI.SetChecked(self.game, self.projectID, self:GetChecked())
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
    if ns.db and ns.db.debug then
        if type(row.wowProjectID) == "number" then
            debugId = string.format(" [id: %d]", row.wowProjectID)
        elseif row.game == "WoW" then
            debugId = " [id: none]"
        end
    end
    return string.format("%s%s (%d)", label, debugId, row.count or 0), pending
end

function UI.Refresh()
    if not frame or not frame:IsShown() then
        return
    end

    local entries = (ns.Friends and ns.Friends.GetAll and ns.Friends.GetAll()) or {}
    local nameFn = ns.Games and ns.Games.GetGameName or nil
    local rows = (ns.Friends and ns.Friends.GroupByGame and ns.Friends.GroupByGame(entries, nameFn)) or {}

    local isEmpty = false
    if #entries == 0 then
        frame.noFriends:SetText("No Battle.net friends found.")
        frame.noFriends:Show()
        isEmpty = true
    elseif #rows == 0 then
        frame.noFriends:SetText("No friends online.")
        frame.noFriends:Show()
        isEmpty = true
    else
        frame.noFriends:Hide()
    end

    local screenWidth = UIParent:GetWidth()
    local maxWindowWidth = UI.ComputeWindowWidth({ math.huge }, screenWidth, false)

    -- Pass 1 (width): measure each header at the widest allowed width.
    local anyPending = false
    local textWidths = {}
    for i, row in ipairs(rows) do
        local r = getRow(i)
        r.header:SetWidth(UI.HeaderWidth(maxWindowWidth))
        local text, pending = UI.HeaderText(row)
        r.header:SetText(text)
        if pending then
            anyPending = true
        end
        textWidths[#textWidths + 1] = r.header:GetStringWidth()
    end
    local windowWidth = UI.ComputeWindowWidth(textWidths, screenWidth, isEmpty)
    local headerWidth = UI.HeaderWidth(windowWidth)

    local left, top = frame:GetLeft(), frame:GetTop()
    frame:SetWidth(windowWidth)
    content:SetWidth(windowWidth - WIDTH_CHROME)

    -- Pass 2 (height): lay out rows using heights measured at the final width.
    local y = 0
    for i, row in ipairs(rows) do
        local r = lines[i]
        r.check.game, r.check.projectID = row.game, row.wowProjectID
        r.check:ClearAllPoints()
        r.check:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r.check:SetChecked(UI.IsChecked(row.game, row.wowProjectID))
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
    local rowArea = 0
    if #rows > 0 then
        rowArea = y - ROW_GAP
    end
    for i = #rows + 1, #lines do
        lines[i].header:SetText("")
        lines[i].header:Hide()
        lines[i].check:Hide()
    end
    content:SetHeight(math.max(1, rowArea))

    local windowHeight = UI.ComputeWindowHeight(rowArea, UIParent:GetHeight(), isEmpty)
    frame:SetHeight(windowHeight)
    if left and top then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end    if CHROME_HEIGHT + rowArea <= windowHeight then
        scrollFrame:SetVerticalScroll(0)
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

function UI.Show()
    if not frame then
        create()
    end
    retriesLeft = ICON_RETRIES
    frame:Show()
    UI.Refresh()
end

function UI.Hide()
    if frame then
        frame:Hide()
    end
end

function UI.Toggle()
    if frame and frame:IsShown() then
        UI.Hide()
    else
        UI.Show()
    end
end
