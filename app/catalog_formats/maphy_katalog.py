"""Leseprogramm `maphy-katalog`: Modulkataloge der Fakultaet fuer Mathematik und Physik der LUH (Mathematik B.Sc./
M.Sc., Physik B.Sc./M.Sc., Umweltmeteorologie, Lehramt Mathematik und Physik).

Aufbau (docs/STUDIENGAENGE-LUH-2026-11-04.md): Inhaltsverzeichnis mit Abschnitten ("4.1 Pflichtmodule Bachelor",
"3.6 Wahlpflichtbereich Meteorologie"), je Modul eine Seite: Titel, englischer Titel in Klammern, dann
"Semesterlage", "Verantwortlich", "Art der Lehrveranstaltung(en)", "Lehrveranstaltungen (SWS)", "Leistungsnachweise"
(Studienleistung: ... / Pruefungsleistung: ...), "Notenzusammensetzung", "Leistungspunkte (ECTS)" mit der Zahl in
der Zeile darunter und "Insgesamt: 300h", danach "Kompetenzziel:", "Inhalte:", "Grundlegende Literatur:",
"Vorkenntnisse:", "Eingangsvoraussetzungen:", "Modulverwendbarkeit:". Modulgrenze: "Semesterlage". Hinten folgen
Lehrveranstaltungen ("Regelmaessigkeit:", "Sprache:", "Modulzugehoerigkeit:") - keine Module, aber die Sprache
einer Lehrveranstaltung geht auf das Modul ueber, wenn alle seine Lehrveranstaltungen dieselbe nennen.

Ein empfohlenes Fachsemester steht nur in der Umweltmeteorologie im Modul ("Wintersemester, 1. Semester"); sonst in
der Pruefungsordnung (null).

Eingabe wie phil_kv_tabelle: Seitentexte, am besten mit Spaltenlage (pypdf Layout-Modus); normale pypdf-Texte gehen.
Ausgabe: (Katalog im geteilten Format, {modul_id: {content, goals, literature}}).
"""
from __future__ import annotations

import re

from app.study_catalog import _fold, normalize_lines
from app.catalog_formats.formats_a_common import clip, kind_of, language_of, number, turnus_of
from app.catalog_formats.phil_kv_tabelle import (
    _families,
    build_with_prereqs,
    _raw_lines,
    catalog_term,
    layout_pages,  # noqa: F401  (Aufrufer lesen PDFs ueber dieses Modul)
    program_family,
)

FORMAT = "maphy-katalog"

SECTION_RE = re.compile(r"^\s*([0-9]{1,2}(?:\.[0-9]{1,2}){0,2})\.?\s+([A-ZÄÖÜ].{2,})$")
TOC_RE = re.compile(r"(?:\. ){3,}|\.{6,}|\s{2,}[0-9]{1,3}\s*$")

# (Anfang des gefalteten Schluessels, Feld)
LABELS = (
    ("semesterlage", "semlage"),
    ("verantwortlich", "resp"),
    ("art der lehrveranstaltung", "lv"),
    ("veranstaltungstyp", "lv"),
    ("lehrveranstaltungen (sws)", "sws"),
    ("lehrveranstaltungen", "sws"),
    ("leistungsnachweise", "proofs"),
    ("notenzusammensetzung", "other"),
    ("leistungspunkte (ects)", "lp"),
    ("leistungspunkte", "lp"),
    ("kompetenzziel", "goals"),
    ("qualifikationsziel", "goals"),
    ("inhalte", "content"),
    ("inhalt", "content"),
    ("grundlegende literatur", "literature"),
    ("literatur", "literature"),
    ("empfohlene vorkenntnisse", "prereq"),
    ("vorkenntnisse", "prereq"),
    ("eingangsvoraussetzungen", "prereq"),
    ("modulverwendbarkeit", "usage"),
    ("sprache", "language"),
    ("unterrichtssprache", "language"),
    ("bemerkung", "other"),
)
TEXT_FIELDS = ("goals", "content", "literature")


def _label(line: str):
    """Zeile beginnt mit einem Schluessel? -> (Feld, Rest der Zeile)"""
    s = line.strip()
    f = _fold(s)
    for lab, key in LABELS:
        if f.startswith(lab):
            n = len(lab)
            # Laenge im Original: _fold aendert die Laenge nur bei Umlauten (ae, oe, ue, ss)
            orig = 0
            acc = ""
            while orig < len(s) and len(acc) < n:
                acc += _fold(s[orig])
                orig += 1
            rest = s[orig:]
            if rest[:1].isalpha() and lab not in ("lehrveranstaltungen (sws)", "notenzusammensetzung",
                                                   "leistungspunkte (ects)"):
                # "Inhaltsverzeichnis" ist kein "Inhalt"; zusammengeklebte Werte nur bei bekannten Faellen
                if not (lab in ("semesterlage",) and rest[:1].isupper()):
                    continue
            return key, rest.strip(" :")
    return None, None


def _pages_lines(pages: list[str]) -> list[list[str]]:
    """Zeilen je Seite; Seitenzahl am Seitenende weg (auch angeklebt: 'Technical Education.27')"""
    out = []
    for n, t in enumerate(pages, start=1):
        lines = _raw_lines(t)
        while lines and lines[-1].strip() == str(n):
            lines.pop()
        if lines:
            last = lines[-1].rstrip()
            if last.endswith(str(n)) and not last.strip() == str(n):
                cut = last[: -len(str(n))]
                if cut.rstrip() != cut or cut.endswith((".", ")", ",")) or re.search(r"[a-zäöü]$", cut):
                    lines[-1] = cut.rstrip()
        out.append(lines)
    return out


def _is_section(line: str) -> str | None:
    s = line.strip()
    if TOC_RE.search(line) and not re.match(r"^\s*[0-9.]+\s+\S.*\S$", s):
        return None
    m = SECTION_RE.match(s)
    if not m or TOC_RE.search(s) or len(s) > 110:
        return None
    return m.group(2).strip()


def _blocks(pages: list[str]) -> tuple[list[dict], dict]:
    """-> (Rohbloecke je Modul, Sprache je Lehrveranstaltung aus dem Anhang)"""
    plines = _pages_lines(pages)
    flat = [(p, l) for p, ls in enumerate(plines, start=1) for l in ls]
    # Modulanfaenge: Zeile "Semesterlage ..." am linken Rand
    starts = [i for i, (_, l) in enumerate(flat) if len(l) - len(l.lstrip()) <= 3 and _label(l)[0] == "semlage"]
    # Lehrveranstaltungen im Anhang: Titelzeile vor "Leistungspunkte:" / "Mathematikbereich:" mit "Sprache:"
    course_lang = {}
    for i, (p, l) in enumerate(flat):
        m = re.search(r"Sprache:\s*([A-Za-zÄÖÜäöü/ ,]+?)(?:\s{2,}|$)", l)
        if m and i > 0:
            j = i - 1
            while j >= 0 and flat[j][0] == p and re.search(r":\s", flat[j][1]):
                j -= 1
            if j >= 0 and flat[j][0] == p:
                t = flat[j][1].strip()
                if t and not _label(t)[0]:
                    course_lang[_fold(t)] = language_of(m.group(1))
    blocks = []
    area = None
    area_pos = 0
    title_starts = []
    for s in starts:
        p = flat[s][0]
        # Titel: Zeilen derselben Seite direkt ueber "Semesterlage" (hoechstens drei; englische Klammerzeile weg)
        j = s - 1
        title_lines: list[str] = []
        while j >= 0 and flat[j][0] == p and s - j <= 4:
            l = flat[j][1].strip()
            if _is_section(flat[j][1]) or _label(l)[0]:
                break
            title_lines.insert(0, l)
            j -= 1
        title_starts.append(j + 1)
        blocks.append({"start": s, "title_lines": title_lines, "page": flat[(j + 1) if title_lines else s][0]})
    for n, b in enumerate(blocks):
        s = b["start"]
        # Bereich: letzte Abschnittsueberschrift vor dem Titel
        for k in range(area_pos, title_starts[n]):
            sec = _is_section(flat[k][1])
            if sec:
                area = sec
        area_pos = title_starts[n]
        end = title_starts[n + 1] if n + 1 < len(blocks) else len(flat)
        # nie ueber eine Abschnittsueberschrift oder mehr als drei Seiten hinaus
        for k in range(s + 1, end):
            if _is_section(flat[k][1]) or flat[k][0] > flat[s][0] + 3:
                end = k
                break
        fields: list[list] = []
        for k in range(s, end):
            l = flat[k][1]
            indent = len(l) - len(l.lstrip())
            key, rest = _label(l) if indent <= 3 else (None, None)
            if key:
                fields.append([key, [rest] if rest else []])
            elif fields:
                fields[-1][1].append(l.strip())
        b["fields"] = fields
        b["area"] = area
    return blocks, course_lang


def _val(fields, key) -> str:
    return " ".join(" ".join(" ".join(v) for k, v in fields if k == key).split())


def _txt(fields, key) -> str | None:
    t = "\n".join(" ".join(x.split()) for k, v in fields if k == key for x in v if x.strip()).strip()
    return t or None


def _title(lines: list[str]) -> str:
    keep = [l for l in lines if not re.fullmatch(r"\(.*\)", l.strip())]
    # englischer Titel in Klammern ueber zwei Zeilen: "(Basic Module ..." / "... Mathematics)"
    out = []
    depth = 0
    for l in keep:
        if l.startswith("(") or depth > 0:
            depth += l.count("(") - l.count(")")
            continue
        out.append(l)
    t = " ".join(" ".join(out).split())
    return t.strip(" .")


def _proofs(text: str) -> tuple[str | None, str | None]:
    t = " ".join(text.split())
    t = re.sub(r"(\w)- (\w)", r"\1\2", t)
    exam = cw = None
    m_sl = re.search(r"Studienleistung(?:en)?:?", t)
    m_pl = re.search(r"Prüfungsleistung(?:en)?:?", t)
    if m_pl and m_sl:
        if m_sl.start() < m_pl.start():
            cw, exam = t[m_sl.end():m_pl.start()], t[m_pl.end():]
        else:
            exam, cw = t[m_pl.end():m_sl.start()], t[m_sl.end():]
    elif m_pl:
        exam = t[m_pl.end():]
    elif m_sl:
        cw = t[m_sl.end():]
    elif t:
        exam = t

    def short(s):
        s = (s or "").strip(" .;,")
        if not s or _fold(s) in ("keine", "-", "keine studienleistung", "keine pruefungsleistung"):
            return None
        return clip(s, 300)
    return short(exam), short(cw)


SEM_RE = re.compile(r"(?:ab (?:dem )?)?([0-9]{1,2})\. ?(?:Fach)?[Ss]emester")


def raw_module(b: dict, course_lang: dict) -> dict:
    f = b["fields"]
    lp_text = _val(f, "lp")
    m = re.match(r"^\s*([0-9]+(?:[.,][0-9]+)?)\b(?!\s*h)", lp_text) or \
        re.search(r"(?:^|\s)([0-9]+(?:[.,][0-9]+)?)\s+(?=[0-9]+(?:[.,][0-9]+)? ?h\b)", lp_text)
    lp = number(m.group(1)) if m else None
    wm = re.search(r"Insgesamt:?\s*([0-9]+)\s*h", lp_text)
    workload = number(wm.group(1)) if wm else None
    if workload is None:
        parts = [number(x) for x in re.findall(r"([0-9]+) ?h (?:Präsenz|Selbst)", lp_text)]
        workload = sum(parts) if len(parts) >= 2 else None
    if lp is not None and workload is not None and lp > 0 and workload < 20 * lp:
        workload = None
    if lp is not None and (lp > 60 or lp <= 0):
        lp = None
    exam, cw = _proofs(_val(f, "proofs"))
    semlage = _val(f, "semlage")
    sm = SEM_RE.search(semlage)
    # Sprache: ausdrueckliche Angabe, sonst die gemeinsame Sprache der Lehrveranstaltungen aus dem Anhang
    lang = language_of(_val(f, "language")) if _val(f, "language") else None
    if lang is None and course_lang:
        sws = _fold(_val(f, "sws"))
        found = {v for k, v in course_lang.items() if v and len(k) > 4 and k in sws}
        if len(found) == 1:
            lang = found.pop()
    area = b.get("area") or ""
    kind = None
    fa = _fold(area)
    if re.search(r"wahlpflicht", fa):
        kind = "wahlpflicht"
    elif re.search(r"\bwahl", fa):
        kind = "wahl"
    elif re.search(r"pflicht|kernmodul|grundlagen", fa):
        kind = "pflicht"
    title = _title(b["title_lines"])
    if re.match(r"^wahlmodul", _fold(title)):
        kind = kind or "wahl"
    return {
        "title": title,
        "code": None,
        "area": area or None,
        "kind": kind_of(kind) if kind else None,
        "lp": lp,
        "semester": int(sm.group(1)) if sm and 1 <= int(sm.group(1)) <= 20 else None,
        "turnus": turnus_of(re.split(r",|\bab\b", semlage)[0] if semlage else ""),
        "exam": exam,
        "coursework": cw,
        "prereq": _val(f, "prereq"),
        "language": lang,
        "workload_h": workload,
        "page": b["page"],
        "usage": _val(f, "usage"),
        "content": _txt(f, "content"),
        "goals": _txt(f, "goals"),
        "literature": _txt(f, "literature"),
    }


def _degree_class(degree: str | None) -> str | None:
    d = _fold(degree or "")
    if d.startswith("b"):
        return "bachelor"
    if d.startswith("m"):
        return "master"
    return None


def keep_for_program(raw: dict, meta: dict) -> bool:
    """Gemeinsamer Katalog mehrerer Studiengaenge: Lehramt ueber die Familie (FueBa, TE, LG, LBS, Sprint,
    Sonderpaedagogik), Fachstudiengang ueber Bachelor/Master in Verwendbarkeit oder Abschnitt."""
    usage = _fold(raw.get("usage") or "")
    family = program_family(meta.get("program_key"))
    if family:
        fams = _families(raw.get("usage") or "")
        if not fams and re.search(r"zert", usage):
            return False
        return not fams or family in fams
    cls = _degree_class(meta.get("degree"))
    if not cls:
        return True
    other = "master" if cls == "bachelor" else "bachelor"
    if usage:
        if cls in usage:
            return True
        if other in usage:
            return False
    area = _fold(raw.get("area") or "")
    if other in area and cls not in area:
        return False
    return True


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    blocks, course_lang = _blocks(pages)
    raw = []
    for b in blocks:
        r = raw_module(b, course_lang)
        if not r["title"]:
            continue
        if meta.get("shared_catalog") and not keep_for_program(r, meta):
            continue
        raw.append(r)
    first = "\n".join(" ".join(l.split()) for t in pages[:2] for l in normalize_lines(t))
    term = catalog_term(meta.get("catalog_term"), first, meta.get("term_hint"),
                        (meta.get("source") or {}).get("fetched_at"))
    return build_with_prereqs(meta, raw, term)
