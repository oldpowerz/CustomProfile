setDefaultTab("Main")
local CONFIG_NAME = modules.game_bot.contentsPanel.config:getCurrentOption().text
local REPOSITORY = "oldpowerz/CustomProfile"
local BRANCH = "main"
local CHECK_INTERVAL = 60000
local CHECK_TIMEOUT = 30000
local DOWNLOAD_TIMEOUT = 120000
local G = modules._G
local R = G.g_resources
local H = G.HTTP
local BOT = modules.game_bot
local TARGET = "/bot/" .. CONFIG_NAME
local VERSION_FILE = TARGET .. "/Version.lua"
local STATE_KEY = "CustomProfileUpdaterState"
local old = G[STATE_KEY]
if old then
    if old.busy and old.installing and old.controls and not old.controls:isDestroyed() then return end
    if old.abortInstall then old.abortInstall("el perfil se recargo durante la instalacion") end
    if old.window and not old.window:isDestroyed() then old.window:destroy() end
    if old.controls and not old.controls:isDestroyed() then old.controls:destroy() end
    if old.timer then G.removeEvent(old.timer) end
    if old.requestTimer then G.removeEvent(old.requestTimer) end
    old.requestId = (old.requestId or 0) + 1
    if old.operation and H and H.cancel then pcall(H.cancel, old.operation) end
end
local state = {busy = false, requestId = 0, profile = CONFIG_NAME}
if old and old.profile == CONFIG_NAME then
    state.processedVersion, state.notice = old.processedVersion, old.notice
end
G[STATE_KEY] = state
local controls = setupUI([[
Panel
  height: 110

  Label
    id: localVersion
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    text: Version: sin comprobar
    height: 36
    text-wrap: true

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
    height: 42
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
    controls:setHeight(state.pendingVersion and 135 or 110)
end
local function parseVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('CustomPanel%.version%s*=%s*["\'](%d[%d%.]*)["\']')
        or text:match('return%s*["\'](%d[%d%.]*)["\']')
end
local function localVersion()
    if R.fileExists(VERSION_FILE) then
        return parseVersion(R.readFileContents(VERSION_FILE))
    end
end
local function missingVersionFile()
    return not R.fileExists(VERSION_FILE) and not R.directoryExists(VERSION_FILE)
end
local function showLocalVersion(current)
    local text = "Version local: " .. (current or "no detectada")
    if state.processedVersion and state.processedVersion ~= current then
        text = text .. " | Ultima procesada: " .. state.processedVersion
    end
    controls.localVersion:setText(text)
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
local MAX_BYTES = 256 * 1024 * 1024
local function safePath(path)
    assert(type(path) == "string" and #path > 0 and #path <= 500 and
        not path:find('[%c\\:*?"<>|]') and not path:find("//", 1, true) and
        path:sub(1, 1) ~= "/" and path:sub(-1) ~= "/", "ruta no valida")
    for part in path:gmatch("[^/]+") do
        local name = part:lower():match("^[^.]+") or ""
        assert(part ~= "." and part ~= ".." and not part:find("[%. ]$") and
            name ~= "con" and name ~= "prn" and name ~= "aux" and name ~= "nul" and
            not name:match("^com[1-9]$") and not name:match("^lpt[1-9]$"), "ruta reservada")
    end
end
local function protected(path)
    local lower = path:lower()
    local first = lower:match("^[^/]+")
    return first == "storage" or first == "cavebot_configs" or first == "targetbot_configs" or
        first == "profiles" or first == "configs" or first == "config" or first == "backups" or
        first == ".git" or first == "tests" or first == "bot_update_data" or
        lower == "__customprofileupdater.lua" or lower == "customprofile_loader.lua" or
        lower:match("%.json$") or lower:match("%.cfg$") or lower:match("%.zip$") or
        lower:match("%.ini$") or lower:match("%.log$") or lower:match("%.bak$")
end
local function ensureParent(path, created)
    local current = ""
    for part in path:match("^(.*)/[^/]+$"):gmatch("[^/]+") do
        current = current .. "/" .. part
        if not R.directoryExists(current) then
            R.makeDir(current)
            assert(R.directoryExists(current), "no se pudo crear " .. current)
            created[#created + 1] = current
        end
    end
end

local checkVersion
local fail
local function isActive()
    return G[STATE_KEY] == state and not controls:isDestroyed() and not window:isDestroyed()
end
local function stopTimer()
    if state.timer then G.removeEvent(state.timer); state.timer = nil end
end
local function clearRequest(cancel)
    state.requestId = state.requestId + 1
    if state.requestTimer then G.removeEvent(state.requestTimer); state.requestTimer = nil end
    local operation = state.operation
    state.operation = nil
    if cancel and operation and H and H.cancel then pcall(H.cancel, operation) end
end
local function startRequest(timeout, timeoutMessage, keepOffer)
    clearRequest(true)
    local id = state.requestId
    state.requestTimer = G.scheduleEvent(function()
        if state.requestId ~= id then return end
        state.requestTimer = nil
        fail(timeoutMessage, keepOffer)
    end, timeout)
    return id
end
local function requestCallback(id, callback, keepOffer)
    return function(...)
        if state.requestId ~= id then return end
        clearRequest(false)
        if not isActive() then return end
        local ok, err = pcall(callback, ...)
        if not ok then fail(err, keepOffer) end
    end
end
local function recordRequest(id, ok, operation, keepOffer)
    if not ok then return fail(operation, keepOffer) end
    if state.requestId == id then state.operation = operation end
end
local function scheduleNext()
    stopTimer()
    state.timer = G.scheduleEvent(function()
        state.timer = nil
        if not isActive() then return end
        if state.busy then scheduleNext() else checkVersion() end
    end, CHECK_INTERVAL)
end
fail = function(text, keepOffer)
    clearRequest(true)
    local installing = state.installing
    state.installing = false
    if not isActive() then return end
    if not keepOffer then state.pendingVersion = nil end
    setBusy(false)
    message(tostring(text))
    window.detail:setText(keepOffer and "Pulsa Actualizar para reintentar o Comprobar para buscar otra version."
        or "se comprobara de nuevo en " .. (CHECK_INTERVAL / 1000) .. " segundos")
    if installing then window:show() end
    scheduleNext()
end
local function finish(completion)
    state.pendingVersion = nil
    controls.updateButton:setText("Actualizar")
    setBusy(false)
    showLocalVersion(localVersion())
    window.progress:setPercent(100)
    message(state.notice or completion)
    window.detail:setText("El ZIP se proceso en memoria.")
    state.installing = false
    if state.notice then window:show() else window:hide() end
    scheduleNext()
    G.scheduleEvent(function()
        if not isActive() then return end
        local option = BOT.contentsPanel.config:getCurrentOption()
        if option and option.text == CONFIG_NAME then BOT.refresh() end
    end, 200)
end
local function extractAndMerge(data, expectedVersion)
    assert(type(data) == "string" and #data >= 64 and #data <= MAX_BYTES and data:sub(1, 2) == "PK",
        "la descarga no es un ZIP valido o supera el limite")
    local files = R.decompressArchive(data)
    if type(files) ~= "table" then error("no se pudo extraer el zip") end
    local entries, root, sameRoot = {}, nil, true
    local total = 0
    for name, contents in pairs(files) do
        if type(name) ~= "string" or type(contents) ~= "string" then error("zip no valido") end
        name = name:gsub("\\", "/"):gsub("^/+", "")
        if name:find(":", 1, true) or name:find("//", 1, true) then error("ruta no valida en el zip") end
        for part in name:gmatch("[^/]+") do
            if part == ".." or part == "." then error("ruta no permitida en el zip") end
        end
        if name ~= "" and name:sub(-1) ~= "/" then
            safePath(name)
            total = total + #contents
            assert(total <= MAX_BYTES and #entries < 10000, "zip supera los limites")
            local folder = name:match("^([^/]+)/")
            if not folder then sameRoot = false
            elseif not root then root = folder
            elseif folder ~= root then sameRoot = false end
            entries[#entries + 1] = {path = name, contents = contents}
        end
    end
    local remote, seen = {}, {}
    for _, entry in ipairs(entries) do
        if sameRoot and root then entry.path = entry.path:sub(#root + 2) end
        safePath(entry.path)
        local lower = entry.path:lower()
        if seen[lower] then error("rutas duplicadas en el zip") end
        seen[lower] = true
        if not protected(entry.path) then remote[entry.path] = entry.contents end
    end
    assert(parseVersion(remote["Version.lua"]) == expectedVersion,
        "la version del zip no coincide con la version consultada vuelve a comprobar")
    local currentVersion = localVersion()
    local repairVersion = missingVersionFile()
    assert(not isNewer(currentVersion or expectedVersion, expectedVersion) and
        not isNewer(state.processedVersion or expectedVersion, expectedVersion),
        "el ZIP es anterior a la version local o procesada; vuelve a comprobar")
    local planned, conflicts = {}, 0
    for name, contents in pairs(remote) do
        local path = TARGET .. "/" .. name
        if R.directoryExists(path) then
            conflicts = conflicts + 1
        elseif not R.fileExists(path) then
            planned[#planned + 1] = {path = name, contents = contents}
        elseif R.readFileContents(path) ~= contents then
            conflicts = conflicts + 1
        end
    end
    table.sort(planned, function(a, b)
        if a.path == "Version.lua" then return false end
        if b.path == "Version.lua" then return true end
        return a.path < b.path
    end)
    assert(type(R.deleteFile) == "function", "el cliente no permite revertir archivos nuevos")
    local index, attempted, created = 1, 0, {}
    local function abortInstall(reason)
        if state.abortInstall ~= abortInstall then return end
        state.abortInstall = nil
        local failures = {}
        for i = attempted, 1, -1 do
            local entry = planned[i]
            local path = TARGET .. "/" .. entry.path
            local ok, err = pcall(function()
                if R.fileExists(path) then
                    assert(not entry.verified or R.readFileContents(path) == entry.contents,
                        "se conservo un cambio posterior: " .. path)
                    R.deleteFile(path)
                    assert(not R.fileExists(path), "no se pudo revertir " .. path)
                end
            end)
            if not ok then failures[#failures + 1] = tostring(err) end
        end
        for i = #created, 1, -1 do
            pcall(function()
                local entries = R.listDirectoryFiles(created[i], false, false)
                if type(entries) == "table" and not next(entries) then R.deleteFile(created[i]) end
            end)
        end
        local result = #failures == 0 and "Cambios revertidos." or "Reversion incompleta: " .. table.concat(failures, "; ")
        fail("Instalacion detenida: " .. reason .. ". " .. result, true)
    end
    local function batch()
        if state.abortInstall ~= abortInstall then return end
        if not isActive() then return abortInstall("el perfil se cerro durante la instalacion") end
        local ok, err = pcall(function()
            local last = math.min(index + 14, #planned)
            while index <= last do
                local entry = planned[index]
                local destination = TARGET .. "/" .. entry.path
                assert(not R.fileExists(destination) and not R.directoryExists(destination),
                    "aparecio un archivo durante la actualizacion: " .. entry.path)
                ensureParent(destination, created)
                attempted = index
                writeVerified(destination, entry.contents)
                entry.verified = true
                index = index + 1
            end
            local applied = index - 1
            window.progress:setPercent(math.floor(applied / math.max(1, #planned) * 100))
            window.detail:setText("instalando " .. applied .. "/" .. #planned .. " archivos")
            if index <= #planned then
                G.scheduleEvent(batch, 10)
            end
        end)
        if not ok then return abortInstall(tostring(err)) end
        if index > #planned then
            state.abortInstall = nil
            state.processedVersion = expectedVersion
            state.notice = conflicts > 0 and ("Se conservaron " .. conflicts .. " archivos o carpetas existentes.") or nil
            finish(repairVersion and "archivo Version.lua restaurado" or
                (currentVersion and "actualizacion completada" or "instalacion completada"))
        end
    end
    message("aplicando actualizacion segura")
    window.progress:setPercent(0)
    state.abortInstall = abortInstall
    local scheduled, err = pcall(G.scheduleEvent, batch, 10)
    if not scheduled then abortInstall(tostring(err)) end
end
local function download(version)
    state.installing = true
    message("descargando version " .. version)
    window:show()
    window.progress:setPercent(0)
    local url = "https://github.com/" .. REPOSITORY .. "/archive/refs/heads/" .. BRANCH .. ".zip?t=" .. G.os.time()
    local id = startRequest(DOWNLOAD_TIMEOUT, "La descarga del ZIP agoto el tiempo de espera.", true)
    local previous = H.timeout
    H.timeout = DOWNLOAD_TIMEOUT / 1000
    local ok, operation = pcall(H.get, url, requestCallback(id, function(data, downloadError)
        if downloadError then return fail("No se pudo descargar el ZIP: " .. tostring(downloadError), true) end
        message("comprobando el zip")
        extractAndMerge(data, version)
    end, true))
    H.timeout = previous
    recordRequest(id, ok, operation, true)
end
checkVersion = function()
    if not isActive() or state.busy then return end
    stopTimer()
    state.pendingVersion = nil
    setBusy(true)
    local requestId = startRequest(CHECK_TIMEOUT, "La consulta de version agoto el tiempo de espera.")
    scheduleNext()
    local ok, operation = pcall(function()
        message("Comprobando...")
        window.progress:setPercent(0)
        local current = localVersion()
        showLocalVersion(current)
        local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/" .. BRANCH .. "/Version.lua?t=" .. G.os.time()
        return H.get(url, requestCallback(requestId, function(contents, requestError)
            if requestError then return fail("No se pudo consultar la version: " .. tostring(requestError)) end
            local version = parseVersion(contents)
            if not version then return fail("el archivo de version no contiene una version reconocible") end
            local repair = missingVersionFile()
            local processed = state.processedVersion
            if isNewer(version, current) and (isNewer(version, processed) or
                (repair and not isNewer(processed, version))) then
                state.pendingVersion = version
                controls.updateButton:setText((repair and "Reparar con " or
                    (current and "Actualizar a " or "Instalar ")) .. version)
                message(repair and "Falta Version.lua; puedes recuperarlo" or
                    (current and "Nueva version disponible" or "Instalacion disponible"))
                window.detail:setText("pulsa el boton cuando quieras continuar")
            else
                controls.updateButton:setText("Actualizar")
                message(repair and "Falta Version.lua; la version remota es anterior" or state.notice or "Actualizado")
                window.progress:setPercent(100)
                window.detail:setText("proxima comprobacion en " .. (CHECK_INTERVAL / 1000) .. " segundos")
            end
            setBusy(false)
        end))
    end)
    recordRequest(requestId, ok, operation)
end
controls.check.onClick = checkVersion
controls.updateButton.onClick = function()
    if state.busy or not state.pendingVersion then return end
    local version = state.pendingVersion
    stopTimer()
    setBusy(true)
    local ok, err = pcall(download, version)
    if not ok then fail(tostring(err), true) end
end
checkVersion()
