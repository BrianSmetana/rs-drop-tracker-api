-- Test suite for the Drop Tracker plugin against a MOCK RS API and a MOCK Drop Tracker server.
-- Plain Lua 5.1-5.4, no dependencies.  Run from the project root:   lua plugin/test/run.lua
-- The mock `rs` table mirrors the assumptions in adapter.lua; if the real RS API differs,
-- update both adapter.lua and this mock together.

package.path = "./plugin/?.lua;" .. package.path

local core = require("drop_tracker.core")
local adapter = require("drop_tracker.adapter")

---------------------------------------------------------------- mock RS API
-- `server(method_path, headers, body)` returns status, response_body (status nil = network error)
local function new_env(server)
  local env = { calls = {}, logs = {}, permission_requests = {}, clock = 0, store = {} }
  local hooks = {}

  env.rs = {
    log = function(m) env.logs[#env.logs + 1] = m end,
    time = function() return env.clock end,
    storage = {
      get = function(k) return env.store[k] end,
      set = function(k, v) env.store[k] = v end,
    },
    http = {
      post = function(url, headers, body, cb)
        local path = url:gsub("^https?://[^/]+", "")
        env.calls[#env.calls + 1] = { path = path, headers = headers, body = body }
        local status, resp = server(path, headers, body, #env.calls)
        cb(status, resp)
      end,
    },
    permissions = {
      request_http = function(url, reason) env.permission_requests[#env.permission_requests + 1] = url end,
    },
    hooks = {
      on_chat_message = function(f) hooks.chat = f end,
      on_loot = function(f) hooks.loot = f end,
      on_tick = function(f) hooks.tick = f end,
    },
  }

  function env.chat(text) hooks.chat(text) end
  function env.loot(item, qty) hooks.loot(item, qty or 1) end
  function env.tick() hooks.tick() end
  function env.advance(s) env.clock = env.clock + s end
  function env.calls_to(path)
    local n = 0
    for _, c in ipairs(env.calls) do if c.path == path then n = n + 1 end end
    return n
  end
  function env.last_call(path)
    for i = #env.calls, 1, -1 do if env.calls[i].path == path then return env.calls[i] end end
  end

  adapter.start(env.rs)
  return env
end

-- Healthy mock Drop Tracker server.
local function healthy_server()
  local n = 0
  return function(path)
    if path == "/v1/players" then
      n = n + 1
      return 201, '{"player_id":"p' .. n .. '","token":"p' .. n .. '.secret"}'
    elseif path == "/v1/events" then
      return 200, '{"received":1,"accepted":1}'
    end
    return 404, "{}"
  end
end

---------------------------------------------------------------- tiny test runner
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("PASS  " .. name)
  else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function has(s, sub, msg) if not s:find(sub, 1, true) then error((msg or "") .. " missing " .. sub .. " in " .. s, 2) end end
local function lacks(s, sub, msg) if s:find(sub, 1, true) then error((msg or "") .. " unexpected " .. sub .. " in " .. s, 2) end end
local function count(s, sub)
  local pat = (sub:gsub("%p", "%%%0"))   -- parens: gsub returns 2 values
  local n = 0
  for _ in s:gmatch(pat) do n = n + 1 end
  return n
end

---------------------------------------------------------------- tests
test("asks for HTTP permission on start", function()
  local env = new_env(healthy_server())
  eq(#env.permission_requests, 1)
end)

test("kill + tracked drop are registered, batched and sent with the bearer token", function()
  local env = new_env(healthy_server())
  env.chat("Your Har-Aken kill count is: 1.")
  env.loot("Volcanic shard")          -- aliased to Shrimpy
  env.tick()                          -- registers
  env.tick()                          -- sends
  eq(env.calls_to("/v1/players"), 1)
  eq(env.calls_to("/v1/events"), 1)
  local c = env.last_call("/v1/events")
  eq(c.headers["Authorization"], "Bearer p1.secret")
  has(c.body, '"type":"kill"'); has(c.body, '"boss":"Har-Aken"'); has(c.body, '"kc":1')
  has(c.body, '"type":"drop"'); has(c.body, '"item":"Shrimpy"')
  eq(env.store.queue, "", "queue should be empty after success")
end)

test("comma-formatted kill counts are parsed", function()
  local env = new_env(healthy_server())
  env.chat("Your Har-Aken kill count is: 1,234.")
  env.tick(); env.tick()
  has(env.last_call("/v1/events").body, '"kc":1234')
end)

test("untracked bosses and items never leave the client", function()
  local env = new_env(healthy_server())
  env.chat("Your Vorkath kill count is: 5.")
  env.loot("Coins", 1000)
  env.tick(); env.tick()
  eq(#env.calls, 0, "no HTTP calls expected")
end)

test("Barrows uniques are sent, other loot is not", function()
  local env = new_env(healthy_server())
  env.chat("Your The Barrows Brothers kill count is: 10.")
  env.loot("Dharok's helm")
  env.loot("Death rune", 200)
  env.loot("Linza's hammer")
  env.tick(); env.tick()
  local body = env.last_call("/v1/events").body
  has(body, "Dharok's helm"); has(body, "Linza's hammer"); lacks(body, "Death rune")
  eq(count(body, '"type":"drop"'), 2)
end)

test("drops are attributed to the latest kill's boss and kc", function()
  local env = new_env(healthy_server())
  env.chat("Your Har-Aken kill count is: 40.")
  env.chat("Your The Barrows Brothers kill count is: 7.")
  env.loot("Verac's flail")
  env.tick(); env.tick()
  local body = env.last_call("/v1/events").body
  has(body, '"boss":"The Barrows Brothers"'); has(body, '"item":"Verac\'s flail"')
  has(body, '"kc":7')
end)

test("offline: events are kept and retried with backoff", function()
  local online = false
  local inner = healthy_server()
  local env = new_env(function(path, h, b)
    if not online then return nil end
    return inner(path, h, b)
  end)
  env.chat("Your Har-Aken kill count is: 3.")
  env.tick()                          -- registration fails
  eq(env.calls_to("/v1/players"), 1)
  env.tick()                          -- still inside backoff window
  eq(env.calls_to("/v1/players"), 1, "must not retry during backoff")
  online = true
  env.advance(1000)
  env.tick(); env.tick()
  eq(env.calls_to("/v1/events"), 1)
  has(env.last_call("/v1/events").body, '"kc":3')
end)

test("server error on /v1/events keeps the batch for retry", function()
  local fail = true
  local inner = healthy_server()
  local env = new_env(function(path, h, b)
    if path == "/v1/events" and fail then return 503, "{}" end
    return inner(path, h, b)
  end)
  env.chat("Your Har-Aken kill count is: 9.")
  env.tick(); env.tick()              -- register, then 503
  assert(env.store.queue ~= "", "queue must be retained")
  fail = false
  env.advance(1000)
  env.tick()
  eq(env.store.queue, "", "queue should drain after recovery")
  eq(env.calls_to("/v1/events"), 2)
  -- Same event_id on both attempts => server-side idempotency makes the retry safe.
  local ids = {}
  for _, c in ipairs(env.calls) do
    if c.path == "/v1/events" then ids[#ids + 1] = c.body:match('"event_id":"([^"]+)"') end
  end
  eq(ids[1], ids[2], "retry must reuse the same event_id")
end)

test("401 triggers re-registration and the queued events are resent", function()
  local inner = healthy_server()
  local rejected = false
  local env = new_env(function(path, h, b)
    if path == "/v1/events" and not rejected then rejected = true; return 401, "{}" end
    return inner(path, h, b)
  end)
  env.chat("Your Har-Aken kill count is: 2.")
  env.tick(); env.tick()              -- register(p1), events -> 401
  env.tick()                          -- register(p2)
  env.tick()                          -- events with new token
  eq(env.calls_to("/v1/players"), 2)
  eq(env.last_call("/v1/events").headers["Authorization"], "Bearer p2.secret")
  eq(env.store.queue, "")
end)

test("a 4xx batch rejection drops the batch instead of looping forever", function()
  local inner = healthy_server()
  local env = new_env(function(path, h, b)
    if path == "/v1/events" then return 422, "{}" end
    return inner(path, h, b)
  end)
  env.chat("Your Har-Aken kill count is: 1.")
  env.tick(); env.tick()
  eq(env.store.queue, "")
  env.tick()
  eq(env.calls_to("/v1/events"), 1)
end)

test("queue and token survive a restart", function()
  local env = new_env(healthy_server())
  env.chat("Your Har-Aken kill count is: 1.")
  env.tick()                          -- registers; token stored; events still queued
  local token = env.store.token
  assert(token and token ~= "", "token should be stored")
  -- "restart": new tracker over the same storage
  local host = {
    http_post = function() end, now = function() return 0 end, random_hex = function() return "abcd1234" end,
    log = function() end,
    storage_get = function(k) return env.store[k] end,
    storage_set = function(k, v) env.store[k] = v end,
  }
  local t2 = core.new(host, { api_url = "http://x" })
  eq(#t2.queue, 1, "queued event restored")
  eq(t2.token, token, "token restored")
end)

test("large backlog is sent in batches of at most 500", function()
  local env = new_env(healthy_server())
  for i = 1, 1200 do env.chat("Your Har-Aken kill count is: " .. i .. ".") end
  env.tick()                          -- register
  env.tick(); env.tick(); env.tick()
  eq(env.calls_to("/v1/events"), 3)
  for _, c in ipairs(env.calls) do
    if c.path == "/v1/events" then assert(count(c.body, '"type":"kill"') <= 500) end
  end
  eq(env.store.queue, "")
end)

test("JSON encoder escapes special characters", function()
  eq(core._encode('a"b\\c\nd'), '"a\\"b\\\\c\\nd"')
  eq(core._encode({ 1, 2, 3 }), "[1,2,3]")
  eq(core._encode({ a = 1, b = "x" }), '{"a":1,"b":"x"}')
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
