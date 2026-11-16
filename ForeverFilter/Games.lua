local _, ns = ...

local Games = {}
ns.Games = Games

local GAME_NAMES = {
    WoW = "World of Warcraft",
    App = "Battle.net",
    BSAp = "Battle.net Mobile",
    Hero = "Heroes of the Storm",
    Pro = "Overwatch 2",
    S1 = "StarCraft",
    S2 = "StarCraft II",
    D3 = "Diablo III",
    Fen = "Diablo IV",
    OSI = "Diablo II: Resurrected",
    ANBS = "Diablo Immortal",
    WTCG = "Hearthstone",
    W3 = "Warcraft III: Reforged",
    GRY = "Warcraft Rumble",
    VIPR = "Call of Duty: Black Ops 4",
    ODIN = "Call of Duty: Modern Warfare",
    LAZR = "Call of Duty: Modern Warfare 2",
    ZEUS = "Call of Duty: Black Ops Cold War",
    FORE = "Call of Duty",
    RTRO = "Blizzard Arcade Collection",
    WLBY = "Crash Bandicoot 4: It's About Time",
    DST2 = "Destiny 2",
    CLNT = "Battle.net Client",
}

local WOW_NAMES = {
    [1] = "World of Warcraft: Retail",
    [2] = "World of Warcraft Classic Era",
    [3] = "World of Warcraft: Plunderstorm",
    [5] = "World of Warcraft: Burning Crusade Classic",
    [11] = "World of Warcraft: Wrath of the Lich King Classic",
    [14] = "World of Warcraft: Cataclysm Classic",
    [18] = "World of Warcraft: Forever",
    [19] = "World of Warcraft: Mists of Pandaria Classic",
}

-- Returns a display name for a clientProgram code. Never nil, never errors.
function Games.GetGameName(game, projectID)
    if type(game) ~= "string" or game == "" then
        return "?"
    end
    if game == "WoW" then
        if type(projectID) ~= "number" then
            return GAME_NAMES.WoW
        end
        return WOW_NAMES[projectID] or ("World of Warcraft: Project " .. tostring(projectID))
    end
    return GAME_NAMES[game] or (game:gsub("|", "||"))
end

-- Sentinel for the combined Battle.net apps row (same value as Friends.APPS_GAME).
-- It is named "Battle.net" and uses the icon of "App".
GAME_NAMES["@apps"] = "Battle.net"

local function nonEmpty(s)
    return type(s) == "string" and s ~= ""
end

-- Returns inline icon markup for a clientProgram code, or nil when no icon is available.
-- Second return value `pending` is true only when the title icon API exists and
-- reports the texture not ready.
function Games.GetIconMarkup(game, size, subIcon)
    if type(game) ~= "string" or game == "" then
        return nil, false
    end
    if game == "@apps" then
        game = "App"
    end
    size = tonumber(size) or 14
    if not nonEmpty(subIcon) then
        subIcon = nil
    end
    local pending = false

    -- (a) Title-icon route, as Blizzard's own friends list does.
    local ok, markup = pcall(function()
        if C_Texture and C_Texture.IsTitleIconTextureReady and C_Texture.GetTitleIconTexture
            and Enum and Enum.TitleIconVersion and BNet_GetClientEmbeddedTexture then
            local version = Enum.TitleIconVersion.Small
            local ready
            if subIcon ~= nil then
                ready = C_Texture.IsTitleIconTextureReady(game, version, subIcon)
            else
                ready = C_Texture.IsTitleIconTextureReady(game, version)
            end
            if not ready then
                pending = true
                -- Warm-up request so a later refresh finds the texture ready.
                pcall(function()
                    if subIcon ~= nil then
                        C_Texture.GetTitleIconTexture(game, version, function() end, subIcon)
                    else
                        C_Texture.GetTitleIconTexture(game, version, function() end)
                    end
                end)
                return nil
            end
            local result
            -- The callback runs synchronously when the icon is ready.
            local function callback(success, texture)
                if success then
                    result = BNet_GetClientEmbeddedTexture(texture, 32, 32, size, size, 0, 0)
                end
            end
            if subIcon ~= nil then
                C_Texture.GetTitleIconTexture(game, version, callback, subIcon)
            else
                C_Texture.GetTitleIconTexture(game, version, callback)
            end
            return result
        end
    end)
    if ok and nonEmpty(markup) then
        return markup, false
    end
    if not ok then
        pending = false
    end

    -- (b) Atlas route, only when the atlas exists (the helper would otherwise return the App icon).
    ok, markup = pcall(function()
        if BNet_GetClientEmbeddedAtlas and C_Texture and C_Texture.GetAtlasInfo
            and C_Texture.GetAtlasInfo("UI-ChatIcon-" .. game) then
            return BNet_GetClientEmbeddedAtlas(game, size, size)
        end
    end)
    if ok and nonEmpty(markup) then
        return markup, pending
    end

    -- (c) No icon: text only.
    return nil, pending
end

-- Returns "<icon> <name>" or just "<name>", plus pending. Text is never empty.
function Games.FormatGame(game, projectID, size, subIcon)
    local name = Games.GetGameName(game, projectID)
    local icon, pending = Games.GetIconMarkup(game, size, subIcon)
    if icon then
        return icon .. " " .. name, pending
    end
    return name, pending
end
