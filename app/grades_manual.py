"""Selbst eingetragene Leistungen (Entscheidung des Inhabers 20.11.2026): "man soll selber Noten eintragen koennen, wenn
man will, und Klausuren abhaken ... wenn unsere App das nicht erkennt, dann soll das automatisch uebernommen werden und
auch bei LP angerechnet werden".

Bis dahin galt allein QIS (grades_model.py, Regel 12.11.2026). Selbst eingetragene Leistungen ergaenzen QIS, sie
ersetzen es nie:
- Tabelle `grades_manual` nur auf dem Geraet bzw. am eigenen PC (wie `grades`): nie im Dienst, nicht im
  Geraete-Abgleich (app/sync.py ENTITIES, DeviceSync.swift). Angelegt erst beim ersten Eintrag.
- Ein Eintrag gehoert zu einem Modul des Katalogs (`module_id`, dazu Kuerzel `code` und Titel) oder zu einem eigenen
  Eintrag des Studienverlaufs ("eigen-<n>"). LP: die des Katalogmoduls bzw. eigenen Eintrags, nur ohne solche die
  eingetragenen. Note optional (1,0 bis 5,0, eine Nachkommastelle); ueber 4,0 heisst nicht bestanden: der Eintrag
  bleibt stehen, zaehlt aber nirgends.
- QIS geht vor (`resolve`): meldet QIS eine bestandene Leistung zu demselben Modul, gilt der Eintrag als `replaced`
  und zaehlt nicht (keine Doppelzaehlung). Gleich heisst: Pruefungs- oder Modulnummer der QIS-Zeile = Kuerzel des
  Eintrags, oder gleicher Namensschluessel (study_plan.name_key) von Text oder Modultext der QIS-Zeile, oder die
  QIS-Zeile nennt einen Teil eines zusammengesetzten Titels ("Thermodynamik I / Chemie"). Bereichszeilen und
  Pruefungsanmeldungen zaehlen dafuer nie.
- Zaehlende Eintraege (`counted`: bestanden, nicht ersetzt) gehen als Zeile mit `source: "manuell"` in den
  Studienverlauf (`rows`) und in Uni & Noten (grades_model.summary): LP-Summe, Zahl der bestandenen Leistungen und,
  nur mit Note, der Schnitt. Ohne Eintraege bleiben alle Antworten wie bisher.
Gleiche Regeln im Swift-Kern (LocalBackend/GradesManual.swift).
"""
from __future__ import annotations

import math

from . import db, grades_model

TABLE = "grades_manual"
TABLE_SQL = """CREATE TABLE IF NOT EXISTS grades_manual (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id TEXT,          -- Modul des Katalogs oder eigener Eintrag des Studienverlaufs ("eigen-1")
    code TEXT,               -- Pruefungsnummer/Kuerzel laut Katalog
    title TEXT NOT NULL,
    lp REAL,                 -- LP laut Katalog, sonst selbst eingetragen
    grade TEXT,              -- "2,3" oder NULL
    passed INTEGER NOT NULL DEFAULT 1,
    semester TEXT,           -- "WiSe 24/25" oder NULL
    created_at TEXT,
    updated_at TEXT
)"""
SOURCE = "manuell"
MAX_ENTRIES = 200
MAX_TITLE = 120
MAX_ID = 200
MAX_CODE = 40
MAX_LP = 60
GRADE_ERROR = "Note bitte zwischen 1,0 und 5,0 eintragen, z. B. 2,3."
LP_ERROR = "Leistungspunkte bitte als Zahl zwischen 0 und 60 eintragen."
TERM_ERROR = "Semester bitte wie „WiSe 24/25“ oder „SoSe 25“ eintragen."


class Invalid(ValueError):
    """Eingabe ungueltig (Text fuer die Oberflaeche)"""


# ---------------------------------------------------------------------------- Werte

def parse_grade(v) -> float | None:
    """'2,3', '2.3', 2.3 -> 2.3; leer -> None; sonst Invalid (1,0 bis 5,0, hoechstens eine Nachkommastelle)"""
    if v is None or (isinstance(v, str) and not v.strip()):
        return None
    if isinstance(v, bool):
        raise Invalid(GRADE_ERROR)
    if isinstance(v, (int, float)):
        g = float(v)
    elif isinstance(v, str):
        s = v.strip().replace(",", ".")
        if not s or len(s) > 4 or not all(c.isdigit() or c == "." for c in s) or s.count(".") > 1 or s.startswith("."):
            raise Invalid(GRADE_ERROR)
        g = float(s)
    else:
        raise Invalid(GRADE_ERROR)
    if not math.isfinite(g) or g < 1.0 or g > 5.0 or abs(round(g, 1) - g) > 1e-9:
        raise Invalid(GRADE_ERROR)
    return round(g, 1)


def grade_text(g: float | None) -> str | None:
    """2.3 -> '2,3'"""
    return None if g is None else f"{g:.1f}".replace(".", ",")


def parse_lp(v) -> float | None:
    """LP: Zahl oder Text ('7,5'); leer -> None; 0 bis 60, sonst Invalid"""
    if v is None or (isinstance(v, str) and not v.strip()):
        return None
    if isinstance(v, bool):
        raise Invalid(LP_ERROR)
    try:
        x = float(v.strip().replace(",", ".")) if isinstance(v, str) else float(v)
    except (TypeError, ValueError):
        raise Invalid(LP_ERROR) from None
    if not math.isfinite(x) or x < 0 or x > MAX_LP:
        raise Invalid(LP_ERROR)
    return round(x, 1)


def lp_value(x) -> int | float:
    """5.0 -> 5, 7.5 -> 7.5 (wie die LP im Katalog)"""
    x = float(x or 0)
    return int(x) if x == int(x) else x


def lp_text(x) -> str:
    """LP als QIS-Text: 5 -> '5', 7.5 -> '7,5'"""
    x = float(x or 0)
    return str(int(x)) if x == int(x) else f"{x:.1f}".replace(".", ",")


def parse_semester(v) -> str | None:
    if v is None or (isinstance(v, str) and not v.strip()):
        return None
    t = grades_model.parse_term(v) if isinstance(v, str) else None
    if t is None:
        raise Invalid(TERM_ERROR)
    return grades_model.term_name(t)


def _text(v, limit: int) -> str:
    return " ".join(v.split())[:limit].strip() if isinstance(v, str) else ""


# ---------------------------------------------------------------------------- Tabelle

def has_table(conn) -> bool:
    return db.row(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (TABLE,)) is not None


def entry_of(r: dict) -> dict:
    g = r.get("grade")
    lp = r.get("lp")
    return {"id": r["id"], "module_id": r.get("module_id") or None, "code": r.get("code") or None, "title": r.get("title") or "",
            "lp": lp_value(lp if isinstance(lp, (int, float)) else 0), "grade": g or None, "passed": bool(r.get("passed")),
            "semester": r.get("semester") or None, "created_at": r.get("created_at"), "updated_at": r.get("updated_at")}


def load(conn) -> list[dict]:
    """Alle Eintraege (nach id); ohne Tabelle keine (GET legt nichts an)"""
    if not has_table(conn):
        return []
    return [entry_of(r) for r in db.rows(conn, f"SELECT * FROM {TABLE} ORDER BY id")]


def facts(conn, module_id: str) -> dict | None:
    """Titel, Kuerzel und LP eines Katalogmoduls (gewaehlter Katalog wie im Studienverlauf) oder eines eigenen Eintrags"""
    from . import study_plan as sp
    settings = sp.load_settings(conn)
    for c in settings.get("custom") or []:
        if c["id"] == module_id:
            return {"title": c["title"], "code": None, "lp": c["lp"]}
    cat, _ = sp.pick_catalog(sp.DbCatalogSource(conn).catalogs(), settings, sp.grade_rows(conn))
    if cat is None:
        return None
    mods, _ = sp.effective_modules(cat)
    for m in mods:
        if m["id"] == module_id:
            code = sp.text_of(m.get("code")).strip()
            return {"title": sp.text_of(m.get("title")).strip(), "code": code or None, "lp": sp.lp_of(m)}
    return None


def save(conn, body: dict) -> dict:
    """Eintrag anlegen oder aendern: `id` (aendern), sonst je `module_id` ein Eintrag (vorhandener wird geaendert).
    Felder: module_id, title, code, lp, grade, passed (Vorgabe ja), semester. Titel, Kuerzel und LP kommen aus dem
    Katalog bzw. eigenen Eintrag, wenn das Modul dort steht; Note ueber 4,0 heisst nicht bestanden."""
    if not isinstance(body, dict):
        raise Invalid("Eintrag fehlt.")
    module_id = _text(body.get("module_id"), MAX_ID) or None
    known = facts(conn, module_id) if module_id else None
    title = (known or {}).get("title") or _text(body.get("title"), MAX_TITLE)
    if not title:
        raise Invalid("Bitte den Namen des Moduls oder der Prüfung eintragen.")
    code = (known or {}).get("code") if known else (_text(body.get("code"), MAX_CODE) or None)
    # LP des Katalogmoduls bzw. eigenen Eintrags gehen vor; nur ohne solche zaehlen die eingetragenen
    lp = known["lp"] if known and known.get("lp") else (parse_lp(body.get("lp")) or 0)
    grade = parse_grade(body.get("grade"))
    passed = body.get("passed", True)
    if not isinstance(passed, bool):
        raise Invalid("„bestanden“ muss ja oder nein sein.")
    if grade is not None and grade > 4.0:
        passed = False                                  # 5,0: nicht bestanden, zaehlt nicht
    semester = parse_semester(body.get("semester"))
    conn.execute(TABLE_SQL)
    now = db.now_iso()
    rid = body.get("id")
    row = None
    if rid is not None:
        if isinstance(rid, bool) or not isinstance(rid, int):
            raise Invalid("Eintrag unbekannt.")
        row = db.row(conn, f"SELECT * FROM {TABLE} WHERE id=?", (rid,))
        if row is None:
            raise LookupError("Eintrag unbekannt.")
    elif module_id:
        row = db.row(conn, f"SELECT * FROM {TABLE} WHERE module_id=? ORDER BY id LIMIT 1", (module_id,))
    values = (module_id, code, title, float(lp), grade_text(grade), int(passed), semester)
    if row is not None:
        conn.execute(f"UPDATE {TABLE} SET module_id=?, code=?, title=?, lp=?, grade=?, passed=?, semester=?, updated_at=? "
                     "WHERE id=?", (*values, now, row["id"]))
        new_id = row["id"]
    else:
        n = db.row(conn, f"SELECT COUNT(*) AS n FROM {TABLE}")["n"]
        if n >= MAX_ENTRIES:
            raise Invalid(f"Höchstens {MAX_ENTRIES} eigene Einträge.")
        cur = conn.execute(f"INSERT INTO {TABLE}(module_id, code, title, lp, grade, passed, semester, created_at, updated_at) "
                           "VALUES (?,?,?,?,?,?,?,?,?)", (*values, now, now))
        new_id = cur.lastrowid
    return entry_of(db.row(conn, f"SELECT * FROM {TABLE} WHERE id=?", (new_id,)))


def delete(conn, entry_id: int) -> bool:
    if not has_table(conn):
        return False
    return conn.execute(f"DELETE FROM {TABLE} WHERE id=?", (entry_id,)).rowcount > 0


# ---------------------------------------------------------------------------- QIS geht vor

def qis_match(entry: dict, rows: list[dict]) -> dict | None:
    """Erste bestandene QIS-Zeile (bereinigt, grades_model.model) zu dem Modul des Eintrags, sonst None"""
    from .study_plan import name_key, part_index, text_of, title_parts
    code = (entry.get("code") or "").strip()
    key = name_key(entry.get("title"))
    parts, _ = title_parts(entry.get("title"))
    for r in rows:
        if not isinstance(r, dict) or r.get("source") in ("anmeldung", SOURCE) or not r.get("passed") \
                or r.get("level") == "bereich":
            continue
        nr, mnr = text_of(r.get("pruefungsnr")).strip(), text_of(r.get("modul_nr")).strip()
        if code and code in (nr, mnr):
            return r
        mt = text_of(r.get("modul_text")).strip()
        if key and (name_key(r.get("text")) == key or (mt and name_key(mt) == key)):
            return r
        if parts and (part_index(r.get("text"), parts) is not None or (mt and part_index(mt, parts) is not None)):
            return r
    return None


def resolve(rows: list[dict], entries: list[dict]) -> list[dict]:
    """Eintraege mit `replaced` (QIS meldet das Modul bestanden), `replaced_by` (die QIS-Zeile) und `counted` (bestanden
    und nicht ersetzt: zaehlt in LP, Studienverlauf und, mit Note bis 4,0, im Schnitt)"""
    out = []
    for e in entries:
        hit = qis_match(e, rows)
        g = dict(e)
        g["replaced"] = hit is not None
        g["replaced_by"] = ({"text": hit.get("text") or "", "note": hit.get("note") or "",
                             "semester": hit.get("semester_norm") or hit.get("semester") or ""} if hit else None)
        g["counted"] = bool(e.get("passed")) and hit is None
        out.append(g)
    return out


def grade_num(e: dict) -> float | None:
    try:
        return parse_grade(e.get("grade"))
    except Invalid:
        return None


def row_of(e: dict) -> dict:
    """Zeile wie eine bereinigte QIS-Modulzeile (grades_model.model) fuer den Studienverlauf"""
    g = grade_num(e)
    sem = e.get("semester") or ""
    return {"id": None, "source": SOURCE, "manual_id": e["id"], "module_id": e.get("module_id"),
            "pruefungsnr": e.get("code") or "", "text": e.get("title") or "", "semester": sem, "semester_norm": sem,
            "note": grade_text(g) if g is not None and g <= 4.0 else "", "status": "bestanden",
            "credits": lp_text(e.get("lp")), "versuch": "", "datum": "", "datum_iso": "", "abschluss": None, "raw": None,
            "art": "", "level": "modul", "passed": True, "graded": g is not None and g <= 4.0, "anerkannt": False,
            "counted": True, "lp_counted": float(e.get("lp") or 0), "superseded": False, "modul_nr": None, "modul_text": None}


def rows(resolved: list[dict]) -> list[dict]:
    """Zeilen der zaehlenden Eintraege (`counted`)"""
    return [row_of(e) for e in resolved if e.get("counted")]


def is_manual(r: dict) -> bool:
    return isinstance(r, dict) and r.get("source") == SOURCE
