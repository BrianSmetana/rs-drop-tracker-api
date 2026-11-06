"""Enrage-boss farming strategies (app/clog_rates.py) must score items exactly as the server does."""
from pathlib import Path

from app import clog_rates, main

ROOT = Path(__file__).resolve().parent.parent
RARE = ROOT / "rare_drops.json"


def test_every_strategy_rate_matches_the_servers_per_kill_chance():
    data = main.json.loads(RARE.read_text(encoding="utf-8"))
    overlays = clog_rates.strategy_overlays(RARE)
    assert set(overlays) == {"Telos", "Arch-Glacor", "Amascut"}
    checked = 0
    for group, strat in overlays.items():
        assert strat["default"] in {o["id"] for o in strat["options"]}
        for opt in strat["options"]:
            for page, items in opt["rates"].items():
                for item, spec in items.items():
                    cfg = data[page][item]
                    if "streak" in cfg:
                        want = main.streak_rate(cfg, opt["enrage"], opt["streak"], 0)[0]
                    else:
                        want = main.rate_at(cfg, opt["enrage"])
                    got = spec["base"] if isinstance(spec, dict) else spec
                    assert abs(got - want) < 1e-12, (group, opt["id"], item)
                    checked += 1
    assert checked > 50


def test_telos_best_option_is_the_users_2449_claim_every_kill():
    overlays = clog_rates.strategy_overlays(RARE)
    telos = overlays["Telos"]
    assert telos["default"] == "claim_2449"
    best = {o["id"]: o for o in telos["options"]}["claim_2449"]
    assert (best["enrage"], best["streak"]) == (2449, 1)
    # the whole unique table at 2449% / streak 1 is about 1 in 16 (capped at 1/15)
    total = sum(r for k, r in best["rates"]["Telos, the Warden"].items() if k != "Telos' tendril")
    assert 0.05 < total < 1 / 15 + 1e-9


def test_amascut_normal_mode_drops_nothing_that_cannot_drop():
    overlays = clog_rates.strategy_overlays(RARE)
    normal = {o["id"]: o for o in overlays["Amascut"]["options"]}["enrage_0"]
    assert "Shard of Genesis Essence" not in normal["rates"]["Amascut, the Devourer"]
