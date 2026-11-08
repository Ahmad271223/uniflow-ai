"""Fixture des Modulkatalog-Parsers (docs/STUDIENVERLAUF-2026-11-04.md): packages/shared-contracts/fixtures/study-catalog/

Schreibt eine kleine ERFUNDENE PDF im Aufbau der LUH-Modulkataloge (modkat: Titelseite, Inhaltsverzeichnis mit
Punktfuehrern, Bereichsseiten "Information zum Kompetenzbereich", Modulseiten mit Kopf- und Fusszeile, beide
Varianten der Felder: aeltere Form mit "Frequenz der Lehrveranstaltung", neuere mit "Modultyp", "Empfohlenes
Fachsemester" und Titel+"Sprache" in einer Zeile, umbrochener Titel, Modul ueber zwei Seiten). Kein Text aus einem
echten Katalog (Urheberrecht): alle Module, Texte und Namen sind erfunden.

Dazu die erwarteten Ergebnisse, die Python (app/study_catalog.py) und der Swift-Kern (UniFlowCore/StudyCatalog)
gleich liefern muessen:
  modkat-sample.pdf     die PDF (Helvetica, WinAnsiEncoding, eine Textzeile je Tm/Tj)
  pages.json            normalisierte Zeilen je Seite (pypdf hier, PDFKit am Geraet)
  expected.json         {meta, key, catalog, module_texts, dumps}: Ergebnis des Parsers, dumps = kanonischer Text
  validator-cases.json  Faelle fuer den Validator {name, catalog, errors}
  registry-cases.json   QIS `abschluss` -> Vorschlag aus dem gemischten Register (study-sources-all.json); Semester und URLs
Dazu packages/shared-contracts/study-sources-all.json (study-sources.json + study-sources-luh.json, `merge_luh_registry`)
und dessen Kopie im Kern (StudySourcesData.swift).
  text-cases.json       Zeilen-Normalisierung und ids (slug)
  modkat-full-sample.pdf, pages-full.json, expected-full.json
                        dieselben drei fuer die neuere Form (modkat-full, ab WS 2026/27): Inhaltsverzeichnis mit
                        ". . . ."-Fuehrern, Kapitel "1. Kompetenzbereiche" mit Bereichstabellen "Modul LP SWS ...",
                        Kapitel "2. Details der Semesterangebote" mit den Modulen alphabetisch und neuen Ueberschriften
                        ("regelhaftes Lehrangebot", "Gewählte Prüfungsform", "LP (ECTS)", "Inhalt und Stoffplan")
  plan-sample.pdf       erfundener Studienverlaufsplan im Aufbau der FEI-Plaene (eine gedrehte Seite /Rotate 90,
                        Semester als Zeilen "1." + "SEMESTER", Kaesten mit Titel, Lehrperson und "2V+2Ü | 5 ECTS",
                        Summen rechts, Legende und Fussnote "*"; Kaesten nicht in Lesereihenfolge im Inhalt)
  plan-items.json       Textstuecke mit Lage je Seite (pypdf, `pdf_items`)
  plan-expected.json    {plan, plan_dumps, source, catalog_dumps, unmatched, merge_cases}: gelesener Plan und der mit
                        dem Katalog aus expected.json gemischte Katalog (`semester` laut Plan, `plan_slots`), dazu
                        kleine Mischfaelle (Praefix mehrerer Module, Nebenfach-Gruppe, Tippfehler, Gleichstand)
Aufruf im Projektordner: .venv/bin/python tools/gen-study-catalog-fixture.py [--check]
"""
from __future__ import annotations

import copy
import hashlib
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog"
HEADER = "Modulkatalog Technische Informatik - Bachelor (Wintersemester 2025/2026) Stand: 01.09.2025"

# --------------------------------------------------------------------------------------------------------------------
# Seiten (erfunden)
# --------------------------------------------------------------------------------------------------------------------

TITLE = ["Modulkatalog", "für den Studiengang", "Technische Informatik - Bachelor", "im Wintersemester 2025/2026",
         "Fakultät Elektrotechnik und Informatik", "Leibniz Universität Hannover", "Stand: 01.09.2025"]


def toc_line(title: str, page: int) -> str:
    return f"{title} " + "." * max(8, 70 - len(title)) + f" {page}"


TOC = [
    toc_line("1.1. Grundlagen der Beispielinformatik", 3),
    toc_line("Beispielprogrammierung I", 4),
    toc_line("Beispielprogrammierung II", 6),
    toc_line("Beispielsysteme und Netze", 7),
    toc_line("1.2. Vertiefung Beispiel", 8),
    toc_line("Proseminar Beispielthemen", 9),
    "Studium Beispiel Angebote anderer Fakultäten",
    toc_line("und Einrichtungen", 10),
    toc_line("1.3. Bachelorarbeit", 11),
    toc_line("Bachelorarbeit", 12),
]


def area(number: str, name: str, english: str, info: str) -> list[str]:
    return [HEADER, f"{number} {name}", f"Englischer Titel: {english}", f"Information zum Kompetenzbereich: {info}"]


MOD_PROG1_A = [
    HEADER, "Beispielprogrammierung I", "Example Programming I",
    "Sprache", "deutsch",
    "Angebot im WS 2025/26", "Lehrveranstaltung und Prüfung",
    "Frequenz der Lehrveranstaltung", "jährlich Winter",
    "Prüfungsform", "Klausur (K) , 90 min",
    "Prüfungsbewertung", "benotet",
    "Studienleistung", "1, WiSe",
    "Studentische Arbeitsleistung", "Workload: Gesamt 150 h / Präsenz 56 h / Selbstlernen 94 h",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "2V + 2Ü 5 LP Muster Muster",
    "Schwerpunkt / Micro-Degree", "keine",
    "Bei Seminar: Semesterthema (dt/en)",
    "Organisationseinheit", "Fachgebiet Beispielsysteme",
    "Modulverantwortung", "Muster",
    "Webseite", "https://www.example.org/lehre/",
    "Qualifikationsziele",
    "Die Studierenden schreiben kleine Programme und erklären deren Ablauf.",
    "Sie zerlegen Aufgaben in Teilschritte.",
    "Inhalt",
    "Variablen, Schleifen und Funktionen",
    "Einfache Datenstrukturen",
    "Teilnahmevoraussetzungen und -empfehlungen",
    "keine",
    "Literatur",
    "A. Autorin: Erfundenes Lehrbuch, 1. Auflage.",
]
MOD_PROG1_B = [
    HEADER,
    "B. Autor: Noch ein Skript.",
    "Weitere Angaben",
    "Die Übung ist eine Studienleistung.",
]
MOD_PROG2 = [
    HEADER, "Beispielprogrammierung II", "Example Programming II",
    "Sprache", "Deutsch",
    "Angebot im WS 2025/26", "nur Prüfung",
    "Frequenz der Lehrveranstaltung", "jährlich Sommer",
    "Prüfungsform", "Klausur (K) , 120 min",
    "Prüfungsbewertung", "benotet",
    "Studienleistung", "keine",
    "Studentische Arbeitsleistung", "Workload: Gesamt 150 h / Präsenz 56 h / Selbstlernen 94 h",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "2V + 2Ü 5 LP Muster Muster",
    "Schwerpunkt / Micro-Degree", "keine",
    "Organisationseinheit", "Fachgebiet Beispielsysteme",
    "Modulverantwortung", "Muster",
    "Qualifikationsziele", "Die Studierenden entwerfen größere Programme.",
    "Inhalt", "Objekte, Module und Tests",
    "Teilnahmevoraussetzungen und -empfehlungen", "Empfohlen: Beispielprogrammierung I.",
    "Literatur", "C. Autor: Erfundene Programmierpraxis.",
]
MOD_SYS = [
    HEADER, "Beispielsysteme und Netze", "Example Systems and Networks",
    "Sprache", "englisch",
    "Angebot im WS 2025/26", "Lehrveranstaltung und Prüfung",
    "Frequenz der Lehrveranstaltung", "jedes Semester",
    "Prüfungsform", "mündl. Prüfung (MP)",
    "Prüfungsbewertung", "benotet",
    "Studienleistung", "2, WiSe/SoSe",
    "Studentische Arbeitsleistung", "150 h",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "2V + 1Ü + 1L 5 LP Probe",
    "Qualifikationsziele", "Die Studierenden beschreiben einfache Netze.",
    "Inhalt", "Schichten, Adressen, Rechner",
    "Teilnahmevoraussetzungen und -empfehlungen",
    "Kenntnisse aus Beispielprogrammierung II und Beispielprogrammierung I.",
    "Literatur",
    "Weitere Angaben", "Empfohlen für das 3. oder 4. Fachsemester.",
]
MOD_PROSEM = [
    HEADER, "Proseminar Beispielthemen Sprache", "Deutsch",
    "Modultitel englisch", "Proseminar Example Topics",
    "Kompetenzbereich", "Vertiefung Beispiel",
    "Angebot im WS 2025/26", "nur Prüfung",
    "Modultyp", "Wahl-Pflicht",
    "Prüfungsform", "Klausur (60 min)",
    "Prüfungsbewertung", "benotet",
    "Studienleistung", "Keine",
    "Empfohlenes Fachsemester", "4. Fachsemester",
    "Studentische Arbeitsleistung", "Gesamt: 150 Stunden; davon Präsenz: 42 Stunden",
    "Frequenz", "jährlich",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "3SE 5 LP Probe Probe",
    "Qualifikationsziele", "Die Studierenden halten einen kurzen Vortrag.",
    "Inhalt", "Wechselnde Themen",
    "Teilnahmevoraussetzungen und -empfehlungen", "Notwendig: Beispielsysteme und Netze",
    "Literatur", "Wird bekannt gegeben.",
]
MOD_GENERALE = [
    HEADER, "Studium Beispiel Angebote anderer Fakultäten", "und Einrichtungen",
    "General Studies Example", "Sprache", "deutsch",
    "Angebot im WS 2025/26", "Lehrveranstaltung und Prüfung",
    "Frequenz der Lehrveranstaltung", "unregelmäßig",
    "Prüfungsform", "wird noch angekündigt",
    "Prüfungsbewertung", "unbenotet",
    "Studienleistung", "1, : 1",
    "Studentische Arbeitsleistung", "Gesamt: 90 Stunden; davon Präsenz: 0 Stunden",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "3 LP N.N. N.N.",
    "Organisationseinheit Modulverantwortung", "Studiendekanat Beispiel",
    "Qualifikationsziele",
    "Inhalt", "Veranstaltungen anderer Fakultäten nach Wahl.",
    "Teilnahmevoraussetzungen und -empfehlungen", "keine",
    "Literatur",
]
MOD_THESIS = [
    HEADER, "Bachelorarbeit", "Bachelor Thesis",
    "Sprache", "deutsch",
    "Angebot im WS 2025/26", "Lehrveranstaltung und Prüfung",
    "Frequenz der Lehrveranstaltung", "jedes Semester",
    "Prüfungsform", "Bachelorarbeit",
    "Prüfungsbewertung", "benotet",
    "Studienleistung", "keine",
    "Studentische Arbeitsleistung", "Gesamt 450 h",
    "SWS LP (ECTS) Dozent/in Prüfer/in", "15 LP N.N.",
    "Qualifikationsziele", "Die Studierenden bearbeiten eine Aufgabe selbstständig.",
    "Inhalt", "Thema nach Absprache.",
    "Teilnahmevoraussetzungen und -empfehlungen", "Mindestens 120 LP.",
    "Literatur",
]

PAGES = [
    TITLE,
    TOC,
    area("1.1.", "Grundlagen der Beispielinformatik", "Fundamentals of Example Computing", "15 LP, Pflicht"),
    MOD_PROG1_A, MOD_PROG1_B, MOD_PROG2, MOD_SYS,
    area("1.2.", "Vertiefung Beispiel", "Advanced Example", "5 - 10 LP, Pflicht"),
    MOD_PROSEM, MOD_GENERALE,
    area("1.3.", "Bachelorarbeit", "Bachelor Thesis", "15 LP, Pflicht"),
    MOD_THESIS,
]

# --------------------------------------------------------------------------------------------------------------------
# Neuere Form (modkat-full, erfunden)
# --------------------------------------------------------------------------------------------------------------------

FULL_HEADER = "Modulkatalog Beispielinformatik - Bachelor (Wintersemester 2026/2027) Stand: 30.10.2026"


def full_toc(title: str, page: int) -> str:
    return title + " " + ". " * max(4, 30 - len(title) // 2) + str(page)


FULL_TABLE_HEAD = ["Modul LP SWS PL SL Frequenz", "der LV", "(i.d.R.)", "zuletzt angeboten Sprache Prüfer:in"]


def full_module(abbr, title, english, unit, offer, frequency, exam, grading, coursework, language, workload, sws, lp, goals,
                content, prereq, literature, notes) -> list[str]:
    return [FULL_HEADER, title, english, "Zuständigkeit", unit, "Einordnung und Belegungsmöglichkeit in Studiengänge",
            f"TIBSc25 - {abbr} - {title}", f"Angebot im WS 2026/27: {offer}", "Lehrveranstaltung zuletzt durchgeführt: WS 2026/27",
            "Prüfungs/Studienleistung zuletzt angeboten: WS 2026/27", "regelhaftes Lehrangebot", frequency,
            "Gewählte Prüfungsform", exam, "Prüfungsbewertungen", grading, "Studienleistung", coursework, "Sprache", language,
            "Studentische Arbeitsleistung", workload, "SWS", sws, "LP (ECTS)", lp, "Dozent/in", "Muster", "Prüfer/in", "Muster",
            "Schwerpunkt / Micro-Degree Bei Seminar: Semesterthema (dt/en)", "Prüfungsanmeldung",
            "Zeitraum für alle Prüfungsformen außer VbP", "Organisationseinheit", "Fachgebiet Muster", "Modulverantwortung",
            "Muster", "Webseite", "-", "Qualifikationsziele", *goals, "Inhalt und Stoffplan", *content,
            "Teilnahmevoraussetzungen und -empfehlungen", *prereq, "Literatur", *literature, "Weitere Angaben", *notes]


FULL_PAGES = [
    ["Fakultät für", "Elektrotechnik und Informatik", "Modulkatalog", "für den Studiengang", "Beispielinformatik - Bachelor",
     "im Wintersemester 2026/2027"],
    [FULL_HEADER, full_toc("1. Kompetenzbereiche", 3),
     full_toc("1.1. Grundlagen Muster", 3), full_toc("1.2. Vertiefung Muster", 4),
     full_toc("2. Details der Semesterangebote", 5), full_toc("Musterlabor", 5), full_toc("Musterlehre I", 6),
     full_toc("Musterlehre II", 7), full_toc("Proseminar Musterthemen", 8)],
    [FULL_HEADER, "1. Kompetenzbereiche", "1.1. Grundlagen Muster", "Englischer Titel: Example Basics",
     "Information zum Kompetenzbereich: 10 LP", *FULL_TABLE_HEAD,
     "Musterlehre I 5 2V + 2Ü K 1 jw WS 2026/27: LuP", "SS 2026: nP", "deutsch Muster",
     "Musterlehre II 5 2V + 2Ü K 0 js WS 2026/27: nP", "SS 2026: LuP", "deutsch Muster"],
    [FULL_HEADER, "1.2. Vertiefung Muster", "Englischer Titel: Example Advanced", "Information zum Kompetenzbereich: 5 - 10 LP",
     *FULL_TABLE_HEAD, "Proseminar", "5 3SE VbP (SE) 0 u WS 2026/27: LuP deutsch Probe", "Musterthemen",
     "Musterlabor 5 4L VbP (LÜ) 0 jw WS 2026/27: LuP deutsch Probe"],
    [FULL_HEADER, "2. Details der Semesterangebote"]
    + full_module("VM", "Musterlabor", "Example Lab", "Lehreinheit ET", "Lehrveranstaltung und Prüfung", "jedes Semester",
                  "Laborübung (LÜ)", "benotet", "keine", "deutsch", "150 h", "4L", "5 LP", ["Die Studierenden messen."],
                  ["Versuche im Labor"], ["Musterlehre I"], [], [])[1:],
    full_module("GM", "Musterlehre I", "Example Studies I", "Lehreinheit INF", "Lehrveranstaltung und Prüfung", "jährlich Winter",
                "Klausur (K)", "unbenotet", "1, WiSe", "deutsch", "Workload: Gesamt 150 h / Präsenz 56 h / Selbstlernen 94 h",
                "2V + 2Ü", "5 LP", ["Die Studierenden kennen Muster."], ["Muster und Beispiele", "Kleine Aufgaben"], ["keine"],
                ["E. Autorin: Erfundenes Buch."], ["Empfohlen für das 1. Fachsemester."]),
    full_module("GM", "Musterlehre II", "Example Studies II", "Lehreinheit INF", "nur Prüfung", "jährlich Sommer",
                "Mündliche Prüfung (MP)", "benotet", "keine", "englisch", "150 h", "2V + 2Ü", "5 LP",
                ["Die Studierenden vertiefen Muster."], ["Mehr Muster"], ["Empfohlen: Musterlehre I"], [], []),
    full_module("VM", "Proseminar Musterthemen", "Proseminar Example Topics", "Lehreinheit INF", "Lehrveranstaltung und Prüfung",
                "unregelmäßig", "Veranstaltungsbegleitende Prüfung (VbP)", "benotet", "keine", "deutsch",
                "Gesamt: 150 Stunden; davon Präsenz: 42 Stunden", "3SE", "5 LP", ["Vortrag halten."], ["Wechselnde Themen"],
                ["keine"], ["Wird bekannt gegeben."], []),
]

# --------------------------------------------------------------------------------------------------------------------
# Studienverlaufsplan (erfunden, Aufbau wie die FEI-Plaene: Querformat ueber /Rotate 90)
# --------------------------------------------------------------------------------------------------------------------

PLAN_COLS = [99, 192, 285, 377, 470, 563]


def plan_row(n: int) -> float:
    """Grundlinie der Beschriftung "n." (senkrecht, von oben)"""
    return 117 + (n - 1) * 68.5


def plan_box(n: int, col: int, title: list[str], person: str | None, sws: str | None, lp: str, lp_dx: float = 58,
             sub: list[str] | None = None) -> list[tuple]:
    """Kasten: Titelzeilen (8 pt), optional Unterzeile(n) klein, Lehrperson (6 pt), unten "2V+2Ü" und "| 5 ECTS" als
    getrennte Stuecke (wie im echten Plan) oder nur die LP"""
    base, x = plan_row(n), PLAN_COLS[col]
    out = [(x, base - 11 + 9.5 * k, 8, t) for k, t in enumerate(title)]
    for k, t in enumerate(sub or []):
        out.append((x, base - 11 + 9.5 * len(title) + 8 + 7 * k, 6, t))
    if person:
        out.append((x, base + 25, 6, person))
    if sws:
        out.append((x + 40, base + 33, 6, sws + " "))
        out.append((x + 58, base + 33, 6, "| " + lp))
    else:
        out.append((x + lp_dx, base + 33, 6, lp))
    return out


def plan_label(n: int, total: str) -> list[tuple]:
    base = plan_row(n)
    return [(44, base, 16, f"{n}."), (44, base + 17, 8, "SEMESTER"), (788, base + 18, 12, total), (786, base + 30, 8, "ECTS")]


PLAN_LATE = plan_box(5, 1, ["Wahlpflichtmodul", "(Vertiefung Beispiel)*"], None, None, "5 ECTS")
PLAN_ITEMS = (
    [(760, 21, 8, "Stand: 01/10/26"), (36, 42, 10, "STUDIENVERLAUFSPLAN"), (36, 59, 14, "BACHELOR BEISPIELINFORMATIK")]
    + plan_label(1, "8")
    + plan_box(1, 0, ["Beispielprogrammierung I"], "Muster", "2V+2Ü", "5 ECTS")
    + plan_box(1, 1, ["Einführung in", "Beispielwerkzeuge"], "Probe", None, "1V+1Ü | 3 ECTS", lp_dx=40)
    + plan_label(2, "15")
    + plan_box(2, 0, ["Beispielprogrammie-", "rung II"], "Muster", "2V+2Ü", "5 ECTS")
    + plan_box(2, 1, ["Beispielsysteme und", "Netze"], "Probe, Muster", "2V+1Ü+1L", "5 ECTS")
    + plan_box(2, 2, ["Wahlmodul*"], None, None, "5 ECTS", sub=["(A / B)"])
    + plan_label(3, "8")
    + plan_box(3, 0, ["Proseminar"], None, None, "5 ECTS")
    + plan_box(3, 1, ["Vertiefung Beispiel"], None, None, "3-6 ECTS")
    + plan_label(4, "8")
    + plan_box(4, 0, ["Wahlpflichtmodul", "(Vertiefung Beispiel)*"], None, None, "5 ECTS")
    + [(PLAN_COLS[1], plan_row(4) - 11, 8, "Studium Beispiel Angebote 3 LP")]
    + plan_label(5, "10")
    + plan_box(5, 0, ["Wahlmodul*"], None, None, "5 ECTS", sub=["(A / B)"])
    + plan_label(6, "15")
    + plan_box(6, 0, ["Bachelorarbiet inkl. Kolloquium"], None, None, "15 ECTS", lp_dx=230)
    + [(57, 522, 7, "Grundlagen der Beispielinformatik Wahlbereich*"), (747, 530, 12, "GESAMT"), (740, 546, 14, "61 ECTS"),
       (36, 568, 8, "* Wahlbereich: Wahl zwischen Vertiefung Beispiel und/oder Grundlagen der Beispielinformatik gemäß der"),
       (36, 578, 8, "gültigen Prüfungsordnung."), (538, 581, 8, "ECTS = Leistungspunkte | V = Vorlesung | Ü = Übung")]
    + PLAN_LATE
)


def make_plan_pdf(items: list[tuple]) -> bytes:
    """Eine Seite A4 hochkant mit /Rotate 90; Text gedreht (Tm 0 s -s 0 X Y) wie aus PowerPoint gedruckt: Lage in
    Leserichtung (dx, dy) -> X = dy, Y = dx"""
    ops = []
    for dx, dy, size, text in items:
        ops.append(b"BT /F1 1 Tf 0 %s -%s 0 %s %s Tm (" % tuple(f"{v:g}".encode() for v in (size, size, dy, dx))
                   + _pdf_text(text) + b") Tj ET")
    stream = b"\n".join(ops)
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 90 /Resources << /Font << /F1 3 0 R >> >> "
            b"/Contents 5 0 R >>",
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream"]
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for k, o in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % k + o + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
    out.write(b"".join(b"%010d 00000 n \n" % off for off in offsets))
    out.write(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref))
    return out.getvalue()


def _area(id_, name, kind="wahlpflicht"):
    return {"id": id_, "name": name, "lp_required": None, "lp_max": None, "kind": kind}


def _mod(id_, title, area, kind="wahlpflicht", sem=None):
    return {"id": id_, "title": title, "code": None, "area": area, "kind": kind, "lp": 5, "semester": sem, "turnus": "WS",
            "exam": None, "coursework": None, "prerequisites": [], "language": None, "workload_h": None, "source_page": 1}


def _entry(sem, title, text=None, lp=5, lp_max=None):
    return {"semester": sem, "title": title, "text": text or title, "lp": lp, "lp_max": lp_max}


def merge_cases(base: dict) -> list[dict]:
    """Kleine Kataloge und Plaene fuer die Zweige der Zuordnung"""
    head = {k: v for k, v in base.items() if k not in ("areas", "modules")}
    cat = dict(head, areas=[_area("grundlagen-beispiel", "Grundlagen Beispiel", "pflicht"),
                            _area("seminare", "Seminare"),
                            _area("vertiefung-der-beispielkunde", "Vertiefung der Beispielkunde"),
                            _area("vertiefung-der-musterkunde", "Vertiefung der Musterkunde"),
                            _area("nebenfach-alpha", "Nebenfach Alpha", "wahl"),
                            _area("nebenfach-beta", "Nebenfach Beta", "wahl")],
               modules=[_mod("musterlehre-1", "Musterlehre I", "grundlagen-beispiel", "pflicht", 3),
                        _mod("musterlehre-2", "Musterlehre II", "grundlagen-beispiel", "pflicht"),
                        _mod("seminar-alpha", "Seminar Alpha", "seminare", sem=4),
                        _mod("seminar-beta", "Seminar Beta", "seminare"),
                        _mod("kunde-a", "Beispielkunde A", "vertiefung-der-beispielkunde"),
                        _mod("kunde-b", "Musterkunde B", "vertiefung-der-musterkunde"),
                        _mod("alpha-1", "Alphakunde", "nebenfach-alpha", "wahl"),
                        _mod("beta-1", "Betakunde", "nebenfach-beta", "wahl"),
                        _mod("datenwege-a", "Datenwegeplanung A", None, "pflicht"),
                        _mod("datenwege-b", "Datenwegeplanung B", None, "pflicht")])
    plans = [
        ("praefix_mehrdeutig_und_eindeutig", {"entries": [_entry(1, "Musterlehre 1"), _entry(2, "Seminar"),
                                                          _entry(3, "Musterlehre II inkl. Übung")], "footnote": None}),
        ("nebenfach_gruppe_und_vertiefung", {"entries": [
            _entry(5, "Wahlmodul*", "Wahlmodul* (V / N)"),
            _entry(6, "Wahlpflicht Beispielkunde", "Wahlpflicht Beispielkunde (Vertiefung der Beispielkunde)", 5, 10)],
            "footnote": "Wahl zwischen Vertiefung der Musterkunde (V) und einem Nebenfach (N)."}),
        ("tippfehler_gleichstand_unbekannt", {"entries": [
            _entry(2, "Datenwegeplanung C"), _entry(2, "Musterleher II"), _entry(4, "Ganz neues Modul"),
            _entry(4, "Wahlmodul ohne Bereich"), _entry(5, "Seminare", lp=3, lp_max=6), _entry(6, "***")],
            "footnote": None}),
    ]
    out = []
    for name, plan in plans:
        merged, unmatched = sc.merge_study_plan(cat, plan)
        assert sc.validate(merged) == [], (name, sc.validate(merged))
        out.append({"name": name, "catalog_dumps": sc.dumps(cat), "plan_dumps": sc.dumps(plan), "dumps": sc.dumps(merged),
                    "unmatched": unmatched})
    return out


# --------------------------------------------------------------------------------------------------------------------
# PDF ohne Fremdbibliothek
# --------------------------------------------------------------------------------------------------------------------


def _pdf_text(s: str) -> bytes:
    b = s.encode("cp1252")
    return b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def make_pdf(pages: list[list[str]]) -> bytes:
    n = len(pages)
    objs: list[bytes] = []
    # 1 Katalog, 2 Seitenbaum, 3 Schrift, dann je Seite: Seite + Inhalt
    kids = " ".join(f"{4 + 2 * i} 0 R" for i in range(n))
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(f"<< /Type /Pages /Kids [{kids}] /Count {n} >>".encode())
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    for i, lines in enumerate(pages):
        ops = [b"BT", b"/F1 9 Tf"]
        placed = [(800 - 14 * k, line) for k, line in enumerate(lines)]
        if i > 0:
            placed.append((40, f"{i + 1} / {n}"))          # Fusszeile "Seite / Seiten"
        for y, line in placed:
            ops.append(b"1 0 0 1 50 %d Tm (" % y + _pdf_text(line) + b") Tj")
        ops.append(b"ET")
        stream = b"\n".join(ops)
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> "
                    f"/Contents {5 + 2 * i} 0 R >>".encode())
        objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for k, o in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % k + o + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
    out.write(b"".join(b"%010d 00000 n \n" % off for off in offsets))
    out.write(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref))
    return out.getvalue()


# --------------------------------------------------------------------------------------------------------------------
# Faelle
# --------------------------------------------------------------------------------------------------------------------

def validator_cases(base: dict) -> list[dict]:
    def case(name, mutate):
        c = copy.deepcopy(base)
        mutate(c)
        return {"name": name, "catalog": c, "errors": sc.validate(c)}

    def drop(*keys):
        def f(c):
            for k in keys:
                c.pop(k, None)
        return f

    def set_(path, value):
        def f(c):
            obj = c
            for p in path[:-1]:
                obj = obj[p]
            obj[path[-1]] = value
        return f

    def many(*fs):
        def f(c):
            for g in fs:
                g(c)
        return f

    return [
        case("gueltig", lambda c: None),
        case("pflichtfelder_fehlen", drop("v", "program", "catalog_term", "code", "source", "modules")),
        case("falsche_typen", many(set_(["v"], 2), set_(["university"], 7), set_(["regular_semesters"], 6.5),
                                   set_(["total_lp"], 0), set_(["areas"], {}))),
        case("semester_format", set_(["catalog_term"], "WiSe 25/26")),
        case("quelle", many(set_(["source", "url"], "http://example.org/x.pdf"), set_(["source", "sha256"], "ABC"))),
        case("modultexte_verboten", many(set_(["module_texts"], {}), set_(["modules", 0, "content"], "Langer Text"))),
        case("bereich", many(set_(["areas", 1, "id"], "Grundlagen Beispiel"), set_(["areas", 1, "lp_max"], 1),
                             set_(["areas", 2, "kind"], "frei"))),
        case("doppelte_ids", many(set_(["modules", 1, "id"], base["modules"][0]["id"]),
                                  set_(["areas", 2, "id"], base["areas"][0]["id"]))),
        case("modulfelder", many(set_(["modules", 0, "kind"], "pflichtig"), set_(["modules", 0, "lp"], -1),
                                 set_(["modules", 0, "semester"], 0), set_(["modules", 0, "turnus"], "Winter"),
                                 set_(["modules", 0, "area"], "gibt-es-nicht"), set_(["modules", 0, "exam"], "x" * 501),
                                 set_(["modules", 0, "source_page"], 0), set_(["modules", 0, "workload_h"], "150"))),
        case("voraussetzungen", many(set_(["modules", 1, "prerequisites"], [base["modules"][1]["id"], "fehlt", 3]),
                                     set_(["modules", 2, "prerequisites"], None))),
        case("lp_fehlt", lambda c: c["modules"][3].pop("lp")),
        case("kein_objekt", lambda c: (c.clear(), c.update({"modules": [1], "areas": ["x"]}))),
        case("verlaufsplan_gueltig", many(set_(["study_plan"], {"url": "https://example.org/plan.pdf", "fetched_at": None,
                                                                 "sha256": None}),
                                          set_(["plan_slots"], [{"semester": 5, "title": "Wahlmodul", "areas": [],
                                                                 "lp": 5, "lp_max": None}]))),
        case("verlaufsplan_fehler", many(set_(["study_plan"], {"url": "http://example.org/plan.pdf", "fetched_at": 1,
                                                                "sha256": "x"}),
                                         set_(["plan_slots"], [{"semester": 0, "title": "", "areas": [base["areas"][0]["id"],
                                                                                                     "fehlt", 3],
                                                                "lp": 6, "lp_max": 5},
                                                               {"semester": 2.5, "areas": None, "lp": "5"}, 7]))),
        case("verlaufsplan_typen", many(set_(["study_plan"], "plan.pdf"), set_(["plan_slots"], {}))),
    ]


REGISTRY_LABELS = [
    ("Technische Informatik (PO-Version 2017)", None),
    ("Technische Informatik (PO-Version 2022)", None),
    ("Technische Informatik (PO-Version 2017)", "TIBSc22"),
    ("Technische Informatik (PO-Version 2017)", "TIBSc25"),
    ("Technische Informatik (PO-Version 2025)", None),
    ("Technische Informatik (PO-Version 2017)", "2022"),
    ("  technische   informatik  ", None),
    ("Informatik (PO-Version 2017)", None),
    ("Informatik Bachelor (PO-Version 2022)", None),
    ("Informatik Master (PO-Version 2017)", None),
    ("Abschluss: Bachelor Informatik PO-Version: 2017", None),
    ("Elektrotechnik und Informationstechnik (PO-Version 2017)", None),
    ("Musterfach (PO-Version 2017)", None),
    # aus der breiten Erhebung (study-sources-luh.json, gemischtes Register)
    ("Elektrotechnik und Informationstechnik (PO-Version 2025)", None),
    ("Technische Informatik Master (PO-Version 2017)", None),
    ("Maschinenbau (PO-Version 2017)", None),
    ("Mathematik (PO-Version 2020)", None),
    ("Physik Bachelor", None),
    ("Technische Informatik (PO-Version 2017)", "ETBSc25"),
    ("", None),
]

# LSF Hildesheim (Notenspiegel-Zeile "Abschluss: ..."; Nummern erfunden) und Namen aus study-sources-hildesheim.json
HILDESHEIM_LABELS = [
    ("Abschluss: [82] Bachelor Studiengang: [079] B.Sc. Angewandte Informatik PO-Version: 2024", None),
    ("Abschluss: [88] Master Studiengang: [079] M.Sc. Angewandte Informatik PO-Version: 2024", None),
    ("Abschluss: [82] Bachelor Studiengang: [277] B.Sc. Wirtschaftsinformatik PO-Version: 2019", None),
    ("Abschluss: [82] Bachelor Studiengang: [026] B.A. Biologie PO-Version: 2025", None),
    ("Abschluss: [Ed] Master of Education Studiengang: [026] M.Ed. Biologie PO-Version: 2026", None),
    ("Abschluss: [82] Bachelor Studiengang: [132] B.Sc. Psychologie PO-Version: 2021", None),
    ("Psychologie (PO-Version 2021)", None),
    ("Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022", None),
    ("Abschluss: [82] Bachelor", None),
    # Studiengangwechsel (07.11.2026): alter und neuer Name des Bachelors, Master desselben Instituts
    ("Abschluss: [82] Bachelor Studiengang: [117] B.A. Sozialpädagogik PO-Version: 2025", None),
    ("Abschluss: [82] Bachelor Studiengang: [118] B.A. Sozial- und Organisationspädagogik PO-Version: 2022", None),
    ("Abschluss: [88] Master Studiengang: [118] M.A. Sozial- und Organisationspädagogik PO-Version: 2025", None),
    ("Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022", None),
]

TEXTS = [
    "Pﬂicht und Qualiﬁkationsziele",
    "A B\tC  D \r\nE\rF G H\x0cI\x0bJ\x85K",
    "  Leer  \n\n\n  zeilen  ",
    "Ver­teilte Sys​teme﻿",
    "Ａｂｃ ① ½",
    "",
]
SLUGS = ["Programmieren I", "Mathematik für die Ingenieurwissenschaften III - Numerik", "Grundlagen der Software-Technik",
         "Labor: Linux-Systemadministration", "Scientiﬁc Data Management and Knowledge Graphs ", "Ökonomie & Straße",
         "Café Résumé", "Mathe I-III, ET I-III", "!!!", "Künstliche Intelligenz I"]


def _json(v) -> bytes:
    return (json.dumps(v, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def build() -> dict[str, bytes]:
    """Alle Dateien der Fixture (Name -> Inhalt), ohne zu schreiben"""
    files: dict[str, bytes] = {}
    pdf = make_pdf(PAGES)
    files["modkat-sample.pdf"] = pdf
    pages = sc.pdf_pages(pdf)
    lines = [sc.normalize_lines(p) for p in pages]
    files["pages.json"] = _json(lines)

    reg = sc.load_registry()
    meta = {"university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022", "code": "TIBSc22",
            "catalog_term": "WS 2025/26", "regular_semesters": 6, "total_lp": 180,
            "source": {"url": sc.source_urls(reg, "luh", "TIBSc22", "WS 2025/26")[0], "fetched_at": "2026-11-04T09:00:00Z",
                       "sha256": hashlib.sha256(pdf).hexdigest()}}
    catalog, texts = sc.parse_luh_modkat(pages, meta)
    assert sc.validate(catalog) == [], sc.validate(catalog)
    expected = {"meta": meta, "key": sc.catalog_key(catalog), "catalog": catalog, "module_texts": texts,
                "dumps": sc.dumps(catalog), "texts_dumps": sc.dumps(texts)}
    files["expected.json"] = _json(expected)
    files["validator-cases.json"] = _json(validator_cases(catalog))
    registry = {
        "matches": [{"label": lab, "po": po, "university": "luh", "result": sc.match_program(lab, "luh", reg, po)}
                    for lab, po in REGISTRY_LABELS]
                   + [{"label": lab, "po": po, "university": "hildesheim", "result": sc.match_program(lab, "hildesheim", reg, po)}
                      for lab, po in HILDESHEIM_LABELS],
        "keys": [{"university": u, "code": c, "term": t, "key": sc.library_key(u, c, t)}
                 for u, c, t in [("luh", "TIBSc22", "WS 2025/26"), ("luh", "INFBSc22", "WS 2024/25"), ("luh", "TIBSc22", "SS 2026"),
                                 ("luh", "TIBSc25", "WS 2026/27")]],
        "urls": [{"code": c, "term": t, "urls": sc.source_urls(reg, "luh", c, t)}
                 for c, t in [("TIBSc22", "WS 2025/26"), ("TIBSc25", "WS 2026/27"), ("INFBSc22", "SS 2026"), ("XYZ", "WS 2025/26"),
                              ("ETBSc25", "WS 2026/27"), (sc.match_program("Maschinenbau (PO-Version 2017)", "luh", reg)["code"], "WS 2026/27")]],
        "terms": [{"code": c, "today": d, "terms": sc.candidate_terms(reg, "luh", c, d)}
                  for c, d in [("TIBSc22", "2026-11-04"), ("TIBSc22", "2025-11-04"), ("TIBSc25", "2026-11-04"), ("TIBSc25", "2027-10-15"),
                               ("INFBSc22", "2026-05-01"), ("XYZ", "2026-11-04"), ("ETMSc17", "2027-05-01"),
                               (sc.match_program("Mathematik (PO-Version 2020)", "luh", reg)["code"], "2027-05-01")]],
        "study_plans": [{"code": c, "url": (sc.study_plan_source(reg, "luh", c) or {}).get("url")}
                        for c in ("TIBSc25", "TIBSc22", "INFBSc22", "XYZ")],
        "modkat_parts": [{"url": u, "parts": list(sc.modkat_parts(u) or []) or None} for u in [
            "https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc25-WS_2026_27.pdf",
            "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc22-WS_2025_26.pdf",
            "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_Sp-INF-SS_2027.pdf",
            "https://example.org/handbuch.pdf"]],
        "title_terms": [{"text": t, "term": sc.term_from_title(t)}
                        for t in ["im Wintersemester 2025/2026", "im Sommersemester 2026", "Sommer 2026"]],
    }
    files["registry-cases.json"] = _json(registry)
    files["text-cases.json"] = _json({"normalize": [{"text": t, "lines": sc.normalize_lines(t)} for t in TEXTS],
                                      "slug": [{"text": t, "slug": sc.slug(t)} for t in SLUGS]})

    full_pdf = make_pdf(FULL_PAGES)
    files["modkat-full-sample.pdf"] = full_pdf
    full_pages = sc.pdf_pages(full_pdf)
    files["pages-full.json"] = _json([sc.normalize_lines(p) for p in full_pages])
    full_meta = {"university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2025", "code": "TIBSc25",
                 "catalog_term": "WS 2026/27", "regular_semesters": 6, "total_lp": 180,
                 "source": {"url": sc.source_urls(reg, "luh", "TIBSc25", "WS 2026/27")[0], "fetched_at": "2026-11-04T09:00:00Z",
                            "sha256": hashlib.sha256(full_pdf).hexdigest()}}
    full_catalog, full_texts = sc.parse_luh_modkat(full_pages, full_meta)
    assert sc.validate(full_catalog) == [] and len(full_catalog["modules"]) == 4, full_catalog
    files["expected-full.json"] = _json({"meta": full_meta, "key": sc.catalog_key(full_catalog), "catalog": full_catalog,
                                         "module_texts": full_texts, "dumps": sc.dumps(full_catalog),
                                         "texts_dumps": sc.dumps(full_texts)})

    plan_pdf = make_plan_pdf(PLAN_ITEMS)
    files["plan-sample.pdf"] = plan_pdf
    items = sc.pdf_items(plan_pdf)
    files["plan-items.json"] = _json(items)
    plan = sc.parse_study_plan(items)
    plan_src = sc.study_plan_source(reg, "luh", "TIBSc25")
    source = {"url": plan_src["url"], "fetched_at": "2026-11-04T09:00:00Z", "sha256": hashlib.sha256(plan_pdf).hexdigest()}
    merged, unmatched = sc.merge_study_plan(catalog, plan, source)
    assert sc.validate(merged) == [], sc.validate(merged)
    files["plan-expected.json"] = _json({"plan": plan, "plan_dumps": sc.dumps(plan), "source": source,
                                         "catalog_dumps": sc.dumps(merged), "unmatched": unmatched,
                                         "merge_cases": merge_cases(catalog)})
    return files


SWIFT_DATA = ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/StudyCatalog/StudySourcesData.swift"


def full_registry() -> bytes:
    """Gemischtes Register (study-sources.json + alle LUH-Studiengaenge aus study-sources-luh.json + alle Studiengaenge
    der Universitaet Hildesheim aus study-sources-hildesheim.json und der Hochschule Hannover aus study-sources-hsh.json,
    `merge_wide_registries`):
    packages/shared-contracts/study-sources-all.json, das Python und der Kern fuer die QIS-Zuordnung nutzen"""
    curated = json.loads(sc.REGISTRY_PATH.read_text(encoding="utf-8"))
    merged = sc.merge_wide_registries(curated, sc.load_wide_registries())
    merged["note"] = ("ERZEUGT von tools/gen-study-catalog-fixture.py aus study-sources.json (gepflegt, vorn), "
                      "study-sources-luh.json (alle LUH-Studiengaenge; Quelle luh-grundstock = nur aus dem Grundstock der "
                      "App), study-sources-hildesheim.json (Universitaet Hildesheim; Quelle hildesheim-grundstock) und "
                      "study-sources-hsh.json (Hochschule Hannover; Quelle hsh-grundstock) - nicht "
                      "von Hand aendern. " + str(curated.get("note") or ""))
    return (json.dumps(merged, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def swift_data(registry: bytes) -> bytes:
    """Register im Swift-Kern (eingebettet, ohne Ressourcen im Paket): woertlich study-sources-all.json"""
    text = registry.decode("utf-8")
    assert '"""#' not in text
    return ("// Erzeugt von tools/gen-study-catalog-fixture.py aus packages/shared-contracts/study-sources-all.json - nicht von Hand aendern.\n"
            "enum StudySourcesData {\n    static let json = #\"\"\"\n" + text.rstrip("\n") + "\n\"\"\"#\n}\n").encode("utf-8")


def main() -> int:
    registry = full_registry()
    sc._registry_cache = json.loads(registry)          # Faelle mit dem frisch gemischten Register
    files = {str(OUT / n): b for n, b in build().items()}
    files[str(sc.FULL_REGISTRY_PATH)] = registry
    files[str(SWIFT_DATA)] = swift_data(registry)
    if "--check" in sys.argv:
        stale = [n for n, b in files.items() if not Path(n).exists() or Path(n).read_bytes() != b]
        if stale:
            print("Fixture veraltet: " + ", ".join(stale) + " (tools/gen-study-catalog-fixture.py ausfuehren)")
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, b in files.items():
        Path(n).write_bytes(b)
    print(f"{len(files)} Dateien -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
