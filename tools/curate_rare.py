"""Build rare_drops.json (rare drops only) from the full wiki scrape in wiki_drops_raw.json.

The wiki lists rare drops (uniques, pre-rolls, pets...) in their own tables, apart from the common loot.
A line is kept when the wiki table it came from is one of those. Run from the project root:

    python tools/curate_rare.py            # write rare_drops.json
    python tools/curate_rare.py --report   # also list rare-looking lines that were NOT kept
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
SRC = ROOT / "wiki_drops_raw.json"
DST = ROOT / "rare_drops.json"

# Wiki table names (lowercased) that hold rare drops. Everything else is common loot, seeds, supplies,
# tertiaries such as stone spirits and clue scrolls, etc.
RARE_EXACT = {
    "pre-roll", "pre-rolls", "unique", "uniques", "unique items", "unique rewards", "rare table",
    "solo", "duo", "trio", "solo encounter", "group encounter",
    "ancient warriors' equipment", "corrupt dragon equipment", "other barrows equipment",
    "linza the disgraced's equipment", "godsword shard table", "sigils", "trophy", "rewards",
    "weapon and armour table", "shard of genesis essence table", "devourer's nexus table",
    "normal mode", "hard mode", "demonic title scroll",
    "dagannoth prime", "dagannoth rex", "dagannoth supreme",
    "orikalka", "rathis", "pthentraken", "osseous",
}
RARE_PREFIX = ("unique", "pet")  # "Unique (5 mechanics)", "Unique drops (any enrage)", "Pet (unlocked via ...)"


# The wiki files many rare drops (boss heads, pets, boss-specific uniques) under "Tertiary" or "Common"
# next to supplies, so rarity itself also counts: 1/500 or rarer, minus things that are not boss rares.
RARE_RATE = 1 / 500
TERTIARY_RARE_RATE = 1 / 150  # tertiaries between 1/150 and 1/500 are real uniques (armour sets, helmets); 1/128 is effigies/spirits
NOT_RARE_NAME = re.compile(r"clue scroll|reroll token", re.I)
# Rare drops the wiki files under a common-looking table (bosses with no "Unique" table, or a 1/100-1/450 unique).
EXTRA_ITEMS = {
    "Draconic visage", "Black dragon egg (unchecked)", "Umbral urn", "Crystal triskelion", "Dark nilas",
    "Heart of the Berserker", "Volcanic shard",
    "Savage spear tip", "Savage spear cap", "Savage plume", "Savage spear shaft",
}


# Bosses where only the solo drop rates are tracked: the plugin cannot tell the group mode, so the
# duo/trio variants (separate "[Duo]" keys) would never be matched anyway.
SOLO_ONLY = {"Araxxi", "Araxxor"}
GROUP_TABLES = {"duo", "trio"}


# The four Rex Matriarchs (Osseous, Orikalka, Rathis, Pthentraken) share one kill count, so a drop only one of them
# makes cannot be scored; only what they all drop is kept (decided with the user). Pets are not drops: they live in
# tools/clog_extra_rates.json.
REX_BOSSES = {"Osseous", "Orikalka", "Rathis", "Pthentraken", "Rex Matriarchs"}
REX_SHARED = {"Savage spear tip", "Savage spear cap", "Savage plume", "Savage spear shaft", "Heart of the Berserker"}


def is_rare(boss: str, item: str, cfg: dict) -> bool:
    if NOT_RARE_NAME.search(item):
        return False
    if boss in REX_BOSSES and item not in REX_SHARED:
        return False
    t = (cfg.get("table") or "").strip().lower()
    if boss in SOLO_ONLY and t in GROUP_TABLES:
        return False
    rate = cfg.get("rate", 1.0)
    return (
        t in RARE_EXACT
        or t.startswith(RARE_PREFIX)
        or rate <= RARE_RATE
        or (t.startswith("tertiary") and rate <= TERTIARY_RARE_RATE)
        or (item in EXTRA_ITEMS and rate <= 1 / 100)
        or (boss.startswith("Dagannoth") and t in {"weapons and armour", "common"} and rate <= 1 / 100)  # DK rings, hatchet
    )


# --- bosses whose rare-drop chance depends on the kill's enrage ---------------------------------------------
# Each entry replaces the scraped lines for those items (the scrape only has one or two enrage variants, as
# separate "[...]" keys) with one item carrying "enrage": [[min_enrage_%, rate], ...] tiers, or
# "enrage_linear": {"base", "per_pct"}. The server picks the tier from each kill's reported enrage.
# Source: the boss pages on runescape.wiki. Bad-luck mitigation / streaks are NOT modelled, nor are tier-4 luck,
# story mode, or dungeon-completion bonuses.

def _tiers(pairs):
    return [[lo, rate] for lo, rate in pairs]


def _enrage_item(rate_pairs, **extra):
    pairs = sorted(rate_pairs)
    return {"rate": pairs[0][1], "rolls": 1, "rarity": "varies with enrage", "table": "Enrage-based",
            "enrage": _tiers(pairs), **extra}


def _enrage_overrides() -> dict:
    out: dict[str, dict] = {}

    # Telos: sword is flat; tendril is a pet-threshold drop whose base rate doubles at 100% enrage.
    # The unique table is rolled with the community streak formula (1000 + 25*enrage + 300*streak) / 1e6, reduced
    # 10x at 25-99% enrage and 30x below 25%, capped at 1/15 (unconfirmed on the wiki). Shares of the table are
    # out of 115: 10 for each dormant item / the codex, 75 for "the next anima orb", reported here as one
    # "Anima orb" (the plugin maps all three orbs to that name).
    def telos(share):
        return {"rate": share * 3800e-6 / 30, "rolls": 1, "rarity": "varies with enrage and streak",
                "table": "Enrage/streak-based",
                "streak": {"group": "telos_unique", "kind": "formula", "a": 1000, "b": 25, "c": 300,
                           "mult": [[0, 1 / 30], [25, 1 / 10], [100, 1.0]], "cap": 1 / 15, "share": share}}

    out["Telos, the Warden"] = {
        "Telos' tendril": _enrage_item([(0, 1 / 1400), (100, 1 / 700)], threshold=300),
        "Anima orb": telos(75 / 115),
        "Dormant Seren godbow": telos(10 / 115),
        "Dormant staff of Sliske": telos(10 / 115),
        "Dormant Zaros godsword": telos(10 / 115),
        "Reprisal ability codex": telos(10 / 115),
    }

    # Zamorak: chance of a signature drop per kill by enrage, times each item's share of the unique table.
    # Shares of the table change with enrage; vestments and Chaos Roar split what is left in their 0-99% ratio.
    zam_chance = [(0, 100), (20, 99), (50, 97), (100, 80), (150, 77), (200, 72), (300, 67), (400, 62), (500, 52),
                  (750, 47), (900, 40), (1000, 37), (1250, 35), (1500, 31), (2000, 28)]
    zam_shares = [  # min enrage -> (bow pieces combined, codex of lost knowledge)
        (0, 0.125, 0.35), (100, 0.15, 0.325), (500, 0.175, 0.30), (750, 0.185, 0.29), (900, 0.19, 0.285),
        (1000, 0.20, 0.275), (1250, 0.21, 0.265), (2000, 0.225, 0.25),
    ]

    def share_at(enr):
        return [s for s in zam_shares if s[0] <= enr][-1]

    # Bad-luck mitigation (history-based): from 100% enrage, after 10 dry signature kills the denominator falls by
    # `dec` per further dry kill, down to `cap`. [min_enrage, dec, cap_denominator]
    zam_blm = {
        "group": "zamorak_signature", "kind": "blm", "min_enrage": 100, "start": 10, "base": _tiers(zam_chance),
        "tiers": [[100, 1, 20], [500, 2, 20], [1000, 4, 10], [2000, 8, 5]],
    }

    def zam(fn):
        pts = sorted({d[0] for d in zam_chance} | {s[0] for s in zam_shares})
        return _enrage_item([
            (e, fn(share_at(e)) / [d for d in zam_chance if d[0] <= e][-1][1]) for e in pts
        ], streak=zam_blm)

    def rest(sh):
        return 1 - sh[1] - sh[2]

    zamorak = {
        "Codex of lost knowledge": zam(lambda s: s[2]),
        "Chaos Roar ability codex": zam(lambda s: rest(s) * 16.5 / 52.5),
    }
    for piece in ("hood", "robe top", "robe bottom", "boots"):
        zamorak[f"Vestments of havoc {piece}"] = zam(lambda s: rest(s) * 9 / 52.5)
    for piece in ("Top of the Last Guardian's bow", "Divine bowstring", "Bottom of the Last Guardian's bow"):
        zamorak[piece] = zam(lambda s: s[1] / 3)  # the wiki gives only the combined bow share; split evenly
    out["Zamorak, Lord of Chaos"] = zamorak

    # Arch-Glacor hard mode: unique chance ~ (1500 + 15*enrage + 25*streak) / 1,000,000 (community formula,
    # unconfirmed), streak = the killstreak the plugin reports. Split: core 24%, Scripture 38%, artefact 38%.
    def ag(share):
        return {"rate": share * 1525e-6, "rolls": 1, "rarity": "varies with enrage and streak",
                "table": "Enrage/streak-based",
                "streak": {"group": "arch_glacor_unique", "kind": "formula", "a": 1500, "b": 15, "c": 25,
                           "cap": 1.0, "share": share}}

    out["Arch-Glacor"] = {"Leng artefact": ag(0.38), "Scripture of Wen": ag(0.38), "Frozen core of Leng": ag(0.24)}

    # Amascut: per-item chances at each enrage tier (0 = normal mode), straight from the wiki's drop tables.
    tiers = (0, 100, 500, 750, 1000, 2000)
    guard = (1 / 4800, 1 / 560, 1 / 480, 1 / 400, 1 / 280, 1 / 200)
    resp = (3 / 12000, 3 / 1400, 3 / 1200, 3 / 1000, 3 / 700, 3 / 500)
    shard = (0, 1 / 280, 1 / 240, 1 / 200, 1 / 140, 1 / 100)
    nexus = (1 / 750, 1 / 280, 1 / 240, 1 / 200, 1 / 140, 1 / 100)
    amascut = {n: _enrage_item(list(zip(tiers, guard))) for n in ("Devourer's Guard", "Tumeken's Light")}
    for p in ("Mask", "Robe top", "Robe bottom", "Gloves", "Boots"):
        amascut[f"{p} of Tumeken's resplendence"] = _enrage_item(list(zip(tiers, resp)))
    amascut["Shard of Genesis Essence"] = _enrage_item(list(zip(tiers, shard)))
    amascut["The Devourer's Nexus (unattuned)"] = _enrage_item(list(zip(tiers, nexus)))
    out["Amascut, the Devourer"] = amascut
    return out


# Bosses with no collection-log drops (or none worth tracking); left out entirely, so the API ignores their kills.
EXCLUDED_BOSSES = {
    "Abomination", "Demon boss", "Glod", "Giant Sea Snake", "Skeletal horror",
    "TokTz-Ket-Dill (monster)", "Tormented wraith", "The Ghrazi Blood Knights", "Phoenix",
}

# Bosses missing from the original scrape, added by hand from their wiki pages.
def _fixed(num, den, table):
    return {"rate": num / den, "rolls": 1, "rarity": f"{num}/{den}", "table": table}


MANUAL_BOSSES = {
    # Shield roll 1/80, then 1/240 per shield (the wiki gives 1/240 per shield overall). Malevolent energy (always
    # dropped) and the bobbleheads (achievement unlocks) are not rate-based, so they are left out.
    "The Barrows: Rise of the Six": {
        "Malevolent kiteshield": _fixed(1, 240, "Unique"),
        "Merciless kiteshield": _fixed(1, 240, "Unique"),
        "Vengeful kiteshield": _fixed(1, 240, "Unique"),
        "Rise of the Six chest": _fixed(1, 500, "Tertiary"),
    },
}

# Different names for the same encounter (identical drop lists on the wiki). canonical -> aliases. The server
# rewrites an alias to its canonical name on every event and lookup, so the plugin may send either.
# Deliberately NOT merged: bosses that merely look alike but have their own kill count and loot (Nex vs Nex, Angel
# of Death, the two Kalphite queens, the Legios, Osseous).
BOSS_ALIASES = {
    "Araxxi": ["Araxxor"],
    "Vindicta & Gorvek": ["Gorvek", "Vindicta", "Gorvek and Vindicta"],
    "The Twin Furies": ["Avaryss, the Unceasing", "Nymora, the Vengeful"],
    # Merged to follow the wiki's "Boss kills" list, which has one entry for each of these.
    "Dagannoth Kings": ["Dagannoth Prime", "Dagannoth Rex", "Dagannoth Supreme"],
    "Rex Matriarchs": ["Orikalka", "Rathis", "Pthentraken"],  # Osseous stays its own entry, as on the wiki
    "TzTok-Jad": ["TzekHaar-Aken"],
    "The Barrows: Rise of the Six": ["Rise of the Six", "Barrows: Rise of the Six", "Rise of the Six (boss)"],
}


def merge_aliases(out: dict) -> dict:
    """Fold each alias's items into its canonical boss (canonical's own lines win) and return alias -> canonical."""
    alias_map = {}
    for canon, aliases in BOSS_ALIASES.items():
        merged = out.setdefault(canon, {})
        for alias in aliases:
            for item, cfg in out.pop(alias, {}).items():
                merged.setdefault(item, cfg)
            alias_map[alias] = canon
    return alias_map


def apply_enrage(out: dict) -> None:
    """Replace the scraped lines of enrage-dependent items (and their "[variant]" duplicates)."""
    for boss, items in _enrage_overrides().items():
        existing = out.setdefault(boss, {})
        for name in items:
            for key in [k for k in existing if k == name or k.startswith(name + " [")]:
                del existing[key]
        existing.update(items)


def main() -> None:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    meta = {k: v for k, v in data.items() if k.startswith("_")}
    out, dropped = dict(meta), []
    for boss, items in data.items():
        if boss.startswith("_") or boss in EXCLUDED_BOSSES:
            continue
        kept = {i: c for i, c in items.items() if is_rare(boss, i, c)}
        dropped += [(boss, i, c) for i, c in items.items() if i not in kept]
        if kept:
            out[boss] = kept
    for boss, items in MANUAL_BOSSES.items():
        out.setdefault(boss, {}).update(items)
    out["_aliases"] = merge_aliases(out)
    apply_enrage(out)
    out["_note"] = (
        "Rare drops only, filtered from wiki_drops_raw.json by tools/curate_rare.py (wiki rare/unique tables). "
        + meta.get("_note", "")
    )
    DST.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    bosses = [b for b in out if not b.startswith("_")]
    print(f"kept {sum(len(out[b]) for b in bosses)} items across {len(bosses)} bosses")
    if "--report" in sys.argv:
        print("\nExcluded lines that are 1/100 or rarer (check none should be kept):")
        for boss, item, c in dropped:
            if c.get("rate", 1.0) <= 1 / 100:
                print(f"  {boss}: {item} {c['rarity']} [{c.get('table')}]")


if __name__ == "__main__":
    main()
