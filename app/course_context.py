"""Kontext aus Stud.IP fuer die KI (Entscheidung des Inhabers 02.11.2026): Kursbeschreibung, Sonstiges und die
Sitzungsthemen (Termin-Attribut `description`) eines Moduls in einem Zeitraum. Nur was zum Modul und zur Woche passt;
gekuerzt in ai.studip_context. Gleiche Regel im Swift-Kern (CourseContext).
"""
from __future__ import annotations

from datetime import date, timedelta

from . import ai, db


def _courses(conn, course_id: str | None, module_id) -> list[str]:
    """Kurse des Moduls (aktiv), der eigene Kurs zuerst; ohne Modul nur der Kurs selbst"""
    ids = [course_id] if course_id else []
    if module_id is not None:
        ids += [r["id"] for r in db.rows(conn, "SELECT id FROM courses WHERE module_id=? AND active=1 ORDER BY id", (module_id,))
                if r["id"] != course_id]
    return ids


def build(conn, course_ids: list[str], start: date, end: date) -> str:
    """Kontextblock fuer die Kurse im Zeitraum [start, end] (ganze Tage); leer ohne Beschreibung und Sitzungsthema"""
    if not course_ids:
        return ""
    marks = ",".join("?" * len(course_ids))
    rows = {r["id"]: r for r in db.rows(conn, f"SELECT id, description, miscellaneous FROM courses WHERE id IN ({marks})", course_ids)}
    desc = next((rows[c]["description"] for c in course_ids if c in rows and (rows[c]["description"] or "").strip()), "")
    misc = next((rows[c]["miscellaneous"] for c in course_ids if c in rows and (rows[c]["miscellaneous"] or "").strip()), "")
    sessions, seen = [], set()
    for r in db.rows(conn, f"""SELECT start, description FROM studip_events WHERE course_id IN ({marks}) AND COALESCE(cancelled, 0)=0
                              AND start >= ? AND start < ? AND COALESCE(description, '') <> '' ORDER BY start, id""",
                     [*course_ids, start.isoformat(), (end + timedelta(days=1)).isoformat()]):
        t = (r["description"] or "").strip()
        if t and t not in seen:
            seen.add(t)
            sessions.append({"date": (r["start"] or "")[:10], "topic": t})
    return ai.studip_context(desc, misc, sessions)


def for_file(conn, file_id: str | None, today: date) -> str:
    """Tutor: Kurs der Datei und die anderen Kurse ihres Moduls, Sitzungsthemen der laufenden Woche (Mo bis So)"""
    if not file_id:
        return ""
    r = db.row(conn, "SELECT c.id, c.module_id FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=? AND c.id <> '__user__'", (file_id,))
    if not r:
        return ""
    monday = today - timedelta(days=today.weekday())
    return build(conn, _courses(conn, r["id"], r["module_id"]), monday, monday + timedelta(days=6))


def for_module_week(conn, module_id, lecture_end: str | None) -> str:
    """Wochentest: Kurse des Moduls, Sitzungsthemen der sieben Tage bis zum Ende der Lehrwoche (`lecture_end`)"""
    try:
        end = date.fromisoformat((lecture_end or "")[:10])
    except ValueError:
        return ""
    return build(conn, _courses(conn, None, module_id), end - timedelta(days=6), end)
