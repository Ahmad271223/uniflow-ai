"""Geraete-Abgleich der Windows-App mit dem Studora-Konto (Vertrag G2, 28.10.2026).

Die Windows-App behaelt ihre eigene Datenbank (Einzelplatz) und gleicht sie mit dem Konto im Dienst ab, damit Notizen,
Module, Stundenplan-Anpassungen, Lernkalender, Karteikarten und Einstellungen auf Windows und dem iPad gleich sind.
Hochschuldateien laedt weiter jedes Geraet selbst; abgeglichen wird, was der Nutzer daraus macht.

Ablauf je Lauf (`run`): abrufen -> senden -> noch einmal abrufen (Ergebnisse von Konflikten).
- **Zuordnung:** lokale und entfernte Zeilen haben verschiedene IDs. `sync_link_map` merkt sich je Zeile die ID im
  Dienst, die zuletzt abgeglichene Version dort (`remote_version`) und hier (`local_version`). Eine Zeile ist lokal
  geaendert, wenn ihre `sync_version` nicht mehr `local_version` ist (die Trigger aus `app/sync.py` zaehlen sie bei
  jeder Aenderung der App hoch).
- **Erster Abgleich ohne Doppelte:** Kommt eine Zeile aus dem Dienst, die hier noch keine Zuordnung hat, sucht der Client
  zuerst eine gleiche Zeile ueber einen fachlichen Schluessel (Modul: Name + Semester, Termin: Kurs + Wochentag +
  Zeiten, Lernpaket: Datum + Modul + Titel, ...). Windows und iPad legen aus demselben Stud.IP sonst alles doppelt an.
  Deshalb wird vor dem Senden immer zuerst abgerufen.
- **Konflikte:** Felder fuehrt der Dienst zusammen (spaeterer Schreiber je Feld). Notizen fuehrt der Client je Objekt
  zusammen (`app/annotation_merge.py`, gleiche Regeln wie Web, iPad, Android) und sendet erneut; Striche beider
  Geraete bleiben.
- **Loeschen:** lokale Tombstones (von den Triggern) gehen als `deletes` an den Dienst; Tombstones aus dem Dienst
  loeschen hier, wenn die Zeile hier nicht geaendert wurde. Was der Client selbst anwendet, traegt `sync_device` =
  `~dienst`, damit es nie zurueckgesendet wird.
- **Noch nicht passend:** Zeilen, deren Eltern oder Datei es hier (noch) nicht gibt (z. B. Notizen zu einer PDF, die
  der Stud.IP-Abgleich dieses PCs noch nicht geladen hat), warten in `sync_link_pending` und werden bei jedem Lauf
  erneut versucht.
Nie abgeglichen: Einstellungen dieses Geraets (`LOCAL_SETTINGS`), Hochschuldateien selbst, Zugangsdaten.
"""
from __future__ import annotations

import json
import re
import threading
import time

from . import config, db, service_link
from .annotation_merge import merge_document
from .sync import ENTITIES, SYNC_COLS

APPLIED_DEVICE = "~dienst"
PAGE = 2000
PUSH_BATCH = 400
LOCAL_SETTINGS = {"lan_pin", "university", "demo_content", "semester_rule_applied", "pen_input"}
# Spalten, die nur auf diesem Geraet etwas bedeuten (IDs von Tabellen ausserhalb des Abgleichs)
LOCAL_COLS = {"study_tasks": {"test_id"}}
_SECRET_RE = re.compile(r"token|secret|passw|pin$|_path$|_dir$|service", re.I)


class SyncError(Exception):
    pass


# ---------------------------------------------------------------- Tabellen fuer die Zuordnung

def ensure_tables(conn) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_link_map (
        entity TEXT NOT NULL, remote_id TEXT NOT NULL, local_id TEXT NOT NULL, remote_version INTEGER,
        local_version INTEGER, base TEXT, PRIMARY KEY (entity, remote_id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sync_link_local ON sync_link_map(entity, local_id)")
    conn.execute("CREATE TABLE IF NOT EXISTS sync_link_state (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("""CREATE TABLE IF NOT EXISTS sync_link_pending (
        entity TEXT NOT NULL, remote_id TEXT NOT NULL, payload TEXT NOT NULL, reason TEXT, PRIMARY KEY (entity, remote_id))""")


def _state(conn, key, default=None):
    r = conn.execute("SELECT value FROM sync_link_state WHERE key=?", (key,)).fetchone()
    return r[0] if r else default


def _set_state(conn, key, value) -> None:
    conn.execute("INSERT INTO sync_link_state(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                 (key, None if value is None else str(value)))


def reset(conn) -> None:
    """Anderes Konto oder Neuanfang: Zuordnung und Cursor vergessen (lokale Daten bleiben)."""
    ensure_tables(conn)
    for t in ("sync_link_map", "sync_link_state", "sync_link_pending"):
        conn.execute(f"DELETE FROM {t}")


# ---------------------------------------------------------------- Hilfen

def _cols(conn, table) -> list[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})") if r[1] not in SYNC_COLS]


def _int_pk(table) -> bool:
    return ENTITIES[table]["pk"] == "id"


def _setting_local(key: str) -> bool:
    return key in LOCAL_SETTINGS or bool(_SECRET_RE.search(key or ""))


def _norm(v):
    return (str(v).strip().lower() if v is not None else "")


def natural_key(table: str, row: dict, fk_local: dict | None = None) -> tuple | None:
    """Fachlicher Schluessel einer Zeile (Fremdschluessel als lokale IDs). None = kein Abgleich ueber Inhalt."""
    f = fk_local or {}
    if table == "modules":
        return (_norm(row.get("name")), _norm(row.get("semester")))
    if table == "folders":
        return (_norm(row.get("name")), f.get("parent_id", row.get("parent_id")), f.get("module_id", row.get("module_id")))
    if table == "course_events":
        return (_norm(row.get("course_id")) or _norm(row.get("title")), row.get("weekday"), row.get("start_time"), row.get("end_time"),
                _norm(row.get("date_from")), _norm(row.get("kind")))
    if table == "event_exceptions":
        return (f.get("event_id", row.get("event_id")), row.get("date"), _norm(row.get("type")))
    if table == "study_packages":
        return (row.get("date"), f.get("module_id", row.get("module_id")), _norm(row.get("title") or row.get("subject")))
    if table == "study_tasks":
        return (f.get("package_id", row.get("package_id")), _norm(row.get("type")), _norm(row.get("title")), _norm(row.get("file_id")))
    if table == "flashcards":
        return (_norm(row.get("question")), _norm(row.get("file_id")))
    return None


class Client:
    def __init__(self, conn, device: str):
        self.conn, self.device = conn, device
        self.retry_notes = False
        self._nk: dict[str, dict] = {}
        self.stats = {"pulled": 0, "applied": 0, "pushed": 0, "deleted": 0, "conflicts": 0, "pending": 0, "notes_merged": 0,
                      "plan_required": False, "errors": []}

    # ------------------------------------------------ Zuordnung
    def local_of(self, table, remote_id) -> str | None:
        r = self.conn.execute("SELECT local_id FROM sync_link_map WHERE entity=? AND remote_id=?", (table, str(remote_id))).fetchone()
        return r[0] if r else None

    def map_of_local(self, table, local_id) -> dict | None:
        return db.row(self.conn, "SELECT * FROM sync_link_map WHERE entity=? AND local_id=? ORDER BY rowid LIMIT 1", (table, str(local_id)))

    def set_map(self, table, remote_id, local_id, remote_version, local_version, base=None, keep_base=False):
        if keep_base:
            old = db.row(self.conn, "SELECT base FROM sync_link_map WHERE entity=? AND remote_id=?", (table, str(remote_id)))
            base = old["base"] if old else base
        self.conn.execute("""INSERT INTO sync_link_map(entity, remote_id, local_id, remote_version, local_version, base) VALUES (?,?,?,?,?,?)
                             ON CONFLICT(entity, remote_id) DO UPDATE SET local_id=excluded.local_id, remote_version=excluded.remote_version,
                             local_version=excluded.local_version, base=excluded.base""",
                          (table, str(remote_id), str(local_id), remote_version, local_version, base))

    def local_row(self, table, local_id) -> dict | None:
        pk = ENTITIES[table]["pk"]
        lid = int(local_id) if _int_pk(table) else local_id
        return db.row(self.conn, f"SELECT * FROM {table} WHERE {pk}=?", (lid,))

    # ------------------------------------------------ Abrufen und anwenden
    def remote_fk_to_local(self, table, row) -> tuple[dict, str | None]:
        """Fremdschluessel aus dem Dienst -> lokale IDs; (Werte, fehlender Pflicht-Elternteil oder None)."""
        out = {}
        for col, target in ENTITIES[table]["fk"].items():
            v = row.get(col)
            if v is None:
                continue
            lid = self.local_of(target, v)
            if lid is None:
                if col in ("package_id", "event_id"):          # NOT NULL in der Datenbank
                    return out, f"{target} {v} fehlt hier"
                out[col] = None
            else:
                out[col] = int(lid)
        return out, None

    def apply_row(self, table, row) -> str:
        """Eine Zeile aus dem Dienst hier uebernehmen. Ergebnis: applied | skipped | pending | own."""
        pk = ENTITIES[table]["pk"]
        rid = str(row[pk])
        if table == "settings" and _setting_local(rid):
            return "skipped"
        if table == "annotations":
            return self.apply_annotation(row)
        fk, missing = self.remote_fk_to_local(table, row)
        if missing:
            self.conn.execute("INSERT OR REPLACE INTO sync_link_pending(entity, remote_id, payload, reason) VALUES (?,?,?,?)",
                              (table, rid, json.dumps(row, ensure_ascii=False), missing))
            return "pending"
        cols = [c for c in _cols(self.conn, table) if c != pk and c in row and c not in LOCAL_COLS.get(table, ())]
        vals = {c: (fk[c] if c in fk else row[c]) for c in cols}
        rv = row.get("sync_version") or 1
        lid = self.local_of(table, rid)
        if lid is None and table == "settings" and self.local_row(table, rid):
            lid = rid
        if lid is None:
            nk = natural_key(table, row, fk)
            if nk is not None:
                lid = self.find_by_key(table, nk)
        if lid is not None:
            cur = self.local_row(table, lid)
            m = db.row(self.conn, "SELECT * FROM sync_link_map WHERE entity=? AND remote_id=?", (table, rid))
            if cur is None:
                if m:
                    return "skipped"                            # hier geloescht, das Senden entscheidet
                lid = None
            else:
                dirty = m is not None and cur.get("sync_version") != m["local_version"]
                if m is None:
                    # erster Abgleich mit gleicher Zeile: der spaetere Stand gewinnt. Einstellungen: ein geaenderter Wert
                    # schlaegt immer den Standardwert (ein neues Konto im Dienst hat frische Standardwerte, die sonst
                    # die eigenen Einstellungen dieses PCs ueberschreiben wuerden)
                    newer_here = (cur.get("sync_updated_at") or "") > (row.get("sync_updated_at") or "")
                    if table == "settings":
                        default = db.DEFAULT_SETTINGS.get(rid)
                        if default is not None and str(row.get("value")) == default and str(cur.get("value")) != default:
                            newer_here = True
                        elif default is not None and str(cur.get("value")) == default and str(row.get("value")) != default:
                            newer_here = False
                    if newer_here:
                        self.set_map(table, rid, lid, rv, -1)
                        return "skipped"
                elif dirty:
                    return "skipped"                            # lokal geaendert: der Dienst fuehrt beim Senden zusammen
                elif m["remote_version"] == rv and row.get("sync_device") == self.device:
                    return "own"
                changed = {c: v for c, v in vals.items() if cur.get(c) != v}
                nv = (cur.get("sync_version") or 1) + 1
                sets = "".join(f"{c}=?, " for c in changed)
                self.conn.execute(f"UPDATE {table} SET {sets}sync_version=?, sync_updated_at=?, sync_device=? WHERE {pk}=?",
                                  [*changed.values(), nv, row.get("sync_updated_at") or service_now(), APPLIED_DEVICE,
                                   int(lid) if _int_pk(table) else lid])
                self.set_map(table, rid, lid, rv, nv)
                return "applied"
        # neu hier
        nv = 1
        data = dict(vals)
        if not _int_pk(table):
            data[pk] = rid
        data.update(sync_version=nv, sync_updated_at=row.get("sync_updated_at") or service_now(), sync_device=APPLIED_DEVICE)
        keys = list(data)
        cur = self.conn.execute(f"INSERT INTO {table}({','.join(keys)}) VALUES ({','.join('?' * len(keys))})", [data[k] for k in keys])
        new_lid = cur.lastrowid if _int_pk(table) else rid
        self.set_map(table, rid, new_lid, rv, nv)
        nk = natural_key(table, {**data, pk: new_lid})
        if nk is not None and table in self._nk:
            self._nk[table].setdefault(nk, str(new_lid))
        return "applied"

    def find_by_key(self, table, nk) -> str | None:
        """Gleiche Zeile ueber den fachlichen Schluessel (je Lauf einmal je Tabelle eingelesen)."""
        if table not in self._nk:
            pk = ENTITIES[table]["pk"]
            idx = {}
            for r in db.rows(self.conn, f"SELECT * FROM {table} ORDER BY {pk}"):
                k = natural_key(table, r)
                if k is not None:
                    idx.setdefault(k, str(r[pk]))
            self._nk[table] = idx
        return self._nk[table].get(nk)

    def apply_annotation(self, row) -> str:
        fid = str(row["file_id"])
        remote = row.get("data") if isinstance(row.get("data"), dict) else json.loads(row.get("data") or "{}")
        rv = row.get("version") or row.get("sync_version") or 1
        if not db.row(self.conn, "SELECT 1 FROM files WHERE id=?", (fid,)):
            self.conn.execute("INSERT OR REPLACE INTO sync_link_pending(entity, remote_id, payload, reason) VALUES (?,?,?,?)",
                              ("annotations", fid, json.dumps(row, ensure_ascii=False), "Datei hier noch nicht geladen"))
            return "pending"
        cur = db.row(self.conn, "SELECT * FROM annotations WHERE file_id=?", (fid,))
        m = db.row(self.conn, "SELECT * FROM sync_link_map WHERE entity='annotations' AND remote_id=?", (fid,))
        rtxt = json.dumps(remote, ensure_ascii=False)
        if cur is None:
            self.conn.execute("INSERT INTO annotations(file_id, data, updated_at, version, sync_version, sync_updated_at, sync_device) "
                              "VALUES (?,?,?,?,?,?,?)", (fid, rtxt, db.now_iso(), 1, 1, row.get("sync_updated_at") or service_now(), APPLIED_DEVICE))
            self.set_map("annotations", fid, fid, rv, 1, rtxt)
            return "applied"
        dirty = m is None or cur.get("sync_version") != m["local_version"]
        if m is not None and m["remote_version"] == rv and not dirty:
            return "own"
        local = json.loads(cur["data"] or "{}")
        if not dirty:
            new_doc, merged = remote, False
        else:
            base = json.loads(m["base"]) if m and m["base"] else None
            new_doc, conflicts, _ = merge_document(base, local, remote)
            merged = True
            self.stats["conflicts"] += conflicts
            self.stats["notes_merged"] += 1
        nv = (cur.get("sync_version") or 1) + 1
        self.conn.execute("UPDATE annotations SET data=?, updated_at=?, version=COALESCE(version,1)+1, sync_version=?, sync_updated_at=?, sync_device=? "
                          "WHERE file_id=?", (json.dumps(new_doc, ensure_ascii=False), db.now_iso(), nv,
                                              row.get("sync_updated_at") or service_now(), APPLIED_DEVICE, fid))
        # zusammengefuehrt: lokal noch nicht im Dienst -> beim Senden mit base_version = rv
        self.set_map("annotations", fid, fid, rv, -1 if merged and json.dumps(new_doc, sort_keys=True) != json.dumps(remote, sort_keys=True) else nv, rtxt)
        return "applied"

    def apply_tombstone(self, t) -> None:
        table = t.get("entity")
        if table not in ENTITIES or table == "annotations":
            return
        rid = str(t.get("entity_id"))
        lid = self.local_of(table, rid)
        self.conn.execute("DELETE FROM sync_link_pending WHERE entity=? AND remote_id=?", (table, rid))
        if lid is None:
            return
        cur = self.local_row(table, lid)
        m = db.row(self.conn, "SELECT * FROM sync_link_map WHERE entity=? AND remote_id=?", (table, rid))
        self.conn.execute("DELETE FROM sync_link_map WHERE entity=? AND remote_id=?", (table, rid))
        others = self.conn.execute("SELECT 1 FROM sync_link_map WHERE entity=? AND local_id=?", (table, lid)).fetchone()
        if cur is None or others:
            return
        if m and cur.get("sync_version") != m["local_version"]:
            return                                              # hier geaendert: Zeile bleibt, wird neu gesendet
        pk = ENTITIES[table]["pk"]
        self.conn.execute(f"DELETE FROM {table} WHERE {pk}=?", (int(lid) if _int_pk(table) else lid,))
        self.stats["deleted"] += 1

    def pull(self) -> None:
        cursor = _state(self.conn, "cursor")
        for _ in range(200):
            q = "limit=%d&device_id=%s" % (PAGE, self.device) + (f"&since={cursor}" if cursor else "")
            d = _call("GET", "/api/sync/changes", query=q)
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                mark = service_now_sql(self.conn)
                for table in ENTITIES:
                    for row in (d.get("changes") or {}).get(table, []):
                        self.stats["pulled"] += 1
                        if self.apply_row(table, row) == "applied":
                            self.stats["applied"] += 1
                for t in d.get("tombstones") or []:
                    self.apply_tombstone(t)
                self.retry_pending()
                self.mark_applied_tombstones(mark)
                cursor = d.get("cursor") or cursor
                _set_state(self.conn, "cursor", cursor)
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise
            if not d.get("has_more"):
                break

    def retry_pending(self) -> None:
        for p in db.rows(self.conn, "SELECT * FROM sync_link_pending ORDER BY rowid"):
            row = json.loads(p["payload"])
            self.conn.execute("DELETE FROM sync_link_pending WHERE entity=? AND remote_id=?", (p["entity"], p["remote_id"]))
            if self.apply_row(p["entity"], row) == "applied":
                self.stats["applied"] += 1
        self.stats["pending"] = self.conn.execute("SELECT COUNT(*) FROM sync_link_pending").fetchone()[0]

    def mark_applied_tombstones(self, mark: str) -> None:
        """Tombstones, die beim Anwenden entstanden (auch durch ON DELETE CASCADE), gehoeren dem Dienst."""
        self.conn.execute("UPDATE sync_tombstones SET device=? WHERE device IS NULL AND deleted_at >= ?", (APPLIED_DEVICE, mark))

    # ------------------------------------------------ Senden
    def file_info(self, fid) -> dict | None:
        f = db.row(self.conn, "SELECT f.id, f.name, f.mime, f.course_id, c.title AS course_title, c.semester FROM files f "
                              "LEFT JOIN courses c ON c.id=f.course_id WHERE f.id=?", (fid,))
        if not f or f["course_id"] == "__user__":
            return None
        return {"name": f["name"], "mime": f["mime"], "course_id": f["course_id"], "course_title": f["course_title"] or f["course_id"],
                "semester": f["semester"]}

    def collect(self) -> tuple[list[dict], list[dict]]:
        items, deletes = [], []
        neg = {}
        for table in ENTITIES:
            pk = ENTITIES[table]["pk"]
            for r in db.rows(self.conn, f"SELECT * FROM {table}"):
                lid = str(r[pk])
                if table == "settings" and _setting_local(lid):
                    continue
                if table == "annotations":
                    if not self.file_info(lid):
                        continue                                # eigene Dokumente gleichen spaeter ab
                m = self.map_of_local(table, lid)
                if m and m["local_version"] == r.get("sync_version"):
                    continue
                if m is None and r.get("sync_device") == APPLIED_DEVICE:
                    continue
                data = {c: r[c] for c in _cols(self.conn, table) if c != pk and c not in LOCAL_COLS.get(table, ())}
                if table == "annotations":
                    data = json.loads(r["data"] or "{}")
                else:
                    for col, target in ENTITIES[table]["fk"].items():
                        v = data.get(col)
                        if v is None:
                            continue
                        pm = self.map_of_local(target, v)
                        if pm:
                            data[col] = int(pm["remote_id"])
                        elif (target, int(v)) in neg:
                            data[col] = neg[(target, int(v))]
                        else:
                            data[col] = None if col not in ("package_id", "event_id") else -10**9
                    if any(data.get(c) == -10**9 for c in ("package_id", "event_id")):
                        continue                                # Elternteil noch nicht im Dienst: naechster Lauf
                it = {"entity": table, "updated_at": r.get("sync_updated_at") or service_now(), "data": data,
                      "op_id": f"{self.device}.{table}.{lid}.{r.get('sync_version')}"[:100]}
                if table == "annotations":
                    it["id"] = lid
                    it["base_version"] = m["remote_version"] if m else None
                    it["file"] = self.file_info(lid)
                elif m:
                    it["id"] = int(m["remote_id"]) if _int_pk(table) else m["remote_id"]
                    it["base_version"] = m["remote_version"] if m["remote_version"] and m["remote_version"] > 0 else None
                elif _int_pk(table):
                    it["local_id"] = -int(lid)
                    neg[(table, int(lid))] = -int(lid)
                else:
                    it["local_id"] = lid
                it["_local"] = lid
                items.append(it)
        mark = _state(self.conn, "tomb_mark", "")
        for t in db.rows(self.conn, "SELECT * FROM sync_tombstones WHERE device IS NULL AND deleted_at > ? ORDER BY deleted_at", (mark,)):
            if t["entity"] not in ENTITIES or t["entity"] == "annotations":
                continue
            for m in db.rows(self.conn, "SELECT remote_id FROM sync_link_map WHERE entity=? AND local_id=?", (t["entity"], t["entity_id"])):
                deletes.append({"entity": t["entity"], "id": int(m["remote_id"]) if _int_pk(t["entity"]) else m["remote_id"],
                                "deleted_at": t["deleted_at"], "_local": t["entity_id"]})
        return items, deletes

    def push(self) -> None:
        items, deletes = self.collect()
        tomb_mark = max([d["deleted_at"] for d in deletes] + [_state(self.conn, "tomb_mark", "") or ""])
        if not items and not deletes:
            self._advance_tomb_mark()
            return
        # Neue Zeilen (negative IDs) mit ihren Kindern immer in einer Sendung; nur reine Aenderungen werden geteilt
        if any(isinstance(it.get("local_id"), int) for it in items):
            batches = [items]
        else:
            batches = [items[i:i + PUSH_BATCH] for i in range(0, len(items), PUSH_BATCH)] or [[]]
        for i, batch in enumerate(batches):
            body = {"device_id": self.device, "items": [{k: v for k, v in it.items() if not k.startswith("_")} for it in batch],
                    "deletes": [{k: v for k, v in d.items() if not k.startswith("_")} for d in deletes] if i == len(batches) - 1 else []}
            res = _call("POST", "/api/sync/push", body)
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                self.handle_results(batch, deletes if i == len(batches) - 1 else [], res)
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise
        _set_state(self.conn, "tomb_mark", tomb_mark)
        self._advance_tomb_mark()

    def _advance_tomb_mark(self) -> None:
        r = self.conn.execute("SELECT MAX(deleted_at) FROM sync_tombstones WHERE device IS NULL").fetchone()
        cur = _state(self.conn, "tomb_mark", "") or ""
        # Tombstones ohne Zuordnung (nie im Dienst) muessen nicht gesendet werden
        if r and r[0] and r[0] > cur:
            unsent = self.conn.execute("""SELECT 1 FROM sync_tombstones t JOIN sync_link_map m ON m.entity=t.entity AND m.local_id=t.entity_id
                                          WHERE t.device IS NULL AND t.deleted_at > ? LIMIT 1""", (cur,)).fetchone()
            if not unsent:
                _set_state(self.conn, "tomb_mark", r[0])

    def handle_results(self, batch, deletes, res) -> None:
        mapping = {(m["entity"], m["local_id"]): m["id"] for m in res.get("mapping") or []}
        by_key = {}
        for r in res.get("results") or []:
            key = (r.get("entity"), str(r.get("local_id")) if r.get("local_id") is not None else None, str(r.get("id")) if r.get("id") is not None else None)
            by_key.setdefault(key, r)
        conflicts = {(c["entity"], str(c["id"])): c for c in res.get("conflicts") or []}
        for it in batch:
            table, lid = it["entity"], it["_local"]
            r = None
            for k, v in by_key.items():
                if k[0] != table:
                    continue
                if it.get("local_id") is not None and k[1] == str(it["local_id"]):
                    r = v
                    break
                if it.get("id") is not None and k[2] == str(it["id"]) and (table != "settings" or k[1] is None):
                    r = v
                    break
            if r is None and table == "settings":
                r = next((v for k, v in by_key.items() if k[0] == "settings" and k[2] == str(it.get("local_id") or it.get("id"))), None)
            if r is None:
                continue
            st = r.get("status")
            cur = self.local_row(table, lid)
            lv = cur.get("sync_version") if cur else None
            if st == "plan_required":
                self.stats["plan_required"] = True
                continue
            if table == "annotations":
                self.after_annotation(it, r, cur)
                continue
            if st in ("created", "applied", "resurrected"):
                remote_id = r.get("id") if r.get("id") is not None else mapping.get((table, it.get("local_id")))
                if remote_id is None:
                    continue
                self.set_map(table, remote_id, lid, r.get("version") or 1, lv)
                self.stats["pushed"] += 1
            elif st == "conflict":
                c = conflicts.get((table, str(r.get("id"))))
                self.stats["conflicts"] += 1
                # Ergebnis des Dienstes gleich hier uebernehmen (Felder, die der Dienst behalten hat)
                if c and cur and c.get("server"):
                    merged = dict(c["server"])
                    for f in c.get("client_won") or []:
                        merged[f] = c["client"].get(f)
                    merged["sync_version"] = r.get("version")
                    self.set_map(table, r["id"], lid, None, lv)
                    self.apply_row(table, {**merged, ENTITIES[table]["pk"]: r["id"]})
                else:
                    self.set_map(table, r["id"], lid, None, lv)
            elif st == "deleted":
                pk = ENTITIES[table]["pk"]
                self.conn.execute("DELETE FROM sync_link_map WHERE entity=? AND local_id=?", (table, lid))
                mark = service_now_sql(self.conn)
                self.conn.execute(f"DELETE FROM {table} WHERE {pk}=?", (int(lid) if _int_pk(table) else lid,))
                self.mark_applied_tombstones(mark)
            elif st == "error":
                self.stats["errors"].append(f"{table}: {r.get('message')}")
        for d in deletes:
            r = next((v for k, v in by_key.items() if k[0] == d["entity"] and k[2] == str(d["id"])), None)
            if r is None:
                continue
            if r.get("status") == "deleted":
                self.conn.execute("DELETE FROM sync_link_map WHERE entity=? AND remote_id=?", (d["entity"], str(d["id"])))
            elif r.get("status") == "edit_wins":
                c = conflicts.get((d["entity"], str(d["id"])))
                self.conn.execute("DELETE FROM sync_link_map WHERE entity=? AND remote_id=?", (d["entity"], str(d["id"])))
                if c and c.get("server"):
                    self.apply_row(d["entity"], c["server"])    # im Dienst geaendert: Zeile kommt zurueck

    def after_annotation(self, it, r, cur) -> None:
        fid = it["_local"]
        st = r.get("status")
        if st == "applied":
            self.set_map("annotations", fid, fid, r.get("version"), cur.get("sync_version") if cur else None,
                         json.dumps(it["data"], ensure_ascii=False))
            self.stats["pushed"] += 1
        elif st == "conflict" and cur is not None:
            m = db.row(self.conn, "SELECT * FROM sync_link_map WHERE entity='annotations' AND remote_id=?", (fid,))
            base = json.loads(m["base"]) if m and m["base"] else None
            merged, conflicts, _ = merge_document(base, it["data"], r.get("data") or {})
            self.stats["conflicts"] += conflicts
            self.stats["notes_merged"] += 1
            nv = (cur.get("sync_version") or 1) + 1
            self.conn.execute("UPDATE annotations SET data=?, updated_at=?, version=COALESCE(version,1)+1, sync_version=?, sync_device=NULL WHERE file_id=?",
                              (json.dumps(merged, ensure_ascii=False), db.now_iso(), nv, fid))
            # naechster Versuch mit der Version des Dienstes als Basis (im selben Lauf, `run` sendet erneut)
            self.set_map("annotations", fid, fid, r.get("version"), -1, json.dumps(r.get("data") or {}, ensure_ascii=False))
            self.retry_notes = True
        elif st == "unknown_file":
            self.stats["errors"].append(f"Notizen zu {fid}: Datei im Dienst unbekannt")


def service_now() -> str:
    from .sync import now_utc
    return now_utc()


def service_now_sql(conn) -> str:
    return conn.execute("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now')").fetchone()[0]


def _call(method, path, body=None, query=""):
    status, _, data = service_link.call(method, path, json.dumps(body).encode() if body is not None else None, query=query,
                                        timeout=service_link.UPLOAD_TIMEOUT)
    try:
        d = json.loads(data or b"{}")
    except ValueError:
        d = {}
    if status >= 400:
        msg = d.get("detail") if isinstance(d.get("detail"), str) else f"Dienst antwortet {status}"
        raise SyncError(msg)
    return d


# ---------------------------------------------------------------- Lauf, Status, Hintergrund

_lock = threading.Lock()
_last: dict = {}
_kick = threading.Event()


def enabled() -> bool:
    st = service_link.load_state()
    return service_link.linked(st) and st.get("sync_enabled", True) and not service_link.university_mismatch(st)


def run(force: bool = False) -> dict:
    """Ein vollstaendiger Abgleich. Gibt Zahlen und Fehler zurueck; wirft nie (Ergebnis in `last_result`)."""
    global _last
    if config.is_hosted():
        return {"ok": False, "error": "Im Dienst gleicht das Konto selbst ab."}
    st = service_link.load_state()
    if not service_link.linked(st):
        return {"ok": False, "error": "Nicht mit einem Studora-Konto verbunden."}
    if (msg := service_link.university_mismatch(st)):
        return {"ok": False, "error": msg}
    if not _lock.acquire(blocking=False):
        return {"ok": False, "error": "Abgleich läuft schon.", "running": True}
    started = time.time()
    try:
        db.init_db()
        conn = db.connect()
        conn.isolation_level = None                             # Transaktionen selbst steuern
        try:
            ensure_tables(conn)
            account = (st.get("user") or {}).get("id")
            if _state(conn, "account") != account:
                reset(conn)
                _set_state(conn, "account", account)
            c = Client(conn, st.get("device_id") or "win")
            c.retry_notes = False
            c.pull()
            c.push()
            for _ in range(2):
                if not c.retry_notes:
                    break
                c.retry_notes = False
                c.push()
            c.pull()
            out = {"ok": True, **c.stats}
        finally:
            conn.close()
    except (SyncError, service_link.LinkError) as e:
        out = {"ok": False, "error": getattr(e, "message", None) or str(e)}
    except Exception as e:                                     # noqa: BLE001 - Hintergrundlauf darf nie abbrechen
        out = {"ok": False, "error": f"Abgleich fehlgeschlagen: {e}"}
    finally:
        _lock.release()
    out["at"] = int(time.time())
    out["seconds"] = round(time.time() - started, 1)
    _last = out
    try:
        s = service_link.load_state()
        s["sync_last"] = {k: out[k] for k in out if k in ("ok", "at", "pulled", "applied", "pushed", "deleted", "conflicts", "pending",
                                                          "notes_merged", "plan_required", "error")}
        service_link.save_state(s)
    except OSError:
        pass
    return out


def status() -> dict:
    st = service_link.load_state()
    return {"enabled": bool(st.get("sync_enabled", True)), "linked": service_link.linked(st), "last": st.get("sync_last"),
            "running": _lock.locked()}


def set_enabled(on: bool) -> dict:
    st = service_link.load_state()
    st["sync_enabled"] = bool(on)
    service_link.save_state(st)
    if on:
        kick()
    return status()


def kick() -> None:
    """Nach einer Aenderung in der App: bald abgleichen (gebuendelt)."""
    _kick.set()


_thread: threading.Thread | None = None


def start_background(interval: int = 180, debounce: float = 4.0) -> None:
    """Windows-App: im Hintergrund abgleichen, nach Aenderungen (gebuendelt) und sonst alle `interval` Sekunden."""
    global _thread
    if config.is_hosted() or (_thread and _thread.is_alive()):
        return

    def loop():
        time.sleep(5)
        while True:
            try:
                if enabled():
                    run()
            except Exception:                                  # noqa: BLE001
                pass
            _kick.wait(interval)
            if _kick.is_set():
                time.sleep(debounce)
                _kick.clear()
    _thread = threading.Thread(target=loop, name="studora-sync", daemon=True)
    _thread.start()
