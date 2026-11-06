# RS Drop Tracker API

Backend for a RuneScape API plugin that reports boss kill counts and drops, then
compares each player's drops with the expected rate to give a luck percentile.

**Status:** working prototype. The API has a pytest suite, the plugin has a Lua test harness, and the plugin was tested in the RuneScape beta client. Assumptions still to confirm in game are listed under *Testing in the RS beta client* below.

## Run

```
pip install -r requirements.txt
pytest
uvicorn app.main:app --reload
```

Interactive docs at http://localhost:8000/docs.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/v1/players` | none | Anonymous player id + token (shown once) |
| POST | `/v1/events` | Bearer | Batch of `kill` / `drop` events (idempotent by `event_id`) |
| GET | `/v1/me/luck?boss=&item=` | Bearer | Your drops vs expected, percentile, community rank |
| GET | `/v1/aggregate?boss=&item=&min_kills=50` | none | Pooled observed rate, decile histogram |
| POST | `/v1/me/collection` | Bearer | Collection-log snapshot from the plugin: `{"entries":[{"boss","item","kills","hard_kills","count"}]}` (lifetime kills, how many of the item you have; `count` 0 = missing). Items with no known rate are ignored |
| GET | `/v1/me/collection?boss=` | Bearer | Your lifetime luck per item: `dry_percent` (the in-game label), `percentile`, `community_rank` |

| POST | `/v1/me/profile` | Bearer | Opt in/out of the website: `{"username":"Zezima","public":true}` |
| GET | `/v1/me/summary` | Bearer | All your synced data (works even when not public) |
| GET | `/v1/players/{username}/summary` | none | Public per-boss stats by in-game name; 404 unless the player opted in |

## Website (WikiSync-style)

Modelled on the RS Wiki's WikiSync: the plugin pushes data on its own, the player opts in, and anyone can then look the player up by name with no login. Open `http://localhost:8000/` and enter a name (also works as `/#Zezima`). The page is plain HTML/JS in `app/static/`, served by the same FastAPI process.

- The summary lists every boss in `rare_drops.json`, like a collection log: bosses with kills first (expanded when something dropped), the rest collapsed with their rare items and rates and `has_data: false`. The page has a filter box (boss or item name) and an "only bosses with kills" toggle. Bosses the wiki lists under several names are merged: `Araxxor` into `Araxxi`; `Gorvek`, `Vindicta` and `Gorvek and Vindicta` into `Vindicta & Gorvek`; `Avaryss, the Unceasing` and `Nymora, the Vengeful` into `The Twin Furies`; `Dagannoth Prime`/`Rex`/`Supreme` into `Dagannoth Kings`; `Orikalka`, `Rathis` and `Pthentraken` into `Rex Matriarchs` (Osseous stays separate, as on the wiki); `TzekHaar-Aken` into `TzTok-Jad` (`BOSS_ALIASES` in `tools/curate_rare.py`, stored as `_aliases` in `rare_drops.json`). The server rewrites an alias to the canonical name on events, lookups and, once at startup, on rows already stored, so the plugin may send either. Look-alike bosses with their own kill count and loot (`Nex` vs `Nex, Angel of Death`, the two Kalphite queens, the Legios, Osseous) stay separate.
- Nothing is public until the plugin calls `/v1/me/profile` with `public: true`; setting `false` hides it again. The plugin ties this to a settings tick box (`publish_to_website`).
- Players can also opt in or out from the site itself: open "Opt in / manage my page", paste the plugin token, then set the in-game name and the public tick box. The token is held in page memory only (never stored or put in a URL), and there are no site accounts, so the token is the login.
- Like the hiscores, opted-in data is visible to anyone who knows the name. The website is the one place the otherwise anonymous player id is linked to an in-game name.
- Names are first-come: the first install to claim a name keeps it, and nothing verifies that it is really that player's name (WikiSync-style clients have the same limitation). Add verification before anyone relies on it.

Event examples:

```json
{"type":"kill","event_id":"uuid-1","boss":"example_boss","kc":101}
{"type":"drop","event_id":"uuid-2","boss":"example_boss","item":"example_item","quantity":1,"kc":101}
```

Send a `kill` event for every kill (with the in-game kc after it) and a `drop` for every unique drop.

## Plugin client (`plugin/drop_tracker/`)

Lua, because Jagex has said RS plugins use Lua. **Not run or tested**: no Lua here and the RS API is unpublished.

- `core.lua`: host-independent. Queues events, persists the queue, registers once for a token, batches (500 max), retries with backoff, re-registers on 401. Talks only to the `host` table it is given.
- `adapter.lua`: the only file that touches the game. Every `rs.*` call and the kill-count chat pattern are **assumptions** to replace once the docs are public. It also holds the per-boss list of items that may be sent.

Tests: `lua plugin/test/run.lua` (needs any Lua 5.1-5.4) runs 13 cases against a mock RS API and mock server: tracking filters, batching, offline backoff, 401 re-register, restart persistence. **Written but not yet executed.**

Set `api_url` in `adapter.lua` to wherever the API runs. The plugin must obtain the player's HTTP permission before sending.

## Testing in the RS beta client (`plugin/drop_tracker_rs/`)

The public RS Client API ([docs](https://developer.runescape.com/rs/getting-started.html)) differs from the guesses in `plugin/drop_tracker/adapter.lua`, so `plugin/drop_tracker_rs/` is the version for the real client. `core.lua` there is an unchanged copy of `plugin/drop_tracker/core.lua` (keep them in sync). `lua plugin/test/run_rs.lua` runs 14 cases against mocks of the real API; it does not prove the plugin works in the client.

1. Start the API: `uvicorn app.main:app --reload` (default `http://127.0.0.1:8000`).
2. Edit `plugin/drop_tracker_rs/plugin.json`: set `contactEmailAddress` to a real address. If the API is elsewhere, change `urls.api` there **and** `api_url` in `config.lua` (they must match, no trailing slash).
3. Copy the `drop_tracker_rs` folder to `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\`.
4. In the client console (ALT + backtick): `prf` (refresh), `plist` (should show `drop_tracker_rs`), `pon drop_tracker_rs`. After editing Lua files, `prl drop_tracker_rs`.
5. The plugin sends nothing until `httpAccess` is granted to it, and kill messages need `chatAccess`. Both are `optionalPermissions` in `plugin.json`: tested in the beta client, listing them under `requiredPermissions` made the plugin fail to enable ("This plugin could not be enabled"). The grant itself is not documented, so look for it in the Plugin Hub (gear icon on the plugin); `Plugin.HasPermission` is checked every tick. `main.lua` prints each load step to the console as `[DropTracker] ...`, including whether each permission is granted.
6. Kill a tracked boss, then watch the API log for `POST /v1/players` and `POST /v1/events`, or call `GET /v1/me/summary`.

Unverified assumptions to check in game (each fails silently by sending nothing):

- **Kill-count chat wording.** Confirmed for one boss: `You have killed 48 Ivar, King of Bones in normal mode.` (`kill_patterns` in `config.lua`). Other bosses may word it differently, so add a pattern per format; the boss name must match `rare_drops.json`.
- **Drop wording.** Confirmed in game: `News: Silly Sour has received Ivar's loincloth drop at 54 kills!` (`drop_patterns` in `config.lua`). The line names the player, item and kill count but not the boss, so the plugin finds the boss from the item. It records the drop only for the local player (name from `PlayerEntity.displayName`; if that is unavailable, only when the count equals the latest kill count).
- **`objType.name` on loot.** A second path: `Event.ObjStackEntityAdded` (owner only) reads `event.objType.name`. Unverified; if both paths report the same drop it is counted once.
- **`PlayerEntity.displayName`.** Used for the website name when `publish_to_website = true` in `config.lua`. If it is nil, no profile is sent.

**Friendly output.** `ui.lua` shows a "Drop Tracker" window built on the [PrettyUI](https://developer.runescape.com/rs/getting-started.html) plugin (sync status, per-boss kill count, session kills, drops). PrettyUI is a Hub plugin with ID 6398181; the manifest depends on it as `"requiredDependencies": { "prettyui": 6398181 }`. Tested in the beta client: the same entry under `optionalDependencies` left the `prettyui` global `nil`, and `optionalDependencies` must be a JSON object (an array is rejected: "expected a json Object"). Without PrettyUI enabled the plugin will not load. If the window cannot be built, `ui.lua` falls back to chat lines (needs `chatAccess`).

**Dry % in the Boss Collection Log.** `collog.lua` adds a small label (`NOTOSANS_BOLD_11`), bottom right inside the item's box, on every item with a known rate on a boss page of the collection log (Adventure > Beasts > Boss kills). The figure is `P(X <= k)`, the chance of having *at most* as many drops as you do, where `X ~ Binomial(kills, rate)` and `k` is the number the log draws in the slot's corner (`associatedObjectQuantity`; 0 for a missing item, and 1 for an owned item whose count cannot be read). Low means unlucky and high means lucky: red under 10%, orange under 50%, gold under 90%, green from 90%. For a missing item (`k = 0`) it is the plain dry chance `(1 - rate) ^ kills`, e.g. `42%`; a missing item has never dropped, so its streak is the boss's total kill count. Values above 99.5% show as `>99%`. The plugin learns that count from the kill message, so **kill the boss once after installing** (it is saved to `PersistentDB` and survives restarts). Facts verified in game: the collection log is interface 656; the page title is a dynamic text in layer 11, the item slots are dynamic components in layer 21 with `associatedObjectID` set to the item id, and missing items are drawn dimmed (alpha ~0.84, rgb 0x141414). Item names come from `config.Obj.FromID(id).name`, rates from `rates.lua`, which `python tools/gen_lua_rates.py` generates from `rare_drops.json` (flat-rate items only; enrage and killstreak items are skipped). Items the collection log lists but `rare_drops.json` does not (pets, set pieces, some tertiaries) live in `tools/clog_extra_rates.json`, which `gen_lua_rates.py` merges into `rates.lua` for display only; it does not change what the server accepts. The plugin saves the names it could not label, one line per boss page, under the `clog_unmatched` key in its `PersistentDB`, so gaps can be found by browsing pages in game. `python tools/fetch_clog_extras.py <that list>` fills the extras file from the RuneScape Wiki (wikitext via the MediaWiki API, nothing saved), then re-run `gen_lua_rates.py`. Its rules: lore books are skipped; items that always drop or are commoner than 1 in 5 are skipped; the enrage/killstreak bosses (Telos, Arch-Glacor, Zamorak, Amascut) get no item rates; elite-dungeon items depend on mode and team size so only their pets are included; the four gods' Warpriest pieces are 1/768 each. **Boss pets** use the wiki's bad-luck formula: the chance is `(1 + min(floor(kills / threshold), 9)) / base`, so the count of drops is a sum of independent binomials, one per threshold block, and `collog.cdf` convolves them (truncated at `k`); hard-mode kills are not separated from normal ones. **No percentages on Legiones and Rex Matriarchs.** Each is several sub-bosses with their own items and kill counts, so one page-level count cannot give an item a dry percentage. They are listed in `NO_LABELS` (`tools/gen_lua_rates.py`) and `NO_LABEL_PAGES` (`tools/fetch_clog_extras.py`); this is display only, `rare_drops.json` and server-side tracking are unchanged.

**Croesus** rolls its reward table several times per kill, up to 12 at top contribution, and the wiki lists 1/5400 per roll for each of the nine uniques (its `altrarity` 1/441 is the whole-kill chance at that roll count). The plugin cannot see the contribution factor, so it assumes the best case: 12 independent rolls per kill, i.e. `Binomial(12 x kills, 1/5400)` (`{ rate = 1/5400, rolls = 12 }` in `rates.lua`, set by `ROLLS_PER_KILL` in `tools/fetch_clog_extras.py`). A player whose kills had less contribution has a lower real chance than this assumes, so their dry percentages read slightly worse than the true ones. Not covered (no usable source): Vorago's Omens set (on a separate reward table), Araxxi's egg pets, Vitalis, Bombi, Kerry, Vorkath's rewards, the Rise of the Six bobbleheads and the Legio signets II to VI. Kill counts are matched to a page by exact name, or by a stored NPC name that starts with the page title (`Telos` finds `Telos, the Warden`; `Nex, Angel of Death` does not take plain `Nex`); multi-boss pages such as the Dagannoth Kings or Rex Matriarchs have no single kill count yet.

**Kill counts without killing.** The game keeps boss kill counts in variables named `BSLAY_KILLS_<BOSS>` (a `_HARDMODE` twin where the boss has one), readable with `var.VarPlayer["BSLAY_KILLS_..."].value`. `killvars.lua` maps collection-log page titles and boss names to them, and the labels use that count, so no kill is needed; kill messages remain the fallback for bosses with no mapped variable (only Rex Matriarch: Osseous, plus the deliberately unlabelled Legiones and Rex Matriarchs). Every mapping was checked against the Adventures > Beasts > Boss kills page, whose per-boss and per-mode counts matched the variable values one for one; some bosses are not named after themselves (Ivar is `WENDLE_GIANT_BOSS`, Gregorovic `SLISKE`, Flesh-hatcher Mhekarnahz `STALKER_BOSS`, Telos `GWD2_SOLO_BOSS`, the Magister `MENAPHOS_SLAYER_BOSS`, Raksha `DINO_BOSS_DUO` + `DINO_BOSS_SOLO`). Pages of several sub-bosses or modes add the variables together (Sanctum of Rebirth, Liberation of Mazcab, the elite dungeons' group + solo, Zamorak, Raksha). A kill message whose count differs from its single variable is logged as `kill count mismatch ... (wrong variable?)`. The variables hold the normal-mode count, which is what kill messages report and what the normal-mode drop rates assume, so flat-rate items count normal kills only. Boss pets use normal plus hard kills together for the threshold, as the wiki does, with the hard share using the pet's `hard_base` (e.g. Molly 1/2500 normal, 1/500 hard) and the hard kills assumed spread evenly over the threshold blocks; a boss killed only in hard mode, like the Giant Mole, therefore still gets its pet labelled.

**Permissions from the console.** Use `ppe droptracker httpAccess` and `ppe droptracker chatAccess` to grant them (`ppd` revokes, `ppr` asks the plugin to request what its manifest lists), then `prl droptracker`.

Known gaps: no enrage or killstreak source is known in the public API, so they are never sent. Telos, Arch-Glacor, Zamorak and Amascut score every kill at 0% enrage and their luck numbers are rough. There is no settings UI yet for `publish_to_website`; it is a constant in `config.lua`.

## Lifetime luck: the in-game label and `/v1/me/collection`

The collection-log label and the API return the same number. With `X` the number of drops over your lifetime kills and `k` how many of the item you have (0 if missing):

- **`dry_percent = P(X <= k)`**, the chance of having at most as many drops as you do (low = unlucky, high = lucky). For `k = 0` it is the plain dry chance `(1 - p)^kills`.
- **Flat rate `p`:** `X ~ Binomial(kills, p)`, using normal-mode kills. Multi-roll bosses (Croesus: 12 rolls at 1/5400) use `Binomial(12 x kills, 1/5400)`.
- **Boss pets:** the chance grows with kills, `(1 + min(floor(kills / T), 9)) x base` per kill, so `X` is a sum of independent binomials, one per block of `T` kills (normal + hard kills together; the hard share uses `hard_base`). Computed by convolution.
- **`percentile`** is the mid-p value `P(X < k) + 0.5 P(X = k)`, kept for ranking players (`community_rank`); it is not the label's number (for a missing item it is half of it).
- The plugin sends `{boss, item, kills, hard_kills, count}` from the game's own kill-count variables and the slot counts (`POST /v1/me/collection`), so pre-install drops count. Both sides read the same rate table, built by `app/clog_rates.py` (the plugin's `rates.lua` is generated from it), and `tests/test_collection.py` runs the plugin's Lua and the backend on the same inputs and requires identical results.
- The older `/v1/me/luck` still scores only kills and drops seen since install; it now also returns `dry_percent`, and its pet threshold is capped at 10x like the wiki's.

## How the percentile works

For `n` tracked kills and per-kill chance `p`, drops follow Binomial(n, p). With `k` observed drops,
`percentile = 100 * (P(X<k) + 0.5*P(X=k))`. 50 is average, near 0 is very dry, near 100 is very lucky.

- Tracked kills start at the first kc the player reports, so pre-install kills don't count.
- Each drop event counts once regardless of `quantity` (stack size isn't extra rolls).
- `community_rank` is the share of players with a lower percentile than you.

## Rare drops only

Only rare drops are tracked. `rare_drops.json` is the allowlist: `/v1/events` stores a drop only if its boss/item is listed there, and a kill only if the boss has at least one listed drop; everything else is counted in the response's `ignored` field and discarded. On startup, anything already stored that is not on the list is deleted.

`rare_drops.json` is generated from the full wiki scrape (`wiki_drops_raw.json`) by `python tools/curate_rare.py` (add `--report` to see excluded lines that look rare). A line counts as rare if the wiki lists it in a unique/pre-roll/pet/rare-type table, is rarer than 1/500 (1/150 for tertiaries), or is on a short named list in the script. Nine bosses with no collection-log drops (Abomination, Demon boss, Glod, Giant Sea Snake, Skeletal horror, TokTz-Ket-Dill, Tormented wraith, The Ghrazi Blood Knights, Phoenix) are excluded outright (`EXCLUDED_BOSSES`). Clue scrolls, reroll tokens, seeds, supplies, salvage and stone spirits are excluded. Edit the rules in the script and re-run it; the 823 items kept across 84 bosses are a judgement call, so skim the list for bosses you care about.

## Testing with your own account (CSV import)

The plugin cannot send real data until Jagex publishes the RS API, so `tools/import_account.py` loads an account from a CSV instead (standard library only; the server must be running).

```
python tools/import_account.py --template my_account.csv     # every boss and item, ready to fill in
python tools/import_account.py --dry-run my_account.csv      # check the names, see what would be sent
python tools/import_account.py --register --username "Your Name" my_account.csv
python tools/import_account.py --token <token> my_account.csv   # later runs (or set DROP_TRACKER_TOKEN)
```

Fill `kills` once per boss and `drops` for each item you have; `drop_kcs` (e.g. `230;1040`) is the kill count each drop came at, `first_kc` skips kills made before you want counting, and `enrage` is a typical enrage % for the boss. `examples/example_account.csv` shows the format. Names are checked against `rare_drops.json` (case-insensitive, aliases work) and typos get a suggestion. `--register` prints the token once, so save it. Re-running is safe: events have fixed ids, so the server ignores ones it already has.

What the import cannot know: with no `drop_kcs` the drops are spread evenly across your kills, and with no `enrage` the enrage-based bosses (Telos, Zamorak, Arch-Glacor, Amascut) score every kill at 0%, so their luck numbers are rough. A constant `enrage` is applied to every kill of that boss, and no streaks are sent. The import works against any running server, so use a throwaway database (`DROP_DB=...`) if you do not want test data in `drops.db`.

## Enrage-dependent drops

For Telos, Arch-Glacor, Zamorak and Amascut the chance of a rare drop depends on the kill's enrage. The plugin sends the enrage % on each `kill` event (`"enrage": 1200`); the server scores every kill at its own enrage and combines them (Poisson-binomial), so the luck percentile, expected drops and community aggregate all account for it. A kill with no enrage reported counts as 0%.

In `rare_drops.json` such an item has `"enrage": [[min_enrage_%, rate], ...]` (tiers; the highest tier at or below the kill's enrage applies) or `"enrage_linear": {"base", "per_pct"}`. They are generated by `tools/curate_rare.py` from the boss pages on runescape.wiki:

- **Telos:** tendril 1/1400 below 100% and 1/700 at 100%+ (pet threshold 300). The sword is flat 1/500.
- **Zamorak:** signature chance by enrage tier x each item's share of the unique table (the combined bow share is split evenly over the three pieces; vestments and Chaos Roar split the remainder in their 0-99% ratio, both assumptions).
- **Arch-Glacor (hard mode):** the community formula `(1500 + 15*enrage + 25*streak) / 1,000,000` split 38/38/24 across Leng artefact, Scripture of Wen and Frozen core of Leng. The wiki marks it unconfirmed, and streak is fixed at 1.
- **Amascut:** the wiki's per-tier tables (normal, 100, 500, 750, 1000, 2000%) for the armour/weapons, Shard of Genesis Essence and Devourer's Nexus.

### Streaks and bad-luck mitigation

Items with a `"streak"` rule in `rare_drops.json` change chance with more than enrage. Two kinds:

- **`formula` (Telos, Arch-Glacor):** the unique chance uses the boss's *killstreak* (kills since loot was last claimed; Telos caps it at 200), so the plugin sends `"streak": n` on each `kill` event (n counts the kill itself; omitted = 1). Chance = `min(cap, mult(enrage) * (a + b*enrage + c*streak) / 1e6)`, times each item's share of the unique table. Telos uses `1000 + 25*enrage + 300*streak`, divided by 10 at 25-99% enrage and by 30 below 25%, capped at 1/15. Arch-Glacor uses `1500 + 15*enrage + 25*streak`. Both are community formulas the wiki marks unconfirmed.
- **`blm` (Zamorak):** the plugin sends nothing extra. At 100%+ enrage, after 10 consecutive kills with no signature drop, the signature denominator falls by 1/2/4/8 per further dry kill (by enrage tier) to a floor of 1/20, 1/10 or 1/5. The server counts dry kills from the player's own history and resets on any signature drop. Kills under 100% enrage get no mitigation and have no effect on the counter: they neither add a dry kill nor reset it, even if they drop a signature item.

Telos' unique table is tracked as `Anima orb` (all three orbs, mapped by the plugin; shares are 75/115, 10/115 for each dormant item and the codex), Dormant Seren godbow, Dormant staff of Sliske, Dormant Zaros godsword and Reprisal ability codex. For a mitigation group to work the plugin must report every item in it, since any one resets the counter.

Known limits: dry counts start at 0 on the first tracked kill (pre-install history is unknown); the signature drops are assumed to be the only resets; tier-4 luck, story mode, and chaos die rerolls are ignored. Amascut's rare-table items (Vital spark, Cursed Amascut sand) and tertiaries still use the scrape's flat rates, and Zamorak's Jewels keep separate solo/group entries.

## Before you rely on it

- `wiki_drops_raw.json` was scraped from runescape.wiki (87 bosses, ~2000 items). Only fractional rarities (e.g. `1/128`) were captured; `rolls` is assumed to be 1 and the `table` field shows which drop table a line came from. Verify rolls and mode-specific tables for the bosses you care about.
- Tokens give no protection against fabricated data. Aggregates are only as honest as submitters; add rate limiting and outlier filtering before publishing numbers.
- Once the RS API is public: the plugin must request user permission for HTTP access, and Plugin Moderation will review what it sends. Player ids here are anonymous by design.
- Swap SQLite for Postgres if volume grows; `_tracked` loops per player and would need to become a single grouped query.
