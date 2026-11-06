"""Build tools/clog_extra_rates.json: display-only drop rates for collection-log items that rare_drops.json lacks.

Reads the RuneScape Wiki (wikitext via the MediaWiki API, in memory only) for the pages behind the boss
collection log, using the list of items the plugin could not label (its `clog_unmatched` storage entry,
exported to a text file: one "<page title>\\t<item>; <item>" line per page).

    python tools/fetch_clog_extras.py <clog_unmatched.txt>

Rules (decided with the user):
  * lore books are skipped (names below), as are items that always drop or are far too common to be a "dry" stat;
  * enrage- and killstreak-based bosses (Telos, Arch-Glacor, Zamorak, Amascut) get no flat item rates;
  * elite-dungeon items depend on mode and team size, so only their pets are included;
  * boss pets use the wiki's bad-luck formula: chance = (1 + min(floor(kills / threshold), 9)) / base, stored as
    {"base": "1/D", "threshold": T, "hard_base": "1/H"}; kills are normal + hard together for the threshold, with the
    hard-mode share using the hard-mode base.
After running, regenerate the plugin data with `python tools/gen_lua_rates.py`.
"""
import ast
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "tools" / "clog_extra_rates.json"
UA = "rs-drop-tracker-api/0.1 (personal project)"

# collection-log page title -> wiki pages that hold its drop tables
PAGES = {
    "Liberation of Mazcab": ["Beastmaster Durzag", "Yakamaru"],
    "Gregorovic": ["Gregorovic"],
    "Helwyr": ["Helwyr"],
    "The Twin Furies": ["Twin Furies"],
    "Vindicta & Gorvek": ["Vindicta & Gorvek"],
    "Kerapac": ["Kerapac, the bound"],
    "Araxxi": ["Araxxi"],
    "Solak": ["Solak, Guardian of the Grove"],
    "Rasial": ["Rasial, the First Necromancer"],
    "The Magister": ["The Magister"],
    "Silverquill": ["Silverquill, the Dreadhog"],
    "Zemouregal & Vorkath": ["Zemouregal & Vorkath"],
    "The Barrows Brothers": ["Ahrim the Blighted", "Dharok the Wretched", "Guthan the Infested", "Karil the Tainted",
                             "Torag the Corrupted", "Verac the Defiled", "Akrisae the Doomed", "Linza the Disgraced"],
    "Rex Matriarchs": ["Orikalka", "Rathis", "Pthentraken"],
    "Rex Matriarch: Osseous": ["Osseous"],
    "Dagannoth Kings": ["Dagannoth Rex", "Dagannoth Prime", "Dagannoth Supreme"],
    "Chaos Elemental": ["Chaos Elemental"],
    "King Black Dragon": ["King Black Dragon"],
    "Kalphite Queen": ["Kalphite Queen"],
    "Giant Mole": ["Giant mole"],
    "Flesh-hatcher Mhekarnahz": ["Flesh-hatcher Mhekarnahz"],
    "Commander Zilyana": ["Commander Zilyana"],
    "Corporeal Beast": ["Corporeal Beast"],
    "Croesus": ["Croesus"],
    "The Gate of Elidinis": ["The Gate of Elidinis"],
    "Hermod": ["Hermod, the Spirit of War"],
    "Ivar": ["Ivar, King of Bones"],
    "K'ril Tsutsaroth": ["K'ril Tsutsaroth"],
    "Raksha": ["Raksha, the Shadow Colossus"],
    "TzKal-Zuk": ["TzKal-Zuk"],
    "Sanctum of Rebirth": ["Vermyx, Brood Mother", "Kezalam, the Wanderer", "Nakatra, Devourer Eternal"],
    "Queen Black Dragon": ["Queen Black Dragon"],
    "Nex": ["Nex"],
    "Nex, Angel of Death": ["Nex: Angel of Death"],
    "Legiones": ["Legio Primus"],
    "Kree'arra": ["Kree'arra"],
    "General Graardor": ["General Graardor"],
    "Vorago": ["Vorago"],
    "The Barrows: Rise of the Six": ["Barrows: Rise of the Six"],
}
# bosses whose drop chances depend on enrage / killstreak: no flat item rates (pets are still included)
ENRAGE_PAGES = {"Telos", "Arch-Glacor", "Zamorak", "Amascut"}
# elite dungeons: item chances depend on mode and team size (pets only)
ELITE_PAGES = {"Dragonkin Laboratory", "The Shadow Reef", "Temple of Aminishi"}
# standard chance of each Warpriest piece (the wiki template DropsLineWarpriest is shared by the four gods)
WARPRIEST = {"Commander Zilyana": "Saradomin", "K'ril Tsutsaroth": "Zamorak", "Kree'arra": "Armadyl",
             "General Graardor": "Bandos"}
WARPRIEST_PIECES = ["helm", "cape", "cuirass", "greaves", "gauntlets", "boots"]
# Items deliberately given no label (decided with the user): the Rex Matriarchs share one kill count, so only their
# shared drops are scored (see REX_SHARED in curate_rare.py), and Osseous' pet is left out.
NO_LABEL_ITEMS = {"Baby osseous"}

LORE = {n.lower() for n in [
    "Saradomin's hum", "Zilyana's Notes", "Razulei's Tale", "Armadyl's Assault", "The Glory of General Graardor",
    "The Promised Gift", "The Praesul", "Kranon's Ancient Journal", "After The Flood", "The Last Offering",
    "The Brood Mother", "The Beast of Darkness", "Death and Devourers", "The Minister", "Himiko's Vision",
    "Crassian Allegiance", "Nex's Followers", "Memoirs of the Devourer", "Diary of an Overzealous Gnome",
    "Redacted Dragonkin Research",
]}
LORE_WORDS = re.compile(r"journal|\bnotes\b|\bdiary\b|memoirs|\btale\b|biography", re.I)
MAX_RATE = 0.2  # anything commoner than 1 in 5 is not a meaningful dry statistic
# Independent rolls of a flat per-roll chance per kill, best case (decided with the user). Croesus rolls its reward table
# up to 12 times at top contribution; the wiki lists 1/5400 per roll for each of its nine uniques ("altrarity" 1/441 is
# the whole-kill chance at that roll count). The plugin cannot see the contribution factor, so it assumes the best case.
ROLLS_PER_KILL = {"Croesus": 12}
# Pages with no percentages (decided with the user): several sub-bosses, each with its own items and kill count, so a
# page-level kill count cannot give any item a dry percentage. Kept in step with NO_LABELS in gen_lua_rates.py.
NO_LABEL_PAGES = {"Legiones", "Rex Matriarchs"}


def is_lore(name):
    return name.lower() in LORE or bool(LORE_WORDS.search(name))


def wikitext(title):
    url = "https://runescape.wiki/api.php?" + urllib.parse.urlencode(
        {"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
         "titles": title, "format": "json", "formatversion": "2", "redirects": "1"})
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30) as r:
        page = json.load(r)["query"]["pages"][0]
    time.sleep(0.4)  # be polite to the wiki
    return page["revisions"][0]["slots"]["main"]["content"] if "revisions" in page else None


def balanced(t, start):
    depth, i = 0, start
    while i < len(t) - 1:
        two = t[i:i + 2]
        if two == "{{":
            depth += 1; i += 2
        elif two == "}}":
            depth -= 1; i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return len(t)


def split_params(body):
    parts, depth, cur, i = [], 0, "", 0
    while i < len(body):
        two = body[i:i + 2]
        if two in ("{{", "[["):
            depth += 1; cur += two; i += 2; continue
        if two in ("}}", "]]"):
            depth -= 1; cur += two; i += 2; continue
        if body[i] == "|" and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += body[i]
        i += 1
    parts.append(cur)
    return parts


def drop_lines(t):
    """[(name, rarity, version)] for every {{DropsLine}} on a boss page."""
    out, version, pos = [], None, 0
    # DropsLine plus its variants that take a name= (DropsLineReward, DropsLineTriskelion, ...)
    for m in re.finditer(r"\{\{(DropsTableHead|DropsLine\w*)", t):
        if m.start() < pos:
            continue
        end = balanced(t, m.start())
        params = split_params(t[m.start() + 2:end - 2])
        kv = {}
        for p in params[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                kv[k.strip()] = v.strip()
        if params[0].strip() == "DropsTableHead":
            version = kv.get("version")
        elif kv.get("name"):
            out.append((kv["name"], kv.get("rarity", ""), version or ""))
        pos = end
    return out


def safe_eval(expr):
    node = ast.parse(expr, mode="eval")
    for n in ast.walk(node):
        if not isinstance(n, (ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant, ast.Add, ast.Sub, ast.Mult,
                              ast.Div, ast.USub, ast.UAdd)):
            raise ValueError("unsafe expression")
    return eval(compile(node, "<expr>", "eval"), {"__builtins__": {}}, {})


def parse_rarity(text):
    """'1/768' / '8/512' / '1/{{#expr:1/(19/20 * 1/30) round 1}}' -> per-kill chance, or None."""
    text = re.sub(r"<!--.*?-->", "", text).strip()
    text = re.sub(r"\{\{#expr:\s*(.*?)\s*(?:round\s*\d+)?\s*\}\}",
                  lambda m: repr(safe_eval(m.group(1))), text)
    m = re.fullmatch(r"([\d,.]+)\s*/\s*([\d,.]+)", text)
    if not m:
        return None
    return float(m.group(1).replace(",", "")) / float(m.group(2).replace(",", ""))


def pick(lines, item):
    """Normal-mode chance for `item` among a boss page's lines."""
    hits = [(v, r) for n, r, v in lines if n.lower() == item.lower()]
    for want in ("normal", ""):
        for v, r in hits:
            vl = v.lower()
            if (want and want in vl and not re.search(r"story|duo|trio|solo", vl)) or (not want and not vl):
                p = parse_rarity(r) if r else None
                if p:
                    return p
    for v, r in hits:
        p = parse_rarity(r) if r else None
        if p:
            return p
    return None


def pets_table():
    """{pet name (lower): (base denominator, threshold, hard-mode denominator or None)} from the wiki's Boss pets page."""
    t = wikitext("Boss pets")
    i = t.find("==Boss pets unlocked by item drops==")
    j = t.find("==Boss pets unlocked through other methods==")
    out = {}
    for row in re.split(r"^\|-\s.*$", t[i:j], flags=re.M)[1:]:
        cells = [l[1:].strip() for l in row.splitlines() if l.startswith("|") and not l.startswith(("|}", "|-"))]
        if len(cells) < 5:
            continue
        pm = re.search(r"plinkt\|([^|}]+)(?:\|[^}]*?txt=([^|}]+))?", cells[0])
        if not pm:
            continue
        name = (pm.group(2) or pm.group(1)).strip()
        denom_cell = re.sub(r"\{\{.*?\}\}", "", cells[3])
        base = re.match(r"\s*([\d,]+)", denom_cell)
        thr = re.match(r"\s*([\d,]+)", re.sub(r"\{\{.*?\}\}", "", cells[4]))
        hard = re.search(r"\(\s*([\d,]+)\s+in\s+(?:hard|challenge)\s+mode\s*\)", denom_cell)  # e.g. "2,500 (500 in hard mode)"
        if base and thr:
            out[name.lower()] = (int(base.group(1).replace(",", "")), int(thr.group(1).replace(",", "")),
                                 int(hard.group(1).replace(",", "")) if hard else None)
    return out


def pet_entry(base, thr, hard):
    entry = {"base": f"1/{base}", "threshold": thr, "note": "boss pet; bad-luck threshold"}
    if hard:
        entry["hard_base"] = f"1/{hard}"
    return entry


def main(gap_file):
    gaps = {}
    for line in pathlib.Path(gap_file).read_text(encoding="utf-8").splitlines():
        if "\t" in line:
            title, items = line.split("\t", 1)
            gaps[title] = [i.strip() for i in items.split("; ") if i.strip()]
    pets = pets_table()
    print("pets in wiki table:", len(pets))

    result, skipped = {}, {"lore": [], "always/rare/unknown": [], "enrage": [], "elite": [], "no source": []}
    for title, items in sorted(gaps.items()):
        if title in NO_LABEL_PAGES:
            skipped["no labels (sub-bosses)"] = skipped.get("no labels (sub-bosses)", []) + [f"{title}: {i}" for i in items]
            continue
        lines = []
        for page in PAGES.get(title, []):
            t = wikitext(page)
            lines += drop_lines(t) if t else []
        entries = {}
        for item in items:
            if item in NO_LABEL_ITEMS:
                continue
            if is_lore(item):
                skipped["lore"].append(f"{title}: {item}")
                continue
            if item.lower() in pets:
                entries[item] = pet_entry(*pets[item.lower()])
                continue
            if title in ENRAGE_PAGES:
                skipped["enrage"].append(f"{title}: {item}")
                continue
            if title in ELITE_PAGES:
                skipped["elite"].append(f"{title}: {item}")
                continue
            god = WARPRIEST.get(title)
            if god and item.startswith(f"Warpriest of {god}"):
                entries[item] = {"rate": "1/768", "note": "Warpriest piece; any piece is 1/128"}
                continue
            p = pick(lines, item) if lines else None
            if p is None:
                skipped["always/rare/unknown" if lines else "no source"].append(f"{title}: {item}")
            elif p > MAX_RATE:
                skipped["always/rare/unknown"].append(f"{title}: {item} (chance {p:.2f} is too common)")
            else:
                entries[item] = {"rate": round(p, 8)}
        if entries:
            result[title] = entries

    # Keep earlier entries for pages not in this run (a page drops out of the gap list once it is covered),
    # but never lore books, whatever an older run or a hand edit put there.
    kept = {}
    if OUT.exists():
        for page, entries in json.loads(OUT.read_text(encoding="utf-8")).items():
            if page.startswith("_") or page in NO_LABEL_PAGES:
                continue
            keep = {i: v for i, v in entries.items() if not is_lore(i) and i not in NO_LABEL_ITEMS}
            for item in list(keep):  # pets are always refreshed from the wiki table (older flat entries, new fields)
                if item.lower() in pets:
                    keep[item] = pet_entry(*pets[item.lower()])
            if keep:
                kept[page] = keep
    for page, entries in result.items():
        kept.setdefault(page, {}).update(entries)
    for page, entries in kept.items():  # per-roll chances become per-kill binomials: n = kills * rolls
        for entry in entries.values():
            if page in ROLLS_PER_KILL and "rate" in entry and "base" not in entry:
                entry["rolls"] = ROLLS_PER_KILL[page]
                entry["note"] = f"{ROLLS_PER_KILL[page]} independent rolls per kill (best case, top contribution)"
    result = dict(sorted(kept.items()))

    doc = {"_note": __doc__.split("\n\n")[0].strip() + " Generated by tools/fetch_clog_extras.py; edit that script's "
                    "rules rather than this file. Rates are per kill, normal mode, from runescape.wiki."}
    doc.update(result)
    OUT.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    n = sum(len(v) for v in result.values())
    print(f"wrote {OUT.relative_to(ROOT)}: {n} items on {len(result)} pages")
    for why, lst in skipped.items():
        print(f"\nskipped ({why}): {len(lst)}")
        for x in lst:
            print("   ", x)


if __name__ == "__main__":
    main(sys.argv[1])
