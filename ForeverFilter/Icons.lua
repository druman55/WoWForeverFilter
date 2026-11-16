local ADDON_NAME, ns = ...

-- Addon icon buttons: the toggle button on the friends list and the minimap button.
-- No external libraries. Pure helpers come first so they can be tested without a game client.
local Icons = {}
ns.Icons = Icons

local ICON_32 = "Interface\\AddOns\\ForeverFilter\\Textures\\ForeverFilter_32"
local ICON_64 = "Interface\\AddOns\\ForeverFilter\\Textures\\ForeverFilter_64"
Icons.ICON_32, Icons.ICON_64 = ICON_32, ICON_64

local DEFAULT_ANGLE = 200
local MINIMAP_BUTTON_SIZE = 31

local function isFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Pure: any finite number maps into [0, 360); anything else gives the default angle.
function Icons.NormalizeAngle(angle)
    if not isFinite(angle) then
        return DEFAULT_ANGLE
    end
    local a = angle % 360
    if a < 0 or a >= 360 then
        a = 0
    end
    return a
end

-- Pure: offset from the minimap center for an angle in degrees (0 = right, 90 = up).
function Icons.AngleToOffset(angle, radius)
    local a = math.rad(Icons.NormalizeAngle(angle))
    local r = (isFinite(radius) and radius > 0) and radius or 80
    return math.cos(a) * r, math.sin(a) * r
end

-- Pure: angle in degrees [0, 360) of a cursor position around a center. Invalid input gives the default.
function Icons.CursorToAngle(cursorX, cursorY, centerX, centerY)
    if not (isFinite(cursorX) and isFinite(cursorY) and isFinite(centerX) and isFinite(centerY)) then
        return DEFAULT_ANGLE
    end
    local dx, dy = cursorX - centerX, cursorY - centerY
    if dx == 0 and dy == 0 then
        return DEFAULT_ANGLE
    end
    local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
    return Icons.NormalizeAngle(math.deg(atan2(dy, dx)))
end

-- Pure read: returns angle (normalized, default when missing or invalid) and hide (true only for boolean true).
function Icons.ReadMinimapSettings(db)
    local m = type(db) == "table" and db.minimap or nil
    if type(m) ~= "table" then
        return DEFAULT_ANGLE, false
    end
    return Icons.NormalizeAngle(m.angle), m.hide == true
end

-- Writes db.minimap = { angle, hide }, keeping valid values already stored.
function Icons.WriteMinimapSettings(db, angle, hide)
    if type(db) ~= "table" then return end
    local curAngle, curHide = Icons.ReadMinimapSettings(db)
    if angle == nil then angle = curAngle end
    if hide == nil then hide = curHide end
    db.minimap = { angle = Icons.NormalizeAngle(angle), hide = hide == true }
end

local function getDb()
    local db = ns.db
    if type(db) ~= "table" and type(ForeverFilterDB) == "table" then
        db = ForeverFilterDB
    end
    return db
end

----------------------------------------------------------------------
-- Friends list button
----------------------------------------------------------------------
local friendsButtons = {} -- frame name -> button (created once per frame)

local function showTooltip(owner, lines)
    if type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    for i, line in ipairs(lines) do
        if i == 1 then
            GameTooltip:SetText(line, 1, 1, 1)
        else
            GameTooltip:AddLine(line, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

local function hideTooltip()
    if type(GameTooltip) == "table" then
        GameTooltip:Hide()
    end
end

-- Creates the toggle button once on a social frame ("FriendsFrame" or "SocialUIFrame").
-- Anchored left of the frame's CloseButton (PortraitFrameTemplate parentKey), or to the
-- frame's top right corner when no close button is found. Returns the button or nil.
function Icons.AttachFriendsButton(parentFrame, name)
    if friendsButtons[name] then
        return friendsButtons[name]
    end
    if type(parentFrame) ~= "table" or type(CreateFrame) ~= "function" then
        return nil
    end
    local ok, button = pcall(function()
        local b = CreateFrame("Button", "ForeverFilterToggleButton" .. tostring(name), parentFrame)
        b:SetSize(20, 20)
        local level = 0
        if type(parentFrame.GetFrameLevel) == "function" then
            level = parentFrame:GetFrameLevel() or 0
        end
        b:SetFrameLevel(level + 510) -- above the title container (510)
        local close = parentFrame.CloseButton
        if type(close) == "table" and type(close.GetObjectType) == "function" then
            b:SetPoint("RIGHT", close, "LEFT", -2, 0)
        else
            b:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -30, -3)
        end
        b:SetNormalTexture(ICON_32)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:RegisterForClicks("LeftButtonUp")
        b:SetScript("OnClick", function()
            if ns.UI and ns.UI.ToggleFromFriendsButton then
                ns.UI.ToggleFromFriendsButton()
            end
        end)
        b:SetScript("OnEnter", function(self)
            showTooltip(self, { "Forever Filter", "Click: show or hide the filter window", "Your choice is remembered." })
        end)
        b:SetScript("OnLeave", hideTooltip)
        return b
    end)
    if ok and button then
        friendsButtons[name] = button
        return button
    end
    return nil
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------
local minimapButton

local function minimapRadius()
    local w = 140
    if type(Minimap) == "table" and type(Minimap.GetWidth) == "function" then
        local ok, v = pcall(Minimap.GetWidth, Minimap)
        if ok and isFinite(v) and v > 0 then w = v end
    end
    return w / 2 + 5
end

function Icons.UpdateMinimapPosition()
    if not minimapButton then return end
    local angle = Icons.ReadMinimapSettings(getDb())
    local x, y = Icons.AngleToOffset(angle, minimapRadius())
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onMinimapDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (isFinite(mx) and isFinite(my) and isFinite(cx) and isFinite(cy) and isFinite(scale) and scale > 0) then
        return
    end
    local db = getDb()
    if type(db) ~= "table" then return end
    Icons.WriteMinimapSettings(db, Icons.CursorToAngle(cx / scale, cy / scale, mx, my), nil)
    Icons.UpdateMinimapPosition()
end

local function createMinimapButton()
    if minimapButton or type(CreateFrame) ~= "function" or type(Minimap) ~= "table" then
        return minimapButton
    end
    local ok, b = pcall(function()
        local btn = CreateFrame("Button", "ForeverFilterMinimapButton", Minimap)
        btn:SetSize(MINIMAP_BUTTON_SIZE, MINIMAP_BUTTON_SIZE)
        btn:SetFrameStrata("MEDIUM")
        btn:SetFrameLevel(8)
        btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(20, 20)
        bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
        bg:SetPoint("TOPLEFT", 7, -5)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetTexture(ICON_32)
        icon:SetPoint("TOPLEFT", 7, -5)
        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetPoint("TOPLEFT")
        btn:RegisterForClicks("LeftButtonUp")
        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnClick", function()
            if ns.UI and ns.UI.Toggle then
                ns.UI.Toggle()
            end
        end)
        btn:SetScript("OnDragStart", function(self)
            hideTooltip()
            self:SetScript("OnUpdate", function() pcall(onMinimapDragUpdate) end)
        end)
        btn:SetScript("OnDragStop", function(self)
            self:SetScript("OnUpdate", nil)
        end)
        btn:SetScript("OnEnter", function(self)
            showTooltip(self, {
                "Forever Filter v" .. tostring(ns.version or "dev"),
                "Left-click: toggle window, drag: move",
            })
        end)
        btn:SetScript("OnLeave", hideTooltip)
        return btn
    end)
    if ok and b then
        minimapButton = b
    end
    return minimapButton
end

-- Creates the button on first use and applies the saved position and visibility.
function Icons.RefreshMinimapButton()
    local _, hide = Icons.ReadMinimapSettings(getDb())
    if hide then
        if minimapButton then minimapButton:Hide() end
        return
    end
    if createMinimapButton() then
        Icons.UpdateMinimapPosition()
        minimapButton:Show()
    end
end

-- /ff minimap: shows or hides the button and saves the choice.
function Icons.ToggleMinimap()
    local db = getDb()
    if type(db) ~= "table" then return end
    local _, hide = Icons.ReadMinimapSettings(db)
    Icons.WriteMinimapSettings(db, nil, not hide)
    Icons.RefreshMinimapButton()
    print("Forever Filter: minimap button " .. (hide and "shown." or "hidden."))
end

if type(CreateFrame) == "function" then
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGIN")
    ev:SetScript("OnEvent", function()
        pcall(Icons.RefreshMinimapButton)
        if ns.UI and ns.UI.TryHookSocialFrames then
            pcall(ns.UI.TryHookSocialFrames) -- attach friends buttons to frames that already exist
        end
    end)
end
