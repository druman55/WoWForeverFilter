local ADDON_NAME, ns = ...

ns.name = ADDON_NAME

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" and loadedName == ADDON_NAME then
        ForeverFilterDB = ForeverFilterDB or {}
        ns.db = ForeverFilterDB
        frame:UnregisterEvent("ADDON_LOADED")
        print("|cff33ff99Forever Filter|r loaded. Type /ff to open the friends window.")
    end
end)

SLASH_FOREVERFILTER1 = "/ff"
SLASH_FOREVERFILTER2 = "/foreverfilter"
SlashCmdList["FOREVERFILTER"] = function(msg)
    -- ns.UI is resolved at call time; UI.lua loads after Core.lua.
    local cmd = strtrim(msg or ""):lower()
    if cmd == "debug" then
        ns.db = ns.db or ForeverFilterDB or {}
        ns.db.debug = not ns.db.debug
        print("ForeverFilter debug " .. (ns.db.debug and "ON" or "OFF"))
        if ns.UI and ns.UI.Show then
            ns.UI.Show() -- shows the panel if hidden and refreshes it
        end
        return
    end
    if ns.UI and ns.UI.Toggle then
        ns.UI.Toggle()
    end
end
