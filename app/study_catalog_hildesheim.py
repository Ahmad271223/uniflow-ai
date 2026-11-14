"""Leser fuer "Studienordnung inklusive Modulhandbuch" der Universitaet Hildesheim (Fachbereich 1, z. B. Bachelor
Sozialpaedagogik; Auftrag 14.11.2026). Fuer eigene Katalog-Links: der modkat-Leser der LUH (`parse_luh_modkat`) findet in
diesen PDFs kein Modul. Gleiche Regeln im Swift-Kern (UniFlowCore/StudyCatalog/StudyCatalogHildesheimParser.swift);
gemeinsame Fixture packages/shared-contracts/fixtures/study-catalog-hildesheim (tools/gen-study-catalog-hildesheim-fixture.py).

Aufbau der PDF: Paragrafen-Text, "Anlage 1" (Ueberblick mit "Gesamtzahl der Leistungspunkte 180"), "Anlage 2
Studienablaufplan", "Anlage 3 Modulhandbuch" mit einer zweispaltigen Tabelle je Modul (links Feldname, rechts Wert):
  Bezeichnung                Modul 3: Titel (kann in der naechsten Zeile weitergehen)
  Kompetenzen und Lernziele  ...
  Lerninhalte                ... darin Teilmodule "TM 1: Titel (Seminar; 2 SWS; 2 LP (WiSe))" bzw. "(2 SWS / 2 LP)"
  Leistungspunkte            "6 LP", "6" oder "12 LP fuer ..." + "3 LP fuer ..." (Summe)
  Semesterwochenstunden, Studienleistung(en), Lehr- und Lernformen, Verwendbarkeit des Moduls, Pruefungsleistung(en),
  Arbeitsaufwand (Workload), Empfohlene(s) Fachsemester, Voraussetzung(en) fuer die Teilnahme am Modul / Zulassung zur
  Pruefung (Feldname ueber zwei Zeilen), Moduldauer, Haeufigkeit (des Angebots), Zustaendige Staendige
  Pruefungskommission, Modulverantwortliche
Seitenkopf: "Verkündungsblatt der Universität Hildesheim - Heft N - Nr. ... (TT.MM.JJJJ) - Seite N -" oder bei
Lesefassungen "Lesefassung" + "(Stand TT.MM.JJJJ)"; faellt vor dem Lesen weg.

Eingabe sind Seitentexte, deren Zeilen die Tabellenzeilen sind ("Feldname Wert", danach Folgezeilen des Werts):
- pypdf (`app.study_catalog.pdf_pages`) liefert sie so.
- PDFKit (`page.string`) stellt in diesen PDFs oft die Feldnamen-Spalte vor die Werte ("Bezeichnung Kompetenzen und
  Lernziele Lerninhalte Modul 2: ..."). Am Geraet deshalb die Textstuecke mit Lage nehmen (`StudyCatalogPDF.planItems`)
  und mit `row_pages` / `rowPages` zu Zeilen ordnen. Auf dem rohen PDFKit-Text findet der Leser die Module trotzdem,
  laesst aber jedes Feld weg, dessen Wert nicht sicher zuzuordnen ist (mehrere Feldnamen in einer Zeile).

Was nicht sicher lesbar ist, bleibt leer: `semester` nur aus "Empfohlene(s) Fachsemester" in klarer Form ("1. Semester",
"1. und 2. Semester", "5. - 6. Semester"; erste Zahl), die Tabelle in Anlage 2 wird nicht gelesen. `code` bleibt null
(die Modulnummer ist keine QIS-Pruefungsnummer), `areas` leer, `language` null.
"""
from __future__ import annotations

import re

from app.study_catalog import MAX_TEXT, _number, _unique, current_term, normalize_lines, slug

FORMAT = "hildesheim-studienordnung"

# Seitenkopf (ganze Zeile)
HEADER_RES = (
    re.compile(r"^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft .*[-–] ?Seite ?[0-9]+ ?[-–]?$"),
    re.compile(r"^Lesefassung$"),
    re.compile(r"^\(Stand:? ?[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}\)$"),
)
TITLE_PHRASE = "Studienordnung inklusive Modulhandbuch"
MODULE_RE = re.compile(r"^Bezeichnung:? ((?:(?:Kompetenzen und Lernziele|Lerninhalte) )*)Modul ?([0-9]{1,2}) ?: ?(.+)$")
ANNEX_RE = re.compile(r"^Anlage [0-9]+[a-z]?(?: |:|$)")

# Feldnamen der Modultabelle: Schluessel -> Muster des Namens am Zeilenanfang (danach Zeilenende oder Wert)
LABELS = (
    ("goals", "Kompetenzen und Lernziele"),
    ("content", "Lerninhalte"),
    ("lp", "Leistungspunkte"),
    ("sws", "Semesterwochenstunden"),
    ("coursework", "Studienleistung(?:en)?"),
    ("forms", "Lehr- und Lernformen"),
    ("usage", "Verwendbarkeit des Moduls"),
    ("exam", "Prüfungsleistung(?:en)?"),
    ("workload", r"Arbeitsaufwand(?: \([Ww]orkload\))?"),
    ("semester", r"Empf\w* Fachsemester"),
    ("req", "Voraussetzung(?:en)? für die"),
    ("duration", "Moduldauer"),
    ("freq", "Häufigkeit(?: des Angebots)?"),
    ("board", "Zuständige Ständige"),
    ("lead", "Modulverantwortliche(?:r|/r)?"),
)
LABEL_RES = tuple((k, re.compile("^(?:" + p + "):?(?: (.*))?$")) for k, p in LABELS)
# zweite Zeile zweizeiliger Feldnamen
PREREQ_PART_RE = re.compile(r"^Teilnahme am Modul:?(?: (.*))?$")
ADMISSION_PART_RE = re.compile(r"^Zulassung (?:zur (?:Modul)?[Pp]rüfung|zu den Prüfungen):?(?: (.*))?$")
BOARD_PART_RE = re.compile(r"^Prüfungskommission:?(?: (.*))?$")
BARE_SEMESTER_RE = re.compile(r"^Semester (.+)$")

SEMESTER_VALUE_RE = re.compile(r"^([1-9])\. ?(?:(?:-|–|−|/|und|bis|oder) ?[1-9]\. ?)?(?:Fach)?[Ss]emester$")
SEMESTER_WORD_RE = re.compile(r"^(erstes|zweites|drittes|viertes|fünftes|sechstes|siebtes|achtes)"
                              r"(?: (?:bis|und|oder) (?:erstes|zweites|drittes|viertes|fünftes|sechstes|siebtes|achtes))?"
                              r" (?:fach)?semester$")
SEMESTER_WORDS = {"erstes": 1, "zweites": 2, "drittes": 3, "viertes": 4, "fünftes": 5, "sechstes": 6, "siebtes": 7, "achtes": 8}
LP_VALUE_RE = re.compile(r"^([0-9]+(?:,[0-9]+)?)(?: ?LP)?(?: \(.*)?$")
LP_FOR_RE = re.compile(r"^([0-9]+(?:,[0-9]+)?) ?LP für ")
SWS_VALUE_RE = re.compile(r"^([0-9]+(?:,[0-9]+)?)(?: ?SWS)?(?: \(.*)?$")
WORKLOAD_VALUE_RE = re.compile(r"^([0-9]+) ?(?:Stunden|Std\.?|h)(?: |$)")
REASON_RE = re.compile(r"^Begründung:")
# Verweise auf andere Module in den Voraussetzungen: "des Moduls 2", "(Modul 6)", "der Module 1 und 3"
MODULE_REF_RE = re.compile(r"\bModul(?:s|e|en)? ([0-9]{1,2}(?:(?:, ?| und | sowie )[0-9]{1,2})*)\b")
NUMBER_RE = re.compile(r"[0-9]+")
FINAL_RE = re.compile(r"bachelorarbeit|masterarbeit|abschlussarbeit|^abschlussmodul")
NONE_VALUES = ("", "-", "–", "keine", "keiner", "nein", "entfällt")

# Teilmodule in "Lerninhalte": "TM 1: Titel (Seminar; 2 SWS; 2 LP (WiSe))", "TM 2: Titel (2 SWS / 4,5 LP)",
# "TM 3: Titel (2 SWS; 3 LP) (SoSe)", "(2 SWS / 3 + 3 LP)"
PART_START_RE = re.compile(r"(?:^| )TM ?([0-9]{1,2}) ?:(?: ?:)? ?")
PART_SPEC_RE = re.compile(r"^(.*?) ?\((?:([^()0-9;]*?) ?; ?)?([0-9]+) ?SWS ?[;/]? ?"
                          r"([0-9]+(?:,[0-9]+)?(?: ?\+ ?[0-9]+(?:,[0-9]+)?)*) ?LP ?\)?(?: ?\(([^()]*)\))?")
_SEASON = "(?:WiSe|SoSe|WS|SS|Wintersemester|Sommersemester)"
PART_TERM_RE = re.compile("^" + _SEASON + "(?: ?(?:,|/|und|oder) ?" + _SEASON + ")*$")
MAX_PART_TITLE = 200

# Turnus aus "Häufigkeit des Angebots" (Text klein geschrieben)
EVERY_TERM_RE = re.compile(r"jede[sm] semester")
WINTER_RE = re.compile(r"winter|\bwise\b|\bws\b")
SUMMER_RE = re.compile(r"sommer|\bsose\b|\bss\b")

# Kopf
PROGRAM_RE = re.compile(TITLE_PHRASE + r" für den (Bachelor|Master) ?-? ?[Ss]tudiengang (.+?) im Fachbereich")
STAND_RE = re.compile(r"^\(Stand:? ?([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\)$")
HEFT_RE = re.compile(r"^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft ([0-9]+) .*?"
                     r"\(([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\)")
VALID_FROM_RE = re.compile(r"zum (Winter|Sommer)semester ((?:[0-9] ?){4})(?:/ ?[0-9]{2,4})? aufgenommen")
TOTAL_LP_RE = re.compile(r"Gesamtzahl der Leistungspunkte:? ([0-9]+(?:,[0-9]+)?)$")
DEGREES = (("Bachelor", "Bachelor of Arts", "B.A."), ("Bachelor", "Bachelor of Science", "B.Sc."),
           ("Bachelor", "Bachelor of Education", "B.Ed."), ("Master", "Master of Arts", "M.A."),
           ("Master", "Master of Science", "M.Sc."), ("Master", "Master of Education", "M.Ed."))
ROW_TOLERANCE = 3.0
# Felder, die bei vermischter Reihenfolge (roher PDFKit-Text) in allen Modulen wegfallen
MIXED_UNSURE = ("sws", "coursework", "exam", "workload", "semester", "prereq", "admission", "freq")


# --------------------------------------------------------------------------------------------------------------------
# Zeilen
# --------------------------------------------------------------------------------------------------------------------

def row_pages(items: list) -> list[str]:
    """Textstuecke mit Lage je Seite ([x, y, text] wie `app.study_catalog.pdf_items`, am Geraet
    `StudyCatalogPDF.planItems`) -> Seitentexte, eine Zeile je Tabellenzeile: nach y geordnet, Stuecke bis 3 Punkte unter
    dem ersten der Zeile gehoeren dazu, in der Zeile von links nach rechts."""
    pages = []
    for page in items:
        order = sorted(range(len(page)), key=lambda i: (page[i][1], i))
        rows: list[list[int]] = []
        y0 = 0.0
        for i in order:
            if not rows or page[i][1] - y0 > ROW_TOLERANCE:
                rows.append([])
                y0 = page[i][1]
            rows[-1].append(i)
        pages.append("\n".join(" ".join(str(page[i][2]) for i in sorted(r, key=lambda i: (page[i][0], i))) for r in rows))
    return pages


def clean_pages(pages: list[str]) -> list[list[str]]:
    """Normalisierte Zeilen je Seite ohne Seitenkopf"""
    return [[l for l in normalize_lines(t) if not any(rx.match(l) for rx in HEADER_RES)] for t in pages]


def _label(line: str) -> tuple[str, str] | None:
    """Feldname am Zeilenanfang -> (Schluessel, Rest der Zeile)"""
    for key, rx in LABEL_RES:
        m = rx.match(line)
        if m:
            return key, m.group(1) or ""
    m = BARE_SEMESTER_RE.match(line)
    if m and _semester(m.group(1)) is not None:
        return "semester", m.group(1)
    return None


def _clip(s: str, limit: int = MAX_TEXT) -> str | None:
    """Raender weg, leer -> None, hoechstens `limit` Zeichen (am Wortende gekuerzt, mit "…")"""
    s = s.strip(" ;,")
    if not s:
        return None
    if len(s) > limit:
        s = s[:limit - 1].rsplit(" ", 1)[0] + "…"
    return s


# --------------------------------------------------------------------------------------------------------------------
# Werte
# --------------------------------------------------------------------------------------------------------------------

def _semester(value: str) -> int | None:
    m = SEMESTER_VALUE_RE.match(value)
    if m:
        return int(m.group(1))
    m = SEMESTER_WORD_RE.match(value.lower())
    return SEMESTER_WORDS[m.group(1)] if m else None


def _lp(lines: list[str]):
    if not lines:
        return None
    if LP_FOR_RE.match(lines[0]):
        total = sum(float(m.group(1).replace(",", ".")) for m in (LP_FOR_RE.match(l) for l in lines) if m)
        return int(total) if total == int(total) else total
    m = LP_VALUE_RE.match(lines[0])
    return _number(m.group(1)) if m else None


def _fact(lines: list[str]) -> str | None:
    """Studien-/Pruefungsleistung: Wert bis vor "Begründung:", "keine" -> None"""
    kept = []
    for l in lines:
        if REASON_RE.match(l):
            break
        kept.append(l)
    s = " ".join(kept).strip(" ")
    return None if s.lower() in NONE_VALUES else _clip(s)


def _season(text: str) -> str:
    t = text.lower()
    if EVERY_TERM_RE.search(t):
        return "WS+SS"
    winter, summer = bool(WINTER_RE.search(t)), bool(SUMMER_RE.search(t))
    if winter and summer:
        return "WS+SS"
    return "WS" if winter else ("SS" if summer else "unbekannt")


def _parts(content: list[str]) -> list[dict]:
    """Teilmodule aus den Zeilen von "Lerninhalte" (nur mit Angabe "(… SWS … LP)")"""
    pieces = PART_START_RE.split(" ".join(content))
    out = []
    for k in range(1, len(pieces) - 1, 2):
        m = PART_SPEC_RE.match(pieces[k + 1])
        title = _clip(m.group(1).strip(" :"), MAX_PART_TITLE) if m else None
        if not title:
            continue
        lp = sum(float(x.strip(" ").replace(",", ".")) for x in m.group(4).split("+"))
        term = m.group(5).strip(" ") if m.group(5) else ""
        out.append({"number": int(pieces[k]), "title": title, "kind": (m.group(2) or "").strip(" ,") or None,
                    "sws": int(m.group(3)), "lp": int(lp) if lp == int(lp) else lp,
                    "term": _season(term) if PART_TERM_RE.match(term) else None})
    return out


# --------------------------------------------------------------------------------------------------------------------
# Module
# --------------------------------------------------------------------------------------------------------------------

def _read(clean: list[list[str]]) -> list[dict]:
    """Rohmodule: {number, title, page, fields {Schluessel: Zeilen}, unsure {Schluessel}}. `unsure`: der Feldname stand
    mit weiteren Feldnamen in einer Zeile (roher PDFKit-Text), der Wert ist nicht sicher zuzuordnen. Kommt das
    irgendwo im Dokument vor, ist die Reihenfolge von Feldnamen und Werten insgesamt nicht verlaesslich: dann gelten in
    allen Modulen nur noch Titel, Leistungspunkte, Teilmodule und die Texte, alle anderen Felder sind `unsure`."""
    mods: list[dict] = []
    cur: dict | None = None
    key = "_head"
    for p, lines in enumerate(clean):
        for line in lines:
            m = MODULE_RE.match(line)
            if m:
                cur = {"number": int(m.group(2)), "title": m.group(3).strip(" "), "page": p + 1, "fields": {"_head": []},
                       "unsure": set()}
                mods.append(cur)
                key = "_head"
                if m.group(1):                             # Feldnamen vor dem Titel: Ziele und Inhalte nicht zu trennen
                    cur["fields"].update(goals=[], content=[])
                    cur["unsure"].update(("goals", "content", "_head"))
                    key = "content"
                continue
            if cur is None:
                continue
            if ANNEX_RE.match(line):                       # weitere Anlage nach dem Modulhandbuch
                cur = None
                continue
            f = cur["fields"]
            if key == "req":
                m = PREREQ_PART_RE.match(line)
                name = "prereq"
                if not m:
                    m = ADMISSION_PART_RE.match(line)
                    name = "admission"
                if m and name not in f:
                    f[name] = f.pop("req")
                    if "req" in cur["unsure"]:
                        cur["unsure"].discard("req")
                        cur["unsure"].add(name)
                    key = name
                    if m.group(1):
                        f[key].append(m.group(1))
                    continue
            if key == "board" and "_board" not in f:
                m = BOARD_PART_RE.match(line)
                if m:
                    f["_board"] = []
                    if m.group(1):
                        f[key].append(m.group(1))
                    continue
            found = _label(line)
            if found is None or found[0] in f:
                f[key].append(line)
                continue
            key, rest = found
            f[key] = []
            more = _label(rest) if rest else None
            while more is not None and more[0] not in f:   # mehrere Feldnamen in einer Zeile
                cur["unsure"].update((key, more[0]))
                key, rest = more
                f[key] = []
                more = _label(rest) if rest else None
            if rest:
                f[key].append(rest)
    mixed = any(r["unsure"] for r in mods)
    for r in mods:
        head = r["fields"]["_head"]
        if head and len(head) <= 2 and "_head" not in r["unsure"]:
            r["title"] = r["title"] + " " + " ".join(head)
        if mixed:
            r["unsure"].update(MIXED_UNSURE)
    return mods


def _sure(r: dict, key: str) -> list[str]:
    return [] if key in r["unsure"] else (r["fields"].get(key) or [])


def is_hildesheim_sto(pages: list[str]) -> bool:
    """Ist das eine "Studienordnung inklusive Modulhandbuch" mit Modultabellen ("Bezeichnung Modul 1: ...")? Geht auch
    mit dem rohen PDFKit-Text."""
    clean = clean_pages(pages)
    first = " ".join(clean[0]) if clean else ""
    return TITLE_PHRASE in first and any(MODULE_RE.match(l) for lines in clean for l in lines)


def hildesheim_sto_head(pages: list[str]) -> dict:
    """Kopf aus Titelseite und Paragrafen: {program, level, degree, stand, heft, po, catalog_term, total_lp}.
    program "Sozialpädagogik"; level "Bachelor"/"Master"; degree "B.A." usw. nur, wenn die PDF "Bachelor of Arts" o. ae.
    nennt, sonst gleich level; stand "JJJJ-MM-TT" aus "(Stand TT.MM.JJJJ)" der Lesefassung, sonst Datum des Hefts; po =
    Jahr des Stands; catalog_term aus "gilt erstmals ... zum Wintersemester 2025/26 aufgenommen", sonst das Semester
    des Stands; total_lp aus "Gesamtzahl der Leistungspunkte". Unbekanntes ist None."""
    raw = [normalize_lines(t) for t in pages]
    clean = clean_pages(pages)
    first = " ".join(clean[0]) if clean else ""
    m = PROGRAM_RE.search(first)
    program = level = degree = None
    if m:
        level = m.group(1)
        program = m.group(2).strip(" „“\"")
        for word in ("und", "oder"):                       # pypdf-Luecke "Sozial - und"
            program = program.replace(f" - {word} ", f"- {word} ")
        degree = level
    stand = heft = None
    for l in (raw[0] if raw else [])[:6]:
        m = STAND_RE.match(l)
        if m:
            stand = f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
            break
    for l in (raw[0] if raw else [])[:6]:
        m = HEFT_RE.match(l)
        if m:
            heft = m.group(1)
            stand = stand or f"{m.group(4)}-{int(m.group(3)):02d}-{int(m.group(2)):02d}"
            break
    # Text vor dem Modulhandbuch
    before: list[str] = []
    for lines in clean:
        k = next((i for i, l in enumerate(lines) if MODULE_RE.match(l)), None)
        before.extend(lines if k is None else lines[:k])
        if k is not None:
            break
    text = " ".join(before)
    if level:
        for lv, long, short in DEGREES:
            if lv == level and long in text:
                degree = short
                break
    term = None
    m = VALID_FROM_RE.search(text)
    if m:
        y = int(m.group(2).replace(" ", ""))
        term = f"WS {y}/{(y + 1) % 100:02d}" if m.group(1) == "Winter" else f"SS {y}"
    elif stand:
        term = current_term(stand)
    total = None
    for l in before:
        m = TOTAL_LP_RE.search(l)
        if m:
            total = _number(m.group(1))
            break
    return {"program": program, "level": level, "degree": degree, "stand": stand, "heft": heft,
            "po": stand[:4] if stand else None, "catalog_term": term, "total_lp": total}


def parse_hildesheim_sto(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Seitentexte -> (Katalog im geteilten Format, {modul_id: {content, goals, literature}}), Form wie
    `parse_luh_modkat`. meta wie dort (university, program, degree, po, code, catalog_term, regular_semesters, total_lp,
    source {url, fetched_at, sha256}); fehlen program, degree, po, catalog_term oder total_lp, kommen sie aus
    `hildesheim_sto_head`."""
    clean = clean_pages(pages)
    raw = _read(clean)
    head = hildesheim_sto_head(pages)
    by_number: dict = {}
    module_ids: set = set()
    for r in raw:
        r["id"] = _unique(slug(r["title"]), module_ids)
        by_number.setdefault(r["number"], r["id"])
    modules: list[dict] = []
    texts: dict = {}
    for r in raw:
        f = r["fields"]
        sem_lines = _sure(r, "semester")
        work = _sure(r, "workload")
        wm = WORKLOAD_VALUE_RE.match(work[0]) if work else None
        turnus = _season(" ".join(_sure(r, "freq")))
        if turnus == "unbekannt" and "freq" not in r["unsure"]:   # sonst aus den Angaben der Teilmodule
            seasons = {p["term"] for p in _parts(f.get("content") or [])}
            if seasons and None not in seasons:
                turnus = "WS+SS" if len(seasons) > 1 else next(iter(seasons))
        pre: list[str] = []
        for ref in MODULE_REF_RE.findall(" ".join(_sure(r, "prereq") + _sure(r, "admission"))):
            for n in NUMBER_RE.findall(ref):
                mid = by_number.get(int(n))
                if mid and mid != r["id"] and mid not in pre:
                    pre.append(mid)
        modules.append({
            "id": r["id"],
            "title": r["title"][:MAX_TEXT],
            "code": None,
            "area": None,
            "kind": "abschluss" if FINAL_RE.search(r["title"].lower()) else "pflicht",
            "lp": _lp(_sure(r, "lp")),
            "semester": _semester(" ".join(sem_lines)) if sem_lines else None,
            "turnus": turnus,
            "exam": _fact(_sure(r, "exam")),
            "coursework": _fact(_sure(r, "coursework")),
            "prerequisites": pre,
            "language": None,
            "workload_h": int(wm.group(1)) if wm else None,
            "source_page": r["page"],
        })
        texts[r["id"]] = {"content": "\n".join(f.get("content") or []) or None,
                          "goals": "\n".join(f.get("goals") or []) or None, "literature": None}
    src = meta.get("source") or {}
    total = meta.get("total_lp")
    catalog = {
        "v": 1,
        "university": meta.get("university"),
        "program": meta.get("program") or head["program"],
        "degree": meta.get("degree") or head["degree"],
        "po": meta.get("po") or head["po"],
        "catalog_term": meta.get("catalog_term") or head["catalog_term"] or "",
        "code": meta.get("code"),
        "regular_semesters": meta.get("regular_semesters"),
        "total_lp": total if total is not None else head["total_lp"],
        "source": {"url": src.get("url"), "fetched_at": src.get("fetched_at"), "sha256": src.get("sha256")},
        "areas": [],
        "modules": modules,
    }
    return catalog, texts


def hildesheim_sto_details(pages: list[str]) -> dict:
    """Angaben, die das geteilte Katalogformat nicht traegt: {modul_id: {number, sws, parts}} mit der Modulnummer, den
    Semesterwochenstunden (Zahl oder None) und den Teilmodulen [{number, title, kind, sws, lp, term}] (kind z. B.
    "Seminar", term "WS", "SS", "WS+SS" oder None). ids wie in `parse_hildesheim_sto`."""
    raw = _read(clean_pages(pages))
    module_ids: set = set()
    out: dict = {}
    for r in raw:
        sws = _sure(r, "sws")
        m = SWS_VALUE_RE.match(sws[0]) if sws else None
        out[_unique(slug(r["title"]), module_ids)] = {"number": r["number"], "sws": _number(m.group(1)) if m else None,
                                                     "parts": _parts(r["fields"].get("content") or [])}
    return out
