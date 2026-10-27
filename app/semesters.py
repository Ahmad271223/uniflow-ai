"""Semester erkennen: nur aktuelle Kurse werden eingeplant (28.10.2026).

Befund mit echten Daten: Stud.IP liefert alle Veranstaltungen, die der Nutzer je belegt hat (208 Kurse von WiSe 2022/23
bis WiSe 2026/27), und die App fuehrte sie alle als aktiv – mit Modulen, Dateien, Terminen und Lernplaenen aus alten
Semestern. Der feste Filter SEMESTER_FILTER in der .env half nur beim naechsten Abgleich und veraltet jedes Semester.

Regel: Ein Kurs ist aktuell, wenn sein Ende (Stud.IP: `end-semester`, Ende des Semesters als Datum) heute oder spaeter
liegt, oder wenn er unbegrenzt laeuft. Ohne Datum entscheidet der Semestertitel („WiSe 2026/27“, „SoSe 2026“, auch
„WS 26/27“, „Wintersemester 2026/2027“) gegen das heutige Semester (April–September SoSe, sonst WiSe). Kurse ohne
erkennbares Semester bleiben, wie sie sind. Der Nutzer kann jeden Kurs von Hand ein- oder ausschalten (courses.active,
Merker active_custom); solche Entscheidungen ueberschreibt der Abgleich nicht. Module ohne aktiven Kurs werden
ausgeschaltet (modules.active, Merker active_custom), bleiben aber mit ihren Unterlagen erhalten.
"""
from __future__ import annotations

import re
from datetime import date

_RE = re.compile(r"\b(WiSe|SoSe|WS|SS|Wintersemester|Sommersemester)\s*'?(\d{2,4})", re.I)


def _today() -> date:
    """Heute wie im uebrigen Kern (study.today, in Tests und Fixtures eingefroren)."""
    from . import study
    return study.today()


def key(title: str | None) -> tuple[int, int] | None:
    """„WiSe 2026/27“ -> (2026, 2), „SoSe 2026“ -> (2026, 1), „WS 26/27“ -> (2026, 2); None ohne Semester."""
    m = _RE.search(title or "")
    if not m:
        return None
    y = int(m.group(2))
    if y < 100:
        y += 2000
    winter = m.group(1).lower().startswith(("wi", "ws"))
    return (y, 2 if winter else 1)


def current(today: date | None = None) -> tuple[int, int]:
    d = today or _today()
    if 4 <= d.month <= 9:
        return (d.year, 1)
    return (d.year if d.month >= 10 else d.year - 1, 2)


def label(k: tuple[int, int]) -> str:
    y, h = k
    return f"SoSe {y}" if h == 1 else f"WiSe {y}/{str(y + 1)[-2:]}"


def is_current(semester: str | None, semester_end: str | None = None, ends_at: str | None = None,
               today: date | None = None) -> bool | None:
    """True/False, oder None, wenn sich das nicht entscheiden laesst (kein Datum, kein Semester im Titel)."""
    d = today or _today()
    if semester_end == "unbegrenzt":
        return True
    if ends_at:
        return ends_at[:10] >= d.isoformat()
    k = key(semester_end) or key(semester)
    if k is None:
        return None
    return k >= current(d)


def apply_to_course(conn, course_id: str, semester: str | None, semester_end: str | None = None,
                    ends_at: str | None = None, today: date | None = None) -> bool | None:
    """Setzt courses.active nach der Regel, ausser der Nutzer hat selbst entschieden (active_custom)."""
    cur = is_current(semester, semester_end, ends_at, today)
    if cur is not None:
        conn.execute("UPDATE courses SET active=? WHERE id=? AND COALESCE(active_custom, 0)=0", (1 if cur else 0, course_id))
    return cur


def deactivate_stale_modules(conn) -> int:
    """Module, deren Kurse alle aus (active=0) sind, ausschalten; Module ohne Kurse (selbst angelegt) und von Hand
    geschaltete Module (active_custom) bleiben. Liefert die Zahl der ausgeschalteten Module."""
    rows = conn.execute("""SELECT id FROM modules WHERE COALESCE(active, 1)=1 AND COALESCE(active_custom, 0)=0
                           AND EXISTS (SELECT 1 FROM courses c WHERE c.module_id=modules.id)
                           AND NOT EXISTS (SELECT 1 FROM courses c WHERE c.module_id=modules.id AND c.active=1)""").fetchall()
    for r in rows:
        conn.execute("UPDATE modules SET active=0 WHERE id=?", (r[0],))
    return len(rows)


def migrate(conn, today: date | None = None) -> dict:
    """Einmalig fuer bestehende Datenbanken (db._init_db): alle Kurse nach der Regel schalten, Module ohne aktiven Kurs
    aus. Danach ohne Wirkung (Merker in settings), damit spaetere Entscheidungen des Nutzers bleiben."""
    done = conn.execute("SELECT value FROM settings WHERE key='semester_rule_applied'").fetchone()
    if done and done[0] == "1":
        return {"courses": 0, "modules": 0}
    n = 0
    for cid, sem, sem_end, ends in conn.execute("SELECT id, semester, semester_end, semester_ends_at FROM courses WHERE id != '__user__'").fetchall():
        if apply_to_course(conn, cid, sem, sem_end, ends, today) is not None:
            n += 1
    m = deactivate_stale_modules(conn)
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('semester_rule_applied', '1')")
    return {"courses": n, "modules": m}
