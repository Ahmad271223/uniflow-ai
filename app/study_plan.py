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
- Offene Plaetze (05.11.2026): ein Wahl(pflicht)modul ohne Fachsemester belegt immer einen Platz seines Bereichs, auch
  auf eigener Lage (im selben Semester, sonst im naechstgelegenen). Ein freier Platz bleibt nur fuer einen Bereich mit
  offenem Bedarf (LP oder Zahl der Module, beides muss erfuellt sein), sonst fuer einen Bereich, in dessen Spanne bis
  zur Obergrenze ("0 - 15 LP", "15 - 40 LP") der ganze Platz noch passt (so bleibt der Verlaufsplan ohne Wahl ganz
  stehen, auch wo er mehr als den Mindestbedarf vorsieht). Ist der Bedarf eines Bereichs schon durch
  bestandene, geplante oder gewaehlte Module (und eigene Eintraege) gedeckt, faellt jeder weitere Platz dieses Bereichs
  weg, auch wenn die Obergrenze mehr erlauben wuerde. Ein Modul, das in mehreren Bereichen waehlbar ist, zaehlt genau
  einmal: im eigenen Bereich, solange dessen Bedarf offen ist, sonst im ersten aktiven Bereich mit offenem Bedarf
  (PO: eine Leistung wird nur einem Bereich angerechnet).
- Voraussetzungen: ein Modul liegt immer nach seinen nicht bestandenen Voraussetzungen; wandert eine, wandern die
  abhaengigen mit, wenn noetig.
- Ausgleich: ab dem aktuellen Semester wandert bei mehr als 36 LP das am wenigsten dringende Wahl(pflicht)modul
  (hoechstes empfohlenes Fachsemester, sonst spaeter im Katalog) ins naechste passende Semester.
- Hinweise: endgueltig nicht bestanden, letzter Versuch, fehlende Voraussetzung, Semester ab jetzt mit mehr
  als 36 LP (nur Pflicht, nichts zu verschieben), Rueckstand (mindestens 10 LP hinter dem Verlaufsplan), Wahl erkannt.
- Versuche ehrlich (11.11.2026): "letzter Versuch" nur, wenn QIS es meldet ("letzter Versuch" im Status/Vermerk) oder
  Katalog bzw. Modul eine Hoechstzahl nennen (`max_attempts`, Vorgabe: unbekannt); "endgueltig" nur aus QIS oder bei
  erreichter Hoechstzahl, nie pauschal ab dem dritten Versuch. `attempt_known`: QIS nennt die Nummer des Versuchs
  (sonst ist sie aus den Fehlversuchen gezaehlt, z. B. LSF Hildesheim ohne Versuchsspalte). Zaehlung (12.11.2026,
  echter LUH-Notenspiegel): Fehlversuche = verschiedene (Semester, Datum) nicht bestandener Pruefungszeilen, mindestens
  die hoechste QIS-Versuchsnummer; der bestandene Versuch ist max(Fehlversuche + 1, QIS-Versuch). Zeigt QIS bei
  Fehlversuch (SoSe 25) und bestandenem Eintrag (SoSe 26) beide als Versuch 1, ist der bestandene Versuch 2.
- Wahl statt Pflicht (11.11.2026): ein Bereich, dessen Pflichtmodule zusammen mehr als das 1,5-fache seiner LP
  (Obergrenze, sonst Bedarf; ohne Angabe: mehr als der ganze Studiengang) haben, bietet eine Wahl an: seine
  Pflichtmodule gelten als Wahlpflicht (die mit empfohlenem Fachsemester bleiben Pflicht, solange sie allein in den
  Bereich passen); Hinweis "wahl_erkannt". Voraussetzungen, die Wahlmodule sind, fehlen nie "im Plan".
- Wahlfach aus QIS ohne Katalogmodul (11.11.2026): eine nicht zugeordnete QIS-Leistung unter einer QIS-Bereichszeile,
  deren Name den Namen eines aktiven Wahlbereichs enthaelt ("Kompetenzbereich Studium Generale"), steht mit Stand im
  Plan (`qis: true`, LP aus QIS, sonst die uebliche LP des Bereichs), zaehlt im Bereich und belegt dessen
  naechstgelegenen freien Platz laut Verlaufsplan; eigene Eintraege gleichen Namens gehen vor.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import math
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
NOTE_RANK = {"endgueltig": 0, "letzter_versuch": 1, "voraussetzung": 2, "ueberlast": 3, "rueckstand": 4, "wahl_erkannt": 5}
CHOICE_FACTOR = 1.5
LAST_TRY_RE = re.compile(r"letzte[rnms]? ?(wiederholungs)?versuch|letztversuch")

TERM_RE = re.compile(r"^\s*(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*/\s*(\d{2,4}))?\s*$", re.I)
ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"}
FILLER = {"modul", "pl", "sl", "pruefungsleistung", "studienleistung", "modulpruefung", "pruefung", "klausur", "und", "u"}
NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")
REGISTERED_RE = re.compile(r"^an$|angemeldet")
PROGRAM_RE = re.compile(r"\s*\(.*$")
DIGITS_RE = re.compile(r"[0-9]{1,3}")
CREDITS_RE = re.compile(r"[0-9]{1,3}(?:[.,][0-9]{1,2})?")

# Wahlbereiche (05.11.2026): Typ eines Bereichs aus seinem Namen (klein, Umlaute ausgeschrieben), erster Treffer zaehlt;
# ohne Treffer aus der Art der Module (pflicht | wahlpflicht | wahl). Ein Katalog darf `type` und `group` selbst nennen.
AREA_TYPE_RULES = (
    ("abschluss", re.compile(r"bachelorarbeit|masterarbeit|abschlussarbeit")),
    ("studium_generale", re.compile(r"studium generale")),
    ("schluessel", re.compile(r"schluesselkompetenz|soft skills|zusatzkompetenz|ueberfachlich")),
    ("praktikum", re.compile(r"betriebspraktikum|fachpraktikum|industriepraktikum|berufspraktikum|berufspraktische")),
    ("seminar", re.compile(r"seminar|akademisches arbeiten")),
    ("labor", re.compile(r"labor|praktikum")),
    ("projekt", re.compile(r"projekt")),
    ("schwerpunkt", re.compile(r"schwerpunkt|vertiefungsrichtung|studienrichtung|profilbereich")),
    ("nebenfach", re.compile(r"nebenfach|anwendungsfach")),
    ("vertiefung", re.compile(r"vertiefung|spezialisierung")),
)
AREA_TYPES = {t for t, _ in AREA_TYPE_RULES} | {"pflicht", "wahlpflicht", "wahl"}
GROUP_TYPES = ("schwerpunkt", "nebenfach")
GROUP_LABELS = {"schwerpunkt": "Schwerpunkt", "nebenfach": "Nebenfach", "vertiefungsrichtung": "Vertiefungsrichtung",
                "studienrichtung": "Studienrichtung"}
EARLY_TYPES = ("studium_generale", "schluessel", "seminar")
UNIT_LP = 5
MAX_AREA_SLOTS = 8
MAX_UNKNOWN_SLOTS = 4
CUSTOM_ID_RE = re.compile(r"eigen-[0-9]{1,4}")
MANUAL = "manuell"          # Quelle selbst eingetragener Leistungen (app/grades_manual.py)
MAX_CUSTOM = 40
MAX_CUSTOM_TITLE = 120
MAX_CUSTOM_CONTENT = 2000     # Inhalt eines eigenen Eintrags (26.11.2026)
MAX_CUSTOM_HOURS = 2000       # Arbeitsaufwand in Stunden


# ----------------------------------------------------------------------------
# Semester
# ----------------------------------------------------------------------------

def parse_term(s) -> int | None:
    """'WiSe 25/26', 'WS 2025/26', 'Wintersemester 2025/2026', 'SoSe 26', 'SS 2026', 'W25', '25/26 WS', '20252' -> Zahl,
    sonst None (grades_model.parse_term, alle Schreibweisen des QIS seit 12.11.2026)"""
    return grades_model.parse_term(s)


def row_term(r: dict) -> int | None:
    """Semester einer QIS-Zeile: Semesterspalte, sonst aus dem Pruefungsdatum (grades_model.row_term)"""
    return grades_model.row_term(r)


def term_name(t: int) -> str:
    return grades_model.term_name(t)


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


def _rec_sem(m: dict) -> int | None:
    s = num(m.get("semester"))
    return int(s) if s is not None and s >= 1 else None


def plan_prereqs(m: dict, by_id: dict) -> list[str]:
    """Voraussetzungen, die der Plan beachtet: ohne die, die der Studienverlaufsplan selbst ins gleiche oder ein spaeteres
    Fachsemester legt (dann nur eine Empfehlung; 11.11.2026, INFBSc22: Logik und formale Systeme im 2. vor Grundlagen
    der Theoretischen Informatik im 3. Semester)"""
    own = _rec_sem(m)
    return [p for p in prereqs(m) if not (own is not None and p in by_id and _rec_sem(by_id[p]) is not None
                                          and _rec_sem(by_id[p]) >= own)]


def int_or_none(v) -> int | None:
    s = str(v).strip() if v is not None else ""
    return int(s) if DIGITS_RE.fullmatch(s) else None


def text_of(v) -> str:
    return v if isinstance(v, str) else ""


def row_result(r: dict) -> str | None:
    """passed | final | failed | registered | None (abgemeldet, krank ...)"""
    s = text_of(r.get("status")).strip().lower()
    # bestanden wie im Notenspiegel (grades_model.is_passed, Regel des Inhabers 12.11.2026: QIS ist die Quelle)
    if s in ("bestanden", "anerkannt", "be") or (r.get("level") is not None and r.get("passed") is True):
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
    return r.get("level") == "bereich" or grades_model.is_bereich_text(text_of(r.get("text")))


def fold(text) -> str:
    """klein, Umlaute ausgeschrieben (Bereichsnamen und Modultitel fuer die Typ-Regeln)"""
    return text_of(text).lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")


def area_type_of(name, kind: str, titles: list[str]) -> str:
    """Typ eines Bereichs: aus dem Namen (AREA_TYPE_RULES), sonst aus den Modultiteln (mindestens die Haelfte nennt
    "Seminar" bzw. "Labor"), sonst die Art (pflicht | wahlpflicht | wahl | abschluss)"""
    f = fold(name)
    for t, rx in AREA_TYPE_RULES:
        if rx.search(f):
            return t
    if kind != "abschluss" and len(titles) >= 2:
        for word in ("seminar", "labor"):
            if 2 * sum(1 for x in titles if word in fold(x)) >= len(titles):
                return word
    return kind


def says_last_try(r: dict) -> bool:
    """QIS meldet ausdruecklich den letzten Versuch (Status, Vermerk oder eine andere Zelle als der Titel)"""
    text = text_of(r.get("text")).strip()
    cells = [text_of(r.get("status")), text_of(r.get("vermerk"))] + \
        [c for c in text_of(r.get("raw")).split(" | ") if c.strip() != text]
    return any(LAST_TRY_RE.search(fold(c)) for c in cells)


def max_attempts_of(m: dict, catalog: dict) -> int | None:
    """Hoechstzahl der Versuche: Modul, sonst Katalog (1..20), sonst unbekannt"""
    for v in (m.get("max_attempts"), catalog.get("max_attempts")):
        n = _int_value(v)
        if n is not None and 1 <= n <= 20:
            return n
    return None


def tokens(text) -> list[str]:
    """Woerter (klein, Umlaute ausgeschrieben, nur Buchstaben/Ziffern)"""
    return [t for t in NON_ALNUM_RE.sub(" ", fold(text)).split(" ") if t]


def area_of_bereich(text, area_toks: list[tuple[str, list[str]]]) -> str | None:
    """Bereich, dessen Name als Wortfolge in der QIS-Bereichszeile steht (der laengste, bei Gleichstand der erste)"""
    toks = tokens(text)
    best, best_n = None, 0
    for aid, at in area_toks:
        n = len(at)
        if n > best_n and any(toks[i:i + n] == at for i in range(len(toks) - n + 1)):
            best, best_n = aid, n
    return best


def credits_of(r: dict) -> float:
    """LP einer QIS-Zeile ("5", "7,5"), sonst 0"""
    s = text_of(r.get("credits")).strip()
    return float(s.replace(",", ".")) if CREDITS_RE.fullmatch(s) else 0.0


def _int_value(v) -> int | None:
    """ganze Zahl (auch 5.0) oder None"""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
        return None
    return int(v) if float(v) == int(v) else None


def clean_tracks(v) -> dict:
    """{Gruppe: Bereichs-id}, beide nicht leer, nach Gruppe sortiert"""
    if not isinstance(v, dict):
        return {}
    return {k: v[k] for k in sorted(v) if isinstance(k, str) and k and isinstance(v[k], str) and v[k]}


def clean_placements(v) -> dict:
    """{Modul-id: Semestername ("WiSe 27/28")}, eigene Lage je Modul; nach Modul-id sortiert"""
    if not isinstance(v, dict):
        return {}
    out = {}
    for k in sorted(v):
        t = parse_term(v[k])
        if isinstance(k, str) and k and t is not None:
            out[k] = term_name(t)
    return out


def clean_ids(v) -> list[str]:
    """Liste von ids: Texte, nicht leer, sortiert, ohne Doppelte"""
    return sorted({e for e in v if isinstance(e, str) and e}) if isinstance(v, list) else []


def clean_custom(v) -> list[dict]:
    """Eigene Eintraege (z. B. Studium generale aus einer anderen Fakultaet): {id, title, lp, area, semester,
    workload_h, content}; Titel noetig (hoechstens 120 Zeichen), LP 0..60, Fachsemester 1..20 oder null; ids
    "eigen-<n>", fehlende neu. Seit 26.11.2026 (Wunsch des Inhabers: was die App nicht erkennt, selbst anlegen, mit
    Stunden und Inhalt): Arbeitsaufwand in Stunden 1..2000 oder null, Inhalt als Text (hoechstens 2000 Zeichen) oder null"""
    items = [c for c in v if isinstance(c, dict)] if isinstance(v, list) else []
    rows, used = [], set()
    for c in items:
        title = text_of(c.get("title")).strip()[:MAX_CUSTOM_TITLE].strip()
        if not title:
            continue
        lp = num(c.get("lp"))
        lp = lp if lp is not None and 0 <= lp <= 60 else 0
        lp = int(lp) if float(lp) == int(lp) else float(lp)
        sem = _int_value(c.get("semester"))
        cid = text_of(c.get("id"))
        cid = cid if CUSTOM_ID_RE.fullmatch(cid) and cid not in used else None
        if cid:
            used.add(cid)
        hours = _int_value(c.get("workload_h"))
        content = text_of(c.get("content")).strip()[:MAX_CUSTOM_CONTENT].strip()
        rows.append({"id": cid, "title": title, "lp": lp, "area": text_of(c.get("area")) or None,
                     "semester": sem if sem is not None and 1 <= sem <= 20 else None,
                     "workload_h": hours if hours is not None and 1 <= hours <= MAX_CUSTOM_HOURS else None,
                     "content": content or None})
        if len(rows) >= MAX_CUSTOM:
            break
    n = 1
    for r in rows:
        if r["id"] is None:
            while f"eigen-{n}" in used:
                n += 1
            r["id"] = f"eigen-{n}"
            used.add(r["id"])
    return rows


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

PO_YEAR_RE = re.compile(r"PO[- ]?Version:?\s*([0-9]{4})", re.I)


def current_label(labels: list) -> str | None:
    """Studiengang der laufenden Einschreibung aus mehreren QIS-/LSF-Bezeichnungen (14.11.2026, erstes echtes
    Hildesheim-Konto: nach einem Wechsel von Erziehungswissenschaft zu Sozialpaedagogik hatte nur der alte Studiengang
    Leistungen und gewann als "haeufigster"). Die neueste PO-Version gewinnt, bei Gleichstand die meisten Zeilen, dann
    die zuerst gesehene."""
    names = [text_of(n).strip() for n in labels]
    names = [n for n in names if n]
    if not names:
        return None
    counts = Counter(names)
    order = list(dict.fromkeys(names))

    def year(n: str) -> int:
        m = PO_YEAR_RE.search(n)
        return int(m.group(1)) if m else -1
    return max(order, key=lambda n: (year(n), counts[n], -order.index(n)))


def program_of(grades: list[dict]) -> str | None:
    """Studiengang aus QIS `abschluss` ("Technische Informatik (PO-Version 2017)" -> "Technische Informatik"), der
    aktuelle bei mehreren (`current_label`)"""
    label = abschluss_of(grades)
    if not label:
        return None
    # LSF Hildesheim ("Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022"):
    # nur der Name, sonst passte nie ein Katalog
    from .study_catalog import parse_abschluss
    name = parse_abschluss(label)["name"] if label.lower().startswith("abschluss:") else PROGRAM_RE.sub("", label).strip()
    return name or None


def abschluss_of(grades: list[dict]) -> str | None:
    return current_label([r.get("abschluss") for r in grades])


def programs_of(grades: list[dict], university: str, registry: dict | None = None) -> list[dict]:
    """Alle Studiengaenge im Notenspiegel, der aktuelle zuerst: [{label, program, degree, po, code, grades}] (code nur,
    wenn das Register den Studiengang kennt). Fuer die Frage "Welchen Studiengang studierst du gerade?"."""
    from .study_catalog import load_registry, match_program, name_key, parse_abschluss
    reg = registry or load_registry()
    labels = [text_of(r.get("abschluss")).strip() for r in grades]
    labels = [x for x in labels if x]
    counts = Counter(labels)
    rest = list(dict.fromkeys(labels))
    order = []
    while rest:
        best = current_label(rest)
        order.append(best)
        rest = [x for x in rest if x != best]
    out, seen = [], set()
    for label in order:
        m = match_program(label, university, reg) or {}
        parsed = parse_abschluss(label)
        program = m.get("program") or parsed["name"] or label
        key = m.get("code") or name_key(program)
        if key in seen:
            continue
        seen.add(key)
        out.append({"label": label, "program": program, "degree": m.get("degree") or parsed["degree"],
                    "po": m.get("po") or parsed["po"], "code": m.get("code"), "grades": counts[label]})
    return out


# Mehr-Faecher-Studiengang (26.11.2026, echtes Konto Uni Hildesheim): das LSF fuehrt jedes Fach eines Zwei-Faecher-
# Bachelors als eigenen "Studiengang" unter demselben Abschluss ("Abschluss: [B5] Polyvalenter Zwei-Fächer-Bachelor …
# Studiengang: [105] Mathematik PO-Version: 2025", dazu Wirtschaft, Erziehungs- und Sozialwissenschaften, Philosophie).
# Vorher galten die anderen Faecher als "Früheres Studium" oder zaehlten im Katalog des gewaehlten Fachs mit
# ("69 von 72 LP"). Sie sind zusammen EIN Studiengang: Bachelor 180 LP, Master 120 LP.
COMBINED_RE = re.compile(r"zwei[- ]?f(?:ä|ae)cher|zwei[- ]?fach|2[- ]?f(?:ä|ae)cher|mehr[- ]?f(?:ä|ae)cher|mehrfach|kombi|lehramt", re.I)
HIS_LABEL_RE = re.compile(r"^\s*Abschluss:\s*((?:\[[^\]]*\]\s*)?.*?)\s*Studiengang:\s*(?:\[[^\]]*\]\s*)?(.*?)\s*$", re.I | re.S)
ACCOUNT_PREFIX = "Gesamtkonto: "


def his_label(label) -> dict | None:
    """'Abschluss: [B5] <Abschluss> Studiengang: [105] <Fach> PO-Version: 2025' -> {degree_key, degree, subject, po};
    None fuer andere Bezeichnungen (QIS der LUH)"""
    text = text_of(label).strip()
    m = HIS_LABEL_RE.match(text)
    if not m:
        return None
    po = PO_YEAR_RE.search(text)
    subject = re.sub(r"PO[- ]?Version:?\s*[0-9]{4}.*$", " ", m.group(2), flags=re.I | re.S)
    subject = re.sub(r"\s+", " ", subject).strip(" ,;:-.")
    key = re.sub(r"\s+", " ", m.group(1)).strip()
    degree = re.sub(r"^\[[^\]]*\]\s*", "", key).strip()
    return {"degree_key": key, "degree": degree, "subject": subject or "Ohne Angabe", "po": po.group(1) if po else None}


def combined_degree(grades: list[dict]) -> dict | None:
    """Faecher eines Mehr-Faecher-Studiengangs im Notenspiegel: {degree, labels (Reihenfolge des ersten Auftretens)}.
    Nur wenn mindestens zwei Faecher denselben Abschluss tragen und der Abschluss ein Mehr-Faecher-Studiengang ist
    (COMBINED_RE); ein Wechsel des Studiengangs im selben Abschluss ("Bachelor") bleibt "Früheres Studium". Bei
    mehreren solchen Abschluessen der des aktuellen Studiengangs (`abschluss_of`)."""
    groups: dict[str, dict] = {}
    for r in grades:
        label = text_of(r.get("abschluss")).strip()
        h = his_label(label) if label else None
        if not h or not COMBINED_RE.search(h["degree"]):
            continue
        g = groups.setdefault(h["degree_key"], {"degree": h["degree"], "labels": []})
        if label not in g["labels"]:
            g["labels"].append(label)
    groups = {k: g for k, g in groups.items() if len(g["labels"]) >= 2}
    if not groups:
        return None
    current = his_label(abschluss_of(grades))
    if current and current["degree_key"] in groups:
        return groups[current["degree_key"]]
    return max(groups.values(), key=lambda g: len(g["labels"]))


def degree_total(name: str) -> int | None:
    """LP des ganzen Studiengangs: Bachelor 180, Master 120, sonst unbekannt"""
    n = text_of(name).lower()
    return 180 if "bachelor" in n else 120 if "master" in n else None


def degree_overview(grades: list[dict], current: list[dict], lp_manual=None) -> dict | None:
    """Ueberblick ueber den ganzen Mehr-Faecher-Studiengang: LP aller Faecher (dieselbe Zaehlung wie Uni & Noten,
    `lp_counted`), die Gesamtzahl des Studiengangs und je Fach Name, PO, LP, bestandene Leistungen; `current` sind die
    Zeilen des Fachs, dessen Katalog gerade geplant wird. Dazu, was das LSF selbst als Gesamtkonto nennt (LP und
    vorlaeufige Gesamtnote), wenn es im Notenspiegel steht. None ohne Mehr-Faecher-Studiengang."""
    deg = combined_degree(grades)
    if not deg:
        return None
    mine = {text_of(r.get("abschluss")).strip() for r in current}
    subjects = []
    for label in deg["labels"]:
        rows = [r for r in grades if text_of(r.get("abschluss")).strip() == label and r.get("source") != "anmeldung"]
        h = his_label(label)
        subjects.append({"label": label, "program": h["subject"], "po": h["po"],
                         "lp_done": round(sum(num(r.get("lp_counted")) or 0 for r in rows), 1),
                         "passed": sum(1 for r in rows if r.get("counted")), "current": label in mine})
    official_lp = official_grade = None
    for r in grades:
        text = text_of(r.get("text"))
        if text.startswith(ACCOUNT_PREFIX) and "gesamtnote" in text.lower() and text_of(r.get("abschluss")).strip() in deg["labels"]:
            official_lp = credits_of(r) or None
            raw = [c.strip() for c in text_of(r.get("raw")).split(" | ")]
            official_grade = next((c for c in raw[1:] if re.fullmatch(r"[0-9],[0-9]{1,2}", c) and c not in ("0,0", "0,00")), None)
            break
    lp_done = round(sum(s["lp_done"] for s in subjects) + (lp_manual or 0), 1)
    return {"name": deg["degree"], "lp_total": degree_total(deg["degree"]), "lp_done": lp_done, "official_lp": official_lp,
            "official_grade": official_grade, "subjects": subjects}


def passed_terms(grades: list[dict]) -> list[dict]:
    """Bestanden je Semester (26.11.2026, Wunsch des Inhabers: "erkennen, in welchem Semester man was bestanden hat"):
    jede zaehlende Leistung des Notenspiegels mit ihrem Semester (Spalte "Semester", sonst aus dem Pruefungsdatum,
    `semester_norm`), aelteste zuerst; Leistungen ohne erkennbares Semester am Ende unter term None. Unabhaengig vom
    Katalog, fuer alle Faecher: [{term, name, lp, rows: [{text, lp, note, program}]}]."""
    by_term: dict = {}
    for r in grades:
        if not r.get("counted") or r.get("source") == "anmeldung":
            continue
        t = row_term(r)
        e = by_term.setdefault(t, {"term": t, "name": term_name(t) if t is not None else None, "lp": 0.0, "rows": []})
        lp = num(r.get("lp_counted")) or 0
        e["lp"] += lp
        h = his_label(r.get("abschluss"))
        e["rows"].append({"text": r.get("text"), "lp": lp, "note": r.get("note") or None,
                          "program": h["subject"] if h else None})
    out = [by_term[t] for t in sorted(k for k in by_term if k is not None)]
    if None in by_term:
        out.append(by_term[None])
    for e in out:
        e["lp"] = round(e["lp"], 1)
    return out


def earlier_studies(rows: list[dict]) -> list[dict]:
    """Leistungen anderer Studiengaenge als "Früheres Studium" (14.11.2026, Studiengangswechsel): je Studiengang Name,
    Abschluss, Anzahl, LP der bestandenen und die Zeilen, wie sie im Notenspiegel stehen; Reihenfolge des ersten
    Auftretens. Zaehlen nicht im aktuellen Studiengang."""
    from .study_catalog import parse_abschluss
    out: dict[str, dict] = {}
    for r in rows:
        label = text_of(r.get("abschluss")).strip()
        e = out.get(label)
        if e is None:
            parsed = parse_abschluss(label) if label.lower().startswith("abschluss:") else None
            name = (parsed["name"] if parsed else PROGRAM_RE.sub("", label).strip()) or "Ohne Angabe"
            e = out[label] = {"label": label, "program": name, "count": 0, "lp": 0.0, "rows": []}
        e["count"] += 1
        if "lp_counted" in r:
            # bereinigte Zeilen (grades_model.model): dieselbe Summe wie Uni & Noten, Modul und Teilleistung nie doppelt
            e["lp"] += num(r.get("lp_counted")) or 0
        elif text_of(r.get("status")).strip().lower().startswith("bestanden"):
            e["lp"] += credits_of(r)
        e["rows"].append({"text": r.get("text"), "note": r.get("note"), "status": r.get("status"),
                          "credits": r.get("credits"), "semester": r.get("semester")})
    return list(out.values())


def grades_for_catalog(grades: list[dict], catalog: dict | None, university: str, registry: dict | None = None) -> list[dict]:
    """Leistungen eines anderen Studiengangs nicht in diesen Katalog mischen (14.11.2026): eine Zeile, deren
    `abschluss` laut Register zu einem anderen Studiengang gehoert als der Katalog, faellt weg. Zeilen ohne `abschluss`
    und mit einer Bezeichnung, die das Register nicht kennt, bleiben; anerkannte Leistungen stehen im Notenspiegel unter
    dem neuen Studiengang und zaehlen darum mit."""
    if not catalog:
        return grades
    from .study_catalog import load_registry, match_program, name_key
    want = name_key(text_of(catalog.get("program")))
    if not want:
        return grades
    reg = registry or load_registry()
    belongs: dict[str, bool] = {}
    # Mehr-Faecher-Studiengang: ist eines seiner Faecher das Fach dieses Katalogs, gehoeren die anderen Faecher nicht
    # hierher - auch wenn das Register sie nicht kennt (26.11.2026: ihre LP zaehlten im Katalog Mathematik mit)
    deg = combined_degree(grades)
    siblings = set(deg["labels"]) if deg else set()
    exact = {x: (lambda m: m is not None and name_key(m.get("program") or "") == want)(match_program(x, university, reg))
             for x in siblings}
    strict = any(exact.values())
    out = []
    for g in grades:
        label = text_of(g.get("abschluss")).strip()
        if label and label not in belongs:
            if strict and label in siblings:
                belongs[label] = exact[label]
            else:
                m = match_program(label, university, reg)
                belongs[label] = m is None or name_key(m.get("program") or "") == want
        if not label or belongs[label]:
            out.append(g)
    return out


def pick_catalog(catalogs: list[dict], settings: dict, grades: list[dict]) -> tuple[dict | None, str | None]:
    """(Katalog, None) oder (None, Grund-Code: no_catalog | no_catalog_po). Gewaehlte PO (po oder Kuerzel), dann der
    Studiengang aus QIS, dann die neueste PO, das neueste Katalogsemester, das Kuerzel."""
    cands = [c for c in catalogs if valid_catalog(c)]
    if not cands:
        return None, "no_catalog"
    # eingefuegter Link: der Katalog von genau diesem Link gilt (14.11.2026, Hildesheim: Link zum Modulhandbuch
    # Sozialpaedagogik, der Notenspiegel nennt nur Erziehungswissenschaft)
    link = text_of(settings.get("catalog_url")).strip()
    linked = [c for c in cands if link and isinstance(c.get("source"), dict) and c["source"].get("url") == link]
    if linked:
        cands = linked
    po = "" if linked else text_of(settings.get("po")).strip()
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

# Zusammengesetzte Modultitel (12.11.2026, iPad eines Nutzers, Maschinenbau B.Sc.): der Katalog nennt "Thermodynamik I /
# Chemie" und "Tutorien oder Studium Generale", das QIS die Teile ("Thermodynamik I", "Grundzüge der Chemie", Modul
# "Studium Generale"). Vorher passte nur der ganze Titel: die Leistungen und Anmeldungen standen als "nicht
# zugeordnet" da und das Modul blieb offen. " / " heisst: alle Teile noetig; " oder ": einer reicht.
PART_SPLIT_RE = re.compile(r"\s+/\s+|\s+oder\s+", re.I)
OR_RE = re.compile(r"\s+oder\s+", re.I)
# Teile kuerzer als das ("II") ordnen nichts zu
MIN_PART_KEY = 4


def title_parts(title) -> tuple[list[tuple[str, str]], bool]:
    """Teile eines zusammengesetzten Modultitels als (Text, Namensschluessel) und ob alle noetig sind ("/") oder einer
    reicht ("oder"); ([], False) fuer einen einfachen Titel"""
    t = text_of(title).strip()
    raw = [p.strip() for p in PART_SPLIT_RE.split(t)]
    if len(raw) < 2 or any(not p for p in raw):
        return [], False
    return [(p, name_key(p)) for p in raw], not OR_RE.search(t)


def part_index(text, parts: list[tuple[str, str]]) -> int | None:
    """Teil, den ein QIS-Text nennt: gleicher Namensschluessel, sonst endet der Text mit dem Teil ("Grundzüge der
    Chemie" -> "Chemie"); der laengste Teil gewinnt"""
    k = name_key(text)
    if not k:
        return None
    best, best_n = None, 0
    for i, (_, pk) in enumerate(parts):
        if len(pk) >= MIN_PART_KEY and (k == pk or k.endswith(" " + pk)) and len(pk) > best_n:
            best, best_n = i, len(pk)
    return best


# Modulbezeichner (26.11.2026, echtes Konto Uni Hildesheim): das Modulhandbuch nennt "Basismodul 1: Aufbau der
# Zahlbereiche", der Notenspiegel des LSF "BM 1: Aufbau der Zahlbereiche" (dazu "AM 1: …", "VM 1: …", "M 3: …"). Vorher
# passte nur der ganze Titel: die Module blieben "offen", ihre Teilmodule ("TM 1: Arithmetik und Algebra …") standen als
# "nicht zugeordnet" da. Jetzt gilt der Name ohne Bezeichner, sonst der Bezeichner selbst (Art und Nummer).
MODULE_WORD_RE = re.compile(r"^\s*([A-Za-zÄÖÜäöüß]*?)[Mm]odul\s*([0-9]{1,2})\s*:\s*(.*)$")
MODULE_ABBR_RE = re.compile(r"^\s*([A-ZÄÖÜ]{0,3})M\s*([0-9]{1,2})\s*:\s*(.*)$")
PENDING_STATUS = "prüfung vorhanden"
PARTLY_REASON = "Angefangen – Rest nachholen"
LATE_REASON = "Noch nicht abgelegt – nachholen"


def module_tag(text) -> tuple[str, str] | None:
    """("#b1", Name ohne Bezeichner) fuer "Basismodul 1: Aufbau der Zahlbereiche" und "BM 1: Aufbau der Zahlbereiche";
    ("#1", …) fuer "Modul 1: …" / "M 1: …"; None ohne Bezeichner mit Nummer und Doppelpunkt"""
    t = text_of(text)
    m = MODULE_WORD_RE.match(t) or MODULE_ABBR_RE.match(t)
    if not m:
        return None
    return "#" + fold(m.group(1))[:1] + str(int(m.group(2))), m.group(3).strip()


def _tagged_module(text, by_key: dict) -> str | None:
    """Katalogmodul einer Zeile mit Modulbezeichner: erst der Name ohne Bezeichner, dann der Bezeichner"""
    tag = module_tag(text)
    if tag is None:
        return None
    k = name_key(tag[1])
    mid = by_key.get(k) if k else None
    return mid if mid is not None else by_key.get(tag[0])


def _index(mods: list[dict]) -> tuple[dict, dict, dict]:
    """(Pruefungsnummer -> Modul-id, Namensschluessel -> Modul-id, Teile -> Modul-id), jeweils das erste Modul; ein Teil
    nur, wenn kein Modul so heisst. Titel mit Modulbezeichner ("Basismodul 1: …") stehen zusaetzlich unter dem Namen
    ohne Bezeichner und unter dem Bezeichner ("#b1"; nur wenn ihn genau ein Modul traegt), ganze Titel gehen vor."""
    by_code: dict[str, str] = {}
    by_key: dict[str, str] = {}
    by_part: dict[str, list[tuple[str, str]]] = {}
    for m in mods:
        code = text_of(m.get("code")).strip()
        if code and code not in by_code:
            by_code[code] = m["id"]
        k = name_key(m.get("title"))
        if k and k not in by_key:
            by_key[k] = m["id"]
    tags: dict[str, list[str]] = {}
    for m in mods:
        tag = module_tag(m.get("title"))
        if tag is None:
            continue
        tags.setdefault(tag[0], []).append(m["id"])
        k = name_key(tag[1])
        if k and k not in by_key:
            by_key[k] = m["id"]
    for t, ids in tags.items():
        if len(ids) == 1:
            by_key[t] = ids[0]
    for m in mods:
        parts, _ = title_parts(m.get("title"))
        if parts and m["id"] not in by_part:
            by_part[m["id"]] = [p for p in parts if p[1] not in by_key]
    return by_code, by_key, by_part


def _part_module(text, by_part: dict) -> str | None:
    """Modul, dessen Titel einen Teil nennt, den der Text nennt (der laengste Teil gewinnt, dann das erste Modul)"""
    best, best_n = None, 0
    for mid, parts in by_part.items():
        i = part_index(text, parts)
        if i is not None and len(parts[i][1]) > best_n:
            best, best_n = mid, len(parts[i][1])
    return best


def _row_module(r: dict, by_code: dict, by_key: dict, by_part: dict | None = None) -> str | None:
    """Katalogmodul einer QIS-Zeile: Pruefungsnummer, sonst Name; sonst das Modul ihrer QIS-Modulzeile (`modul_nr`,
    `modul_text` aus grades_model, 12.11.2026: Leistungen eines Moduls ohne eigene Pruefungen wie "Studium Generale"
    gehoeren zu diesem Modul, vorher standen sie als "nicht zugeordnet" da); sonst ein Teil eines zusammengesetzten
    Titels (Name, dann Modulzeile)"""
    nr = text_of(r.get("pruefungsnr")).strip()
    mid = by_code.get(nr) if nr else None
    if mid is None:
        mid = by_key.get(name_key(r.get("text")))
    if mid is None:
        mid = _tagged_module(r.get("text"), by_key)             # "BM 1: Aufbau der Zahlbereiche" (LSF Hildesheim)
    if mid is None:
        mnr = text_of(r.get("modul_nr")).strip()
        mid = by_code.get(mnr) if mnr else None
        if mid is None and text_of(r.get("modul_text")).strip():
            mid = by_key.get(name_key(r.get("modul_text")))
            if mid is None:
                mid = _tagged_module(r.get("modul_text"), by_key)
    if mid is None and by_part:
        mid = _part_module(r.get("text"), by_part)
        if mid is None and text_of(r.get("modul_text")).strip():
            mid = _part_module(r.get("modul_text"), by_part)
    return mid


def _parts_state(m: dict, passed: list[dict]) -> tuple[list[str], list[str]]:
    """(Texte der bestandenen QIS-Zeilen, offene Teile laut Katalog) eines Moduls, dessen Teile alle noetig sind; ([], [])
    wenn das Modul einfach ist, einer reicht ("oder") oder eine bestandene Zeile fuer das ganze Modul steht (gleicher
    Titel, Nummer oder eine Modulzeile, die keinen Teil nennt)"""
    parts, need_all = title_parts(m.get("title"))
    if not parts or not need_all or not passed:
        return [], []
    title_key, code = name_key(m.get("title")), text_of(m.get("code")).strip()
    done: set[int] = set()
    for r in passed:
        if name_key(r.get("text")) == title_key or (code and text_of(r.get("pruefungsnr")).strip() == code):
            return [], []
        i = part_index(r.get("text"), parts)
        if i is None:
            if r.get("level") not in (None, "pruefung"):
                return [], []                               # Modulzeile unter anderem Namen: das ganze Modul
            continue
        done.add(i)
    if len(done) == len(parts):
        return [], []
    names: list[str] = []
    for r in passed:
        t = text_of(r.get("text")).strip()
        if t and t not in names:
            names.append(t)
    return names, [p[0] for i, p in enumerate(parts) if i not in done]


def _exam_key(r: dict) -> str:
    """Dieselbe Leistung ueber mehrere Versuche: Pruefungsnummer, sonst Namensschluessel"""
    return text_of(r.get("pruefungsnr")).strip() or name_key(r.get("text"))


def _begun(rows: list[dict]) -> tuple[list[str], float | int | None, list[dict]] | None:
    """Angefangenes Modul (26.11.2026, LSF Hildesheim): die Modulzeile selbst steht auf "Prüfung vorhanden" (keine
    Modulzeile bestanden), darunter sind Teilmodule bestanden. Vorher galt das Modul damit als bestanden. Ergebnis:
    (Namen der bestandenen Teile mit LP, ihre LP wie in Uni & Noten, Zeilen ohne die bestandenen Teile und ihre
    frueheren Fehlversuche); None, wenn das Modul nicht so gefuehrt wird."""
    own = [r for r in rows if r.get("level") == "modul"]
    if not any(text_of(r.get("status")).strip().lower() == PENDING_STATUS for r in own) \
            or any(row_result(r) == "passed" for r in own):
        return None
    got = [r for r in rows if r.get("level") == "pruefung" and row_result(r) == "passed"]
    keys = {_exam_key(r) for r in got}
    lp = round(sum(num(r.get("lp_counted")) or 0 for r in got), 1)
    lp = int(lp) if float(lp) == int(lp) else lp
    names: list[str] = []
    for r in got:
        t = PART_SPLIT_RE.split(text_of(r.get("text")).strip())[0].strip()
        if t and t not in names and (num(r.get("lp_counted")) or 0) > 0:
            names.append(t)
    return names, (lp if lp > 0 else None), [r for r in rows if _exam_key(r) not in keys]


def _manual_module(r: dict, ids: set, by_code: dict, by_key: dict, by_part: dict) -> str | None:
    """Katalogmodul einer selbst eingetragenen Zeile: ihr `module_id`, sonst wie eine QIS-Zeile (Kuerzel, Name)"""
    mid = r.get("module_id")
    return mid if isinstance(mid, str) and mid in ids else _row_module(r, by_code, by_key, by_part)


def _match(mods: list[dict], grades: list[dict]) -> tuple[dict, list[str]]:
    """{Modul-id: [Zeilen]} und die nicht zugeordneten Texte (sortiert, ohne Doppelte)"""
    by_code, by_key, by_part = _index(mods)
    ids = {m["id"] for m in mods}
    hist: dict[str, list[dict]] = {}
    unmatched: set[str] = set()
    for r in grades:
        if not isinstance(r, dict):
            continue
        # selbst eingetragen (20.11.2026, app/grades_manual.py): zu ihrem Katalogmodul, sonst wie eine QIS-Zeile; nie
        # unter "nicht zugeordnet" (das sind QIS-Zeilen)
        if r.get("source") == MANUAL:
            mid = _manual_module(r, ids, by_code, by_key, by_part)
            if mid is not None:
                hist.setdefault(mid, []).append(r)
            continue
        # Bereichszeile nur, wenn kein Katalogmodul so heisst (11.11.2026: "Vertiefung der Betriebssysteme" ist im
        # TI-Katalog ein Wahlpflichtmodul, die Bereichsregel "Vertiefung ..." hatte die bestandene Leistung verschluckt)
        mid = _row_module(r, by_code, by_key, by_part)
        if mid is None and is_bereich(r):
            continue
        if mid is None:
            if text_of(r.get("text")).strip():
                unmatched.add(text_of(r.get("text")).strip())
            continue
        hist.setdefault(mid, []).append(r)
    return hist, sorted(unmatched)


def _best_passed(passed: list[dict]) -> dict:
    """Massgebliche bestandene Zeile: die neueste nach Semester; QIS-Zeilen vor selbst eingetragenen (20.11.2026)"""
    pool = [r for r in passed if r.get("source") != MANUAL] or passed
    best = pool[0]
    for r in pool[1:]:
        if (row_term(r) or -1) >= (row_term(best) or -1):
            best = r
    return best


def _attempts(rows: list[dict], max_attempts: int | None = None) -> tuple[int, int | None, bool, bool, bool]:
    """(Fehlversuche, Semester des letzten Fehlversuchs, endgueltig, Versuchsnummer aus QIS, QIS meldet letzten Versuch).
    Endgueltig nur, wenn QIS es meldet oder die bekannte Hoechstzahl erreicht ist (11.11.2026)"""
    known = any(int_or_none(r.get("versuch")) for r in rows)
    last = any(says_last_try(r) for r in rows)
    failed = [r for r in rows if row_result(r) in ("failed", "final")]
    if not failed:
        return 0, None, False, known, last
    versuche = [int_or_none(r.get("versuch")) or 0 for r in failed]
    terms = {row_term(r) for r in failed}
    # ohne Versuchsspalte: jede nicht bestandene Pruefung (Semester, Datum) ist ein Versuch; Modulzeilen nur, wenn es
    # keine Pruefungszeilen gibt (sonst stuenden Modul und Pruefung desselben Versuchs doppelt da)
    exams = [r for r in failed if r.get("level") == "pruefung"] or failed
    tries = {(row_term(r), text_of(r.get("datum")).strip()) for r in exams}
    n = max(max(versuche), len(terms), len(tries))
    seen = [t for t in terms if t is not None]
    final = any(row_result(r) == "final" for r in failed) or (max_attempts is not None and n >= max_attempts)
    return n, (max(seen) if seen else None), final, known, last


def effective_modules(catalog: dict) -> tuple[list[dict], list[dict]]:
    """Module des Katalogs (ohne Doppelte) mit der Art, die der Plan nutzt, und die als Wahl erkannten Bereiche.
    Wahl statt Pflicht (11.11.2026): haben die Pflichtmodule eines Bereichs zusammen mehr als das 1,5-fache seiner LP
    (Obergrenze, sonst Bedarf; ohne Angabe mehr als der ganze Studiengang), ist der Bereich eine Wahl (z. B. ETBSc17:
    196 Module mit 910 LP in einem Bereich, alle als Pflicht gelesen). Module mit empfohlenem Fachsemester bleiben
    Pflicht, solange sie allein in den Bereich passen."""
    mods: list[dict] = []
    seen: set[str] = set()
    for m in catalog.get("modules") or []:
        if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"] and m["id"] not in seen:
            seen.add(m["id"])
            mods.append(m)
    total = num(catalog.get("total_lp"))
    if not total or total <= 0:
        reg = num(catalog.get("regular_semesters"))
        total = (int(reg) if reg and reg > 0 else 6) * TARGET_LP
    found: list[dict] = []
    changed: set[str] = set()
    areas_seen: set[str] = set()
    for a in catalog.get("areas") or []:
        if not isinstance(a, dict) or not isinstance(a.get("id"), str) or not a["id"] or a["id"] in areas_seen:
            continue
        areas_seen.add(a["id"])
        pf = [m for m in mods if m.get("area") == a["id"] and text_of(m.get("kind")) not in ELECTIVE_KINDS + ("abschluss",)]
        lp = sum(lp_of(m) for m in pf)
        mx, req = num(a.get("lp_max")), num(a.get("lp_required"))
        cap = mx if mx and mx > 0 else (req if req and req > 0 else None)
        if not pf or lp <= (cap * CHOICE_FACTOR if cap is not None else total):
            continue
        bound = cap if cap is not None else total
        fixed = [m for m in pf if isinstance(num(m.get("semester")), (int, float)) and num(m.get("semester")) >= 1]
        keep = {m["id"] for m in fixed} if sum(lp_of(m) for m in fixed) <= bound else set()
        conv = [m for m in pf if m["id"] not in keep]
        changed |= {m["id"] for m in conv}
        found.append({"area": a["id"], "name": text_of(a.get("name")), "n": len(conv), "lp": sum(lp_of(m) for m in conv),
                      "cap": cap, "total": total})
    if changed:
        mods = [dict(m, kind="wahlpflicht") if m["id"] in changed else m for m in mods]
    return mods, found


def compute(catalog: dict, grades: list[dict], settings: dict, today: str) -> dict:
    """Der volle Stand (fuer Plan und Moduldetail): {plan, state, hist}"""
    mods, recognized = effective_modules(catalog)
    order = {m["id"]: i for i, m in enumerate(mods)}
    by_id = {m["id"]: m for m in mods}
    current = current_term(today)
    hist, unmatched = _match(mods, grades)

    # Studienbeginn: Einstellung, sonst das frueheste Semester mit einer QIS-Leistung (Semesterspalte oder Datum);
    # liegt eine QIS-Leistung vor dem eingestellten Beginn, gilt das QIS (12.11.2026: hoehere Semester bekamen sonst den
    # Beginn = aktuelles Semester, weil das Einstellungsblatt ihn ungefragt so speicherte, und alles Bestandene rutschte
    # in dieses Semester). Pruefungsanmeldungen zaehlen nicht (sie liegen im aktuellen Semester).
    terms = [row_term(r) for r in grades if isinstance(r, dict) and not is_bereich(r) and r.get("source") != "anmeldung"]
    known = [t for t in terms if t is not None]
    start = parse_term(settings.get("start_term"))
    if start is None or (known and min(known) < start):
        start = min(known) if known else current
    regular = num(catalog.get("regular_semesters"))
    regular = int(regular) if regular and regular > 0 else 6
    last_regular = start + regular - 1
    lower = max(current, start)

    el = settings.get("electives")
    chosen = [e for e in el if isinstance(e, str)] if isinstance(el, list) else []

    def sem_of(m: dict) -> int | None:
        s = num(m.get("semester"))
        return int(s) if s is not None and s >= 1 else None

    # Bereiche (Wahlbereiche, 05.11.2026): Mitglieder aus module.area und `areas[].modules` (ein Modul kann in mehreren
    # Bereichen waehlbar sein), Art aus den Modulen, Typ aus dem Namen, Gruppen fuer Schwerpunkt/Nebenfach (eins waehlen)
    area_list: list[dict] = []
    area_by: dict[str, dict] = {}
    for a in catalog.get("areas") or []:
        if isinstance(a, dict) and isinstance(a.get("id"), str) and a["id"] and a["id"] not in area_by:
            area_by[a["id"]] = a
            area_list.append(a)
    members: dict[str, list[str]] = {}
    for a in area_list:
        listed = {x for x in a.get("modules") or [] if isinstance(x, str)} if isinstance(a.get("modules"), list) else set()
        members[a["id"]] = [m["id"] for m in mods if m.get("area") == a["id"] or m["id"] in listed]
    member_sets = {aid: set(ids) for aid, ids in members.items()}
    mem_of: dict[str, list[str]] = {}
    for m in mods:
        prim = m.get("area") if isinstance(m.get("area"), str) and m.get("area") in area_by else None
        mem_of[m["id"]] = ([prim] if prim else []) + [a["id"] for a in area_list
                                                       if a["id"] != prim and m["id"] in member_sets[a["id"]]]
    akind: dict[str, str] = {}
    atype: dict[str, str] = {}
    for a in area_list:
        aid = a["id"]
        kinds = [text_of(by_id[i].get("kind")) for i in members[aid]]
        if text_of(a.get("kind")) == "abschluss" or (kinds and all(k == "abschluss" for k in kinds)):
            k = "abschluss"
        elif "wahlpflicht" in kinds:
            k = "wahlpflicht"
        elif "wahl" in kinds:
            k = "wahl"
        elif kinds:
            k = "pflicht" if num(a.get("lp_max")) is None else "wahlpflicht"
        else:
            k = text_of(a.get("kind")) if text_of(a.get("kind")) in ("pflicht", "wahlpflicht", "wahl") else "pflicht"
        akind[aid] = k
        t = text_of(a.get("type"))
        atype[aid] = t if t in AREA_TYPES else area_type_of(a.get("name"), k,
                                                            [text_of(by_id[i].get("title")) for i in members[aid]])
    groups: dict[str, list[str]] = {}
    for a in area_list:
        g = text_of(a.get("group")) or (atype[a["id"]] if atype[a["id"]] in GROUP_TYPES else "")
        if g:
            groups.setdefault(g, []).append(a["id"])
    groups = {g: ids for g, ids in groups.items() if len(ids) >= 2}
    group_of = {aid: g for g, ids in groups.items() for aid in ids}
    # gewaehlter Schwerpunkt je Gruppe: Einstellung, sonst der mit den meisten LP bestandener/angemeldeter Module
    wanted = clean_tracks(settings.get("tracks"))
    track: dict[str, str] = {}
    track_auto: dict[str, bool] = {}
    for g, ids in groups.items():
        if wanted.get(g) in ids:
            track[g], track_auto[g] = wanted[g], False
            continue
        best, score = None, 0
        for aid in ids:
            sc = sum(lp_of(by_id[i]) for i in members[aid] if by_id[i].get("area") == aid
                     and any(row_result(r) in ("passed", "registered") for r in hist.get(i, [])))
            if sc > score:
                best, score = aid, sc
        if best is not None:
            track[g], track_auto[g] = best, True
    active = {a["id"] for a in area_list if a["id"] not in group_of or track.get(group_of[a["id"]]) == a["id"]}
    choice = [a["id"] for a in area_list
              if a["id"] in active and akind[a["id"]] in ELECTIVE_KINDS and atype[a["id"]] != "abschluss"]

    # Module im Plan: Pflicht, gewaehlte Wahlmodule und alles aus QIS. "Nicht belegen" (05.11.2026) nimmt ein Modul heraus
    # (ausser QIS kennt es); Pflichtmodule eines nicht gewaehlten Schwerpunkts fehlen ebenso
    excluded = set(clean_ids(settings.get("excluded")))

    def in_plan(m: dict) -> bool:
        if m["id"] in hist:
            return True
        if m["id"] in excluded:
            return False
        if text_of(m.get("kind")) in ELECTIVE_KINDS:
            return m["id"] in chosen
        since = parse_term(m.get("required_from"))           # Pflicht erst ab diesem Studienbeginn (11.11.2026)
        if since is not None and start < since:
            return m["id"] in chosen
        prim = m.get("area")
        return m["id"] in chosen or not (isinstance(prim, str) and prim in group_of and prim not in active)

    included = [m["id"] for m in mods if in_plan(m)]
    # eigene Lage je Modul (verschoben, vorgezogen, auf einen Platz gewaehlt): Semester als Zahl; Bestandenes bleibt
    # im Semester aus QIS
    placed = {k: parse_term(v) for k, v in clean_placements(settings.get("placements")).items()
              if k in included and not any(row_result(r) == "passed" for r in hist.get(k, []))}

    # Plaetze fuer Wahlmodule laut Studienverlaufsplan (`plan_slots`): gewaehlte Wahl(pflicht)module ohne Fachsemester
    # belegen der Reihe nach den ersten freien Platz ihres Bereichs (leere Bereichsliste = jeder); Module mit
    # QIS-Zeilen zuerst, damit Bestandenes die fruehen Plaetze fuellt
    slots = [s for s in catalog.get("plan_slots") or []
             if isinstance(s, dict) and isinstance(num(s.get("semester")), int) and num(s.get("semester")) >= 1]
    slot_sem: dict[str, int] = {}
    taken: set[int] = set()

    def fits_slot(mid: str, s: dict) -> bool:
        areas = s.get("areas") if isinstance(s.get("areas"), list) else []
        return not areas or any(a in areas for a in mem_of[mid])

    own_slot: set[str] = set()
    for mid in included:                                        # eigener Platz: belegt einen Platz in dem Semester
        if mid in placed:
            for k, s in enumerate(slots):
                if k not in taken and start + int(num(s["semester"])) - 1 == placed[mid] and fits_slot(mid, s):
                    taken.add(k)
                    own_slot.add(mid)
                    break
    elect = [i for i in included if text_of(by_id[i].get("kind")) in ELECTIVE_KINDS and sem_of(by_id[i]) is None
             and i not in placed]
    for mid in [i for i in elect if i in hist] + [i for i in elect if i not in hist]:
        for k, s in enumerate(slots):
            if k not in taken and fits_slot(mid, s):
                taken.add(k)
                slot_sem[mid] = int(num(s["semester"]))
                break
    # Wahl(pflicht)modul ohne Fachsemester auf eigener Lage ohne Platz in dem Semester: belegt trotzdem einen Platz seines
    # Bereichs (den naechstgelegenen), sonst bliebe der Platz offen, obwohl das Modul ihn fuellt (05.11.2026)
    for mid in included:
        if mid not in placed or mid in own_slot or text_of(by_id[mid].get("kind")) not in ELECTIVE_KINDS \
                or sem_of(by_id[mid]) is not None:
            continue
        free = [k for k, s in enumerate(slots) if k not in taken and fits_slot(mid, s)]
        if free:
            taken.add(min(free, key=lambda k: (abs(start + int(num(slots[k]["semester"])) - 1 - placed[mid]), k)))

    state: dict[str, dict] = {}
    for mid in included:
        m, rows = by_id[mid], hist.get(mid, [])
        turnus = turnus_of(m.get("turnus"))
        max_n = max_attempts_of(m, catalog)
        passed = [r for r in rows if row_result(r) == "passed"]
        # Modul aus Teilen, die alle noetig sind ("Thermodynamik I / Chemie"): bestanden erst mit allen Teilen oder einer
        # bestandenen Zeile fuer das ganze Modul; bis dahin zaehlen die bestandenen Teile nicht als Fehlversuche
        done_parts, open_parts = _parts_state(m, passed)
        lp_part = None
        if open_parts:
            done = {part_index(r.get("text"), title_parts(m.get("title"))[0]) for r in passed} - {None}
            rows = [r for r in rows if part_index(r.get("text"), title_parts(m.get("title"))[0]) not in done]
            passed = []
        else:
            done_parts = []
            # das LSF fuehrt das Modul als angefangen ("Prüfung vorhanden"): bestandene Teilmodule sind Teile, kein
            # bestandenes Modul; ihre frueheren Fehlversuche zaehlen nicht mehr
            begun = _begun(rows)
            if begun is not None:
                done_parts, lp_part, rows = begun
                passed = []
        failed_n, last_fail, final, known, qis_last = _attempts(rows, max_n)
        registered = [r for r in rows if row_result(r) == "registered"]
        st = {"status": None, "term": None, "attempt": None, "grade": None, "moved_from": None, "reason": None,
              "failed": failed_n, "final": final, "placed": False, "known": known, "max_attempts": max_n,
              "qis_last": qis_last, "parts_done": done_parts, "parts_open": open_parts, "lp_part": lp_part}
        sem = sem_of(m) or slot_sem.get(mid)
        rec = start + sem - 1 if sem else None
        own = placed.get(mid)
        if passed:
            best = _best_passed(passed)
            t = row_term(best)
            if t is None:
                t = min(rec, current) if rec is not None else current
            st.update(status="bestanden", term=max(t, start), attempt=max(failed_n + 1, int_or_none(best.get("versuch")) or 0),
                      grade=text_of(best.get("note")).strip() or None)
            if best.get("source") == MANUAL:
                st["manual"] = True
        elif registered:
            vs = [int_or_none(r.get("versuch")) for r in registered]
            vs = [v for v in vs if v]
            st.update(status="angemeldet", term=current, attempt=max(vs) if vs else failed_n + 1)
        elif failed_n:
            begin = max(last_fail + 1 if last_fail is not None else current, lower)
            st.update(status="nicht_bestanden", term=next_fit(begin, turnus), attempt=failed_n,
                      moved_from=term_name(last_fail) if last_fail is not None else None,
                      reason="Nicht bestanden – nächster Versuch")
            if own is not None and own >= begin:
                st.update(term=own, placed=True)
        elif own is not None:
            st.update(status="plan", term=own, placed=True)
            if own < lower:
                st.update(term=next_fit(lower, turnus), placed=False, moved_from=term_name(own),
                          reason=PARTLY_REASON if lp_part else LATE_REASON)
        elif rec is not None:
            t = next_fit(max(rec, start), turnus)
            st.update(status="plan", term=t)
            if t != rec:
                st.update(moved_from=term_name(rec),
                          reason=f"Wird nur im {'Wintersemester' if turnus == 'WS' else 'Sommersemester'} angeboten")
            if t < lower:
                st.update(term=next_fit(lower, turnus), moved_from=term_name(rec),
                          reason=PARTLY_REASON if lp_part else LATE_REASON)
        else:
            st["status"] = "plan"                                   # ohne Fachsemester: unten auffuellen
        state[mid] = st

    def rest_lp(i: str):
        """LP, die ein Modul im Semester noch kostet: bei einem angefangenen Modul ohne die schon erreichten"""
        part = state[i]["lp_part"]
        return max(lp_of(by_id[i]) - part, 0) if part and state[i]["status"] != "bestanden" else lp_of(by_id[i])

    def load(t: int) -> float:
        return sum(rest_lp(i) for i in included if state[i]["term"] == t)

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
                if st["status"] not in ("plan", "nicht_bestanden") or st["placed"]:
                    continue
                need, need_id = None, None
                for p in plan_prereqs(by_id[mid], by_id):
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
                     and not state[i]["placed"] and text_of(by_id[i].get("kind")) in ELECTIVE_KINDS]
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

    # Eigene Eintraege (z. B. Studium generale einer anderen Fakultaet): Stand aus einer nicht zugeordneten QIS-Zeile
    # mit gleichem Namensschluessel, sonst im gewaehlten Fachsemester (fruehestens jetzt)
    by_code, by_key, by_part = _index(mods)
    loose = [r for r in grades if isinstance(r, dict) and not is_bereich(r) and not (r.get("source") == MANUAL and r.get("module_id") in by_id)
             and _row_module(r, by_code, by_key, by_part) is None]
    custom = []
    for c in clean_custom(settings.get("custom")):
        key = name_key(c["title"])
        rows = [r for r in loose if key and name_key(r.get("text")) == key]
        passed_rows = [r for r in rows if row_result(r) == "passed"]
        area = c["area"] if c["area"] in active else None
        e = {"id": c["id"], "title": c["title"], "code": None, "kind": akind[area] if area else "wahl", "area": area,
             "lp": c["lp"], "semester": c["semester"], "turnus": None, "status": None, "attempt": None, "grade": None,
             "moved_from": None, "reason": None, "last_attempt": False, "attempt_known": False, "max_attempts": None,
             "final": False, "placed": False, "hints": [], "custom": True,
             "workload_h": c["workload_h"], "content": c["content"]}
        if passed_rows:
            best = _best_passed(passed_rows)
            t = row_term(best)
            e.update(status="bestanden", grade=text_of(best.get("note")).strip() or None)
            if best.get("source") == MANUAL:
                e["manual"] = True
            t = max(t if t is not None else current, start)
        elif any(row_result(r) == "registered" for r in rows):
            t = current
            e["status"] = "angemeldet"
        else:
            t = max(start + c["semester"] - 1 if c["semester"] else lower, lower)
            e["status"] = "offen" if t <= current else "geplant"
        custom.append((t, e))

    # Wahlfach aus QIS ohne Katalogmodul (11.11.2026): nicht zugeordnete Leistungen unter einer QIS-Bereichszeile, die
    # einen aktiven Wahlbereich nennt, stehen mit Stand im Plan (wie eigene Eintraege, die gleichnamig vorgehen) und
    # belegen den naechstgelegenen freien Platz ihres Bereichs laut Verlaufsplan
    custom_keys = {name_key(e["title"]) for _, e in custom}
    area_toks = [(aid, tokens(area_by[aid].get("name"))) for aid in choice]
    groups_q: dict[str, list[dict]] = {}
    area_q: dict[str, str] = {}
    ctx = None
    for r in grades:
        if not isinstance(r, dict) or r.get("source") == MANUAL:
            continue
        if _row_module(r, by_code, by_key, by_part) is not None:
            continue
        if is_bereich(r):
            ctx = area_of_bereich(r.get("text"), area_toks)
            continue
        if ctx is None or text_of(r.get("source")) == "anmeldung":
            continue
        key = name_key(r.get("text"))
        if not key or key in custom_keys:
            continue
        groups_q.setdefault(key, []).append(r)
        area_q.setdefault(key, ctx)
    taken_q: set[str] = set()
    for key, rows in groups_q.items():
        area = area_q[key]
        failed_n, last_fail, final, known, qis_last = _attempts(rows)
        passed_rows = [r for r in rows if row_result(r) == "passed"]
        registered = [r for r in rows if row_result(r) == "registered"]
        if not passed_rows and not registered and not failed_n:
            continue                                            # nur abgemeldet, krank ...
        lps = sorted(lp_of(by_id[i]) for i in members[area] if lp_of(by_id[i]) > 0)
        credits = max(credits_of(r) for r in rows)
        lp = credits if credits > 0 else (lps[(len(lps) - 1) // 2] if lps else UNIT_LP)
        lp = int(lp) if float(lp) == int(lp) else float(lp)
        code = next((text_of(r.get("pruefungsnr")).strip() for r in rows if text_of(r.get("pruefungsnr")).strip()), None)
        e = {"id": f"qis-{len(taken_q) + 1}", "title": text_of(rows[0].get("text")).strip(), "code": code,
             "kind": akind[area], "area": area, "lp": lp, "semester": None, "turnus": None, "status": None,
             "attempt": None, "grade": None, "moved_from": None, "reason": None, "last_attempt": False,
             "attempt_known": known, "max_attempts": None, "final": False, "placed": False, "hints": [], "custom": False,
             "qis": True}
        if passed_rows:
            best = passed_rows[0]
            for r in passed_rows[1:]:
                if (row_term(r) or -1) >= (row_term(best) or -1):
                    best = r
            t = max(row_term(best) or current, start)
            e.update(status="bestanden", attempt=max(failed_n + 1, int_or_none(best.get("versuch")) or 0),
                     grade=text_of(best.get("note")).strip() or None)
        elif registered:
            vs = [v for v in (int_or_none(r.get("versuch")) for r in registered) if v]
            t = current
            e.update(status="angemeldet", attempt=max(vs) if vs else failed_n + 1)
        else:
            t = max(last_fail + 1 if last_fail is not None else current, lower)
            e.update(status="nicht_bestanden", attempt=failed_n, final=final,
                     moved_from=term_name(last_fail) if last_fail is not None else None,
                     reason="Nicht bestanden – nächster Versuch")
        e["last_attempt"] = last_attempt({"status": e["status"], "final": final, "qis_last": qis_last,
                                          "max_attempts": None, "attempt": e["attempt"]})
        taken_q.add(e["id"])
        free = [k for k, s in enumerate(slots) if k not in taken
                and (not isinstance(s.get("areas"), list) or not s["areas"] or area in s["areas"])]
        if free:
            taken.add(min(free, key=lambda k: (abs(start + int(num(slots[k]["semester"])) - 1 - t), k)))
        custom.append((t, e))
        unmatched = [u for u in unmatched if u not in {text_of(r.get("text")).strip() for r in rows}]

    # Stand je Bereich: jedes Modul zaehlt einmal, im eigenen Bereich, sonst im ersten aktiven Bereich mit Platz
    target: dict[str, float | None] = {}
    for a in area_list:
        req, mx = num(a.get("lp_required")), num(a.get("lp_max"))
        target[a["id"]] = req if req and req > 0 else (mx if a["id"] in group_of and a["id"] in active and mx else None)
    used = {aid: 0 for aid in area_by}
    done = {aid: 0 for aid in area_by}
    counted: dict[str, list[str]] = {aid: [] for aid in area_by}
    n_done = {aid: 0 for aid in area_by}

    def count(cands: list[str], ident: str, lp, passed: bool, part=None) -> None:
        pick = next((x for x in cands if target[x] is None or used[x] < target[x]), cands[0])
        used[pick] += lp
        counted[pick].append(ident)
        if passed:
            done[pick] += lp
            n_done[pick] += 1
        elif part:
            done[pick] += min(part, lp) if lp else part     # angefangenes Modul: seine erreichten LP (26.11.2026)

    for mid in included:
        cands = [x for x in mem_of[mid] if x in active]
        if cands:
            count(cands, mid, lp_of(by_id[mid]), state[mid]["status"] == "bestanden", state[mid]["lp_part"])
    for _, e in custom:
        if e["area"]:
            count([e["area"]], e["id"], e["lp"], e["status"] == "bestanden")

    # Plaetze im Semester fuer offene Wahl: freie Plaetze laut Verlaufsplan, sonst je Bereich aus den offenen LP
    # (bzw. Modulen), im empfohlenen Semester mit der geringsten Last; Gruppe ohne Wahl: ein Platz "... waehlen"
    unit: dict[str, float] = {}
    mreq: dict[str, int | None] = {}
    for a in area_list:
        lps = sorted(lp_of(by_id[i]) for i in members[a["id"]] if lp_of(by_id[i]) > 0)
        unit[a["id"]] = lps[(len(lps) - 1) // 2] if lps else UNIT_LP
        n = _int_value(a.get("modules_required"))
        mreq[a["id"]] = n if n is not None and n >= 1 else None
    open_lp = {aid: target[aid] - used[aid] if target[aid] is not None else None for aid in area_by}
    open_n = {aid: mreq[aid] - len(counted[aid]) if mreq[aid] is not None else None for aid in area_by}
    room = {aid: num(area_by[aid].get("lp_max")) - used[aid] if num(area_by[aid].get("lp_max")) else None for aid in area_by}
    # Bedarf schon durch Module (bestanden, geplant, gewaehlt, eigene Eintraege) gedeckt: keine weiteren Plaetze
    met = {aid: (target[aid] is not None or mreq[aid] is not None) and not (open_lp[aid] is not None and open_lp[aid] > 0)
           and not (open_n[aid] is not None and open_n[aid] > 0) for aid in area_by}
    nslots = {aid: 0 for aid in area_by}
    custom_lp: dict[int, float] = {}
    for t, e in custom:
        custom_lp[t] = custom_lp.get(t, 0) + e["lp"]
    slot_lp: dict[int, float] = {}
    places: list[tuple[int, dict]] = []

    def is_open(aid: str) -> bool:                              # LP oder Zahl der Module noch offen
        return (open_lp[aid] is not None and open_lp[aid] > 0) or (open_n[aid] is not None and open_n[aid] > 0)

    def has_room(aid: str, lp) -> bool:     # Spanne bis zur Obergrenze, der ganze Platz passt, Bedarf nicht durch Module gedeckt
        return not met[aid] and room[aid] is not None and room[aid] > 0 and room[aid] >= (lp or 0)

    def is_unknown(aid: str) -> bool:
        return open_lp[aid] is None and open_n[aid] is None and room[aid] is None

    def term_load(t: int) -> float:
        return load(t) + custom_lp.get(t, 0) + slot_lp.get(t, 0)

    def hint_of(aids: list[str]) -> int:
        for aid in aids:
            h = _int_value(area_by[aid].get("semester"))
            if h is not None and 1 <= h <= 20:
                return h
        sems = sorted(sem_of(by_id[i]) for aid in aids for i in members[aid] if sem_of(by_id[i]))
        if sems:
            return sems[(len(sems) - 1) // 2]
        if any(atype[aid] in EARLY_TYPES for aid in aids):
            return max(1, (regular + 1) // 2)
        return max(1, regular - 1)

    def pick_term(h: int) -> int:
        lo = max(start + h - 1, lower)
        best = lo
        for t in range(lo, max(last_regular, lo) + 1):
            if term_load(t) < term_load(best):
                best = t
        return best

    def place(t: int, kind: str, title: str, area, areas: list[str], group, lp, lp_max, fach: int) -> None:
        places.append((t, {"id": f"platz-{len(places) + 1}", "kind": kind, "title": title, "area": area, "areas": areas,
                           "group": group, "type": atype[area] if area else (group or "wahl"),
                           "area_kind": akind[area] if area else "wahlpflicht", "lp": lp, "lp_max": lp_max,
                           "fachsemester": fach}))
        slot_lp[t] = slot_lp.get(t, 0) + (lp or 0)
        if area:
            nslots[area] += 1

    referenced: set[str] = set()
    for s in slots:
        ar = [a for a in s.get("areas") if isinstance(a, str)] if isinstance(s.get("areas"), list) else []
        referenced |= set(ar) if ar else set(choice)
    for k, s in enumerate(slots):
        if k in taken:
            continue
        ar = [a for a in s.get("areas") if isinstance(a, str)] if isinstance(s.get("areas"), list) else []
        cands = [a for a in ar if a in choice] if ar else list(choice)
        slot_lp_of = num(s.get("lp")) if num(s.get("lp")) is not None and num(s.get("lp")) > 0 else None
        # zuerst Bereiche mit offenen LP/Modulen, dann Spannen bis zur Obergrenze ("0 - 15 LP", auch ueber den Bedarf
        # hinaus, solange ihn erst die Plaetze decken), dann ohne Angabe; ist der Bedarf eines Bereichs durch Module
        # gedeckt, bekommt er keinen Platz mehr
        pick = next((a for a in cands if is_open(a)), None)
        if pick is None:
            pick = next((a for a in cands if has_room(a, slot_lp_of or unit[a])), None)
        if pick is None:
            pick = next((a for a in cands if is_unknown(a)), None)
        if pick is None:
            continue
        lp = slot_lp_of if slot_lp_of is not None else unit[pick]
        if room[pick] is not None:
            room[pick] -= lp
        if open_lp[pick] is not None:
            open_lp[pick] -= lp
        if open_n[pick] is not None:
            open_n[pick] -= 1
        fach = int(num(s["semester"]))
        place(max(start + fach - 1, lower), "slot", text_of(s.get("title")) or text_of(area_by[pick].get("name")), pick,
              cands, None, lp, num(s.get("lp_max")), fach)
    unknown_left = [MAX_UNKNOWN_SLOTS]
    for aid in choice:
        if aid in referenced:
            continue
        o = open_lp[aid]
        step = unit[aid]
        if o is not None or open_n[aid] is not None:
            # so viele Plaetze, dass LP und Zahl der Module reichen (beides muss erfuellt sein)
            n = math.ceil(o / step) if o is not None and o > 0 else 0
            if n > 1 and step < 3:                                # kleine Module (1-2 LP): ein Platz fuer alles
                n, step = 1, o
            n = max(n, open_n[aid] or 0)
        elif not counted[aid] and unknown_left[0] > 0:            # ohne LP-Angabe: ein Platz, solange nichts gewaehlt
            n = 1
            unknown_left[0] -= 1
        else:
            n = 0
        h = hint_of([aid])
        for j in range(min(n, MAX_AREA_SLOTS)):
            lp = min(step, o - j * step) if o is not None and o - j * step > 0 else unit[aid]
            place(pick_term(h), "area", text_of(area_by[aid].get("name")), aid, [aid], group_of.get(aid), lp, None, h)
    for g, ids in groups.items():
        if g in track:
            continue
        if slots and all(aid in referenced for aid in ids):
            continue                    # der Verlaufsplan hat Plaetze dafuer (INFBSc22: Nebenfach in "Wahl(pflicht)modul")
        lps = []
        for aid in ids:
            req, mx = num(area_by[aid].get("lp_required")), num(area_by[aid].get("lp_max"))
            v = req if req and req > 0 else mx
            if v:
                lps.append(v)
        h = hint_of(ids)
        place(pick_term(h), "track", f"{GROUP_LABELS.get(g, g)} wählen", None, list(ids), g, max(lps) if lps else None,
              None, h)

    # Semesterliste
    last = max([last_regular] + [state[i]["term"] for i in included] + [t for t, _ in custom] + [t for t, _ in places])
    semesters = []
    for t in range(start, last + 1):
        ids = sorted((i for i in included if state[i]["term"] == t), key=lambda i: (sem_of(by_id[i]) or 99, order[i]))
        mine = [e for ct, e in custom if ct == t]
        here = [p for pt, p in places if pt == t]
        semesters.append({"term": term_name(t), "fachsemester": t - start + 1, "current": t == current,
                          "lp": sum(rest_lp(i) for i in ids) + sum(e["lp"] for e in mine),
                          "modules": [_entry(by_id[i], state[i], module_hints(by_id[i], state[i], state, by_id))
                                      for i in ids] + mine,
                          "slots": here, "lp_slots": sum(p["lp"] or 0 for p in here)})

    # LP erreicht: die LP aller bestandenen QIS-Leistungen wie in Uni & Noten (grades_model.credits_done, Regel des
    # Inhabers 12.11.2026), auch nicht zugeordnete; nur ohne jede LP-Angabe im QIS die Katalog-LP der bestandenen Module
    manual = [r for r in grades if isinstance(r, dict) and r.get("source") == MANUAL]
    lp_manual = None
    if not manual:
        lp_done = grades_model.credits_done(grades) or (
            sum(lp_of(by_id[i]) for i in included if state[i]["status"] == "bestanden")
            + sum(e["lp"] for _, e in custom if e["status"] == "bestanden"))
    else:
        # selbst eingetragen (20.11.2026): ihre LP kommen zur QIS-Summe dazu (je Eintrag einmal, QIS geht vor:
        # app/grades_manual.py gibt nur Eintraege weiter, deren Modul QIS nicht als bestanden meldet)
        qis_done = grades_model.credits_done([r for r in grades if not (isinstance(r, dict) and r.get("source") == MANUAL)]) or (
            sum(lp_of(by_id[i]) for i in included if state[i]["status"] == "bestanden" and not state[i].get("manual"))
            + sum(e["lp"] for _, e in custom if e["status"] == "bestanden" and not e.get("manual")))
        lp_manual = round(sum(r["lp_counted"] for r in manual), 1)
        lp_done = round(qis_done + lp_manual, 1)
    total = num(catalog.get("total_lp"))
    lp_total = total if total else sum(lp_of(by_id[i]) for i in included)
    lp_expected = sum(lp_of(by_id[i]) for i in included if sem_of(by_id[i]) and start + sem_of(by_id[i]) - 1 < current)

    notes = []
    for mid in included:
        m, st = by_id[mid], state[mid]
        title = text_of(m.get("title"))
        attempt_notes(notes, mid, title, st)
        if st["status"] == "bestanden":
            continue
        for p in plan_prereqs(m, by_id):
            if p not in by_id:
                continue
            ps = state.get(p)
            ptitle = text_of(by_id[p].get("title"))
            if ps is None:
                if text_of(by_id[p].get("kind")) not in ELECTIVE_KINDS:     # ein Wahlmodul muss nicht im Plan sein
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
    for _, e in custom:
        if e.get("qis"):
            attempt_notes(notes, e["id"], e["title"], {"status": e["status"], "final": e["final"],
                                                       "qis_last": e["last_attempt"] and not e["final"],
                                                       "max_attempts": None, "attempt": e["attempt"]})
    for f in recognized:
        limit = (f"der Bereich verlangt {fmt_lp(f['cap'])} LP" if f["cap"] is not None
                 else f"mehr als der ganze Studiengang ({fmt_lp(f['total'])} LP)")
        notes.append(_note("wahl_erkannt", None, f"{f['name']}: {f['n']} Module mit {fmt_lp(f['lp'])} LP stehen im Katalog "
                                                 f"als Pflicht, {limit} – StudiNow zeigt sie als Wahl."))
    notes.sort(key=lambda n: NOTE_RANK[n["kind"]])

    electives = []
    for m in mods:
        if text_of(m.get("kind")) not in ELECTIVE_KINDS:
            continue
        st = state.get(m["id"])
        electives.append({"id": m["id"], "title": text_of(m.get("title")), "kind": m.get("kind"), "area": m.get("area"),
                          "lp": lp_of(m), "semester": sem_of(m), "chosen": m["id"] in chosen, "included": st is not None,
                          "status": st["status"] if st else None, "areas": mem_of[m["id"]], "turnus": m.get("turnus"),
                          "excluded": m["id"] in excluded})

    areas_out = []
    for a in area_list:
        aid = a["id"]
        areas_out.append({
            "id": aid, "name": text_of(a.get("name")), "type": atype[aid], "kind": akind[aid], "group": group_of.get(aid),
            "active": aid in active, "choice": akind[aid] in ELECTIVE_KINDS and atype[aid] != "abschluss",
            "lp_required": num(a.get("lp_required")), "lp_max": num(a.get("lp_max")), "target": target[aid],
            "modules_required": mreq[aid], "lp_done": done[aid], "lp_planned": used[aid] - done[aid],
            "lp_open": max(0, target[aid] - used[aid]) if target[aid] is not None else None,
            "count": len(counted[aid]), "count_done": n_done[aid], "options": len(members[aid]), "chosen": counted[aid],
            "slots": nslots[aid], "rule": text_of(a.get("rule")) or None})
    groups_out = [{"id": g, "label": GROUP_LABELS.get(g, g), "options": ids, "chosen": track.get(g),
                   "auto": track_auto.get(g, False)} for g, ids in groups.items()]

    plan = {
        "available": True, "reason": None, "message": None,
        "university": catalog.get("university"), "program": catalog.get("program"), "degree": catalog.get("degree"),
        "po": catalog.get("po"), "code": catalog.get("code"), "catalog_term": catalog.get("catalog_term"),
        "start_term": term_name(start), "current_term": term_name(current), "current_fachsemester": current - start + 1,
        "semesters": semesters, "lp_done": lp_done, "lp_total": lp_total, "lp_expected": lp_expected,
        "notes": notes, "electives": electives, "unmatched": unmatched, "disclaimer": DISCLAIMER,
        "areas": areas_out, "groups": groups_out,
        "excluded": [{"id": i, "title": text_of(by_id[i].get("title")), "kind": by_id[i].get("kind"), "lp": lp_of(by_id[i]),
                      "semester": sem_of(by_id[i])} for i in by_id if i in excluded and i not in state],
        "placements": {k: term_name(v) for k, v in placed.items()},
    }
    if lp_manual is not None:
        plan["lp_manual"] = lp_manual
    return {"plan": plan, "state": state, "hist": hist, "by_id": by_id, "included": included}


def _entry(m: dict, st: dict, hints: list[str] | None = None) -> dict:
    return {"id": m["id"], "title": text_of(m.get("title")), "code": m.get("code"), "kind": m.get("kind"),
            "area": m.get("area"), "lp": lp_of(m), "semester": num(m.get("semester")), "turnus": m.get("turnus"),
            "status": st["status"], "attempt": st["attempt"], "grade": st["grade"],
            "moved_from": st["moved_from"], "reason": st["reason"], "last_attempt": last_attempt(st),
            "attempt_known": st["known"], "max_attempts": st["max_attempts"],
            "final": bool(st["final"]) and st["status"] != "bestanden", "placed": st["placed"], "hints": hints or [],
            **({"manual": True} if st.get("manual") else {}),
            **({"lp_part": st["lp_part"]} if st.get("lp_part") and st["status"] != "bestanden" else {})}


def module_hints(m: dict, st: dict, state: dict, by_id: dict) -> list[str]:
    """Hinweise je Modul im Plan: Turnus passt nicht zum Semester (nach eigenem Verschieben), Voraussetzung nicht davor
    oder nicht im Plan"""
    if st["status"] == "bestanden":
        return []
    out = []
    if st.get("parts_open"):
        out.append(f"Teil bestanden: {', '.join(st['parts_done'])} – es fehlt noch: {', '.join(st['parts_open'])}")
    elif st.get("parts_done"):
        lp = f" ({fmt_lp(st['lp_part'])} von {fmt_lp(lp_of(m))} LP)" if st.get("lp_part") and lp_of(m) else ""
        out.append(f"Teilweise bestanden{lp}: {', '.join(st['parts_done'])}")
    turnus = turnus_of(m.get("turnus"))
    if not fits(st["term"], turnus):
        out.append(f"Laut Katalog nur im {'Wintersemester' if turnus == 'WS' else 'Sommersemester'} angeboten")
    for p in plan_prereqs(m, by_id):
        if p not in by_id:
            continue
        ps, ptitle = state.get(p), text_of(by_id[p].get("title"))
        if ps is None:
            if text_of(by_id[p].get("kind")) not in ELECTIVE_KINDS:
                out.append(f"Voraussetzung {ptitle} ist nicht im Plan")
        elif ps["status"] != "bestanden" and ps["term"] >= st["term"]:
            out.append(f"Voraussetzung {ptitle} liegt nicht davor")
    return out


def last_attempt(st: dict) -> bool:
    """Endgueltig nicht bestanden, QIS meldet den letzten Versuch, oder bei bekannter Hoechstzahl: der naechste bzw.
    angemeldete Versuch ist der letzte. Ohne Hoechstzahl nie aus der Zahl der Versuche (11.11.2026)"""
    if st["status"] not in ("nicht_bestanden", "angemeldet"):
        return False
    if st["final"] or st.get("qis_last"):
        return True
    mx = st.get("max_attempts")
    if mx is None:
        return False
    return (st["status"] == "nicht_bestanden" and st["attempt"] == mx - 1) or \
        (st["status"] == "angemeldet" and st["attempt"] == mx)


def attempt_notes(notes: list, module_id: str, title: str, st: dict) -> None:
    """Hinweis endgueltig nicht bestanden bzw. letzter Versuch (mit Grund: QIS oder Hoechstzahl der Pruefungsordnung)"""
    if st["status"] != "bestanden" and st["final"]:
        notes.append(_note("endgueltig", module_id, f"{title}: endgültig nicht bestanden – sprich mit der Studienberatung."))
    elif last_attempt(st):
        why = "laut QIS" if st.get("qis_last") else f"höchstens {st['max_attempts']} Versuche laut Prüfungsordnung"
        notes.append(_note("letzter_versuch", module_id, f"{title}: Letzter Versuch ({why}) – sprich mit der Studienberatung."))


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
            "unmatched": [], "disclaimer": DISCLAIMER, "areas": [], "groups": [], "excluded": [], "placements": {}}


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
    # Wahlbereiche und eigene Lage (05.11.2026): immer da, gespeichert nur, wenn nicht leer
    out["tracks"] = clean_tracks(v.get("tracks"))
    out["placements"] = clean_placements(v.get("placements"))
    out["excluded"] = clean_ids(v.get("excluded"))
    out["custom"] = clean_custom(v.get("custom"))
    # Neben- bzw. Begleitfaecher (Kuerzel aus dem Register, Frage "Was studierst du?", 14.11.2026) und ein Studiengang aus
    # dem Notenspiegel, bei dem der Nutzer schon "nein, ich bleibe" gesagt hat
    out["minors"] = clean_minors(v.get("minors"))
    ack = v.get("program_ack")
    if isinstance(ack, str) and ack.strip():
        out["program_ack"] = ack.strip()[:200]
    ack = v.get("order_ack")
    if isinstance(ack, str) and ack.strip():
        out["order_ack"] = ack.strip()[:200]
    return out


def clean_minors(v) -> list[str]:
    """Neben-/Begleitfaecher: hoechstens 3 Kuerzel, Text bis 200 Zeichen, ohne Doppelte, Reihenfolge bleibt"""
    out: list[str] = []
    for x in v if isinstance(v, list) else []:
        if isinstance(x, str) and x.strip() and x.strip()[:200] not in out:
            out.append(x.strip()[:200])
    return out[:3]


def grade_rows(conn) -> list[dict]:
    return grades_model.model(db.rows(conn, "SELECT * FROM grades ORDER BY id"))


def manual_entries(conn, grades: list[dict]) -> tuple[list[dict], list[dict]]:
    """Selbst eingetragene Leistungen (20.11.2026, app/grades_manual.py): (alle mit `replaced`/`counted`, Zeilen der
    zaehlenden fuer `compute`). QIS geht vor: gegen alle QIS-Zeilen geprueft, wie in Uni & Noten."""
    from . import grades_manual
    resolved = grades_manual.resolve(grades, grades_manual.load(conn))
    return resolved, grades_manual.rows(resolved)


def plan_response(conn, today: str, source=None) -> dict:
    source = source or DbCatalogSource(conn)
    settings, grades = load_settings(conn), grade_rows(conn)
    catalogs = source.catalogs()
    cat, reason = pick_catalog(catalogs, settings, grades)
    uni = _university(conn)
    mine = grades_for_catalog(grades, cat, uni)
    _, manual_rows = manual_entries(conn, grades)
    out = unavailable(reason, settings["po"]) if cat is None else build_plan(cat, mine + manual_rows, settings, today)
    if cat is None and reason in ("no_catalog", "no_catalog_po"):
        # gewaehlter Studiengang aus dem Register (auch ohne Katalog): ehrlich mit Namen statt "Verbinde das LSF"
        named = chosen_program_name(settings["po"], uni)
        if named:
            out["message"] = f"Für {named} gibt es noch keinen Modulkatalog."
            out["program"] = named
    other = [r for r in grades if r not in mine and r.get("source") != "anmeldung" and not is_bereich(r)]
    # Faecher desselben Mehr-Faecher-Studiengangs sind kein frueheres Studium: sie stehen in `degree_overview`
    deg = combined_degree(grades)
    siblings = set(deg["labels"]) if deg else set()
    other = [r for r in other if text_of(r.get("abschluss")).strip() not in siblings]
    # eigenes Feld: `degree` ist schon die Abschlussart des Katalogs ("B.Sc.") und bleibt, wie es war
    out["degree_overview"] = degree_overview(grades, mine if cat is not None else [], out.get("lp_manual"))
    out["passed_terms"] = passed_terms(grades)
    out["earlier_studies"] = earlier_studies(other) if cat is not None else []
    if cat is not None and other:
        # ehrlich sagen, warum Leistungen fehlen (Wechsel des Studiengangs, 14.11.2026)
        names = [e["program"] for e in out["earlier_studies"]]
        out["notes"] = list(out.get("notes") or []) + [{
            "kind": "anderer_studiengang", "tone": "info", "module_id": None,
            "text": f"{len(other)} Leistungen aus „{' / '.join(names)}“ stehen unten unter „Früheres Studium“ und zählen "
                    f"hier nicht. Angerechnete Leistungen zählen, sobald der Notenspiegel sie beim aktuellen Studiengang führt."}]
    suggested, _ = pick_catalog(catalogs, {}, grades)
    progs = programs_of(grades, uni)
    out.update(suggested_po=suggested.get("po") if suggested else None, po_confirmed=settings["po"] is not None,
               qis_program=abschluss_of(grades), programs=progs if len(progs) > 1 else [],
               program_mismatch=program_mismatch(progs, settings, uni),
               order_suggestion=order_suggestion(settings, out.get("code") or settings.get("po"), out.get("start_term"), uni),
               lsf_plan=lsf_plan(cat.get("code") if cat else settings.get("po"), uni))
    return out


def lsf_plan(code: str | None, university: str, registry: dict | None = None) -> dict | None:
    """Link zum LSF-"Studiengangsplan" des Studiengangs (Kuerzel oder ID; 14.11.2026): Wochenraster der Veranstaltungen
    dieses Semesters, kein Studienverlauf. None ohne Eintrag."""
    from .study_catalog import load_registry, program_entry
    if not code:
        return None
    reg = registry or load_registry()
    found = program_entry(reg, university, code)
    prog = found[1] if found else next((p for u in reg.get("universities") or [] if u.get("id") == university
                                        for p in u.get("programs") or [] if p.get("id") == code), None)
    lsf = (prog or {}).get("lsf")
    if not isinstance(lsf, dict) or not lsf.get("url"):
        return None
    return {"url": lsf["url"], "text": lsf.get("text"), "label": "Veranstaltungen dieses Semesters im LSF"}


ORDERS_PATH = Path(__file__).resolve().parent.parent / "packages" / "shared-contracts" / "study-orders.json"
_orders_cache: list | None = None


def study_orders() -> list[dict]:
    """Vorgaengerordnungen (packages/shared-contracts/study-orders.json, von Hand gepflegt)"""
    global _orders_cache
    if _orders_cache is None:
        try:
            _orders_cache = json.loads(ORDERS_PATH.read_text(encoding="utf-8")).get("orders") or []
        except (OSError, ValueError):
            _orders_cache = []
    return _orders_cache


def order_suggestion(settings: dict, code: str | None, start_term: str | None, university: str) -> dict | None:
    """Neue Ordnung gewaehlt, Studienbeginn vor deren erstem Semester: die alte Ordnung vorschlagen (14.11.2026,
    Sozialpaedagogik ab WiSe 2025/26, davor Sozial- und Organisationspaedagogik). None ohne passenden Eintrag, ohne
    bekannten Studienbeginn, mit Beginn ab dem Stichsemester, wenn die alte schon gewaehlt (Link) oder der Vorschlag
    abgelehnt ist (`order_ack`)."""
    start = parse_term(start_term) if start_term else None
    if not code or start is None:
        return None
    for o in study_orders():
        if o.get("university") != university or o.get("code") != code:
            continue
        since = parse_term(o.get("since"))
        older = o.get("older") or {}
        if since is None or start >= since or settings.get("catalog_url") == older.get("url"):
            return None
        if settings.get("order_ack") == "order:" + code:
            return None
        return {"code": code, "since": o.get("since"), "start_term": start_term, "program": older.get("program"),
                "degree": older.get("degree"), "po": older.get("po"), "url": older.get("url")}
    return None


def program_mismatch(progs: list[dict], settings: dict, university: str, registry: dict | None = None) -> dict | None:
    """Gewaehlt ist ein Studiengang aus dem Register, der Notenspiegel nennt einen anderen mit neuerer PO (14.11.2026:
    die Wahl des Nutzers gilt, aber einmal nachfragen statt still zu ueberschreiben). None ohne Wahl, bei gleichem
    Studiengang, aelterer PO im Notenspiegel oder wenn der Nutzer genau diesen schon abgelehnt hat (`program_ack`)."""
    from .study_catalog import load_registry, program_entry
    chosen = settings.get("po")
    if not chosen or not progs or not progs[0].get("code"):
        return None
    top = progs[0]
    if top["code"] == chosen or top["code"] == settings.get("program_ack"):
        return None
    found = program_entry(registry or load_registry(), university, chosen)
    if found is None:
        return None
    _, prog, po = found

    def year(x) -> int:
        try:
            return int(str(x or "")[:4])
        except ValueError:
            return -1
    if year(top.get("po")) <= year(po.get("po")):
        return None
    return {"code": top["code"], "program": top["program"], "degree": top.get("degree"), "po": top.get("po"),
            "chosen": prog.get("program")}


def chosen_program_name(code: str | None, university: str, registry: dict | None = None) -> str | None:
    """Kuerzel aus dem Register -> "Sozialpädagogik (B.A., PO 2025)" fuer Meldungen; None fuer eine PO-Jahreszahl"""
    from .study_catalog import load_registry, program_entry
    reg = registry or load_registry()
    found = program_entry(reg, university, code) if code else None
    if not found:
        # Studiengang ohne Katalog: gewaehlt ueber seine ID (14.11.2026, "Was studierst du?")
        for u in reg.get("universities") or []:
            for p in u.get("programs") or [] if u.get("id") == university else []:
                if code and p.get("id") == code:
                    return f"{p.get('program')} ({p.get('degree')})" if p.get("degree") else p.get("program")
        return None
    _, prog, po = found
    extra = ", ".join(x for x in (prog.get("degree"), f"PO {po.get('po')}" if po.get("po") else None) if x)
    return f"{prog.get('program')} ({extra})" if extra else prog.get("program")


def _university(conn) -> str:
    r = db.row(conn, "SELECT value FROM settings WHERE key='university'")
    return (r["value"] if r and r["value"] else None) or "luh"


def module_response(conn, module_id: str, today: str, source=None) -> dict:
    """Fakten, lokaler Text, eigener Stand, Kurse und Dateien der App zu einem Katalogmodul; 404 ohne Katalog/Modul"""
    source = source or DbCatalogSource(conn)
    settings, grades = load_settings(conn), grade_rows(conn)
    cat, _ = pick_catalog(source.catalogs(), settings, grades)
    if cat is None:
        raise HTTPException(404, "Kein Katalog")
    resolved, manual_rows = manual_entries(conn, grades)
    grades = grades_for_catalog(grades, cat, _university(conn))
    full = compute(cat, grades + manual_rows, settings, today)
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
           "attempt_known": st["known"] if st else False,
           "max_attempts": max_attempts_of(m, cat),
           "final": bool(st["final"]) and st["status"] != "bestanden" if st else False,
           "attempts":[{"text": r.get("text"), "semester": r.get("semester"), "status": r.get("status"),
                         "grade": r.get("note"), "attempt": int_or_none(r.get("versuch")), "date": r.get("datum")}
                        for r in full["hist"].get(module_id, []) if r.get("source") != MANUAL]}
    # selbst eingetragen (20.11.2026): der Eintrag zu diesem Modul (auch wenn QIS ihn inzwischen ersetzt) und ob
    # "Als bestanden abhaken" angeboten wird: nur ohne bestandene QIS-Leistung, nur am Geraet bzw. eigenen PC
    from . import config
    own["manual"] = next((e for e in resolved if e.get("module_id") == module_id), None)
    own["can_mark"] = not config.is_hosted() and not any(
        row_result(r) == "passed" for r in full["hist"].get(module_id, []) if r.get("source") != MANUAL)

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
    texts = source.module_text(cat, module_id)
    loading = False
    if texts is None and isinstance(source, DbCatalogSource):
        # Katalog aus Grundstock ohne lokale Texte: im Hintergrund nachladen (einmal je Katalog, nur am eigenen PC)
        from . import study_catalog as sc
        key = sc.catalog_key(cat)
        if sc.AUTO_SYNC and sc.texts_wanted(conn, key):
            loading = sc.start_texts(key)
    out = {
        "available": True, "id": module_id, "title": text_of(m.get("title")), "code": m.get("code"),
        "area": m.get("area"), "area_name": area.get("name") if area else None,
        "kind": m.get("kind"), "lp": lp_of(m), "semester": num(m.get("semester")), "turnus": m.get("turnus"),
        "exam": m.get("exam"), "coursework": m.get("coursework"), "language": m.get("language"),
        "workload_h": num(m.get("workload_h")), "prerequisites": pre, "required_for": required_for,
        "texts": texts, "own": own, "app_modules": app_modules, "courses": courses,
        "files": files, "source": {"url": src.get("url"), "page": num(m.get("source_page"))},
        "program": cat.get("program"), "po": cat.get("po"), "catalog_term": cat.get("catalog_term"),
        "disclaimer": DISCLAIMER,
    }
    if loading:
        out["texts_loading"] = True
    return out


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
    terms = [row_term(r) for r in grades if not is_bereich(r) and r.get("source") != "anmeldung"]
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
               for m in (effective_modules(cat)[0] if cat else [])
               if text_of(m.get("kind")) in ELECTIVE_KINDS]
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
    if "tracks" in body:
        v = body["tracks"]
        if v is not None and (not isinstance(v, dict) or not all(isinstance(x, str) for x in v.values())):
            raise HTTPException(400, "tracks muss ein Objekt {Gruppe: Bereich} sein")
        s["tracks"] = clean_tracks(v)
    if "placements" in body:
        v = body["placements"]
        if v is not None and (not isinstance(v, dict) or not all(isinstance(x, str) or x is None for x in v.values())):
            raise HTTPException(400, "placements muss ein Objekt {Modul: Semester} sein")
        for k, x in (v or {}).items():
            if isinstance(x, str) and x.strip() and parse_term(x) is None:
                raise HTTPException(400, f"Unbekanntes Semester: {x.strip()}")
        s["placements"] = clean_placements(v)
    if "excluded" in body:
        v = body["excluded"]
        if v is not None and (not isinstance(v, list) or not all(isinstance(e, str) for e in v)):
            raise HTTPException(400, "excluded muss eine Liste von Modul-ids sein")
        s["excluded"] = clean_ids(v)
    if "custom" in body:
        v = body["custom"]
        if v is not None and (not isinstance(v, list) or not all(isinstance(c, dict) for c in v)):
            raise HTTPException(400, "custom muss eine Liste von Eintraegen sein")
        s["custom"] = clean_custom(v)
    if "minors" in body:
        v = body["minors"]
        if v is not None and (not isinstance(v, list) or not all(isinstance(e, str) for e in v)):
            raise HTTPException(400, "minors muss eine Liste von Kuerzeln sein")
        s["minors"] = clean_minors(v)
    if "order_ack" in body:
        v = body["order_ack"]
        if v is not None and not isinstance(v, str):
            raise HTTPException(400, "order_ack muss Text sein")
        if isinstance(v, str) and v.strip():
            s["order_ack"] = v.strip()[:200]
        else:
            s.pop("order_ack", None)
    if "program_ack" in body:
        v = body["program_ack"]
        if v is not None and not isinstance(v, str):
            raise HTTPException(400, "program_ack muss Text sein")
        if isinstance(v, str) and v.strip():
            s["program_ack"] = v.strip()[:200]
        else:
            s.pop("program_ack", None)
    stored = {"po": s["po"], "start_term": s["start_term"], "electives": s["electives"]}
    if s.get("catalog_url"):
        stored["catalog_url"] = s["catalog_url"]
    for k in ("tracks", "placements", "excluded", "custom", "minors", "program_ack", "order_ack"):
        if s.get(k):
            stored[k] = s[k]
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
