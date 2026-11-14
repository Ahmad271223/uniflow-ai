"""Erzeugt packages/shared-contracts/fixtures/study-catalog/program-search.json: Suche "Was studierst du?" nach der Regel
`study_catalog.program_matches` ueber alle Studiengaenge der Universitaet Hildesheim im Register. Anfragen: das
Studienangebot der Uni-Seiten (Bachelor, Master, Lehramtsfaecher; Quellenliste des Inhabers vom 14.11.2026, nur die
Namen) und Kurzformen. Swift (StudyProgramChangeTests) und das Web (tests/js/study-plan.test.mjs) muessen dieselben
Treffer liefern; jede Anfrage muss mindestens einen haben.
Aufruf im Projektordner: python tools/gen-program-search-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app import study_catalog as sc  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog" / "program-search.json"

BACHELOR = ["Angewandte Informatik B.Sc.", "English Applied Linguistics B.A.", "Erziehungswissenschaft B.A.", "IMIT B.Sc.",
            "Internationale Kommunikation und Übersetzen B.A.", "Internationales Informationsmanagement B.A.",
            "Digitale Sozialwissenschaften", "Informationswissenschaft und interkulturelle Kommunikation",
            "Interkulturelle Sprachwissenschaft", "Linguistik", "Kulturwissenschaften und künstlerische Praxis B.A.",
            "Lehramt Grundschule", "Lehramt Haupt- und Realschule", "Literarisches Schreiben und Kulturjournalismus B.A.",
            "Medieninformatik B.Sc.", "Philosophie, Künste, Medien B.A.", "Polyvalenter Zwei-Fächer-Bachelor", "Psychologie B.Sc.",
            "Sozialpädagogik B.A.", "Sport, Gesundheit und Leistung B.A.", "Szenische Künste B.A.", "Umweltsicherung B.Sc.",
            "Wirtschaft Plus B.Sc.", "Wirtschaftsinformatik B.Sc.", "Umweltinformatik B.Sc."]
MASTER = ["Angewandte Informatik M.Sc.", "Barrierefreie Kommunikation M.A.", "Data Analytics M.Sc.", "DaZ/DaF M.A.",
          "Deutsch-Französischer Doppel-Master Kulturvermittlung M.A.", "Erziehungswissenschaft (Kindheitspädagogik/Diversität) M.A.",
          "Future Analytics: AI & Audio Worlds", "IMIT M.Sc.", "Internationale Fachkommunikation, Sprachen und Technik M.A.",
          "IIM Informationswissenschaft M.A.", "IIM Sprachwissenschaft und Interkulturelle Kommunikation M.A.",
          "Kulturvermittlung, Kulturpolitik und Transformation M.A.", "Künste und Gegenwartskulturen transdisziplinär M.A.",
          "Lehramt M.Ed.", "Lehramt HRS Quereinstieg M.Ed.", "Literarisches Schreiben und Lektorieren M.A.",
          "Medientext und Medienübersetzung M.A.", "Philosophie und Künste interkulturell M.A.", "Psychologie M.Sc.",
          "Psychologie Klinische Psychologie und Psychotherapie M.Sc.", "Sozial- und Organisationspädagogik M.A.",
          "Software Engineering M.Sc.", "Soziale Dienste M.A.", "Sportwissenschaft M.Sc.", "Umweltinformatik M.Sc.",
          "Umwelt, Naturschutz und Nachhaltigkeit M.Sc.", "Wirtschaftsinformatik M.Sc."]
FAECHER = ["Biologie", "Chemie", "Deutsch", "Englisch", "Evangelische Theologie", "Geographie", "Geschichte", "Katholische Theologie",
           "Kunst", "Mathematik", "Musik", "Physik", "Politikwissenschaft", "Sachunterricht", "Sport", "Technik", "Wirtschaft",
           "Pädagogik", "Psychologie", "Philosophie", "Soziologie", "Informatik"]
EXTRA = ["", "imit", "IKÜ", "daf", "ghr", "2FB", "sozialp", "lehramt grundschule deutsch"]


def build() -> dict:
    progs = sc.programs(university="hildesheim")
    cases = []
    for q in dict.fromkeys(BACHELOR + MASTER + FAECHER + EXTRA):
        hits = [f"{p['program']} | {p['degree']}" for p in sc.filter_programs(progs, q)]
        cases.append({"query": q, "hits": hits})
    return {"note": "Erzeugt von tools/gen-program-search-fixture.py - nicht von Hand aendern.", "university": "hildesheim",
            "programs": len(progs), "cases": cases}


def main() -> int:
    data = build()
    empty = [c["query"] for c in data["cases"] if not c["hits"]]
    if empty:
        print("ohne Treffer:", empty)
        return 1
    content = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv[1:]:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == content
        print(("aktuell: " if ok else "VERALTET: ") + str(OUT.relative_to(ROOT)))
        return 0 if ok else 1
    OUT.write_text(content, encoding="utf-8")
    print("geschrieben:", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
