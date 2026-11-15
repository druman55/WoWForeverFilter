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

local function nonEmpty(s)
    return type(s) == "string" and s ~= ""
end

-- Returns inline icon markup for a clientProgram code, or nil when no icon is available.
function Games.GetIconMarkup(game, size)
    if type(game) ~= "string" or game == "" then
        return nil
    end
    size = tonumber(size) or 14

    -- (a) Title-icon route, as Blizzard's own friends list does.
    local ok, markup = pcall(function()
        if C_Texture and C_Texture.IsTitleIconTextureReady and C_Texture.GetTitleIconTexture
            and Enum and Enum.TitleIconVersion and BNet_GetClientEmbeddedTexture
            and C_Texture.IsTitleIconTextureReady(game, Enum.TitleIconVersion.Small) then
            local result
            -- The callback runs synchronously when the icon is ready.
            C_Texture.GetTitleIconTexture(game, Enum.TitleIconVersion.Small, function(success, texture)
                if success then
                    result = BNet_GetClientEmbeddedTexture(texture, 32, 32, size, size, 0, 0)
                end
            end)
            return result
        end
    end)
    if ok and nonEmpty(markup) then
        return markup
    end

    -- (b) Atlas route, only when the atlas exists (the helper would otherwise return the App icon).
    ok, markup = pcall(function()
        if BNet_GetClientEmbeddedAtlas and C_Texture and C_Texture.GetAtlasInfo
            and C_Texture.GetAtlasInfo("UI-ChatIcon-" .. game) then
            return BNet_GetClientEmbeddedAtlas(game, size, size)
        end
    end)
    if ok and nonEmpty(markup) then
        return markup
    end

    -- (c) No icon: text only.
    return nil
end

-- Returns "<icon> <name>" or just "<name>". Never empty.
function Games.FormatGame(game, projectID, size)
    local name = Games.GetGameName(game, projectID)
    local icon = Games.GetIconMarkup(game, size)
    if icon then
        return icon .. " " .. name
    end
    return name
end
