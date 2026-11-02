"""Semester und vorlesungsfreie Zeiten aus Stud.IP (02.11.2026, Auftrag des Inhabers "alles schlau einbauen").

app/holidays.py kennt Vorlesungszeiten und Unterbrechungen aus den offiziellen Zeitplaenen der Hochschulen. Stud.IP
liefert ueber die JSON:API dazu die Semester mit Vorlesungsbeginn und -ende (`semesters`) und, wenn die Hochschule sie
pflegt, vorlesungsfreie Zeiten (`holidays`). Beides ergaenzt den Zeitplan, statt ihn zu ersetzen:
 - Ein Stud.IP-Semester mit Vorlesungsbeginn und -ende gilt fuer das Semester gleichen Namens (semesters.key: "WiSe
   2026/27" = "WS 26/27"); die Unterbrechungen des Zeitplans bleiben. Semester, die der Zeitplan nicht kennt (spaeter
   als die nachgetragenen), kommen dazu. Die vorlesungsfreie Zeit zwischen zwei Semestern folgt daraus wie bisher.
 - Vorlesungsfreie Zeiten aus Stud.IP sind Unterbrechungen ("pause") mit ihrem Titel.
Planer (timetable.occurrences: an diesen Tagen keine Uni-Veranstaltungen erwarten) und Kalender lesen beides ueber
holidays.day_marks(..., studip=load(conn)).

Lernplan (`lecture_week`): In Unterbrechungen und in der vorlesungsfreien Zeit kommt kein neuer Stoff. Ein solcher Tag
bekommt den offenen Stoff der letzten Vorlesungswoche davor, statt einer Lehrwoche ohne Unterlagen ("Keine offenen
Vorlesungen"). Einzelne Feiertage aendern die Lehrwoche nicht.

Nur lesend. Gleiche Regeln im Swift-Kern (StudIPTerms.swift), Fixture tools/gen-studip-extras-fixture.py.
"""
from __future__ import annotations

import re
from datetime import date, timedelta

TABLE = """CREATE TABLE IF NOT EXISTS studip_periods (
    kind TEXT NOT NULL,                -- semester | holiday
    id TEXT NOT NULL,
    title TEXT,
    start TEXT,                        -- YYYY-MM-DD
    end TEXT,
    lectures_start TEXT,               -- nur Semester: Vorlesungsbeginn
    lectures_end TEXT,                 -- nur Semester: Vorlesungsende
    fetched_at TEXT,
    PRIMARY KEY (kind, id)
)"""

_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")
# Lehrwoche eines freien Tages: so weit zurueck wird hoechstens nach dem letzten Vorlesungstag gesucht
LOOKBACK_DAYS = 200
FREE_KINDS = ("pause", "vorlesungsfrei")


def _day(v) -> str | None:
    """ISO-Datum (auch mit Uhrzeit und Versatz) -> "YYYY-MM-DD"; Zahlen (Unix-Zeit) und Unlesbares -> None."""
    if isinstance(v, str) and _DAY_RE.match(v):
        try:
            return date.fromisoformat(v[:10]).isoformat()
        except ValueError:
            return None
    return None


def _text(v) -> str:
    return v.strip() if isinstance(v, str) else ""


def parse_semesters(data) -> list[dict]:
    """`data` von jsonapi.php/v1/semesters -> [{id, title, start, end, lectures_start, lectures_end}], nach Beginn.
    Annahme (Stud.IP 5, SemestersSchema): Attribute title, start, end, start-of-lectures, end-of-lectures als ISO-Zeit.
    Eintraege ohne Kennung fehlen; fehlende Daten bleiben None."""
    out = []
    for s in data if isinstance(data, list) else []:
        if not isinstance(s, dict) or not isinstance(s.get("id"), (str, int)) or s.get("id") in ("", None):
            continue
        a = s.get("attributes") if isinstance(s.get("attributes"), dict) else {}
        out.append({"id": str(s["id"]), "title": _text(a.get("title")), "start": _day(a.get("start")), "end": _day(a.get("end")),
                    "lectures_start": _day(a.get("start-of-lectures")), "lectures_end": _day(a.get("end-of-lectures"))})
    return sorted(out, key=lambda x: (x["start"] or "", x["id"]))


def parse_holidays(data) -> list[dict]:
    """`data` von jsonapi.php/v1/holidays -> [{id, title, start, end}], nach Beginn. Annahme (nicht an der LUH
    belegt): Attribute title (sonst name), start (sonst begin), end; ohne Ende ein Tag. Ohne Beginn oder mit Ende vor
    dem Beginn fehlt der Eintrag."""
    out = []
    for h in data if isinstance(data, list) else []:
        if not isinstance(h, dict) or not isinstance(h.get("id"), (str, int)) or h.get("id") in ("", None):
            continue
        a = h.get("attributes") if isinstance(h.get("attributes"), dict) else {}
        start = _day(a.get("start")) or _day(a.get("begin"))
        end = _day(a.get("end")) or start
        if not start or end < start:
            continue
        title = _text(a.get("title")) or _text(a.get("name")) or "Vorlesungsfrei"
        out.append({"id": str(h["id"]), "title": title[:80], "start": start, "end": end})
    return sorted(out, key=lambda x: (x["start"], x["id"]))


def merged_semesters(university: str, studip: dict | None) -> list[tuple[str, str, str, list[tuple[str, str, str]]]]:
    """Zeitplan der Hochschule (holidays.SEMESTERS) mit den Vorlesungszeiten aus Stud.IP: gleiches Semester -> Beginn
    und Ende aus Stud.IP, Unterbrechungen bleiben; unbekannte Semester kommen ohne Unterbrechungen dazu. Nach Beginn."""
    from . import holidays, semesters
    base = [(n, s, e, list(b)) for n, s, e, b in holidays.SEMESTERS.get(university, [])]
    if not studip:
        return base
    out = [list(x) for x in base]
    index = {semesters.key(x[0]): i for i, x in enumerate(out) if semesters.key(x[0]) is not None}
    for s in studip.get("semesters") or []:
        ls, le = s.get("lectures_start"), s.get("lectures_end")
        if not ls or not le or le < ls:
            continue
        k = semesters.key(s.get("title"))
        if k is not None and k in index:
            out[index[k]][1], out[index[k]][2] = ls, le
        else:
            name = semesters.label(k) if k is not None else (s.get("title") or "Semester")
            if k is not None:
                index[k] = len(out)
            out.append([name, ls, le, []])
    out.sort(key=lambda x: (x[1], x[0]))
    return [(n, s, e, b) for n, s, e, b in out]


def holiday_breaks(studip: dict | None) -> list[tuple[str, str, str]]:
    """Vorlesungsfreie Zeiten aus Stud.IP als Unterbrechungen (von, bis, Bezeichnung)."""
    return [(h["start"], h["end"], h["title"]) for h in (studip or {}).get("holidays") or []]


# ----------------------------------------------------------------------------
# Speicher
# ----------------------------------------------------------------------------

def ensure_table(conn) -> None:
    conn.execute(TABLE)


def store(conn, kind: str, items: list[dict] | None, fetched_at: str) -> int:
    """Semester (kind "semester") bzw. vorlesungsfreie Zeiten ("holiday") ersetzen. None = nicht geladen: der Bestand
    bleibt. Liefert die Zahl der gespeicherten Eintraege."""
    if items is None:
        return 0
    ensure_table(conn)
    conn.execute("DELETE FROM studip_periods WHERE kind=?", (kind,))
    for x in items:
        conn.execute("""INSERT OR REPLACE INTO studip_periods(kind, id, title, start, end, lectures_start, lectures_end, fetched_at)
                        VALUES (?,?,?,?,?,?,?,?)""",
                     (kind, x["id"], x.get("title"), x.get("start"), x.get("end"), x.get("lectures_start"), x.get("lectures_end"), fetched_at))
    return len(items)


def load(conn) -> dict | None:
    """Gespeicherte Stud.IP-Zeiten fuer holidays.day_marks; None, solange nichts gespeichert ist."""
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_periods'").fetchone():
        return None
    sems, hols = [], []
    for r in conn.execute("SELECT kind, id, title, start, end, lectures_start, lectures_end FROM studip_periods ORDER BY start, id").fetchall():
        kind, id_, title, start, end, ls, le = tuple(r)
        if kind == "semester":
            sems.append({"id": id_, "title": title or "", "start": start, "end": end, "lectures_start": ls, "lectures_end": le})
        elif kind == "holiday" and start and end:
            hols.append({"id": id_, "title": title or "Vorlesungsfrei", "start": start, "end": end})
    if not sems and not hols:
        return None
    return {"semesters": sems, "holidays": hols}


# ----------------------------------------------------------------------------
# Lernplan
# ----------------------------------------------------------------------------

def free_days(start: date, end: date, university: str, studip: dict | None) -> set[str]:
    """Tage in Unterbrechungen und in der vorlesungsfreien Zeit (ohne einzelne Feiertage), ab LOOKBACK_DAYS vor `start`."""
    from . import holidays
    marks = holidays.day_marks(start - timedelta(days=LOOKBACK_DAYS), end, university, studip=studip)
    return {d for d, ms in marks.items() if any(m["kind"] in FREE_KINDS for m in ms)}


def lecture_week(sem_start: date, d: date, free: set[str]) -> int:
    """Lehrwoche fuer den Lernplan: an freien Tagen die des letzten Tages davor, der nicht frei ist (study.day_week)."""
    from . import study
    x, n = d, 0
    while x.isoformat() in free and n < LOOKBACK_DAYS:
        x -= timedelta(days=1)
        n += 1
    return study.day_week(sem_start, x)
