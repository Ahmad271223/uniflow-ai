"""Doppelt geplante Lernpakete zusammenfuehren (Fehler vom echten iPhone vom 14.11.2026, docs/PLANER-KEINE-DOPPELPLANUNG.md).

Ursache: Jedes Geraet plant selbst (erste Planung nach der Einrichtung, neue Dokumente nach dem eigenen Abgleich mit
der Hochschule), bevor der Geraete-Abgleich die Planung des anderen Geraets gebracht hat. Der Abgleich erkennt ein
Paket nur dann als dasselbe, wenn Tag, Fach und Titel gleich sind; liegt dieselbe Unterlage auf dem anderen Geraet an
einem anderen Tag, stehen danach beide Planungen nebeneinander (dieselbe Datei zweimal, vier Pakete an einem Tag).

Regel (auf jedem Geraet und im Dienst dieselbe, Swift: `StudyPlanMerge`):
- Der Schluessel einer automatischen Aufgabe ist ihre Unterlage: Datei + Ausschnitt (Seiten, "Teil k/n"). Er ist auf
  jedem Geraet gleich (Datei-IDs kommen von der Hochschule) und braucht keine neue Spalte. Wochentest und
  Wiederholung: Fach + Lehrwoche + Art.
- Stehen zwei Aufgaben fuer dieselbe Unterlage im Plan, bleibt genau eine:
  1. eine angefasste immer (erledigt, begonnen, verschoben, von Hand angelegt, gesperrt, mit Lernzeit, mit Verlauf),
  2. sonst die, die schon im Konto steht (das Geraet uebernimmt die Planung des Kontos statt seiner eigenen),
  3. sonst die frueher geplante (`created_at` des Pakets, unveraenderlich und abgeglichen),
  4. sonst die mit der kleineren Nummer im Dienst.
  Die Reihenfolge haengt nur an abgeglichenen, unveraenderlichen Werten: zwei Geraete, die dieselben zwei Zeilen
  sehen, entfernen dieselbe. Darum kein Hin und Her mit Loeschmarken.
- Entfernt wird nur eine unberuehrte automatische Aufgabe, und nur, wenn eine andere Aufgabe dieselbe Unterlage
  abdeckt. Ein Paket verschwindet erst, wenn es dadurch leer ist. Nichts von Hand Angelegtes, Geaendertes, Begonnenes
  oder Erledigtes wird je entfernt.
"""
from __future__ import annotations

import re
from datetime import date, timedelta

from . import db

COVER = ("geplant", "in_bearbeitung", "erledigt", "nachholen")      # wie study._planned_files: steht im Plan
OPEN = ("geplant", "nachholen")                                     # unberuehrt (nachholen setzt die Uhr, nicht der Mensch)
SINGLE = ("test", "wiederholung")                                   # je Fach und Lehrwoche genau einmal
PART_RE = re.compile(r"\(Teil ([0-9]+)/([0-9]+)\)$")
PAGES_RE = re.compile(r"· S\. ([0-9]+)(?:–([0-9]+))?$")
FAR = "9999"                                                        # ohne Anlagezeit: zuletzt
BALANCE_DAYS = 28                                                   # so viele Tage ab morgen prueft `balance_days`
APPLIED_DEVICE = "~dienst"                                          # aus dem Konto uebernommen, hier nicht geaendert


def slot(t: dict) -> tuple:
    """Ausschnitt der Unterlage: (von, bis, aus der Gliederung?, Teil k, von n). Ohne Seiten: von = 0; ohne Teile: n = 0."""
    title = (t.get("title") or "").strip()
    k = n = 0
    m = PART_RE.search(title)
    if m:
        k, n = int(m.group(1)), int(m.group(2))
        title = title[:m.start()].strip()
    if t.get("page_from") is not None:
        a = int(t["page_from"])
        return (a, int(t["page_to"]) if t.get("page_to") is not None else a, 1, k, n)
    m = PAGES_RE.search(title)
    if m:
        a = int(m.group(1))
        return (a, int(m.group(2)) if m.group(2) else a, 0, k, n)
    return (0, 0, 0, k, n)


def same_material(x: tuple, y: tuple) -> bool:
    """Decken zwei Ausschnitte derselben Datei in derselben Lehrwoche dasselbe ab? Gleiche Seiten bzw. gleicher Teil;
    die ganze Datei gegen Abschnitte aus der Gliederung (aeltere App ohne Gliederung neben der neuen); verschieden
    geteilt ("Teil 1/2" gegen "Teil 1/3"). Verschiedene Seiten und verschiedene Teile derselben Teilung nicht."""
    ranged_x, ranged_y = x[0] > 0, y[0] > 0
    if ranged_x and ranged_y:
        if x[:2] != y[:2]:
            return False
    elif ranged_x != ranged_y:
        return bool((x if ranged_x else y)[2])
    (kx, nx), (ky, ny) = x[3:], y[3:]
    return not (nx and nx == ny and kx != ky)


def same_planned(a: tuple, b: tuple) -> bool:
    """(Lehrwoche, Ausschnitt) zweier Aufgaben zur selben Datei: in derselben Lehrwoche `same_material`, sonst nur genau
    derselbe Ausschnitt (die Lehrwoche einer Datei kann je Geraet anders zaehlen; der Skriptrest einer spaeteren Woche
    hat andere Seiten und bleibt)"""
    if a[0] == b[0]:
        return same_material(a[1], b[1])
    return a[1][:2] == b[1][:2] and a[1][3:] == b[1][3:]


def _tables(conn) -> set[str]:
    return {r["name"] for r in db.rows(conn, "SELECT name FROM sqlite_master WHERE type='table'")}


def _remote_ids(conn, tables: set[str], entity: str, hosted: bool) -> dict[int, int] | None:
    """Nummer der Zeile im Dienst (kleinste, falls mehrere Zeilen des Dienstes hier eine sind). None: diese Datenbank
    ist der Dienst selbst (jede Zeile steht im Konto, ihre ID ist die Nummer)."""
    if hosted:
        return None
    out: dict[int, int] = {}
    if "sync_link_map" in tables:
        for r in db.rows(conn, "SELECT local_id, remote_id FROM sync_link_map WHERE entity=?", (entity,)):
            try:
                lid, rid = int(r["local_id"]), int(r["remote_id"])
            except (TypeError, ValueError):
                continue
            out[lid] = min(rid, out.get(lid, rid))
    return out


def _order(remote: dict[int, int] | None, row_id: int, planned_at) -> tuple:
    """Reihenfolge unter unberuehrten Zeilen: im Konto vor nur hier, frueher geplant, kleinere Nummer im Dienst"""
    in_account = remote is None or row_id in remote
    return (0 if in_account else 1, planned_at or FAR, row_id if remote is None else remote.get(row_id, row_id), row_id)


def _untouched(conn) -> set[int]:
    from . import study
    return {r["id"] for r in db.rows(conn, f"SELECT p.id FROM study_packages p WHERE {study.UNTOUCHED_AUTO_SQL} "
                                           "AND p.status IN ('geplant','nachholen')")}


def merge_duplicates(conn, hosted: bool | None = None) -> dict:
    """Fuehrt doppelt geplante Unterlagen zusammen (Regel oben). Liefert {"tasks": entfernte Aufgaben, "packages":
    entfernte Pakete, "empty": leere automatische Pakete, die keine Uhrzeit mehr belegen}. Ohne Doppel und ohne leere
    Pakete aendert der Aufruf nichts."""
    from . import config, study
    hosted = config.is_hosted() if hosted is None else hosted
    tables = _tables(conn)
    untouched = _untouched(conn)
    out = {"tasks": 0, "packages": 0, "empty": 0}
    # Paket ohne jede Aufgabe (seine Aufgaben stehen in der Planung des anderen Geraets): wie nach dem Verschieben der
    # letzten Aufgabe (`study._recalc_package`) belegt es keine Uhrzeit mehr. Nicht loeschen: kaemen seine Aufgaben
    # noch, stellt refresh_statuses den Status wieder her.
    for p in db.rows(conn, """SELECT p.id FROM study_packages p WHERE COALESCE(p.source,'')<>'smart'
                              AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id) ORDER BY p.id"""):
        if p["id"] in untouched:
            study._recalc_package(conn, p["id"])
            out["empty"] += 1
    cols = {r["name"] for r in db.rows(conn, "PRAGMA table_info(study_tasks)")}
    extra = "".join(f", t.{c}" for c in ("page_from", "page_to", "steps_done", "test_id") if c in cols)
    marks = ",".join("?" * len(COVER))
    tasks = db.rows(conn, f"""SELECT t.id, t.package_id, t.type, t.file_id, t.title, t.status, t.moved_from, t.done_at, t.actual_minutes{extra},
                                     p.module_id, p.week_no, p.created_at AS planned_at
                              FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
                              WHERE t.status IN ({marks}) ORDER BY t.id""", COVER)
    groups: dict[tuple, list[dict]] = {}
    for t in tasks:
        if t["file_id"]:
            key = ("f", t["file_id"])
        elif t["type"] in SINGLE and t["module_id"] is not None and t["week_no"] is not None:
            key = ("t", t["module_id"], t["week_no"], t["type"])
        else:
            continue                                            # freie Aufgaben ohne Datei: nie
        groups.setdefault(key, []).append(t)
    groups = {k: g for k, g in groups.items() if len(g) > 1}
    if not groups:
        return out
    history = {r["task_id"] for r in db.rows(conn, "SELECT DISTINCT task_id FROM task_history")} if "task_history" in tables else set()
    remote = _remote_ids(conn, tables, "study_tasks", hosted)

    def removable(t: dict) -> bool:
        return (t["package_id"] in untouched and t["status"] in OPEN and t["moved_from"] is None and t["done_at"] is None
                and t["actual_minutes"] is None and t.get("steps_done") in (None, "", "[]") and t.get("test_id") is None
                and t["id"] not in history)

    def rank(t: dict) -> tuple:
        return (1 if removable(t) else 0, *_order(remote, t["id"], t["planned_at"]))

    drop: list[dict] = []
    for key, group in groups.items():
        kept: list[tuple] = []
        for t in sorted(group, key=rank):
            s = (t["week_no"], slot(t) if key[0] == "f" else (0, 0, 0, 0, 0))
            if removable(t) and any(same_planned(s, other) for other in kept):
                drop.append(t)
            else:
                kept.append(s)
    if not drop:
        return out
    for t in drop:
        conn.execute("DELETE FROM study_tasks WHERE id=?", (t["id"],))
    for pid in sorted({t["package_id"] for t in drop}):
        if not db.row(conn, "SELECT 1 FROM study_tasks WHERE package_id=?", (pid,)):
            conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))
            out["packages"] += 1
            continue
        p = db.row(conn, "SELECT source, start_time, end_time FROM study_packages WHERE id=?", (pid,))
        if p["source"] == "smart":                              # Block des Stundenplaners: Dauer = Stundenbudget
            continue
        study._recalc_package(conn, pid)
        # der Block reicht nur noch ueber die Aufgaben, die geblieben sind (nie laenger als vorher)
        span = db.row(conn, """SELECT MIN(start_time) a, MAX(end_time) b FROM study_tasks WHERE package_id=? AND start_time IS NOT NULL
                               AND end_time IS NOT NULL AND status NOT IN ('erledigt','uebersprungen','verschoben')""", (pid,))
        if p["start_time"] and p["end_time"] and span["a"] and span["b"]:
            a, b = max(span["a"], p["start_time"]), min(span["b"], p["end_time"])
            if a < b and (a, b) != (p["start_time"], p["end_time"]):
                conn.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", (a, b, pid))
    out["tasks"] = len(drop)
    return out


# ---------------------------------------------------------------- Tageslimit ueber alle Geraete

def balance_days(conn, today: date | None = None) -> int:
    """Tageslimit ueber alle Geraete: Jedes Geraet prueft beim Einordnen nur die Pakete, die es kennt. Liegen an einem
    kuenftigen Tag danach Pakete aus dem Konto neben eigenen und ist der Tag damit ueber dem Limit (Lernzeit je Tag
    schon aufgebraucht, mehr Faecher als eingestellt) oder liegen zwei Bloecke uebereinander, weicht das zuletzt
    geplante unberuehrte automatische Paket: anderes freies Fenster bzw. der naechste Lerntag mit Platz. Welches
    weicht, bestimmt dieselbe Reihenfolge wie beim Zusammenfuehren, also auf jedem Geraet dasselbe. Von Hand
    Angelegtes, Begonnenes, Gesperrtes und Bloecke des Stundenplaners bleiben immer liegen. Heute bleibt, wie es ist.
    Nur auf einem Geraet mit Geraete-Abgleich (im Dienst liegt nichts "aus dem Konto neben eigenem"). Liefert die Zahl
    verlegter Pakete."""
    from . import study, timetable
    tables = _tables(conn)
    if "sync_link_map" not in tables:
        return 0
    t0 = today or study.today()
    first, last = t0 + timedelta(days=1), t0 + timedelta(days=BALANCE_DAYS)
    days = [r["date"] for r in db.rows(conn, f"""SELECT DISTINCT p.date FROM study_packages p WHERE p.date BETWEEN ? AND ?
                                                 AND p.sync_device=? AND p.status='geplant' AND COALESCE(p.source,'')<>'smart'
                                                 AND {study.UNTOUCHED_AUTO_SQL}
                                                 AND EXISTS (SELECT 1 FROM study_packages o WHERE o.date=p.date AND o.id<>p.id
                                                             AND COALESCE(o.sync_device,'')<>? AND o.status NOT IN ('verschoben','uebersprungen'))
                                                 ORDER BY p.date""", (first.isoformat(), last.isoformat(), APPLIED_DEVICE, APPLIED_DEVICE))]
    if not days:
        return 0
    s = db.get_settings(conn)
    budget, subjects_max = int(s["minutes_per_day"]), max(1, int(s["subjects_per_day"]))
    remote = _remote_ids(conn, tables, "study_packages", False)
    moved = 0

    def load(day: str) -> list[dict]:
        return db.rows(conn, "SELECT * FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen') ORDER BY id", (day,))

    def subject(p: dict) -> str:
        return f"m{p['module_id']}" if p["module_id"] is not None else "s" + (p["subject"] or "").strip().lower()

    def unslot(pid: int) -> None:
        conn.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", (pid,))
        conn.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben')", (pid,))

    def fits(day: date, p: dict) -> bool:
        if day.weekday() not in s["learn_days"] or not timetable.free_windows(conn, day):
            return False
        there = load(day.isoformat())
        subs = {subject(x) for x in there}
        return (sum(int(x["planned_minutes"] or 0) for x in there) + int(p["planned_minutes"] or 0) <= budget
                and (subject(p) in subs or len(subs) < subjects_max))

    for day in days:
        d = date.fromisoformat(day)
        movable = _untouched(conn)
        pkgs = load(day)
        can_move = [p for p in pkgs if p["id"] in movable and p["status"] == "geplant" and (p["source"] or "") != "smart"]
        ids = {p["id"] for p in can_move}
        stay = [p for p in pkgs if p["id"] not in ids]
        used = sum(int(p["planned_minutes"] or 0) for p in stay)
        subs = {subject(p) for p in stay}
        spans = [(p["start_time"], p["end_time"]) for p in stay if p["start_time"] and p["end_time"]]
        for p in sorted(can_move, key=lambda p: _order(remote, p["id"], p["created_at"])):
            if used < budget and (subject(p) in subs or len(subs) < subjects_max):
                if p["start_time"] and p["end_time"] and any(p["start_time"] < b and p["end_time"] > a for a, b in spans):
                    unslot(p["id"])                             # zwei Bloecke uebereinander: neues freies Fenster
                    study.assign_slots(conn, d, package_id=p["id"], spill=study.SPILL_DAYS)
                    moved += 1
                    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (p["id"],))
                    if not p or p["date"] != day:
                        continue                                # kein Platz mehr an diesem Tag: liegt jetzt spaeter
                used += int(p["planned_minutes"] or 0)
                subs.add(subject(p))
                if p["start_time"] and p["end_time"]:
                    spans.append((p["start_time"], p["end_time"]))
                continue
            target, n, e = None, 0, d
            while n < study.SPILL_DAYS and target is None and (e - d).days < 60:
                e += timedelta(days=1)
                if e.weekday() not in s["learn_days"]:
                    continue
                n += 1
                if fits(e, p):
                    target = e
            if target is None:
                continue                                        # nirgends Platz: bleibt, wo es ist
            unslot(p["id"])
            conn.execute("UPDATE study_packages SET date=? WHERE id=?", (target.isoformat(), p["id"]))
            study.assign_slots(conn, target, package_id=p["id"], spill=study.SPILL_DAYS)
            moved += 1
    return moved


def after_pull(conn, hosted: bool | None = None, today: date | None = None) -> dict:
    """Nach dem Abruf vom Konto und vor dem Senden: zusammenfuehren, dann das Tageslimit pruefen"""
    out = merge_duplicates(conn, hosted)
    out["moved"] = balance_days(conn, today)
    return out
