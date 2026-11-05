setDefaultTab("Main")
local CONFIG_NAME = modules.game_bot.contentsPanel.config:getCurrentOption().text
local REPOSITORY = "oldpowerz/CustomProfile"
local BRANCH = "main"
local CHECK_INTERVAL = 60000
local CHECK_TIMEOUT = 30000
local G = modules._G
local R = G.g_resources
local H = G.HTTP
local BOT = modules.game_bot
local TARGET = "/bot/" .. CONFIG_NAME
local DATA = "/bot_update_data/" .. CONFIG_NAME
local BASELINE = DATA .. "/original.zip"
local REPORT = DATA .. "/last-update.txt"
local STATE_KEY = "CustomProfileUpdaterState"
local old = G[STATE_KEY]
if old then
    if old.busy and old.installing then return end
    if old.window and not old.window:isDestroyed() then old.window:destroy() end
    if old.controls and not old.controls:isDestroyed() then old.controls:destroy() end
    if old.timer then G.removeEvent(old.timer) end
    if old.requestTimer then G.removeEvent(old.requestTimer) end
end
local state = {busy = false, timer = nil, revision = 7, pendingVersion = nil, requestId = 0}
G[STATE_KEY] = state
local controls = setupUI([[
Panel
  height: 88

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
    controls:setHeight(state.pendingVersion and 113 or 88)
end
local function parseVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('CustomPanel%.version%s*=%s*["\'](%d[%d%.]*)["\']')
        or text:match('return%s*["\'](%d[%d%.]*)["\']')
end
local function localVersion()
    if state.appliedVersion then return state.appliedVersion end
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
local JSON = G.json or json
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
local function ensureParent(path)
    local current = ""
    for part in path:match("^(.*)/[^/]+$"):gmatch("[^/]+") do
        current = current .. "/" .. part
        mkdir(current)
    end
end
local function unpackSnapshot(path)
    local archive = R.decompressArchive(path)
    assert(type(archive) == "table", "registro de originales no valido")
    local files, metadata = {}, nil
    for name, contents in pairs(archive) do
        name = name:gsub("^/+", "")
        if name == "snapshot.json" then metadata = JSON.decode(contents)
        elseif name:sub(1, 6) == "files/" then
            local relative = name:sub(7)
            safePath(relative)
            files[relative] = contents
        end
    end
    assert(type(metadata) == "table" and metadata.format == "CustomBotUpdateSnapshot" and
        metadata.profile == CONFIG_NAME and type(metadata.empty) == "table", "registro incompatible")
    for _, name in ipairs(metadata.empty) do safePath(name); files[name] = "" end
    return files, metadata
end
local function saveSnapshot(path, files, version)
    local archive, empty = {}, {}
    for name, contents in pairs(files) do
        safePath(name)
        if contents == "" then empty[#empty + 1] = name else archive["files/" .. name] = contents end
    end
    archive["snapshot.json"] = JSON.encode({format = "CustomBotUpdateSnapshot", profile = CONFIG_NAME,
        version = version, empty = empty, conflicts = state.conflicts or 0})
    local encoded = R.createArchive(archive)
    assert(type(encoded) == "string" and #encoded > 0, "no se pudo crear el respaldo")
    ensureParent(path)
    writeVerified(path, encoded)
    local verified = unpackSnapshot(path)
    for name, contents in pairs(files) do assert(verified[name] == contents, "respaldo incompleto: " .. name) end
    for name in pairs(verified) do assert(files[name] ~= nil, "respaldo inesperado") end
end
local function collectLocal()
    local files, folders, total, count = {}, {""}, 0, 0
    local index = 1
    while folders[index] do
        local folder = folders[index]
        local entries = R.listDirectoryFiles(TARGET .. "/" .. folder, false, false)
        assert(type(entries) == "table", "no se pudo listar el custom")
        for _, part in ipairs(entries) do
            safePath(part)
            assert(not part:find("/", 1, true), "nombre de archivo inesperado")
            local path = folder .. part
            if path ~= ".git" and path:sub(1, 5) ~= ".git/" then
                local absolute = TARGET .. "/" .. path
                if R.fileExists(absolute) then
                    local contents = R.readFileContents(absolute)
                    assert(type(contents) == "string", "no se pudo leer " .. path)
                    count, total = count + 1, total + #contents
                    assert(count <= 10000 and total <= MAX_BYTES, "respaldo supera los limites")
                    files[path] = contents
                elseif R.directoryExists(absolute) then
                    assert(#folders < 10000, "demasiadas carpetas")
                    folders[#folders + 1] = path .. "/"
                end
            end
        end
        index = index + 1
    end
    return files
end

local checkVersion
local fail
local function isActive()
    return G[STATE_KEY] == state and not controls:isDestroyed()
end
local function scheduleNext()
    if state.timer then G.removeEvent(state.timer) end
    state.timer = G.scheduleEvent(function()
        state.timer = nil
        if not isActive() then return end
        if state.busy then
            scheduleNext()
        else
            checkVersion()
        end
    end, CHECK_INTERVAL)
end
fail = function(text)
    if not isActive() then return end
    if state.requestTimer then G.removeEvent(state.requestTimer); state.requestTimer = nil end
    state.requestId = state.requestId + 1
    state.pendingVersion = nil
    setBusy(false)
    message(tostring(text):lower():gsub("[%p]", " "):gsub("%s+", " "))
    window.detail:setText("se comprobara de nuevo en " .. (CHECK_INTERVAL / 1000) .. " segundos")
    if state.installing then window:show() end
    state.installing = false
    scheduleNext()
end
local function finish(version, added, kept, initial)
    state.pendingVersion = nil
    controls.updateButton:setText("Actualizar")
    setBusy(false)
    window.progress:setPercent(100)
    message(state.notice or (initial and "instalacion completada" or "actualizacion completada"))
    window.detail:setText("Respaldo: " .. (state.backupPath or "") .. " | Informe: " .. REPORT)
    state.installing = false
    if state.conflicts and state.conflicts > 0 then window:show() else window:hide() end
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
    assert(type(R.createArchive) == "function" and type(R.listDirectoryFiles) == "function" and
        JSON and type(JSON.encode) == "function" and type(JSON.decode) == "function",
        "el cliente no permite respaldos seguros")
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
    local versionContents
    local remote, seen = {}, {}
    for _, entry in ipairs(entries) do
        if sameRoot and root then entry.path = entry.path:sub(#root + 2) end
        safePath(entry.path)
        local lower = entry.path:lower()
        if seen[lower] then error("rutas duplicadas en el zip") end
        seen[lower] = true
        if entry.path == "Version.lua" then
            versionContents = entry.contents
        end
        if not protected(entry.path) then remote[entry.path] = entry.contents end
    end
    if parseVersion(versionContents) ~= expectedVersion then
        error("la version del zip no coincide con la version consultada vuelve a comprobar")
    end
    local initial = not localVersion()
    if BOT.save then BOT.save() end
    local localFiles = collectLocal()
    local baseline = {}
    if R.fileExists(BASELINE) then baseline = unpackSnapshot(BASELINE) end
    local planned, conflicts, conflictFiles, lines, kept = {}, {}, {}, {}, 0
    for name, contents in pairs(remote) do
        local current, original = localFiles[name], baseline[name]
        if R.directoryExists(TARGET .. "/" .. name) then
            conflicts[#conflicts + 1] = name .. " (existe una carpeta)"
            conflictFiles[name] = contents
        elseif current == contents then
            kept = kept + 1
        elseif current == nil and original == nil then
            planned[#planned + 1] = {path = name, contents = contents}
        elseif current ~= nil and original ~= nil and current == original then
            planned[#planned + 1] = {path = name, contents = contents, before = current}
        elseif original == nil or contents ~= original then
            conflicts[#conflicts + 1] = name .. (original == nil and " (sin referencia previa)" or " (cambios locales y remotos)")
            conflictFiles[name] = contents
        else
            kept = kept + 1
        end
    end
    table.sort(planned, function(a, b)
        if a.path == "Version.lua" then return false end
        if b.path == "Version.lua" then return true end
        return a.path < b.path
    end)
    table.sort(conflicts)
    mkdir("/bot_update_data")
    mkdir(DATA)
    local stamp = tostring(G.os.time())
    local backupPath = DATA .. "/backup-" .. stamp .. ".zip"
    local suffix = 0
    while R.fileExists(backupPath) do
        suffix = suffix + 1
        backupPath = DATA .. "/backup-" .. stamp .. "-" .. suffix .. ".zip"
    end
    message("creando y verificando respaldo")
    if R.fileExists(BASELINE) then
        writeVerified(backupPath .. ".original.zip", R.readFileContents(BASELINE))
    end
    saveSnapshot(backupPath, localFiles, localVersion())
    state.backupPath = backupPath
    lines = {"Perfil: " .. CONFIG_NAME, "Version remota: " .. expectedVersion,
        "Respaldo: " .. backupPath, "Conflictos conservados: " .. #conflicts}
    for _, name in ipairs(conflicts) do
        lines[#lines + 1] = "CONFLICTO: " .. name
    end
    for _, entry in ipairs(planned) do lines[#lines + 1] = "APLICAR: " .. entry.path end
    writeVerified(REPORT, table.concat(lines, "\n"))
    -- Guardar las alternativas remotas fuera del custom, nunca encima de archivos del usuario.
    for path, contents in pairs(conflictFiles) do
        local alternative = backupPath .. ".remote/" .. path
        ensureParent(alternative)
        writeVerified(alternative, contents)
    end
    local index, added = 1, 0
    local function batch()
        local ok, err = pcall(function()
            local last = math.min(index + 14, #planned)
            while index <= last do
                local entry = planned[index]
                local destination = TARGET .. "/" .. entry.path
                local current = R.fileExists(destination) and R.readFileContents(destination) or nil
                assert(current == entry.before and not R.directoryExists(destination),
                    "archivo cambiado durante la actualizacion: " .. entry.path .. "; respaldo: " .. backupPath)
                ensureParent(destination)
                writeVerified(destination, entry.contents)
                added = added + 1
                index = index + 1
            end
            window.progress:setPercent(math.floor(math.min(index - 1, #planned) / math.max(1, #planned) * 100))
            window.detail:setText("instalando " .. math.min(index - 1, #planned) .. "/" .. #planned .. " archivos nuevos")
            if index <= #planned then
                G.scheduleEvent(batch, 10)
            else
                state.conflicts = #conflicts
                saveSnapshot(BASELINE, remote, expectedVersion)
                state.appliedVersion = expectedVersion
                state.notice = #conflicts > 0 and ("Actualizado con " .. #conflicts .. " conflictos. Ver informe.") or nil
                if state.notice then print("[CustomBot Update] " .. state.notice .. " " .. REPORT) end
                finish(expectedVersion, added, kept, initial)
            end
        end)
        if not ok then fail("instalacion detenida " .. tostring(err) .. "; respaldo: " .. backupPath) end
    end
    message("aplicando actualizacion segura")
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
    if not isActive() or state.busy then return end
    if state.timer then G.removeEvent(state.timer); state.timer = nil end
    state.pendingVersion = nil
    setBusy(true)
    state.requestId = state.requestId + 1
    local requestId = state.requestId
    scheduleNext()
    state.requestTimer = G.scheduleEvent(function()
        state.requestTimer = nil
        if isActive() and state.requestId == requestId then
            fail("la consulta de version ha agotado el tiempo de espera")
        end
    end, CHECK_TIMEOUT)
    local ok, err = pcall(function()
        message("Comprobando...")
        window.progress:setPercent(0)
        local current = localVersion()
        controls.localVersion:setText("Version: " .. (current or "sin instalar"))
        local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/" .. BRANCH .. "/Version.lua?t=" .. G.os.time()
        H.get(url, function(contents, requestError)
            if not isActive() or state.requestId ~= requestId then return end
            if state.requestTimer then G.removeEvent(state.requestTimer); state.requestTimer = nil end
            state.requestId = state.requestId + 1
            local success, callbackError = pcall(function()
                if requestError then return fail("no se pudo consultar la version") end
                local version = parseVersion(contents)
                if not version then return fail("el archivo de version no contiene una version reconocible") end
                if isNewer(version, current) then
                    state.pendingVersion = version
                    setBusy(false)
                    controls.updateButton:setText((current and "Actualizar a " or "Instalar ") .. version)
                    message(current and "Nueva version disponible" or "Instalacion disponible")
                    window.detail:setText("pulsa el boton cuando quieras continuar")
                else
                    setBusy(false)
                    controls.updateButton:setText("Actualizar")
                    message(state.notice or "Actualizado")
                    window.progress:setPercent(100)
                    window.detail:setText("proxima comprobacion en " .. (CHECK_INTERVAL / 1000) .. " segundos")
                end
            end)
            if not success then fail(tostring(callbackError)) end
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
    if R.fileExists(BASELINE) then
        local _, metadata = unpackSnapshot(BASELINE)
        state.appliedVersion = metadata.version
        state.conflicts = metadata.conflicts or 0
        if state.conflicts > 0 then
            state.notice = "Actualizado con " .. state.conflicts .. " conflictos. Ver informe."
        end
    end
end)
if not ok then
    fail(tostring(err))
else
    checkVersion()
end
