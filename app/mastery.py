"""Lernstand je Modul (docs/LERNSTAND-2026-11-04.md): eine Zahl 0-100 aus Wochentests, Karteikarten und Aufgaben des
Lernplans. Keine KI, keine neue Tabelle: `compute` ist eine reine Funktion (dieselben Faelle wie `Mastery` im
Swift-Kern, packages/shared-contracts/fixtures/mastery/cases.json), `for_module` liest die Zahlen aus der Datenbank."""
import math

from . import db

WEIGHT_TESTS, WEIGHT_CARDS, WEIGHT_TASKS = 0.5, 0.3, 0.2


def reason(tests: int, cards: int, tasks_done: int, tasks_total: int) -> str:
    """'3 Wochentests, 42 Karten, 12 von 20 Aufgaben' - nur die vorhandenen Signale."""
    parts = []
    if tests:
        parts.append(f"{tests} Wochentest{'' if tests == 1 else 's'}")
    if cards:
        parts.append(f"{cards} Karte{'' if cards == 1 else 'n'}")
    if tasks_total:
        parts.append(f"{tasks_done} von {tasks_total} Aufgabe{'' if tasks_total == 1 else 'n'}")
    return ", ".join(parts)


def compute(tests: list, cards_right: int, cards_wrong: int, tasks_done: int, tasks_total: int) -> dict | None:
    """tests: Paare (score, max_score) der abgegebenen Wochentests, aelteste zuerst. Ohne Signal None.
    Reihenfolge der Gleitkomma-Operationen bewusst fest (Swift rechnet dieselben Schritte in derselben Reihenfolge)."""
    pcts = []
    for score, max_score in tests:
        try:
            s, m = float(score), float(max_score)
        except (TypeError, ValueError):
            continue
        if m <= 0 or s != s or m != m:                    # kein Hoechstwert oder NaN: zaehlt nicht
            continue
        pcts.append(min(100.0, max(0.0, 100.0 * s / m)))
    cards = int(cards_right) + int(cards_wrong)
    num, den = 0.0, 0.0
    if pcts:
        wsum, psum = 0.0, 0.0
        for i, p in enumerate(pcts, start=1):            # der aelteste wiegt 1, der neueste n
            wsum += float(i)
            psum += float(i) * p
        num += WEIGHT_TESTS * (psum / wsum)
        den += WEIGHT_TESTS
    if cards > 0:
        num += WEIGHT_CARDS * (100.0 * float(cards_right) / float(cards))
        den += WEIGHT_CARDS
    if tasks_total > 0:
        num += WEIGHT_TASKS * (100.0 * float(tasks_done) / float(tasks_total))
        den += WEIGHT_TASKS
    if den == 0.0:
        return None
    score = int(math.floor(num / den + 0.5))             # halbe Prozent aufwaerts, nicht round() (kaufmaennisch)
    score = max(0, min(100, score))
    return {"score": score, "reason": reason(len(pcts), cards, int(tasks_done), int(tasks_total)),
            "tests": len(pcts), "cards": cards, "tasks_done": int(tasks_done), "tasks_total": int(tasks_total)}


def for_module(conn, module_id: int, name: str | None) -> dict | None:
    """Zahlen eines Moduls aus `tests`, `flashcards` und `study_tasks` (nur lesen); Zuordnung ueber module_id, sonst
    ueber das Fach (`subject` = Modulname, so setzen es die Module-Endpunkte an Kursen und Karten)."""
    tests = [(r["score"], r["max_score"]) for r in db.rows(conn, """
        SELECT score, max_score FROM tests
        WHERE (module_id=? OR (module_id IS NULL AND subject=?)) AND submitted_at IS NOT NULL AND score IS NOT NULL
          AND COALESCE(max_score, 0) > 0 AND COALESCE(user_id, 'local')='local'
        ORDER BY submitted_at, id""", (module_id, name))]
    c = db.row(conn, """
        SELECT COALESCE(SUM(fc.last_result='right'), 0) AS r, COALESCE(SUM(fc.last_result='wrong'), 0) AS w
        FROM flashcards fc LEFT JOIN files f ON f.id=fc.file_id LEFT JOIN courses c ON c.id=f.course_id
        WHERE COALESCE(fc.hidden, 0)=0 AND (c.module_id=? OR (c.module_id IS NULL AND fc.subject=?))""", (module_id, name))
    t = db.row(conn, """
        SELECT COUNT(*) AS n, COALESCE(SUM(st.status='erledigt'), 0) AS d
        FROM study_tasks st JOIN study_packages p ON p.id=st.package_id WHERE p.module_id=?""", (module_id,))
    return compute(tests, c["r"] or 0, c["w"] or 0, t["d"] or 0, t["n"] or 0)
