CustomProfiles = {}

local changingProfile = false

local function normalizeProfile(profile)
  profile = math.floor(tonumber(profile) or 1)
  return math.max(1, math.min(10, profile))
end

function CustomProfiles.getProfile()
  local ok, profile = pcall(function()
    return g_settings.getNumber("profile")
  end)
  return normalizeProfile(ok and profile or 1)
end

function CustomProfiles.setProfile(profile, options)
  profile = normalizeProfile(profile)
  options = options or {}
  if CustomPanel and CustomPanel.backups and CustomPanel.backups.busy then
    print("CustomProfiles: espera a que termine la operacion de respaldos antes de cambiar de perfil")
    return false
  end
  if changingProfile then return false end
  changingProfile = true

  local ok, result = pcall(function()
    local current = modules.game_bot.contentsPanel.config:getCurrentOption().text
    local name = current
    if profile == CustomProfiles.getProfile() and not options.forceReload then return end
    local settings = g_settings.getNode("bot") or {}
    local key = g_game.getCharacterName() .. "_" .. g_game.getClientVersion()
    if not settings[key] then error("No se encontro la configuracion del personaje") end
    if not options.skipSave and modules.game_bot.save then modules.game_bot.save() end
    settings[key].config = name
    g_settings.setNode("bot", settings)
    g_settings.set("profile", profile)
    if normalizeProfile(g_settings.getNumber("profile")) ~= profile then
      error("el cliente no conservo el perfil seleccionado")
    end
    if type(g_settings.save) == "function" then g_settings.save() end


    if modules.client_profiles and type(modules.client_profiles.onProfileChange) == "function" then
      modules.client_profiles.onProfileChange(true)
    end
    if not modules.game_bot or type(modules.game_bot.refresh) ~= "function" then
      error("game_bot.refresh no esta disponible")
    end
    if options.skipSave then
      if type(modules.game_bot.clear) ~= "function" then
        error("game_bot.clear no esta disponible; no se recargo para proteger el storage importado")
      end
      modules.game_bot.clear()
    end
    modules.game_bot.refresh()
  end)
  changingProfile = false

  if not ok then
    print("CustomProfiles: no se pudo seleccionar el Perfil " .. profile .. ": " .. tostring(result))
    return false
  end
  return true
end
