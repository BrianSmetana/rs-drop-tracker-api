"""Drop rates for the collection-log luck figures, built the same way as the plugin's rates.lua.

rare_drops.json supplies flat per-kill rates (the server's allowlist); tools/clog_extra_rates.json adds display-only
rates (pets, set pieces, tertiaries) and wins on conflict. A rate spec is one of:

    0.0078125                                        a flat per-kill chance
    {"rate": 1/5400, "rolls": 12}                    r independent rolls per kill: Binomial(kills * r, rate)
    {"base": 1/5000, "threshold": 1000,              a boss pet: chance grows by `base` every `threshold` total
     "hard_base": 1/1000}                            kills (capped at 10x); hard-mode kills use `hard_base`

tools/gen_lua_rates.py uses this module to write the plugin's rates.lua, so the two cannot drift apart.
"""
import json
from pathlib import Path
from typing import Optional

# Collection-log pages with no percentages: each is several sub-bosses with their own items and kill counts, so a
# page-level kill count cannot give an item a dry percentage. Display only; the server still tracks their drops.
NO_LABELS = {
    "Legiones", "Legio Primus", "Legio Secundus", "Legio Tertius", "Legio Quartus", "Legio Quintus", "Legio Sextus",
    "Rex Matriarchs",
    # no usable kill count for these pages: dropped from the labels (the server still tracks them)
    "Masuta the Ascended", "The Sanctum Guardian", "Seiryu the Azure Serpent", "Exiled Kalphite Queen",
}

# Bosses shown under another page: the game keeps one kill count for the whole dungeon / raid / Osseous page, so their
# items are labelled with the group's count. group -> bosses folded into it. Where two bosses share an item name the
# group's own entry wins, then the first boss listed here.
MERGE = {
    "Dragonkin Laboratory": ["Black stone dragon", "Astellarn", "Verak Lith"],
    "The Shadow Reef": ["Crassian Leviathan", "Taraket the Necromancer", "The Ambassador"],
    "Sanctum of Rebirth": ["Vermyx, Brood Mother", "Kezalam, the Wanderer", "Nakatra, Devourer Eternal"],
    "Liberation of Mazcab": ["Beastmaster Durzag", "Yakamaru"],
    "Osseous": ["Rex Matriarch: Osseous"],  # the same boss under two names
}


# Items that several bosses drop and the collection log shows as one count on every one of their pages: they are scored
# over the bosses' kills added together (each at its own rate). GWD1 without Nex; GWD2 without Telos.
_GWD1 = ["General Graardor", "Commander Zilyana", "K'ril Tsutsaroth", "Kree'arra"]
_GWD2 = ["Helwyr", "Vindicta & Gorvek", "The Twin Furies", "Gregorovic"]
SHARED_DROPS = {
    **{f"Godsword shard {n}": _GWD1 for n in (1, 2, 3)},
    **{f"Dormant anima core {part}": _GWD2 for part in ("helm", "body", "legs")},
}

# --- enrage bosses: drop chances that depend on how the player farms them ------------------------------------------
# The kill's enrage and killstreak are not visible to the plugin, so the player picks how they usually farm each boss
# and every kill is scored as if made that way. A strategy fixes an enrage % and a killstreak (kills since loot was
# last claimed, including this one); each enrage- or streak-dependent item then becomes a flat rate (a boss pet keeps
# its threshold, with the base taken at that enrage). Rates use the same rules as the server (app/main.py rate_at /
# streak_rate). "pages" are the rates keys the strategy overlays: a boss's drops and its pet are keyed separately.
# group -> { pages, default, options: [(id, label, enrage %, killstreak)] }; the first option is the one used until
# the player chooses. Streak formulas are the community's, unconfirmed on the wiki (see tools/curate_rare.py).
STRATEGIES = {
    "Telos": {
        "pages": ["Telos, the Warden", "Telos"],
        "default": "claim_2449",
        "options": [
            ("claim_2449", "Claim every kill at 2449% enrage (best)", 2449, 1),
            ("claim_1000", "Claim every kill at 1000% enrage", 1000, 1),
            ("claim_500", "Claim every kill at 500% enrage", 500, 1),
            ("claim_100", "Claim every kill at 100% enrage", 100, 1),
            ("claim_0", "Claim every kill at 0% enrage", 0, 1),
        ],
    },
    "Arch-Glacor": {
        "pages": ["Arch-Glacor"],
        "default": "claim_1000",
        "options": [
            ("claim_2000", "Claim every kill at 2000% enrage", 2000, 1),
            ("claim_1000", "Claim every kill at 1000% enrage", 1000, 1),
            ("claim_500", "Claim every kill at 500% enrage", 500, 1),
            ("claim_100", "Claim every kill at 100% enrage", 100, 1),
            ("claim_0", "Claim every kill at 0% enrage", 0, 1),
        ],
    },
    "Amascut": {
        "pages": ["Amascut, the Devourer", "Amascut"],
        "default": "enrage_500",
        "options": [
            ("enrage_2000", "2000%+ enrage", 2000, 1),
            ("enrage_1000", "1000% enrage", 1000, 1),
            ("enrage_750", "750% enrage", 750, 1),
            ("enrage_500", "500% enrage", 500, 1),
            ("enrage_100", "100% enrage", 100, 1),
            ("enrage_0", "Normal mode (0% enrage)", 0, 1),
        ],
    },
}


def _tier(tiers, value, default=None):
    hit = default
    for t in tiers:
        if value >= t[0]:
            hit = t
    return hit


def _item_rate_at(cfg: dict, enrage: int, streak: int):
    """Per-kill chance of an enrage/streak item at a fixed enrage and killstreak, or None if it cannot be scored."""
    s = cfg.get("streak")
    if s:
        if s.get("kind") != "formula":
            return None  # bad-luck mitigation (Zamorak) needs the player's dry history
        p = (s["a"] + s["b"] * enrage + s["c"] * streak) / 1e6
        return min(s.get("cap", 1.0), p * _tier(s.get("mult", [[0, 1.0]]), enrage, [0, 1.0])[1]) * s["share"]
    if "enrage_linear" in cfg:
        lin = cfg["enrage_linear"]
        return min(1.0, lin["base"] + lin["per_pct"] * enrage)
    tier = _tier(cfg.get("enrage", []), enrage)
    return tier[1] if tier else cfg["rate"]


def strategy_overlays(rare_path: Path) -> dict:
    """{group: {"default": id, "options": [{"id", "label", "enrage", "streak", "rates": {page: {item: spec}}}]}}.

    `rates` holds only the enrage- or streak-dependent items, as specs in the same form as load() returns; the plugin
    lays them over the base rates of each page while that option is selected."""
    data = json.loads(Path(rare_path).read_text(encoding="utf-8"))
    out = {}
    for group, cfg in STRATEGIES.items():
        options = []
        for oid, label, enrage, streak in cfg["options"]:
            rates = {}
            for page in cfg["pages"]:
                for item, info in sorted(data.get(page, {}).items()):
                    if not ("enrage" in info or "enrage_linear" in info or "streak" in info):
                        continue
                    p = _item_rate_at(info, enrage, streak)
                    if p is None or p <= 0:
                        continue  # not scoreable, or cannot drop at this enrage (Amascut's shard in normal mode)
                    if "threshold" in info:  # pet-style: the chance still grows every `threshold` kills
                        spec = {"base": p, "threshold": int(info["threshold"])}
                    else:
                        spec = float(info.get("rolls", 1) or 1) * p
                    rates.setdefault(page, {})[item] = spec
            options.append({"id": oid, "label": label, "enrage": enrage, "streak": streak, "rates": rates})
        out[group] = {"default": cfg["default"], "options": options}
    return out


def parse_rate(value) -> float:
    """'1/768' -> 0.001302..., '1/56.9' -> 0.01757..., 0.002 -> 0.002"""
    if isinstance(value, str) and "/" in value:
        num, den = value.split("/", 1)
        return float(num) / float(den.replace(",", ""))
    return float(value)


def load(rare_path: Path, extra_path: Optional[Path] = None):
    """Returns (rates, aliases): rates[boss][item] = spec, aliases[name] = canonical boss."""
    data = json.loads(Path(rare_path).read_text(encoding="utf-8"))
    aliases = data.get("_aliases", {})

    rates: dict = {}
    for boss in sorted(k for k in data if not k.startswith("_") and k not in NO_LABELS):
        for item, info in sorted(data[boss].items()):
            # items whose chance depends on enrage / killstreak cannot be scored from kills alone
            if "enrage" in info or "enrage_linear" in info or "streak" in info or "rate" not in info:
                continue
            rates.setdefault(boss, {})[item] = float(info["rate"]) * float(info.get("rolls", 1) or 1)

    if extra_path and Path(extra_path).exists():
        extras = json.loads(Path(extra_path).read_text(encoding="utf-8"))
        for boss, items in extras.items():
            if boss.startswith("_") or boss in NO_LABELS:
                continue
            for item, info in items.items():
                if "base" in info:
                    spec = {"base": parse_rate(info["base"]), "threshold": int(info["threshold"])}
                    if "hard_base" in info:
                        spec["hard_base"] = parse_rate(info["hard_base"])
                elif "rolls" in info:
                    spec = {"rate": parse_rate(info["rate"]), "rolls": int(info["rolls"])}
                else:
                    spec = parse_rate(info["rate"])
                rates.setdefault(boss, {})[item] = spec  # extras win on conflict

    for group, members in MERGE.items():
        for member in members:
            for item, spec in rates.pop(member, {}).items():
                rates.setdefault(group, {}).setdefault(item, spec)
    return rates, aliases
