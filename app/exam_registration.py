"""Pruefungsanmeldung (Entscheidung des Inhabers 05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Meldezeitraeume
je Hochschule und Studiengang (LUH: packages/shared-contracts/exam-registration-luh.json, Uni Hildesheim:
exam-registration-hildesheim.json), Zuordnung Studiengang -> Terminseite des Pruefungsamts und Phase des naechsten
Fensters je Tag.

Uni Hildesheim: keine einheitliche Frist, nur der Start der POS-Anmeldung im LSF fuer alle Bachelor- und
Masterstudiengaenge; das Fenster hat `open_end` (Ende = Ende des Semesters, keine Anmeldefrist; die Frist steht im LSF
an jeder Pruefung). Studiengaenge ohne eigenen Eintrag nehmen den Eintrag mit `default` (alle Bachelor/Master).

Gleiche Regeln im Swift-Kern (ExamRegistration/ExamRegistrationPeriods.swift); Faelle in
packages/shared-contracts/fixtures/exam-registration/period-cases.json (tools/gen-exam-registration-fixture.py).
Nur Daten und Rechnen: am PC gibt es keinen Endpunkt und keinen Abruf der QIS-Seite "Info ueber angemeldete
Pruefungen" (siehe "Luecken" im Dokument). Die App meldet nie selbst an oder ab.

Regeln:
- Name: Klammerzusatz ("(PO-Version 2017)") weg, klein, Umlaute ausgeschrieben, alles ausser a-z/0-9 -> "-".
- Abschluss: "B.Sc." -> bsc, "M.Sc." -> msc, "B.A." -> ba, "M.A." -> ma, "M.Ed." -> med, "B.Ed." -> bed; ohne Angabe
  "Bachelor"/"Master" im Text -> alle passenden Kuerzel; Treffer nur, wenn genau eine Terminseite passt.
- Phase je Art (meldung, vbp_meldung): laeuft heute ein Fenster -> open (days_left); sonst das naechste: soon (beginnt in
  hoechstens 7 Tagen) oder later; keins mehr in den Daten -> None (dann nur der Link).
"""
from __future__ import annotations

import json
import re
import unicodedata
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "packages" / "shared-contracts" / "exam-registration-luh.json"
HILDESHEIM_PATH = ROOT / "packages" / "shared-contracts" / "exam-registration-hildesheim.json"
HSH_PATH = ROOT / "packages" / "shared-contracts" / "exam-registration-hsh.json"
DATA_PATHS = {"luh": DATA_PATH, "hildesheim": HILDESHEIM_PATH, "hsh": HSH_PATH}

SOON_DAYS = 7

DEGREE_SLUGS = {"bsc": "bsc", "msc": "msc", "ba": "ba", "ma": "ma", "med": "med", "bed": "bed", "llb": "llb", "llm": "llm",
                "beng": "beng", "meng": "meng", "mba": "mba"}          # B.Eng./M.Eng./MBA: Hochschule Hannover
BACHELOR = ["bsc", "ba", "bed", "beng"]
MASTER = ["msc", "ma", "med", "meng", "mba"]


def load_data(path: Path = DATA_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def for_university(key: str | None) -> dict | None:
    """Daten der Hochschule (`luh` | `hildesheim`) oder None (keine Daten: nicht unterstuetzt)"""
    path = DATA_PATHS.get(key or "")
    return load_data(path) if path else None


def system(data: dict) -> str:
    """Name des Pruefungssystems in den Texten: "QIS" (LUH) oder "LSF" (Uni Hildesheim)"""
    return str(data.get("system") or "QIS")


def default_program(data: dict) -> dict | None:
    """Eintrag fuer alle Studiengaenge ohne eigenen (`default`), sonst None"""
    return next((p for p in data.get("programs") or [] if p.get("default")), None)


def resolve_program(data: dict, name: str | None, degree: str | None = None) -> dict | None:
    """`find_program`, sonst der Eintrag fuer alle Studiengaenge (Uni Hildesheim), sonst None"""
    return find_program(data, name, degree) or default_program(data)


def fold(text: str) -> str:
    """klein, Umlaute ausgeschrieben, NFC"""
    s = unicodedata.normalize("NFC", text or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        s = s.replace(a, b)
    return s


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", fold(text)).strip("-")


def program_name(name: str) -> str:
    """"Technische Informatik (PO-Version 2017)" -> "Technische Informatik" """
    return re.sub(r"\s*\(.*$", "", name or "").strip()


def degree_slugs(degree: str | None, text: str = "") -> list[str]:
    d = re.sub(r"[^a-z]", "", fold(degree or ""))
    if d in DEGREE_SLUGS:
        return [DEGREE_SLUGS[d]]
    for word, slugs in (("bachelor", BACHELOR), ("master", MASTER)):
        if word in d or word in fold(text):
            return list(slugs)
    return []


def find_program(data: dict, name: str | None, degree: str | None = None) -> dict | None:
    """Terminseite des Studiengangs oder None (kein oder kein eindeutiger Treffer)"""
    base = slugify(program_name(name or ""))
    if not base:
        return None
    programs = data.get("programs") or []
    cands = degree_slugs(degree, name or "")
    if not cands:
        cands = sorted(set(DEGREE_SLUGS.values()))
    hits = [p for p in programs if not p.get("default") and p.get("slug") in {f"{base}-{d}" for d in cands}]
    return hits[0] if len(hits) == 1 else None


def table_of(data: dict, program: dict | None) -> dict | None:
    if not program or not program.get("table"):
        return None
    return (data.get("tables") or {}).get(program["table"])


def window_state(data: dict, program: dict | None, today: str, kind: str = "meldung") -> dict | None:
    """Fenster der Art `kind`, das heute laeuft, sonst das naechste; None ohne Daten"""
    table = table_of(data, program)
    if table is None:
        return None
    t = date.fromisoformat(today)
    cands = []
    for term in table.get("terms") or []:
        for p in term.get("periods") or []:
            if p.get("kind") == kind:
                cands.append((p["start"], p["end"], term["term"], p))
    cands.sort(key=lambda x: (x[0], x[1]))
    pick = None
    for start, end, term, p in cands:
        if date.fromisoformat(start) <= t <= date.fromisoformat(end):
            pick = (term, p, "open")
            break
    if pick is None:
        for start, end, term, p in cands:
            if date.fromisoformat(start) > t:
                soon = (date.fromisoformat(start) - t).days <= SOON_DAYS
                pick = (term, p, "soon" if soon else "later")
                break
    if pick is None:
        return None
    term, p, phase = pick
    start, end = date.fromisoformat(p["start"]), date.fromisoformat(p["end"])
    return {"term": term, "kind": p["kind"], "n": p.get("n", 1), "label": p["label"], "start": p["start"], "end": p["end"],
            "phase": phase, "days_left": (end - t).days, "days_until": max(0, (start - t).days),
            "open_end": bool(p.get("open_end"))}


def term_periods(data: dict, program: dict | None, term: str | None) -> list[dict]:
    table = table_of(data, program)
    if table is None or term is None:
        return []
    for x in table.get("terms") or []:
        if x.get("term") == term:
            return list(x.get("periods") or [])
    return []
