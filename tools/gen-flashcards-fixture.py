"""Erzeugt packages/shared-contracts/fixtures/local-backend/flashcards.json (M8): eigene Karteikarten aus app/server.py
(`GET /api/flashcards` mit file_id und due, `POST /api/flashcards`, `POST /api/flashcards/{id}/review`,
`DELETE /api/flashcards/{id}`) auf erfundenen Daten. Der Swift-Kern (LocalFlashcardTests) legt dieselben Daten an,
schickt dieselben Anfragen mit derselben Uhr an das lokale Backend und vergleicht Status, Antwort und Tabelle.

Inhalt je Szenario:
- seed: SQL-Anweisungen nach init_db (Kurse mit und ohne Fach, Dateien; im Szenario "grenzen" Karten mit Faechern
  und Faelligkeiten, die nur Daten von aussen haben koennen)
- steps: Anfragen mit eingefrorener, weitergestellter Uhr (`now`, Ortszeit Berlin; date.today() und db.now_iso()),
  dem genau gesendeten Rumpf (`raw`), Status und Antwort (bei 500 keine, Starlette antwortet mit Text)
- tables_after: Tabelle flashcards nach allen Anfragen

Leitner wie im Server: richtig -> naechstes Fach bis 5 (Abstaende 1, 2, 4, 8, 16 Tage), falsch -> Fach 1. Die Uhr
geht ueber mehrere Tage und einen Jahreswechsel. Keine KI, nur selbst angelegte Karten.
Der Server laeuft nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Aufruf im Projektordner: python tools/gen-flashcards-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, berlin_time, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "flashcards.json"

COURSES = [  # id, Titel, Fach
    ("k-la", "Lineare Algebra Test", "Lineare Algebra Test"),
    ("k-an", "Analysis Beispiel", "Analysis Beispiel"),
    ("k-frei", "Freies Seminar Beispiel", None),
]
FILES = [  # id, Kurs, Name
    ("f-la1", "k-la", "LA_Vorlesung_01.pdf"),
    ("f-an1", "k-an", "Analysis_Blatt_01.pdf"),
    ("f-frei", "k-frei", "Seminar_Einfuehrung.pdf"),
    ("5", "k-la", "LA_Zusatz.pdf"),                       # Kennung aus Ziffern: file_id 5 (Zahl) trifft sie
]


def base_seed() -> list[tuple[str, list]]:
    seed: list[tuple[str, list]] = []
    for cid, title, subject in COURSES:
        seed.append(("INSERT INTO courses(id, title, semester, subject, kind, active, created_at) VALUES (?,?,?,?,?,?,?)",
                     [cid, title, "WiSe 2026/27", subject, "vorlesung", 1, "2026-10-01T09:00:00"]))
    for fid, course, name in FILES:
        seed.append(("INSERT INTO files(id, course_id, name, status, kind, first_seen) VALUES (?,?,?,?,?,?)",
                     [fid, course, name, "neu", "pdf", "2026-10-20T08:00:00"]))
    return seed


def card(q, a):
    return {"question": q, "answer": a}


# Hauptablauf: anlegen (mit und ohne Datei, ungueltige Karten), auflisten, wiederholen bis Fach 5, falsch -> 1,
# faellig nach Tagen, loeschen. Montag, 26.10.2026; spaeter Dienstag, Ende November und Jahreswechsel.
D0, D1, D2, D3 = "2026-10-26T09:00:00", "2026-10-27T18:45:10", "2026-11-30T07:05:00", "2026-12-30T23:59:59"
MAIN_STEPS = [
    (D0, "GET", "/api/flashcards", None),
    (D0, "GET", "/api/flashcards?due=true", None),
    (D0, "POST", "/api/flashcards", {"cards": [card("Was ist eine Basis?", "Ein linear unabhängiges Erzeugendensystem")], "file_id": "f-la1"}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Ableitung von x²?", "2x"), card("", "leer"), {"question": "ohne Antwort"},
                                               {"answer": "ohne Frage"}, card("Grenzwert von 1/n?", "0")], "file_id": "f-an1"}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Freie Frage 😀", "Freie Antwort mit \"Zitat\"\nund Zeilenumbruch")]}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Zahl als Antwort", 42), card(1.5, True)], "file_id": "gibtsnicht"}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Kurs ohne Fach", "ja")], "file_id": "f-frei"}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Datei als Zahl", "trifft Datei 5")], "file_id": 5}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Datei als Kommazahl", "trifft keine Datei")], "file_id": 5.0}),
    (D0, "POST", "/api/flashcards", {"cards": [card("Leere Datei-ID", "kein Fach")], "file_id": ""}),
    (D0, "POST", "/api/flashcards", {"cards": [card("   ", "nur Leerzeichen zaehlen in Python als Text")]}),
    (D0, "POST", "/api/flashcards", {"cards": [], "file_id": "f-la1"}),
    (D0, "POST", "/api/flashcards", {}),
    (D0, "POST", "/api/flashcards", {"cards": None}),
    (D0, "POST", "/api/flashcards", {"cards": 0}),
    (D0, "POST", "/api/flashcards", {"cards": ""}),
    (D0, "POST", "/api/flashcards", {"cards": {}}),
    (D0, "POST", "/api/flashcards", {"cards": [card([], "leere Liste als Frage wird uebersprungen")]}),
    (D0, "POST", "/api/flashcards", {"cards": [card("q", "a")], "file_id": []}),                      # 500, nichts gespeichert
    (D0, "POST", "/api/flashcards", {"cards": [], "file_id": []}),                                    # keine Karte: 200
    (D0, "POST", "/api/flashcards", {"cards": "Frage"}),                                              # 500
    (D0, "POST", "/api/flashcards", {"cards": card("q", "a")}),                                       # 500
    (D0, "POST", "/api/flashcards", {"cards": 5}),                                                    # 500
    (D0, "POST", "/api/flashcards", {"cards": [card("vorher", "nicht gespeichert"), "kein Objekt"]}),  # 500, Rollback
    (D0, "POST", "/api/flashcards", {"cards": [card(["Liste"], "a")]}),                               # 500
    (D0, "POST", "/api/flashcards", {"cards": [card("q", "a")], "file_id": {"x": 1}}),                # 500
    (D0, "POST", "/api/flashcards", {"cards": [card("q", 10 ** 20)]}),                                # 500 (OverflowError)
    (D0, "POST", "/api/flashcards", [1]),                                                             # 422
    (D0, "POST", "/api/flashcards", None),                                                            # 422
    (D0, "GET", "/api/flashcards", None),
    (D0, "GET", "/api/flashcards?file_id=f-la1", None),
    (D0, "GET", "/api/flashcards?file_id=", None),
    (D0, "GET", "/api/flashcards?file_id=gibtsnicht", None),
    (D0, "GET", "/api/flashcards?file_id=5", None),
    (D0, "GET", "/api/flashcards?file_id=f-la1&file_id=f-an1", None),
    (D0, "GET", "/api/flashcards?due=true", None),
    (D0, "GET", "/api/flashcards?due=false", None),
    (D0, "GET", "/api/flashcards?due=1&file_id=f-an1", None),
    (D0, "GET", "/api/flashcards?due=vielleicht", None),                                              # 422
    # wiederholen am selben Tag
    (D0, "POST", "/api/flashcards/1/review", {"correct": True}),                                      # Fach 2, +2
    (D0, "POST", "/api/flashcards/1/review", {"correct": True}),                                      # Fach 3, +4
    (D0, "POST", "/api/flashcards/2/review", {"correct": False}),                                     # Fach 1, +1
    (D0, "POST", "/api/flashcards/3/review", {"correct": "false"}),                                   # Text ist wahr: Fach 2
    (D0, "POST", "/api/flashcards/4/review", {"correct": 0}),
    (D0, "POST", "/api/flashcards/5/review", {"correct": "0"}),
    (D0, "POST", "/api/flashcards/6/review", {"correct": []}),
    (D0, "POST", "/api/flashcards/7/review", {}),
    (D0, "POST", "/api/flashcards/8/review", {"correct": 1.0}),
    (D0, "POST", "/api/flashcards/9999/review", {"correct": True}),                                   # 404
    (D0, "POST", "/api/flashcards/1/review", [True]),                                                 # 422
    (D0, "POST", "/api/flashcards/1/review", None),                                                   # 422
    (D0, "POST", "/api/flashcards/eins/review", {"correct": True}),                                   # 422
    (D0, "GET", "/api/flashcards?due=true", None),
    # naechster Tag: faellig ist, was heute oder frueher dran ist
    (D1, "GET", "/api/flashcards?due=true", None),
    (D1, "POST", "/api/flashcards/1/review", {"correct": True}),                                      # Fach 4, +8
    (D1, "POST", "/api/flashcards/1/review", {"correct": True}),                                      # Fach 5, +16
    (D1, "POST", "/api/flashcards/1/review", {"correct": True}),                                      # bleibt 5
    (D1, "POST", "/api/flashcards", {"cards": [card("Neu am Dienstag", "faellig ab heute")]}),
    (D1, "GET", "/api/flashcards?due=true", None),
    (D2, "GET", "/api/flashcards?due=true", None),
    (D2, "POST", "/api/flashcards/1/review", {"correct": False}),                                     # zurueck auf 1
    (D2, "POST", "/api/flashcards/2/review", {"correct": True}),
    (D3, "POST", "/api/flashcards/3/review", {"correct": True}),
    (D3, "POST", "/api/flashcards/3/review", {"correct": True}),
    (D3, "POST", "/api/flashcards/3/review", {"correct": True}),
    (D3, "POST", "/api/flashcards/3/review", {"correct": True}),                                      # Fach 5 ueber Neujahr
    (D3, "GET", "/api/flashcards?due=true", None),
    # loeschen
    (D3, "DELETE", "/api/flashcards/2", None),
    (D3, "DELETE", "/api/flashcards/2", None),                                                        # 404
    (D3, "DELETE", "/api/flashcards/9999", None),                                                     # 404
    (D3, "DELETE", "/api/flashcards/zwei", None),                                                     # 422
    (D3, "POST", "/api/flashcards/2/review", {"correct": True}),                                      # 404
    (D3, "GET", "/api/flashcards", None),
]

# Karten, die nur Daten von aussen haben koennen (Fach ausserhalb 1..5, Text, Kommazahl, faellig ohne Datum)
EDGE_CARDS = [  # id, file_id, Fach als SQL, faellig als SQL
    (1, "f-la1", "NULL", "NULL"),
    (2, "f-la1", "0", "'2026-10-26'"),
    (3, "f-an1", "5", "'2026-10-25'"),
    (4, "f-an1", "9", "'2026-10-27'"),
    (5, None, "-1", "''"),
    (6, None, "-4", "'morgen'"),
    (7, None, "-5", "'2026-10-26'"),
    (8, None, "-6", "'2026-10-26'"),
    (9, None, "'abc'", "'2026-10-26'"),
    (10, None, "2.5", "'2026-10-26'"),
    (11, None, "7.5", "'2026-10-26'"),
    (12, None, "''", "'2026-10-26'"),
    (13, "f-weg", "9223372036854775807", "'2026-10-26'"),
]
E0 = "2026-10-26T12:00:00"
EDGE_STEPS = [(E0, "GET", "/api/flashcards", None), (E0, "GET", "/api/flashcards?due=true", None)] + [
    (E0, "POST", f"/api/flashcards/{cid}/review", {"correct": True}) for cid, *_ in EDGE_CARDS
] + [
    (E0, "POST", "/api/flashcards/9/review", {"correct": False}),                                     # falsch: Fach egal
    (E0, "GET", "/api/flashcards?file_id=f-weg", None),
    (E0, "GET", "/api/flashcards", None),
]


def edge_seed() -> list[tuple[str, list]]:
    seed = base_seed()
    for cid, fid, box, due in EDGE_CARDS:
        seed.append((f"INSERT INTO flashcards(id, file_id, subject, question, answer, created_at, box, due) "
                     f"VALUES ({cid}, ?, ?, ?, ?, ?, {box}, {due})",
                     [fid, None, f"Grenzfall {cid}", f"Fach {box}", "2026-10-20T08:00:00"]))
    return seed


def run(src: SchemaSource, gen, server, name: str, seed: list, steps: list) -> dict:
    src.fresh_db(name)
    with src.db.cursor() as conn:
        for sql, params in seed:
            conn.execute(sql, params)
    clock = {"now": steps[0][0]}
    src.freeze(lambda: date.fromisoformat(clock["now"][:10]), lambda: clock["now"],
               lambda: datetime.fromisoformat(clock["now"]))
    out = []
    for now, method, path, body in steps:
        clock["now"] = now
        raw = json.dumps(body) if body is not None else None
        status, value = gen.asgi(server.app, method, path, raw_body=raw)
        step = {"now": now, "method": method, "path": path, "raw": raw, "status": status}
        if status != 500:
            step["response"] = value
        out.append(step)
    with src.db.cursor() as conn:
        table = src.db.rows(conn, "SELECT * FROM flashcards ORDER BY id")
    return {"name": name, "seed": [{"sql": q, "params": p} for q, p in seed], "steps": out, "tables_after": {"flashcards": table}}


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import server
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        with berlin_time():
            scenarios = [run(src, gen, server, "haupt", base_seed(), MAIN_STEPS),
                         run(src, gen, server, "grenzen", edge_seed(), EDGE_STEPS)]
    finally:
        src.cleanup()
    out = without_sync({"generator": "tools/gen-flashcards-fixture.py", "intervals": [1, 2, 4, 8, 16], "scenarios": scenarios})
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
