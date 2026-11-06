import csv
import io
import json

import pytest
from fastapi.testclient import TestClient

from tools import import_account as imp

RATES = {
    "Boss A": {"rare one": {"rate": 0.01, "rolls": 1}, "rare two": {"rate": 0.002, "rolls": 1}},
    "Boss, With Comma": {"x": {"rate": 0.01, "rolls": 1, "enrage": [[0, 0.001], [100, 0.1]]}},
}
ALIASES = {"Old A": "Boss A"}


def parse(text):
    rows = list(csv.DictReader(io.StringIO(text)))
    bosses, warnings = imp.parse_rows(rows, RATES, ALIASES)
    return bosses, warnings, imp.build_events(bosses, warnings)


HEADER = "boss,kills,first_kc,enrage,item,drops,drop_kcs\n"


def test_kills_become_two_endpoint_events_and_drops_are_placed():
    _, warnings, ev = parse(HEADER + "Boss A,100,,,,,\nBoss A,,,,rare one,1,40\n")
    assert warnings == []
    assert [(e["type"], e["kc"]) for e in ev] == [("kill", 1), ("kill", 100), ("drop", 40)]


def test_names_are_case_insensitive_and_aliases_resolve():
    _, warnings, ev = parse(HEADER + "old a,10,,,,,\nBOSS A,,,,RARE ONE,1,5\n")
    assert warnings == []
    assert {e["boss"] for e in ev} == {"Boss A"} and ev[-1]["item"] == "rare one"


def test_unknown_names_warn_with_a_suggestion_and_are_skipped():
    _, warnings, ev = parse(HEADER + "Bos A,10,,,,,\nBoss A,10,,,rare onee,1,3\n")
    assert any("unknown boss 'Bos A'" in w and "Boss A" in w for w in warnings)
    assert any("rare onee" in w and "rare one" in w for w in warnings)
    assert all(e["boss"] == "Boss A" for e in ev) and not any(e["type"] == "drop" for e in ev)


def test_blank_drops_means_none_and_drop_kcs_sets_the_count():
    _, _, ev = parse(HEADER + "Boss A,50,,,,,\nBoss A,,,,rare one,,\nBoss A,,,,rare two,,10;20\n")
    drops = [e for e in ev if e["type"] == "drop"]
    assert [(d["item"], d["kc"]) for d in drops] == [("rare two", 10), ("rare two", 20)]


def test_drops_without_kcs_are_spread_evenly():
    _, _, ev = parse(HEADER + "Boss A,100,,,,,\nBoss A,,,,rare one,3,\n")
    assert [e["kc"] for e in ev if e["type"] == "drop"] == [26, 51, 75]  # 1 + round(k*99/4); Python rounds 49.5 to 50


def test_enrage_sends_every_kill_with_its_enrage():
    _, _, ev = parse(HEADER + '"Boss, With Comma",30,,500,,,\n')
    kills = [e for e in ev if e["type"] == "kill"]
    assert [k["kc"] for k in kills] == list(range(1, 31)) and {k["enrage"] for k in kills} == {500}


def test_first_kc_and_out_of_range_drop_kc():
    _, warnings, ev = parse(HEADER + "Boss A,100,60,,,,\nBoss A,,,,rare one,1,10\n")
    assert [e["kc"] for e in ev if e["type"] == "kill"] == [60, 100]
    assert any("outside 60-100" in w for w in warnings)
    assert [e["kc"] for e in ev if e["type"] == "drop"] == [60]


def test_drops_without_kills_use_the_last_drop_kc_and_missing_kills_skip():
    _, _, ev = parse(HEADER + "Boss A,,,,rare one,1,40\n")
    assert max(e["kc"] for e in ev if e["type"] == "kill") == 40
    _, warnings, ev = parse(HEADER + "Boss A,,,,rare one,1,\n")
    assert ev == [] and any("no kills" in w for w in warnings)


def test_event_ids_are_stable_unique_and_fit_the_api_limit():
    text = HEADER + "Boss A,200,,,,,\nBoss A,,,,rare one,2,\n"
    a, b = parse(text)[2], parse(text)[2]
    ids = [e["event_id"] for e in a]
    assert ids == [e["event_id"] for e in b] and len(set(ids)) == len(ids) and max(map(len, ids)) <= 64


def test_template_lists_every_boss_and_item_and_imports_as_empty(tmp_path):
    rates, aliases = imp.load_rates()
    path = tmp_path / "t.csv"
    assert imp.write_template(path, rates) == sum(1 + len(v) for v in rates.values())
    with open(path, encoding="utf-8", newline="") as f:
        bosses, warnings = imp.parse_rows(list(csv.DictReader(f)), rates, aliases)
    assert imp.build_events(bosses, warnings) == [] and warnings == [] and len(bosses) == len(rates)


def test_example_csv_imports_cleanly_against_the_real_rates():
    rates, aliases = imp.load_rates()
    from pathlib import Path
    with open(Path(imp.ROOT) / "examples" / "example_account.csv", encoding="utf-8-sig", newline="") as f:
        bosses, warnings = imp.parse_rows(list(csv.DictReader(f)), rates, aliases)
    ev = imp.build_events(bosses, warnings)
    assert warnings == [] and any(e["type"] == "drop" for e in ev)


@pytest.fixture
def client(tmp_path, monkeypatch):
    rates = tmp_path / "rates.json"
    rates.write_text(json.dumps({"_aliases": ALIASES, **RATES}))
    monkeypatch.setattr("app.db.DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setattr("app.main.RATES_PATH", rates)
    from app.main import app
    with TestClient(app) as c:
        yield c


def test_imported_events_are_accepted_scored_and_reimport_is_idempotent(client):
    h = {"Authorization": "Bearer " + client.post("/v1/players").json()["token"]}
    _, _, ev = parse(HEADER + "Boss A,500,,,,,\nBoss A,,,,rare one,2,100;300\n"
                              '"Boss, With Comma",40,,1200,,,\n')
    first = client.post("/v1/events", json={"events": ev}, headers=h).json()
    assert first == {"received": len(ev), "accepted": len(ev), "ignored": 0}
    assert client.post("/v1/events", json={"events": ev}, headers=h).json()["accepted"] == 0
    r = client.get("/v1/me/luck", params={"boss": "Boss A", "item": "rare one"}, headers=h).json()
    assert r["kills"] == 500 and r["drops"] == 2 and r["expected_drops"] == pytest.approx(500 * 0.01)
    e = client.get("/v1/me/luck", params={"boss": "Boss, With Comma", "item": "x"}, headers=h).json()
    assert e["expected_drops"] == pytest.approx(40 * 0.1)  # every kill carried 1200% enrage


def test_cli_dry_run_sends_nothing_and_a_real_run_needs_a_token(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("DROP_TRACKER_TOKEN", raising=False)
    p = tmp_path / "a.csv"
    p.write_text(HEADER + "Araxxi,10,,,,,\n")
    assert imp.main([str(p), "--dry-run"]) == 0
    assert "Dry run, nothing sent" in capsys.readouterr().out
    with pytest.raises(SystemExit, match="--token"):
        imp.main([str(p)])  # has events but no token and no --register
