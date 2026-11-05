setDefaultTab("Main")
local CONFIG_NAME = "CustomBot_GitHub"
local REPOSITORY = "oldpowerz/CustomProfile"
local BRANCH = "main"
local CHECK_INTERVAL = 60000
local G = modules._G
local R = G.g_resources
local H = G.HTTP
local BOT = modules.game_bot
local TARGET = "/bot/" .. CONFIG_NAME
local UPDATER = TARGET .. "/__CustomProfileUpdater.lua"
local STATE_KEY = "CustomProfileUpdaterState"
local old = G[STATE_KEY]
if old then
    if old.revision == 5 and old.controls and not old.controls:isDestroyed() then
        return
    end
    if old.busy then return end
    if old.window and not old.window:isDestroyed() then old.window:destroy() end
    if old.controls and not old.controls:isDestroyed() then old.controls:destroy() end
    if old.timer then G.removeEvent(old.timer) end
end
local state = {busy = false, timer = nil, revision = 5, pendingVersion = nil}
G[STATE_KEY] = state
local controls = setupUI([[
Panel
  height: 68

  Label
    id: localVersion
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    text: Version: sin comprobar
    height: 18

  Button
    id: check
    anchors.top: localVersion.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    text: Comprobar
    height: 22
    margin-top: 3

  Button
    id: updateButton
    anchors.top: info.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    text: Actualizar
    height: 22
    margin-top: 3
    enabled: false
    visible: false

  Label
    id: info
    anchors.top: check.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    text: Comprobando...
    height: 22
    margin-top: 3
    text-wrap: true
]])
state.controls = controls
local window = setupUI([[
MainWindow
  text: actualizando customprofile
  size: 380 170
  visible: false
  @onEscape: self:hide()

  Label
    id: status
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    text: preparando descarga
    height: 40
    text-wrap: true

  ProgressBar
    id: progress
    anchors.top: status.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 22
    percent: 0

  Label
    id: detail
    anchors.top: progress.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    text: esperando descarga
    height: 40
    text-wrap: true
]], G.g_ui.getRootWidget())
window.botWidget = false
window:hide()
state.window = window
local function message(text)
    window.status:setText(text)
    if not controls:isDestroyed() then controls.info:setText(text) end
end
local function setBusy(value)
    state.busy = value
    controls.check:setEnabled(not value)
    controls.updateButton:setEnabled(not value and state.pendingVersion ~= nil)
    controls.updateButton:setVisible(state.pendingVersion ~= nil)
    controls:setHeight(state.pendingVersion and 93 or 68)
end
local function parseVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('CustomPanel%.version%s*=%s*["\'](%d[%d%.]*)["\']')
        or text:match('return%s*["\'](%d[%d%.]*)["\']')
end
local function localVersion()
    if R.fileExists(TARGET .. "/Version.lua") then
        return parseVersion(R.readFileContents(TARGET .. "/Version.lua"))
    end
end
local function isNewer(remote, current)
    if not current then return true end
    local a, b = {}, {}
    for n in remote:gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in current:gmatch("%d+") do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        if (a[i] or 0) ~= (b[i] or 0) then
            return (a[i] or 0) > (b[i] or 0)
        end
    end
    return false
end
local function writeVerified(path, contents)
    if R.writeFileContents(path, contents) == false or R.readFileContents(path) ~= contents then
        error("no se pudo guardar " .. path)
    end
end
local function mkdir(path)
    if not R.directoryExists(path) then R.makeDir(path) end
    if not R.directoryExists(path) then error("no se pudo crear " .. path) end
end
local scriptSource
if configDir then
    for _, filename in ipairs({"CustomProfile_loader.lua", "__CustomProfileUpdater.lua"}) do
        local sourcePath = configDir .. "/" .. filename
        if R.fileExists(sourcePath) then
            scriptSource = R.readFileContents(sourcePath)
            break
        end
    end
end
local function persistUpdater()
    if not scriptSource then return end
    if not R.fileExists(UPDATER) or R.readFileContents(UPDATER) ~= scriptSource then
        writeVerified(UPDATER, scriptSource)
    end
end

local checkVersion
local function scheduleNext()
    if state.timer then G.removeEvent(state.timer) end
    state.timer = G.scheduleEvent(function()
        state.timer = nil
        checkVersion()
    end, CHECK_INTERVAL)
end
local function fail(text)
    state.pendingVersion = nil
    setBusy(false)
    message(tostring(text):lower():gsub("[%p]", " "):gsub("%s+", " "))
    window.detail:setText("se comprobara de nuevo en un minuto")
    if state.installing then window:show() end
    state.installing = false
    scheduleNext()
end
local function finish(version, added, kept, initial)
    state.pendingVersion = nil
    controls.updateButton:setText("Actualizar")
    setBusy(false)
    window.progress:setPercent(100)
    message(initial and "instalacion completada" or "actualizacion completada")
    window.detail:setText(added .. " archivos nuevos y " .. kept .. " existentes conservados")
    state.installing = false
    window:hide()
    scheduleNext()
    G.scheduleEvent(function()
        BOT.refresh()
        BOT.contentsPanel.config:setCurrentOption(CONFIG_NAME)
    end, 200)
end
local function extractAndMerge(path, expectedVersion)
    local archivePath = "/downloads/" .. path
    local data = R.readFileContents(archivePath)
    if type(data) ~= "string" or data:sub(1, 2) ~= "PK" then
        error("la descarga no es un zip comprueba el acceso publico al repositorio")
    end
    local files = R.decompressArchive(archivePath)
    if type(files) ~= "table" then error("no se pudo extraer el zip") end
    local entries, root, sameRoot = {}, nil, true
    for name, contents in pairs(files) do
        if type(name) ~= "string" or type(contents) ~= "string" then error("zip no valido") end
        name = name:gsub("\\", "/"):gsub("^/+", "")
        if name:find(":", 1, true) or name:find("//", 1, true) then error("ruta no valida en el zip") end
        for part in name:gmatch("[^/]+") do
            if part == ".." or part == "." then error("ruta no permitida en el zip") end
        end
        if name ~= "" and name:sub(-1) ~= "/" then
            local folder = name:match("^([^/]+)/")
            if not folder then sameRoot = false
            elseif not root then root = folder
            elseif folder ~= root then sameRoot = false end
            entries[#entries + 1] = {path = name, contents = contents}
        end
    end
    local versionContents
    local planned, kept, seen = {}, 0, {}
    for _, entry in ipairs(entries) do
        if sameRoot and root then entry.path = entry.path:sub(#root + 2) end
        if seen[entry.path] then error("rutas duplicadas en el zip") end
        seen[entry.path] = true
        if entry.path == "Version.lua" then
            versionContents = entry.contents
        elseif entry.path ~= "__CustomProfileUpdater.lua" then
            local destination = TARGET .. "/" .. entry.path
            if R.fileExists(destination) or R.directoryExists(destination) then
                kept = kept + 1
            else
                planned[#planned + 1] = entry
            end
        end
    end
    if parseVersion(versionContents) ~= expectedVersion then
        error("la version del zip no coincide con la version consultada vuelve a comprobar")
    end
    local initial = not localVersion()
    mkdir(TARGET)
    persistUpdater()
    local index, added = 1, 0
    local function batch()
        local ok, err = pcall(function()
            local last = math.min(index + 14, #planned)
            while index <= last do
                local entry = planned[index]
                local destination = TARGET .. "/" .. entry.path
                if not R.fileExists(destination) and not R.directoryExists(destination) then
                    local folder = TARGET
                    local parent = entry.path:match("^(.*)/[^/]+$")
                    if parent then
                        for part in parent:gmatch("[^/]+") do
                            folder = folder .. "/" .. part
                            mkdir(folder)
                        end
                    end
                    writeVerified(destination, entry.contents)
                    added = added + 1
                else
                    kept = kept + 1
                end
                index = index + 1
            end
            window.progress:setPercent(math.floor(math.min(index - 1, #planned) / math.max(1, #planned) * 100))
            window.detail:setText("instalando " .. math.min(index - 1, #planned) .. "/" .. #planned .. " archivos nuevos")
            if index <= #planned then
                G.scheduleEvent(batch, 10)
            else
                writeVerified(TARGET .. "/Version.lua", versionContents)
                finish(expectedVersion, added, kept, initial)
            end
        end)
        if not ok then fail("instalacion detenida " .. tostring(err)) end
    end
    message("agregando archivos nuevos")
    window.progress:setPercent(0)
    G.scheduleEvent(batch, 10)
end
local function download(version)
    state.installing = true
    message("descargando version " .. version)
    window:show()
    window.progress:setPercent(0)
    local url = "https://github.com/" .. REPOSITORY .. "/archive/refs/heads/" .. BRANCH .. ".zip?t=" .. G.os.time()
    local previous = H.timeout
    H.timeout = 120
    local ok, err = pcall(function()
        H.download(url, "CustomProfile_update.zip", function(path, checksum, downloadError)
            if downloadError then return fail("no se pudo descargar el zip") end
            message("comprobando el zip")
            local success, mergeError = pcall(extractAndMerge, path, version)
            if not success then fail(tostring(mergeError)) end
        end, function(progress, speed)
            window.progress:setPercent(progress)
            window.detail:setText(string.format("descarga %d%% velocidad %s kb por segundo", math.floor(progress), tostring(speed)))
        end)
    end)
    H.timeout = previous
    if not ok then fail(tostring(err)) end
end
checkVersion = function()
    if state.busy then return end
    if state.timer then G.removeEvent(state.timer); state.timer = nil end
    state.pendingVersion = nil
    setBusy(true)
    message("Comprobando...")
    window.progress:setPercent(0)
    local current = localVersion()
    controls.localVersion:setText("Version: " .. (current or "sin instalar"))
    local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/" .. BRANCH .. "/Version.lua?t=" .. G.os.time()
    local ok, err = pcall(function()
        H.get(url, function(contents, requestError)
            if requestError then return fail("no se pudo consultar la version") end
            local version = parseVersion(contents)
            if not version then return fail("el archivo de version no contiene una version reconocible") end
            if isNewer(version, current) then
                state.pendingVersion = version
                setBusy(false)
                controls.updateButton:setText((current and "Actualizar a " or "Instalar ") .. version)
                message(current and "Nueva version disponible" or "Instalacion disponible")
                window.detail:setText("pulsa el boton cuando quieras continuar")
                scheduleNext()
            else
                setBusy(false)
                controls.updateButton:setText("Actualizar")
                message("Actualizado")
                window.progress:setPercent(100)
                window.detail:setText("proxima comprobacion dentro de un minuto")
                scheduleNext()
            end
        end)
    end)
    if not ok then fail(tostring(err)) end
end
controls.check.onClick = checkVersion
controls.updateButton.onClick = function()
    if state.busy or not state.pendingVersion then return end
    local version = state.pendingVersion
    if state.timer then G.removeEvent(state.timer); state.timer = nil end
    setBusy(true)
    download(version)
end
local ok, err = pcall(function()
    if R.directoryExists(TARGET) then persistUpdater() end
end)
if not ok then
    fail(tostring(err))
else
    checkVersion()
end
