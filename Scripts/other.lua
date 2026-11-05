-- other tab

UI.Separator(panelOther.content.left)

UI.Button("Zoom In map [ctrl + =]", function() zoomIn() end, panelOther.content.left)
UI.Button("Zoom Out map [ctrl + -]", function() zoomOut() end, panelOther.content.left)

UI.Separator(panelOther.content.right)

local moneyIds = {3031, 3035, 3043} -- gold coin, platinium coin
macro(1000, "Exchange money", function()
  local containers = g_game.getContainers()
  for index, container in pairs(containers) do
    if not container.lootContainer then -- ignore monster containers
      for i, item in ipairs(container:getItems()) do
        if item:getCount() == 100 then
          for m, moneyId in ipairs(moneyIds) do
            if item:getId() == moneyId then
              return g_game.use(item)            
            end
          end
        end
      end
    end
  end
end, panelOther.content.left)

macro(1000, "Stack items", function()
  local containers = g_game.getContainers()
  local toStack = {}
  for index, container in pairs(containers) do
    if not container.lootContainer then -- ignore monster containers
      for i, item in ipairs(container:getItems()) do
        if item:isStackable() and item:getCount() < 100 then
          local stackWith = toStack[item:getId()]
          if stackWith then
            g_game.move(item, stackWith[1], math.min(stackWith[2], item:getCount()))
            return
          end
          toStack[item:getId()] = {container:getSlotPosition(i - 1), 100 - item:getCount()}
        end
      end
    end
  end
end, panelOther.content.right)

macro(10000, "Anti Kick",  function()
  local dir = player:getDirection()
  turn((dir + 1) % 4)
  turn(dir)
end, panelOther.content.left)

UI.Separator()
UI.Label("Drop items:", panelOther.content.right)
if type(storage.dropItems) ~= "table" then
  storage.dropItems = {283, 284, 285}
end

local foodContainer = UI.Container(function(widget, items)
  storage.dropItems = items
end, true, panelOther.content.right)
foodContainer:setHeight(35)
foodContainer:setItems(storage.dropItems)

macro(5000, "drop items", function()
  if not storage.dropItems[1] then return end
  if TargetBot and TargetBot.isActive() then return end -- pause when attacking
  for _, container in pairs(g_game.getContainers()) do
    for __, item in ipairs(container:getItems()) do
      for i, dropItem in ipairs(storage.dropItems) do
        if item:getId() == dropItem.id then
          if item:isStackable() then
            return g_game.move(item, player:getPosition(), item:getCount())
          else
            return g_game.move(item, player:getPosition(), dropItem.count) -- count is also subtype
          end
        end
      end
    end
  end
end, panelOther.content.right)

UI.Separator(panelOther.content.left)

UI.Label("Mana training", panelOther.content.left)
if type(storage.manaTrain) ~= "table" then
  storage.manaTrain = {on=false, title="MP%", text="utevo lux", min=80, max=100}
end

local manatrainmacro = macro(1000, function()
  if TargetBot and TargetBot.isActive() then return end -- pause when attacking
  local mana = math.min(100, math.floor(100 * (player:getMana() / player:getMaxMana())))
  if storage.manaTrain.max >= mana and mana >= storage.manaTrain.min then
    say(storage.manaTrain.text)
  end
end, panelOther.content.left)
manatrainmacro.setOn(storage.manaTrain.on)

UI.DualScrollPanel(storage.manaTrain, function(widget, newParams) 
  storage.manaTrain = newParams
  manatrainmacro.setOn(storage.manaTrain.on)
end, panelOther.content.left)

UI.Separator(panelOther.content.right)

macro(60000, "Send message on trade", function()
  local trade = getChannelId("advertising")
  if not trade then
    trade = getChannelId("trade")
  end
  if trade and storage.autoTradeMessage:len() > 0 then    
    sayChannel(trade, storage.autoTradeMessage)
  end
end, panelOther.content.right)
UI.TextEdit(storage.autoTradeMessage or "I'm using OTClientV8!", function(widget, text)    
  storage.autoTradeMessage = text
end, panelOther.content.right)

UI.Separator(panelOther.content.right)


if type(storage.SpyUpKey) ~= "string" then storage.SpyUpKey = "*" end
if type(storage.SpyDownKey) ~= "string" then storage.SpyDownKey = "-  " end

UI.Label("Tecla Spy Up", panelOther.content.left)
UI.TextEdit(storage.SpyUpKey, function(_, text)
  storage.SpyUpKey = text
end, panelOther.content.left)

UI.Label("Tecla Spy Down", panelOther.content.left)
UI.TextEdit(storage.SpyDownKey, function(_, text)
  storage.SpyDownKey = text
end, panelOther.content.left)

local lockedLevel = pos().z
local m = macro(1000, "Spy Level", function() end, panelOther.content.left)

onPlayerPositionChange(function(newPos, oldPos)
  if oldPos.z ~= newPos.z then
    lockedLevel = pos().z
    modules.game_interface.getMapPanel():unlockVisibleFloor()
  end
end)

onKeyPress(function(keys)
  if not m.isOn() then return end
  if keys == storage.SpyDownKey then
    lockedLevel = lockedLevel + 1
    modules.game_interface.getMapPanel():lockVisibleFloor(lockedLevel)
  elseif keys == storage.SpyUpKey then
    lockedLevel = lockedLevel - 1
    modules.game_interface.getMapPanel():lockVisibleFloor(lockedLevel)
  end
end)