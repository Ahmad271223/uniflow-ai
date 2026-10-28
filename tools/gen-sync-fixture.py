"""Erzeugt packages/shared-contracts/fixtures/sync/cases.json: Vertrag G2 (Geraete-Synchronisierung) aus der Python-Referenz.

Jeder Fall laeuft gegen eine frische Datenbank (app/db.py-Schema mit den Sync-Triggern) und zeichnet Push-Eingaben
und -Antworten sowie Abruf-Antworten auf. Zeitstempel des Servers werden durch "<zeit>" ersetzt; die Entscheidungen
(wer gewinnt) haengen nur von den Zeitstempeln der Clients ab, die weit in Vergangenheit oder Zukunft liegen.
Der Swift- und der Kotlin-Client (lokaler Teil: eigene Datenbank mit denselben Spalten/Trigger-Regeln, Push/Pull)
pruefen gegen dieselbe Datei. Aufruf im Projektordner: python tools/gen-sync-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "sync" / "cases.json"
TIME_KEYS = {"sync_updated_at", "deleted_at", "server_time", "cursor", "created_at", "updated_at", "first_seen", "downloaded_at", "due"}
PAST, FUTURE, LATER = "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z", "2099-06-01T00:00:00.000Z"


def _setup_env() -> None:
    tmp = tempfile.mkdtemp(prefix="uniflow-sync-fixture-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    sys.path.insert(0, str(ROOT))


def scrub(x):
    if isinstance(x, dict):
        return {k: ("<zeit>" if k in TIME_KEYS and isinstance(v, str) and v[:2] == "20" and v not in (PAST, FUTURE, LATER) else scrub(v)) for k, v in x.items()}
    if isinstance(x, list):
        return [scrub(v) for v in x]
    return x


def fresh_conn():
    from app import db
    p = Path(tempfile.mkdtemp(prefix="uniflow-sync-case-")) / "case.db"
    conn = sqlite3.connect(p, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    db._init_db(conn)
    # Zeilen aus dem Start (Einstellungen, Pseudokurs, Semester) bekommen EINEN Zeitstempel, danach eine kurze Pause:
    # sonst lagen sie mit feiner Uhr (Mac) mal in verschiedenen Millisekunden, mal gleich, und tauschten im Abruf den
    # Platz (ORDER BY sync_updated_at, Schluessel), etwa semester_rule_applied und hours_per_day (Befund 28.10.2026).
    # Nur Zeilen mit anderem Wert werden geaendert, so greift der Trigger fuer unveraenderte Zeilen nicht.
    from app import sync
    tables = [t for t in sync.ENTITIES if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (t,)).fetchone()]
    stamps = [conn.execute(f"SELECT MAX(sync_updated_at) FROM {t}").fetchone()[0] for t in tables]
    t0 = max((x for x in stamps if x), default=None)
    if t0:
        for t in tables:
            conn.execute(f"UPDATE {t} SET sync_updated_at=? WHERE sync_updated_at IS NOT ?", (t0, t0))
    conn.commit()
    time.sleep(0.05)
    conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Kurs', 'vorlesung', 1, '2026-10-26')")
    conn.execute("INSERT OR IGNORE INTO files(id, course_id, name, kind, status) VALUES ('f1', 'c1', 'x.pdf', 'pdf', 'neu')")
    conn.commit()
    return conn


def build() -> dict:
    from app import sync
    cases = []

    def case(name, steps_fn):
        conn = fresh_conn()
        steps = []

        def push(label, device, items, deletes=None):
            out = sync.push(conn, device, items, deletes)
            conn.commit()
            steps.append({"op": "push", "label": label, "device": device, "items": items, "deletes": deletes or [], "expect": scrub(out)})
            return out

        def pull(label, since=None, limit=None):
            out = sync.changes(conn, since, limit or sync.MAX_PULL)
            step = {"op": "pull", "label": label, "since": "<cursor>" if since else None, "expect": scrub(out)}
            if limit:
                step["limit"] = limit
            steps.append(step)
            return out
        steps_fn(push, pull, conn)
        conn.close()
        cases.append({"name": name, "steps": steps})

    def neu(push, pull, conn):
        push("Erstes Geraet legt Modul, Paket und Aufgabe an (lokale IDs negativ, Eltern vor Kindern)", "ipad-1", [
            {"entity": "modules", "local_id": -1, "data": {"name": "Mathe I", "color": "#4f5bd5", "priority": 2}},
            {"entity": "study_packages", "local_id": -2, "data": {"date": "2026-11-02", "module_id": -1, "subject": "Mathe I", "title": "Woche 3", "planned_minutes": 60}},
            {"entity": "study_tasks", "local_id": -3, "data": {"package_id": -2, "type": "uebung", "title": "Blatt 3", "est_minutes": 30}},
            {"entity": "study_tasks", "local_id": -4, "data": {"package_id": -99, "type": "uebung", "title": "kaputt"}},
        ])
        r = pull("Zweites Geraet holt alles (ohne Cursor)")
        pull("Mit dem Cursor der letzten Antwort: nichts Neues", since=r["cursor"])

    def aenderung(push, pull, conn):
        push("Anlegen", "ipad-1", [{"entity": "modules", "local_id": -1, "data": {"name": "Physik", "color": "#111111"}}])
        push("Aenderung mit passender Version: uebernommen", "mac-1", [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": FUTURE, "data": {"name": "Physik I"}}])
        push("Veraltete Version, Client spaeter: Client gewinnt die geaenderten Felder", "ipad-1",
             [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": FUTURE, "data": {"name": "Physik 1", "priority": 3}}])
        push("Veraltete Version, Client frueher: Server bleibt, Konflikt gemeldet", "ipad-1",
             [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": PAST, "data": {"name": "uralt"}}])
        pull("Stand danach")

    def loeschen(push, pull, conn):
        push("Anlegen", "ipad-1", [{"entity": "flashcards", "local_id": -1, "data": {"question": "Q", "answer": "A", "box": 1}},
                                   {"entity": "flashcards", "local_id": -2, "data": {"question": "Q2", "answer": "A2", "box": 1}}])
        push("Loeschen nach der letzten Aenderung: geloescht, Tombstone", "mac-1", [], [{"entity": "flashcards", "id": 1, "deleted_at": FUTURE}])
        push("Loeschen vor der letzten Aenderung: Aenderung gewinnt", "mac-1", [], [{"entity": "flashcards", "id": 2, "deleted_at": PAST}])
        push("Aenderung aelter als der Tombstone: bleibt geloescht", "ipad-1", [{"entity": "flashcards", "id": 1, "base_version": 1, "updated_at": PAST, "data": {"box": 2}}])
        push("Aenderung juenger als der Tombstone: wiederhergestellt", "ipad-1", [{"entity": "flashcards", "id": 1, "base_version": 1, "updated_at": LATER, "data": {"question": "Q", "answer": "A", "box": 2}}])
        pull("Stand danach: Tombstone und wiederhergestellte Karte")

    def notizen(push, pull, conn):
        push("Erste Notizen ohne base_version", "ipad-1", [{"entity": "annotations", "id": "f1", "data": {"pages": {"1": {"objects": [{"id": "s1", "type": "stroke"}]}}}}])
        push("Mit passender base_version: Version 2", "mac-1", [{"entity": "annotations", "id": "f1", "base_version": 1, "data": {"pages": {"1": {"objects": [{"id": "s1"}, {"id": "s2"}]}}}}])
        push("Veraltete base_version: Konflikt mit Serverstand (Client fuehrt zusammen und sendet erneut)", "ipad-1",
             [{"entity": "annotations", "id": "f1", "base_version": 1, "data": {"pages": {"1": {"objects": [{"id": "s1"}, {"id": "s3"}]}}}}])
        push("Unbekannte Datei", "ipad-1", [{"entity": "annotations", "id": "gibt-es-nicht", "base_version": 0, "data": {}}])
        pull("Stand danach")

    def einstellungen(push, pull, conn):
        push("Einstellung setzen; lan_pin wird nie synchronisiert", "ipad-1", [
            {"entity": "settings", "local_id": "hours_per_day", "data": {"value": "6"}},
            {"entity": "settings", "local_id": "lan_pin", "data": {"value": "123456"}}])
        out = pull("Abruf enthaelt hours_per_day, nie lan_pin oder university")
        assert "lan_pin" not in {r["key"] for r in out["changes"].get("settings", [])}

    def seiten(push, pull, conn):
        # Startzustand abholen, dann fuenf Karten mit verschiedenen Zeitstempeln und ein spaeteres Modul
        r = pull("Startzustand (Einstellungen usw.)")
        cards = [{"entity": "flashcards", "local_id": -(i + 1), "data": {"question": f"S{i}", "answer": "A", "box": 1}} for i in range(5)]
        for i, c in enumerate(cards):
            push(f"Karte {i + 1} anlegen", "ipad-1", [c])
            time.sleep(0.005)
        push("Spaeter ein Modul", "mac-1", [{"entity": "modules", "local_id": -1, "data": {"name": "Danach"}}])
        cur = r["cursor"]
        for n in range(1, 10):
            r = pull(f"Seite {n} mit limit=2: hoechstens 2 Zeilen je Tabelle, Cursor = Grenze, has_more bis zum Ende",
                     since=cur, limit=2)
            cur = r["cursor"]
            if not r["has_more"]:
                break
        pull("Danach nichts mehr", since=cur, limit=2)

    def wiederholen(push, pull, conn):
        items = [{"entity": "modules", "local_id": -1, "op_id": "op-ipad-0001", "data": {"name": "Wdh"}},
                 {"entity": "study_packages", "local_id": -2, "op_id": "op-ipad-0002",
                  "data": {"date": "2026-11-02", "module_id": -1, "subject": "Wdh", "title": "W1"}}]
        push("Erster Versand mit op_id je Eintrag", "ipad-1", items)
        push("Derselbe Versand noch einmal (Antwort verloren): dasselbe Ergebnis mit repeated, keine zweite Zeile", "ipad-1", items)
        push("Wiederholung plus neues Kind, das auf das wiederholte Modul zeigt", "ipad-1",
             [items[0], {"entity": "study_tasks", "local_id": -3, "op_id": "op-ipad-0003",
                         "data": {"package_id": -2, "type": "uebung", "title": "Blatt"}}, items[1]])
        push("Fehler werden nicht gemerkt", "ipad-1",
             [{"entity": "study_tasks", "local_id": -9, "op_id": "op-ipad-0009", "data": {"package_id": -77, "type": "uebung", "title": "x"}}])
        push("Fehler noch einmal: wieder ausgewertet, ohne repeated", "ipad-1",
             [{"entity": "study_tasks", "local_id": -9, "op_id": "op-ipad-0009", "data": {"package_id": -77, "type": "uebung", "title": "x"}}])
        pull("Stand danach: ein Modul, ein Paket, eine Aufgabe")

    for name, fn in (("neu-anlegen-und-abrufen", neu), ("aenderungen-und-konflikte", aenderung), ("loeschen-und-wiederherstellen", loeschen),
                     ("notizen-base-version", notizen), ("einstellungen", einstellungen), ("abruf-in-seiten", seiten),
                     ("wiederholt-senden-op-id", wiederholen)):
        case(name, fn)
    return {"_hinweis": "Erzeugt mit tools/gen-sync-fixture.py aus der Python-Referenz (app/sync.py); nicht von Hand aendern. "
                        "Zeitstempel des Servers sind '<zeit>'; Entscheidungen haengen nur von den Client-Zeitstempeln ab.",
            "rules": {"entities": list(sync.ENTITIES), "order": "Eltern vor Kindern (Reihenfolge der entities)",
                      "columns": list(sync.SYNC_COLS), "private_settings": sorted(sync.PRIVATE_SETTINGS),
                      "timestamp": "UTC, YYYY-MM-DDTHH:MM:SS.mmmZ, Vergleich als Text",
                      "new_rows": "id weglassen, local_id negativ; Antwort mapping; Fremdschluessel mit negativen IDs werden im selben Push aufgeloest",
                      "op_id": "optional je Eintrag, 8-100 Zeichen [A-Za-z0-9._:-], beim Wiederholen dieselbe: gemerktes Ergebnis mit repeated=true "
                               "und derselben mapping-Zuordnung, keine zweite Zeile; Fehler (status error) werden nicht gemerkt; Frist 90 Tage",
                      "pull_paging": "limit 1-2000 (Standard 2000) je Tabelle; wird eine Tabelle abgeschnitten, gilt fuer alle Tabellen und "
                                     "Tombstones die kleinste abgeschnittene Zeit als Grenze: alles bis einschliesslich Grenze, cursor = Grenze, "
                                     "has_more = true; gleiche Zeitstempel am Ende kommen vollstaendig; weiter abrufen, solange has_more",
                      "update": "base_version == Serverversion -> applied; sonst conflict: je Feld gewinnt der spaetere Schreiber (updated_at vs sync_updated_at)",
                      "delete": "deleted_at >= sync_updated_at des Servers -> deleted (Tombstone); sonst edit_wins; spaetere Aenderung nach Tombstone -> resurrected",
                      "annotations": "wie PUT /api/files/{id}/annotations: base_version muss der Serverversion entsprechen, sonst conflict mit data/version",
                      "endpoints": {"pull": "GET /api/sync/changes?since=<cursor>&device_id=&limit=", "push": "POST /api/sync/push {device_id, items, deletes}"}},
            "cases": cases}


def main(check: bool) -> bool:
    _setup_env()
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
