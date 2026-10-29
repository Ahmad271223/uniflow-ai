"""Erzeugt packages/shared-contracts/fixtures/local-backend/grades.json: der Notenspiegel aus app/grades_model.py und
GET /api/grades aus app/server.py (qis.summary) auf erfundenen Notenspiegeln. Der Swift-Kern (GradesModelTests) legt
dieselben Zeilen in die Tabelle grades, fragt GET /api/grades und vergleicht die Antwort exakt.

Inhalt:
- cases: je Fall die gespeicherten Zeilen (Tabelle grades nach qis.store_grades, mit eingefrorener Uhr) und die Antwort
  von GET /api/grades. Faelle: LUH-Aufbau (Bereich, Modul, Pruefung, Doppel mit langem Semesternamen, nicht bestandener
  Versuch, verschobene Bereichszeile), LP mit Komma, Schnitt mit Abschneiden (3,47 -> 3,4), Hildesheim ohne Modulzeilen,
  Leistungen ohne LP (einfacher Mittelwert), leerer Notenspiegel
- norm_semester, truncate1, fields_from_raw: Einzelfaelle der Hilfsfunktionen

Alle Namen, Nummern und Noten sind erfunden. Der Server laeuft nur gegen Dateien in einem Temp-Ordner
(tools/schema_source.py), nie gegen data/.
Aufruf im Projektordner: python tools/gen-grades-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import date
from pathlib import Path

from schema_source import ROOT, SchemaSource, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "grades.json"
NOW = "2026-10-29T09:00:00"


def raw(*cells: str) -> str:
    return " | ".join(cells)


# Aufbau wie im LUH-QIS (wie tests/test_grades_model.py, dazu LP mit Komma, anerkannt, endgueltig nicht bestanden)
LUH = [
    {"text": "Kompetenzbereich Grundlagen", "semester": "3,3", "note": "bestanden", "status": "13",
     "raw": raw("10", "Kompetenzbereich Grundlagen", "", "3,3", "bestanden", "13", "", "", "", "")},
    {"pruefungsnr": "110", "text": "Testmathe I", "semester": "WiSe 23/24", "note": "3,3", "status": "bestanden", "versuch": "",
     "raw": raw("110", "Testmathe I", "", "WiSe 23/24", "3,3", "bestanden", "8", "22.01.2024", "", "", "")},
    {"pruefungsnr": "111", "text": "Testmathe I", "semester": "WiSe 23/24", "note": "3,3", "status": "bestanden", "versuch": "1",
     "raw": raw("111", "Testmathe I", "PL", "WiSe 23/24", "3,3", "bestanden", "8", "22.01.2024", "1", "", "")},
    # zweite Leistung desselben Moduls im selben Semester: gleiche Sortierschluessel, Reihenfolge nach id (stabil)
    {"pruefungsnr": "112", "text": "Testmathe I", "semester": "WiSe 23/24", "note": "", "status": "bestanden", "versuch": "1",
     "raw": raw("112", "Testmathe I", "SL", "WiSe 23/24", "", "bestanden", "0", "15.01.2024", "1", "", "")},
    {"pruefungsnr": "111", "text": "Testmathe I", "semester": "Wintersemester 23/24", "note": "3,3", "status": "bestanden", "versuch": "1",
     "raw": raw("111", "Testmathe I", "PL", "Wintersemester 23/24", "3,3", "bestanden", "8", "22.01.2024", "1", "", "")},
    {"pruefungsnr": "121", "text": "Testphysik", "semester": "SoSe 24", "note": "5,0", "status": "nicht bestanden", "versuch": "1",
     "raw": raw("121", "Testphysik", "PL", "SoSe 24", "5,0", "nicht bestanden", "0", "20.07.2024", "1", "OWR", "")},
    {"pruefungsnr": "120", "text": "Testphysik", "semester": "WiSe 24/25", "note": "", "status": "", "versuch": "",
     "raw": raw("120", "Testphysik", "", "WiSe 24/25", "2,0", "bestanden", "5", "10.02.2025", "", "", "")},
    {"pruefungsnr": "121", "text": "Testphysik", "semester": "WiSe 24/25", "note": "2,0", "status": "bestanden", "versuch": "1",
     "raw": raw("121", "Testphysik", "PL", "WiSe 24/25", "2,0", "bestanden", "5", "10.02.2025", "1", "", "")},
    {"pruefungsnr": "521", "text": "Testlabor", "semester": "SoSe 24", "note": "", "status": "bestanden", "versuch": "1",
     "raw": raw("521", "Testlabor", "LA", "SoSe 24", "", "bestanden", "2", "23.07.2024", "1", "", "")},
    {"pruefungsnr": "599", "text": "Pflichtmodule", "semester": "SoSe 25", "note": "", "status": "bestanden",
     "raw": raw("599", "Pflichtmodule", "", "SoSe 25", "", "bestanden", "6", "13.06.2025", "", "", "")},
    {"pruefungsnr": "510", "text": "Einstiegsmodul", "semester": "SoSe 25", "note": "", "status": "bestanden",
     "raw": raw("510", "Einstiegsmodul", "", "SoSe 25", "", "bestanden", "6", "13.06.2025", "", "", "")},
    {"pruefungsnr": "130", "text": "Testinformatik", "semester": "Sommersemester 25", "note": "1,7", "status": "bestanden", "versuch": "",
     "raw": raw("130", "Testinformatik", "", "Sommersemester 25", "1,7", "bestanden", "7,5", "01.08.2025", "", "", "")},
    {"pruefungsnr": "140", "text": "Testsprachkurs", "semester": "WiSe 25/26", "note": "", "status": "anerkannt", "versuch": "",
     "raw": raw("140", "Testsprachkurs", "", "WiSe 25/26", "", "anerkannt", "4", "", "", "", "")},
    {"pruefungsnr": "151", "text": "Testchemie", "semester": "WS 2025/2026", "note": "5,0", "status": "endgültig nicht bestanden", "versuch": "3",
     "raw": raw("151", "Testchemie", "KL", "WS 2025/2026", "5,0", "endgültig nicht bestanden", "0", "12.02.2026", "3", "", "")},
]

# Schnitt mit Abschneiden: (3,7*6 + 3,3*5 + 3,3*4) / 15 = 3,4666.. -> 3,4 und genau 3,47
ABSCHNEIDEN = [
    {"pruefungsnr": "200", "text": "Testmodul A", "semester": "WiSe 24/25", "note": "3,7", "status": "bestanden",
     "raw": raw("200", "Testmodul A", "", "WiSe 24/25", "3,7", "bestanden", "6", "01.02.2025", "", "", "")},
    {"pruefungsnr": "210", "text": "Testmodul B", "semester": "SoSe 25", "note": "3,3", "status": "bestanden",
     "raw": raw("210", "Testmodul B", "", "SoSe 25", "3,3", "bestanden", "5", "01.08.2025", "", "", "")},
    {"pruefungsnr": "220", "text": "Testmodul C", "semester": "SoSe 25", "note": "3,3", "status": "bestanden",
     "raw": raw("220", "Testmodul C", "", "SoSe 25", "3,3", "bestanden", "4", "02.08.2025", "", "", "")},
]

# LSF Hildesheim: keine Modulzeilen, weder Semester noch Versuch
HILDESHEIM = [
    {"pruefungsnr": "5011", "text": "TM 1: Grundlagen", "note": "1,7", "status": "bestanden", "credits": "6", "raw": "5011 | TM 1 | 1,7 | bestanden | 6"},
    {"pruefungsnr": "4220", "text": "Grundlagen I", "note": "2,3", "status": "bestanden", "credits": "6", "raw": "4220 | Grundlagen I | 2,3 | bestanden | 6"},
    {"pruefungsnr": "5032", "text": "TM 2", "note": "", "status": "angemeldet (SoSe 26)", "credits": "0", "raw": "5032 | TM 2 |  | angemeldet (SoSe 26) | 0"},
    {"pruefungsnr": "10010", "text": "Pflichtmodule (mindestens 12 LP)", "note": "", "status": "Prüfung vorhanden", "credits": "6", "raw": "10010 | Pflichtmodule"},
]

# Leistungen ohne LP: einfacher Mittelwert der bestandenen benoteten
OHNE_LP = [
    {"pruefungsnr": "301", "text": "Testseminar", "note": "1,3", "status": "bestanden", "raw": "301 | Testseminar | PL | 1,3 | bestanden"},
    {"pruefungsnr": "302", "text": "Testprojekt", "note": "2,0", "status": "bestanden", "raw": "302 | Testprojekt | PL | 2,0 | bestanden"},
    {"pruefungsnr": "303", "text": "Testreferat", "note": "4,3", "status": "bestanden", "raw": "303 | Testreferat | PL | 4,3 | bestanden"},
]

CASES = [("luh", LUH), ("abschneiden", ABSCHNEIDEN), ("hildesheim", HILDESHEIM), ("ohne_lp", OHNE_LP), ("leer", [])]

SEMESTERS = ["WiSe 23/24", "Wintersemester 23/24", "Sommersemester 26", "SoSe 26", "WS 2024/2025", "SS 2025", "ws 24/25",
             "Wintersemester 2025", "Sommersemester2024", "3,3", "", "  WiSe 25/26  ", "Winter 23/24"]
TRUNCATE = [3.47, 3.0, 1.99, 2.8, 2.0000000001, 1.0, 4.0, 3.4666666666666663, 2.95, 0.1 + 0.2]
RAWS = [r["raw"] for _, rows in CASES for r in rows] + [
    "", "Kein | Feld", "12 | Text | sl | SoSe 24 | 1,0 | Bestanden | 3 | 01.01.2024 | 2 | RT",
    "13 | Text | PL | WiSe 24/25 | 2,7 | bestanden | 5,5 | 02.02.2025 | 10",
    "14 | Text | PL | WiSe 24/25 | 2,7 | bestanden | x | 02.02.2025 | 1 | abc",
]


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import grades_model as gm
        from app import qis, server
        src.freeze(lambda: date(2026, 10, 29), lambda: NOW)
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        cases = []
        for name, rows in CASES:
            src.fresh_db(f"noten-{name}")
            with src.db.cursor() as conn:
                conn.execute("DELETE FROM grades")
                qis.store_grades(conn, rows)
                stored = [dict(r) for r in conn.execute("SELECT * FROM grades ORDER BY id")]
            status, value = gen.asgi(server.app, "GET", "/api/grades")
            assert status == 200, value
            cases.append({"name": name, "rows": stored, "response": value})
        helpers = {
            "norm_semester": [{"in": s, "out": gm.norm_semester(s)} for s in SEMESTERS],
            "truncate1": [{"in": x, "out": gm.truncate1(x)} for x in TRUNCATE],
            "fields_from_raw": [{"in": r, "out": gm.fields_from_raw(r)} for r in RAWS],
        }
    finally:
        src.cleanup()
    out = without_sync({"generator": "tools/gen-grades-fixture.py", "now": NOW, "cases": cases, **helpers})
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
