CustomPanel = CustomPanel or {}
CustomPanel.pending = CustomPanel.pending or {}
CustomPanel.mountEntries = CustomPanel.mountEntries or {}

function CustomPanel.registerMountEntry(panelName, side, callback, displayName)
    for _, entry in ipairs(CustomPanel.mountEntries) do
        if entry.callback == callback then
            return entry
        end
    end

    local entry = {
        panel = tostring(panelName or ""):lower(),
        side = tostring(side or ""):lower(),
        callback = callback,
        index = #CustomPanel.mountEntries + 1,
        displayName = displayName,
        detectedNames = {},
        detectedControls = {},
        pendingControls = {},
        settingsRows = {}
    }
    table.insert(CustomPanel.mountEntries, entry)
    return entry
end

if type(CustomPanel.mount) ~= "function" then
    function CustomPanel.mount(panelName, side, callback, displayName)
        local entry = CustomPanel.registerMountEntry(panelName, side, callback, displayName)
        table.insert(CustomPanel.pending, {
            panel = entry.panel,
            side = entry.side,
            callback = callback,
            displayName = displayName
        })
        return false
    end
end