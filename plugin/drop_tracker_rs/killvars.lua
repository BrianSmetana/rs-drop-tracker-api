-- Boss kill counts straight from the game's variables, so the plugin knows them without the player killing anything.
-- The Beasts tab (and so the collection log) keeps them in VarBits named BSLAY_KILLS_<BOSS>, one for normal mode and
-- (where the boss has one) a *_HARDMODE twin. Found with the id probe by matching known counts: General Graardor
-- 77 -> BSLAY_KILLS_GWD_GRAARDOR, Vindicta & Gorvek 1764 -> BSLAY_KILLS_VINDICTA, Ivar 60 -> BSLAY_KILLS_WENDLE_GIANT_BOSS.
-- Every mapping below was then checked against the Adventures > Beasts > Boss kills page (kill counts per boss and per
-- mode shown on screen matched the variable values one for one). A kill message whose count differs from its variable
-- is still logged (see M.check).
--
-- `normal` is the variable suffix after BSLAY_KILLS_; `hard` is its hard-mode twin. Either may be a list of suffixes
-- that are added together (a page of several sub-bosses or modes). Kill messages and the drop rates in rates.lua are
-- normal-mode, so the normal count is what flat-rate labels use.

local M = {}

local ENTRIES = {
  { names = { "Amascut", "Amascut, the Devourer" }, normal = "AMASCUT_BOSS", hard = "AMASCUT_BOSS_HARDMODE" },
  { names = { "Araxxi", "Araxxor" }, normal = "ARAXXI" },
  { names = { "Arch-Glacor" }, normal = "EGWD_WEN_BOSS", hard = "EGWD_WEN_BOSS_HARDMODE" },
  { names = { "The Barrows Brothers", "Barrows brothers" }, normal = "BARROWS" },
  { names = { "The Barrows: Rise of the Six", "Barrows: Rise of the Six", "Barrows - Rise of the Six" },
    normal = "BARROWSROTS" },
  { names = { "Chaos Elemental" }, normal = "CHAOSELEMENTAL" },
  { names = { "Commander Zilyana" }, normal = "GWD_ZILYANA", hard = "GWD_ZILYANA_HARDMODE" },
  { names = { "Corporeal Beast" }, normal = "CORPBEAST" },
  { names = { "Croesus" }, normal = "EGWD_BIK_BOSS" },
  { names = { "Dagannoth Kings" }, normal = "DAGANNOTHKINGS" },
  { names = { "The Gate of Elidinis" }, normal = "ELIDINIS_BOSS" },
  { names = { "General Graardor" }, normal = "GWD_GRAARDOR", hard = "GWD_GRAARDOR_HARDMODE" },
  { names = { "Giant Mole" }, normal = "GIANTMOLE", hard = "GIANTMOLE_HARDMODE" },
  { names = { "Helwyr" }, normal = "HELWYR", hard = "HELWYR_HARDMODE" },
  { names = { "Hermod", "Hermod, the Spirit of War" }, normal = "HERMOD_BOSS" },
  { names = { "Ivar", "Ivar, King of Bones" }, normal = "WENDLE_GIANT_BOSS" },
  { names = { "Silverquill", "Silverquill, the Dreadhog" }, normal = "WENDLE_HEDGEHOG_BOSS" },
  { names = { "Kalphite King" }, normal = "KALPHITEKING" },
  { names = { "Kalphite Queen" }, normal = "KALPHITEQUEEN" },
  { names = { "King Black Dragon" }, normal = "KINGBLACKDRAGON" },
  { names = { "K'ril Tsutsaroth" }, normal = "GWD_KRIL", hard = "GWD_KRIL_HARDMODE" },
  { names = { "Kree'arra" }, normal = "GWD_KREEARRA", hard = "GWD_KREEARRA_HARDMODE" },
  { names = { "Kerapac", "Kerapac, the Bound" }, normal = "EGWD_JAS_BOSS", hard = "EGWD_JAS_BOSS_HARDMODE" },
  { names = { "Nex" }, normal = "GWD_NEX" },
  { names = { "Nex, Angel of Death", "Nex: Angel of Death" }, normal = "NEX2" },
  { names = { "Queen Black Dragon" }, normal = "QUEENBLACKDRAGON" },
  { names = { "Rasial", "Rasial, the First Necromancer" }, normal = "RASIAL_BOSS" },
  { names = { "Solak", "Solak, Guardian of the Grove" }, normal = "SOLAK" },
  { names = { "The Twin Furies", "Twin Furies" }, normal = "TWINDEMONS", hard = "TWINDEMONS_HARDMODE" },
  { names = { "TzKal-Zuk" }, normal = "EGWD_FUL_BOSS", hard = "EGWD_FUL_BOSS_HARDMODE" },
  { names = { "Vindicta & Gorvek", "Vindicta", "Gorvek" }, normal = "VINDICTA", hard = "VINDICTA_HARDMODE" },
  { names = { "Vorago" }, normal = "VORAGO", hard = "VORAGO_HARDMODE" },
  { names = { "Zemouregal & Vorkath" }, normal = "FORT_BOSS_ZEMO_VORKATH", hard = "FORT_BOSS_ZEMO_VORKATH_HARD" },
  { names = { "TzTok-Jad and Har-Aken", "TzTok-Jad" }, normal = "JAD" },
  { names = { "Har-Aken" }, normal = "HARAKEN" },

  -- Added from the Boss kills page (value shown on screen in brackets):
  -- The four Rex Matriarchs share one count (2243), found by the user comparing the Boss kills page with the variable
  { names = { "Osseous", "Rex Matriarch: Osseous" }, normal = "REXKINGS" },
  { names = { "Gregorovic" }, normal = "SLISKE", hard = "SLISKE_HARDMODE" },                  -- 280 / hard 8
  { names = { "Flesh-hatcher Mhekarnahz" }, normal = "STALKER_BOSS" },                        -- 105
  { names = { "Telos", "Telos, the Warden" }, normal = "GWD2_SOLO_BOSS" },                    -- 38
  { names = { "The Magister" }, normal = "MENAPHOS_SLAYER_BOSS" },                            -- 144
  -- Raksha has duo and solo modes only: 72 + 140
  { names = { "Raksha", "Raksha, the Shadow Colossus" }, normal = { "DINO_BOSS_DUO", "DINO_BOSS_SOLO" } },
  -- Zamorak has group and solo modes: 68 + 33
  { names = { "Zamorak", "Zamorak, Lord of Chaos" }, normal = { "EGWD_ZAMORAK_BOSS", "EGWD_ZAMORAK_BOSS_SOLO" } },
  -- Elite dungeons: each boss in a dungeon shows the same group and solo counts (completions), so one boss is read.
  { names = { "Dragonkin Laboratory" }, normal = { "DUNGEON_DRAGONFORT1", "DUNGEON_DRAGONFORT1_SOLO" } },  -- 8 + 27
  { names = { "Temple of Aminishi" }, normal = { "DUNGEON_AMINISHI1", "DUNGEON_AMINISHI1_SOLO" } },        -- 7 + 18
  { names = { "The Shadow Reef" }, normal = { "DUNGEON_ULTHVEN1", "DUNGEON_ULTHVEN1_SOLO" } },            -- 9 + 18
  -- Several bosses whose items drop from any of them: their kills add up (Sanctum 9+9+9 normal, 237+236+237 hard)
  { names = { "Sanctum of Rebirth" },
    normal = { "RAID_REBIRTH1_BEAST_BOSS", "RAID_REBIRTH1_SLAYER_MASTER_BOSS", "RAID_REBIRTH1_WYRM_BOSS" },
    hard = { "RAID_REBIRTH1_BEAST_BOSS_HARDMODE", "RAID_REBIRTH1_SLAYER_MASTER_BOSS_HARDMODE",
             "RAID_REBIRTH1_WYRM_BOSS_HARDMODE" } },
  { names = { "Liberation of Mazcab" }, normal = { "BEASTMASTER", "YAKAMARU" } },                -- 31 + 1
}

local by_name = {}
for _, e in ipairs(ENTRIES) do
  for _, n in ipairs(e.names) do by_name[n:lower()] = e end
end

--- The entry for a boss name or collection-log page title: an exact (case-insensitive) match on either, else the
--- entry whose name starts with the title followed by a comma or space ("Telos" would find "Telos, the Warden").
--- A longer title never matches a shorter name, so "Nex, Angel of Death" does not fall back to plain "Nex".
local entry_cache = {} -- "boss\0title" -> entry or false; the table above never changes, so neither do the answers

function M.entry_for(boss, title)
  local ck = (boss or "") .. "\0" .. (title or "")
  local cached = entry_cache[ck]
  if cached ~= nil then return cached or nil end
  local found
  for _, key in ipairs({ boss, title }) do
    if key and by_name[key:lower()] then found = by_name[key:lower()] break end
  end
  local t = (title or ""):lower()
  if not found and t ~= "" then
    local best_len
    for name, e in pairs(by_name) do
      if name:sub(1, #t) == t and name:sub(#t + 1, #t + 1):match("[, ]") and (not best_len or #name < best_len) then
        found, best_len = e, #name
      end
    end
  end
  entry_cache[ck] = found or false
  return found
end

local function read_var(G, suffix)
  if not suffix or not G.var then return nil end
  local ok, value = pcall(function() return G.var.VarPlayer["BSLAY_KILLS_" .. suffix].value end)
  if not ok or value == nil then return nil end
  return tonumber(value) or tonumber(tostring(value))
end

-- Sum of the readable variables named by `suffixes` (a string or a list of strings), or nil if none can be read.
local function read_sum(G, suffixes)
  if suffixes == nil then return nil end
  if type(suffixes) ~= "table" then suffixes = { suffixes } end
  local total, any = 0, false
  for _, suffix in ipairs(suffixes) do
    local value = read_var(G, suffix)
    if value then total, any = total + value, true end
  end
  return any and total or nil
end

--- Normal-mode and hard-mode kill counts for an entry (either may be nil).
function M.read(G, entry)
  if not entry then return nil end
  return read_sum(G, entry.normal), read_sum(G, entry.hard)
end

--- Normal and hard-mode kill counts for a boss / page title, or nil when the game has no variable we know of or
--- both read 0 (some bosses are only ever killed in hard mode, like the Giant Mole: normal 0, hard 46).
function M.counts(G, boss, title)
  local normal, hard = M.read(G, M.entry_for(boss, title))
  normal, hard = normal or 0, hard or 0
  if normal > 0 or hard > 0 then return normal, hard end
end

--- Cross-check: the count in a kill message should equal the variable's. Returns a warning string, or nil.
function M.check(G, boss, message_kc)
  local entry = M.entry_for(boss, nil)
  if not entry or type(entry.normal) ~= "string" then return nil end -- summed entries have no single message to compare
  local normal = M.read(G, entry)
  if normal and normal ~= message_kc then
    return "kill count mismatch for " .. boss .. ": message says " .. message_kc .. ", BSLAY_KILLS_" ..
      entry.normal .. " is " .. normal .. " (wrong variable?)"
  end
end

return M
