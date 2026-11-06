"""Import an account's kill counts and drops from a CSV, until the in-game plugin can send them itself.

    python tools/import_account.py --template my_account.csv        # a CSV listing every tracked boss and item
    python tools/import_account.py --register --username "Zezima" my_account.csv
    python tools/import_account.py --token <token> my_account.csv   # later runs (token from DROP_TRACKER_TOKEN too)
    python tools/import_account.py --dry-run my_account.csv         # check names and see what would be sent

CSV columns (header required, extra rows and blank cells are fine):

    boss      boss name as in rare_drops.json (aliases such as "Araxxor" work; case does not matter)
    kills     your total kill count for that boss. Fill it on ONE row per boss.
    first_kc  optional. Kill count tracking starts from (default 1 = count every kill you have).
    enrage    optional. Typical enrage % for the boss's kills; sent with every kill. Telos, Zamorak, Arch-Glacor and
              Amascut drop chances depend on it, so leave it blank only if you do not know.
    item      a rare item from that boss (one row per item; the template lists them all)
    drops     how many you received. Blank means none, unless drop_kcs is filled (then it is their count).
    drop_kcs  optional, `;`-separated kill counts you got them at, e.g. 230;1040. Without it the drops are spread
              evenly across your kills, which only matters for items whose chance depends on kill count or enrage.

Re-running is safe: every event has a fixed id and the server ignores ones it already has. Raising `kills` and running
again adds the new kills.
"""
import argparse
import csv
import difflib
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RATES = ROOT / "rare_drops.json"
BATCH = 500  # API limit per request
COLUMNS = ["boss", "kills", "first_kc", "enrage", "item", "drops", "drop_kcs"]


def load_rates(path: Path = RATES):
    data = json.loads(path.read_text(encoding="utf-8"))
    bosses = {k: v for k, v in data.items() if not k.startswith("_")}
    return bosses, data.get("_aliases", {})


def write_template(path: Path, rates: dict) -> int:
    rows = 0
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        for boss in sorted(rates):
            w.writerow([boss, "", "", "", "", "", ""])  # fill `kills` (and optionally first_kc / enrage) here
            for item in rates[boss]:
                w.writerow([boss, "", "", "", item, "", ""])  # fill `drops` (and optionally drop_kcs) for what you got
            rows += 1 + len(rates[boss])
    return rows


def _eid(*parts) -> str:
    return "imp-" + hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:20]


def _int(value, what, line, warnings, minimum=0):
    value = (value or "").strip().replace(",", "")
    if not value:
        return None
    try:
        n = int(value)
    except ValueError:
        warnings.append(f"line {line}: {what} {value!r} is not a whole number, ignored")
        return None
    if n < minimum:
        warnings.append(f"line {line}: {what} {n} is below {minimum}, ignored")
        return None
    return n


def _match(name: str, choices, aliases: dict = None, kind: str = "name"):
    """Case-insensitive exact match, then alias; None with a suggestion message if there is no match."""
    lookup = {c.lower(): c for c in choices}
    key = name.strip().lower()
    if key in lookup:
        return lookup[key], None
    for alias, canon in (aliases or {}).items():
        if alias.lower() == key and canon in choices:
            return canon, None
    near = difflib.get_close_matches(key, list(lookup), n=2, cutoff=0.6)
    hint = f" Did you mean {' or '.join(repr(lookup[n]) for n in near)}?" if near else ""
    return None, f"unknown {kind} {name!r}.{hint}"


def parse_rows(rows, rates: dict, aliases: dict):
    """CSV rows -> {boss: {"kills", "first", "enrage", "drops": {item: [kc, ...]}}}, warnings."""
    warnings, bosses = [], {}
    for line, row in enumerate(rows, start=2):  # line 1 is the header
        boss_raw = (row.get("boss") or "").strip()
        if not boss_raw:
            continue
        boss, err = _match(boss_raw, rates, aliases, "boss")
        if err:
            warnings.append(f"line {line}: {err} Row skipped.")
            continue
        b = bosses.setdefault(boss, {"kills": None, "first": None, "enrage": None, "drops": {}, "pending": []})
        kills = _int(row.get("kills"), "kills", line, warnings, 1)
        if kills is not None:
            b["kills"] = kills
        first = _int(row.get("first_kc"), "first_kc", line, warnings, 1)
        if first is not None:
            b["first"] = first
        enrage = _int(row.get("enrage"), "enrage", line, warnings, 0)
        if enrage is not None:
            b["enrage"] = enrage
        item_raw = (row.get("item") or "").strip()
        if not item_raw:
            continue
        item, err = _match(item_raw, rates[boss], kind=f"item for {boss}")
        if err:
            warnings.append(f"line {line}: {err} Row skipped.")
            continue
        count = _int(row.get("drops"), "drops", line, warnings, 0)
        kcs = [_int(x, "drop_kcs entry", line, warnings, 1) for x in (row.get("drop_kcs") or "").split(";") if x.strip()]
        kcs = [k for k in kcs if k is not None]
        if count is None:  # blank = none received, unless the kill counts were listed
            count = len(kcs)
        if kcs and count != len(kcs):
            warnings.append(f"line {line}: {item}: drops={count} but {len(kcs)} drop_kcs given; using {len(kcs)}")
            count = len(kcs)
        if count > 0:
            b["pending"].append((line, item, count, kcs))
    return bosses, warnings


def build_events(bosses: dict, warnings: list):
    """Turn parsed bosses into API events. Drops are placed at their kcs or spread evenly over the kill range."""
    events = []
    for boss, b in bosses.items():
        last_drop = max((k for _, _, _, kcs in b["pending"] for k in kcs), default=None)
        kills = b["kills"] if b["kills"] is not None else last_drop
        if kills is None:
            if b["pending"]:
                warnings.append(f"{boss}: has drops but no kills (fill `kills`); skipped")
            continue
        first = b["first"] or 1
        if first > kills:
            warnings.append(f"{boss}: first_kc {first} is above kills {kills}; skipped")
            continue
        kc_list = range(first, kills + 1) if b["enrage"] is not None else sorted({first, kills})
        for kc in kc_list:  # every kill is sent when enrage is known, since enrage is stored per kill
            ev = {"type": "kill", "event_id": _eid(boss, "kill", kc), "boss": boss, "kc": kc}
            if b["enrage"] is not None:
                ev["enrage"] = b["enrage"]
            events.append(ev)
        for line, item, count, kcs in b["pending"]:
            if not kcs:
                kcs = [first + round((i + 1) * (kills - first) / (count + 1)) for i in range(count)]
            for i, kc in enumerate(kcs):
                if not first <= kc <= kills:
                    warnings.append(f"line {line}: {boss} / {item}: drop kc {kc} is outside {first}-{kills}; moved inside")
                    kc = min(max(kc, first), kills)
                events.append({"type": "drop", "event_id": _eid(boss, item, "drop", i, kc), "boss": boss,
                               "item": item, "kc": kc})
    return events


def call(api: str, path: str, token: str = None, body=None):
    req = urllib.request.Request(
        api.rstrip("/") + path,
        data=None if body is None else json.dumps(body).encode(),
        method="POST" if body is not None else "GET",
        headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{path} failed: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Could not reach {api} ({e.reason}). Is the server running?")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", type=Path, help="account CSV to import (or the file to write with --template)")
    ap.add_argument("--template", action="store_true", help="write a CSV listing every boss and item, then exit")
    ap.add_argument("--api", default="http://localhost:8000", help="API base URL (default %(default)s)")
    ap.add_argument("--token", default=os.environ.get("DROP_TRACKER_TOKEN"), help="player token (or DROP_TRACKER_TOKEN)")
    ap.add_argument("--register", action="store_true", help="create a new player first and print its token (shown once)")
    ap.add_argument("--username", help="in-game name to publish this player's page under")
    ap.add_argument("--private", action="store_true", help="with --username: link the name but keep the page hidden")
    ap.add_argument("--dry-run", action="store_true", help="validate and summarise, send nothing")
    args = ap.parse_args(argv)

    rates, aliases = load_rates()
    if args.template:
        n = write_template(args.csv, rates)
        print(f"Wrote {n} rows ({len(rates)} bosses) to {args.csv}. Fill `kills` once per boss and `drops` per item.")
        return 0

    with open(args.csv, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        missing = {"boss", "kills", "item"} - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(f"{args.csv} is missing column(s): {', '.join(sorted(missing))}")
        bosses, warnings = parse_rows(list(reader), rates, aliases)
    events = build_events(bosses, warnings)
    n_kill = sum(e["type"] == "kill" for e in events)
    for w in warnings:
        print("warning:", w)
    print(f"{len(bosses)} bosses -> {n_kill} kill events + {len(events) - n_kill} drop events")
    if args.dry_run or not events:
        print("Dry run, nothing sent." if args.dry_run else "Nothing to send.")
        return 0

    token = args.token
    if args.register:
        token = call(args.api, "/v1/players", body={})["token"]
        print(f"Registered a new player. TOKEN (shown once, save it): {token}")
    if not token:
        raise SystemExit("Need --token (or DROP_TRACKER_TOKEN), or --register to create a player.")

    accepted = ignored = 0
    for i in range(0, len(events), BATCH):
        r = call(args.api, "/v1/events", token, {"events": events[i:i + BATCH]})
        accepted += r["accepted"]
        ignored += r["ignored"]
    print(f"Sent {len(events)} events: {accepted} new, {len(events) - accepted - ignored} already stored, {ignored} ignored")
    if args.username:
        r = call(args.api, "/v1/me/profile", token, {"username": args.username, "public": not args.private})
        print(f"Linked name {r['username']!r} ({'public' if r['public'] else 'hidden'})")
        if r["public"]:
            print(f"View it at {args.api.rstrip('/')}/#{r['username'].replace(' ', '%20')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
