-- Luck percentages on the game's Boss Collection Log (interface 656, found with the id probe).
-- Every item with a known rate gets a small label in the bottom right of its box: P(X <= k), the chance of having
-- AT MOST as many drops as you do, where X ~ Binomial(kills, rate) and k is the number the log shows on the item
-- (0 for a missing item). Low = unlucky, high = lucky. For a missing item (k = 0) that is the plain dry chance,
-- (1 - rate)^kills; a missing item has never dropped, so its streak is the boss's total kill count.
-- Boss pets have a chance that grows with kills, so X is a sum of binomials (one per threshold block), see M.cdf.
--
-- Layout (verified in game): header layer 11 holds the page title as a dynamic text; contents layer 21 holds
-- the item slots as dynamic type-3 components whose associatedObjectID is the item id and whose
-- associatedObjectQuantity is the count drawn in the slot's corner. Missing items are drawn dimmed
-- (rgb 0x141414, alpha ~0.84); owned ones are white with alpha 1.

local M = {}

local IFACE, HEADER, CONTENTS = 656, 11, 21
local TEXT_TYPE = 2
local LABEL_W, LABEL_H = 36, 14 -- sits inside the item's box, bottom right (the top left holds the game's own count)
-- Dynamic-component category for our labels; the game's item slots use category 0. The client only accepts category
-- and dynamic ids from 0 to 255 ("invalid dynamic ID, expected a value between 0 and 256"), so this stays small.
local LABEL_CATEGORY = 200
local MAX_LABELS = 256 -- dynamic ids 0..255 within that category
local MAX_RETRIES = 5 -- attempts to redraw a page's labels after the client refused to create one

-- Binomial(n, p) probabilities for 0..k successes, in log space so long runs cannot underflow early.
local function binomial_pmf(n, p, k)
  local out = {}
  if p <= 0 then
    for j = 0, k do out[j] = (j == 0) and 1 or 0 end
    return out
  end
  if p >= 1 then
    for j = 0, k do out[j] = (j == n) and 1 or 0 end
    return out
  end
  local lp, lq = math.log(p), math.log(1 - p)
  local logpmf = n * lq -- P(X = 0)
  for j = 0, k do
    if j > n then
      out[j] = 0
    else
      out[j] = math.exp(logpmf)
      logpmf = logpmf + math.log((n - j) / (j + 1)) + lp - lq -- P(X = j + 1) from P(X = j)
    end
  end
  return out
end

--- P(X <= k): the chance of at most `k` drops in `kills` kills. `rate` is a per-kill chance (X ~ Binomial), or
--- { base = 1/D, threshold = T, hard_base = 1/H } for a boss pet, whose chance is (1 + min(floor(kills / T), 9)) * base:
--- it steps up by `base` every T kills and caps at 10x, so X is a sum of independent binomials, one per block of T
--- kills; or { rate = p, rolls = r } when each kill makes r independent rolls at chance p (Croesus: 12 at 1/5400, the
--- best case), which is simply Binomial(kills * r, p). For a pet `kills` is normal + hard kills together (the wiki counts them together for the threshold) and
--- `hard_kills` of them were hard mode, which uses `hard_base`; the hard kills are assumed spread evenly over the blocks.
function M.cdf(rate, kills, k, hard_kills)
  return M.cdf_parts({ { rate, kills, hard_kills } }, k)
end

--- P(X <= k) where X adds up several independent parts { rate, kills, hard_kills }, each scored as in M.cdf. Used for
--- an item that several bosses drop and that the log shows as one count (the Godsword shards).
function M.cdf_parts(parts, k)
  k = math.max(0, math.floor(k or 0))
  local dist = { [0] = 1 }
  for j = 1, k do dist[j] = 0 end

  local function add_block(n, p)
    local block, out = binomial_pmf(n, p, k), {}
    for j = 0, k do
      local s = 0
      for a = 0, j do s = s + dist[a] * block[j - a] end
      out[j] = s
    end
    dist = out
  end

  for _, part in ipairs(parts) do
    local rate, kills, hard_kills = part[1], math.max(0, math.floor(part[2])), part[3]
    local hard_share = (kills > 0 and hard_kills) and math.min(1, math.max(0, hard_kills / kills)) or 0
    if type(rate) ~= "table" then
      add_block(kills, rate)
    elseif rate.rolls then
      add_block(kills * rate.rolls, rate.rate) -- several independent rolls per kill: Binomial(kills * rolls, rate)
    else
      local remaining, step = kills, 0
      while remaining > 0 do
        local n = step < 9 and math.min(rate.threshold, remaining) or remaining
        local multiplier = 1 + math.min(step, 9)
        local hard_n = math.floor(n * hard_share + 0.5)
        add_block(n - hard_n, math.min(1, multiplier * rate.base))
        if hard_n > 0 then add_block(hard_n, math.min(1, multiplier * (rate.hard_base or rate.base))) end
        remaining = remaining - n
        step = step + 1
      end
    end
  end

  local total = 0
  for j = 0, k do total = total + dist[j] end
  return math.min(1, total)
end

--- Chance of no drop at all in `kills` kills: M.cdf with k = 0.
function M.dry_probability(rate, kills) return M.cdf(rate, kills, 0) end

function M.format_percent(prob)
  local pct = prob * 100
  if pct > 99.5 and pct < 100 then return ">99%" end -- never round a near-certainty up to "100%"
  if pct >= 10 then return string.format("%d%%", math.floor(pct + 0.5)) end
  if pct >= 0.1 then return string.format("%.1f%%", pct) end
  return "<0.1%"
end

--- Label colour (RGBA): red when very unlucky, orange when unlucky, gold in between, green when lucky.
function M.colour(prob)
  if prob < 0.10 then return 0xFF6B6BFF end
  if prob < 0.50 then return 0xFFA94DFF end
  if prob < 0.90 then return 0xFFD700FF end
  return 0x7FE08FFF
end

-- item -> sorted list of the bosses (keys of `rates`) that drop it. Built once per rates table (a new table, as when the
-- player changes an enrage strategy, gets a new index) so a page only looks up its own items instead of walking every
-- boss's drop table for every slot on every scan.
local index_cache = setmetatable({}, { __mode = "k" })

local function item_index(rates)
  local index = index_cache[rates]
  if index then return index end
  index = {}
  for boss, items in pairs(rates) do
    for item in pairs(items) do
      local list = index[item]
      if not list then list = {} index[item] = list end
      list[#list + 1] = boss
    end
  end
  for _, list in pairs(index) do table.sort(list) end
  index_cache[rates] = index
  return index
end

--- The boss (a key of `rates`) that drops `item`; `title` breaks ties when several bosses share an item name.
function M.resolve_boss(item, title, rates)
  local found = item_index(rates)[item] or {}
  if #found <= 1 then return found[1] end
  local t = (title or ""):lower()
  if t == "" then return nil end
  local best -- an exact match wins; otherwise the longest name that contains the title or is contained by it
  for _, boss in ipairs(found) do
    local b = boss:lower()
    if b == t then return boss end
    if (b:find(t, 1, true) or t:find(b, 1, true)) and (not best or #boss > #best) then best = boss end
  end
  return best
end

--- Label text and colour, or nil when there is no rate or no kill count yet.
--- `count` is the number shown on the item (how many drops you have); a missing item counts as 0 and an owned item
--- with no readable count as 1. The figure is P(X <= count) for X ~ Binomial(kills, rate), see M.cdf.
function M.label_for(item, title, rates, kc_of, missing, count, shared)
  local boss = M.resolve_boss(item, title, rates)
  if not boss then return nil end
  local normal, hard = kc_of(boss, title) -- normal-mode kills, and hard-mode kills where the boss has a hard mode
  normal, hard = tonumber(normal) or 0, tonumber(hard) or 0
  local rate = rates[boss][item]
  -- An item several bosses drop (shared[item] = list of their names) shows one count on every page, so it is scored
  -- over all their normal-mode kills together, each boss at its own rate.
  local pool = shared and shared[item]
  if pool then
    local member = false
    for _, name in ipairs(pool) do if name == boss then member = true end end
    pool = member and pool or nil
  end
  if pool then
    local parts, total = {}, 0
    for _, name in ipairs(pool) do
      local n = tonumber((kc_of(name, name))) or 0
      local r = rates[name] and rates[name][item]
      if r and n > 0 then parts[#parts + 1] = { r, n }; total = total + n end
    end
    if total <= 0 then return nil end
    local n = tonumber(count) or tonumber(tostring(count))
    local k = missing and 0 or math.max(1, math.floor(n or 1))
    local prob = M.cdf_parts(parts, k)
    return M.format_percent(prob), M.colour(prob), { boss = boss, kills = total, hard_kills = hard, count = k }
  end
  -- flat rates are normal-mode chances, so they count normal kills; a pet's threshold counts normal + hard together
  local is_pet = type(rate) == "table" and rate.base ~= nil
  local kc = is_pet and (normal + hard) or normal
  if kc <= 0 then return nil end
  -- the client may hand back its own integer type, so go through tostring; anything unreadable counts as 1
  local n = tonumber(count) or tonumber(tostring(count))
  local k = missing and 0 or math.max(1, math.floor(n or 1))
  local prob = M.cdf(rate, kc, k, hard)
  -- the inputs behind the figure, so they can be sent to the backend: it computes the same number from them
  return M.format_percent(prob), M.colour(prob), { boss = boss, kills = normal, hard_kills = hard, count = k }
end

-- TIMING (temporary, remove after testing): cpu clock and whole-second wall clock, either may be missing in the client
local function cpu_ms() local ok, v = pcall(function() return os.clock() * 1000 end) return ok and v or 0 end
local function wall_s() local ok, v = pcall(function() return os.time() end) return ok and v or 0 end
-- END TIMING

local function get(c, name)
  local ok, v = pcall(function() return c[name] end)
  if ok then return v end
end

local function is_missing(slot)
  local alpha, rgb = get(slot, "alpha"), get(slot, "rgb")
  return (alpha ~= nil and alpha < 0.99) or (rgb ~= nil and rgb ~= 0xFFFFFF)
end

--- ctx = { rates = {boss = {item = rate}}, kc_of = function(boss) -> total kill count or nil, log = function,
---         unmatched = optional function(title, names) called when a page shows items that have no rate,
---         report = optional function(entries) with { boss, item, kills, hard_kills, count } for every labelled item }
--- G needs ui, id, clientConfig (the client's `config`). Returns { tick(), shutdown() }.
function M.new(G, ctx)
  local self = { labels = {}, sig = nil, names = {}, probes = {} }

  local function clear()
    for _, t in ipairs(self.labels) do pcall(function() t:Destroy() end) end
    self.labels = {}
  end

  -- The page title (first non-empty header text) and the item total from the "owned/total" text next to it ("3/11").
  local function page_title(header)
    local title, total
    header:IterateDynamicComponents(function(child)
      if get(child, "type") == TEXT_TYPE then
        local content = tostring(get(child, "content") or "")
        if content ~= "" then
          local have, of = content:match("^(%d+)/(%d+)$")
          if of then total = total or tonumber(of) elseif title == nil then title = content end
        end
      end
      return false
    end)
    return title, total
  end

  local function item_name(obj)
    local ok, name = pcall(function() return G.clientConfig.Obj.FromID(obj).name end)
    return ok and name and tostring(name) or nil
  end

  local function add_label(layer, slot, text, colour)
    -- Explicit ids in a category of our own: without them the client picks a dynamic id itself, which may be one the
    -- game uses for its item slots, so creating or destroying our label could take the game's slot with it (an
    -- Amascut page with 11 items showed 8 after labelling).
    -- Ids rotate through 0..255 instead of restarting at 0: the client may free a destroyed label's id a moment later,
    -- and re-creating a label under an id that was only just destroyed failed ("sometimes percentages only came back
    -- after a reload"). An id is not handed out again until 255 other labels have been created.
    local id = self.next_id or 0
    self.next_id = (id + 1) % MAX_LABELS
    local t = G.ui.Text.new(layer, LABEL_CATEGORY, id)
    t:SetPos(slot.x + slot.width - LABEL_W, slot.y + slot.height - LABEL_H)
    t:SetSize(LABEL_W, LABEL_H)
    t.font = G.id.Font.NOTOSANS_BOLD_11 or G.id.Font.MUSEO_SANS_15PT_REGULAR -- small, like the game's own counts
    t.content = text
    t.rgba = colour
    t.isShadowed = true
    -- right-align inside the box; AlignMode names other than TOPLEFT/CENTRE are unverified, so fall back quietly
    pcall(function()
      local mode = G.ui.AlignMode.BOTTOMRIGHT or G.ui.AlignMode.CENTRE
      t.alignHorizontal = mode
      t.alignVertical = mode
    end)
    self.labels[#self.labels + 1] = t
  end

  local function scan()
    if G.ui.Interfaces:GetInterface(IFACE) == nil then
      if self.sig ~= nil then clear() self.sig = nil end
      self.pending = nil
      self.timing_title = nil -- TIMING
      return
    end
    local header = G.ui.Interfaces:GetComponent(IFACE, HEADER)
    local layer = G.ui.Interfaces:GetComponent(IFACE, CONTENTS)
    if not header or not layer then return end

    local title, total = page_title(header)
    local slots, ours = {}, 0
    layer:IterateDynamicComponents(function(child)
      local obj = get(child, "associatedObjectID")
      if obj ~= nil and obj >= 0 then slots[#slots + 1] = { c = child, obj = obj } end
      if get(child, "categoryID") == LABEL_CATEGORY then ours = ours + 1 end -- our labels still in the layer
      return false
    end)

    -- Cheap pass first: only what the page itself shows (item, dimmed or not, the corner count). Names, drop rates and
    -- kill counts are looked up only once the page has settled, so clicking through bosses costs one full pass per page
    -- and an idle page costs next to nothing per tick.
    local layout = { tostring(title) }
    for i, s in ipairs(slots) do
      s.missing = is_missing(s.c)
      s.count = get(s.c, "associatedObjectQuantity") -- the number drawn in the slot's corner: drops received
      layout[i + 1] = s.obj .. (s.missing and "m" or "o") .. tostring(s.count)
    end

    -- The game changes the page title before it has rebuilt the item slots, so a new title can briefly sit over a
    -- half-built page. Only act on a page layout that shows up unchanged in two scans in a row.
    local layout_key = table.concat(layout, "|")
    -- TIMING: a page's clock starts when its title is first seen; scans are about 0.6 s apart
    self.scan_n = (self.scan_n or 0) + 1
    if self.timing_title ~= tostring(title) then
      self.timing_title, self.t_scan, self.t_wall = tostring(title), self.scan_n, wall_s()
    end
    -- END TIMING
    -- Exception: when the slot count equals the header's "owned/total" the page is complete, so act at once. A stale
    -- page that happens to have the same count is corrected on the next scan, when its layout changes.
    if layout_key ~= self.pending then
      local complete = total ~= nil and #slots > 0 and #slots == total
      self.pending = layout_key
      if not complete then return end
    end
    -- Settled page we already labelled, with our labels still in place and the kill counts behind them unchanged:
    -- nothing to do. Only the few kill counts this page used are re-read, not every item.
    local function kills_sig(probes)
      local out = {}
      for i, p in ipairs(probes) do
        local normal, hard = ctx.kc_of(p[1], p[2])
        out[i] = tostring(normal) .. "/" .. tostring(hard)
      end
      return table.concat(out, ",")
    end
    if layout_key == self.done_layout and self.sig ~= nil and (self.blind or ours >= #self.labels)
        and kills_sig(self.probes) == self.probe_sig then
      return
    end
    self.done_layout = layout_key
    local t_compute = cpu_ms() -- TIMING

    -- kill counts are read once per boss per pass, not once per item
    local kc_memo, probes = {}, {}
    local function kc_of(boss, t)
      local key = tostring(boss) .. "\0" .. tostring(t)
      local m = kc_memo[key]
      if not m then
        local normal, hard = ctx.kc_of(boss, t)
        m = { normal, hard }
        kc_memo[key] = m
        probes[#probes + 1] = { boss, t }
      end
      return m[1], m[2]
    end

    local wanted, sig, unmatched, counts, reports = {}, { tostring(title) }, {}, {}, {}
    for _, s in ipairs(slots) do
      local text, colour, info
      local name = self.names[s.obj]
      if name == nil then
        name = item_name(s.obj) or false -- names never change, so each item is looked up once
        self.names[s.obj] = name
      end
      name = name or nil
      local missing, count = s.missing, s.count
      counts[#counts + 1] = type(count) .. ":" .. tostring(count)
      if name then
        text, colour, info = M.label_for(name, title, ctx.rates, kc_of, missing, count, ctx.shared)
        if info then
          reports[#reports + 1] = { boss = info.boss, item = name, kills = info.kills, hard_kills = info.hard_kills,
                                    count = info.count }
        end
        if not M.resolve_boss(name, title, ctx.rates) then unmatched[#unmatched + 1] = name end
      else
        unmatched[#unmatched + 1] = "item id " .. s.obj
      end
      -- the inputs (kills) are part of the signature, not just the rounded text, so the backend never keeps stale counts
      sig[#sig + 1] = layout[#sig + 1] .. tostring(text) .. (info and (":" .. info.kills .. "/" .. info.hard_kills) or "")
      if text then wanted[#wanted + 1] = { slot = s.c, text = text, colour = colour } end
    end

    self.probes, self.probe_sig = probes, kills_sig(probes)
    local joined = table.concat(sig, "|")
    -- The game can rebuild a page's item slots AFTER we drew (a variable update, a refresh): that clears every dynamic
    -- component in the layer, our labels included, while the layout stays identical. So "nothing changed" is only
    -- true if our labels are still there; if some have gone, draw them again.
    if #self.labels > 0 and ours >= #self.labels then self.redraw_streak = 0 end
    local vanished = not self.blind and joined == self.sig and ours < #self.labels
    if vanished then
      -- If the layer's iteration never lists our labels at all, "missing" would be permanent and we would redraw every
      -- scan. A few redraws in a row that never make them visible mean we cannot see them: stop checking.
      self.redraw_streak = (self.redraw_streak or 0) + 1
      if self.redraw_streak > 3 then
        self.blind, vanished = true, false
        ctx.log("collection log: cannot see its own labels in the layer, no longer redrawing cleared labels")
      end
    end
    if joined == self.sig and not vanished then return end
    self.sig = joined
    -- the same page again, after a failed attempt or after the game cleared our labels: do not repeat the logs
    local retrying = self.retry_key == joined or vanished
    if not retrying then
      -- Items the page shows that have no drop rate on file; lets us see which names to add to rare_drops.json.
      ctx.log("collection log page '" .. tostring(title) .. "': " .. #slots .. " items, " .. #wanted ..
        " labelled, " .. #unmatched .. " without a drop rate; counts " .. table.concat(counts, ","))
      if total and #slots ~= total then -- the header counts every item on the page, so a gap means slots went missing
        ctx.log("WARNING: page '" .. tostring(title) .. "' has " .. #slots .. " item slots but its header says " ..
          total .. " - slots are missing")
      end
      if ctx.unmatched then ctx.unmatched(tostring(title), unmatched) end -- an empty list clears the page's entry
      -- Hand the backend the inputs behind every label (lifetime kills, how many of the item); it dedupes repeats.
      if ctx.report and #reports > 0 then ctx.report(reports) end
    end

    if vanished then
      self.redraws = (self.redraws or 0) + 1
      ctx.log("collection log: the game cleared the labels on '" .. tostring(title) .. "', redrawing (" ..
        self.redraws .. ")")
    end
    local t_draw = cpu_ms() -- TIMING
    clear()
    local failure
    for i, w in ipairs(wanted) do
      if i > MAX_LABELS - 1 then break end -- more labels than ids is not a real page; never wrap onto a live id
      local ok, err = pcall(add_label, layer, w.slot, w.text, w.colour)
      if not ok then failure = err break end
    end
    -- TIMING: scans waited = scans from first sight of the title to this draw (1 = drawn on the first scan)
    ctx.log(string.format("TIMING '%s': %d labels, drawn on scan %d after first sight (~%.1f s), wall %d s, " ..
      "lookup %.1f ms, draw %.1f ms, whole pass %.1f ms%s", tostring(title), #wanted,
      self.scan_n - (self.t_scan or self.scan_n) + 1, (self.scan_n - (self.t_scan or self.scan_n)) * 0.6,
      wall_s() - (self.t_wall or 0), t_draw - t_compute, cpu_ms() - t_draw, cpu_ms() - t_compute,
      failure and (", FAILED: " .. tostring(failure)) or ""))
    -- END TIMING

    if failure then
      -- Do not leave the page half-labelled until something else changes: forget this attempt so the next scan (about
      -- 0.6 s later, with fresh ids) tries again, a few times, then give up and say so.
      self.seen_errors = self.seen_errors or {}
      if not self.seen_errors[tostring(failure)] then
        self.seen_errors[tostring(failure)] = true
        ctx.log("collection log label failed: " .. tostring(failure))
      end
      self.retry_key = joined
      self.retries = (retrying and self.retries or 0) + 1
      if self.retries <= MAX_RETRIES then
        self.sig = nil
      else
        ctx.log("collection log: gave up labelling '" .. tostring(title) .. "' after " .. MAX_RETRIES .. " retries")
      end
    else
      self.retry_key, self.retries = nil, 0
    end
  end

  --- Call every server tick (about every 0.6 s); a page is labelled once two scans in a row agree on its layout.
  function self.tick()
    local ok, err = pcall(scan)
    self.seen_errors = self.seen_errors or {}
    if not ok and not self.seen_errors[tostring(err)] then -- log each distinct failure once, not just the first
      self.seen_errors[tostring(err)] = true
      ctx.log("collection log scan failed: " .. tostring(err))
    end
  end

  function self.shutdown() clear() end
  return self
end

return M
