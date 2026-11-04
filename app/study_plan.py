"""Persoenlicher Studienverlauf (Auftrag des Inhabers 04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md).

Eingaben: Modulkatalog des Studiengangs (geteilte Fakten, Format study-catalog.schema.json), QIS-Leistungen (Tabelle
`grades`), Einstellungen je Konto (`settings.study_plan`: po, start_term, electives) und der heutige Tag. Ergebnis:
Semesterliste mit Modulen, Status, Verschiebungen und Hinweisen. Gleiche Regeln im Swift-Kern
(LocalBackend/StudyPlan/StudyPlanEngine.swift); Fixture tools/gen-study-plan-fixture.py.

Regeln (alle Reihenfolgen fest, damit Python und Swift dasselbe JSON liefern):
- Semester als Zahl: Jahr * 2 + (1 fuer WS, 0 fuer SS); WS 2026/27 = 4053, SoSe 2027 = 4054. Name "WiSe 26/27",
  "SoSe 27". Aktuelles Semester: Oktober bis Maerz WS, April bis September SS.
- Studienbeginn: Einstellung, sonst fruehestes QIS-Semester, sonst das aktuelle. Fachsemester = Semester - Beginn + 1.
- Zuordnung QIS-Zeile -> Modul: Pruefungsnummer = Modulkuerzel, sonst gleicher Namensschluessel (`name_key`: Fach wie
  `studip_sync.classify` (Uebung zu, Tranche, Gruppe ...), klein, Umlaute ausgeschrieben, roemische Zahlen als Ziffern,
  Fuellwoerter wie "Modul", "PL", "Klausur", "und" weg). Bereichszeilen ("Pflichtmodule" ...) zaehlen nicht.
- Status: bestanden (Semester der bestandenen Zeile), angemeldet (aktuelles Semester), nicht_bestanden (Versuch n,
  naechstes Semester mit passendem Turnus ab dem Semester nach dem Fehlversuch, fruehestens jetzt), offen (dran im
  aktuellen Semester), geplant (spaeter).
- Lage: empfohlenes Fachsemester laut Katalog, verschoben auf das naechste Semester mit passendem Turnus (WS/SS);
  Liegengebliebenes ("Noch nicht abgelegt") kommt ins aktuelle Semester bzw. das naechste passende; gewaehlte
  Wahl(pflicht)module ohne Fachsemester belegen die Plaetze laut Studienverlaufsplan (`plan_slots`, erster freier
  Platz ihres Bereichs, Module mit QIS-Zeilen zuerst); die uebrigen Module ohne Fachsemester fuellen das erste
  passende Semester ab jetzt mit Platz bis 30 LP.
- Voraussetzungen: ein Modul liegt immer nach seinen nicht bestandenen Voraussetzungen; wandert eine, wandern die
  abhaengigen mit, wenn noetig.
- Ausgleich: ab dem aktuellen Semester wandert bei mehr als 36 LP das am wenigsten dringende Wahl(pflicht)modul
  (hoechstes empfohlenes Fachsemester, sonst spaeter im Katalog) ins naechste passende Semester.
- Hinweise: endgueltig nicht bestanden, letzter (dritter) Versuch, fehlende Voraussetzung, Semester ab jetzt mit mehr
  als 36 LP (nur Pflicht, nichts zu verschieben), Rueckstand (mindestens 10 LP hinter dem Verlaufsplan).
"""
from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from datetime import date

from fastapi import APIRouter, Body, HTTPException

from . import db, grades_model, study
from .studip_sync import classify

DISCLAIMER = "Verbindlich ist die Prüfungsordnung deiner Hochschule."
NO_CATALOG = "Für deinen Studiengang gibt es noch keinen Katalog."
NO_CATALOG_PO = "Für die Prüfungsordnung {po} gibt es noch keinen Katalog."
SETTINGS_KEY = "study_plan"
TARGET_LP = 30
CAP_LP = 36
BEHIND_LP = 10
ELECTIVE_KINDS = ("wahlpflicht", "wahl")
NOTE_RANK = {"endgueltig": 0, "letzter_versuch": 1, "voraussetzung": 2, "ueberlast": 3, "rueckstand": 4}

TERM_RE = re.compile(r"^\s*(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*/\s*(\d{2,4}))?\s*$", re.I)
ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"}
FILLER = {"modul", "pl", "sl", "pruefungsleistung", "studienleistung", "modulpruefung", "pruefung", "klausur", "und", "u"}
NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")
REGISTERED_RE = re.compile(r"^an$|angemeldet")
PROGRAM_RE = re.compile(r"\s*\(.*$")
DIGITS_RE = re.compile(r"[0-9]{1,3}")


# ----------------------------------------------------------------------------
# Semester
# ----------------------------------------------------------------------------

def parse_term(s) -> int | None:
    """'WiSe 25/26', 'WS 2025/26', 'Wintersemester 2025/2026', 'SoSe 26', 'SS 2026' -> Zahl, sonst None"""
    if not isinstance(s, str):
        return None
    m = TERM_RE.match(s)
    if not m:
        return None
    year = int(m.group(2))
    if year < 100:
        year += 2000
    winter = m.group(1).lower().startswith(("wi", "ws"))
    return year * 2 + (1 if winter else 0)


def term_name(t: int) -> str:
    year = t // 2
    if t % 2:
        return f"WiSe {year % 100:02d}/{(year + 1) % 100:02d}"
    return f"SoSe {year % 100:02d}"


def current_term(today: str) -> int:
    """Oktober bis Maerz: WS (Jahr des Oktobers), April bis September: SS"""
    year, month = int(today[0:4]), int(today[5:7])
    if month >= 10:
        return year * 2 + 1
    if month <= 3:
        return (year - 1) * 2 + 1
    return year * 2


def turnus_of(v) -> str:
    """WS | SS | beide"""
    s = (v if isinstance(v, str) else "").lower()
    ws = "ws" in s or "winter" in s
    ss = "ss" in s or "sommer" in s
    if ws and not ss:
        return "WS"
    if ss and not ws:
        return "SS"
    return "beide"


def fits(t: int, turnus: str) -> bool:
    return turnus == "beide" or (turnus == "WS") == (t % 2 == 1)


def next_fit(t: int, turnus: str) -> int:
    while not fits(t, turnus):
        t += 1
    return t


# ----------------------------------------------------------------------------
# Namen und Zahlen
# ----------------------------------------------------------------------------

def name_key(text) -> str:
    """Namensschluessel fuer die Zuordnung QIS-Zeile/Kurs/App-Modul -> Katalogmodul"""
    s = classify(text if isinstance(text, str) else "")[0].lower()
    s = s.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    toks = [t for t in NON_ALNUM_RE.sub(" ", s).split(" ") if t]
    toks = [ROMAN.get(t, t) if len(toks) > 1 else t for t in toks]
    kept = [t for t in toks if t not in FILLER]
    return " ".join(kept or toks)


def num(v) -> float | int | None:
    """Zahl aus dem Katalog (int bleibt int) oder None"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def lp_of(m: dict):
    return num(m.get("lp")) or 0


def fmt_lp(x) -> str:
    """LP fuer Texte: 12 -> "12", 7.5 -> "7,5" """
    if float(x) == int(x):
        return str(int(x))
    return f"{float(x):.1f}".replace(".", ",")


def prereqs(m: dict) -> list[str]:
    """Voraussetzungen als Modul-ids (nur Texte aus einer Liste)"""
    v = m.get("prerequisites")
    return [p for p in v if isinstance(p, str)] if isinstance(v, list) else []


def int_or_none(v) -> int | None:
    s = str(v).strip() if v is not None else ""
    return int(s) if DIGITS_RE.fullmatch(s) else None


def text_of(v) -> str:
    return v if isinstance(v, str) else ""


def row_result(r: dict) -> str | None:
    """passed | final | failed | registered | None (abgemeldet, krank ...)"""
    s = text_of(r.get("status")).strip().lower()
    if s in ("bestanden", "anerkannt", "be"):
        return "passed"
    if s.startswith("endgültig") or s.startswith("endgueltig") or s == "en":
        return "final"
    if s.startswith("nicht bestanden") or s == "nb":
        return "failed"
    if REGISTERED_RE.search(s):
        return "registered"
    if not s and text_of(r.get("note")).strip() == "5,0":
        return "failed"
    return None


def is_bereich(r: dict) -> bool:
    return r.get("level") == "bereich" or bool(grades_model.BEREICH_RE.match(text_of(r.get("text"))))


# ----------------------------------------------------------------------------
# Katalog-Quellen
# ----------------------------------------------------------------------------

def catalog_key(c: dict) -> str:
    """Bibliotheksschluessel sha256("luh|TIBSc22|WS 2025/26")"""
    raw = f"{text_of(c.get('university'))}|{text_of(c.get('code'))}|{text_of(c.get('catalog_term'))}"
    return hashlib.sha256(raw.encode()).hexdigest()


def valid_catalog(c) -> bool:
    return isinstance(c, dict) and isinstance(c.get("modules"), list)


class MemoryCatalogSource:
    """Kataloge und Modultexte aus dem Speicher (Tests, Fixtures)"""

    def __init__(self, catalogs: list[dict], texts: dict | None = None) -> None:
        self._catalogs = catalogs
        self._texts = texts or {}                 # {catalog_key: {module_id: {content, goals, literature}}}

    def catalogs(self) -> list[dict]:
        return [c for c in self._catalogs if valid_catalog(c)]

    def module_text(self, catalog: dict, module_id: str) -> dict | None:
        return (self._texts.get(catalog_key(catalog)) or {}).get(module_id)


PAYLOAD_COLUMNS = ("payload", "catalog", "json", "data")


class DbCatalogSource:
    """Kataloge aus den lokalen Tabellen des Katalog-Abrufs (`study_catalogs`, `study_module_texts`). Die Spalten
    werden gelesen, nicht vorausgesetzt: JSON in `payload` (oder catalog/json/data), Texte je `module_id` und, wenn
    vorhanden, `catalog_key`."""

    def __init__(self, conn) -> None:
        self.conn = conn

    def _columns(self, table: str) -> list[str]:
        if not db.row(self.conn, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)):
            return []
        return [r["name"] for r in db.rows(self.conn, f"PRAGMA table_info({table})")]

    def catalogs(self) -> list[dict]:
        cols = self._columns("study_catalogs")
        col = next((c for c in PAYLOAD_COLUMNS if c in cols), None)
        if not col:
            return []
        out = []
        for r in db.rows(self.conn, f"SELECT {col} AS p FROM study_catalogs ORDER BY rowid"):
            try:
                c = json.loads(r["p"]) if isinstance(r["p"], str) else None
            except ValueError:
                c = None
            if valid_catalog(c):
                out.append(c)
        return out

    def module_text(self, catalog: dict, module_id: str) -> dict | None:
        cols = self._columns("study_module_texts")
        if "module_id" not in cols:
            return None
        sql, params = "SELECT * FROM study_module_texts WHERE module_id=?", [module_id]
        if "catalog_key" in cols:
            sql += " AND catalog_key=?"
            params.append(catalog_key(catalog))
        elif "code" in cols:
            sql += " AND code=?"
            params.append(text_of(catalog.get("code")))
        r = db.row(self.conn, sql + " ORDER BY rowid DESC LIMIT 1", params)
        if not r:
            return None
        return {k: r.get(k) if isinstance(r.get(k), str) else None for k in ("content", "goals", "literature")}


# ----------------------------------------------------------------------------
# Katalog waehlen
# ----------------------------------------------------------------------------

def program_of(grades: list[dict]) -> str | None:
    """Haeufigster Studiengang aus QIS `abschluss` ("Technische Informatik (PO-Version 2017)" -> "Technische
    Informatik"); bei Gleichstand der zuerst gesehene"""
    names = [PROGRAM_RE.sub("", text_of(r.get("abschluss"))).strip() for r in grades]
    names = [n for n in names if n]
    if not names:
        return None
    counts = Counter(names)
    best = max(counts.values())
    return next(n for n in names if counts[n] == best)


def abschluss_of(grades: list[dict]) -> str | None:
    names = [text_of(r.get("abschluss")).strip() for r in grades]
    names = [n for n in names if n]
    if not names:
        return None
    counts = Counter(names)
    best = max(counts.values())
    return next(n for n in names if counts[n] == best)


def pick_catalog(catalogs: list[dict], settings: dict, grades: list[dict]) -> tuple[dict | None, str | None]:
    """(Katalog, None) oder (None, Grund-Code: no_catalog | no_catalog_po). Gewaehlte PO (po oder Kuerzel), dann der
    Studiengang aus QIS, dann die neueste PO, das neueste Katalogsemester, das Kuerzel."""
    cands = [c for c in catalogs if valid_catalog(c)]
    if not cands:
        return None, "no_catalog"
    po = text_of(settings.get("po")).strip()
    if po:
        cands = [c for c in cands if str(c.get("po") or "") == po or text_of(c.get("code")) == po]
        if not cands:
            return None, "no_catalog_po"
    program = program_of(grades)
    if program:
        same = [c for c in cands if name_key(c.get("program")) == name_key(program)]
        if same:
            cands = same
    best = cands[0]
    for c in cands[1:]:
        if _catalog_rank(c) > _catalog_rank(best):
            best = c
    return best, None


def _catalog_rank(c: dict) -> tuple:
    return (str(c.get("po") or ""), parse_term(c.get("catalog_term")) or -1, text_of(c.get("code")))


# ----------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------

def _match(mods: list[dict], grades: list[dict]) -> tuple[dict, list[str]]:
    """{Modul-id: [Zeilen]} und die nicht zugeordneten Texte (sortiert, ohne Doppelte)"""
    by_code: dict[str, str] = {}
    by_key: dict[str, str] = {}
    for m in mods:
        code = text_of(m.get("code")).strip()
        if code and code not in by_code:
            by_code[code] = m["id"]
        k = name_key(m.get("title"))
        if k and k not in by_key:
            by_key[k] = m["id"]
    hist: dict[str, list[dict]] = {}
    unmatched: set[str] = set()
    for r in grades:
        if not isinstance(r, dict) or is_bereich(r):
            continue
        nr = text_of(r.get("pruefungsnr")).strip()
        mid = by_code.get(nr) if nr else None
        if mid is None:
            mid = by_key.get(name_key(r.get("text")))
        if mid is None:
            if text_of(r.get("text")).strip():
                unmatched.add(text_of(r.get("text")).strip())
            continue
        hist.setdefault(mid, []).append(r)
    return hist, sorted(unmatched)


def _attempts(rows: list[dict]) -> tuple[int, int | None, bool]:
    """(Fehlversuche, Semester des letzten Fehlversuchs, endgueltig)"""
    failed = [r for r in rows if row_result(r) in ("failed", "final")]
    if not failed:
        return 0, None, False
    versuche = [int_or_none(r.get("versuch")) or 0 for r in failed]
    terms = {parse_term(r.get("semester")) for r in failed}
    n = max(max(versuche), len(terms))
    known = [t for t in terms if t is not None]
    final = any(row_result(r) == "final" for r in failed) or n >= 3
    return n, (max(known) if known else None), final


def compute(catalog: dict, grades: list[dict], settings: dict, today: str) -> dict:
    """Der volle Stand (fuer Plan und Moduldetail): {plan, state, hist}"""
    mods: list[dict] = []
    seen: set[str] = set()
    for m in catalog.get("modules") or []:
        if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"] and m["id"] not in seen:
            seen.add(m["id"])
            mods.append(m)
    order = {m["id"]: i for i, m in enumerate(mods)}
    by_id = {m["id"]: m for m in mods}
    current = current_term(today)
    hist, unmatched = _match(mods, grades)

    start = parse_term(settings.get("start_term"))
    if start is None:
        terms = [parse_term(r.get("semester")) for r in grades if isinstance(r, dict) and not is_bereich(r)]
        known = [t for t in terms if t is not None]
        start = min(known) if known else current
    regular = num(catalog.get("regular_semesters"))
    regular = int(regular) if regular and regular > 0 else 6
    last_regular = start + regular - 1
    lower = max(current, start)

    el = settings.get("electives")
    chosen = [e for e in el if isinstance(e, str)] if isinstance(el, list) else []
    included = [m["id"] for m in mods
                if text_of(m.get("kind")) not in ELECTIVE_KINDS or m["id"] in chosen or m["id"] in hist]

    def sem_of(m: dict) -> int | None:
        s = num(m.get("semester"))
        return int(s) if s is not None and s >= 1 else None

    # Plaetze fuer Wahlmodule laut Studienverlaufsplan (`plan_slots`): gewaehlte Wahl(pflicht)module ohne Fachsemester
    # belegen der Reihe nach den ersten freien Platz ihres Bereichs (leere Bereichsliste = jeder); Module mit
    # QIS-Zeilen zuerst, damit Bestandenes die fruehen Plaetze fuellt
    slots = [s for s in catalog.get("plan_slots") or []
             if isinstance(s, dict) and isinstance(num(s.get("semester")), int) and num(s.get("semester")) >= 1]
    slot_sem: dict[str, int] = {}
    taken: set[int] = set()
    elect = [i for i in included if text_of(by_id[i].get("kind")) in ELECTIVE_KINDS and sem_of(by_id[i]) is None]
    for mid in [i for i in elect if i in hist] + [i for i in elect if i not in hist]:
        for k, s in enumerate(slots):
            areas = s.get("areas") if isinstance(s.get("areas"), list) else []
            if k not in taken and (not areas or by_id[mid].get("area") in areas):
                taken.add(k)
                slot_sem[mid] = int(num(s["semester"]))
                break

    state: dict[str, dict] = {}
    for mid in included:
        m, rows = by_id[mid], hist.get(mid, [])
        turnus = turnus_of(m.get("turnus"))
        failed_n, last_fail, final = _attempts(rows)
        passed = [r for r in rows if row_result(r) == "passed"]
        registered = [r for r in rows if row_result(r) == "registered"]
        st = {"status": None, "term": None, "attempt": None, "grade": None, "moved_from": None, "reason": None,
              "failed": failed_n, "final": final}
        sem = sem_of(m) or slot_sem.get(mid)
        rec = start + sem - 1 if sem else None
        if passed:
            best = passed[0]
            for r in passed[1:]:
                if (parse_term(r.get("semester")) or -1) >= (parse_term(best.get("semester")) or -1):
                    best = r
            t = parse_term(best.get("semester"))
            if t is None:
                t = min(rec, current) if rec is not None else current
            st.update(status="bestanden", term=max(t, start), attempt=failed_n + 1,
                      grade=text_of(best.get("note")).strip() or None)
        elif registered:
            vs = [int_or_none(r.get("versuch")) for r in registered]
            vs = [v for v in vs if v]
            st.update(status="angemeldet", term=current, attempt=max(vs) if vs else failed_n + 1)
        elif failed_n:
            begin = max(last_fail + 1 if last_fail is not None else current, lower)
            st.update(status="nicht_bestanden", term=next_fit(begin, turnus), attempt=failed_n,
                      moved_from=term_name(last_fail) if last_fail is not None else None,
                      reason="Nicht bestanden – nächster Versuch")
        elif rec is not None:
            t = next_fit(max(rec, start), turnus)
            st.update(status="plan", term=t)
            if t != rec:
                st.update(moved_from=term_name(rec),
                          reason=f"Wird nur im {'Wintersemester' if turnus == 'WS' else 'Sommersemester'} angeboten")
            if t < lower:
                st.update(term=next_fit(lower, turnus), moved_from=term_name(rec), reason="Noch nicht abgelegt – nachholen")
        else:
            st["status"] = "plan"                                   # ohne Fachsemester: unten auffuellen
        state[mid] = st

    def load(t: int) -> float:
        return sum(lp_of(by_id[i]) for i in included if state[i]["term"] == t)

    for mid in included:
        st = state[mid]
        if st["term"] is not None:
            continue
        m = by_id[mid]
        turnus = turnus_of(m.get("turnus"))
        t = next_fit(lower, turnus)
        while t <= last_regular and load(t) + lp_of(m) > TARGET_LP:
            t = next_fit(t + 1, turnus)
        if t > last_regular:
            t = next_fit(max(lower, last_regular), turnus)
        st["term"] = t

    def move(mid: str, t: int, reason: str) -> None:
        st = state[mid]
        if st["moved_from"] is None:
            st["moved_from"] = term_name(st["term"])
        st["term"], st["reason"] = t, reason

    def fix_prerequisites() -> None:
        for _ in range(len(included) + 1):
            changed = False
            for mid in included:
                st = state[mid]
                if st["status"] not in ("plan", "nicht_bestanden"):
                    continue
                need, need_id = None, None
                for p in prereqs(by_id[mid]):
                    ps = state.get(p)
                    if ps is None or ps["status"] == "bestanden":
                        continue
                    if need is None or ps["term"] > need:
                        need, need_id = ps["term"], p
                if need is not None and st["term"] <= need:
                    move(mid, next_fit(need + 1, turnus_of(by_id[mid].get("turnus"))),
                         f"Voraussetzung {text_of(by_id[need_id].get('title'))} zuerst")
                    changed = True
            if not changed:
                return

    fix_prerequisites()
    t = lower
    while included and t <= max(state[i]["term"] for i in included):
        while load(t) > CAP_LP:
            cands = [i for i in included if state[i]["term"] == t and state[i]["status"] == "plan"
                     and text_of(by_id[i].get("kind")) in ELECTIVE_KINDS]
            if not cands:
                break
            pick = cands[0]
            for i in cands[1:]:
                if (sem_of(by_id[i]) or 99, order[i]) > (sem_of(by_id[pick]) or 99, order[pick]):
                    pick = i
            move(pick, next_fit(t + 1, turnus_of(by_id[pick].get("turnus"))), f"Mehr als {CAP_LP} LP im Semester")
            fix_prerequisites()
        t += 1

    for mid in included:
        st = state[mid]
        if st["status"] == "plan":
            st["status"] = "offen" if st["term"] <= current else "geplant"

    # Semesterliste
    last = max([last_regular] + [state[i]["term"] for i in included])
    semesters = []
    for t in range(start, last + 1):
        ids = sorted((i for i in included if state[i]["term"] == t), key=lambda i: (sem_of(by_id[i]) or 99, order[i]))
        semesters.append({"term": term_name(t), "fachsemester": t - start + 1, "current": t == current,
                          "lp": sum(lp_of(by_id[i]) for i in ids), "modules": [_entry(by_id[i], state[i]) for i in ids]})

    lp_done = sum(lp_of(by_id[i]) for i in included if state[i]["status"] == "bestanden")
    total = num(catalog.get("total_lp"))
    lp_total = total if total else sum(lp_of(by_id[i]) for i in included)
    lp_expected = sum(lp_of(by_id[i]) for i in included if sem_of(by_id[i]) and start + sem_of(by_id[i]) - 1 < current)

    notes = []
    for mid in included:
        m, st = by_id[mid], state[mid]
        title = text_of(m.get("title"))
        if st["status"] != "bestanden" and st["final"]:
            notes.append(_note("endgueltig", mid, f"{title}: endgültig nicht bestanden – sprich mit der Studienberatung."))
        elif (st["status"] == "nicht_bestanden" and st["attempt"] == 2) or (st["status"] == "angemeldet" and st["attempt"] == 3):
            notes.append(_note("letzter_versuch", mid, f"{title}: Letzter Versuch – sprich mit der Studienberatung."))
        if st["status"] == "bestanden":
            continue
        for p in prereqs(m):
            if p not in by_id:
                continue
            ps = state.get(p)
            ptitle = text_of(by_id[p].get("title"))
            if ps is None:
                notes.append(_note("voraussetzung", mid, f"{title}: Voraussetzung {ptitle} ist nicht im Plan."))
            elif ps["status"] != "bestanden" and st["status"] == "angemeldet":
                notes.append(_note("voraussetzung", mid, f"{title}: Voraussetzung {ptitle} ist noch nicht bestanden."))
    for sem in semesters:
        if start + sem["fachsemester"] - 1 >= lower and sem["lp"] > CAP_LP:
            notes.append(_note("ueberlast", None, f"{sem['term']}: {fmt_lp(sem['lp'])} LP geplant, mehr als {CAP_LP} LP "
                                                  f"(Richtwert {TARGET_LP} LP)."))
    if current > start and lp_expected - lp_done >= BEHIND_LP:
        notes.append(_note("rueckstand", None,
                           f"Du liegst {fmt_lp(lp_expected - lp_done)} LP hinter dem Studienverlaufsplan: {fmt_lp(lp_done)} "
                           f"von {fmt_lp(lp_expected)} LP bis zum Ende des {current - start}. Fachsemesters."))
    notes.sort(key=lambda n: NOTE_RANK[n["kind"]])

    electives = []
    for m in mods:
        if text_of(m.get("kind")) not in ELECTIVE_KINDS:
            continue
        st = state.get(m["id"])
        electives.append({"id": m["id"], "title": text_of(m.get("title")), "kind": m.get("kind"), "area": m.get("area"),
                          "lp": lp_of(m), "semester": sem_of(m), "chosen": m["id"] in chosen, "included": st is not None,
                          "status": st["status"] if st else None})

    plan = {
        "available": True, "reason": None, "message": None,
        "university": catalog.get("university"), "program": catalog.get("program"), "degree": catalog.get("degree"),
        "po": catalog.get("po"), "code": catalog.get("code"), "catalog_term": catalog.get("catalog_term"),
        "start_term": term_name(start), "current_term": term_name(current), "current_fachsemester": current - start + 1,
        "semesters": semesters, "lp_done": lp_done, "lp_total": lp_total, "lp_expected": lp_expected,
        "notes": notes, "electives": electives, "unmatched": unmatched, "disclaimer": DISCLAIMER,
    }
    return {"plan": plan, "state": state, "hist": hist, "by_id": by_id, "included": included}


def _entry(m: dict, st: dict) -> dict:
    return {"id": m["id"], "title": text_of(m.get("title")), "code": m.get("code"), "kind": m.get("kind"),
            "area": m.get("area"), "lp": lp_of(m), "semester": num(m.get("semester")), "turnus": m.get("turnus"),
            "status": st["status"], "attempt": st["attempt"], "grade": st["grade"],
            "moved_from": st["moved_from"], "reason": st["reason"], "last_attempt": last_attempt(st)}


def last_attempt(st: dict) -> bool:
    """Naechster bzw. angemeldeter Versuch ist der dritte, oder endgueltig nicht bestanden"""
    if st["status"] == "bestanden":
        return False
    return bool(st["final"]) or (st["status"] == "nicht_bestanden" and st["attempt"] == 2) or \
        (st["status"] == "angemeldet" and st["attempt"] == 3)


def _note(kind: str, module_id: str | None, text: str) -> dict:
    return {"kind": kind, "tone": "bad" if NOTE_RANK[kind] <= 1 else "warn", "module_id": module_id, "text": text}


def build_plan(catalog: dict, grades: list[dict], settings: dict, today: str) -> dict:
    return compute(catalog, grades, settings, today)["plan"]


def unavailable(reason: str, po: str | None = None) -> dict:
    """Ohne Katalog: reason als Code, message als Text"""
    message = NO_CATALOG_PO.format(po=po) if reason == "no_catalog_po" else NO_CATALOG
    return {"available": False, "reason": reason, "message": message, "university": None, "program": None, "degree": None, "po": None,
            "code": None, "catalog_term": None, "start_term": None, "current_term": None, "current_fachsemester": None,
            "semesters": [], "lp_done": 0, "lp_total": 0, "lp_expected": 0, "notes": [], "electives": [],
            "unmatched": [], "disclaimer": DISCLAIMER}


# ----------------------------------------------------------------------------
# Einstellungen und Endpunkte
# ----------------------------------------------------------------------------

def load_settings(conn) -> dict:
    r = db.row(conn, "SELECT value FROM settings WHERE key=?", (SETTINGS_KEY,))
    try:
        v = json.loads(r["value"]) if r and r["value"] else {}
    except ValueError:
        v = {}
    if not isinstance(v, dict):
        v = {}
    po = v.get("po") if isinstance(v.get("po"), str) and v.get("po") else None
    start = v.get("start_term") if isinstance(v.get("start_term"), str) and parse_term(v.get("start_term")) else None
    el = v.get("electives") if isinstance(v.get("electives"), list) else []
    out = {"po": po, "start_term": start, "electives": sorted({e for e in el if isinstance(e, str) and e})}
    from .study_catalog import clean_catalog_url      # eigener Link zum Modulhandbuch, nur wenn gesetzt
    url = clean_catalog_url(v.get("catalog_url"))
    if url:
        out["catalog_url"] = url
    return out


def grade_rows(conn) -> list[dict]:
    return grades_model.model(db.rows(conn, "SELECT * FROM grades ORDER BY id"))


def plan_response(conn, today: str, source=None) -> dict:
    source = source or DbCatalogSource(conn)
    settings, grades = load_settings(conn), grade_rows(conn)
    catalogs = source.catalogs()
    cat, reason = pick_catalog(catalogs, settings, grades)
    out = unavailable(reason, settings["po"]) if cat is None else build_plan(cat, grades, settings, today)
    suggested, _ = pick_catalog(catalogs, {}, grades)
    out.update(suggested_po=suggested.get("po") if suggested else None, po_confirmed=settings["po"] is not None,
               qis_program=abschluss_of(grades))
    return out


def module_response(conn, module_id: str, today: str, source=None) -> dict:
    """Fakten, lokaler Text, eigener Stand, Kurse und Dateien der App zu einem Katalogmodul; 404 ohne Katalog/Modul"""
    source = source or DbCatalogSource(conn)
    settings, grades = load_settings(conn), grade_rows(conn)
    cat, _ = pick_catalog(source.catalogs(), settings, grades)
    if cat is None:
        raise HTTPException(404, "Kein Katalog")
    full = compute(cat, grades, settings, today)
    m = full["by_id"].get(module_id)
    if m is None:
        raise HTTPException(404, "Modul nicht im Katalog")
    state, by_id = full["state"], full["by_id"]
    areas = {a["id"]: a for a in cat.get("areas") or [] if isinstance(a, dict) and isinstance(a.get("id"), str)}
    area = areas.get(m.get("area")) if isinstance(m.get("area"), str) else None
    st = state.get(module_id)
    own = {"status": st["status"] if st else "nicht_gewaehlt", "term": term_name(st["term"]) if st else None,
           "attempt": st["attempt"] if st else None, "grade": st["grade"] if st else None,
           "moved_from": st["moved_from"] if st else None, "reason": st["reason"] if st else None,
           "last_attempt": last_attempt(st) if st else False,
           "attempts": [{"text": r.get("text"), "semester": r.get("semester"), "status": r.get("status"),
                         "grade": r.get("note"), "attempt": int_or_none(r.get("versuch")), "date": r.get("datum")}
                        for r in full["hist"].get(module_id, [])]}

    def ref(i: str) -> dict:
        s = state.get(i)
        return {"id": i, "title": text_of(by_id[i].get("title")), "status": s["status"] if s else "nicht_gewaehlt"}

    pre = [ref(p) for p in prereqs(m) if p in by_id]
    required_for = [ref(i) for i in by_id if module_id in prereqs(by_id[i])]
    key = name_key(m.get("title"))
    app_modules = [{"id": r["id"], "name": r["name"]} for r in db.rows(conn, "SELECT id, name FROM modules ORDER BY id")
                   if name_key(r["name"]) == key]
    mids = {a["id"] for a in app_modules}
    courses = [{"id": r["id"], "title": r["title"], "semester": r["semester"], "kind": r["kind"], "module_id": r["module_id"]}
               for r in db.rows(conn, "SELECT id, title, semester, kind, subject, module_id FROM courses "
                                      "WHERE COALESCE(active, 1)=1 ORDER BY title, id")
               if r["module_id"] in mids or name_key(r["subject"] or r["title"]) == key]
    files = []
    if courses:
        ids = [c["id"] for c in courses]
        files = db.rows(conn, f"SELECT id, name, course_id, mime FROM files WHERE course_id IN ({','.join('?' * len(ids))}) "
                              "ORDER BY name, id LIMIT 200", ids)
    src = cat.get("source") if isinstance(cat.get("source"), dict) else {}
    return {
        "available": True, "id": module_id, "title": text_of(m.get("title")), "code": m.get("code"),
        "area": m.get("area"), "area_name": area.get("name") if area else None,
        "kind": m.get("kind"), "lp": lp_of(m), "semester": num(m.get("semester")), "turnus": m.get("turnus"),
        "exam": m.get("exam"), "coursework": m.get("coursework"), "language": m.get("language"),
        "workload_h": num(m.get("workload_h")), "prerequisites": pre, "required_for": required_for,
        "texts": source.module_text(cat, module_id), "own": own, "app_modules": app_modules, "courses": courses,
        "files": files, "source": {"url": src.get("url"), "page": num(m.get("source_page"))},
        "program": cat.get("program"), "po": cat.get("po"), "catalog_term": cat.get("catalog_term"),
        "disclaimer": DISCLAIMER,
    }


def py_str(v) -> str:
    """str(v or "") fuer Werte aus dem Katalog (PO als Text oder Zahl)"""
    return str(v or "")


def settings_response(conn, today: str, source=None) -> dict:
    """Einstellungen mit Vorschlaegen: PO aus QIS und Katalogen, Studienbeginn aus QIS, Auswahl fuer PO, Semester und
    Wahlmodule (aus dem Katalog, der mit den Einstellungen gilt)"""
    source = source or DbCatalogSource(conn)
    s, grades = load_settings(conn), grade_rows(conn)
    catalogs = source.catalogs()
    suggested, _ = pick_catalog(catalogs, {}, grades)
    cat, _ = pick_catalog(catalogs, s, grades)
    terms = [parse_term(r.get("semester")) for r in grades if not is_bereich(r)]
    known = [t for t in terms if t is not None]
    pos: list[str] = []
    for c in catalogs:
        if py_str(c.get("po")) and py_str(c.get("po")) not in pos:
            pos.append(py_str(c.get("po")))
    current = current_term(today)
    areas = [a for a in (cat or {}).get("areas") or [] if isinstance(a, dict)]
    names = {a["id"]: a.get("name") for a in areas if isinstance(a.get("id"), str)}
    wp = [num(a.get("lp_required")) or 0 for a in areas if a.get("kind") == "wahlpflicht"]
    options = [{"id": m["id"], "title": text_of(m.get("title")), "kind": m.get("kind"), "lp": lp_of(m),
                "semester": num(m.get("semester")), "area": m.get("area"),
                "area_name": names.get(m.get("area")) if isinstance(m.get("area"), str) else None}
               for m in (cat or {}).get("modules") or []
               if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"] and text_of(m.get("kind")) in ELECTIVE_KINDS]
    return {**s, "suggested_po": suggested.get("po") if suggested else None,
            "suggested_start_term": term_name(min(known)) if known else None,
            "abschluss": abschluss_of(grades), "po_options": pos,
            "term_options": [term_name(current - i) for i in range(12)],
            "elective_options": options, "elective_lp_required": sum(wp) if wp else None,
            "catalogs": [{"po": c.get("po"), "code": c.get("code"), "program": c.get("program"),
                          "degree": c.get("degree"), "catalog_term": c.get("catalog_term")} for c in catalogs]}


def save_settings(conn, body: dict, today: str, source=None) -> dict:
    """Teilweise aendern: nur die genannten Schluessel; 400 bei falschem Typ oder unbekanntem Semester"""
    s = load_settings(conn)
    if "po" in body:
        v = body["po"]
        if v is not None and not isinstance(v, str):
            raise HTTPException(400, "po muss Text sein")
        s["po"] = (v.strip() or None) if isinstance(v, str) else None
    if "start_term" in body:
        v = body["start_term"]
        if v is not None and not isinstance(v, str):
            raise HTTPException(400, "start_term muss Text sein")
        if isinstance(v, str) and v.strip():
            t = parse_term(v)
            if t is None:
                raise HTTPException(400, f"Unbekanntes Semester: {v.strip()}")
            s["start_term"] = term_name(t)
        else:
            s["start_term"] = None
    if "electives" in body:
        v = body["electives"]
        if not isinstance(v, list) or not all(isinstance(e, str) for e in v):
            raise HTTPException(400, "electives muss eine Liste von Modul-ids sein")
        s["electives"] = sorted({e for e in v if e})
    if "catalog_url" in body:
        from .study_catalog import clean_catalog_url
        v = body["catalog_url"]
        if v is not None and not isinstance(v, str):
            raise HTTPException(400, "catalog_url muss Text sein")
        if isinstance(v, str) and v.strip():
            url = clean_catalog_url(v)
            if not url:
                raise HTTPException(400, "catalog_url muss ein https-Link sein (höchstens 500 Zeichen)")
            s["catalog_url"] = url
        else:
            s.pop("catalog_url", None)
    stored = {"po": s["po"], "start_term": s["start_term"], "electives": s["electives"]}
    if s.get("catalog_url"):
        stored["catalog_url"] = s["catalog_url"]
    db.set_setting(conn, SETTINGS_KEY, stored)
    return settings_response(conn, today, source)


router = APIRouter(prefix="/api/study-plan", tags=["study-plan"])


@router.get("")
def api_study_plan():
    """Persoenlicher Studienverlauf: Semester mit Modulen, LP, Hinweise; available=false ohne Katalog"""
    with db.cursor() as conn:
        return plan_response(conn, study.today().isoformat())


@router.get("/settings")
def api_study_plan_settings():
    with db.cursor() as conn:
        return settings_response(conn, study.today().isoformat())


@router.post("/settings")
def api_study_plan_settings_save(body: dict = Body(...)):
    with db.cursor() as conn:
        return save_settings(conn, body, study.today().isoformat())


@router.get("/module/{module_id}")
def api_study_plan_module(module_id: str):
    with db.cursor() as conn:
        return module_response(conn, module_id, study.today().isoformat())
