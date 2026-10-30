"""Orchestrierung: Dateien analysieren, Wochenplan erzeugen, Wochentests anlegen."""
from __future__ import annotations

import json
import re
from datetime import date, datetime, timedelta

from . import ai, db
from .extract import extract_text
from .study import monday


def planning_week(d: date | None = None) -> date:
    """Woche, fuer die geplant wird: Mo-Do die laufende Woche, ab Freitag die naechste."""
    d = d or date.today()
    m = monday(d)
    return m + timedelta(days=7) if d.weekday() >= 4 else m


# ----------------------------------------------------------------------------
# Analyse
# ----------------------------------------------------------------------------

def _store_analysis(file_id: str, res: dict, text: str) -> None:
    with db.cursor() as conn:
        conn.execute(
            """INSERT OR REPLACE INTO analysis(file_id, doc_type, title, topics, difficulty, est_minutes, summary,
               prerequisites, raw, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (file_id, res.get("doc_type"), res.get("title"), json.dumps(res.get("topics") or [], ensure_ascii=False),
             int(res.get("difficulty") or 3), int(res.get("est_minutes") or 45), res.get("summary"),
             json.dumps(res.get("prerequisites") or [], ensure_ascii=False), json.dumps(res, ensure_ascii=False),
             db.now_iso()),
        )
        conn.execute("UPDATE files SET text_excerpt=? WHERE id=?", (text[:4000], file_id))


def analyze_pending(limit: int = 80, workers: int = 4, log=print) -> int:
    """Analysiert heruntergeladene Dateien ohne Analyse (neueste zuerst, mehrere parallel). Gibt Anzahl zurueck."""
    from concurrent.futures import ThreadPoolExecutor, as_completed
    from pathlib import Path

    from .config import TEXT_EXTENSIONS

    with db.cursor() as conn:
        pending = db.rows(conn, """
            SELECT f.id, f.name, f.local_path, c.title AS course_title
            FROM files f JOIN courses c ON c.id = f.course_id
            LEFT JOIN analysis a ON a.file_id = f.id
            WHERE a.file_id IS NULL AND f.local_path IS NOT NULL AND c.active = 1
            ORDER BY f.chdate DESC LIMIT ?""", (limit,))

    # Nicht-Text-Dateien (zip, gif, ...) ohne KI einordnen
    todo = []
    for f in pending:
        if Path(f["local_path"]).suffix.lower() not in TEXT_EXTENSIONS:
            _store_analysis(f["id"], {"doc_type": "sonstiges", "title": f["name"], "topics": [], "difficulty": 2,
                                      "est_minutes": 15, "summary": "Keine Textdatei (z. B. Archiv oder Bild), nicht automatisch analysiert.",
                                      "prerequisites": []}, "")
        else:
            todo.append(f)

    def work(f):
        text = extract_text(f["local_path"])
        res = ai.analyze_file(f["course_title"], f["name"], text, pdf_path=f["local_path"])
        _store_analysis(f["id"], res, text)
        return f, res

    done = 0
    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        futures = {ex.submit(work, f): f for f in todo}
        for fut in as_completed(futures):
            f = futures[fut]
            try:
                _, res = fut.result()
            except Exception as e:  # noqa: BLE001
                log(f"Analyse fehlgeschlagen fuer {f['name']}: {e}")
                continue
            done += 1
            log(f"Analysiert: {f['name']} -> {res.get('doc_type')} / Schwierigkeit {res.get('difficulty')}")
    return done


def reanalyze_pdfs(workers: int = 4, limit: int | None = None, log=print) -> dict:
    """Bestehende Analysen von PDFs, die noch aus dem Text-Weg stammen, neu mit PDF-Seiten erstellen.
    Die alte Analyse bleibt, wenn die neue scheitert oder nicht ueber den PDF-Weg entstand."""
    from concurrent.futures import ThreadPoolExecutor, as_completed
    from pathlib import Path

    with db.cursor() as conn:
        rows = db.rows(conn, """
            SELECT f.id, f.name, f.local_path, c.title AS course_title, a.doc_type AS old_type
            FROM analysis a JOIN files f ON f.id = a.file_id JOIN courses c ON c.id = f.course_id
            WHERE lower(f.name) LIKE '%.pdf' AND f.local_path IS NOT NULL
              AND COALESCE(a.raw, '') NOT LIKE '%"_input": "pdf"%'
            ORDER BY f.chdate DESC""")
    rows = [r for r in rows if Path(r["local_path"]).is_file()][:limit]
    stats = {"gesamt": len(rows), "neu": 0, "behalten": 0, "typ_geaendert": 0}

    def work(f):
        text = extract_text(f["local_path"])
        res = ai.analyze_file(f["course_title"], f["name"], text, pdf_path=f["local_path"])
        return f, res, text

    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        futures = [ex.submit(work, f) for f in rows]
        for fut in as_completed(futures):
            try:
                f, res, text = fut.result()
            except Exception as e:  # noqa: BLE001
                stats["behalten"] += 1
                log(f"Neu-Analyse fehlgeschlagen, alte bleibt: {e}")
                continue
            if not (isinstance(res, dict) and res.get("doc_type") and res.get("_input") == "pdf"):
                stats["behalten"] += 1
                log(f"Neu-Analyse ohne PDF-Ergebnis, alte bleibt: {f['name']}")
                continue
            _store_analysis(f["id"], res, text)
            stats["neu"] += 1
            if res.get("doc_type") != f["old_type"]:
                stats["typ_geaendert"] += 1
            log(f"Neu analysiert ({stats['neu']}/{stats['gesamt']}): {f['name']} -> {res.get('doc_type')} (vorher {f['old_type']})")
    return stats


# ----------------------------------------------------------------------------
# Wochenplan
# ----------------------------------------------------------------------------

def _subjects(conn) -> list[dict]:
    return db.rows(conn, """
        SELECT subject, MAX(test_minutes) AS test_minutes
        FROM courses WHERE active = 1 AND kind != 'sonstiges' AND subject IS NOT NULL
        GROUP BY subject ORDER BY subject""")


def _open_materials(conn, per_subject: int = 12) -> list[dict]:
    """Offene Materialien, hoechstens `per_subject` je Fach (neueste und schwerste zuerst)."""
    return db.rows(conn, """
        SELECT * FROM (
            SELECT f.id, f.name, f.chdate, c.subject, c.title AS course_title, c.id AS course_id,
                   a.doc_type, a.title, a.difficulty, a.est_minutes, a.topics,
                   ROW_NUMBER() OVER (PARTITION BY c.subject ORDER BY f.chdate DESC, COALESCE(a.difficulty, 3) DESC) AS rn
            FROM files f JOIN courses c ON c.id = f.course_id
            LEFT JOIN analysis a ON a.file_id = f.id
            WHERE c.active = 1 AND c.kind != 'sonstiges' AND f.status != 'erledigt'
              AND COALESCE(a.doc_type, '') NOT IN ('organisatorisch')
        ) WHERE rn <= ?
        ORDER BY subject, COALESCE(difficulty, 3) DESC, chdate DESC""", (per_subject,))


def _enforce_limits(items: list[dict], settings: dict, week_start: date, log=print) -> list[dict]:
    """Erzwingt freie Tage, vergangene Tage und das Tageslimit. Ueberschuss wandert auf den naechsten freien Platz,
    Tests haben Vorrang. Startzeiten werden pro Tag neu vergeben."""
    free = set(int(d) for d in settings["free_days"])
    budget = int(settings["hours_per_day"] * 60)
    today = date.today()
    allowed = [d for d in range(7) if d not in free and week_start + timedelta(days=d) >= today]
    if not allowed:
        return []
    used = {d: 0 for d in range(7)}
    placed: list[dict] = []
    # Tests zuerst (bevorzugt Ende der Woche), dann der Rest in KI-Reihenfolge
    ordered = sorted(enumerate(items), key=lambda p: (0 if p[1].get("kind") == "test" else 1, p[0]))
    for idx, it in ordered:
        it = {**it, "_i": idx}
        dur = int(it.get("duration_min") or 60)
        day = int(it.get("day", 0)) % 7
        candidates = [day] + [d for d in allowed if d != day]
        if it.get("kind") == "test":
            candidates = [day] + sorted((d for d in allowed if d != day), reverse=True)
        target = next((d for d in candidates if d in allowed and used[d] + dur <= budget), None)
        if target is None:
            log(f"Plan: kein Platz mehr fuer '{it.get('title')}' ({dur} min) - verschoben auf naechste Woche")
            continue
        used[target] += dur
        placed.append({**it, "day": target})
    # Startzeiten pro Tag fortlaufend ab Lernbeginn, Reihenfolge: KI-Reihenfolge, Tests zuletzt
    h, m = (int(x) for x in str(settings.get("day_start") or "09:00").split(":"))
    for d in range(7):
        day_items = [it for it in placed if it["day"] == d]
        day_items.sort(key=lambda it: (1 if it.get("kind") == "test" else 0, it.get("_i", 0)))
        t = h * 60 + m
        for it in day_items:
            it["start_time"] = f"{t // 60:02d}:{t % 60:02d}"
            t += int(it.get("duration_min") or 60) + 15   # 15 min Pause
    return placed


def generate_plan(week_start: date | None = None, keep_manual: bool = True, log=print) -> dict:
    ws = (week_start or planning_week()).isoformat()
    with db.cursor() as conn:
        settings = db.get_settings(conn)
        subjects = _subjects(conn)
        materials = _open_materials(conn)
        prev = (date.fromisoformat(ws) - timedelta(days=7)).isoformat()
        carry = db.rows(conn, "SELECT title, subject FROM plan_items WHERE week_start=? AND done=0 AND kind!='test'", (prev,))
    if not subjects:
        raise RuntimeError("Keine Kurse vorhanden. Bitte zuerst synchronisieren.")

    res = ai.build_week_plan(date.fromisoformat(ws), materials, subjects, settings, carry, today=date.today())
    items = _enforce_limits(res.get("items") or [], settings, date.fromisoformat(ws), log)
    subj_names = {s["subject"] for s in subjects}
    course_by_subject = {}
    with db.cursor() as conn:
        for c in db.rows(conn, "SELECT id, subject, kind FROM courses WHERE active=1"):
            course_by_subject.setdefault(c["subject"], c["id"])
        conn.execute("INSERT INTO plans(week_start, generated_at, notes) VALUES (?,?,?) "
                     "ON CONFLICT(week_start) DO UPDATE SET generated_at=excluded.generated_at, notes=excluded.notes",
                     (ws, db.now_iso(), res.get("notes")))
        if keep_manual:
            conn.execute("DELETE FROM plan_items WHERE week_start=? AND manual=0", (ws,))
        else:
            conn.execute("DELETE FROM plan_items WHERE week_start=?", (ws,))
        order = 0
        for it in items:
            subj = it.get("subject") if it.get("subject") in subj_names else None
            order += 1
            conn.execute(
                """INSERT INTO plan_items(week_start, day, start_time, duration_min, course_id, subject, file_id, title, kind, sort_order)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""",
                (ws, int(it.get("day", 0)) % 7, it.get("start_time") or "09:00", int(it.get("duration_min") or 60),
                 course_by_subject.get(subj), subj, it.get("file_id") or None, it.get("title") or "Lernen",
                 it.get("kind") or "lernen", order),
            )
        # Bereits vorhandene Tests dieser Woche mit den Testbloecken verknuepfen
        conn.execute("""UPDATE plan_items SET test_id = (
                            SELECT t.id FROM tests t WHERE t.week_start = plan_items.week_start AND t.subject = plan_items.subject
                            ORDER BY t.submitted_at IS NOT NULL, t.id LIMIT 1)
                        WHERE week_start=? AND kind='test' AND test_id IS NULL""", (ws,))
    log(f"Wochenplan {ws}: {len(items)} Bloecke")
    return {"week_start": ws, "items": len(items), "notes": res.get("notes")}


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

def _materials_for_test(conn, subject: str, limit: int = 8, module_id: int | None = None, week_no: int | None = None) -> list[dict]:
    """Materialien fuer einen Test: bei Modul + Lehrwoche alle Vorlesungen und Uebungen dieser Woche (ueber alle Kurse
    des Moduls), sonst die neuesten Dateien des Fachs."""
    if module_id and week_no:
        from . import study
        start = study.semester_start(conn)
        files = [f for f in study._file_rows(conn, module_id) if study.file_week(start, f) == week_no
                 and f.get("doc_type") in study.LECTURE_WEEK_TYPES]
        files.sort(key=lambda f: ({"vorlesung": 0, "skript": 1, "uebung": 2, "loesung": 3}.get(f.get("doc_type"), 4), f["chdate"]))
        rows = [{"id": f["id"], "name": f["name"], "title": f.get("ai_title"), "doc_type": f.get("doc_type"), "difficulty": f.get("difficulty"), "text": None} for f in files[:10]]
        for r in rows:
            p = db.row(conn, "SELECT text_excerpt, local_path, content_sha256 FROM files WHERE id=?", (r["id"],))
            r["text"] = (p["text_excerpt"] if p and p["text_excerpt"] else (extract_text(p["local_path"], 3500) if p and p["local_path"] else ""))
            r["local_path"] = (p or {}).get("local_path")
            r["content_sha256"] = (p or {}).get("content_sha256")
        if rows:
            return rows
    rows = db.rows(conn, """
        SELECT f.id, f.name, f.text_excerpt AS text, f.local_path, f.content_sha256, a.title, a.doc_type, a.difficulty
        FROM files f JOIN courses c ON c.id = f.course_id
        LEFT JOIN analysis a ON a.file_id = f.id
        WHERE (c.subject = ? OR c.module_id = ?) AND c.active = 1 AND f.local_path IS NOT NULL
          AND COALESCE(a.doc_type,'') NOT IN ('organisatorisch')
        ORDER BY f.chdate DESC LIMIT ?""", (subject, module_id or -1, limit))
    for r in rows:
        if not r.get("text"):
            p = db.row(conn, "SELECT local_path FROM files WHERE id=?", (r["id"],))
            r["text"] = extract_text(p["local_path"], 3500) if p and p["local_path"] else ""
    return rows


def _exam_for_test(conn, module_id: int | None) -> dict | None:
    """Neueste Altklausur des Moduls (Analyse `klausur`) mit Text, fuer die Klausuraufgabe im Wochentest
    (Entscheidung 29.10.2026); None ohne Modul oder Klausur."""
    if not module_id:
        return None
    from . import study
    exams = [f for f in study._file_rows(conn, module_id) if f.get("doc_type") == "klausur"]
    if not exams:
        return None
    f = exams[-1]                                    # _file_rows ist nach chdate sortiert
    p = db.row(conn, "SELECT text_excerpt, local_path, content_sha256 FROM files WHERE id=?", (f["id"],)) or {}
    text = p.get("text_excerpt") or (extract_text(p["local_path"], 3500) if p.get("local_path") else "")
    return {"id": f["id"], "name": f["name"], "title": f.get("ai_title"), "text": text,
            "local_path": p.get("local_path"), "content_sha256": p.get("content_sha256")}


def create_test(subject: str, duration_min: int | None = None, week_start: date | None = None, log=print,
                module_id: int | None = None, week_no: int | None = None, auto: bool = False) -> int:
    """Erstellt einen Test. auto=True: gemeinsamer Wochentest des Moduls fuer die Lehrwoche (hoechstens einer)."""
    ws = (week_start or planning_week()).isoformat()
    with db.cursor() as conn:
        if module_id is None:
            m = db.row(conn, "SELECT id FROM modules WHERE name=?", (subject,))
            module_id = m["id"] if m else None
        if auto and module_id and week_no:
            ex = db.row(conn, "SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", (module_id, week_no))
            if ex:
                return ex["id"]
        if duration_min is None:
            s = db.get_settings(conn)
            m = db.row(conn, "SELECT test_minutes FROM modules WHERE id=?", (module_id,)) if module_id else None
            duration_min = int((m or {}).get("test_minutes") or s["test_minutes"])
        mats = _materials_for_test(conn, subject, module_id=module_id, week_no=week_no)
        exam = _exam_for_test(conn, module_id)
        # Gemeinsamer Wochentest: gleiche Materialien (Inhalt) + gleiche Dauer -> derselbe Test, ohne neue KI-Anfrage;
        # die Altklausur gehoert mit in den Schluessel (sie praegt eine Aufgabe)
        from . import testshare, universities
        key = testshare.share_key(universities.current_key(), duration_min, mats + ([exam] if exam else [])) if (auto and mats) else None
        shared = testshare.lookup_local(conn, key) if key else None
    if not mats:
        raise RuntimeError(f"Keine Materialien fuer {subject}")
    if shared:
        # Lehrwochen-Nummer gehoert dem jeweiligen Nutzer: aus dem geteilten Titel entfernen, unten neu setzen
        res = {"title": re.sub(r"^Lehrwoche \d+:\s*", "", shared["title"] or ""), "questions": json.loads(shared["questions"] or "[]")}
        log(f"Gemeinsamer Wochentest wiederverwendet ({key[:16]}…)")
    else:
        res = ai.generate_test(subject, duration_min, mats, exam=exam)
    title = res.get("title") or f"Wochentest {subject}"
    if week_no:
        title = f"Lehrwoche {week_no}: " + title.replace(f"Wochentest {subject}", "").strip(" –-:") or title
    with db.cursor() as conn:
        try:
            cur = conn.execute(
                "INSERT INTO tests(subject, week_start, title, duration_min, questions, created_at, module_id, week_no, auto, share_key) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (subject, ws, title, duration_min, json.dumps(res.get("questions") or [], ensure_ascii=False), db.now_iso(), module_id, week_no, 1 if auto else 0, key),
            )
        except Exception:  # noqa: BLE001 - Unique-Index: parallel entstandener Wochentest
            ex = db.row(conn, "SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", (module_id, week_no))
            if ex:
                return ex["id"]
            raise
        test_id = cur.lastrowid
        conn.execute("UPDATE plan_items SET test_id=? WHERE week_start=? AND subject=? AND kind='test' AND test_id IS NULL", (test_id, ws, subject))
        if auto and module_id and week_no:
            conn.execute("""UPDATE study_tasks SET test_id=? WHERE test_id IS NULL AND type='test' AND package_id IN
                            (SELECT id FROM study_packages WHERE module_id=? AND week_no=?)""", (test_id, module_id, week_no))
    log(f"Test erstellt: {subject} ({duration_min} min), id={test_id}")
    return test_id


def create_weekly_tests(week_start: date | None = None, log=print) -> list[int]:
    """Gemeinsamer Wochentest pro aktivem Modul und Lehrwoche, nur wenn die Woche neue Inhalte hat und noch kein Test existiert."""
    from . import study
    ids = []
    with db.cursor() as conn:
        start = study.semester_start(conn)
        s = db.get_settings(conn)
        todo = []
        for m in db.rows(conn, "SELECT * FROM modules WHERE active=1 AND weekly_test=1"):
            # Module mit Vorlesungs-Seitenmarkern laufen ueber app/weekly.py (Stoff nur bis zum Marker)
            if db.row(conn, "SELECT 1 FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", (m["id"],)):
                continue
            weeks = sorted({w for f in study._file_rows(conn, m["id"]) if f.get("doc_type") in ("vorlesung", "uebung") and (w := study.file_week(start, f)) >= 1})
            for w in weeks[-2:]:  # die beiden juengsten Lehrwochen mit Inhalten
                if db.row(conn, "SELECT 1 FROM tests WHERE module_id=? AND week_no=? AND auto=1", (m["id"], w)):
                    continue
                if db.row(conn, "SELECT 1 FROM dismissed_tests WHERE module_id=? AND week_no=?", (m["id"], w)):
                    continue   # vom Nutzer geloescht
                todo.append((m, w))
    for m, w in todo:
        try:
            ids.append(create_test(m["name"], m.get("test_minutes") or s["test_minutes"], log=log, module_id=m["id"], week_no=w, auto=True))
        except Exception as e:  # noqa: BLE001
            log(f"Wochentest {m['name']} Woche {w} nicht erstellt: {e}")
    return ids


def grade(test_id: int, answers: dict) -> dict:
    with db.cursor() as conn:
        t = db.row(conn, "SELECT * FROM tests WHERE id=?", (test_id,))
    if not t:
        raise RuntimeError("Test nicht gefunden")
    if t["submitted_at"] and t.get("def_id"):
        raise RuntimeError("Dieser gemeinsame Test wurde bereits abgegeben und wird nicht neu bewertet.")
    questions = json.loads(t["questions"])
    res = ai.grade_test(t["subject"], questions, answers)
    duration = None
    if t.get("def_id"):
        # Gemeinsamer Wochentest: Multiple Choice ohne KI, Punkte begrenzt -> gleiche Kriterien fuer alle
        from . import weekly
        res = weekly.grade_consistent(questions, answers, res)
    if t.get("started_at"):
        try:
            duration = int((datetime.now() - datetime.fromisoformat(t["started_at"])).total_seconds())
        except ValueError:
            duration = None
    with db.cursor() as conn:
        conn.execute("UPDATE tests SET submitted_at=?, answers=?, score=?, max_score=?, feedback=?, duration_sec=? WHERE id=?",
                     (db.now_iso(), json.dumps(answers, ensure_ascii=False), float(res.get("total") or 0),
                      float(res.get("max") or sum(q.get("points", 0) for q in questions)),
                      json.dumps(res, ensure_ascii=False), duration, test_id))
        conn.execute("UPDATE plan_items SET done=1 WHERE test_id=?", (test_id,))
    return res
