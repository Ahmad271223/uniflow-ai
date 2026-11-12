"""Erzeugt packages/shared-contracts/fixtures/study-plan-engine/: der persoenliche Studienverlauf (app/study_plan.py,
04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md) mit der Python-Referenz. Der Swift-Kern (StudyPlanEngineTests)
rechnet dieselben Faelle und vergleicht exakt.

- engine.json: ein erfundener Katalog ("Technische Informatik", 29 Module, 6 Semester, Turnus WS/SS, Voraussetzungen,
  Wahlpflicht) und QIS-Verlaeufe mit Einstellungen und Tag, je mit dem erwarteten Plan (`build_plan`): im Plan,
  im WS nicht bestanden (naechstes WS), nicht bestanden mit abhaengigen Modulen, dritter Versuch, Beginn im SS,
  Wahlpflicht gewaehlt (mehr als 36 LP: Ausgleich), Namensvarianten (Uebung zu, Tranche, roemische Zahlen,
  Pruefungsnummer, Bereichszeilen, nicht zugeordnete Zeilen). Dazu `name_keys`, `terms` und `pick` (Katalogwahl).
- endpoints.json: Anfragen an GET /api/study-plan, /api/study-plan/module/{id} und GET/POST
  /api/study-plan/settings auf einer erfundenen Datenbank (ohne und mit Katalog in `study_catalogs`, Modultext in
  `study_module_texts`, App-Module, Kurse, Dateien) mit eingefrorener Uhr, je mit Status und Antwort, dazu die
  Einstellung danach.

Aufruf im Projektordner: python tools/gen-study-plan-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, dump_tables, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-plan-engine"
TODAY = date(2026, 11, 4)
NOW = "2026-11-04T10:00:00"


def mod(id, title, area, lp, sem, turnus, pre=(), kind="pflicht", code=None, page=10):
    return {"id": id, "title": title, "code": code, "area": area, "kind": kind, "lp": lp, "semester": sem, "turnus": turnus,
            "exam": "Klausur 90 min" if kind != "abschluss" else "Bachelorarbeit mit Kolloquium",
            "coursework": "Übungsaufgaben" if sem and sem <= 3 else None, "prerequisites": list(pre),
            "language": "deutsch", "workload_h": int(lp * 30), "source_page": page}


CATALOG = {
    "v": 1, "university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022",
    "catalog_term": "WS 2025/26", "code": "TIBSc22", "regular_semesters": 6, "total_lp": 180,
    "source": {"url": "https://modkat.example.invalid/modkat-TIBSc22-WS_2025_26.pdf", "fetched_at": "2026-11-04T09:00:00Z",
               "sha256": "0" * 64},
    "areas": [
        {"id": "informatik", "name": "Grundlagen der Informatik", "lp_required": 50, "kind": "pflicht"},
        {"id": "mathematik", "name": "Mathematik", "lp_required": 29, "kind": "pflicht"},
        {"id": "elektrotechnik", "name": "Elektrotechnik", "lp_required": 28, "kind": "pflicht"},
        {"id": "technische-informatik", "name": "Technische Informatik", "lp_required": 33, "kind": "pflicht"},
        {"id": "wahlpflicht", "name": "Wahlpflicht", "lp_required": 20, "kind": "wahlpflicht"},
        {"id": "schluessel", "name": "Schlüsselkompetenzen", "lp_required": 5, "kind": "wahl"},
        {"id": "abschluss", "name": "Abschluss", "lp_required": 15, "kind": "abschluss"},
    ],
    "modules": [
        mod("programmieren-1", "Programmieren I", "informatik", 5, 1, "WS", page=12),
        mod("mathematik-1", "Mathematik I", "mathematik", 8, 1, "WS", page=14),
        mod("digitale-systeme", "Grundlagen digitaler Systeme", "technische-informatik", 5, 1, "WS", page=16),
        mod("et-1", "Elektrotechnische Grundlagen I", "elektrotechnik", 6, 1, "WS", page=18),
        mod("theoretische-informatik", "Grundlagen der theoretischen Informatik", "informatik", 5, 1, "WS", page=20),
        mod("programmieren-2", "Programmieren II", "informatik", 5, 2, "SS", ["programmieren-1"], code="1234", page=22),
        mod("mathematik-2", "Mathematik II", "mathematik", 8, 2, "SS", ["mathematik-1"], page=24),
        mod("rechnerstrukturen", "Rechnerstrukturen", "technische-informatik", 5, 2, "SS", ["digitale-systeme"], page=26),
        mod("et-2", "Elektrotechnische Grundlagen II", "elektrotechnik", 6, 2, "SS", ["et-1"], page=28),
        mod("datenstrukturen", "Datenstrukturen und Algorithmen", "informatik", 6, 2, "SS", ["programmieren-1"], page=30),
        mod("mathematik-3", "Mathematik III", "mathematik", 8, 3, "WS", ["mathematik-2"], page=32),
        mod("betriebssysteme", "Grundlagen der Betriebssysteme", "informatik", 5, 3, "WS", ["programmieren-2"], page=34),
        mod("signale-systeme", "Signale und Systeme", "elektrotechnik", 6, 3, "WS", ["mathematik-2"], page=36),
        mod("software-engineering", "Software-Engineering", "informatik", 5, 3, "WS+SS", ["programmieren-2"], page=38),
        mod("digitalschaltungen", "Digitalschaltungen der Elektronik", "elektrotechnik", 5, 3, "WS", ["et-2"], page=40),
        mod("rechnernetze", "Grundlagen der Rechnernetze", "informatik", 5, 4, "SS", ["betriebssysteme"], page=42),
        mod("stochastik", "Stochastik für Ingenieure", "mathematik", 5, 4, "SS", ["mathematik-2"], page=44),
        mod("regelungstechnik", "Grundlagen der Regelungstechnik", "elektrotechnik", 5, 4, "SS", ["signale-systeme"], page=46),
        mod("softwareprojekt", "Softwareprojekt", "technische-informatik", 8, 4, "SS", ["software-engineering"], page=48),
        mod("eingebettete-systeme", "Eingebettete Systeme", "wahlpflicht", 5, 4, "SS", kind="wahlpflicht", page=50),
        mod("datenbanken", "Datenbanksysteme I", "wahlpflicht", 5, 5, "WS", kind="wahlpflicht", page=52),
        mod("bildverarbeitung", "Digitale Bildverarbeitung", "wahlpflicht", 5, 5, "WS", kind="wahlpflicht", page=54),
        mod("ki", "Grundlagen der künstlichen Intelligenz", "wahlpflicht", 5, None, "WS+SS", kind="wahlpflicht", page=56),
        mod("robotik", "Robotik I", "wahlpflicht", 5, 5, "WS", ["regelungstechnik"], kind="wahlpflicht", page=58),
        mod("seminar", "Seminar Technische Informatik", "technische-informatik", 3, 5, "WS+SS", page=60),
        mod("labor", "Labor Technische Informatik", "technische-informatik", 7, 5, "WS", ["et-2"], page=62),
        mod("schluesselkompetenzen", "Schlüsselkompetenzen", "schluessel", 5, None, "unbekannt", kind="wahl", page=64),
        mod("fachpraktikum", "Fachpraktikum", "technische-informatik", 10, 6, "WS+SS", page=66),
        mod("bachelorarbeit", "Bachelorarbeit", "abschluss", 15, 6, "WS+SS", ["softwareprojekt"], kind="abschluss", page=68),
    ],
}

# zweiter Katalog (andere PO) fuer die Katalogwahl
CATALOG_INF = {**{k: v for k, v in CATALOG.items() if k != "modules"}, "program": "Informatik", "code": "INFBSc22",
               "modules": [mod("programmieren-1", "Programmieren I", "informatik", 5, 1, "WS")]}
CATALOG_OLD = {**CATALOG, "po": "2017", "code": "TIBSc17", "catalog_term": "SS 2024"}
# mit Studienverlaufsplan: Wahlpflicht ohne Fachsemester, dafuer Plaetze je Semester (`plan_slots`)
CATALOG_SLOTS = {**CATALOG, "code": "TIBSc25", "catalog_term": "WS 2026/27",
                 "modules": [dict(m, semester=None) if m["kind"] == "wahlpflicht" else m for m in CATALOG["modules"]],
                 "study_plan": {"url": "https://plan.example.invalid/verlaufsplan.pdf", "fetched_at": None, "sha256": None},
                 "plan_slots": [{"semester": 4, "title": "Wahlpflichtmodul", "areas": ["wahlpflicht"], "lp": 5, "lp_max": None},
                                {"semester": 5, "title": "Wahlpflichtmodul", "areas": ["wahlpflicht"], "lp": 5, "lp_max": None},
                                {"semester": 5, "title": "Wahlpflichtmodul", "areas": ["wahlpflicht"], "lp": 5, "lp_max": None},
                                {"semester": 6, "title": "Wahlmodul", "areas": [], "lp": 5, "lp_max": None}]}

# Wahlbereiche (05.11.2026): Schwerpunkte als Gruppe (mit "Allgemeine ..." als Wahl ohne Schwerpunkt), Module in
# mehreren Bereichen (`areas[].modules`), Seminarbereich mit Zahl der Module, Studium generale ohne Module (eigener
# Eintrag), Regeltext; ohne Studienverlaufsplan (Plaetze aus den offenen LP)
_ELECTIVE = {"wahlpflicht", "schluessel"}
CATALOG_AREAS = {
    **{k: v for k, v in CATALOG.items() if k not in ("areas", "modules")}, "code": "ETBSc25", "catalog_term": "WS 2026/27",
    "areas": [a for a in CATALOG["areas"] if a["id"] not in _ELECTIVE] + [
        {"id": "seminare", "name": "Seminare", "lp_required": 5, "lp_max": None, "kind": "wahlpflicht", "modules_required": 1},
        {"id": "studium-generale", "name": "Studium Generale", "lp_required": 4, "lp_max": None, "kind": "wahl", "semester": 3,
         "rule": "Lehrveranstaltungen anderer Fakultäten."},
        {"id": "allgemeine-et", "name": "Allgemeine Elektrotechnik", "lp_required": 0, "lp_max": 15, "kind": "pflicht",
         "group": "schwerpunkt", "modules": ["robotik", "datenbanken"]},
        {"id": "schwerpunkt-robotik", "name": "Schwerpunkt Robotik", "lp_required": 0, "lp_max": 15, "kind": "pflicht",
         "rule": "Mindestens zwei Module.", "modules_required": 2, "modules": ["ki"]},
        {"id": "schwerpunkt-daten", "name": "Schwerpunkt Daten", "lp_required": 0, "lp_max": 15, "kind": "pflicht",
         "modules": ["ki"]},
    ],
    "modules": [m for m in CATALOG["modules"] if m["area"] not in _ELECTIVE] + [
        mod("seminar-a", "Seminar Eingebettete Systeme", "seminare", 5, None, "WS", kind="wahlpflicht"),
        mod("seminar-b", "Seminar Datenbanken", "seminare", 5, None, "SS", kind="wahlpflicht"),
        mod("robotik", "Robotik I", "schwerpunkt-robotik", 5, None, "WS", ["regelungstechnik"], kind="wahlpflicht"),
        mod("robotik-2", "Robotik II", "schwerpunkt-robotik", 5, None, "SS", ["robotik"], kind="wahlpflicht"),
        mod("robotik-pflicht", "Grundlagen der Robotik", "schwerpunkt-robotik", 5, 5, "WS"),
        mod("datenbanken", "Datenbanksysteme I", "schwerpunkt-daten", 5, None, "WS", kind="wahlpflicht"),
        mod("ki", "Grundlagen der künstlichen Intelligenz", "allgemeine-et", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("messtechnik", "Messtechnik", "allgemeine-et", 5, None, "SS", kind="wahlpflicht"),
    ],
}

# Wahlbereich ohne LP-Angabe (viele Kataloge ausserhalb der FEI): ein Platz, solange nichts gewaehlt ist
CATALOG_AREAS_NO_LP = {**CATALOG_AREAS, "code": "ETBSc17",
                       "areas": [{k: v for k, v in a.items() if k != "modules_required"} | {"lp_required": None}
                                 if a["id"] == "seminare" else a for a in CATALOG_AREAS["areas"]]}

# Volle Bereiche (05.11.2026, Fund im Web: "Proseminar" in INFBSc22 blieb trotz "0 von 5 LP offen" stehen): Plaetze
# laut Verlaufsplan fuer Akademisches Arbeiten (5 LP, bis 10; ein Wahlpflichtmodul mit Fachsemester 1 deckt den Bedarf
# wie "Einfuehrung in die Informatik"), Vertiefung nur mit LP (10, bis 20), Seminare nur mit Zahl der Module (1),
# Labore mit LP und Zahl (6 LP, 2 Module), Praxis als Spanne (0 - 10 LP); ein Modul ist in Vertiefung und Praxis waehlbar
CATALOG_FULL = {
    **{k: v for k, v in CATALOG.items() if k not in ("areas", "modules")}, "code": "TIBSc26", "catalog_term": "WS 2026/27",
    "study_plan": {"url": "https://plan.example.invalid/verlaufsplan-26.pdf", "fetched_at": None, "sha256": None},
    "areas": [a for a in CATALOG["areas"] if a["id"] not in _ELECTIVE] + [
        {"id": "akademisches-arbeiten", "name": "Akademisches Arbeiten", "lp_required": 5, "lp_max": 10, "kind": "pflicht"},
        {"id": "vertiefung", "name": "Vertiefung", "lp_required": 10, "lp_max": 20, "kind": "pflicht"},
        {"id": "seminare", "name": "Seminare", "lp_required": None, "lp_max": None, "kind": "wahlpflicht",
         "modules_required": 1},
        {"id": "labore", "name": "Labore", "lp_required": 6, "lp_max": None, "kind": "wahlpflicht", "modules_required": 2},
        {"id": "praxis", "name": "Praxis", "lp_required": 0, "lp_max": 10, "kind": "pflicht", "modules": ["vertiefung-c"]},
    ],
    "modules": [m for m in CATALOG["modules"] if m["area"] not in _ELECTIVE] + [
        mod("einfuehrung-wa", "Einführung in das wissenschaftliche Arbeiten", "akademisches-arbeiten", 5, 1, "WS",
            kind="wahlpflicht"),
        mod("proseminar-a", "Proseminar Rechnernetze", "akademisches-arbeiten", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("proseminar-b", "Proseminar Robotik", "akademisches-arbeiten", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("vertiefung-a", "Vertiefung Echtzeitsysteme", "vertiefung", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("vertiefung-b", "Vertiefung Compilerbau", "vertiefung", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("vertiefung-c", "Vertiefung Datenbanken", "vertiefung", 5, None, "WS+SS", kind="wahlpflicht"),
        mod("seminar-x", "Seminar Sicherheit", "seminare", 4, None, "WS+SS", kind="wahlpflicht"),
        mod("seminar-y", "Seminar Verteilte Systeme", "seminare", 4, None, "WS+SS", kind="wahlpflicht"),
        mod("labor-a", "Labor Mikrocontroller", "labore", 6, None, "WS+SS", kind="wahlpflicht"),
        mod("labor-b", "Labor FPGA", "labore", 3, None, "WS+SS", kind="wahlpflicht"),
        mod("praxis-a", "Praxisprojekt", "praxis", 5, None, "WS+SS", kind="wahlpflicht"),
    ],
    "plan_slots": [{"semester": 4, "title": "Proseminar", "areas": ["akademisches-arbeiten"], "lp": 5, "lp_max": None},
                   {"semester": 4, "title": "Vertiefung", "areas": ["vertiefung"], "lp": 5, "lp_max": None},
                   {"semester": 5, "title": "Vertiefung", "areas": ["vertiefung"], "lp": 5, "lp_max": None},
                   {"semester": 5, "title": "Seminar", "areas": ["seminare"], "lp": None, "lp_max": None},
                   {"semester": 5, "title": "Labor", "areas": ["labore"], "lp": 3, "lp_max": None},
                   {"semester": 5, "title": "Labor", "areas": ["labore"], "lp": 3, "lp_max": None},
                   {"semester": 6, "title": "Wahlmodul", "areas": ["vertiefung", "praxis"], "lp": 5, "lp_max": None},
                   {"semester": 6, "title": "Wahlmodul", "areas": ["vertiefung", "praxis"], "lp": 5, "lp_max": None}],
}

# Versuche ehrlich (11.11.2026): Hoechstzahl der Versuche im Katalog (3), Bachelorarbeit nur 2
CATALOG_MAX = {**CATALOG, "code": "TIBSc22MAX", "max_attempts": 3,
               "modules": [dict(m, max_attempts=2) if m["id"] == "bachelorarbeit" else m for m in CATALOG["modules"]]}

# Wahl statt Pflicht (11.11.2026): Bereich "Vertiefung" verlangt 10 LP, der Katalog nennt 5 Module (25 LP) als Pflicht
# (eins mit Fachsemester bleibt Pflicht); ein Kapitel "Details der Semesterangebote" mit 40 Modulen (200 LP) als
# Pflicht ohne LP-Angabe (wie ETBSc17); Softwareprojekt setzt ein Wahlmodul voraus (kein "nicht im Plan")
CATALOG_OVERFULL = {
    **{k: v for k, v in CATALOG.items() if k not in ("areas", "modules")}, "code": "ETBSc17X", "catalog_term": "WS 2026/27",
    "areas": [a for a in CATALOG["areas"] if a["id"] not in _ELECTIVE] + [
        {"id": "vertiefung", "name": "Vertiefung", "lp_required": 10, "lp_max": None, "kind": "pflicht"},
        {"id": "details", "name": "Details der Semesterangebote", "lp_required": None, "lp_max": None, "kind": "pflicht"},
    ],
    "modules": [dict(m, prerequisites=["software-engineering", "vertiefung-c"]) if m["id"] == "softwareprojekt" else m
                for m in CATALOG["modules"] if m["area"] not in _ELECTIVE] + [
        mod("vertiefung-a", "Vertiefung Echtzeitsysteme", "vertiefung", 5, 5, "WS"),
        mod("vertiefung-b", "Vertiefung Compilerbau", "vertiefung", 5, None, "SS"),
        mod("vertiefung-c", "Vertiefung Datenbanken", "vertiefung", 5, None, "WS"),
        mod("vertiefung-d", "Vertiefung Robotik", "vertiefung", 5, None, "WS+SS"),
        mod("vertiefung-e", "Vertiefung Grafik", "vertiefung", 5, None, "WS+SS"),
    ] + [mod(f"angebot-{i}", f"Angebot {i}", "details", 5, None, "WS+SS") for i in range(1, 41)],
}

# Abgleich mit dem Online-Verlaufsplan (11.11.2026, wie TIBSc25/INFBSc22 laut PO 2026 und Verlaufsplan WS 2026/27):
# "Einfuehrung" ist Pflicht im 1. Semester erst ab Studienbeginn WS 2025/26 (`required_from`), Akademisches Arbeiten
# 10 LP (Einfuehrung + Proseminar-Platz im 4.); "Logik" liegt laut Verlaufsplan im 2. vor ihrer empfohlenen
# Voraussetzung "Theorie" (3.); das Nebenfach steckt in den Plaetzen "Wahl(pflicht)modul" (kein eigener "Nebenfach waehlen")
CATALOG_VP = {
    **{k: v for k, v in CATALOG.items() if k not in ("areas", "modules")}, "program": "Informatik", "code": "INFBSc22X",
    "catalog_term": "WS 2026/27", "max_attempts": 3,
    "study_plan": {"url": "https://plan.example.invalid/verlaufsplan-inf.pdf", "fetched_at": None, "sha256": None},
    "areas": [
        {"id": "informatik", "name": "Grundlagen der Informatik", "lp_required": 20, "kind": "pflicht"},
        {"id": "akademisches-arbeiten", "name": "Akademisches Arbeiten", "lp_required": 10, "lp_max": 10, "kind": "pflicht"},
        {"id": "studium-generale", "name": "Studium Generale", "lp_required": 3, "lp_max": 6, "kind": "wahlpflicht"},
        {"id": "nebenfach-bwl", "name": "Nebenfach Betriebswirtschaftslehre", "lp_required": 12, "lp_max": 16, "kind": "wahlpflicht"},
        {"id": "nebenfach-physik", "name": "Nebenfach Physik", "lp_required": 12, "kind": "wahlpflicht"},
        {"id": "abschluss", "name": "Bachelorarbeit", "lp_required": 15, "kind": "abschluss"},
    ],
    "modules": [
        mod("programmieren-1", "Programmieren I", "informatik", 5, 1, "WS"),
        mod("einfuehrung", "Einführung in die Informatik", "akademisches-arbeiten", 5, 1, "WS") | {"required_from": "WS 2025/26"},
        mod("logik", "Logik und formale Systeme", "informatik", 5, 2, "SS", ["theorie"]),
        mod("theorie", "Grundlagen der Theoretischen Informatik", "informatik", 5, 3, "WS"),
        mod("datenbanken", "Grundlagen der Datenbanksysteme", "informatik", 5, 4, "SS", ["programmieren-1"]),
        mod("proseminar-a", "Proseminar Theoretische Informatik", "akademisches-arbeiten", 5, None, "WS", kind="wahlpflicht"),
        mod("proseminar-b", "Proseminar Maschinelles Lernen", "akademisches-arbeiten", 5, None, "SS", kind="wahlpflicht"),
        mod("sg-recht", "Patentrecht", "studium-generale", 3, None, "WS", kind="wahlpflicht"),
        mod("bwl-1", "Einführung in die BWL", "nebenfach-bwl", 6, None, "WS", kind="wahlpflicht"),
        mod("physik-1", "Physik für Informatiker", "nebenfach-physik", 12, None, "WS", kind="wahlpflicht"),
        mod("bachelorarbeit", "Bachelorarbeit", "abschluss", 15, 6, "WS+SS", kind="abschluss") | {"max_attempts": 2},
    ],
    "plan_slots": [{"semester": 2, "title": "Wahl(pflicht)modul (SG / N)", "areas": ["studium-generale", "nebenfach-bwl",
                                                                                     "nebenfach-physik"], "lp": 5, "lp_max": None},
                   {"semester": 4, "title": "Proseminar", "areas": ["akademisches-arbeiten"], "lp": 5, "lp_max": None}],
}

ABSCHLUSS = "Technische Informatik (PO-Version 2017)"


def g(text, semester, status, note="", versuch="", nr="", credits="", datum="", raw=None):
    row = {"text": text, "semester": semester, "status": status, "note": note, "versuch": versuch, "pruefungsnr": nr,
           "credits": credits, "datum": datum, "abschluss": ABSCHLUSS}
    if raw is not None:
        row["raw"] = raw
    return row


def passed(titles_terms):
    return [g(t, s, "bestanden", "2,3") for t, s in titles_terms]


SEM1 = ["Programmieren I", "Mathematik I", "Grundlagen digitaler Systeme", "Elektrotechnische Grundlagen I",
        "Grundlagen der theoretischen Informatik"]
SEM2 = ["Programmieren II", "Mathematik II", "Rechnerstrukturen", "Elektrotechnische Grundlagen II",
        "Datenstrukturen und Algorithmen"]
SEM3 = ["Mathematik III", "Grundlagen der Betriebssysteme", "Signale und Systeme", "Software-Engineering",
        "Digitalschaltungen der Elektronik"]
SEM4 = ["Grundlagen der Rechnernetze", "Stochastik für Ingenieure", "Grundlagen der Regelungstechnik", "Softwareprojekt"]

# Hoehere Fachsemester (Meldung des Inhabers 12.11.2026: ausser im 1. Semester erkannte der Plan weder Semester noch
# Versuche): Semester in allen Schreibweisen des QIS/HIS, leere Semesterspalte mit Pruefungsdatum, Versuche ohne
# Versuchsspalte, Studienbeginn vom Einstellungsblatt ungefragt auf das aktuelle Semester gesetzt
HOEHER_3 = ([g(t, "25/26 WS", "bestanden", "2,3") for t in SEM1 if t not in ("Mathematik I", "Grundlagen digitaler Systeme")]
            + [g("Grundlagen digitaler Systeme", "", "bestanden", "1,7", datum="18.02.2026"),
               g("Mathematik I", "W25", "nicht bestanden", "5,0", datum="20.02.2026"),
               g("Mathematik I", "S26", "bestanden", "3,0", datum="02.04.2026")]
            + [g(t, "20261", "bestanden", "2,0") for t in SEM2 if t != "Mathematik II"])
HOEHER_5 = (passed([(t, "WS 2024/25") for t in SEM1]) + passed([(t, "Sommersemester 2025") for t in SEM2])
            + passed([(t, "Wi.Se. 25/26") for t in SEM3]) + passed([(t, "SoSe2026") for t in SEM4]))
HOEHER_7 = ([g(t, "", "bestanden", "2,7", datum="14.02.2024") for t in SEM1]
            + [g(t, "", "bestanden", "2,3", datum="22.07.2024") for t in SEM2 if t != "Mathematik II"]
            + [g("Mathematik II", "", "nicht bestanden", "5,0", datum="16.07.2024"),
               g("Mathematik II", "", "nicht bestanden", "5,0", datum="27.09.2024"),
               g("Mathematik II", "SS 2025", "bestanden", "4,0", datum="15.07.2025")]
            + passed([(t, "2024W") for t in SEM3]) + passed([(t, "S 25") for t in SEM4])
            + [g("Seminar Technische Informatik", "WiSe 2025/26", "bestanden", "1,3", versuch="1")])

CASES = [
    {"name": "hoeher_3_fachsemester", "what": "3. Fachsemester: Semester als '25/26 WS', 'W25', 'S26', HIS-Schluessel "
     "'20261', leere Semesterspalte mit Datum; Mathematik I erst im zweiten Versuch (ohne Versuchsspalte)",
     "today": "2026-11-12", "settings": {}, "grades": HOEHER_3},
    {"name": "hoeher_5_beginn_aus_qis", "what": "5. Fachsemester, Studienbeginn vom Einstellungsblatt auf das aktuelle "
     "Semester gesetzt: QIS-Leistungen ab WS 2024/25 gehen vor, alles Bestandene im QIS-Semester",
     "today": "2026-11-12", "settings": {"start_term": "WiSe 26/27"}, "grades": HOEHER_5},
    {"name": "hoeher_7_datum_und_versuche", "what": "7. Fachsemester: die ersten beiden Semester ohne Semesterspalte "
     "(nur Datum), Mathematik II zweimal im SoSe 24 nicht bestanden (Erst- und Zweittermin), im SoSe 25 im dritten Versuch",
     "today": "2026-11-12", "settings": {}, "grades": HOEHER_7},
    {"name": "im_plan", "what": "Beginn WiSe 24/25, alles bis zum 4. Fachsemester bestanden, Seminar angemeldet",
     "today": "2026-11-04", "settings": {},
     "grades": [g("Pflichtmodule", "", "", credits="117")]
     + passed([(t, "WiSe 24/25") for t in SEM1]) + passed([(t, "SoSe 25") for t in SEM2])
     + passed([(t, "WiSe 25/26") for t in SEM3]) + passed([(t, "SoSe 26") for t in SEM4])
     + [g("Seminar Technische Informatik", "WiSe 26/27", "angemeldet", versuch="1")]},
    {"name": "nicht_bestanden_ws", "what": "Theoretische Informatik im WiSe 25/26 nicht bestanden: naechstes WS",
     "today": "2026-05-15", "settings": {},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1 if "theoretischen" not in t])
     + [g("Grundlagen der theoretischen Informatik", "WiSe 25/26", "nicht bestanden", "5,0", "1")]},
    {"name": "nicht_bestanden_abhaengige", "what": "Programmieren I nicht bestanden: Programmieren II, Datenstrukturen "
     "und alles danach wandern mit", "today": "2026-05-15", "settings": {},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1 if t != "Programmieren I"])
     + [g("Programmieren I", "WiSe 25/26", "nicht bestanden", "5,0", "1"),
        g("Mathematik II", "SoSe 26", "angemeldet")]},
    {"name": "dritter_versuch", "what": "Mathematik I zweimal nicht bestanden, dritter Versuch angemeldet; Mathematik II "
     "angemeldet ohne Mathematik I; Signale und Systeme endgueltig; Rueckstand",
     "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 24/25") for t in SEM1 if t != "Mathematik I"])
     + [g("Mathematik I", "WiSe 24/25", "nicht bestanden", "5,0", "1"),
        g("Mathematik I", "SoSe 25", "nicht bestanden", "5,0", "2"),
        g("Mathematik I", "WiSe 26/27", "angemeldet", "", "3"),
        g("Mathematik II", "WiSe 26/27", "angemeldet", "", "1"),
        g("Signale und Systeme", "WiSe 25/26", "nicht bestanden", "5,0", "1"),
        g("Signale und Systeme", "SoSe 26", "endgültig nicht bestanden", "5,0", "2")]
     + passed([("Programmieren II", "SoSe 25"), ("Datenstrukturen und Algorithmen", "SoSe 25")])},
    {"name": "beginn_sose", "what": "Beginn SoSe 25 (fruehestes QIS-Semester): WS-Module des 1. Fachsemesters erst im "
     "WiSe 25/26", "today": "2026-11-04", "settings": {},
     "grades": [g("Schlüsselkompetenzen", "SoSe 25", "bestanden", "1,0")]
     + passed([(t, "WiSe 25/26") for t in SEM1]) + passed([(t, "SoSe 26") for t in SEM2[:3]])},
    {"name": "wahlpflicht_gewaehlt", "what": "Wahlpflicht gewaehlt, Eingebettete Systeme aus QIS; Mathematik III und "
     "Digitalschaltungen liegen geblieben: 38 LP im WiSe 26/27, Robotik wandert ins naechste WS",
     "today": "2026-11-04", "settings": {"electives": ["datenbanken", "bildverarbeitung", "robotik", "ki"]},
     "grades": passed([(t, "WiSe 24/25") for t in SEM1]) + passed([(t, "SoSe 25") for t in SEM2])
     + passed([(t, "WiSe 25/26") for t in SEM3 if t not in ("Mathematik III", "Digitalschaltungen der Elektronik")])
     + passed([(t, "SoSe 26") for t in SEM4]) + passed([("Eingebettete Systeme", "SoSe 26")])},
    {"name": "namensvarianten", "what": "Uebung zu, Tranche, Gruppe, roemische/arabische Zahlen, &, Pruefungsnummer, "
     "Bereichszeilen, Studienbeginn als Einstellung, nicht zugeordnete Zeilen",
     "today": "2026-11-04", "settings": {"start_term": "WS 2024/25", "po": "2022"},
     "grades": [g("Pflichtmodule", "", "", credits="40"), g("Kompetenzbereich Mathematik", "", "bestanden"),
                g("Übung zu Programmieren I", "WiSe 24/25", "bestanden", "2,0"),
                g("Mathematik 1", "Wintersemester 2024/2025", "bestanden", "3,0"),
                g("Grundlagen digitaler Systeme, Tranche A", "WS 2024/25", "bestanden", "1,7"),
                g("Elektrotechnische Grundlagen 1 (Tranche 2)", "WiSe 24/25", "bestanden", "2,7"),
                g("Programmierung 2", "SoSe 25", "bestanden", "1,3", nr="1234"),
                g("Datenstrukturen & Algorithmen - Gruppe 3", "Sommersemester 2025", "bestanden", "2,0"),
                g("Modul Rechnerstrukturen", "SS 25", "bestanden", "2,3"),
                g("Mathematik II (Klausur)", "SoSe 25", "nicht bestanden", "5,0", "1"),
                g("Signale u. Systeme", "WiSe 25/26", "bestanden", "2,0"),
                g("Englisch für Ingenieure", "WiSe 25/26", "bestanden", "1,0"),
                g("Grundlagen der theoretischen Informatik", "WiSe 24/25", "abgemeldet")]},
    {"name": "plaetze_laut_verlaufsplan", "catalog_code": "TIBSc25", "what": "Katalog mit Studienverlaufsplan: "
     "Eingebettete Systeme (bestanden) belegt den Platz im 4. Fachsemester, Datenbanken und KI (Katalogreihenfolge) die "
     "beiden im 5., Robotik den freien im 6. (nur im WS angeboten: WiSe 27/28)", "today": "2026-11-04", "settings": {"electives": ["ki", "datenbanken", "robotik"]},
     "grades": passed([(t, "WiSe 24/25") for t in SEM1]) + passed([(t, "SoSe 25") for t in SEM2])
     + passed([(t, "WiSe 25/26") for t in SEM3]) + passed([(t, "SoSe 26") for t in SEM4])
     + passed([("Eingebettete Systeme", "SoSe 26")])},
    {"name": "noch_nichts", "what": "keine QIS-Zeilen, Beginn = aktuelles Semester", "today": "2026-11-04",
     "settings": {}, "grades": []},
    {"name": "wahlbereiche_offen", "catalog_code": "ETBSc25", "what": "Wahlbereiche ohne Wahl: Plaetze fuer Seminar "
     "(1 Modul), Studium generale (4 LP, 3. Fachsemester, ohne Module) und 'Schwerpunkt wählen' (15 LP); Pflichtmodul des "
     "Schwerpunkts fehlt", "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1]) + passed([(t, "SoSe 26") for t in SEM2])},
    {"name": "schwerpunkt_gewaehlt", "catalog_code": "ETBSc25", "what": "Schwerpunkt Robotik gewaehlt: dessen Pflichtmodul "
     "im Plan, Robotik I auf eigenen Platz (WiSe 27/28), KI zaehlt im Schwerpunkt (Mitglied ueber areas[].modules), eigener "
     "Eintrag Studium generale aus QIS bestanden, ein zweiter geplant", "today": "2026-11-04",
     "settings": {"tracks": {"schwerpunkt": "schwerpunkt-robotik"}, "electives": ["robotik", "ki", "seminar-b"],
                  "placements": {"robotik": "WiSe 27/28"},
                  "custom": [{"title": "Spanisch A1", "lp": 4, "area": "studium-generale"},
                             {"id": "eigen-7", "title": "Rhetorik", "lp": 2.5, "area": "studium-generale", "semester": 5},
                             {"title": "  ", "lp": 3}]},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1]) + passed([(t, "SoSe 26") for t in SEM2])
     + [g("Spanisch A1", "SoSe 26", "bestanden", "1,3", credits="4")]},
    {"name": "schwerpunkt_aus_qis", "catalog_code": "ETBSc25", "what": "ohne Einstellung: Datenbanksysteme I bestanden -> "
     "Schwerpunkt Daten", "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1]) + passed([("Datenbanksysteme I", "SoSe 26")])},
    {"name": "wahlbereich_ohne_lp", "catalog_code": "ETBSc17", "what": "Seminare ohne LP-Angabe: ein Platz; mit gewaehltem "
     "Seminar keiner mehr", "today": "2026-11-04", "settings": {"tracks": {"schwerpunkt": "schwerpunkt-daten"}},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1])},
    {"name": "wahlbereich_ohne_lp_gewaehlt", "catalog_code": "ETBSc17", "what": "Seminar gewaehlt: kein Platz mehr",
     "today": "2026-11-04", "settings": {"electives": ["seminar-a"]}, "grades": []},
    {"name": "selbst_verschoben", "what": "eigene Lage: Rechnernetze (SS) ins WiSe 26/27 vorgezogen (Turnus-Hinweis), "
     "Mathematik III ins SoSe 27 (Hinweis Voraussetzung fuer Signale ... nicht), Stochastik nicht belegt, Programmieren I "
     "bestanden bleibt (Lage ignoriert), Theoretische Informatik nicht bestanden auf WiSe 27/28 gelegt, alte Lage "
     "(SoSe 25) wird nachgeholt", "today": "2026-11-04",
     "settings": {"start_term": "WiSe 25/26", "excluded": ["stochastik"],
                  "placements": {"rechnernetze": "WiSe 26/27", "mathematik-3": "SoSe 27", "programmieren-1": "SoSe 27",
                                 "theoretische-informatik": "WiSe 27/28", "et-2": "SoSe 25", "unbekannt": "WiSe 26/27",
                                 "datenstrukturen": "Herbst"}},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1 if "theoretischen" not in t])
     + [g("Grundlagen der theoretischen Informatik", "WiSe 25/26", "nicht bestanden", "5,0", "1")]},
    # volle Bereiche (05.11.2026)
    {"name": "bereiche_offen_verlaufsplan", "catalog_code": "TIBSc26", "what": "nichts gewaehlt: alle Plaetze laut "
     "Verlaufsplan, die beiden Wahlmodule im 6. Fachsemester ueber die Spanne der Vertiefung (bis 20 LP)",
     "today": "2026-11-04", "settings": {"start_term": "WiSe 26/27"}, "grades": []},
    {"name": "proseminar_bereich_voll_fachsemester", "catalog_code": "TIBSc26", "what": "Einfuehrung in das "
     "wissenschaftliche Arbeiten (Fachsemester 1) deckt Akademisches Arbeiten: kein Platz Proseminar mehr, obwohl die "
     "Obergrenze 10 LP erlaubt (wie INFBSc22)", "today": "2026-11-04",
     "settings": {"start_term": "WiSe 26/27", "electives": ["einfuehrung-wa"]}, "grades": []},
    {"name": "proseminar_bereich_voll_eigene_lage", "catalog_code": "TIBSc26", "what": "Proseminar auf eigener Lage im "
     "WiSe 27/28 (dort kein Platz): belegt trotzdem den Platz Proseminar im 4. Fachsemester",
     "today": "2026-11-04", "settings": {"start_term": "WiSe 26/27", "electives": ["proseminar-a"],
                                         "placements": {"proseminar-a": "WiSe 27/28"}}, "grades": []},
    {"name": "lp_bereich_voll", "catalog_code": "TIBSc26", "what": "eigener Eintrag mit 10 LP deckt die Vertiefung: "
     "keine Plaetze Vertiefung mehr, die Wahlmodule gehen an die Praxis (0 - 10 LP)", "today": "2026-11-04",
     "settings": {"start_term": "WiSe 26/27", "custom": [{"title": "Auslandsmodul", "lp": 10, "area": "vertiefung"}]},
     "grades": []},
    {"name": "lp_bereich_teilweise", "catalog_code": "TIBSc26", "what": "Vertiefung Datenbanken (auch in der Praxis "
     "waehlbar) zaehlt einmal, in der Vertiefung (5 von 10 LP), und belegt deren ersten Platz; der zweite zeigt die "
     "restlichen 5 LP, die Wahlmodule bleiben in der Spanne bis 20 LP", "today": "2026-11-04",
     "settings": {"start_term": "WiSe 26/27", "electives": ["vertiefung-c"]}, "grades": []},
    {"name": "zahl_bereich_voll", "catalog_code": "TIBSc26", "what": "Seminare (1 Modul) mit eigenem Eintrag gedeckt: kein "
     "Platz Seminar; Labore: Labor Mikrocontroller deckt 6 LP, aber erst 1 von 2 Modulen, ein Platz Labor bleibt",
     "today": "2026-11-04", "settings": {"start_term": "WiSe 26/27", "electives": ["labor-a"],
                                         "custom": [{"title": "Seminar im Ausland", "lp": 3, "area": "seminare"}]},
     "grades": []},
    # Versuche ehrlich (11.11.2026)
    {"name": "versuche_hoechstzahl", "catalog_code": "TIBSc22MAX", "what": "Katalog nennt hoechstens 3 Versuche: "
     "Mathematik I im 3. Versuch angemeldet und Signale und Systeme zweimal nicht bestanden -> letzter Versuch (laut "
     "Pruefungsordnung); Programmieren II dreimal nicht bestanden -> endgueltig, obwohl QIS nur 'nicht bestanden' sagt",
     "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 24/25") for t in SEM1 if t != "Mathematik I"])
     + [g("Mathematik I", "WiSe 24/25", "nicht bestanden", "5,0", "1"),
        g("Mathematik I", "SoSe 25", "nicht bestanden", "5,0", "2"),
        g("Mathematik I", "WiSe 26/27", "angemeldet", "", "3"),
        g("Signale und Systeme", "WiSe 25/26", "nicht bestanden", "5,0", "1"),
        g("Signale und Systeme", "SoSe 26", "nicht bestanden", "5,0", "2"),
        g("Programmieren II", "SoSe 25", "nicht bestanden", "5,0", "1"),
        g("Programmieren II", "WiSe 25/26", "nicht bestanden", "5,0", "2"),
        g("Programmieren II", "SoSe 26", "nicht bestanden", "5,0", "3")]},
    {"name": "versuche_ohne_nummer", "what": "QIS ohne Versuchsspalte (wie LSF Hildesheim): Mathematik I zweimal nicht "
     "bestanden und angemeldet -> neutral, keine Nummer aus QIS, kein letzter Versuch; Signale und Systeme mit Vermerk "
     "'letzter Versuch' in QIS -> letzter Versuch laut QIS", "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 24/25") for t in SEM1 if t != "Mathematik I"])
     + [g("Mathematik I", "WiSe 24/25", "nicht bestanden", "5,0"),
        g("Mathematik I", "SoSe 25", "nicht bestanden", "5,0"),
        g("Mathematik I", "WiSe 26/27", "angemeldet"),
        g("Signale und Systeme", "WiSe 25/26", "nicht bestanden", "5,0",
          raw="210 | Signale und Systeme | PL | WiSe 25/26 | 5,0 | nicht bestanden | 0 | 20.02.2026 | 2 | letzter Versuch")]},
    # Wahl statt Pflicht und Wahlfach aus QIS (11.11.2026)
    {"name": "wahl_statt_pflicht", "catalog_code": "ETBSc17X", "what": "Vertiefung (10 LP) mit 5 Pflichtmodulen (25 LP): "
     "nur das mit Fachsemester bleibt Pflicht, ein Platz fuer die restlichen 5 LP; Kapitel mit 200 LP als Pflicht: ein "
     "Platz statt 40 Pflichtmodulen; Hinweise 'wahl_erkannt'; Voraussetzung Vertiefung Datenbanken (Wahl) fehlt nicht",
     "today": "2026-11-04", "settings": {"start_term": "WiSe 26/27"}, "grades": []},
    {"name": "wahl_statt_pflicht_aus_qis", "catalog_code": "ETBSc17X", "what": "Vertiefung Compilerbau bestanden (Titel beginnt wie eine QIS-Bereichszeile): steht "
     "als Wahlpflicht im Plan, die Vertiefung ist voll (kein Platz mehr)", "today": "2026-11-04", "settings": {},
     "grades": passed([(t, "WiSe 25/26") for t in SEM1]) + passed([("Vertiefung Compilerbau", "SoSe 26")])},
    {"name": "wahlfach_aus_qis", "catalog_code": "ETBSc25", "what": "QIS-Bereich 'Kompetenzbereich Studium Generale': "
     "Englisch B2 (4 LP, bestanden) fuellt den Bereich ohne Katalogmodul, kein Platz mehr; Seminar Datenbanken (Katalog) "
     "unter 'Kompetenzbereich Seminare' angemeldet belegt den Seminar-Platz; 'Englisch für Ingenieure' unter "
     "'Pflichtmodule' bleibt nicht zugeordnet", "today": "2026-11-04", "settings": {},
     "grades": [g("Pflichtmodule", "", "")] + passed([(t, "WiSe 25/26") for t in SEM1])
     + [g("Englisch für Ingenieure", "WiSe 25/26", "bestanden", "1,0"),
        g("Kompetenzbereich Studium Generale", "", "bestanden"),
        g("Englisch B2", "SoSe 26", "bestanden", "1,7", credits="4"),
        g("Englisch B2", "SoSe 26", "bestanden", "1,7", versuch="1"),
        g("Kompetenzbereich Seminare", "", ""),
        g("Seminar Datenbanken", "WiSe 26/27", "angemeldet", versuch="1")]},
    {"name": "wahlfach_aus_qis_verlaufsplan", "catalog_code": "TIBSc26", "what": "Proseminar aus QIS (nicht im Katalog) "
     "unter 'Kompetenzbereich Akademisches Arbeiten' bestanden: belegt den Platz Proseminar; ein nicht bestandenes "
     "Vertiefungsmodul aus QIS zaehlt in der Vertiefung und belegt den naechsten Vertiefungsplatz; abgemeldet zaehlt nicht",
     "today": "2026-11-04", "settings": {"start_term": "WiSe 24/25"},
     "grades": [g("Kompetenzbereich Akademisches Arbeiten", "", ""),
                g("Proseminar Quantencomputing", "SoSe 26", "bestanden", "2,0", "1", nr="4711", credits="5"),
                g("Kompetenzbereich Vertiefung", "", ""),
                g("Kryptographie", "SoSe 26", "nicht bestanden", "5,0", "1"),
                g("Spieltheorie", "SoSe 26", "abgemeldet")]},
    # Abgleich mit dem Online-Verlaufsplan (11.11.2026)
    {"name": "verlaufsplan_neu", "catalog_code": "INFBSc22X", "what": "Beginn WiSe 26/27: Einfuehrung (Pflicht ab WS 2025/26) "
     "im 1. Semester, Logik bleibt im 2. (Voraussetzung Theorie liegt laut Verlaufsplan danach: Empfehlung), Proseminar-Platz "
     "im 4., Nebenfach nur in den Plaetzen Wahl(pflicht)modul (kein eigener Platz 'Nebenfach waehlen')", "today": "2026-11-04",
     "settings": {"start_term": "WiSe 26/27"}, "grades": []},
    {"name": "verlaufsplan_einfuehrung_bestanden", "catalog_code": "INFBSc22X", "what": "Einfuehrung bestanden: der "
     "Proseminar-Platz bleibt (Akademisches Arbeiten 10 LP: beides Pflicht)", "today": "2026-11-04", "settings": {},
     "grades": passed([("Programmieren I", "WiSe 25/26"), ("Einführung in die Informatik", "WiSe 25/26")])},
    {"name": "verlaufsplan_ueberfuehrt", "catalog_code": "INFBSc22X", "what": "Beginn WiSe 23/24 (in die PO ueberfuehrt): "
     "Einfuehrung nicht noetig (nicht im Plan, kein 'nachholen'), Proseminar-Platz bleibt", "today": "2026-11-04",
     "settings": {}, "grades": passed([("Programmieren I", "WiSe 23/24")])},
]

NAMES = ["Programmieren I", "Übung zu Programmieren I", "Programmieren 1", "Vorlesung und Übung Mathematik II",
         "Grundlagen digitaler Systeme, Tranche A", "Elektrotechnische Grundlagen I (Tranche 2)",
         "Datenstrukturen & Algorithmen", "Datenstrukturen und Algorithmen - Gruppe 3", "Modul Rechnerstrukturen",
         "Mathematik II (Klausur)", "Stochastik für Ingenieure", "Schlüsselkompetenzen", "V", "Robotik IV",
         "Fragestunde zur Vorlesung Analysis I", "", "  Größen   und   Maße  "]
TERMS = ["WiSe 25/26", "WS 2025/26", "Wintersemester 2025/2026", "SoSe 26", "SS 2026", "Sommersemester 26",
         "ws 99/00", "WiSe 25", "Herbst 2025", "", "SoSe 2026 "]
TODAYS = ["2026-01-15", "2026-03-31", "2026-04-01", "2026-09-30", "2026-10-01", "2026-12-31"]

PICKS = [
    {"catalogs": [CATALOG_INF, CATALOG, CATALOG_OLD], "settings": {}, "grades": [g("Programmieren I", "WiSe 24/25", "bestanden")]},
    {"catalogs": [CATALOG_INF, CATALOG, CATALOG_OLD], "settings": {"po": "2017"}, "grades": []},
    {"catalogs": [CATALOG_INF, CATALOG, CATALOG_OLD], "settings": {"po": "INFBSc22"}, "grades": []},
    {"catalogs": [CATALOG_INF, CATALOG, CATALOG_OLD], "settings": {"po": "2010"}, "grades": []},
    {"catalogs": [CATALOG_INF, CATALOG_OLD], "settings": {}, "grades": []},
    {"catalogs": [], "settings": {}, "grades": []},
]

# Endpunkte: Datenbank mit App-Modulen, Kursen, Dateien und QIS; Katalogtabellen mit dem Schema des Katalog-Abrufs
# (app/study_catalog.py SCHEMA, dort erst bei Bedarf angelegt)


def catalog_tables() -> list[str]:
    from app import study_catalog
    return [q.strip() for q in study_catalog.SCHEMA.split(";") if q.strip()]


SEED_SQL = [
    *[("INSERT INTO modules(id, name, color, sort, created_at) VALUES (?,?,?,?,?)", [i, n, "#4f5bd5", i, "2026-10-01T08:00:00"])
      for i, n in [(1, "Programmieren II"), (2, "Mathematik III"), (3, "Signale und Systeme"), (4, "Chemie")]],
    *[("INSERT INTO courses(id, title, semester, subject, kind, module_id, active, created_at) VALUES (?,?,?,?,?,?,?,?)",
       [cid, title, "WiSe 26/27", subj, kind, mid, act, "2026-10-01T08:00:00"])
      for cid, title, subj, kind, mid, act in [
          ("c1", "Programmieren II", "Programmieren II", "vorlesung", 1, 1),
          ("c2", "Übung zu Programmieren II", "Programmieren II", "uebung", 1, 1),
          ("c3", "Mathematik III für Ingenieure", "Mathematik III für Ingenieure", "vorlesung", None, 1),
          ("c4", "Mathematik III (Tranche B)", "Mathematik III", "vorlesung", None, 1),
          ("c5", "Programmieren II (alt)", "Programmieren II", "vorlesung", 1, 0),
          ("c6", "Chemie", "Chemie", "vorlesung", 4, 1)]],
    *[("INSERT INTO files(id, course_id, name, size, mime, chdate, first_seen) VALUES (?,?,?,?,?,?,?)",
       [fid, cid, name, 100, "application/pdf", 1760000000, "2026-10-02T08:00:00"])
      for fid, cid, name in [("f1", "c1", "Vorlesung 01.pdf"), ("f2", "c2", "Blatt 1.pdf"), ("f3", "c1", "Altklausur.pdf"),
                             ("f4", "c4", "Skript.pdf"), ("f5", "c6", "Chemie.pdf"), ("f6", "c5", "Alt.pdf")]],
    *[("INSERT INTO grades(text, semester, status, note, versuch, pruefungsnr, credits, datum, abschluss, raw, fetched_at) "
       "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
       [r["text"], r["semester"], r["status"], r["note"], r["versuch"], r["pruefungsnr"], r["credits"], r["datum"],
        r["abschluss"], None, "2026-11-01T08:00:00"])
      for r in passed([(t, "WiSe 25/26") for t in SEM1]) + [g("Programmieren II", "SoSe 26", "nicht bestanden", "5,0", "1"),
                                                            g("Mathematik II", "SoSe 26", "bestanden", "2,0")]],
]


def catalog_insert(c: dict):
    from app import study_plan
    return ("INSERT INTO study_catalogs(catalog_key, university, code, catalog_term, program, po, payload, origin, source_url, "
            "fetched_at, stored_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            [study_plan.catalog_key(c), c["university"], c["code"], c["catalog_term"], c["program"], c["po"],
             json.dumps(c, ensure_ascii=False), "fixture", c["source"]["url"], "2026-11-04T09:00:00", "2026-11-04T09:00:00"])


def steps_def():
    from app import study_plan
    text = ("INSERT INTO study_module_texts(catalog_key, module_id, content, goals, literature) VALUES (?,?,?,?,?)",
            [study_plan.catalog_key(CATALOG), "programmieren-2", "Objektorientierung, Generics, Nebenläufigkeit.",
             "Die Studierenden können größere Programme entwerfen.", "Ullenboom: Java ist auch eine Insel"])
    return [
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "GET", "path": "/api/study-plan/settings"},
        {"method": "GET", "path": "/api/study-plan/module/programmieren-2"},
        {"sql": [catalog_insert(CATALOG_INF), catalog_insert(CATALOG), text]},
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "GET", "path": "/api/study-plan/settings"},
        {"method": "GET", "path": "/api/study-plan/module/programmieren-2"},
        {"method": "GET", "path": "/api/study-plan/module/mathematik-3"},
        {"method": "GET", "path": "/api/study-plan/module/robotik"},
        {"method": "GET", "path": "/api/study-plan/module/gibt-es-nicht"},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"start_term": "Wintersemester 2025/2026",
                                                                        "electives": ["robotik", "ki", "robotik", ""]}},
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"po": "INFBSc22"}},
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"po": "1999"}},
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"po": "  "}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"start_term": "Herbst 25"}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"po": 2022}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"electives": "ki"}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"start_term": None}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": [1]},
        {"method": "GET", "path": "/api/study-plan/module/robotik"},
        # Wahlbereiche und eigene Lage (05.11.2026)
        {"method": "POST", "path": "/api/study-plan/settings", "body": {
            "po": None, "tracks": {"schwerpunkt": "x", "": "y"}, "excluded": ["stochastik", "stochastik", ""],
            "placements": {"mathematik-3": "WS 2027/28", "rechnernetze": "SoSe 27", "leer": ""},
            "custom": [{"title": "Spanisch A1", "lp": 4}, {"title": "Rhetorik", "lp": 99, "semester": 30, "id": "eigen-1"}]}},
        {"method": "GET", "path": "/api/study-plan"},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"electives": []}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"placements": {"mathematik-3": "Herbst 27"}}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"placements": ["x"]}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"tracks": {"schwerpunkt": 1}}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"excluded": "stochastik"}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"custom": [1]}},
        {"method": "POST", "path": "/api/study-plan/settings", "body": {"placements": None, "excluded": None}},
    ]


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import server, study_plan

        src.freeze(lambda: TODAY, lambda: NOW, lambda: datetime.fromisoformat(NOW))
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)

        cases = []
        for c in CASES:
            cat = {"TIBSc25": CATALOG_SLOTS, "ETBSc25": CATALOG_AREAS, "ETBSc17": CATALOG_AREAS_NO_LP,
                   "TIBSc26": CATALOG_FULL, "TIBSc22MAX": CATALOG_MAX, "ETBSc17X": CATALOG_OVERFULL,
                   "INFBSc22X": CATALOG_VP}.get(c.get("catalog_code"), CATALOG)
            cases.append({**c, "expected": study_plan.build_plan(cat, c["grades"], c["settings"], c["today"])})
        picks = []
        for p in PICKS:
            cat, reason = study_plan.pick_catalog(p["catalogs"], p["settings"], p["grades"])
            picks.append({"catalogs": [c["code"] for c in p["catalogs"]], "settings": p["settings"], "grades": p["grades"],
                          "code": cat["code"] if cat else None, "reason": reason})
        engine = {
            "generator": "tools/gen-study-plan-fixture.py", "catalog": CATALOG,
            "catalogs": {c["code"]: c for c in (CATALOG, CATALOG_INF, CATALOG_OLD, CATALOG_SLOTS, CATALOG_AREAS,
                                                CATALOG_AREAS_NO_LP, CATALOG_FULL, CATALOG_MAX, CATALOG_OVERFULL, CATALOG_VP)},
            "cases": cases,
            "name_keys": [{"text": t, "key": study_plan.name_key(t)} for t in NAMES],
            "terms": [{"text": t, "term": study_plan.parse_term(t),
                       "name": study_plan.term_name(study_plan.parse_term(t)) if study_plan.parse_term(t) else None} for t in TERMS],
            "current_terms": [{"today": d, "term": study_plan.term_name(study_plan.current_term(d))} for d in TODAYS],
            "picks": picks,
        }

        path = src.fresh_db("studienverlauf")
        seed = [{"sql": s, "params": []} for s in catalog_tables()] + [{"sql": sql, "params": params} for sql, params in SEED_SQL]
        with src.db.cursor() as conn:
            for s in seed:
                conn.execute(s["sql"], s["params"])
        steps = []
        for s in steps_def():
            if "sql" in s:
                with src.db.cursor() as conn:
                    for sql, params in s["sql"]:
                        conn.execute(sql, params)
                steps.append({"sql": [{"sql": q, "params": p} for q, p in s["sql"]]})
                continue
            status, value = gen.asgi(server.app, s["method"], s["path"], s.get("body"))
            step = {"method": s["method"], "path": s["path"], "status": status, "response": without_sync(value)}
            if "body" in s:
                step["body"] = s["body"]
            steps.append(step)
        after = dump_tables(path, {"settings": "SELECT key, value FROM settings WHERE key='study_plan'"})
        endpoints = {"generator": "tools/gen-study-plan-fixture.py", "today": TODAY.isoformat(), "now": NOW, "seed": seed,
                     "steps": steps, "tables_after": after}

        ok = True
        for name, obj in (("engine.json", engine), ("endpoints.json", endpoints)):
            text = json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
            ok = write_or_check(OUT / name, text, check) and ok
        return 0 if ok or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
