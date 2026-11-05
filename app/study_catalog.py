"""Modulkatalog eines Studiengangs (Auftrag des Inhabers 04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md).

Bausteine (gleiche Regeln im Swift-Kern, UniFlowCore/StudyCatalog/*; Fixture tools/gen-study-catalog-fixture.py):
- Register der Quellen (packages/shared-contracts/study-sources.json) und Zuordnung QIS `abschluss` -> Eintrag
  ("Technische Informatik (PO-Version 2017)" -> Technische Informatik B.Sc., neueste PO als Vorschlag).
- Zeilen-Normalisierung des PDF-Texts (NFKC, Zeilenumbrueche, Leerraum), damit pypdf (hier) und PDFKit (Geraet)
  dieselben Zeilen liefern.
- Parser fuer das Format der LUH-Modulkataloge (modkat, Fakultaet fuer Elektrotechnik und Informatik): Inhaltsverzeichnis
  -> Bereiche und Module mit Seite, je Modul die Felder unter ihren Ueberschriften.
- Validator des geteilten Formats (study-catalog.schema.json) mit Fehlerliste "pfad: code".
- Bibliotheksschluessel sha256("luh|TIBSc22|WS 2025/26").
- Lokale Tabellen `study_catalogs` (geteilte Fakten, payload JSON) und `study_module_texts` (nur lokal: Inhalt,
  Lernziele, Literatur), Stand der Suche in `study_catalog_state`; erst bei Bedarf angelegt (wie due_hits am Geraet),
  das Schema von app/db.py bleibt unveraendert.
- Abgleich: lokal -> herunterladen (oeffentliche PDF, einmal je Katalogsemester, ETag/304) -> lesen -> speichern.
  Die Bibliothek (CloudKit) gibt es nur auf dem Geraet; der Dienst laedt selbst.
- Studienverlaufsplan der Fakultaet (eigene PDF, study_plan im Register): lesen (`parse_study_plan`), in den Katalog
  mischen (`merge_study_plan`: `semester` laut Plan, `plan_slots` fuer Wahlmodule), einmal laden wie den Katalog.
- GET /api/study-catalog/status.
"""
from __future__ import annotations

import contextvars
import copy
import hashlib
import io
import json
import math
import os
import re
import threading
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import APIRouter

from . import db

ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "packages" / "shared-contracts" / "study-sources.json"
# Breite Erhebung aller LUH-Studiengaenge (tools/luh-programs.py) und das daraus gemischte Register, das Python und der
# Swift-Kern (StudySourcesData.swift) fuer die QIS-Zuordnung nutzen (tools/gen-study-catalog-fixture.py schreibt beide)
LUH_REGISTRY_PATH = ROOT / "packages" / "shared-contracts" / "study-sources-luh.json"
# dasselbe fuer die Universitaet Hildesheim (tools/hildesheim-programs.py, docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md)
HILDESHEIM_REGISTRY_PATH = ROOT / "packages" / "shared-contracts" / "study-sources-hildesheim.json"
# dasselbe fuer die Hochschule Hannover (tools/hsh-programs.py, docs/STUDIENGAENGE-HSH-2026-11-05.md)
HSH_REGISTRY_PATH = ROOT / "packages" / "shared-contracts" / "study-sources-hsh.json"
# breite Erhebungen je Hochschule, in dieser Reihenfolge ins gemischte Register (LUH zuerst)
WIDE_REGISTRY_PATHS = (LUH_REGISTRY_PATH, HILDESHEIM_REGISTRY_PATH, HSH_REGISTRY_PATH)
UNIVERSITY_NAMES = {"luh": "Leibniz Universität Hannover", "hildesheim": "Universität Hildesheim",
                    "hsh": "Hochschule Hannover"}
FULL_REGISTRY_PATH = ROOT / "packages" / "shared-contracts" / "study-sources-all.json"

KINDS = ("pflicht", "wahlpflicht", "wahl", "abschluss")
TURNUS = ("WS", "SS", "WS+SS", "unbekannt")
MAX_TEXT = 500
RETRY_HOURS = 24
MISSING_DAYS = 30
USER_AGENT = "StudiNow-Modulkatalog/1.0 (support@studinow.app)"

# ----------------------------------------------------------------------------
# Zeilen
# ----------------------------------------------------------------------------

BREAKS = "\r  \x0b\x0c\x1c\x1d\x1e\x85"
DROP = "­​‌‍﻿"
_BREAK_TABLE = {ord(c): "\n" for c in BREAKS} | {ord(c): None for c in DROP} | {ord("\t"): " "}
SPACES_RE = re.compile(r" {2,}")


def normalize_lines(text: str) -> list[str]:
    """Text einer Seite -> nichtleere Zeilen: NFKC (Ligaturen wie 'fl' zerlegt, geschuetzte Leerzeichen zu
    Leerzeichen), jeder Zeilenumbruch gleich, Tabulator zu Leerzeichen, Leerzeichenfolgen zu einem, Raender weg."""
    t = unicodedata.normalize("NFKC", text or "").translate(_BREAK_TABLE)
    out = []
    for line in t.split("\n"):
        line = SPACES_RE.sub(" ", line).strip(" ")
        if line:
            out.append(line)
    return out


def pdf_pages(data: bytes) -> list[str]:
    """Seitentexte einer PDF wie app/extract.py und app/scriptsearch.py (pypdf, je Seite extract_text)"""
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    pages = []
    for p in reader.pages:
        try:
            pages.append(p.extract_text() or "")
        except Exception:  # noqa: BLE001
            pages.append("")
    return pages


# ----------------------------------------------------------------------------
# Semester und Schluessel
# ----------------------------------------------------------------------------

TERM_RE = re.compile(r"^(WS) ([0-9]{4})/([0-9]{2})$|^(SS) ([0-9]{4})$")
TITLE_TERM_RE = re.compile(r"(Wintersemester|Sommersemester) ([0-9]{4})(?:/([0-9]{4}))?")


def term_number(term: str | None) -> int | None:
    """'WS 2025/26' -> 2025*2+1, 'SS 2026' -> 2026*2 (wie study_plan.parse_term)"""
    m = TERM_RE.match(term or "")
    if not m:
        return None
    if m.group(1):
        return int(m.group(2)) * 2 + 1
    return int(m.group(5)) * 2


def term_name(n: int) -> str:
    y = n // 2
    return f"WS {y}/{(y + 1) % 100:02d}" if n % 2 else f"SS {y}"


def term_slug(term: str) -> str:
    """'WS 2025/26' -> 'WS_2025_26', 'SS 2026' -> 'SS_2026' (Dateiname der modkat-PDF)"""
    return term.replace(" ", "_").replace("/", "_")


def term_from_title(text: str) -> str | None:
    """'im Wintersemester 2025/2026' -> 'WS 2025/26'"""
    m = TITLE_TERM_RE.search(text or "")
    if not m:
        return None
    y = int(m.group(2))
    return f"WS {y}/{(y + 1) % 100:02d}" if m.group(1) == "Wintersemester" else f"SS {y}"


def current_term(today: str) -> str:
    """Laufendes Semester: Oktober bis Maerz WS, April bis September SS"""
    y, mo = int(today[:4]), int(today[5:7])
    if mo >= 10:
        return f"WS {y}/{(y + 1) % 100:02d}"
    if mo <= 3:
        return f"WS {y - 1}/{y % 100:02d}"
    return f"SS {y}"


def library_key(university: str, code: str, term: str) -> str:
    """Bibliotheksschluessel sha256("luh|TIBSc22|WS 2025/26") (gleich study_plan.catalog_key)"""
    return hashlib.sha256(f"{university}|{code}|{term}".encode()).hexdigest()


def catalog_key(c: dict) -> str:
    return library_key(str(c.get("university") or ""), str(c.get("code") or ""), str(c.get("catalog_term") or ""))


# ----------------------------------------------------------------------------
# Namen
# ----------------------------------------------------------------------------

ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"}
UMLAUTS = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"}
TOKEN_RE = re.compile(r"[a-z0-9]+")


def _fold(text: str) -> str:
    s = (text or "").lower()
    for k, v in UMLAUTS.items():
        s = s.replace(k, v)
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if unicodedata.category(c) != "Mn")


def slug(text: str) -> str:
    """'Programmieren I' -> 'programmieren-1', 'Grundlagen der Informatik' -> 'grundlagen-der-informatik'"""
    tokens = [ROMAN.get(t, t) for t in TOKEN_RE.findall(_fold(text))]
    return "-".join(tokens) or "modul"


def name_key(text: str) -> str:
    """Vergleichsform eines Studiengangsnamens: klein, Umlaute ausgeschrieben, nur Buchstaben und Ziffern"""
    return "".join(TOKEN_RE.findall(_fold(text)))


# ----------------------------------------------------------------------------
# Register und Zuordnung
# ----------------------------------------------------------------------------

_registry_cache: dict | None = None


def load_registry(path: Path | None = None) -> dict:
    """Register; ohne Pfad das gemischte (study-sources-all.json: study-sources.json plus alle LUH-Studiengaenge),
    fehlt es, das gepflegte study-sources.json"""
    global _registry_cache
    if path is None and _registry_cache is not None:
        return _registry_cache
    try:
        data = json.loads((path or (FULL_REGISTRY_PATH if FULL_REGISTRY_PATH.exists() else REGISTRY_PATH)).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {"v": 1, "universities": []}
    if path is None:
        _registry_cache = data
    return data


GRUNDSTOCK_SOURCE = "luh-grundstock"
FEI_SOURCE = "luh-fei-modkat"
NO_CATALOG_FORMATS = (None, "none", "overview-only")


def seed_code(entry_key: str, url: str | None = None) -> str:
    """Kuerzel eines Katalogs im Register und im Grundstock: modkat-Kuerzel ('TIBSc25'), sonst der Registerschluessel
    ohne 'luh|' ('maschinenbau|b.sc.|2017'; die Formate ausserhalb von modkat haben kein Kuerzel, ihre Leser in
    app/catalog_formats/ setzen `code` ebenso)"""
    parts = modkat_parts(url or "")
    if parts:
        return parts[0]
    return entry_key.split("|", 1)[1] if "|" in (entry_key or "") else (entry_key or "")


def luh_catalogs(entry: dict) -> list[dict]:
    """Kataloge eines Eintrags aus study-sources-luh.json (Haupt-Katalog zuerst, dann more_catalogs), nur mit URL und
    Modulbeschreibungen"""
    out = []
    for c in [entry.get("catalog") or {}] + list(entry.get("more_catalogs") or []):
        if isinstance(c, dict) and isinstance(c.get("url"), str) and c["url"].startswith("https://") \
                and c.get("format") not in NO_CATALOG_FORMATS:
            out.append(c)
    return out


def grundstock_source(university: str) -> str:
    """Quelle "nur aus dem Grundstock" einer Hochschule im gemischten Register ('luh-grundstock', 'hildesheim-grundstock')"""
    return GRUNDSTOCK_SOURCE if university == "luh" else f"{university}-grundstock"


def merge_wide_registries(curated: dict, wides: list[dict]) -> dict:
    """Gepflegtes Register + breite Erhebungen mehrerer Hochschulen (je wie `merge_luh_registry`), in dieser
    Reihenfolge"""
    out = curated
    for w in wides:
        out = merge_luh_registry(out, w)
    return out


def load_wide_registries() -> list[dict]:
    """Breite Erhebungen, die es gibt (study-sources-luh.json, study-sources-hildesheim.json)"""
    out = []
    for p in WIDE_REGISTRY_PATHS:
        try:
            out.append(json.loads(p.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            continue
    return out


def merge_luh_registry(curated: dict, luh: dict) -> dict:
    """Gepflegtes Register (study-sources.json) + breite Erhebung (study-sources-luh.json) -> ein Register fuer die
    QIS-Zuordnung. Gepflegte Eintraege bleiben vorn und unveraendert; jeder LUH-Eintrag wird ein Studiengang
    (zusammengefasst nach Name und Abschluss) mit einer PO je Katalog: modkat-Kataloge mit Quelle luh-fei-modkat
    (Laden auf dem Geraet moeglich), alle anderen mit Quelle luh-grundstock (nur aus dem Grundstock der App).
    Kuerzel: modkat-Kuerzel, sonst der Registerschluessel ohne 'luh|' (`seed_code`; weitere Kataloge ausserhalb von
    modkat sind dort schon in den Haupt-Katalog gemischt und bekommen keine eigene PO). Kuerzel, die das gepflegte
    Register schon kennt, werden uebersprungen; Eintraege ohne Katalog bekommen keine PO (die Zuordnung liefert dann
    nichts, wie bisher)."""
    out = copy.deepcopy(curated)
    uid = luh.get("university") or "luh"
    uni = next((u for u in out.get("universities") or [] if u.get("id") == uid), None)
    if uni is None:
        uni = {"id": uid, "name": UNIVERSITY_NAMES.get(uid, uid), "sources": [], "programs": []}
        out.setdefault("universities", []).append(uni)
    src_id = grundstock_source(uid)
    if not any(s.get("id") == src_id for s in uni.get("sources") or []):
        uni.setdefault("sources", []).append({
            "id": src_id, "format": "grundstock",
            "note": ("Kataloge ausserhalb von modkat: nur aus dem StudiNow-Grundstock (App-Ressource StudyCatalogSeed), "
                     "auf dem Geraet wird nichts geladen (tools/build-luh-seed.py)") if uid == "luh" else
                    ("Kataloge nur aus dem StudiNow-Grundstock (App-Ressource StudyCatalogSeed), auf dem Geraet wird "
                     f"nichts geladen (tools/build-{uid}-seed.py)"),
            "probe_current_term": False})
    if "grundstock" not in (out.get("formats") or []):
        out.setdefault("formats", []).append("grundstock")
    known = {po.get("code") for p in uni.get("programs") or [] for po in p.get("pos") or []}
    ids = {p.get("id") for p in uni.get("programs") or []}
    groups: dict[tuple, dict] = {}
    # Studiengaenge vor Vertiefungen vor Faechern im Lehramt ("Mathematik" -> Mathematik B.Sc., nicht das Fach im
    # Lehramt), sonst Reihenfolge der Erhebung
    rank = {"studiengang": 0, "vertiefung": 1, "fach": 2}
    entries = [e for e in luh.get("programs") or [] if isinstance(e, dict) and e.get("program")]
    entries = [e for _, e in sorted(enumerate(entries), key=lambda x: (rank.get(x[1].get("kind"), 3), x[0]))]
    for e in entries:
        cats = luh_catalogs(e)
        pos = []
        own = False                                      # ein Katalog ausserhalb von modkat je Eintrag
        for c in cats:
            code = seed_code(e.get("key") or "", c["url"])
            if modkat_parts(c["url"]) is None:
                if own:
                    continue
                own = True
            if code in known:
                continue                                 # gepflegter Eintrag gilt
            fei = c.get("format") == "modkat-FEI" and modkat_parts(c["url"]) is not None
            term = c.get("term") if term_number(c.get("term")) else (modkat_parts(c["url"]) or (None, None))[1]
            po = {"po": str(e.get("po") or "unbekannt"), "code": code, "source": FEI_SOURCE if fei else src_id,
                  "catalog_terms": [term] if term else [], "study_plan": None, "key": e.get("key"),
                  "format": c.get("format")}
            if c.get("label"):
                po["label"] = c["label"]
            pos.append(po)
        if cats and not pos:
            continue                                     # ganz im gepflegten Register
        gk = (name_key(e["program"]), str(e.get("degree") or ""))
        prog = groups.get(gk)
        if prog is None:
            pid = _unique(slug(f"{e['program']} {e.get('degree') or ''}"), ids)
            docs = [d.get("url") for d in e.get("po_documents") or [] if isinstance(d, dict) and d.get("url")]
            prog = {"id": pid, "program": e["program"], "degree": e.get("degree") or "unbekannt", "qis_names": [],
                    "regular_semesters": e.get("regular_semesters"), "total_lp": e.get("total_lp"),
                    "po_document_url": docs[0] if docs else None, "faculty": e.get("faculty"), "pos": []}
            groups[gk] = prog
            uni["programs"].append(prog)
        for label in e.get("qis_labels") or []:
            name = parse_abschluss(label)["name"]
            if name and name not in prog["qis_names"]:
                prog["qis_names"].append(name)
        prog["pos"].extend(pos)
    return out


PO_RE = re.compile(r"\(\s*PO[- ]?Version[^)]*\)", re.I)
PO_NUMBER_RE = re.compile(r"PO[- ]?Version:?\s*([0-9]{4})", re.I)
ABSCHLUSS_PREFIX_RE = re.compile(r"^Abschluss:\s*", re.I)
DEGREE_HINTS = (
    (re.compile(r"\bbachelor\b|\bb\.?\s?sc\b|\bb\.?\s?a\b|\bb\.?\s?eng\b", re.I), "B"),
    (re.compile(r"\bmaster\b|\bm\.?\s?sc\b|\bm\.?\s?a\b|\bm\.?\s?eng\b", re.I), "M"),
)


# HIS-LSF (Hildesheim): "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022"
HIS_RE = re.compile(r"^\s*Abschluss:\s*(?:\[[^\]]*\]\s*)?(.*?)\s*Studiengang:\s*(?:\[[^\]]*\]\s*)?(.*)$", re.I | re.S)
HIS_DEGREE_RE = re.compile(r"^\s*([BM])\s?\.?\s?(?:A|Sc|Ed|Eng|Mus)\b\.?", re.I)


def _his_abschluss(text: str, po: str | None) -> dict | None:
    """Zeile 'Abschluss: [nr] <Abschluss> Studiengang: [nr] <Abk.> <Name> PO-Version: <Jahr>' (LSF Hildesheim) ->
    {name, po, degree}; Abschlussart aus der Abkuerzung vor dem Namen, sonst aus dem Abschluss (Bachelor/Master)"""
    m = HIS_RE.match(text)
    if not m:
        return None
    rest = re.sub(r"PO[- ]?Version:?\s*[0-9]{4}.*$", " ", m.group(2), flags=re.I | re.S)
    degree = None
    d = HIS_DEGREE_RE.match(rest)
    if d:
        degree = d.group(1).upper()
        rest = rest[d.end():]
    if degree is None:
        for rx, dc in DEGREE_HINTS:
            if rx.search(m.group(1)):
                degree = dc
                break
    name = re.sub(r"\s+", " ", rest).strip(" ,;:-.")
    return {"name": name, "po": po, "degree": degree}


def parse_abschluss(label: str) -> dict:
    """QIS `abschluss` -> {name, po, degree}: 'Technische Informatik (PO-Version 2017)' -> name 'Technische
    Informatik', po '2017', degree None; LSF Hildesheim 'Abschluss: [82] Bachelor Studiengang: [052] B.A.
    Erziehungswissenschaft PO-Version: 2022' -> 'Erziehungswissenschaft', '2022', 'B'"""
    text = (label or "").strip()
    m = PO_NUMBER_RE.search(text)
    po = m.group(1) if m else None
    his = _his_abschluss(text, po)
    if his is not None:
        return his
    name = PO_RE.sub(" ", text)
    name = re.sub(r"PO[- ]?Version:?\s*[0-9]{4}", " ", name, flags=re.I)
    name = ABSCHLUSS_PREFIX_RE.sub("", name)
    degree = None
    for rx, d in DEGREE_HINTS:
        if rx.search(name):
            degree = d
            name = rx.sub(" ", name)
            break
    name = re.sub(r"\s+", " ", name).strip(" ,;:-")
    return {"name": name, "po": po, "degree": degree}


def _degree_class(degree: str) -> str:
    return "M" if degree.upper().startswith("M") else "B"


def _newest_po(program: dict) -> dict | None:
    pos = program.get("pos") or []
    return max(pos, key=lambda p: (str(p.get("po") or ""), str(p.get("code") or ""))) if pos else None


def match_program(label: str, university: str = "luh", registry: dict | None = None, po: str | None = None) -> dict | None:
    """QIS `abschluss` (und optional bestaetigte PO bzw. Kuerzel) -> Vorschlag:
    {university, program_id, program, degree, po, code, qis_label, qis_po, needs_confirmation} oder None"""
    reg = registry or load_registry()
    parsed = parse_abschluss(label)
    key = name_key(parsed["name"])
    if not key:
        return None
    for uni in reg.get("universities") or []:
        if uni.get("id") != university:
            continue
        cands = [p for p in uni.get("programs") or []
                 if key in {name_key(n) for n in [p.get("program") or ""] + list(p.get("qis_names") or [])}]
        if parsed["degree"]:
            cands = [p for p in cands if _degree_class(p.get("degree") or "") == parsed["degree"]]
        if not cands:
            return None
        cands.sort(key=lambda p: _degree_class(p.get("degree") or ""))     # Bachelor zuerst
        prog = cands[0]
        chosen, confirmed = None, False
        if po:
            chosen = next((p for p in prog.get("pos") or [] if po in (str(p.get("po")), str(p.get("code")))), None)
            confirmed = chosen is not None
        if chosen is None and parsed["po"]:
            chosen = next((p for p in prog.get("pos") or [] if str(p.get("po")) == parsed["po"]), None)
            confirmed = chosen is not None
        if chosen is None:
            chosen = _newest_po(prog)
        if chosen is None or not chosen.get("code"):
            return None
        return {"university": university, "program_id": prog.get("id"), "program": prog.get("program"),
                "degree": prog.get("degree"), "po": str(chosen.get("po")), "code": chosen.get("code"),
                "qis_label": label, "qis_po": parsed["po"], "needs_confirmation": not confirmed}
    return None


def program_entry(registry: dict, university: str, code: str) -> tuple[dict, dict, dict] | None:
    """(Hochschule, Studiengang, PO) zum Kuerzel"""
    for uni in registry.get("universities") or []:
        if uni.get("id") != university:
            continue
        for prog in uni.get("programs") or []:
            for po in prog.get("pos") or []:
                if po.get("code") == code:
                    return uni, prog, po
    return None


def source_urls(registry: dict, university: str, code: str, term: str) -> list[str]:
    """URL des Katalogs und der Spiegel (in dieser Reihenfolge)"""
    found = program_entry(registry, university, code)
    if not found:
        return []
    uni, _, po = found
    src = next((s for s in uni.get("sources") or [] if s.get("id") == po.get("source")), None)
    if not src:
        return []
    patterns = [src.get("url_pattern")] + list(src.get("mirror_patterns") or [])
    return [p.replace("{code}", code).replace("{term}", term_slug(term)) for p in patterns if p]


def study_plan_source(registry: dict, university: str, code: str) -> dict | None:
    """Quelle des Studienverlaufsplans zum Kuerzel ({url, format}, nur https und bekanntes Format), sonst None"""
    found = program_entry(registry, university, code)
    sp = found[2].get("study_plan") if found else None
    if not isinstance(sp, dict) or sp.get("format") != PLAN_FORMAT:
        return None
    url = sp.get("url")
    return {"url": url, "format": PLAN_FORMAT} if isinstance(url, str) and url.startswith("https://") else None


def candidate_terms(registry: dict, university: str, code: str, today: str) -> list[str]:
    """Katalogsemester zum Versuchen: das laufende (wenn neuer als alle bekannten und die Quelle es erlaubt), dann
    die bekannten, neueste zuerst"""
    found = program_entry(registry, university, code)
    if not found:
        return []
    uni, _, po = found
    known = sorted({t for t in po.get("catalog_terms") or [] if term_number(t)}, key=term_number, reverse=True)
    src = next((s for s in uni.get("sources") or [] if s.get("id") == po.get("source")), {})
    cur = current_term(today)
    if src.get("probe_current_term") and (not known or term_number(cur) > term_number(known[0])):
        return [cur] + known
    return known


# ----------------------------------------------------------------------------
# Parser: LUH-Modulkatalog (modkat)
# ----------------------------------------------------------------------------

FOOTER_RE = re.compile(r"^[0-9]+ / [0-9]+$")
HEADER_RE = re.compile(r"^Modulkatalog .+? \((?:Wintersemester|Sommersemester) [0-9]{4}(?:/[0-9]{4})?\) ?")
STAND_RE = re.compile(r"^Stand: [0-9]{2}\.[0-9]{2}\.[0-9]{4} ?")
TOC_RE = re.compile(r"^(.*?) ?(?:\. ?){4,}([0-9]+)$")            # Punktfuehrer "....." oder ". . . ."
TABLE_HEAD_RE = re.compile(r"^Modul LP SWS\b")
PLACEMENT_RE = re.compile(r"^(.+?) - ")
SECTION_RE = re.compile(r"^([0-9]+(?:\.[0-9]+)*)\. (.+)$")
AREA_INFO_RE = re.compile(r"^Information zum Kompetenzbereich: ?(.*)$")
LP_RANGE_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?)(?: ?- ?([0-9]+(?:[.,][0-9]+)?))? ?LP")
LP_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?) ?LP\b")
WORKLOAD_RE = re.compile(r"(?:Gesamt:? ?)?([0-9]+) ?(?:h\b|Stunden)")
SEMESTER_RE = re.compile(r"([0-9]+)\. ?Fachsemester")
SEMESTER_HINT_RE = re.compile(r"Empfohlen (?:für|ab) (?:das|dem) ([0-9]+)\.")
EXAM_KLAUSUR_RE = re.compile(r"^Klausur(?: \(K\))?(?:,? \(?([0-9]+) ?min\)?| \( ?min\))?$")
COURSEWORK_RE = re.compile(r"^([0-9]+), ?([^:]*?) ?(?::.*)?$")
FINAL_RE = re.compile(r"bachelorarbeit|masterarbeit|abschlussarbeit", re.I)

# Ueberschriften der Felder (ganze Zeile); Reihenfolge im Katalog: Fakten, dann Texte
FACT_LABELS = {
    "Sprache": "language", "Modultitel englisch": "title_en", "Kompetenzbereich": "area_name", "Modultyp": "kind",
    "Prüfungsform": "exam", "Prüfungsbewertung": "grading", "Studienleistung": "coursework",
    "Empfohlenes Fachsemester": "semester", "Studentische Arbeitsleistung": "workload",
    "Frequenz der Lehrveranstaltung": "frequency", "Frequenz": "frequency", "Schwerpunkt / Micro-Degree": "focus",
    "Bei Seminar: Semesterthema (dt/en)": "seminar", "Organisationseinheit": "org", "Modulverantwortung": "responsible",
    "Organisationseinheit Modulverantwortung": "org", "Webseite": "website",
    # neuere Form (modkat-full, ab WS 2026/27): Bereiche als Tabellen, Module alphabetisch mit diesen Ueberschriften
    "LP (ECTS)": "lp", "SWS": "sws_only", "regelhaftes Lehrangebot": "frequency", "Gewählte Prüfungsform": "exam",
    "Prüfungsbewertungen": "grading", "Zuständigkeit": "unit", "Einordnung und Belegungsmöglichkeit in Studiengänge": "placement",
    "Dozent/in": "lecturer", "Prüfer/in": "examiner", "Prüfungsanmeldung": "registration",
    "Schwerpunkt / Micro-Degree Bei Seminar: Semesterthema (dt/en)": "focus",
}
TEXT_LABELS = {"Qualifikationsziele": "goals", "Inhalt": "content", "Inhalt und Stoffplan": "content",
               "Teilnahmevoraussetzungen und -empfehlungen": "prereq",
               "Literatur": "literature", "Weitere Angaben": "notes"}
PREFIX_LABELS = (("Angebot im ", "offer"), ("SWS LP", "sws"))
SUFFIX_LABELS = ("Sprache",)


def clean_pages(pages: list[str]) -> list[list[str]]:
    """Normalisierte Zeilen je Seite ohne Kopf ('Modulkatalog ... (Wintersemester ...) Stand: ...') und Fuss ('5 / 106')"""
    out = []
    for text in pages:
        lines = []
        for line in normalize_lines(text):
            if FOOTER_RE.match(line):
                continue
            rest = HEADER_RE.sub("", line, count=1) if HEADER_RE.match(line) else line
            rest = STAND_RE.sub("", rest, count=1) if STAND_RE.match(rest) else rest
            rest = rest.strip(" ")
            if rest:
                lines.append(rest)
        out.append(lines)
    return out


def _number(s: str):
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _toc(pages: list[list[str]]) -> list[dict]:
    """Eintraege des Inhaltsverzeichnisses: {kind: area|module, title, page, number?} in Reihenfolge. Beginnt auf der
    ersten Seite mit mindestens drei Eintraegen und endet vor der ersten Seite ohne Eintrag. Stehen mehrere Nummern vor
    einem Titel ("1. 2. Kompetenzbereiche", PDFKit setzt die Nummernspalte so zusammen), gehoert die erste zum Titel,
    die weiteren der Reihe nach zu den naechsten Eintraegen ohne Nummer."""
    entries: list[dict] = []
    started = False
    displaced: list[str] = []
    for lines in pages:
        hits = sum(1 for l in lines if TOC_RE.match(l))
        if hits < (1 if started else 3):
            if started:
                break
            continue
        started = True
        pending = ""
        for l in lines:
            m = TOC_RE.match(l)
            if not m:
                pending = (pending + " " + l).strip(" ")
                continue
            title = (pending + " " + m.group(1)).strip(" ")
            pending = ""
            s = SECTION_RE.match(title)
            if s:
                number, rest = s.group(1), s.group(2)
                while True:
                    more = SECTION_RE.match(rest)
                    if not more or "." in more.group(1):
                        break
                    displaced.append(more.group(1))
                    rest = more.group(2)
                entries.append({"kind": "area", "number": number, "title": rest, "page": int(m.group(2))})
            elif displaced:
                entries.append({"kind": "area", "number": displaced.pop(0), "title": title, "page": int(m.group(2))})
            else:
                entries.append({"kind": "module", "title": title, "page": int(m.group(2))})
    return entries


def _label(line: str):
    if line in FACT_LABELS:
        return FACT_LABELS[line], None
    if line in TEXT_LABELS:
        return TEXT_LABELS[line], None
    for prefix, key in PREFIX_LABELS:
        if line.startswith(prefix):
            return key, line[len(prefix):].strip(" ")
    return None, None


def _module_fields(lines: list[str], title: str) -> dict:
    """Felder eines Moduls: Kopf (Titel, englischer Titel), dann Feld -> Zeilen. Texte (ab Qualifikationsziele) nur in
    ihrer festen Reihenfolge, Fakten nur davor."""
    fields: dict[str, list[str]] = {}
    current = "_head"
    fields[current] = []
    text_order = list(TEXT_LABELS.values())
    in_text = -1
    want = title
    for i, line in enumerate(lines):
        key, inline = _label(line)
        if key is None and current == "_head":
            # Titel und Ueberschrift "Sprache" in einer Zeile ("Grundlagen der Data Science Sprache")
            for suf in SUFFIX_LABELS:
                if line.endswith(" " + suf) and want.startswith(line[: -len(suf) - 1]):
                    fields["_head"].append(line[: -len(suf) - 1])
                    key = FACT_LABELS[suf]
                    break
            if key is not None:
                current = key
                fields.setdefault(current, [])
                continue
        if key is not None:
            if key in text_order:
                pos = text_order.index(key)
                if pos <= in_text:
                    key = None
                else:
                    in_text = pos
            elif in_text >= 0 or key in fields:
                key = None
        if key is None:
            fields[current].append(line)
            continue
        current = key
        fields.setdefault(current, [])
        if inline:
            fields.setdefault("_" + key, []).append(inline)
    return fields


def _join(lines: list[str] | None, sep: str = " ") -> str:
    return sep.join(lines or []).strip(" ")


def _exam(value: str) -> str | None:
    s = re.sub(r" +,", ",", value).strip(" ")
    if not s or s.lower() in ("keine", "-"):
        return None
    m = EXAM_KLAUSUR_RE.match(s)
    if m:
        return f"Klausur {m.group(1)} min" if m.group(1) else "Klausur"
    return s[:MAX_TEXT]


def _coursework(value: str) -> str | None:
    s = value.strip(" ")
    if not s or s.lower() in ("keine", "-", "nein"):
        return None
    m = COURSEWORK_RE.match(s)
    if m:
        n = int(m.group(1))
        if n == 0:
            return None
        term = m.group(2).strip(" ,")
        word = "Studienleistung" if n == 1 else "Studienleistungen"
        return f"{n} {word}" + (f" ({term})" if term else "")
    return s[:MAX_TEXT]


def _turnus(frequency: str, offer_value: str, has_offer: bool, season: str) -> str:
    f = frequency.lower()
    if "jedes semester" in f:
        return "WS+SS"
    if "winter" in f:
        return "WS"
    if "sommer" in f:
        return "SS"
    if f.startswith("jährlich") and has_offer:
        o = offer_value.lower()
        if "vorlesung" in o or "lehrveranstaltung" in o:
            return season
        if "nur prüfung" in o:
            return "SS" if season == "WS" else "WS"
    return "unbekannt"


def _kind_of(value: str) -> str | None:
    v = value.lower().replace("-", "").replace(" ", "")
    return {"pflicht": "pflicht", "p": "pflicht", "wahlpflicht": "wahlpflicht", "wp": "wahlpflicht", "wahl": "wahl",
            "w": "wahl"}.get(v)


def _is_word_char(c: str) -> bool:
    return c.isalnum()


def _mentions(text: str, title: str) -> bool:
    hay, needle = text.lower(), title.lower()
    if not needle:
        return False
    start = 0
    while True:
        i = hay.find(needle, start)
        if i < 0:
            return False
        before = hay[i - 1] if i > 0 else " "
        j = i + len(needle)
        after = hay[j] if j < len(hay) else " "
        if not _is_word_char(before) and not _is_word_char(after):
            return True
        start = i + 1


def _unique(base: str, seen: set) -> str:
    out, n = base, 2
    while out in seen:
        out = f"{base}-{n}"
        n += 1
    seen.add(out)
    return out


def parse_luh_modkat(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Seitentexte eines LUH-Modulkatalogs -> (Katalog im geteilten Format, {modul_id: {content, goals, literature}}).
    meta: university, program, degree, po, code, catalog_term, regular_semesters, total_lp, source {url, fetched_at,
    sha256}"""
    clean = clean_pages(pages)
    term = meta.get("catalog_term") or ""
    if not term and clean:
        term = term_from_title(" ".join(clean[0])) or ""
    season = "SS" if term.startswith("SS") else "WS"
    toc = _toc(clean)
    n_pages = len(clean)
    starts = sorted({e["page"] for e in toc})

    def block(page: int) -> list[str]:
        nxt = next((p for p in starts if p > page), n_pages + 1)
        out = []
        for p in range(page, max(page + 1, nxt)):
            if 1 <= p <= n_pages:
                out.extend(clean[p - 1])
        return out

    def area_info(e: dict):
        if not 1 <= e["page"] <= n_pages:
            return None
        return next((AREA_INFO_RE.match(l) for l in clean[e["page"] - 1] if AREA_INFO_RE.match(l)), None)

    # Abschnitte: Kapitel ("1." mit "1.1." darunter) und Abschnitte ohne Bereichsangabe ("2. Details der
    # Semesterangebote") sind keine Bereiche, sobald irgendein Abschnitt eine Bereichsangabe hat
    numbers = [e["number"] for e in toc if e["kind"] == "area"]
    chapters = {n for n in numbers if any(o.startswith(n + ".") for o in numbers)}
    any_info = any(area_info(e) for e in toc if e["kind"] == "area" and e["number"] not in chapters)

    areas: list[dict] = []
    area_ids: set = set()
    area_pages: list[int] = []
    raw_modules: list[dict] = []
    current_area: dict | None = None
    for e in toc:
        if e["kind"] == "area":
            info = area_info(e)
            if e["number"] in chapters or (any_info and not info):
                current_area = None
                continue
            lp_req = lp_max = None
            kind = "pflicht"
            if info:
                m = LP_RANGE_RE.search(info.group(1))
                if m:
                    lp_req = _number(m.group(1))
                    lp_max = _number(m.group(2)) if m.group(2) else None
                tail = info.group(1).rsplit(",", 1)[-1] if "," in info.group(1) else ""
                kind = _kind_of(tail.strip(" ")) or "pflicht"
            if FINAL_RE.search(e["title"]):
                kind = "abschluss"
            current_area = {"id": _unique(slug(e["title"]), area_ids), "name": e["title"], "lp_required": lp_req,
                            "lp_max": lp_max, "kind": kind}
            areas.append(current_area)
            area_pages.append(e["page"])
            continue
        raw_modules.append({"title": e["title"], "page": e["page"], "area": current_area,
                            "fields": _module_fields(block(e["page"]), e["title"])})

    # neuere Form: Module stehen alphabetisch, der Bereich ergibt sich aus der Tabelle "Modul LP SWS ..." auf den
    # Bereichsseiten (Titel, dahinter die LP-Zahl; umbrochene Titel wie im Verlaufsplan verbunden)
    tables = [_plan_join(block(p)) for p in area_pages]
    if any(TABLE_HEAD_RE.match(l) for p in area_pages for l in block(p)):
        for rm in raw_modules:
            if rm["area"] is None:
                rx = re.compile(r"(?:^| )" + re.escape(rm["title"]) + r" [0-9]")
                k = next((i for i, t in enumerate(tables) if rx.search(t)), None)
                rm["area"] = areas[k] if k is not None else None
        # sonst ueber das Kuerzel der Einordnung ("TIBSc25 - GI - Programmieren I"), das andere Module desselben
        # Bereichs schon zeigen (PDFKit setzt umbrochene Tabellenzeilen manchmal auseinander)
        code = str(meta.get("code") or "")

        def abbr(rm: dict) -> str | None:
            for line in rm["fields"].get("placement") or []:
                if code and line.startswith(code + " - "):
                    m = PLACEMENT_RE.match(line[len(code) + 3:])
                    return m.group(1) if m else None
            return None

        by_abbr: dict = {}
        for rm in raw_modules:
            a = abbr(rm)
            if a and rm["area"] is not None and a not in by_abbr:
                by_abbr[a] = rm["area"]
        for rm in raw_modules:
            if rm["area"] is None and abbr(rm) in by_abbr:
                rm["area"] = by_abbr[abbr(rm)]

    module_ids: set = set()
    modules: list[dict] = []
    texts: dict = {}
    for rm in raw_modules:
        f = rm["fields"]
        mid = _unique(slug(rm["title"]), module_ids)
        sws = _join(f.get("sws"))
        lp_m = LP_RE.search(sws) or LP_RE.search(_join(f.get("lp")))
        lp = _number(lp_m.group(1)) if lp_m else None
        sem_m = SEMESTER_RE.search(_join(f.get("semester")))
        semester = int(sem_m.group(1)) if sem_m else None
        if semester is None:
            hint = SEMESTER_HINT_RE.search(_join(f.get("prereq")) + " " + _join(f.get("notes")))
            semester = int(hint.group(1)) if hint else None
        if semester is not None and not 1 <= semester <= 20:
            semester = None
        work_m = WORKLOAD_RE.search(_join(f.get("workload")))
        language = _join((f.get("language") or [])[:1]).lower() or None
        modules.append({
            "id": mid,
            "title": rm["title"],
            "code": None,
            "area": rm["area"]["id"] if rm["area"] else None,
            "kind": _kind_of(_join((f.get("kind") or [])[:1])),
            "lp": lp,
            "semester": semester,
            "turnus": _turnus(_join(f.get("frequency")), _join(f.get("offer")), "offer" in f, season),
            "exam": _exam(_join(f.get("exam"))),
            "coursework": _coursework(_join(f.get("coursework"))),
            "prerequisites": [],
            "language": language[:MAX_TEXT] if language else None,
            "workload_h": int(work_m.group(1)) if work_m else None,
            "source_page": rm["page"],
            "_prereq": _join(f.get("prereq")),
        })
        texts[mid] = {"content": _join(f.get("content"), "\n") or None, "goals": _join(f.get("goals"), "\n") or None,
                      "literature": _join(f.get("literature"), "\n") or None}

    # Art aus dem Bereich, wenn der Katalog keine nennt
    # (nennen andere Module des Bereichs ausdruecklich Wahl(pflicht), sind die ohne Angabe der feste Kern)
    for a in areas:
        mods = [m for m in modules if m["area"] == a["id"]]
        total = sum(m["lp"] or 0 for m in mods)
        explicit_choice = any(m["kind"] in ("wahlpflicht", "wahl") for m in mods)
        for m in mods:
            if a["kind"] == "abschluss":
                m["kind"] = "abschluss"
            elif m["kind"] is None:
                if a["kind"] == "wahl":
                    m["kind"] = "wahl"
                elif explicit_choice:
                    m["kind"] = "pflicht"
                elif a["lp_max"] is not None or (a["lp_required"] is not None and total > a["lp_required"]):
                    m["kind"] = "wahlpflicht"
                else:
                    m["kind"] = "pflicht"
    for m in modules:
        if m["kind"] is None:
            m["kind"] = "pflicht"
    # Voraussetzungen: genannte andere Module (Titel als ganzes Wort), Reihenfolge wie im Katalog
    for m in modules:
        text = m.pop("_prereq")
        m["prerequisites"] = [o["id"] for o in modules if o["id"] != m["id"] and _mentions(text, o["title"])]

    src = meta.get("source") or {}
    catalog = {
        "v": 1,
        "university": meta.get("university"),
        "program": meta.get("program"),
        "degree": meta.get("degree"),
        "po": meta.get("po"),
        "catalog_term": term,
        "code": meta.get("code"),
        "regular_semesters": meta.get("regular_semesters"),
        "total_lp": meta.get("total_lp"),
        "source": {"url": src.get("url"), "fetched_at": src.get("fetched_at"), "sha256": src.get("sha256")},
        "areas": areas,
        "modules": modules,
    }
    return catalog, texts


MODULE_COUNT_RE = re.compile(r"\b([0-9]+|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn) (?:weitere )?(?:Wahlpflicht|Wahl|Pflicht)?[Mm]odule\b", re.I)
COUNT_WORDS = {"zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8,
               "neun": 9, "zehn": 10}
MAX_RULE = 400


def modkat_area_extras(pages: list[str], catalog: dict) -> dict:
    """Wahlbereiche (05.11.2026), nur fuer den Grundstock (tools/build-luh-seed.py): je Bereich der neueren
    modkat-Form die Regel unter "Information zum Kompetenzbereich" ("Der Studienschwerpunkt ist absolviert, wenn
    mindestens vier Module ...") und alle Module der Bereichstabelle (ein Modul steht oft in mehreren Bereichen, der
    Katalog fuehrt es nur im ersten). Ergebnis {Bereichs-id: {rule, modules, modules_required}}; der Leser selbst
    (parse_luh_modkat, gleich im Swift-Kern) bleibt unveraendert."""
    clean = clean_pages(pages)
    toc = _toc(clean)
    n_pages = len(clean)
    starts = sorted({e["page"] for e in toc})
    by_name = {a["name"]: a["id"] for a in catalog.get("areas") or []}
    titles = [(m["id"], m["title"]) for m in catalog.get("modules") or []]
    out: dict = {}
    for e in toc:
        if e["kind"] != "area" or e["title"] not in by_name or not 1 <= e["page"] <= n_pages:
            continue
        nxt = next((p for p in starts if p > e["page"]), n_pages + 1)
        lines = [l for p in range(e["page"], max(e["page"] + 1, nxt)) if 1 <= p <= n_pages for l in clean[p - 1]]
        info = next((i for i, l in enumerate(lines) if AREA_INFO_RE.match(l)), None)
        head = next((i for i, l in enumerate(lines) if TABLE_HEAD_RE.match(l) or l.startswith("Modul Modul LP SWS")), None)
        if info is None or head is None:
            continue
        rule = " ".join(lines[info + 1:head]).strip(" ")
        rule = re.sub(r" {2,}", " ", rule)
        if len(rule) > MAX_RULE:
            cut = rule[:MAX_RULE].rsplit(". ", 1)[0]
            rule = cut + "." if len(cut) > 40 else rule[:MAX_RULE - 1] + "…"
        table = _plan_join(lines[head:])
        mods = [mid for mid, t in titles if re.search(r"(?:^| )" + re.escape(t) + r" [0-9]", table)]
        count = None
        m = MODULE_COUNT_RE.search(rule)
        if m:
            w = m.group(1).lower()
            count = int(w) if w.isdigit() else COUNT_WORDS.get(w)
        out[by_name[e["title"]]] = {"rule": rule or None, "modules": mods, "modules_required": count}
    return out


def dumps(value) -> str:
    """Kanonische Form fuer Vergleiche mit dem Swift-Kern (PyJSON.dumps(ensureASCII: false))"""
    return json.dumps(value, ensure_ascii=False)


# ----------------------------------------------------------------------------
# Studienverlaufsplan (LUH FEI: eine Seite, Semester als Zeilen "1. SEMESTER", Module als Kaesten mit Titel,
# Lehrperson und "2V+2Ü | 5 ECTS"; gleiche Regeln: UniFlowCore StudyCatalog/StudyPlanSheet.swift)
# ----------------------------------------------------------------------------

PLAN_FORMAT = "luh-fei-verlaufsplan"
PLAN_LABEL_RE = re.compile(r"^([0-9]{1,2})\. ?(?:fach)?semester$", re.I)
PLAN_LABEL_NUM_RE = re.compile(r"^([0-9]{1,2})\.$")
PLAN_LABEL_WORD_RE = re.compile(r"^(?:fach)?semester$", re.I)
PLAN_LP_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?)(?: ?- ?([0-9]+(?:[.,][0-9]+)?))? ?(?:ECTS|LP)\b")
PLAN_UNIT_RE = re.compile(r"^(?:ECTS|LP)$")
_SWS_UNIT = r"(?:LÜ|LU|PR|PJ|SE|TU|V|Ü|U|S|L|P|T)"
PLAN_SWS_RE = re.compile(r"^(?:[0-9]+ ?" + _SWS_UNIT + r"|(?:PR|PJ|SE|LÜ) ?[0-9]+)(?: ?\+ ?[0-9]+ ?" + _SWS_UNIT + r")*$")
PLAN_INKL_RE = re.compile(r" (?:inkl\.?|inklusive|einschl\.?|einschließlich) .*$", re.I)
PLAN_STOP = {"der", "die", "das", "des", "dem", "den", "und", "oder", "in", "im", "fuer", "von", "vom", "zu", "zur",
             "zum", "mit", "the", "of", "and", "a", "an", "for"}


def _display_point(rot: int, x: float, y: float, box: tuple) -> tuple[float, float]:
    """Punkt der Seite -> Leserichtung (links oben 0/0) bei /Rotate 0, 90, 180, 270"""
    x0, y0, x1, y1 = box
    if rot == 90:
        return y - y0, x - x0
    if rot == 180:
        return x1 - x, y - y0
    if rot == 270:
        return y1 - y, x1 - x
    return x - x0, y1 - y


def pdf_items(data: bytes) -> list[list[list]]:
    """Textstuecke je Seite mit Lage [x, y, text] in Leserichtung: x = linke Kante, y = senkrechte Mitte der Zeile
    (Grundlinie minus 0,35 Schriftgroesse). Der Swift-Kern nimmt die Zeilen aus PDFKit (Mitte des Rahmens); der Parser
    rechnet mit Toleranzen, beide ergeben auf der Fixture denselben Plan."""
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    out: list[list[list]] = []
    for page in reader.pages:
        items: list[list] = []
        try:
            rot = int(page.get("/Rotate") or 0) % 360
            mb = page.mediabox
            box = (float(mb.left), float(mb.bottom), float(mb.right), float(mb.top))

            def visit(text, cm, tm, _font, size, items=items, rot=rot, box=box):
                px = tm[4] * cm[0] + tm[5] * cm[2] + cm[4]
                py = tm[4] * cm[1] + tm[5] * cm[3] + cm[5]
                h = float(size or 0) * math.hypot(tm[2], tm[3]) * math.hypot(cm[2], cm[3])
                dx, dy = _display_point(rot, px, py, box)
                for k, part in enumerate((text or "").split("\n")):
                    t = " ".join(normalize_lines(part))
                    if t:
                        items.append([round(dx, 1), round(dy - 0.35 * h + k * 1.2 * h, 1), t])

            page.extract_text(visitor_text=visit)
        except Exception:  # noqa: BLE001
            pass
        out.append(items)
    return out


def _plan_join(lines: list[str]) -> str:
    """Zeilen eines Kastens: Trennstrich vor Kleinbuchstabe weg ("Ingenieurwissen-" + "schaften"), sonst ohne
    Leerzeichen ("IT-" + "Sicherheit"); " -" am Ende bleibt ein Wort"""
    out = ""
    for line in lines:
        if not out:
            out = line
        elif out.endswith("-") and not out.endswith(" -") and len(out) > 1:
            out = out[:-1] + line if line[:1].islower() else out + line
        else:
            out = out + " " + line
    return out


def _has_letter(s: str) -> bool:
    return any(c.isalpha() for c in s)


def _plan_meta(t: str) -> bool:
    """LP-Angabe, Einheit, Semesterwochenstunden ("2V+2Ü", "PR6") oder ohne Buchstaben (Summen "28")"""
    return bool(PLAN_LP_RE.search(t) or PLAN_UNIT_RE.match(t) or PLAN_SWS_RE.match(t)) or not _has_letter(t)


def parse_study_plan(pages: list) -> dict:
    """Studienverlaufsplan aus Textstuecken je Seite ([x, y, text], `pdf_items`) -> {entries: [{semester, title, text,
    lp, lp_max}], footnote}. Semesterzeilen aus den Beschriftungen "n." + "SEMESTER", Kaesten je Spalte (linke Kante
    der Titelzeilen), LP aus "| 5 ECTS" bzw. "3-6 ECTS" im Kasten, Titel = erster Absatz (danach Lehrperson)."""
    entries: list[dict] = []
    footnote = None
    for raw in pages or []:
        items: list[tuple] = []
        for it in raw or []:
            if not isinstance(it, (list, tuple)) or len(it) < 3 or not all(_is_num(v) for v in it[:2]):
                continue
            t = " ".join(normalize_lines(str(it[2])))
            if not t:
                continue
            x, y = float(it[0]), float(it[1])
            m = PLAN_LP_RE.search(t)
            before = t[:m.start()].strip(" |") if m else ""
            if m and before and _has_letter(before) and not PLAN_SWS_RE.match(before):
                # Titel und LP in einer Zeile ("Wahlpflicht Technische Informatik 5 LP")
                items.append((x, y, before, len(items)))
                items.append((x, y, t[m.start():], len(items)))
            else:
                items.append((x, y, t, len(items)))
        # Semester-Beschriftungen
        labels: list[tuple] = []
        used: set = set()
        for x, y, t, i in items:
            m = PLAN_LABEL_RE.match(t)
            if m:
                labels.append((y, int(m.group(1)), x, i))
                used.add(i)
                continue
            m = PLAN_LABEL_NUM_RE.match(t)
            if not m:
                continue
            words = [(y2 - y, j) for x2, y2, t2, j in items
                     if j not in used and j != i and PLAN_LABEL_WORD_RE.match(t2) and abs(x2 - x) <= 40 and 0 < y2 - y <= 40]
            if words:
                labels.append((y, int(m.group(1)), x, i))
                used.add(i)
                used.add(min(words)[1])
        if len(labels) < 2:
            continue
        labels.sort()
        diffs = sorted(labels[k + 1][0] - labels[k][0] for k in range(len(labels) - 1))
        spacing = diffs[len(diffs) // 2]
        if spacing <= 0:
            continue
        bands = []
        for k, (y, n, _, _) in enumerate(labels):
            bottom = labels[k + 1][0] - 0.25 * spacing if k + 1 < len(labels) else y + 0.75 * spacing
            bands.append((n, y - 0.25 * spacing, bottom))

        def in_band(y: float) -> bool:
            return any(top <= y < bottom for _, top, bottom in bands)

        free = [o for o in items if o[3] not in used]
        # Fussnote "* ..." unter dem Plan (fuer Wahlbereiche wie "Wahl(pflicht)modul*")
        outside = [o for o in free if not in_band(o[1])]
        stars = sorted((o for o in outside if o[2].startswith("*")), key=lambda o: (o[1], o[0], o[3]))
        if stars and footnote is None:
            fx, fy = stars[0][0], stars[0][1]
            lines, last = [], None
            for o in sorted((o for o in outside if abs(o[0] - fx) <= 3 and o[1] >= fy), key=lambda o: (o[1], o[0], o[3])):
                if last is not None and o[1] - last > 0.25 * spacing:
                    break
                lines.append(o[2])
                last = o[1]
            footnote = _plan_join(lines).lstrip("* ") or None
        # Spalten je Semester: linke Kante der Titelzeilen
        per_band = []
        for n, top, bottom in bands:
            inside = [o for o in free if top <= o[1] < bottom]
            content = sorted((o for o in inside if not _plan_meta(o[2])), key=lambda o: (o[0], o[1], o[3]))
            anchors: list[float] = []
            for o in content:
                if not anchors or o[0] - anchors[-1] > 4:
                    anchors.append(o[0])
            per_band.append((n, inside, anchors))
        all_anchors = sorted({a for _, _, anchors in per_band for a in anchors})
        gaps = [b - a for _, _, anchors in per_band for a, b in zip(anchors, anchors[1:])]
        pitch = min(gaps) if gaps else spacing
        right = (all_anchors[-1] + pitch) if all_anchors else 0
        for n, inside, anchors in per_band:
            boxes: dict = {a: ([], []) for a in anchors}
            for o in inside:
                if _plan_meta(o[2]):
                    cands = [a for a in anchors if a <= o[0] + 4]
                    if cands and o[0] <= right:
                        boxes[max(cands)][1].append(o)
                else:
                    boxes[max(a for a in anchors if a <= o[0])][0].append(o)
            for a in anchors:
                lines = sorted(boxes[a][0], key=lambda o: (o[1], o[0], o[3]))
                meta = sorted(boxes[a][1], key=lambda o: (o[1], o[0], o[3]))
                m = PLAN_LP_RE.search(" ".join(o[2] for o in meta))
                if not lines or not m:
                    continue
                segs = [[lines[0]]]
                for prev, cur in zip(lines, lines[1:]):
                    if cur[1] - prev[1] > 0.2 * spacing:
                        segs.append([cur])
                    else:
                        segs[-1].append(cur)
                title = _plan_join([o[2] for o in segs[0]])
                entries.append({"semester": n, "title": title[:MAX_TEXT],
                                "text": " ".join(_plan_join([o[2] for o in s]) for s in segs)[:MAX_TEXT],
                                "lp": _number(m.group(1)), "lp_max": _number(m.group(2)) if m.group(2) else None})
    return {"entries": entries, "footnote": footnote[:MAX_TEXT] if footnote else None}


def _plan_tokens(text: str) -> list[str]:
    return [ROMAN.get(t, t) for t in TOKEN_RE.findall(_fold(text))]


def _levenshtein(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _plan_areas(text: str, areas: list[dict]) -> list[str]:
    """Bereiche, die ein Wahlkasten (mit Fussnote) nennt: alle bedeutungstragenden Woerter des Bereichsnamens kommen
    vor ("Vertiefung der Informatik oder Informationstechnik" -> beide Vertiefungen), oder das gemeinsame erste Wort
    einer Gruppe steht allein ("einem Nebenfach (N)" -> alle Nebenfaecher)"""
    toks = [t for t in _plan_tokens(text) if t not in PLAN_STOP]
    have = set(toks)
    sig = {a["id"]: [t for t in _plan_tokens(a.get("name") or "") if t not in PLAN_STOP] for a in areas}
    out: list[str] = []
    for a in areas:
        s = sig[a["id"]]
        if not s or a["id"] in out:
            continue
        if all(t in have for t in s):
            out.append(a["id"])
            continue
        group = [b for b in areas if sig[b["id"]][:1] == s[:1]]
        if len(group) < 2:
            continue
        seconds = {sig[b["id"]][1] for b in group if len(sig[b["id"]]) > 1}
        if any(t == s[0] and (k + 1 >= len(toks) or toks[k + 1] not in seconds) for k, t in enumerate(toks)):
            out.append(a["id"])
    return out


def _plan_slot_title(text: str) -> str:
    return SPACES_RE.sub(" ", text.replace("*", "")).strip(" ")[:MAX_TEXT] or "Wahlmodul"


def merge_study_plan(catalog: dict, plan: dict, source: dict | None = None) -> tuple[dict, list[str]]:
    """Katalog + Studienverlaufsplan -> (Katalog mit `semester` laut Plan und `plan_slots`, nicht zugeordnete Kaesten).
    Zuordnung je Kasten ueber den Titel (Woerter klein, Umlaute ausgeschrieben, roemische Zahlen als Ziffern, "inkl. ..."
    weg): gleich -> Modul; Name eines Bereichs -> Platz fuer diesen Bereich; Anfang mehrerer Modultitel ("Proseminar")
    -> Platz fuer deren Bereiche, eines Modultitels -> Modul; fast gleich (hoechstens 2 Zeichen, ab 12 Zeichen,
    eindeutig) -> Modul; "Wahl..." -> Platz fuer die genannten Bereiche (leer = jeder Wahlbereich). Module ohne
    Kasten in Wahl(pflicht)- oder Platz-Bereichen bekommen `semester: null`, die anderen behalten den Katalogwert."""
    out = copy.deepcopy(catalog)
    areas = [a for a in out.get("areas") or [] if isinstance(a, dict) and isinstance(a.get("id"), str)]
    mods = [m for m in out.get("modules") or [] if isinstance(m, dict) and isinstance(m.get("id"), str)]
    mtoks = [_plan_tokens(m.get("title") if isinstance(m.get("title"), str) else "") for m in mods]
    mkeys = ["".join(t) for t in mtoks]
    akeys: dict[str, str] = {}
    for a in areas:
        akeys.setdefault("".join(_plan_tokens(a.get("name") if isinstance(a.get("name"), str) else "")), a["id"])
    footnote = plan.get("footnote") if isinstance(plan.get("footnote"), str) else ""
    assigned: dict[str, int] = {}
    slots: list[dict] = []
    unmatched: list[str] = []

    def slot(e: dict, ids: list[str]) -> dict:
        text = e.get("text") if isinstance(e.get("text"), str) and e.get("text") else e.get("title") or ""
        return {"semester": e.get("semester"), "title": _plan_slot_title(text), "areas": ids,
                "lp": e.get("lp") if _is_num(e.get("lp")) else None,
                "lp_max": e.get("lp_max") if _is_num(e.get("lp_max")) else None}

    for e in plan.get("entries") or []:
        if not isinstance(e, dict) or not _is_int(e.get("semester")) or not isinstance(e.get("title"), str):
            continue
        title = e["title"]
        toks = _plan_tokens(PLAN_INKL_RE.sub("", title))
        key = "".join(toks)
        if not key:
            continue
        hit = next((m for m, k in zip(mods, mkeys) if k == key), None)
        if hit is None and key in akeys:
            slots.append(slot(e, [akeys[key]]))
            continue
        if hit is None:
            pre = [m for m, t in zip(mods, mtoks) if len(toks) < len(t) and t[:len(toks)] == toks]
            if len(pre) > 1:
                ids: list[str] = []
                for m in pre:
                    if isinstance(m.get("area"), str) and m["area"] not in ids:
                        ids.append(m["area"])
                slots.append(slot(e, ids))
                continue
            hit = pre[0] if pre else None
        if hit is None and len(key) >= 12:
            ds = [_levenshtein(key, k) for k in mkeys]
            best = min(ds, default=99)
            if best <= 2 and ds.count(best) == 1:
                hit = mods[ds.index(best)]
        if hit is not None:
            assigned.setdefault(hit["id"], int(e["semester"]))
            continue
        full = e.get("text") if isinstance(e.get("text"), str) and e.get("text") else title
        if "wahl" in _fold(full):
            slots.append(slot(e, _plan_areas(full + (" " + footnote if "*" in full and footnote else ""), areas)))
            continue
        unmatched.append(title)

    covered = {a for s in slots for a in s["areas"]}
    for m in mods:
        if m["id"] in assigned:
            m["semester"] = assigned[m["id"]]
        elif m.get("kind") in ("wahlpflicht", "wahl") or m.get("area") in covered:
            m["semester"] = None
    if source is not None:
        out["study_plan"] = {"url": source.get("url"), "fetched_at": source.get("fetched_at"), "sha256": source.get("sha256")}
    out["plan_slots"] = slots
    return out, unmatched


# ----------------------------------------------------------------------------
# Validator (gleiche Regeln: StudyCatalogValidator.swift, Faelle in fixtures/study-catalog/validator-cases.json)
# ----------------------------------------------------------------------------

ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
TEXT_KEYS = ("content", "goals", "literature")


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _is_int(v) -> bool:
    return _is_num(v) and float(v) == int(v)


def validate(c) -> list[str]:
    """Fehler als 'pfad: code' (required, type, enum, range, format, unique, ref, forbidden, too_long), feste Reihenfolge"""
    errs: list[str] = []
    if not isinstance(c, dict):
        return [": type"]

    def text(path, v, nullable=False, min1=True):
        if v is None:
            if not nullable:
                errs.append(f"{path}: required")
            return
        if not isinstance(v, str):
            errs.append(f"{path}: type")
        elif min1 and not v:
            errs.append(f"{path}: range")
        elif len(v) > MAX_TEXT:
            errs.append(f"{path}: too_long")

    def number(path, v, lo=None, hi=None, integer=False, nullable=True, exclusive=False):
        if v is None:
            if not nullable:
                errs.append(f"{path}: required")
            return
        if not (_is_int(v) if integer else _is_num(v)):
            errs.append(f"{path}: type")
        elif (lo is not None and (v <= lo if exclusive else v < lo)) or (hi is not None and v > hi):
            errs.append(f"{path}: range")

    if c.get("v") != 1 or isinstance(c.get("v"), bool):
        errs.append("v: " + ("required" if "v" not in c else "enum"))
    for k in ("university", "program", "degree", "po"):
        text(k, c.get(k))
    t = c.get("catalog_term")
    if t is None:
        errs.append("catalog_term: required")
    elif not isinstance(t, str) or not TERM_RE.match(t):
        errs.append("catalog_term: format")
    if "code" not in c:
        errs.append("code: required")
    else:
        text("code", c.get("code"), nullable=True)
    number("regular_semesters", c.get("regular_semesters"), 1, 20, integer=True)
    number("total_lp", c.get("total_lp"), 0, exclusive=True)
    src = c.get("source")
    if not isinstance(src, dict):
        errs.append("source: " + ("required" if src is None else "type"))
    else:
        u = src.get("url")
        if u is None:
            errs.append("source.url: required")
        elif not isinstance(u, str) or not u.startswith("https://"):
            errs.append("source.url: format")
        if src.get("fetched_at") is not None and not isinstance(src.get("fetched_at"), str):
            errs.append("source.fetched_at: type")
        sha = src.get("sha256")
        if sha is not None and (not isinstance(sha, str) or not SHA_RE.match(sha)):
            errs.append("source.sha256: format")
    if "module_texts" in c:
        errs.append("module_texts: forbidden")

    areas = c.get("areas")
    area_ids: set = set()
    if not isinstance(areas, list):
        errs.append("areas: " + ("required" if areas is None else "type"))
        areas = []
    for i, a in enumerate(areas):
        p = f"areas[{i}]"
        if not isinstance(a, dict):
            errs.append(f"{p}: type")
            continue
        aid = a.get("id")
        if aid is None:
            errs.append(f"{p}.id: required")
        elif not isinstance(aid, str) or not ID_RE.match(aid):
            errs.append(f"{p}.id: format")
        elif aid in area_ids:
            errs.append(f"{p}.id: unique")
        else:
            area_ids.add(aid)
        text(f"{p}.name", a.get("name"))
        number(f"{p}.lp_required", a.get("lp_required"), 0)
        number(f"{p}.lp_max", a.get("lp_max"), 0)
        if _is_num(a.get("lp_required")) and _is_num(a.get("lp_max")) and a["lp_max"] < a["lp_required"]:
            errs.append(f"{p}.lp_max: range")
        if a.get("kind") not in KINDS:
            errs.append(f"{p}.kind: " + ("required" if a.get("kind") is None else "enum"))

    modules = c.get("modules")
    if not isinstance(modules, list):
        errs.append("modules: " + ("required" if modules is None else "type"))
        modules = []
    module_ids = {m.get("id") for m in modules if isinstance(m, dict) and isinstance(m.get("id"), str)}
    seen: set = set()
    for i, m in enumerate(modules):
        p = f"modules[{i}]"
        if not isinstance(m, dict):
            errs.append(f"{p}: type")
            continue
        mid = m.get("id")
        if mid is None:
            errs.append(f"{p}.id: required")
        elif not isinstance(mid, str) or not ID_RE.match(mid):
            errs.append(f"{p}.id: format")
        elif mid in seen:
            errs.append(f"{p}.id: unique")
        else:
            seen.add(mid)
        text(f"{p}.title", m.get("title"))
        text(f"{p}.code", m.get("code"), nullable=True)
        area = m.get("area")
        if area is not None and (not isinstance(area, str) or area not in area_ids):
            errs.append(f"{p}.area: ref")
        if m.get("kind") not in KINDS:
            errs.append(f"{p}.kind: " + ("required" if m.get("kind") is None else "enum"))
        if "lp" not in m:
            errs.append(f"{p}.lp: required")
        else:
            number(f"{p}.lp", m.get("lp"), 0)
        number(f"{p}.semester", m.get("semester"), 1, 20, integer=True)
        if m.get("turnus") not in TURNUS:
            errs.append(f"{p}.turnus: " + ("required" if m.get("turnus") is None else "enum"))
        text(f"{p}.exam", m.get("exam"), nullable=True)
        text(f"{p}.coursework", m.get("coursework"), nullable=True)
        pre = m.get("prerequisites")
        if not isinstance(pre, list):
            errs.append(f"{p}.prerequisites: " + ("required" if pre is None else "type"))
        else:
            for j, r in enumerate(pre):
                if not isinstance(r, str):
                    errs.append(f"{p}.prerequisites[{j}]: type")
                elif r == mid or r not in module_ids:
                    errs.append(f"{p}.prerequisites[{j}]: ref")
        text(f"{p}.language", m.get("language"), nullable=True)
        number(f"{p}.workload_h", m.get("workload_h"), 0)
        number(f"{p}.source_page", m.get("source_page"), 1, integer=True)
        for k in TEXT_KEYS:
            if k in m:
                errs.append(f"{p}.{k}: forbidden")

    # Studienverlaufsplan (optional): Quelle und Plaetze fuer Wahlmodule je Semester
    sp = c.get("study_plan")
    if sp is not None:
        if not isinstance(sp, dict):
            errs.append("study_plan: type")
        else:
            u = sp.get("url")
            if u is None:
                errs.append("study_plan.url: required")
            elif not isinstance(u, str) or not u.startswith("https://"):
                errs.append("study_plan.url: format")
            if sp.get("fetched_at") is not None and not isinstance(sp.get("fetched_at"), str):
                errs.append("study_plan.fetched_at: type")
            sha = sp.get("sha256")
            if sha is not None and (not isinstance(sha, str) or not SHA_RE.match(sha)):
                errs.append("study_plan.sha256: format")
    slots = c.get("plan_slots")
    if slots is not None:
        if not isinstance(slots, list):
            errs.append("plan_slots: type")
            slots = []
        for i, s in enumerate(slots):
            p = f"plan_slots[{i}]"
            if not isinstance(s, dict):
                errs.append(f"{p}: type")
                continue
            number(f"{p}.semester", s.get("semester"), 1, 20, integer=True, nullable=False)
            text(f"{p}.title", s.get("title"))
            ar = s.get("areas")
            if not isinstance(ar, list):
                errs.append(f"{p}.areas: " + ("required" if ar is None else "type"))
            else:
                for j, a in enumerate(ar):
                    if not isinstance(a, str):
                        errs.append(f"{p}.areas[{j}]: type")
                    elif a not in area_ids:
                        errs.append(f"{p}.areas[{j}]: ref")
            number(f"{p}.lp", s.get("lp"), 0)
            number(f"{p}.lp_max", s.get("lp_max"), 0)
            if _is_num(s.get("lp")) and _is_num(s.get("lp_max")) and s["lp_max"] < s["lp"]:
                errs.append(f"{p}.lp_max: range")
    return errs


def shareable(c: dict) -> dict:
    """Nur die geteilten Fakten (ohne module_texts und Modultexte), fuer die Bibliothek"""
    out = {k: v for k, v in c.items() if k != "module_texts"}
    out["modules"] = [{k: v for k, v in m.items() if k not in TEXT_KEYS} for m in c.get("modules") or []]
    return out


# ----------------------------------------------------------------------------
# Lokale Tabellen
# ----------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS study_catalogs (
    catalog_key TEXT PRIMARY KEY,          -- sha256("luh|TIBSc22|WS 2025/26")
    university TEXT NOT NULL,
    code TEXT NOT NULL,
    catalog_term TEXT NOT NULL,
    program TEXT,
    po TEXT,
    payload TEXT NOT NULL,                 -- geteilte Fakten (study-catalog.schema.json)
    origin TEXT NOT NULL,                  -- download | library | fixture
    source_url TEXT,
    sha256 TEXT,
    fetched_at TEXT,
    stored_at TEXT
);
CREATE TABLE IF NOT EXISTS study_module_texts (
    catalog_key TEXT NOT NULL,
    module_id TEXT NOT NULL,
    content TEXT,
    goals TEXT,
    literature TEXT,
    PRIMARY KEY (catalog_key, module_id)
);
CREATE TABLE IF NOT EXISTS study_catalog_state (key TEXT PRIMARY KEY, value TEXT);
"""


def ensure_schema(conn) -> None:
    conn.executescript(SCHEMA)


def _has_tables(conn) -> bool:
    return db.row(conn, "SELECT 1 AS x FROM sqlite_master WHERE type='table' AND name='study_catalogs'") is not None


def store_catalog(conn, catalog: dict, texts: dict | None, origin: str, now: str) -> str:
    """Katalog speichern (vorhandener Schluessel: ersetzt, die Texte nur, wenn neue mitkommen)"""
    ensure_schema(conn)
    key = catalog_key(catalog)
    src = catalog.get("source") or {}
    conn.execute("INSERT OR REPLACE INTO study_catalogs(catalog_key, university, code, catalog_term, program, po, payload, "
                 "origin, source_url, sha256, fetched_at, stored_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                 (key, catalog.get("university"), catalog.get("code") or "", catalog.get("catalog_term"),
                  catalog.get("program"), catalog.get("po"), dumps(shareable(catalog)), origin, src.get("url"),
                  src.get("sha256"), src.get("fetched_at"), now))
    if texts:
        conn.execute("DELETE FROM study_module_texts WHERE catalog_key=?", (key,))
        conn.executemany("INSERT INTO study_module_texts(catalog_key, module_id, content, goals, literature) VALUES (?,?,?,?,?)",
                         [(key, mid, t.get("content"), t.get("goals"), t.get("literature")) for mid, t in texts.items()])
    return key


def get_catalog(conn, key: str) -> dict | None:
    if not _has_tables(conn):
        return None
    r = db.row(conn, "SELECT payload FROM study_catalogs WHERE catalog_key=?", (key,))
    if not r:
        return None
    try:
        return json.loads(r["payload"])
    except ValueError:
        return None


def get_state(conn, key: str):
    if not _has_tables(conn):
        return None
    r = db.row(conn, "SELECT value FROM study_catalog_state WHERE key=?", (key,))
    if not r:
        return None
    try:
        return json.loads(r["value"])
    except ValueError:
        return None


def set_state(conn, key: str, value) -> None:
    ensure_schema(conn)
    conn.execute("INSERT OR REPLACE INTO study_catalog_state(key, value) VALUES (?, ?)", (key, dumps(value)))


# ----------------------------------------------------------------------------
# Abgleich
# ----------------------------------------------------------------------------

MESSAGES = {
    "searching": "StudiNow sucht den Modulkatalog deines Studiengangs …",
    "no_program": "Noch kein Studiengang bekannt. Verbinde QIS oder wähle deine Prüfungsordnung.",
    "not_found": "Für deinen Studiengang gibt es noch keinen Katalog.",
    "ready": "Modulkatalog geladen",
    "library": "Aus der Bibliothek übernommen",
    "error_download": "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut.",
    "error_parse": "Der Modulkatalog ließ sich nicht lesen. StudiNow versucht es in 24 Stunden erneut.",
    "seed": "Aus dem StudiNow-Grundstock",
    "unknown_format": "Das Format dieses Modulhandbuchs kennt StudiNow noch nicht. Der Link ist gespeichert.",
}
MODKAT_URL_RE = re.compile(r"/modkat-(?:full-)?([A-Za-z0-9_-]+)-(WS_([0-9]{4})_([0-9]{2})|SS_([0-9]{4}))\.pdf$")


def clean_catalog_url(raw) -> str | None:
    """Eigener Link zum Modulhandbuch (settings.study_plan.catalog_url): nur https, hoechstens 500 Zeichen, ohne
    Leerraum (gleich StudyCatalogPipeline.cleanCatalogURL)"""
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s or len(s) > 500 or not s.lower().startswith("https://") or any(c.isspace() for c in s):
        return None
    from urllib.parse import urlsplit
    try:
        host = urlsplit(s).hostname
    except ValueError:
        return None
    return s if host else None


def modkat_parts(url: str) -> tuple[str, str] | None:
    """'.../modkat-TIBSc22-WS_2025_26.pdf' -> ('TIBSc22', 'WS 2025/26'), '.../modkat-full-TIBSc25-WS_2026_27.pdf' ->
    ('TIBSc25', 'WS 2026/27')"""
    m = MODKAT_URL_RE.search(url or "")
    if not m:
        return None
    if m.group(3):
        return m.group(1), f"WS {m.group(3)}/{m.group(4)}"
    return m.group(1), f"SS {m.group(5)}"


class FetchResult:
    """Antwort des Ladens: status 200 (data, etag, last_modified), 304, 404 oder 0 (Netzfehler, error)"""

    def __init__(self, status: int, data: bytes = b"", etag: str | None = None, last_modified: str | None = None,
                 error: str | None = None) -> None:
        self.status, self.data, self.etag, self.last_modified, self.error = status, data, etag, last_modified, error


def urllib_fetch(url: str, etag: str | None = None, last_modified: str | None = None) -> FetchResult:
    """Einfaches HTTPS-GET ohne Cookies, mit If-None-Match/If-Modified-Since"""
    headers = {"User-Agent": USER_AGENT}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310 - nur https-URLs aus dem Register
            return FetchResult(r.status, r.read(), r.headers.get("ETag"), r.headers.get("Last-Modified"))
    except urllib.error.HTTPError as e:
        return FetchResult(e.code, error=f"HTTP {e.code}")
    except Exception as e:  # noqa: BLE001
        return FetchResult(0, error=str(e)[:200])


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s) -> datetime | None:
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def qis_label(conn) -> str | None:
    """Haeufigster QIS-Studiengang (`grades.abschluss`), bei Gleichstand der zuerst gespeicherte"""
    rows = db.rows(conn, "SELECT abschluss FROM grades WHERE abschluss IS NOT NULL AND trim(abschluss) <> '' ORDER BY id")
    counts: dict = {}
    for r in rows:
        counts[r["abschluss"].strip()] = counts.get(r["abschluss"].strip(), 0) + 1
    if not counts:
        return None
    best = max(counts.values())
    return next(k for k, v in counts.items() if v == best)


def plan_settings(conn) -> dict:
    r = db.row(conn, "SELECT value FROM settings WHERE key='study_plan'")
    try:
        v = json.loads(r["value"]) if r and r["value"] else {}
    except ValueError:
        v = {}
    return v if isinstance(v, dict) else {}


def attach_study_plan(conn, catalog: dict, src: dict, fetch, now: datetime, force: bool = False) -> tuple[dict, dict]:
    """Studienverlaufsplan einmal laden (wie der Katalog: ohne Cookies, ETag/304, 404 wird 30 Tage gemerkt, Fehler
    erst nach 24 Stunden erneut), lesen, in `study_catalog_state` ablegen (`plan:<url>`) und in den Katalog mischen.
    Ergebnis: (Katalog, Stand {state: merged|missing|error, url, entries, slots, unmatched, error})."""
    url = src["url"]
    info: dict = {"url": url}
    miss = _parse_iso((get_state(conn, "missing:" + url) or {}).get("at"))
    if miss and now - miss < timedelta(days=MISSING_DAYS):
        return catalog, dict(info, state="missing")
    attempt = get_state(conn, "plan_attempt:" + url) or {}
    at = _parse_iso(attempt.get("at"))
    if not force and at and now - at < timedelta(hours=RETRY_HOURS) and attempt.get("error"):
        return catalog, dict(info, state="error", error=attempt.get("error"))
    stored = get_state(conn, "plan:" + url)
    have = isinstance(stored, dict) and isinstance(stored.get("plan"), dict) and isinstance(stored.get("source"), dict)
    cache = get_state(conn, "http:" + url) or {}

    def fail(error: str) -> tuple[dict, dict]:
        set_state(conn, "plan_attempt:" + url, {"at": _iso(now), "error": error})
        return catalog, dict(info, state="error", error=error)

    r = fetch(url, cache.get("etag") if have else None, cache.get("last_modified") if have else None)
    if r.status == 404:
        set_state(conn, "missing:" + url, {"at": _iso(now)})
        return catalog, dict(info, state="missing")
    if r.status == 304 and have:
        plan, source = stored["plan"], stored["source"]
    elif r.status == 200:
        try:
            plan = parse_study_plan(pdf_items(r.data))
        except Exception:  # noqa: BLE001
            plan = {"entries": [], "footnote": None}
        if not plan["entries"]:
            return fail("keine Module im Studienverlaufsplan")
        source = {"url": url, "fetched_at": _iso(now), "sha256": hashlib.sha256(r.data).hexdigest()}
        set_state(conn, "plan:" + url, {"plan": plan, "source": source})
        set_state(conn, "http:" + url, {"etag": r.etag, "last_modified": r.last_modified})
    else:
        return fail(r.error or f"HTTP {r.status}")
    merged, unmatched = merge_study_plan(catalog, plan, source)
    errors = validate(merged)
    if errors:
        return fail("; ".join(errors[:5]))
    return merged, dict(info, state="merged", entries=len(plan["entries"]), slots=len(merged["plan_slots"]),
                        unmatched=unmatched)


def _ensure_plan(conn, key: str, registry: dict, university: str, code: str, fetch, now: datetime,
                 force: bool = False) -> dict | None:
    """Gespeicherter Katalog ohne Verlaufsplan (aelterer Stand): Plan einmal nachladen und mischen"""
    src = study_plan_source(registry, university, code)
    cat = get_catalog(conn, key)
    if not src or cat is None or isinstance(cat.get("study_plan"), dict):
        return None
    merged, info = attach_study_plan(conn, cat, src, fetch, now, force)
    if info["state"] == "merged":
        r = db.row(conn, "SELECT origin FROM study_catalogs WHERE catalog_key=?", (key,))
        store_catalog(conn, merged, None, (r or {}).get("origin") or "download", _iso(now))
    return info


SEED_DIR = ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed"


SEED_UNIVERSITIES = ("luh", "hildesheim", "hsh")


def current_university(conn) -> str:
    """Hochschule des Abgleichs: settings.university, sonst die der laufenden App (UNIVERSITY in der .env), sonst luh"""
    v = (db.row(conn, "SELECT value FROM settings WHERE key='university'") or {}).get("value")
    if v:
        return v
    try:
        from . import universities
        return universities.current_key()
    except Exception:  # noqa: BLE001
        return "luh"


def load_seed(directory: Path | None = None) -> dict:
    """Grundstock der App (tools/build-luh-seed.py, tools/build-hildesheim-seed.py): {Bibliotheksschluessel: Katalog}
    aller Hochschulen (Schluessel enthalten die Hochschule); leer ohne Ressource"""
    import gzip
    out: dict = {}
    files = sorted({f for u in SEED_UNIVERSITIES for f in (directory or SEED_DIR).glob(f"{u}*.json.gz")})
    for f in files:
        try:
            data = json.loads(gzip.decompress(f.read_bytes()))
        except (OSError, ValueError):
            continue
        for c in data.get("catalogs") or []:
            if isinstance(c, dict):
                out[catalog_key(c)] = c
    return out


def seed_terms(seed: dict, university: str, code: str) -> list[str]:
    """Katalogsemester des Grundstocks zum Kuerzel, neueste zuerst"""
    terms = {c.get("catalog_term") for c in seed.values() if c.get("university") == university and c.get("code") == code}
    return sorted((t for t in terms if term_number(t)), key=term_number, reverse=True)


def run_sync(conn, fetch=urllib_fetch, now: datetime | None = None, university: str | None = None,
             registry: dict | None = None, force: bool = False, seed: dict | None = None) -> dict:
    """Ein Abgleich (am PC ohne Bibliothek): Studiengang -> Schluessel -> lokal -> Grundstock (`seed`, wie
    StudyCatalogPipeline; ohne Angabe keiner) -> laden -> lesen -> speichern.
    Ergebnis ist der neue Stand (auch in study_catalog_state 'status')."""
    now = now or datetime.now(timezone.utc)
    reg = registry or load_registry()
    uni = university or current_university(conn)
    settings = plan_settings(conn)
    label = qis_label(conn)
    base = {"checked_at": _iso(now), "qis_label": label, "inputs": inputs(conn)}
    custom = clean_catalog_url(settings.get("catalog_url"))
    if custom:
        return _run_custom(conn, custom, fetch, now, uni, reg, base, force)
    po = str(settings.get("po") or "").strip() or None
    suggestion = match_program(label or "", uni, reg, po) if label else None
    if suggestion is None and po:
        found = program_entry(reg, uni, po)
        if found:
            _, p, x = found
            suggestion = {"university": uni, "program_id": p.get("id"), "program": p.get("program"), "degree": p.get("degree"),
                          "po": str(x.get("po")), "code": x.get("code"), "qis_label": label, "qis_po": None,
                          "needs_confirmation": False}
    if suggestion is None:
        state = dict(base, state="not_found", reason="no_program" if not label else "no_source",
                     message=MESSAGES["no_program" if not label else "not_found"])
        set_state(conn, "status", state)
        return state
    base.update({k: suggestion[k] for k in ("program", "degree", "po", "code", "needs_confirmation")})
    base["suggested_po"] = suggestion["po"]
    terms = candidate_terms(reg, uni, suggestion["code"], now.strftime("%Y-%m-%d"))
    seed = seed or {}
    terms = terms + [t for t in seed_terms(seed, uni, suggestion["code"]) if t not in terms]
    terms = [t for _, t in sorted(enumerate(terms), key=lambda x: (-(term_number(x[1]) or 0), x[0]))]
    entry = program_entry(reg, uni, suggestion["code"])
    last_error = None
    for term in terms:
        key = library_key(uni, suggestion["code"], term)
        info = dict(base, catalog_term=term, key=key)
        if not force and get_catalog(conn, key) is not None:
            plan_info = _ensure_plan(conn, key, reg, uni, suggestion["code"], fetch, now)
            state = dict(info, state="ready", origin="local", message=MESSAGES["ready"],
                         modules=len((get_catalog(conn, key) or {}).get("modules") or []))
            if plan_info:
                state["study_plan"] = plan_info
            set_state(conn, "status", state)
            return state
        hit = seed.get(key) if get_catalog(conn, key) is None else None
        if isinstance(hit, dict) and catalog_key(hit) == key and not validate(hit) and hit.get("modules"):
            store_catalog(conn, hit, None, "seed", _iso(now))
            plan_info = _ensure_plan(conn, key, reg, uni, suggestion["code"], fetch, now)
            state = dict(info, state="seed", origin="seed", message=MESSAGES["seed"], modules=len(hit["modules"]))
            if plan_info:
                state["study_plan"] = plan_info
            set_state(conn, "status", state)
            return state
        attempt = get_state(conn, "attempt:" + key) or {}
        at = _parse_iso(attempt.get("at"))
        if not force and at and now - at < timedelta(hours=RETRY_HOURS) and attempt.get("error"):
            state = dict(info, state="error", error=attempt.get("error"), message=attempt.get("message"),
                         retry_at=_iso(at + timedelta(hours=RETRY_HOURS)))
            set_state(conn, "status", state)
            return state
        result, used = None, None
        missing = 0
        urls = source_urls(reg, uni, suggestion["code"], term)
        if not urls:                          # nur im Grundstock der App (luh-grundstock): hier nichts zu laden
            if get_catalog(conn, key) is not None:
                state = dict(info, state="ready", origin="local", message=MESSAGES["ready"],
                             modules=len((get_catalog(conn, key) or {}).get("modules") or []))
                set_state(conn, "status", state)
                return state
            continue
        for url in urls:
            miss = _parse_iso((get_state(conn, "missing:" + url) or {}).get("at"))
            if miss and now - miss < timedelta(days=MISSING_DAYS):
                missing += 1
                continue
            cache = get_state(conn, "http:" + url) or {}
            have = get_catalog(conn, key) is not None
            r = fetch(url, cache.get("etag") if have else None, cache.get("last_modified") if have else None)
            if r.status == 404:
                set_state(conn, "missing:" + url, {"at": _iso(now)})
                missing += 1
                continue
            if r.status in (200, 304):
                result, used = r, url
                break
            last_error = r.error or f"HTTP {r.status}"
        if result is None:
            if missing and last_error is None:
                continue                      # dieses Semester gibt es (noch) nicht: das naechste versuchen
            msg = MESSAGES["error_download"]
            set_state(conn, "attempt:" + key, {"at": _iso(now), "error": last_error or "download", "message": msg})
            state = dict(info, state="error", error=last_error or "download", message=msg,
                         retry_at=_iso(now + timedelta(hours=RETRY_HOURS)))
            set_state(conn, "status", state)
            return state
        if result.status == 304:
            plan_info = _ensure_plan(conn, key, reg, uni, suggestion["code"], fetch, now, force)
            state = dict(info, state="ready", origin="local", message=MESSAGES["ready"])
            if plan_info:
                state["study_plan"] = plan_info
            set_state(conn, "status", state)
            return state
        try:
            _, prog, _po = entry
            meta = {"university": uni, "program": prog.get("program"), "degree": prog.get("degree"),
                    "po": str(_po.get("po")), "code": suggestion["code"], "catalog_term": term,
                    "regular_semesters": prog.get("regular_semesters"), "total_lp": prog.get("total_lp"),
                    "source": {"url": used, "fetched_at": _iso(now), "sha256": hashlib.sha256(result.data).hexdigest()}}
            catalog, texts = parse_luh_modkat(pdf_pages(result.data), meta)
            errors = validate(catalog)
            if errors or not catalog["modules"]:
                raise ValueError("; ".join(errors[:5]) or "keine Module gefunden")
        except Exception as e:  # noqa: BLE001
            msg = MESSAGES["error_parse"]
            set_state(conn, "attempt:" + key, {"at": _iso(now), "error": str(e)[:200], "message": msg})
            state = dict(info, state="error", error=str(e)[:200], message=msg, retry_at=_iso(now + timedelta(hours=RETRY_HOURS)))
            set_state(conn, "status", state)
            return state
        # Studienverlaufsplan dazu (eigene Quelle im Register), vor dem Speichern gemischt
        plan_info = None
        plan_src = study_plan_source(reg, uni, suggestion["code"])
        if plan_src:
            catalog, plan_info = attach_study_plan(conn, catalog, plan_src, fetch, now, force)
        store_catalog(conn, catalog, texts, "download", _iso(now))
        set_state(conn, "http:" + used, {"etag": result.etag, "last_modified": result.last_modified})
        state = dict(info, state="ready", origin="download", message=MESSAGES["ready"], modules=len(catalog["modules"]),
                     source_url=used)
        if plan_info:
            state["study_plan"] = plan_info
        set_state(conn, "status", state)
        return state
    state = dict(base, state="not_found", reason="no_catalog", message=MESSAGES["not_found"])
    set_state(conn, "status", state)
    return state


def _run_custom(conn, url: str, fetch, now: datetime, uni: str, reg: dict, base: dict, force: bool) -> dict:
    """Eigener Link: einmal laden (Fehler erst nach 24 Stunden erneut), mit dem LUH-Parser lesen, sonst 'Format
    unbekannt'. Kopf aus dem Register (modkat-Link mit bekanntem Kuerzel), sonst aus der Titelseite."""
    url_key = "url:" + url
    info = dict(base, catalog_url=url, origin_kind="custom")
    prev = get_state(conn, url_key) or {}
    if not force and prev.get("key") and get_catalog(conn, prev["key"]) is not None:
        state = dict(info, state="ready", origin="local", key=prev["key"], message=MESSAGES["ready"])
        set_state(conn, "status", state)
        return state
    at = _parse_iso(prev.get("at"))
    if not force and at and now - at < timedelta(hours=RETRY_HOURS) and prev.get("error"):
        state = dict(info, state="error", error=prev.get("error"), reason=prev.get("reason"), message=prev.get("message"),
                     retry_at=_iso(at + timedelta(hours=RETRY_HOURS)))
        set_state(conn, "status", state)
        return state

    def fail(error: str, reason: str, msg: str) -> dict:
        set_state(conn, url_key, {"at": _iso(now), "error": error, "reason": reason, "message": msg})
        state = dict(info, state="error", error=error, reason=reason, message=msg, retry_at=_iso(now + timedelta(hours=RETRY_HOURS)))
        set_state(conn, "status", state)
        return state

    r = fetch(url, None, None)
    if r.status != 200:
        return fail(r.error or f"HTTP {r.status}", "download", MESSAGES["error_download"])
    try:
        pages = pdf_pages(r.data)
    except Exception:  # noqa: BLE001
        return fail("keine PDF", "unknown_format", MESSAGES["unknown_format"])
    parts = modkat_parts(url)
    first = clean_pages(pages[:1])
    lines = first[0] if first else []
    entry = program_entry(reg, uni, parts[0]) if parts else None
    if parts and entry:
        _, prog, po = entry
        meta = {"university": uni, "program": prog.get("program"), "degree": prog.get("degree"), "po": str(po.get("po")),
                "code": parts[0], "catalog_term": parts[1], "regular_semesters": prog.get("regular_semesters"),
                "total_lp": prog.get("total_lp")}
    else:
        i = lines.index("für den Studiengang") if "für den Studiengang" in lines else None
        program_line = lines[i + 1] if i is not None and i + 1 < len(lines) else "Eigener Katalog"
        degree = "M.Sc." if "Master" in program_line else ("B.Sc." if "Bachelor" in program_line else "unbekannt")
        code = parts[0] if parts else "link-" + hashlib.sha256(url.encode()).hexdigest()[:12]
        term = parts[1] if parts else (term_from_title(" ".join(lines)) or current_term(now.strftime("%Y-%m-%d")))
        meta = {"university": uni, "program": program_line.split(" - ")[0].strip(" "), "degree": degree, "po": "eigener Link",
                "code": code, "catalog_term": term, "regular_semesters": None, "total_lp": None}
    meta["source"] = {"url": url, "fetched_at": _iso(now), "sha256": hashlib.sha256(r.data).hexdigest()}
    catalog, texts = parse_luh_modkat(pages, meta)
    if not catalog["modules"] or validate(catalog):
        return fail("Format unbekannt", "unknown_format", MESSAGES["unknown_format"])
    key = store_catalog(conn, catalog, texts, "download", _iso(now))
    set_state(conn, url_key, {"at": _iso(now), "key": key})
    state = dict(info, state="ready", origin="download", key=key, program=meta["program"], code=meta["code"],
                 catalog_term=meta["catalog_term"], modules=len(catalog["modules"]), message=MESSAGES["ready"])
    set_state(conn, "status", state)
    return state


def status(conn) -> dict:
    """GET /api/study-catalog/status: letzter Stand; ohne Lauf 'idle' oder 'ready', wenn schon ein Katalog da ist"""
    s = get_state(conn, "status")
    if isinstance(s, dict):
        return s
    if _has_tables(conn) and db.row(conn, "SELECT 1 AS x FROM study_catalogs LIMIT 1"):
        return {"state": "ready", "origin": "local", "message": MESSAGES["ready"]}
    return {"state": "idle", "message": "Der Modulkatalog wurde noch nicht gesucht."}


# ----------------------------------------------------------------------------
# Ausloeser am PC und im Dienst (Web/Windows, 05.11.2026)
# ----------------------------------------------------------------------------
# Auf dem iPad stoesst der Kern die Suche an (StudyCatalogTriggers). Hier tut das `GET /api/study-catalog/status`: noch nie
# gesucht, Stand nicht abgeschlossen, Wiederholung faellig oder Eingaben geaendert (QIS-Studiengang, PO, eigener Link)
# -> Suche im Hintergrund (eigener Thread mit Nutzerkontext), Stand sofort "searching". Der Grundstock (App-Ressource
# StudyCatalogSeed) wird gelesen, bevor etwas geladen wird.

FETCH = urllib_fetch                    # Tests setzen eine Attrappe (kein echtes Netz)
AUTO_SYNC = os.environ.get("LERNAPP_NO_SCHEDULER") != "1"      # Tests: aus; einzelne Tests schalten ein
BUSY_STATES = ("searching", "downloading", "parsing")
SETTLED_STATES = ("ready", "library", "seed", "error", "not_found", "idle")
BUSY_SECONDS = 600                      # ein Zwischenstand aelter als 10 Minuten gilt als abgebrochen
_lock = threading.Lock()
_active: set = set()
_seed_cache: dict | None = None


def seed_cached() -> dict:
    """Grundstock einmal je Prozess lesen (rund 0,4 s)"""
    global _seed_cache
    if _seed_cache is None:
        _seed_cache = load_seed()
    return _seed_cache


def inputs(conn) -> str:
    """Fingerabdruck der Eingaben eines Laufs: QIS-Studiengang, PO und eigener Link (steht im Stand als `inputs`)"""
    s = plan_settings(conn)
    po = s.get("po") if isinstance(s.get("po"), str) else None
    return json.dumps([qis_label(conn), po, clean_catalog_url(s.get("catalog_url"))], ensure_ascii=False, separators=(",", ":"))


def due(conn, now: datetime) -> bool:
    """Soll die Suche (wieder) anlaufen? Gleiche Regel wie StudyCatalogEndpoints im Kern"""
    raw = get_state(conn, "status")
    st = status(conn)
    state = st.get("state")
    started = _parse_iso(st.get("checked_at"))
    if state in BUSY_STATES and started and (now - started).total_seconds() < BUSY_SECONDS:
        return False
    retry = _parse_iso(st.get("retry_at"))
    retry_due = state == "error" and retry is not None and retry <= now
    return (not isinstance(raw, dict)) or state not in SETTLED_STATES or retry_due or st.get("inputs") != inputs(conn)


def _run_key() -> tuple:
    from . import config
    return (config.current_user_id() or "", str(config.db_path() if config.current_user_id() else db.DB_PATH))


def _run_once(force: bool, fetch, seed, now) -> dict | None:
    try:
        with db.cursor() as conn:
            return run_sync(conn, fetch=fetch or FETCH, now=now, force=force, seed=seed if seed is not None else seed_cached())
    except Exception as e:  # noqa: BLE001 - die Suche darf die Anfrage nie zu Fall bringen
        at = now or datetime.now(timezone.utc)
        with db.cursor() as conn:
            set_state(conn, "status", {"state": "error", "error": str(e)[:200], "message": MESSAGES["error_parse"],
                                       "checked_at": _iso(at), "retry_at": _iso(at + timedelta(hours=RETRY_HOURS)),
                                       "inputs": inputs(conn)})
        return None


def maybe_start(conn, force: bool = False, now: datetime | None = None, fetch=None, seed=None, background: bool = True) -> dict | None:
    """Suche anstossen, wenn sie faellig ist (oder `force`); nie zwei zugleich je Konto. Gibt den neuen Zwischenstand
    ("searching") zurueck, sonst None. `background=False` laeuft in dieser Anfrage und gibt den Endstand zurueck (Tests)."""
    now = now or datetime.now(timezone.utc)
    if not force and not due(conn, now):
        return None
    key = _run_key()
    with _lock:
        if key in _active:
            return None
        _active.add(key)
    try:
        prev = get_state(conn, "status")
        state = dict(prev) if isinstance(prev, dict) else {}
        state.update(state="searching", message=MESSAGES["searching"], checked_at=_iso(now), inputs=inputs(conn))
        state.pop("error", None)
        state.pop("retry_at", None)
        set_state(conn, "status", state)
        conn.commit()                       # der Lauf (anderer Thread, andere Verbindung) sieht den Zwischenstand
    except Exception:
        with _lock:
            _active.discard(key)
        raise
    ctx = contextvars.copy_context()

    def work():
        try:
            ctx.run(_run_once, force, fetch, seed, now)
        finally:
            with _lock:
                _active.discard(key)

    if not background:
        work()
        return get_state(conn, "status")
    threading.Thread(target=work, daemon=True, name="study-catalog").start()
    return state


def start_if_needed(force: bool = False) -> bool:
    """Fuer Aufrufer ausserhalb einer Anfrage (nach dem QIS-Abruf am PC): leise, Fehler stoeren nie"""
    if not AUTO_SYNC:
        return False
    try:
        with db.cursor() as conn:
            return maybe_start(conn, force=force) is not None
    except Exception:  # noqa: BLE001
        return False


# ----------------------------------------------------------------------------
# Modultexte nachladen (nur auf dem eigenen PC, nie geteilt)
# ----------------------------------------------------------------------------

def text_count(conn, key: str) -> int:
    if not _has_tables(conn):
        return 0
    return (db.row(conn, "SELECT COUNT(*) AS n FROM study_module_texts WHERE catalog_key=?", (key,)) or {"n": 0})["n"]


def texts_wanted(conn, key: str, now: datetime | None = None) -> bool:
    """Katalog ohne lokale Texte, Quelle ein modkat-Link, noch nicht geladen und keine laufende Pause. Im Dienst
    (hosted) nie: Texte sollen auf dem Geraet der Person bleiben (Swift: `StudyCatalogPipeline.textsWanted`)."""
    from . import config
    if config.is_hosted():
        return False
    now = now or datetime.now(timezone.utc)
    cat = get_catalog(conn, key)
    src = cat.get("source") if isinstance(cat, dict) and isinstance(cat.get("source"), dict) else {}
    if not cat or text_count(conn, key) or not modkat_parts(src.get("url") or ""):
        return False
    prev = get_state(conn, "texts:" + key) or {}
    at = _parse_iso(prev.get("at"))
    kind = prev.get("state")
    if kind in ("loaded", "unsupported"):
        return False
    if kind == "missing":
        return not (at and now - at < timedelta(days=MISSING_DAYS))
    if kind == "error":
        return not (at and now - at < timedelta(hours=RETRY_HOURS))
    return True


def load_texts(conn, key: str, fetch=None, now: datetime | None = None) -> dict:
    """Modultexte (Inhalt, Lernziele, Literatur) eines Katalogs aus Grundstock oder Bibliothek nachladen: die oeffentliche
    PDF der Quelle einmal laden (ohne Cookies, ETag), mit dem modkat-Leser lesen und nur die Texte ablegen; die Fakten
    bleiben, wie sie sind. Andere Formate (luh-grundstock) liest der PC nicht. Ergebnis: Stand
    {state: loaded|have|unsupported|missing|error|none}. Fehler: 24 Stunden Pause, 404: 30 Tage."""
    now = now or datetime.now(timezone.utc)
    cat = get_catalog(conn, key)
    if cat is None:
        return {"state": "none"}
    n = text_count(conn, key)
    if n:
        return {"state": "have", "modules": n}
    state_key = "texts:" + key
    prev = get_state(conn, state_key) or {}
    at = _parse_iso(prev.get("at"))

    def remember(v: dict) -> dict:
        set_state(conn, state_key, v)
        return v

    if prev.get("state") in ("loaded", "unsupported"):
        return prev
    if prev.get("state") == "missing" and at and now - at < timedelta(days=MISSING_DAYS):
        return prev
    if prev.get("state") == "error" and at and now - at < timedelta(hours=RETRY_HOURS):
        return prev
    src = cat.get("source") if isinstance(cat.get("source"), dict) else {}
    url = src.get("url")
    if not isinstance(url, str) or not url.startswith("https://") or not modkat_parts(url):
        return remember({"state": "unsupported", "at": _iso(now)})
    cache = get_state(conn, "http:" + url) or {}
    r = (fetch or FETCH)(url, cache.get("etag"), cache.get("last_modified"))
    if r.status == 404:
        return remember({"state": "missing", "at": _iso(now)})
    if r.status != 200:
        return remember({"state": "error", "at": _iso(now), "error": r.error or f"HTTP {r.status}"})
    try:
        meta = {"university": cat.get("university"), "program": cat.get("program"), "degree": cat.get("degree"),
                "po": str(cat.get("po")), "code": cat.get("code"), "catalog_term": cat.get("catalog_term"),
                "regular_semesters": cat.get("regular_semesters"), "total_lp": cat.get("total_lp"),
                "source": {"url": url, "fetched_at": _iso(now), "sha256": hashlib.sha256(r.data).hexdigest()}}
        parsed, all_texts = parse_luh_modkat(pdf_pages(r.data), meta)
    except Exception as e:  # noqa: BLE001
        return remember({"state": "error", "at": _iso(now), "error": str(e)[:200]})
    by_title: dict = {}
    for m in parsed.get("modules") or []:
        by_title.setdefault(name_key(m.get("title") or ""), m["id"])
    texts = {}
    for m in cat.get("modules") or []:
        pid = m["id"] if m["id"] in all_texts else by_title.get(name_key(m.get("title") or ""))
        if pid in all_texts:
            texts[m["id"]] = all_texts[pid]
    if not texts:
        return remember({"state": "error", "at": _iso(now), "error": "keine Modultexte"})
    conn.executemany("INSERT INTO study_module_texts(catalog_key, module_id, content, goals, literature) VALUES (?,?,?,?,?)",
                     [(key, mid, t.get("content"), t.get("goals"), t.get("literature")) for mid, t in texts.items()])
    set_state(conn, "http:" + url, {"etag": r.etag, "last_modified": r.last_modified})
    return remember({"state": "loaded", "at": _iso(now), "modules": len(texts), "sha256": hashlib.sha256(r.data).hexdigest()})


def start_texts(key: str, fetch=None, background: bool = True) -> bool:
    """Texte im Hintergrund nachladen (ein Lauf je Konto und Katalog); true, wenn einer laeuft oder anlief"""
    run_key = _run_key() + ("texts", key)
    with _lock:
        if run_key in _active:
            return True
        _active.add(run_key)
    ctx = contextvars.copy_context()

    def job():
        try:
            with db.cursor() as conn:
                load_texts(conn, key, fetch)
        except Exception:  # noqa: BLE001
            pass

    def work():
        try:
            ctx.run(job)
        finally:
            with _lock:
                _active.discard(run_key)

    if not background:
        work()
    else:
        threading.Thread(target=work, daemon=True, name="study-texts").start()
    return True


# ----------------------------------------------------------------------------
# Register zum Auswaehlen (Web): Studiengaenge mit Pruefungsordnungen
# ----------------------------------------------------------------------------

def programs(registry: dict | None = None, university: str = "luh", seed: dict | None = None) -> list[dict]:
    """Studiengaenge des Registers zur Auswahl: [{id, program, degree, faculty, pos: [{po, code, catalog_terms,
    loadable}]}] nach Name; Eintraege ohne Katalog haben `pos: []` (der Katalog fehlt noch). `loadable`: der PC kann
    den Katalog laden (modkat) oder er liegt im Grundstock."""
    reg = registry or load_registry()
    seed_codes = {c.get("code") for c in (seed or {}).values()}
    out = []
    for uni in reg.get("universities") or []:
        if uni.get("id") != university:
            continue
        sources = {s.get("id"): s for s in uni.get("sources") or []}
        for p in uni.get("programs") or []:
            pos = []
            for x in p.get("pos") or []:
                src = sources.get(x.get("source")) or {}
                pos.append({"po": str(x.get("po")), "code": x.get("code"), "catalog_terms": list(x.get("catalog_terms") or []),
                            "loadable": bool(src.get("url_pattern")) or x.get("code") in seed_codes})
            out.append({"id": p.get("id"), "program": p.get("program"), "degree": p.get("degree"), "faculty": p.get("faculty"),
                        "regular_semesters": p.get("regular_semesters"), "total_lp": p.get("total_lp"), "pos": pos})
    out.sort(key=lambda e: (name_key(e["program"] or ""), e["degree"] or ""))
    return out


router = APIRouter(prefix="/api/study-catalog", tags=["study-catalog"])


@router.get("/status")
def api_status():
    """Stand der Suche; stoesst sie im Hintergrund an, wenn sie faellig ist (nie gesucht oder Eingaben geaendert)"""
    with db.cursor() as conn:
        if AUTO_SYNC:
            started = maybe_start(conn)
            if started:
                return started
        return status(conn)


@router.post("/sync")
def api_sync(body: dict | None = None):
    """Suche jetzt anstossen (`{"force": true}`: auch wenn nichts neu ist); antwortet sofort mit dem Stand"""
    force = bool((body or {}).get("force"))
    with db.cursor() as conn:
        started = maybe_start(conn, force=force) if AUTO_SYNC else None
        return started or status(conn)


@router.get("/programs")
def api_programs(q: str = ""):
    """Studiengaenge des Registers zum Waehlen (Web); `q` filtert nach Name"""
    with db.cursor() as conn:
        uni = current_university(conn)
    items = programs(university=uni, seed=seed_cached())
    key = name_key(q) if q.strip() else ""
    if key:
        items = [e for e in items if key in name_key(e["program"] or "")]
    return {"programs": items, "count": len(items)}
