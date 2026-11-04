"""Gemeinsame Bausteine der Leseprogramme "Formate A" (luh-modulbeschreibung, mb-modulkatalog, wiwi-modulhandbuch,
fbg-modulhandbuch; Auftrag 04.11.2026, docs/STUDIENGAENGE-LUH-2026-11-04.md "Leseprogramme Formate A").

Die Kataloge werden einmal auf dem Mac gelesen (Grundstock), nie auf dem Geraet. Textgewinnung und Normalisierung
wie app/study_catalog.py (pypdf je Seite, normalize_lines), Ausgabe im geteilten Format
(packages/shared-contracts/study-catalog.schema.json) plus lokale Texte {modul_id: {content, goals, literature}},
die NIE in die geteilten Fakten gehen.

Ein Leseprogramm liefert je Modul ein "Rohmodul" (dict) mit den Schluesseln
  title, code, area (Name), kind, lp, semester, turnus, exam, coursework, prereq (Text), language, workload_h, page,
  content, goals, literature
und baut daraus mit build_catalog() den Katalog (ids, Bereiche, Art, Voraussetzungen als Modul-ids).
"""
from __future__ import annotations

import re

from app.study_catalog import (  # noqa: F401  (Wiederverwendung der Regeln des modkat-Lesers)
    FINAL_RE,
    MAX_TEXT,
    TERM_RE,
    _mentions,
    _number,
    _unique,
    current_term,
    normalize_lines,
    pdf_pages,
    slug,
    term_from_title,
    validate,
)

NUM = r"[0-9]+(?:[.,][0-9]+)?"
PAGE_NO_RE = re.compile(r"^(?:Seite )?[0-9]{1,3}(?: (?:von|/) [0-9]{1,3})?$")
WORKLOAD_H_RE = re.compile(r"(" + NUM + r") ?(?:h\b|Std\b|Std\.|Stunden|hours)", re.I)
STAND_DATE_RE = re.compile(r"Stand:? ?([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})")
SEMESTER_WORD_RE = re.compile(r"(Wintersemester|Sommersemester|WiSe|SoSe|WS|SS) ?([0-9]{4})(?: ?/ ?([0-9]{2,4}))?")


def page_lines(pages: list[str]) -> list[list[str]]:
    """Seitentexte -> normalisierte Zeilen je Seite (gleiche Regeln wie der modkat-Leser)"""
    return [normalize_lines(t) for t in pages]


def clip(s, limit: int = MAX_TEXT):
    """Leerraum zusammenfassen, leer -> None, hoechstens 500 Zeichen (geteilte Fakten)"""
    if s is None:
        return None
    s = re.sub(r"\s+", " ", str(s)).strip(" ;,")
    if not s:
        return None
    if len(s) > limit:
        cut = s[: limit - 1].rsplit(" ", 1)[0]
        s = cut + "…"
    return s


def number(s: str):
    return _number(s)


def join(lines, sep: str = " ") -> str:
    return sep.join(l for l in (lines or []) if l).strip(" ")


def text_join(lines) -> str | None:
    """Lokaler Text: Zeilen mit Zeilenumbruch, Silbentrennung am Zeilenende bleibt (wie modkat)"""
    t = "\n".join(l for l in (lines or []) if l).strip()
    return t or None


# ----------------------------------------------------------------------------
# Werte
# ----------------------------------------------------------------------------

def turnus_of(text: str | None) -> str:
    """Turnus aus Angaben wie 'WiSe', 'SoSe', 'WiSe/SoSe', 'jedes Wintersemester', 'jährlich (SoSe)', 'jedes Semester',
    'every winter term'. Unklar ('unregelmäßig', 'nach Bedarf', nur 'jährlich') -> unbekannt."""
    t = (text or "").lower()
    if not t.strip():
        return "unbekannt"
    if re.search(r"jedes semester|jedem semester|semesterweise|halbjährlich|every (?:term|semester)|each (?:term|semester)"
                 r"|winter- und sommersemester|sommer- und wintersemester|ws und ss|ss und ws|ws/ss|ss/ws|ws ?\+ ?ss"
                 r"|wise ?/ ?sose|sose ?/ ?wise|wise und sose|sose und wise|winter and summer|summer and winter", t):
        return "WS+SS"
    winter = bool(re.search(r"winter|wise\b|\bws\b|\bwi\.?se", t))
    summer = bool(re.search(r"sommer|summer|sose\b|\bss\b|\bso\.?se", t))
    if winter and summer:
        return "WS+SS"
    if winter:
        return "WS"
    if summer:
        return "SS"
    return "unbekannt"


LANG_WORDS = (("deutsch", "deutsch"), ("german", "deutsch"), ("englisch", "englisch"), ("english", "englisch"),
              ("französisch", "französisch"), ("french", "französisch"), ("spanisch", "spanisch"))


def language_of(text: str | None) -> str | None:
    """'Deutsch/Englisch' -> 'deutsch/englisch', 'English' -> 'englisch', 'D' -> 'deutsch', 'E' -> 'englisch'"""
    t = (text or "").strip(" .:;").lower()
    if not t:
        return None
    if t in ("d", "de", "dt.", "dt"):
        return "deutsch"
    if t in ("e", "en", "engl.", "engl"):
        return "englisch"
    if t in ("d/e", "d / e", "de/en", "d, e", "d+e", "d und e", "e/d", "e / d", "en/de"):
        return "deutsch/englisch" if t.startswith("d") else "englisch/deutsch"
    found = []
    for word, name in LANG_WORDS:
        i = t.find(word)
        if i >= 0 and name not in [n for _, n in found]:
            found.append((i, name))
    if found:
        return "/".join(n for _, n in sorted(found))
    return clip(t, 60)


def kind_of(text: str | None) -> str | None:
    """Modulart: Pflicht / Wahlpflicht / Wahl / Abschluss (deutsch und englisch, auch 'Pflichtmodul', 'P', 'WP')"""
    t = (text or "").strip(" .:;").lower()
    if not t:
        return None
    t = t.replace("-", "").replace(" ", "")
    if t in ("p", "pf", "pm"):
        return "pflicht"
    if t in ("wp", "wpf", "wpm"):
        return "wahlpflicht"
    if t in ("w", "wm"):
        return "wahl"
    if t.startswith("wahlpflicht") or ("elective" in t or "optional" in t) and \
            any(w in t for w in ("compulsory", "required", "mandatory", "obligatory")):
        return "wahlpflicht"
    if t.startswith("pflicht") or t.startswith("compulsory") or t.startswith("mandatory") or t.startswith("obligatory") \
            or t.startswith("required"):
        return "pflicht"
    if t.startswith("wahl") or t.startswith("elective") or t.startswith("optional"):
        return "wahl"
    if t.startswith("abschluss") or "arbeit" in t and ("bachelor" in t or "master" in t):
        return "abschluss"
    return None


def workload_of(text: str | None):
    m = WORKLOAD_H_RE.search(text or "")
    if not m:
        return None
    v = number(m.group(1))
    return v if v > 0 else None


def term_of_catalog(meta_term: str | None, first_text: str, stand_text: str = "") -> str | None:
    """Katalogsemester: Registerangabe im Format 'WS 2026/27' / 'SS 2026', sonst Semester im Titel der PDF
    ('Wintersemester 2026/2027', 'WiSe 26/27'), sonst aus 'Stand: TT.MM.JJJJ', sonst None"""
    if meta_term and TERM_RE.match(meta_term):
        return meta_term
    t = term_from_title(first_text)
    if t:
        return t
    m = re.search(r"\b(WiSe|SoSe|WS|SS) ?(20[0-9]{2}|[0-9]{2})(?: ?/ ?(?:20)?([0-9]{2}))?\b", first_text)
    if m:
        y = int(m.group(2))
        y = y + 2000 if y < 100 else y
        return f"WS {y}/{(y + 1) % 100:02d}" if m.group(1) in ("WiSe", "WS") else f"SS {y}"
    m = STAND_DATE_RE.search(stand_text or first_text)
    if m:
        return current_term(f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}")
    return None


# ----------------------------------------------------------------------------
# Katalog
# ----------------------------------------------------------------------------

def _norm_title(t: str) -> str:
    return re.sub(r"\s+", " ", t).strip(" .:;-–")


def _prereq_ids(text: str, me: dict, modules: list[dict]) -> list[str]:
    if not text:
        return []
    out = []
    for o in modules:
        if o["id"] == me["id"] or o["id"] in out:
            continue
        title = o["title"]
        # sehr kurze Titel ("Physik") nur, wenn sie allein stehen; sonst falsche Treffer in Saetzen
        if len(title) < 6:
            continue
        if _mentions(text, title):
            out.append(o["id"])
    return out


def build_catalog(meta: dict, raw: list[dict], area_specs: dict | None = None,
                  term: str | None = None) -> tuple[dict, dict]:
    """Rohmodule -> (Katalog im geteilten Format, lokale Texte). area_specs: Bereichsname -> {lp_required, lp_max,
    kind} (falls das Handbuch sie nennt). Doppelte Module (gleicher Titel und gleiche LP) werden einmal gefuehrt."""
    area_specs = area_specs or {}
    seen_titles: dict = {}
    mods: list[dict] = []
    for r in raw:
        title = _norm_title(r.get("title") or "")
        if not title:
            continue
        key = (title.lower(), r.get("lp"))
        if key in seen_titles:
            prev = seen_titles[key]
            # fehlende Fakten aus der zweiten Beschreibung ergaenzen
            for k in ("exam", "coursework", "language", "workload_h", "semester", "code"):
                if prev.get(k) is None and r.get(k) is not None:
                    prev[k] = r[k]
            if prev.get("turnus") in (None, "unbekannt") and r.get("turnus") not in (None, "unbekannt"):
                prev["turnus"] = r["turnus"]
            continue
        r = dict(r)
        r["title"] = title
        seen_titles[key] = r
        mods.append(r)

    # Bereiche in Reihenfolge des ersten Auftretens
    areas: list[dict] = []
    area_by_name: dict = {}
    area_ids: set = set()
    for name in list(area_specs.keys()) + [m.get("area") for m in mods]:
        name = _norm_title(name or "")
        if not name or name.lower() in area_by_name:
            continue
        spec = area_specs.get(name) or {}
        a = {"id": _unique(slug(name)[:80].strip("-") or "bereich", area_ids), "name": clip(name), "lp_required": None,
             "lp_max": None, "kind": spec.get("kind")}
        lp_req, lp_max = spec.get("lp_required"), spec.get("lp_max")
        if lp_req is not None:
            a["lp_required"] = lp_req
            a["lp_max"] = lp_max if lp_max is not None and lp_max >= lp_req else None
        area_by_name[name.lower()] = a
        areas.append(a)

    module_ids: set = set()
    modules: list[dict] = []
    texts: dict = {}
    for r in mods:
        mid = _unique(slug(r["title"])[:80].strip("-") or "modul", module_ids)
        area = area_by_name.get(_norm_title(r.get("area") or "").lower())
        kind = r.get("kind")
        if FINAL_RE.search(r["title"]) and len(r["title"]) <= 40 and kind != "wahl":
            kind = "abschluss"
        sem = r.get("semester")
        if not isinstance(sem, int) or not 1 <= sem <= 20:
            sem = None
        lp = r.get("lp")
        if lp is not None and (lp < 0 or lp > 120):
            lp = None
        wl = r.get("workload_h")
        if wl is not None and (wl <= 0 or wl > 5000):
            wl = None
        page = r.get("page")
        modules.append({
            "id": mid,
            "title": clip(r["title"]),
            "code": clip(r.get("code")),
            "area": area["id"] if area else None,
            "kind": kind,
            "lp": lp,
            "semester": sem,
            "turnus": r.get("turnus") if r.get("turnus") in ("WS", "SS", "WS+SS", "unbekannt") else "unbekannt",
            "exam": clip(r.get("exam")),
            "coursework": clip(r.get("coursework")),
            "prerequisites": [],
            "language": clip(r.get("language")),
            "workload_h": wl,
            "source_page": page if isinstance(page, int) and page >= 1 else None,
            "_prereq": r.get("prereq") or "",
        })
        t = {k: (r.get(k) or None) for k in ("content", "goals", "literature")}
        if any(t.values()):
            texts[mid] = t

    # Art je Bereich: Bereichsangabe, sonst aus den Modulen
    for a in areas:
        mine = [m for m in modules if m["area"] == a["id"]]
        for m in mine:
            if m["kind"] is None and a["kind"]:
                m["kind"] = a["kind"]
        if a["kind"] is None:
            kinds = {m["kind"] for m in mine if m["kind"]}
            if FINAL_RE.search(a["name"]) or kinds == {"abschluss"}:
                a["kind"] = "abschluss"
            elif kinds == {"wahl"}:
                a["kind"] = "wahl"
            elif "wahlpflicht" in kinds or "wahl" in kinds:
                a["kind"] = "wahlpflicht"
            else:
                a["kind"] = "pflicht"
    for m in modules:
        if m["kind"] is None:
            m["kind"] = "pflicht"
    for m in modules:
        text = m.pop("_prereq")
        m["prerequisites"] = _prereq_ids(text, m, modules)

    src = meta.get("source") or {}
    catalog = {
        "v": 1,
        "university": meta.get("university") or "luh",
        "program": meta.get("program"),
        "degree": meta.get("degree"),
        "po": meta.get("po"),
        "catalog_term": term or meta.get("catalog_term"),
        "code": meta.get("code"),
        "regular_semesters": meta.get("regular_semesters"),
        "total_lp": meta.get("total_lp"),
        "source": {"url": src.get("url"), "fetched_at": src.get("fetched_at"), "sha256": src.get("sha256")},
        "areas": areas,
        "modules": modules,
    }
    return catalog, texts


FACT_KEYS = ("lp", "exam", "coursework", "turnus", "semester", "language", "workload_h", "area", "code")


def fill_rates(catalog: dict) -> dict:
    """Anteil der Module mit Wert je Feld (turnus zaehlt nur, wenn nicht 'unbekannt')"""
    mods = catalog.get("modules") or []
    n = len(mods) or 1
    out = {"modules": len(mods)}
    for k in FACT_KEYS:
        if k == "turnus":
            out[k] = sum(1 for m in mods if m.get(k) not in (None, "unbekannt")) / n
        else:
            out[k] = sum(1 for m in mods if m.get(k) is not None) / n
    out["title"] = sum(1 for m in mods if m.get("title")) / n
    out["prerequisites"] = sum(1 for m in mods if m.get("prerequisites")) / n
    return out


def merge_catalogs(base: dict, base_texts: dict, extra: dict, extra_texts: dict) -> tuple[dict, dict]:
    """Zweiten Katalog desselben Studiengangs anhaengen (z. B. getrenntes Wahlpflicht-Handbuch): Bereiche nach Namen
    zusammen, Module mit gleichem Titel einmal, ids eindeutig, Voraussetzungen umbenannt"""
    out = {**base, "areas": [dict(a) for a in base["areas"]], "modules": [dict(m) for m in base["modules"]]}
    texts = dict(base_texts)
    area_ids = {a["id"] for a in out["areas"]}
    by_name = {a["name"].lower(): a["id"] for a in out["areas"]}
    area_map = {}
    for a in extra.get("areas") or []:
        if a["name"].lower() in by_name:
            area_map[a["id"]] = by_name[a["name"].lower()]
            continue
        nid = _unique(a["id"], area_ids)
        area_map[a["id"]] = nid
        by_name[a["name"].lower()] = nid
        out["areas"].append({**a, "id": nid})
    titles = {m["title"].lower() for m in out["modules"]}
    mod_ids = {m["id"] for m in out["modules"]}
    id_map = {}
    added = []
    for m in extra.get("modules") or []:
        if m["title"].lower() in titles:
            id_map[m["id"]] = next(x["id"] for x in out["modules"] if x["title"].lower() == m["title"].lower())
            continue
        nid = _unique(m["id"], mod_ids)
        id_map[m["id"]] = nid
        nm = {**m, "id": nid, "area": area_map.get(m["area"]) if m.get("area") else None}
        added.append(nm)
        if m["id"] in extra_texts:
            texts[nid] = extra_texts[m["id"]]
    for m in added:
        m["prerequisites"] = [id_map[p] for p in m["prerequisites"] if p in id_map and id_map[p] != m["id"]]
    out["modules"].extend(added)
    return out, texts
