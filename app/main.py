import hashlib
import hmac
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Literal, Optional, Union

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from functools import lru_cache

from . import clog_rates, db
from .stats import lifetime_luck, luck, luck_from_probs, luck_threshold, per_kill_probability

RATES_PATH = Path(os.environ.get("DROP_RATES", Path(__file__).parent.parent / "rare_drops.json"))
# Display-only rates (pets, set pieces, multi-roll bosses) used for the collection-log luck figures.
CLOG_EXTRA_PATH = Path(os.environ.get("DROP_CLOG_EXTRA", Path(__file__).parent.parent / "tools" / "clog_extra_rates.json"))

app = FastAPI(title="RS Drop Tracker API", version="0.3.0")

_NAME_RE = re.compile(r"[A-Za-z0-9 \-]{1,12}")
STATIC_DIR = Path(__file__).parent / "static"


@app.on_event("startup")
def _startup() -> None:
    db.init()
    purge_untracked()


def load_rates() -> dict:
    with open(RATES_PATH, encoding="utf-8") as f:
        return {k: v for k, v in json.load(f).items() if not k.startswith("_")}


def load_aliases() -> dict:
    """alias -> canonical boss name (rare_drops.json "_aliases"), for bosses known by several names."""
    with open(RATES_PATH, encoding="utf-8") as f:
        return json.load(f).get("_aliases", {})


def canon(boss: str) -> str:
    return load_aliases().get(boss, boss)


@lru_cache(maxsize=4)
def _clog_rates_cached(rare: str, extra: str, rare_mtime: int, extra_mtime: int) -> dict:
    return clog_rates.load(Path(rare), Path(extra))[0]


def clog_rate_table() -> dict:
    """rates[boss][item] -> spec, the same table the plugin's rates.lua is generated from. Reloaded if a file changes."""
    def mtime(p: Path) -> int:
        return p.stat().st_mtime_ns if p.exists() else 0
    return _clog_rates_cached(str(RATES_PATH), str(CLOG_EXTRA_PATH), mtime(RATES_PATH), mtime(CLOG_EXTRA_PATH))


def purge_untracked() -> int:
    """Rename stored alias boss names to their canonical name, then delete stored events that are not rare drops
    (or kills of bosses with none), e.g. from before the rare-only rule or after rare_drops.json was narrowed.
    Returns the number of rows removed."""
    rates = load_rates()
    removed = 0
    with db.connect() as conn:
        for alias, name in load_aliases().items():
            for table in ("kill_events", "drop_events"):
                conn.execute(f"UPDATE {table} SET boss = ? WHERE boss = ?", (name, alias))
        for b, i in conn.execute("SELECT DISTINCT boss, item FROM drop_events").fetchall():
            if i not in rates.get(b, {}):
                removed += conn.execute("DELETE FROM drop_events WHERE boss = ? AND item = ?", (b, i)).rowcount
        for (b,) in conn.execute("SELECT DISTINCT boss FROM kill_events").fetchall():
            if b not in rates:
                removed += conn.execute("DELETE FROM kill_events WHERE boss = ?", (b,)).rowcount
    return removed


def get_rate(boss: str, item: str) -> dict:
    try:
        return load_rates()[canon(boss)][item]
    except KeyError:
        raise HTTPException(404, f"No configured drop rate for {boss!r} / {item!r}")


# --- auth -------------------------------------------------------------------

def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def current_player(authorization: Annotated[Optional[str], Header()] = None) -> str:
    """Resolve 'Authorization: Bearer <player_id>.<secret>' to a player id."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Missing bearer token")
    token = authorization[7:]
    player_id, _, _ = token.partition(".")
    with db.connect() as conn:
        row = conn.execute("SELECT token_hash FROM players WHERE id = ?", (player_id,)).fetchone()
    if not row or not hmac.compare_digest(row["token_hash"], _hash(token)):
        raise HTTPException(401, "Invalid token")
    return player_id


Player = Annotated[str, Depends(current_player)]


# --- models -----------------------------------------------------------------

class KillEvent(BaseModel):
    type: Literal["kill"]
    event_id: str = Field(min_length=1, max_length=64)
    boss: str = Field(min_length=1, max_length=64)
    kc: int = Field(ge=1, description="Kill count AFTER this kill, as shown in game")
    enrage: Optional[int] = Field(
        default=None, ge=0, le=100000,
        description="Enrage % of this kill. Needed for bosses whose rare drops vary with enrage; omitted = treated as 0.",
    )
    streak: Optional[int] = Field(
        default=None, ge=1, le=100000,
        description="Killstreak INCLUDING this kill (kills since loot was last claimed). Needed for Telos and "
                    "Arch-Glacor; omitted = 1.",
    )
    ts: Optional[datetime] = None


class DropEvent(BaseModel):
    type: Literal["drop"]
    event_id: str = Field(min_length=1, max_length=64)
    boss: str = Field(min_length=1, max_length=64)
    item: str = Field(min_length=1, max_length=64)
    quantity: int = Field(default=1, ge=1)
    kc: int = Field(ge=1, description="Kill count of the kill that produced the drop")
    ts: Optional[datetime] = None


class CollectionEntry(BaseModel):
    boss: str = Field(min_length=1, max_length=64)
    item: str = Field(min_length=1, max_length=64)
    kills: int = Field(ge=0, le=100_000_000, description="Lifetime normal-mode kills of the boss, from the game")
    hard_kills: int = Field(default=0, ge=0, le=100_000_000, description="Lifetime hard-mode kills, where the boss has them")
    count: int = Field(ge=0, le=1_000_000, description="How many of the item the player has (0 = missing)")


class CollectionBatch(BaseModel):
    entries: list[CollectionEntry] = Field(max_length=500)


Event = Annotated[Union[KillEvent, DropEvent], Field(discriminator="type")]


class EventBatch(BaseModel):
    events: list[Event] = Field(max_length=500)


# --- endpoints --------------------------------------------------------------

@app.post("/v1/players", status_code=201)
def register_player():
    """Create an anonymous player id + token. The token is shown once; store it in the plugin config."""
    player_id = secrets.token_hex(8)
    token = f"{player_id}.{secrets.token_urlsafe(32)}"
    with db.connect() as conn:
        conn.execute("INSERT INTO players (id, token_hash) VALUES (?, ?)", (player_id, _hash(token)))
    return {"player_id": player_id, "token": token}


@app.post("/v1/events")
def submit_events(batch: EventBatch, player: Player):
    """Idempotent: re-sending an event_id is ignored, so the plugin can safely retry.

    Only rare drops (those in rare_drops.json) and kills of bosses that have one are stored; the rest count as `ignored`.
    """
    accepted = ignored = 0
    rates = load_rates()
    aliases = load_aliases()
    with db.connect() as conn:
        for e in batch.events:
            e.boss = aliases.get(e.boss, e.boss)  # one canonical name per boss, whichever the plugin sent
            # Only rare drops are tracked: rare_drops.json lists them. A drop of anything else is discarded, and
            # so are kills of bosses with no rare drop listed (their kill count would never be used).
            tracked = e.item in rates.get(e.boss, {}) if isinstance(e, DropEvent) else e.boss in rates
            if not tracked:
                ignored += 1
                continue
            ts = (e.ts or datetime.now(timezone.utc)).isoformat()
            key = f"{player}:{e.event_id}"
            if isinstance(e, KillEvent):
                cur = conn.execute(
                    "INSERT OR IGNORE INTO kill_events (event_id, player_id, boss, kc, enrage, streak, ts)"
                    " VALUES (?,?,?,?,?,?,?)",
                    (key, player, e.boss, e.kc, e.enrage, e.streak, ts),
                )
            else:
                cur = conn.execute(
                    "INSERT OR IGNORE INTO drop_events (event_id, player_id, boss, item, quantity, kc, ts)"
                    " VALUES (?,?,?,?,?,?,?)",
                    (key, player, e.boss, e.item, e.quantity, e.kc, ts),
                )
            accepted += cur.rowcount
    return {"received": len(batch.events), "accepted": accepted, "ignored": ignored}


class Profile(BaseModel):
    username: str = Field(min_length=1, max_length=12)
    public: bool = True


def normalize_username(name: str) -> str:
    """RS names treat space, underscore and non-breaking space alike; compare case-insensitively."""
    name = re.sub(r"[ _\u00a0]+", " ", name).strip()
    if not _NAME_RE.fullmatch(name):
        raise HTTPException(422, "Invalid username (1-12 letters, digits, spaces or hyphens)")
    return name


@app.post("/v1/me/profile")
def set_profile(profile: Profile, player: Player):
    """Opt in (or out) of the public website lookup, like WikiSync.

    While public, anyone who knows the username can see the stats below. Set public=false to hide them.
    """
    name = normalize_username(profile.username)
    with db.connect() as conn:
        taken = conn.execute(
            "SELECT id FROM players WHERE lower(username) = lower(?) AND id != ?", (name, player)
        ).fetchone()
        if taken:
            raise HTTPException(409, "That username is already linked to another plugin install")
        conn.execute(
            "UPDATE players SET username = ?, public = ? WHERE id = ?", (name, int(profile.public), player)
        )
    return {"username": name, "public": profile.public}


def _summary(conn, player_id: str) -> dict:
    """Every tracked boss (all of rare_drops.json), with luck for each rare item.

    Bosses the player has no events for come back with zero kills and no luck, so the website can show the full
    list like a collection log. `has_data` marks the ones with kills or drops.
    """
    rates = load_rates()
    with_data = {
        r["boss"]
        for r in conn.execute(
            "SELECT boss FROM kill_events WHERE player_id = ? UNION SELECT boss FROM drop_events WHERE player_id = ?",
            (player_id, player_id),
        )
    }
    bosses = []
    for boss in sorted(rates):
        items = []
        first = kills = 0
        for item, cfg in rates[boss].items():
            entry = {"item": item, "rate": cfg["rate"], "rarity": cfg.get("rarity"), "drops": 0,
                     "expected_drops": 0.0, "percentile": None}
            if boss in with_data:
                first, kills, drops = _tracked(conn, player_id, boss, item)
                r = _score(cfg, first, kills, drops, _context(conn, player_id, boss, cfg))
                entry.update(drops=drops, expected_drops=r["expected_drops"], percentile=r["percentile"])
            items.append(entry)
        items.sort(key=lambda i: (-i["drops"], i["rate"]))
        bosses.append({
            "boss": boss, "has_data": boss in with_data, "tracked_kills": kills, "first_kc": first, "items": items,
        })
    last = conn.execute(
        "SELECT MAX(ts) AS t FROM (SELECT ts FROM kill_events WHERE player_id = ? "
        "UNION ALL SELECT ts FROM drop_events WHERE player_id = ?)",
        (player_id, player_id),
    ).fetchone()["t"]
    return {"last_synced": last, "bosses": bosses}


@app.get("/v1/me/summary")
def my_summary(player: Player):
    """All of your synced data, whether or not you are public."""
    with db.connect() as conn:
        row = conn.execute("SELECT username, public FROM players WHERE id = ?", (player,)).fetchone()
        return {"username": row["username"], "public": bool(row["public"]), **_summary(conn, player)}


@app.get("/v1/players/{username}/summary")
def player_summary(username: str):
    """Public lookup by in-game name (what the website calls). 404 if unknown or not opted in."""
    name = normalize_username(username)
    with db.connect() as conn:
        row = conn.execute(
            "SELECT id, username FROM players WHERE lower(username) = lower(?) AND public = 1", (name,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "No public data for that player")
        return {"username": row["username"], **_summary(conn, row["id"])}


def uses_enrage(cfg: dict) -> bool:
    """True when the chance can differ between kills of the same boss (enrage, streak or mitigation)."""
    return "enrage" in cfg or "enrage_linear" in cfg or "streak" in cfg


def _tier(tiers: list, value: float, default=None):
    """Value of the last [min, ...] tier whose min is <= `value` (tiers sorted ascending)."""
    hit = default
    for t in tiers:
        if value >= t[0]:
            hit = t
    return hit


def rate_at(cfg: dict, enrage: int) -> float:
    """Per-roll chance at a given enrage %, ignoring streaks.

    "enrage" is a list of [min_enrage, rate] tiers (the highest tier whose min is <= enrage applies);
    "enrage_linear" is {"base", "per_pct"}. Anything else is a flat rate.
    """
    if "enrage_linear" in cfg:
        lin = cfg["enrage_linear"]
        return min(1.0, lin["base"] + lin["per_pct"] * enrage)
    tier = _tier(cfg.get("enrage", []), enrage)
    return tier[1] if tier else cfg["rate"]


def streak_rate(cfg: dict, enrage: int, reported_streak: int, dry: int) -> tuple[float, bool]:
    """(per-roll chance, whether this kill counts as a dry roll) for items with a "streak" rule.

    kind "formula" (Telos, Arch-Glacor): the drop group's chance is
        min(cap, mult(enrage) * (a + b*enrage + c*streak) / 1e6)
    using the killstreak the plugin reported for that kill; the item gets `share` of it.

    kind "blm" (Zamorak bad-luck mitigation): the item's tier rate (rate_at) is scaled by base_denom/eff_denom,
    where after `start` dry kills at >= min_enrage the signature denominator drops by `dec` per further dry
    kill, down to `cap`. `dry` is derived from the player's own history by the caller.
    """
    s = cfg["streak"]
    if s["kind"] == "formula":
        p = (s["a"] + s["b"] * enrage + s["c"] * reported_streak) / 1e6
        p = min(s.get("cap", 1.0), p * _tier(s.get("mult", [[0, 1.0]]), enrage, [0, 1.0])[1])
        return p * s["share"], True
    base = rate_at(cfg, enrage)
    if enrage < s["min_enrage"]:
        return base, False
    base_denom = _tier(s["base"], enrage)[1]
    _, dec, cap = _tier(s["tiers"], enrage, [0, 0, base_denom])
    eff = min(base_denom, max(cap, base_denom - dec * max(0, dry - s["start"])))
    return base * base_denom / eff, True


def _context(conn, player_id: str, boss: str, cfg: dict) -> dict:
    """Per-kill facts that change a drop's chance, for items that depend on them ({} otherwise)."""
    if not uses_enrage(cfg):
        return {}
    kills = conn.execute(
        "SELECT kc, enrage, streak FROM kill_events WHERE player_id = ? AND boss = ?", (player_id, boss)
    ).fetchall()
    ctx = {
        "enrage": {r["kc"]: r["enrage"] for r in kills if r["enrage"] is not None},
        "streak": {r["kc"]: r["streak"] for r in kills if r["streak"] is not None},
        "group_drops": set(),
    }
    group = cfg.get("streak", {}).get("group")
    if group:  # drops of any item in the same mitigation group reset the dry counter
        members = [i for i, c in load_rates().get(boss, {}).items() if c.get("streak", {}).get("group") == group]
        marks = ",".join("?" * len(members))
        ctx["group_drops"] = {
            r["kc"]
            for r in conn.execute(
                f"SELECT kc FROM drop_events WHERE player_id = ? AND boss = ? AND item IN ({marks})",
                (player_id, boss, *members),
            )
        }
    return ctx


def _score(cfg: dict, kc_first: int, kills: int, drops: int, ctx: Optional[dict] = None) -> dict:
    """Luck for one player.

    Chances can differ per kill (pet threshold growing with kc, rate depending on that kill's enrage, killstreak
    or bad-luck mitigation), in which case each kill gets its own probability. A kill with no reported enrage
    counts as 0% and no reported streak as 1. Dry counts for mitigation start at 0 on the first tracked kill.
    """
    rolls = cfg.get("rolls", 1)
    if uses_enrage(cfg):
        threshold = cfg.get("threshold")
        ctx = ctx or {}
        enrages, streaks, group_drops = ctx.get("enrage", {}), ctx.get("streak", {}), ctx.get("group_drops", set())
        probs, dry = [], 0
        for kc in range(kc_first, kc_first + kills):
            enrage = enrages.get(kc, 0)
            if "streak" in cfg:
                rate, counts = streak_rate(cfg, enrage, streaks.get(kc, 1), dry)
            else:
                rate, counts = rate_at(cfg, enrage), False
            if threshold:
                rate = min(1.0, rate * (1 + min((kc - 1) // threshold, 9)))  # numerator capped at 10, as on the wiki
            probs.append(per_kill_probability(min(1.0, rate), rolls))
            if counts:  # kills the rule does not apply to (Zamorak under 100% enrage) neither count nor reset
                dry = 0 if kc in group_drops else dry + 1
        return luck_from_probs(probs, drops)
    if cfg.get("threshold"):
        return luck_threshold(kc_first, kc_first + kills - 1, drops, cfg["rate"], cfg["threshold"], rolls)
    return luck(kills, drops, cfg["rate"], rolls)


def _tracked(conn, player_id: str, boss: str, item: str) -> tuple[int, int, int]:
    """(first kc, tracked kills, drop count) for one player.

    Kills are counted from the first kc this player ever reported for the boss,
    so kills made before the plugin was installed do not dilute the rate.
    """
    row = conn.execute(
        """SELECT MIN(kc) AS lo, MAX(kc) AS hi FROM (
               SELECT kc FROM kill_events WHERE player_id = ? AND boss = ?
               UNION ALL
               SELECT kc FROM drop_events WHERE player_id = ? AND boss = ?)""",
        (player_id, boss, player_id, boss),
    ).fetchone()
    if row["lo"] is None:
        return 0, 0, 0
    drops = conn.execute(
        "SELECT COUNT(*) AS n FROM drop_events WHERE player_id = ? AND boss = ? AND item = ?",
        (player_id, boss, item),
    ).fetchone()["n"]
    return row["lo"], row["hi"] - row["lo"] + 1, drops


@app.get("/v1/me/luck")
def my_luck(boss: str, item: str, player: Player):
    """Your drop luck for one boss/item, plus your rank among all players."""
    cfg = get_rate(boss, item)
    boss = canon(boss)
    with db.connect() as conn:
        first, kills, drops = _tracked(conn, player, boss, item)
        if kills == 0:
            raise HTTPException(404, "No kills recorded for this boss")
        result = _score(cfg, first, kills, drops, _context(conn, player, boss, cfg))
        scores = [
            _score(cfg, f, k, d, _context(conn, pid, boss, cfg))["percentile"]
            for pid in _players_with_boss(conn, boss)
            for f, k, d in [_tracked(conn, pid, boss, item)]
            if k > 0
        ]
    result["community_rank"] = (
        round(100.0 * sum(s < result["percentile"] for s in scores) / len(scores), 2) if scores else None
    )
    result["community_players"] = len(scores)
    return {"boss": boss, "item": item, "rate": cfg["rate"], "rolls": cfg.get("rolls", 1), **result}


def _players_with_boss(conn, boss: str) -> list[str]:
    return [
        r["player_id"]
        for r in conn.execute(
            "SELECT player_id FROM kill_events WHERE boss = ? UNION SELECT player_id FROM drop_events WHERE boss = ?",
            (boss, boss),
        )
    ]


@app.get("/v1/aggregate")
def aggregate(boss: str, item: str, min_kills: Annotated[int, Query(ge=1)] = 50):
    """Community-wide observed rate versus the configured expected rate."""
    cfg = get_rate(boss, item)
    boss = canon(boss)
    rolls = cfg.get("rolls", 1)
    total_kills = total_drops = 0
    expected_drops = 0.0
    buckets = [0] * 10  # percentile deciles
    with db.connect() as conn:
        for pid in _players_with_boss(conn, boss):
            first, kills, drops = _tracked(conn, pid, boss, item)
            if kills < min_kills:
                continue
            total_kills += kills
            total_drops += drops
            r = _score(cfg, first, kills, drops, _context(conn, pid, boss, cfg))
            expected_drops += r["expected_drops"]
            buckets[min(int(r["percentile"] // 10), 9)] += 1
    players = sum(buckets)
    expected_p = expected_drops / total_kills if total_kills else per_kill_probability(cfg["rate"], rolls)
    observed = total_drops / total_kills if total_kills else None
    return {
        "boss": boss,
        "item": item,
        "players": players,
        "total_kills": total_kills,
        "total_drops": total_drops,
        "expected_rate": expected_p,
        "observed_rate": observed,
        "observed_one_in": (1 / observed) if observed else None,
        "percentile_deciles": buckets,
    }


@app.post("/v1/me/collection")
def submit_collection(batch: CollectionBatch, player: Player):
    """Replace your collection-log snapshot for the given items: lifetime kills and how many you have.

    Items with no known rate are ignored (counted in `ignored`). Idempotent: sending the same entries again changes
    nothing, and newer entries replace older ones.
    """
    table = clog_rate_table()
    now = datetime.now(timezone.utc).isoformat()
    accepted = 0
    with db.connect() as conn:
        for e in batch.entries:
            boss = canon(e.boss)
            if e.item not in table.get(boss, {}):
                continue
            conn.execute(
                """INSERT INTO collection (player_id, boss, item, kills, hard_kills, count, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(player_id, boss, item) DO UPDATE SET
                       kills = excluded.kills, hard_kills = excluded.hard_kills,
                       count = excluded.count, updated_at = excluded.updated_at""",
                (player, boss, e.item, e.kills, e.hard_kills, e.count, now),
            )
            accepted += 1
    return {"received": len(batch.entries), "accepted": accepted, "ignored": len(batch.entries) - accepted}


def _collection_luck(table: dict, row) -> dict:
    return lifetime_luck(table[row["boss"]][row["item"]], row["kills"], row["count"], row["hard_kills"])


@app.get("/v1/me/collection")
def my_collection(player: Player, boss: Optional[str] = None):
    """Your collection-log luck per item, lifetime. `dry_percent` is the figure the in-game label shows, P(X <= count):
    low = unlucky, high = lucky. `percentile` is the mid-p value, used for `community_rank` (the share of players
    with a lower percentile on the same item)."""
    table = clog_rate_table()
    where, args = ("AND boss = ?", (canon(boss),)) if boss else ("", ())
    with db.connect() as conn:
        mine = conn.execute(
            f"SELECT boss, item, kills, hard_kills, count, updated_at FROM collection WHERE player_id = ? {where}",
            (player, *args),
        ).fetchall()
        out = []
        for row in mine:
            if row["item"] not in table.get(row["boss"], {}):
                continue  # rate removed since it was stored
            result = _collection_luck(table, row)
            others = [
                _collection_luck(table, r)["percentile"]
                for r in conn.execute(
                    "SELECT boss, item, kills, hard_kills, count FROM collection WHERE boss = ? AND item = ?",
                    (row["boss"], row["item"]),
                )
            ]
            out.append({
                "boss": row["boss"],
                "item": row["item"],
                **result,
                "community_rank": round(100.0 * sum(s < result["percentile"] for s in others) / len(others), 2),
                "community_players": len(others),
                "updated_at": row["updated_at"],
            })
    out.sort(key=lambda r: (r["dry_percent"], r["boss"], r["item"]))
    return {"items": out}


# Website (must be last so it does not shadow the API routes).
if STATIC_DIR.is_dir():
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="site")


