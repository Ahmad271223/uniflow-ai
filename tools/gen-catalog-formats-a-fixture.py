"""Fixture der Leseprogramme "Formate A" (docs/STUDIENGAENGE-LUH-2026-11-04.md, Abschnitt "Leseprogramme Formate A"):
packages/shared-contracts/fixtures/catalog-formats-a/

ERFUNDENE Seitentexte im Aufbau der vier Vorlagen (Feldnamen und Anordnung wie in den echten Handbuechern, alle Module,
Namen und Texte ausgedacht; kein Text aus einem echten Handbuch):
  mb-modulkatalog         Seitenkopf "Stand: ... Modul: / Module:", gestapelte und einzeilige Pruefungstabelle, Modul
                          ueber zwei Seiten, englische Feldnamen, Studienverlaufsgrafik mit "Bereich (22 LP)"
  luh-modulbeschreibung   Feld und Wert je Zeile mit nummerierten Abschnitten, Variante ohne "Modultitel" (Titel vor
                          "Kennnummer / Pruefcode", mehrere Felder in einer Zeile, direkt nach dem vorigen Modul),
                          englische Variante ohne Nummern, Kopfzeile auf jeder Seite, "5" + Abschnittsname getrennt
  wiwi-semester / wiwi-unabhaengig  Semesterfassung (Turnus aus Hinweisen) und semesterunabhaengige Fassung
  fbg-modulhandbuch       Uebersicht der Bereiche mit LP, Modul mit "Fachsemester Pflicht/Wahl Kompetenzbereich",
                          Modul mit Vertiefungsmatrix, gewaehlte und nur moegliche Pruefungsform
Je Fall: <name>.pages.json (Seitentexte), <name>.expected.json ({format, meta, catalog, module_texts}).
Aufruf im Projektordner: .venv/bin/python tools/gen-catalog-formats-a-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.catalog_formats import get_parser  # noqa: E402
from app.catalog_formats.wiwi_modulhandbuch import turnus_hints  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "catalog-formats-a"


def meta(program, degree, po, code, term=None, hints=None):
    m = {"university": "luh", "program": program, "degree": degree, "po": po, "code": code, "catalog_term": term,
         "regular_semesters": 6 if degree.startswith("B") else 4, "total_lp": 180 if degree.startswith("B") else 120,
         "source": {"url": f"https://example.org/fixture/{code.replace('|', '-')}.pdf", "fetched_at": None,
                    "sha256": None}}
    if hints:
        m["turnus_hints"] = hints
    return m


MB = [
    """Modulkatalog
zur PO 2030
Studienführer für den
Studiengang Beispieltechnik
Bachelor of Science
Wintersemester 2026/2027""",
    """Kompetenzbereiche des Bachelorstudiums
Grundlagen der Beispieltechnik (12 LP) Vertiefung Beispieltechnik (5- 10 LP)
7""",
    """Stand: 01.10.2026 Beispieltechnik B.Sc. PO 2030
Modul: Grundlagen der
Beispieltechnik
Module: Basics of Example Engineering
Modultyp Kompetenzbereich
Pflicht Grundlagen der Beispieltechnik
Angebot im Dauer Sprache ECTS Empfohlen ab
WiSe 1 Semester Deutsch 7 Zulassung WiSe: 1. Semester Zulassung SoSe: 2. Semester
Prüfungsleistungen (PL) / Studienleistung (SL)
Art ECTS Dauer / Umfang Notenskala
PL
SL
Klausur
Studienleistung
6
1
120 min
Laborversuche
benotet
unbenotet
Workload 210 h
Präsenzstudienzeit 70 h
Selbststudienzeit 140 h
Modulverantwortliche-r Prof. Dr.-Ing. Erika Muster
Dozent-in Prof. Dr.-Ing. Erika Muster
Institut Institut für Beispielkunde
Fakultät Fakultät für Maschinenbau
Aufbau des Moduls
Veranstaltungstitel und Form SWS PL / SL
Grundlagen der Beispieltechnik - Vorlesung 2 Klausur
Voraussetzungen für die Teilnahme: Empfohlen für die Teilnahme:
keine keine
Qualifikationsziele
Die Studierenden kennen erfundene Grundlagen.
12""",
    """Stand: 01.10.2026 Beispieltechnik B.Sc. PO 2030
Modul: Grundlagen der
Beispieltechnik
Module: Basics of Example Engineering
Inhalte
Erfundene Inhalte über zwei Seiten.
Besonderheiten
keine
Literatur
Muster, E.: Beispielbuch. Verlag 2030.
Verwendbarkeit in anderen Studiengängen
keine
13""",
    """Stand: 01.10.2026 Beispieltechnik B.Sc. PO 2030
Modul: Angewandte Beispielsysteme
Module: Applied Example Systems
Type of module Area of competence
Wahlpflicht Vertiefung Beispieltechnik, Grundlagen der Beispieltechnik
Offer in Duration Language ECTS Recommended from
SoSe/WiSe 1 Semester Englisch 5 Admission WiSe: 3/4. Semester Admission SoSe: 4. Semester
Examination performance (Ep) / Academic achievement (Aa)
Kind ECTS Duration / Scope Grading scale
PL Projektorientierte Prüfung 5 Bericht (~10 Seiten) und Präsentation
(~15 Minuten)
benotet
Workload 150 h
Attendance study period 42 h
Self-study time 108 h
Module coordinator Prof. Dr. Max Beispiel
Requirements for participation: Recommended for participation:
none Grundlagen der Beispieltechnik
Qualification goals
Invented goals.
Contents
Invented contents.
Literature
none
14""",
]

LUH = [
    """Modulkatalog Bachelor Beispielwissenschaft
Stand: 01.10.2026""",
    """Beispielwissenschaft B.Sc. – Modulkatalog
4
Pflichtmodule
Modultitel
Einführung in die Beispielkunde
Kennnummer / Prüfcode
100
Studiengang
Bachelorstudiengang Beispielwissenschaft
Modultyp
Pflicht
Leistungspunkte
6 LP
Häufigkeit des Angebots
jedes Wintersemester
Sprache
Deutsch
Kompetenzbereich
kein
Empfohlenes Fachsemester
1. Semester
Moduldauer
1 Semester
Studentische Arbeitsbelastung
180 Stunden 60 h Präsenzstudium 120 h Selbststudium
Weitere Verwendung des Moduls
keine
1 Qualifikationsziele
Die Studierenden beschreiben erfundene Sachverhalte.
2 Inhalte des Moduls
Erfundene Inhalte.
3 Lehrformen und Lehrveranstaltungen
Vorlesung (2 SWS)
4a Teilnahmevoraussetzungenkeine
4b Empfehlungenkeine
5
Voraussetzungen für die Vergabe von Leistungspunkten
Studienleistungen:
Teilnahme an der Übung (1 SL)
Prüfungsleistungen:
Klausur K 90 (1 PL)
6 Literatur
Muster, E.: Erfundenes Lehrbuch.
7 Weitere Angaben
8 Organisationseinheit
Institut für Beispielkunde
9 Modulverantwortliche/r
Prof. Dr. Erika Muster""",
    """Beispielwissenschaft B.Sc. – Modulkatalog
5
Aufbaumodul Beispielkunde
(Advanced Example Studies)
Kennnummer / Prüfcode
BSc Beispielwissenschaft Modultyp: Wahlpflicht
Leistungspunkte: 5 Häufigkeit des Angebots:
Sommersemester
Sprache: Deutsch
Spezialisierungsbereich:
Vertiefung Beispiele
Empfohlenes Fachsemester:
4
Moduldauer: 1 Semester
Studentische Arbeitsbelastung
Gesamt (Stunden) auf Modulebene: 150 Davon Präsenzzeit: 56 Davon Selbststudium: 94
Weitere Verwendung des Moduls
1 Qualifikationsziele
Erfundene Ziele.
2 Inhalte des Moduls
Erfundene Inhalte.
3 Lehrformen und Lehrveranstaltungen
Seminar
4 Teilnahmevoraussetzungen; Empfehlungen
Empfohlen: Einführung in die Beispielkunde
5 Voraussetzungen für die Vergabe von Leistungspunkten
Studienleistungen: Keine
Prüfungsleistungen: Hausarbeit (15 Seiten) / benotet
6 Literatur: Nach Ankündigung
7 Weitere Angaben
8 Organisationseinheit
Institut für Beispielkunde
9 Modulverantwortliche/r
Dr. Max Beispiel, E-Mail: max@example.org
Beispielpraktikum im Gelände
(Example Field Course)
Kennnummer / Prüfcode
BSc Beispielwissenschaft Modultyp: Pflicht
Leistungspunkte: 4 Häufigkeit des Angebots:
Jährlich
Sprache: Deutsch
Empfohlenes Fachsemester:
3
Moduldauer: 1 Semester
Studentische Arbeitsbelastung
Gesamt (Stunden) auf Modulebene: 120
1 Qualifikationsziele
Erfundene Ziele.
5 Voraussetzungen für die Vergabe von Leistungspunkten
Studienleistungen: Geländeprotokoll
Prüfungsleistungen: Keine
9 Modulverantwortliche/r
Dr. Max Beispiel""",
    """Beispielwissenschaft B.Sc. – Modulkatalog
6
Module Title
Example Data Analysis
Module Code
Degree Course
Bachelor Example Science
Module Type
Required elective
Credit Points
5
Frequency of Occurrence
WS
Language
English
Special Skills Area
Datenanalyse
Recommended Semester of
Study
5
Module Duration
1 Semester
Student Workload
Total No of Hours
150
Further Use of Module
Qualification Goals
Invented goals.
Module Contents
Invented contents.
Requirements for Allocation of Credit Points
Course work: accepted exercises
Examination: written exam (90 minutes)
Literature
Invented reference.
Person Responsible for Module
Prof. Example""",
]

WIWI_B = [
    """Modulhandbuch der Wirtschaftswissenschaftlichen Fakultät
Bachelor Beispielökonomie
Semesterunabhängige Version mit Stand Februar 2026, voraussichtliches Angebot, Änderungen möglich
Modulhandbuch
1 / 3""",
    """Modulhandbuch der Wirtschaftswissenschaftlichen Fakultät
Bachelor Beispielökonomie
Semesterunabhängige Version mit Stand Februar 2026, voraussichtliches Angebot, Änderungen möglich
Beispiel-BWL I: Grundlagen
(Example Business I: Basics)
Art Verwendbarkeit Semester
von - bis
Prüfungsnr. Leistungs
punkte
(ECTS)
Workload in
h (Gesamt /
Präsenz /
Selbst)
Pflichtmodul Bachelor Andere Ökonomie - Kompetenzbereich Betriebswirtschaftslehre 2 - 2 999101 6 180 / 42 /
138
Pflichtmodul Bachelor Beispielökonomie - Kompetenzbereich Betriebswirtschaftslehre 1 - 1 999101 6 180 / 42 /
138
Voraussetzungen für die Teilnahme Prüfungsform (und
-dauer)
Prüfer(in) Lehr- und
Lernmethoden
Modulverantwort-
liche(r)
keine Klausur (60 Min.) Prof. Dr. Muster Vorlesung, Übung Prof. Dr. Muster
Qualifikationsziele
Erfundene Ziele.
Veranstaltungen
Belegnr. Titel SWS Art Sprache Semester
999101 Beispiel-BWL I 2 Vorlesung Deutsch Winter
Inhalte
Erfundene Inhalte.
2 / 3""",
    """Modulhandbuch der Wirtschaftswissenschaftlichen Fakultät
Bachelor Beispielökonomie
Semesterunabhängige Version mit Stand Februar 2026, voraussichtliches Angebot, Änderungen möglich
Beispielmärkte
(Example Markets)
Art Verwendbarkeit Semester
von - bis
Prüfungsnr. Leistungs
punkte
(ECTS)
Workload in
h (Gesamt /
Präsenz /
Selbst)
Wahlmodul Bachelor Beispielökonomie - Kompetenzbereich Vertiefung 4 - 6 999202 5 150 / 28 / 122
Voraussetzungen für die Teilnahme Prüfungsform (und
-dauer)
Prüfer(in) Lehr- und
Lernmethoden
Modulverantwort-
liche(r)
Beispiel-BWL I: Grundlagen Hausarbeit (10 Seiten) Prof. Dr. Beispiel Seminar Prof. Dr. Beispiel
Qualifikationsziele
Erfundene Ziele.
Veranstaltungen
Belegnr. Titel SWS Art Sprache Semester
999202 Beispielmärkte 2 Seminar Englisch Sommer
3 / 3""",
]

WIWI_A = [
    """Modulhandbuch der Wirtschaftswissenschaftlichen Fakultät
Bachelor Beispielökonomie
Sommersemester 2026
Modulhandbuch
1 / 2""",
    """Modulhandbuch der Wirtschaftswissenschaftlichen Fakultät
Bachelor Beispielökonomie
Sommersemester 2026
Beispielmärkte
(Example Markets)
Verwendbarkeit Art Semester von
- bis
Bachelor Beispielökonomie - Kompetenzbereich
Vertiefung
Wahlmodul 4 - 6
Bachelor Andere Ökonomie - Kompetenzbereich
Volkswirtschaftslehre
Pflichtmodul 3 - 3
Leistungspunkte
(ECTS)
5
Workload in h 150 / 28 / 122
Lehr- und Lernmethoden Seminar
Modulverantwortung Prof. Dr. Beispiel
Qualifikationsziele
Erfundene Ziele.
Voraussetzungen für die Teilnahme
keine
Veranstaltungsdaten für das Sommersemester 2026
Belegnr., Titel,
SWS und Art
Termin und Raum Dozent(in) Sprache
999202 Beispielmärkte
(2 S)
Mo. 10:00 - 12:00 | I-001 Beispiel Englisch
Prüfungsleistung im Sommersemester 2026
Prüfungsnummer 999202
Prüfungsform (und
-dauer)
Hausarbeit (10 Seiten)
Prüfer/in Prof. Dr. Beispiel
2 / 2""",
]

FBG = [
    """Beispielbauwesen (B. Sc.)
Modulhandbuch
WiSe 2026/27, Stand 01.10.2026 1
Kompetenzbereich LP Module
1 Mathematisch-naturwissenschaftliche Grundlagen (MNG) 6 LP 6 LP Pflichtmodule
2 Übergreifende Inhalte (ÜI) 6 - 12 LP 6 - 12 LP Wahlmodule""",
    """Beispielbauwesen (B. Sc.)
Modulhandbuch
WiSe 2026/27, Stand 01.10.2026 2
Beispielmechanik
Example Mechanics
Mögl. Prüfungsleistungen: K/KA/MP/HA/PJ/VbP
Studienleistungen: 1 SWS / Art
2V / 2Ü
Sprache
D
LP
6
Semester
WS WiSe 2026/27
P-Form VbP: - P-Form PZ I: K P-Form PZ II: K
Ziel des Moduls
Erfundene Ziele.
Inhalt des Moduls
Erfundene Inhalte.
Workload 180 h (60 h Präsenz- und 120 h Eigenstudium einschl. Prüfungs-/Studienleistung)
Voraussetzungen -
Empf. Vorkenntnisse keine
Literatur Muster: Erfundenes Buch.
Medien Tafel
Modulverantwortlich Muster, Erika
Studiengangs-
spezifische
Informationen
Fachsemester Pflicht/Wahl Kompetenzbereich
1 P Mathematisch-naturwissenschaftliche Grundlagen""",
    """Beispielbauwesen (B. Sc.)
Modulhandbuch
WiSe 2026/27, Stand 01.10.2026 3
Beispielstatik
Example Statics
Mögl. Prüfungsleistungen: K/MP/VbP
Studienleistungen: - SWS / Art
2V / 1Ü
Sprache
D/E
LP
5
Semester
WS / SS WiSe 2026/27
P-Form VbP: - P-Form PZ I: - P-Form PZ II: -
Ziel des Moduls
Erfundene Ziele.
Workload 150 h (45 h Präsenz- und 105 h Eigenstudium)
Voraussetzungen -
Empf. Vorkenntnisse Beispielmechanik
Literatur keine
Modulverantwortlich Beispiel, Max
Studiengangs-
spezifische
Informationen
P/W/WP und Kompetenzbereich in Abhängigkeit von Vertiefungsrichtung
Konstruktion
Wasser
W ÜI WP ÜI""",
]

CASES = [
    ("mb-modulkatalog", "mb-modulkatalog", MB, meta("Beispieltechnik", "B.Sc.", "2030", "beispieltechnik|b.sc.|2030")),
    ("luh-modulbeschreibung", "luh-modulbeschreibung", LUH,
     meta("Beispielwissenschaft", "B.Sc.", "2030", "beispielwissenschaft|b.sc.|2030")),
    ("wiwi-unabhaengig", "wiwi-modulhandbuch", WIWI_B,
     meta("Beispielökonomie", "B.Sc.", "2030", "beispieloekonomie|b.sc.|2030", "WS 2026/27")),
    ("wiwi-semester", "wiwi-modulhandbuch", WIWI_A, meta("Beispielökonomie", "B.Sc.", "2030", "beispieloekonomie|b.sc.|2030")),
    ("fbg-modulhandbuch", "fbg-modulhandbuch", FBG, meta("Beispielbauwesen", "B.Sc.", "2030", "beispielbauwesen|b.sc.|2030")),
]


def build() -> dict:
    files = {}
    hints = {}
    for name, fmt, pages, m in CASES:
        if name == "wiwi-semester":
            m = {**m, "turnus_hints": hints}
        catalog, texts = get_parser(fmt)(pages, m)
        if name == "wiwi-unabhaengig":
            hints = turnus_hints(catalog)
        files[f"{name}.pages.json"] = pages
        files[f"{name}.expected.json"] = {"format": fmt, "meta": m, "catalog": catalog, "module_texts": texts}
    return files


def main() -> int:
    files = build()
    if "--check" in sys.argv:
        bad = []
        for name, value in files.items():
            p = OUT / name
            if not p.exists() or json.loads(p.read_text(encoding="utf-8")) != value:
                bad.append(name)
        if bad:
            print("veraltet:", ", ".join(bad))
            return 1
        print("ok")
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, value in files.items():
        (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(files)} Dateien nach {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
