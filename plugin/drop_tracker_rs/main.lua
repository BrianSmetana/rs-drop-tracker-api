-- Entry point run by the RS client when the plugin is enabled (pon drop_tracker_rs).
-- Logic lives in adapter.lua so it can be tested with mock globals.
-- Staged loader: every step prints to the client console, so a failure shows exactly where it happened.
local function say(m) print("[DropTracker] " .. m) end

local function trace(e)
  if debug and debug.traceback then return debug.traceback(tostring(e), 2) end
  return tostring(e)
end

local function step(name, f)
  local ok, res = xpcall(f, trace)
  say(name .. ": " .. (ok and "ok" or ("FAILED\n" .. tostring(res))))
  return ok, res
end

-- 1. Which globals does this client actually provide?
local env = _ENV
for _, n in ipairs({ "Event", "HTTPRequest", "PersistentDB", "Plugin", "PluginPermissions", "Player", "log",
                     "prettyui", "ui", "id", "var", "Chat", "string", "table", "math", "pcall", "xpcall", "require" }) do
  say("global " .. n .. " = " .. type(env[n]))
end
-- Dependencies may be injected as plain variables rather than _ENV fields, so test the name directly.
say("direct prettyui = " .. type(prettyui))
if type(prettyui) == "table" then
  say("prettyui.Window = " .. type(prettyui.Window) .. ", prettyui.version = " .. tostring(prettyui.version))
end
if type(env.Event) == "table" then
  for _, n in ipairs({ "ChatMessage", "ObjStackEntityAdded", "ServerLogic" }) do
    say("Event." .. n .. " = " .. type(env.Event[n]))
  end
end
if type(env.Plugin) == "table" then
  say("Plugin.urls = " .. type(env.Plugin.urls))
  if type(env.Plugin.HasPermission) == "function" and type(env.PluginPermissions) == "table" then
    for _, p in ipairs({ "httpAccess", "chatAccess" }) do
      local ok, v = pcall(env.Plugin.HasPermission, env.PluginPermissions[p])
      say("permission " .. p .. " = " .. tostring(v) .. (ok and "" or " (HasPermission raised an error)")
        .. " [enum " .. tostring(env.PluginPermissions[p]) .. "]")
    end
  end
end

-- 2. Load each module on its own, then start.
local loaded = true
for _, m in ipairs({ "core", "config", "rates", "ui", "killvars", "collog", "adapter" }) do
  local ok = step("require " .. m, function()
    if require(m) == nil then error("require returned nil (file missing?)") end
  end)
  loaded = loaded and ok
end

local app
if loaded then
  step("start", function()
    app = require("adapter").start({
      Event = Event,
      HTTPRequest = HTTPRequest,
      PersistentDB = PersistentDB,
      Plugin = Plugin,
      PluginPermissions = PluginPermissions,
      Player = Player,
      log = log,
      -- friendly output: prettyui is the PrettyUI plugin (required dependency); ui/id/Chat are client globals
      PrettyUI = prettyui,
      ui = ui,
      id = id,
      Chat = Chat,
      clientConfig = config, -- the client's own config tables (config.Obj.FromID(...) turns item ids into names)
      var = var, -- game variables: var.VarPlayer["BSLAY_KILLS_..."].value is a boss kill count
    })
  end)
end
-- Run by the client when the plugin is disabled or reloaded: remove our window and event hooks.
function PluginShutdown()
  if app and app.shutdown then pcall(app.shutdown) end
end

say("main.lua finished")
