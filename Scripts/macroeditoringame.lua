local managerLoaded, managerError = pcall(function()
  local validPanels = {main = true, pvp = true, hp = true, other = true}
  local validSides = {left = true, right = true}

  if type(storage.customPanelScripts) ~= "table" then storage.customPanelScripts = {} end
  if type(storage.customPanelScriptsNextId) ~= "number" then storage.customPanelScriptsNextId = 1 end
  if type(storage.customPanelScriptManager) ~= "table" then
    storage.customPanelScriptManager = {open = false, selectedId = nil}
  end
  local managerState = storage.customPanelScriptManager
  managerState.open = managerState.open == true
  managerState.selectedId = tonumber(managerState.selectedId)
  local activeProfile = CustomPanel.getProfile and CustomPanel.getProfile() or
                        (CustomProfiles and CustomProfiles.getProfile()) or 1

  local function nextScriptId()
    local id = storage.customPanelScriptsNextId
    storage.customPanelScriptsNextId = id + 1
    return id
  end

  local function addStoredScript(name, code, panelName, side, enabled)
    local entry = {
      id = nextScriptId(), name = tostring(name or "Nuevo Script"), code = tostring(code or ""),
      panel = validPanels[panelName] and panelName or "main",
      side = validSides[side] and side or "left", enabled = enabled == true,
      status = enabled == true and "Pendiente" or "Off", error = ""
    }
    table.insert(storage.customPanelScripts, entry)
    return entry
  end

  if storage.customPanelScriptsMigrated ~= true then
    storage.customPanelScriptsMigrated = true
    if type(storage.ingame_macros) == "string" and storage.ingame_macros:len() > 3 then
      addStoredScript("Macros anteriores", storage.ingame_macros, "other", "left", true)
    end
    if type(storage.ingame_hotkeys) == "string" and storage.ingame_hotkeys:len() > 3 then
      addStoredScript("Hotkeys anteriores", storage.ingame_hotkeys, "other", "right", true)
    end
  end

  local managerWindow, listPanel, selectedEntry
  local managerHideEvent
  local managerFadeDuration = tonumber(CustomPanel.fadeDuration) or 220

  local function cancelManagerHideEvent()
    if managerHideEvent and type(managerHideEvent.cancel) == "function" then
      managerHideEvent:cancel()
    end
    managerHideEvent = nil
  end

  local function openManager()
    managerState.open = true
    if not managerWindow then return end

    cancelManagerHideEvent()
    managerWindow:setOpacity(1)
    managerWindow:show()
    managerWindow:focus()
    managerWindow:raise()

    local effects = g_effects or (modules.corelib and modules.corelib.g_effects)
    if effects and effects.cancelFade and effects.fadeIn then
      effects.cancelFade(managerWindow)
      effects.fadeIn(managerWindow, managerFadeDuration)
    end
  end

  local function closeManager()
    managerState.open = false
    if not managerWindow or not managerWindow:isVisible() then return end

    cancelManagerHideEvent()
    local window = managerWindow
    local effects = g_effects or (modules.corelib and modules.corelib.g_effects)
    if not effects or not effects.cancelFade or not effects.fadeOut then
      window:hide()
      window:setOpacity(1)
      return
    end

    effects.cancelFade(window)
    effects.fadeOut(window, managerFadeDuration)

    local scheduleClose = modules.corelib and modules.corelib.scheduleEvent
    if type(scheduleClose) ~= "function" then
      window:hide()
      window:setOpacity(1)
      return
    end

    managerHideEvent = scheduleClose(function()
      if window then
        window:hide()
        window:setOpacity(1)
      end
      managerHideEvent = nil
    end, managerFadeDuration + 30)
  end

  local function defaultScriptCode(name)
    name = tostring(name or "Nuevo Script")
    return "macro(1000, \"" .. name:gsub('"', "'") .. "\", function()\n" ..
           "  -- Escribe aqui el codigo de la macro\n" ..
           "end)"
  end
  local codeDraft = defaultScriptCode("Nuevo Script")

  local normalized = {}
  for _, entry in ipairs(storage.customPanelScripts) do
    if type(entry) == "table" then
      entry.id = tonumber(entry.id) or nextScriptId()
      entry.name = tostring(entry.name or ("Script " .. entry.id))
      entry.code = tostring(entry.code or "")
      entry.panel = tostring(entry.panel or "main"):lower()
      entry.side = tostring(entry.side or "left"):lower()
      if not validPanels[entry.panel] then entry.panel = "main" end
      if not validSides[entry.side] then entry.side = "left" end
      entry.enabled = entry.enabled == true
      entry.status = entry.enabled and "Pendiente" or "Off"
      entry.error = ""
      table.insert(normalized, entry)
    end
  end
  storage.customPanelScripts = normalized

  local function setEntryStatus(entry, status, err)
    entry.status = status
    entry.error = err and tostring(err) or ""
  end

  local function createPanelAlias(original, parent)
    local originalContent = original and original.content
    local content = setmetatable({left = parent, right = parent}, {
      __index = originalContent
    })
    return setmetatable({content = content}, {__index = original})
  end

  local function createScriptCompiler(parent)
    local panelAliases = {
      createPanelAlias(panelMain, parent),
      createPanelAlias(panelPvp, parent),
      createPanelAlias(panelHp, parent),
      createPanelAlias(panelOther, parent),
      createPanelAlias(panelSettings, parent),
      createPanelAlias(panelCavebot, parent),
      createPanelAlias(panelTarget, parent)
    }
    local uiProxy = UI
    if type(UI) == "table" then
      uiProxy = setmetatable({}, {
        __call = function(_, ...)
          return UI(...)
        end,
        __index = function(_, key)
          if key == "createWidget" and type(UI.createWidget) == "function" then
            return function(style, widgetParent)
              return UI.createWidget(style, widgetParent or parent)
            end
          end
          return UI[key]
        end,
        __newindex = function(_, key, value)
          UI[key] = value
        end
      })
    end

    local gUiProxy = g_ui
    if type(g_ui) == "table" then
      gUiProxy = setmetatable({}, {
        __index = function(_, key)
          if key == "createWidget" and type(g_ui.createWidget) == "function" then
            return function(style, widgetParent)
              return g_ui.createWidget(style, widgetParent or parent)
            end
          end
          return g_ui[key]
        end,
        __newindex = function(_, key, value)
          g_ui[key] = value
        end
      })
    end

    local customSetDefaultTab = function() return parent end
    local customGetTab = function() return parent end
    local nativeLoadString = loadstring
    local nativeLoad = load
    local compileInContext
    local compatibilityGlobals = {
      panelMain = panelAliases[1], panelPvp = panelAliases[2],
      panelHp = panelAliases[3], panelOther = panelAliases[4],
      panelSettings = panelAliases[5], panelCavebot = panelAliases[6],
      panelTarget = panelAliases[7], UI = uiProxy, g_ui = gUiProxy,
      setDefaultTab = customSetDefaultTab, getTab = customGetTab,
      getDefaultTab = customGetTab, getCurrentTab = customGetTab
    }

    local injectedNames = {
      panelMain = true, panelPvp = true, panelHp = true, panelOther = true,
      panelSettings = true, panelCavebot = true, panelTarget = true,
      UI = true, g_ui = true, setDefaultTab = true, getTab = true,
      getDefaultTab = true, getCurrentTab = true, loadstring = true,
      load = true, _G = true
    }

    local function findRootAssignedNames(source)
      local names, found = {}, {}
      for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local name = line:match("^([%a_][%w_]*)%s*=[^=]") or
                     line:match("^function%s+([%a_][%w_]*)%s*%(")
        if name and not injectedNames[name] and not found[name] then
          found[name] = true
          table.insert(names, name)
        end
      end
      return names
    end

    compileInContext = function(source, chunkName)
      source = tostring(source or "")
      while source:sub(1, 3) == "\239\187\191" do
        source = source:sub(4)
      end
      chunkName = chunkName or "custom_panel_dynamic_script"
      local rootAssignedNames = findRootAssignedNames(source)
      local sharedLocals = ""
      if #rootAssignedNames > 0 then
        sharedLocals = "local " .. table.concat(rootAssignedNames, ", ") .. "\n"
      end
      local wrappedSource =
        "return function(panelMain, panelPvp, panelHp, panelOther, " ..
        "panelSettings, panelCavebot, panelTarget, UI, g_ui, " ..
        "setDefaultTab, getTab, getDefaultTab, getCurrentTab, " ..
        "loadstring, load, _G, ...)\n" .. sharedLocals .. source .. "\nend"
      local factory, compileError

      if type(nativeLoadString) == "function" then
        factory, compileError = nativeLoadString(wrappedSource, chunkName)
      elseif type(nativeLoad) == "function" then
        factory, compileError = nativeLoad(wrappedSource, chunkName)
      else
        return nil, "load/loadstring no disponible"
      end
      if not factory then return nil, compileError end

      local ok, runner = pcall(factory)
      if not ok then return nil, runner end
      if type(runner) ~= "function" then return nil, "El compilador no devolvio una funcion" end

      return function(...)
        return runner(
          panelAliases[1], panelAliases[2], panelAliases[3], panelAliases[4],
          panelAliases[5], panelAliases[6], panelAliases[7], uiProxy, gUiProxy,
          customSetDefaultTab, customGetTab, customGetTab, customGetTab,
          compileInContext, compileInContext,
          compatibilityGlobals, ...
        )
      end
    end

    compatibilityGlobals.loadstring = compileInContext
    compatibilityGlobals.load = compileInContext
    compatibilityGlobals._G = compatibilityGlobals
    return compileInContext
  end

  local function runStoredScript(entry)
    if not entry.enabled then return setEntryStatus(entry, "Off") end
    local queued, queueError = pcall(function()
      CustomPanel.mount(entry.panel, entry.side, function(parent)
        local previousErrorHandler = CustomPanel.currentScriptErrorHandler
        local runtimeFailed = false
        CustomPanel.currentScriptErrorHandler = function(runtimeError)
          runtimeFailed = true
          setEntryStatus(entry, "Error", runtimeError)
          print("CustomPanel Script [" .. entry.name .. "]: " .. tostring(runtimeError))
        end
        local executed, executeError = pcall(function()
          local compiler = createScriptCompiler(parent)
          local chunk, compileError = compiler(entry.code, "custom_panel_script_" .. entry.id)
          if not chunk then error(compileError or "No se pudo compilar") end
          chunk()
        end)
        CustomPanel.currentScriptErrorHandler = previousErrorHandler
        if executed and not runtimeFailed then
          setEntryStatus(entry, "OK")
        elseif not executed then
          setEntryStatus(entry, "Error", executeError)
          print("CustomPanel Script [" .. entry.name .. "]: " .. tostring(executeError))
        end
      end)
    end)
    if not queued then
      setEntryStatus(entry, "Error", queueError)
      print("CustomPanel Script [" .. entry.name .. "]: " .. tostring(queueError))
    end
  end

  for _, entry in ipairs(storage.customPanelScripts) do
    local ok, err = pcall(function() runStoredScript(entry) end)
    if not ok then setEntryStatus(entry, "Error", err) end
  end

  local settingsHeader = CustomPanel.getSettingsHeaderParent and CustomPanel.getSettingsHeaderParent()
  if not settingsHeader then error("No se encontro la cabecera de Settings") end

  do
    local launcher = setupUI([[
Button
  id: scriptManagerLauncher
  width: 220
  height: 20
  anchors.top: parent.top
  anchors.horizontalCenter: parent.horizontalCenter
  text: Gestionador de Scripts
]], settingsHeader)
    launcher:setImageSource("")
    launcher.onClick = function()
      openManager()
    end
    launcher:setTooltip("Organiza y edita tus scripts desde un solo lugar")

managerWindow = setupUI([[
MainWindow
  id: customScriptManager
  text: Gestionador de Scripts
  size: 720 430
  anchors.centerIn: parent

  Panel
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 48
    background-color: #292a30
    border-width: 1
    border-color: #44464f

    Panel
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      width: 4
      background-color: #45a9d6

    Label
      id: title
      anchors.top: parent.top
      anchors.left: parent.left
      margin-top: 6
      margin-left: 15
      color: #75cfff
      text: Gestionador de Scripts - Perfil ]] .. activeProfile .. [[

    Label
      anchors.top: title.bottom
      anchors.left: title.left
      margin-top: 2
      color: #a5a8b0
      text: Scripts independientes del Perfil ]] .. activeProfile .. [[

    Label
      id: scriptCount
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: close.left
      margin-right: 12
      color: #b9bbc2
      text: 0 guardados

    Button
      id: close
      anchors.top: parent.top
      anchors.right: parent.right
      width: 34
      height: 28
      margin-top: 8
      margin-right: 8
      text: X

  Panel
    id: library
    anchors.top: header.bottom
    anchors.left: parent.left
    anchors.bottom: footer.top
    width: 245
    margin-top: 8
    margin-bottom: 8
    background-color: #24252a
    border-width: 1
    border-color: #3f4149

    Label
      id: libraryTitle
      anchors.top: parent.top
      anchors.left: parent.left
      margin-top: 8
      margin-left: 10
      color: #d7d9df
      text: MIS SCRIPTS

    Button
      id: new
      anchors.top: libraryTitle.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 26
      margin-top: 7
      margin-left: 8
      margin-right: 8
      text: + Crear nuevo script

    VerticalScrollBar
      id: listScroll
      anchors.top: new.bottom
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      margin-top: 7
      margin-right: 3
      margin-bottom: 5
      step: 30
      pixels-scroll: true

    ScrollablePanel
      id: list
      anchors.top: new.bottom
      anchors.left: parent.left
      anchors.right: listScroll.left
      anchors.bottom: parent.bottom
      vertical-scrollbar: listScroll
      margin-top: 7
      margin-left: 7
      margin-right: 3
      margin-bottom: 5
      layout:
        type: verticalBox
        cell-height: 43

  Panel
    id: editor
    anchors.top: header.bottom
    anchors.left: library.right
    anchors.right: parent.right
    anchors.bottom: footer.top
    margin-top: 8
    margin-left: 8
    margin-bottom: 8
    background-color: #303137
    border-width: 1
    border-color: #484a53

    Label
      id: sectionLabel
      anchors.top: parent.top
      anchors.left: parent.left
      margin-top: 9
      margin-left: 12
      color: #8b8e98
      text: EDITANDO

    Label
      id: editorTitle
      anchors.top: sectionLabel.bottom
      anchors.left: sectionLabel.left
      anchors.right: parent.right
      margin-top: 3
      margin-right: 12
      text-align: left
      color: #75cfff
      text: Nuevo Script

    Panel
      id: divider
      anchors.top: editorTitle.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      margin-top: 8
      margin-left: 12
      margin-right: 12
      background-color: #4b4d55

    Label
      id: nameLabel
      anchors.top: divider.bottom
      anchors.left: divider.left
      margin-top: 8
      text: Nombre del script

    TextEdit
      id: name
      anchors.top: nameLabel.bottom
      anchors.left: nameLabel.left
      anchors.right: divider.right
      height: 25
      margin-top: 4

    Label
      id: panelLabel
      anchors.top: name.bottom
      anchors.left: name.left
      margin-top: 7
      text: Panel de destino

    ComboBox
      id: panel
      anchors.top: panelLabel.bottom
      anchors.left: panelLabel.left
      width: 150
      height: 24
      margin-top: 4

    Label
      id: sideLabel
      anchors.top: name.bottom
      anchors.left: panel.right
      margin-top: 7
      margin-left: 10
      text: Columna

    ComboBox
      id: side
      anchors.top: sideLabel.bottom
      anchors.left: panel.right
      anchors.right: divider.right
      height: 24
      margin-top: 4
      margin-left: 10

    CheckBox
      id: enabled
      anchors.top: panel.bottom
      anchors.left: panel.left
      width: 240
      height: 18
      margin-top: 8
      text: Cargar automaticamente

    Panel
      id: codeCard
      anchors.top: enabled.bottom
      anchors.left: divider.left
      anchors.right: divider.right
      height: 60
      margin-top: 8
      background-color: #292a2f
      border-width: 1
      border-color: #44464e

      Label
        id: codeTitle
        anchors.top: parent.top
        anchors.left: parent.left
        margin-top: 7
        margin-left: 10
        color: #d9dbe1
        text: Contenido Lua

      Label
        anchors.top: codeTitle.bottom
        anchors.left: codeTitle.left
        anchors.right: code.left
        margin-top: 3
        margin-right: 8
        color: #9699a2
        text: Revisa o modifica el codigo en el editor

      Button
        id: code
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        width: 115
        height: 30
        margin-right: 9
        text: Abrir editor

    Label
      id: currentStatus
      anchors.top: codeCard.bottom
      anchors.left: codeCard.left
      anchors.right: codeCard.right
      height: 18
      margin-top: 5
      color: #bfc1c7
      text: Estado: Sin guardar

    Button
      id: remove
      anchors.top: currentStatus.bottom
      anchors.left: divider.left
      width: 105
      height: 26
      margin-top: 4
      text: Eliminar

    Button
      id: save
      anchors.top: currentStatus.bottom
      anchors.right: divider.right
      width: 135
      height: 26
      margin-top: 4
      text: Guardar cambios

  Panel
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 24
    background-color: #25262b

    Label
      anchors.centerIn: parent
      color: #8f929b
      text: Selecciona un script para editarlo o crea uno nuevo
]], g_ui.getRootWidget())

    local headerPanel = managerWindow:getChildById("header")
    local libraryPanel = managerWindow:getChildById("library")
    local editorPanel = managerWindow:getChildById("editor")
    local footerPanel = managerWindow:getChildById("footer")
    if not headerPanel or not libraryPanel or not editorPanel or not footerPanel then
      error("No se pudieron crear las secciones del Gestionador de Scripts")
    end

    listPanel = libraryPanel:getChildById("list")
    local newButton = libraryPanel:getChildById("new")
    local closeButton = headerPanel:getChildById("close")
    local codeCard = editorPanel:getChildById("codeCard")
    local codeButton = codeCard and codeCard:getChildById("code") or nil
    if not listPanel or not newButton or not closeButton or not codeCard or not codeButton then
      error("No se pudieron crear los controles del Gestionador de Scripts")
    end
    managerWindow:hide()
    for _, option in ipairs({"Main", "Pvp", "Hp", "Other"}) do editorPanel.panel:addOption(option) end
    for _, option in ipairs({"Left", "Right"}) do editorPanel.side:addOption(option) end

    local function findEntryById(id)
      for _, entry in ipairs(storage.customPanelScripts) do if entry.id == id then return entry end end
    end

    local function reloadKeepingManagerOpen(selectedId)
      managerState.open = true
      managerState.selectedId = tonumber(selectedId)
      reload()
    end

    local function selectEntry(entry)
      selectedEntry = entry
      managerState.selectedId = entry and entry.id or nil
      codeDraft = entry and entry.code or defaultScriptCode("Nuevo Script")
      editorPanel.name:setText(entry and entry.name or "Nuevo Script")
      editorPanel.editorTitle:setText(entry and entry.name or "Nuevo Script")
      editorPanel.editorTitle:setTooltip(entry and entry.name or "Nuevo Script")
      editorPanel.panel:setCurrentOption(entry and entry.panel:gsub("^%l", string.upper) or "Main")
      editorPanel.side:setCurrentOption(entry and entry.side:gsub("^%l", string.upper) or "Left")
      editorPanel.enabled:setChecked(entry == nil or entry.enabled == true)
      editorPanel.remove:setEnabled(entry ~= nil)
      editorPanel.name:setTooltip(entry and entry.error or "")
      editorPanel.currentStatus:setText("Estado: " .. (entry and (entry.status or "-") or "Sin guardar"))
      editorPanel.currentStatus:setColor(entry and entry.status == "OK" and "#66d98b" or
        (entry and entry.status == "Error" and "#ff7070" or "#bfc1c7"))
      editorPanel.currentStatus:setTooltip(entry and entry.error or "")
    end

    managerWindow.refreshList = function()
      listPanel:destroyChildren()
      headerPanel.scriptCount:setText(#storage.customPanelScripts .. " guardados")
      for _, entry in ipairs(storage.customPanelScripts) do
        local row = setupUI([[
Panel
  height: 43
  Button
    id: select
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: toggle.left
    margin-right: 4
    text-align: left
  Button
    id: toggle
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: 52
]], listPanel)
        local entryId = entry.id
        local location = entry.panel:gsub("^%l", string.upper) .. " / " .. entry.side:gsub("^%l", string.upper)
        row.select:setText("  " .. entry.name)
        row.toggle:setText(entry.enabled and "ON" or "OFF")
        row.toggle:setColor(entry.enabled and "#66d98b" or "#9b9da5")
        row.select:setTooltip(entry.error ~= "" and entry.error or location .. " - " .. (entry.status or "-"))
        row.toggle:setTooltip(entry.enabled and "Desactivar " .. entry.name or "Activar " .. entry.name)
        row.select.onClick = function() selectEntry(findEntryById(entryId)) end
        row.toggle.onClick = function()
          local stored = findEntryById(entryId)
          if not stored then return end
          stored.enabled = not stored.enabled
          stored.status = stored.enabled and "Pendiente" or "Off"
          reloadKeepingManagerOpen(selectedEntry and selectedEntry.id or stored.id)
        end
      end
    end

    closeButton.onClick = closeManager
    managerWindow.onEscape = closeManager
    newButton.onClick = function() selectEntry(nil) end
    codeButton.onClick = function()
      UI.MultilineEditorWindow(codeDraft or "", {
        title = "Codigo del script",
        description = "Usa una macro con nombre para generar un icono automatico"
      }, function(text) codeDraft = text end)
    end
    editorPanel.save.onClick = function()
      local name = editorPanel.name:getText()
      if not name or name:gsub("%s", "") == "" then return editorPanel.name:setTooltip("Nombre obligatorio") end
      local panelName = editorPanel.panel:getCurrentOption().text:lower()
      local side = editorPanel.side:getCurrentOption().text:lower()
      if not selectedEntry then
        selectedEntry = addStoredScript(name, codeDraft, panelName, side, editorPanel.enabled:isChecked())
      else
        selectedEntry.name, selectedEntry.code = name, codeDraft or ""
        selectedEntry.panel, selectedEntry.side = panelName, side
        selectedEntry.enabled = editorPanel.enabled:isChecked()
        selectedEntry.status, selectedEntry.error = selectedEntry.enabled and "Pendiente" or "Off", ""
      end
      reloadKeepingManagerOpen(selectedEntry.id)
    end
    editorPanel.remove.onClick = function()
      if not selectedEntry then return end
      for index, entry in ipairs(storage.customPanelScripts) do
        if entry.id == selectedEntry.id then table.remove(storage.customPanelScripts, index); break end
      end
      local nextEntry = storage.customPanelScripts[1]
      reloadKeepingManagerOpen(nextEntry and nextEntry.id or nil)
    end

    selectEntry(findEntryById(managerState.selectedId) or storage.customPanelScripts[1])
    managerWindow.refreshList()
    if managerState.open then
      openManager()
    end
  end
end)

if not managerLoaded then print("Gestionador de Scripts: " .. tostring(managerError)) end