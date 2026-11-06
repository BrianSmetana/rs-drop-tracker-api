import os
import sqlite3

DB_PATH = os.environ.get("DROP_DB", "drops.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS players (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS kill_events (
    event_id TEXT PRIMARY KEY,
    player_id TEXT NOT NULL REFERENCES players(id),
    boss TEXT NOT NULL,
    kc INTEGER NOT NULL,
    ts TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS drop_events (
    event_id TEXT PRIMARY KEY,
    player_id TEXT NOT NULL REFERENCES players(id),
    boss TEXT NOT NULL,
    item TEXT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1,
    kc INTEGER NOT NULL,
    ts TEXT NOT NULL
);
-- Collection-log snapshot sent by the plugin: lifetime kills (normal and hard mode) and how many of an item the
-- player has. One row per player/boss/item, replaced on every sync, so the API can compute the same luck figure
-- the in-game label shows, including drops from before the plugin was installed.
CREATE TABLE IF NOT EXISTS collection (
    player_id TEXT NOT NULL REFERENCES players(id),
    boss TEXT NOT NULL,
    item TEXT NOT NULL,
    kills INTEGER NOT NULL,
    hard_kills INTEGER NOT NULL DEFAULT 0,
    count INTEGER NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (player_id, boss, item)
);
CREATE INDEX IF NOT EXISTS ix_collection_bi ON collection(boss, item);
CREATE INDEX IF NOT EXISTS ix_kill_pb ON kill_events(player_id, boss);
CREATE INDEX IF NOT EXISTS ix_drop_pbi ON drop_events(player_id, boss, item);
"""


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init() -> None:
    with connect() as conn:
        conn.executescript(SCHEMA)
        # WikiSync-style profile: opt-in public lookup by in-game name. Added after v0.1, so migrate in place.
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(players)")}
        if "username" not in cols:
            conn.execute("ALTER TABLE players ADD COLUMN username TEXT")
            conn.execute("ALTER TABLE players ADD COLUMN public INTEGER NOT NULL DEFAULT 0")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS ux_players_username ON players(lower(username))")
        # Enrage % of each kill, for bosses whose rare-drop chance depends on it (NULL = not reported).
        if "enrage" not in {r["name"] for r in conn.execute("PRAGMA table_info(kill_events)")}:
            conn.execute("ALTER TABLE kill_events ADD COLUMN enrage INTEGER")
        # Killstreak (kills since loot was last claimed) for Telos-style streak formulas (NULL = not reported).
        if "streak" not in {r["name"] for r in conn.execute("PRAGMA table_info(kill_events)")}:
            conn.execute("ALTER TABLE kill_events ADD COLUMN streak INTEGER")
