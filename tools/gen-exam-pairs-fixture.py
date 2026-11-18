"""Erzeugt packages/shared-contracts/fixtures/local-backend/exam-pairs.json: Klausur und Loesung zusammenfuehren
(app/exam_pairs.py, im Swift-Kern ExamPairs.swift), 17.11.2026. Ausgedachte Dateinamen nach dem Muster echter Kurse.

Inhalt:
- keys: Schluessel eines Dateinamens (solution_key, plain_key, numbers, Kennung aus ID_TAIL)
- terms: Jahrgang aus Ordner und Name (term): [Rang, Bezeichnung] oder null
- links: je Fall die Dateien eines Moduls und die Loesungsdateien je Aufgabendatei (links)
- groups: je Fall die Dateien eines Moduls, die Dateien des Blocks "Klausuren & Altklausuren" und die Gruppen nach
  Jahrgang (groups), wie sie das Moduldetail unter `exam_groups` liefert

Geprueft von Swift (ExamPairsTests) und Python (tests/test_exam_pairs.py).
Aufruf im Projektordner: python tools/gen-exam-pairs-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys

from schema_source import ROOT, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "exam-pairs.json"

KEY_NAMES = [
    "kk3a.pdf", "sol3a.pdf", "kk3a_sol.pdf", "sol.pdf", "SOL 2.PDF", "sol-4.pdf", "Solar_2.pdf", "Konsole 1.pdf", "Sol-Gel.pdf",
    "KK1.pdf", "KK1loes.pdf", "gk.pdf", "gk_lsg.pdf", "KK2bWS2122auf.pdf", "KK2bWS2122lsg.pdf", "kkw17_auf.pdf", "kkw17_loes.pdf",
    "TK.pdf", "Lösungen zu TK.pdf", "Loesung zur Probeklausur.pdf", "Lösung zum Blatt 3.pdf", "Lösung für Blatt 4.pdf",
    "Loesung fuer Blatt 5.pdf", "Lösung von Blatt 6.pdf", "Zusatzaufgaben.pdf", "Vonhier.pdf", "Lösungen.pdf", "Musterlösung.pdf",
    "Muster-Klausuraufgaben-WS1920.pdf", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf", "Klausur WS1920 - A4.pdf",
    "A4.pdf", "A4_lsg.pdf", "A3 Lsg.pdf", "A5-Blatt 2.pdf", "A6-Klausur-WS1920.pdf", "Übung 3.pdf", "Lösung 3.pdf",
    "Übungsblatt 10 Lösung.pdf", "Blatt 1.pdf", "Blatt 1.2 (Lösung).pdf", "Lösung 7.pdf", "Übung 7.pdf",
    "LÖSUNG 8.PDF", "blatt٣.pdf", "Blatt 3.tar.gz", "", None,
]

# (Ordner, Name)
TERM_CASES = [
    ("Alte Klausuren/WS 22/23", "KK1.pdf"), ("Alte Klausuren/WS25/26", "KK1.pdf"), ("Alte Klausuren/WS 20/21", "Lösungen.pdf"),
    ("Alte Klausuren", "KK2bWS2122lsg.pdf"), ("Alte Klausuren", "Klausur SS23.pdf"), ("Klausuren", "Klausur_SoSe_2021.pdf"),
    ("Klausuren", "Klausur WiSe 2022/23.pdf"), ("Klausuren", "Klausur WS 2021.pdf"), ("Klausuren", "KlausurWS2021.pdf"),
    ("Klausuren", "Klausur_ws1920.pdf"), ("Klausuren", "Klausur WS 98/99.pdf"), ("Klausuren", "Klausur SS 1999.pdf"),
    ("Klausuren/Wintersemester 2019/20", "Klausur.pdf"), ("Klausuren/Sommersemester 2018", "Klausur.pdf"),
    ("Klausuren/Sommer 17", "Klausur.pdf"), ("Klausuren/Winter 16", "Klausur.pdf"), ("Klausuren/2019", "Klausur.pdf"),
    ("Klausuren", "Klausur_2018-02-14.pdf"), ("Klausuren", "Klausur 2051.pdf"), ("Klausuren", "Klausur 12345.pdf"),
    ("Alte Klausuren/WS 22/23", "Klausur SS 21.pdf"), ("Klausuren SS 20/Wiederholung WS 20/21", "x.pdf"),
    ("Klausuren", "abschluss2023.pdf"), ("Klausuren", "news24.pdf"), ("Klausuren", "Klasse 12.pdf"), ("Klausuren", "KLAUSURWS23.pdf"),
    ("Klausuren", "ISS 2023.pdf"), ("Klausuren", "kkw17_auf.pdf"), ("Klausuren", "WS 123.pdf"), ("Klausuren", "WS 2324.pdf"),
    ("Klausuren", "SS2324.pdf"), ("Klausuren", "ws'22.pdf"), ("Klausuren", "SS-19.pdf"), ("Klausuren", "Pruefung.ss21"),
    ("WiSe 2026/27", "Blatt.pdf"), ("", "Klausur.pdf"), (None, None), ("Alte Kurzklausuren", "gk.pdf"), ("Klausur/WS ٢٢", "x.pdf"),
]


def _f(fid: str, name: str, folder: str | None, doc_type: str, course: str = "k2") -> dict:
    return {"id": fid, "name": name, "course_id": course, "studip_folder": folder, "doc_type": doc_type}


K, L, U = "klausur", "loesung", "uebung"
OLD = "Alte Klausuren/WS 21/22"

LINK_CASES = {
    "gleicher Ordner": [
        _f("k0", "kk0b.pdf", OLD, K), _f("s0", "sol0b.pdf", OLD, L), _f("k3", "kk3a.pdf", OLD, K), _f("s3", "sol3a.pdf", OLD, L),
        _f("k4", "kk4a.pdf", OLD, K), _f("tk", "TK.pdf", "Probeklausur", K), _f("tks", "Lösungen zu TK.pdf", "Probeklausur", L),
        _f("mk", "Muster-Klausuraufgaben-WS1920.pdf", "Klausur", K), _f("mks", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf", "Klausur", L),
        _f("a", "KK1.pdf", "Kurzklausuren", K), _f("as", "KK1loes.pdf", "Kurzklausuren", L), _f("b", "gk.pdf", "Kurzklausuren", K),
        _f("bs", "gk_lsg.pdf", "Kurzklausuren", L), _f("d", "KK2bWS2122auf.pdf", "Kurzklausuren", K),
        _f("ds", "KK2bWS2122lsg.pdf", "Kurzklausuren", L), _f("e", "kkw17_auf.pdf", "Kurzklausuren", K),
        _f("es", "kkw17_loes.pdf", "Kurzklausuren", L),
    ],
    "gleiche Namen in drei Semestern": [
        _f("k21", "kk1b.pdf", "Alte Klausuren/WS 21/22", K), _f("s21", "sol1b.pdf", "Alte Klausuren/WS 21/22", L),
        _f("k20", "kk1b.pdf", "Alte Klausuren/WS 20/21", K), _f("s20", "sol1b.pdf", "Alte Klausuren/WS 20/21", L),
        _f("k19", "kk1b.pdf", "Alte Klausuren/WS 19/20", K), _f("p21", "KK2.pdf", "Alte Klausuren/WS 21/22", K),
        _f("q21", "KK2loes.pdf", "Alte Klausuren/WS 21/22", L), _f("p20", "KK2.pdf", "Alte Klausuren/WS 20/21", K),
        _f("q20", "KK2loes.pdf", "Alte Klausuren/WS 20/21", L), _f("p19", "KK2.pdf", "Alte Klausuren/WS 19/20", K),
    ],
    "Kennung nur eindeutig": [
        _f("u3", "Übung 3.pdf", "Übungen", U), _f("l3", "Lösung 3.pdf", "Übungen", L), _f("b1", "Blatt 1.pdf", "Blätter", U),
        _f("b10", "Blatt 10.pdf", "Blätter", U), _f("l10", "Lösung 10.pdf", "Blätter", L), _f("g2", "GU 2.pdf", "Gemischt", U),
        _f("h2", "HU 2.pdf", "Gemischt", U), _f("l2", "Lösung 2.pdf", "Gemischt", L), _f("x5", "Blatt 5.pdf", "Aufgaben", U),
        _f("y5", "Lösung 5.pdf", "Lösungen", L), _f("v6", "Blatt 6.pdf", "Doppelt", U), _f("w6", "Lösung 6.pdf", "Doppelt", L),
        _f("w6b", "Lsg 6.pdf", "Doppelt", L),
    ],
    "Loesungen im eigenen Ordner": [
        _f("b2", "Blatt 2.pdf", "Übungsblätter", U), _f("l2", "Lösung Blatt 2.pdf", "Lösungen", L),
        _f("b7", "Übungsblatt 7.pdf", "Übungsblätter", U), _f("l7", "Übungsblatt 7 Musterlösung.pdf", "Lösungen", L),
        _f("b1", "Übungsblatt 1.pdf", "Übungsblätter", U), _f("l10", "Übungsblatt 10 Lösung.pdf", "Lösungen", L),
        _f("b8", "Blatt 8.pdf", "Übungsblätter", U), _f("l8a", "Blatt 8 Lösung.pdf", "Lösungen", L),
        _f("l8b", "Blatt_8_Loesung.pdf", "Lösungen alt", L),
    ],
    "Sammeldatei": [
        _f("k", "Klausur.pdf", "Alte Klausuren/SS 21", K), _f("ks", "Lösung.pdf", "Alte Klausuren/SS 21", L),
        _f("m1", "KK1.pdf", "Alte Klausuren/WS 20/21", K), _f("m2", "KK2.pdf", "Alte Klausuren/WS 20/21", K),
        _f("m3", "KK3.pdf", "Alte Klausuren/WS 20/21", K), _f("m3s", "KK3loes.pdf", "Alte Klausuren/WS 20/21", L),
        _f("ms", "Lösungen.pdf", "Alte Klausuren/WS 20/21", L),
        _f("r", "Probeklausur.pdf", "", K), _f("rs", "Lösung.pdf", "", L), _f("n", "Probeklausur.pdf", None, K, "k3"),
        _f("ns", "Lösung.pdf", None, L, "k3"), _f("u", "Blatt 4.pdf", "Übungen", U), _f("us", "Lösungen.pdf", "Übungen", L),
        _f("z", "Klausur.pdf", "Alte Klausuren/SS 19", K), _f("z1", "Lösung.pdf", "Alte Klausuren/SS 19", L),
        _f("z2", "Musterlösung.pdf", "Alte Klausuren/SS 19", L),
        _f("o", "Klausur.pdf", "Alte Klausuren/SS 21", K, "k3"),          # gleicher Ordnername, anderer Kurs
    ],
    "ohne Loesungen": [_f("k", "Klausur.pdf", "Klausur", K), _f("u", "Blatt 1.pdf", "Übungen", U)],
    "leer": [],
}

# Moduldateien; der Block sind alle Klausuren und Loesungen daraus ausser den IDs in `outside` (Loesungen einer
# normalen Woche, vom Nutzer verschobene Dateien)
GROUP_CASES = {
    "Jahrgaenge wie im echten Kurs": {"outside": ["ub", "ul"], "files": [
        _f("a1", "KK1.pdf", "Alte Klausuren/WS 22/23", K), _f("a1s", "KK1loes.pdf", "Alte Klausuren/WS 22/23", L),
        _f("a2", "KK2.pdf", "Alte Klausuren/WS 22/23", K), _f("a2s", "KK2loes.pdf", "Alte Klausuren/WS 22/23", L),
        _f("a10", "KK10.pdf", "Alte Klausuren/WS 22/23", K),
        _f("b1", "kk1b.pdf", "Alte Klausuren/WS 23/24", K), _f("b1s", "sol1b.pdf", "Alte Klausuren/WS 23/24", L),
        _f("b0", "kk0b.pdf", "Alte Klausuren/WS 23/24", K), _f("b0s", "sol0b.pdf", "Alte Klausuren/WS 23/24", L),
        _f("c1", "KK1.pdf", "Alte Klausuren/WS 20/21", K), _f("c2", "KK2.pdf", "Alte Klausuren/WS 20/21", K),
        _f("cs", "Lösungen.pdf", "Alte Klausuren/WS 20/21", L),
        _f("d1", "KK1aWS2425auf.pdf", "Alte Klausuren/WS25/26", K), _f("d1s", "KK1aWS2425lsg.pdf", "Alte Klausuren/WS25/26", L),
        _f("e1", "Klausur SS 24.pdf", "Alte Klausuren", K), _f("e1s", "Klausur SS 24 Lösung.pdf", "Alte Klausuren", L),
        _f("f1", "gk.pdf", "Alte Kurzklausuren", K), _f("f1s", "gk_lsg.pdf", "Alte Kurzklausuren", L),
        _f("g1", "Probeklausur.pdf", "", K), _f("g2", "Lsg_unbekannt.pdf", "", L),
        _f("h1", "Lösung ohne Klausur.pdf", "Alte Klausuren/WS 22/23", L),
        _f("ub", "Blatt 3.pdf", "Übungen", U), _f("ul", "Lösung Blatt 3.pdf", "Übungen", L),
    ]},
    "Loesung in anderem Ordner und doppelt": {"outside": [], "files": [
        _f("k1", "Klausur WS 21/22.pdf", "Klausuren", K), _f("l1", "Klausur WS 21/22 Lösung.pdf", "Lösungen", L),
        _f("l1b", "Klausur_WS_21/22_Loesung.pdf", "Lösungen", L),
        _f("k2", "klausur ss 22.pdf", "Klausuren", K), _f("K3", "Klausur SS 22.pdf", "Klausuren", K, "k3"),
        _f("l2", "klausur ss 22 lsg.pdf", "Klausuren", L),
    ]},
    "nur Loesungen": {"outside": [], "files": [_f("s1", "Lösung.pdf", "Klausur 2019", L), _f("s2", "Musterlösung.pdf", "Klausur", L)]},
    "leer": {"outside": [], "files": []},
}


def build() -> dict:
    from app import exam_pairs as ep
    keys = []
    for n in KEY_NAMES:
        k = ep.solution_key(n)
        m = ep.ID_TAIL.match(k)
        keys.append({"name": n, "key": k, "plain": ep.plain_key(n), "numbers": ep.numbers(k), "tail": m.group(1) if m else None})
    terms = [{"folder": f, "name": n, "term": ep.term(f, n)} for f, n in TERM_CASES]
    links = [{"case": name, "files": files, "links": ep.links(files)} for name, files in LINK_CASES.items()]
    groups = []
    for name, c in GROUP_CASES.items():
        block = [f for f in c["files"] if f["doc_type"] in (K, L) and f["id"] not in c["outside"]]
        groups.append({"case": name, "files": c["files"], "block": [f["id"] for f in block],
                       "groups": ep.groups(block, ep.links(c["files"]))})
    return {"generator": "tools/gen-exam-pairs-fixture.py", "keys": keys, "terms": terms, "links": links, "groups": groups}


def main() -> int:
    sys.path.insert(0, str(ROOT))
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    return 0 if write_or_check(OUT, text, "--check" in sys.argv[1:]) or "--check" not in sys.argv[1:] else 1


if __name__ == "__main__":
    sys.exit(main())
