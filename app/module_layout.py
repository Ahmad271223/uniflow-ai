"""Eigene Wochen und Abschnitte je Modul (Auftrag des Inhabers 12.11.2026).

"Wenn keine klaren Vorlesungswochen bestehen, soll der Nutzer selbst welche anlegen koennen. Wir geben ihm alle Dateien
so gut geordnet wie moeglich, und den Rest darf er selbst umstrukturieren."

Gleiche Regeln wie im Kern (`ModuleLayout.swift`); gemeinsame Faelle in
packages/shared-contracts/fixtures/module-layout/cases.json (tools/gen-module-layout-fixture.py).

- `module_sections`: Zeilen fuer automatische Wochen (`week` gesetzt: eigener Titel, ausgeblendet, eigener Platz) und
  eigene Abschnitte (`week` NULL). `rank`: Platz eines eigenen Abschnitts zwischen den Wochen (10 * n + 0,5 = nach
  Woche n), `sort`: Platz, nachdem der Nutzer selbst sortiert hat.
- `module_file_places`: Datei -> Abschnitt des Nutzers ("w:3", "s:12", "w:-4"). Ein Abgleich schreibt hier nie.

Lehrwoche fuer Lernplan und Wochentests (`planning_week`): die Woche, in die der Nutzer die Datei gelegt hat; in einem
eigenen Abschnitt die Woche davor; sonst automatisch. Block im Moduldetail (`display_week`): Abschnitt des Nutzers,
sonst automatisch; Unsicheres (Stud.IP-Sammelupload zu Semesterbeginn ohne Nummer) in "Nicht zugeordnet".
"""
from __future__ import annotations

import math
import re
import unicodedata

UNASSIGNED = -4
GENERAL = -3          # "Allgemein" (nur Kern: Moodle-Zuordnung)
CUSTOM_BASE = 1000
BULK_MINIMUM = 6
LECTURE_WEEK_TYPES = ("vorlesung", "uebung", "skript", "loesung")

TABLE_SQL = """
CREATE TABLE IF NOT EXISTS module_sections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id INTEGER NOT NULL,
    week INTEGER,
    title TEXT,
    rank REAL,
    sort REAL,
    hidden INTEGER NOT NULL DEFAULT 0,
    created_at TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS module_sections_week ON module_sections(module_id, week) WHERE week IS NOT NULL;
CREATE TABLE IF NOT EXISTS module_file_places (
    file_id TEXT PRIMARY KEY,
    module_id INTEGER NOT NULL,
    section TEXT NOT NULL,
    placed_at TEXT);
"""


class EditError(Exception):
    pass


def custom_week(sid: int) -> int:
    return -(CUSTOM_BASE + int(sid))


def section_id(w: int) -> int | None:
    return -w - CUSTOM_BASE if w <= -CUSTOM_BASE else None


def key(w: int) -> str:
    sid = section_id(w)
    return f"s:{sid}" if sid is not None else f"w:{w}"


def week_of_key(k) -> int | None:
    if not isinstance(k, str):
        return None
    parts = k.split(":", 1)
    if len(parts) != 2 or not re.fullmatch(r"-?\d+", parts[1]):
        return None
    n = int(parts[1])
    if parts[0] == "w":
        return n if UNASSIGNED <= n <= 60 else None
    if parts[0] == "s":
        return custom_week(n) if n > 0 else None
    return None


def default_rank(w: int) -> float:
    if w == UNASSIGNED:
        return -40
    if w == GENERAL:
        return -30
    if w == -2:
        return 1_000_010
    if w == -1:
        return 1_000_000
    return float(w) if w <= 0 else float(10 * w)


def week_after(rank: float | None) -> int | None:
    if rank is None or not (10 <= rank < 1_000_000):
        return None
    return int(math.floor(rank / 10))


class Layout:
    def __init__(self, sections: list[dict] | None = None, places: dict[str, str] | None = None):
        self.sections = sections or []
        self.places = places or {}

    @property
    def empty(self) -> bool:
        return not self.sections and not self.places

    def row(self, w: int) -> dict | None:
        return next((s for s in self.sections if s.get("week") == w), None)

    def custom(self, sid: int) -> dict | None:
        return next((s for s in self.sections if s["id"] == sid and s.get("week") is None and not s.get("hidden")), None)

    @property
    def customs(self) -> list[dict]:
        return [s for s in self.sections if s.get("week") is None and not s.get("hidden")]

    def hidden(self, w: int) -> bool:
        r = self.row(w)
        return bool(r and r.get("hidden"))

    def exists(self, w: int) -> bool:
        sid = section_id(w)
        if sid is not None:
            return self.custom(sid) is not None
        return not self.hidden(w)

    def rank(self, w: int) -> float:
        sid = section_id(w)
        if sid is not None:
            s = self.custom(sid)
            if s is not None:
                return s["rank"] if s.get("rank") is not None else 999_000 + sid
        return default_rank(w)

    def sort(self, w: int) -> float | None:
        sid = section_id(w)
        if sid is not None:
            s = self.custom(sid)
            return s.get("sort") if s else None
        r = self.row(w)
        return r.get("sort") if r else None

    def planning_week(self, file_id, auto: int) -> int:
        k = self.places.get(file_id) if file_id is not None else None
        w = week_of_key(k) if k else None
        if w is None:
            return auto
        sid = section_id(w)
        if sid is not None:
            s = self.custom(sid)
            if s is None:
                return auto
            a = week_after(s.get("rank"))
            return a if a is not None else auto
        if w == UNASSIGNED or self.hidden(w):
            return auto
        return w

    def display_week(self, file_id, auto: int, unsure: bool) -> int:
        k = self.places.get(file_id) if file_id is not None else None
        w = week_of_key(k) if k else None
        if w is not None and self.exists(w):
            return w
        w = UNASSIGNED if unsure else auto
        return w if self.exists(w) else UNASSIGNED

    @property
    def shown_empty(self) -> list[int]:
        return [custom_week(s["id"]) if s.get("week") is None else s["week"]
                for s in self.sections if not s.get("hidden") and (s.get("week") if s.get("week") is not None else 1) >= 1]


def load(conn) -> dict[int, Layout]:
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='module_sections'").fetchone():
        return {}
    out: dict[int, Layout] = {}
    for r in conn.execute("SELECT * FROM module_sections ORDER BY id").fetchall():
        r = dict(r)
        out.setdefault(r["module_id"], Layout()).sections.append(
            {"id": r["id"], "week": r["week"], "title": r["title"], "rank": r["rank"], "sort": r["sort"], "hidden": bool(r["hidden"])})
    for r in conn.execute("SELECT file_id, module_id, section FROM module_file_places").fetchall():
        out.setdefault(r[1], Layout()).places[r[0]] = r[2]
    return out


def order(weeks: list[int], layout: Layout) -> list[int]:
    """Selbst sortierte nach `sort`; die anderen nach `rank`: ans Ende, wenn kein Block einen groesseren Platz hat,
    sonst hinter den Block mit dem naechstkleineren Platz, ganz vorn, wenn es keinen gibt."""
    def tie(w):
        sid = section_id(w)
        return 1_000_000 + sid if sid is not None else w

    def by_rank(w):
        return (layout.rank(w), tie(w))

    explicit = sorted([w for w in weeks if layout.sort(w) is not None], key=lambda w: (layout.sort(w), *by_rank(w)))
    out = list(explicit)
    for w in sorted([w for w in weeks if layout.sort(w) is None], key=by_rank):
        r = layout.rank(w)
        best = None
        for i, x in enumerate(out):
            if layout.rank(x) < r or (layout.rank(x) == r and by_rank(x) < by_rank(w)):
                if best is not None and layout.rank(out[best]) > layout.rank(x):
                    continue
                best = i
        if not any(layout.rank(x) > r for x in weeks):
            out.append(w)
        elif best is not None:
            out.insert(best + 1, w)
        else:
            out.insert(0, w)
    return out


# ----------------------------------------------------------------------------
# Hinweise (wie LectureWeeks.nameHint / dateInName im Kern)
# ----------------------------------------------------------------------------

def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s or "")


def collapse(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


_EXT = re.compile(r"\.[a-z0-9]{1,5}$")
_DATE_IN_NAME = re.compile(r"(?<!\d)(?:\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2})?|\d{4}[-_.]\d{2}[-_.]\d{2}|20\d{6})(?!\d)")
_PATTERNS = [
    ("kw", re.compile(r"\bkw\s?0?(\d{1,2})(?!\d)")),
    ("woche", re.compile(r"\b(?:lehr|vorlesungs)?(?:woche|week)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)")),
    ("woche", re.compile(r"(?<![\d.])0?(\d{1,2})\.\s?(?:lehr|vorlesungs)?woche\b")),
    ("loesung", re.compile(r"\b(?:muster)?(?:l(?:ö|oe)sung(?:en|s)?|lsg|solutions?)\s?(?:zu[mr]?\s?)?(?:(?:übungs|uebungs|aufgaben)?blatt|übung|uebung|ü|ue|sheet|aufgabe|serie)?\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)")),
    ("blatt", re.compile(r"\b(?:(?:übungs|uebungs|aufgaben)?blatt|haus(?:ü|ue)bung|(?:ü|ue)bungs?serie|(?:ü|ue)bung|ueb|serie|exercise|sheet|assignment)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)")),
    ("blatt", re.compile(r"\b(?:ü|ue|ub)\s?0?(\d{1,2})(?!\d)")),
    ("tutorium", re.compile(r"\b(?:tutorium|tut)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)")),
    ("vl", re.compile(r"\b(?:vorlesung|vl|vo|folien|slides|lecture|lec|sitzung|termin)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)")),
    ("vl", re.compile(r"\bv(\d{2})(?!\d)")),
    ("teil", re.compile(r"\b(?:teil|part)\s?0?(\d{1,2})(?!\d)")),
    ("kapitel", re.compile(r"\b(?:kapitel|kap\.?|chapter)\s?0?(\d{1,2})(?!\d)")),
]
_SOLUTION_WORD = re.compile(r"l(?:ö|oe)sung|\blsg\b|solution")
_ISO_DATE = re.compile(r"(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)")
_GERMAN_DATE = re.compile(r"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?!\d)")
_LEADING_NUMBER = re.compile(r"^0?(\d{1,2})(?:[ ._\-)]|$)")
_WEEK_TITLE = re.compile(r"^(?:(?:lehr|vorlesungs)?woche|week)\s*0?(\d{1,2})$|^0?(\d{1,2})\.\s*(?:lehr|vorlesungs)?woche$")
LABELS = {"kw": "KW", "woche": "Woche", "loesung": "Lösung", "blatt": "Blatt", "tutorium": "Tutorium", "vl": "Vorlesung",
          "teil": "Teil", "kapitel": "Kapitel"}


def name_hint(text: str, strip_extension: bool = True) -> tuple[str, int] | None:
    raw = _nfc(text).lower()
    t = _DATE_IN_NAME.sub(" ", raw)
    t = _nfc(t).lower()
    if strip_extension:
        t = _EXT.sub("", t)
    t = collapse(t.replace("_", " ").replace("-", " "))
    for kind, rx in _PATTERNS:
        m = rx.search(t)
        if not m:
            continue
        n = int(m.group(1))
        if kind == "kw" and not 1 <= n <= 53:
            continue
        if kind != "kw" and not 0 <= n <= 40:
            continue
        if kind == "blatt" and _SOLUTION_WORD.search(t):
            return ("loesung", n)
        return (kind, n)
    return None


def _days_in_month(y: int, m: int) -> int:
    import calendar
    return calendar.monthrange(y, m)[1]


def date_in_name(text: str):
    from datetime import date
    t = _nfc(text)
    m = _ISO_DATE.search(t)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    else:
        m = _GERMAN_DATE.search(t)
        if not m:
            return None
        d, mo, ys = int(m.group(1)), int(m.group(2)), m.group(3)
        y = int(ys) + (2000 if len(ys) == 2 else 0)
    if not (2000 <= y <= 2100 and 1 <= mo <= 12 and 1 <= d <= _days_in_month(y, mo)):
        return None
    return date(y, mo, d)


def week_number_in_title(t: str) -> int | None:
    m = _WEEK_TITLE.search(collapse(_nfc(t).lower()))
    if not m:
        return None
    n = int(m.group(1) or m.group(2))
    return n if 1 <= n <= 40 else None


def _block_week_of_day(d, start) -> int | None:
    from datetime import timedelta
    monday = d - timedelta(days=d.weekday())
    w = (monday - start).days // 7 + 1
    return w if 1 <= w <= 20 else None


def _hint_week(text: str, start):
    h = name_hint(text, strip_extension=False)
    if h:
        kind, n = h
        if kind == "kw":
            pass                                   # ohne gemerktes Semester (nur Kern) keine Kalenderwoche
        elif kind == "loesung":
            if 1 <= n + 1 <= 40:
                return n + 1, f"Lösung {n}"
        elif 1 <= n <= 40:
            return n, f"{LABELS[kind]} {n}"
    d = date_in_name(text)
    if d is not None:
        w = _block_week_of_day(d, start)
        if w is not None:
            return w, f"Datum {d.strftime('%d.%m.')}"
    return None


def suggest(name: str, first_page: str | None, start) -> dict | None:
    """Vorschlag fuer eine Datei in "Nicht zugeordnet": erste Seite (Titel der Folien), dann Nummer am Anfang des
    Namens. `start`: Montag der ersten Semesterwoche (date)."""
    if first_page:
        head = collapse(first_page)[:400]
        h = _hint_week(head, start)
        if h:
            return {"week": h[0], "reason": f"Inhalt: {h[1]}"}
    m = _LEADING_NUMBER.search(_nfc(name or ""))
    if m:
        n = int(m.group(1))
        if 1 <= n <= 40:
            return {"week": n, "reason": f"Nummer {n} am Anfang des Namens"}
    return None


def bulk_uploads(files: list[dict]) -> set[str]:
    """Stud.IP-Sammelupload zu Semesterbeginn: >= 6 Dateien eines Kurses am selben Tag, Woche 0/1, ohne Nummer im
    Namen, nur Vorlesung/Skript/Uebung/Loesung, keine eigenen. `files`: {id, course, day, week, doc_type, hint}."""
    groups: dict[str, list[str]] = {}
    for f in files:
        if f["course"] == "__user__" or f.get("hint") is not None or f["week"] not in (0, 1) or f.get("doc_type") not in LECTURE_WEEK_TYPES:
            continue
        if f.get("day") is None:
            continue
        groups.setdefault(f"{f['course']}|{f['day']}", []).append(f["id"])
    return {i for ids in groups.values() if len(ids) >= BULK_MINIMUM for i in ids}


# ----------------------------------------------------------------------------
# Aendern (Endpunkte in app/server.py)
# ----------------------------------------------------------------------------

def ensure_tables(conn) -> None:
    conn.executescript(TABLE_SQL)


def _clean(t) -> str:
    return collapse(t if isinstance(t, str) else "")[:80]


def _auto_row(conn, m: int, w: int, now: str) -> int:
    r = conn.execute("SELECT id FROM module_sections WHERE module_id=? AND week=?", (m, w)).fetchone()
    if r:
        return r[0]
    return conn.execute("INSERT INTO module_sections(module_id, week, created_at) VALUES (?,?,?)", (m, w, now)).lastrowid


def create(conn, m: int, title, after, now: str) -> str:
    ensure_tables(conn)
    title = _clean(title)
    if not title:
        raise EditError("Bitte einen Namen eingeben.")
    n = week_number_in_title(title)
    if n is not None:
        rid = _auto_row(conn, m, n, now)
        conn.execute("UPDATE module_sections SET hidden=0 WHERE id=?", (rid,))
        return key(n)
    layout = load(conn).get(m, Layout())
    a = week_of_key(after)
    rank = layout.rank(a) + 0.5 if a is not None else None
    sid = conn.execute("INSERT INTO module_sections(module_id, title, rank, created_at) VALUES (?,?,?,?)", (m, title, rank, now)).lastrowid
    if a is not None and layout.sort(a) is not None:
        s = layout.sort(a)
        conn.execute("UPDATE module_sections SET sort=sort+1 WHERE module_id=? AND sort>?", (m, s))
        conn.execute("UPDATE module_sections SET sort=? WHERE id=?", (s + 1, sid))
    return f"s:{sid}"


def rename(conn, m: int, k, title, now: str) -> None:
    ensure_tables(conn)
    w = week_of_key(k)
    if w is None:
        raise EditError("Unbekannter Abschnitt.")
    title = _clean(title)
    sid = section_id(w)
    if sid is not None:
        if not title:
            raise EditError("Bitte einen Namen eingeben.")
        if conn.execute("UPDATE module_sections SET title=? WHERE id=? AND module_id=? AND week IS NULL", (title, sid, m)).rowcount == 0:
            raise EditError("Abschnitt nicht gefunden.")
        return
    rid = _auto_row(conn, m, w, now)
    conn.execute("UPDATE module_sections SET title=? WHERE id=?", (title or None, rid))


def remove(conn, m: int, k, now: str) -> None:
    ensure_tables(conn)
    w = week_of_key(k)
    if w is None or w == UNASSIGNED:
        raise EditError("Dieser Abschnitt lässt sich nicht löschen.")
    sid = section_id(w)
    if sid is not None:
        if conn.execute("DELETE FROM module_sections WHERE id=? AND module_id=? AND week IS NULL", (sid, m)).rowcount == 0:
            raise EditError("Abschnitt nicht gefunden.")
    else:
        rid = _auto_row(conn, m, w, now)
        conn.execute("UPDATE module_sections SET hidden=1, title=NULL, sort=NULL WHERE id=?", (rid,))
    conn.execute("DELETE FROM module_file_places WHERE module_id=? AND section=?", (m, k))


def reorder(conn, m: int, keys, now: str) -> None:
    ensure_tables(conn)
    keys = keys if isinstance(keys, list) else []
    weeks = [week_of_key(k) for k in keys]
    if any(w is None for w in weeks) or len(set(weeks)) != len(weeks):
        raise EditError("Ungültige Reihenfolge.")
    last = None
    for i, w in enumerate(weeks):
        sid = section_id(w)
        if sid is not None:
            rank = 10 * last + 0.5 if last is not None else 0.5
            conn.execute("UPDATE module_sections SET sort=?, rank=? WHERE id=? AND module_id=?", (float(i), rank, sid, m))
        else:
            rid = _auto_row(conn, m, w, now)
            conn.execute("UPDATE module_sections SET sort=? WHERE id=?", (float(i), rid))
            if w >= 1:
                last = w


def place(conn, m: int, file_ids, to, now: str) -> int:
    ensure_tables(conn)
    if to is not None:
        w = week_of_key(to)
        if w is None or not load(conn).get(m, Layout()).exists(w):
            raise EditError("Unbekannter Abschnitt.")
    n = 0
    for fid in dict.fromkeys(f for f in (file_ids or []) if isinstance(f, str)):
        if not conn.execute("SELECT 1 FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=? AND c.module_id=?", (fid, m)).fetchone():
            continue
        if to is not None:
            conn.execute("INSERT OR REPLACE INTO module_file_places(file_id, module_id, section, placed_at) VALUES (?,?,?,?)", (fid, m, to, now))
        else:
            conn.execute("DELETE FROM module_file_places WHERE file_id=?", (fid,))
        n += 1
    return n


def reset(conn, m: int) -> None:
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='module_sections'").fetchone():
        return
    conn.execute("DELETE FROM module_sections WHERE module_id=?", (m,))
    conn.execute("DELETE FROM module_file_places WHERE module_id=?", (m,))
