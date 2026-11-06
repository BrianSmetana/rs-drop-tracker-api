-- v14: finds where the Boss kills / Beasts screens keep their text, in small steps so a slow client does not cut it off.
-- Writes a stage marker as it goes ("probe_stage"), then scans ONE loaded interface per server tick, saving any that
-- contain a boss name ("dump14").
local NEEDLES = { "graardor", "gregorovic", "telos", "raksha", "mhekarnahz", "vorago", "kerapac", "croesus", "helwyr" }
local function stage(m)
  print("[IDProbe] v14 " .. m)
  pcall(function() PersistentDB:SetString("probe_stage", m) end)
end
stage("loading")

local names, ids = {}, {}
pcall(function()
  for k, v in pairs(id.Interface) do
    local iid = type(k) == "number" and k or v
    names[iid] = type(k) == "string" and k or tostring(v)
    ids[#ids + 1] = iid
  end
end)
table.sort(ids)
stage("names built: " .. #ids .. " interfaces")

local statics = {}
pcall(function()
  for combined, cname in pairs(id.Component) do
    if math.type(combined) == "integer" and combined > 0 then
      local iid = combined >> 16
      statics[iid] = statics[iid] or {}
      table.insert(statics[iid], { combined = combined, name = tostring(cname) })
    end
  end
end)
stage("components indexed")

local function prop(c, n) local ok, v = pcall(function() return c[n] end) if ok then return v end end
local function text_of(c)
  local t = prop(c, "content")
  if t ~= nil and tostring(t) ~= "" then return (tostring(t):gsub("[\r\n]", " "):sub(1, 100)) end
end

local function walk(c, label, out, depth)
  if depth > 4 or #out >= 600 then return end
  pcall(function()
    c:IterateStaticComponents(function(ch)
      local t = text_of(ch)
      if t then out[#out + 1] = label .. ">S" .. tostring(prop(ch, "staticID")) .. ": " .. t end
      walk(ch, label, out, depth + 1)
      return false
    end)
  end)
  pcall(function()
    c:IterateDynamicComponents(function(ch)
      local t = text_of(ch)
      if t then out[#out + 1] = label .. ">D" .. tostring(prop(ch, "categoryID")) .. "." .. tostring(prop(ch, "dynamicID")) .. ": " .. t end
      walk(ch, label, out, depth + 1)
      return false
    end)
  end)
end

local function loaded(iid)
  local ok, i = pcall(function() return ui.Interfaces:GetInterface(iid) end)
  return ok and i ~= nil
end

local function scan_interface(iid)
  local out = {}
  for _, s in ipairs(statics[iid] or {}) do
    if #out >= 600 then break end
    local ok, c = pcall(function() return ui.Interfaces:GetComponent(s.combined) end)
    if ok and c then
      local label = "static" .. (s.combined & 0xFFFF) .. " " .. s.name
      local t = text_of(c)
      if t then out[#out + 1] = label .. ": " .. t end
      walk(c, label, out, 1)
    end
  end
  return out
end

local function has_boss(lines)
  for _, l in ipairs(lines) do
    local low = l:lower()
    for _, n in ipairs(NEEDLES) do if low:find(n, 1, true) then return n end end
  end
end

local found, order, cursor, cycle = {}, {}, 0, 0
local current = {}      -- the loaded interfaces this rotation will visit
local ticks, seen_loaded = 0, 0

local function save()
  local out = { "cycles " .. cycle .. ", loaded interfaces last cycle " .. seen_loaded }
  for _, iid in ipairs(order) do out[#out + 1] = found[iid] end
  pcall(function() PersistentDB:SetString("dump14", table.concat(out, "\n\n"):sub(1, 200000)) end)
end

Event.ServerLogic.Subscribe("idprobe14", function()
  ticks = ticks + 1
  if cursor >= #current then            -- start a new rotation: find which interfaces are loaded now
    current = {}
    for _, iid in ipairs(ids) do if loaded(iid) then current[#current + 1] = iid end end
    cursor, cycle, seen_loaded = 0, cycle + 1, #current
    if cycle == 1 then stage("scanning: " .. #current .. " interfaces loaded; open Adventure > Beasts > Boss kills and scroll") end
    save()
    return
  end
  cursor = cursor + 1
  local iid = current[cursor]
  local lines = scan_interface(iid)
  local hit = has_boss(lines)
  if hit then
    local section = "=== interface " .. iid .. " " .. tostring(names[iid]) .. " (matched '" .. hit .. "') ===\n" .. table.concat(lines, "\n")
    if found[iid] ~= section then
      if not found[iid] then order[#order + 1] = iid print("[IDProbe] v14 boss text in interface " .. iid .. " " .. tostring(names[iid])) end
      found[iid] = section
      save()
    end
  end
end)

function PluginShutdown() pcall(function() Event.ServerLogic.Unsubscribe("idprobe14") end) end
stage("running")
