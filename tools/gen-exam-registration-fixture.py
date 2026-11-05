"""Pruefungsanmeldung (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Datendatei pruefen, Kopie im Swift-Kern und Faelle.

Quelle der Wahrheit: packages/shared-contracts/exam-registration-luh.json (Meldezeitraeume der LUH je Studiengang aus den
oeffentlichen Terminseiten des Pruefungsamts, mit Abrufdatum). Dieses Werkzeug
- prueft die Datei (ISO-Daten, Beginn <= Ende, Verweise auf Tabellen, nur https auf www.uni-hannover.de),
- schreibt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/ExamRegistration/ExamRegistrationData.swift (woertlich),
- schreibt packages/shared-contracts/fixtures/exam-registration/period-cases.json: Zuordnung Studiengang -> Terminseite
  und Phase des Fensters je Tag aus app/exam_registration.py (der Kern prueft dieselben Faelle).

--from-cache DIR: liest gespeicherte Seiten (DIR/termine-<slug>.html, DIR/termine-urls.txt aus der Sitemap,
DIR/fetched_at.txt) und schreibt die Datendatei neu. Laedt selbst nichts (Abruf von Hand, wenige Seiten, >= 2,5 s Abstand).

Aufruf im Projektordner: .venv/bin/python tools/gen-exam-registration-fixture.py [--check | --from-cache DIR]
"""
from __future__ import annotations

import json
import re
import sys
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from schema_source import ROOT, write_or_check  # noqa: E402

from app import exam_registration as er  # noqa: E402

DATA = ROOT / "packages" / "shared-contracts" / "exam-registration-luh.json"
SWIFT = ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/ExamRegistration/ExamRegistrationData.swift"
CASES = ROOT / "packages" / "shared-contracts" / "fixtures" / "exam-registration" / "period-cases.json"

PAGE_BASE = "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/"
GENERAL = {
    "url": PAGE_BASE + "pruefungsanmeldung",
    "title": "Prüfungsanmeldung und Musterprüfungsordnung (Akademisches Prüfungsamt der LUH)",
}
QIS_MENU = ("https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet"
            "?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm")
RULES = [
    {"form": "Klausur", "withdraw_days_before": 7,
     "text": "Klausur (auch mit Antwortwahl): Abmeldung bis 7 Tage vor dem Prüfungstermin im QIS."},
    {"form": "Mündliche Prüfung", "withdraw_days_before": 1,
     "text": "Mündliche Prüfung und Sportpraktische Präsentation: Abmeldung bis 1 Tag vorher, schriftlich oder per E-Mail."},
    {"form": "VbP", "withdraw_days_before": None,
     "text": "Veranstaltungsbegleitende Prüfung (VbP) und Leistungen mit Abgabe: Abmeldung bis zum Beginn der Prüfungsleistung."},
    {"form": "Abschlussarbeit", "withdraw_days_before": None,
     "text": "Bachelor-, Master- und Studienarbeiten: kein Meldezeitraum, eigener Antrag; keine Abmeldung."},
]
NOTE = ("Meldezeitraeume der LUH aus den oeffentlichen Terminseiten des Pruefungsamts (Quelle je Studiengang in url, "
        "gelesen am checked_at). Daten nur fuer gepruefte Studiengaenge (table gesetzt); alle anderen nur mit Link. "
        "Neu lesen: tools/gen-exam-registration-fixture.py --from-cache DIR. docs/PRUEFUNGSANMELDUNG-2026-11-05.md")
KINDS = {"meldung", "pruefung", "bewertung", "vbp_meldung", "vbp_pruefung", "vbp_bewertung"}


# MARK: Pruefen

def check_data(d: dict) -> list[str]:
    errs: list[str] = []
    if d.get("v") != 1 or d.get("university") != "luh":
        errs.append("v/university")
    def https_luh(u: str | None) -> bool:
        return isinstance(u, str) and u.startswith("https://www.uni-hannover.de/")
    if not https_luh((d.get("general") or {}).get("url")):
        errs.append("general.url")
    if not str(d.get("qis_menu") or "").startswith("https://qis.verwaltung.uni-hannover.de/"):
        errs.append("qis_menu")
    tables = d.get("tables") or {}
    for key, t in tables.items():
        for term in t.get("terms") or []:
            if not re.fullmatch(r"(WiSe \d\d/\d\d|SoSe \d\d)", term.get("term", "")):
                errs.append(f"tables.{key}.term {term.get('term')}")
            for p in term.get("periods") or []:
                try:
                    s, e = date.fromisoformat(p["start"]), date.fromisoformat(p["end"])
                except (KeyError, ValueError):
                    errs.append(f"tables.{key}.{term.get('term')}: Datum")
                    continue
                if s > e:
                    errs.append(f"tables.{key}.{term.get('term')}.{p.get('label')}: Beginn nach Ende")
                if p.get("kind") not in KINDS or p.get("n") not in (1, 2) or not p.get("label"):
                    errs.append(f"tables.{key}.{term.get('term')}: Art {p.get('kind')}")
    seen = set()
    for p in d.get("programs") or []:
        slug = p.get("slug") or ""
        if not re.fullmatch(r"[a-z0-9-]+", slug) or slug in seen:
            errs.append(f"programs.{slug}: slug")
        seen.add(slug)
        if not https_luh(p.get("url")):
            errs.append(f"programs.{slug}: url")
        if p.get("table") is not None and p["table"] not in tables:
            errs.append(f"programs.{slug}: table {p['table']}")
        if p.get("table") is not None and not p.get("checked_at"):
            errs.append(f"programs.{slug}: checked_at")
    return errs


# MARK: Aus gespeicherten Seiten lesen

class TermineParser(HTMLParser):
    """h3 "Wintersemester 2026/27" + table.contenttable mit Zeilen (Bezeichnung, Zeitraum); dazu die Variante"""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.h3: list[str] | None = None
        self.heading = ""
        self.tables: list[tuple[str, list[list[str]]]] = []
        self.rows: list[list[str]] | None = None
        self.cell: list[str] | None = None
        self.text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "h3":
            self.h3 = []
        elif tag == "table" and "contenttable" in (dict(attrs).get("class") or ""):
            self.rows = []
        elif tag == "tr" and self.rows is not None:
            self.rows.append([])
        elif tag in ("td", "th") and self.rows is not None:
            self.cell = []

    def handle_endtag(self, tag):
        if tag == "h3" and self.h3 is not None:
            self.heading = " ".join("".join(self.h3).split())
            self.text.append(self.heading)
            self.h3 = None
        elif tag == "table" and self.rows is not None:
            self.tables.append((self.heading, [r for r in self.rows if r]))
            self.rows = None
        elif tag in ("td", "th") and self.cell is not None and self.rows:
            self.rows[-1].append(" ".join("".join(self.cell).replace("\xa0", " ").split()))
            self.cell = None

    def handle_data(self, data):
        if self.h3 is not None:
            self.h3.append(data)
        if self.cell is not None:
            self.cell.append(data)


def term_name(heading: str) -> str | None:
    m = re.fullmatch(r"Wintersemester (\d{4})/(\d{2,4})", heading)
    if m:
        y = int(m.group(1))
        return f"WiSe {y % 100:02d}/{(y + 1) % 100:02d}"
    m = re.fullmatch(r"Sommersemester (\d{4})", heading)
    return f"SoSe {int(m.group(1)) % 100:02d}" if m else None


def period_of(label: str, when: str) -> dict | None:
    dates = re.findall(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", when)
    if not dates:
        return None                                       # ohne Jahr ("15.04. - 30.04."): nicht sicher -> weglassen
    iso = [f"{y}-{int(m):02d}-{int(d):02d}" for d, m, y in dates]
    clean = re.sub(r"\*+", "", label).replace(" - ", " ").strip()
    clean = " ".join(clean.split())
    low = clean.lower()
    n = 2 if re.match(r"2\.", low) or "2. pz" in low else 1
    clean = re.sub(r"^[12]\.\s*", "", clean)
    if "meldezeitraum" in low:
        kind = "meldung"
    elif "prüfungszeitraum" in low:
        kind = "pruefung"
    elif "bewertungsfrist" in low:
        kind = "bewertung"
    else:
        return None
    if "vbp" in low:
        kind = "vbp_" + kind
    return {"kind": kind, "n": n, "label": clean, "start": iso[0], "end": iso[-1]}


def read_page(html: str) -> tuple[str | None, list[dict]]:
    p = TermineParser()
    p.feed(html)
    variant = None
    for t in p.text:
        m = re.search(r"gilt die Variante (\d)", t)
        if m:
            variant = m.group(1)
    terms = []
    for heading, rows in p.tables:
        name = term_name(heading)
        if not name:
            continue
        periods = []
        complete = True
        for r in rows:
            if len(r) < 2:
                continue
            per = period_of(r[0], r[1])
            if per is None:
                complete = False
                continue
            periods.append(per)
        if periods and complete:
            terms.append({"term": name, "periods": periods})
    return variant, terms


def from_cache(cache: Path) -> dict:
    urls = [u.strip() for u in (cache / "termine-urls.txt").read_text(encoding="utf-8").splitlines() if u.strip()]
    fetched = (cache / "fetched_at.txt").read_text(encoding="utf-8").strip()[:10]
    tables: dict[str, dict] = {}
    by_content: dict[str, str] = {}
    programs = []
    for u in sorted(set(urls)):
        m = re.fullmatch(re.escape(PAGE_BASE) + r"([a-z0-9-]+)/termine", u)
        if not m:
            continue
        slug = m.group(1)
        entry = {"slug": slug, "url": u, "table": None, "variant": None, "checked_at": None}
        page = cache / f"termine-{slug}.html"
        if page.exists():
            variant, terms = read_page(page.read_text(encoding="utf-8"))
            if terms:
                content = json.dumps(terms, ensure_ascii=False, sort_keys=True)
                key = by_content.get(content)
                if key is None:
                    key = f"luh-v{variant or 'x'}"
                    if key in tables:
                        key = f"{key}-{slug}"
                    tables[key] = {"variant": variant, "terms": terms}
                    by_content[content] = key
                entry.update(table=key, variant=variant, checked_at=fetched)
        programs.append(entry)
    return {"v": 1, "university": "luh", "note": NOTE, "checked_at": fetched, "general": GENERAL, "qis_menu": QIS_MENU,
            "rules": RULES, "tables": tables, "programs": programs}


# MARK: Faelle

PROGRAM_CASES = [
    ("Technische Informatik (PO-Version 2017)", "B.Sc."),
    ("Technische Informatik", "M.Sc."),
    ("Informatik", "Bachelor of Science"),
    ("Mathematik", "B.Sc."),
    ("Elektrotechnik und Informationstechnik", "B.Sc."),
    ("Architektur", "B.Sc."),
    ("Technische Informatik (PO-Version 2017)", None),
    ("Geodäsie und Geoinformatik", "M.Sc."),
    ("Kochkunst", "B.Sc."),
    ("", "B.Sc."),
]
DAYS = ["2026-10-20", "2026-11-05", "2026-11-09", "2026-11-15", "2026-11-22", "2026-11-23", "2027-02-27", "2027-03-01",
        "2027-03-08", "2027-04-30", "2027-10-01"]


def cases(d: dict) -> dict:
    progs = []
    for name, degree in PROGRAM_CASES:
        p = er.find_program(d, name, degree)
        progs.append({"name": name, "degree": degree, "slug": p["slug"] if p else None,
                      "has_table": bool(p and p.get("table"))})
    phases = []
    for name, degree in PROGRAM_CASES[:6]:
        p = er.find_program(d, name, degree)
        for day in DAYS:
            for kind in ("meldung", "vbp_meldung"):
                w = er.window_state(d, p, day, kind)
                phases.append({"name": name, "degree": degree, "today": day, "kind": kind, "window": w,
                               "periods": len(er.term_periods(d, p, w["term"] if w else None))})
    slugs = [{"text": t, "slug": er.slugify(er.program_name(t))} for t in
             ["Technische Informatik (PO-Version 2017)", "Geodäsie und Geoinformatik", "Landschaftsarchitektur und Umweltplanung",
              "Lehramt an berufsbildenden Schulen", "  Wirtschafts-Wissenschaften  ", "Größe & Maß"]]
    degrees = [{"degree": g, "text": t, "slugs": er.degree_slugs(g, t)} for g, t in
               [("B.Sc.", ""), ("M. Sc.", ""), ("B.A.", ""), ("M.Ed.", ""), (None, "Bachelor of Arts"), ("Master", ""), (None, "")]]
    return {"generator": "tools/gen-exam-registration-fixture.py", "soon_days": er.SOON_DAYS, "programs": progs,
            "phases": phases, "slugs": slugs, "degrees": degrees}


def swift_text(raw: str) -> str:
    assert '"""#' not in raw
    return ("// Erzeugt von tools/gen-exam-registration-fixture.py aus packages/shared-contracts/exam-registration-luh.json"
            " - nicht von Hand aendern.\nenum ExamRegistrationData {\n    static let json = #\"\"\"\n"
            + raw.rstrip("\n") + "\n\"\"\"#\n}\n")


def main() -> int:
    args = sys.argv[1:]
    check = "--check" in args
    if "--from-cache" in args:
        cache = Path(args[args.index("--from-cache") + 1]).expanduser()
        d = from_cache(cache)
        DATA.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"geschrieben: {DATA.relative_to(ROOT)} ({sum(1 for p in d['programs'] if p['table'])} mit Daten, "
              f"{len(d['programs'])} Studiengaenge)")
    raw = DATA.read_text(encoding="utf-8")
    d = json.loads(raw)
    errs = check_data(d)
    if errs:
        print("FEHLER in der Datendatei:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1
    ok = write_or_check(SWIFT, swift_text(raw), check)
    ok = write_or_check(CASES, json.dumps(cases(d), ensure_ascii=False, indent=1) + "\n", check) and ok
    return 1 if check and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
