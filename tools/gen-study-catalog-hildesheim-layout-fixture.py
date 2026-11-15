"""Fixture der beiden Tabellen-Leser der Universitaet Hildesheim (app/study_catalog_hildesheim_layout.py, Swift-Kern
StudyCatalog/StudyCatalogHildesheimLayoutParser.swift): packages/shared-contracts/fixtures/study-catalog-hildesheim-layout/

Alle Seitentexte hier sind ERFUNDEN (Faecher, Module, Namen, Heft, Daten); nur der Aufbau folgt den echten
Studienordnungen (Informatik im Lehramt 2026, Barrierefreie Kommunikation 2024), so wie pypdf sie im Layout-Modus
liefert: Spalten einer Tabellenzeile in einer Textzeile, getrennt durch mindestens zwei Leerzeichen. Kein Text aus einer
echten Ordnung.

  kuerzel-fach.json    Fach im Zwei-Faecher-Bachelor: Anlage 1 mit "Pflichtmodule: ..." je Studienvariante (Pflicht nur,
                       wenn in jeder Variante), Anlage 2 Modulhandbuch mit Titelzeile "GAR-B1: „Titel“", Verweis auf ein
                       anderes Handbuch, Tabellenkopf "Studiensemester | Dauer | Häufigkeit | Status", LP in der letzten
                       Spalte, Teilmodule, Modul ueber die Seitengrenze (Kolumnentitel), Abkuerzungen, Anlage 3
  kuerzel-master.json  Fach im Master: "Status Modul" nennt Pflicht/Wahlpflicht, LP des ganzen Moduls in einer Zeile
                       "s. RStO ...   13", Zeilen mit "-", Titel mit Zusatz nach den Anfuehrungszeichen
  kennnummer.json      Masterstudiengang: Titelzeile "TG 1 Titel" bzw. "Modul TG 5 – Titel" (auch ueber zwei Zeilen,
                       "(Wahlpflichtmodul)"), Kopf "Kennnummer | Workload | Credits | ...", Werte darunter (umbrochen),
                       nummerierte Zeilen 1-11, Studien-/Pruefungsleistung in Zeile 6 oder 7
  werte.json           Einzelfaelle: Zellen einer Zeile, Zusammenfuegen, Turnus, Leistungen, Erkennung
Je Fall: {note, pages, meta, detect {kuerzel, kennnummer}, catalog, module_texts, dumps, texts_dumps}; dumps =
kanonischer Text (`app.study_catalog.dumps`), den Swift byte-gleich liefern muss.

Aufruf im Projektordner: .venv/bin/python tools/gen-study-catalog-hildesheim-layout-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402
from app import study_catalog_hildesheim_layout as hl  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog-hildesheim-layout"
NOTE = "erfunden; nur der Aufbau folgt den Studienordnungen (tools/gen-study-catalog-hildesheim-layout-fixture.py)"


def L(*cells) -> str:
    """Zeile im Layout-Modus: (Spalte, Text) der Reihe nach -> Text, mit Leerzeichen bis zur Spalte aufgefuellt"""
    out = ""
    for col, text in cells:
        out = out.ljust(col) + text
    return out


def head(heft: int, page: int) -> str:
    return f"Verkündungsblatt der Universität Hildesheim - Heft {heft} - Nr. 02 / 2031 (14.02.2031) - Seite {page} -"


def page(*lines: str) -> str:
    return "\n".join(lines)


# --------------------------------------------------------------------------------------------------------------------
# Fall 1: Fach im Zwei-Faecher-Bachelor (Kuerzel, Pflicht/Wahlpflicht aus Anlage 1)
# --------------------------------------------------------------------------------------------------------------------

V = 35                                                     # Wertspalte der Modultabellen
REF = [L((1, "Für das Modul verantwortliche Person, Inhalte und Qualifikationsziele des Moduls, Voraussetzung für die")),
       L((1, "Teilnahme, Studienleistungen sowie Voraussetzung für die"), (80, "Zulassung zur Prüfung: siehe Modulhandbuch")),
       L((1, "Angewandte Gartenkunde"))]


def table(semester: str, second: str | None, duration: str, freq: str, status: str, v: int = V) -> list[str]:
    out = [L((1, "Studiensemester"), (v, "Dauer des Moduls"), (v + 25, "Häufigkeit des Ange-"), (v + 57, "Status Modul")),
           L((v + 25, "bots")),
           L((1, semester), (v, duration), (v + 25, freq), (v + 57, status))]
    return out + ([L((1, second))] if second else [])


def forms_head(v: int = V) -> list[str]:
    return [L((1, "Lehr-/ Lernformen;"), (24, "Ar-"), (v, "Teil-"), (v + 11, "Lehr-"), (v + 20, "Titel"), (v + 50, "Kontakt-"),
              (v + 64, "Selbst-"), (v + 79, "SWS"), (v + 99, "LP")),
            L((1, "beitsaufwand"), (v, "modul"), (v + 11, "form"), (v + 50, "zeit"), (v + 64, "studium"))]


def form_row(part: str, kind: str, title: str, contact: str, own: str, sws: str, lp: str, v: int = V) -> str:
    return L((v, part), (v + 11, kind), (v + 20, title), (v + 50, contact), (v + 64, own), (v + 79, sws), (v + 99, lp))


def exam_head(v: int = V) -> list[str]:
    return [L((1, "Voraussetzung für die"), (v, "(Teil-)"), (v + 10, "Art der Prüfung"), (v + 38, "Prüfungsformen"),
              (v + 68, "Prüfungsleistungen")),
            L((1, "Vergabe von ECTS-Leis-"), (v, "Modul"))]


def exam_row(label: str, part: str, mark: str, form: str, text: str, v: int = V) -> str:
    return L((1, label), (v, part), (v + 10, mark), (v + 38, form), (v + 68, text)) if label else \
        L((v, part), (v + 10, mark), (v + 38, form), (v + 68, text))


def tail(v: int = V) -> list[str]:
    return [L((1, "Verwendbarkeit des"), (v, "s. Anlage 1  – Modulübersicht(en)")),
            L((1, "Moduls")),
            L((1, "Zuständige Ständige"), (v, "Je nach Wahl des Erstfaches: Ständige Prüfungskommission Zwei"), (v + 66, "-Fächer-Bachelor")),
            L((1, "Prüfungskommission"), (v, "(B. A.) oder (B.    Sc.)"))]


ANLAGE1 = "s. Anlage 1 – Modulübersicht(en)"
KF_PAGES = [
    page(head(998, 3),
         L((23, "Studienordnung für das Fach Gartenkunde")),
         L((2, "Polyvalente Zwei-Fächer-Bachelor-Studiengänge (B.A. / B.Sc.)")),
         "",
         "Auf der Grundlage des Beispielgesetzes hat der Fachbereich 9 am 03.02.2031 die folgende",
         "Studienordnung für das Fach Gartenkunde beschlossen.",
         L((53, "§ 4")),
         "(1) Eine Übersicht über Aufbau und Ziele der einzelnen Studienvarianten gibt Anlage 1.",
         "(2) Eine ausführliche Beschreibung aller Module liefert das Modulhandbuch (Anlage 2). Für ein-",
         "zelne Module verweist das Modulhandbuch auf das Handbuch Angewandte Gartenkunde.",
         "Pflichtmodule und Wahlpflichtmodule der Studienvarianten nennt Anlage 1."),
    page(head(998, 4),
         "",
         "Anlage 1: Beschreibung der Studienvarianten",
         "",
         "1      Lehramtsoption: Lehramt an Garten- und Parkschulen",
         "",
         "Abkürzung: Gar_Us",
         "",
         "Umfang des Faches:",
         L((7, "Gartenkunde als Erstfach:"), (78, "39 LP")),
         "",
         "Auflistung der zu belegenden Module:",
         "Pflichtmodule: GAR-B1, GAR-B2, GAR-A1,",
         L((7, "GAR-A2")),
         "Wahlpflichtmodule: Auswahl aus GAR           -Vx im Umfang von 6 LP           sowie   weitere Auswahl-",
         L((7, "möglichkeit aus dem Handbuch Angewandte Gartenkunde. Ohne Biologie ist GAR-V1 zu wählen.")),
         "",
         "2      Zweitfach in den Studienvarianten Beetpflege (BP) und Teichbau (TB)",
         "",
         "Abkürzung     : BP, TB",
         "",
         "Auflistung der zu belegenden Module:",
         "Pflichtmodule: GAR-B1, GAR-B2, GAR-A2, GAR-V1",
         "Wahlpflichtmodule: Auswahl aus GAR-A1 sowie GAR     -Vx  im Umfang von 9 LP"),
    page(head(998, 5),
         "",
         "Anlage 2: Modulhandbuch",
         "",
         L((1, "GAR-B1: „Einführung in die Gartenkunde“")),
         *REF[:2], L((1, "Angewandte Gartenkunde1")),
         "",
         *table("1 (Start im WiSe),", "2 (Start im SoSe)", "1", "WiSe", ANLAGE1),
         *forms_head(),
         form_row("-", "VL +", "Einführung in die Gar-", "60", "90", "2 (Vorlesung)", "6"),
         L((V + 11, "Ü"), (V + 20, "tenkunde"), (V + 79, "+ 2 (Übung)")),
         *exam_head(),
         exam_row("tungspunkten", "-", "MP", "Klausur oder mündliche", "Schriftliche Prüfung in Form einer"),
         L((V + 38, "Prüfung"), (V + 68, "Klausur im Umfang von 120 Minu-")),
         L((V + 68, "ten oder mündliche    Prüfung im Um-")),
         L((V + 68, "fang von 30 Minuten.")),
         *tail(),
         "",
         L((1, "GAR-B2: „Beetpraktikum I“")),
         *REF,
         *table("1 (Start im WiSe),", "2 (Start im SoSe)", "1", "WiSe", ANLAGE1),
         *forms_head(),
         form_row("-", "PR", "Beetprak-", "60", "90", "4 (Praktikum)", "6"),
         L((V + 20, "tikum I")),
         *exam_head(),
         exam_row("tungspunkten", "-", "MP", "Projekt mit Bericht und", "Im Anschluss an den Kurs muss in"),
         L((V + 38, "mündliche Prüfung"), (V + 68, "einer Kleingruppe innerhalb von etwa")),
         "",
         "1 in der aktuell gültigen Version, abrufbar auf den Seiten des Fachbereichs 9."),
    page(head(998, 6),
         "",
         L((1, "GAR-B2: „Beetpraktikum I“")),
         L((V + 70, "zwei Monaten ein Beet angelegt wer-")),
         L((V + 70, "den. Zur Abgabe gehört ein Bericht.")),
         *tail(V + 2),
         "",
         L((1, "GAR-A1: „Didaktik der Gartenkunde I“")),
         L((1, "Für das Modul verantwortliche Person: Prof. Dr. Erika Beispiel")),
         *table("4-5 (Start im WiSe),", "2-3 (Start im SoSe)", "2", "SoSe", ANLAGE1, V + 2),
         L((1, "Inhalte und"), (14, "Qualifikati-"), (V + 2, "Das Modul führt in Konzepte der Gartendidaktik ein. Im Mittelpunkt stehen histo-")),
         L((1, "onsziele des Moduls:"), (V + 2, "rische und aktuelle Ansätze des Gartenunterrichts"), (V + 56, "sowie deren Bedeutung.")),
         L((V + 2, "Ziel des Moduls ist es, fachliche und methodische Kompetenzen zu vermitteln.")),
         *forms_head(V + 2),
         form_row("TM1", "VL+Ü", "Gartendidaktik I", "60", "90", "2 (Vorlesung)", "6", V + 2),
         L((V + 81, "+ 2 (Übung)"))),
    page(head(998, 7),
         "",
         L((1, "GAR-A1: „Didaktik der Gartenkunde I“")),
         form_row("TM2", "SE", "Seminar zur Garten-", "30", "45", "2 (Semi-", "3"),
         L((V + 20, "didaktik I"), (V + 79, "nar)")),
         L((1, "Voraussetzung für die"), (V, "-")),
         L((1, "Teilnahme")),
         L((1, "Studienleistungen"), (V, "TM1: Gießprotokolle")),
         L((V, "TM2: Referat mit Hand-")),
         L((V, "out")),
         L((1, "Voraussetzung für die"), (V, "TM1: regelmäßige aktive Teilnahme an den Übungen")),
         L((1, "Zulassung zur Prüfung"), (V, "TM2: regelmäßige aktive Teilnahme am Seminar")),
         *exam_head(),
         exam_row("tungspunkten", "TM1", "TMP", "Mündliche Prüfung", "Mündliche Prüfung im Umfang von"),
         L((V + 68, "30 Minuten")),
         exam_row("", "TM2", "TMP", "Hausarbeit", "Hausarbeit (ca. 10-15 Seiten)"),
         *tail(),
         "",
         L((1, "GAR-A2: „Garten und Gesellschaft“")),
         L((1, "Für das Modul verantwortliche Person: Prof. Dr. Erika Beispiel")),
         *table("5 (Start im WiSe),", "6 (Start im SoSe)", "1", "WiSe", ANLAGE1),
         L((1, "Inhalte und Qualifikati-"), (V, "Im Modul befassen sich die Studierenden mit der Wirkung der Gärten auf die Gesell-")),
         L((1, "onsziele des Moduls:"), (V, "schaft.")),
         *forms_head(),
         form_row("-", "SE", "Garten und Gesell-", "30", "45", "2 (Seminar)", "3"),
         L((V + 20, "schaft")),
         L((1, "Voraussetzung für die"), (V, "-")),
         L((1, "Teilnahme")),
         L((1, "Studienleistungen"), (V, "ggfs. Hausübungen")),
         L((1, "Voraussetzung für die"), (V, "regelmäßige aktive Teilnahme am Seminar")),
         L((1, "Zulassung zur Prüfung")),
         *exam_head(),
         exam_row("tungspunkten", "-", "MP", "Vortrag und Ausarbei-", "Vortrag und Ausarbeitung oder"),
         L((V + 38, "tung oder Portfolio"), (V + 68, "Portfolio")),
         L((1, "Verwendbarkeit des"), (V, "s. Anlage 1  – Modulübersicht(en)")),
         L((1, "Moduls"), (V, "zusätzlich: Master  -Studiengang „Lehramt an Park       - und Gartenschulen“ (M.Ed.)"))),
    page(head(998, 8),
         "",
         L((1, "GAR-A2: „Garten und Gesellschaft“")),
         *tail()[2:],
         "",
         L((1, "GAR-V1: „Bodenkunde: Grundlagen“")),
         *REF,
         *table("3", None, "1", "jedes Semester", ANLAGE1),
         *forms_head(),
         form_row("-", "VL +", "Bodenkunde: Grund-", "45", "90", "2 (Vorlesung)", "4,5"),
         L((V + 11, "Ü"), (V + 20, "lagen"), (V + 79, "+ 1 (Übung)")),
         *exam_head(),
         exam_row("tungspunkten", "-", "MP", "Klausur", "Prüfung in Form einer Klausur"),
         *tail(),
         "",
         "Abkürzungen:",
         "LP: Leistungspunkte",
         "MP: Modulprüfung",
         "TM: Teilmodul"),
    page(head(998, 9),
         "",
         "Anlage 3: Modellstudienpläne",
         "",
         L((1, "Modultitel"), (30, "1. Semester"), (48, "2. Semester"), (100, "LP"), (106, "SWS")),
         L((1, "GAR-B1 – Einführung in die"), (30, "TM1 (PF) –"), (100, "6"), (106, "4")),
         L((1, "Gartenkunde"), (30, "6 LP / 4 SWS")),
         L((1, "GAR-B9: „Nur im Plan genannt“"))),
]
KF_META = {"university": "hildesheim", "program": "Gartenkunde im Polyvalenten Zwei-Fächer-Bachelor", "degree": "B.A./B.Sc.",
           "po": "2031", "code": "gartenkunde-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2031", "catalog_term": "WS 2030/31",
           "regular_semesters": 6, "total_lp": None,
           "source": {"url": "https://www.uni-hildesheim.de/media/beispiel/StO-Gartenkunde-2FB.pdf",
                      "fetched_at": "2031-03-01T09:00:00Z", "sha256": "a" * 64}}

# --------------------------------------------------------------------------------------------------------------------
# Fall 2: Fach im Master (Status Modul, LP des ganzen Moduls, Titel mit Zusatz)
# --------------------------------------------------------------------------------------------------------------------

RSTO = "s. RStO für die Masterstudiengänge Lehramt an Garten- und Parkschulen (M.Ed.),"


def board(v: int = V) -> list[str]:
    return [L((1, "Verwendbarkeit des"), (v, "Master-Studiengang „Lehramt an Park       - und Gartenschulen“ (M.Ed.)")),
            L((1, "Moduls")),
            L((1, "Zuständige Ständige Prü-"), (v, "Ständige Prüfungskommission für den Master       -Studiengang")),
            L((1, "fungskommission"))]


KM_PAGES = [
    page(head(998, 27),
         L((23, "Studienordnung für das Fach Gartenkunde")),
         L((2, "Master-Studiengang „Lehramt an Park- und Gartenschulen“ (M.Ed.)")),
         "(1) Das Fach Gartenkunde wird im Umfang von 7 Leistungspunkten (LP) studiert."),
    page(head(998, 28),
         "",
         "Anlage 1: Modulhandbuch",
         "",
         L((1, "GAR-M1: „Didaktik der Gartenkunde II“")),
         L((1, "Für das Modul verantwortliche Person: Prof. Dr. Erika Beispiel")),
         *table("1-2 (Start im WiSe),", "2-3 (Start im SoSe)", "2", "WiSe", "Pflichtmodul"),
         L((1, "Inhalte und Qualifikati-"), (V, "Das Modul vertieft Grundlagen der Gartendidaktik.")),
         L((1, "onsziele des Moduls:"), (V, "Im     Mittelpunkt stehen Grundfragen der Gartendidaktik.")),
         *forms_head(),
         form_row("TM1", "VL+Ü", "Gartendidaktik II", "45", "55", "2 (Vorlesung)", "4"),
         L((V + 79, "+ 1 (Übung)")),
         form_row("TM2", "S", "Seminar zur Garten-", "30", "45", "2 (Seminar)", "3"),
         L((V + 20, "didaktik II")),
         L((1, "Voraussetzung für die"), (V, "-")),
         L((1, "Teilnahme")),
         L((1, "Studienleistungen"), (V, "TM1 und TM2: Hausübungen")),
         *exam_head(),
         exam_row("tungspunkten", "TM1", "TMP", "Mündliche Prüfung oder", "Mündliche Prüfung im Umfang von"),
         L((V + 38, "Klausur"), (V + 68, "30 Minuten oder Klausur")),
         exam_row("", "TM2", "TMP", "Hausarbeit", "Schriftliche Hausarbeit"),
         *board()),
    page(head(998, 29),
         "",
         L((1, "LPS_Gar1: „Praxisphase Gartenkunde“")),
         L((1, "Für das Modul verantwortliche Person: Prof. Dr. Erika Beispiel")),
         *table("1 (Start im WiSe),", "2 (Start im SoSe)", "3", "Beginn jeweils im WiSe", "Pflichtmodul"),
         L((1, "Inhalte und Qualifikati-"), (V, RSTO)),
         L((1, "onsziele des Moduls:"), (V + 4, "Modulbeschreibung „Modul Praxisphase“")),
         *forms_head(),
         L((V, "s. RStO für die Masterstudiengänge Lehramt an Garten- und Parkschulen"), (V + 99, "13")),
         L((V, "(M.Ed.), Modulbeschreibung „Modul Praxisphase“")),
         L((1, "Voraussetzung für die"), (V, RSTO)),
         L((1, "Teilnahme"), (V, "Modulbeschreibung „Modul Praxisphase“")),
         L((1, "Studienleistungen"), (V, RSTO)),
         L((V, "Modulbeschreibung „Modul Praxisphase“")),
         L((1, "Voraussetzung für die"), (V, "(Teil-)"), (V + 26, "Art der"), (V + 38, "Prüfungsfor-"), (V + 55, "Prüfungsleistungen")),
         L((1, "Vergabe von ECTS-Leis-"), (V, "Modul"), (V + 26, "Prüfung"), (V + 38, "men")),
         L((1, "tungspunkten"), (V, "TM6 (s. RStO für"), (V + 26, "MP"), (V + 38, "Schriftliche"), (V + 55, "Die didaktische Ausarbeitung (Umfang ca.")),
         L((V, "die Masterstudien-"), (V + 38, "Hausarbeit"), (V + 55, "15 Seiten) kann die Planung einer Stunde")),
         L((V, "gänge)"), (V + 55, "umfassen.")),
         *board(),
         "",
         L((1, "LPS_Gar3: „Mastermodul” (Variante B der RStO für die Masterstudiengänge Lehramt an Gartenschulen")),
         L((1, "sowie Lehramt an Park"), (35, "- und Gartenschulen (M.Ed.))")),
         L((1, "Für das Modul verantwortliche Person: Erstbetreuer_in der Masterarbeit")),
         *table("4", None, "1", "jedes Semester", "Wahlpflichtmodul"),
         *forms_head(),
         form_row("TM1", "SE", "Mastervorbereitung", "30", "30", "2", "2"),
         L((V + 20, "(Master-Seminar)")),
         form_row("TM2", "-", "Masterarbeit", "-", "600", "-", "20"),
         form_row("TM3", "-", "Master-Kolloquium", "-", "60", "-", "2"),
         L((V, "s. RStO für die Masterstudiengänge Lehramt an Garten- und Parkschulen"), (V + 99, "24"))),
    page(head(998, 30),
         "",
         L((1, "LPS_Gar3: „Mastermodul” (Variante B der RStO für die Masterstudiengänge Lehramt an Gartenschulen")),
         L((1, "sowie Lehramt an Park- und Gartenschulen (M.Ed.))")),
         L((1, "Studienleistungen"), (V, "siehe Rahmenstudienordnung")),
         *exam_head(),
         exam_row("tungspunkten", "-", "MP", "Masterarbeit", "Masterarbeit"),
         "",
         *board(),
         "",
         "Abkürzungen:",
         "LP: Leistungspunkte"),
]
KM_META = {"university": "hildesheim", "program": "Gartenkunde im Master Lehramt an Park- und Gartenschulen", "degree": "M.Ed.",
           "po": "2031", "code": "gartenkunde-im-master-lehramt-an-park-und-gartenschulen|m.ed.|2031", "catalog_term": "WS 2030/31",
           "regular_semesters": 4, "total_lp": None,
           "source": {"url": "https://www.uni-hildesheim.de/media/beispiel/StO-Gartenkunde-MEd.pdf", "fetched_at": None, "sha256": None}}

# --------------------------------------------------------------------------------------------------------------------
# Fall 3: Kennnummer | Workload | Credits
# --------------------------------------------------------------------------------------------------------------------


def kn_head(spaced: bool = False) -> list[str]:
    return [L((57, "Studiense-"), (76, "Häufigkeit des An-")),
            L((1, "Kenn   nummer" if spaced else "Kennnummer"), (22, "Workload"), (42, "Credits"), (57, "mester"), (76, "gebots"), (103, "Dauer"))]


def kn_values(hours: str, credits: str, sem: str, freq: str, dur: str) -> str:
    return L((22, hours), (42, credits), (57, sem), (76, freq), (103, dur))


def kn_row(n: int, name: str, *more) -> str:
    return L((1, str(n)), (9, name), *more)


def kn(text: str) -> str:
    return L((9, text))


KN_PAGES = [
    page(head(997, 6),
         "",
         "Anlage 1",
         L((39, "Modulhandbuch")),
         L((11, "für den Masterstudiengang Teichgestaltung")),
         "Im Textteil des Modulhandbuches beschreiben fett umrandete Tabellen Module.",
         "LP = Leistungspunkte"),
    page(head(997, 7),
         L((19, "1.1 V (4 LP)"), (52, "2.1 V (4 LP)")),
         L((19, "Teichkunde"), (52, "Uferpflanzen"))),
    page(head(997, 8),
         "",
         L((1, "TG 1 Grundlagen der Teichgestaltung")),
         *kn_head(),
         kn_values("390 h", "13", "1./2. Sem.", "Jährlich: TM 1.1 &", "2 Semester"),
         L((76, "TM 1.2 im WS, TM")),
         L((76, "1.3 im SoSe")),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Gruppen-")),
         L((9, "1.1 V: Teichkunde (4 LP)"), (36, "30 h"), (62, "90"), (88, "größe")),
         L((9, "(2 SWS)"), (88, "20 Studierende")),
         L((9, "1.2 S: Theorie und Praxis"), (36, "30 h"), (62, "120")),
         kn_row(2, "Lernergebnisse (learning outcomes)/Kompetenzen"),
         kn("Die Studierenden kennen die wichtigsten Grundlagen der Teichgestaltung. Sie sind mit der"),
         kn("Pflege von Ufern vertraut."),
         kn("1.1: Die Studierenden kennen die Grundlagen der Teichkunde."),
         kn_row(3, "Inhalte"),
         kn("Das Modul dient der Einführung in die Thematik des Studiengangs. Neben einer Überblicks-"),
         kn("veranstaltung werden die Grundlagen       der Uferpflege vermittelt."),
         kn_row(4, "Lehrformen"),
         kn("Vorlesung (Dozierendenvortrag mit Diskussionsanteilen);"),
         kn_row(5, "Teilnahmevoraussetzungen"),
         kn("Keine")),
    page(head(997, 9),
         "",
         L((1, "TG 1 Grundlagen der Teichgestaltung")),
         kn_row(6, "Prüfungsformen"),
         L((10, "Klausur")),
         kn_row(7, "Voraussetzungen für die Vergabe von Leistungspunkten"),
         L((10, "Studienleistungen:")),
         L((10, "1.1. oder 1.3: Bestehen der Klausur")),
         L((10, "1.2. Aktive, regelmäßige Teilnahme")),
         L((10, "Prüfungsleistung:")),
         L((10, "1.1 oder 1.3: Klausur")),
         kn_row(8, "Verwendung des Moduls", (40, "(in anderen Studiengängen)")),
         L((10, "keine")),
         kn_row(9, "Stellenwert der Note für die Endnote"),
         L((10, "13/61 = 21,3 %")),
         kn_row(10, "Modulbeauftragte/r und hauptamtlich Lehrende"),
         L((10, "Prof. Dr. Erika Beispiel")),
         kn_row(11, "Sonstige Informationen"),
         L((10, "Eine der beiden Klausuren stellt die Modulnote dar."))),
    page(head(997, 10),
         "",
         L((1, "TG 2   Uferpflanzen")),
         *kn_head(spaced=True),
         kn_values("330 h", "11", "1. Sem.", "Jährlich: TM 2.1, TM", "1 Semester"),
         L((76, "2.2, TM 2.3 im WS")),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Gruppen-")),
         L((9, "2.1 V: Uferpflanzen (4"), (36, "30 h"), (62, "90 h"), (88, "größe")),
         kn_row(2, "Lernergebnisse (learning outcomes)/Kompetenzen"),
         kn("Die Studierenden sind mit Uferpflanzen vertraut."),
         kn_row(3, "Inhalte"),
         kn("Grundlagen der Uferpflanzen. Konzept und Funktion."),
         L((1, "TG 2 Uferpflanzen")),
         kn_row(4, "Lehrformen"),
         kn("Übung (Einzel- und Gruppenarbeit)."),
         kn_row(5, "Teilnahmevoraussetzungen"),
         kn("Keine"),
         kn_row(6, "Prüfungsformen"),
         kn("Studienleistung"),
         kn("2.2: Aktive, regelmäßige Teilnahme         ; Bearbeitung von Aufgaben, wie Projektarbeit,"),
         kn("Portfolio"),
         kn("2.3: Aktive, regelmäßige Teilnahme"),
         kn("Prüfungsleistung"),
         kn("2.1: Hausarbeit oder Projektarbeit (z.B.       Poster mit Präsentation      ) im jeweils ande-"),
         kn("ren Teilmodul"),
         kn_row(7, "Voraussetzungen für die Vergabe von           Leistungspunkten"),
         kn("Bestandene Hausarbeit in 2.1"),
         kn_row(8, "Verwendung des Moduls (in anderen Studiengängen)"),
         kn("Keine"),
         kn_row(11, "Sonstige Informationen")),
    page(head(997, 11),
         "",
         L((1, "Modul TG 5 – Vertiefungsbereich Wasserbau I:")),
         L((1, "Theorie")),
         *kn_head()[1:],
         L((57, "mester"), (76, "gebots")),
         kn_values("300 h", "10", "2. Sem.", "Jedes", "1 Semester"),
         L((73, "Sommersemester")),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Grup-")),
         kn_row(2, "Lernergebnisse / Kompetenzen"),
         kn("Die Studierenden kennen Verfahren des Wasserbaus.")),
    page(head(997, 12),
         "",
         L((1, "Modul TG 5 – Vertiefungsbereich Wasserbau I:")),
         L((1, "Theorie")),
         kn_row(3, "Inhalte"),
         kn("Theorie"),
         kn("des Wasserbaus an Beispielen."),
         kn_row(6, "Prüfungsformen"),
         kn("Hausarbeit oder"),
         kn("Projektarbeit (z.B. Poster mit Präsentation)"),
         "",
         L((1, "Modul TG 7 – Fachsprache 2 (Wahlpflichtmodul)")),
         *kn_head()[1:],
         L((57, "mester"), (76, "gebots")),
         kn_values("390 h", "13", "3. Sem.", "Jedes Winterse-", "1 Semester"),
         L((80, "mester")),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Grup-")),
         kn_row(6, "Prüfungsformen"),
         kn("Klausur"),
         kn_row(11, "Sonstige Informationen"),
         kn("Das Modul 7 ist ein Wahlpflichtmodul; es muss eines von zwei Modulen TG 7 oder TG 8 belegt werden.")),
    page(head(997, 13),
         "",
         L((1, "TG 10 Profilmodul: Forschung oder Praxis")),
         *kn_head(),
         kn_values("300 h", "10", "4. Sem.", "individuell", "variabel je"),
         L((57, "(empfohlen)"), (103, "nach gewähl-")),
         L((103, "ter Form")),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Gruppen-")),
         L((9, "--- entfällt ---"), (36, "variabel je nach ge-"), (62, "variabel je nach ge-"), (88, "größe")),
         kn_row(2, "Lernergebnisse (learning outcomes)/Kompetenzen"),
         kn("Option Praktikum: Die Studierenden können die erworbenen Kenntnisse anwenden."),
         kn_row(3, "Inhalte"),
         kn("Option Praktikum: Die Studierenden absolvieren ein Praktikum."),
         kn_row(6, "Prüfungsformen"),
         kn("--- entfällt ---"),
         kn_row(7, "Voraussetzungen für die Vergabe von Leistungspunkten"),
         kn("Studienleistung:"),
         kn("Bericht im Umfang von        6-8 Seiten. Im Bericht wird auf alle Leistungen eingegangen, die zur"),
         kn("Anrechnung gebracht werden            sollen. Der Bericht wird dem/der Praktikumsbeauftragten zur"),
         kn("Anerkennung vorgelegt. Bei einem Vollzeitpraktikum im Umfang von 8 Wochen entfällt die Studien-"),
         kn("leistung Bericht."),
         "",
         kn("Prüfungsleistung:"),
         kn("entfällt"),
         kn_row(9, "Stellenwert der Note für die Endnote"),
         kn("--- entfällt, da unbenotet ---")),
    page(head(997, 14),
         "",
         L((1, "TG 11 Abschluss")),
         *kn_head(),
         kn_values("600 h", "20", "4. Sem.", "Individuell", "4 Monate"),
         kn_row(1, "Lehrveranstaltungen", (36, "Kontaktzeit"), (62, "Selbststudium"), (88, "geplante Gruppen-")),
         L((9, "--- entfällt ---"), (36, "--- entfällt ---"), (62, "600 h"), (88, "größe")),
         kn_row(2, "Lernergebnisse (learning outcomes)/Kompetenzen"),
         kn("Die Studierenden bearbeiten ein Thema eigenständig."),
         kn_row(3, "Inhalte"),
         kn("Die Inhalte der Masterarbeit sind frei wählbar."),
         kn_row(5, "Teilnahmevoraussetzungen"),
         kn("Voraussetzung für die Anmeldung zum Abschlussmodul ist der Erwerb von mind. 80 LP."),
         kn_row(6, "Prüfungsformen"),
         kn("Masterarbeit im Umfang von ca. 60 Seiten (inkl.                  Leerzeichen) (ohne"),
         kn("eventuelle Anhänge)"),
         kn_row(7, "Voraussetzungen für die Vergabe von Leistungspunkten"),
         kn("bestandene Masterarbeit (s. 6)"),
         kn_row(9, "Stellenwert der Note für die Endnote"),
         kn("20 LP gewichtet mit Faktor 1,5")),
]
KN_META = {"university": "hildesheim", "program": "Teichgestaltung", "degree": "M.A.", "po": "2031",
           "code": "teichgestaltung|m.a.|2031", "catalog_term": "SS 2031", "regular_semesters": 4, "total_lp": 120,
           "source": {"url": "https://www.uni-hildesheim.de/media/beispiel/StO-Teichgestaltung.pdf", "fetched_at": None, "sha256": None}}

# --------------------------------------------------------------------------------------------------------------------
# Einzelfaelle
# --------------------------------------------------------------------------------------------------------------------

LINE_CASES = [
    " Studiensemester                   Dauer des Moduls         Häufigkeit des Ange-            Status Modul",
    "  a b   c",
    "x",
    "",
    "     ",
    "\tTab  und\tTab",
    " Schiﬀ  ﬂach  weit",
    "Sil­ben  tren​nung",
    "eins\r\nzwei\x0cdrei  vier",
    "Verkündungsblatt der Universität Hildesheim - Heft 214 - Nr. 07 / 2026 (27.08.2026) - Seite 6 -",
    "   Verkündungsblatt der Stiftung Universität Hildesheim – Heft 9 – Nr. 1 / 2031   – Seite 12 –",
    "Verkündungsblatt der Universität Hildesheim erscheint  im Heft",
    "Ende mit Leerzeichen   ",
]
JOIN_CASES = [[], [""], ["Vortrag und Ausarbei-", "tung oder Portfolio"], ["Haupt-", "und Realschulen"], ["Web- und Daten-", "banken-Praktikum"],
              ["Klausur oder mündliche", "Prüfung"], ["Poster mit Präsentation ) oder ( Werkstück", "plus Reflexion ; mind. 1"],
              ["Unter-", "Übertitelung"], ["E-", "Klausur"], ["Teil-", "sowie Vollzeit"], ["TM1:", "", "Mündliche Prüfung"],
              ["Ände-", "rung", "en -", "ökologisch"]]
SEASON_CASES = ["WiSe", "SoSe", "Beginn jeweils im WiSe", "jedes Semester", "Jährlich: TM 1.1 & TM 1.2 im WS, TM 1.3 im SoSe",
                "Jährlich: TM 2.1, TM 2.2, TM 2.3 im WS", "individuell", "", "Wintersemester und Sommersemester", "jedem Semester",
                "SS", "wissen"]
FACT_CASES = [
    {"items": [], "references": True},
    {"items": [["-"]], "references": True},
    {"items": [["--- entfällt ---"]], "references": True},
    {"items": [["Keine"], ["entfällt"]], "references": True},
    {"items": [["TM1: Hausübungen"], ["TM2: Referat mit Hand-", "out"]], "references": False},
    {"items": [["s. RStO für die Masterstudiengänge,", "Modulbeschreibung „Modul Praxisphase“"]], "references": False},
    {"items": [["s. RStO für die Masterstudiengänge,", "Modulbeschreibung „Modul Praxisphase“"]], "references": True},
    {"items": [["siehe Rahmenstudienordnung"], ["Hausübungen ;"]], "references": False},
    {"items": [["Bericht " * 40]], "references": True},
    {"items": [["Wort" * 60]], "references": True},
    {"items": [["Ähre und Öl " * 20], ["zweiter Eintrag"]], "references": True},
]
DETECT_CASES = [
    {"name": "leer", "pages": []},
    {"name": "studienordnung inklusive modulhandbuch", "pages": ["Studienordnung inklusive Modulhandbuch für den Bachelor-Studiengang Beetkunde",
                                                                 "Bezeichnung Modul 1: Hochbeet\nLeistungspunkte 6 LP"]},
    {"name": "titel ohne tabelle", "pages": [" GAR-B1: „Einführung in die Gartenkunde“\n Lehrinhalte          Beete"]},
    {"name": "titel mit tabelle", "pages": [" GAR-B1: „Einführung“\n Studiensemester                   Dauer des Moduls   Häufigkeit   Status Modul\n"
                                            " 1                                 1                  WiSe         Pflichtmodul"]},
    {"name": "kopf ohne titel", "pages": [" Kennnummer   Workload   Credits   Studiensemester\n              300 h      10        1. Sem."]},
    {"name": "kopf mit titel", "pages": [" TG 3 Wasserbau\n Kennnummer   Workload   Credits   Studiensemester\n              300 h      10        1. Sem."]},
    {"name": "titel zu weit ueber dem kopf", "pages": [" TG 3 Wasserbau\n eins\n zwei\n Kennnummer   Workload   Credits\n              300 h      10"]},
]


# --------------------------------------------------------------------------------------------------------------------

def _json(v) -> bytes:
    return (json.dumps(v, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def detect(pages: list[str]) -> dict:
    return {"kuerzel": hl.is_kuerzel_modultabelle(pages), "kennnummer": hl.is_kennnummer_tabelle(pages)}


def case(note: str, fmt: str, pages: list[str], meta: dict) -> dict:
    parse = hl.parse_kuerzel_modultabelle if fmt == hl.KUERZEL_FORMAT else hl.parse_kennnummer_tabelle
    catalog, texts = parse(pages, meta)
    errors = sc.validate(catalog)
    assert not errors, errors
    return {"note": NOTE + "; " + note, "format": fmt, "pages": pages, "meta": meta, "detect": detect(pages), "catalog": catalog,
            "module_texts": texts, "dumps": sc.dumps(catalog), "texts_dumps": sc.dumps(texts)}


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    files["kuerzel-fach.json"] = _json(case("Fach im Zwei-Fächer-Bachelor, Pflicht/Wahlpflicht aus Anlage 1", hl.KUERZEL_FORMAT, KF_PAGES, KF_META))
    files["kuerzel-master.json"] = _json(case("Fach im Master, Status Modul in der Tabelle", hl.KUERZEL_FORMAT, KM_PAGES, KM_META))
    files["kennnummer.json"] = _json(case("Kennnummer | Workload | Credits", hl.KENNNUMMER_FORMAT, KN_PAGES, KN_META))
    files["werte.json"] = _json({
        "note": NOTE,
        "lines": [{"text": t, "lines": hl.layout_lines([t])[0], "dumps": sc.dumps(hl.layout_lines([t])[0])} for t in LINE_CASES],
        "join": [{"parts": p, "text": hl._join(p)} for p in JOIN_CASES],
        "season": [{"text": t, "turnus": hl._season(t)} for t in SEASON_CASES],
        "facts": [dict(c, text=hl._facts(c["items"], c["references"])) for c in FACT_CASES],
        "detect": [dict(c, detect=detect(c["pages"])) for c in DETECT_CASES],
    })
    return files


def main() -> int:
    files = {str(OUT / n): b for n, b in build().items()}
    if "--check" in sys.argv:
        stale = [n for n, b in files.items() if not Path(n).exists() or Path(n).read_bytes() != b]
        if stale:
            print("Fixture veraltet: " + ", ".join(stale) + " (tools/gen-study-catalog-hildesheim-layout-fixture.py ausfuehren)")
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, b in files.items():
        Path(n).write_bytes(b)
    print(f"{len(files)} Dateien -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
