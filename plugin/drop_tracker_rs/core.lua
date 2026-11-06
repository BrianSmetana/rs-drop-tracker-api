-- Drop Tracker core: queues kill/drop events and ships them to the Drop Tracker API.
-- Host-agnostic: everything game- or platform-specific comes in through the `host` table:
--   host.http_post(url, headers, body, callback)   callback(status, response_body); status nil on network error
--   host.storage_get(key) / host.storage_set(key, value)   persistent string storage
--   host.now()                                     seconds (monotonic or wall clock)
--   host.random_hex(n)                             n random hex chars (for event ids)
--   host.log(msg)

local M = {}

local MAX_BATCH = 500        -- API limit per request
local MAX_QUEUE = 5000       -- drop oldest events beyond this
local BASE_BACKOFF = 5       -- seconds
local MAX_BACKOFF = 600

-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects).
local function encode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local out = {}
      for i, x in ipairs(v) do out[i] = encode(x) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local out = {}
    for k, x in pairs(v) do out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x) end
    table.sort(out)
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end
M._encode = encode

function M.new(host, cfg)
  assert(cfg.api_url, "cfg.api_url required")
  local self = {
    queue = {},
    inflight = false,
    failures = 0,
    next_try = 0,
    token = (host.storage_get("token") ~= "" and host.storage_get("token")) or nil, -- "" means cleared
    counter = tonumber(host.storage_get("counter")) or 0,
    session = host.random_hex(8),
    registering = false,
    collection_latest = {}, -- "boss|item" -> JSON of the newest collection-log snapshot entry
    collection_pending = {}, -- the entries the server has not acknowledged yet
  }
  local base = cfg.api_url:gsub("/+$", "")

  -- A new player id (after a 401) has none of our collection data, so send everything again.
  local function resend_collection()
    self.collection_pending = {}
    for key, json in pairs(self.collection_latest) do self.collection_pending[key] = json end
  end

  -- Queue survives restarts so nothing is lost while offline.
  local saved = host.storage_get("queue")
  if saved and saved ~= "" then
    -- stored as one JSON object per line
    for line in saved:gmatch("[^\n]+") do self.queue[#self.queue + 1] = line end
  end

  local function persist()
    host.storage_set("queue", table.concat(self.queue, "\n"))
    host.storage_set("counter", tostring(self.counter))
  end

  local function event_id()
    self.counter = self.counter + 1
    return self.session .. "-" .. self.counter
  end

  local function push(ev)
    ev.event_id = event_id()
    self.queue[#self.queue + 1] = encode(ev)
    if #self.queue > MAX_QUEUE then table.remove(self.queue, 1) end
    persist()
  end

  --- Call when the in-game kill count for `boss` goes up. `kc` is the count AFTER the kill.
  --- `enrage` (whole percent, optional) is the enrage of that kill; bosses like Telos, Arch-Glacor, Zamorak and
  --- Amascut have rare-drop chances that depend on it, so pass it whenever the boss has an enrage.
  --- `streak` (optional) is the boss's killstreak INCLUDING this kill (kills since loot was last claimed); Telos and
  --- Arch-Glacor scale their unique chance with it. Zamorak's bad-luck mitigation needs nothing extra: the server
  --- works it out from the kills and drops already sent.
  function self.on_kill(boss, kc, enrage, streak)
    push({
      type = "kill", boss = boss, kc = kc,
      enrage = enrage and math.floor(enrage) or nil,
      streak = streak and math.floor(streak) or nil,
    })
  end

  --- Call when a tracked item drops. `kc` is the kill count of the kill that produced it.
  function self.on_drop(boss, item, quantity, kc)
    push({ type = "drop", boss = boss, item = item, quantity = quantity or 1, kc = kc })
  end

  --- Collection-log snapshot: lifetime kills and how many of each item the player has, so the server can compute the
  --- same luck figure the in-game label shows. `entries` is a list of { boss, item, kills, hard_kills, count }.
  --- Only new or changed entries are sent; the server replaces what it has, so repeats are harmless.
  function self.set_collection(entries)
    for _, e in ipairs(entries) do
      local json = encode({
        boss = e.boss, item = e.item,
        kills = math.floor(e.kills or 0), hard_kills = math.floor(e.hard_kills or 0), count = math.floor(e.count or 0),
      })
      local key = e.boss .. "|" .. e.item
      if self.collection_latest[key] ~= json then
        self.collection_latest[key] = json
        self.collection_pending[key] = json
      end
    end
  end

  local function register(now)
    if self.registering then return end
    self.registering = true
    host.http_post(base .. "/v1/players", { ["Content-Type"] = "application/json" }, "{}", function(status, body)
      self.registering = false
      local token = status == 201 and body and body:match('"token"%s*:%s*"([^"]+)"')
      if token then
        self.token = token
        host.storage_set("token", token)
      else
        self.failures = self.failures + 1
        self.next_try = now + math.min(MAX_BACKOFF, BASE_BACKOFF * 2 ^ self.failures)
        host.log("registration failed (status " .. tostring(status) .. ")")
      end
    end)
  end

  --- WikiSync-style opt-in: publish stats on the website under `username`. Call with public=false to opt out.
  --- Remembered and re-sent until the server accepts it (also after a re-registration).
  function self.set_profile(username, public)
    self.profile = { username = username, public = public ~= false }
    host.storage_set("profile", encode(self.profile))
    self.profile_sent = false
  end

  local saved_profile = host.storage_get("profile")
  if saved_profile and saved_profile ~= "" then
    local name = saved_profile:match('"username":"(.-)"')
    if name then
      self.profile = { username = name, public = saved_profile:find('"public":true', 1, true) ~= nil }
    end
  end

  local function send_profile(now)
    self.inflight = true
    host.http_post(base .. "/v1/me/profile", {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. self.token,
    }, encode(self.profile), function(status)
      self.inflight = false
      if status == 200 then
        self.profile_sent = true
      elseif status == 401 then
        self.token = nil
        host.storage_set("token", "")
        resend_collection()
      elseif status and status >= 400 and status < 500 then
        self.profile_sent = true -- rejected (e.g. name taken); retrying would fail forever
        host.log("profile rejected (status " .. status .. ")")
      else
        self.failures = self.failures + 1
        self.next_try = now + math.min(MAX_BACKOFF, BASE_BACKOFF * 2 ^ self.failures)
      end
    end)
  end

  local function send_collection(now)
    local keys = {}
    for key in pairs(self.collection_pending) do keys[#keys + 1] = key end
    table.sort(keys)
    local sent, parts = {}, {}
    for i = 1, math.min(#keys, MAX_BATCH) do
      sent[keys[i]] = self.collection_pending[keys[i]]
      parts[i] = sent[keys[i]]
    end
    self.inflight = true
    host.http_post(base .. "/v1/me/collection", {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. self.token,
    }, '{"entries":[' .. table.concat(parts, ",") .. "]}", function(status)
      self.inflight = false
      if status == 200 then
        -- keep any entry that changed again while this request was in flight
        for key, json in pairs(sent) do
          if self.collection_pending[key] == json then self.collection_pending[key] = nil end
        end
        self.failures = 0
      elseif status == 401 then
        self.token = nil
        host.storage_set("token", "")
        resend_collection()
      elseif status and status >= 400 and status < 500 then
        for key in pairs(sent) do self.collection_pending[key] = nil end -- would be rejected forever
        host.log("dropped rejected collection snapshot (status " .. status .. ")")
      else
        self.failures = self.failures + 1
        self.next_try = now + math.min(MAX_BACKOFF, BASE_BACKOFF * 2 ^ self.failures)
      end
    end)
  end

  --- Call periodically (e.g. every second or on a timer). Sends queued events when due.
  function self.tick()
    local now = host.now()
    local need_profile = self.profile and not self.profile_sent
    local need_collection = next(self.collection_pending) ~= nil
    if self.inflight or self.registering or now < self.next_try
      or (#self.queue == 0 and not need_profile and not need_collection) then return end
    if not self.token then return register(now) end
    if need_profile then return send_profile(now) end
    if #self.queue == 0 then return send_collection(now) end -- kill/drop events go first

    local n = math.min(#self.queue, MAX_BATCH)
    local events = table.concat(self.queue, ",", 1, n)
    local body = '{"events":[' .. events .. "]}"
    self.inflight = true
    host.http_post(base .. "/v1/events", {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. self.token,
    }, body, function(status)
      self.inflight = false
      if status == 200 then
        for _ = 1, n do table.remove(self.queue, 1) end
        self.failures = 0
        persist()
      elseif status == 401 then
        -- Token rejected (e.g. server DB reset): re-register; queued events are kept.
        self.token = nil
        host.storage_set("token", "")
        resend_collection()
      elseif status and status >= 400 and status < 500 then
        -- Batch is invalid and would fail forever; drop it so the queue can move on.
        for _ = 1, n do table.remove(self.queue, 1) end
        persist()
        host.log("dropped rejected batch (status " .. status .. ")")
      else
        self.failures = self.failures + 1
        self.next_try = now + math.min(MAX_BACKOFF, BASE_BACKOFF * 2 ^ self.failures)
      end
    end)
  end

  return self
end

return M
