-- main tab

local panel = modules.game_bot.contentsPanel
local configName = panel.config:getCurrentOption().text
local pathBot = "/bot/" .. configName .. "/"

CustomPanel = CustomPanel or {}
CustomPanel.backups = {}
local backups = CustomPanel.backups
backups.maxFileBytes = 256 * 1024 * 1024
backups.maxArchiveBytes = backups.maxFileBytes + 16 * 1024 * 1024
do
  local resources = g_resources
  local protected = {
    ["custom_profiles.lua"] = true, ["CustomPanel.lua"] = true,
    ["koofr_lib.lua"] = true
  }

  local function validSlot(profile)
    assert(type(profile) == "number" and profile == math.floor(profile) and
           profile >= 1 and profile <= 10, "Perfil invalido")
  end

  local function safePath(path)
    assert(type(path) == "string" and #path > 0 and #path <= 500 and
           not path:find('[%c\\:*?"<>|]') and not path:find("//", 1, true) and
           path:sub(1, 1) ~= "/" and path:sub(-1) ~= "/", "Ruta invalida")
    for part in path:gmatch("[^/]+") do
      local device = part:lower():match("^[^.]+") or ""
      assert(part ~= "." and part ~= ".." and not part:find("[%. ]$") and
             device ~= "nul" and device ~= "con" and device ~= "aux" and device ~= "prn" and
             not device:match("^com[1-9]$") and not device:match("^lpt[1-9]$"), "Ruta reservada")
    end
  end

  function backups.filename(name)
    assert(type(name) == "string" and #name > 0 and #name <= 74 and name:find("%S"),
           "Escribe un nombre de respaldo de hasta 70 caracteres, sin contar .zip")
    local file = name:lower():match("%.zip$") and name or (name .. ".zip")
    local stem = file:sub(1, -5)
    assert(#stem > 0 and #stem <= 70 and stem:find("%S") and
           not stem:find("[%. ]$") and not file:find("[/\\]"), "Nombre de respaldo invalido")
    safePath(file)
    return file
  end

  local function makeDirectory(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
      current = current .. "/" .. part
      if not resources.directoryExists(current) then resources.makeDir(current) end
      assert(resources.directoryExists(current), "No se pudo crear " .. current)
    end
  end

  function backups.validateUI(path, data)
    local function validate(text, firstLine)
      local lineNumber = firstLine
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:find("%S") then
          local indentation = line:match("^([ \t]*)")
          assert(not indentation:find("\t", 1, true) and #indentation % 2 == 0,
                 "Interfaz invalida en " .. path .. ", linea " .. lineNumber ..
                 ": usa indentacion de 2 espacios. No se importo el respaldo.")
        end
        lineNumber = lineNumber + 1
      end
    end
    local extension = path:lower():match("%.([a-z]+)$")
    if extension == "otui" then
      validate(data, 1)
    elseif extension == "lua" then
      local position = 1
      for block = 1, #data do
        local first, last, equals = data:find("%[(=*)%[", position)
        if not first then break end
        local closing = data:find("]" .. equals .. "]", last + 1, true)
        if not closing then break end
        local text = data:sub(last + 1, closing - 1)
        local root = text:match("^%s*([%w_]+)")
        if root and (root:match("Panel$") or root:match("Window$") or
                     root:match("Widget$") or root:match("Button$") or
                     root == "Label" or root == "ComboBox") then
          local _, lines = data:sub(1, last):gsub("\n", "")
          validate(text, lines + 1)
        end
        position = closing + #equals + 2
      end
    end
  end

  -- Una tarea por evento: compatible con el sandbox, sin coroutines.
  local function startJob(callback)
    assert(not backups.busy, "Ya hay una operacion de respaldos en curso.")
    assert(type(callback) == "function", "Falta el callback de finalizacion")
    local job = {writing = false}
    backups.busy = true
    local function run()
      local task = job.task
      job.task = nil
      local ok, message = pcall(task)
      if not ok then
        job.task = nil
        backups.busy = false
        local warning = job.writing and " Puede haber archivos parcialmente escritos." or
          " No se escribieron archivos del respaldo."
        callback(false, tostring(message) .. warning)
      elseif job.task then
        schedule(10, run)
      end
    end
    function job.go(task, message)
      job.task = task
      if message and backups.showStatus then backups.showStatus(message) end
    end
    function job.finish(result)
      job.task = nil
      backups.busy = false
      callback(true, result)
    end
    function job.start(task)
      job.go(task)
      schedule(10, run)
    end
    return job
  end

  function backups.pack(profile, onComplete)
    local job = startJob(onComplete)
    local files, pending, current = {}, {""}, nil
    local folderIndex, entryIndex, count, total = 1, 1, 0, 0
    local source, base
    local function visit()
      if not current then
        local folder = pending[folderIndex]
        if folder == nil then
          assert(files["storage/profile_" .. profile .. ".json"], "No se encontro el storage del perfil " .. profile)
          job.finish({v = 2, src = source, profile = profile, files = files})
          return
        end
        current = resources.listDirectoryFiles(base .. folder, false, false)
        entryIndex = 1
      end
      local part = current[entryIndex]
      if part == nil then
        current = nil
        folderIndex = folderIndex + 1
        job.go(visit)
        return
      end
      entryIndex = entryIndex + 1
      assert(not part:find("/", 1, true), "Nombre inesperado")
      local path = pending[folderIndex] .. part
      safePath(path)
      if resources.fileExists(base .. path) then
        local slot = path:lower():match("^storage/profile_(%d+)%.json$")
        if not slot or tonumber(slot) == profile then
          local data = resources.readFileContents(base .. path)
          count = count + 1
          total = total + #data
          assert(count <= 10000, "Demasiados archivos")
          assert(total <= backups.maxFileBytes, "La config supera 256 MiB")
          if backups.showStatus then backups.showStatus("Exportando: " .. path) end
          assert(path:lower() ~= "custombot-backup.json", "El Custom contiene un nombre reservado: " .. path)
          files[path] = data
          job.go(visit)
          return
        end
      elseif resources.directoryExists(base .. path) then
        assert(#pending < 10000, "Demasiadas carpetas")
        pending[#pending + 1] = path .. "/"
      end
      job.go(visit)
    end
    job.start(function()
      validSlot(profile)
      source = configName
      base = "/bot/" .. source .. "/"
      if profile == CustomPanel.getProfile() and modules.game_bot.save then modules.game_bot.save() end
      job.go(visit, "Preparando exportacion...")
    end)
  end

  -- Prepara el ZIP en memoria; subirlo a la nube no crea una copia local.
  function backups.createProfileArchive(profile, onComplete)
    assert(type(resources.createArchive) == "function", "createArchive no esta disponible en este cliente")
    backups.pack(profile, function(ok, document)
      if not ok then onComplete(false, document) return end
      local job = startJob(onComplete)
      job.start(function()
        local emptyFiles = {}
        for filePath, data in pairs(document.files) do
          if data == "" then emptyFiles[#emptyFiles + 1] = filePath end
        end
        document.files["custombot-backup.json"] = json.encode({
          format = "CustomPanelBackup", v = 2, src = document.src,
          profile = document.profile, emptyFiles = emptyFiles
        })
        job.go(function()
          local encoded = resources.createArchive(document.files)
          document = nil
          assert(type(encoded) == "string" and #encoded > 0, "No se pudo comprimir el respaldo")
          assert(#encoded <= backups.maxArchiveBytes, "Respaldo demasiado grande")
          job.finish(encoded)
        end, "Comprimiendo con createArchive. Puede tardar...")
      end)
    end)
  end

  function backups.exportProfile(profile, path, onComplete)
    assert(not resources.fileExists(path), "El archivo de destino ya existe")
    backups.createProfileArchive(profile, function(ok, encoded)
      if not ok then onComplete(false, encoded) return end
      local job = startJob(onComplete)
      job.start(function()
        assert(not resources.fileExists(path), "El archivo de destino ya existe")
        job.writing = true
        makeDirectory(path:match("^(.*)/"))
        assert(resources.writeFileContents(path, encoded) ~= false, "No se pudo exportar el respaldo")
        job.go(function()
          assert(resources.readFileContents(path) == encoded, "No se pudo verificar el respaldo exportado")
          job.finish(path)
        end, "Verificando ZIP exportado...")
      end)
    end)
  end

  function backups.install(document, profile, onComplete)
    local job = startJob(onComplete)
    local entries, seen, coreFiles = {}, {}, {}
    local index, total, phase = 1, 0, "validate"
    local name, base, sourceSlot
    local function process()
      local entry = entries[index]
      if not entry then
        if phase == "validate" then
          if modules.game_bot.save then modules.game_bot.save() end
          phase, index = "write", 1
          job.go(process, "Validacion terminada. Preparando escritura...")
        else
          job.finish(name)
        end
        return
      end
      local path, value = entry.path, entry.value
      if phase == "validate" then
        if entry.core then
          backups.validateUI(path, value)
          index = index + 1
          job.go(process)
          return
        end
        assert(type(value) == "string", "Archivo invalido: " .. path)
        total = total + #value
        assert(total <= backups.maxFileBytes, "La config supera 256 MiB")
      end
      if not entry.core and protected[path] then
        index = index + 1
        job.go(process)
        return
      end
      local function decoded(data)
        if phase == "validate" then
          backups.validateUI(path, data)
          if path == sourceSlot then assert(type(json.decode(data)) == "table", "Storage invalido") end
          index = index + 1
          job.go(process)
          return
        end
        local destination = path == sourceSlot and ("storage/profile_" .. profile .. ".json") or path
        local extension = path:lower():match("%.([a-z]+)$")
        if path ~= sourceSlot and not entry.core and (extension == "lua" or extension == "cfg" or extension == "json" or
           extension == "otui" or extension == "otml") then
          local pattern = ("/bot/" .. document.src .. "/"):gsub("(%W)", "%%%1")
          data = data:gsub(pattern, function() return base end)
        end
        job.go(function()
          job.writing = true
          makeDirectory((base .. destination):match("^(.*)/"))
          assert(resources.writeFileContents(base .. destination, data) ~= false, "No se pudo escribir " .. destination)
          job.go(function()
            assert(resources.readFileContents(base .. destination) == data, "No se pudo verificar " .. destination)
            index = index + 1
            job.go(process)
          end, "Verificando: " .. destination)
        end, "Escribiendo: " .. destination)
      end
      if backups.showStatus then backups.showStatus((phase == "validate" and "Validando: " or "Decodificando: ") .. path) end
      decoded(value)
    end
    local function prepare()
      validSlot(profile)
      profile = math.floor(profile)
      assert(type(document) == "table" and document.v == 2 and
             type(document.files) == "table", "Respaldo incompatible")
      validSlot(document.profile)
      document.profile = math.floor(document.profile)
      safePath(document.src)
      assert(not document.src:find("/", 1, true), "Origen invalido")
      sourceSlot = "storage/profile_" .. document.profile .. ".json"
      for _, path in ipairs({"cavebot.lua", "CustomPanel.lua", sourceSlot}) do assert(document.files[path], "Falta " .. path) end
      name = configName
      safePath(name)
      assert(not name:find("/", 1, true), "Destino invalido")
      base = "/bot/" .. name .. "/"
      for path, value in pairs(document.files) do
        safePath(path)
        local key = path:lower()
        assert(not seen[key], "Ruta duplicada")
        seen[key] = true
        if key:match("^storage/profile_%d+%.json$") then assert(path == sourceSlot, "El respaldo mezcla perfiles") end
        assert(#entries < 10000, "Demasiados archivos")
        entries[#entries + 1] = {path = path, value = value}
      end
      for path in pairs(protected) do
        coreFiles[path] = resources.readFileContents(pathBot .. path)
        entries[#entries + 1] = {path = path, value = coreFiles[path], core = true}
      end
      job.go(process, "Validando respaldo...")
    end
    job.start(function()
      if type(document) == "string" then
        local archivePath = document
        assert(archivePath:lower():match("%.zip$"), "Selecciona un respaldo ZIP")
        local data = resources.readFileContents(document)
        assert(#data <= backups.maxArchiveBytes, "Respaldo demasiado grande")
        job.go(function()
          assert(type(resources.decompressArchive) == "function", "decompressArchive no esta disponible en este cliente")
          local extracted = resources.decompressArchive(data)
          assert(type(extracted) == "table", "No se pudo descomprimir el respaldo")
          local files, seenPaths, expanded, count = {}, {}, 0, 0
          for path, contents in pairs(extracted) do
            assert(type(path) == "string" and type(contents) == "string", "Entrada ZIP invalida")
            -- decompressArchive devuelve nombres con una barra inicial.
            if path:sub(1, 1) == "/" then path = path:sub(2) end
            safePath(path)
            local key = path:lower()
            assert(not seenPaths[key], "Ruta ZIP duplicada")
            seenPaths[key] = true
            expanded = expanded + #contents
            count = count + 1
            assert(expanded <= backups.maxFileBytes + 1024 * 1024 and count <= 10001, "ZIP demasiado grande")
            files[path] = contents
          end
          local metadata = files["custombot-backup.json"]
          assert(type(metadata) == "string" and #metadata <= 1024 * 1024, "Faltan los datos del perfil en el ZIP")
          local manifest = json.decode(metadata)
          assert(type(manifest) == "table" and manifest.format == "CustomPanelBackup" and manifest.v == 2,
                 "ZIP de respaldo incompatible")
          files["custombot-backup.json"] = nil
          assert(type(manifest.emptyFiles) == "table", "Lista de archivos vacios invalida")
          local emptyCount = 0
          for _, path in ipairs(manifest.emptyFiles) do
            safePath(path)
            local key = path:lower()
            assert(not seenPaths[key], "Archivo vacio duplicado")
            seenPaths[key] = true
            emptyCount = emptyCount + 1
            assert(count + emptyCount <= 10001, "Demasiados archivos")
            files[path] = ""
          end
          document = {v = 2, src = manifest.src, profile = manifest.profile, files = files}
          job.go(prepare)
        end, "Abriendo respaldo. La descompresion nativa puede tardar...")
      else
        job.go(prepare)
      end
    end)
  end
end

CustomPanel.backgrounds = {
    defaults = {bot = "", window = ""},
    widgets = {},
    appliedPaths = {},
    requestVersions = {},
    downloads = {},
    requestedSources = {},
    resourcesPath = pathBot .. "resources/"
}
local backgrounds = CustomPanel.backgrounds

function CustomPanel.getProfile()
    return CustomProfiles and CustomProfiles.getProfile() or 1
end

function CustomPanel.setProfile(profile, options)
    return CustomProfiles and CustomProfiles.setProfile(profile, options) or false
end

if type(storage.customPanelBackgrounds) ~= "table" then
    storage.customPanelBackgrounds = {}
end
for target, defaultUrl in pairs(backgrounds.defaults) do
    local saved = storage.customPanelBackgrounds[target]
    if type(saved) ~= "string" or saved == "" then
        storage.customPanelBackgrounds[target] = defaultUrl
    end
end

local _origUIButton = UI.Button
UI.Button = function(text, callback, parent)
    local w = _origUIButton(text, callback, parent)
    w:setImageSource("")
    w:setTooltip("Boton")
    return w
end

local _origUITextEdit = UI.TextEdit
UI.TextEdit = function(text, callback, parent)
  local z = _origUITextEdit(text, callback, parent)
  z:setImageSource("")
  z:setTooltip("Editable")
  return z
end

--[[local _origDualScrollPanel = UI.DualScrollPanel
UI.DualScrollPanel = function(text, callback, parent)
  local y = _origUITextEdit(text, callback, parent)
  y:setImageSource("")
  return y
end
]]


function backgrounds.fileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok, exists = pcall(function()
        return g_resources.fileExists(path)
    end)
    return ok and exists == true
end

function backgrounds.isPng(data)
    return type(data) == "string" and #data >= 8 and
           data:sub(1, 8) == "\137PNG\r\n\26\n"
end

function backgrounds.hashUrl(url)
    local hash = 0
    for index = 1, #url do
        hash = (hash * 31 + url:byte(index)) % 2147483647
    end
    return tostring(hash)
end

function backgrounds.resourcePath(target, url)
    return backgrounds.resourcesPath .. "background_" .. target .. "_" .. backgrounds.hashUrl(url) .. ".png"
end

function backgrounds.localPath(source, target)
    if type(source) ~= "string" then return nil end
    if source:sub(1, #backgrounds.resourcesPath) == backgrounds.resourcesPath then
        source = source:sub(#backgrounds.resourcesPath + 1)
    end
    if source:find("[/\\]") or not source:lower():match("%.png$") then return nil end
    if target then
        if not backgrounds.defaults[target] then return nil end
        local prefix = "background_" .. target
        local name = source:lower()
        if name ~= prefix .. ".png" and name:sub(1, #prefix + 1) ~= prefix .. "_" then return nil end
    end
    return backgrounds.resourcesPath .. source
end

function backgrounds.getDimensions(data)
    if not backgrounds.isPng(data) or #data < 24 or data:sub(13, 16) ~= "IHDR" then return nil end
    local function uint32(offset)
        local a, b, c, d = data:byte(offset, offset + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    local width, height = uint32(17), uint32(21)
    if width < 1 or height < 1 or width > 2147483647 or height > 2147483647 then return nil end
    return width, height
end

function backgrounds.listImages(target)
    if not backgrounds.defaults[target] then return {} end
    local ok, files = pcall(function()
        return g_resources.listDirectoryFiles(backgrounds.resourcesPath, false, false)
    end)
    local images, seen = {}, {}
    for _, file in ipairs(ok and type(files) == "table" and files or {}) do
        local path = backgrounds.localPath(file, target)
        if path and not seen[path] and backgrounds.fileExists(path) then
            seen[path] = true
            table.insert(images, path:sub(#backgrounds.resourcesPath + 1))
        end
    end
    table.sort(images, function(a, b) return a:lower() < b:lower() end)
    return images
end

function backgrounds.resizeWindow(widget, data)
    local width, height = backgrounds.getDimensions(data)
    if not width then return false end
    widget:setWidth(width)
    widget:setHeight(height)
    storage.customPanelWindow.width = width
    storage.customPanelWindow.height = height
    if widget.rightResizeBorder then
        widget.rightResizeBorder:setMinimum(math.min(420, width))
        widget.rightResizeBorder:setMaximum(math.max(1000, width))
    end
    if widget.bottomResizeBorder then
        widget.bottomResizeBorder:setMinimum(math.min(220, height))
        widget.bottomResizeBorder:setMaximum(math.max(800, height))
    end
    return true
end

function backgrounds.applyImage(target, path, version)
    local widget = backgrounds.widgets[target]
    if not widget or not backgrounds.fileExists(path) then return false end
    local function apply()
        if backgrounds.requestVersions[target] ~= version or backgrounds.widgets[target] ~= widget then return end
        local ok, err = pcall(function()
            local data = g_resources.readFileContents(path)
            if not backgrounds.getDimensions(data) then error("imagen PNG no valida: " .. path) end
            widget:setImageSource(path)
            if target == "window" then backgrounds.resizeWindow(widget, data) end
        end)
        if ok then
            backgrounds.appliedPaths[target] = path
            storage.customPanelBackgrounds[target] = backgrounds.requestedSources[target]
            if backgrounds.refreshImages then backgrounds.refreshImages() end
        else
            print("CustomPanel: no se pudo aplicar el fondo: " .. tostring(err))
        end
        return ok
    end
    local scheduleApply = modules.corelib and modules.corelib.scheduleEvent
    if type(scheduleApply) == "function" then
        scheduleApply(apply, 1)
        return true
    end
    return apply()
end

function backgrounds.setSource(target, url)
    if not backgrounds.defaults[target] or type(url) ~= "string" then return false end
    url = url:match("^%s*(.-)%s*$")
    local isUrl = url:match("^https?://") ~= nil
    local path = isUrl and backgrounds.resourcePath(target, url) or backgrounds.localPath(url, target)
    if not path or (not isUrl and not backgrounds.fileExists(path)) then
        print("custompanel introduce un enlace http/https o selecciona un png del grupo background_" .. target)
        return false
    end
    if not isUrl then url = path end

    backgrounds.requestVersions[target] = (backgrounds.requestVersions[target] or 0) + 1
    local version = backgrounds.requestVersions[target]
    backgrounds.requestedSources[target] = url

    if backgrounds.fileExists(path) then
        return backgrounds.applyImage(target, path, version)
    end
    if backgrounds.downloads[path] then return true end
    backgrounds.downloads[path] = true

    HTTP.get(url, function(data, err)
        backgrounds.downloads[path] = nil
        if err or not backgrounds.getDimensions(data) then
            print("CustomPanel: el enlace no devolvio un PNG valido")
            return
        end

        local ok = pcall(function()
            if not g_resources.directoryExists(backgrounds.resourcesPath) then
                g_resources.makeDir(backgrounds.resourcesPath)
            end
            g_resources.writeFileContents(path, data)
        end)
        if ok and backgrounds.fileExists(path) then
            if backgrounds.requestedSources[target] == url then
                backgrounds.applyImage(target, path, backgrounds.requestVersions[target])
            elseif backgrounds.refreshImages then
                backgrounds.refreshImages()
            end
        else
            print("CustomPanel: no se pudo guardar el PNG en resources")
        end
    end)
    return true
end

function backgrounds.registerWidget(target, widget)
    if not backgrounds.defaults[target] or not widget then return false end
    backgrounds.widgets[target] = widget
    local source = storage.customPanelBackgrounds[target]
    if not source:match("^https?://") and not backgrounds.localPath(source, target) then
        storage.customPanelBackgrounds[target] = backgrounds.defaults[target]
    end
    return backgrounds.setSource(target, storage.customPanelBackgrounds[target])
end

function backgrounds.reset(target)
    local url = backgrounds.defaults[target]
    if not url then return nil end
    backgrounds.setSource(target, url)
    return url
end

function backgrounds.getSource(target)
    return storage.customPanelBackgrounds[target] or backgrounds.defaults[target] or ""
end

function CustomPanel.listBackgroundImages(...)
    return backgrounds.listImages(...)
end

function CustomPanel.setBackgroundUrl(...)
    return backgrounds.setSource(...)
end

function CustomPanel.registerBackgroundWidget(...)
    return backgrounds.registerWidget(...)
end

function CustomPanel.resetBackground(...)
    return backgrounds.reset(...)
end

function CustomPanel.getBackgroundUrl(...)
    return backgrounds.getSource(...)
end

function CustomPanel.refreshBackgroundImages(...)
    if backgrounds.refreshImages then return backgrounds.refreshImages(...) end
end

function CustomPanel.openBackgroundPicker(...)
    if backgrounds.openPicker then return backgrounds.openPicker(...) end
end

panel.config:setImageSource("")
panel.enableButton:setImageSource("")
panel.editConfig:setImageSource("")
for _, value in ipairs(tabs.tabs) do
    value:setImageSource("")
end

backgrounds.registerWidget("bot", panel)

CustomPanel = CustomPanel or {}
CustomPanel.panels = CustomPanel.panels or {}
CustomPanel.pending = CustomPanel.pending or {}
CustomPanel.mountEntries = CustomPanel.mountEntries or {}
CustomPanel.validPanels = {
  main = true,
  pvp = true,
  hp = true,
  other = true,
  settings = true
}
storage.customPanelWindow = storage.customPanelWindow or {}
storage.customPanelWindow.width = tonumber(storage.customPanelWindow.width) or 498
storage.customPanelWindow.width = math.max(1, storage.customPanelWindow.width)
storage.customPanelWindow.height = tonumber(storage.customPanelWindow.height) or 281
storage.customPanelWindow.height = math.max(1, storage.customPanelWindow.height)

CustomPanel.fadeDuration = 220
CustomPanel.animations = {duration = CustomPanel.fadeDuration}
local animations = CustomPanel.animations

function animations.install(window)
  if not window or window.customPanelFade then return end
  local state = {version = 0, destroyed = false}
  local setVisible = window.setVisible
  local destroy = window.destroy
  window.customPanelFade = state

  local function animate(visible)
    if state.destroyed then return end
    visible = visible == true
    if state.target == visible then return end
    local wasVisible = window:isExplicitlyVisible()
    state.version = state.version + 1
    local version = state.version
    state.target = visible
    local schedule = modules.corelib and modules.corelib.scheduleEvent
    if type(schedule) ~= "function" or (not wasVisible and not visible) then
      setVisible(window, visible)
      window:setOpacity(1)
      state.target = nil
      return
    end

    local from = wasVisible and window:getOpacity() or 0
    local destination = visible and 1 or 0
    if visible then
      window:setOpacity(from)
      setVisible(window, true)
    end
    local elapsed, step = 0, 16
    local duration = math.max(1, tonumber(CustomPanel.fadeDuration) or animations.duration)
    local function update()
      if state.destroyed or state.version ~= version then return end
      elapsed = math.min(duration, elapsed + step)
      local progress = elapsed / duration
      local eased = progress * progress * (3 - 2 * progress)
      window:setOpacity(from + (destination - from) * eased)
      if elapsed < duration then
        schedule(update, step)
      else
        if not visible then setVisible(window, false) end
        window:setOpacity(1)
        state.target = nil
      end
    end
    schedule(update, step)
  end

  window.setVisible = function(self, visible) animate(visible) end
  window.show = function(self) animate(true) end
  window.hide = function(self) animate(false) end
  window.destroy = function(self, ...)
    state.destroyed = true
    state.version = state.version + 1
    return destroy(self, ...)
  end
end

function CustomPanel.installWindowFade(window)
  return animations.install(window)
end

animations.install(modules.game_bot.botWindow)

function CustomPanel.open()
  local window = CustomPanel.window or windowUI
  if not window then return end

  window:show()
  window:focus()
  window:raise()

end

function CustomPanel.close()
  local window = CustomPanel.window or windowUI
  if not window then return end
  window:hide()
end

CustomPanel.currentParent = nil
if not CustomPanel.autoParentInstalled then
  CustomPanel.autoParentInstalled = true

  local originalSetupUI = setupUI
  setupUI = function(otml, parent)
    local widget = originalSetupUI(otml, parent or CustomPanel.currentParent)
    if type(CustomPanel.captureBotSwitchControls) == "function" then
      CustomPanel.captureBotSwitchControls(otml, widget)
    end
    return widget
  end

  local originalMacro = macro
  macro = function(timeout, nameOrCallback, hotkeyOrCallback, callbackOrParent, parent)
    local scriptErrorHandler = CustomPanel.currentScriptErrorHandler
    local function protectMacroCallback(callback)
      if type(callback) ~= "function" or type(scriptErrorHandler) ~= "function" then
        return callback
      end

      return function(...)
        local ok, result = pcall(callback, ...)
        if not ok then
          scriptErrorHandler(result)
          return
        end
        return result
      end
    end

    local function registerMacroControl(control)
      if type(nameOrCallback) == "string" and nameOrCallback ~= "" and
         type(CustomPanel.captureDetectedControl) == "function" then
        CustomPanel.captureDetectedControl(nameOrCallback, control, "macro")
      end
      return control
    end

    -- macro(timeout, callback)
    if type(nameOrCallback) == "function" then
      return originalMacro(
        timeout,
        "",
        "",
        protectMacroCallback(nameOrCallback),
        hotkeyOrCallback or CustomPanel.currentParent
      )
    end

    -- macro(timeout, name, callback [, parent])
    if type(hotkeyOrCallback) == "function" then
      return registerMacroControl(originalMacro(
        timeout,
        nameOrCallback,
        "",
        protectMacroCallback(hotkeyOrCallback),
        callbackOrParent or CustomPanel.currentParent
      ))
    end

    -- macro(timeout, name, hotkey, callback [, parent])
    return registerMacroControl(originalMacro(
      timeout,
      nameOrCallback,
      hotkeyOrCallback,
      protectMacroCallback(callbackOrParent),
      parent or CustomPanel.currentParent
    ))
  end

  local originalLabel = UI.Label
  if type(originalLabel) == "function" then
    UI.Label = function(text, parent)
      return originalLabel(text, parent or CustomPanel.currentParent)
    end
  end

  local originalButton = UI.Button
  if type(originalButton) == "function" then
    UI.Button = function(text, callback, parent)
      return originalButton(text, callback, parent or CustomPanel.currentParent)
    end
  end

  local originalTextEdit = UI.TextEdit
  if type(originalTextEdit) == "function" then
    UI.TextEdit = function(text, callback, parent)
      return originalTextEdit(text, callback, parent or CustomPanel.currentParent)
    end
  end

  local originalContainer = UI.Container
  if type(originalContainer) == "function" then
    UI.Container = function(callback, hotkey, parent, widget)
      if widget ~= nil then
        return originalContainer(callback, hotkey, parent, widget)
      end
      return originalContainer(callback, hotkey, parent or CustomPanel.currentParent)
    end
  end

  local originalSeparator = UI.Separator
  if type(originalSeparator) == "function" then
    UI.Separator = function(parent)
      return originalSeparator(parent or CustomPanel.currentParent)
    end
  end

  local originalDualScrollPanel = UI.DualScrollPanel
  if type(originalDualScrollPanel) == "function" then
    UI.DualScrollPanel = function(config, callback, parent)
      return originalDualScrollPanel(config, callback, parent or CustomPanel.currentParent)
    end
  end

  local originalTwoItemsAndSlotPanel = UI.TwoItemsAndSlotPanel
  if type(originalTwoItemsAndSlotPanel) == "function" then
    UI.TwoItemsAndSlotPanel = function(config, callback, parent)
      return originalTwoItemsAndSlotPanel(config, callback, parent or CustomPanel.currentParent)
    end
  end
end

local function normalizeCustomPanelName(name)
  return tostring(name or ""):lower()
end

function CustomPanel.registerMountEntry(panelName, side, callback, displayName)
  for _, entry in ipairs(CustomPanel.mountEntries) do
    if entry.callback == callback then
      entry.detectedNames = entry.detectedNames or {}
      entry.detectedControls = entry.detectedControls or {}
      entry.pendingControls = entry.pendingControls or {}
      entry.settingsRows = entry.settingsRows or {}
      entry.index = entry.index or 1
      if type(displayName) == "string" and displayName ~= "" then
        entry.displayName = displayName
      end
      return entry, false
    end
  end

  local entry = {
    panel = normalizeCustomPanelName(panelName),
    side = normalizeCustomPanelName(side),
    callback = callback,
    index = #CustomPanel.mountEntries + 1,
    displayName = displayName,
    detectedNames = {},
    detectedControls = {},
    pendingControls = {},
    settingsRows = {}
  }
  table.insert(CustomPanel.mountEntries, entry)
  return entry, true
end

local function cleanDetectedName(name)
  name = tostring(name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

function CustomPanel.addDetectedName(entry, name)
  if not entry then return end
  name = cleanDetectedName(name)
  if name == "" then return end

  entry.detectedNames = entry.detectedNames or {}
  for _, detectedName in ipairs(entry.detectedNames) do
    if detectedName == name then return end
  end
  table.insert(entry.detectedNames, name)
end

local function getControlMethod(control, methodName)
  if not control then return nil end
  local ok, method = pcall(function()
    return control[methodName]
  end)
  if ok and type(method) == "function" then return method end
  return nil
end

function CustomPanel.registerDetectedControl(entry, name, control, kind)
  if not entry then return end

  name = cleanDetectedName(name)
  if name == "" then return end
  CustomPanel.addDetectedName(entry, name)

  entry.detectedControls = entry.detectedControls or {}
  local detected = entry.detectedControls[name]
  if not detected then
    detected = {name = name, control = control, kind = kind}
    entry.detectedControls[name] = detected
  elseif not detected.control and control then
    detected.control = control
    detected.kind = kind
  end
  CustomPanel.addMountEntryToSettings(entry, name, detected)

  local checkBox = entry.settingsRows and entry.settingsRows[name]
  if checkBox and detected.control and getControlMethod(detected.control, "setOn") then
    checkBox:setTooltip("Mostrar u ocultar el icono de " .. name)
    if checkBox:isChecked() then
      CustomPanel.setDetectedIconEnabled(entry, detected, true)
    end
  end
end

function CustomPanel.captureDetectedControl(name, control, kind)
  CustomPanel.registerDetectedControl(CustomPanel.currentMountEntry, name, control, kind)
end

local function parseOtmlText(value)
  value = cleanDetectedName(value)
  local translated = value:match("^tr%(%s*'(.-)'%s*%)$") or
                     value:match('^tr%(%s*"(.-)"%s*%)$')
  if translated then return translated end
  local quoted = value:match("^'(.-)'$") or value:match('^"(.-)"$')
  return quoted or value
end

local function findChildById(widget, id)
  if not widget or not id or id == "" then return nil end
  local ok, child = pcall(function() return widget[id] end)
  if ok and child then return child end

  local getId = getControlMethod(widget, "getId")
  if getId then
    ok, child = pcall(function() return widget:getId() end)
    if ok and child == id then return widget end
  end

  local recursiveGetChildById = getControlMethod(widget, "recursiveGetChildById")
  if recursiveGetChildById then
    ok, child = pcall(function() return widget:recursiveGetChildById(id) end)
    if ok and child then return child end
  end

  local getChildById = getControlMethod(widget, "getChildById")
  if getChildById then
    ok, child = pcall(function() return widget:getChildById(id) end)
    if ok and child then return child end
  end
  return nil
end

function CustomPanel.captureBotSwitchControls(otml, rootWidget)
  if not CustomPanel.currentMountEntry or type(otml) ~= "string" then return end

  local inBotSwitch = false
  local botSwitchIndent = 0
  local botSwitchId = nil
  local botSwitchName = nil

  local function registerBotSwitch()
    local control = findChildById(rootWidget, botSwitchId)
    if botSwitchName then
      CustomPanel.captureDetectedControl(botSwitchName, control, "botswitch")
    elseif control then
      local entry = CustomPanel.currentMountEntry
      entry.pendingControls = entry.pendingControls or {}
      table.insert(entry.pendingControls, {control = control, kind = "botswitch"})
    end
  end

  for line in (otml .. "\n"):gmatch("([^\n]*)\n") do
    local spaces, content = line:match("^(%s*)(.-)%s*$")
    local indent = spaces and #spaces or 0

    if content:match("^[%w_]*BotSwitch$") or
       content:match("^.-<%s*[%w_]*BotSwitch$") then
      if inBotSwitch then registerBotSwitch() end
      inBotSwitch = true
      botSwitchIndent = indent
      botSwitchId = nil
      botSwitchName = nil
    elseif inBotSwitch then
      if content ~= "" and indent <= botSwitchIndent then
        registerBotSwitch()
        inBotSwitch = false
      else
        local id = content:match("^id:%s*(.+)$")
        if id then botSwitchId = cleanDetectedName(id) end
        local value = content:match("^!text:%s*(.+)$") or
                      content:match("^text:%s*(.+)$")
        if value then
          botSwitchName = parseOtmlText(value)
        end
      end
    end
  end
  if inBotSwitch then registerBotSwitch() end
end

function CustomPanel.refreshPendingControls(entry)
  if not entry then return end
  for _, pending in ipairs(entry.pendingControls or {}) do
    if not pending.registered and pending.control then
      local getText = getControlMethod(pending.control, "getText")
      if getText then
        local ok, text = pcall(function() return pending.control:getText() end)
        text = ok and cleanDetectedName(text) or ""
        if text ~= "" then
          pending.registered = true
          CustomPanel.registerDetectedControl(entry, text, pending.control, pending.kind)
        end
      end
    end
  end
end

local function makeIconStorageKey(entry, name)
  local raw = entry.panel .. "_" .. entry.side .. "_" .. tostring(entry.index or 1) .. "_" .. name:lower()
  return raw:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local function makeIconId(storageKey)
  local hash = 0
  for index = 1, #storageKey do
    hash = (hash * 31 + storageKey:byte(index)) % 1000000
  end
  return "custom_panel_" .. storageKey:sub(1, 32) .. "_" .. hash
end

function CustomPanel.setDetectedIconEnabled(entry, detected, enabled)
  if not entry or not detected then return end
  if type(storage.customPanelIcons) ~= "table" then
    storage.customPanelIcons = {}
  end
  if type(storage.customPanelIconItems) ~= "table" then
    storage.customPanelIconItems = {}
  end
  local storageKey = detected.storageKey or makeIconStorageKey(entry, detected.name)
  detected.storageKey = storageKey
  storage.customPanelIcons[storageKey] = enabled == true

  if not enabled then
    if detected.icon and getControlMethod(detected.icon, "destroy") then
      pcall(function() detected.icon:destroy() end)
    end
    detected.icon = nil
    return
  end

  if detected.icon or not detected.control or not getControlMethod(detected.control, "setOn") or
     type(addIcon) ~= "function" then
    return
  end


  detected.iconCallback = detected.iconCallback or function(widget, value)
    local control = detected.control
    if not control or not getControlMethod(control, "setOn") then return end

    if detected.kind == "botswitch" then
      local current = nil
      if getControlMethod(control, "isOn") then
        local ok, value = pcall(function() return control:isOn() end)
        if ok then current = value end
      end
      if current == value then return end

      local onClick = getControlMethod(control, "onClick")
      if onClick then
        pcall(function() control.onClick(control) end)
      else
        pcall(function() control:setOn(value) end)
      end
    else
      pcall(function() control.setOn(value) end)
    end
  end
  local iconConfig = {text = detected.name}
  local itemId = tonumber(storage.customPanelIconItems[storageKey]) or 0
  if itemId > 0 then
    iconConfig.item = {id = itemId}
  end
  detected.icon = addIcon(makeIconId(storageKey), iconConfig, detected.iconCallback)
end

function CustomPanel.addMountEntryToSettings(entry, name, detected)
  if not entry then return end

  local settingsPanel = CustomPanel.panels.settings
  if not settingsPanel or not settingsPanel.content then return end

  name = cleanDetectedName(name or entry.displayName)
  if name == "" then return end
  entry.settingsRows = entry.settingsRows or {}
  if entry.settingsRows[name] then return end

  detected = detected or (entry.detectedControls and entry.detectedControls[name])
  if not detected then
    detected = {name = name}
    entry.detectedControls = entry.detectedControls or {}
    entry.detectedControls[name] = detected
  end

  if type(storage.customPanelIcons) ~= "table" then
    storage.customPanelIcons = {}
  end
  if type(storage.customPanelIconItems) ~= "table" then
    storage.customPanelIconItems = {}
  end
  detected.storageKey = detected.storageKey or makeIconStorageKey(entry, name)

  CustomPanel.settingsIconCount = CustomPanel.settingsIconCount or 0
  local listParent
  if CustomPanel.settingsIconCount % 2 == 0 then
    listParent = settingsPanel.content.right
  else
    listParent = settingsPanel.content.left
  end

  local row = setupUI([[
Panel
  height: 28
  margin-top: 2
  margin-left: 4
  margin-right: 4

  BotItem
    id: item
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    size: 24 24
    margin-left: 2

  CheckBox
    id: toggle
    anchors.left: item.right
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    margin-left: 6
    margin-right: 4
]], listParent)
  local checkBox = row.toggle
  local itemSelector = row.item
  checkBox:setText(name)
  if not detected.control or not getControlMethod(detected.control, "setOn") then
    checkBox:setTooltip("Control detectado sin setOn; no se puede enlazar a un icono")
  else
    checkBox:setTooltip("Mostrar u ocultar el icono de " .. name)
  end
  checkBox:setChecked(storage.customPanelIcons[detected.storageKey] == true)
  checkBox.onCheckChange = function(widget, checked)
    CustomPanel.setDetectedIconEnabled(entry, detected, checked)
  end

  itemSelector:setItemId(tonumber(storage.customPanelIconItems[detected.storageKey]) or 0)
  itemSelector:setTooltip("Item del icono: arrastra aqui un objeto; vacio muestra solo texto")
  itemSelector.onItemChange = function(widget)
    local itemId = tonumber(widget:getItemId()) or 0
    storage.customPanelIconItems[detected.storageKey] = itemId
    if detected.icon and getControlMethod(detected.icon, "destroy") then
      pcall(function() detected.icon:destroy() end)
    end
    detected.icon = nil
    if checkBox:isChecked() then
      CustomPanel.setDetectedIconEnabled(entry, detected, true)
    end
  end

  entry.settingsRows[name] = checkBox
  detected.settingsRow = row
  detected.itemSelector = itemSelector
  CustomPanel.settingsIconCount = CustomPanel.settingsIconCount + 1
  CustomPanel.setDetectedIconEnabled(entry, detected, checkBox:isChecked())
end

function CustomPanel.refreshMountList()
  for _, entry in ipairs(CustomPanel.mountEntries) do
    if type(entry.displayName) == "string" and entry.displayName ~= "" then
      CustomPanel.addMountEntryToSettings(entry, entry.displayName,
        entry.detectedControls and entry.detectedControls[entry.displayName])
    end
    for _, name in ipairs(entry.detectedNames or {}) do
      CustomPanel.addMountEntryToSettings(entry, name,
        entry.detectedControls and entry.detectedControls[name])
    end
  end
end

function CustomPanel.getParent(panelName, side)
  panelName = normalizeCustomPanelName(panelName)
  side = normalizeCustomPanelName(side)

  local selectedPanel = CustomPanel.panels[panelName]
  if not selectedPanel or not selectedPanel.content then
    return nil
  end

  if side ~= "left" and side ~= "right" then
    return nil
  end

  return selectedPanel.content[side]
end

function CustomPanel.run(parent, callback, mountEntry)
  if not parent or type(callback) ~= "function" then
    return false
  end

  local previousParent = CustomPanel.currentParent
  local previousMountEntry = CustomPanel.currentMountEntry
  CustomPanel.currentParent = parent
  CustomPanel.currentMountEntry = mountEntry or previousMountEntry
  local result = {pcall(callback)}
  local refreshResult = {pcall(CustomPanel.refreshPendingControls, CustomPanel.currentMountEntry)}
  CustomPanel.currentParent = previousParent
  CustomPanel.currentMountEntry = previousMountEntry

  if not result[1] then
    error(result[2])
  end
  if not refreshResult[1] then
    error(refreshResult[2])
  end
  return true
end


if not CustomPanel.eventContextInstalled then
  CustomPanel.eventContextInstalled = true

  local function wrapEventCallback(callback)
    local parent = CustomPanel.currentParent
    local mountEntry = CustomPanel.currentMountEntry
    if not parent or type(callback) ~= "function" then return callback end
    return function(...)
      local args = {...}
      local result
      CustomPanel.run(parent, function()
        result = {callback(unpack(args))}
      end, mountEntry)
      return unpack(result or {})
    end
  end

  local originalAddEvent = addEvent
  if type(originalAddEvent) == "function" then
    addEvent = function(callback, pushFront)
      return originalAddEvent(wrapEventCallback(callback), pushFront)
    end
  end

  local originalScheduleEvent = scheduleEvent
  if type(originalScheduleEvent) == "function" then
    scheduleEvent = function(callback, delay)
      return originalScheduleEvent(wrapEventCallback(callback), delay)
    end
  end

  local originalCycleEvent = cycleEvent
  if type(originalCycleEvent) == "function" then
    cycleEvent = function(callback, delay)
      return originalCycleEvent(wrapEventCallback(callback), delay)
    end
  end

  if modules.corelib then
    local originalCoreAddEvent = modules.corelib.addEvent
    if type(originalCoreAddEvent) == "function" then
      modules.corelib.addEvent = function(callback, pushFront)
        return originalCoreAddEvent(wrapEventCallback(callback), pushFront)
      end
    end

    local originalCoreScheduleEvent = modules.corelib.scheduleEvent
    if type(originalCoreScheduleEvent) == "function" then
      modules.corelib.scheduleEvent = function(callback, delay)
        return originalCoreScheduleEvent(wrapEventCallback(callback), delay)
      end
    end

    local originalCoreCycleEvent = modules.corelib.cycleEvent
    if type(originalCoreCycleEvent) == "function" then
      modules.corelib.cycleEvent = function(callback, delay)
        return originalCoreCycleEvent(wrapEventCallback(callback), delay)
      end
    end
  end
end

if HTTP and not CustomPanel.httpContextInstalled then
  CustomPanel.httpContextInstalled = true

  local function wrapHttpCallback(parent, callback)
    if not parent or type(callback) ~= "function" then
      return callback
    end

    local mountEntry = CustomPanel.currentMountEntry
    return function(data, err)
      CustomPanel.run(parent, function()
        callback(data, err)
      end, mountEntry)
    end
  end

  local originalHttpGet = HTTP.get
  if type(originalHttpGet) == "function" then
    HTTP.get = function(url, callback)
      local parent = CustomPanel.currentParent
      return originalHttpGet(url, wrapHttpCallback(parent, callback))
    end
  end

  local originalHttpGetJSON = HTTP.getJSON
  if type(originalHttpGetJSON) == "function" then
    HTTP.getJSON = function(url, callback)
      local parent = CustomPanel.currentParent
      return originalHttpGetJSON(url, wrapHttpCallback(parent, callback))
    end
  end

  local originalHttpPost = HTTP.post
  if type(originalHttpPost) == "function" then
    HTTP.post = function(url, data, callback)
      local parent = CustomPanel.currentParent
      return originalHttpPost(url, data, wrapHttpCallback(parent, callback))
    end
  end

  local originalHttpPostJSON = HTTP.postJSON
  if type(originalHttpPostJSON) == "function" then
    HTTP.postJSON = function(url, data, callback)
      local parent = CustomPanel.currentParent
      return originalHttpPostJSON(url, data, wrapHttpCallback(parent, callback))
    end
  end

  local originalHttpDownload = HTTP.download
  if type(originalHttpDownload) == "function" then
    HTTP.download = function(url, file, callback, progressCallback)
      local parent = CustomPanel.currentParent
      return originalHttpDownload(
        url,
        file,
        wrapHttpCallback(parent, callback),
        wrapHttpCallback(parent, progressCallback)
      )
    end
  end

  local originalHttpDownloadImage = HTTP.downloadImage
  if type(originalHttpDownloadImage) == "function" then
    HTTP.downloadImage = function(url, callback)
      local parent = CustomPanel.currentParent
      return originalHttpDownloadImage(url, wrapHttpCallback(parent, callback))
    end
  end
end

function CustomPanel.mount(panelName, side, callback, displayName)
  if type(callback) ~= "function" then
    error("CustomPanel.mount: callback debe ser una funcion")
  end

  panelName = normalizeCustomPanelName(panelName)
  side = normalizeCustomPanelName(side)

  if not CustomPanel.validPanels[panelName] then
    error("CustomPanel.mount: panel debe ser 'main', 'pvp', 'hp', 'other' o 'settings'")
  end

  if side ~= "left" and side ~= "right" then
    error("CustomPanel.mount: side debe ser 'left' o 'right'")
  end

  local entry = CustomPanel.registerMountEntry(panelName, side, callback, displayName)
  if type(displayName) == "string" and displayName ~= "" then
    CustomPanel.addDetectedName(entry, displayName)
  end

  local parent = CustomPanel.getParent(panelName, side)
  if parent then
    CustomPanel.run(parent, function()
      callback(parent)
    end, entry)
    return true
  end

  table.insert(CustomPanel.pending, {
    panel = panelName,
    side = side,
    callback = callback,
    displayName = displayName
  })
  return false
end

function CustomPanel.registerPanel(name, widget)
  CustomPanel.panels[normalizeCustomPanelName(name)] = widget
end

function CustomPanel.flush()
  local waiting = CustomPanel.pending
  CustomPanel.pending = {}

  for _, entry in ipairs(waiting) do
    local parent = CustomPanel.getParent(entry.panel, entry.side)
    if parent then
      CustomPanel.mount(entry.panel, entry.side, entry.callback, entry.displayName)
    else
      table.insert(CustomPanel.pending, entry)
    end
  end
end

local customPanelWindowStorage = storage.customPanelWindow

windowUI = setupUI([[
MainWindow
  id: MainWindow
  size: 498 281
  anchors.centerIn: parent

  TabBar
    id: tabBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    tab-spacing: 1
    margin-left: 1
    margin-right: 1
    height: 20

  ResizeBorder
    id: rightResizeBorder
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 6
    minimum: 420
    maximum: 1000
    background-color: #b778d866
    tooltip: Arrastra para cambiar el ancho

    $hover:
      background-color: #dfbae9cc

  ResizeBorder
    id: bottomResizeBorder
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 6
    minimum: 220
    maximum: 800
    margin-left: 0
    margin-right: 0
    background-color: #b778d866
    tooltip: Arrastra para cambiar la altura

    $hover:
      background-color: #dfbae9cc

  Label
    id: resizeHint
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    width: 14
    height: 14
    margin-right: 1
    margin-bottom: 1
    text: ◢
    text-align: center
    color: #dfbae9
    tooltip: Arrastra los bordes para cambiar el tamano
    phantom: true
    focusable: false
]], g_ui.getRootWidget())

CustomPanel.window = windowUI
CustomPanel.window.onEscape = function()
  CustomPanel.close()
end
CustomPanel.window:setWidth(customPanelWindowStorage.width)
CustomPanel.window:setHeight(customPanelWindowStorage.height)
CustomPanel.window.onGeometryChange = function(widget)
  local width = widget:getWidth()
  local height = widget:getHeight()
  if width > 0 then
    customPanelWindowStorage.width = width
  end
  if height > 0 then
    customPanelWindowStorage.height = height
  end
end
CustomPanel.window:hide()
animations.install(CustomPanel.window)
backgrounds.registerWidget("window", CustomPanel.window)


local sin,floor,pi,format,clock = math.sin,math.floor,math.pi,string.format,os.clock

function setBrightWhiteGlowColor() return "#dfbae9" end

local function rgb(t)
  return format("#%02X%02X%02X",
    floor(127*sin(t)+128),
    floor(127*sin(t+2*pi/3)+128),
    floor(127*sin(t+4*pi/3)+128))
end

local function split(s)
  local r={} s:gsub(".",function(c) r[#r+1]=c end) return r
end

local function build(t,i,b,o)
  if i>#t then return o end
  o[#o+1]=t[i] o[#o+1]=rgb(b+i*0.1)
  return build(t,i+1,b,o)
end

if type(UI)=="function" then
  local _uif=UI
  UI=setmetatable({},{__call=function(_,...) return _uif(...) end})
end
if not UI.Button then
  UI.Button=function(text,cb,parent)
    local w=g_ui.createWidget("UIButton",parent or g_ui.getRootWidget())
    w:setText(text)
    if cb then w.onClick=cb end
    return w
  end
end

local txtMain=split("RushandoPVP Panel")
local txtBtn =split("CustomPanel")

local launcherRow = setupUI([[
Panel
  height: 20

  Button
    id: customButton
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: profile.left
    margin-right: 3
    text: CustomPanel

  ComboBox
    id: profile
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: 82
    text-offset: 3 0
]])

local btn = launcherRow.customButton
btn.onClick = function()
  CustomPanel.open()
end

for profile = 1, 10 do
  launcherRow.profile:addOption("Perfil " .. profile, profile)
end
launcherRow.profile:setCurrentIndex(CustomPanel.getProfile(), true)
launcherRow.profile:setMouseScroll(false)
launcherRow.profile:setTooltip("Cambia todas las configuraciones y scripts del CustomBot")
launcherRow.profile.onOptionChange = function(widget, _, data)
  local profile = tonumber(data)
  if not profile then return end
  if profile == CustomPanel.getProfile() then return end
  if not CustomPanel.setProfile(profile) then
    widget:setCurrentIndex(CustomPanel.getProfile(), true)
  end
end

macro(100,function()
  local activeProfile = CustomPanel.getProfile()
  if launcherRow.profile.currentIndex ~= activeProfile then
    launcherRow.profile:setCurrentIndex(activeProfile, true)
  end

  local t=clock()*4
  if windowUI and windowUI.setColoredText then
    windowUI:setColoredText(build(txtMain,1,t,{}))
  end
  if btn and btn.setColoredText then
    btn:setColoredText(build(txtBtn,1,t,{}))
  end
end)

tabBar=CustomPanel.window.tabBar

container=setupUI([[
BotTabBarPanel
  anchors.top: tabBar.bottom
  anchors.left: parent.left
  anchors.right: parent.right
  anchors.bottom: parent.bottom
]],CustomPanel.window)

tabBar:setContentWidget(container)

panelOTML=[[
Panel
  anchors.fill: parent

  VerticalScrollBar
    id: scrollV
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    step: 28
    pixels-scroll: true
    mouse-scroll: true
    focusable: false
    margin-right: 6
    margin-bottom: 5

  ScrollablePanel
    id: content
    anchors.fill: parent
    vertical-scrollbar: scrollV
    phantom: true
    margin-right: 20
    margin-bottom: 5
    layout:
      type: anchor

    Panel
      id: left
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.horizontalCenter
      margin-right: 5
      layout:
        type: verticalBox
        fit-children: true

    Panel
      id: right
      anchors.top: parent.top
      anchors.left: parent.horizontalCenter
      anchors.right: parent.right
      margin-left: 5
      layout:
        type: verticalBox
        fit-children: true

]]

panelMain  = setupUI(panelOTML, container); panelMain:setParent(nil); panelMain:setImageSource("");
panelPvp   = setupUI(panelOTML, container); panelPvp:setParent(nil);   panelPvp:setImageSource("");
panelHp    = setupUI(panelOTML, container); panelHp:setParent(nil);    panelHp:setImageSource("");
--panelCavebot = setupUI(panelOTML, container); panelCavebot:setParent(nil)
--panelTarget  = setupUI(panelOTML, container); panelTarget:setParent(nil)
panelOther = setupUI(panelOTML, container); panelOther:setParent(nil); panelOther:setImageSource("");
local settingsPanelOTML = [[
Panel
  anchors.fill: parent

  Panel
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 116

  VerticalScrollBar
    id: scrollV
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    step: 28
    pixels-scroll: true
    mouse-scroll: true
    focusable: false
    margin-top: 2
    margin-right: 6
    margin-bottom: 5

  ScrollablePanel
    id: content
    anchors.top: header.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    vertical-scrollbar: scrollV
    phantom: true
    margin-top: 2
    margin-right: 20
    margin-bottom: 5
    layout:
      type: anchor

    Panel
      id: left
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.horizontalCenter
      margin-right: 5
      layout:
        type: verticalBox
        fit-children: true

    Panel
      id: right
      anchors.top: parent.top
      anchors.left: parent.horizontalCenter
      anchors.right: parent.right
      margin-left: 5
      layout:
        type: verticalBox
        fit-children: true

  HorizontalSeparator
    id: settingsHorizontalSeparator
    anchors.top: header.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    margin-right: 20
    phantom: true
    focusable: false

  VerticalSeparator
    id: settingsVerticalSeparator
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    margin-top: 2
    margin-left: -10
    margin-bottom: 5
    phantom: true
    focusable: false
]]

panelSettings = setupUI(settingsPanelOTML, container); panelSettings:setParent(nil); panelSettings:setImageSource("");

local function enablePanelMouseWheel(customPanel)
  local content = customPanel and customPanel.content
  local scroll = customPanel and customPanel.scrollV
  if not content or not scroll then return end

  scroll:setMouseScroll(true)
  content.ensureChildVisible = function()
    return
  end
end

enablePanelMouseWheel(panelMain)
enablePanelMouseWheel(panelPvp)
enablePanelMouseWheel(panelHp)
enablePanelMouseWheel(panelOther)
enablePanelMouseWheel(panelSettings)

tabBar:addTab("Main",    panelMain)
tabBar:addTab("Pvp",     panelPvp)
tabBar:addTab("Hp",      panelHp)
--tabBar:addTab("Cavebot", panelCavebot)
--tabBar:addTab("Target",  panelTarget)
tabBar:addTab("Other",   panelOther)
tabBar:addTab("Settings", panelSettings)

-- Main, Pvp, Hp y Other
local function addColumnSeparator(customPanel, separatorId)
  local separator = setupUI([[
VerticalSeparator
  anchors.top: parent.top
  anchors.bottom: parent.bottom
  anchors.horizontalCenter: parent.horizontalCenter
  margin-top: 2
  margin-left: -10
  margin-bottom: 5
  phantom: true
  focusable: false
]], customPanel)
  separator:setId(separatorId)
  return separator
end

CustomPanel.columnSeparators = {
  main = addColumnSeparator(panelMain, "mainColumnSeparator"),
  pvp = addColumnSeparator(panelPvp, "pvpColumnSeparator"),
  hp = addColumnSeparator(panelHp, "hpColumnSeparator"),
  other = addColumnSeparator(panelOther, "otherColumnSeparator")
}
CustomPanel.columnSeparator = CustomPanel.columnSeparators.main

CustomPanel.settingsSeparators = {
  horizontal = panelSettings.settingsHorizontalSeparator,
  vertical = panelSettings.settingsVerticalSeparator
}

CustomPanel.registerPanel("main", panelMain)
CustomPanel.registerPanel("pvp", panelPvp)
CustomPanel.registerPanel("hp", panelHp)
CustomPanel.registerPanel("other", panelOther)
CustomPanel.registerPanel("settings", panelSettings)

CustomPanel.settingsTop = setupUI([[
Panel
  id: settingsTop
  height: 22
  anchors.top: parent.top
  anchors.left: parent.left
  anchors.right: parent.right
]], panelSettings.header)

function CustomPanel.getSettingsTopParent()
  return CustomPanel.settingsTop
end

function CustomPanel.getSettingsHeaderParent()
  return panelSettings.header
end

local backgroundEditor = setupUI([[
Panel
  height: 64
  anchors.top: settingsTop.bottom
  anchors.left: parent.left
  anchors.right: parent.right

  Label
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    text: fondos de paneles

  Button
    id: botChoose
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.horizontalCenter
    margin-top: 22
    margin-right: 4
    height: 24
    text: fondo del panel principal

  Button
    id: windowChoose
    anchors.top: botChoose.top
    anchors.left: parent.horizontalCenter
    anchors.right: parent.right
    margin-left: 4
    height: 24
    text: fondo de la ventana custom
]], panelSettings.header)
backgroundEditor:setId("backgroundEditor")
backgroundEditor.botChoose:setImageSource("")
backgroundEditor.windowChoose:setImageSource("")
backgroundEditor.botChoose:setTooltip("Cambia la imagen de fondo del panel principal del bot usando un enlace o una imagen guardada.")
backgroundEditor.windowChoose:setTooltip("Cambia la imagen de fondo de la ventana CustomPanel usando un enlace o una imagen guardada.")

local backupButton = setupUI([[
Button
  id: backupChoose
  anchors.top: backgroundEditor.bottom
  anchors.left: parent.left
  anchors.right: parent.right
  height: 24
  text: respaldos de perfiles
]], panelSettings.header)
backupButton:setImageSource("")
backupButton:setTooltip("Guarda o restaura respaldos de tus perfiles en este equipo o en tu cuenta de Koofr.")

local backgroundPicker = setupUI([[
MainWindow
  id: backgroundPicker
  text: elegir fondo
  size: 680 460
  anchors.centerIn: parent

  Button
    id: linkMode
    anchors.top: parent.top
    anchors.left: parent.left
    width: 160
    height: 25
    text: usar enlace

  Button
    id: storedMode
    anchors.top: parent.top
    anchors.left: linkMode.right
    margin-left: 6
    width: 180
    height: 25
    text: imagenes almacenadas

  Panel
    id: linkControls
    anchors.top: linkMode.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 35
    margin-top: 8

    TextEdit
      id: url
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      margin-right: 100
      height: 24

    Button
      id: previewLink
      anchors.top: parent.top
      anchors.right: parent.right
      width: 94
      height: 24
      text: vista previa

  Panel
    id: storedControls
    anchors.top: linkMode.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 35
    margin-top: 8

    Label
      anchors.top: parent.top
      anchors.left: parent.left
      margin-top: 5
      text: haz clic en una miniatura para seleccionarla

    Button
      id: refresh
      anchors.top: parent.top
      anchors.right: parent.right
      width: 94
      height: 24
      text: actualizar

  Button
    id: apply
    anchors.bottom: parent.bottom
    anchors.right: close.left
    margin-right: 6
    width: 110
    height: 25
    text: aplicar fondo

  Button
    id: close
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: 90
    height: 25
    text: cancelar

  Button
    id: reset
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: 130
    height: 25
    text: predeterminado

  Label
    id: status
    anchors.bottom: apply.top
    anchors.left: parent.left
    anchors.right: parent.right
    margin-bottom: 8
    height: 30
    text-wrap: true

  Panel
    id: previewArea
    anchors.top: linkControls.bottom
    anchors.right: parent.right
    anchors.bottom: status.top
    width: 280
    margin-bottom: 8
    background-color: #17191e
    border-width: 1
    border-color: #777777

    UIWidget
      id: image
      anchors.centerIn: parent
      size: 1 1
      image-smooth: true
      phantom: true

  VerticalScrollBar
    id: galleryScroll
    anchors.top: previewArea.top
    anchors.left: previewArea.left
    anchors.bottom: previewArea.bottom
    margin-left: -18
    step: 96
    pixels-scroll: true

  ScrollablePanel
    id: gallery
    anchors.top: previewArea.top
    anchors.left: parent.left
    anchors.right: galleryScroll.left
    anchors.bottom: previewArea.bottom
    margin-right: 4
    vertical-scrollbar: galleryScroll
    layout:
      type: verticalBox
]], g_ui.getRootWidget())
backgrounds.picker = backgroundPicker
CustomPanel.backgroundPicker = backgroundPicker
backgroundPicker:hide()
animations.install(backgroundPicker)

backgrounds.pickerState = {version = 0, visible = false, tiles = {}, downloads = {}}
local pickerState = backgrounds.pickerState

function backgrounds.clearPreview(message)
  pickerState.source = nil
  backgroundPicker.previewArea.image:setImageSource("")
  backgroundPicker.apply:setEnabled(false)
  backgroundPicker.status:setText(message or "selecciona como quieres cargar el fondo")
end

function backgrounds.showPreview(path, source)
  local ok, data = pcall(function() return g_resources.readFileContents(path) end)
  local width, height
  if ok then width, height = backgrounds.getDimensions(data) end
  if not width then backgrounds.clearPreview("no se pudo leer la imagen png"); return false end
  local image = backgroundPicker.previewArea.image
  local scale = math.min(260 / width, 260 / height, 1)
  local loaded = pcall(function()
    image:setWidth(math.max(1, math.floor(width * scale)))
    image:setHeight(math.max(1, math.floor(height * scale)))
    image:setImageSource(path)
  end)
  if not loaded then backgrounds.clearPreview("no se pudo mostrar la imagen"); return false end
  pickerState.source = source
  backgroundPicker.apply:setEnabled(true)
  backgroundPicker.status:setText(width .. " x " .. height .. " px vista previa pulsa aplicar fondo para confirmar")
  return true
end

function backgrounds.selectImage(path)
  if pickerState.mode ~= "stored" or not backgrounds.localPath(path, pickerState.target) then return end
  pickerState.version = pickerState.version + 1
  for _, tile in ipairs(pickerState.tiles) do tile:setOn(tile.backgroundPath == path) end
  backgrounds.showPreview(path, path)
end

function backgrounds.refreshImages()
  if not pickerState.visible or pickerState.mode ~= "stored" then return end
  local selected = pickerState.source
  backgroundPicker.gallery:destroyChildren()
  pickerState.tiles = {}
  local images = backgrounds.listImages(pickerState.target)
  local row, count = nil, 0
  for _, name in ipairs(images) do
    local path = backgrounds.resourcesPath .. name
    local ok, data = pcall(function() return g_resources.readFileContents(path) end)
    local width, height
    if ok then width, height = backgrounds.getDimensions(data) end
    if width then
      local column = count % 3
      if column == 0 then
        row = setupUI([[Panel
  height: 96
]], backgroundPicker.gallery)
      end
      local tile = setupUI([[Button
  width: 100
  height: 90
  anchors.top: parent.top
  anchors.left: parent.left
  margin-left: ]] .. (column * 104) .. "\n" .. [[
  border-width: 1
  border-color: #555555

  $on:
    border-width: 2
    border-color: #dfbae9

  UIWidget
    id: thumbnail
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    margin-top: 5
    image-smooth: true
    phantom: true

  Label
    id: resolution
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    margin-bottom: 3
    phantom: true
]], row)
      local scale = math.min(90 / width, 64 / height)
      tile.thumbnail:setWidth(math.max(1, math.floor(width * scale)))
      tile.thumbnail:setHeight(math.max(1, math.floor(height * scale)))
      tile.thumbnail:setImageSource(path)
      tile.resolution:setText(width .. " x " .. height)
      tile:setTooltip(name:lower():gsub("%.[Pp][Nn][Gg]$", ""):gsub("[.,]", " "))
      tile.backgroundPath = path
      tile:setOn(path == selected)
      tile.onClick = function() backgrounds.selectImage(path) end
      table.insert(pickerState.tiles, tile)
      count = count + 1
    end
  end
  if count == 0 then backgrounds.clearPreview("no hay imagenes png validas para este fondo") end
  if selected and not backgrounds.fileExists(selected) then backgrounds.clearPreview("la imagen seleccionada ya no existe") end
end

function backgrounds.previewLink()
  if not pickerState.visible or pickerState.mode ~= "link" then return end
  pickerState.version = pickerState.version + 1
  local version = pickerState.version
  local url = backgroundPicker.linkControls.url:getText():match("^%s*(.-)%s*$")
  backgrounds.clearPreview("introduce un enlace http/https directo a un png")
  if not url:match("^https?://%S+$") then return end
  local path = backgrounds.resourcePath(pickerState.target, url)
  if backgrounds.fileExists(path) then backgrounds.showPreview(path, url); return end
  backgroundPicker.status:setText("cargando vista previa")
  local function showResult(valid)
    if not pickerState.visible or pickerState.mode ~= "link" or pickerState.version ~= version then return end
    if valid then backgrounds.showPreview(path, url)
    else backgrounds.clearPreview("el enlace no devolvio un png valido o no se pudo guardar") end
  end
  if pickerState.downloads[path] then
    table.insert(pickerState.downloads[path], showResult)
    return
  end
  pickerState.downloads[path] = {showResult}
  local function download()
    local currentUrl = backgroundPicker.linkControls.url:getText():match("^%s*(.-)%s*$")
    if not pickerState.visible or pickerState.mode ~= "link" or currentUrl ~= url then
      local callbacks = pickerState.downloads[path] or {}
      pickerState.downloads[path] = nil
      for _, callback in ipairs(callbacks) do callback(false) end
      return
    end
    HTTP.get(url, function(data, err)
      local valid = false
      if not err and backgrounds.getDimensions(data) then
        local ok = pcall(function()
          if not g_resources.directoryExists(backgrounds.resourcesPath) then g_resources.makeDir(backgrounds.resourcesPath) end
          g_resources.writeFileContents(path, data)
        end)
        valid = ok and backgrounds.fileExists(path)
      end
      local callbacks = pickerState.downloads[path] or {}
      pickerState.downloads[path] = nil
      for _, callback in ipairs(callbacks) do callback(valid) end
    end)
  end
  local schedule = modules.corelib and modules.corelib.scheduleEvent
  if type(schedule) == "function" then schedule(download, 400) else download() end
end

function backgrounds.setMode(mode)
  pickerState.version = pickerState.version + 1
  pickerState.mode = mode
  local link, stored = mode == "link", mode == "stored"
  backgroundPicker.linkControls:setVisible(link)
  backgroundPicker.storedControls:setVisible(stored)
  backgroundPicker.gallery:setVisible(stored)
  backgroundPicker.galleryScroll:setVisible(stored)
  backgroundPicker.linkMode:setOn(link)
  backgroundPicker.storedMode:setOn(stored)
  backgrounds.clearPreview()
  if stored then
    backgrounds.refreshImages()
    local source = backgrounds.getSource(pickerState.target)
    local path = source:match("^https?://") and backgrounds.resourcePath(pickerState.target, source) or backgrounds.localPath(source, pickerState.target)
    if path and backgrounds.fileExists(path) then backgrounds.selectImage(path) end
  elseif link then
    backgrounds.previewLink()
  end
end

function backgrounds.openPicker(target)
  if not backgrounds.defaults[target] then return end
  pickerState.mode = nil
  pickerState.version = pickerState.version + 1
  pickerState.target = target
  pickerState.visible = true
  backgroundPicker:setText(target == "bot" and "fondo del panel principal" or "fondo de la ventana custom (tamano automatico)")
  local source = backgrounds.getSource(target)
  backgroundPicker.linkControls.url:setText(source:match("^https?://") and source or "")
  backgrounds.setMode(nil)
  backgroundPicker:show()
  backgroundPicker:raise()
  backgroundPicker:focus()
end

function backgrounds.closePicker()
  pickerState.visible = false
  pickerState.version = pickerState.version + 1
  pickerState.source = nil
  backgroundPicker:hide()
end

backgroundPicker.onEscape = backgrounds.closePicker
backgroundPicker.close.onClick = backgrounds.closePicker
backgroundPicker.linkMode.onClick = function() backgrounds.setMode("link") end
backgroundPicker.storedMode.onClick = function() backgrounds.setMode("stored") end
backgroundPicker.storedControls.refresh.onClick = backgrounds.refreshImages
backgroundPicker.linkControls.url.onTextChange = backgrounds.previewLink
backgroundPicker.linkControls.url:setTooltip("enlace http/https directo a un png la vista previa se actualiza al escribir")
backgroundPicker.linkControls.previewLink.onClick = backgrounds.previewLink
function backgrounds.applySelection()
  if not pickerState.source or not pickerState.mode then return end
  local isUrl = pickerState.source:match("^https?://") ~= nil
  if (pickerState.mode == "link") ~= isUrl then return end
  if backgrounds.setSource(pickerState.target, pickerState.source) then backgrounds.closePicker() end
end
function backgrounds.previewDefault()
  backgrounds.setMode("link")
  backgroundPicker.linkControls.url:setText(backgrounds.defaults[pickerState.target])
  backgrounds.previewLink()
end
backgroundPicker.apply.onClick = backgrounds.applySelection
backgroundPicker.reset.onClick = backgrounds.previewDefault
backgroundEditor.botChoose.onClick = function() backgrounds.openPicker("bot") end
backgroundEditor.windowChoose.onClick = function() backgrounds.openPicker("window") end

UI.Label("ITEM   MACRO / SWITCH", panelSettings.content.left)
UI.Label("ITEM   MACRO / SWITCH", panelSettings.content.right)
CustomPanel.settingsIconCount = 0
CustomPanel.refreshMountList()
CustomPanel.flush()

-- Acceso en el encabezado de Settings; controles en una ventana independiente.
do
  local backupWindow = setupUI([[
MainWindow
  id: customPanelBackupsWindow
  text: respaldos de perfiles
  size: 540 520
  anchors.centerIn: parent

  Button
    id: close
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    width: 80
    height: 24
    text: cerrar
]], g_ui.getRootWidget())
  backupWindow:hide()
  animations.install(backupWindow)
  backups.window = backupWindow

  function backups.close()
    backupWindow:hide()
  end

  function backups.open()
    if not backups.busy then
      local ok, message = pcall(backups.refreshFiles)
      if not ok then backups.showStatus(message) end
    end
    backupWindow:show()
    backupWindow:focus()
    backupWindow:raise()
  end

  backupWindow.onEscape = backups.close
  backupWindow.close.onClick = backups.close
  backupButton.onClick = backups.open

  local backupEditor = setupUI([[

Panel
  id: customPanelBackups
  anchors.top: parent.top
  anchors.left: parent.left
  anchors.right: parent.right
  anchors.bottom: close.top
  margin-bottom: 8

  Panel
    background-color: #292a30
    id: headerFrame
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 78
    border-width: 1
    border-color: #44464f
    phantom: true

  Panel
    id: headerAccent
    anchors.top: headerFrame.top
    anchors.bottom: headerFrame.bottom
    anchors.left: headerFrame.left
    width: 4
    background-color: #45a9d6
    phantom: true

  Panel
    background-color: #24252a
    id: navigation
    anchors.top: headerFrame.bottom
    anchors.left: parent.left
    anchors.bottom: statusTitle.top
    margin-top: 8
    margin-bottom: 6
    width: 94
    border-width: 1
    border-color: #3f4149
    phantom: true

  Label
    id: intro
    margin-top: 6
    margin-left: 10
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 18
    text: copias de seguridad de tus perfiles
    color: #75cfff

  Label
    color: #a5a8b0
    id: profileLabel
    margin-left: 10
    anchors.top: intro.bottom
    anchors.left: parent.left
    margin-top: 4
    height: 18
    text: perfil

  ComboBox
    id: slot
    margin-left: 10
    anchors.top: profileLabel.bottom
    anchors.left: parent.left
    width: 120
    height: 24

  Label
    color: #a5a8b0
    id: nameLabel
    anchors.top: profileLabel.top
    anchors.left: slot.right
    margin-left: 10
    height: 18
    text: nombre del respaldo

  TextEdit
    id: filename
    margin-right: 10
    anchors.top: slot.top
    anchors.left: nameLabel.left
    anchors.right: parent.right
    height: 24
    placeholder: ejemplo: entomatadas

  Button
    id: localTab
    margin-left: 6
    anchors.top: navigation.top
    anchors.left: navigation.left
    margin-top: 8
    width: 82
    height: 28
    text: equipo

    $on:
      color: #75cfff

  Button
    id: cloudTab
    margin-top: 6
    anchors.top: localTab.bottom
    anchors.left: navigation.left
    margin-left: 6
    width: 82
    height: 28
    text: koofr

    $on:
      color: #75cfff

  Button
    id: accountTab
    margin-top: 6
    margin-right: 6
    anchors.top: cloudTab.bottom
    anchors.left: navigation.left
    anchors.right: navigation.right
    margin-left: 6
    height: 28
    text: cuenta

    $on:
      color: #75cfff

  Label
    id: statusTitle
    margin-left: 8
    anchors.bottom: status.top
    anchors.left: parent.left
    height: 18
    text: actividad
    color: #8f929b

  Label
    background-color: #25262b
    id: status
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 70
    padding: 8
    text-wrap: true
    text-align: topLeft
    border-width: 1
    border-color: #44464f

  Panel
    background-color: #303137
    border-width: 1
    border-color: #484a53
    padding: 8
    id: localPage
    margin-left: 8
    anchors.top: navigation.top
    anchors.left: navigation.right
    anchors.right: parent.right
    anchors.bottom: statusTitle.top
    margin-top: 0
    margin-bottom: 6

    Label
      id: saveTitle
      anchors.top: parent.top
      anchors.left: parent.left
      margin-top: 0
      margin-left: 8
      height: 18
      text: guardar copia
      color: #75cfff

    Label
      color: #a5a8b0
      id: saveHint
      margin-right: 8
      margin-left: 8
      anchors.top: saveTitle.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 30
      text-wrap: true
      text: elige un perfil y un nombre para guardar su copia

    Button
      id: exportBtn
      margin-left: 8
      anchors.top: saveHint.bottom
      anchors.left: parent.left
      width: 195
      height: 24
      text: guardar copia local



    Panel
      id: localDivider
      anchors.top: exportBtn.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      margin-top: 8
      height: 1
      background-color: #4b4d55
      phantom: true

    Label
      id: restoreTitle
      anchors.top: localDivider.bottom
      anchors.left: parent.left
      margin-top: 4
      margin-left: 8
      height: 18
      text: restaurar copia
      color: #d7d9df

    ComboBox
      id: files
      margin-left: 8
      anchors.top: restoreTitle.bottom
      anchors.left: parent.left
      anchors.right: list.left
      margin-right: 8
      height: 24

    Button
      id: list
      margin-right: 8
      anchors.top: restoreTitle.bottom
      anchors.right: parent.right
      width: 94
      height: 24
      text: actualizar



    Button
      id: importBtn
      margin-left: 8
      anchors.top: files.bottom
      anchors.left: parent.left
      margin-top: 8
      width: 195
      height: 24
      text: restaurar perfil



    Label
      id: restoreHint
      margin-top: 4
      anchors.top: importBtn.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      margin-left: 8
      height: 26
      text-wrap: true
      color: #a5a8b0
      text: restaurar reemplaza los datos del perfil

  Panel
    background-color: #303137
    border-width: 1
    border-color: #484a53
    padding: 8
    id: cloudPage
    margin-left: 8
    anchors.top: navigation.top
    anchors.left: navigation.right
    anchors.right: parent.right
    anchors.bottom: statusTitle.top
    margin-top: 0
    margin-bottom: 6

    Label
      id: folderLabel
      anchors.top: parent.top
      anchors.left: parent.left
      height: 18
      text: carpeta en koofr
      color: #75cfff

    TextEdit
      id: koofrFolder
      anchors.top: folderLabel.bottom
      anchors.left: parent.left
      anchors.right: listKoofr.left
      margin-right: 8
      height: 24
      text: /

    Button
      id: listKoofr
      anchors.top: folderLabel.bottom
      anchors.right: parent.right
      width: 90
      height: 24
      text: ver archivos



    Button
      id: parentFolder
      anchors.top: koofrFolder.bottom
      anchors.left: parent.left
      margin-top: 8
      width: 112
      height: 24
      text: carpeta superior



    Button
      id: uploadKoofr
      anchors.top: parentFolder.top
      anchors.right: parent.right
      width: 182
      height: 24
      text: guardar en koofr



    Panel
      id: cloudDivider
      anchors.top: parentFolder.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      margin-top: 8
      height: 1
      background-color: #4b4d55
      phantom: true

    Label
      id: remoteTitle
      anchors.top: cloudDivider.bottom
      anchors.left: parent.left
      margin-top: 4
      height: 18
      text: carpetas y respaldos
      color: #d7d9df

    ComboBox
      id: remoteFiles
      anchors.top: remoteTitle.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 24

    Button
      id: downloadKoofr
      anchors.top: remoteFiles.bottom
      anchors.left: parent.left
      margin-top: 8
      width: 204
      height: 24
      text: selecciona un archivo



    Button
      id: cancelKoofr
      anchors.top: downloadKoofr.top
      anchors.right: parent.right
      width: 112
      height: 24
      text: cancelar



    Label
      id: cloudHint
      anchors.top: downloadKoofr.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      margin-top: 6
      height: 40
      text-wrap: true
      color: #a5a8b0
      text: guardar crea una copia. restaurar descarga el zip y reemplaza los datos del perfil.

  Panel
    background-color: #303137
    border-width: 1
    border-color: #484a53
    padding: 8
    id: accountPage
    margin-left: 8
    anchors.top: navigation.top
    anchors.left: navigation.right
    anchors.right: parent.right
    anchors.bottom: statusTitle.top
    margin-top: 0
    margin-bottom: 6

    Label
      id: accountTitle
      anchors.top: parent.top
      anchors.left: parent.left
      height: 18
      text: conectar o cambiar cuenta
      color: #75cfff

    Label
      color: #a5a8b0
      id: accountHint
      anchors.top: accountTitle.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 36
      text-wrap: true
      text: si ya conectaste esta cuenta abre koofr para ver tus archivos

    Label
      color: #a5a8b0
      id: emailLabel
      anchors.top: accountHint.bottom
      anchors.left: parent.left
      height: 18
      text: correo de koofr

    TextEdit
      id: koofrEmail
      anchors.top: emailLabel.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 24
      placeholder: nombre@correo.com

    Label
      color: #a5a8b0
      id: passwordLabel
      anchors.top: koofrEmail.bottom
      anchors.left: parent.left
      margin-top: 6
      height: 18
      text: contrasena de aplicacion webdav

    TextEdit
      id: koofrPassword
      anchors.top: passwordLabel.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 24
      placeholder: contrasena de aplicacion webdav

    Button
      id: koofr
      anchors.top: koofrPassword.bottom
      anchors.left: parent.left
      margin-top: 8
      width: 220
      height: 24
      text: conectar cuenta



    Label
      id: privacyHint
      anchors.top: koofr.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      margin-top: 6
      height: 36
      text-wrap: true
      color: #a5a8b0
      text: la cuenta se guarda cifrada y no se incluye en tus respaldos
]], backupWindow)
  -- Acceso directo a los controles agrupados por seccion.
  for _, page in ipairs({backupEditor.localPage, backupEditor.cloudPage, backupEditor.accountPage}) do
    for _, widget in ipairs(page:getChildren()) do
      local id = widget:getId()
      if id and id ~= "" then backupEditor[id] = widget end
    end
  end
  backups.editor = backupEditor
  local directory = "/CustomBot_Respaldos"
  local confirmation
  local cloudConfirmation
  local updateRemoteAction

  local function resetConfirmation()
    confirmation = nil
    cloudConfirmation = nil
    backupEditor.importBtn:setText("restaurar perfil")
    backupEditor.uploadKoofr:setText("guardar en koofr")
    if updateRemoteAction then updateRemoteAction() end
  end

  local function setSection(section)
    if backups.busy then return end
    resetConfirmation()
    backupEditor.localPage:setVisible(section == "local")
    backupEditor.cloudPage:setVisible(section == "cloud")
    backupEditor.accountPage:setVisible(section == "account")
    backupEditor.localTab:setOn(section == "local")
    backupEditor.cloudTab:setOn(section == "cloud")
    backupEditor.accountTab:setOn(section == "account")
  end
  backupEditor.localTab.onClick = function() setSection("local") end
  backupEditor.cloudTab.onClick = function() setSection("cloud") end
  backupEditor.accountTab.onClick = function() setSection("account") end
  backupEditor.slot.onOptionChange = resetConfirmation
  backupEditor.filename.onTextChange = resetConfirmation
  backupEditor.koofrFolder.onTextChange = resetConfirmation
  backupEditor.files.onOptionChange = resetConfirmation
  backupEditor.filename:setTooltip("nombre para crear una copia local o en koofr. no se usa al restaurar.")
  backupEditor.slot:setTooltip("guardar copia este perfil. restaurar reemplaza los datos de este perfil.")
  backupEditor.koofrPassword:setTooltip("usa una contrasena de aplicacion webdav creada en tu cuenta de koofr.")

  function backups.showStatus(message)
    local text = tostring(message)
    local replacements = {}
    local codes = {161, 169, 173, 179, 186, 129, 137, 141, 147, 154, 177, 145, 188, 156}
    local letters = {'a', 'e', 'i', 'o', 'u', 'a', 'e', 'i', 'o', 'u', 'n', 'n', 'u', 'u'}
    for i, code in ipairs(codes) do replacements[string.char(195, code)] = letters[i] end
    for original, replacement in pairs(replacements) do text = text:gsub(original, replacement) end
    backupEditor.status:setText(text:lower():gsub(",", ""))
  end

  function backups.location()
    local ok, path = pcall(function() return g_resources.getWriteDir() end)
    return (ok and path or "") .. directory
  end

  function backups.refreshFiles()
    local selected = backupEditor.files:getCurrentOption()
    local previous = selected and selected.text
    backupEditor.files:clearOptions()
    if not g_resources.directoryExists(directory) then g_resources.makeDir(directory) end
    local files = {}
    for _, file in ipairs(g_resources.listDirectoryFiles(directory, false, false)) do
      if file:lower():match("%.zip$") and not file:find("[/\\]") then
        files[#files + 1] = file
      end
    end
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    for _, file in ipairs(files) do backupEditor.files:addOption(file, file) end
    if previous then
      for _, file in ipairs(files) do
        if file == previous then backupEditor.files:setCurrentOption(file) break end
      end
    end
    backupEditor.importBtn:setEnabled(#files > 0)
    backupEditor.restoreTitle:setText("restaurar copia (" .. #files .. ")")
    backupEditor.files:setTooltip(#files == 0 and "no hay zip locales. guarda una copia o coloca un respaldo en custombot_respaldos." or backups.location())
  end

  local function bindButton(widget, callback)
    widget.onClick = function()
      if backups.busy then
        backups.showStatus("operacion de respaldos en curso. espera a que termine.")
        return
      end
      local ok, message = pcall(callback)
      if not ok then backups.showStatus(message) end
    end
  end

  for profile = 1, 10 do backupEditor.slot:addOption("perfil " .. profile, profile) end
  backupEditor.slot:setCurrentIndex(CustomPanel.getProfile(), true)

  bindButton(backupEditor.exportBtn, function()
    local profile = backupEditor.slot.currentIndex
    local file = backups.filename(backupEditor.filename:getText())
    backups.refreshFiles()
    local path = directory .. "/" .. file
    assert(not g_resources.fileExists(path), "ya existe un respaldo con ese nombre. escribe otro nombre.")
    backups.showStatus("preparando exportacion. no cierres ni recargues el bot...")
    backups.exportProfile(profile, path, function(ok, result)
      if not ok then backups.showStatus("no se completo la exportacion: " .. result) return end
      backups.refreshFiles()
      backupEditor.files:setCurrentOption(file)
      backups.showStatus("exportado: " .. file .. "\n" .. backups.location())
    end)
  end)

  local koofr
  local remoteEntries = {}

  updateRemoteAction = function()
    cloudConfirmation = nil
    local selected = remoteEntries[backupEditor.remoteFiles.currentIndex]
    backupEditor.downloadKoofr:setEnabled(selected ~= nil)
    backupEditor.downloadKoofr:setText(not selected and "selecciona un archivo" or
      (selected.folder and "abrir carpeta" or "descargar y restaurar"))
  end
  backupEditor.remoteFiles.onOptionChange = updateRemoteAction

  local function getKoofr()
    if not koofr then
      dofile("/koofr_lib.lua")
      koofr = assert(CustomPanelKoofr, "no se pudo cargar koofr")
    end
    return koofr
  end

  local function nativeTask(task)
    local service = getKoofr()
    backups.busy = true
    backups.showStatus("conectando con koofr...")
    local ok, message = pcall(service.run, task, function(success, result)
      if not success or result ~= "installing" then backups.busy = false end
      if not success then backups.showStatus(result) end
    end, function(sent, total, received, expected)
      if total > 0 and sent < total then
        backups.showStatus("subiendo a koofr: " .. math.floor(sent * 100 / total) .. "%")
      elseif received > 0 then
        local amount = expected and expected > 0 and
          (math.floor(received * 100 / expected) .. "%") or
          (math.floor(received / 1024) .. " kib")
        backups.showStatus("recibiendo de koofr: " .. amount)
      else
        backups.showStatus("esperando respuesta de koofr...")
      end
    end)
    if not ok then backups.busy = false; backups.showStatus(message) end
  end

  backupEditor.cancelKoofr.onClick = function()
    if koofr then koofr.cancel() end
  end

  -- El campo se vacia al conectar y nunca se incorpora al storage.
  backupEditor.koofrPassword:setTextHidden(true)
  local listedFolder
  local function refreshRemote(service, folder, finish)
    service.list(folder, function(entries)
      remoteEntries = entries
      listedFolder = service.path(folder)
      backupEditor.koofrFolder:setText(listedFolder)
      backupEditor.remoteFiles:clearOptions()
      for index, item in ipairs(entries) do
        backupEditor.remoteFiles:addOption((item.folder and "[carpeta] " or "") .. item.name, index)
      end
      updateRemoteAction()
      backups.showStatus(#entries == 0 and ("esta carpeta esta vacia. puedes guardar aqui el perfil elegido.") or
        (#entries .. " elementos en " .. listedFolder .. ". selecciona una carpeta para abrirla o un zip para restaurar."))
      finish(true)
    end)
  end

  bindButton(backupEditor.koofr, function()
    local service = getKoofr()
    local email = backupEditor.koofrEmail:getText()
    local password = backupEditor.koofrPassword:getText()
    backupEditor.koofrPassword:setText("")
    nativeTask(function(finish)
      service.connect(email, password, function(result)
        password = nil
        remoteEntries = {}
        backupEditor.remoteFiles:clearOptions()
        updateRemoteAction()
        listedFolder = nil
        finish(true)
        setSection("cloud")
        backups.showStatus(result .. " elige una carpeta y pulsa ver contenido.")
      end)
    end)
  end)

  bindButton(backupEditor.listKoofr, function()
    local service = getKoofr()
    local folder = service.path(backupEditor.koofrFolder:getText())
    nativeTask(function(finish) refreshRemote(service, folder, finish) end)
  end)

  bindButton(backupEditor.parentFolder, function()
    local service = getKoofr()
    local folder = service.path(backupEditor.koofrFolder:getText())
    local parent = folder:match("^(.*)/[^/]+$") or "/"
    if parent == "" then parent = "/" end
    nativeTask(function(finish) refreshRemote(service, parent, finish) end)
  end)

  bindButton(backupEditor.uploadKoofr, function()
    local service = getKoofr()
    local profile = backupEditor.slot.currentIndex
    local file = backups.filename(backupEditor.filename:getText())
    local folder = service.path(backupEditor.koofrFolder:getText())
    local key = "upload:" .. profile .. ":" .. folder .. ":" .. file
    if cloudConfirmation ~= key then
      cloudConfirmation = key
      backupEditor.uploadKoofr:setText("confirmar guardado en koofr")
      backups.showStatus("guardar " .. file .. " desde el perfil " .. profile ..
        " en " .. folder .. ". si ya existe se actualizara. pulsa otra vez para confirmar.")
      return
    end
    resetConfirmation()
    backups.createProfileArchive(profile, function(ok, result)
      if not ok then backups.showStatus(result) return end
      nativeTask(function(finish)
        service.upload(folder, file, result, function()
          backups.showStatus("guardado en tu koofr: " .. file)
          finish(true)
        end)
      end)
    end)
  end)

  bindButton(backupEditor.downloadKoofr, function()
    local service = getKoofr()
    local selected = remoteEntries[backupEditor.remoteFiles.currentIndex]
    assert(selected, "pulsa listar carpeta de koofr y selecciona una.")
    assert(listedFolder == service.path(backupEditor.koofrFolder:getText()), "la ruta cambio. vuelve a listar la carpeta.")
    if selected.folder then
      nativeTask(function(finish) refreshRemote(service, selected.id, finish) end)
      return
    end
    local profile = backupEditor.slot.currentIndex
    local file = backups.filename(selected.name)
    local path = directory .. "/" .. file
    local key = "download:" .. profile .. ":" .. selected.id
    if cloudConfirmation ~= key then
      cloudConfirmation = key
      backupEditor.downloadKoofr:setText("confirmar perfil " .. profile)
      local warning = g_resources.fileExists(path) and
        " se reemplazara el zip local con el mismo nombre." or ""
      backups.showStatus("importar " .. file .. " al perfil " .. profile ..
        ". se sobrescribiran archivos compartidos y el storage de ese perfil." .. warning .. " pulsa otra vez.")
      return
    end
    cloudConfirmation = nil
    updateRemoteAction()
    nativeTask(function(finish)
      service.download(selected.id, function(data)
        assert(#data <= backups.maxArchiveBytes, "zip demasiado grande")
        backups.refreshFiles()
        assert(g_resources.writeFileContents(path, data) ~= false and
               g_resources.readFileContents(path) == data, "no se pudo guardar la descarga")
        backups.refreshFiles()
        backupEditor.files:setCurrentOption(file)
        -- startJob gestiona busy durante la validacion e instalacion.
        backups.busy = false
        backups.install(path, profile, function(ok, result)
          if not ok then backups.showStatus(result) return end
          backups.showStatus("importado desde koofr al perfil " .. profile)
          schedule(100, function()
            if not CustomPanel.setProfile(profile, {skipSave = true, forceReload = true}) then
              backups.showStatus("importado. revisa customprofiles para cargar el perfil.")
            end
          end)
        end)
        finish(true, "installing")
      end)
    end)
  end)

  bindButton(backupEditor.list, function()
    backups.refreshFiles()
    backups.showStatus("coloca aqui el .zip descargado: " .. backups.location())
  end)

  bindButton(backupEditor.importBtn, function()
    local profile = backupEditor.slot.currentIndex
    local selected = backupEditor.files:getCurrentOption()
    assert(selected and selected.text and selected.text ~= "", "selecciona un archivo.")
    local file = selected.text
    assert(file:lower():match("%.zip$") and
           not file:find("[/\\]"), "nombre invalido")
    local key = profile .. ":" .. file
    if confirmation ~= key then
      confirmation = key
      backupEditor.importBtn:setText("confirmar perfil " .. profile)
      local warning = " en " .. configName ..
        ". se sobrescribiran los archivos compartidos y el storage de ese perfil; los otros storages se conservan."
      backups.showStatus("importar " .. file .. " al perfil " .. profile .. warning .. " pulsa otra vez para confirmar.")
      return
    end
    resetConfirmation()
    backups.showStatus("preparando importacion. no cierres ni recargues el bot...")
    backups.install(directory .. "/" .. file, profile, function(ok, result)
      if not ok then
        backups.showStatus("no se completo la importacion: " .. result)
        return
      end
      backups.showStatus("importado en " .. result .. " perfil " .. profile)
      schedule(100, function()
        if not CustomPanel.setProfile(profile, {skipSave = true, forceReload = true}) then
          backups.showStatus("el storage se importo en el perfil " .. profile ..
            " pero no se pudo cargar. revisa el mensaje customprofiles en la consola antes de continuar.")
        end
      end)
    end)
  end)

  setSection("local")
  backupEditor.importBtn:setEnabled(false)
  updateRemoteAction()
  backups.showStatus("elige un perfil arriba. guarda una copia local o abre koofr para usar tus respaldos en la nube. la conexion se configura en cuenta.")
end

--[[UI.createWidget("Label", panelMain.content.left):setText("Script Here")
UI.createWidget("Label", panelMain.content.right):setText("Script Here")
UI.createWidget("Label", panelPvp.content.left):setText("Script Here")
UI.createWidget("Label", panelPvp.content.right):setText("Script Here")
UI.createWidget("Label", panelCavebot.content.left):setText("Script Here")
UI.createWidget("Label", panelCavebot.content.right):setText("Script Here")
UI.createWidget("Label", panelTarget.content.left):setText("Script Here")
UI.createWidget("Label", panelTarget.content.right):setText("Script Here")
UI.createWidget("Label", panelOther.content.left):setText("Script Here")
UI.createWidget("Label", panelOther.content.right):setText("Script Here")
]]

--[[UI.Button("CustomPanel", function()
  windowUI:show()
  windowUI:focus()
  windowUI:raise()
end)
]]
