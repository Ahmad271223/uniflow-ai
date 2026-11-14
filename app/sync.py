"""Geraete-Synchronisierung (Vertrag G2, docs/AUFGABENTEILUNG-APPLE-PC.md): Notizen, Module, Ordner, Stundenplan-Serien
und -Ausnahmen, Lernpakete, Aufgaben, Karteikarten, Einstellungen zwischen den Geraeten eines Kontos.

Jede synchronisierte Tabelle bekommt drei Spalten: `sync_version` (zaehlt bei jeder Aenderung hoch),
`sync_updated_at` (UTC, Millisekunden) und `sync_device` (Geraet der letzten Aenderung, NULL = dieser Server bzw.
Web-Oberflaeche). SQLite-Trigger pflegen sie bei INSERT/UPDATE und schreiben bei DELETE einen Eintrag in
`sync_tombstones`; dadurch bleiben alle bestehenden Schreibpfade der App unveraendert. Notizen (`annotations`)
behalten ihre `version` und die 409-Regel (`base_version`), der Client fuehrt mit den gemeinsamen Regeln
(`fixtures/merge/cases.json`) zusammen und schickt erneut.

Abruf: `changes(conn, since)` liefert alle Zeilen und Tombstones nach dem Cursor. Senden: `push(conn, device, items)`:
 - neue Zeile (`id` fehlt, `local_id` gesetzt) -> der Server vergibt die ID und meldet die Zuordnung; Fremdschluessel
   auf neue Zeilen (negative lokale IDs) werden im selben Push aufgeloest (Reihenfolge der ENTITIES)
 - bestehende Zeile mit passender `base_version` -> uebernommen
 - veraltete `base_version` -> Konflikt: je Feld gewinnt der spaetere Schreiber (`updated_at` des Clients gegen
   `sync_updated_at` des Servers); das Ergebnis kommt mit beiden Staenden zurueck
 - Loeschen: gewinnt, wenn es nicht aelter ist als die letzte Aenderung auf dem Server, sonst bleibt die Zeile
   (Konflikt `edit_wins`); eine Aenderung nach einem Tombstone stellt die Zeile wieder her
Eigene Dokumente mit Inhalt (Notizbuecher, importierte PDFs) folgen spaeter; Hochschuldateien laedt jedes Geraet selbst.

Raeume je Uni-Konto (14.11.2026, docs/ABGLEICH-UNI-KONTO-2026-11-14.md): Geraete desselben StudiNow-Kontos teilen nur,
wenn sie zum selben Uni-Konto gehoeren. Das Geraet meldet einen Hash (`uni_key`, aeltere Apple-Apps `studip_user`);
je Uni-Konto gibt es einen Raum (`sync_rooms`), je Zeile Raum und Ursprungsgeraet (`sync_row_room`). Regeln: `Rooms`.
"""
from __future__ import annotations

import json
import re
import sqlite3
import time
from datetime import datetime, timezone

from . import db

# Reihenfolge = Reihenfolge beim Push (Eltern vor Kindern); (Tabelle, Primaerschluessel, Fremdschluessel -> Tabelle)
ENTITIES: dict[str, dict] = {
    "modules": {"pk": "id", "fk": {}},
    "folders": {"pk": "id", "fk": {"module_id": "modules", "parent_id": "folders"}},
    "course_events": {"pk": "id", "fk": {"module_id": "modules"}},
    "event_exceptions": {"pk": "id", "fk": {"event_id": "course_events"}},
    "study_packages": {"pk": "id", "fk": {"module_id": "modules"}},
    "study_tasks": {"pk": "id", "fk": {"package_id": "study_packages"}},
    "study_goals": {"pk": "id", "fk": {"module_id": "modules"}},
    "study_sessions": {"pk": "id", "fk": {"module_id": "modules", "package_id": "study_packages"}},
    "flashcard_stacks": {"pk": "id", "fk": {}},
    "flashcards": {"pk": "id", "fk": {"stack_id": "flashcard_stacks"}},
    "settings": {"pk": "key", "fk": {}},
    "annotations": {"pk": "file_id", "fk": {}},
}
SYNC_COLS = ("sync_version", "sync_updated_at", "sync_device")
# nie zwischen Geraeten. `studip_user_hash`: Hash der Stud.IP-Benutzerkennung des Geraets (lokal, `StudIPUserMark`); im
# Dienst stand er vom 12. bis 14.11.2026 je Konto (erster Benutzer sperrte den zweiten aus, 409), seitdem ordnen die
# Raeume (`Rooms`) zu. Der Schluessel bleibt privat: kein Geraet kann ihn per Push setzen oder loeschen.
PRIVATE_SETTINGS = {"lan_pin", "university", "studip_user_hash"}
STUDIP_USER_RE = re.compile(r"^[0-9a-f]{16,128}$")
UNI_KEY_RE = STUDIP_USER_RE                        # `uni_key`: SHA-256 hex ueber Konto | Hochschule | Uni-Kennung
ROOM_META = "~meta"                                # Marker in sync_row_room (kein Tabellenname)
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$")
OP_RE = re.compile(r"^[A-Za-z0-9._:-]{8,100}$")             # Operations-ID eines Push-Eintrags (z. B. UUID)
NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"


def now_utc() -> str:
    t = datetime.now(timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


CURSOR_WAIT_MAX = 0.1    # Sekunden; ein Cursor weiter in der Zukunft (von Hand gesetzter Zeitstempel) wird nicht abgewartet


def _clock_past(cursor: str) -> None:
    """Wartet, bis die Uhr des Servers ueber die Millisekunde des Cursors hinaus ist (in der Regel unter 1 ms).

    Der Cursor ist der Zeitstempel der neuesten gelieferten Zeile, der Abruf filtert mit `sync_updated_at > cursor`.
    Eine Aenderung direkt nach dem Abruf, noch in derselben Millisekunde (Trigger mit strftime('now') oder Push mit
    now_utc(), beide dieselbe Systemuhr in Millisekunden), bekaeme sonst denselben Zeitstempel wie der Cursor und
    fiele beim naechsten Abruf durch (Befund 30.10.2026: tests/test_sync.py, Aenderung des Moduls nach dem Abruf in
    rund jedem fuenften engen Durchlauf verloren). Nach dem Warten ist jeder spaeter vergebene Zeitstempel echt
    groesser als der Cursor; der Cursor und das Format bleiben unveraendert."""
    deadline = time.monotonic() + CURSOR_WAIT_MAX
    while now_utc() <= cursor and time.monotonic() < deadline:
        time.sleep(0.0002)


# ---------------------------------------------------------------- Schema: Spalten, Trigger, Tombstones

def ensure_schema(conn) -> None:
    """Idempotent, wird aus db._init_db aufgerufen."""
    # Ergebnis je Operations-ID (op_id eines Push-Eintrags): eine Wiederholung nach verlorener Antwort bekommt dasselbe
    # Ergebnis, statt eine neue Zeile doppelt anzulegen (28.10.2026). Loeschfrist wie sync_log (app/retention.py).
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_ops (
        op_id TEXT PRIMARY KEY, entity TEXT NOT NULL, result TEXT NOT NULL, device TEXT, created_at TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_tombstones (
        entity TEXT NOT NULL, entity_id TEXT NOT NULL, deleted_at TEXT NOT NULL, device TEXT,
        PRIMARY KEY (entity, entity_id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tombstones_time ON sync_tombstones(deleted_at)")
    for table, meta in ENTITIES.items():
        cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if not cols:
            continue
        for col, decl in (("sync_version", "INTEGER DEFAULT 1"), ("sync_updated_at", "TEXT"), ("sync_device", "TEXT")):
            if col not in cols:
                from . import db
                db.add_column(conn, table, col, decl)           # mehrere Prozesse zugleich (Audit P11-02)
        pk = meta["pk"]
        # Einfuegen durch die App (ohne Zeitstempel): Zeitstempel setzen. Der Push fuegt mit Zeitstempel ein, dann nichts.
        conn.execute(f"""CREATE TRIGGER IF NOT EXISTS sync_ins_{table} AFTER INSERT ON {table}
            WHEN NEW.sync_updated_at IS NULL
            BEGIN UPDATE {table} SET sync_updated_at = {NOW_SQL}, sync_version = COALESCE(NEW.sync_version, 1)
                  WHERE rowid = NEW.rowid; END""")
        # Aenderung durch die App (Version und Zeitstempel unberuehrt): Version hoch, Zeitstempel neu, Geraet = Server.
        # Der Push setzt Version und Zeitstempel selbst, ebenso der Einfuege-Trigger: dann kein zweites Hochzaehlen.
        conn.execute(f"""CREATE TRIGGER IF NOT EXISTS sync_upd_{table} AFTER UPDATE ON {table}
            WHEN NEW.sync_version IS OLD.sync_version AND NEW.sync_updated_at IS OLD.sync_updated_at
            BEGIN UPDATE {table} SET sync_version = COALESCE(OLD.sync_version, 0) + 1, sync_updated_at = {NOW_SQL},
                                     sync_device = NULL WHERE rowid = NEW.rowid; END""")
        conn.execute(f"""CREATE TRIGGER IF NOT EXISTS sync_del_{table} AFTER DELETE ON {table}
            BEGIN INSERT OR REPLACE INTO sync_tombstones(entity, entity_id, deleted_at, device)
                  VALUES ('{table}', CAST(OLD.{pk} AS TEXT), {NOW_SQL}, NULL); END""")
        # Bestand ohne Zeitstempel (Datenbanken von vor der Synchronisierung)
        conn.execute(f"UPDATE {table} SET sync_updated_at = {NOW_SQL}, sync_version = COALESCE(sync_version, 1) WHERE sync_updated_at IS NULL")
    ensure_rooms(conn)


# ---------------------------------------------------------------- Raeume je Uni-Konto

def ensure_rooms(conn) -> None:
    """Tabellen der Raeume; einmalig das Ursprungsgeraet je vorhandener Zeile (zuerst `sync_ops`: wer hat angelegt,
    sonst `sync_device`: letzter Schreiber). Idempotent, vertraegt fehlende Tabellen, fasst keine Datenzeile an
    (eine Spalte an den Datentabellen haette ueber die Trigger jede Zeile neu gestempelt)."""
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT, uni_key TEXT UNIQUE, studip_user TEXT UNIQUE, created_at TEXT NOT NULL)""")
    conn.execute("CREATE TABLE IF NOT EXISTS sync_devices (device_id TEXT PRIMARY KEY, room INTEGER NOT NULL, seen_at TEXT NOT NULL)")
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_row_room (
        entity TEXT NOT NULL, entity_id TEXT NOT NULL, room INTEGER, origin TEXT, assigned_at TEXT,
        PRIMARY KEY (entity, entity_id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sync_row_room_origin ON sync_row_room(origin)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sync_row_room_assigned ON sync_row_room(assigned_at)")
    if conn.execute("SELECT 1 FROM sync_row_room WHERE entity=? AND entity_id='backfill'", (ROOM_META,)).fetchone():
        return
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table, meta in ENTITIES.items():
        if table not in tables or "sync_device" not in {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}:
            continue
        conn.execute(f"""INSERT OR IGNORE INTO sync_row_room(entity, entity_id, room, origin, assigned_at)
                         SELECT '{table}', CAST({meta['pk']} AS TEXT), NULL, sync_device, NULL FROM {table}
                         WHERE sync_device IS NOT NULL AND sync_device != ''""")
    if "sync_ops" in tables:
        ops = conn.execute("SELECT entity, result, device FROM sync_ops WHERE device IS NOT NULL AND device != '' ORDER BY created_at").fetchall()
        for entity, result, device in ops:
            try:
                res = json.loads(result)
            except (TypeError, ValueError):
                continue
            if entity not in ENTITIES or entity not in tables or not isinstance(res, dict) or res.get("id") is None:
                continue
            if res.get("status") not in ("created", "resurrected"):
                continue
            pk = ENTITIES[entity]["pk"]
            if not conn.execute(f"SELECT 1 FROM {entity} WHERE CAST({pk} AS TEXT)=?", (str(res["id"]),)).fetchone():
                continue
            conn.execute("INSERT INTO sync_row_room(entity, entity_id, room, origin, assigned_at) VALUES (?,?,NULL,?,NULL) "
                         "ON CONFLICT(entity, entity_id) DO UPDATE SET origin=excluded.origin WHERE sync_row_room.room IS NULL",
                         (entity, str(res["id"]), device))
    conn.execute("INSERT OR IGNORE INTO sync_row_room(entity, entity_id, room, origin, assigned_at) VALUES (?, 'backfill', NULL, NULL, ?)",
                 (ROOM_META, now_utc()))


class Rooms:
    """Raum des anfragenden Geraets und die Regeln dazu (docs/ABGLEICH-UNI-KONTO-2026-11-14.md).

    `room`: Nummer des Raums oder None (Geraet ohne Schluessel: Windows-App alt, Apple bis 1.0.2). `count`: Zahl der
    Raeume des Kontos. `modern`: der Client kennt `other_room` und `foreign` (er schickt `uni_key`).

    Sehen (Abruf):  Geraet mit Raum: Zeilen seines Raums; dazu Zeilen ohne Raum und ohne Ursprungsgeraet (Web, Dienst),
                    solange das Konto genau einen Raum hat.
                    Geraet ohne Raum: hoechstens ein Raum im Konto -> alles wie bisher; sonst nur Zeilen ohne Raum.
    Aendern:        Geraet mit Raum: eigener Raum; eine Zeile ohne Raum und ohne Ursprungsgeraet uebernimmt es dabei.
                    Geraet ohne Raum: Zeilen ohne Raum; Raum-Zeilen nur, solange es hoechstens einen Raum gibt.
    Loeschen:       Geraet mit Raum: eigener Raum (nicht, wenn Zeilen eines anderen Raums daran haengen); Web-Zeile
                    ohne Raum nur bei genau einem Raum.
                    Geraet ohne Raum: kein Raum im Konto -> wie bisher; sonst nur eigene oder Web-Zeilen ohne Raum.
    Nie ein Fehler: was nicht erlaubt ist, bekommt `other_room` (neue App) bzw. ein stilles Ergebnis ohne Wirkung."""

    def __init__(self, conn, device: str | None = None, room: int | None = None, modern: bool = False):
        self.conn, self.device, self.room, self.modern = conn, device, room, modern
        self.ready = bool(conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_row_room'").fetchone())
        self.count = conn.execute("SELECT COUNT(*) FROM sync_rooms").fetchone()[0] if self.ready else 0

    @property
    def legacy(self) -> bool:
        """Abruf genau wie vor den Raeumen: Geraet ohne Raum in einem Konto mit hoechstens einem Raum."""
        return not self.ready or (self.room is None and self.count <= 1)

    def of(self, entity: str, entity_id) -> tuple[int | None, str | None]:
        """(Raum, Ursprungsgeraet) einer Zeile; ohne Eintrag (None, None)."""
        if not self.ready:
            return None, None
        r = self.conn.execute("SELECT room, origin FROM sync_row_room WHERE entity=? AND entity_id=?", (entity, str(entity_id))).fetchone()
        return (r[0], r[1]) if r else (None, None)

    def created(self, entity: str, entity_id, now: str) -> None:
        """Neue Zeile dieses Geraets: Ursprung merken, mit Raum gleich zuordnen."""
        if not self.ready or (self.device is None and self.room is None):
            return
        self.conn.execute("INSERT INTO sync_row_room(entity, entity_id, room, origin, assigned_at) VALUES (?,?,?,?,?) "
                          "ON CONFLICT(entity, entity_id) DO UPDATE SET room=excluded.room, origin=excluded.origin, assigned_at=excluded.assigned_at",
                          (entity, str(entity_id), self.room, self.device, now if self.room is not None else None))

    def may_update(self, entity: str, entity_id, now: str) -> bool:
        if not self.ready:
            return True
        room, origin = self.of(entity, entity_id)
        if self.room is None:
            return room is None or self.count <= 1
        if room is not None:
            return room == self.room
        if origin is not None and origin != self.device:
            return False                                        # Zeile eines Geraets, dessen Uni-Konto noch unbekannt ist
        # Zeile ohne Ursprungsgeraet (Web, Dienst): gehoert ab jetzt diesem Raum
        self.conn.execute("INSERT INTO sync_row_room(entity, entity_id, room, origin, assigned_at) VALUES (?,?,?,NULL,?) "
                          "ON CONFLICT(entity, entity_id) DO UPDATE SET room=excluded.room, assigned_at=excluded.assigned_at",
                          (entity, str(entity_id), self.room, now))
        return True

    def may_delete(self, entity: str, entity_id) -> bool:
        if not self.ready:
            return True
        room, origin = self.of(entity, entity_id)
        if self.room is None:
            if self.count == 0:
                return True
            return room is None and (origin is None or origin == self.device)
        if room is not None:
            return room == self.room and not self._foreign_children(entity, entity_id)
        return origin == self.device or (origin is None and self.count <= 1)

    def _foreign_children(self, entity: str, entity_id) -> bool:
        """Haengt an der Zeile etwas aus einem anderen Raum (Altbestand: zwei Uni-Konten hatten dasselbe Fach)? Dann
        nicht loeschen: ON DELETE CASCADE naehme es dem anderen Raum weg."""
        for child, meta in ENTITIES.items():
            for col, target in meta["fk"].items():
                if target != entity or not self.conn.execute(f"PRAGMA table_info({child})").fetchone():
                    continue
                hit = self.conn.execute(
                    f"""SELECT 1 FROM {child} c JOIN sync_row_room rr ON rr.entity=? AND rr.entity_id=CAST(c.{meta['pk']} AS TEXT)
                        WHERE c.{col}=? AND rr.room IS NOT NULL AND rr.room != ? LIMIT 1""", (child, entity_id, self.room)).fetchone()
                if hit:
                    return True
        return False

    def refused(self, entity: str, entity_id, *, delete: bool = False, version=None) -> dict:
        """Ergebnis fuer eine Zeile ausserhalb des eigenen Raums. Neue App: `other_room` (sie loest die Verknuepfung).
        Aeltere App: das Ergebnis, das sie kennt, ohne Wirkung im Dienst; ihre lokale Aenderung bleibt lokal."""
        if self.modern:
            return {"entity": entity, "id": entity_id, "status": "other_room", "room": "other"}
        if delete:
            return {"entity": entity, "id": entity_id, "status": "deleted", "room": "other"}
        return {"entity": entity, "id": entity_id, "status": "applied", "version": version or 1, "client_won": [], "room": "other"}

    def visible_sql(self, alias: str = "rr") -> tuple[str, list]:
        """Bedingung auf dem LEFT JOIN mit sync_row_room; nur ausserhalb von `legacy` benutzt."""
        if self.room is None:
            return f"{alias}.room IS NULL", []
        if self.count <= 1:
            return f"({alias}.room = ? OR ({alias}.room IS NULL AND {alias}.origin IS NULL))", [self.room]
        return f"{alias}.room = ?", [self.room]


def resolve_room(conn, device: str | None, uni_key=None, studip_user=None, now: str | None = None) -> Rooms:
    """Raum des Geraets aus seinen Hashes; legt Raum und Geraet bei Bedarf an und ordnet die Zeilen zu, die dieses
    Geraet frueher ohne Raum angelegt hat (Altbestand). Ohne Hash: der zuletzt gemeldete Raum des Geraets, sonst
    keiner. ValueError bei einem Wert, der kein Hex-Hash ist (wie bisher bei `studip_user`)."""
    for name, value in (("uni_key", uni_key), ("studip_user", studip_user)):
        if value not in (None, "") and (not isinstance(value, str) or not UNI_KEY_RE.match(value)):
            raise ValueError(f"{name} muss ein Hex-Hash sein")
    key, user = uni_key or None, studip_user or None
    device = (device if isinstance(device, str) else "")[:80] or None
    ctx = Rooms(conn, device, None, modern=bool(key))
    if not ctx.ready:
        return ctx
    now = now or now_utc()
    room = None
    if key or user:
        by_key = conn.execute("SELECT id, studip_user FROM sync_rooms WHERE uni_key=?", (key,)).fetchone() if key else None
        by_user = conn.execute("SELECT id, uni_key FROM sync_rooms WHERE studip_user=?", (user,)).fetchone() if user else None
        if by_key:
            room = by_key[0]
            if user and not by_key[1] and not by_user:          # alten Hash nachtragen: aeltere Apps finden denselben Raum
                conn.execute("UPDATE sync_rooms SET studip_user=? WHERE id=?", (user, room))
        elif by_user and (not key or not by_user[1]):
            room = by_user[0]
            if key:                                             # Raum einer aelteren App bekommt den neuen Schluessel
                conn.execute("UPDATE sync_rooms SET uni_key=? WHERE id=?", (key, room))
        else:
            room = conn.execute("INSERT INTO sync_rooms(uni_key, studip_user, created_at) VALUES (?,?,?)",
                                (key, None if by_user else user, now)).lastrowid
        if device:
            known = conn.execute("SELECT room FROM sync_devices WHERE device_id=?", (device,)).fetchone()
            if not known or known[0] != room:                   # nur schreiben, wenn sich etwas aendert (jeder Abruf kommt hier vorbei)
                conn.execute("INSERT INTO sync_devices(device_id, room, seen_at) VALUES (?,?,?) "
                             "ON CONFLICT(device_id) DO UPDATE SET room=excluded.room, seen_at=excluded.seen_at", (device, room, now))
    elif device:
        r = conn.execute("SELECT room FROM sync_devices WHERE device_id=?", (device,)).fetchone()
        room = r[0] if r else None
    if room is not None and device and conn.execute(
            "SELECT 1 FROM sync_row_room WHERE room IS NULL AND origin=? AND entity != ? LIMIT 1", (device, ROOM_META)).fetchone():
        # Altbestand und alles, was das Geraet ohne Raum angelegt hat: gehoert jetzt seinem Raum. `assigned_at` laesst
        # die anderen Geraete des Raums die Zeilen nachholen, auch wenn ihr Cursor schon weiter ist.
        conn.execute("UPDATE sync_row_room SET room=?, assigned_at=? WHERE room IS NULL AND origin=? AND entity != ?",
                     (room, now, device, ROOM_META))
    ctx.room = room
    ctx.count = conn.execute("SELECT COUNT(*) FROM sync_rooms").fetchone()[0]
    return ctx


def _columns(conn, table: str) -> list[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})") if r[1] not in SYNC_COLS]


def _json_dict(value):
    """Notizen aus der Datenbank. Korrupter Text (Audit 08.11.2026, Paket 3 Nr. 76) ergibt {} mit der Version des
    Servers statt eines 500 fuer jeden Abruf des Kontos; die naechste Aenderung des Geraets ueberschreibt den Stand."""
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return {}


def _row_out(table: str, r: dict) -> dict:
    out = dict(r)
    if table == "annotations":
        out["data"] = _json_dict(out.get("data"))
        out["version"] = out.get("version") or 1
    return out


# ---------------------------------------------------------------- Abruf

MAX_PULL = 2000


def _page(conn, sql_more: str, sql_same: str, since: str, limit: int, ts_key: str, extra: tuple = ()) -> tuple[list[dict], str | None]:
    """Hoechstens `limit` Zeilen nach `since`, aufsteigend nach Zeitstempel; bei abgeschnittener Liste kommen alle
    Zeilen mit dem letzten Zeitstempel dazu (gleiche Zeitstempel lassen sich mit einem Zeit-Cursor nicht teilen).
    Liefert (Zeilen, Grenze) - Grenze = letzter Zeitstempel, wenn es danach weitere Zeilen geben kann, sonst None.
    `extra`: weitere Parameter der Bedingung (Raum), in beiden Abfragen nach dem Zeitstempel."""
    rows = db.rows(conn, sql_more, (since, *extra, limit))
    if len(rows) < limit:
        return rows, None
    last = rows[-1][ts_key]
    return [r for r in rows if r[ts_key] < last] + db.rows(conn, sql_same, (last, *extra)), last


def changes(conn, since: str | None, limit: int = MAX_PULL, rooms: Rooms | None = None) -> dict:
    """Alle Aenderungen nach `since` (Cursor aus der letzten Antwort; None = alles), seitenweise.

    Je Tabelle hoechstens `limit` Zeilen (plus Gleichstand am Ende). Wird eine Tabelle abgeschnitten, gilt fuer alle
    Tabellen und Tombstones dieselbe Grenze (kleinster abgeschnittener Zeitstempel): geliefert wird alles bis
    einschliesslich der Grenze, der Cursor ist die Grenze und `has_more` ist true. Vorher (bis 28.10.2026) war der
    Cursor das Maximum ueber alle Tabellen; bei mehr als `limit` Aenderungen in einer Tabelle gingen Zeilen verloren.
    Clients rufen weiter ab, solange `has_more` true ist; der Cursor bleibt ein Zeitstempel (alte Clients holen den
    Rest beim naechsten Abgleich).

    `rooms` (14.11.2026): nur was das Geraet sehen darf (`Rooms`). Eine Zeile zaehlt dann ab dem spaeteren von
    Aenderung und Zuordnung zum Raum (`assigned_at`): wird Altbestand zugeordnet, holen ihn die Geraete des Raums nach.
    Neue Apps (`rooms.modern`) bekommen dazu `foreign` (Zeilen, die nachweislich einem anderen Raum gehoeren: das
    Geraet raeumt sie bei sich auf) und `uni.rooms` (Zahl der Uni-Konten unter diesem StudiNow-Konto)."""
    since = since if since and TS_RE.match(since) else ""
    limit = max(1, min(int(limit or MAX_PULL), MAX_PULL))
    filtered = rooms is not None and not rooms.legacy
    vis, vis_params = rooms.visible_sql() if filtered else ("", [])
    ts_key = "_ts" if filtered else "sync_updated_at"
    fetched: dict[str, list] = {}
    bounds: list[str] = []
    for table, meta in ENTITIES.items():
        pk = meta["pk"]
        if filtered:
            ts = "MAX(COALESCE(t.sync_updated_at, ''), COALESCE(rr.assigned_at, ''))"
            join = (f"SELECT t.*, {ts} AS _ts FROM {table} t LEFT JOIN sync_row_room rr "
                    f"ON rr.entity='{table}' AND rr.entity_id=CAST(t.{pk} AS TEXT)")
            rows, bound = _page(conn, f"{join} WHERE {ts} > ? AND {vis} ORDER BY _ts, t.{pk} LIMIT ?",
                                f"{join} WHERE {ts} = ? AND {vis} ORDER BY t.{pk}", since, limit, ts_key, tuple(vis_params))
        else:
            rows, bound = _page(conn, f"SELECT * FROM {table} WHERE sync_updated_at > ? ORDER BY sync_updated_at, {pk} LIMIT ?",
                                f"SELECT * FROM {table} WHERE sync_updated_at = ? ORDER BY {pk}", since, limit, ts_key)
        fetched[table] = rows
        if bound:
            bounds.append(bound)
    if filtered:
        join = ("SELECT s.entity, s.entity_id, s.deleted_at, s.device FROM sync_tombstones s LEFT JOIN sync_row_room rr "
                "ON rr.entity=s.entity AND rr.entity_id=s.entity_id")
        tomb, bound = _page(conn, f"{join} WHERE s.deleted_at > ? AND {vis} ORDER BY s.deleted_at, s.entity, s.entity_id LIMIT ?",
                            f"{join} WHERE s.deleted_at = ? AND {vis} ORDER BY s.entity, s.entity_id", since, limit, "deleted_at",
                            tuple(vis_params))
    else:
        tomb, bound = _page(conn, "SELECT entity, entity_id, deleted_at, device FROM sync_tombstones WHERE deleted_at > ? "
                                  "ORDER BY deleted_at, entity, entity_id LIMIT ?",
                            "SELECT entity, entity_id, deleted_at, device FROM sync_tombstones WHERE deleted_at = ? ORDER BY entity, entity_id",
                            since, limit, "deleted_at")
    if bound:
        bounds.append(bound)
    foreign: list[dict] = []
    tell = rooms is not None and rooms.modern and rooms.ready and rooms.room is not None
    if tell:
        cond = "room IS NOT NULL AND room != ? AND entity != ?"
        foreign, bound = _page(conn, f"SELECT entity, entity_id, assigned_at FROM sync_row_room WHERE assigned_at > ? AND {cond} "
                                     "ORDER BY assigned_at, entity, entity_id LIMIT ?",
                               f"SELECT entity, entity_id, assigned_at FROM sync_row_room WHERE assigned_at = ? AND {cond} "
                               "ORDER BY entity, entity_id", since, limit, "assigned_at", (rooms.room, ROOM_META))
        if bound:
            bounds.append(bound)
    cut = min(bounds) if bounds else None
    out: dict[str, list] = {}
    newest = since
    for table, rows in fetched.items():
        if cut:
            rows = [r for r in rows if (r[ts_key] or "") <= cut]
        if rows:
            newest = max(newest, rows[-1][ts_key] or "")
        if table == "settings":
            rows = [r for r in rows if r["key"] not in PRIVATE_SETTINGS]
        if filtered:
            rows = [{k: v for k, v in r.items() if k != "_ts"} for r in rows]
        if rows:
            out[table] = [_row_out(table, r) for r in rows]
    if cut:
        tomb = [t for t in tomb if t["deleted_at"] <= cut]
        foreign = [f for f in foreign if f["assigned_at"] <= cut]
    if tomb:
        newest = max(newest, tomb[-1]["deleted_at"])
    if foreign:
        newest = max(newest, foreign[-1]["assigned_at"])
    cursor = (cut or newest or since) or None
    if cursor:
        _clock_past(cursor)
    res = {"cursor": cursor, "changes": out, "tombstones": tomb, "has_more": cut is not None}
    if tell:
        res["foreign"] = [{"entity": f["entity"], "id": _foreign_id(f["entity"], f["entity_id"])} for f in foreign]
    if rooms is not None and rooms.modern:
        res["uni"] = {"rooms": rooms.count, "room": rooms.room is not None}
    return res


# ---------------------------------------------------------------- Senden

def _coerce_id(table: str, value):
    return str(value) if ENTITIES[table]["pk"] != "id" else int(value)


def _foreign_id(table: str, value: str):
    """ID im Abruf wie in den Zeilen selbst: Zahl bei Tabellen mit `id`, sonst Text."""
    try:
        return _coerce_id(table, value) if table in ENTITIES else value
    except ValueError:
        return value


def _resolve_fk(table: str, data: dict, mapping: dict[tuple[str, int], int]) -> dict:
    data = dict(data)
    for col, target in ENTITIES[table]["fk"].items():
        v = data.get(col)
        if isinstance(v, int) and v < 0:
            if (target, v) not in mapping:
                raise ValueError(f"{table}.{col} verweist auf eine unbekannte neue Zeile {v}")
            data[col] = mapping[(target, v)]
    return data


def _merge_fields(server: dict, client: dict, client_ts: str, server_ts: str, cols: list[str]) -> tuple[dict, list[str]]:
    """Je Feld gewinnt der spaetere Schreiber; liefert (Ergebnis, Felder in denen der Client gewonnen hat)."""
    client_wins = client_ts >= (server_ts or "")
    out, won = dict(server), []
    for c in cols:
        if c in client and client[c] != server.get(c):
            if client_wins:
                out[c] = client[c]
                won.append(c)
    return out, won


def push(conn, device: str | None, items: list[dict], deletes: list[dict] | None = None, now: str | None = None,
         rooms: Rooms | None = None) -> dict:
    """items: [{entity, id | local_id, op_id?, base_version, updated_at, data}], deletes: [{entity, id, deleted_at}].

    `rooms` (14.11.2026): Raum des Geraets (`resolve_room`); ohne Angabe der zuletzt gemeldete Raum des Geraets. Neue
    Zeilen gehoeren zum Raum; Aendern und Loeschen ausserhalb des Raums hat keine Wirkung (`Rooms.refused`).

    `op_id` (optional, 8-100 Zeichen [A-Za-z0-9._:-], z. B. eine UUID je Eintrag, beim Wiederholen dieselbe): das
    Ergebnis wird gemerkt; derselbe Eintrag noch einmal bekommt dasselbe Ergebnis mit `repeated: true` und dieselbe
    ID-Zuordnung, statt eine neue Zeile doppelt anzulegen. Fehler werden nicht gemerkt (ein spaeterer Versuch darf
    gelingen)."""
    now = now or now_utc()
    device = (device if isinstance(device, str) else "")[:80] or None
    rooms = rooms or resolve_room(conn, device, now=now)
    results, mapping, conflicts = [], {}, []
    by_entity: dict[str, list[dict]] = {}
    for it in items or []:
        if it.get("entity") not in ENTITIES:
            results.append({"entity": it.get("entity"), "status": "unknown_entity"})
            continue
        by_entity.setdefault(it["entity"], []).append(it)
    for table in ENTITIES:                                      # Eltern vor Kindern
        pk, cols = ENTITIES[table]["pk"], _columns(conn, table)
        for it in by_entity.get(table, []):
            op = it.get("op_id") if isinstance(it.get("op_id"), str) and OP_RE.match(it["op_id"]) else None
            if op:
                prev = db.row(conn, "SELECT result FROM sync_ops WHERE op_id=? AND entity=?", (op, table))
                if prev:                                         # Wiederholung: dasselbe Ergebnis, keine neue Zeile
                    res = json.loads(prev["result"]) | {"repeated": True}
                    if isinstance(res.get("local_id"), int) and res["local_id"] < 0 and res.get("id") is not None:
                        mapping[(table, res["local_id"])] = res["id"]
                    results.append(res)
                    continue
            n0 = len(results)
            try:
                data = {k: v for k, v in (it.get("data") or {}).items() if k in cols and k != pk}
                if table == "settings" and (it.get("id") or it.get("local_id")) in PRIVATE_SETTINGS:
                    results.append({"entity": table, "id": it.get("id") or it.get("local_id"), "status": "ignored"})
                    continue
                try:
                    data = _resolve_fk(table, data, mapping)
                except ValueError as e:
                    results.append({"entity": table, "local_id": it.get("local_id"), "status": "error", "message": str(e)})
                    continue
                if table == "annotations":
                    results.append(_push_annotation(conn, it, device, now, rooms))
                    continue
                client_ts = it.get("updated_at") if TS_RE.match(it.get("updated_at") or "") else now
                rid = it.get("id")
                if rid is None:
                    data["sync_version"], data["sync_updated_at"], data["sync_device"] = 1, now, device
                    keys = list(data)
                    if table == "settings":
                        key = it.get("local_id")
                        old = db.row(conn, "SELECT sync_version FROM settings WHERE key=?", (key,))
                        if old is not None and not rooms.may_update(table, key, now):
                            results.append(rooms.refused(table, key, version=old["sync_version"]))
                            continue
                        if old is None:
                            rooms.created(table, key, now)
                        conn.execute("INSERT INTO settings(key, value, sync_version, sync_updated_at, sync_device) VALUES (?,?,?,?,?) "
                                     "ON CONFLICT(key) DO UPDATE SET value=excluded.value, sync_version=settings.sync_version+1, "
                                     "sync_updated_at=excluded.sync_updated_at, sync_device=excluded.sync_device",
                                     (it.get("local_id"), data.get("value"), 1, now, device))
                        row = db.row(conn, "SELECT * FROM settings WHERE key=?", (it.get("local_id"),))
                        results.append({"entity": table, "id": row["key"], "status": "applied", "version": row["sync_version"]})
                        continue
                    cur = conn.execute(f"INSERT INTO {table}({','.join(keys)}) VALUES ({','.join('?' * len(keys))})", [data[k] for k in keys])
                    new_id = cur.lastrowid
                    rooms.created(table, new_id, now)
                    if isinstance(it.get("local_id"), int) and it["local_id"] < 0:
                        mapping[(table, it["local_id"])] = new_id
                    results.append({"entity": table, "local_id": it.get("local_id"), "id": new_id, "status": "created", "version": 1})
                    continue
                rid = _coerce_id(table, rid)
                server = db.row(conn, f"SELECT * FROM {table} WHERE {pk}=?", (rid,))
                # vor allem anderen: eine Zeile ausserhalb des eigenen Raums wird weder geaendert noch wiederhergestellt,
                # und ihr Tombstone ("deleted") erreicht dieses Geraet nicht (es loeschte sonst seine eigene Zeile)
                if not rooms.may_update(table, rid, now):
                    results.append(rooms.refused(table, rid, version=(server or {}).get("sync_version")))
                    continue
                if server is None:
                    tomb = db.row(conn, "SELECT deleted_at FROM sync_tombstones WHERE entity=? AND entity_id=?", (table, str(rid)))
                    if tomb and tomb["deleted_at"] >= client_ts:
                        results.append({"entity": table, "id": rid, "status": "deleted", "deleted_at": tomb["deleted_at"]})
                        continue
                    data[pk] = rid                                   # Wiederherstellen (oder unbekannte ID eines anderen Geraets)
                    data["sync_version"], data["sync_updated_at"], data["sync_device"] = 1, now, device
                    keys = list(data)
                    conn.execute(f"INSERT INTO {table}({','.join(keys)}) VALUES ({','.join('?' * len(keys))})", [data[k] for k in keys])
                    conn.execute("DELETE FROM sync_tombstones WHERE entity=? AND entity_id=?", (table, str(rid)))
                    rooms.created(table, rid, now)
                    results.append({"entity": table, "id": rid, "status": "resurrected" if tomb else "created", "version": 1})
                    continue
                sv = server.get("sync_version") or 1
                base = it.get("base_version")
                if base is not None and int(base) == sv:
                    merged, won = dict(server) | data, list(data)
                    status = "applied"
                else:
                    # `changed` (Audit 09.11.2026, P73-F6): nur diese Felder hat das Geraet seit seiner Basis geaendert;
                    # die uebrigen Werte der ganzen Zeile sind sein alter Stand und duerfen nichts ueberschreiben (sonst
                    # verlor eine Erledigung auf Geraet A gegen eine spaetere Verschiebung auf Geraet B). Ohne `changed`
                    # (aeltere Geraete) wie bisher die ganze Zeile.
                    claimed = it.get("changed")
                    if isinstance(claimed, list):
                        claimed = {k: v for k, v in data.items() if k in {c for c in claimed if isinstance(c, str)}}
                    else:
                        claimed = data
                    merged, won = _merge_fields(server, claimed, client_ts, server.get("sync_updated_at") or "", cols)
                    status = "conflict"
                    conflicts.append({"entity": table, "id": rid, "server": _row_out(table, server), "client": data, "client_won": won})
                changed = {c: merged[c] for c in cols if c != pk and merged.get(c) != server.get(c)}
                if changed:
                    sets = ", ".join(f"{c}=?" for c in changed) + ", sync_version=?, sync_updated_at=?, sync_device=?"
                    conn.execute(f"UPDATE {table} SET {sets} WHERE {pk}=?", [*changed.values(), sv + 1, now, device, rid])
                    sv += 1
                results.append({"entity": table, "id": rid, "status": status, "version": sv, "client_won": won})
            except (ValueError, TypeError, sqlite3.IntegrityError) as e:
                # Ein kaputter Eintrag (id nicht ganzzahlig, Fremdschluessel auf eine fremde ID, Pflichtfeld leer) bleibt
                # ein Fehler dieses Eintrags; vorher brach der ganze Push mit 500 ab und das Geraet wiederholte ihn
                # endlos (Audit 08.11.2026, Paket 3 Nr. 79/80/82). SQLite rollt nur die Anweisung zurueck, nicht die
                # Transaktion; die uebrigen Eintraege werden uebernommen.
                results.append({"entity": table, "id": it.get("id"), "local_id": it.get("local_id"), "status": "error",
                                "message": f"{table}: {e}"})
            finally:
                # nicht gemerkt: Fehler und Zeilen ausserhalb des Raums (ein spaeterer Versuch darf gelingen)
                if op and len(results) > n0 and results[-1].get("status") not in ("error", "plan_required") \
                        and results[-1].get("room") != "other":
                    conn.execute("INSERT OR IGNORE INTO sync_ops(op_id, entity, result, device, created_at) VALUES (?,?,?,?,?)",
                                 (op, table, json.dumps(results[-1], ensure_ascii=False), device, now))
    for d in deletes or []:
        table = d.get("entity")
        if table not in ENTITIES or table == "annotations":
            results.append({"entity": table, "status": "unknown_entity"})
            continue
        if table == "settings" and d.get("id") in PRIVATE_SETTINGS:
            results.append({"entity": table, "id": d.get("id"), "status": "ignored"})
            continue
        pk = ENTITIES[table]["pk"]
        try:
            rid = _coerce_id(table, d.get("id"))
            when = d.get("deleted_at") if TS_RE.match(d.get("deleted_at") or "") else now
            server = db.row(conn, f"SELECT * FROM {table} WHERE {pk}=?", (rid,))
            if server is None:
                results.append({"entity": table, "id": rid, "status": "deleted"})
                continue
            if not rooms.may_delete(table, rid):                # Loeschen bleibt im Raum: Zeile und Tombstone unberuehrt
                results.append(rooms.refused(table, rid, delete=True))
                continue
            if when >= (server.get("sync_updated_at") or ""):
                conn.execute(f"DELETE FROM {table} WHERE {pk}=?", (rid,))
                conn.execute("UPDATE sync_tombstones SET device=?, deleted_at=? WHERE entity=? AND entity_id=?", (device, now, table, str(rid)))
                results.append({"entity": table, "id": rid, "status": "deleted"})
            else:
                conflicts.append({"entity": table, "id": rid, "server": _row_out(table, server), "client": None, "client_won": []})
                results.append({"entity": table, "id": rid, "status": "edit_wins", "version": server.get("sync_version")})
        except (ValueError, TypeError, sqlite3.IntegrityError) as e:          # wie oben: Fehler nur dieses Eintrags
            results.append({"entity": table, "id": d.get("id"), "status": "error", "message": f"{table}: {e}"})
    return {"results": results, "mapping": [{"entity": e, "local_id": l, "id": i} for (e, l), i in mapping.items()],
            "conflicts": conflicts, "server_time": now}


def _push_annotation(conn, it: dict, device: str | None, now: str, rooms: Rooms | None = None) -> dict:
    """Notizen: gleiche Regel wie PUT /api/files/{id}/annotations (base_version, 409 -> Konflikt mit Serverstand)."""
    file_id = str(it.get("id") or it.get("local_id") or "")
    rooms = rooms or Rooms(conn, device)
    known = db.row(conn, "SELECT version FROM annotations WHERE file_id=?", (file_id,))
    if known is not None and not rooms.may_update("annotations", file_id, now):
        return rooms.refused("annotations", file_id, version=known["version"])
    if not db.row(conn, "SELECT 1 FROM files WHERE id=?", (file_id,)):
        if not _register_device_file(conn, file_id, it.get("file")):
            return {"entity": "annotations", "id": file_id, "status": "unknown_file"}
    data = it.get("data") or {}
    cur = db.row(conn, "SELECT version, data FROM annotations WHERE file_id=?", (file_id,))
    cur_v = (cur["version"] or 1) if cur else 0
    if cur is None:
        rooms.created("annotations", file_id, now)
    base = it.get("base_version")
    if cur and (base is None or int(base) != cur_v):
        return {"entity": "annotations", "id": file_id, "status": "conflict", "version": cur_v, "data": _json_dict(cur["data"])}
    new_v = cur_v + 1
    payload = json.dumps(data, ensure_ascii=False)
    conn.execute("INSERT INTO annotations(file_id, data, updated_at, version, sync_version, sync_updated_at, sync_device) VALUES (?,?,?,?,?,?,?) "
                 "ON CONFLICT(file_id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, version=excluded.version, "
                 "sync_version=excluded.version, sync_updated_at=excluded.sync_updated_at, sync_device=excluded.sync_device",
                 (file_id, payload, db.now_iso(), new_v, new_v, now, device))
    conn.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)", (file_id, new_v, payload, db.now_iso()))
    conn.execute("""DELETE FROM annotation_versions WHERE file_id=? AND id NOT IN (
                        SELECT id FROM annotation_versions WHERE file_id=? ORDER BY version DESC LIMIT 30)""", (file_id, file_id))
    return {"entity": "annotations", "id": file_id, "status": "applied", "version": new_v}


def _register_device_file(conn, file_id: str, info) -> bool:
    """Notizen zu einer Hochschuldatei, die nur das Geraet kennt (Windows-App und iPad gleichen mit der Hochschule
    selbst ab, 28.10.2026): Kurs und Datei als Kopfzeile anlegen, damit die Notizen eine Datei haben. Ohne
    `download_url`: der Dienst laedt die Datei nie und die Community gilt dafuer nicht (`community.owns_file` braucht
    die Adresse, dafuer melden Geraete Fingerabdruecke). Ein spaeterer Abgleich im Dienst ergaenzt die Zeile."""
    if not isinstance(info, dict) or not str(info.get("name") or "").strip() or not str(info.get("course_id") or "").strip():
        return False
    if len(file_id) > 200 or str(info.get("course_id")) == "__user__":
        return False
    cid = str(info["course_id"])[:200]
    conn.execute("INSERT OR IGNORE INTO courses(id, title, semester) VALUES (?,?,?)",
                 (cid, str(info.get("course_title") or cid)[:300], (str(info.get("semester"))[:60] if info.get("semester") else None)))
    conn.execute("INSERT OR IGNORE INTO files(id, course_id, name, mime, first_seen, status) VALUES (?,?,?,?,?, 'neu')",
                 (file_id, cid, str(info["name"])[:300], (str(info.get("mime"))[:100] if info.get("mime") else None), db.now_iso()))
    return True
