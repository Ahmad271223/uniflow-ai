"""Fixture des Lesers fuer "Studienordnung inklusive Modulhandbuch" der Universitaet Hildesheim
(app/study_catalog_hildesheim.py, Swift-Kern StudyCatalog/StudyCatalogHildesheimParser.swift):
packages/shared-contracts/fixtures/study-catalog-hildesheim/

Alle Seitentexte hier sind ERFUNDEN (Studiengang, Module, Namen, Heft, Daten); nur der Aufbau folgt den echten
Studienordnungen: Titelseite, Paragrafen, "Anlage 1" mit "Gesamtzahl der Leistungspunkte", "Anlage 2 Studienablaufplan",
"Anlage 3 Modulhandbuch" mit der zweispaltigen Tabelle je Modul, Seitenkopf. Kein Text aus einer echten Ordnung.

  verkuendungsblatt.json  Seitentexte wie pypdf sie liefert (Seitenkopf "Verkündungsblatt ... - Seite N -", Luecken wie
                          "Bachelor -Studiengang" und "20 31/32", Titel ueber zwei Zeilen, Teilmodule, Modul ueber die
                          Seitengrenze, zweizeilige Feldnamen, LP als Summe, weitere Anlage danach)
  lesefassung.json        Textstuecke mit Lage (wie `pdf_items` / `StudyCatalogPDF.planItems`, in der Reihenfolge, in der
                          PDFKit sie liefert: erst die Feldnamen-Spalte, dann die Werte) -> `row_pages` -> Seitentexte;
                          Titelseite "Lesefassung (Stand ...)", Master mit "Master of Arts", Teilmodule "(2 SWS / 2 LP)"
  pdfkit-roh.json         roher PDFKit-Text mit mehreren Feldnamen in einer Zeile: Module, Titel und LP bleiben, alles
                          nicht sicher Zuordenbare faellt weg
  werte.json              Einzelfaelle: Fachsemester, Turnus, Leistungspunkte, Teilmodule, Kuerzen, Erkennung
Je Fall: {note, pages | items, meta, detect, head, catalog, module_texts, details, dumps, texts_dumps, details_dumps,
head_dumps}; dumps = kanonischer Text (`app.study_catalog.dumps`), den Swift byte-gleich liefern muss.

Aufruf im Projektordner: .venv/bin/python tools/gen-study-catalog-hildesheim-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402
from app import study_catalog_hildesheim as hi  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog-hildesheim"
NOTE = "erfunden; nur der Aufbau folgt den Studienordnungen (tools/gen-study-catalog-hildesheim-fixture.py)"

# --------------------------------------------------------------------------------------------------------------------
# Fall 1: Verkuendungsblatt, Text wie pypdf
# --------------------------------------------------------------------------------------------------------------------


def vb_head(page: int) -> str:
    return f"Verkündungsblatt der Universität Hildesheim - Heft 999 - Nr. 03 / 2031 (14.02.2031) - Seite {page} - "


VB_PAGES = [
    "\n".join([
        vb_head(40),
        "Studienordnung inklusive Modulhandbuch für den Bachelor- ",
        "Studiengang Garten- und Teichpädagogik im Fachbereich 9 – Garten- und ",
        "Landschaftswissenschaften ",
        "Auf der Grundlage des Beispielgesetzes hat der Fachbereich 9 am 03.02.2031 die folgende ",
        "Studienordnung für den Bachelor -Studiengang Garten - und Teichpädagogik beschlossen. ",
        "§ 1 ",
        "Aufgaben der Studienordnung ",
        "(1) Die Studienordnung legt den Inhalt und den Aufbau des Studiums fest. ",
        "§ 2 ",
        "Inkrafttreten ",
        "(1) Diese Studienordnung gilt erstmals für Studierende, die ihr Studium im Bachelor- ",
        "Studiengang Garten- und Teichpädagogik zum Wintersemester 20 31/32 aufgenommen haben. ",
    ]),
    "\n".join([
        vb_head(41),
        "Anlage 1 Überblick über die Module des Studiengangs: ",
        "Modul SWS LP ",
        "1 Einstieg in den Garten 6 6 ",
        "2 Gartenpädagogik II – Handeln in Gemeinschaftsgärten 8 15 ",
        "3 Teichrecht I 4 9 ",
        "4 Abschlussmodul 15 ",
        "Gesamtzahl der Leistungspunkte 45 ",
        "Anlage 2 Studienablaufplan ",
        "Modul 1. Semester (WiSe) 2. Semester (SoSe) 3. Semester (WiSe) ",
        "1: Einstieg in den Garten 1-2 Semester Dauer, Beginn im WS ",
        "3: Teichrecht I 2 Semester Dauer; TM 1 im SoSe, TM 2 im WiSe ",
    ]),
    "\n".join([
        vb_head(42),
        "Anlage 3 Modulhandbuch ",
        "Bezeichnung  Modul 1: Einstieg in den Garten ",
        "Kompetenzen und Lernziele  Die Studierenden kennen die Wege durch den Mustergarten und ",
        "können ein Beet beschreiben. ",
        "Lerninhalte  Das erste Jahr beginnt im Gewächshaus. Dort werden die ",
        "Grundlagen des Gießens erklärt. ",
        "Das Modul gliedert sich in drei Teilmodule: ",
        "TM 1: Grundlagen des Gießens (Seminar; 2 SWS; ",
        "2 LP (WiSe)) ",
        "TM 2: Beeterkundung (Tutorium; 2 SWS; 2 LP (WiSe)) ",
        "TM 3: Werkzeuge der Gartenarbeit (Seminar; 2 SWS; 2 ",
        "LP (WiSe, SoSe)) ",
        "Leistungspunkte  6 LP ",
        "Semesterwochenstunden  6 SWS ",
        "Studienleistungen  Aktive Teilnahme an den Veranstaltungen, die ggf. durch ein ",
        "Gartentagebuch ergänzt wird. ",
        "Lehr- und Lernformen  Übung, Seminar, Tutorium ",
        "Verwendbarkeit des Moduls  Bachelorstudiengang Garten- und Teichpädagogik ",
        "Prüfungsleistungen  Modulprüfung (unbenotet): Beetbericht und Referat ",
        "Arbeitsaufwand (Workload)  180 Stunden (90 Stunden Präsenzstudium, 90 Stunden Selbststudium) ",
        "Empfohlenes Fachsemester  1. Semester ",
        "Voraussetzung für die ",
        "Teilnahme am Modul ",
        "keine ",
        "Voraussetzung für die ",
        "Zulassung zur Prüfung ",
        "keine ",
        "Moduldauer  1-2 Semester ",
        "Häufigkeit des Angebots  Teilmodul 1 und Teilmodul 2 werden jeweils im Wintersemester, ",
    ]),
    "\n".join([
        vb_head(43),
        "Teilmodul 3 im Sommers emester und Wintersemester angeboten. ",
        "Zuständige Ständige ",
        "Prüfungskommission ",
        "Ständige Prüfungskommission für den Bachelor -Studiengang ",
        "Garten- und Teichpädagogik ",
        "Modulverantwortliche  Siehe Liste auf der Webseite des Mustergartens ",
        "Bezeichnung  Modul 2: Gartenpädagogik II – Handeln in ",
        "Gemeinschaftsgärten ",
        "Kompetenzen und Lernziele  Die Studierenden besitzen Kenntnisse über das gemeinsame ",
        "Gärtnern. ",
        "Lerninhalte  Kompost und Mulch ",
        "Leistungspunkte  15 LP ",
        "Semesterwochenstunden  8 SWS ",
        "Studienleistungen  Aktive Mitarbeit, Präsentation ",
        "Lehr- und Lernformen  Übungen, Seminare ",
        "Verwendbarkeit des Moduls  Bachelorstudiengang Garten- und Teichpädagogik ",
        "Prüfungsleistung  Modulprüfung: Hausarbeit oder mündliche Prüfung ",
        "Arbeitsaufwand (Workload)  450 Stunden (120 Stunden Präsenzstudium, 330 Stunden ",
        "Selbststudium) ",
        "Empfohlenes Fachsemester  4. und 5. Semester ",
        "Voraussetzung für die ",
        "Teilnahme am Modul ",
        "Erfolgreicher Abschluss des Moduls 1 ",
        "Voraussetzung für die ",
        "Zulassung zur Prüfung ",
        "Die Modulprüfung kann erst nach der Belegung von 4 ",
        "Veranstaltungen in diesem Modul erfolgen. ",
        "Moduldauer  2 Semester ",
        "Häufigkeit des Angebots  Veranstaltungen zu den Inhalten des Moduls werden ",
        "jedes Semester angeboten. ",
        "Zuständige Ständige ",
        "Prüfungskommission ",
        "Ständige Prüfungskommission für den Bachelor -Studiengang ",
        "Garten- und Teichpädagogik ",
        "Modulverantwortliche  Siehe Liste auf der Webseite des Mustergartens ",
    ]),
    "\n".join([
        vb_head(44),
        "Bezeichnung  Modul 3: Teichrecht I ",
        "Kompetenzen und Lernziele  Die Studierenden verstehen die Regeln am Teich. ",
        "Lerninhalte  Das Modul gliedert sich in zwei Teilmodule: ",
        "TM 1: Einführung in das Teichrecht (Vorlesung; 2 SWS ; 4,5 LP (SoSe)) ",
        "(Grundbegriffe und Uferregeln) ",
        "TM 2: Froschrecht „Quaken und Schweigen“ (Vorlesung, Seminar; 2 SWS; 4,5LP ",
        "(WiSe) ",
        "Leistungspunkte  9 LP ",
        "Semesterwochenstunden  4 SWS ",
        "Studienleistungen  Aktive Teilnahme ",
        "Lehr- und Lernformen  Vorlesung ",
        "Verwendbarkeit des Moduls  Bachelorstudiengang Garten- und Teichpädagogik ",
        "Prüfungsleistungen  Teilmodulprüfungen: Klausur in TM 1 und in TM 2 ",
        "Begründung: Die Inhalte der beiden Teilmodule unterscheiden sich ",
        "erheblich. ",
        "Die Modulnote errechnet sich aus dem Mittel der beiden Teilmodulnoten. ",
        "Arbeitsaufwand (Workload)  270 Stunden (60 Stunden Präsenzstudium, 210 Stunden ",
        "Selbststudium) ",
        "Empfohlene Fachsemester  2. und 3. Semester ",
        "Voraussetzung für die ",
        "Teilnahme am Modul ",
        "Das Modul kann frühestens im 2. Fachsemester belegt werden. ",
        "Voraussetzungen für die ",
        "Zulassung zu den Prüfungen ",
        "Keine ",
        "Moduldauer  zwei Semester ",
        "Häufigkeit des Angebots  siehe Teilmodule ",
        "Zuständige Ständige ",
        "Prüfungskommission ",
        "Ständige Prüfungskommission für den Bachelor-Studiengang ",
        "Garten- und Teichpädagogik ",
        "Modulverantwortliche  Siehe Liste auf der Webseite des Mustergartens ",
        "Bezeichnung  Modul 4: Abschlussmodul ",
        "Kompetenzen und Lernziele  Die Studierenden bearbeiten ein selbst gewähltes Gartenthema. ",
        "Lerninhalte  je nach Themenwahl ",
        "Leistungspunkte  12 LP für Bachelorarbeit (schriftliche Arbeit und Kolloquium) ",
        "3 LP für Begleitung „Schreiben im Grünen“ ",
        "Semesterwochenstunden  Keine ",
        "Studienleistung  Keine ",
        "Lehr- und Lernformen  Individuelle Begleitung, Selbststudium ",
        "Verwendbarkeit des Moduls  Bachelorstudiengang Garten- und Teichpädagogik ",
        "Prüfungsleistungen  Modulprüfung: Bachelorarbeit und Kolloquium ",
        "Arbeitsaufwand (Workload)  450 Stunden (450 Stunden Selbststudium) ",
        "Empfohlenes Fachsemester  6. Fachsemester ",
    ]),
    "\n".join([
        vb_head(45),
        "Voraussetzung für die ",
        "Teilnahme am Modul ",
        "in Prüfungsordnung geregelt; Abschluss der Module 1 und 3 (Modul 3 mit Klausur) ",
        "Voraussetzung für die ",
        "Zulassung zur Prüfung ",
        "in Prüfungsordnung geregelt ",
        "Moduldauer  1 Semester ",
        "Häufigkeit des Angebots  ständig (je nach Absprache) ",
        "Zuständige Ständige ",
        "Prüfungskommission ",
        "Ständige Prüfungskommission für den Bachelor -Studiengang ",
        "Garten- und Teichpädagogik ",
        "Modulverantwortliche  Siehe Liste auf der Webseite des Mustergartens ",
        "Anlage 4 Praktikumsordnung ",
        "Bezeichnung der Praktikumsstelle und Dauer nach Absprache. ",
        "Leistungspunkte  99 LP ",
    ]),
]
VB_META = {"university": "hildesheim", "program": "Garten- und Teichpädagogik", "degree": "B.A.", "po": "2031",
           "code": "link-0123456789ab", "catalog_term": "WS 2031/32", "regular_semesters": 6, "total_lp": 45,
           "source": {"url": "https://example.org/sto-garten.pdf", "fetched_at": "2031-03-01T08:00:00Z",
                      "sha256": "ab" * 32}}

# --------------------------------------------------------------------------------------------------------------------
# Fall 2: Lesefassung als Textstuecke mit Lage (Feldname links bei x = 74, Wert rechts bei x = 221.5)
# --------------------------------------------------------------------------------------------------------------------

LEFT, RIGHT, PITCH = 74.0, 221.5, 13.4


class Sheet:
    """Eine Seite: Zeilen von oben nach unten; `items` in der Reihenfolge, in der PDFKit solche Tabellen oft liefert
    (je Block erst alle Feldnamen, dann alle Werte)"""

    def __init__(self) -> None:
        self.y = 40.0
        self.items: list[list] = []

    def text(self, *lines: str, x: float = 71.0) -> None:
        for l in lines:
            self.items.append([x, round(self.y, 1), l])
            self.y += PITCH

    def table(self, *rows: tuple) -> None:
        """rows: (Feldname, Wert) mit Zeilen als Listen oder Text; Feldnamen zuerst, dann Werte"""
        left: list[list] = []
        right: list[list] = []
        for label, value in rows:
            ls = [label] if isinstance(label, str) else list(label)
            vs = [value] if isinstance(value, str) else list(value)
            for k, l in enumerate(ls):
                if l:
                    left.append([LEFT, round(self.y + k * PITCH, 1), l])
            for k, v in enumerate(vs):
                if v:
                    # Blocksatz: PDFKit trennt weit auseinanderstehende Woerter in eigene Stuecke
                    if v.startswith("Ständige Prüfungskommission für"):
                        a, b = v.split(" für", 1)
                        right.append([RIGHT - 2.0, round(self.y + k * PITCH + 0.1, 1), a])
                        right.append([RIGHT + 160.0, round(self.y + k * PITCH, 1), "für" + b])
                    else:
                        right.append([RIGHT, round(self.y + k * PITCH, 1), v])
            self.y += max(len(ls), len(vs)) * PITCH + 6.0
        self.items.extend(left + right)


def lesefassung_items() -> list[list[list]]:
    kopf = ("Lesefassung", "(Stand 02.03.2032)")
    board = ("Zuständige Ständige", "Prüfungskommission:")
    board_value = ("Ständige Prüfungskommission für den Master-Studiengang Wald-", "und Wiesenpädagogik")
    usage = ("Verwendbarkeit des Moduls", "Masterstudiengang Wald- und Wiesenpädagogik")
    p1 = Sheet()
    p1.text(*kopf, x=300.0)
    p1.text("Fassung: Verkündungsblatt Heft 998 Nr. 01 / 2031 vom 05.01.2031, geändert mit",
            "Verkündungsblatt Heft 999 Nr. 02 / 2032 vom 02.03.2032",
            "Neufassung der Studienordnung inklusive Modulhandbuch für den",
            "Master-Studiengang „Wald- und",
            "Wiesenpädagogik“ im Fachbereich 9 – Garten- und Landschaftswissenschaften",
            "Präambel",
            "Der Studiengang schließt mit dem Grad Master of Arts (M.A.) ab.",
            "§ 4",
            "(1) Sie gilt erstmals für Studierende, die ihr Studium im Master-Studiengang Wald- und",
            "Wiesenpädagogik zum Sommersemester 2031",
            "aufgenommen haben.")
    p2 = Sheet()
    p2.text(*kopf, x=300.0)
    p2.text("Anlage 1", "Überblick über die Module des Studiengangs:", "Modul Modulverantw. SWS LP Seite",
            "1 Waldeingangsphase Muster/ Beispiel 6 6", "2 Wiesenkunde Muster 4 6", "3 Pilze Beispiel 4 9", "4 Moose Muster 8 12",
            "Gesamtzahl der Leistungspunkte 33", "Anlage 2 Studienablaufplan",
            "Modul 1. Semester 2. Semester", "(SoSe) (WiSe)", "1: Waldeingangsphase Beginn im SoSe")
    p3 = Sheet()
    p3.text(*kopf, x=300.0)
    p3.text("Anlage Modulhandbuch")
    p3.table(
        ("Bezeichnung", "Modul 1: Waldeingangsphase"),
        ("Kompetenzen und Lernziele", ["Die Studierenden kennen den Musterwald und", "seine Wege."]),
        ("Lerninhalte", ["Der Wald wird vorgestellt.", "TM 1: Grundlagen des Waldgangs (2 SWS / 2 LP)", "TM 2: Wegekunde (2 SWS / 2 LP)",
                         "TM 3: : Rindenlehre (Übung; 2 SWS; 2 LP) (SoSe)"]),
        ("Leistungspunkte", "6 LP"),
        ("Semesterwochenstunden", "6 SWS"),
        ("Studienleistungen", "Aktive Teilnahme, Präsentation"),
        ("Lehr- und Lernformen", "Übung, Seminar"),
        usage,
        ("Prüfungsleistungen", "Modulprüfung ( unbenotet): Waldbericht"),
        ("Arbeitsaufwand (Workload)", "180 Stunden (90 Stunden Präsenzstudium, 90 Stunden Selbststudium)"),
        ("Empfohlenes Fachsemester", "1. Semester"),
        (["Voraussetzung für die", "Teilnahme am Modul"], "Keine"),
        (["Voraussetzung für die", "Zulassung zur Prüfung"], "keine"),
        ("Moduldauer", "Ein oder zwei Semester"),
        ("Häufigkeit des Angebots", ["TM 1 und TM 2 jeweils im Sommersemester", "TM 3 jedes Semester"]),
        (board, board_value),
        ("Modulverantwortliche", "Muster, Beispiel"),
        ("Bezeichnung", "Modul 2: Wiesenkunde"),
        ("Kompetenzen und Lernziele", "Die Studierenden kennen die Gräser der Musterwiese."),
        ("Lerninhalte", ["1) Einführung in die Wiese", "2) Nach Wahl", "- Halme", "- Blüten"]),
        ("Leistungspunkte", "6 (TM 1: 2 SWS / 4 LP; TM 2: 2 SWS / 2 LP)"),
        ("Semesterwochenstunden", "4"),
        ("Studienleistung", ""),
        ("Lehr- und Lernformen", "Vorlesung"),
        usage,
        ("Prüfungsleistungen", "Modulprüfung: Klausur zur Vorlesung „Einführung in die Wiese“"),
        ("Arbeitsaufwand (workload)", ["180 Stunden (60 Stunden Präsenzstudium, 120 Stunden", "Selbststudium)"]),
        ("Semester", "1. und 2. Semester"),
    )
    p4 = Sheet()
    p4.text(*kopf, x=300.0)
    p4.table(
        (["Voraussetzungen für die", "Teilnahme am Modul"], "Keine"),
        (["Voraussetzungen für die", "Zulassung zur Prüfung"], ["Vorlesung „Einführung in die Wiese“ muss erfolgreich", "absolviert sein"]),
        ("Häufigkeit", "Jedes Semester"),
        ("Moduldauer", "Ein oder zwei Semester"),
        (board, board_value),
        ("Modulverantwortliche", "Muster"),
        ("Bezeichnung", ["Modul 3: Pilze und Flechten III – Sammeln,", "Bestimmen und Bewahren"]),
        ("Kompetenzen und Lernziele", "Die Studierenden bestimmen Pilze sicher."),
        ("Lerninhalte", ["Das Modul gliedert sich in zwei Teilmodule:",
                         "TM1: Pilzkunde oder Flechtenkunde (Bestimmung,", "Lagerung, Schutz) (2 SWS / 3 + 3 LP)",
                         "TM 2: Vertiefung freier Wahl (Seminar; 2 SWS 3 LP (WS)"]),
        ("Leistungspunkte", "9 LP"),
        ("Semesterwochenstunden", "4 SWS"),
        ("Studienleistungen", "Aktive Mitarbeit"),
        ("Lehr- und Lernformen", "Vorlesung mit Übungen"),
        usage,
        ("Prüfungsleistung", "Modulprüfung: Klausur"),
        ("Arbeitsaufwand (Workload)", ["270 Stunden (60 Stunden Präsenzstudium, 210 Stunden", "Selbststudium)"]),
        ("Empfolenes Fachsemester", "3. − 4. Semester"),
        (["Voraussetzung für die", "Teilnahme am Modul"], "Absolvierung des Moduls Wiesenkunde (Modul 2)"),
        (["Voraussetzung für die", "Zulassung zur Prüfung"], ["Erfolgreicher Abschluss der Module Waldeingangsphase und",
                                                               "Wiesenkunde (Modul 1, Modul 2)"]),
        ("Moduldauer", "zwei Semester"),
        ("Häufigkeit des Angebots", "nach Aushang"),
        (board, board_value),
        ("Modulverantwortliche", "Beispiel"),
        ("Bezeichnung", "Modul 4: Moose"),
        ("Kompetenzen und Lernziele", "Die Studierenden unterscheiden Moose."),
        ("Lerninhalte", "Konkrete Inhalte entsprechend der Wahl der Veranstaltungen"),
        ("Leistungspunkte", "12"),
        ("Semesterwochenstunden", "8 (vier Teilmodule à 2 SWS und 3 LP)"),
        ("Studienleistungen", "Aktive Mitarbeit, Präsentation, schriftliche Ausarbeitungen"),
        ("Lehr- und Lernformen", "Vorlesung, Seminar, Übung"),
        usage,
        ("Prüfungsleistungen", ["Teilmodulprüfungen (unbenotet): Präsentation, schriftliche", "Ausarbeitung etc.",
                                "Begründung: Das Modul kann nur in mehreren Teilen", "geprüft werden."]),
        ("Arbeitsaufwand (Workload)", "360 Stunden (Aufteilung ist variabel)"),
        ("Empfohlene Fachsemester", "Erstes bis drittes Semester"),
        (["Voraussetzung für die", "Teilnahme am Modul"], "keine"),
        (["Voraussetzung für die", "Zulassung zu den Prüfungen"], "Ggf. lehrveranstaltungsspezifisch"),
        ("Moduldauer", "Zwei Semester"),
        ("Häufigkeit des Angebots", "In jedem Wintersemester"),
        (board, board_value),
        ("Modulverantwortliche", ["Ständige Prüfungskommission für den Masterstudiengang Wald-", "und Wiesenpädagogik"]),
    )
    return [p1.items, p2.items, p3.items, p4.items]


LF_META = {"university": "hildesheim", "code": "link-ba9876543210",
           "source": {"url": "https://example.org/lesefassung-wald.pdf", "fetched_at": None, "sha256": None}}

# --------------------------------------------------------------------------------------------------------------------
# Fall 3: roher PDFKit-Text (Feldnamen-Spalte vor den Werten)
# --------------------------------------------------------------------------------------------------------------------

RAW_PAGES = [
    "\n".join([
        "Verkündungsblatt der Universität Hildesheim - Heft 999 - Nr. 03 / 2031 (14.02.2031) - Seite 60 -",
        "Studienordnung inklusive Modulhandbuch für den Bachelor-",
        "Studiengang Beetkunde im Fachbereich 9 – Garten- und",
        "Landschaftswissenschaften",
        "Gesamtzahl der Leistungspunkte 21",
    ]),
    "\n".join([
        "Verkündungsblatt der Universität Hildesheim - Heft 999 - Nr. 03 / 2031 (14.02.2031) - Seite 61 -",
        "Anlage 3 Modulhandbuch",
        "Bezeichnung Modul 1: Hochbeet",
        "Kompetenzen und Lernziele Die Studierenden bauen ein Hochbeet.",
        "Lerninhalte TM 1: Holz (Seminar; 2 SWS; 3 LP (WiSe))",
        "TM 2: Erde (Seminar; 2 SWS; 3 LP (WiSe))",
        "Leistungspunkte 6 LP",
        "Semesterwochenstunden 4 SWS",
        "Studienleistungen Aktive Teilnahme",
        "Prüfungsleistungen Modulprüfung: Baubericht",
        "Arbeitsaufwand (Workload) 180 Stunden (60 Stunden Präsenzstudium, 120 Stunden",
        "Selbststudium)",
        "Empfohlenes Fachsemester 1. Semester",
        "Voraussetzung für die",
        "Teilnahme am Modul",
        "Voraussetzung für die",
        "Zulassung zur Prüfung",
        "keine",
        "keine",
        "Moduldauer 2 Semester",
        "Häufigkeit des Angebots Zuständige Ständige",
        "Prüfungskommission",
        "Modulverantwortliche TM 1 und TM 2 werden im Wintersemester angeboten",
        "Ständige Prüfungskommission für den Bachelor-Studiengang",
        "Beetkunde",
        "Siehe Liste auf der Webseite",
        "Bezeichnung Kompetenzen und Lernziele Lerninhalte Modul 2: Kräuterspirale – Planen und",
        "Die Studierenden planen eine Kräuterspirale.",
        "Steine und Kräuter",
        "Leistungspunkte 6",
        "Semesterwochenstunden 4",
        "Studienleistungen Aktive Mitarbeit",
        "Prüfungsleistung Arbeitsaufwand (Workload) Modulprüfung: Hausarbeit",
        "180 Stunden (60 Stunden Präsenzstudium, 120 Stunden",
        "Selbststudium)",
        "2. und 3. Semester",
        "keine",
        "Empfohlenes Fachsemester Voraussetzungen für die",
        "Teilnahme am Modul",
        "Moduldauer Häufigkeit des Angebots Keine",
        "Bezeichnung Modul 3: Teichbau",
        "Kompetenzen und Lernziele Lerninhalte Die Studierenden legen einen Teich an.",
        "Folie und Wasser",
        "Leistungspunkte Semesterwochenstunden 4",
        "9 (TM 1: 2 SWS / 4,5 LP; TM 2: 2 SWS / 4,5 LP)",
        "Prüfungsleistungen Modulprüfung: Klausur",
        "Empfohlenes Fachsemester 5.",
    ]),
]
RAW_META = {"university": "hildesheim", "code": "link-roh", "po": "eigener Link", "catalog_term": "SS 2031",
            "source": {"url": "https://example.org/roh.pdf", "fetched_at": None, "sha256": None}}

# --------------------------------------------------------------------------------------------------------------------
# Einzelfaelle
# --------------------------------------------------------------------------------------------------------------------

SEMESTER_CASES = ["1. Semester", "1.-3. Semester", "1. und 2. Semester", "1./2. Semester", "5. – 6. Semester", "3. − 4. Semester",
                  "6. Fachsemester", "1.und 2. Semester", "Erstes bis drittes Semester", "zweites Semester", "2 Semester",
                  "Ein oder zwei Semester", "Praktikum wird nach dem 2. oder nach dem 4. Semester empfohlen)", "5.", "",
                  "1. Semester (empfohlen)", "10. Semester"]
SEASON_CASES = ["", "jedes Semester", "Jedes Semester", "In jedem Sommersemester", "Veranstaltungen werden jedes Wintersemester angeboten",
                "TM1, TM2 im WS, TM 3, TM 4 im SoSe", "Begleitseminare werden im WiSe angeboten", "im S oSe und im W iSe",
                "ständig (je nach Absprache)", "Angebot im SS", "Wasserspiele im Hof", "jedem Semester ein Angebot",
                "die übrigen Veranstaltungen im Sommer- oder im Wintersemester"]
LP_CASES = [[], ["6 LP"], ["6"], ["4,5 LP"], ["6 (TM 1: 2 SWS / 4 LP; TM 2: 2 SWS / 2 LP)"], ["12 LP für Arbeit", "3 LP für Begleitung"],
            ["12 LP für Arbeit (schriftlich und", "Kolloquium)", "2,5 LP für Begleitung"], ["je nach Wahl"], ["6 LP und mehr"], ["18LP"]]
PARTS_CASES = [
    ["Vorweg.", "TM 1: Eins (Seminar; 2 SWS; 2 LP (WiSe))", "TM 2: Zwei (Tutorium; 2 SWS; 2 LP (WiSe, SoSe))"],
    ["TM 1: Eins (2 SWS / 2 LP)", "TM 2: : Zwei (2 SWS / 4,5 LP)", "TM3: Drei (Vorlesung; 2 SWS 3 LP (WS)"],
    ["TM 1: Eins (Seminar; 2 SWS; 3 LP) (WS)", "TM 2: Zwei „mit Zusatz“ (2 SWS; 3 LP) (SoSe)", "(Hinweis in Klammern)"],
    ["TM 1: Eins oder Anderes (Erstens, Zweitens,", "Drittens) (Vorlesung; 2 SWS; 6LP (SoSe, WiSe))",
     "TM 2: Gebiet freier Wahl (Vorlesung, Seminar; 2 SWS; 3 LP (SoSe, WiSe))"],
    ["TM 1: Eins (2 SWS / 3 + 3 LP)", "(Nachsatz zu Eins)", "TM 2: Ohne Angabe", "TM 3: Drei (2 SWS / 1,5 LP) (nur nach Anmeldung)"],
    ["TM 1: Nach Wahl:", "- A", "- B", "(Vorlesung; 2 SWS; 2 LP (Wintersemester und Sommersemester))"],
    ["Klausur am Ende von TM 4", "Leistung in TM 1 (Konzept) ist Voraussetzung"],
    ["TM 1: " + "Sehr langer Titel " * 14 + "(2 SWS / 2 LP)"],
    [],
]
CLIP_CASES = [["", 500], [" ; , ", 500], ["Aktive Mitarbeit, ", 500], ["x" * 500, 500], ["Wort " * 120, 500], ["y" * 501, 500],
              ["Ähre und Öl " * 30, 60]]
DETECT_CASES = [
    {"name": "modkat", "pages": ["Modulkatalog\nfür den Studiengang\nTechnische Informatik - Bachelor\nim Wintersemester 2025/2026",
                                 "Inhaltsverzeichnis\nProgrammieren ........ 3"]},
    {"name": "titel ohne modultabelle", "pages": ["Studienordnung inklusive Modulhandbuch für den Bachelor-Studiengang Beetkunde im Fachbereich 9",
                                                  "Anlage 3 Modulhandbuch\nModultitel Hochbeet\nModulnummer 1"]},
    {"name": "modultabelle ohne titel", "pages": ["Prüfungsordnung für den Bachelor-Studiengang Beetkunde", "Bezeichnung Modul 1: Hochbeet"]},
    {"name": "leer", "pages": []},
    {"name": "treffer in einer zeile", "pages": ["Lesefassung\n(Stand 01.01.2031)\nNeufassung der Studienordnung inklusive\nModulhandbuch für den Bachelorstudiengang Beet - und\nWegekunde im Fachbereich 9\nAbschluss: Bachelor of Science",
                                                 "Bezeichnung: Modul 12 : Hochbeet"]},
]


# --------------------------------------------------------------------------------------------------------------------

def _json(v) -> bytes:
    return (json.dumps(v, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def case(note: str, pages: list[str], meta: dict, items=None) -> dict:
    catalog, texts = hi.parse_hildesheim_sto(pages, meta)
    errors = sc.validate(catalog)
    assert not errors, errors
    head = hi.hildesheim_sto_head(pages)
    details = hi.hildesheim_sto_details(pages)
    out = {"note": NOTE + "; " + note}
    if items is not None:
        out["items"] = items
    out.update({"pages": pages, "meta": meta, "detect": hi.is_hildesheim_sto(pages), "head": head, "catalog": catalog,
                "module_texts": texts, "details": details, "dumps": sc.dumps(catalog), "texts_dumps": sc.dumps(texts),
                "details_dumps": sc.dumps(details), "head_dumps": sc.dumps(head)})
    return out


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    files["verkuendungsblatt.json"] = _json(case("Seitentexte wie pypdf", VB_PAGES, VB_META))
    items = lesefassung_items()
    files["lesefassung.json"] = _json(case("Textstuecke mit Lage [x, y, text] -> row_pages -> pages", hi.row_pages(items), LF_META, items))
    files["pdfkit-roh.json"] = _json(case("roher PDFKit-Text, Feldnamen und Werte vermischt", RAW_PAGES, RAW_META))
    files["werte.json"] = _json({
        "note": NOTE,
        "semester": [{"text": t, "semester": hi._semester(t)} for t in SEMESTER_CASES],
        "season": [{"text": t, "turnus": hi._season(t)} for t in SEASON_CASES],
        "lp": [{"lines": l, "lp": hi._lp(l)} for l in LP_CASES],
        "parts": [{"lines": l, "parts": hi._parts(l), "dumps": sc.dumps(hi._parts(l))} for l in PARTS_CASES],
        "clip": [{"text": t, "limit": n, "clip": hi._clip(t, n)} for t, n in CLIP_CASES],
        "detect": [dict(c, detect=hi.is_hildesheim_sto(c["pages"]), head_dumps=sc.dumps(hi.hildesheim_sto_head(c["pages"])))
                   for c in DETECT_CASES],
    })
    return files


def main() -> int:
    files = {str(OUT / n): b for n, b in build().items()}
    if "--check" in sys.argv:
        stale = [n for n, b in files.items() if not Path(n).exists() or Path(n).read_bytes() != b]
        if stale:
            print("Fixture veraltet: " + ", ".join(stale) + " (tools/gen-study-catalog-hildesheim-fixture.py ausfuehren)")
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, b in files.items():
        Path(n).write_bytes(b)
    print(f"{len(files)} Dateien -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
