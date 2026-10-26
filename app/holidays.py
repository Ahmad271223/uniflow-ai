"""Feiertage und vorlesungsfreie Zeit fuer die Kalender (gruen markiert).

Weder Stud.IP noch Learnweb/LSF liefern eine Ferienliste (geprueft 26.10.2026). Deshalb:
 - Gesetzliche Feiertage in Niedersachsen (beide Hochschulen liegen dort) werden berechnet.
 - Vorlesungszeiten und Unterbrechungen stammen aus den offiziellen Zeitplaenen der Hochschulen:
   LUH:        https://www.uni-hannover.de/studium/semestertermine (abgerufen 26.10.2026)
   Hildesheim: https://www.uni-hildesheim.de/termine-fristen/ (Zeitplan-PDFs bis SoSe 2030, abgerufen 26.10.2026;
               im PDF SoSe 2028 steht als Beginn der Projektwoche "06.06.2027", gemeint ist 2028)
   Die Hochschulen geben die Angaben ohne Gewaehr an; neue Semester werden hier nachgetragen.
Vorlesungsfreie Zeit = vom Tag nach dem Ende der Vorlesungen bis zum Tag vor dem Beginn der naechsten (wie bei der LUH).
"""
from __future__ import annotations

from datetime import date, timedelta

# (Semester, Beginn der Vorlesungen, Ende der Vorlesungen, [(von, bis, Bezeichnung), ...])
SEMESTERS: dict[str, list[tuple[str, str, str, list[tuple[str, str, str]]]]] = {
    "luh": [
        ("SoSe 2026", "2026-04-07", "2026-07-18", [("2026-05-26", "2026-05-30", "Exkursionswoche")]),
        ("WiSe 2026/27", "2026-10-12", "2027-01-30", [("2026-12-23", "2027-01-05", "Weihnachtspause")]),
        ("SoSe 2027", "2027-04-05", "2027-07-17", [("2027-05-18", "2027-05-23", "Exkursionswoche")]),
        ("WiSe 2027/28", "2027-10-11", "2028-01-29", [("2027-12-24", "2028-01-08", "Weihnachtspause")]),
        ("SoSe 2028", "2028-04-18", "2028-07-29", [("2028-06-06", "2028-06-10", "Exkursionswoche")]),
        ("WiSe 2028/29", "2028-10-09", "2029-01-27", [("2028-12-25", "2029-01-06", "Weihnachtspause")]),
    ],
    "hildesheim": [
        ("SoSe 2026", "2026-04-07", "2026-07-17", [("2026-05-26", "2026-05-29", "Exkursions- und Projektwoche")]),
        ("WiSe 2026/27", "2026-10-19", "2027-02-05", [("2026-12-23", "2027-01-01", "Weihnachtspause")]),
        ("SoSe 2027", "2027-04-05", "2027-07-16", [("2027-05-18", "2027-05-21", "Exkursions- und Projektwoche")]),
        ("WiSe 2027/28", "2027-10-11", "2028-02-04", [("2027-12-23", "2028-01-03", "Weihnachtspause")]),
        ("SoSe 2028", "2028-04-18", "2028-07-28", [("2028-06-06", "2028-06-09", "Exkursions- und Projektwoche")]),
        ("WiSe 2028/29", "2028-10-09", "2029-02-02", [("2028-12-23", "2029-01-05", "Weihnachtspause")]),
        ("SoSe 2029", "2029-04-09", "2029-07-20", [("2029-05-22", "2029-05-25", "Exkursions- und Projektwoche")]),
        ("WiSe 2029/30", "2029-10-08", "2030-02-01", [("2029-12-21", "2030-01-04", "Weihnachtspause")]),
        ("SoSe 2030", "2030-04-15", "2030-07-26", [("2030-06-11", "2030-06-14", "Exkursions- und Projektwoche")]),
    ],
}


def easter(year: int) -> date:
    """Ostersonntag (gregorianisch, Algorithmus nach Meeus/Jones/Butcher)."""
    a, b, c = year % 19, year // 100, year % 100
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    l = (32 + 2 * e + 2 * i - h - k) % 7  # noqa: E741
    m = (a + 11 * h + 22 * l) // 451
    month, day = divmod(h + l - 7 * m + 114, 31)
    return date(year, month, day + 1)


def public_holidays(year: int) -> dict[str, str]:
    """Gesetzliche Feiertage in Niedersachsen (Reformationstag seit 2018)."""
    e = easter(year)
    days = {date(year, 1, 1): "Neujahr", e - timedelta(days=2): "Karfreitag", e + timedelta(days=1): "Ostermontag",
            date(year, 5, 1): "Tag der Arbeit", e + timedelta(days=39): "Christi Himmelfahrt",
            e + timedelta(days=50): "Pfingstmontag", date(year, 10, 3): "Tag der Deutschen Einheit",
            date(year, 12, 25): "1. Weihnachtstag", date(year, 12, 26): "2. Weihnachtstag"}
    if year >= 2018:
        days[date(year, 10, 31)] = "Reformationstag"
    return {d.isoformat(): name for d, name in sorted(days.items())}


def _span(a: str, b: str):
    d, end = date.fromisoformat(a), date.fromisoformat(b)
    while d <= end:
        yield d.isoformat()
        d += timedelta(days=1)


def day_marks(start: date, end: date, university: str) -> dict[str, list[dict]]:
    """Markierungen je Tag im Zeitraum: feiertag | pause (Weihnachtspause, Exkursionswoche) | vorlesungsfrei.
    Nur Tage mit Markierung stehen im Ergebnis; Feiertage zuerst."""
    lo, hi = start.isoformat(), end.isoformat()
    out: dict[str, list[dict]] = {}

    def add(day: str, kind: str, label: str) -> None:
        if lo <= day <= hi:
            out.setdefault(day, []).append({"kind": kind, "label": label})

    for y in range(start.year, end.year + 1):
        for day, name in public_holidays(y).items():
            add(day, "feiertag", name)
    sems = SEMESTERS.get(university, [])
    for _, _, _, breaks in sems:
        for a, b, label in breaks:
            for day in _span(a, b):
                add(day, "pause", label)
    for (_, _, end_prev, _), (_, start_next, _, _) in zip(sems, sems[1:]):
        a = (date.fromisoformat(end_prev) + timedelta(days=1)).isoformat()
        b = (date.fromisoformat(start_next) - timedelta(days=1)).isoformat()
        for day in _span(a, b):
            add(day, "vorlesungsfrei", "Vorlesungsfreie Zeit")
    return out


def default_term(university: str, today: date | None = None) -> dict | None:
    """Vorlesungszeit des laufenden oder naechsten Semesters laut Zeitplan (Vorgabe fuer den Stundenplan)."""
    t = (today or date.today()).isoformat()
    for name, start, end, _ in SEMESTERS.get(university, []):
        if end >= t:
            return {"name": name, "start": start, "end": end}
    return None


def lecture_free(day: date, university: str) -> bool:
    """Feiertag, Unterbrechung oder vorlesungsfreie Zeit (fuer den Stundenplan: keine Vorlesungen)."""
    return bool(day_marks(day, day, university))


def calendar_extras(conn, start: date, end: date, university: str | None = None) -> tuple[dict, dict]:
    """(Markierungen je Tag, Learnweb-Fristen je Tag) fuer Lernkalender und Stundenplan."""
    from . import config, db
    marks = day_marks(start, end, university or config.UNIVERSITY)
    by_day: dict[str, list[dict]] = {}
    for r in db.rows(conn, """SELECT d.id, d.title, d.full_title, d.kind, d.due_at, d.url, d.overdue, c.title AS course_title, m.color
                              FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id LEFT JOIN modules m ON m.id=c.module_id
                              WHERE d.due_at >= ? AND d.due_at < ? ORDER BY d.due_at""",
                     (start.isoformat(), (end + timedelta(days=1)).isoformat())):
        by_day.setdefault(r["due_at"][:10], []).append({
            "id": r["id"], "title": r["title"], "full_title": r["full_title"] or r["title"], "kind": r["kind"],
            "kind_label": DEADLINE_LABELS.get(r["kind"], "Frist") + (" (überfällig)" if r["overdue"] else ""), "time": r["due_at"][11:16], "url": r["url"],
            "overdue": bool(r["overdue"]),
            "course_title": r["course_title"], "color": r["color"]})
    return marks, by_day


DEADLINE_LABELS = {"abgabe": "Abgabe", "test_ende": "Test endet", "test_beginn": "Test beginnt", "frist": "Frist", "termin": "Termin"}
