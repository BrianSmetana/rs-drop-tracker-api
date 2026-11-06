"""Collection-log luck: the stats maths, the shared rates module, the /v1/me/collection endpoints, and parity with
the plugin's Lua implementation (plugin/drop_tracker_rs/collog.lua)."""
import json
import math
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import clog_rates, stats

ROOT = Path(__file__).resolve().parent.parent


def exact_cdf(n, p, k):
    """P(X <= k) for Binomial(n, p) by direct summation, independent of app.stats."""
    total = 0.0
    for j in range(min(k, n) + 1):
        total += math.comb(n, j) * p ** j * (1 - p) ** (n - j)
    return total


# --- the maths ---------------------------------------------------------------------------------------------------

def test_missing_item_is_the_plain_dry_chance():
    r = stats.lifetime_luck(1 / 64, kills=55, count=0)
    assert r["p_at_most"] == pytest.approx((63 / 64) ** 55)
    assert r["dry_percent"] == pytest.approx(42.06, abs=0.01)
    # the mid-p percentile used for ranking halves the P(X = 0) term, so it is not the same number
    assert r["percentile"] == pytest.approx(r["dry_percent"] / 2, abs=0.01)


def test_owned_items_use_the_cdf_at_their_count():
    for count in (1, 2, 5):
        r = stats.lifetime_luck(1 / 64, kills=200, count=count)
        assert r["p_at_most"] == pytest.approx(exact_cdf(200, 1 / 64, count), rel=1e-9)
    assert stats.lifetime_luck(1 / 64, 55, 1)["dry_percent"] == pytest.approx(78.77, abs=0.01)


def test_lucky_reads_high_and_unlucky_reads_low():
    assert stats.lifetime_luck(0.01, 1000, 3)["dry_percent"] < 5     # mean 10, only 3
    assert stats.lifetime_luck(0.01, 1000, 20)["dry_percent"] > 99   # mean 10, got 20


def test_multi_roll_is_a_binomial_over_kills_times_rolls():
    spec = {"rate": 1 / 5400, "rolls": 12}
    r = stats.lifetime_luck(spec, kills=135, count=0)
    assert r["p_at_most"] == pytest.approx(exact_cdf(135 * 12, 1 / 5400, 0), rel=1e-9)
    assert r["dry_percent"] == pytest.approx(74.08, abs=0.01)
    r2 = stats.lifetime_luck(spec, kills=135, count=2)
    assert r2["p_at_most"] == pytest.approx(exact_cdf(135 * 12, 1 / 5400, 2), rel=1e-9)
    assert r["expected_drops"] == pytest.approx(135 * 12 / 5400)


def test_pet_is_a_sum_of_binomials_one_per_threshold_block():
    pet = {"base": 1 / 100, "threshold": 50}
    # 100 kills = two blocks of 50: Binomial(50, 1/100) + Binomial(50, 2/100)
    assert stats.lifetime_luck(pet, 100, 0)["p_at_most"] == pytest.approx((0.99 ** 50) * (0.98 ** 50))
    a0, a1 = 0.99 ** 50, 50 * 0.01 * 0.99 ** 49
    b0, b1 = 0.98 ** 50, 50 * 0.02 * 0.98 ** 49
    assert stats.lifetime_luck(pet, 100, 1)["p_at_most"] == pytest.approx(a0 * b0 + a0 * b1 + a1 * b0)
    assert stats.lifetime_luck(pet, 50, 2)["p_at_most"] == pytest.approx(exact_cdf(50, 0.01, 2))


def test_pet_numerator_is_capped_at_ten():
    pet = {"base": 1 / 5000, "threshold": 1000}
    nine_blocks = stats.lifetime_luck(pet, 9000, 0)["p_at_most"]
    # past nine thresholds the numerator stays at 10: the next 1000 kills are all at 10/5000
    assert stats.lifetime_luck(pet, 10000, 0)["p_at_most"] == pytest.approx(nine_blocks * (1 - 10 / 5000) ** 1000)
    assert stats.lifetime_luck(pet, 20000, 0)["p_at_most"] == pytest.approx(nine_blocks * (1 - 10 / 5000) ** 11000)


def test_pet_hard_kills_use_the_hard_base_and_count_towards_the_threshold():
    pet = {"base": 0.01, "threshold": 50, "hard_base": 0.02}
    # 50 normal + 50 hard: kills (for the threshold) = 100; each block of 50 has 25 normal and 25 hard
    r = stats.lifetime_luck(pet, kills=50, hard_kills=50, count=0)
    assert r["p_at_most"] == pytest.approx((0.99 ** 25) * (0.98 ** 25) * (0.98 ** 25) * (0.96 ** 25))
    assert r["kills"] == 50 and r["hard_kills"] == 50
    # hard kills make the pet more likely, so being dry is less likely
    assert stats.lifetime_luck(pet, 0, hard_kills=100, count=0)["p_at_most"] < stats.lifetime_luck(pet, 100, 0, 0)["p_at_most"]
    # a boss killed only in hard mode (normal 0) still scores
    molly = {"base": 0.0004, "threshold": 500, "hard_base": 0.002}
    assert stats.lifetime_luck(molly, kills=0, count=0, hard_kills=46)["p_at_most"] == pytest.approx((1 - 0.002) ** 46)


def test_flat_rates_ignore_hard_kills_like_the_plugin():
    r = stats.lifetime_luck(1 / 100, kills=100, hard_kills=999, count=0)
    assert r["p_at_most"] == pytest.approx(0.99 ** 100)


def test_zero_kills_is_certainly_dry():
    assert stats.lifetime_luck(0.5, 0, 0)["p_at_most"] == pytest.approx(1.0)
    assert stats.lifetime_luck({"base": 0.01, "threshold": 10}, 0, 0)["p_at_most"] == pytest.approx(1.0)


def test_since_install_outputs_now_carry_the_same_dry_percent():
    r = stats.luck(kills=55, drops=0, rate=1 / 64)
    assert r["dry_percent"] == pytest.approx(42.06, abs=0.01)
    t = stats.luck_threshold(1, 100, 1, 0.01, threshold=50)
    assert t["dry_percent"] == pytest.approx(100 * t["p_at_most"], abs=0.01)


def test_since_install_pet_numerator_is_capped_at_ten():
    probs = stats.threshold_probabilities(1, 12000, 1 / 5000, threshold=1000)
    assert probs[0] == pytest.approx(1 / 5000)
    assert probs[9000] == pytest.approx(10 / 5000)       # kill 9001: numerator 10
    assert probs[11999] == pytest.approx(10 / 5000)      # still 10, not 12


# --- shared rates ------------------------------------------------------------------------------------------------

@pytest.fixture
def rate_files(tmp_path):
    rare = tmp_path / "rare.json"
    rare.write_text(json.dumps({
        "_aliases": {"Bee": "Boss"},
        "Boss": {
            "Flat": {"rate": 0.01, "rolls": 1},
            "Multi": {"rate": 0.001, "rolls": 3},
            "Enraged": {"rate": 0.01, "enrage": [[0, 0.01]]},
        },
        "Legiones": {"Signet": {"rate": 0.02, "rolls": 1}},
        "Legio Primus": {"Signet II": {"rate": 0.02, "rolls": 1}},
        "Rex Matriarchs": {"Thing": {"rate": 0.02, "rolls": 1}},
    }))
    extra = tmp_path / "extra.json"
    extra.write_text(json.dumps({
        "_note": "x",
        "Boss": {
            "Flat": {"rate": "1/50"},                                    # wins over rare_drops.json
            "Pet": {"base": "1/500", "threshold": 100, "hard_base": "1/100"},
            "Rolled": {"rate": "1/5400", "rolls": 12},
        },
        "Legiones": {"Pet": {"base": "1/1000", "threshold": 1200}},
    }))
    return rare, extra


def test_rates_module_builds_specs_and_applies_the_rules(rate_files):
    rates, aliases = clog_rates.load(*rate_files)
    assert aliases == {"Bee": "Boss"}
    assert rates["Boss"]["Flat"] == pytest.approx(0.02)                  # extras win
    assert rates["Boss"]["Multi"] == pytest.approx(0.003)                # rare_drops multiplies rate by rolls
    assert "Enraged" not in rates["Boss"]                                # enrage items cannot be scored
    assert rates["Boss"]["Pet"] == {"base": pytest.approx(0.002), "threshold": 100, "hard_base": pytest.approx(0.01)}
    assert rates["Boss"]["Rolled"] == {"rate": pytest.approx(1 / 5400), "rolls": 12}
    for name in ("Legiones", "Legio Primus", "Rex Matriarchs"):          # pages with no percentages
        assert name not in rates


def test_real_rates_files_load_and_match_the_plugins_data():
    rates, aliases = clog_rates.load(ROOT / "rare_drops.json", ROOT / "tools" / "clog_extra_rates.json")
    assert rates["Croesus"]["Croesus sporehammer"] == {"rate": pytest.approx(0.00018519), "rolls": 12}
    assert rates["General Graardor"]["General awwdor"]["hard_base"] == pytest.approx(0.001)
    assert "Legiones" not in rates and "Rex Matriarchs" not in rates
    lua = (ROOT / "plugin" / "drop_tracker_rs" / "rates.lua").read_text(encoding="utf-8")
    count = sum(len(v) for v in rates.values())
    assert lua.count("] = ") >= count   # every item (plus the aliases) appears in the generated Lua


# --- parity with the plugin's Lua ---------------------------------------------------------------------------------

def _lua_literal(spec):
    if not isinstance(spec, dict):
        return repr(float(spec))
    return "{ " + ", ".join(f"{k} = {v!r}" for k, v in spec.items()) + " }"


CASES = [
    (1 / 64, 55, 0, 0), (1 / 64, 55, 1, 0), (1 / 64, 128, 3, 0), (0.01, 1000, 10, 0), (0.2, 5, 1, 0),
    ({"rate": 1 / 5400, "rolls": 12}, 135, 0, 0), ({"rate": 1 / 5400, "rolls": 12}, 135, 2, 0),
    ({"base": 1 / 5000, "threshold": 1000}, 2000, 0, 0), ({"base": 1 / 5000, "threshold": 1000}, 10000, 2, 0),
    ({"base": 0.01, "threshold": 50, "hard_base": 0.02}, 100, 1, 50),
    ({"base": 0.0004, "threshold": 500, "hard_base": 0.002}, 46, 0, 46),
    ({"base": 1 / 300, "threshold": 60}, 35, 0, 0),
]


@pytest.mark.skipif(shutil.which("lua") is None, reason="needs a lua interpreter")
def test_backend_and_plugin_compute_the_same_numbers():
    """The in-game label and the API must agree: run collog.cdf (Lua) and lifetime_luck (Python) on the same inputs.
    Note the Lua cdf takes the kills the spec counts (normal + hard for a pet) plus the hard share."""
    script = ['package.path = "./plugin/drop_tracker_rs/?.lua;" .. package.path', 'local c = require("collog")']
    expected = []
    for spec, kills, count, hard in CASES:
        is_pet = isinstance(spec, dict) and "base" in spec
        lua_kills = kills + hard if is_pet else kills
        script.append(f'print(string.format("%.15g", c.cdf({_lua_literal(spec)}, {lua_kills}, {count}, {hard if is_pet else 0})))')
        expected.append(stats.lifetime_luck(spec, kills, count, hard)["p_at_most"])
    out = subprocess.run(["lua", "-e", "\n".join(script)], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    assert len(out) == len(CASES)
    for got, want, case in zip(out, expected, CASES):
        assert float(got) == pytest.approx(want, rel=1e-9, abs=1e-12), case


# --- end to end: plugin Lua -> backend, on the real rate files ----------------------------------------------------

END_TO_END = [  # (boss as the plugin resolves it, item, normal kills, hard kills, count on the slot, 0 = missing)
    ("Ivar, King of Bones", "Bonecrusher maul", 60, 0, 3),
    ("Ivar, King of Bones", "Magic skull mask", 60, 0, 0),
    ("Croesus", "Croesus sporehammer", 135, 0, 0),
    ("Croesus", "Little sus", 135, 0, 0),
    ("Giant Mole", "Molly", 0, 46, 0),
    ("General Graardor", "General awwdor", 77, 38, 1),
    ("General Graardor", "Warpriest of Bandos helm", 77, 38, 0),
    ("General Graardor", "Bandos hilt", 77, 38, 2),
]


@pytest.mark.skipif(shutil.which("lua") is None, reason="needs a lua interpreter")
def test_plugin_snapshot_is_scored_by_the_backend_exactly_like_the_game_label(tmp_path, monkeypatch):
    # 1. the plugin's own code builds the request body and the label's probability for every entry
    lines = [
        'package.path = "./plugin/drop_tracker_rs/?.lua;" .. package.path',
        'local collog, core, rates = require("collog"), require("core"), require("rates").rates',
        'local captured',
        'local host = {',
        '  http_post = function(url, headers, body, cb)',
        '    if url:find("/v1/players", 1, true) then return cb(201, \'{"token":"t.s"}\') end',
        '    captured = body; cb(200, "{}")',
        '  end,',
        '  storage_get = function() return nil end, storage_set = function() end, now = function() return 0 end,',
        '  random_hex = function() return "abcd1234" end, log = function() end,',
        '}',
        'local tracker = core.new(host, { api_url = "http://x" })',
        'local entries = {}',
    ]
    for boss, item, normal, hard, count in END_TO_END:
        lines.append(
            f'do local r = rates[{json.dumps(boss)}][{json.dumps(item)}]; assert(r, "no rate for {item}")\n'
            f'  local is_pet = type(r) == "table" and r.base ~= nil\n'
            f'  local k = {count}\n'
            f'  local prob = collog.cdf(r, is_pet and {normal + hard} or {normal}, k, {hard})\n'
            f'  print(string.format("%.15g", prob))\n'
            f'  entries[#entries + 1] = {{ boss = {json.dumps(boss)}, item = {json.dumps(item)}, kills = {normal}, '
            f'hard_kills = {hard}, count = k }} end'
        )
    lines += ['tracker.set_collection(entries)', 'for _ = 1, 3 do tracker.tick() end', 'print("BODY " .. captured)']
    out = subprocess.run(["lua", "-e", "\n".join(lines)], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    *prob_lines, body_line = out.strip().splitlines()
    assert body_line.startswith("BODY ")
    plugin_probs = [float(x) for x in prob_lines]
    body = json.loads(body_line[5:])
    assert len(body["entries"]) == len(END_TO_END)

    # 2. the real backend (real rare_drops.json and extras) scores that body
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "e2e.db"))
    from app.main import app
    with TestClient(app) as client:
        reg = client.post("/v1/players").json()
        h = {"Authorization": f"Bearer {reg['token']}"}
        r = client.post("/v1/me/collection", json=body, headers=h).json()
        assert r["accepted"] == len(END_TO_END) and r["ignored"] == 0
        items = {(i["boss"], i["item"]): i for i in client.get("/v1/me/collection", headers=h).json()["items"]}

    # 3. both sides agree on every number
    for (boss, item, *_), prob in zip(END_TO_END, plugin_probs):
        assert items[(boss, item)]["p_at_most"] == pytest.approx(prob, rel=1e-9, abs=1e-12), (boss, item)
        assert items[(boss, item)]["dry_percent"] == pytest.approx(round(100 * prob, 2), abs=0.011), (boss, item)


# --- the endpoints ------------------------------------------------------------------------------------------------

@pytest.fixture
def client(tmp_path, monkeypatch, rate_files):
    rare, extra = rate_files
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rare)
    monkeypatch.setattr("app.main.CLOG_EXTRA_PATH", extra)
    from app.main import app
    with TestClient(app) as c:
        yield c


def _player(client):
    reg = client.post("/v1/players").json()
    return {"Authorization": f"Bearer {reg['token']}"}


def _entry(boss, item, kills, count, hard=0):
    return {"boss": boss, "item": item, "kills": kills, "hard_kills": hard, "count": count}


def test_collection_requires_a_token(client):
    assert client.post("/v1/me/collection", json={"entries": []}).status_code == 401
    assert client.get("/v1/me/collection").status_code == 401
    assert client.get("/v1/me/collection", headers={"Authorization": "Bearer nope.nope"}).status_code == 401


def test_snapshot_is_scored_like_the_game_label(client):
    h = _player(client)
    r = client.post("/v1/me/collection", headers=h, json={"entries": [
        _entry("Boss", "Flat", 55, 0),                       # missing
        _entry("Boss", "Rolled", 135, 0),                    # Croesus-style, 12 rolls
        _entry("Boss", "Pet", 0, 0, hard=46),                # only ever killed in hard mode
        _entry("Boss", "Unknown item", 10, 0),               # no rate: ignored
        _entry("Nobody", "Flat", 10, 0),                     # unknown boss: ignored
        _entry("Legiones", "Pet", 10, 0),                    # a page with no percentages: ignored
    ]}).json()
    assert r == {"received": 6, "accepted": 3, "ignored": 3}

    items = {i["item"]: i for i in client.get("/v1/me/collection", headers=h).json()["items"]}
    assert set(items) == {"Flat", "Rolled", "Pet"}
    assert items["Flat"]["dry_percent"] == pytest.approx(100 * 0.98 ** 55, abs=0.01)     # extras say 1/50 for Flat
    assert items["Rolled"]["dry_percent"] == pytest.approx(74.08, abs=0.01)
    assert items["Pet"]["dry_percent"] == pytest.approx(100 * (1 - 0.01) ** 46, abs=0.01)  # hard_base 1/100
    assert items["Pet"]["kills"] == 0 and items["Pet"]["hard_kills"] == 46
    assert items["Rolled"]["community_players"] == 1 and items["Rolled"]["community_rank"] == 0.0


def test_owned_counts_use_p_at_most_of_the_count(client):
    h = _player(client)
    client.post("/v1/me/collection", headers=h, json={"entries": [_entry("Boss", "Flat", 200, 3)]})
    item = client.get("/v1/me/collection", headers=h).json()["items"][0]
    assert item["dry_percent"] == pytest.approx(100 * exact_cdf(200, 0.02, 3), abs=0.01)
    assert item["count"] == 3
    assert item["expected_drops"] == pytest.approx(200 * 0.02)


def test_resending_replaces_the_snapshot_and_is_idempotent(client):
    h = _player(client)
    body = {"entries": [_entry("Boss", "Flat", 100, 0)]}
    assert client.post("/v1/me/collection", headers=h, json=body).json()["accepted"] == 1
    assert client.post("/v1/me/collection", headers=h, json=body).json()["accepted"] == 1
    assert len(client.get("/v1/me/collection", headers=h).json()["items"]) == 1
    client.post("/v1/me/collection", headers=h, json={"entries": [_entry("Boss", "Flat", 250, 1)]})
    items = client.get("/v1/me/collection", headers=h).json()["items"]
    assert len(items) == 1 and items[0]["kills"] == 250 and items[0]["count"] == 1


def test_alias_boss_names_are_stored_under_the_canonical_name(client):
    h = _player(client)
    assert client.post("/v1/me/collection", headers=h, json={"entries": [_entry("Bee", "Flat", 10, 0)]}).json()["accepted"] == 1
    assert client.get("/v1/me/collection", headers=h).json()["items"][0]["boss"] == "Boss"
    assert len(client.get("/v1/me/collection", headers=h, params={"boss": "Bee"}).json()["items"]) == 1
    assert client.get("/v1/me/collection", headers=h, params={"boss": "Other"}).json()["items"] == []


def test_items_come_back_unluckiest_first(client):
    h = _player(client)
    client.post("/v1/me/collection", headers=h, json={"entries": [
        _entry("Boss", "Flat", 10, 0),         # barely any kills: very likely still dry (high)
        _entry("Boss", "Rolled", 5400, 0),     # 12 rolls * 5400 kills at 1/5400: very unlucky to be dry (low)
    ]})
    items = client.get("/v1/me/collection", headers=h).json()["items"]
    assert [i["item"] for i in items] == ["Rolled", "Flat"]
    assert items[0]["dry_percent"] < items[1]["dry_percent"]


def test_community_rank_compares_players_on_the_same_item(client):
    lucky, unlucky = _player(client), _player(client)
    client.post("/v1/me/collection", headers=lucky, json={"entries": [_entry("Boss", "Flat", 100, 5)]})
    client.post("/v1/me/collection", headers=unlucky, json={"entries": [_entry("Boss", "Flat", 100, 0)]})
    a = client.get("/v1/me/collection", headers=lucky).json()["items"][0]
    b = client.get("/v1/me/collection", headers=unlucky).json()["items"][0]
    assert a["community_players"] == b["community_players"] == 2
    assert a["community_rank"] == 50.0 and b["community_rank"] == 0.0   # share of players with a lower percentile


def test_collection_input_is_validated(client):
    h = _player(client)
    for bad in (_entry("Boss", "Flat", -1, 0), _entry("Boss", "Flat", 10, -1), {"boss": "", "item": "x", "kills": 1, "count": 0}):
        assert client.post("/v1/me/collection", headers=h, json={"entries": [bad]}).status_code == 422
    too_many = {"entries": [_entry("Boss", "Flat", 1, 0)] * 501}
    assert client.post("/v1/me/collection", headers=h, json=too_many).status_code == 422
    # counts are per player: another player does not see yours
    client.post("/v1/me/collection", headers=h, json={"entries": [_entry("Boss", "Flat", 10, 0)]})
    assert client.get("/v1/me/collection", headers=_player(client)).json()["items"] == []
