"""Lernplaner: Faecher, Wochenwunsch, "Thema gemacht" (Auftrag des Inhabers 14.11.2026, Teil 1;
docs/PLANER-FAECHER-WOCHENWUNSCH.md). Spiegel von StudyChoice.swift / StudyPlanModules.swift im iPad-Kern, gleiche
Pfade und Antworten (packages/shared-contracts/fixtures/local-backend/study-plan.json, Szenario "faecher_wunsch").

- `GET/POST /api/calendar/modules`: Faecher im Lernkalender (aktuelle Module mit Haken, eigenes Fach hinzufuegen).
  Die Wahl steht in `plan_modules_off` (Namen), abgewaehlte Faecher werden nie verplant (study.plan_off_ids).
- `GET/PUT /api/calendar/week-wish`: "Diese Woche will ich vor allem X und Y machen" (`plan_week_wish`, Namen und der
  Montag der Woche); Speichern plant den Rest der Woche neu.
- `POST /api/calendar/topic-done`: Thema erledigt (frueher oder im Termin eines anderen Fachs): Termin wird frei,
  der verdraengte Termin rueckt nach."""
from __future__ import annotations

import json
from datetime import date, timedelta

from fastapi import APIRouter, Body, HTTPException

from . import colors, db, study

ASKED_KEY = "plan_modules_asked"
WISH_KEY = "plan_week_wish"
NAME_MAX = 200                                   # wie server.MODULE_NAME_MAX
MAX_TASKS = 50

router = APIRouter()


def _put(conn, key: str, value: str) -> None:
    conn.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))


def _dumps(v) -> str:
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def _write_off(conn, names: set[str]) -> None:
    _put(conn, study.PLAN_OFF_KEY, _dumps(sorted(names)))


def _asked(conn) -> bool:
    r = db.row(conn, "SELECT value FROM settings WHERE key=?", (ASKED_KEY,))
    return bool(r) and r["value"] == "1"


# ---------------------------------------------------------------- Faecher

_KEPT_SQL = """SELECT p.id FROM study_packages p WHERE p.module_id IN ({marks}) AND p.date >= ?
               AND p.status NOT IN ('erledigt','teilweise','verschoben','uebersprungen')"""


def kept_count(conn, today: date) -> int:
    ids = study.plan_off_ids(conn)
    if not ids:
        return 0
    return len(db.rows(conn, _KEPT_SQL.format(marks=",".join("?" * len(ids))), (*sorted(ids), today.isoformat())))


def remove_own(conn, today: date) -> int:
    """Nach Rueckfrage: kuenftige selbst angelegte bzw. geaenderte Pakete abgewaehlter Faecher (Erledigtes bleibt)"""
    ids = study.plan_off_ids(conn)
    if not ids:
        return 0
    n = 0
    for p in db.rows(conn, _KEPT_SQL.format(marks=",".join("?" * len(ids))), (*sorted(ids), today.isoformat())):
        conn.execute("DELETE FROM study_tasks WHERE package_id=? AND status<>'erledigt'", (p["id"],))
        if not db.row(conn, "SELECT 1 FROM study_tasks WHERE package_id=?", (p["id"],)):
            conn.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", (p["id"],))
            conn.execute("DELETE FROM study_packages WHERE id=?", (p["id"],))
            n += 1
    return n


def overview(conn, today: date) -> dict:
    """Aktuelle Module (aktives Semester) mit Haken "Im Lernkalender planen"; `kept`: kuenftige eigene bzw. geaenderte
    Pakete abgewaehlter Faecher (die App fragt, ob sie weg sollen)"""
    skip = study.plan_off(conn)
    modules = [{"id": m["id"], "name": m["name"] or "", "color": m["color"], "planned": (m["name"] or "") not in skip}
               for m in db.rows(conn, "SELECT id, name, color FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, name")]
    return {"asked": _asked(conn), "modules": modules, "kept": kept_count(conn, today)}


def add_subject(conn, raw) -> str:
    """Eigenes Fach: vorhandenes Modul gleichen Namens wird aktiv, sonst ein neues Modul (wie POST /api/modules)"""
    name = raw.strip() if isinstance(raw, str) else ""
    if not name or len(name) > NAME_MAX:
        raise HTTPException(422, f"add: Name des Fachs (höchstens {NAME_MAX} Zeichen)")
    m = db.row(conn, "SELECT id, active FROM modules WHERE name=? ORDER BY id LIMIT 1", (name,))
    if m:
        if m["active"] is not None and not m["active"]:
            conn.execute("UPDATE modules SET active=1, active_custom=1 WHERE id=?", (m["id"],))
    else:
        n = db.row(conn, "SELECT COUNT(*) n FROM modules")["n"]
        conn.execute("INSERT INTO modules(name, semester, color, color_custom, sort, created_at) VALUES (?,?,?,?,?,?)",
                     (name, None, colors.next_color(conn), 0, n, db.now_iso()))
    return name


def save(conn, body, today: date) -> None:
    """`{"modules": [{"name", "planned"}], "add": "Fach", "remove_own": true}` (alles freiwillig; ohne Liste nur
    "gefragt" merken). Abgewaehlte Faecher verlieren sofort ihre unberuehrten automatischen Pakete."""
    if not isinstance(body, dict):
        raise HTTPException(422, "modules: Liste aus name und planned")
    names = study.plan_off(conn)
    mods = body.get("modules")
    if mods is not None and not isinstance(mods, list):
        raise HTTPException(422, "modules: Liste aus name und planned")
    for m in mods or []:
        name = m.get("name") if isinstance(m, dict) else None
        on = m.get("planned") if isinstance(m, dict) else None
        if not isinstance(name, str) or not name or not isinstance(on, bool):
            raise HTTPException(422, "modules: Liste aus name und planned")
        if on:
            names.discard(name)
        else:
            names.add(name)
    if "remove_own" in body and not isinstance(body["remove_own"], bool):
        raise HTTPException(422, "remove_own: ja oder nein")
    if body.get("add") is not None:
        names.discard(add_subject(conn, body["add"]))
    if mods is not None or body.get("add") is not None:
        _write_off(conn, names)
    study.drop_unplanned(conn)
    if body.get("remove_own") is True:
        remove_own(conn, today)
    _put(conn, ASKED_KEY, "1")


# ---------------------------------------------------------------- Wochenwunsch

def _wish_raw(conn) -> dict:
    r = db.row(conn, "SELECT value FROM settings WHERE key=?", (WISH_KEY,))
    try:
        v = json.loads(r["value"]) if r and r["value"] else {}
    except (TypeError, ValueError):
        return {}
    return v if isinstance(v, dict) else {}


def _choices(conn) -> list[dict]:
    off = study.plan_off_ids(conn)
    return [{"id": m["id"], "name": m["name"], "color": m["color"]}
            for m in db.rows(conn, "SELECT id, name, color FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, name")
            if m["id"] not in off and m["name"]]


def wish_for(conn, today: date) -> tuple[date, date, list[int]] | None:
    """Wunsch der laufenden oder einer kommenden Woche, die noch nicht vorbei ist: (Montag, Sonntag, Modul-IDs in der
    gewuenschten Reihenfolge; nur geplante, aktive Faecher)"""
    v = _wish_raw(conn)
    try:
        mon = date.fromisoformat(v.get("week") or "")
    except (TypeError, ValueError):
        return None
    sun = mon + timedelta(days=6)
    if sun < today:
        return None
    by_name = {c["name"]: c["id"] for c in _choices(conn)}
    ids = []
    for n in v.get("modules") or []:
        if isinstance(n, str) and n in by_name and by_name[n] not in ids:
            ids.append(by_name[n])
    return (mon, sun, ids) if ids else None


def wish_out(conn, today: date) -> dict:
    mon = study.monday(today)
    w = wish_for(conn, today)
    chosen = {i for i in (w[2] if w and w[0] == mon else [])}
    order = w[2] if w and w[0] == mon else []
    names = {c["id"]: c["name"] for c in _choices(conn)}
    return {"week": mon.isoformat(), "modules": [names[i] for i in order], "choices": [{**c, "wished": c["id"] in chosen} for c in _choices(conn)]}


def save_wish(conn, body, today: date) -> dict:
    """Wunsch dieser Woche speichern (leere Liste: kein Wunsch) und den Rest der Woche neu planen"""
    if not isinstance(body, dict) or not isinstance(body.get("modules"), list) or \
            not all(isinstance(n, str) for n in body["modules"]):
        raise HTTPException(422, "modules: Liste von Fächern")
    known = {c["name"] for c in _choices(conn)}
    wanted: list[str] = []
    for n in body["modules"]:
        if n not in known:
            raise HTTPException(422, f"„{n}“ ist kein Fach im Lernkalender.")
        if n not in wanted:
            wanted.append(n)
    mon = study.monday(today)
    _put(conn, WISH_KEY, _dumps({"week": mon.isoformat(), "modules": wanted}))
    sun = mon + timedelta(days=6)
    if study.smart_active(conn):
        from . import smart_goals
        r = smart_goals.plan_now(conn, {})
        plan = {"smart": True, "applied": r["applied"], "message": (r.get("result") or {}).get("message")}
    else:
        r = study.generate_packages(conn, today, (sun - today).days + 1, replace=True, log=lambda *a: None)
        plan = {"smart": False, "created": r.get("created", 0), "message": r.get("message")}
    return {**wish_out(conn, today), "plan": plan}


# ---------------------------------------------------------------- Thema gemacht

def _ids(v, field: str) -> list[int]:
    if not isinstance(v, list) or not v or len(v) > MAX_TASKS or any(isinstance(x, bool) or not isinstance(x, int) for x in v):
        raise HTTPException(422, f"{field}: Liste von Aufgaben (1 bis {MAX_TASKS})")
    out: list[int] = []
    for x in v:
        if x not in out:
            out.append(x)
    return out


def _today_package(conn, module: dict, today: date) -> int:
    """Paket von heute fuer dieses Fach (eigenes, nicht vom Stundenplaner), sonst ein neues eigenes"""
    r = db.row(conn, "SELECT id FROM study_packages WHERE date=? AND module_id IS ? AND COALESCE(source,'')<>'smart' ORDER BY id LIMIT 1",
               (today.isoformat(), module["module_id"]))
    if r:
        return r["id"]
    return conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) "
                        "VALUES (?,?,?,?,?,0,'erledigt',0,0,?)",
                        (today.isoformat(), module["module_id"], module["subject"], module["subject"] or "Erledigt", module["week_no"],
                         db.now_iso())).lastrowid


def _move_task(conn, t: dict, pid: int, note: str) -> None:
    # die Uhrzeit der Aufgabe gehoerte zum alten Termin
    conn.execute("UPDATE study_tasks SET package_id=?, moved_from=?, start_time=NULL, end_time=NULL, "
                 "sort=(SELECT COALESCE(MAX(sort),-1)+1 FROM study_tasks WHERE package_id=?) WHERE id=?",
                 (pid, t["date"], pid, t["id"]))
    new = db.row(conn, "SELECT date FROM study_packages WHERE id=?", (pid,))
    conn.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                 (t["id"], pid, t["status"], t["status"], t["date"], new["date"], note, db.now_iso()))


def topic_done(conn, body, today: date) -> dict:
    """Thema erledigt. `task_ids`: die Aufgaben (dieselbe Datei in anderen Paketen wird mit erledigt, nichts doppelt);
    `in_package`: das Paket, in dessen Zeit man es gemacht hat (z. B. ein anderes Fach). Kuenftige Pakete, die dadurch
    leer werden, verschwinden (Termin frei); die offenen Aufgaben von `in_package` ruecken in den ersten frei
    gewordenen Termin, sonst auf die naechsten Lerntage. Bloecke des Stundenplaners bleiben (Lernzeit)."""
    if not isinstance(body, dict):
        raise HTTPException(422, f"task_ids: Liste von Aufgaben (1 bis {MAX_TASKS})")
    ids = _ids(body.get("task_ids"), "task_ids")
    ip = body.get("in_package")
    if ip is not None and (isinstance(ip, bool) or not isinstance(ip, int)):
        raise HTTPException(422, "in_package: Lernpaket")
    host = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (ip,)) if ip is not None else None
    if ip is not None and not host:
        raise HTTPException(404, "Lernpaket nicht gefunden")
    ti = today.isoformat()
    tasks = []
    for i in ids:
        t = db.row(conn, "SELECT t.*, p.date, p.module_id, p.subject, p.title AS ptitle, p.week_no, p.source FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", (i,))
        if not t:
            raise HTTPException(404, "Aufgabe nicht gefunden")
        tasks.append(t)
    files = sorted({t["file_id"] for t in tasks if t["file_id"] and t["type"] not in study.OWN_RESULT})
    # alle offenen Aufgaben, die gleich erledigt sind: die gewaehlten und dieselben Dateien anderswo
    closing = {t["id"] for t in tasks if t["status"] in study.OPEN_TASKS}
    if files:
        closing |= {r["id"] for r in db.rows(conn, f"SELECT id FROM study_tasks WHERE file_id IN ({','.join('?' * len(files))}) "
                                                   f"AND status IN ({','.join('?' * len(study.OPEN_TASKS))}) "
                                                   f"AND type NOT IN ({','.join('?' * len(study.OWN_RESULT))})",
                                             (*files, *study.OPEN_TASKS, *study.OWN_RESULT))}
    for t in tasks:
        if t["status"] in study.OPEN_TASKS and (not t["file_id"] or t["type"] in study.OWN_RESULT):
            study.set_task_status(conn, t["id"], "erledigt", note="Thema gemacht")
    if files:
        study.set_files_done(conn, files, True)
    # erledigte Aufgaben aus kuenftigen Paketen dorthin, wo sie gemacht wurden (Paket von heute bzw. in_package)
    touched: list[int] = []
    origin = None                                       # Fach des Themas, das im Termin von in_package gemacht wurde
    for i in sorted(closing):
        t = db.row(conn, "SELECT t.*, p.date, p.module_id, p.subject, p.title AS ptitle, p.week_no, p.source FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", (i,))
        if t["package_id"] not in touched:
            touched.append(t["package_id"])
        if t["date"] <= ti or t["source"] == "smart":
            continue
        target = host["id"] if host and host["date"] <= ti and (host["source"] or "") != "smart" else _today_package(conn, t, today)
        _move_task(conn, t, target, "Thema gemacht")
        if host and target == host["id"] and origin is None and t["module_id"] != host["module_id"]:
            origin = t
        if target not in touched:
            touched.append(target)
    # frei gewordene Termine: kuenftige, automatisch erstellte Pakete ohne Aufgaben verschwinden
    freed: list[dict] = []
    for pid in touched:
        p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))
        if not p or (p["source"] or "") == "smart":
            continue
        n = db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", (pid,))["n"]
        if n == 0 and p["date"] >= ti and p["generated"]:
            freed.append({"date": p["date"], "start_time": p["start_time"], "end_time": p["end_time"]})
            conn.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", (pid,))
            conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))
        else:
            study._recalc_package(conn, pid)
    # der verdraengte Termin: offene Aufgaben von in_package in den ersten frei gewordenen Termin, sonst weiter hinten
    moved = 0
    if host and (host["source"] or "") != "smart":
        rest = db.rows(conn, "SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id "
                             "WHERE t.package_id=? AND t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY t.sort, t.id", (host["id"],))
        slot = next((f for f in sorted(freed, key=lambda f: (f["date"], f["start_time"] or "")) if f["date"] >= ti and f["date"] >= host["date"]), None)
        if rest and slot:
            pid = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time) "
                               "VALUES (?,?,?,?,?,0,'geplant',0,?,?,?,?)",
                               (slot["date"], host["module_id"], host["subject"], host["title"], host["week_no"], host["generated"], db.now_iso(),
                                slot["start_time"], slot["end_time"])).lastrowid
            for t in rest:
                _move_task(conn, t, pid, "Platz für ein anderes Thema")
                moved += 1
            study._recalc_package(conn, pid)
        elif rest:
            moves = study.suggest_reschedule(conn, [t["id"] for t in rest], horizon=7)["moves"]
            moved = study.apply_moves(conn, moves)
        # bleibt im Termin nur das dort gemachte Thema eines anderen Fachs, ist es jetzt dessen Termin
        left = {r["id"] for r in db.rows(conn, "SELECT id FROM study_tasks WHERE package_id=?", (host["id"],))}
        if origin and left and left <= closing:
            conn.execute("UPDATE study_packages SET module_id=?, subject=?, title=? WHERE id=?",
                         (origin["module_id"], origin["subject"], origin["ptitle"], host["id"]))
        study._recalc_package(conn, host["id"])
    study.refresh_statuses(conn)
    done = len(closing)
    parts = [f"{done} {'Aufgabe' if done == 1 else 'Aufgaben'} erledigt"]
    if freed:
        parts.append(f"{len(freed)} {'Termin' if len(freed) == 1 else 'Termine'} frei")
    if moved:
        parts.append(f"{moved} {'Aufgabe' if moved == 1 else 'Aufgaben'} neu eingeordnet")
    return {"done": done, "freed": freed, "moved": moved, "message": ", ".join(parts) + "."}


# ---------------------------------------------------------------- Endpunkte

@router.get("/api/calendar/modules")
def api_modules():
    with db.cursor() as conn:
        return overview(conn, study.today())


@router.post("/api/calendar/modules")
def api_modules_save(body=Body(default={})):
    with db.cursor() as conn:
        save(conn, body, study.today())
        return overview(conn, study.today())


@router.get("/api/calendar/week-wish")
def api_wish():
    with db.cursor() as conn:
        return wish_out(conn, study.today())


@router.put("/api/calendar/week-wish")
def api_wish_save(body=Body(default={})):
    with db.cursor() as conn:
        return save_wish(conn, body, study.today())


@router.post("/api/calendar/topic-done")
def api_topic_done(body=Body(default={})):
    with db.cursor() as conn:
        return topic_done(conn, body, study.today())
