"""Module, Semesterwochen, Lernpakete und der interaktive Lernkalender.

Begriffe:
  Modul        = Fach (z. B. "Mathematik I"), fasst mehrere Stud.IP-Kurse (Vorlesung, Uebung, ...) zusammen
  Woche        = Semesterwoche, abgeleitet aus dem Upload-Datum der Dateien
  Lernpaket    = ein Modul an einem Tag mit mehreren Aufgaben (Vorlesung, Uebung, Test)
  Aufgabe      = eine Datei oder ein Test mit eigenem Status
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from datetime import date, datetime, timedelta

from . import db

PALETTE = ["#4f6df5", "#0ea5a0", "#e0803a", "#9b59d9", "#d94f6b", "#2f9e5a", "#c7891a", "#3b82c4", "#7c5cd6", "#1aa39a"]
DEFAULT_EST = {"vorlesung": 45, "skript": 60, "uebung": 60, "loesung": 30, "test": 45, "wiederholung": 30}
OPEN = ("geplant", "in_bearbeitung", "nachholen")


def today() -> date:
    return date.today()


def monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


# ----------------------------------------------------------------------------
# Module
# ----------------------------------------------------------------------------

def ensure_modules(conn) -> None:
    """Legt fuer jedes Fach (subject) ein Modul an und ordnet Kurse zu, die noch kein Modul haben."""
    existing = {r["name"]: r["id"] for r in db.rows(conn, "SELECT id, name FROM modules")}
    courses = db.rows(conn, "SELECT id, subject, kind, semester FROM courses WHERE module_id IS NULL")
    n = len(existing)
    for c in courses:
        if c["kind"] == "sonstiges" or not c["subject"]:
            continue
        name = c["subject"]
        if name not in existing:
            cur = conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                               (name, c["semester"], PALETTE[n % len(PALETTE)], n, db.now_iso()))
            existing[name] = cur.lastrowid
            n += 1
        conn.execute("UPDATE courses SET module_id=? WHERE id=?", (existing[name], c["id"]))


# ----------------------------------------------------------------------------
# Semesterwochen
# ----------------------------------------------------------------------------

def semester_cut(t: date) -> date:
    """Stichtag des laufenden Semesters: der letzte 1.10. (Wintersemester) bzw. 1.3. (Sommersemester), der nicht nach
    t liegt. Frueher lag er im Januar/Februar (1.3.) und im September (1.10.) in der Zukunft: Dann galten alle Dateien
    als "Aeltere Unterlagen" und der Semesterbeginn war die laufende Woche."""
    if t.month >= 10:
        return date(t.year, 10, 1)
    if t.month >= 3:
        return date(t.year, 3, 1)
    return date(t.year - 1, 10, 1)


def semester_start(conn) -> date:
    """Montag der ersten Woche, in der >= 5 Kurse Dateien hochgeladen haben (sonst >= 3, sonst erste)."""
    t = today()
    cut = semester_cut(t)
    rows = db.rows(conn, "SELECT course_id, chdate FROM files WHERE chdate >= ?", (int(datetime(cut.year, cut.month, cut.day).timestamp()),))
    per = defaultdict(set)
    for r in rows:
        per[monday(datetime.fromtimestamp(r["chdate"]).date())].add(r["course_id"])
    mondays = sorted(per)
    for mn in (5, 3, 1):
        for m in mondays:
            if len(per[m]) >= mn:
                return m
    return monday(t)


def day_week(start: date, d: date) -> int:
    """Semesterwoche eines Tages: -1 vor dem Stichtag (aelteres Semester), 0 nach dem Stichtag, aber vor dem
    Vorlesungsbeginn, sonst ab 1. Gilt fuer Dateien (week_index) und Termine (timetable.materials_for_event), damit
    eine Datei und ein Termin am selben Tag immer in derselben Woche liegen."""
    if d < semester_cut(today()):
        return -1  # aelteres Semester
    # nach dem Stichtag, aber vor dem Vorlesungsbeginn: Woche 0 ("Vor Vorlesungsbeginn"); ohne max() wurden daraus
    # -1 und -2, also "Aeltere Unterlagen" bzw. "Klausuren & Altklausuren"
    return max(0, (monday(d) - start).days // 7 + 1)


def week_index(start: date, chdate: int | None) -> int:
    if not chdate:
        return 0
    return day_week(start, datetime.fromtimestamp(chdate).date())


def week_label(start: date, w: int) -> str:
    if w == -2:
        return "Klausuren & Altklausuren"
    if w == -1:
        return "Ältere Unterlagen"
    if w < 1:
        return "Vor Vorlesungsbeginn"
    s = start + timedelta(days=7 * (w - 1))
    return f"Woche {w} · {s.strftime('%d.%m.')} – {(s + timedelta(days=6)).strftime('%d.%m.')}"



# ----------------------------------------------------------------------------
# Dokumenttyp aus Stud.IP-Ordner + Dateiname (schlaegt die KI-Einschaetzung, wenn eindeutig)
# ----------------------------------------------------------------------------

def effective_type(name: str, folder: str | None, ai_type: str | None) -> tuple[str, str]:
    """Liefert (doc_type, label). label z. B. 'Gruppenuebung', 'Hoersaaluebung', 'Altklausur'."""
    fl = f"{folder or ''} / {name or ''}".lower()
    nm = (name or "").lower()
    if re.search(r"klausurergebnis|raumverteilung|organisat|termine|ankuendigung|ankündigung", fl):
        return "organisatorisch", "Organisatorisches"
    if re.search(r"l(ö|oe)s|\blsg\b|_lsg|lsg\.|solution|musterl", nm):
        return "loesung", "Klausur-Lösung" if re.search(r"klausur|kurztest|\bkk\d|\bgk\d?", fl) else "Lösung"
    if re.search(r"alte klausur|altklausur|probeklausur|klausur|kurztest|\bkk\d|\bgk\d?\b|exam", fl):
        return "klausur", "Altklausur" if re.search(r"alte klausur|altklausur|\bws ?\d|\bss ?\d", fl) else "Klausur"
    if re.search(r"gruppen(ü|ue)bung|\bg(ü|ue|u)\d", fl):
        return "uebung", "Gruppenübung"
    if re.search(r"h(ö|oe)rsaal|zentral(ü|ue)bung|\bz(ü|ue)\d|\bh(ü|ue)\d|\bhu\d", fl):
        return "uebung", "Hörsaalübung"
    if re.search(r"tutorium|\btut\d", fl):
        return "uebung", "Tutorium"
    if re.search(r"(ü|ue)bung|blatt|\bueb\d|\bub\d|exercise|aufgaben|sheet", fl):
        return "uebung", "Übung"
    if re.search(r"mitschrift", fl) and not re.search(r"vorlesung|folien", fl):
        return "skript", "Mitschrift"
    if re.search(r"skript|script", fl):
        return "skript", "Skript"
    if re.search(r"vorlesung|folien|slides|\bvl\d|lecture", fl):
        return "vorlesung", "Vorlesung"
    lab = {"vorlesung": "Vorlesung", "uebung": "Übung", "loesung": "Lösung", "skript": "Skript", "klausur": "Klausur", "organisatorisch": "Organisatorisches"}
    t = ai_type or "sonstiges"
    return t, lab.get(t, "Sonstiges")


def week_hint(name: str, folder: str | None) -> int | None:
    """Wochennummer aus Dateiname/Ordner: 'Blatt 3', 'ueb2', 'GU01', '02A', 'VL03', 'Woche 4'. None, wenn unklar."""
    stem = re.sub(r"\.[a-z0-9]+$", "", (name or "").lower())
    for src in (stem, (folder or "").lower().split("/")[-1]):
        m = re.search(r"(?:woche|kw|blatt|(?:ü|ue|u)bung|ueb|aufgabenblatt|serie|vl|vorlesung|folien|kapitel|kap|gu|g(?:ü|ue)|z(?:ü|ue)|h(?:ü|ue)|hu|tut)[ _\-]*0?(\d{1,2})(?!\d)", src)
        if m and 1 <= int(m.group(1)) <= 16:
            return int(m.group(1))
    m = re.match(r"^0?(\d{1,2})[a-z]?$", stem)        # '02A', '01B'
    if m and 1 <= int(m.group(1)) <= 16:
        return int(m.group(1))
    m = re.search(r"(?<!\d)0(\d)(?!\d)", stem)       # fuehrende Null: 'Prog1-01-Intro' -> 1
    if m and 1 <= int(m.group(1)) <= 9:
        return int(m.group(1))
    return None


def enrich_file(f: dict) -> dict:
    t, lab = effective_type(f.get("name"), f.get("studip_folder"), f.get("doc_type"))
    f["ai_doc_type"] = f.get("doc_type"); f["doc_type"] = t; f["sub_label"] = lab
    f["week_hint"] = week_hint(f.get("name"), f.get("studip_folder")) if t in ("vorlesung", "uebung", "loesung", "skript") else None
    return f


def _file_rows(conn, module_id: int | None = None) -> list[dict]:
    sql = """SELECT f.id, f.name, f.chdate, f.status, f.favorite, f.last_opened, f.size, f.course_id, f.studip_folder,
                    c.title AS course_title, c.kind AS course_kind, c.subject, c.module_id,
                    a.doc_type, a.title AS ai_title, a.difficulty, a.est_minutes, a.topics, a.summary,
                    (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes
             FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
             WHERE c.active=1"""
    params: list = []
    if module_id is not None:
        sql += " AND c.module_id=?"
        params.append(module_id)
    return [enrich_file(r) for r in db.rows(conn, sql + " ORDER BY f.chdate", params)]


def week_topic(files: list[dict]) -> str:
    """Thema der Woche: erstes Analyse-Thema einer Vorlesung, sonst des ersten Dokuments."""
    for pref in ("vorlesung", "uebung", "skript"):
        for f in files:
            if f.get("doc_type") == pref and f.get("topics"):
                try:
                    t = json.loads(f["topics"])
                    if t:
                        return str(t[0])
                except json.JSONDecodeError:
                    pass
    for f in files:
        if f.get("ai_title"):
            return f["ai_title"]
    return ""


def module_detail(conn, module_id: int) -> dict:
    m = db.row(conn, "SELECT * FROM modules WHERE id=?", (module_id,))
    if not m:
        return {}
    start = semester_start(conn)
    files = _file_rows(conn, module_id)
    weeks: dict[int, list] = defaultdict(list)
    for f in files:
        if f["doc_type"] == "klausur" or f.get("sub_label") == "Klausur-Lösung":
            w = -2                                   # Klausuren & Altklausuren: eigener Block, keine Lehrwoche
        elif f.get("week_hint") and week_index(start, f["chdate"]) >= 0:
            w = f["week_hint"]                       # Blatt 3 / VL03 -> Lehrwoche 3
        else:
            w = week_index(start, f["chdate"])
        weeks[w].append(f)
    order = sorted(weeks, key=lambda w: (w == -2, w == -1, w))
    out_weeks = []
    for w in order:
        fl = weeks[w]
        grp = {"vorlesungen": [], "uebungen": [], "loesungen": [], "skripte": [], "klausuren": [], "sonstiges": []}
        for f in fl:
            dt = f.get("doc_type")
            key = {"vorlesung": "vorlesungen", "uebung": "uebungen", "loesung": "loesungen", "skript": "skripte", "klausur": "klausuren"}.get(dt, "sonstiges")
            grp[key].append(f)
        for k in grp:
            grp[k].sort(key=lambda x: (x.get("sub_label") or "", x.get("name") or ""))
        out_weeks.append({"week": w, "label": week_label(start, w), "topic": week_topic(fl), "count": len(fl), **grp})
    courses = db.rows(conn, "SELECT id, title, kind, number FROM courses WHERE module_id=? ORDER BY kind, title", (module_id,))
    tasks = db.rows(conn, """SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
                             WHERE p.module_id=? ORDER BY p.date""", (module_id,))
    done_files = {t["file_id"] for t in tasks if t["status"] == "erledigt" and t["file_id"]} | {f["id"] for f in files if f["status"] == "erledigt"}
    learnable = [f for f in files if f.get("doc_type") in ("vorlesung", "uebung", "skript")]
    progress = round(100 * len([f for f in learnable if f["id"] in done_files]) / len(learnable)) if learnable else 0
    next_pkg = db.row(conn, "SELECT date, title FROM study_packages WHERE module_id=? AND date>=? AND status IN ('geplant','in_bearbeitung') ORDER BY date LIMIT 1", (module_id, today().isoformat()))
    return {"module": dict(m), "courses": courses, "weeks": out_weeks, "files": files, "progress": progress,
            "new_count": len([f for f in files if f["status"] == "neu"]), "open_tasks": len([t for t in tasks if t["status"] in OPEN]),
            "next_package": next_pkg, "notes": [f for f in files if f["has_notes"]]}


def modules_overview(conn) -> list[dict]:
    from . import timetable
    ensure_modules(conn)
    t = today()
    try:
        occ = [o for o in timetable.occurrences(conn, t, t + timedelta(days=14)) if o.get("status") in (None, "teilnahme") and (o["date"] > t.isoformat() or o["end"] >= t.strftime("%H:%M"))]
    except Exception:
        occ = []
    occ.sort(key=lambda o: (o["date"], o["start"]))
    out = []
    for m in db.rows(conn, "SELECT * FROM modules ORDER BY sort, name"):
        d = module_detail(conn, m["id"])
        nxt = next((o for o in occ if o.get("module_id") == m["id"]), None)
        topics = [w["topic"] for w in d["weeks"] if w.get("topic") and w["week"] >= 1]
        tests = db.row(conn, "SELECT COUNT(*) AS n FROM tests WHERE module_id=?", (m["id"],))["n"]
        tasks = db.row(conn, "SELECT COUNT(*) AS n FROM study_tasks st JOIN study_packages p ON p.id=st.package_id WHERE p.module_id=?", (m["id"],))["n"]
        out.append({**m, "file_count": len(d["files"]), "new_count": d["new_count"], "open_tasks": d["open_tasks"],
                    "progress": d["progress"], "next_package": d["next_package"], "next_event": nxt,
                    "task_count": tasks, "test_count": tests, "topics": topics[-3:],
                    "courses": len(d["courses"]), "weeks": len([w for w in d["weeks"] if w["week"] >= 1])})
    return out


# ----------------------------------------------------------------------------
# Lernpakete: Status
# ----------------------------------------------------------------------------

def refresh_statuses(conn) -> None:
    """Vergangene Pakete mit offenen Aufgaben -> nachholen; Paketstatus aus Aufgaben ableiten."""
    t = today().isoformat()
    conn.execute("""UPDATE study_tasks SET status='nachholen' WHERE status IN ('geplant','in_bearbeitung')
                    AND package_id IN (SELECT id FROM study_packages WHERE date < ?)""", (t,))
    for p in db.rows(conn, "SELECT id, date, status FROM study_packages"):
        tasks = db.rows(conn, "SELECT status FROM study_tasks WHERE package_id=?", (p["id"],))
        if not tasks:
            # Paket ohne Aufgaben (alle verschoben oder geloescht): _recalc_package hat es auf "verschoben" gesetzt.
            # Frueher wurde daraus hier wieder "geplant": ein leeres Paket blieb im Kalender, belegte sein Zeitfenster
            # im Stundenplan und stand unter "Naechste Termine" (Korrektur vom 26.10.2026).
            continue
        st = _derive_status([x["status"] for x in tasks], p["date"] < t)
        if st != p["status"]:
            conn.execute("UPDATE study_packages SET status=? WHERE id=?", (st, p["id"]))


def _derive_status(statuses: list[str], past: bool) -> str:
    if not statuses:
        return "geplant"
    s = set(statuses)
    if s <= {"erledigt", "uebersprungen", "verschoben"}:
        if "erledigt" in s:
            return "erledigt"
        return "verschoben" if "verschoben" in s else "uebersprungen"
    if "erledigt" in s and (past or "nachholen" in s):
        return "teilweise"
    if "nachholen" in s:
        return "nachholen"
    if "in_bearbeitung" in s:
        return "in_bearbeitung"
    return "geplant"


def set_task_status(conn, task_id: int, status: str, actual_minutes: int | None = None, note: str = "") -> dict:
    t = db.row(conn, "SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", (task_id,))
    if not t:
        raise ValueError("Aufgabe nicht gefunden")
    conn.execute("UPDATE study_tasks SET status=?, done_at=?, actual_minutes=COALESCE(?, actual_minutes) WHERE id=?",
                 (status, db.now_iso() if status == "erledigt" else None, actual_minutes, task_id))
    conn.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                 (task_id, t["package_id"], t["status"], status, t["date"], t["date"], note, db.now_iso()))
    if status == "erledigt" and t["file_id"]:
        conn.execute("UPDATE files SET status='erledigt', seen_by_user=1 WHERE id=?", (t["file_id"],))
    refresh_statuses(conn)
    return db.row(conn, "SELECT * FROM study_tasks WHERE id=?", (task_id,))


# ----------------------------------------------------------------------------
# Planung
# ----------------------------------------------------------------------------

def _est(f: dict) -> int:
    return int(f.get("est_minutes") or DEFAULT_EST.get(f.get("doc_type") or "", 45))


def _units(conn, module_id: int, exclude_files: set[str]) -> list[dict]:
    """Lerneinheiten eines Moduls: pro Semesterwoche Vorlesungen + Uebungen, die noch offen sind."""
    start = semester_start(conn)
    files = _file_rows(conn, module_id)
    weeks: dict[int, dict] = defaultdict(lambda: {"vorlesungen": [], "uebungen": [], "files": []})
    for f in files:
        if f["id"] in exclude_files or f["status"] == "erledigt":
            continue
        w = week_index(start, f["chdate"])
        if w < 1:
            continue  # alte und vorsemesterliche Unterlagen nicht automatisch einplanen
        weeks[w]["files"].append(f)
        if f.get("doc_type") == "vorlesung":
            weeks[w]["vorlesungen"].append(f)
        elif f.get("doc_type") == "uebung":
            weeks[w]["uebungen"].append(f)
    out = []
    for w in sorted(weeks):
        u = weeks[w]
        if not u["vorlesungen"] and not u["uebungen"]:
            continue
        out.append({"week": w, "label": week_label(start, w), "topic": week_topic(u["files"]), "vorlesungen": u["vorlesungen"], "uebungen": u["uebungen"]})
    return out


def _module_score(m: dict, open_units: int, settings: dict) -> float:
    score = (m.get("priority") or 2) * 10 + open_units
    if settings["exam_priority"] and m.get("exam_date"):
        try:
            days = (date.fromisoformat(m["exam_date"]) - today()).days
            if 0 <= days <= 42:
                score += (42 - days)
        except ValueError:
            pass
    return score


def generate_packages(conn, start: date | None = None, days: int = 7, replace: bool = False, log=print) -> dict:
    """Erstellt Lernpakete fuer `days` Tage ab `start` nach der Lernkombination in den Einstellungen."""
    ensure_modules(conn)
    refresh_statuses(conn)
    s = db.get_settings(conn)
    start = start or today()
    end = start + timedelta(days=days - 1)
    if replace:
        # nur noch nicht begonnene Pakete: Ein Paket von heute oder spaeter mit einer erledigten (begonnenen,
        # uebersprungenen) Aufgabe hat ebenfalls den Status "geplant" und wurde frueher samt der erledigten Aufgabe
        # geloescht (Korrektur vom 26.10.2026)
        ids = [r["id"] for r in db.rows(conn, """SELECT id FROM study_packages p WHERE date BETWEEN ? AND ? AND status IN ('geplant')
                                                AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id AND t.status != 'geplant')""",
                                        (start.isoformat(), end.isoformat()))]
        for pid in ids:
            conn.execute("DELETE FROM study_tasks WHERE package_id=?", (pid,))
            conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))
    planned_files = {r["file_id"] for r in db.rows(conn, "SELECT file_id FROM study_tasks WHERE file_id IS NOT NULL AND status IN ('geplant','in_bearbeitung','erledigt','nachholen')")}
    modules = db.rows(conn, "SELECT * FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort")
    queues = {}
    for m in modules:
        units = _units(conn, m["id"], planned_files)
        if units:
            queues[m["id"]] = {"module": m, "units": units, "pos": 0, "pending": []}  # pending: Aufgaben der angefangenen Einheit
    if not queues:
        return {"created": 0, "message": "Keine offenen Vorlesungen oder Übungen für die Planung."}

    budget_day = s["minutes_per_day"]
    per_pkg = max(30, budget_day // max(1, s["subjects_per_day"]))
    order = sorted(queues, key=lambda mid: -_module_score(queues[mid]["module"], len(queues[mid]["units"]), s))
    rr = list(order)
    created = 0
    existing_days = {r["date"]: r["n"] for r in db.rows(conn, "SELECT date, COUNT(*) n FROM study_packages WHERE date BETWEEN ? AND ? GROUP BY date", (start.isoformat(), end.isoformat()))}
    for i in range(days):
        d = start + timedelta(days=i)
        if d.weekday() not in s["learn_days"] or existing_days.get(d.isoformat()):
            continue
        picked: list[tuple[dict, int]] = []
        day_used = 0
        attempts = 0
        while len(picked) < s["subjects_per_day"] and rr and attempts < len(rr):
            mid = rr.pop(0)
            q = queues[mid]
            tasks = _next_tasks(q, s, per_pkg)
            if tasks:
                pid = _insert_package(conn, d, q["module"], tasks, q.get("cur_unit"))
                day_used += sum(t["est"] for t in tasks)
                picked.append((q, pid))
                created += 1
                if q["pending"] or q["pos"] < len(q["units"]):
                    rr.append(mid)
            else:
                attempts += 1
                if q["pos"] < len(q["units"]) or q["pending"]:
                    rr.append(mid)
        # Restzeit des Tages mit weiteren Aufgaben der gewaehlten Faecher auffuellen (keine neuen Einheiten)
        changed = True
        while changed and day_used < budget_day:
            changed = False
            for q, pid in picked:
                while q["pending"] and day_used + q["pending"][0]["est"] <= budget_day:
                    t = q["pending"].pop(0)
                    n = db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", (pid,))["n"]
                    conn.execute("INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?, 'geplant', ?)",
                                 (pid, t["type"], t["file_id"], None, t["title"], n, t["est"], db.now_iso()))
                    day_used += t["est"]
                    changed = True
                _recalc_package(conn, pid)
    # Zeitslots in freien Fenstern des Stundenplans vergeben
    for i in range(days):
        assign_slots(conn, start + timedelta(days=i))
    feas = feasibility(conn)
    return {"created": created, "message": f"{created} Lernpakete erstellt", "feasibility": feas}


def assign_slots(conn, d: date, only_unset: bool = True) -> None:
    """Weist den Lernpaketen eines Tages Uhrzeiten in den freien Fenstern zu (Hochschultermine, Sperrzeiten,
    Fahrtzeit beruecksichtigt). Ein Paket liegt am Stueck im ersten Fenster mit genug Platz; passt es in keines,
    werden seine Aufgaben auf mehrere Fenster verteilt."""
    from . import timetable
    s = db.get_settings(conn)
    pkgs = db.rows(conn, "SELECT * FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen','erledigt') ORDER BY sort, id", (d.isoformat(),))
    if only_unset:
        pkgs = [p for p in pkgs if not p["start_time"]]
    if not pkgs:
        return
    windows = [dict(w) for w in timetable.free_windows(conn, d, s, include_packages=True)]
    if not windows:  # kein freies Fenster: Lernbeginn als Fallback, hintereinander
        windows = [{"start": timetable.hm(s["learn_start"]), "end": timetable.hm(s["learn_end"])}]
    brk = s["break_minutes"]
    free = [w["start"] for w in windows]          # naechste freie Minute je Fenster
    for p in pkgs:
        tasks = db.rows(conn, "SELECT id, est_minutes FROM study_tasks WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben') ORDER BY sort", (p["id"],))
        needs = [int(t["est_minutes"] or 45) for t in tasks]
        # Ein Paket kommt am Stueck in das erste freie Fenster, in dem es Platz hat. Frueher begann es im aktuellen
        # Fenster und endete hinter dem naechsten Termin: der Lernblock lag ueber der Vorlesung, der Stundenplan meldete
        # einen Konflikt, und "Lernslots neu legen" ergab wieder dasselbe; ein spaeteres kurzes Paket konnte die Luecke
        # davor nicht mehr nutzen (Korrektur vom 26.10.2026). Passt es in kein Fenster, werden seine Aufgaben wie
        # bisher der Reihe nach auf die Fenster verteilt.
        total = sum(needs) + brk * max(0, len(needs) - 1)
        k = next((j for j, w in enumerate(windows) if free[j] + total <= w["end"]), 0)
        first, last = None, None
        for t, need in zip(tasks, needs):
            placed = False
            while k < len(windows):
                w, cur = windows[k], free[k]
                if cur + need <= w["end"] or (w["end"] - w["start"] < need and cur == w["start"]):
                    st, en = cur, min(cur + need, w["end"]) if cur + need > w["end"] else cur + need
                    conn.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?", (timetable.mh(st), timetable.mh(en), t["id"]))
                    first = first if first is not None else st
                    last = en
                    free[k] = en + brk
                    placed = True
                    break
                k += 1
            if not placed:  # ueber das Tagesende hinaus (hinter das letzte Fenster)
                st = free[-1]
                conn.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?", (timetable.mh(st), timetable.mh(st + need), t["id"]))
                first = first if first is not None else st
                last = st + need
                free[-1] = st + need + brk
        if first is not None:
            conn.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", (timetable.mh(first), timetable.mh(last), p["id"]))


def set_package_time(conn, package_id: int, start: str | None, end: str | None) -> None:
    """Uhrzeit eines Lernpakets von Hand ("Uhrzeit" im Lernpaket, "Beginn" beim Anlegen). Frueher uebernahm
    PATCH /api/packages/{id} nur Tag, Titel und Reihenfolge, die Uhrzeit ging verloren (Korrektur vom 26.10.2026).
    Ohne Beginn wird die Uhrzeit entfernt, ohne Ende gilt die geplante Dauer. Aufgaben mit Uhrzeit ruecken um
    denselben Abstand mit. Ungueltige Uhrzeit: ValueError."""
    p = db.row(conn, "SELECT start_time, planned_minutes FROM study_packages WHERE id=?", (package_id,))
    if not p:
        return
    if not start:
        conn.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", (package_id,))
        conn.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=?", (package_id,))
        return
    a = _clock_minutes(start)
    b = _clock_minutes(end) if end else a + int(p["planned_minutes"] or 0)
    if b <= a:
        raise ValueError("Das Ende muss nach dem Beginn liegen.")
    from . import timetable
    conn.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", (timetable.mh(a), timetable.mh(b), package_id))
    if p["start_time"]:
        shift = a - timetable.hm(p["start_time"])
        for t in db.rows(conn, "SELECT id, start_time, end_time FROM study_tasks WHERE package_id=? AND start_time IS NOT NULL AND end_time IS NOT NULL", (package_id,)):
            conn.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                         (timetable.mh(timetable.hm(t["start_time"]) + shift), timetable.mh(timetable.hm(t["end_time"]) + shift), t["id"]))


def _clock_minutes(v) -> int:
    """'HH:MM' (auch '24:30' fuer ein Ende nach Mitternacht) in Minuten, sonst ValueError"""
    m = re.fullmatch(r"([0-9]{1,2}):([0-9]{2})", v) if isinstance(v, str) else None
    if not m or int(m.group(2)) > 59:
        raise ValueError(f"Ungültige Uhrzeit: {v}")
    return int(m.group(1)) * 60 + int(m.group(2))


def reslot_day(conn, d: date) -> None:
    """Alle Slots eines Tages neu vergeben (z. B. nach Stundenplan-Aenderung)."""
    conn.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE date=? AND status NOT IN ('erledigt')", (d.isoformat(),))
    conn.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id IN (SELECT id FROM study_packages WHERE date=? AND status NOT IN ('erledigt'))", (d.isoformat(),))
    assign_slots(conn, d)


def slot_conflicts(conn, start: date, end: date) -> list[dict]:
    """Lernslots, die sich mit besuchten Hochschulterminen ueberschneiden (nach Stundenplan-Aenderungen)."""
    from . import timetable
    out = []
    d = start
    while d <= end:
        occ = [o for o in timetable.occurrences(conn, d, d) if o["status"] == "teilnahme"]
        for p in db.rows(conn, "SELECT id, subject, title, start_time, end_time FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status IN ('geplant','in_bearbeitung')", (d.isoformat(),)):
            ps, pe = timetable.hm(p["start_time"]), timetable.hm(p["end_time"])
            for o in occ:
                if ps < timetable.hm(o["end"]) and pe > timetable.hm(o["start"]):
                    out.append({"date": d.isoformat(), "package_id": p["id"], "subject": p["subject"], "title": p["title"], "slot": f"{p['start_time']}–{p['end_time']}", "event": o["title"], "event_time": f"{o['start']}–{o['end']}"})
                    break
        d += timedelta(days=1)
    return out


def _next_tasks(q: dict, s: dict, budget: int) -> list[dict]:
    """Naechste Aufgaben eines Moduls innerhalb des Budgets. Reihenfolge: Vorlesung -> Uebung -> Test."""
    if not q["pending"]:
        if q["pos"] >= len(q["units"]):
            return []
        u = q["units"][q["pos"]]
        q["pos"] += 1
        q["cur_unit"] = u
        tasks = []

        def add(kind, f):
            est = _est(f)
            title = f.get("ai_title") or f["name"]
            if est > budget:  # lange Materialien in Teile splitten (max. 4)
                n = min(4, -(-est // budget))
                part = -(-est // n)
                for k in range(n):
                    tasks.append({"type": kind, "file_id": f["id"], "title": f"{title} (Teil {k + 1}/{n})", "est": part})
            else:
                tasks.append({"type": kind, "file_id": f["id"], "title": title, "est": est})

        # Alle Vorlesungen und alle Uebungen der Lehrwoche (Hoersaal-, Gruppenuebung ...), hoechstens 4 je Art
        for f in u["vorlesungen"][:4] if s["parts_lecture"] else []:
            add("vorlesung", f)
        for f in u["uebungen"][:4] if s["parts_exercise"] else []:
            add("uebung", f)
        # Genau EIN gemeinsamer Wochentest fuer das Modul und die Lehrwoche
        if s["tests_per_subject"] >= 1 and (q["module"].get("weekly_test", 1) != 0):
            tasks.append({"type": "test", "file_id": None, "title": f"Gemeinsamer Wochentest Lehrwoche {u['week']}" + (f" – {u['topic']}" if u["topic"] else ""), "est": int(q["module"].get("test_minutes") or s["test_minutes"])})
        if s["tests_per_subject"] >= 2:
            tasks.append({"type": "wiederholung", "file_id": None, "title": f"Wiederholung Lehrwoche {u['week']} (Karteikarten, Fehler aus dem Test)", "est": 15})
        q["pending"] = tasks
    out, used = [], 0
    while q["pending"]:
        t = q["pending"][0]
        if out and used + t["est"] > budget:
            break
        out.append(q["pending"].pop(0))
        used += t["est"]
    return out


def _insert_package(conn, d: date, m: dict, tasks: list[dict], unit: dict | None) -> int:
    title = (unit or {}).get("topic") or (unit or {}).get("label") or m["name"]
    cur = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) VALUES (?,?,?,?,?,?, 'geplant', 0, 1, ?)",
                       (d.isoformat(), m["id"], m["name"], title, (unit or {}).get("week"), sum(t["est"] for t in tasks), db.now_iso()))
    pid = cur.lastrowid
    for i, t in enumerate(tasks):
        conn.execute("INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?, 'geplant', ?)",
                     (pid, t["type"], t["file_id"], None, t["title"], i, t["est"], db.now_iso()))
    return pid


def feasibility(conn) -> dict:
    """Vergleicht offene Lernmenge mit verfuegbarer Zeit der naechsten 4 Wochen."""
    s = db.get_settings(conn)
    planned_files = {r["file_id"] for r in db.rows(conn, "SELECT file_id FROM study_tasks WHERE file_id IS NOT NULL AND status='erledigt'")}
    total = 0
    for m in db.rows(conn, "SELECT id FROM modules WHERE COALESCE(active,1)=1"):
        for u in _units(conn, m["id"], planned_files):
            total += (sum(_est(f) for f in u["vorlesungen"][:4]) if s["parts_lecture"] else 0) + (sum(_est(f) for f in u["uebungen"][:4]) if s["parts_exercise"] else 0) + (s["test_minutes"] if s["tests_per_subject"] else 0)
    avail = 0
    for i in range(28):
        if (today() + timedelta(days=i)).weekday() in s["learn_days"]:
            avail += s["minutes_per_day"]
    per_day_need = s["subjects_per_day"] * (s["parts_lecture"] * 45 + s["parts_exercise"] * 60 + s["tests_per_subject"] * s["test_minutes"])
    hint = None
    if per_day_need > s["minutes_per_day"]:
        hint = f"Deine Kombination braucht etwa {per_day_need} Minuten pro Tag, verfügbar sind {s['minutes_per_day']}. Weniger Fächer pro Tag, kürzere Tests oder mehr Lernzeit wählen."
    elif total > avail:
        hint = f"Offene Materialien brauchen etwa {round(total / 60)} Stunden, in 4 Wochen sind {round(avail / 60)} Stunden verfügbar. Die Planung verteilt den Rest auf spätere Wochen."
    return {"open_minutes": total, "available_minutes_4w": avail, "per_day_need": per_day_need, "per_day_available": s["minutes_per_day"], "hint": hint}


# ----------------------------------------------------------------------------
# Kalender
# ----------------------------------------------------------------------------

def calendar(conn, start: date, end: date) -> dict:
    ensure_modules(conn)
    refresh_statuses(conn)
    pkgs = db.rows(conn, """SELECT p.*, m.color, m.name AS module_name FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id
                             WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.sort, p.id""", (start.isoformat(), end.isoformat()))
    ids = [p["id"] for p in pkgs]
    tasks = db.rows(conn, f"""SELECT t.*, f.name AS file_name, f.last_page, te.submitted_at AS test_submitted, te.score AS test_score, te.max_score AS test_max
                              FROM study_tasks t LEFT JOIN files f ON f.id=t.file_id LEFT JOIN tests te ON te.id=t.test_id
                              WHERE t.package_id IN ({','.join('?' * len(ids)) or 'NULL'}) ORDER BY t.package_id, t.sort""", ids) if ids else []
    by_pkg = defaultdict(list)
    for t in tasks:
        by_pkg[t["package_id"]].append(t)
    s = db.get_settings(conn)
    from . import timetable
    occ_all = timetable.occurrences(conn, start, end) if (end - start).days <= 45 else []
    days = []
    d = start
    while d <= end:
        dp = [dict(p, tasks=by_pkg[p["id"]]) for p in pkgs if p["date"] == d.isoformat()]
        ev = [o for o in occ_all if o["date"] == d.isoformat()]
        minutes = sum(p["planned_minutes"] or 0 for p in dp)
        done = sum(1 for p in dp for t in p["tasks"] if t["status"] == "erledigt")
        total = sum(len(p["tasks"]) for p in dp)
        statuses = [p["status"] for p in dp]
        if not dp:
            st = "frei" if d.weekday() not in s["learn_days"] else "leer"
        elif all(x in ("erledigt", "uebersprungen", "verschoben") for x in statuses) and "erledigt" in statuses:
            st = "erledigt"
        elif "nachholen" in statuses or (d < today() and any(x in ("geplant", "in_bearbeitung") for x in statuses)):
            st = "nachholen" if done == 0 else "teilweise"
        elif "teilweise" in statuses:
            st = "teilweise"
        elif "in_bearbeitung" in statuses:
            st = "in_bearbeitung"
        else:
            st = "geplant"
        days.append({"date": d.isoformat(), "weekday": d.weekday(), "status": st, "minutes": minutes, "tasks_done": done, "tasks_total": total, "packages": dp, "events": ev})
        d += timedelta(days=1)
    return {"start": start.isoformat(), "end": end.isoformat(), "days": days, "settings": s}


def open_tasks(conn) -> list[dict]:
    refresh_statuses(conn)
    return db.rows(conn, """SELECT t.*, p.date, p.subject, p.title AS package_title, p.module_id, m.color, f.name AS file_name
                            FROM study_tasks t JOIN study_packages p ON p.id=t.package_id LEFT JOIN modules m ON m.id=p.module_id
                            LEFT JOIN files f ON f.id=t.file_id
                            WHERE t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY p.date, p.sort, t.sort""")


# ----------------------------------------------------------------------------
# Verschieben, Nachholen, Woche retten
# ----------------------------------------------------------------------------

def _capacity(conn, d: date, s: dict) -> int:
    used = db.row(conn, "SELECT COALESCE(SUM(planned_minutes),0) m FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen')", (d.isoformat(),))["m"]
    return max(0, s["minutes_per_day"] - used)


def suggest_reschedule(conn, task_ids: list[int] | None = None, package_id: int | None = None, horizon: int = 10, max_share: float = 1.0) -> dict:
    """Schlaegt freie Tage fuer offene Aufgaben vor (erst Vorschlag, dann Bestaetigung)."""
    refresh_statuses(conn)
    s = db.get_settings(conn)
    if package_id is not None:
        tasks = db.rows(conn, "SELECT t.*, p.date, p.module_id, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE p.id=? AND t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY t.sort", (package_id,))
    elif task_ids:
        tasks = db.rows(conn, f"SELECT t.*, p.date, p.module_id, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id IN ({','.join('?' * len(task_ids))}) ORDER BY p.date, t.sort", task_ids)
    else:  # alle nachzuholenden
        tasks = db.rows(conn, "SELECT t.*, p.date, p.module_id, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.status='nachholen' ORDER BY p.date, t.sort")
    moves = []
    t0 = today()
    cap = {}
    for i in range(1, horizon + 1):
        d = t0 + timedelta(days=i)
        if d.weekday() in s["learn_days"]:
            cap[d] = int(_capacity(conn, d, s) * max_share)
    # Auch heute, wenn noch Platz ist
    if t0.weekday() in s["learn_days"]:
        cap = {t0: int(_capacity(conn, t0, s) * max_share), **cap}
    for t in tasks:
        placed = None
        for d in sorted(cap):
            if cap[d] >= t["est_minutes"] and d.isoformat() != t["date"]:
                cap[d] -= t["est_minutes"]
                placed = d
                break
        if placed is None:  # notfalls auf den ersten Lerntag mit dem meisten Platz
            if cap:
                d = max(cap, key=cap.get)
                cap[d] -= t["est_minutes"]
                placed = d
        moves.append({"task_id": t["id"], "title": t["title"], "type": t["type"], "subject": t["subject"], "module_id": t["module_id"], "est_minutes": t["est_minutes"], "from": t["date"], "to": placed.isoformat() if placed else None})
    return {"moves": moves, "message": _suggest_text(moves)}


def _suggest_text(moves: list[dict]) -> str:
    if not moves:
        return "Keine offenen Aufgaben."
    days = sorted({m["to"] for m in moves if m["to"]})
    subj = sorted({m["subject"] for m in moves if m["subject"]})
    wd = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    fmt = lambda d: f"{wd[date.fromisoformat(d).weekday()]} {date.fromisoformat(d).strftime('%d.%m.')}"
    return f"{len(moves)} offene Aufgaben ({', '.join(subj)}) können auf {', '.join(fmt(d) for d in days)} verteilt werden."


def apply_moves(conn, moves: list[dict]) -> int:
    """Verschiebt Aufgaben in (neue) Pakete am Zieltag. Erledigte Aufgaben bleiben unberuehrt."""
    n = 0
    for mv in moves:
        if not mv.get("to"):
            continue
        t = db.row(conn, "SELECT t.*, p.date, p.module_id, p.subject, p.title AS ptitle, p.week_no FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", (mv["task_id"],))
        if not t or t["status"] == "erledigt" or t["date"] == mv["to"]:
            continue
        target = db.row(conn, "SELECT id FROM study_packages WHERE date=? AND module_id IS ? AND status IN ('geplant','in_bearbeitung') ORDER BY id LIMIT 1", (mv["to"], t["module_id"]))
        if target:
            pid = target["id"]
        else:
            cur = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) VALUES (?,?,?,?,?,0,'geplant',0,0,?)",
                               (mv["to"], t["module_id"], t["subject"], t["ptitle"], t["week_no"], db.now_iso()))
            pid = cur.lastrowid
        old_pid = t["package_id"]
        conn.execute("UPDATE study_tasks SET package_id=?, status='geplant', moved_from=?, sort=(SELECT COALESCE(MAX(sort),-1)+1 FROM study_tasks WHERE package_id=?) WHERE id=?", (pid, t["date"], pid, t["id"]))
        conn.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                     (t["id"], pid, t["status"], "geplant", t["date"], mv["to"], "verschoben", db.now_iso()))
        _recalc_package(conn, old_pid)
        _recalc_package(conn, pid)
        n += 1
    refresh_statuses(conn)
    return n


def _recalc_package(conn, pid: int) -> None:
    r = db.row(conn, "SELECT COUNT(*) n, COALESCE(SUM(est_minutes),0) m FROM study_tasks WHERE package_id=?", (pid,))
    if r["n"] == 0:
        p = db.row(conn, "SELECT generated FROM study_packages WHERE id=?", (pid,))
        if p:
            conn.execute("UPDATE study_packages SET status='verschoben', planned_minutes=0 WHERE id=?", (pid,))
    else:
        conn.execute("UPDATE study_packages SET planned_minutes=? WHERE id=?", (r["m"], pid))


def move_package(conn, package_id: int, new_date: str) -> None:
    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (package_id,))
    if not p:
        raise ValueError("Paket nicht gefunden")
    conn.execute("UPDATE study_packages SET date=? WHERE id=?", (new_date, package_id))
    conn.execute("UPDATE study_tasks SET moved_from=?, status=CASE WHEN status='nachholen' THEN 'geplant' ELSE status END WHERE package_id=? AND status!='erledigt'", (p["date"], package_id))
    for t in db.rows(conn, "SELECT id, status FROM study_tasks WHERE package_id=?", (package_id,)):
        conn.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                     (t["id"], package_id, t["status"], t["status"], p["date"], new_date, "Paket verschoben", db.now_iso()))
    refresh_statuses(conn)


def rescue_week(conn) -> dict:
    """'Meine Woche retten': offene Aufgaben realistisch auf die naechsten 7 Tage verteilen (max. 60 % der Tageszeit)."""
    return suggest_reschedule(conn, horizon=7, max_share=0.6)


def skip_tasks(conn, task_ids: list[int]) -> None:
    for tid in task_ids:
        set_task_status(conn, tid, "uebersprungen", note="bewusst übersprungen")


def dashboard(conn) -> dict:
    ensure_modules(conn)
    refresh_statuses(conn)
    t = today()
    cal = calendar(conn, t, t)
    today_day = cal["days"][0]
    mods = modules_overview(conn)
    new_files = db.rows(conn, """SELECT f.id, f.name, f.first_seen, f.chdate, c.subject, c.module_id, a.doc_type, a.title AS ai_title, a.difficulty, a.est_minutes
                                 FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                                 WHERE f.seen_by_user=0 AND c.active=1 ORDER BY f.first_seen DESC, f.chdate DESC""")
    week_start = monday(t)
    week = calendar(conn, week_start, week_start + timedelta(days=6))
    wk_total = sum(d["tasks_total"] for d in week["days"])
    wk_done = sum(d["tasks_done"] for d in week["days"])
    backlog = db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE status='nachholen'")["n"]
    upcoming = []
    for m in mods:
        if m.get("exam_date") and m["exam_date"] >= t.isoformat():
            upcoming.append({"date": m["exam_date"], "kind": "klausur", "title": f"Klausur {m['name']}", "module_id": m["id"], "color": m["color"]})
    for p in db.rows(conn, "SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date > ? AND p.status IN ('geplant') ORDER BY p.date LIMIT 6", (t.isoformat(),)):
        upcoming.append({"date": p["date"], "kind": "lernpaket", "title": f"{p['subject']}: {p['title']}", "module_id": p["module_id"], "color": p["color"], "package_id": p["id"]})
    for te in db.rows(conn, "SELECT t.id, t.title, p.date, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.type='test' AND t.status IN ('geplant') AND p.date>=? ORDER BY p.date LIMIT 4", (t.isoformat(),)):
        upcoming.append({"date": te["date"], "kind": "test", "title": f"{te['subject']}: {te['title']}", "task_id": te["id"]})
    upcoming.sort(key=lambda x: x["date"])
    last_sync = db.row(conn, "SELECT * FROM sync_log ORDER BY id DESC LIMIT 1")
    from . import timetable
    today_day["events"] = timetable.occurrences(conn, t, t)
    today_day["free"] = timetable.free_windows(conn, t)
    return {"today": today_day, "modules": mods, "new_files": new_files[:50], "new_total": len(new_files),
            "week": {"start": week_start.isoformat(), "done": wk_done, "total": wk_total, "days": [{"date": d["date"], "status": d["status"], "minutes": d["minutes"]} for d in week["days"]]},
            "backlog": backlog, "upcoming": upcoming[:8], "last_sync": last_sync, "settings": db.get_settings(conn)}
