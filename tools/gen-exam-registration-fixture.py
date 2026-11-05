"""Pruefungsanmeldung (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Datendateien pruefen, Kopie im Swift-Kern und Faelle.

Quellen der Wahrheit (je Hochschule, aus oeffentlichen Seiten, mit Abrufdatum):
- packages/shared-contracts/exam-registration-luh.json: Meldezeitraeume der LUH je Studiengang (Terminseiten des
  Pruefungsamts),
- packages/shared-contracts/exam-registration-hildesheim.json: Uni Hildesheim, Start der POS-Anmeldung im LSF (keine
  einheitliche Frist, `open_end`), Zustaendigkeiten der Pruefungsaemter je Studiengang (nur Link), Regeln.
Dieses Werkzeug
- prueft beide Dateien (ISO-Daten, Beginn <= Ende, Verweise auf Tabellen, nur https auf den Seiten der Hochschule),
- schreibt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/ExamRegistration/ExamRegistrationData.swift (beide
  woertlich: `ExamRegistrationData.luh`, `ExamRegistrationData.hildesheim`),
- schreibt packages/shared-contracts/fixtures/exam-registration/period-cases.json: Zuordnung Studiengang -> Terminseite
  und Phase des Fensters je Tag aus app/exam_registration.py (der Kern prueft dieselben Faelle; Hildesheim unter
  "hildesheim").

--from-cache DIR: liest gespeicherte LUH-Seiten (DIR/termine-<slug>.html, DIR/termine-urls.txt aus der Sitemap,
DIR/fetched_at.txt) und schreibt die LUH-Datei neu.
--from-cache-hildesheim DIR: liest die gespeicherte Seite "Zuständigkeiten nach Studiengängen"
(DIR/studium__studierende__pruefungsamt__zustaendigkeiten-nach-studiengaengen.html) und DIR/fetched_at.txt und schreibt
die Hildesheim-Datei neu; Zeitraeume und Regeln stehen unten (HILDESHEIM_*), abgeschrieben aus den Seiten in
HILDESHEIM_SOURCES. Laedt selbst nichts (Abruf von Hand, wenige Seiten, >= 2,5 s Abstand, robots.txt beachten).

Aufruf im Projektordner: .venv/bin/python tools/gen-exam-registration-fixture.py [--check | --from-cache DIR |
--from-cache-hildesheim DIR]
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
DATA_HILDESHEIM = ROOT / "packages" / "shared-contracts" / "exam-registration-hildesheim.json"
DATA_HSH = ROOT / "packages" / "shared-contracts" / "exam-registration-hsh.json"   # tools/hsh-exam-registration.py
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
# je Hochschule: Seiten (Quelle) und Pruefungssystem (Knopf "Im QIS/LSF anmelden")
HOSTS = {
    "luh": ("https://www.uni-hannover.de/", "https://qis.verwaltung.uni-hannover.de/"),
    "hildesheim": ("https://www.uni-hildesheim.de/", "https://lsf.uni-hildesheim.de/"),
    # Hochschule Hannover: Seiten der Fakultaeten f1..f5 und das Campusmanagement (HISinOne)
    "hsh": (("https://www.hs-hannover.de/",) + tuple(f"https://f{i}.hs-hannover.de/" for i in range(1, 6))
            + ("https://campusmanagement.hs-hannover.de/",), "https://campusmanagement.hs-hannover.de/"),
}


# MARK: Pruefen

def check_data(d: dict, university: str = "luh") -> list[str]:
    errs: list[str] = []
    if d.get("v") != 1 or d.get("university") != university or university not in HOSTS:
        return ["v/university"]
    site, system_host = HOSTS[university]
    def https_luh(u: str | None) -> bool:
        return isinstance(u, str) and u.startswith(site)
    if not https_luh((d.get("general") or {}).get("url")):
        errs.append("general.url")
    if not str(d.get("qis_menu") or "").startswith(system_host):
        errs.append("qis_menu")
    for src in d.get("sources") or []:
        if not https_luh(src.get("url")) or not src.get("checked_at"):
            errs.append(f"sources: {src.get('url')}")
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
                if p.get("open_end") and (p.get("kind") != "meldung" or not https_luh(p.get("source"))):
                    errs.append(f"tables.{key}.{term.get('term')}: open_end nur fuer meldung, mit Quelle")
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
    if sum(1 for p in d.get("programs") or [] if p.get("default")) > 1:
        errs.append("programs: mehr als ein default")
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


# MARK: Uni Hildesheim (gelesen am 05.11.2026, Seiten unter ~/Studora-Builds/hildesheim/pruefungsanmeldung/)

HI_SITE = "https://www.uni-hildesheim.de"
HI_FAQ_PA2 = HI_SITE + "/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/"
HI_LSF_TERMINE = HI_SITE + "/dez3/it-abteilung/lsf-vergabe/lsf-termine/"
HI_POS_FAQ = HI_SITE + "/posanmeldung/haeufige-fragen-zur-online-anmeldung-zu-studien-pruefungsleistungen/"
HI_POS_HOWTO = HI_SITE + "/posanmeldung/howto-schnellanleitung-zur-online-pruefungsanmeldung/"
HI_ZUST = HI_SITE + "/studium/studierende/pruefungsamt/zustaendigkeiten-nach-studiengaengen/"
HI_SEMESTER = HI_SITE + "/termine-fristen/semesterzeiten-in-reintext-zum-barrierefreien-aufruf/"
HI_LSF_START = "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0"
HI_CHECKED = "2026-11-05"
HILDESHEIM_SOURCES = [
    {"url": HI_FAQ_PA2, "title": "Prüfungsamt 2: Fragen zu Prüfungs-/Studienleistungen",
     "says": "Ab dem 11. November 2026 ist im LSF die POS-Anmeldung für das Wintersemester 26/27 für alle Bachelor- und "
             "Masterstudiengänge freigeschaltet (mit Ausnahme einiger Weiterbildungsmaster)."},
    {"url": HI_LSF_TERMINE, "title": "LSF-Termine (IT-Abteilung)",
     "says": "11.11.2026: Beginn der POS Anmeldephase (Wintersemester 2026/2027)."},
    {"url": HI_POS_FAQ, "title": "Häufige Fragen zur Online-Anmeldung zu Studien-/Prüfungsleistungen",
     "says": "Keine universitätsweit einheitlichen Fristen; Anmeldungen mit Frist sind verbindlich, ohne Frist "
             "unverbindlich und jederzeit stornierbar; Übersicht unter Meine Funktionen → POS-Management → Meine "
             "POS-Anmeldungen (bei Klausuren mit Ort und Zeit)."},
    {"url": HI_POS_HOWTO, "title": "Schnellanleitung zur Online-Prüfungsanmeldung",
     "says": "LSF → Meine Funktionen → POS-Management → An-/Abmeldung zu Studien-/Prüfungsleistungen → Semester, "
             "Modul/Teilmodul, Veranstaltung → „Zur Anmeldung“ → bestätigen."},
    {"url": HI_SEMESTER, "title": "Semesterzeiten", "says": "Wintersemester 2026/27: Semesterzeit 01.10.2026 – 31.03.2027."},
    {"url": HI_ZUST, "title": "Zuständigkeiten nach Studiengängen", "says": "Prüfungsamt je Studiengang (Link je Eintrag)."},
]
for _s in HILDESHEIM_SOURCES:
    _s["checked_at"] = HI_CHECKED
HILDESHEIM_TABLES = {
    "hildesheim-pos": {"variant": None, "terms": [
        {"term": "WiSe 26/27", "periods": [
            # Ende = Ende des Semesters laut Semesterzeiten; eine Anmeldefrist gibt es nicht (open_end)
            {"kind": "meldung", "n": 1, "label": "POS-Anmeldung im LSF (Fristen je Prüfung im LSF)", "start": "2026-11-11",
             "end": "2027-03-31", "open_end": True, "source": HI_FAQ_PA2},
        ]},
        # SoSe 27: Start der POS-Anmeldung noch nicht veroeffentlicht ("typischerweise Ende April" ist kein Datum)
    ]},
}
HILDESHEIM_RULES = [
    {"form": "Verbindliche Anmeldung", "withdraw_days_before": None,
     "text": "Anmeldungen mit Frist sind verbindlich: Das LSF zeigt bei der Anmeldung, bis wann du dich abmelden kannst."},
    {"form": "Unverbindliche Anmeldung", "withdraw_days_before": None,
     "text": "Anmeldungen ohne Frist sind unverbindlich und lassen sich im LSF jederzeit stornieren (höchstens 3 Semester rückwirkend)."},
    {"form": "Nachklausur", "withdraw_days_before": None,
     "text": "Nachklausuren meldest du im Semester der ursprünglichen Veranstaltung an (eigener Termin unter der Vorlesung)."},
    {"form": "Abschlussarbeit", "withdraw_days_before": None,
     "text": "Bachelor- und Masterarbeit: Anmeldeformular deines Prüfungsamts per Uni-E-Mail, nicht über das LSF."},
]
HILDESHEIM_TEXTS = {
    "system": "LSF",
    "hint": ("Im LSF: Meine Funktionen → POS-Management → „An-/Abmeldung zu Studien-/Prüfungsleistungen“, Semester, Modul "
             "und Veranstaltung wählen, „Zur Anmeldung“ tippen und selbst bestätigen. StudiNow füllt nichts aus und schickt "
             "nichts ab."),
    "disclaimer": ("Verbindlich sind die Angaben im LSF und auf den Seiten des Prüfungsamts. Eine universitätsweit "
                   "einheitliche Anmeldefrist gibt es nicht; einige Weiterbildungsmaster und Institute melden anders an."),
    "period_note": ("Die Uni Hildesheim hat keine einheitliche Anmeldefrist. Ab dem Start der POS-Anmeldung meldest du "
                    "dich im LSF je Prüfung an; Klausuren mit Frist sind verbindlich, die Frist steht im LSF an der Prüfung."),
}
HILDESHEIM_NOTE = ("Uni Hildesheim: Start der POS-Anmeldung im LSF (alle Bachelor- und Masterstudiengaenge, keine einheitliche "
                   "Frist, open_end; Ende = Semesterende) aus den Seiten in sources, gelesen am checked_at. programs: "
                   "Pruefungsamt je Studiengang laut Zustaendigkeiten (nur Link bei Weiterbildung, Diplom/Magister und "
                   "Sonderfaellen). Neu lesen: tools/gen-exam-registration-fixture.py --from-cache-hildesheim DIR. "
                   "docs/PRUEFUNGSANMELDUNG-2026-11-05.md")
DEGREE_TOKENS = [("b.a.+", "ba"), ("b.a.", "ba"), ("m.a.", "ma"), ("b.sc.", "bsc"), ("m.sc", "msc"), ("m.ed.", "med"),
                 ("b.ed.", "bed")]
# kein POS-Start bekannt: Weiterbildung, ausgelaufene Diplom-/Magisterstudiengaenge, Zugangspruefung, Austausch
HI_NO_TABLE_RE = re.compile(r"weiterbildung|berufsbegleitend|ausgelaufen|diplom|magister|immaturen|z-prüfung|"
                            r"austauschstudierende|staatliche anerkennung|musik\.welt", re.I)


class ZustParser(HTMLParser):
    """Akkordeon der Seite "Zuständigkeiten nach Studiengängen": <summary> = Fachbereich, darin Links auf Pruefungsaemter"""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.section = ""
        self.in_summary = False
        self.summary: list[str] = []
        self.a: dict | None = None
        self.links: list[dict] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "summary":
            self.in_summary, self.summary = True, []
        elif tag == "a" and self.section and "pruefungsamt" in (a.get("href") or ""):
            self.a = {"href": a["href"], "text": [], "section": self.section}

    def handle_endtag(self, tag):
        if tag == "summary" and self.in_summary:
            self.in_summary = False
            self.section = " ".join("".join(self.summary).split())
        elif tag == "a" and self.a is not None:
            self.a["text"] = " ".join("".join(self.a["text"]).replace("\xa0", " ").split())
            if self.a["text"]:
                self.links.append(self.a)
            self.a = None

    def handle_data(self, data):
        if self.in_summary:
            self.summary.append(data)
        if self.a is not None:
            self.a["text"].append(data)


def hildesheim_degrees(text: str) -> tuple[str, list[str]]:
    """"Erziehungswissenschaft (B. A. und M. A.)" -> ("Erziehungswissenschaft", ["ba", "ma"]); Name ohne den letzten
    Klammerzusatz mit Abschluss ("Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - mit Lehramtsoption" ->
    "... Studiengang mit Lehramtsoption", ["ba", "bsc"])"""
    for m in reversed(list(re.finditer(r"\(([^()]*)\)", text))):
        inner = re.sub(r"\s+", "", m.group(1).lower())
        found = []
        for tok, slug in DEGREE_TOKENS:
            if tok in inner and slug not in found:
                found.append(slug)
                inner = inner.replace(tok, "")
        if found:
            rest = text[m.end():].lstrip()
            rest = rest[1:] if rest.startswith(")") else rest          # "(M.A.))": doppelte Klammer der Seite
            name = (text[:m.start()] + " " + rest).replace(" - ", " ")
            return " ".join(name.split()), found
    return text.strip(), []


def hildesheim_entries(text: str) -> list[tuple[str, list[str]]]:
    """Ein Link kann zwei Studiengaenge nennen ("A (M.A.), B (M.A.))")"""
    parts = [x for x in re.split(r"(?<=\)),\s+", text) if x.strip()]
    found = [hildesheim_degrees(x) for x in parts]
    if len(parts) > 1 and all(d for _, d in found):
        return found
    return [hildesheim_degrees(text)]


def hildesheim_programs(html: str, checked: str) -> list[dict]:
    p = ZustParser()
    p.feed(html)
    out, seen = [], set()
    for link in p.links:
        url = link["href"] if link["href"].startswith("http") else HI_SITE + link["href"]
        for name, degrees in hildesheim_entries(link["text"]):
            table = None if HI_NO_TABLE_RE.search(link["text"]) or not degrees else "hildesheim-pos"
            for d in degrees or [""]:
                slug = er.slugify(name) + (f"-{d}" if d else "")
                if not slug or slug in seen:
                    continue
                seen.add(slug)
                out.append({"slug": slug, "name": link["text"], "faculty": link["section"], "url": url, "table": table,
                            "variant": None, "checked_at": checked})
    out.append({"slug": "alle-bachelor-und-masterstudiengaenge", "name": "Alle Bachelor- und Masterstudiengänge",
                "faculty": None, "url": HI_FAQ_PA2, "table": "hildesheim-pos", "variant": None, "checked_at": checked,
                "default": True})
    return out


def hildesheim_from_cache(cache: Path) -> dict:
    fetched = (cache / "fetched_at.txt").read_text(encoding="utf-8").strip()[:10]
    html = (cache / "studium__studierende__pruefungsamt__zustaendigkeiten-nach-studiengaengen.html").read_text(encoding="utf-8")
    return {"v": 1, "university": "hildesheim", "note": HILDESHEIM_NOTE, "checked_at": fetched,
            "general": {"url": HI_POS_FAQ, "title": "Online-Anmeldung zu Studien-/Prüfungsleistungen (POS, Universität Hildesheim)"},
            "qis_menu": HI_LSF_START, **HILDESHEIM_TEXTS, "sources": HILDESHEIM_SOURCES, "rules": HILDESHEIM_RULES,
            "tables": HILDESHEIM_TABLES, "programs": hildesheim_programs(html, fetched)}


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


HI_PROGRAM_CASES = [
    ("Angewandte Informatik", "B.Sc."),
    ("Angewandte Informatik (PO-Version 2019)", "M.Sc."),
    ("Erziehungswissenschaft", "M.A."),
    ("Psychologie", "B.Sc."),
    ("Wirtschaftsinformatik", None),
    ("Informationsmanagement und Informationstechnologie", "Bachelor of Science"),
    ("Kochkunst", "B.Sc."),
    ("", None),
]
HI_DAYS = ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-11", "2026-11-25", "2026-11-26", "2027-03-31", "2027-04-01"]


def hildesheim_cases(d: dict) -> dict:
    progs = []
    for name, degree in HI_PROGRAM_CASES:
        f = er.find_program(d, name, degree)
        r = er.resolve_program(d, name, degree)
        progs.append({"name": name, "degree": degree, "slug": f["slug"] if f else None,
                      "resolved": r["slug"] if r else None, "has_table": bool(r and r.get("table"))})
    phases = []
    for name, degree in HI_PROGRAM_CASES[:3]:
        p = er.resolve_program(d, name, degree)
        for day in HI_DAYS:
            w = er.window_state(d, p, day, "meldung")
            phases.append({"name": name, "degree": degree, "today": day, "kind": "meldung", "window": w,
                           "periods": len(er.term_periods(d, p, w["term"] if w else None))})
    return {"programs": progs, "phases": phases, "count": len(d.get("programs") or []),
            "with_table": sum(1 for p in d.get("programs") or [] if p.get("table"))}


HSH_PROGRAM_CASES = [
    ("Angewandte Informatik", "B.Sc."),
    ("Angewandte Informatik (PO-Version 2019)", None),
    ("Elektrotechnik und Informationstechnik", "B.Eng."),
    ("Elektrische Energiesysteme und Elektromobilität", "M.Eng."),
    ("Kochkunst", "B.Eng."),
]
HSH_DAYS = ["2026-09-01", "2026-09-10", "2026-11-05", "2026-12-01", "2027-03-01"]


def hsh_cases(d: dict) -> dict:
    progs = []
    for name, degree in HSH_PROGRAM_CASES:
        f = er.find_program(d, name, degree)
        progs.append({"name": name, "degree": degree, "slug": f["slug"] if f else None, "has_table": bool(f and f.get("table"))})
    phases = []
    for name, degree in HSH_PROGRAM_CASES[:1]:
        p = er.resolve_program(d, name, degree)
        for day in HSH_DAYS:
            w = er.window_state(d, p, day, "meldung")
            phases.append({"name": name, "degree": degree, "today": day, "kind": "meldung", "window": w,
                           "periods": len(er.term_periods(d, p, w["term"] if w else None))})
    return {"programs": progs, "phases": phases, "count": len(d.get("programs") or []),
            "with_table": sum(1 for p in d.get("programs") or [] if p.get("table"))}


def cases(d: dict, hildesheim: dict | None = None, hsh: dict | None = None) -> dict:
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
    out = {"generator": "tools/gen-exam-registration-fixture.py", "soon_days": er.SOON_DAYS, "programs": progs,
           "phases": phases, "slugs": slugs, "degrees": degrees}
    if hildesheim is not None:
        out["hildesheim"] = hildesheim_cases(hildesheim)
    if hsh is not None:
        out["hsh"] = hsh_cases(hsh)
    return out


def swift_text(raw: str, raw_hildesheim: str, raw_hsh: str) -> str:
    assert '"""#' not in raw and '"""#' not in raw_hildesheim and '"""#' not in raw_hsh
    return ("// Erzeugt von tools/gen-exam-registration-fixture.py aus packages/shared-contracts/exam-registration-luh.json,"
            "\n// exam-registration-hildesheim.json und exam-registration-hsh.json - nicht von Hand aendern.\nenum ExamRegistrationData {\n"
            "    static let luh = #\"\"\"\n" + raw.rstrip("\n") + "\n\"\"\"#\n\n"
            "    static let hildesheim = #\"\"\"\n" + raw_hildesheim.rstrip("\n") + "\n\"\"\"#\n\n"
            "    static let hsh = #\"\"\"\n" + raw_hsh.rstrip("\n") + "\n\"\"\"#\n}\n")


def main() -> int:
    args = sys.argv[1:]
    check = "--check" in args
    if "--from-cache" in args:
        cache = Path(args[args.index("--from-cache") + 1]).expanduser()
        d = from_cache(cache)
        DATA.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"geschrieben: {DATA.relative_to(ROOT)} ({sum(1 for p in d['programs'] if p['table'])} mit Daten, "
              f"{len(d['programs'])} Studiengaenge)")
    if "--from-cache-hildesheim" in args:
        cache = Path(args[args.index("--from-cache-hildesheim") + 1]).expanduser()
        h = hildesheim_from_cache(cache)
        DATA_HILDESHEIM.write_text(json.dumps(h, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"geschrieben: {DATA_HILDESHEIM.relative_to(ROOT)} ({len(h['programs'])} Eintraege, "
              f"{sum(1 for p in h['programs'] if p['table'])} mit POS-Start)")
    raw = DATA.read_text(encoding="utf-8")
    raw_h = DATA_HILDESHEIM.read_text(encoding="utf-8")
    raw_s = DATA_HSH.read_text(encoding="utf-8")
    d, h, s = json.loads(raw), json.loads(raw_h), json.loads(raw_s)
    errs = (check_data(d, "luh") + [f"hildesheim: {e}" for e in check_data(h, "hildesheim")]
            + [f"hsh: {e}" for e in check_data(s, "hsh")])
    if errs:
        print("FEHLER in der Datendatei:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1
    ok = write_or_check(SWIFT, swift_text(raw, raw_h, raw_s), check)
    ok = write_or_check(CASES, json.dumps(cases(d, h, s), ensure_ascii=False, indent=1) + "\n", check) and ok
    return 1 if check and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
