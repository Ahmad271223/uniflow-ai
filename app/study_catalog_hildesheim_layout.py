"""Zwei weitere Leser fuer Modulhandbuecher der Universitaet Hildesheim, deren Module als mehrspaltige Tabellen gesetzt
sind (Auftrag 14./15.11.2026, docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md). Gleiche Regeln im Swift-Kern
(UniFlowCore/StudyCatalog/StudyCatalogHildesheimLayoutParser.swift); gemeinsame Fixture
packages/shared-contracts/fixtures/study-catalog-hildesheim-layout (tools/gen-study-catalog-hildesheim-layout-fixture.py).

Eingabe sind Seitentexte im Layout-Modus (`app.catalog_formats.hildesheim.layout_pages`, pypdf mit
extraction_mode="layout"): die Spalten einer Tabellenzeile stehen in einer Textzeile, getrennt durch mindestens zwei
Leerzeichen. `layout_lines` macht daraus je Zeile die Zellen mit ihrer Spalte (Zeichen ab Zeilenanfang).

`hildesheim-kuerzel-modultabelle` - Studienordnungen des Fachs Informatik im Lehramt ab 2026 (Verkuendungsblatt Heft 214):
  INF-B1: „Einführung in die Informatik“                       Titelzeile: Kuerzel, Doppelpunkt, Titel in Anfuehrungszeichen
  Für das Modul verantwortliche Person ...: siehe Modulhandbuch Angewandte Informatik   (oder ": Prof. ...")
  Studiensemester | Dauer des Moduls | Häufigkeit des Angebots | Status Modul            Kopf, Werte in der Zeile darunter
  Inhalte und Qualifikationsziele des Moduls: ...
  Lehr-/Lernformen; Arbeitsaufwand: Teilmodul | Lehrform | Titel | Kontaktzeit | Selbststudium | SWS | LP
                                    je Teilmodul eine Zeile, LP in der letzten Spalte (Summe = LP des Moduls); eine
                                    Zeile "s. RStO ...   13" nennt die LP des ganzen Moduls
  Voraussetzung für die Teilnahme | Studienleistungen | Voraussetzung für die Zulassung zur Prüfung
  Voraussetzung für die Vergabe von ECTS-Leistungspunkten: (Teil-)Modul | Art der Prüfung | Prüfungsformen | Prüfungsleistungen
  Verwendbarkeit des Moduls | Zuständige Ständige Prüfungskommission
  Der Titel steht auf jeder Folgeseite noch einmal (Kolumnentitel). Pflicht oder Wahlpflicht: "Status Modul"
  ("Pflichtmodul", "Wahlpflichtmodul"); steht dort nur ein Verweis ("s. Anlage 1 – Modulübersicht(en)"), gilt die
  Anlage "Beschreibung der Studienvarianten" mit einer Zeile "Pflichtmodule: INF-B1, INF-B2, ..." je Studienvariante:
  Pflicht ist ein Modul nur, wenn es in JEDER Studienvariante Pflichtmodul ist, sonst Wahlpflicht (die Regeln je
  Variante stehen als Handangabe in study-area-rules-hildesheim.json).

`hildesheim-kennnummer-tabelle` - Masterstudiengang Barrierefreie Kommunikation (Heft 193):
  BK 1 Grundlagen der Barrierefreien Kommunikation             Titelzeile, auch "Modul MuM 1 – Titel" (Medientext und
                                                               Medienübersetzung) und ueber zwei Zeilen
  Kennnummer | Workload | Credits | Studiensemester | Häufigkeit des Angebots | Dauer    Kopf, Werte in der Zeile darunter
  1 Lehrveranstaltungen | Kontaktzeit | Selbststudium | geplante Gruppengröße
  2 Lernergebnisse (learning outcomes)/Kompetenzen, 3 Inhalte, 4 Lehrformen, 5 Teilnahmevoraussetzungen,
  6 Prüfungsformen, 7 Voraussetzungen für die Vergabe von Leistungspunkten (darin "Studienleistungen:" und
  "Prüfungsleistung:"), 8 Verwendung des Moduls, 9 Stellenwert der Note für die Endnote, 10 Modulbeauftragte/r und
  hauptamtlich Lehrende, 11 Sonstige Informationen
  Module sind Pflicht, mit "(Wahlpflichtmodul)" im Titel Wahlpflicht, die Masterarbeit ist `abschluss`.

Was nicht sicher lesbar ist, bleibt leer. `prerequisites` und `language` bleiben leer, `areas` nur beim ersten Format
mit Anlage der Studienvarianten ("Pflichtmodule", "Wahlpflichtmodule").
"""
from __future__ import annotations

import re
import unicodedata

from app.study_catalog import MAX_TEXT, _BREAK_TABLE, _unique, slug

KUERZEL_FORMAT = "hildesheim-kuerzel-modultabelle"
KENNNUMMER_FORMAT = "hildesheim-kennnummer-tabelle"

HEADER_RE = re.compile(r"^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft .*[-–] ?Seite ?[0-9]+ ?[-–]?$")
ANNEX_RE = re.compile(r"^Anlage ([0-9]+)[a-z]? ?: ?(.*)$")
FINAL_RE = re.compile(r"bachelorarbeit|masterarbeit|abschlussarbeit|^abschlussmodul|^abschluss$")
NONE_VALUES = ("", "-", "–", "keine", "keiner", "nein", "entfällt")
REFERENCE_RE = re.compile(r"^(?:s\. |siehe )")
MAX_FACT = 200            # Pruefungs- und Studienleistung im Grundstock hoechstens so lang
JOIN_WORDS = ("und", "oder", "bzw", "bzw.", "sowie")
EVERY_TERM_RE = re.compile(r"jede[sm] semester")
WINTER_RE = re.compile(r"winter|\bwise\b|\bws\b")
SUMMER_RE = re.compile(r"sommer|\bsose\b|\bss\b")
FIRST_INT_RE = re.compile(r"[0-9]{1,2}")
NUMBER_RE = re.compile(r"^[0-9]{1,3}(?:,[0-9])?$")
HOURS_RE = re.compile(r"^(?:[0-9]{1,4}|-)$")
SPACE_BEFORE_RE = re.compile(r" ([),;.])")
SPACE_AFTER_RE = re.compile(r"\( ")

# erstes Format
CODE = r"[A-Z][A-Za-z]{1,6}[-_][A-Za-z]{1,4}[0-9]{1,2}"
K_TITLE_RE = re.compile("^(" + CODE + r") ?: ?[„“”\"](.+?)[“”„\"](?: .*)?$")
K_CODE_RE = re.compile("(?<![A-Za-z0-9_-])" + CODE + "(?![A-Za-z0-9])")
K_REQUIRED_RE = re.compile(r"^Pflichtmodule ?: ?(.*)$")
K_ELECTIVE_RE = re.compile(r"^Wahlpflichtmodule ?:")
K_END_RE = re.compile(r"^Abkürzungen ?:")
K_REQ_RE = re.compile(r"^Voraussetzung(?:en)? für die$")
K_COURSEWORK_RE = re.compile(r"^Studienleistung(?:en)?$")
K_EXAM_MARK_RE = re.compile(r"^T?MP$")
K_PART_RE = re.compile(r"^(TM ?[0-9]{1,2})\b")
K_VALUE_COL = 30          # Wertspalte, solange kein Tabellenkopf "Studiensemester | Dauer ..." sie nennt
K_LABEL_GAP = 4           # Zellen bis so viele Zeichen vor der Wertspalte gehoeren noch zur Feldnamen-Spalte
K_COL_TOLERANCE = 2
K_KEEP = ("content", "forms")   # Abschnitte, die ueber den Kolumnentitel der Folgeseite weiterlaufen

# zweites Format
N_TITLE_RE = re.compile(r"^(?:Modul )?([A-Z][A-Za-z]{0,3}) ?([0-9]{1,2}) (?:[–-] )?(.+)$")
N_ELECTIVE_RE = re.compile(r"\(Wahlpflicht(?:modul)?\)")
N_HEAD_KEY = "KennnummerWorkloadCredits"
N_WORKLOAD_RE = re.compile(r"^([0-9]{2,4}) ?h$")
N_SEMESTER_RE = re.compile(r"^([1-9])\.")
N_ROW_RE = re.compile(r"^[0-9]{1,2}$")
N_ROWS = (("Lehrveranstaltungen", "courses"), ("Lernergebnisse", "goals"), ("Inhalte", "content"), ("Lehrformen", "forms"),
          ("Teilnahmevoraussetzungen", "prereq"), ("Prüfungsformen", "exam"), ("Voraussetzungen für die Vergabe", "credit"),
          ("Verwendung des Moduls", "usage"), ("Stellenwert", "weight"), ("Modulbeauftragte", "lead"),
          ("Sonstige Informationen", "remarks"))
N_COURSEWORK_RE = re.compile(r"^Studienleistung(?:en)? ?:?$")
N_EXAM_RE = re.compile(r"^Prüfungsleistung(?:en)? ?:?$")
N_ITEM_RE = re.compile(r"^[0-9]{1,2}\.[0-9]")
N_LABEL_INDENT = 3
N_TITLE_BACK = 2


# --------------------------------------------------------------------------------------------------------------------
# Zeilen und Werte
# --------------------------------------------------------------------------------------------------------------------

def layout_lines(pages: list[str]) -> list[list[list]]:
    """Seitentexte im Layout-Modus -> je Seite die nichtleeren Zeilen als Zellen [[Spalte, Text], ...]: NFKC, jeder
    Zeilenumbruch gleich, Tabulator zu Leerzeichen; eine Zelle endet an zwei oder mehr Leerzeichen. Der Seitenkopf des
    Verkuendungsblatts faellt weg."""
    out = []
    for text in pages:
        t = unicodedata.normalize("NFKC", text or "").translate(_BREAK_TABLE)
        lines = []
        for raw in t.split("\n"):
            cells: list[list] = []
            start, cur, spaces = 0, "", 0
            for i, ch in enumerate(raw):
                if ch == " ":
                    spaces += 1
                    continue
                if cur and spaces >= 2:
                    cells.append([start, cur])
                    cur = ""
                if not cur:
                    start = i
                elif spaces == 1:
                    cur += " "
                cur += ch
                spaces = 0
            if cur:
                cells.append([start, cur])
            if cells and not HEADER_RE.match(" ".join(c[1] for c in cells)):
                lines.append(cells)
        out.append(lines)
    return out


def _join(parts: list[str]) -> str:
    """Zeilenstuecke -> ein Text; Silbentrennung am Zeilenende faellt weg ("Ausarbei-" + "tung"), "Haupt-" + "und" bleibt"""
    t = ""
    for p in parts:
        if not p:
            continue
        if t.endswith("-") and p[:1].islower() and p.split(" ")[0] not in JOIN_WORDS:
            t = t[:-1] + p
        else:
            t = (t + " " + p) if t else p
    return SPACE_AFTER_RE.sub("(", SPACE_BEFORE_RE.sub(r"\1", t))


def _clip(s: str, limit: int = MAX_TEXT) -> str | None:
    """Raender weg, leer -> None, hoechstens `limit` Zeichen (am Wortende gekuerzt, mit "…")"""
    s = s.strip(" ;,")
    if not s:
        return None
    if len(s) > limit:
        s = s[:limit - 1].rsplit(" ", 1)[0] + "…"
    return s


def _fact(parts: list[str]) -> str | None:
    """Studien-/Pruefungsleistung: zusammengefuegt, "-", "keine", "--- entfällt ---" -> None"""
    s = _join(parts)
    return None if s.strip(" -–").lower() in NONE_VALUES else s.strip(" ;,")


def _facts(items: list[list[str]], references: bool = True) -> str | None:
    """Eintraege (je Eintrag die Zeilenstuecke) -> mit "; " verbunden, hoechstens MAX_FACT Zeichen; ohne `references`
    faellt ein reiner Verweis ("s. RStO ...") weg"""
    facts = [f for f in (_fact(x) for x in items) if f and (references or not REFERENCE_RE.match(f))]
    return _clip("; ".join(facts), MAX_FACT) if facts else None


def _season(text: str) -> str:
    t = text.lower()
    if EVERY_TERM_RE.search(t):
        return "WS+SS"
    winter, summer = bool(WINTER_RE.search(t)), bool(SUMMER_RE.search(t))
    if winter and summer:
        return "WS+SS"
    return "WS" if winter else ("SS" if summer else "unbekannt")


def _num(s: str):
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _catalog(meta: dict, areas: list[dict], modules: list[dict]) -> dict:
    src = meta.get("source") or {}
    return {
        "v": 1,
        "university": meta.get("university"),
        "program": meta.get("program"),
        "degree": meta.get("degree"),
        "po": meta.get("po"),
        "catalog_term": meta.get("catalog_term") or "",
        "code": meta.get("code"),
        "regular_semesters": meta.get("regular_semesters"),
        "total_lp": meta.get("total_lp"),
        "source": {"url": src.get("url"), "fetched_at": src.get("fetched_at"), "sha256": src.get("sha256")},
        "areas": areas,
        "modules": modules,
    }


def _module(mid: str, title: str, code: str, area, kind: str, lp, semester, turnus: str, exam, coursework, workload, page: int) -> dict:
    return {"id": mid, "title": title[:MAX_TEXT], "code": code, "area": area, "kind": kind, "lp": lp, "semester": semester,
            "turnus": turnus, "exam": exam, "coursework": coursework, "prerequisites": [], "language": None,
            "workload_h": workload, "source_page": page}


# --------------------------------------------------------------------------------------------------------------------
# hildesheim-kuerzel-modultabelle
# --------------------------------------------------------------------------------------------------------------------

def _kuerzel_read(pages: list[str]) -> tuple[list[dict], list[list[str]]]:
    """-> (Rohmodule, Pflichtmodule je Studienvariante). Rohmodul: {code, title, page, semester, freq, status, rows
    [[Kontaktzeit, Selbststudium, LP]], total, exams [[Teilmodul, [Stuecke der Pruefungsform]]], coursework [Eintraege, je
    Eintrag die Stuecke; ein neuer beginnt mit "TM1"], content [Zeilen]}"""
    mods: list[dict] = []
    variants: list[list[str]] = []
    collecting: list[str] | None = None
    cur: dict | None = None
    section = None
    value_col = K_VALUE_COL
    form_col = desc_col = None
    for p, lines in enumerate(layout_lines(pages)):
        for cells in lines:
            text = " ".join(c[1] for c in cells)
            indent = cells[0][0]
            if indent < value_col - K_LABEL_GAP and (ANNEX_RE.match(text) or K_END_RE.match(text)):
                cur, collecting, section = None, None, None
                continue
            t = K_TITLE_RE.match(text) if indent < value_col - K_LABEL_GAP else None
            if t:
                collecting = None
                if cur is not None and cur["code"] == t.group(1):      # Kolumnentitel der Folgeseite
                    if section not in K_KEEP:
                        section = None
                    continue
                cur = {"code": t.group(1), "title": t.group(2).strip(" "), "page": p + 1, "semester": None, "freq": None,
                       "status": None, "rows": [], "total": None, "exams": [], "coursework": [], "content": []}
                mods.append(cur)
                section, value_col = "head", K_VALUE_COL
                continue
            if cur is None:
                # Anlage "Beschreibung der Studienvarianten": Pflichtmodule je Variante
                m = K_REQUIRED_RE.match(text)
                if m:
                    collecting = K_CODE_RE.findall(m.group(1))
                    variants.append(collecting)
                elif collecting is not None:
                    if K_ELECTIVE_RE.match(text):
                        collecting = None
                    else:
                        collecting.extend(K_CODE_RE.findall(text))
                continue
            label = " ".join(c[1] for c in cells if c[0] < value_col - K_LABEL_GAP)
            vals = [c for c in cells if c[0] >= value_col - K_LABEL_GAP]
            if label:
                key = None
                if label.startswith("Für das Modul verantwortliche Person"):
                    key = "lead"
                elif label == "Studiensemester" and vals and vals[0][1].startswith("Dauer"):
                    key, value_col = "table", vals[0][0]
                elif label.startswith("Inhalte und"):
                    key = "content"
                elif label.startswith("Lehr-/"):
                    key = "forms"
                elif K_REQ_RE.match(label):
                    key = "exam" if any(v[1].startswith("Art der") for v in vals) else "req"
                elif K_COURSEWORK_RE.match(label):
                    key = "coursework"
                elif label.startswith("Verwendbarkeit des"):
                    key = "usage"
                elif label.startswith("Zuständige Ständige"):
                    key = "board"
                elif section == "req" and label.startswith("Vergabe von"):
                    key = "exam"
                elif section == "req" and (label.startswith("Teilnahme") or label.startswith("Zulassung zur")):
                    section = "other"
                if key == "exam":
                    form_col = next((v[0] for v in vals if v[1].startswith("Prüfungsfor")), None)
                    desc_col = next((v[0] for v in vals if v[1].startswith("Prüfungsleistung")), None)
                    section = key
                    continue
                if key is not None:
                    section = key
                    if key == "table":
                        continue
            if section == "table":
                if cur["semester"] is None and FIRST_INT_RE.match(label):
                    cur["semester"] = int(FIRST_INT_RE.match(label).group(0))
                    cur["freq"] = vals[1][1] if len(vals) >= 2 else None
                    cur["status"] = " ".join(v[1] for v in vals[2:]) or None
            elif section == "content":
                if vals:
                    cur["content"].append(" ".join(v[1] for v in vals))
            elif section == "forms":
                if len(vals) >= 4 and NUMBER_RE.match(vals[-1][1]) and HOURS_RE.match(vals[-3][1]) and HOURS_RE.match(vals[-4][1]):
                    cur["rows"].append([vals[-4][1], vals[-3][1], vals[-1][1]])
                elif len(vals) >= 2 and NUMBER_RE.match(vals[-1][1]) and not FIRST_INT_RE.match(vals[0][1]):
                    cur["total"] = _num(vals[-1][1])          # "s. RStO ...   13": LP des ganzen Moduls
            elif section == "coursework":
                if vals:
                    line = " ".join(v[1] for v in vals)
                    if cur["coursework"] and not K_PART_RE.match(line):
                        cur["coursework"][-1].append(line)
                    else:
                        cur["coursework"].append([line])
            elif section == "exam" and form_col is not None:
                lo = form_col - K_COL_TOLERANCE
                hi = desc_col - K_COL_TOLERANCE if desc_col is not None and desc_col > form_col else None
                form = " ".join(v[1] for v in vals if v[0] >= lo and (hi is None or v[0] < hi))
                mark = next((k for k, v in enumerate(vals) if v[0] < lo and K_EXAM_MARK_RE.match(v[1])), None)
                if mark is not None:
                    cur["exams"].append([" ".join(v[1] for v in vals[:mark]), [form] if form else []])
                elif form and cur["exams"]:
                    cur["exams"][-1][1].append(form)
    return mods, variants


def is_kuerzel_modultabelle(pages: list[str]) -> bool:
    """Hat das Dokument Module mit Titelzeile "INF-B1: „Titel“" und dem Tabellenkopf "Studiensemester | Dauer ..."?"""
    return any(m["semester"] is not None for m in _kuerzel_read(pages)[0])


def _kuerzel_kind(r: dict, variants: list[list[str]]) -> tuple[str, str | None]:
    """-> (Art, Bereich): "Status Modul", sonst die Pflichtmodule der Studienvarianten (Pflicht nur, wenn in jeder)"""
    if FINAL_RE.search(r["title"].lower()):
        return "abschluss", None
    status = (r["status"] or "").lower()
    if status.startswith("pflicht"):
        return "pflicht", None
    if status.startswith("wahlpflicht"):
        return "wahlpflicht", None
    if status.startswith("wahl"):
        return "wahl", None
    if variants:
        if all(r["code"] in v for v in variants):
            return "pflicht", "pflichtmodule"
        return "wahlpflicht", "wahlpflichtmodule"
    return "pflicht", None


def parse_kuerzel_modultabelle(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Layout-Seitentexte -> (Katalog im geteilten Format, {modul_id: {content, goals, literature}}); meta wie
    `parse_luh_modkat` (university, program, degree, po, code, catalog_term, regular_semesters, total_lp, source)"""
    raw, variants = _kuerzel_read(pages)
    raw = [r for r in raw if r["semester"] is not None or r["rows"] or r["total"] is not None]
    ids: set = set()
    modules: list[dict] = []
    texts: dict = {}
    used: list[str] = []
    for r in raw:
        mid = _unique(slug(r["title"]), ids)
        kind, area = _kuerzel_kind(r, variants)
        if area and area not in used:
            used.append(area)
        lp = r["total"]
        if lp is None and r["rows"]:
            total = sum(float(x[2].replace(",", ".")) for x in r["rows"])
            lp = int(total) if total == int(total) else total
        hours = sum(int(x) for row in r["rows"] for x in row[:2] if x != "-")
        exams = []
        for part, pieces in r["exams"]:
            m = K_PART_RE.match(part)
            exams.append(([m.group(1) + ":"] if m and pieces else []) + pieces)
        modules.append(_module(mid, r["title"], r["code"], area, kind, lp, r["semester"], _season(r["freq"] or ""),
                               _facts(exams), _facts(r["coursework"], references=False), hours or None, r["page"]))
        texts[mid] = {"content": "\n".join(r["content"]) or None, "goals": None, "literature": None}
    names = {"pflichtmodule": ("Pflichtmodule", "pflicht"), "wahlpflichtmodule": ("Wahlpflichtmodule", "wahlpflicht")}
    areas = [{"id": a, "name": names[a][0], "lp_required": None, "lp_max": None, "kind": names[a][1]}
             for a in ("pflichtmodule", "wahlpflichtmodule") if a in used]
    return _catalog(meta, areas, modules), texts


# --------------------------------------------------------------------------------------------------------------------
# hildesheim-kennnummer-tabelle
# --------------------------------------------------------------------------------------------------------------------

def _kennnummer_read(pages: list[str]) -> list[dict]:
    """Rohmodule: {code, title, page, workload, lp, semester, freq [Stuecke], sections {Schluessel: [Zeilen]}}"""
    flat = [(p + 1, cells) for p, lines in enumerate(layout_lines(pages)) for cells in lines]
    texts = [" ".join(c[1] for c in cells) for _, cells in flat]
    starts: list[tuple[int, int, re.Match]] = []          # (Titelzeile, Kopfzeile, Titel)
    for h, text in enumerate(texts):
        if N_HEAD_KEY not in text.replace(" ", ""):
            continue
        for back in range(1, N_TITLE_BACK + 1):
            k = h - back
            m = N_TITLE_RE.match(texts[k]) if k >= 0 and flat[k][1][0][0] <= N_LABEL_INDENT else None
            if m:
                starts.append((k, h, m))
                break
    mods = []
    for n, (k, h, m) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(flat)
        r = {"code": m.group(1) + " " + m.group(2), "title": m.group(3).strip(" "), "page": flat[k][0], "workload": None,
             "lp": None, "semester": None, "freq": [], "sections": {}}
        running = [texts[k]]                               # Kolumnentitel der Folgeseiten
        if h - k == 2 and flat[k + 1][1][0][0] <= N_LABEL_INDENT:      # Titel ueber zwei Zeilen
            r["title"] = _join([r["title"], texts[k + 1]])
            running.append(texts[k + 1])
        sem_end = dur_col = None
        key = None
        for i in range(h + 1, end):
            cells = flat[i][1]
            text = texts[i]
            if ANNEX_RE.match(text) and cells[0][0] <= N_LABEL_INDENT:
                break
            if text == running[0] or (len(running) == 2 and text == running[1] and texts[i - 1] == running[0]):
                continue
            if r["workload"] is None and key is None:
                w = next((j for j, c in enumerate(cells) if N_WORKLOAD_RE.match(c[1])), None)
                if w is None:
                    continue
                r["workload"] = int(N_WORKLOAD_RE.match(cells[w][1]).group(1))
                if w + 1 < len(cells) and NUMBER_RE.match(cells[w + 1][1]):
                    r["lp"] = _num(cells[w + 1][1])
                sm = N_SEMESTER_RE.match(cells[w + 2][1]) if w + 2 < len(cells) else None
                r["semester"] = int(sm.group(1)) if sm else None
                if w + 3 < len(cells):
                    sem_end = cells[w + 2][0] + len(cells[w + 2][1])
                    r["freq"].append(cells[w + 3][1])
                dur_col = cells[w + 4][0] if w + 4 < len(cells) else None
                continue
            name = None
            if cells[0][0] <= N_LABEL_INDENT and len(cells) >= 2 and N_ROW_RE.match(cells[0][1]):
                name = next((s for prefix, s in N_ROWS if cells[1][1].startswith(prefix)), None)
            if name is not None:
                key = name
                r["sections"].setdefault(key, [])
                continue
            if key is None:
                if sem_end is not None:                    # umbrochene Werte der Kopfzeile: nur die Spalte Haeufigkeit
                    # (zentriert gesetzt: rechts vom Ende der Semester-Zelle, links von der Spalte Dauer)
                    r["freq"].extend(c[1] for c in cells if c[0] > sem_end
                                     and (dur_col is None or c[0] < dur_col - K_COL_TOLERANCE))
                continue
            r["sections"][key].append(text)
        mods.append(r)
    return mods


def is_kennnummer_tabelle(pages: list[str]) -> bool:
    """Hat das Dokument Module mit dem Tabellenkopf "Kennnummer | Workload | Credits"?"""
    return any(r["workload"] is not None for r in _kennnummer_read(pages))


def _kennnummer_split(lines: list[str]) -> dict:
    """Zeilen eines Abschnitts -> {plain, coursework, exam}: Teile unter "Studienleistung(en):" / "Prüfungsleistung:",
    davor `plain`; je Teil die Eintraege (ein neuer beginnt mit einer Teilmodulnummer "2.1"), mit "; " verbunden"""
    parts: dict = {"plain": [], "coursework": [], "exam": []}
    sub = "plain"
    for line in lines:
        if N_COURSEWORK_RE.match(line):
            sub = "coursework"
        elif N_EXAM_RE.match(line):
            sub = "exam"
        elif parts[sub] and not N_ITEM_RE.match(line):
            parts[sub][-1].append(line)
        else:
            parts[sub].append([line])
    return {k: _facts(items) for k, items in parts.items()}


def parse_kennnummer_tabelle(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Layout-Seitentexte -> (Katalog im geteilten Format, {modul_id: {content, goals, literature}}); meta wie
    `parse_luh_modkat`"""
    ids: set = set()
    modules: list[dict] = []
    texts: dict = {}
    for r in _kennnummer_read(pages):
        if r["workload"] is None and r["lp"] is None:
            continue
        mid = _unique(slug(r["title"]), ids)
        s = r["sections"]
        exam, credit = _kennnummer_split(s.get("exam") or []), _kennnummer_split(s.get("credit") or [])
        kind = "abschluss" if FINAL_RE.search(r["title"].lower()) else ("wahlpflicht" if N_ELECTIVE_RE.search(r["title"]) else "pflicht")
        modules.append(_module(mid, r["title"], r["code"], None, kind, r["lp"], r["semester"], _season(_join(r["freq"])),
                               exam["plain"] or exam["exam"] or credit["exam"], exam["coursework"] or credit["coursework"],
                               r["workload"], r["page"]))
        texts[mid] = {"content": "\n".join(s.get("content") or []) or None, "goals": "\n".join(s.get("goals") or []) or None,
                      "literature": None}
    return _catalog(meta, [], modules), texts
