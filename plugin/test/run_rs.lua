-- Tests for plugin/drop_tracker_rs against MOCKS of the public RS client API
-- (Event.<Name>.Subscribe, HTTPRequest, PersistentDB, Plugin.HasPermission) and a mock Drop Tracker server.
-- Run from the project root:   lua plugin/test/run_rs.lua

package.path = "./plugin/drop_tracker_rs/?.lua;" .. package.path

local adapter = require("adapter")
local core = require("core")

local function new_env(server, opts)
  opts = opts or {}
  local env = { calls = {}, logs = {}, store = opts.store or {}, perms = { httpAccess = opts.http ~= false }, subs = {}, unsubs = {} }

  local G = {
    log = function(m) env.logs[#env.logs + 1] = m end,
    Plugin = {
      urls = { api = "API" },
      HasPermission = function(p) return env.perms[p] == true end,
    },
    PluginPermissions = { httpAccess = "httpAccess", chatAccess = "chatAccess" },
    PersistentDB = {
      GetString = function(_, k) return env.store[k] end,
      SetString = function(_, k, v) env.store[k] = v return true end,
    },
    Player = {
      IsAvailable = function() return opts.player ~= nil end,
      GetEntity = function() return { displayName = opts.player } end,
    },
    Event = setmetatable({}, { __index = function(t, name)
      local e = {
        Subscribe = function(ref, f) env.subs[name] = f end,
        Unsubscribe = function(ref) env.unsubs[name] = ref end,
      }
      rawset(t, name, e)
      return e
    end }),
    HTTPRequest = {
      new = function(base, path)
        assert(base == "API", "must use Plugin.urls.api as the base URL")
        local req = { headers = {} }
        function req:AddHeader(k, v) self.headers[k] = v end
        function req:Post(data, cb)
          env.calls[#env.calls + 1] = { path = path, headers = self.headers, body = data }
          local status, resp = server(path, self.headers, data, #env.calls)
          self.responseCode, self.data = status or 0, resp or ""
          self.successful = status ~= nil and status < 300
          self.failed = status == nil
          cb(self)
        end
        return req
      end,
    },
  }

  function env.chat(text) env.subs.ChatMessage({ chatMessage = text, chatType = 4 }) end
  function env.kill(boss, kc) env.chat("You have killed " .. kc .. " " .. boss .. " in normal mode.") end
  function env.loot(item, qty, owner)
    env.subs.ObjStackEntityAdded({ objType = { name = item }, count = qty or 1, isOwner = owner ~= false })
  end
  function env.tick(n)
    for _ = 1, n or 1 do
      env.subs.ServerLogic({})
      env.clog.held = nil                              -- ids destroyed during this tick are free from the next one
    end
  end
  function env.advance(seconds) env.tick(math.ceil(seconds / 0.6)) end
  function env.calls_to(path)
    local n = 0
    for _, c in ipairs(env.calls) do if c.path == path then n = n + 1 end end
    return n
  end
  function env.last_call(path)
    for i = #env.calls, 1, -1 do if env.calls[i].path == path then return env.calls[i] end end
  end

  env.chat_lines = {}
  if opts.chat_out then
    G.Chat = { AddMessage = function(m) env.chat_lines[#env.chat_lines + 1] = m end }
    env.perms.chatAccess = true
  end
  -- Mock of the collection log (interface 656): header layer 11 with a title text, contents layer 21 with item slots.
  local function layer() return { children = {} , IterateDynamicComponents = function(self, fn)
    for _, ch in ipairs(self.children) do if fn(ch, true) then break end end
  end } end
  env.clog = { open = false, labels = {}, header = layer(), contents = layer() }
  -- game variables: env.vars.BSLAY_KILLS_X = n  ->  var.VarPlayer["BSLAY_KILLS_X"].value == n
  env.vars = {}
  G.var = { VarPlayer = setmetatable({}, { __index = function(_, name)
    local v = env.vars[name]
    if v == nil then error("no such variable " .. tostring(name)) end
    return { value = v }
  end }) }
  -- The game rebuilding the page: it clears every dynamic component in the layer (our labels too) and rebuilds the same slots.
  function env.clog.rebuild()
    local kept = {}
    for _, ch in ipairs(env.clog.contents.children) do
      if ch.category then ch.destroyed = true else kept[#kept + 1] = ch end
    end
    env.clog.contents.children = kept
  end
  function env.clog.show(title, slots, total)
    env.clog.open = true
    env.clog.header.children = { { type = 2, content = title }, { type = 2, content = "1/" .. (total or #slots) } }
    env.clog.contents.children = {}
    for _, s in ipairs(slots) do
      env.clog.contents.children[#env.clog.contents.children + 1] = {
        type = 3, associatedObjectID = s.obj, x = s.x or 13, y = s.y or 10, width = 36, height = 32,
        alpha = s.missing and 0.84313726425171 or 1.0, rgb = s.missing and 1315860 or 16777215,
        associatedObjectQuantity = s.qty,
      }
    end
  end
  if opts.pretty or opts.clog then
    G.id = { Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 1 }, Font = { MUSEO_SANS_15PT_REGULAR = 7, NOTOSANS_BOLD_11 = 166 } }
    G.ui = {
      AlignMode = { CENTRE = 4 },
      Interfaces = {
        GetInterface = function(_, iface) if iface == 656 and env.clog.open then return {} end end,
        GetComponent = function(_, a, b)
          if a == 656 and b == 11 then return env.clog.header end
          if a == 656 and b == 21 then return env.clog.contents end
          return {}
        end,
      },
      Text = { new = function(parent, category, dynamic)
        -- like the real client: ids must be 0..255 (it rejected category 7777), and a mock switch can force a rejection
        if env.clog.reject_labels or (category and (category < 0 or category > 255))
          or (dynamic and (dynamic < 0 or dynamic > 255)) then
          error("Failed to create Label (category=" .. tostring(category) .. " ID=" .. tostring(dynamic) ..
            ") - invalid dynamic ID, expected a value between 0 and 256")
        end
        if (env.clog.fail_creates or 0) > 0 then      -- the client refusing the next N creations
          env.clog.fail_creates = env.clog.fail_creates - 1
          error("Failed to create Label (category=" .. tostring(category) .. " ID=" .. tostring(dynamic) .. ") - ID in use")
        end
        local key = tostring(category) .. ":" .. tostring(dynamic)
        if env.clog.held and env.clog.held[key] then  -- a destroyed label's id stays reserved until the next tick
          error("Failed to create Label (category=" .. tostring(category) .. " ID=" .. tostring(dynamic) .. ") - ID in use")
        end
        local t = { parent = parent, category = category, dynamic = dynamic, categoryID = category }
        env.clog.creations = (env.clog.creations or 0) + 1
        if env.clog.blind then                         -- a client whose iteration never lists our labels
          function t:SetPos(x, y) self.x, self.y = x, y end
          function t:SetSize(w, h) self.w, self.h = w, h end
          function t:Destroy() self.destroyed = true end
          env.clog.labels[#env.clog.labels + 1] = t
          return t
        end
        function t:SetPos(x, y) self.x, self.y = x, y end
        function t:SetSize(w, h) self.w, self.h = w, h end
        function t:Destroy()
          self.destroyed = true
          if env.clog.hold_ids then                    -- the client frees the id only on the next tick
            env.clog.held = env.clog.held or {}
            env.clog.held[tostring(self.category) .. ":" .. tostring(self.dynamic)] = true
          end
        end
        env.clog.labels[#env.clog.labels + 1] = t
        table.insert(parent.children, t)
        return t
      end },
    }
  end
  if opts.clog then
    local names = { [60334] = "Bonecrusher maul", [60336] = "Magic skull mask", [60333] = "Colossal bone", [60794] = "Ivarsson", [70001] = "Tess", [70002] = "Reeves", [70003] = "Molly", [70004] = "Croesus sporehammer", [70005] = "Little sus", [70006] = "Dormant Zaros godsword", [70007] = "Devourer's Guard", [70008] = "Godsword shard 1", [70009] = "Dormant anima core body", [70010] = "Savage plume" }
    G.clientConfig = { Obj = { FromID = function(obj) return { name = names[obj] } end } }
  end
  function env.live_labels()
    local out = {}
    for _, t in ipairs(env.clog.labels) do if not t.destroyed then out[#out + 1] = t end end
    return out
  end
  if opts.pretty then
    local win = { shown = false, texts = {}, radios = {} }
    env.window = win
    G.PrettyUI = { Window = { new = function(parent, o)
      win.title = o.title
      local w = {}
      function w:AddRadioButton(choices, ro) win.radios[#win.radios + 1] = { choices = choices, options = ro } end
      function w:AddText(t) local x = { content = t.text } win.texts[#win.texts + 1] = x return x end
      function w:Show() win.shown = true end
      function w:Destroy() win.destroyed = true end
      return w
    end } }
  end

  env.app = adapter.start(G)
  return env
end

local function healthy_server()
  local n = 0
  return function(path)
    if path == "/v1/players" then
      n = n + 1
      return 201, '{"player_id":"p' .. n .. '","token":"p' .. n .. '.secret"}'
    elseif path == "/v1/events" or path == "/v1/me/profile" or path == "/v1/me/collection" then
      return 200, "{}"
    end
    return 404, "{}"
  end
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("PASS  " .. name)
  else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function has(s, sub) if not s:find(sub, 1, true) then error("missing " .. sub .. " in " .. s, 2) end end
local function lacks(s, sub) if s:find(sub, 1, true) then error("unexpected " .. sub .. " in " .. s, 2) end end
local function count(s, sub)
  local n = 0
  for _ in s:gmatch((sub:gsub("%p", "%%%0"))) do n = n + 1 end
  return n
end

test("nothing is sent until httpAccess is granted", function()
  local env = new_env(healthy_server(), { http = false })
  env.kill("Har-Aken", "1")
  env.tick(5)
  eq(#env.calls, 0)
  env.perms.httpAccess = true
  env.tick(2)
  eq(env.calls_to("/v1/events"), 1)
end)

test("kill + tracked drop are registered and sent via Plugin.urls.api with the bearer token", function()
  local env = new_env(healthy_server())
  env.kill("Har-Aken", "1")
  env.loot("Volcanic shard")
  env.tick(2)
  eq(env.calls_to("/v1/players"), 1)
  local c = env.last_call("/v1/events")
  eq(c.headers["Authorization"], "Bearer p1.secret")
  eq(c.headers["Content-Type"], "application/json")
  has(c.body, '"type":"kill"'); has(c.body, '"boss":"Har-Aken"'); has(c.body, '"kc":1')
  has(c.body, '"type":"drop"'); has(c.body, '"item":"Shrimpy"')
  eq(env.store.queue, "")
end)

test("chat colour markup is stripped and comma kill counts parsed", function()
  local env = new_env(healthy_server())
  env.chat("<col=ff0000>You have killed 1,234 Har-Aken in hard mode.</col>")
  env.tick(2)
  has(env.last_call("/v1/events").body, '"kc":1234')
end)

test("real in-game kill message (Ivar) is parsed with the kc first", function()
  local env = new_env(healthy_server())
  env.chat("You have killed 48 Ivar, King of Bones in normal mode.")
  env.loot("Bonecrusher maul")
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, '"boss":"Ivar, King of Bones"'); has(body, '"kc":48'); has(body, '"item":"Bonecrusher maul"')
end)

test("untracked bosses and items never leave the client", function()
  local env = new_env(healthy_server())
  env.kill("Vorkath", "5")
  env.loot("Coins", 1000)
  env.tick(3)
  eq(#env.calls, 0)
end)

test("loot not owned by the player is ignored", function()
  local env = new_env(healthy_server())
  env.kill("Har-Aken", "2")
  env.loot("Volcanic shard", 1, false)
  env.tick(2)
  lacks(env.last_call("/v1/events").body, '"type":"drop"')
end)

test("Barrows uniques are sent, other loot is not", function()
  local env = new_env(healthy_server())
  env.kill("The Barrows Brothers", "10")
  env.loot("Dharok's helm"); env.loot("Death rune", 200); env.loot("Linza's hammer")
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, "Dharok's helm"); has(body, "Linza's hammer"); lacks(body, "Death rune")
  eq(count(body, '"type":"drop"'), 2)
end)

test("drops are attributed to the latest kill's boss and kc", function()
  local env = new_env(healthy_server())
  env.kill("Har-Aken", "40")
  env.kill("The Barrows Brothers", "7")
  env.loot("Verac's flail")
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, '"boss":"The Barrows Brothers"'); has(body, '"kc":7')
end)

test("network failure: events kept and retried after backoff", function()
  local online = false
  local inner = healthy_server()
  local env = new_env(function(...) if not online then return nil end return inner(...) end)
  env.kill("Har-Aken", "3")
  env.tick()
  eq(env.calls_to("/v1/players"), 1)
  env.tick()
  eq(env.calls_to("/v1/players"), 1, "must not retry during backoff")
  online = true
  env.advance(1000)
  env.tick(2)
  has(env.last_call("/v1/events").body, '"kc":3')
end)

test("5xx keeps the batch and reuses event ids", function()
  local fail = true
  local inner = healthy_server()
  local env = new_env(function(path, ...) if path == "/v1/events" and fail then return 503, "{}" end return inner(path, ...) end)
  env.kill("Har-Aken", "9")
  env.tick(2)
  assert(env.store.queue ~= "")
  fail = false
  env.advance(1000)
  env.tick()
  eq(env.store.queue, "")
  local ids = {}
  for _, c in ipairs(env.calls) do
    if c.path == "/v1/events" then ids[#ids + 1] = c.body:match('"event_id":"([^"]+)"') end
  end
  eq(ids[1], ids[2])
end)

test("401 triggers re-registration and the queued events are resent", function()
  local inner = healthy_server()
  local rejected = false
  local env = new_env(function(path, ...)
    if path == "/v1/events" and not rejected then rejected = true return 401, "{}" end
    return inner(path, ...)
  end)
  env.kill("Har-Aken", "2")
  env.tick(4)
  eq(env.calls_to("/v1/players"), 2)
  eq(env.last_call("/v1/events").headers["Authorization"], "Bearer p2.secret")
  eq(env.store.queue, "")
end)

test("a 4xx batch rejection drops the batch", function()
  local inner = healthy_server()
  local env = new_env(function(path, ...) if path == "/v1/events" then return 422, "{}" end return inner(path, ...) end)
  env.kill("Har-Aken", "1")
  env.tick(3)
  eq(env.store.queue, "")
  eq(env.calls_to("/v1/events"), 1)
end)

test("queue and token persist through PersistentDB across a restart", function()
  local env = new_env(healthy_server())
  env.kill("Har-Aken", "1")
  env.tick() -- registers only
  local token = env.store.token
  assert(token and token ~= "")
  local host = {
    http_post = function() end, now = function() return 0 end, random_hex = function() return "abcd1234" end,
    log = function() end,
    storage_get = function(k) return env.store[k] end,
    storage_set = function(k, v) env.store[k] = v end,
  }
  local t2 = core.new(host, { api_url = "http://x" })
  eq(#t2.queue, 1)
  eq(t2.token, token)
end)

test("profile is not published unless publish_to_website is on", function()
  local env = new_env(healthy_server(), { player = "Zezima" })
  env.tick(3)
  eq(env.calls_to("/v1/me/profile"), 0)
end)

test("publish_to_website sends the in-game name once the player is available", function()
  local config = require("config")
  config.publish_to_website = true
  local env = new_env(healthy_server(), { player = "Zezima" })
  env.tick(4)
  config.publish_to_website = false
  local c = env.last_call("/v1/me/profile")
  assert(c, "profile call expected")
  has(c.body, '"username":"Zezima"'); has(c.body, '"public":true')
end)

local ui = require("ui")

test("format: empty state, permission warning, syncing and synced", function()
  local _, body = ui.format({ http = true, pending = 0, bosses = {} })
  has(body, "No tracked kills yet")
  has((ui.format({ http = false, pending = 0, bosses = {} })), "HTTP permission not granted")
  has((ui.format({ http = true, pending = 2, bosses = {} })), "2 events queued")
  has((ui.format({ http = true, pending = 1, bosses = {} })), "1 event queued")
  has((ui.format({ http = true, pending = 0, bosses = {} })), "All synced")
end)

test("format: boss, kill count, session kills and drops", function()
  local _, body = ui.format({ http = true, pending = 0, bosses = {
    { name = "Ivar, King of Bones", kc = 49, kills = 3, drops = { { item = "Bonecrusher maul", count = 1 } } },
  } })
  has(body, "Ivar, King of Bones"); has(body, "Kill count 49"); has(body, "3 this session")
  has(body, "Bonecrusher maul</col> x1")
end)

test("body height grows with the number of lines", function()
  eq(ui.body_height(""), 26)
  eq(ui.body_height("a<br>b<br>c"), 62)
end)

test("PrettyUI window is filled and shown on a kill, and status follows the sync", function()
  local env = new_env(healthy_server(), { pretty = true })
  eq(env.window.title, "Drop Tracker")
  eq(env.window.shown, false)
  has(env.window.texts[#env.window.texts].content, "No tracked kills yet")
  env.kill("Ivar, King of Bones", "49")
  env.loot("Bonecrusher maul")
  eq(env.window.shown, true)
  local body = env.window.texts[#env.window.texts].content
  has(body, "Ivar, King of Bones"); has(body, "Kill count 49"); has(body, "Bonecrusher maul")
  has(env.window.texts[1].content, "2 events queued")
  env.tick(2)
  has(env.window.texts[1].content, "All synced")
end)

test("window status warns when httpAccess is missing", function()
  local env = new_env(healthy_server(), { pretty = true, http = false })
  env.kill("Har-Aken", "1")
  has(env.window.texts[1].content, "HTTP permission not granted")
end)

test("without PrettyUI a chat line is shown for kills and drops", function()
  local env = new_env(healthy_server(), { chat_out = true })
  env.kill("Ivar, King of Bones", "49")
  env.loot("Bonecrusher maul")
  eq(env.chat_lines[1], "Drop Tracker: Ivar, King of Bones kill 49 (1 this session)")
  eq(env.chat_lines[2], "Drop Tracker: Bonecrusher maul from Ivar, King of Bones!")
end)

test("shutdown destroys the window and unsubscribes every hook (no duplicate windows after a reload)", function()
  local env = new_env(healthy_server(), { pretty = true })
  env.app.shutdown()
  eq(env.window.destroyed, true)
  eq(env.unsubs.ChatMessage, "dropTrackerChat")
  eq(env.unsubs.ObjStackEntityAdded, "dropTrackerLoot")
  eq(env.unsubs.ServerLogic, "dropTrackerTick")
  eq(env.unsubs.OptionalPermissionChanged, "dropTrackerPerm")
end)

test("a permission change is logged and the window status follows it", function()
  local env = new_env(healthy_server(), { pretty = true, http = false })
  has(env.window.texts[1].content, "HTTP permission not granted")
  env.perms.httpAccess = true
  env.subs.OptionalPermissionChanged({ permissionName = "httpAccess", enabled = true })
  has(env.window.texts[1].content, "All synced")
  local found = false
  for _, l in ipairs(env.logs) do if l:find("permission httpAccess enabled = true", 1, true) then found = true end end
  assert(found, "permission change should be logged")
end)

local NEWS = "<col=ff8000>News: <img=3>Silly Sour has received Ivar's loincloth drop at 54 kills!</col>"

test("real drop announcement is recorded against the right boss and kill count", function()
  local env = new_env(healthy_server(), { pretty = true, player = "Silly Sour" })
  env.kill("Ivar, King of Bones", "54")
  env.chat(NEWS)
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, '"type":"drop"'); has(body, '"boss":"Ivar, King of Bones"')
  has(body, '"item":"Ivar\'s loincloth"'); has(body, '"kc":54')
  has(env.window.texts[#env.window.texts].content, "Ivar's loincloth")
end)

test("an announcement for another player is ignored", function()
  local env = new_env(healthy_server(), { player = "Someone Else" })
  env.kill("Ivar, King of Bones", "54")
  env.chat(NEWS)
  env.tick(2)
  lacks(env.last_call("/v1/events").body, '"type":"drop"')
end)

test("announcement and loot event for the same drop are counted once", function()
  local env = new_env(healthy_server(), { player = "Silly Sour" })
  env.kill("Ivar, King of Bones", "54")
  env.loot("Ivar's loincloth")
  env.chat(NEWS)
  env.tick(2)
  eq(count(env.last_call("/v1/events").body, '"type":"drop"'), 1)
end)

test("announcement works before the kill message and finds the boss from the item", function()
  local env = new_env(healthy_server(), { player = "Silly Sour" })
  env.chat(NEWS)
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, '"boss":"Ivar, King of Bones"'); has(body, '"kc":54')
end)

test("name unknown: only a drop at our own latest kill count is trusted", function()
  local env = new_env(healthy_server())
  env.kill("Ivar, King of Bones", "54")
  env.chat(NEWS)
  env.chat("News: Other Guy has received Ivar's head drop at 900 kills!")
  env.tick(2)
  local body = env.last_call("/v1/events").body
  has(body, "Ivar's loincloth"); lacks(body, "Ivar's head")
end)

local collog = require("collog")

-- Exact P(X <= k) for X ~ Binomial(n, p), computed directly (independent of the plugin's log-space version).
local function exact_cdf(n, p, k)
  local total = 0
  for j = 0, math.min(k, n) do
    local c = 1
    for i = 1, j do c = c * (n - j + i) / i end
    total = total + c * p ^ j * (1 - p) ^ (n - j)
  end
  return total
end
local function pct(prob) return collog.format_percent(prob) end
local IVAR = { { obj = 60334, x = 13 }, { obj = 60336, x = 55, missing = true }, { obj = 60333, x = 97, missing = true }, { obj = 60794, x = 139 } }

test("collog: probability, percent format, colour and boss resolution", function()
  assert(math.abs(collog.dry_probability(1 / 64, 64) - 0.3649) < 0.001) -- (63/64)^64
  eq(collog.format_percent(0.4206), "42%")
  eq(collog.format_percent(0.052), "5.2%")
  eq(collog.format_percent(0.0004), "<0.1%")
  eq(collog.colour(0.05), 0xFF6B6BFF); eq(collog.colour(0.3), 0xFFA94DFF)
  eq(collog.colour(0.7), 0xFFD700FF); eq(collog.colour(0.95), 0x7FE08FFF)
  local rates = { ["Ivar, King of Bones"] = { ["Magic skull mask"] = 1 / 64 }, ["Other"] = { ["Shared"] = 0.1 },
                  ["Other Two"] = { ["Shared"] = 0.2 } }
  eq(collog.resolve_boss("Magic skull mask", "Ivar", rates), "Ivar, King of Bones")
  eq(collog.resolve_boss("Shared", "Other Two", rates), "Other Two")
  eq(collog.resolve_boss("Shared", "Nothing", rates), nil)
  eq(collog.resolve_boss("Nope", "Ivar", rates), nil)
end)

test("collog: a missing item with a known kill count gets a dry % label under its slot", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 3, "owned maul, missing mask and owned pet have a rate; Colossal bone (always drops) has none")
  -- owned Bonecrusher maul (no readable count, so k = 1): P(X <= 1), X ~ Binomial(55, 1/64) = 79%, gold
  eq(labels[1].content, pct(exact_cdf(55, 1 / 64, 1))); eq(labels[1].content, "79%"); eq(labels[1].rgba, 0xFFD700FF)
  -- missing Magic skull mask: chance of still being dry, (63/64)^55 = 42%, orange
  eq(labels[2].content, "42%"); eq(labels[2].rgba, 0xFFA94DFF)
  eq(labels[2].x, 55); eq(labels[2].y, 28) -- inside the 36x32 item box at (55,10): bottom right
  eq(labels[2].w, 36); eq(labels[2].h, 14)
  -- owned pet Ivarsson (1/1250, threshold 250), k = 1: nearly certain at 55 kills, green
  eq(labels[3].content, pct(exact_cdf(55, 1 / 1250, 1))); eq(labels[3].rgba, 0x7FE08FFF)
end)

test("collog: items without a known rate get no label, owned or missing", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", { { obj = 60333, x = 97, missing = true } })
  env.tick(2)
  eq(#env.live_labels(), 0)
end)

test("collog: items with no drop rate are recorded per page for review", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(env.store.clog_unmatched, "Ivar\tColossal bone")
  env.clog.show("Ivar", { { obj = 60333, x = 97, missing = true } })
  env.tick(2)
  eq(env.store.clog_unmatched, "Ivar\tColossal bone", "a page is replaced, not duplicated")
  env.clog.show("Ivar", { { obj = 60334 } }) -- only Bonecrusher maul, which has a rate: the page is fully covered
  env.tick(2)
  eq(env.store.clog_unmatched, "", "a fully covered page is removed from the list")
end)

test("collog: boss pets use the stepped bad-luck chance", function()
  local pet = { base = 1 / 5000, threshold = 1000 }
  assert(math.abs(collog.dry_probability(pet, 0) - 1) < 1e-12)
  assert(math.abs(collog.dry_probability(pet, 1000) - 0.8187) < 0.001)           -- (1 - 1/5000)^1000
  assert(math.abs(collog.dry_probability(pet, 2000) - 0.5488) < 0.001)           -- then (1 - 2/5000)^1000
  -- past nine thresholds the numerator stays at 10: 9000 kills, then 1000 more at 10/5000
  local nine = collog.dry_probability(pet, 9000)
  assert(math.abs(collog.dry_probability(pet, 10000) - nine * (1 - 10 / 5000) ^ 1000) < 1e-9)
  assert(collog.dry_probability(pet, 500) > collog.dry_probability(pet, 1500)) -- monotonic
  local text, colour = collog.label_for("Pet", "Boss", { Boss = { Pet = pet } }, function() return 2000 end, true)
  eq(text, "55%"); eq(colour, 0xFFD700FF)
end)

test("collog: a short page title finds the kill count stored under the full NPC name", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Telos, the Warden", "100")
  env.clog.show("Telos", { { obj = 70001, missing = true } })   -- Tess, Telos's pet
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  assert(labels[1].content:find("%%$"), "a percentage: " .. labels[1].content)
end)

test("collog: 'Nex, Angel of Death' does not pick up the plain 'Nex' kill count", function()
  local rates = require("rates").rates
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Nex", "10")
  env.kill("Nex, Angel of Death", "99")
  env.clog.show("Nex, Angel of Death", { { obj = 70002, missing = true } }) -- Reeves
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  eq(labels[1].content, collog.format_percent(collog.dry_probability(rates["Nex, Angel of Death"]["Reeves"], 99)))
end)
test("collog: label is P(X <= count) for X ~ Binomial(kills, rate), using the count shown on the item", function()
  local rates = { Boss = { Thing = 0.01 } }
  local function label(missing, count)
    return collog.label_for("Thing", "Boss", rates, function() return 100 end, missing, count)
  end
  eq((label(true)), pct(exact_cdf(100, 0.01, 0)))        -- missing: k = 0, the plain dry chance 0.99^100 = 37%
  eq((label(true)), "37%")
  eq((label(false, 1)), pct(exact_cdf(100, 0.01, 1)))    -- one drop: 74%
  eq((label(false, 1)), "74%")
  eq((label(false)), "74%")                              -- owned with no readable count counts as 1
  eq((label(false, 3)), pct(exact_cdf(100, 0.01, 3)))    -- three drops (above the mean of 1): lucky, 98%
  eq((label(false, 3)), "98%")
  local _, colour = label(false, 3)
  eq(colour, 0x7FE08FFF)
  eq(collog.format_percent(0.9992), ">99%")
  eq(collog.format_percent(1), "100%")
end)

test("plugin files are plain UTF-8 without a byte-order mark (the client's loader rejects a BOM)", function()
  for _, name in ipairs({ "main", "adapter", "collog", "config", "core", "rates", "ui", "killvars" }) do
    local fh = assert(io.open("plugin/drop_tracker_rs/" .. name .. ".lua", "rb"))
    local head = fh:read(3)
    fh:close()
    assert(head ~= "\239\187\191", name .. ".lua starts with a UTF-8 BOM")
  end
end)

local killvars = require("killvars")

test("killvars: names and titles resolve to the right variable", function()
  eq(killvars.entry_for("Ivar, King of Bones").normal, "WENDLE_GIANT_BOSS")
  eq(killvars.entry_for("Ivar").normal, "WENDLE_GIANT_BOSS")
  eq(killvars.entry_for("Vindicta").normal, "VINDICTA")
  eq(killvars.entry_for("x", "Vindicta & Gorvek").normal, "VINDICTA")
  eq(killvars.entry_for("Nex").normal, "GWD_NEX")
  eq(killvars.entry_for("Nex, Angel of Death").normal, "NEX2")
  eq(killvars.entry_for("Nope", "Zilyana"), nil, "no loose substring matches")
  eq(killvars.entry_for("Nope", "Kerapac").normal, "EGWD_JAS_BOSS") -- title prefix of "Kerapac, the Bound"
  eq(killvars.entry_for("General Graardor").hard, "GWD_GRAARDOR_HARDMODE")
end)

test("every page's kill count matches what the Boss kills tab shows (values from a real account)", function()
  -- variable values as read in game, and the counts shown on Adventures > Beasts > Boss kills
  local vars = {
    SLISKE = 280, SLISKE_HARDMODE = 8, STALKER_BOSS = 105, GWD2_SOLO_BOSS = 38, MENAPHOS_SLAYER_BOSS = 144,
    DINO_BOSS_DUO = 72, DINO_BOSS_SOLO = 140, EGWD_ZAMORAK_BOSS = 68, EGWD_ZAMORAK_BOSS_SOLO = 33,
    DUNGEON_DRAGONFORT1 = 8, DUNGEON_DRAGONFORT1_SOLO = 27, DUNGEON_AMINISHI1 = 7, DUNGEON_AMINISHI1_SOLO = 18,
    DUNGEON_ULTHVEN1 = 9, DUNGEON_ULTHVEN1_SOLO = 18,
    RAID_REBIRTH1_BEAST_BOSS = 9, RAID_REBIRTH1_SLAYER_MASTER_BOSS = 9, RAID_REBIRTH1_WYRM_BOSS = 9,
    RAID_REBIRTH1_BEAST_BOSS_HARDMODE = 237, RAID_REBIRTH1_SLAYER_MASTER_BOSS_HARDMODE = 236,
    RAID_REBIRTH1_WYRM_BOSS_HARDMODE = 237, BEASTMASTER = 31, YAKAMARU = 1,
    EGWD_BIK_BOSS = 135, EGWD_JAS_BOSS = 273, EGWD_JAS_BOSS_HARDMODE = 299, EGWD_FUL_BOSS = 5,
    EGWD_FUL_BOSS_HARDMODE = 157, WENDLE_HEDGEHOG_BOSS = 25, WENDLE_GIANT_BOSS = 60,
  }
  local G = { var = { VarPlayer = setmetatable({}, { __index = function(_, name)
    local short = name:gsub("^BSLAY_KILLS_", "")
    if vars[short] == nil then error("no such variable " .. name) end
    return { value = vars[short] }
  end }) } }
  local cases = {
    { "Gregorovic", 280, 8 }, { "Flesh-hatcher Mhekarnahz", 105, 0 }, { "Telos", 38, 0 }, { "The Magister", 144, 0 },
    { "Raksha", 212, 0 }, { "Zamorak", 101, 0 }, { "Dragonkin Laboratory", 35, 0 }, { "Temple of Aminishi", 25, 0 },
    { "The Shadow Reef", 27, 0 }, { "Sanctum of Rebirth", 27, 710 }, { "Liberation of Mazcab", 32, 0 },
    { "Croesus", 135, 0 }, { "Kerapac", 273, 299 }, { "TzKal-Zuk", 5, 157 }, { "Silverquill", 25, 0 },
    { "Ivar", 60, 0 },
  }
  for _, c in ipairs(cases) do
    local normal, hard = killvars.counts(G, c[1], c[1])
    eq(normal, c[2], c[1] .. " normal")
    eq(hard, c[3], c[1] .. " hard")
  end
  -- the full names kill messages use find the same entries
  eq((killvars.counts(G, "Telos, the Warden")), 38)
  eq((killvars.counts(G, "Raksha, the Shadow Colossus")), 212)
  eq((killvars.counts(G, "Zamorak, Lord of Chaos")), 101)
  -- a summed entry has no single kill message to compare with, so it never raises a mismatch
  eq(killvars.check(G, "Raksha, the Shadow Colossus", 72), nil)
  -- Legiones and Rex Matriarchs stay unmapped
  eq(killvars.counts(G, "Legiones", "Legiones"), nil)
end)

test("Telos reads its kill count from the game variable and labels its pet without a kill", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GWD2_SOLO_BOSS = 38
  env.clog.show("Telos", { { obj = 70001, x = 13, missing = true } })   -- Tess
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  assert(labels[1].content:find("%%$"), "a percentage: " .. labels[1].content)
end)

test("kill counts come from the game's variables, with no kill message needed", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60            -- Ivar's count, never killed this session
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })   -- Magic skull mask
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  eq(labels[1].content, pct(exact_cdf(60, 1 / 64, 0)))
end)

test("the variable wins over a stored kill message, and messages are the fallback", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")                  -- message count 55
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60            -- game says 60
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(2)
  eq(env.live_labels()[1].content, pct(exact_cdf(60, 1 / 64, 0)))
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 0             -- variable unreadable/zero: fall back to the message
  env.clog.show("Ivar", { { obj = 60336, x = 56, missing = true } })  -- (a changed slot forces a rescan)
  env.tick(2)
  eq(env.live_labels()[1].content, pct(exact_cdf(55, 1 / 64, 0)))
end)

test("a boss killed only in hard mode (Giant Mole: normal 0, hard 46) still gets its pet labelled", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GIANTMOLE = 0
  env.vars.BSLAY_KILLS_GIANTMOLE_HARDMODE = 46
  env.clog.show("Giant Mole", { { obj = 70003, x = 13, missing = true } })   -- Molly
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  -- 46 hard kills, one block (threshold 500), hard base 1/500: (1 - 1/500)^46
  eq(labels[1].content, pct(exact_cdf(46, 1 / 500, 0)))
  local normal, hard = killvars.counts({ var = { VarPlayer = setmetatable({}, { __index = function(_, n)
    return { value = ({ BSLAY_KILLS_GIANTMOLE = 0, BSLAY_KILLS_GIANTMOLE_HARDMODE = 46 })[n] } end }) } }, "Giant Mole")
  eq(normal, 0); eq(hard, 46)
end)

test("collog: a pet's hard-mode kills use the hard-mode base within the same threshold blocks", function()
  local pet = { base = 0.01, threshold = 50, hard_base = 0.02 }
  -- 100 kills, 50 of them hard: each block of 50 has 25 normal and 25 hard kills
  local expected = (0.99 ^ 25) * (0.98 ^ 25) * (0.98 ^ 25) * (0.96 ^ 25)
  assert(math.abs(collog.cdf(pet, 100, 0, 50) - expected) < 1e-12)
  -- with no hard kills it is the old normal-only result
  assert(math.abs(collog.cdf(pet, 100, 0, 0) - (0.99 ^ 50) * (0.98 ^ 50)) < 1e-12)
  -- a pet without a hard_base treats hard kills like normal ones
  assert(math.abs(collog.cdf({ base = 0.01, threshold = 50 }, 100, 0, 50) - (0.99 ^ 50) * (0.98 ^ 50)) < 1e-12)
  -- hard kills make the pet more likely, so being dry is less likely
  assert(collog.cdf(pet, 100, 0, 100) < collog.cdf(pet, 100, 0, 0))
end)

test("Legiones and Rex Matriarchs get no percentages: no rates and no kill variable for either page", function()
  local rates = require("rates").rates
  eq(rates["Legiones"], nil)
  eq(rates["Rex Matriarchs"], nil)
  for _, name in ipairs({ "Legio Primus", "Legio Secundus", "Legio Tertius", "Legio Quartus", "Legio Quintus", "Legio Sextus" }) do
    eq(rates[name], nil, name .. " (the server file names the Legios individually)")
  end
  for boss, items in pairs(rates) do
    for item in pairs(items) do
      assert(not item:find("^Ascension signet"), "Legio item still has a rate: " .. boss .. " / " .. item)
      assert(item ~= "Legio primulus" and item ~= "Bagra" and item ~= "Corbi" and item ~= "Pavo", item)
    end
  end
  eq(killvars.entry_for("Legiones", "Legiones"), nil)
  eq(killvars.entry_for("Rex Matriarchs", "Rex Matriarchs"), nil)
  -- the server still tracks them: rare_drops.json is untouched (display-only change)
  local fh = assert(io.open("rare_drops.json", "rb"))
  local text = fh:read("a")
  fh:close()
  assert(text:find('"Rex Matriarchs"', 1, true) and text:find('"Legio Primus"', 1, true), "server allowlist kept")
end)

test("a rate with several independent rolls per kill is a binomial over kills * rolls", function()
  local rolled = { rate = 1 / 5400, rolls = 12 }
  assert(math.abs(collog.cdf(rolled, 135, 0) - exact_cdf(135 * 12, 1 / 5400, 0)) < 1e-12)
  assert(math.abs(collog.cdf(rolled, 135, 2) - exact_cdf(135 * 12, 1 / 5400, 2)) < 1e-12)
  -- twelve rolls per kill is much more likely to drop than one: being dry is less likely
  assert(collog.cdf(rolled, 135, 0) < collog.cdf(1 / 5400, 135, 0))
  assert(math.abs(collog.cdf(rolled, 135, 0) - 0.7408) < 0.001)      -- about 74%, as the wiki's 1/441 per kill gives
  eq(pct(collog.cdf(rolled, 135, 0)), "74%")
end)

test("Croesus uniques use 12 rolls per kill and the pet keeps its own stepped rate", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_EGWD_BIK_BOSS = 135
  env.clog.show("Croesus", { { obj = 70004, x = 13, missing = true }, { obj = 70005, x = 55, missing = true } })
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 2)
  eq(labels[1].content, pct(exact_cdf(135 * 12, 1 / 5400, 0)))     -- sporehammer, missing: 12 rolls a kill
  eq(labels[1].content, "74%")
  eq(labels[2].content, pct(exact_cdf(135, 1 / 1000, 0)))          -- Little sus (1/1000, threshold 500): one block
  -- an owned sporehammer with 2 copies: P(X <= 2) over 1620 rolls
  env.clog.show("Croesus", { { obj = 70004, x = 13, qty = 2 } })
  env.tick(2)
  eq(env.live_labels()[1].content, pct(exact_cdf(135 * 12, 1 / 5400, 2)))
end)

test("a kill message that disagrees with the variable is logged", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GWD_GRAARDOR = 77
  env.kill("General Graardor", "77")                     -- agrees: nothing logged
  for _, l in ipairs(env.logs) do assert(not l:find("mismatch", 1, true), l) end
  env.kill("General Graardor", "80")                     -- disagrees
  local found = false
  for _, l in ipairs(env.logs) do if l:find("kill count mismatch for General Graardor", 1, true) then found = true end end
  assert(found, "mismatch should be logged")
end)

test("'Nex, Angel of Death' and 'Nex' read their own variables", function()
  local rates = require("rates").rates
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GWD_NEX = 229
  env.vars.BSLAY_KILLS_NEX2 = 127
  env.clog.show("Nex, Angel of Death", { { obj = 70002, missing = true } })   -- Reeves
  env.tick(2)
  eq(env.live_labels()[1].content, collog.format_percent(collog.dry_probability(rates["Nex, Angel of Death"]["Reeves"], 127)))
end)
test("collog: labels get ids in their own category so they cannot collide with the game's item slots", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 3)
  local seen = {}
  for _, t in ipairs(labels) do
    eq(t.category, 200, "not the game's category 0")
    assert(t.dynamic >= 0 and t.dynamic <= 255, "the client only accepts ids 0..255, got " .. tostring(t.dynamic))
    assert(not seen[t.dynamic], "dynamic ids are unique among live labels")
    seen[t.dynamic] = true
  end
  -- a relabel (new kill) destroys the old labels first, so the ids start again from 0 instead of growing past 255
  env.kill("Ivar, King of Bones", "128")
  env.tick(2)
  seen = {}
  for _, t in ipairs(env.live_labels()) do
    assert(t.dynamic <= 255 and not seen[t.dynamic], "ids stay in range and unique after a relabel")
    seen[t.dynamic] = true
  end
  for i = 1, 40 do                                    -- many relabels never run out of ids
    env.kill("Ivar, King of Bones", tostring(200 + i))
    env.tick(2)
  end
  for _, t in ipairs(env.live_labels()) do assert(t.dynamic <= 255, "still within 0..255") end
end)

-- Collection-log snapshot sent to the backend (POST /v1/me/collection)
local function body_of(call) return call and call.body or "" end

test("collection snapshot: lifetime kills and how many of each item are sent with the bearer token", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.clog.show("Ivar", { { obj = 60334, x = 13, qty = 3 }, { obj = 60336, x = 55, missing = true },
                          { obj = 60333, x = 97, missing = true } })   -- owned maul x3, missing mask, Colossal bone (no rate)
  env.tick(6)
  local c = env.last_call("/v1/me/collection")
  assert(c, "a snapshot was sent")
  local body = body_of(c)
  eq(c.headers["Authorization"], "Bearer p1.secret")
  has(body, '"boss":"Ivar, King of Bones"'); has(body, '"item":"Bonecrusher maul"')
  has(body, '"kills":60'); has(body, '"hard_kills":0'); has(body, '"count":3')
  has(body, '"item":"Magic skull mask"'); has(body, '"count":0')
  lacks(body, "Colossal bone")                                   -- no rate, so nothing to score
  eq(count(body, '"boss"'), 2, "only the two items that have a rate")
end)

test("collection snapshot: unchanged pages are not sent again, changed ones are", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(6)
  eq(env.calls_to("/v1/me/collection"), 1)
  env.tick(40)
  eq(env.calls_to("/v1/me/collection"), 1, "nothing changed, nothing resent")
  env.clog.rebuild()                                              -- the game clears our labels and we redraw them
  env.tick(10)
  eq(env.calls_to("/v1/me/collection"), 1, "a redraw alone does not resend")
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 61                     -- a kill: the count changes, the percent may not
  env.tick(6)
  eq(env.calls_to("/v1/me/collection"), 2)
  has(body_of(env.last_call("/v1/me/collection")), '"kills":61')
end)

test("collection snapshot: nothing is sent without httpAccess, and it goes out once granted", function()
  local env = new_env(healthy_server(), { clog = true, http = false })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(10)
  eq(#env.calls, 0)
  env.perms.httpAccess = true
  env.tick(6)
  eq(env.calls_to("/v1/me/collection"), 1)
end)

test("collection snapshot: kill and drop events go first, then the snapshot", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.kill("Ivar, King of Bones", "60")
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(8)
  local order = {}
  for _, call in ipairs(env.calls) do order[#order + 1] = call.path end
  local events_at, snapshot_at
  for i, p in ipairs(order) do
    if p == "/v1/events" and not events_at then events_at = i end
    if p == "/v1/me/collection" and not snapshot_at then snapshot_at = i end
  end
  assert(events_at and snapshot_at and events_at < snapshot_at, table.concat(order, " "))
end)

test("collection snapshot: a rejected token re-registers and every entry is sent again", function()
  local inner = healthy_server()
  local rejected = false
  local env = new_env(function(path, ...)
    if path == "/v1/me/collection" and not rejected then rejected = true return 401, "{}" end
    return inner(path, ...)
  end, { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(14)
  eq(env.calls_to("/v1/players"), 2, "registered again after the 401")
  eq(env.last_call("/v1/me/collection").headers["Authorization"], "Bearer p2.secret")
  has(body_of(env.last_call("/v1/me/collection")), '"item":"Magic skull mask"')
end)

test("collection snapshot: a server error is retried with backoff, a rejection is dropped", function()
  local fail = true
  local inner = healthy_server()
  local env = new_env(function(path, ...)
    if path == "/v1/me/collection" and fail then return 503, "{}" end
    return inner(path, ...)
  end, { clog = true })
  env.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(6)
  eq(env.calls_to("/v1/me/collection"), 1)
  env.tick(3)
  eq(env.calls_to("/v1/me/collection"), 1, "backing off")
  fail = false
  env.advance(1000)
  env.tick(2)
  eq(env.calls_to("/v1/me/collection"), 2, "retried after the backoff")
  -- a 4xx is dropped instead of looping forever
  local env2 = new_env(function(path, ...)
    if path == "/v1/me/collection" then return 422, "{}" end
    return inner(path, ...)
  end, { clog = true })
  env2.vars.BSLAY_KILLS_WENDLE_GIANT_BOSS = 60
  env2.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env2.tick(20)
  eq(env2.calls_to("/v1/me/collection"), 1)
end)

test("collection snapshot: pets send both kill counts", function()
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GIANTMOLE = 0
  env.vars.BSLAY_KILLS_GIANTMOLE_HARDMODE = 46
  env.clog.show("Giant Mole", { { obj = 70003, x = 13, missing = true } })   -- Molly
  env.tick(6)
  local body = body_of(env.last_call("/v1/me/collection"))
  has(body, '"item":"Molly"'); has(body, '"kills":0'); has(body, '"hard_kills":46'); has(body, '"count":0')
end)

test("collog: labels the game cleared by rebuilding the page are drawn again, without a reload", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(#env.live_labels(), 3)
  env.clog.rebuild()                                  -- same slots, our labels gone
  eq(#env.live_labels(), 0, "the game removed them")
  env.tick(1)
  eq(#env.live_labels(), 3, "redrawn on the next scan")
  local redraw_logs = 0
  for _, l in ipairs(env.logs) do if l:find("the game cleared the labels on 'Ivar'", 1, true) then redraw_logs = redraw_logs + 1 end end
  eq(redraw_logs, 1)
  -- and it keeps working if the game does that again
  env.clog.rebuild()
  env.tick(1)
  eq(#env.live_labels(), 3)
end)

test("collog: if the layer's iteration never lists our labels, redrawing stops after a few tries", function()
  local env = new_env(healthy_server(), { clog = true })
  env.clog.blind = true
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  env.tick(30)
  local made = env.clog.creations
  assert(made <= 3 * 5, "bounded number of labels created: " .. made)
  env.tick(30)
  eq(env.clog.creations, made, "no further redraws")
  local told = false
  for _, l in ipairs(env.logs) do if l:find("cannot see its own labels", 1, true) then told = true end end
  assert(told, "the situation is logged")
end)

test("collog: with nothing changed the labels are left alone (no redraw churn)", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  local made = env.clog.creations
  env.tick(40)
  eq(env.clog.creations, made, "no labels were recreated while the page sat unchanged")
end)

test("collog: labels from an earlier run left in the layer do not cause endless redraws", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  -- two stray labels in our category that this instance did not create
  for i = 1, 2 do table.insert(env.clog.contents.children, { category = 200, categoryID = 200, content = "old" }) end
  env.tick(2)
  local made = env.clog.creations
  env.tick(30)
  eq(env.clog.creations, made, "orphans are ignored, not redrawn over")
end)

test("collog: relabelling works even when the client frees a destroyed label's id only on the next tick", function()
  local env = new_env(healthy_server(), { clog = true })
  env.clog.hold_ids = true
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  local first = env.live_labels()
  eq(#first, 3)
  local old_ids = {}
  for _, t in ipairs(first) do old_ids[t.dynamic] = true end
  env.kill("Ivar, King of Bones", "128")            -- the kill count changed: every label is replaced in one scan
  env.tick(1)
  local second = env.live_labels()
  eq(#second, 3, "the labels were redrawn straight away, not left missing")
  for _, t in ipairs(second) do assert(not old_ids[t.dynamic], "a just-destroyed id is not reused") end
end)

test("collog: a refused label create is retried on the next scan, so the page does not stay unlabelled", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.fail_creates = 2                          -- the client refuses the first two attempts
  env.clog.show("Ivar", IVAR)
  env.tick(2)                                        -- settles, first attempt fails
  assert(#env.live_labels() < 3, "not drawn yet")
  env.tick(3)                                        -- retries
  eq(#env.live_labels(), 3, "labels appear without reloading the plugin")
  local pages = 0
  for _, l in ipairs(env.logs) do if l:find("collection log page 'Ivar'", 1, true) then pages = pages + 1 end end
  eq(pages, 1, "a retry does not repeat the page log line")
end)

test("collog: a client that always refuses is retried a few times, then given up on", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.fail_creates = 1000
  env.clog.show("Ivar", IVAR)
  env.tick(30)
  eq(#env.live_labels(), 0)
  local gave_up = 0
  for _, l in ipairs(env.logs) do if l:find("gave up labelling 'Ivar' after 5 retries", 1, true) then gave_up = gave_up + 1 end end
  eq(gave_up, 1, "gives up once, instead of retrying every scan forever")
  local before = env.clog.fail_creates
  env.tick(10)
  eq(env.clog.fail_creates, before, "no more attempts after giving up")
  env.clog.fail_creates = 0                           -- the page changes: a new layout is tried afresh
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } })
  env.tick(3)
  eq(#env.live_labels(), 1)
end)

test("collog: the client rejecting a label id is logged and leaves the page alone", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  local real = env.clog_text_new
  env.clog.reject_labels = true
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(#env.live_labels(), 0)
  local logged = false
  for _, l in ipairs(env.logs) do if l:find("collection log label failed", 1, true) then logged = true end end
  assert(logged, "the failure is reported")
end)

test("collog: a page with fewer item slots than its header total is reported", function()
  local env = new_env(healthy_server(), { clog = true })
  env.clog.show("Amascut", { { obj = 60334 }, { obj = 60336, x = 55, missing = true } }, 11) -- header says 3/11, 2 slots
  env.tick(2)
  local warned = false
  for _, l in ipairs(env.logs) do if l:find("has 2 item slots but its header says 11", 1, true) then warned = true end end
  assert(warned, "a missing-slot warning is logged")
  local env2 = new_env(healthy_server(), { clog = true })
  env2.clog.show("Ivar", IVAR)                       -- 4 slots, header total 4
  env2.tick(2)
  for _, l in ipairs(env2.logs) do assert(not l:find("WARNING", 1, true), l) end
end)

test("collog: a new title over the previous page's leftover slots is not labelled (settles in two scans)", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR, 5)               -- header says 5 but 4 slots: half-built, only remembered
  env.tick(1)
  eq(#env.live_labels(), 0, "one sighting of an incomplete page is not enough")
  env.clog.show("Ivar", { { obj = 60336, x = 55, missing = true } }, 5)   -- still rebuilding: layout changed
  env.tick(1)
  eq(#env.live_labels(), 0, "a changed layout starts the count again")
  env.tick(1)                                  -- the same layout twice in a row
  eq(#env.live_labels(), 1)
  local pages = 0
  for _, l in ipairs(env.logs) do if l:find("collection log page 'Ivar'", 1, true) then pages = pages + 1 end end
  eq(pages, 1, "only the settled layout is logged")
end)

test("collog: a complete page (slots match the header total) is labelled on the first scan", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)                  -- 4 slots, header total 4
  env.tick(1)
  eq(#env.live_labels(), 3)
end)

test("collog: the count drawn on a slot becomes k, and the label follows when the count changes", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", { { obj = 60334, x = 13, qty = 3 } })       -- Bonecrusher maul, received 3 times
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 1)
  eq(labels[1].content, pct(exact_cdf(55, 1 / 64, 3)))            -- P(X <= 3), X ~ Binomial(55, 1/64)
  assert(labels[1].content ~= pct(exact_cdf(55, 1 / 64, 1)), "k = 3 differs from k = 1")
  env.clog.show("Ivar", { { obj = 60334, x = 13, qty = 4 } })       -- a fourth copy arrives
  env.tick(2)
  labels = env.live_labels()
  eq(#labels, 1, "the old label was replaced")
  eq(labels[1].content, pct(exact_cdf(55, 1 / 64, 4)))
end)

test("collog: a count in the client's own integer type (not a Lua number) is still read", function()
  local big = setmetatable({}, { __tostring = function() return "8" end }) -- like a Uint64 userdata
  local rates = { Boss = { Thing = 0.01 } }
  local text = collog.label_for("Thing", "Boss", rates, function() return 100 end, false, big)
  eq(text, pct(exact_cdf(100, 0.01, 8)))
  -- unreadable counts fall back to 1 instead of raising
  local bad = setmetatable({}, { __tostring = function() return "not a number" end })
  eq((collog.label_for("Thing", "Boss", rates, function() return 100 end, false, bad)), pct(exact_cdf(100, 0.01, 1)))
  eq((collog.label_for("Thing", "Boss", rates, function() return 100 end, false, nil)), pct(exact_cdf(100, 0.01, 1)))
end)

test("collog: every distinct scan failure is logged once", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.clog.contents.IterateDynamicComponents = function() error("boom A") end
  env.tick(6)
  local n = 0
  for _, l in ipairs(env.logs) do if l:find("collection log scan failed: ", 1, true) and l:find("boom A", 1, true) then n = n + 1 end end
  eq(n, 1, "the same error is not repeated")
  env.clog.contents.IterateDynamicComponents = function() error("boom B") end
  env.tick(2)
  local b = false
  for _, l in ipairs(env.logs) do if l:find("boom B", 1, true) then b = true end end
  assert(b, "a different error is logged")
end)

test("collog: more successes than expected read as lucky, fewer as unlucky", function()
  -- n = 1000, p = 1/100: mean 10
  assert(collog.cdf(0.01, 1000, 3) < 0.05)      -- 3 drops is very unlucky
  assert(math.abs(collog.cdf(0.01, 1000, 10) - exact_cdf(1000, 0.01, 10)) < 1e-9)
  assert(collog.cdf(0.01, 1000, 20) > 0.99)     -- 20 drops is very lucky
  -- the CDF only grows with k and reaches 1 once k >= kills
  assert(collog.cdf(0.2, 5, 1) < collog.cdf(0.2, 5, 2))
  assert(math.abs(collog.cdf(0.2, 5, 5) - 1) < 1e-12)
  assert(math.abs(collog.cdf(0.5, 10, 5) - 0.623046875) < 1e-12)
  assert(math.abs(collog.cdf(0.2, 5, 1) - 0.73728) < 1e-12)
end)

test("collog: stepped pet chance is a sum of binomials, one per threshold block", function()
  local pet = { base = 1 / 100, threshold = 50 }
  -- 100 kills = two blocks of 50: Binomial(50, 1/100) + Binomial(50, 2/100). P(X = 0) is the product.
  assert(math.abs(collog.cdf(pet, 100, 0) - (0.99 ^ 50) * (0.98 ^ 50)) < 1e-12)
  -- P(X <= 1) from the two-block convolution
  local a0, a1 = 0.99 ^ 50, 50 * 0.01 * 0.99 ^ 49
  local b0, b1 = 0.98 ^ 50, 50 * 0.02 * 0.98 ^ 49
  assert(math.abs(collog.cdf(pet, 100, 1) - (a0 * b0 + a0 * b1 + a1 * b0)) < 1e-12)
  -- a single block equals the flat binomial
  assert(math.abs(collog.cdf(pet, 50, 2) - exact_cdf(50, 0.01, 2)) < 1e-12)
  -- zero kills: certainly zero drops
  assert(math.abs(collog.cdf(pet, 0, 0) - 1) < 1e-12)
end)

test("collog: nothing is shown until a kill count is known", function()
  local env = new_env(healthy_server(), { clog = true })
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(#env.live_labels(), 0)
end)

test("collog: labels update with a new kill and disappear when the log closes", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  env.kill("Ivar, King of Bones", "128")
  env.tick(2)
  local labels = env.live_labels()
  eq(#labels, 3)
  eq(labels[1].content, pct(exact_cdf(128, 1 / 64, 1))) -- owned maul, k = 1
  eq(labels[2].content, "13%") -- missing mask: (63/64)^128
  eq(labels[3].content, pct(exact_cdf(128, 1 / 1250, 1))) -- owned pet, k = 1
  env.clog.open = false
  env.tick(2)
  eq(#env.live_labels(), 0)
end)

test("collog: shutdown removes the labels", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Ivar, King of Bones", "55")
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(#env.live_labels(), 3)
  env.app.shutdown()
  eq(#env.live_labels(), 0)
end)

test("kill counts are stored for untracked bosses and under the canonical name", function()
  local env = new_env(healthy_server(), { clog = true })
  env.kill("Kalphite King", "10")          -- has rates, not in the tracked list
  env.kill("Araxxor", "7")                 -- alias of Araxxi
  env.kill("Totally Unknown Boss", "3")    -- no rates: not stored
  has(env.store.boss_kc, "Kalphite King\t10")
  has(env.store.boss_kc, "Araxxi\t7")
  has(env.store.boss_kc, "Totally Unknown Boss\t3") -- every kill message is remembered, rate or not
  eq(env.calls_to("/v1/players"), 0)       -- recording a kc alone sends nothing
end)

test("stored kill counts survive a restart and feed the labels", function()
  local first = new_env(healthy_server(), { clog = true })
  first.kill("Ivar, King of Bones", "55")
  local saved = first.store
  local env = new_env(healthy_server(), { clog = true })
  env.store.boss_kc = saved.boss_kc
  env.app.shutdown()
  env = new_env(healthy_server(), { clog = true, store = saved })
  env.clog.show("Ivar", IVAR)
  env.tick(2)
  eq(#env.live_labels(), 3)
end)

test("a silent permission grant (no event) is still noticed on the next tick", function()
  local env = new_env(healthy_server(), { pretty = true, http = false })
  env.tick()
  has(env.window.texts[1].content, "HTTP permission not granted")
  env.perms.httpAccess = true
  env.tick()
  has(env.window.texts[1].content, "All synced")
  local found = false
  for _, l in ipairs(env.logs) do if l:find("httpAccess is now granted", 1, true) then found = true end end
  assert(found, "grant should be logged")
end)

test("a broken PrettyUI window falls back instead of crashing the plugin", function()
  local env = new_env(healthy_server(), { chat_out = true })
  -- re-run start with a PrettyUI whose Window.new errors
  local G2 = { PrettyUI = { Window = { new = function() error("boom") end } }, ui = { Interfaces = { GetComponent = function() return {} end } }, id = { Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 1 } } }
  local logs = {}
  local p = ui.new(G2, function(m) logs[#logs + 1] = m end)
  p.notify("hello")
  has(logs[1], "PrettyUI window failed")
  eq(logs[2], "hello")
end)

-- Enrage bosses: the player picks how they farm each one and the labels score every kill that way.
local strategies = require("rates").strategies
local function option_rate(group, id, page, item)
  for _, o in ipairs(strategies[group].options) do
    if o.id == id then return o.rates[page][item] end
  end
end
local function find_radio(env, group)
  for i, g in ipairs(ui.strategy_groups(strategies)) do
    if g.name == group then return env.window.radios[i] end
  end
end

test("enrage bosses: the window offers one choice per boss, defaulting to the boss's usual option, ending in Off", function()
  local env = new_env(healthy_server(), { pretty = true, clog = true })
  eq(#env.window.radios, 3)
  local telos = find_radio(env, "Telos")
  eq(telos.options.selectedValue, "claim_2449")
  eq(telos.choices[1].value, "claim_2449")
  eq(telos.choices[#telos.choices].value, "off")
  eq(find_radio(env, "Amascut").options.selectedValue, "enrage_500")
  eq(find_radio(env, "Arch-Glacor").options.selectedValue, "claim_1000")
end)

test("enrage bosses: labels use the chosen option's rates, change when it changes, and Off removes them", function()
  local env = new_env(healthy_server(), { pretty = true, clog = true })
  env.vars.BSLAY_KILLS_GWD2_SOLO_BOSS = 100
  env.vars.BSLAY_KILLS_EGWD_BIK_BOSS = 0
  local function label()
    env.clog.show("Telos, the Warden", { { obj = 70006, missing = true } })   -- Dormant Zaros godsword
    env.tick(3)
    local l = env.live_labels()
    return l[1] and l[1].content
  end
  local best = option_rate("Telos", "claim_2449", "Telos, the Warden", "Dormant Zaros godsword")
  eq(label(), pct(exact_cdf(100, best, 0)))
  find_radio(env, "Telos").options.onChange(nil, "claim_0")
  local worst = option_rate("Telos", "claim_0", "Telos, the Warden", "Dormant Zaros godsword")
  eq(env.store.strategy, "Telos\tclaim_0")
  eq(label(), pct(exact_cdf(100, worst, 0)))
  assert(pct(exact_cdf(100, best, 0)) ~= pct(exact_cdf(100, worst, 0)), "the two options must differ")
  find_radio(env, "Telos").options.onChange(nil, "off")
  eq(label(), nil, "Off leaves the enrage-dependent item unlabelled")
end)

test("enrage bosses: the choice survives a restart", function()
  local store = {}
  local env = new_env(healthy_server(), { pretty = true, clog = true, store = store })
  find_radio(env, "Amascut").options.onChange(nil, "enrage_1000")
  local env2 = new_env(healthy_server(), { pretty = true, clog = true, store = store })
  eq(find_radio(env2, "Amascut").options.selectedValue, "enrage_1000")
  env2.vars.BSLAY_KILLS_AMASCUT_BOSS = 80
  env2.clog.show("Amascut, the Devourer", { { obj = 70007, missing = true } })   -- Devourer's Guard
  env2.tick(3)
  eq(env2.live_labels()[1].content, pct(exact_cdf(80, option_rate("Amascut", "enrage_1000", "Amascut, the Devourer", "Devourer's Guard"), 0)))
end)

test("enrage bosses: a window without radio buttons still shows the kill list", function()
  local env = new_env(healthy_server(), { pretty = true })
  env.kill("Ivar, King of Bones", "49")
  has(env.window.texts[#env.window.texts].content, "Ivar, King of Bones")
end)

test("shared drops: Godsword shards are scored over all four GWD1 bosses' kills, on every page, but not Nex's", function()
  local rates = require("rates").rates
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_GWD_GRAARDOR, env.vars.BSLAY_KILLS_GWD_ZILYANA = 77, 50
  env.vars.BSLAY_KILLS_GWD_KRIL, env.vars.BSLAY_KILLS_GWD_KREEARRA, env.vars.BSLAY_KILLS_GWD_NEX = 30, 20, 500
  local p = rates["General Graardor"]["Godsword shard 1"]
  for _, title in ipairs({ "General Graardor", "Kree'arra" }) do
    env.clog.show(title, { { obj = 70008, missing = true } })
    env.tick(3)
    eq(env.live_labels()[1].content, pct(exact_cdf(77 + 50 + 30 + 20, p, 0)), title)
  end
  env.clog.show("General Graardor", { { obj = 70008, qty = 2 } })       -- two shards owned
  env.tick(3)
  eq(env.live_labels()[1].content, pct(exact_cdf(177, p, 2)))
end)

test("shared drops: GWD2 dormant anima cores add up Helwyr, Vindicta, the Twins and Gregorovic (each at its own rate)", function()
  local rates = require("rates").rates
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_HELWYR, env.vars.BSLAY_KILLS_VINDICTA = 100, 50
  env.vars.BSLAY_KILLS_TWINDEMONS, env.vars.BSLAY_KILLS_SLISKE, env.vars.BSLAY_KILLS_GWD2_SOLO_BOSS = 30, 20, 999
  local item = "Dormant anima core body"
  local dry = (1 - rates["Helwyr"][item]) ^ 100 * (1 - rates["Vindicta & Gorvek"][item]) ^ 50
            * (1 - rates["The Twin Furies"][item]) ^ 30 * (1 - rates["Gregorovic"][item]) ^ 20
  env.clog.show("Vindicta & Gorvek", { { obj = 70009, missing = true } })
  env.tick(3)
  eq(env.live_labels()[1].content, pct(dry))
  env.clog.show("Helwyr", { { obj = 70009, missing = true } })
  env.tick(3)
  eq(env.live_labels()[1].content, pct(dry))
  -- the snapshot sent to the backend carries the pooled kills
  env.tick(6)
  has(env.last_call("/v1/me/collection").body, '"kills":200')
end)

test("shared drops: every pooled boss has a rate for the item, and Nex / Telos are not in a pool", function()
  local data = require("rates")
  for item, bosses in pairs(data.shared) do
    for _, b in ipairs(bosses) do assert(data.rates[b] and data.rates[b][item], b .. " has no rate for " .. item) end
    for _, b in ipairs(bosses) do assert(b ~= "Nex" and b ~= "Telos" and b ~= "Telos, the Warden", item) end
  end
end)

test("Osseous reads the Rex Matriarchs' shared kill count from the game variable", function()
  local rates = require("rates").rates
  local env = new_env(healthy_server(), { clog = true })
  env.vars.BSLAY_KILLS_REXKINGS = 2243
  eq(killvars.entry_for("Osseous").normal, "REXKINGS")
  eq(killvars.entry_for("x", "Rex Matriarch: Osseous").normal, "REXKINGS")
  env.clog.show("Osseous", { { obj = 70010, missing = true } })   -- Savage plume (shared by all four)
  env.tick(3)
  eq(env.live_labels()[1].content, collog.format_percent(collog.dry_probability(rates["Osseous"]["Savage plume"], 2243)))
  eq(rates["Osseous"]["Baby osseous"], nil, "Osseous' pet is deliberately not labelled")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)






