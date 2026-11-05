
g_ui.loadUIFromString([[
TargetBotCreatureEditorScrollBar < Panel
  height: 28
  margin-top: 3

  Label
    id: text
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    text-align: center
    
  HorizontalScrollBar
    id: scroll
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: prev.bottom
    margin-top: 3
    minimum: 0
    maximum: 10
    step: 1

TargetBotCreatureEditorTextEdit < Panel
  height: 40
  margin-top: 7

  Label
    id: text
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    text-align: center
    
  TextEdit
    id: textEdit
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: prev.bottom
    margin-top: 5
    minimum: 0
    maximum: 10
    step: 1

TargetBotCreatureEditorItem < Panel
  height: 34
  margin-top: 7
  margin-left: 25
  margin-right: 25

  Label
    id: text
    anchors.left: parent.left
    anchors.verticalCenter: next.verticalCenter

  BotItem
    id: item
    anchors.top: parent.top
    anchors.right: parent.right


TargetBotCreatureEditorCheckBox < BotSwitch
  height: 20
  margin-top: 7

TargetBotCreatureEditorWindow < MainWindow
  text: TargetBot creature editor
  width: 500
  height: 425
  
  $mobile:
    height: 300

  Label
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    text-align: center
    !text: tr('You can use * (any characters) and ? (any character) in target name')

  Label
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: prev.bottom
    text-align: center
    !text: tr('You can also enter multiple targets, separate them by ,')
  
  TextEdit
    id: name
    anchors.top: prev.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    margin-left: 90
    margin-top: 5

  Label
    anchors.verticalCenter: prev.verticalCenter
    anchors.left: parent.left
    text: Target name:

  VerticalScrollBar
    id: contentScroll
    anchors.top: name.bottom
    anchors.right: parent.right
    anchors.bottom: help.top
    step: 28
    pixels-scroll: true
    margin-right: -10
    margin-top: 5
    margin-bottom: 5

  ScrollablePanel
    id: content
    anchors.top: name.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: help.top
    vertical-scrollbar: contentScroll
    margin-bottom: 10
      
    Panel
      id: left
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.horizontalCenter
      margin-top: 5
      margin-left: 10
      margin-right: 10
      layout:
        type: verticalBox
        fit-children: true

    Panel
      id: right
      anchors.top: parent.top
      anchors.left: parent.horizontalCenter
      anchors.right: parent.right
      margin-top: 5
      margin-left: 10
      margin-right: 10
      layout:
        type: verticalBox
        fit-children: true
  
  Button
    id: help
    !text: tr('Help & Tutorials')
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: 150
    @onClick: g_platform.openUrl("http://bot.otclient.ovh/")

  Button
    id: ok
    !text: tr('Ok')
    anchors.bottom: parent.bottom
    anchors.right: next.left
    margin-right: 10
    width: 60

  Button
    id: cancel
    !text: tr('Cancel')
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: 60
    ]])
    
TargetBot.Creature.edit = function(config, callback) -- callback = function(newConfig)
  config = config or {}

  local editor = UI.createWindow('TargetBotCreatureEditorWindow')
  local values = {} -- (key, function returning value of key)

  editor.name:setText(config.name or "")
  table.insert(values, {"name", function() return editor.name:getText() end})

  local addScrollBar = function(id, title, min, max, defaultValue)
    local widget = UI.createWidget('TargetBotCreatureEditorScrollBar', editor.content.left)
    widget.scroll.onValueChange = function(scroll, value)
      widget.text:setText(title .. ": " .. value)
    end
    widget.scroll:setRange(min, max)
    if max-min > 1000 then
      widget.scroll:setStep(100)
    elseif max-min > 100 then
      widget.scroll:setStep(10)
    end
    widget.scroll:setValue(config[id] or defaultValue)
    widget.scroll.onValueChange(widget.scroll, widget.scroll:getValue())
    table.insert(values, {id, function() return widget.scroll:getValue() end})
  end

  local addTextEdit = function(id, title, defaultValue)
    local widget = UI.createWidget('TargetBotCreatureEditorTextEdit', editor.content.right)
    widget.text:setText(title)
    widget.textEdit:setText(config[id] or defaultValue or "")
    table.insert(values, {id, function() return widget.textEdit:getText() end})
  end

  local addCheckBox = function(id, title, defaultValue)
    local widget = UI.createWidget('TargetBotCreatureEditorCheckBox', editor.content.right)
    widget.onClick = function()
      widget:setOn(not widget:isOn())
    end
    widget:setText(title)
    if config[id] == nil then
      widget:setOn(defaultValue)
    else
      widget:setOn(config[id])
    end
    table.insert(values, {id, function() return widget:isOn() end})
  end

  local addItem = function(id, title, defaultItem)
    local widget = UI.createWidget('TargetBotCreatureEditorItem', editor.content.right)
    widget.text:setText(title)
    widget.item:setItemId(config[id] or defaultItem)
    table.insert(values, {id, function() return widget.item:getItemId() end})
  end

  editor.cancel.onClick = function()
    editor:destroy()
  end
  editor.onEscape = editor.cancel.onClick

  editor.ok.onClick = function()
    local newConfig = {}
    for _, value in ipairs(values) do
      newConfig[value[1]] = value[2]()
    end
    if newConfig.name:len() < 1 then return end

    newConfig.regex = ""
    for part in string.gmatch(newConfig.name, "[^,]+") do
      if newConfig.regex:len() > 0 then
        newConfig.regex = newConfig.regex .. "|"
      end
      newConfig.regex = newConfig.regex .. "^" .. part:trim():lower():gsub("%*", ".*"):gsub("%?", ".?") .. "$"    
    end

    editor:destroy()
    callback(newConfig)
  end

  -- values
  addScrollBar("priority", "Priority", 0, 10, 1)
  addScrollBar("danger", "Danger", 0, 10, 1)
  addScrollBar("maxDistance", "Max distance", 1, 10, 10)
  addScrollBar("keepDistanceRange", "Keep distance", 1, 5, 1)
  addScrollBar("anchorRange", "Anchoring Range", 1, 10, 3)
  addScrollBar("lureCount", "Classic Lure", 0, 12, 1)
  addScrollBar("lureMin", "Dynamic lure min", 0, 29, 1)
  addScrollBar("lureMax", "Dynamic lure max", 1, 30, 3)
  addScrollBar("lureDelay", "Dynamic lure delay", 100, 1000, 250)
  addScrollBar("delayFrom", "Start delay when monsters", 1, 29, 2)
  addScrollBar("rePositionAmount", "Min tiles to rePosition", 0, 7, 5)
  addScrollBar("closeLureAmount", "Close Pull Until", 0, 8, 3)
  addScrollBar("killUnder", "Kill monsters below", 1, 100, 1, leftPanel, "Force TargetBot to kill added creatures when they are below set percentage of health - will ignore all other TargetBot settings.")

  addCheckBox("chase", "Chase", false)
  addCheckBox("keepDistance", "Keep Distance", false)
  addCheckBox("anchor", "Anchoring", false)
  addCheckBox("dontLoot", "Don't loot", false)
  addCheckBox("lure", "Lure", false)
  addCheckBox("lureCavebot", "Lure using cavebot", false)
  addCheckBox("faceMonster", "Face monsters", false)
  addCheckBox("avoidAttacks", "Avoid wave attacks", false)
  addCheckBox("dynamicLure", "Dynamic lure", false)
  addCheckBox("dynamicLureDelay", "Dynamic lure delay", false)
  addCheckBox("diamondArrows", "D-Arrows priority", false)
  addCheckBox("rePosition", "rePosition to better tile", false)
  addCheckBox("closeLure", "Close Pulling Monsters", false)
  addCheckBox("rpSafe", "RP PVP SAFE - (DA)", false)
end