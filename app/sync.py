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
"""
from __future__ import annotations

import json
import re
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
    "flashcards": {"pk": "id", "fk": {}},
    "settings": {"pk": "key", "fk": {}},
    "annotations": {"pk": "file_id", "fk": {}},
}
SYNC_COLS = ("sync_version", "sync_updated_at", "sync_device")
PRIVATE_SETTINGS = {"lan_pin", "university"}       # nie zwischen Geraeten
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$")
OP_RE = re.compile(r"^[A-Za-z0-9._:-]{8,100}$")             # Operations-ID eines Push-Eintrags (z. B. UUID)
NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"


def now_utc() -> str:
    t = datetime.now(timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


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
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
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


def _columns(conn, table: str) -> list[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})") if r[1] not in SYNC_COLS]


def _row_out(table: str, r: dict) -> dict:
    out = dict(r)
    if table == "annotations":
        out["data"] = json.loads(out["data"]) if isinstance(out.get("data"), str) else out.get("data")
        out["version"] = out.get("version") or 1
    return out


# ---------------------------------------------------------------- Abruf

MAX_PULL = 2000


def _page(conn, sql_more: str, sql_same: str, since: str, limit: int, ts_key: str) -> tuple[list[dict], str | None]:
    """Hoechstens `limit` Zeilen nach `since`, aufsteigend nach Zeitstempel; bei abgeschnittener Liste kommen alle
    Zeilen mit dem letzten Zeitstempel dazu (gleiche Zeitstempel lassen sich mit einem Zeit-Cursor nicht teilen).
    Liefert (Zeilen, Grenze) - Grenze = letzter Zeitstempel, wenn es danach weitere Zeilen geben kann, sonst None."""
    rows = db.rows(conn, sql_more, (since, limit))
    if len(rows) < limit:
        return rows, None
    last = rows[-1][ts_key]
    return [r for r in rows if r[ts_key] < last] + db.rows(conn, sql_same, (last,)), last


def changes(conn, since: str | None, limit: int = MAX_PULL) -> dict:
    """Alle Aenderungen nach `since` (Cursor aus der letzten Antwort; None = alles), seitenweise.

    Je Tabelle hoechstens `limit` Zeilen (plus Gleichstand am Ende). Wird eine Tabelle abgeschnitten, gilt fuer alle
    Tabellen und Tombstones dieselbe Grenze (kleinster abgeschnittener Zeitstempel): geliefert wird alles bis
    einschliesslich der Grenze, der Cursor ist die Grenze und `has_more` ist true. Vorher (bis 28.10.2026) war der
    Cursor das Maximum ueber alle Tabellen; bei mehr als `limit` Aenderungen in einer Tabelle gingen Zeilen verloren.
    Clients rufen weiter ab, solange `has_more` true ist; der Cursor bleibt ein Zeitstempel (alte Clients holen den
    Rest beim naechsten Abgleich)."""
    since = since if since and TS_RE.match(since) else ""
    limit = max(1, min(int(limit or MAX_PULL), MAX_PULL))
    fetched: dict[str, list] = {}
    bounds: list[str] = []
    for table, meta in ENTITIES.items():
        pk = meta["pk"]
        rows, bound = _page(conn, f"SELECT * FROM {table} WHERE sync_updated_at > ? ORDER BY sync_updated_at, {pk} LIMIT ?",
                            f"SELECT * FROM {table} WHERE sync_updated_at = ? ORDER BY {pk}", since, limit, "sync_updated_at")
        fetched[table] = rows
        if bound:
            bounds.append(bound)
    tomb, bound = _page(conn, "SELECT entity, entity_id, deleted_at, device FROM sync_tombstones WHERE deleted_at > ? "
                              "ORDER BY deleted_at, entity, entity_id LIMIT ?",
                        "SELECT entity, entity_id, deleted_at, device FROM sync_tombstones WHERE deleted_at = ? ORDER BY entity, entity_id",
                        since, limit, "deleted_at")
    if bound:
        bounds.append(bound)
    cut = min(bounds) if bounds else None
    out: dict[str, list] = {}
    newest = since
    for table, rows in fetched.items():
        if cut:
            rows = [r for r in rows if (r["sync_updated_at"] or "") <= cut]
        if rows:
            newest = max(newest, rows[-1]["sync_updated_at"] or "")
        if table == "settings":
            rows = [r for r in rows if r["key"] not in PRIVATE_SETTINGS]
        if rows:
            out[table] = [_row_out(table, r) for r in rows]
    if cut:
        tomb = [t for t in tomb if t["deleted_at"] <= cut]
    if tomb:
        newest = max(newest, tomb[-1]["deleted_at"])
    return {"cursor": (cut or newest or since) or None, "changes": out, "tombstones": tomb, "has_more": cut is not None}


# ---------------------------------------------------------------- Senden

def _coerce_id(table: str, value):
    return str(value) if ENTITIES[table]["pk"] != "id" else int(value)


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


def push(conn, device: str | None, items: list[dict], deletes: list[dict] | None = None, now: str | None = None) -> dict:
    """items: [{entity, id | local_id, op_id?, base_version, updated_at, data}], deletes: [{entity, id, deleted_at}].

    `op_id` (optional, 8-100 Zeichen [A-Za-z0-9._:-], z. B. eine UUID je Eintrag, beim Wiederholen dieselbe): das
    Ergebnis wird gemerkt; derselbe Eintrag noch einmal bekommt dasselbe Ergebnis mit `repeated: true` und dieselbe
    ID-Zuordnung, statt eine neue Zeile doppelt anzulegen. Fehler werden nicht gemerkt (ein spaeterer Versuch darf
    gelingen)."""
    now = now or now_utc()
    device = (device or "")[:80] or None
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
                    results.append(_push_annotation(conn, it, device, now))
                    continue
                client_ts = it.get("updated_at") if TS_RE.match(it.get("updated_at") or "") else now
                rid = it.get("id")
                if rid is None:
                    data["sync_version"], data["sync_updated_at"], data["sync_device"] = 1, now, device
                    keys = list(data)
                    if table == "settings":
                        conn.execute("INSERT INTO settings(key, value, sync_version, sync_updated_at, sync_device) VALUES (?,?,?,?,?) "
                                     "ON CONFLICT(key) DO UPDATE SET value=excluded.value, sync_version=settings.sync_version+1, "
                                     "sync_updated_at=excluded.sync_updated_at, sync_device=excluded.sync_device",
                                     (it.get("local_id"), data.get("value"), 1, now, device))
                        row = db.row(conn, "SELECT * FROM settings WHERE key=?", (it.get("local_id"),))
                        results.append({"entity": table, "id": row["key"], "status": "applied", "version": row["sync_version"]})
                        continue
                    cur = conn.execute(f"INSERT INTO {table}({','.join(keys)}) VALUES ({','.join('?' * len(keys))})", [data[k] for k in keys])
                    new_id = cur.lastrowid
                    if isinstance(it.get("local_id"), int) and it["local_id"] < 0:
                        mapping[(table, it["local_id"])] = new_id
                    results.append({"entity": table, "local_id": it.get("local_id"), "id": new_id, "status": "created", "version": 1})
                    continue
                rid = _coerce_id(table, rid)
                server = db.row(conn, f"SELECT * FROM {table} WHERE {pk}=?", (rid,))
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
                    results.append({"entity": table, "id": rid, "status": "resurrected" if tomb else "created", "version": 1})
                    continue
                sv = server.get("sync_version") or 1
                base = it.get("base_version")
                if base is not None and int(base) == sv:
                    merged, won = dict(server) | data, list(data)
                    status = "applied"
                else:
                    merged, won = _merge_fields(server, data, client_ts, server.get("sync_updated_at") or "", cols)
                    status = "conflict"
                    conflicts.append({"entity": table, "id": rid, "server": _row_out(table, server), "client": data, "client_won": won})
                changed = {c: merged[c] for c in cols if c != pk and merged.get(c) != server.get(c)}
                if changed:
                    sets = ", ".join(f"{c}=?" for c in changed) + ", sync_version=?, sync_updated_at=?, sync_device=?"
                    conn.execute(f"UPDATE {table} SET {sets} WHERE {pk}=?", [*changed.values(), sv + 1, now, device, rid])
                    sv += 1
                results.append({"entity": table, "id": rid, "status": status, "version": sv, "client_won": won})
            finally:
                if op and len(results) > n0 and results[-1].get("status") not in ("error", "plan_required"):
                    conn.execute("INSERT OR IGNORE INTO sync_ops(op_id, entity, result, device, created_at) VALUES (?,?,?,?,?)",
                                 (op, table, json.dumps(results[-1], ensure_ascii=False), device, now))
    for d in deletes or []:
        table = d.get("entity")
        if table not in ENTITIES or table == "annotations":
            results.append({"entity": table, "status": "unknown_entity"})
            continue
        pk = ENTITIES[table]["pk"]
        rid = _coerce_id(table, d.get("id"))
        when = d.get("deleted_at") if TS_RE.match(d.get("deleted_at") or "") else now
        server = db.row(conn, f"SELECT * FROM {table} WHERE {pk}=?", (rid,))
        if server is None:
            results.append({"entity": table, "id": rid, "status": "deleted"})
            continue
        if when >= (server.get("sync_updated_at") or ""):
            conn.execute(f"DELETE FROM {table} WHERE {pk}=?", (rid,))
            conn.execute("UPDATE sync_tombstones SET device=?, deleted_at=? WHERE entity=? AND entity_id=?", (device, now, table, str(rid)))
            results.append({"entity": table, "id": rid, "status": "deleted"})
        else:
            conflicts.append({"entity": table, "id": rid, "server": _row_out(table, server), "client": None, "client_won": []})
            results.append({"entity": table, "id": rid, "status": "edit_wins", "version": server.get("sync_version")})
    return {"results": results, "mapping": [{"entity": e, "local_id": l, "id": i} for (e, l), i in mapping.items()],
            "conflicts": conflicts, "server_time": now}


def _push_annotation(conn, it: dict, device: str | None, now: str) -> dict:
    """Notizen: gleiche Regel wie PUT /api/files/{id}/annotations (base_version, 409 -> Konflikt mit Serverstand)."""
    file_id = str(it.get("id") or it.get("local_id") or "")
    if not db.row(conn, "SELECT 1 FROM files WHERE id=?", (file_id,)):
        if not _register_device_file(conn, file_id, it.get("file")):
            return {"entity": "annotations", "id": file_id, "status": "unknown_file"}
    data = it.get("data") or {}
    cur = db.row(conn, "SELECT version, data FROM annotations WHERE file_id=?", (file_id,))
    cur_v = (cur["version"] or 1) if cur else 0
    base = it.get("base_version")
    if cur and (base is None or int(base) != cur_v):
        return {"entity": "annotations", "id": file_id, "status": "conflict", "version": cur_v, "data": json.loads(cur["data"])}
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
