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
MAX_CUSTOM = 40
MAX_CUSTOM_TITLE = 120


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
    """Eigene Eintraege (z. B. Studium generale aus einer anderen Fakultaet): {id, title, lp, area, semester};
    Titel noetig (hoechstens 120 Zeichen), LP 0..60, Fachsemester 1..20 oder null; ids "eigen-<n>", fehlende neu"""
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
        rows.append({"id": cid, "title": title, "lp": lp, "area": text_of(c.get("area")) or None,
                     "semester": sem if sem is not None and 1 <= sem <= 20 else None})
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


def _index(mods: list[dict]) -> tuple[dict, dict, dict]:
    """(Pruefungsnummer -> Modul-id, Namensschluessel -> Modul-id, Teile -> Modul-id), jeweils das erste Modul; ein Teil
    nur, wenn kein Modul so heisst"""
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
        mnr = text_of(r.get("modul_nr")).strip()
        mid = by_code.get(mnr) if mnr else None
        if mid is None and text_of(r.get("modul_text")).strip():
            mid = by_key.get(name_key(r.get("modul_text")))
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


def _match(mods: list[dict], grades: list[dict]) -> tuple[dict, list[str]]:
    """{Modul-id: [Zeilen]} und die nicht zugeordneten Texte (sortiert, ohne Doppelte)"""
    by_code, by_key, by_part = _index(mods)
    hist: dict[str, list[dict]] = {}
    unmatched: set[str] = set()
    for r in grades:
        if not isinstance(r, dict):
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
        if open_parts:
            done = {part_index(r.get("text"), title_parts(m.get("title"))[0]) for r in passed} - {None}
            rows = [r for r in rows if part_index(r.get("text"), title_parts(m.get("title"))[0]) not in done]
            passed = []
        failed_n, last_fail, final, known, qis_last = _attempts(rows, max_n)
        registered = [r for r in rows if row_result(r) == "registered"]
        st = {"status": None, "term": None, "attempt": None, "grade": None, "moved_from": None, "reason": None,
              "failed": failed_n, "final": final, "placed": False, "known": known, "max_attempts": max_n,
              "qis_last": qis_last, "parts_done": done_parts if open_parts else [], "parts_open": open_parts}
        sem = sem_of(m) or slot_sem.get(mid)
        rec = start + sem - 1 if sem else None
        own = placed.get(mid)
        if passed:
            best = passed[0]
            for r in passed[1:]:
                if (row_term(r) or -1) >= (row_term(best) or -1):
                    best = r
            t = row_term(best)
            if t is None:
                t = min(rec, current) if rec is not None else current
            st.update(status="bestanden", term=max(t, start), attempt=max(failed_n + 1, int_or_none(best.get("versuch")) or 0),
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
            if own is not None and own >= begin:
                st.update(term=own, placed=True)
        elif own is not None:
            st.update(status="plan", term=own, placed=True)
            if own < lower:
                st.update(term=next_fit(lower, turnus), placed=False, moved_from=term_name(own),
                          reason="Noch nicht abgelegt – nachholen")
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
    loose = [r for r in grades if isinstance(r, dict) and not is_bereich(r) and _row_module(r, by_code, by_key, by_part) is None]
    custom = []
    for c in clean_custom(settings.get("custom")):
        key = name_key(c["title"])
        rows = [r for r in loose if key and name_key(r.get("text")) == key]
        passed_rows = [r for r in rows if row_result(r) == "passed"]
        area = c["area"] if c["area"] in active else None
        e = {"id": c["id"], "title": c["title"], "code": None, "kind": akind[area] if area else "wahl", "area": area,
             "lp": c["lp"], "semester": c["semester"], "turnus": None, "status": None, "attempt": None, "grade": None,
             "moved_from": None, "reason": None, "last_attempt": False, "attempt_known": False, "max_attempts": None,
             "final": False, "placed": False, "hints": [], "custom": True}
        if passed_rows:
            best = passed_rows[0]
            for r in passed_rows[1:]:
                if (row_term(r) or -1) >= (row_term(best) or -1):
                    best = r
            t = row_term(best)
            e.update(status="bestanden", grade=text_of(best.get("note")).strip() or None)
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
        if not isinstance(r, dict):
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

    def count(cands: list[str], ident: str, lp, passed: bool) -> None:
        pick = next((x for x in cands if target[x] is None or used[x] < target[x]), cands[0])
        used[pick] += lp
        counted[pick].append(ident)
        if passed:
            done[pick] += lp
            n_done[pick] += 1

    for mid in included:
        cands = [x for x in mem_of[mid] if x in active]
        if cands:
            count(cands, mid, lp_of(by_id[mid]), state[mid]["status"] == "bestanden")
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
                          "lp": sum(lp_of(by_id[i]) for i in ids) + sum(e["lp"] for e in mine),
                          "modules": [_entry(by_id[i], state[i], module_hints(by_id[i], state[i], state, by_id))
                                      for i in ids] + mine,
                          "slots": here, "lp_slots": sum(p["lp"] or 0 for p in here)})

    # LP erreicht: die LP aller bestandenen QIS-Leistungen wie in Uni & Noten (grades_model.credits_done, Regel des
    # Inhabers 12.11.2026), auch nicht zugeordnete; nur ohne jede LP-Angabe im QIS die Katalog-LP der bestandenen Module
    lp_done = grades_model.credits_done(grades) or (
        sum(lp_of(by_id[i]) for i in included if state[i]["status"] == "bestanden")
        + sum(e["lp"] for _, e in custom if e["status"] == "bestanden"))
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
    return {"plan": plan, "state": state, "hist": hist, "by_id": by_id, "included": included}


def _entry(m: dict, st: dict, hints: list[str] | None = None) -> dict:
    return {"id": m["id"], "title": text_of(m.get("title")), "code": m.get("code"), "kind": m.get("kind"),
            "area": m.get("area"), "lp": lp_of(m), "semester": num(m.get("semester")), "turnus": m.get("turnus"),
            "status": st["status"], "attempt": st["attempt"], "grade": st["grade"],
            "moved_from": st["moved_from"], "reason": st["reason"], "last_attempt": last_attempt(st),
            "attempt_known": st["known"], "max_attempts": st["max_attempts"],
            "final": bool(st["final"]) and st["status"] != "bestanden", "placed": st["placed"], "hints": hints or []}


def module_hints(m: dict, st: dict, state: dict, by_id: dict) -> list[str]:
    """Hinweise je Modul im Plan: Turnus passt nicht zum Semester (nach eigenem Verschieben), Voraussetzung nicht davor
    oder nicht im Plan"""
    if st["status"] == "bestanden":
        return []
    out = []
    if st.get("parts_open"):
        out.append(f"Teil bestanden: {', '.join(st['parts_done'])} – es fehlt noch: {', '.join(st['parts_open'])}")
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
           "attempt_known": st["known"] if st else False,
           "max_attempts": max_attempts_of(m, cat),
           "final": bool(st["final"]) and st["status"] != "bestanden" if st else False,
           "attempts":[{"text": r.get("text"), "semester": r.get("semester"), "status": r.get("status"),
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
    stored = {"po": s["po"], "start_term": s["start_term"], "electives": s["electives"]}
    if s.get("catalog_url"):
        stored["catalog_url"] = s["catalog_url"]
    for k in ("tracks", "placements", "excluded", "custom"):
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
