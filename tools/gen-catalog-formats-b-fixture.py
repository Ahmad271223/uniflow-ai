#!/usr/bin/env python3
"""Erfundene Fixtures fuer die Leseprogramme "Formate B" (phil-kv-tabelle, maphy-katalog, OCR-Zeilen).

Schreibt packages/shared-contracts/fixtures/catalog-formats-b/:
  phil-pages.json      Seitentexte wie pypdf extraction_mode="layout" (zweispaltige Tabelle, zwei Studiengaenge)
  phil-expected.json   {"<Registerschluessel>": Katalog} fuer beide Studiengaenge (gemeinsamer Katalog, gefiltert)
  maphy-pages.json     Seitentexte eines erfundenen MaPhy-Katalogs (Inhaltsverzeichnis, Abschnitte, Anhang)
  maphy-expected.json  {"bachelor": Katalog, "master": Katalog}
  ocr-page.json        erfundene Vision-Beobachtungen einer Phil-Seite (mit Logo, Lesefehler im Feldnamen)
  ocr-expected.json    {"plain": Text, "layout": Text, "template": ...}

Alle Inhalte sind erfunden (keine Texte aus echten Modulhandbuechern). Aufruf:
  .venv/bin/python tools/gen-catalog-formats-b-fixture.py          # schreiben
  .venv/bin/python tools/gen-catalog-formats-b-fixture.py --check  # nur vergleichen (Exit 1 bei Abweichung)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.catalog_formats import maphy_katalog, ocr_pages, phil_kv_tabelle  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "catalog-formats-b"
COL = 44  # Wertspalte der erfundenen Layout-Seiten


def kv(label: str, *values: str) -> list[str]:
    """Tabellenzeilen 'Schluessel | Wert' wie im Layout-Modus (Wert ab Spalte COL, Folgezeilen eingerueckt)"""
    labels = label.split("\n")
    vals = list(values) or [""]
    out = []
    for i in range(max(len(labels), len(vals))):
        left = labels[i] if i < len(labels) else ""
        right = vals[i] if i < len(vals) else ""
        out.append((left.ljust(COL) + right).rstrip() if right else left)
    return out


def head(kind: str, title: str, code: str = "") -> list[str]:
    line = kind.ljust(COL) + title
    if code:
        line = line.ljust(COL + 52) + code
    return [line]


PHIL_TOP = ["Modulkatalog Fach Beispielkunde in Studiengaengen mit Lehramtsoption", "Stand: 01.10.2026"]


def phil_pages() -> list[str]:
    p1 = PHIL_TOP + [
        "",
        "A) Qualifikationsziele",
        "Das Fach Beispielkunde vermittelt erfundene Grundlagen fuer die Pruefung dieses Leseprogramms.",
        "",
        "B) Modulkatalog",
        "",
        *head("Pflichtmodul", "Grundlagen der Beispielkunde", "10 100"),
        *kv("Anbieter", "Institut fuer Beispielkunde"),
        *kv("Modulverantwortliche/r", "Prof. Dr. Erika Muster"),
        *kv("Häufigkeit des Angebots", "jedes Wintersemester"),
        *kv("Dauer des Moduls", "ein Semester"),
        *kv("Semesterlage", "empfohlen im 1. Semester"),
        *kv("Verwendbarkeit", "Fächerübergreifender Bachelor, Master Lehramt an Gymnasien"),
        *kv("Eingangsvoraussetzungen", "keine"),
        *kv("Art der LV/SWS", "Vorlesung (2 SWS)", "Seminar (2 SWS)"),
        *kv("ECTS-LP/Workload", "8 LP / 240 Stunden", "60 Kontaktstunden", "180 Stunden Selbststudium"),
        *kv("Notenskala", "1,0; 1,3 (sehr gut); 1,7; 2,0; 2,3 (gut)"),
        *kv("Prüfungsleistungen", "Klausur (90 Minuten)"),
        *kv("Studienleistungen\n(Voraussetzung für die\nVergabe von LP)", "Eine Studienleistung pro Lehrveranstaltung"),
        *kv("Inhalte", "Erfundene Inhalte der Beispielkunde, Teil eins.", "Erfundene Inhalte, Teil zwei."),
        *kv("Kompetenzziele", "Die Studierenden koennen erfundene Beispiele einordnen."),
        "                                                                      1",
    ]
    p2 = PHIL_TOP + [
        "",
        *kv("Literatur", "Muster, E. (2020): Einfuehrung in die Beispielkunde. Hannover."),
        "",
        *head("Pflichtmodul (FüBa) und", "Vertiefung der Beispielkunde"),
        "Wahlpflichtmodul (Master",
        "LG)",
        *kv("Anbieter", "Institut fuer Beispielkunde"),
        *kv("Modulverantwortliche/r", "Dr. Max Beispiel"),
        *kv("Semesterlage und\nHäufigkeit des Angebots", "Jedes Semester"),
        *kv("Dauer des Moduls", "zwei Semester"),
        *kv("Semesterlage", "2. bis 3. Semester"),
        *kv("Verwendbarkeit", "Fächerübergreifender Bachelor, Master Lehramt an Gymnasien"),
        *kv("Eingangsvoraussetzungen", "Erfolgreicher Abschluss von Grundlagen der Beispielkunde empfohlen"),
        *kv("Arbeitsaufwand / Workload und\nLeistungspunkte (LP)", "10 LP / 300 Stunden",
            "Präsenzzeit: 60 h, Selbststudium: 240 h"),
        *kv("Prüfungs- und\nStudienleistungen", "• Prüfungsleistung: Hausarbeit (15 Seiten)",
            "• Studienleistungen: Referat"),
        *kv("Inhalte", "Erfundene Vertiefung."),
        "                                                                      2",
    ]
    p3 = PHIL_TOP + [
        "",
        "Wahlpflichtbereich",
        "",
        *head("Wahlpflichtmodul", "Beispielpraxis im Lehramt", "Modul-"),
        "".ljust(COL + 52) + "Code: xxxx",
        *kv("Anbieter", "Institut fuer Beispielkunde"),
        *kv("Häufigkeit des Angebots", "jedes Sommersemester"),
        *kv("Semesterlage", "Ab dem 2. Semester"),
        *kv("Verwendbarkeit", "Master Lehramt an Gymnasien"),
        *kv("ECTS-LP/Workload", "5 LP/ 150 Stunden"),
        *kv("Prüfungsleistungen", "Portfolio"),
        *kv("Studienleistungen", "keine"),
        "                                                                      3",
    ]
    p4 = PHIL_TOP + [
        "",
        "Abschlussbereich",
        "",
        *head("Bachelorarbeit", "Bachelorarbeit", "9999"),
        *kv("Anbieter", "Institut fuer Beispielkunde"),
        *kv("Studiensemester", "Im 6. Semester"),
        *kv("Semesterlage und\nHäufigkeit des Angebots", "Jedes Semester"),
        *kv("Verwendbarkeit des Moduls", "Fächerübergreifender Bachelorstudiengang (Erstfach)"),
        *kv("Voraussetzungen\nfür die Teilnahme", "Mindestens 110 Leistungspunkte"),
        *kv("Arbeitsaufwand / Workload und\nLeistungspunkte (LP)", "10 LP / 300 Stunden"),
        *kv("Prüfungsleistungen", "Bachelorarbeit (40 Seiten)"),
        *kv("Studienleistungen", "---"),
        "",
        *head("Wahlmodul", "Beispielkunde im Zertifikat", "9 100"),
        *kv("Anbieter", "Institut fuer Beispielkunde"),
        *kv("Häufigkeit des Angebots", "jedes Semester"),
        *kv("Verwendbarkeit", "Zertifikatsprogramm LG"),
        *kv("ECTS-LP/Workload", "4 LP / 120 Stunden"),
        "                                                                      4",
    ]
    return ["\n".join(p) for p in (p1, p2, p3, p4)]


def phil_meta(key: str, degree: str) -> dict:
    return {"university": "luh", "program": "Beispielkunde", "degree": degree, "po": "2016",
            "code": key.split("|", 1)[1], "catalog_term": None, "term_hint": "aktuell",
            "regular_semesters": 6 if degree.startswith("B") else 4, "total_lp": None,
            "source": {"url": "https://example.invalid/beispielkunde.pdf", "fetched_at": "2026-11-04T21:00:00Z",
                       "sha256": None},
            "program_key": key, "shared_catalog": True}


PHIL_KEYS = {"luh|beispielkunde-im-faecheruebergreifenden-bachelor|b.a.|2016": "B.A.",
             "luh|beispielkunde-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016": "M.Ed."}


def maphy_pages() -> list[str]:
    toc = "\n".join([
        "Inhaltsverzeichnis",
        "1  Vorbemerkung                                                     2",
        "2  Module                                                           3",
        "    2.1  Pflichtmodule Bachelor . . . . . . . . . . . . . . . . . . . 3",
        "           Rechnen I . . . . . . . . . . . . . . . . . . . . . . . .  3",
        "           Rechnen II . . . . . . . . . . . . . . . . . . . . . . . . 4",
        "    2.2  Module Master . . . . . . . . . . . . . . . . . . . . . . . 5",
        "                                                                    1",
    ])
    intro = "\n".join([
        "1 Vorbemerkung",
        "Dieser erfundene Katalog dient nur der Pruefung des Leseprogramms.",
        "Version vom 1. Juli 2026",
        "Redaktionelle Version vom 5. Oktober 2026",
        "                                                                    2",
    ])

    def module(title, eng, semlage, sws, proofs, lp, pres, self_, kompetenz, vork, usage, page, section=None):
        lines = []
        if section:
            lines.append("          " + section)
        lines += [title, f"({eng})",
                  "Semesterlage                    " + semlage,
                  "Verantwortlich                   Studiendekan/in",
                  "Art der Lehrveranstaltung(en)    Vorlesung und Übung",
                  "Lehrveranstaltungen (SWS)      " + sws]
        lines += ["Leistungsnachweise              " + proofs[0]] + ["                                " + x
                                                                    for x in proofs[1:]]
        lines += ["Notenzusammensetzung          Note der Prüfung",
                  f"Leistungspunkte (ECTS)                                          {pres}h Präsenzstudium",
                  f"{lp}                                                               {self_}h Selbststudium",
                  f"                                                                Insgesamt: {pres + self_}h",
                  "Kompetenzziel: " + kompetenz,
                  "Inhalte:",
                  "   • Erfundener Inhalt eins,",
                  "   • Erfundener Inhalt zwei.",
                  "Grundlegende Literatur: Muster: Rechnen, Beispielverlag 2020.",
                  "Vorkenntnisse: " + vork,
                  "Eingangsvoraussetzungen:",
                  "Modulverwendbarkeit: " + usage + f".{page}"]
        return "\n".join(lines)

    p3 = module("Rechnen I", "Calculating I", "Wintersemester, jährlich", "Rechnen I (4+2) SWS",
                ["Studienleistung: Übung", "Prüfungsleistung: Klausur"], 10, 90, 210,
                "Sicherer Umgang mit erfundenen Zahlen.", "Schulkenntnisse",
                "Bachelorstudiengang Beispielmathematik", 3, section="2.1 Pflichtmodule Bachelor")
    p4 = module("Rechnen II", "Calculating II", "Sommersemester, jährlich", "Lineares Rechnen (4+2) SWS",
                ["Studienleistung: Übung", "Prüfungsleistung: Klausur oder mündliche Prüfung"], 10, 90, 210,
                "Vertiefter Umgang.", "Rechnen I", "Bachelorstudiengang Beispielmathematik", 4)
    p5 = module("Seminar Master", "Seminar Master", "Winter- und Sommersemester", "Ein Seminar (2) SWS",
                ["Prüfungsleistung: Präsentation mit Ausarbeitung (VbP)"], 5, 30, 120,
                "Vortragen.", "Rechnen II", "Masterstudiengang Beispielmathematik", 5,
                section="2.2 Module Master")
    p6 = "\n".join([
        "3 Lehrveranstaltungen",
        "Lineares Rechnen",
        "Mathematikbereich:     Reine Mathematik             Sprache:  Deutsch",
        "Leistungspunkte:        10                         SWS:     4+2",
        "Regelmäßigkeit:         jährlich, Sommersemester",
        "Inhalte: erfunden",
        "                                                                    6",
    ])
    return [toc, intro, p3, p4, p5, p6]


def maphy_meta(degree: str, key: str) -> dict:
    return {"university": "luh", "program": "Beispielmathematik", "degree": degree, "po": "2020",
            "code": key.split("|", 1)[1], "catalog_term": None, "term_hint": "2026",
            "regular_semesters": 6 if degree.startswith("B") else 4, "total_lp": 180 if degree.startswith("B") else 120,
            "source": {"url": "https://example.invalid/katalog_fach_beispiel.pdf", "fetched_at": None, "sha256": None},
            "program_key": key, "shared_catalog": True}


MAPHY_KEYS = {"bachelor": ("B.Sc.", "luh|beispielmathematik|b.sc.|2020"),
              "master": ("M.Sc.", "luh|beispielmathematik-1|m.sc.|2020")}


def ocr_page() -> dict:
    """Erfundene Vision-Ausgabe: Logo rechts oben (faellt weg), Kopf links, Tabelle mit Lesefehler 'Prutungsleistungen'"""
    def o(t, x, y, w=0.2, h=0.012, c=1.0):
        return {"t": t, "c": c, "x": x, "y": y, "bw": w, "bh": h}
    return {"w": 1785.0, "h": 2525.0, "obs": [
        o("Leibniz", 0.75, 0.047, 0.08), o("Universität", 0.75, 0.059, 0.1), o("Hannover", 0.75, 0.071, 0.08),
        o("Modulkatalog Fach Beispielkunde", 0.12, 0.074, 0.3),
        o("Pflichtmodul", 0.12, 0.12, 0.1), o("Grundlagen der Beispielkunde", 0.36, 0.1205, 0.3),
        o("Anbieter", 0.12, 0.14, 0.08), o("Institut fuer Beispielkunde", 0.36, 0.1402, 0.25),
        o("Häufigkeit des Angebots", 0.12, 0.16, 0.18), o("jedes Wintersemester", 0.36, 0.1598, 0.2),
        o("ECTS-LP/Workload", 0.12, 0.18, 0.15), o("5 LP / 150 Std.", 0.36, 0.18, 0.12),
        o("Prutungsleistungen", 0.12, 0.20, 0.16, c=0.5), o("Klausur (60 Minuten)", 0.36, 0.2003, 0.18),
        o("1", 0.5, 0.925, 0.01),
    ]}


def build() -> dict[str, object]:
    files: dict[str, object] = {}
    pages = phil_pages()
    files["phil-pages.json"] = pages
    files["phil-expected.json"] = {k: phil_kv_tabelle.parse(pages, phil_meta(k, d))[0] for k, d in PHIL_KEYS.items()}
    mp = maphy_pages()
    files["maphy-pages.json"] = mp
    files["maphy-expected.json"] = {name: maphy_katalog.parse(mp, maphy_meta(d, k))[0]
                                    for name, (d, k) in MAPHY_KEYS.items()}
    page = ocr_page()
    files["ocr-page.json"] = page
    files["ocr-expected.json"] = {"plain": ocr_pages.page_text(page), "layout": ocr_pages.layout_text(page),
                                  "template": ocr_pages.template_of([ocr_pages.page_text(page)] * 3)}
    return files


def main() -> int:
    check = "--check" in sys.argv
    files = build()
    bad = []
    OUT.mkdir(parents=True, exist_ok=True)
    for name, value in files.items():
        text = json.dumps(value, ensure_ascii=False, indent=1) + "\n"
        path = OUT / name
        if check:
            if not path.exists() or path.read_text() != text:
                bad.append(name)
        else:
            path.write_text(text)
    if check and bad:
        print("abweichend:", ", ".join(bad))
        return 1
    print("ok" if check else f"geschrieben: {len(files)} Dateien nach {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
