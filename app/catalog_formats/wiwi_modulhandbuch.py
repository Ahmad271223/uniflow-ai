"""Leseprogramm `wiwi-modulhandbuch`: Modulhandbuecher der Wirtschaftswissenschaftlichen Fakultaet (Datenbank-Ausgabe).

Zwei Fassungen:
A) je Semester ("Sommersemester 2026"): Titel, "(englischer Titel)", Tabelle "Verwendbarkeit Art Semester von - bis"
   mit Zeilen "<Studiengang> - Kompetenzbereich <Bereich>" / "Pflichtmodul 3 - 3", "Leistungspunkte (ECTS) 8",
   "Workload in h 240 / 56 / 184", "Modulverantwortung", "Qualifikationsziele", "Voraussetzungen fuer die Teilnahme",
   "Veranstaltungsdaten fuer das <Semester>" (Belegnr., Titel, SWS und Art | Termin und Raum | Dozent(in) | Sprache),
   "Pruefungsleistung im <Semester>", "Pruefungsnummer", "Pruefungsform (und -dauer)", "Pruefer/in".
   Den Turnus nennt diese Fassung nicht; er kommt nur aus meta["turnus_hints"] (Titel -> Turnus, z. B. aus der
   semesterunabhaengigen Fassung derselben Fakultaet).
B) semesterunabhaengig (Digital Business): Zeilen "Pflichtmodul Bachelor ... - Kompetenzbereich ... 1 - 1 270164 6
   180 / 42 / 138", Kopf "Voraussetzungen fuer die Teilnahme | Pruefungsform (und -dauer) | Pruefer(in) | ...",
   Lehrveranstaltungen "270164 Einfuehrung in die BWL 1 Vorlesung Deutsch Winter" -> Turnus und Sprache.
Modulgrenze: Tabellenkopf "Verwendbarkeit Art" bzw. "Art Verwendbarkeit" (der Titel steht darueber).
"""
from __future__ import annotations

import re
from collections import Counter

from .formats_a_common import NUM, build_catalog, clip, kind_of, language_of, number, page_lines, \
    term_of_catalog, text_join, turnus_of

ANCHOR_RE = re.compile(r"^(?:Verwendbarkeit Art Semester|Art Verwendbarkeit Semester)")
ART = r"(Pflichtmodul|Wahlpflichtmodul|Wahlmodul|Seminar|Schwerpunktmodul|Abschlussmodul|Bachelorarbeit|Masterarbeit|Pflicht|Wahlpflicht|Wahl)"
ROW_A_RE = re.compile(ART + r"\s+([0-9]{1,2})\s*-\s*([0-9]{1,2})(?=\s|$)")
ROW_B_RE = re.compile(ART + r"\s+(.+?)\s+([0-9]{1,2})\s*-\s*([0-9]{1,2})\s+(?:([0-9]{5,7})\s+)?(" + NUM
                      + r")\s+([0-9]+)\s*/")
FOOT_RE = re.compile(r"^[0-9]{1,3} / [0-9]{1,3}$")
COURSE_B_RE = re.compile(r"^[0-9]{5,7}\s+.+?\s(Vorlesung|Übung|Tutorium|Seminar|Praktikum|Projekt|Kolloquium|Exkursion|"
                         r"Planspiel|Workshop|Fallstudie|Repetitorium|Lecture|Exercise|Blockveranstaltung)\s+"
                         r"(Deutsch|Englisch|English|German|Deutsch/Englisch)\s+(Winter|Sommer|Winter/Sommer|"
                         r"Sommer/Winter|Winter und Sommer)\b")
PERSON_START = re.compile(r"(?:Prof\.|Jun\.-Prof|Juniorprof|apl\. Prof|PD |Dr\.|N\.N\.|Dipl\.|M\.Sc\.|Professor)")
EXAM_WORDS = re.compile(r"(Klausur|Hausarbeit|[Mm]ündliche|Präsentation|Referat|Projekt|Portfolio|Seminarleistung|"
                        r"Studienarbeit|Bachelorarbeit|Masterarbeit|Ausarbeitung|Kombinationsprüfung|Prüfung|Essay|"
                        r"Fallstudie|Assignment|Written|Oral|Term paper|Exam|Seminararbeit|Planspiel|Experiment|"
                        r"Kurzklausur|E-Klausur|Test)")
TEXT_LABELS = {"Qualifikationsziele": "goals", "Inhalte": "content", "Literatur": "literature"}
STOP_LABELS = ("Kompetenzfelder", "Voraussetzungen für die Teilnahme", "Bemerkungen", "Veranstaltungsdaten", "Belegnr.",
               "Prüfungsleistung im", "Prüfungsnummer", "Link", "Veranstaltungen", "Literatur", "Inhalte",
               "Lehr- und Lernmethoden", "Modulverantwortung", "Qualifikationsziele")


def _strip(pages: list[list[str]]):
    """Kopfzeilen (wiederholt am Seitenanfang) und Fuss "11 / 103" weg -> [(seite, zeile)], Kopf der ersten Seite"""
    cnt: Counter = Counter()
    for lines in pages:
        cnt.update(set(lines[:3]))
    limit = max(2, len(pages) // 2)
    heads = {l for l, v in cnt.items() if v >= limit}
    out = []
    for pno, lines in enumerate(pages, 1):
        for i, l in enumerate(lines):
            if (i < 4 and l in heads) or FOOT_RE.match(l):
                continue
            out.append((pno, l))
    first = pages[0][:4] if pages else []
    return out, [l for l in first if l in heads]


def _program_of(header: list[str]) -> str:
    for l in header:
        if re.match(r"^(Bachelor|Master)\s", l):
            return l
    return ""


def _title(texts: list[str], a: int, lower: int, pages_of=None) -> tuple[str, int]:
    """Titel ueber dem Tabellenkopf: Zeilen davor, englische Klammerzeilen weg"""
    j = a - 1
    paren = []
    # englischer Titel in Klammern (kann umbrechen)
    if j >= lower and texts[j].endswith(")"):
        while j >= lower:
            paren.insert(0, texts[j])
            if texts[j].startswith("("):
                break
            j -= 1
        j -= 1
    lines = []
    while j >= lower and len(lines) < 3:
        l = texts[j]
        if pages_of and pages_of[j] != pages_of[a]:
            break
        if re.match(r"^(Prüfer|Bemerkungen|Link|Klausurtermin|Prüfungsform|Prüfungsnummer|-dauer\))", l) or \
                l.endswith((".", ":")) or FOOT_RE.match(l) or PERSON_START.match(l):
            break
        lines.insert(0, l)
        j -= 1
    title = " ".join(lines).strip()
    if not title and paren:
        title = " ".join(paren).strip("() ")
    return title, j + 1


def _season(word: str) -> str:
    w = word.lower()
    if "winter" in w and "sommer" in w:
        return "WS+SS"
    return "WS" if "winter" in w else ("SS" if "sommer" in w else "unbekannt")


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    plines = page_lines(pages)
    lines, header = _strip(plines)
    head_text = " ".join(header) + " " + " ".join(" ".join(p[:6]) for p in plines[:1])
    term = term_of_catalog(meta.get("catalog_term"), head_text)
    program = _program_of(header) or ""
    hints = {k.lower(): v for k, v in (meta.get("turnus_hints") or {}).items()}
    texts = [l for _, l in lines]
    anchors = [i for i, l in enumerate(texts) if ANCHOR_RE.match(l)]
    starts = []
    prev = 0
    for a in anchors:
        title, s = _title(texts, a, prev, [p for p, _ in lines])
        starts.append((s, a, title))
        prev = a + 1
    raw = []
    for n, (s, a, title) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(texts)
        block = texts[a:end]
        joined = "\n".join(block)
        flat = re.sub(r"\s+", " ", joined)
        rec = {"title": title, "page": lines[s][0] if s < len(lines) else None, "code": None, "area": None,
               "kind": None, "lp": None, "semester": None, "turnus": "unbekannt", "exam": None, "coursework": None,
               "prereq": "", "language": None, "workload_h": None, "content": None, "goals": None, "literature": None}
        rows = []
        mb = list(ROW_B_RE.finditer(flat[: flat.find("Voraussetzungen für die Teilnahme")]
                                    if "Voraussetzungen für die Teilnahme" in flat else flat[:1500]))
        variant_b = texts[a].startswith("Art Verwendbarkeit")
        if variant_b and mb:
            for m in mb:
                rows.append({"art": m.group(1), "use": m.group(2), "von": int(m.group(3)), "code": m.group(5),
                             "lp": number(m.group(6)), "wl": number(m.group(7))})
        else:
            stop = flat.find("Leistungspunkte")
            table = flat[: stop if stop > 0 else 1500]
            table = re.sub(r"^.*?- bis\s*", "", table)
            last = 0
            for m in ROW_A_RE.finditer(table):
                rows.append({"art": m.group(1), "use": table[last:m.start()].strip(), "von": int(m.group(2))})
                last = m.end()
            lm = re.search(r"Leistungspunkte \(ECTS\) (" + NUM + r")", flat)
            if lm:
                rec["lp"] = number(lm.group(1))
            wm = re.search(r"Workload in h (" + NUM + r")", flat)
            if wm:
                rec["workload_h"] = number(wm.group(1))
        pkey = re.sub(r"\s+", " ", program).lower()
        mine = [r for r in rows if pkey and r["use"].lower().startswith(pkey)] or rows
        if mine:
            r = mine[0]
            k = kind_of(r["art"])
            rec["kind"] = k or ("wahlpflicht" if r["art"] == "Seminar" else None)
            rec["semester"] = r["von"]
            am = re.search(r"Kompetenzbereich\s+(.+)$", r["use"])
            rec["area"] = am.group(1).strip() if am else (r["use"].split(" - ", 1)[1].strip() if " - " in r["use"] else None)
            if r.get("lp") is not None:
                rec["lp"] = r["lp"]
                rec["workload_h"] = r.get("wl")
            if r.get("code"):
                rec["code"] = r["code"]
        # Pruefungen
        exams = []
        if variant_b:
            hm = re.search(r"Modulverantwort-? ?liche\(r\)\s*(.*?)\s*(?:Qualifikationsziele|Kompetenzfelder)", flat)
            if hm:
                val = hm.group(1)
                em = EXAM_WORDS.search(val)
                if em:
                    pre_text = val[: em.start()].strip()
                    rest = val[em.start():]
                    pm = PERSON_START.search(rest)
                    exams.append(rest[: pm.start()].strip() if pm else rest[:120])
                    rec["prereq"] = pre_text
                else:
                    rec["prereq"] = val
        for m in re.finditer(r"Prüfungsform \(und -dauer\)\s*(.*?)\s*(?=Klausurtermin|Prüfer/in|Prüfer\(in\)|"
                             r"Prüfungsleistung im|Prüfungsnummer|$)", flat):
            v = m.group(1).strip()
            if v and v not in exams and not v.startswith("Prüfer"):
                exams.append(v)
        rec["exam"] = "; ".join(exams[:4]) or None
        sm = re.search(r"Studienleistung(?:en)?:?\s+(.{3,160}?)(?:\.|$| Prüfung)", flat)
        if sm and not sm.group(1).lower().startswith("keine"):
            rec["coursework"] = sm.group(1).strip()
        if not variant_b:
            pm = re.search(r"Voraussetzungen für die Teilnahme\s+(.*?)\s+(?:Bemerkungen|Veranstaltungsdaten|Kompetenzfelder|$)", flat)
            if pm:
                rec["prereq"] = pm.group(1)
        # Turnus und Sprache
        seasons, langs = set(), []
        for l in block:
            cm = COURSE_B_RE.match(l)
            if cm:
                seasons.add(_season(cm.group(3)))
                langs.append(cm.group(2))
        if seasons:
            if "WS+SS" in seasons or {"WS", "SS"} <= seasons:
                rec["turnus"] = "WS+SS"
            else:
                rec["turnus"] = seasons.pop()
        elif title.lower() in hints:
            rec["turnus"] = hints[title.lower()]
        if not langs:
            for l in block:
                lm = re.search(r"\b(Deutsch|Englisch|English)$", l)
                if lm:
                    langs.append(lm.group(1))
        if langs:
            rec["language"] = "/".join(dict.fromkeys(language_of(x) for x in langs))
        # lokale Texte
        sec, cur = {}, None
        for l in block:
            if l in TEXT_LABELS:
                cur = TEXT_LABELS[l]
                sec.setdefault(cur, [])
                continue
            if l.startswith(STOP_LABELS) or COURSE_B_RE.match(l):
                cur = None
                continue
            if cur:
                sec[cur].append(l)
        rec["goals"] = text_join(sec.get("goals"))
        rec["content"] = text_join(sec.get("content"))
        rec["literature"] = text_join(sec.get("literature"))
        if title:
            raw.append(rec)
    return build_catalog(meta, raw, None, term)


def turnus_hints(catalog: dict) -> dict:
    """Titel -> Turnus aus einem gelesenen Katalog (nur bekannte Werte), fuer die Semesterfassungen"""
    return {m["title"]: m["turnus"] for m in catalog.get("modules") or [] if m.get("turnus") not in (None, "unbekannt")}
