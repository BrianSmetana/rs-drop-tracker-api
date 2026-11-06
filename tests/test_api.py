import json

import pytest
from fastapi.testclient import TestClient

from app import stats


def test_luck_average_is_near_50():
    r = stats.luck(kills=128, drops=1, rate=1 / 128)
    assert 30 < r["percentile"] < 60
    assert r["expected_drops"] == pytest.approx(1.0)


def test_dry_is_low_lucky_is_high():
    assert stats.luck(1000, 0, 1 / 128)["percentile"] < 1
    assert stats.luck(128, 5, 1 / 128)["percentile"] > 95


def test_threshold_matches_constant_rate_when_threshold_is_huge():
    a = stats.luck(500, 3, 1 / 200)
    b = stats.luck_threshold(1, 500, 3, 1 / 200, threshold=10**9)
    assert a["percentile"] == pytest.approx(b["percentile"], abs=0.01)


def test_threshold_raises_expected_drops():
    r = stats.luck_threshold(1, 120, 0, 1 / 200, threshold=40)
    # 40 kills at 1/200, 40 at 2/200, 40 at 3/200 -> 240/200
    assert r["expected_drops"] == pytest.approx(1.2)


def test_barrows_rolls():
    p = stats.per_kill_probability(1 / 1752, rolls=7)
    assert p == pytest.approx(7 / 1752, rel=0.01)


@pytest.fixture
def client(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({"b": {"i": {"rate": 0.01, "rolls": 1}}}))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        yield c


def test_flow_and_idempotency(client):
    reg = client.post("/v1/players").json()
    h = {"Authorization": f"Bearer {reg['token']}"}
    events = [{"type": "kill", "event_id": f"k{i}", "boss": "b", "kc": 10 + i} for i in range(200)]
    events.append({"type": "drop", "event_id": "d1", "boss": "b", "item": "i", "kc": 50})
    assert client.post("/v1/events", json={"events": events}, headers=h).json()["accepted"] == 201
    assert client.post("/v1/events", json={"events": events}, headers=h).json()["accepted"] == 0
    r = client.get("/v1/me/luck", params={"boss": "b", "item": "i"}, headers=h).json()
    assert r["kills"] == 200 and r["drops"] == 1
    assert client.get("/v1/aggregate", params={"boss": "b", "item": "i"}).json()["players"] == 1


def _sync_player(client, name=None, public=True):
    reg = client.post("/v1/players").json()
    h = {"Authorization": f"Bearer {reg['token']}"}
    events = [{"type": "kill", "event_id": f"k{i}", "boss": "b", "kc": 10 + i} for i in range(100)]
    events.append({"type": "drop", "event_id": "d1", "boss": "b", "item": "i", "kc": 50})
    client.post("/v1/events", json={"events": events}, headers=h)
    if name:
        r = client.post("/v1/me/profile", json={"username": name, "public": public}, headers=h)
        assert r.status_code == 200
    return h


def test_public_lookup_by_username(client):
    _sync_player(client, "Zezima")
    r = client.get("/v1/players/zezima/summary")  # case-insensitive, no auth
    assert r.status_code == 200
    body = r.json()
    assert body["username"] == "Zezima" and body["last_synced"]
    boss = body["bosses"][0]
    assert boss["boss"] == "b" and boss["tracked_kills"] == 100
    assert boss["items"][0]["item"] == "i" and boss["items"][0]["drops"] == 1


def test_summary_lists_every_tracked_boss(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({
        "b": {"i": {"rate": 0.01, "rolls": 1}},
        "other": {"x": {"rate": 0.02, "rolls": 1, "rarity": "1/50"}, "y": {"rate": 0.001, "rolls": 1}},
    }))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        _sync_player(c, "Everyone")
        bosses = {b["boss"]: b for b in c.get("/v1/players/Everyone/summary").json()["bosses"]}
    assert set(bosses) == {"b", "other"}
    assert bosses["b"]["has_data"] and bosses["b"]["tracked_kills"] == 100
    empty = bosses["other"]
    assert not empty["has_data"] and empty["tracked_kills"] == 0
    assert [i["item"] for i in empty["items"]] == ["y", "x"]  # rarest first
    assert all(i["drops"] == 0 and i["percentile"] is None for i in empty["items"])


@pytest.fixture
def alias_client(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({"_aliases": {"Old Name": "Boss"}, "Boss": {"i": {"rate": 0.01, "rolls": 1}}}))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        yield c


def test_alias_boss_names_share_one_entry(alias_client):
    c = alias_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    ev = [{"type": "kill", "event_id": f"a{i}", "boss": "Old Name", "kc": i} for i in range(1, 51)]
    ev += [{"type": "kill", "event_id": f"b{i}", "boss": "Boss", "kc": i} for i in range(51, 101)]
    ev.append({"type": "drop", "event_id": "d", "boss": "Old Name", "item": "i", "kc": 60})
    assert c.post("/v1/events", json={"events": ev}, headers=h).json()["ignored"] == 0
    r = c.get("/v1/me/luck", params={"boss": "Old Name", "item": "i"}, headers=h).json()  # alias works in lookups
    assert r["kills"] == 100 and r["drops"] == 1
    assert c.get("/v1/aggregate", params={"boss": "Old Name", "item": "i", "min_kills": 1}).json()["players"] == 1
    bosses = c.get("/v1/me/summary", headers=h).json()["bosses"]
    assert [b["boss"] for b in bosses] == ["Boss"]


def test_startup_migrates_stored_alias_rows(alias_client):
    from app import db, main
    c = alias_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    pid = h["Authorization"].split(" ")[1].split(".")[0]
    with db.connect() as conn:
        conn.execute("INSERT INTO kill_events (event_id, player_id, boss, kc, ts) VALUES ('o', ?, 'Old Name', 1, 't')", (pid,))
    assert main.purge_untracked() == 0  # renamed, not deleted
    with db.connect() as conn:
        assert [r[0] for r in conn.execute("SELECT boss FROM kill_events")] == ["Boss"]


def test_rise_of_the_six_is_tracked_with_wiki_rates():
    rates = json.load(open("rare_drops.json", encoding="utf-8"))
    ros = rates["The Barrows: Rise of the Six"]
    assert {n: c["rate"] for n, c in ros.items() if n.endswith("kiteshield")} == {
        "Malevolent kiteshield": 1 / 240, "Merciless kiteshield": 1 / 240, "Vengeful kiteshield": 1 / 240}
    assert rates["_aliases"]["Rise of the Six"] == "The Barrows: Rise of the Six"


def test_curated_aliases_point_at_real_bosses():
    rates = json.load(open("rare_drops.json", encoding="utf-8"))
    for alias, name in rates["_aliases"].items():
        assert alias not in rates and name in rates, (alias, name)


def test_not_public_until_opt_in_and_opt_out_hides(client):
    h = _sync_player(client)  # synced, never opted in
    assert client.get("/v1/players/Nobody/summary").status_code == 404
    client.post("/v1/me/profile", json={"username": "Hidden One", "public": False}, headers=h)
    assert client.get("/v1/players/Hidden One/summary").status_code == 404
    assert client.get("/v1/players/Hidden_One/summary").status_code == 404
    me = client.get("/v1/me/summary", headers=h).json()  # owner still sees it
    assert me["public"] is False and me["bosses"][0]["tracked_kills"] == 100
    client.post("/v1/me/profile", json={"username": "Hidden One", "public": True}, headers=h)
    assert client.get("/v1/players/hidden_one/summary").status_code == 200


def test_username_cannot_be_claimed_twice(client):
    _sync_player(client, "Taken")
    h2 = _sync_player(client)
    r = client.post("/v1/me/profile", json={"username": "TAKEN"}, headers=h2)
    assert r.status_code == 409


def test_invalid_username_rejected(client):
    h = _sync_player(client)
    assert client.post("/v1/me/profile", json={"username": "bad<script>"}, headers=h).status_code == 422
    assert client.get("/v1/players/bad<script>/summary").status_code == 422


def test_only_rare_drops_are_stored(client):
    reg = client.post("/v1/players").json()
    h = {"Authorization": f"Bearer {reg['token']}"}
    events = [
        {"type": "kill", "event_id": "k1", "boss": "b", "kc": 1},
        {"type": "kill", "event_id": "k2", "boss": "unlisted boss", "kc": 1},
        {"type": "drop", "event_id": "d1", "boss": "b", "item": "i", "kc": 1},
        {"type": "drop", "event_id": "d2", "boss": "b", "item": "Rune scimitar", "kc": 1},  # common loot
        {"type": "drop", "event_id": "d3", "boss": "unlisted boss", "item": "i", "kc": 1},
    ]
    r = client.post("/v1/events", json={"events": events}, headers=h).json()
    assert r == {"received": 5, "accepted": 2, "ignored": 3}
    from app import db
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM drop_events").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM kill_events").fetchone()[0] == 1


def test_purge_removes_previously_stored_common_drops(client):
    from app import db, main
    h = _sync_player(client)
    pid = h["Authorization"].split(" ")[1].split(".")[0]
    with db.connect() as conn:
        conn.execute("INSERT INTO drop_events VALUES ('x1', ?, 'b', 'Rune scimitar', 1, 5, 't')", (pid,))
        conn.execute(
            "INSERT INTO kill_events (event_id, player_id, boss, kc, ts) VALUES ('x2', ?, 'gone boss', 5, 't')", (pid,)
        )
    assert main.purge_untracked() == 2
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM drop_events WHERE item = 'Rune scimitar'").fetchone()[0] == 0
    assert client.get("/v1/me/luck", params={"boss": "b", "item": "i"}, headers=h).status_code == 200


@pytest.fixture
def enrage_client(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({"b": {
        "tiered": {"rate": 0.001, "rolls": 1, "enrage": [[0, 0.001], [100, 0.01], [1000, 0.1]]},
        "linear": {"rate": 0.001, "rolls": 1, "enrage_linear": {"base": 0.001, "per_pct": 0.0001}},
        "pet": {"rate": 0.001, "rolls": 1, "threshold": 50, "enrage": [[0, 0.001], [100, 0.002]]},
    }}))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        yield c


def test_rate_at_picks_tier_and_formula():
    from app.main import rate_at
    cfg = {"rate": 0.001, "enrage": [[0, 0.001], [100, 0.01], [1000, 0.1]]}
    assert [rate_at(cfg, e) for e in (0, 99, 100, 999, 1000, 4000)] == [0.001, 0.001, 0.01, 0.01, 0.1, 0.1]
    lin = {"rate": 0.0, "enrage_linear": {"base": 0.001, "per_pct": 0.0001}}
    assert rate_at(lin, 100) == pytest.approx(0.011)
    assert rate_at(lin, 10**7) == 1.0  # capped
    assert rate_at({"rate": 0.5}, 500) == 0.5


def _kills(client, h, enrage, n=100, prefix="k"):
    ev = [{"type": "kill", "event_id": f"{prefix}{i}", "boss": "b", "kc": i + 1, **({} if enrage is None else {"enrage": enrage})}
          for i in range(n)]
    assert client.post("/v1/events", json={"events": ev}, headers=h).status_code == 200


def test_expected_drops_follow_each_kills_enrage(enrage_client):
    c = enrage_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    _kills(c, h, None, n=50)  # kc 1-50, no enrage reported -> 0% tier, 0.001 each
    ev = [{"type": "kill", "event_id": f"e{i}", "boss": "b", "kc": 51 + i, "enrage": 1200} for i in range(50)]
    c.post("/v1/events", json={"events": ev}, headers=h)  # kc 51-100 at 1200% -> 0.1 each
    r = c.get("/v1/me/luck", params={"boss": "b", "item": "tiered"}, headers=h).json()
    assert r["kills"] == 100
    assert r["expected_drops"] == pytest.approx(50 * 0.001 + 50 * 0.1)
    lin = c.get("/v1/me/luck", params={"boss": "b", "item": "linear"}, headers=h).json()
    assert lin["expected_drops"] == pytest.approx(50 * 0.001 + 50 * (0.001 + 0.0001 * 1200))


def test_enrage_and_pet_threshold_combine(enrage_client):
    c = enrage_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    _kills(c, h, 100, n=100)  # tier 0.002; threshold 50 -> x1 for kc 1-50, x2 for kc 51-100
    r = c.get("/v1/me/luck", params={"boss": "b", "item": "pet"}, headers=h).json()
    assert r["expected_drops"] == pytest.approx(50 * 0.002 + 50 * 0.004)


def test_enrage_reaches_summary_and_validates(enrage_client):
    c = enrage_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    _kills(c, h, 2000, n=10)
    bad = {"type": "kill", "event_id": "bad", "boss": "b", "kc": 11, "enrage": -5}
    assert c.post("/v1/events", json={"events": [bad]}, headers=h).status_code == 422
    items = {i["item"]: i for i in c.get("/v1/me/summary", headers=h).json()["bosses"][0]["items"]}
    assert items["tiered"]["expected_drops"] == pytest.approx(10 * 0.1)


ZAM_BLM = {"group": "g", "kind": "blm", "min_enrage": 100, "start": 10,
           "base": [[0, 100], [100, 80], [300, 67]], "tiers": [[100, 1, 20], [1000, 4, 10]]}
FORMULA = {"group": "u", "kind": "formula", "a": 1000, "b": 25, "c": 300, "cap": 1 / 15, "share": 0.5,
           "mult": [[0, 1 / 30], [25, 1 / 10], [100, 1.0]]}


def test_blm_denominator_drops_after_ten_dry_kills_and_caps():
    from app.main import streak_rate
    cfg = {"rate": 1 / 670, "enrage": [[0, 1 / 670]], "streak": ZAM_BLM}  # rate = (1/67) * share 0.1 at enrage 300
    cfg["enrage"] = [[0, 0.1 / 100], [300, 0.1 / 67]]
    r = lambda e, dry: streak_rate(cfg, e, 1, dry)
    assert r(300, 10) == pytest.approx((0.1 / 67, True))  # not yet
    assert r(300, 20)[0] == pytest.approx(0.1 / 57)  # wiki example: 20 dry at 300% -> 1/57
    assert r(300, 500)[0] == pytest.approx(0.1 / 20)  # capped at 1/20
    assert r(50, 500) == (pytest.approx(0.1 / 100), False)  # <100% enrage: no mitigation, doesn't count
    assert r(1000, 500)[0] == pytest.approx(0.1 / 10)  # higher tier cap 1/10 (base denom falls back to 67 tier)


def test_streak_formula_uses_reported_streak_tiers_and_cap():
    from app.main import streak_rate
    cfg = {"rate": 0.0, "streak": FORMULA}
    gold = streak_rate(cfg, 100, 1, 0)[0]  # (1000 + 2500 + 300) / 1e6 * share
    assert gold == pytest.approx(0.0038 * 0.5)
    assert streak_rate(cfg, 50, 1, 0)[0] == pytest.approx(gold * 0 + (1000 + 1250 + 300) / 1e6 / 10 * 0.5)  # silver /10
    assert streak_rate(cfg, 10, 1, 0)[0] == pytest.approx((1000 + 250 + 300) / 1e6 / 30 * 0.5)  # bronze /30
    assert streak_rate(cfg, 4000, 200, 0)[0] == pytest.approx(1 / 15 * 0.5)  # capped at 1/15


@pytest.fixture
def streak_client(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({"b": {
        "A": {"rate": 0.001, "rolls": 1, "enrage": [[0, 0.001]], "streak": {**ZAM_BLM, "base": [[0, 100]]}},
        "B": {"rate": 0.001, "rolls": 1, "enrage": [[0, 0.001]], "streak": {**ZAM_BLM, "base": [[0, 100]]}},
        "F": {"rate": 0.0, "rolls": 1, "streak": FORMULA},
    }}))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        yield c


def test_blm_counts_dry_kills_and_resets_on_any_group_drop(streak_client):
    c = streak_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    ev = [{"type": "kill", "event_id": f"k{i}", "boss": "b", "kc": i, "enrage": 200} for i in range(1, 31)]
    ev.append({"type": "drop", "event_id": "d", "boss": "b", "item": "B", "kc": 15})  # resets the group's counter
    c.post("/v1/events", json={"events": ev}, headers=h)
    r = c.get("/v1/me/luck", params={"boss": "b", "item": "A"}, headers=h).json()
    # share 0.1 of a 1/100 chance = 0.001. dry counts: kc1-15 are 0..14 (mitigation from the 12th dry kill),
    # reset at kc15's drop, then kc16-30 are 0..14 again. Rate scale = 100/eff, eff = 100 - 1*max(0, dry-10).
    scale = lambda dry: 100 / max(20, 100 - max(0, dry - 10))
    expected = sum(0.001 * scale(d) for d in range(15)) * 2
    assert r["expected_drops"] == pytest.approx(expected)


def test_blm_ignores_kills_under_100_enrage_entirely(streak_client):
    c = streak_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    # 20 dry kills at 200%, then a drop on a 50% kill (must NOT reset), then 5 more kills at 200%.
    ev = [{"type": "kill", "event_id": f"k{i}", "boss": "b", "kc": i, "enrage": 200} for i in range(1, 21)]
    ev.append({"type": "kill", "event_id": "low", "boss": "b", "kc": 21, "enrage": 50})
    ev.append({"type": "drop", "event_id": "d", "boss": "b", "item": "B", "kc": 21})
    ev += [{"type": "kill", "event_id": f"m{i}", "boss": "b", "kc": 21 + i, "enrage": 200} for i in range(1, 6)]
    c.post("/v1/events", json={"events": ev}, headers=h)
    r = c.get("/v1/me/luck", params={"boss": "b", "item": "A"}, headers=h).json()
    scale = lambda dry: 100 / max(20, 100 - max(0, dry - 10))
    # dry runs 0..19 over kc1-20, kc21 is skipped (flat 50% tier rate, no scaling), then dry continues 20..24.
    expected = sum(0.001 * scale(d) for d in range(20)) + 0.001 + sum(0.001 * scale(d) for d in range(20, 25))
    assert r["expected_drops"] == pytest.approx(expected)


def test_formula_item_uses_each_kills_reported_streak(streak_client):
    c = streak_client
    h = {"Authorization": "Bearer " + c.post("/v1/players").json()["token"]}
    ev = [{"type": "kill", "event_id": f"k{i}", "boss": "b", "kc": i, "enrage": 100, "streak": i} for i in range(1, 6)]
    ev.append({"type": "kill", "event_id": "nostreak", "boss": "b", "kc": 6, "enrage": 100})  # defaults to streak 1
    c.post("/v1/events", json={"events": ev}, headers=h)
    r = c.get("/v1/me/luck", params={"boss": "b", "item": "F"}, headers=h).json()
    expect = sum((1000 + 2500 + 300 * s) / 1e6 * 0.5 for s in (1, 2, 3, 4, 5, 1))
    assert r["expected_drops"] == pytest.approx(expect, rel=1e-3)
    bad = {"type": "kill", "event_id": "z", "boss": "b", "kc": 7, "streak": 0}
    assert c.post("/v1/events", json={"events": [bad]}, headers=h).status_code == 422


def test_curated_enrage_data_is_wellformed():
    rates = json.load(open("rare_drops.json", encoding="utf-8"))
    for boss in ("Telos, the Warden", "Zamorak, Lord of Chaos", "Arch-Glacor", "Amascut, the Devourer"):
        assert any(k in c for c in rates[boss].values() for k in ("enrage", "enrage_linear", "streak")), boss
    for boss, items in rates.items():
        for name, cfg in items.items() if not boss.startswith("_") else []:
            tiers = cfg.get("enrage")
            if tiers:
                assert [t[0] for t in tiers] == sorted(t[0] for t in tiers) and tiers[0][0] == 0, (boss, name)
                assert all(0 <= t[1] <= 1 for t in tiers), (boss, name)


def test_website_served(client):
    r = client.get("/")
    assert r.status_code == 200 and "RS Drop Tracker" in r.text


def test_auth_required(client):
    assert client.post("/v1/events", json={"events": []}).status_code == 401
