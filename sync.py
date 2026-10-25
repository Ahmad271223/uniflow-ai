"""Einstieg fuer den automatischen Lauf (8:00 und 15:00 Uhr):

  python sync.py             -> Uni synchronisieren (LUH: Stud.IP, Hildesheim: Learnweb + LSF), neue Dateien analysieren, Plan/Tests aktualisieren
  python sync.py --show      -> Browser sichtbar (zum Pruefen des Logins)
  python sync.py --no-ai     -> nur synchronisieren
  python sync.py --plan      -> Wochenplan neu erzeugen (auch ohne neue Dateien)
  python sync.py --tests     -> fehlende Wochentests erzeugen
"""
from __future__ import annotations

import sys
from datetime import date

from app import db, planner
from app.studip_sync import log, run_sync


def main(argv: list[str]) -> int:
    db.init_db()
    only_sync = "--no-ai" in argv
    force_plan = "--plan" in argv
    force_tests = "--tests" in argv

    res = run_sync(show_browser="--show" in argv)
    log(f"Sync: {res['message']}")
    if only_sync:
        return 0 if res["ok"] else 1

    with db.cursor() as conn:
        settings = db.get_settings(conn)
        plan_exists = db.row(conn, "SELECT 1 FROM plans WHERE week_start=?", (planner.planning_week().isoformat(),)) is not None

    analyzed = 0
    try:
        analyzed = planner.analyze_pending(log=log)
    except Exception as e:  # noqa: BLE001
        log(f"Analyse-Fehler: {e}")

    try:
        if settings["auto_plan"] and (force_plan or res["new_files"] or not plan_exists):
            planner.generate_plan(log=log)
    except Exception as e:  # noqa: BLE001
        log(f"Plan-Fehler: {e}")

    # Lernkalender: fehlende Tage der naechsten 7 Tage mit Lernpaketen fuellen (bestehende bleiben unangetastet)
    try:
        if settings["auto_plan"]:
            from app import study
            with db.cursor() as conn:
                r = study.generate_packages(conn, days=7, log=log)
            log(f"Lernkalender: {r['message']}")
    except Exception as e:  # noqa: BLE001
        log(f"Lernkalender-Fehler: {e}")

    # Skriptsuche: Seitentexte neuer Vorlesungs-/Skript-PDFs vorab lesen
    try:
        from app import scriptsearch
        with db.cursor() as conn:
            scriptsearch.index_all(conn, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"Skriptsuche-Index-Fehler: {e}")

    # Notenspiegel (LUH: QIS mit Bescheinigungen, Hildesheim: LSF) nur mit eigenem Zugang, hoechstens einmal pro 20 Stunden
    try:
        from app import qis
        if qis.configured():
            from datetime import datetime, timedelta
            with db.cursor() as conn:
                last = db.row(conn, "SELECT finished_at FROM qis_runs WHERE ok=1 ORDER BY id DESC LIMIT 1")
            if "--qis" in argv or not last or datetime.fromisoformat(last["finished_at"]) < datetime.now() - timedelta(hours=20):
                log(f"QIS: {qis.run()['message']}")
    except Exception as e:  # noqa: BLE001
        log(f"QIS-Fehler: {e}")

    try:
        if settings["auto_tests"] and (force_tests or date.today().weekday() in (0, 1) or not plan_exists or res["new_files"]):
            planner.create_weekly_tests(log=log)
    except Exception as e:  # noqa: BLE001
        log(f"Test-Fehler: {e}")

    log(f"Fertig. Neue Dateien: {len(res['new_files'])}, analysiert: {analyzed}")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
