"""Leseprogramm `mb-modulkatalog`: Modulkataloge der Fakultaet fuer Maschinenbau (Datenbank-Ausgabe; auch
Medizintechnik, Nachhaltige Ingenieurwissenschaft, Produktion und Logistik, Optische Technologien, Biomedizintechnik,
Mechatronik und Robotik, AI-driven, Mechanical Engineering mit englischen Feldnamen).

Aufbau je Modulseite:
  Stand: TT.MM.JJJJ <Studiengang> PO <Jahr>
  Modul: <Titel>            (kann umbrechen)
  Module: <englischer Titel>
  Modultyp Kompetenzbereich              | Type of module Area of competence
  Wahlpflicht Produktionstechnik
  Angebot im Dauer Sprache ECTS Empfohlen ab   | Offer in Duration Language ECTS Recommended from
  WiSe 1 Semester Deutsch 5 Zulassung WiSe: 1/2. Semester Zulassung SoSe: 1/2. Semester
  Pruefungsleistungen (PL) / Studienleistung (SL)
  Art ECTS Dauer / Umfang Notenskala     (Zeilen einzeln "PL Klausur 5 90 min benotet" oder spaltenweise
                                          gestapelt: erst alle PL/SL, dann alle Arten, ECTS, Dauer, Notenskala)
  Workload 150 h, Praesenzstudienzeit, Selbststudienzeit, Modulverantwortliche-r, Dozent-in, Institut, Fakultaet
  Aufbau des Moduls, Voraussetzungen fuer die Teilnahme: / Empfohlen fuer die Teilnahme:, Qualifikationsziele,
  Inhalte, Besonderheiten, Literatur, Verwendbarkeit in anderen Studiengaengen
Modulgrenze: Wechsel des Titels nach "Modul:" (Folgeseiten wiederholen den Kopf).
"""
from __future__ import annotations

import re

from .formats_a_common import build_catalog, join, kind_of, language_of, number, page_lines, term_of_catalog, \
    text_join, turnus_of, workload_of, NUM

STAND_RE = re.compile(r"^Stand: ?[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}")
KIND_HDR = ("Modultyp Kompetenzbereich", "Type of module Area of competence")
OFFER_HDR = ("Angebot im Dauer", "Offer in Duration", "Offered in Duration")
EXAM_HDR = ("Prüfungsleistungen (PL)", "Examination performance", "Prüfungsleistung (PL)")
TABLE_HDR = ("Art ECTS", "Kind ECTS", "Type ECTS")
OFFER_RE = re.compile(r"^(?P<turn>\S+)\s+(?P<dur>[0-9]+ (?:Semester|semester|Semesters|terms?))\s+(?P<lang>.+?)\s+"
                      r"(?P<ects>" + NUM + r")\s*(?P<rest>(?:Zulassung|Admission|Empfohlen|Recommended).*)?$")
SEM_RE = re.compile(r"(?:Zulassung|Admission) (?:WiSe|WS|winter[^:]*):? ?([0-9]+)")
_GRADE = r"(benotet|unbenotet|graded|ungraded|not graded|bestanden/nicht bestanden)"
ROW_ECTS_RE = re.compile(r"^(PL|SL) (.+?) (" + NUM + r")(?: (.+?))? " + _GRADE + "$")
ROW_BARE_RE = re.compile(r"^(PL|SL) (.+?)()(?: (.+?))? " + _GRADE + "$")


def _row(line: str):
    return ROW_ECTS_RE.match(line) or ROW_BARE_RE.match(line)
GRADES = {"benotet", "unbenotet", "graded", "ungraded", "bestanden/nicht bestanden", "not graded"}
COURSEWORK_WORDS = {"studienleistung", "academic achievement", "course achievement"}

# Abschnitte nach dem Kopf (Reihenfolge fest; Texte nur in dieser Reihenfolge)
SECTIONS = [
    ("workload", ("Workload",), True),
    ("presence", ("Präsenzstudienzeit", "Attendance study period", "Attendance time"), True),
    ("self", ("Selbststudienzeit", "Self-study time", "Self study time"), True),
    ("lead", ("Modulverantwortliche-r", "Modulverantwortliche", "Module coordinator"), True),
    ("lecturer", ("Dozent-in", "Lecturer"), True),
    ("institute", ("Institut", "Institute"), True),
    ("faculty", ("Fakultät", "Faculty"), True),
    ("structure", ("Aufbau des Moduls", "Structure of the module"), False),
    ("prereq", ("Voraussetzungen für die Teilnahme:", "Requirements for participation:"), True),
    ("goals", ("Qualifikationsziele", "Qualification goals", "Learning outcomes"), False),
    ("content", ("Inhalte", "Contents", "Content"), False),
    ("special", ("Besonderheiten", "Special features"), False),
    ("literature", ("Literatur", "Literature"), False),
    ("usage", ("Verwendbarkeit in anderen Studiengängen", "Applicability in other degree programs",
               "Applicability in other study programs"), False),
]


def _section_of(line: str, after: int):
    """(index, key, Rest der Zeile) wenn die Zeile einen spaeteren Abschnitt beginnt"""
    for i, (key, labels, inline) in enumerate(SECTIONS):
        if i <= after:
            continue
        for lab in labels:
            if line == lab:
                return i, key, ""
            if inline and line.startswith(lab + " ") and key not in ("institute", "faculty"):
                return i, key, line[len(lab) + 1:]
            if inline and key in ("institute", "faculty") and line.startswith(lab + " ") and after >= 3:
                return i, key, line[len(lab) + 1:]
    return None


def _split_pages(pages: list[list[str]]):
    """Seiten -> Module [(titel, erste_seite, koerperzeilen)]"""
    mods: list[dict] = []
    for pno, lines in enumerate(pages, 1):
        lines = list(lines)
        if lines and re.fullmatch(r"[0-9]{1,3}", lines[-1]):
            lines.pop()
        i = 0
        while i < len(lines) and i < 3 and not lines[i].startswith("Modul:"):
            i += 1
        if i >= len(lines) or not lines[i].startswith("Modul:"):
            if mods and lines and not any(l.startswith(KIND_HDR) for l in lines[:6]):
                # Seite ohne Kopf mitten im Modul (selten): anhaengen
                if not (lines[0].startswith("Stand:") or any(l == "Modul:" for l in lines)):
                    mods[-1]["body"].extend(lines)
            continue
        title_lines = [lines[i][len("Modul:"):].strip()]
        i += 1
        while i < len(lines) and not lines[i].startswith("Module:") and not lines[i].startswith(KIND_HDR):
            title_lines.append(lines[i])
            i += 1
        title = join(title_lines)
        en_lines = 0
        if i < len(lines) and lines[i].startswith("Module:"):
            j = i + 1
            # englischer Titel: bis zur ersten Feldzeile (nur auf der ersten Seite sicher erkennbar)
            while j < len(lines) and not lines[j].startswith(KIND_HDR) and j - i < 4:
                j += 1
            first_page = j < len(lines) and lines[j].startswith(KIND_HDR)
            if first_page:
                en_lines = j - i
            i += 1 if not first_page else en_lines
        body = lines[i:]
        new = not mods or mods[-1]["title"] != title or any(l.startswith(KIND_HDR) for l in body[:3])
        if new:
            mods.append({"title": title, "page": pno, "body": body, "en_lines": en_lines})
        else:
            skip = max(0, mods[-1]["en_lines"] - 1)
            mods[-1]["body"].extend(body[skip:])
    return mods


def _exam_table(rows: list[str]) -> tuple[list[dict], bool]:
    """Pruefungstabelle -> [{kind: PL|SL, art, ects, dauer}]"""
    out = []
    if not rows:
        return out, True
    if rows[0] not in ("PL", "SL"):
        # Zeilenform, Zellen koennen umbrechen ("... und Praesentation" / "(~10 Minuten)" / "benotet")
        merged: list[str] = []
        for r in rows:
            if re.match(r"^(PL|SL) ", r) or not merged:
                merged.append(r)
            else:
                merged[-1] += " " + r
        rows = merged
    singles = [_row(r) for r in rows]
    if all(singles):
        for m in singles:
            out.append({"kind": m.group(1), "art": m.group(2), "ects": m.group(3), "dauer": m.group(4) or ""})
        return out, True
    kinds = []
    i = 0
    while i < len(rows) and rows[i] in ("PL", "SL"):
        kinds.append(rows[i])
        i += 1
    if not kinds:
        # gemischte Form: einzelne Zeilen und Rest
        for r in rows:
            m = _row(r)
            if m:
                out.append({"kind": m.group(1), "art": m.group(2), "ects": m.group(3), "dauer": m.group(4) or ""})
        return out, bool(out)
    rest = rows[i:]
    n = len(kinds)
    grades = 0
    while grades < len(rest) and rest[len(rest) - 1 - grades].lower() in GRADES:
        grades += 1
    middle = rest[: len(rest) - grades]
    j = 0
    while j < len(middle) and not re.fullmatch(NUM, middle[j]):
        j += 1
    arts, k = middle[:j], j
    ects = []
    while k < len(middle) and re.fullmatch(NUM, middle[k]):
        ects.append(middle[k])
        k += 1
    dauer = middle[k:]
    if len(arts) != n:
        # umbrochene Art: auf n Zeilen zusammenlegen geht nicht sicher -> alles an die erste Zeile
        arts = [join(arts)] + [""] * (n - 1)
    aligned = len(dauer) == n
    if not aligned:
        dauer = [join(dauer)] + [""] * (n - 1) if dauer else [""] * n
    for idx in range(n):
        out.append({"kind": kinds[idx], "art": arts[idx], "ects": ects[idx] if idx < len(ects) else None,
                    "dauer": dauer[idx]})
    return out, aligned


def _exam_texts(rows: list[dict]) -> tuple[str | None, str | None]:
    pl, sl = [], []
    for r in rows:
        art, dauer = (r["art"] or "").strip(), (r["dauer"] or "").strip()
        if r["kind"] == "PL":
            pl.append(join([art, dauer]))
        else:
            if art.lower() in COURSEWORK_WORDS:
                sl.append(dauer or art)
            else:
                sl.append(f"{art} ({dauer})" if dauer else art)
    pl = [p for p in pl if p]
    sl = [s for s in sl if s]
    return ("; ".join(pl) or None), ("; ".join(sl) or None)


def parse_module(m: dict) -> dict:
    body = m["body"]
    raw = {"title": m["title"], "page": m["page"], "code": None, "area": None, "kind": None, "lp": None,
           "semester": None, "turnus": "unbekannt", "exam": None, "coursework": None, "prereq": "", "language": None,
           "workload_h": None, "content": None, "goals": None, "literature": None}
    i = 0
    n = len(body)
    # Kopf: Modultyp/Kompetenzbereich, Angebot, Pruefungen
    kind_lines, offer_lines, table = [], [], []
    state = None
    while i < n:
        line = body[i]
        if line.startswith(KIND_HDR):
            state = "kind"
        elif line.startswith(OFFER_HDR):
            state = "offer"
        elif line.startswith(EXAM_HDR):
            state = "exam"
        elif line.startswith(TABLE_HDR):
            state = "table"
        elif _section_of(line, -1) and _section_of(line, -1)[1] == "workload":
            break
        elif state == "kind":
            kind_lines.append(line)
        elif state == "offer":
            offer_lines.append(line)
        elif state == "table":
            table.append(line)
        i += 1
    if kind_lines:
        first = kind_lines[0]
        word, _, rest = first.partition(" ")
        k = kind_of(word)
        if k:
            raw["kind"] = k
            area = join([rest] + kind_lines[1:])
        else:
            area = join(kind_lines)
        # mehrere Kompetenzbereiche ("Entwicklung und Konstruktion, Produktionstechnik"): der erste zaehlt
        raw["area"] = area.split(", ")[0].strip() or None
    offer = join(offer_lines)
    om = OFFER_RE.match(offer)
    if om:
        raw["turnus"] = turnus_of(om.group("turn"))
        raw["language"] = language_of(om.group("lang"))
        raw["lp"] = number(om.group("ects"))
        sm = SEM_RE.search(om.group("rest") or "")
        if sm:
            raw["semester"] = int(sm.group(1))
    elif offer:
        raw["turnus"] = turnus_of(offer.split(" ")[0])
        em = re.search(r"\b(" + NUM + r")\s+(?:Zulassung|Admission)", offer)
        if em:
            raw["lp"] = number(em.group(1))
        sm = SEM_RE.search(offer)
        if sm:
            raw["semester"] = int(sm.group(1))
    rows, _ = _exam_table(table)
    raw["exam"], raw["coursework"] = _exam_texts(rows)
    # Abschnitte
    sec = {}
    cur, pos = None, -1
    for line in body[i:]:
        s = _section_of(line, pos)
        if s:
            pos, cur, inline = s
            sec.setdefault(cur, [])
            if inline:
                sec[cur].append(inline)
            continue
        if cur:
            sec[cur].append(line)
    raw["workload_h"] = workload_of(join(sec.get("workload")))
    pre = join(sec.get("prereq"))
    pre = re.sub(r"^(?:Empfohlen für die Teilnahme:|Recommended for participation:)\s*", "", pre)
    raw["prereq"] = pre
    raw["goals"] = text_join(sec.get("goals"))
    raw["content"] = text_join(sec.get("content"))
    lit = text_join(sec.get("literature"))
    raw["literature"] = None if lit and lit.lower() in ("keine", "none", "-") else lit
    return raw


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    lines = page_lines(pages)
    head = " ".join(" ".join(l) for l in lines[:3])
    stand = next((l for p in lines for l in p[:2] if STAND_RE.match(l)), "")
    term = term_of_catalog(meta.get("catalog_term"), head, stand)
    raw = [parse_module(m) for m in _split_pages(lines)]
    # Bereiche mit LP aus der Studienverlaufsgrafik ("Mathematik (22 LP)"), nur wenn eindeutig
    front = " ".join(" ".join(p) for p in lines[: min(len(lines), 25)] if not any(l.startswith("Modul:") for l in p[:3]))
    specs = {}
    for name in dict.fromkeys(r["area"] for r in raw if r["area"]):
        m = re.search(re.escape(name) + r" \((" + NUM + r")(?: ?- ?(" + NUM + r"))? ?(?:LP|ECTS)\)", front)
        if m:
            specs[name] = {"lp_required": number(m.group(1)), "lp_max": number(m.group(2)) if m.group(2) else None}
    return build_catalog(meta, raw, specs, term)
