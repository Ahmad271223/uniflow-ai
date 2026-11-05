"""Rueckfragen zum eigenen Stud.IP-Kalender und Ausfaelle laut Stud.IP (PC, Windows-App, Web; vorher nur iPad).

Gleiche Endpunkte und Antworten wie das lokale Backend des iPads (`TimetableEndpoints.swift`, `StudIPCalendar.questions`,
`StudIPCancellations.list`; docs/IPAD-STUDIP-SYNC.md §10):

- GET  /api/timetable/studip-cancelled?start=YYYY-MM-DD&end=YYYY-MM-DD
      `[{event_id, date}]`: Ausfaelle laut Stud.IP im Zeitraum (Ausnahme `cancelled` mit der Notiz des Abgleichs). Die
      Oberflaeche blendet genau diese Vorkommen aus wie Stud.IP (Entscheidung des Inhabers 28.10.2026); selbst
      markierte Ausfaelle und „nicht besucht“ bleiben sichtbar.
- GET  /api/timetable/studip-questions
      `{hidden: [{course_id, title, times}], busy: [{course_id, title, times: [{cycle_id, weekday, start_time,
      end_time, room, attend}]}]}`.
- POST /api/timetable/studip-questions/course {course_id, include}   Kurs ohne Kalendertermine uebernehmen/weglassen
- POST /api/timetable/studip-questions/times {course_id, attend: [cycle_id]}   besuchte Termine eines vollen Kurses

Unterschied zum iPad: Python kennt keine Kurszeiten, sondern fasst Einzeltermine zu Serien (`timetable.studip_entries`).
Eine „Kurszeit“ (`cycle_id`) ist hier die Serie `Kurs|Wochentag|Beginn|Ende` (`timetable.series_key`).
- hidden: Kurse, von denen keine Serie im eigenen Kalender steht (`calendar = "kurs_fehlt"`), ohne Antwort.
  „Übernehmen“ nimmt den Kurs mit der bisherigen Regel (parallele Gruppen zur Auswahl), „Weglassen“ laesst ihn weg.
- busy: Kurse mit drei oder mehr woechentlichen Serien im eigenen Kalender, zu denen noch nicht alle beantwortet sind.
  Abgewaehlte Serien bekommen attend=0 (grau, Zeit frei), auch wenn der Abgleich sie spaeter neu anlegt.
Antworten je Datenbank, also je Nutzer und Hochschule (Tabelle `studip_course_choices`, wie auf dem iPad erst bei Bedarf
angelegt).
"""
from __future__ import annotations

import json
from datetime import date

from fastapi import APIRouter, Body, HTTPException

from . import db

router = APIRouter()

BUSY_TIMES = 3                                       # ab so vielen Serien je Woche fragt die App (StudIPCalendar.busyTimes)

CHOICES_SQL = """CREATE TABLE IF NOT EXISTS studip_course_choices (
    course_id TEXT PRIMARY KEY,
    include INTEGER,                   -- Kurs ohne Kalendertermine: 1 = uebernehmen, 0 = weglassen, NULL = offen
    times_known TEXT,                  -- Serien, zu denen der Nutzer geantwortet hat (JSON-Liste)
    times_skipped TEXT,                -- davon nicht besucht (JSON-Liste)
    updated_at TEXT
)"""


def _has_choices(conn) -> bool:
    return bool(db.row(conn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_course_choices'"))


def _list(raw) -> set[str]:
    try:
        v = json.loads(raw or "[]")
    except ValueError:
        return set()
    return {x for x in v if isinstance(x, str)} if isinstance(v, list) else set()


def choices(conn) -> dict[str, dict]:
    """Gespeicherte Antworten je Kurs: {include: True|False|None, known: set, skipped: set}."""
    if not _has_choices(conn):
        return {}
    return {r["course_id"]: {"include": None if r["include"] is None else bool(r["include"]),
                             "known": _list(r["times_known"]), "skipped": _list(r["times_skipped"])}
            for r in db.rows(conn, "SELECT course_id, include, times_known, times_skipped FROM studip_course_choices")}


def still_hidden(conn, merged: list[dict], hidden: set) -> set:
    """Fuer `timetable.studip_entries`: Kurse, die der Nutzer trotz fehlender Kalendertermine uebernommen hat, gelten
    nicht mehr als fehlend; ihre Serien folgen der bisherigen Regel (`calendar` None, parallele Gruppen zur Auswahl)."""
    if not hidden:
        return hidden
    included = {c for c, ch in choices(conn).items() if ch["include"] is True and c in hidden}
    for e in merged:
        if e.get("course_id") in included:
            e["calendar"] = None
    return hidden - included


def skipped_series(conn) -> set[str]:
    out: set[str] = set()
    for ch in choices(conn).values():
        out |= ch["skipped"]
    return out


def mark_skipped(conn, event_ids: list[int]) -> None:
    """Nach dem Abgleich: neu angelegte Serien, die der Nutzer abgewaehlt hatte, gleich als „nicht besucht“."""
    if not event_ids:
        return
    skipped = skipped_series(conn)
    if not skipped:
        return
    from .timetable import series_key
    for ev in db.rows(conn, f"SELECT id, course_id, weekday, start_time, end_time FROM course_events WHERE id IN ({','.join('?' * len(event_ids))})",
                      tuple(event_ids)):
        if ev["course_id"] and series_key(ev) in skipped:
            conn.execute("UPDATE course_events SET attend=0 WHERE id=?", (ev["id"],))


def _events_of(conn, e: dict) -> list[dict]:
    return db.rows(conn, """SELECT id, attend FROM course_events WHERE source LIKE 'studip%' AND course_id=? AND weekday=?
                            AND start_time=? AND end_time=?""", (e["course_id"], int(e["weekday"]), e["start_time"], e["end_time"]))


def questions(conn, entries: list[dict] | None = None) -> dict:
    """Offene Fragen wie `StudIPCalendar.questions`; ohne eigenen Kalender keine."""
    from . import timetable
    if timetable.calendar_state(conn) is None:
        return {"hidden": [], "busy": []}
    entries = timetable.studip_entries(conn) if entries is None else entries
    ch = choices(conn)
    titles = {r["id"]: r["title"] for r in db.rows(conn, "SELECT id, title FROM courses")}
    title = lambda c, e=None: titles.get(c) or (e or {}).get("title") or ""
    hidden: dict[str, int] = {}
    times: dict[str, list[dict]] = {}
    for e in entries:
        c = e.get("course_id")
        if not c:
            continue
        if e.get("calendar") == "kurs_fehlt" and (ch.get(c) or {}).get("include") is None:
            hidden[c] = hidden.get(c, 0) + 1
        elif e.get("calendar") == "eigen" and e.get("rrule") != "once":
            times.setdefault(c, []).append(e)
    busy = []
    for c, lst in sorted(times.items(), key=lambda kv: (title(kv[0], kv[1][0]), kv[0])):
        if len(lst) < BUSY_TIMES:
            continue
        known, skipped = (ch.get(c) or {}).get("known", set()), (ch.get(c) or {}).get("skipped", set())
        keys = [timetable.series_key(e) for e in lst]
        if all(k in known for k in keys):
            continue
        rows = []
        for e, k in sorted(zip(lst, keys), key=lambda x: (int(x[0]["weekday"]), x[0]["start_time"], x[1])):
            evs = _events_of(conn, e)
            attend = (evs[0]["attend"] if evs[0]["attend"] is not None else 1) != 0 if evs else k not in skipped
            rows.append({"cycle_id": k, "weekday": int(e["weekday"]), "start_time": e["start_time"], "end_time": e["end_time"],
                         "room": e.get("room") or "", "attend": attend})
        busy.append({"course_id": c, "title": title(c, lst[0]), "times": rows})
    return {"hidden": [{"course_id": c, "title": title(c), "times": n}
                       for c, n in sorted(hidden.items(), key=lambda kv: (title(kv[0]), kv[0]))],
            "busy": busy}


def set_include(conn, course: str, include: bool) -> None:
    conn.execute(CHOICES_SQL)
    conn.execute("""INSERT INTO studip_course_choices(course_id, include, updated_at) VALUES (?,?,?)
                    ON CONFLICT(course_id) DO UPDATE SET include=excluded.include, updated_at=excluded.updated_at""",
                 (course, 1 if include else 0, db.now_iso()))


def set_times(conn, course: str, known: list[str], attend: set[str]) -> None:
    """Gefragte Serien merken; nicht besuchte bekommen attend=0, besuchte attend=1, soweit sie im Stundenplan stehen."""
    from .timetable import series_key
    conn.execute(CHOICES_SQL)
    skipped = sorted({k for k in known if k not in attend})
    conn.execute("""INSERT INTO studip_course_choices(course_id, times_known, times_skipped, updated_at) VALUES (?,?,?,?)
                    ON CONFLICT(course_id) DO UPDATE SET times_known=excluded.times_known, times_skipped=excluded.times_skipped,
                    updated_at=excluded.updated_at""",
                 (course, json.dumps(sorted(set(known))), json.dumps(skipped), db.now_iso()))
    for ev in db.rows(conn, "SELECT id, course_id, weekday, start_time, end_time FROM course_events WHERE source LIKE 'studip%' AND course_id=?", (course,)):
        k = series_key(ev)
        if k in known:
            conn.execute("UPDATE course_events SET attend=? WHERE id=?", (1 if k in attend else 0, ev["id"]))


def cancelled(conn, start: str, end: str) -> list[dict]:
    """Ausfaelle laut Stud.IP mit Datum im Zeitraum (einschliesslich)."""
    from .timetable import STUDIP_CANCEL_NOTE
    return db.rows(conn, """SELECT x.event_id, x.date FROM event_exceptions x JOIN course_events e ON e.id=x.event_id
                            WHERE x.type='cancelled' AND x.note=? AND x.date>=? AND x.date<=? ORDER BY x.date, x.event_id""",
                   (STUDIP_CANCEL_NOTE, start, end))


# ---------------------------------------------------------------- Endpunkte

def _day(v: str, name: str) -> date:
    try:
        return date.fromisoformat(str(v or ""))
    except ValueError:
        raise HTTPException(422, f"{name} ist kein Datum (YYYY-MM-DD)")


@router.get("/api/timetable/studip-cancelled")
def api_studip_cancelled(start: str = "", end: str = ""):
    a, b = _day(start, "start"), _day(end, "end")
    if b < a or (b - a).days > 400:
        raise HTTPException(422, "Zeitraum ungültig")
    with db.cursor() as conn:
        return cancelled(conn, a.isoformat(), b.isoformat())


@router.get("/api/timetable/studip-questions")
def api_studip_questions():
    with db.cursor() as conn:
        return questions(conn)


def _course(body: dict) -> str:
    c = body.get("course_id")
    if not isinstance(c, str) or not c.strip():
        raise HTTPException(400, "course_id fehlt")
    return c


@router.post("/api/timetable/studip-questions/course")
def api_studip_question_course(body: dict = Body(...)):
    from . import timetable
    course = _course(body)
    include = body.get("include")
    if not isinstance(include, bool):
        raise HTTPException(400, "include fehlt")
    with db.cursor() as conn:
        if course not in {q["course_id"] for q in questions(conn)["hidden"]}:
            raise HTTPException(404, "Keine offene Frage zu diesem Kurs")
        set_include(conn, course, include)
        r = timetable.auto_import(conn)
    return {"ok": True, "new": r["new"], "removed": r["removed"], "pending_groups": r["pending_groups"]}


@router.post("/api/timetable/studip-questions/times")
def api_studip_question_times(body: dict = Body(...)):
    course = _course(body)
    lst = body.get("attend")
    if not isinstance(lst, list) or not all(isinstance(x, str) for x in lst):
        raise HTTPException(400, "attend fehlt")
    attend = set(lst)
    with db.cursor() as conn:
        q = next((x for x in questions(conn)["busy"] if x["course_id"] == course), None)
        if not q:
            raise HTTPException(404, "Keine offene Frage zu diesem Kurs")
        known = [t["cycle_id"] for t in q["times"]]
        set_times(conn, course, known, attend)
    return {"ok": True, "attend": sum(1 for k in known if k in attend), "skipped": sum(1 for k in known if k not in attend)}
