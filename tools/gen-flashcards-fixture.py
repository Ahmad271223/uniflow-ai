"""Erzeugt packages/shared-contracts/fixtures/local-backend/flashcards.json (M8): eigene Karteikarten aus app/server.py
(`GET /api/flashcards` mit file_id, due und stack_id, `POST /api/flashcards`, `POST /api/flashcards/{id}/review`,
`PATCH /api/flashcards/{id}`, `DELETE /api/flashcards/{id}`) und die Stapel (`/api/flashcard-stacks`, Szenario
"stapel": anlegen, umbenennen, verschieben, geschlossenes Ueben je Stapel, Karte bearbeiten ohne Fachwechsel,
Loeschen mit und ohne Umzug der Karten, Bestand ohne Stapel bekommt Stapel wie die Migration) auf erfundenen Daten. Der Swift-Kern (LocalFlashcardTests) legt dieselben Daten an,
schickt dieselben Anfragen mit derselben Uhr an das lokale Backend und vergleicht Status, Antwort und Tabelle.

Inhalt je Szenario:
- seed: SQL-Anweisungen nach init_db (Kurse mit und ohne Fach, Dateien; im Szenario "grenzen" Karten mit Faechern
  und Faelligkeiten, die nur Daten von aussen haben koennen)
- steps: Anfragen mit eingefrorener, weitergestellter Uhr (`now`, Ortszeit Berlin; date.today() und db.now_iso()),
  dem genau gesendeten Rumpf (`raw`), Status und Antwort (bei 500 keine, Starlette antwortet mit Text)
- tables_after: Tabellen flashcards und flashcard_stacks nach allen Anfragen

Versteckte Karten (Trainer, hidden != 0) sind nie faellig: `?due=true` laesst sie weg, die Liste ohne due zeigt sie.

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

# Karteikarten-Trainer (PATCH): Lesezeichen, versteckt, letztes Urteil; Fach und Termin bleiben, die Wiederholung
# setzt das Urteil mit
T0 = "2026-11-03T10:00:00"
TRAINER_STEPS = [
    (T0, "POST", "/api/flashcards", {"cards": [card("Begriff A", "Definition A"), card("Begriff B", "Definition B")], "file_id": "f-la1"}),
    (T0, "GET", "/api/flashcards", None),
    (T0, "PATCH", "/api/flashcards/1", {"bookmarked": True}),
    (T0, "PATCH", "/api/flashcards/1", {"hidden": 1, "last_result": "right"}),
    (T0, "PATCH", "/api/flashcards/2", {"last_result": "wrong", "bookmarked": "ja"}),
    (T0, "PATCH", "/api/flashcards/2", {"bookmarked": 0, "hidden": []}),
    (T0, "PATCH", "/api/flashcards/1", {"hidden": False, "last_result": None}),
    (T0, "PATCH", "/api/flashcards/1", {}),                                                           # nichts geaendert
    (T0, "PATCH", "/api/flashcards/1", {"unbekannt": 1}),
    (T0, "PATCH", "/api/flashcards/1", {"last_result": "vielleicht"}),                                # 422
    (T0, "PATCH", "/api/flashcards/1", {"last_result": True}),                                        # 422
    (T0, "PATCH", "/api/flashcards/1", {"last_result": 1, "hidden": True}),                           # 422, nichts geaendert
    (T0, "PATCH", "/api/flashcards/9999", {"hidden": True}),                                          # 404
    (T0, "PATCH", "/api/flashcards/9999", {}),                                                        # 404
    (T0, "PATCH", "/api/flashcards/eins", {"hidden": True}),                                          # 422
    (T0, "PATCH", "/api/flashcards/1", [1]),                                                          # 422
    (T0, "POST", "/api/flashcards/1/review", {"correct": False}),                                     # Urteil wrong, Fach 1
    (T0, "POST", "/api/flashcards/2/review", {"correct": True}),                                      # Urteil right, Fach 2
    (T0, "GET", "/api/flashcards", None),
    (T0, "GET", "/api/flashcards?due=true", None),
    # versteckt = nie faellig: raus aus "Heute faellig", in der Liste bleibt die Karte; wieder zeigen holt sie zurueck
    (T0, "PATCH", "/api/flashcards/1", {"hidden": True}),
    (T0, "GET", "/api/flashcards?due=true", None),
    (T0, "GET", "/api/flashcards", None),
    (T0, "GET", "/api/flashcards?due=true&file_id=f-la1", None),
    ("2026-11-05T08:00:00", "GET", "/api/flashcards?due=true", None),                                 # Karte 2 faellig
    ("2026-11-05T08:00:00", "PATCH", "/api/flashcards/1", {"hidden": False}),
    ("2026-11-05T08:00:00", "GET", "/api/flashcards?due=true", None),
]

# Versteckt mit Werten von aussen (Abgleich, alte Daten): NULL zaehlt als nicht versteckt, alles ausser 0 als versteckt
HIDDEN_CARDS = [  # id, versteckt als SQL
    (1, "NULL"), (2, "0"), (3, "1"), (4, "2"), (5, "''"), (6, "'ja'"), (7, "0.0"), (8, "-1"),
]
H0 = "2026-11-03T12:00:00"
HIDDEN_STEPS = [(H0, "GET", "/api/flashcards?due=true", None), (H0, "GET", "/api/flashcards", None)]


# Geschlossene Stapel (04.11.2026): Bestand ohne Stapel (Karten mit Datei, mit Fach ohne Datei, ohne beides) bekommt beim
# ersten Lesen Stapel wie die Migration; danach Stapel-Endpunkte, Ueben je Stapel, Bearbeiten, Loeschen mit Umzug.
STACK_SEED_CARDS = [  # id, file_id, subject, question
    (1, "f-la1", "Lineare Algebra Test", "Alt mit Datei"),
    (2, "f-la1", "Lineare Algebra Test", "Alt mit Datei 2"),
    (3, None, "Analysis Beispiel", "Alt nur Fach"),
    (4, None, None, "Alt ohne alles"),
    (5, "", "", "Alt mit leeren Werten"),
    (6, "f-weg", None, "Alt mit fehlender Datei"),
]
S0, S1 = "2026-11-04T10:00:00", "2026-11-06T09:30:00"
STACK_STEPS = [
    (S0, "GET", "/api/flashcard-stacks", None),                                                      # Migration beim Lesen
    (S0, "GET", "/api/flashcards", None),
    (S0, "GET", "/api/flashcards?stack_id=1", None),
    (S0, "GET", "/api/flashcards?stack_id=abc", None),                                               # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "  Klausur 1  ", "subject": "Analysis Beispiel"}),
    (S0, "POST", "/api/flashcard-stacks", {"name": "Aus Skript", "file_id": "f-an1"}),               # Fach des Dokuments
    (S0, "POST", "/api/flashcard-stacks", {"name": "Eigenes Fach", "file_id": "f-an1", "subject": "Physik Test"}),
    (S0, "POST", "/api/flashcard-stacks", {"name": "Leer", "subject": ""}),                          # leeres Fach = null
    (S0, "POST", "/api/flashcard-stacks", {"name": ""}),                                             # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": 5}),                                              # 422
    (S0, "POST", "/api/flashcard-stacks", {}),                                                       # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "subject": 3}),                              # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "file_id": "gibtsnicht"}),                   # 404
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "file_id": 5}),                              # 422
    (S0, "POST", "/api/flashcard-stacks", [1]),                                                      # 422
    (S0, "POST", "/api/flashcards", {"cards": [card("In Klausur 1", "ja"), card("Auch", "ja")], "stack_id": 5}),
    (S0, "POST", "/api/flashcards", {"cards": [card("Im Dokumentstapel", "ja")], "file_id": "f-an1", "stack_id": 6}),
    (S0, "POST", "/api/flashcards", {"cards": [card("Neuer Name", "ja")], "file_id": "f-an1", "stack_name": " Blatt 1 "}),   # neuer Stapel
    (S0, "POST", "/api/flashcards", {"cards": [card("Gleicher Name", "ja")], "file_id": "f-an1", "stack_name": "Blatt 1"}),  # derselbe
    (S0, "POST", "/api/flashcards", {"cards": [card("Name ohne Fach", "ja")], "stack_name": "Blatt 1"}),                     # anderes Fach: neu
    (S0, "POST", "/api/flashcards", {"cards": [card("Automatisch", "ja")], "file_id": "f-la1"}),                              # Stapel der Datei
    (S0, "POST", "/api/flashcards", {"cards": [card("Automatisch frei", "ja")]}),                                            # Ohne Modul
    (S0, "POST", "/api/flashcards", {"cards": [card("Neue Datei", "ja")], "file_id": "5"}),                                  # neuer Dateistapel
    (S0, "POST", "/api/flashcards", {"cards": [card("x", "y")], "stack_id": 9999}),                                           # 404
    (S0, "POST", "/api/flashcards", {"cards": [card("x", "y")], "stack_id": "5"}),                                            # Text trifft 5
    (S0, "POST", "/api/flashcards", {"cards": [], "stack_id": 9999}),                                                         # keine Karte: 200
    (S0, "POST", "/api/flashcards", {"cards": [card("", "y")], "stack_id": 9999}),                                            # uebersprungen: 200
    # Lehrwoche und Art (Ergaenzung 04.11.2026): eigene Angabe, Vorgabe aus dem Dokument (Blatt_01 -> uebung, Woche 1), Fehler
    (S0, "POST", "/api/flashcard-stacks", {"name": "Woche 3", "subject": "Analysis Beispiel", "week": 3, "kind": "uebung"}),
    (S0, "POST", "/api/flashcard-stacks", {"name": "Folien", "file_id": "f-la1", "kind": "vorlesung", "week": None}),
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "week": 0}),                                 # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "week": "3"}),                               # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "week": True}),                              # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "week": 2.0}),                               # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "kind": "klausur"}),                         # 422
    (S0, "POST", "/api/flashcard-stacks", {"name": "x", "kind": None}),                              # 422
    (S0, "PATCH", "/api/flashcard-stacks/5", {"week": 2, "kind": "vorlesung"}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {"week": None}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {"kind": ""}),                                          # 422
    (S0, "PATCH", "/api/flashcard-stacks/5", {"week": -1}),                                          # 422
    (S0, "GET", "/api/flashcard-stacks", None),
    (S0, "GET", "/api/flashcards?stack_id=5", None),
    (S0, "GET", "/api/flashcards?stack_id=5&due=1", None),
    (S0, "GET", "/api/flashcards?due=true&stack_id=1", None),
    (S0, "GET", "/api/flashcards?stack_id=0", None),
    (S0, "GET", "/api/flashcards?stack_id=", None),                                                  # 422
    # geschlossenes Ueben: nur Karten des Stapels 5, Wiederholung setzt last_practised des Stapels
    (S0, "POST", "/api/flashcards/7/review", {"correct": True}),
    (S0, "PATCH", "/api/flashcards/8", {"last_result": "wrong"}),
    (S0, "GET", "/api/flashcard-stacks", None),
    (S0, "GET", "/api/flashcards?stack_id=5&due=1", None),
    # bearbeiten: Frage, Antwort, Fach, Stapel; Fach und Termin bleiben
    (S0, "PATCH", "/api/flashcards/7", {"question": "  In Klausur 1 (neu)  ", "answer": "nein"}),
    (S0, "PATCH", "/api/flashcards/7", {"subject": "Physik Test"}),
    (S0, "PATCH", "/api/flashcards/7", {"subject": None}),
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": 6}),                                             # Fach des Stapels
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": 5, "subject": "Eigen"}),                         # eigenes Fach bleibt
    (S0, "PATCH", "/api/flashcards/8", {"question": ""}),                                            # 422
    (S0, "PATCH", "/api/flashcards/8", {"answer": "   "}),                                           # 422
    (S0, "PATCH", "/api/flashcards/8", {"question": 7}),                                             # 422
    (S0, "PATCH", "/api/flashcards/8", {"subject": 7}),                                              # 422
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": "6"}),                                           # 422
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": True}),                                          # 422
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": None}),                                          # 422
    (S0, "PATCH", "/api/flashcards/8", {"stack_id": 9999}),                                          # 404
    (S0, "PATCH", "/api/flashcards/9999", {"question": "x"}),                                        # 404
    (S0, "PATCH", "/api/flashcards/8", {"question": "Nur Frage", "bookmarked": True, "last_result": "right"}),
    (S0, "GET", "/api/flashcards?stack_id=5", None),
    # Stapel aendern
    (S0, "PATCH", "/api/flashcard-stacks/5", {"name": " Klausur 1 neu "}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {"subject": "Physik Test"}),                            # Karten folgen
    (S0, "PATCH", "/api/flashcard-stacks/5", {"file_id": "f-la1"}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {"file_id": None}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {}),
    (S0, "PATCH", "/api/flashcard-stacks/5", {"name": ""}),                                          # 422
    (S0, "PATCH", "/api/flashcard-stacks/5", {"subject": 1}),                                        # 422
    (S0, "PATCH", "/api/flashcard-stacks/5", {"file_id": "gibtsnicht"}),                             # 404
    (S0, "PATCH", "/api/flashcard-stacks/9999", {"name": "x"}),                                      # 404
    (S0, "PATCH", "/api/flashcard-stacks/fuenf", {"name": "x"}),                                     # 422
    (S0, "PATCH", "/api/flashcard-stacks/5", [1]),                                                   # 422
    (S0, "GET", "/api/flashcards?stack_id=5", None),
    # loeschen: mit Umzug (Karten bekommen das Fach des Ziels), ohne Umzug (Karten weg), Fehler
    (S1, "DELETE", "/api/flashcard-stacks/5?move_to=5", None),                                       # 422
    (S1, "DELETE", "/api/flashcard-stacks/5?move_to=9999", None),                                    # 404
    (S1, "DELETE", "/api/flashcard-stacks/9999", None),                                              # 404
    (S1, "DELETE", "/api/flashcard-stacks/5?move_to=abc", None),                                     # 422
    (S1, "DELETE", "/api/flashcard-stacks/5?move_to=6", None),
    (S1, "GET", "/api/flashcards?stack_id=6", None),
    (S1, "DELETE", "/api/flashcard-stacks/6", None),
    (S1, "DELETE", "/api/flashcard-stacks/6", None),                                                 # 404
    (S1, "DELETE", "/api/flashcard-stacks/8", None),                                                 # leerer Stapel
    (S1, "GET", "/api/flashcard-stacks", None),
    (S1, "GET", "/api/flashcards", None),
    # Karte einer geloeschten Datei-Zuordnung: Stapel ohne Karten entstehen nicht neu
    (S1, "DELETE", "/api/flashcards/1", None),
    (S1, "GET", "/api/flashcard-stacks", None),
]


def stack_seed() -> list[tuple[str, list]]:
    seed = base_seed()
    for cid, fid, subject, question in STACK_SEED_CARDS:
        seed.append(("INSERT INTO flashcards(id, file_id, subject, question, answer, created_at, box, due) VALUES (?, ?, ?, ?, ?, ?, 2, '2026-11-01')",
                     [cid, fid, subject, question, "Antwort", f"2026-10-2{cid}T08:00:00"]))
    return seed


def edge_seed() -> list[tuple[str, list]]:
    seed = base_seed()
    for cid, fid, box, due in EDGE_CARDS:
        seed.append((f"INSERT INTO flashcards(id, file_id, subject, question, answer, created_at, box, due) "
                     f"VALUES ({cid}, ?, ?, ?, ?, ?, {box}, {due})",
                     [fid, None, f"Grenzfall {cid}", f"Fach {box}", "2026-10-20T08:00:00"]))
    return seed


def hidden_seed() -> list[tuple[str, list]]:
    seed = base_seed()
    for cid, hidden in HIDDEN_CARDS:
        seed.append((f"INSERT INTO flashcards(id, file_id, subject, question, answer, created_at, box, due, hidden) "
                     f"VALUES ({cid}, NULL, NULL, ?, ?, ?, 1, '2026-11-01', {hidden})",
                     [f"Versteckt {cid}", f"hidden {hidden}", "2026-10-20T08:00:00"]))
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
        stacks = src.db.rows(conn, "SELECT * FROM flashcard_stacks ORDER BY id")
    return {"name": name, "seed": [{"sql": q, "params": p} for q, p in seed], "steps": out,
            "tables_after": {"flashcards": table, "flashcard_stacks": stacks}}


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
                         run(src, gen, server, "grenzen", edge_seed(), EDGE_STEPS),
                         run(src, gen, server, "trainer", base_seed(), TRAINER_STEPS),
                         run(src, gen, server, "versteckt", hidden_seed(), HIDDEN_STEPS),
                         run(src, gen, server, "stapel", stack_seed(), STACK_STEPS)]
    finally:
        src.cleanup()
    out = without_sync({"generator": "tools/gen-flashcards-fixture.py", "intervals": [1, 2, 4, 8, 16], "scenarios": scenarios})
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
