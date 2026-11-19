local ADDON_NAME, ns = ...

ns.name = ADDON_NAME

local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local metaVersion = getMeta and getMeta(ADDON_NAME, "Version")
if type(metaVersion) ~= "string" or metaVersion == "" or metaVersion:find("@project-version@", 1, true) then
    metaVersion = "dev"
end
ns.version = metaVersion
-- Session-only debug flag; never saved.
ns.debug = false

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" and loadedName == ADDON_NAME then
        ForeverFilterDB = ForeverFilterDB or {}
        ns.db = ForeverFilterDB
        frame:UnregisterEvent("ADDON_LOADED")
        print("|cff33ff99Forever Filter|r v" .. ns.version .. " loaded. Type /ff to open the friends window.")
    end
end)

SLASH_FOREVERFILTER1 = "/ff"
SLASH_FOREVERFILTER2 = "/foreverfilter"
SlashCmdList["FOREVERFILTER"] = function(msg)
    -- ns.UI is resolved at call time; UI.lua loads after Core.lua.
    local cmd = strtrim(msg or ""):lower()
    print("|cff33ff99Forever Filter|r v" .. ns.version)
    if cmd == "debug" then
        ns.debug = not ns.debug
        print("ForeverFilter debug " .. (ns.debug and "ON" or "OFF"))
        if ns.UI and ns.UI.Show then
            ns.UI.Show() -- shows the panel if hidden and refreshes it
        end
        return
    end
    if cmd == "log" then
        local lines = ns.Filter and ns.Filter.GetLog and ns.Filter.GetLog() or {}
        print("Forever Filter log (" .. #lines .. " lines):")
        for _, line in ipairs(lines) do
            print("  " .. line)
        end
        return
    end
    if cmd == "minimap" then
        if ns.Icons and ns.Icons.ToggleMinimap then
            ns.Icons.ToggleMinimap()
        end
        return
    end
    if cmd == "reset" then
        if ns.UI and ns.UI.ResetPosition then
            ns.UI.ResetPosition()
        end
        return
    end
    local scaleArg = (cmd == "scale") and "" or cmd:match("^scale%s+(.*)$")
    if scaleArg then
        if ns.UI and ns.UI.HandleScaleCommand then
            ns.UI.HandleScaleCommand(scaleArg)
        end
        return
    end
    if ns.UI and ns.UI.Toggle then
        ns.UI.Toggle()
    end
end
