"""Smart Planner 2.0 (Auftrag des Inhabers vom 12.11.2026): Lernziele in Stunden je Modul, Lernzeit, gemeinsamer
Lernplan ueber alle Klausuren. Datenbank und Endpunkte; die Rechnung steht in app/smart_planner.py (ohne KI).
Gleiche Regeln im Swift-Kern (LocalBackend/Study/SmartGoals.swift, Endpoints/SmartGoalsEndpoints.swift).

- Lernziel je Modul (`study_goals`), Lernzeit (`study_sessions`, eindeutige uuid), Lernbloecke = Lernpakete mit
  source='smart' (Kalender, Verschieben, Abgleich zwischen Geraeten wie bisher).
- Klausurtag: Zweittermin, wenn gewaehlt, sonst `modules.exam_date`; automatisch uebernommene Tage (exam_dates_auto)
  gelten als unbestaetigt, bis der Nutzer sie bestaetigt (`exam_confirmed` = Tag).
- Anerkannte Lernzeit: schon vorher gelernt + `smart_planner.credit` (Ueberlappungen einmal, abgehakter Block mit
  Minuten statt Stoppuhr). Ein abgehakter Block ohne Minuten zaehlt nicht.
- Neuplanung: nur wenn sich die Eingaben geaendert haben (Pruefsumme), ohne KI. Erledigte, gesperrte, von Hand
  geaenderte, heutige und vergangene Bloecke bleiben; bis AUTO_LIMIT geaenderte Bloecke automatisch, mehr nur nach
  Bestaetigung; Unterdeckung nie still: dann bleibt der alte Plan und der Nutzer waehlt eine Option.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid as uuidlib
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, HTTPException

from . import db, smart_planner as sp, study, timetable

BERLIN = ZoneInfo("Europe/Berlin")
SETTINGS_KEY = "smart_planner"
STATE_KEY = "smart_plan_state"
PROPOSAL_KEY = "smart_plan_proposal"
DEFAULTS = {"sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120, "utilization": 60, "min_block": 30,
            "max_block": 120, "break": 10, "max_week_minutes": 0, "max_day_minutes": 0, "commitments": []}
AUTO_LIMIT = 8          # so viele geaenderte Bloecke plant der Planer selbst um, mehr nur nach Bestaetigung
EXTRA_DAYS = 42         # nach der letzten Klausur (Zweittermin, spaeterer Termin)
MIN_DAYS, MAX_DAYS = 28, 400
MATERIAL_KINDS = {"vorlesung": "vorlesung", "skript": "vorlesung", "uebung": "uebung", "loesung": "uebung", "klausur": "wiederholung"}
BLOCK_TITLE = "Selbststudium"
UUID_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,80}$")
HM_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def now() -> datetime:
    return datetime.now(BERLIN)


def _now_ts() -> int:
    return int(now().timestamp())


def _now_minute() -> int:
    n = now()
    return n.hour * 60 + n.minute


def _stamp() -> str:
    """Aenderungszeit mit Millisekunden (spaetere Aenderung gewinnt beim Zusammenfuehren)"""
    return now().astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.%f")[:23] + "Z"


def _json(conn, key: str, default):
    r = db.row(conn, "SELECT value FROM settings WHERE key=?", (key,))
    if not r or r["value"] in (None, ""):
        return default
    try:
        v = json.loads(r["value"])
    except ValueError:
        return default
    return v if isinstance(v, type(default)) or default is None else default


def _put(conn, key: str, value) -> None:
    if value is None:
        conn.execute("DELETE FROM settings WHERE key=?", (key,))
        return
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    old = db.row(conn, "SELECT value FROM settings WHERE key=?", (key,))
    if not old or old["value"] != text:
        conn.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, text))


# ---------------------------------------------------------------- Einstellungen

def settings(conn) -> dict:
    s = dict(DEFAULTS)
    stored = _json(conn, SETTINGS_KEY, {})
    for k in DEFAULTS:
        if k in stored:
            s[k] = stored[k]
    s["learn_days"] = db.get_settings(conn)["learn_days"]
    return s


def _int_in(body: dict, key: str, lo: int, hi: int, label: str) -> int | None:
    if key not in body or body[key] is None:
        return None
    v = body[key]
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or not (lo <= v <= hi):
        raise HTTPException(400, f"{label}: Zahl von {lo} bis {hi}.")
    return int(round(v))


def _hm(v, label: str) -> int:
    if not isinstance(v, str) or not HM_RE.fullmatch(v):
        raise HTTPException(400, f"{label}: Uhrzeit als HH:MM.")
    return int(v[:2]) * 60 + int(v[3:])


def save_settings(conn, body: dict) -> dict:
    if not isinstance(body, dict):
        raise HTTPException(400, "Einstellungen als Objekt.")
    cur = _json(conn, SETTINGS_KEY, {})
    s = {k: cur.get(k, DEFAULTS[k]) for k in DEFAULTS}
    if "sleep_hours" in body and body["sleep_hours"] is not None:
        h = body["sleep_hours"]
        if isinstance(h, bool) or not isinstance(h, (int, float)) or h != h or not (4 <= h <= 14):
            raise HTTPException(400, "Schlaf: 4 bis 14 Stunden.")
        s["sleep_minutes"] = int(round(h * 60))
    if "bedtime" in body and body["bedtime"] is not None:
        s["bedtime"] = _hm(body["bedtime"], "Schlafenszeit")
    for key, lo, hi, label in (("leisure_minutes", 0, 600, "Freizeit pro Tag"), ("utilization", 10, 100, "Nutzungsquote"),
                               ("min_block", 15, 120, "Kürzester Block"), ("max_block", 30, 240, "Längster Block"),
                               ("break", 0, 60, "Pause"), ("max_week_minutes", 0, 7 * 1440, "Höchstens pro Woche"),
                               ("max_day_minutes", 0, 1440, "Höchstens pro Tag")):
        v = _int_in(body, key, lo, hi, label)
        if v is not None:
            s[key] = v
    if s["max_block"] < s["min_block"]:
        raise HTTPException(400, "Der längste Block muss mindestens so lang sein wie der kürzeste.")
    if "commitments" in body and body["commitments"] is not None:
        items = body["commitments"]
        if not isinstance(items, list) or len(items) > 50:
            raise HTTPException(400, "Verpflichtungen als Liste (höchstens 50).")
        out = []
        for c in items:
            if not isinstance(c, dict):
                raise HTTPException(400, "Verpflichtung als Objekt.")
            wd = c.get("weekday")
            if isinstance(wd, bool) or not isinstance(wd, int) or not 0 <= wd <= 6:
                raise HTTPException(400, "Wochentag 0 (Montag) bis 6 (Sonntag).")
            a, b = _hm(c.get("start"), "Beginn"), _hm(c.get("end"), "Ende")
            if b <= a:
                raise HTTPException(400, "Das Ende muss nach dem Beginn liegen.")
            kind = c.get("kind") if c.get("kind") in ("arbeit", "verpflichtung") else "verpflichtung"
            title = str(c.get("title") or ("Arbeit" if kind == "arbeit" else "Verpflichtung"))[:80]
            out.append({"weekday": wd, "start": a, "end": b, "kind": kind, "title": title})
        s["commitments"] = sorted(out, key=lambda c: (c["weekday"], c["start"], c["end"]))
    _put(conn, SETTINGS_KEY, s)
    return settings(conn)


def public_settings(s: dict) -> dict:
    out = {k: s[k] for k in DEFAULTS}
    out["sleep_hours"] = s["sleep_minutes"] / 60
    out["bedtime_hm"] = timetable.mh(s["bedtime"])
    out["learn_days"] = s["learn_days"]
    return out


# ---------------------------------------------------------------- Ziele

def _goals(conn) -> list[dict]:
    """Lernziele der Module, die der Lernkalender plant (abgewaehlte Faecher: kein Ziel, kein Block)"""
    off = study.plan_off_ids(conn)
    return [g for g in db.rows(conn, """SELECT g.*, m.name, m.color, m.exam_date AS module_exam, m.priority AS module_priority
                                        FROM study_goals g JOIN modules m ON m.id=g.module_id
                                        WHERE COALESCE(m.active,1)=1 ORDER BY m.sort, m.id""") if g["module_id"] not in off]


def exam_of(conn, g: dict, auto: dict | None = None) -> dict:
    """Klausurtag eines Ziels: Zweittermin (wenn gewaehlt), sonst der Termin des Moduls; Quelle und Bestaetigung"""
    auto = auto if auto is not None else _json(conn, "exam_dates_auto", {})
    if int(g.get("exam_attempt") or 1) == 2 and g.get("exam_date_2"):
        d, source = g["exam_date_2"], "zweittermin"
    elif g.get("module_exam"):
        d = g["module_exam"]
        source = "automatisch" if auto.get(str(g["module_id"])) == d else "selbst"
    else:
        return {"date": None, "source": None, "confirmed": False}
    return {"date": d, "source": source, "confirmed": source != "automatisch" or g.get("exam_confirmed") == d}


def _check_date(v, label: str) -> str | None:
    if v in (None, ""):
        return None
    try:
        return date.fromisoformat(str(v)).isoformat()
    except ValueError:
        raise HTTPException(400, f"{label}: Datum als JJJJ-MM-TT.") from None


def save_goal(conn, module_id: int, body: dict) -> dict:
    if not isinstance(body, dict):
        raise HTTPException(400, "Lernziel als Objekt.")
    m = db.row(conn, "SELECT * FROM modules WHERE id=?", (module_id,))
    if not m:
        raise HTTPException(404, "Modul nicht gefunden")
    if module_id in study.plan_off_ids(conn):
        raise HTTPException(409, f"„{m['name'] or 'Modul'}“ ist nicht im Lernkalender. Erst unter „Fächer im Lernkalender“ anhaken.")
    g = db.row(conn, "SELECT * FROM study_goals WHERE module_id=?", (module_id,))
    ts = db.now_iso()
    if not g:
        conn.execute("INSERT INTO study_goals(module_id, target_minutes, created_at, updated_at) VALUES (?,0,?,?)", (module_id, ts, ts))
        g = db.row(conn, "SELECT * FROM study_goals WHERE module_id=?", (module_id,))
    upd: dict = {}
    for key, col, hi, label in (("target_hours", "target_minutes", 2000, "Ziel"), ("learned_before_hours", "learned_before_minutes", 2000, "Schon gelernt")):
        if key in body and body[key] is not None:
            v = body[key]
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or not (0 <= v <= hi):
                raise HTTPException(400, f"{label}: 0 bis {hi} Stunden.")
            upd[col] = int(round(v * 60))
    for key in ("include_lectures", "writing"):
        if key in body and body[key] is not None:
            if not isinstance(body[key], bool):
                raise HTTPException(400, f"{key}: ja oder nein.")
            upd[key] = 1 if body[key] else 0
    if "exam_attempt" in body and body["exam_attempt"] is not None:
        if body["exam_attempt"] not in (1, 2) or isinstance(body["exam_attempt"], bool):
            raise HTTPException(400, "Termin: 1 (Ersttermin) oder 2 (Zweittermin).")
        upd["exam_attempt"] = body["exam_attempt"]
    if "exam_date_2" in body:
        upd["exam_date_2"] = _check_date(body["exam_date_2"], "Zweittermin")
    if "priority" in body and body["priority"] is not None:
        if body["priority"] not in (1, 2, 3) or isinstance(body["priority"], bool):
            raise HTTPException(400, "Priorität 1 bis 3.")
        upd["priority"] = body["priority"]
    merged = {**g, **upd}
    if merged.get("exam_attempt") == 2 and not merged.get("exam_date_2"):
        raise HTTPException(400, "Für den Zweittermin fehlt das Datum.")
    if body.get("confirm_exam") is True:
        ex = exam_of(conn, {**merged, "module_exam": m["exam_date"]})
        if not ex["date"]:
            raise HTTPException(400, "Kein Klausurtermin zum Bestätigen.")
        upd["exam_confirmed"] = ex["date"]
    if upd:
        upd["updated_at"] = ts
        conn.execute(f"UPDATE study_goals SET {', '.join(f'{k}=?' for k in upd)} WHERE module_id=?", (*upd.values(), module_id))
    if upd.get("writing") == 0:                     # "schreibe ich nicht": kuenftige automatische Bloecke fallen sofort weg
        for p in db.rows(conn, _AUTO_SQL + " AND module_id=?", (study.today().isoformat(), module_id)):
            _drop_block(conn, p["id"])
    return db.row(conn, "SELECT * FROM study_goals WHERE module_id=?", (module_id,))


def delete_goal(conn, module_id: int) -> None:
    if not db.row(conn, "SELECT 1 FROM study_goals WHERE module_id=?", (module_id,)):
        raise HTTPException(404, "Lernziel nicht gefunden")
    conn.execute("DELETE FROM study_goals WHERE module_id=?", (module_id,))
    t = study.today().isoformat()
    for p in db.rows(conn, _AUTO_SQL + " AND module_id=?", (t, module_id)):
        _drop_block(conn, p["id"])


# ---------------------------------------------------------------- Lernzeit

def _session_rows(conn) -> list[dict]:
    out = []
    for r in db.rows(conn, "SELECT * FROM study_sessions ORDER BY id"):
        try:
            seg = json.loads(r["segments"]) if r["segments"] else []
        except ValueError:
            seg = []
        out.append({"uuid": r["uuid"], "module_id": r["module_id"], "package_id": r["package_id"], "kind": r["kind"],
                    "segments": seg if isinstance(seg, list) else [], "minutes": r["minutes"], "updated_at": r["updated_at"],
                    "deleted": bool(r["deleted_at"]), "day": r["day"]})
    return out


def credit(conn, sessions: list[dict] | None = None) -> dict:
    return sp.credit(sessions if sessions is not None else _session_rows(conn), _now_ts())


def session_out(r: dict) -> dict:
    o = dict(r)
    try:
        o["segments"] = json.loads(r["segments"]) if r.get("segments") else []
    except ValueError:
        o["segments"] = []
    c = sp.credit([{"uuid": r["uuid"], "module_id": r["module_id"], "kind": "manual" if r["kind"] == "block" else r["kind"],
                    "segments": o["segments"], "minutes": r["minutes"]}], _now_ts())
    o["credited_minutes"] = c["modules"].get(str(r["module_id"]), 0)
    return o


def _session(conn, uid: str) -> dict:
    r = db.row(conn, "SELECT * FROM study_sessions WHERE uuid=? AND deleted_at IS NULL", (uid,))
    if not r:
        raise HTTPException(404, "Lerneinheit nicht gefunden")
    return r


def _uuid(body: dict) -> str:
    u = body.get("uuid") or uuidlib.uuid4().hex
    if not isinstance(u, str) or not UUID_RE.fullmatch(u):
        raise HTTPException(400, "uuid: 8 bis 80 Zeichen aus Buchstaben, Ziffern, - _ . :")
    return u


def _module_and_package(conn, body: dict) -> tuple[int, int | None]:
    mid, pid = body.get("module_id"), body.get("package_id")
    if pid is not None:
        if isinstance(pid, bool) or not isinstance(pid, int):
            raise HTTPException(400, "package_id ist keine Zahl.")
        p = db.row(conn, "SELECT id, module_id FROM study_packages WHERE id=?", (pid,))
        if not p:
            raise HTTPException(404, "Lernblock nicht gefunden")
        mid = mid if mid is not None else p["module_id"]
    if isinstance(mid, bool) or not isinstance(mid, int):
        raise HTTPException(400, "module_id fehlt.")
    if not db.row(conn, "SELECT 1 FROM modules WHERE id=?", (mid,)):
        raise HTTPException(404, "Modul nicht gefunden")
    return mid, pid


def add_session(conn, body: dict) -> dict:
    """Zeit eintragen: Minuten (mit Tag) oder Beginn und Ende (Unix-Sekunden); dieselbe uuid zweimal = einmal"""
    if not isinstance(body, dict):
        raise HTTPException(400, "Lerneinheit als Objekt.")
    uid = _uuid(body)
    old = db.row(conn, "SELECT * FROM study_sessions WHERE uuid=?", (uid,))
    if old:
        return session_out(old)
    mid, pid = _module_and_package(conn, body)
    nts = _now_ts()
    seg, minutes, day = None, None, None
    if body.get("start") is not None or body.get("end") is not None:
        a, b = body.get("start"), body.get("end")
        if any(isinstance(x, bool) or not isinstance(x, int) for x in (a, b)):
            raise HTTPException(400, "Beginn und Ende als Unix-Sekunden.")
        if b <= a or b - a > 16 * 3600:
            raise HTTPException(400, "Das Ende muss nach dem Beginn liegen (höchstens 16 Stunden).")
        if b > nts + 300:
            raise HTTPException(400, "Lernzeit in der Zukunft kann nicht eingetragen werden.")
        seg = json.dumps([[a, b]])
        day = datetime.fromtimestamp(a, BERLIN).date().isoformat()
    else:
        minutes = _int_in(body, "minutes", 1, 16 * 60, "Minuten")
        if minutes is None:
            raise HTTPException(400, "Minuten oder Beginn und Ende angeben.")
        day = _check_date(body.get("day"), "Tag") or study.today().isoformat()
        if day > study.today().isoformat():
            raise HTTPException(400, "Lernzeit in der Zukunft kann nicht eingetragen werden.")
    st = _stamp()
    conn.execute("""INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, segments, minutes, day, note, device, created_at, updated_at)
                    VALUES (?,?,?,?, 'fertig', ?,?,?,?,?,?,?)""",
                 (uid, mid, pid, "manual", seg, minutes, day, str(body.get("note") or "")[:500], str(body.get("device") or "")[:80] or None, st, st))
    return session_out(_session(conn, uid))


def start_session(conn, body: dict) -> dict:
    """Stoppuhr starten; eine laufende andere Lerneinheit wird angehalten (nie zwei gleichzeitig)"""
    if not isinstance(body, dict):
        raise HTTPException(400, "Lerneinheit als Objekt.")
    uid = _uuid(body)
    old = db.row(conn, "SELECT * FROM study_sessions WHERE uuid=?", (uid,))
    if old:
        return session_out(old)
    mid, pid = _module_and_package(conn, body)
    for r in db.rows(conn, "SELECT uuid FROM study_sessions WHERE state='laeuft' AND deleted_at IS NULL"):
        pause_session(conn, r["uuid"])
    nts, st = _now_ts(), _stamp()
    conn.execute("""INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, segments, minutes, day, device, created_at, updated_at)
                    VALUES (?,?,?, 'timer', 'laeuft', ?, NULL, ?, ?, ?, ?)""",
                 (uid, mid, pid, json.dumps([[nts, None]]), study.today().isoformat(), str(body.get("device") or "")[:80] or None, st, st))
    return session_out(_session(conn, uid))


def _segments(r: dict) -> list:
    try:
        s = json.loads(r["segments"]) if r["segments"] else []
    except ValueError:
        s = []
    return s if isinstance(s, list) else []


def pause_session(conn, uid: str) -> dict:
    r = _session(conn, uid)
    if r["state"] == "laeuft":
        seg = _segments(r)
        if seg and seg[-1][1] is None:
            seg[-1][1] = max(seg[-1][0], _now_ts())
        conn.execute("UPDATE study_sessions SET state='pause', segments=?, updated_at=? WHERE uuid=?", (json.dumps(seg), _stamp(), uid))
    return session_out(_session(conn, uid))


def resume_session(conn, uid: str) -> dict:
    r = _session(conn, uid)
    if r["state"] == "pause":
        for o in db.rows(conn, "SELECT uuid FROM study_sessions WHERE state='laeuft' AND deleted_at IS NULL AND uuid<>?", (uid,)):
            pause_session(conn, o["uuid"])
        seg = _segments(r) + [[_now_ts(), None]]
        conn.execute("UPDATE study_sessions SET state='laeuft', segments=?, updated_at=? WHERE uuid=?", (json.dumps(seg), _stamp(), uid))
    elif r["state"] == "fertig":
        raise HTTPException(409, "Die Lerneinheit ist schon beendet.")
    return session_out(_session(conn, uid))


def stop_session(conn, uid: str) -> dict:
    r = _session(conn, uid)
    if r["state"] != "fertig":
        seg = _segments(r)
        if seg and seg[-1][1] is None:
            seg[-1][1] = max(seg[-1][0], _now_ts())
        conn.execute("UPDATE study_sessions SET state='fertig', segments=?, updated_at=? WHERE uuid=?", (json.dumps(seg), _stamp(), uid))
    return session_out(_session(conn, uid))


def correct_session(conn, uid: str, body: dict) -> dict:
    """Zeit korrigieren: die eingetragenen Minuten ersetzen die gemessene Zeit"""
    r = _session(conn, uid)
    if not isinstance(body, dict):
        raise HTTPException(400, "Korrektur als Objekt.")
    upd = {}
    m = _int_in(body, "minutes", 0, 16 * 60, "Minuten")
    if m is not None:
        if r["state"] != "fertig":
            raise HTTPException(409, "Erst die Stoppuhr beenden, dann korrigieren.")
        upd.update(minutes=m, segments=None, kind="manual" if r["kind"] == "timer" else r["kind"])
    if "note" in body:
        upd["note"] = str(body.get("note") or "")[:500]
    if "module_id" in body:
        mid, _ = _module_and_package(conn, {"module_id": body["module_id"]})
        upd["module_id"] = mid
    if upd:
        upd["updated_at"] = _stamp()
        conn.execute(f"UPDATE study_sessions SET {', '.join(f'{k}=?' for k in upd)} WHERE uuid=?", (*upd.values(), uid))
    return session_out(_session(conn, uid))


def delete_session(conn, uid: str) -> None:
    _session(conn, uid)
    conn.execute("UPDATE study_sessions SET deleted_at=?, state='fertig', updated_at=? WHERE uuid=?", (db.now_iso(), _stamp(), uid))


def list_sessions(conn, module_id: int | None, start: str | None, end: str | None) -> list[dict]:
    sql, params = "SELECT * FROM study_sessions WHERE deleted_at IS NULL", []
    if module_id is not None:
        sql += " AND module_id=?"
        params.append(module_id)
    if start:
        sql += " AND day>=?"
        params.append(start)
    if end:
        sql += " AND day<=?"
        params.append(end)
    return [session_out(r) for r in db.rows(conn, sql + " ORDER BY day DESC, id DESC LIMIT 500", params)]


# ---------------------------------------------------------------- Bloecke

# automatisch gelegte, kuenftige, unberuehrte Bloecke: nur diese darf der Planer aendern
_AUTO_SQL = """SELECT * FROM study_packages p WHERE source='smart' AND COALESCE(locked,0)=0 AND COALESCE(manual,0)=0
               AND date > ? AND status='geplant'
               AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id AND t.status='erledigt')
               AND NOT EXISTS (SELECT 1 FROM study_sessions s WHERE s.package_id=p.id AND s.deleted_at IS NULL)"""


def _drop_block(conn, pid: int) -> None:
    conn.execute("DELETE FROM study_tasks WHERE package_id=? AND status<>'erledigt'", (pid,))
    if not db.row(conn, "SELECT 1 FROM study_tasks WHERE package_id=?", (pid,)):
        conn.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", (pid,))
        conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))


def dedupe_blocks(conn) -> int:
    """Gleiche Bloecke doppelt (zwei Geraete haben offline denselben Plan gerechnet): einer bleibt, Aufgaben und
    Lernzeit wandern mit"""
    n = 0
    for g in db.rows(conn, """SELECT module_id, date, start_time, end_time, MIN(id) AS keep FROM study_packages
                              WHERE source='smart' AND status<>'erledigt' AND start_time IS NOT NULL
                              GROUP BY module_id, date, start_time, end_time HAVING COUNT(*) > 1"""):
        for d in db.rows(conn, """SELECT id FROM study_packages WHERE source='smart' AND status<>'erledigt' AND module_id IS ?
                                  AND date=? AND start_time=? AND end_time=? AND id<>?""",
                         (g["module_id"], g["date"], g["start_time"], g["end_time"], g["keep"])):
            conn.execute("UPDATE study_tasks SET package_id=? WHERE package_id=?", (g["keep"], d["id"]))
            conn.execute("UPDATE study_sessions SET package_id=? WHERE package_id=?", (g["keep"], d["id"]))
            conn.execute("UPDATE study_packages SET locked=MAX(COALESCE(locked,0), (SELECT COALESCE(locked,0) FROM study_packages WHERE id=?)) WHERE id=?",
                         (d["id"], g["keep"]))
            conn.execute("DELETE FROM study_packages WHERE id=?", (d["id"],))
            n += 1
    return n


def mark_missed(conn, t: date, block_credit: dict) -> None:
    """Vergangene Bloecke: mit Lernzeit "teilweise", ohne "verpasst"; offene Aufgaben darin werden frei (ihr Material
    kommt in einen kuenftigen Block)"""
    for p in db.rows(conn, "SELECT id FROM study_packages WHERE source='smart' AND date < ? AND status IN ('geplant','in_bearbeitung','nachholen')",
                     (t.isoformat(),)):
        st = "teilweise" if block_credit.get(str(p["id"]), 0) > 0 else "verpasst"
        conn.execute("UPDATE study_packages SET status=? WHERE id=?", (st, p["id"]))
        conn.execute("UPDATE study_tasks SET status='verschoben' WHERE package_id=? AND status IN ('geplant','in_bearbeitung','nachholen')", (p["id"],))


def block_done(conn, pid: int, body: dict) -> dict:
    """Block abhaken: nur mit tatsaechlich gelernten Minuten (Vorschlag in der App: gemessene Zeit, sonst Dauer);
    0 Minuten = nicht gelernt. Ein zweiter Haken ersetzt den ersten."""
    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))
    if not p:
        raise HTTPException(404, "Lernblock nicht gefunden")
    if not isinstance(body, dict) or "minutes" not in body:
        raise HTTPException(400, "Wie lange hast du gelernt? Minuten angeben.")
    m = _int_in(body, "minutes", 0, 16 * 60, "Minuten")
    if m is None:
        raise HTTPException(400, "Wie lange hast du gelernt? Minuten angeben.")
    if p["date"] > study.today().isoformat():
        raise HTTPException(400, "Ein Block in der Zukunft kann noch nicht abgehakt werden.")
    if p["module_id"] is None:
        raise HTTPException(400, "Der Block gehört zu keinem Modul.")
    st = _stamp()
    for r in db.rows(conn, "SELECT uuid FROM study_sessions WHERE package_id=? AND kind='block' AND deleted_at IS NULL", (pid,)):
        conn.execute("UPDATE study_sessions SET deleted_at=?, updated_at=? WHERE uuid=?", (db.now_iso(), st, r["uuid"]))
    for r in db.rows(conn, "SELECT uuid FROM study_sessions WHERE package_id=? AND state<>'fertig' AND deleted_at IS NULL", (pid,)):
        stop_session(conn, r["uuid"])
    conn.execute("""INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, minutes, day, created_at, updated_at)
                    VALUES (?,?,?, 'block', 'fertig', ?,?,?,?)""", (uuidlib.uuid4().hex, p["module_id"], pid, m, p["date"], st, st))
    conn.execute("UPDATE study_packages SET status=? WHERE id=?", ("erledigt" if m > 0 else "verpasst", pid))
    return {"package_id": pid, "minutes": m, "status": "erledigt" if m > 0 else "verpasst"}


def block_undone(conn, pid: int) -> dict:
    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))
    if not p:
        raise HTTPException(404, "Lernblock nicht gefunden")
    st = _stamp()
    conn.execute("UPDATE study_sessions SET deleted_at=?, updated_at=? WHERE package_id=? AND kind='block' AND deleted_at IS NULL",
                 (db.now_iso(), st, pid))
    conn.execute("UPDATE study_packages SET status='geplant' WHERE id=?", (pid,))
    return {"package_id": pid, "status": "geplant"}


def set_locked(conn, pid: int, body: dict) -> dict:
    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))
    if not p:
        raise HTTPException(404, "Lernblock nicht gefunden")
    if not isinstance(body, dict) or not isinstance(body.get("locked"), bool):
        raise HTTPException(400, "locked: ja oder nein.")
    conn.execute("UPDATE study_packages SET locked=? WHERE id=?", (1 if body["locked"] else 0, pid))
    return db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))


def check_slot(conn, pid: int, body: dict) -> dict:
    """Sofortige Konfliktpruefung beim Verschieben (ohne zu speichern): Termine, Sperrzeiten, andere Bloecke,
    Klausurtag des Moduls"""
    p = db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))
    if not p:
        raise HTTPException(404, "Lernblock nicht gefunden")
    if not isinstance(body, dict):
        raise HTTPException(400, "Angaben als Objekt.")
    d = _check_date(body.get("date"), "Tag") or p["date"]
    a = _hm(body.get("start"), "Beginn") if body.get("start") is not None else (timetable.hm(p["start_time"]) if p["start_time"] else None)
    if a is None:
        raise HTTPException(400, "Beginn fehlt.")
    dur = (timetable.hm(p["end_time"]) - timetable.hm(p["start_time"])) if p["start_time"] and p["end_time"] else int(p["planned_minutes"] or 60)
    b = _hm(body.get("end"), "Ende") if body.get("end") is not None else a + dur
    if b <= a:
        raise HTTPException(400, "Das Ende muss nach dem Beginn liegen.")
    return {"date": d, "start": a, "end": b, "conflicts": _slot_conflicts(conn, p, date.fromisoformat(d), a, b)}


def _slot_conflicts(conn, p: dict, d: date, a: int, b: int, occ: list[dict] | None = None) -> list[dict]:
    out = []
    s = db.get_settings(conn)
    events = occ if occ is not None else timetable.occurrences(conn, d, d)
    for o in events:
        if o["date"] == d.isoformat() and o["status"] == "teilnahme" and a < timetable.hm(o["end"]) and b > timetable.hm(o["start"]):
            out.append({"kind": "termin", "text": f"Überschneidet „{o['title']}“ ({o['start']}–{o['end']})"})
    for x in s.get("blocked_times", []):
        if int(x.get("weekday", -1)) == d.weekday() and a < timetable.hm(x["end"]) and b > timetable.hm(x["start"]):
            out.append({"kind": "sperrzeit", "text": f"Überschneidet die Sperrzeit „{x.get('title') or 'Sperrzeit'}“"})
    for q in db.rows(conn, """SELECT id, subject, start_time, end_time FROM study_packages WHERE date=? AND id<>? AND start_time IS NOT NULL
                              AND status NOT IN ('verschoben','uebersprungen')""", (d.isoformat(), p["id"])):
        if a < timetable.hm(q["end_time"]) and b > timetable.hm(q["start_time"]):
            out.append({"kind": "block", "text": f"Überschneidet den Lernblock {q['subject'] or ''} ({q['start_time']}–{q['end_time']})".replace("  ", " ")})
    if p.get("module_id") is not None:
        g = db.row(conn, """SELECT g.*, m.exam_date AS module_exam FROM study_goals g JOIN modules m ON m.id=g.module_id
                            WHERE g.module_id=?""", (p["module_id"],))
        if g:
            ex = exam_of(conn, g)
            if ex["date"] and d.isoformat() >= ex["date"]:
                out.append({"kind": "klausur", "text": f"Liegt am oder nach der Klausur ({ex['date']})"})
    return out


# ---------------------------------------------------------------- Eingabe des Planers

def _days(conn, t: date, last: date, s: dict, occ: list[dict]) -> list[dict]:
    travel = int(db.get_settings(conn).get("travel_minutes") or 30)
    blocked = db.get_settings(conn).get("blocked_times", [])
    per: dict[str, list] = {}
    for o in occ:
        if o["status"] == "teilnahme":
            per.setdefault(o["date"], []).append((timetable.hm(o["start"]), timetable.hm(o["end"])))
    dates = []
    d = t
    while d <= last:
        ev = sorted(per.get(d.isoformat(), []))
        busy = [list(x) for x in ev]
        if ev:
            busy.append([ev[0][0] - travel, ev[0][0]])
            busy.append([max(e for _, e in ev), max(e for _, e in ev) + travel])
        for b in blocked:
            if int(b.get("weekday", -1)) == d.weekday():
                busy.append([timetable.hm(b["start"]), timetable.hm(b["end"])])
        dates.append({"date": d.isoformat(), "weekday": d.weekday(), "busy": busy})
        d += timedelta(days=1)
    return sp.build_days(dates, s)


def _lecture_minutes(occ: list[dict], module_id: int, start: str, end: str | None) -> int:
    n = 0
    for o in occ:
        if o.get("module_id") == module_id and o["status"] == "teilnahme" and o["date"] >= start and (end is None or o["date"] < end):
            n += max(0, timetable.hm(o["end"]) - timetable.hm(o["start"]))
    return n


def build(conn, t: date, partial: bool = False) -> dict:
    """Alles, was Planer und Uebersicht brauchen (eine Abfrage des Stundenplans fuer den ganzen Zeitraum)"""
    s = settings(conn)
    auto = _json(conn, "exam_dates_auto", {})
    goals = _goals(conn)
    sessions = _session_rows(conn)
    cr = sp.credit(sessions, _now_ts())
    ti = t.isoformat()
    exams = {}
    for g in goals:
        exams[g["module_id"]] = exam_of(conn, g, auto)
    future = [e["date"] for g in goals if g["writing"] for e in [exams[g["module_id"]]] if e["date"] and e["date"] > ti]
    last = max([date.fromisoformat(x) for x in future] or [t]) + timedelta(days=EXTRA_DAYS)
    last = min(max(last, t + timedelta(days=MIN_DAYS - 1)), t + timedelta(days=MAX_DAYS - 1))
    since = min([date.fromisoformat((g["created_at"] or ti)[:10]) for g in goals if g["include_lectures"]] or [t])
    occ = timetable.occurrences(conn, min(since, t), last)
    days = _days(conn, t, last, s, [o for o in occ if o["date"] >= ti])
    # feste Bloecke: alles mit Uhrzeit ab heute ausser den automatisch gelegten, unberuehrten kuenftigen
    auto_rows = db.rows(conn, _AUTO_SQL + " ORDER BY date, start_time, id", (ti,))     # einmal lesen (auch fuer prefer)
    auto_ids = {p["id"] for p in auto_rows}
    goal_mods = {g["module_id"] for g in goals}
    fixed = []
    for p in db.rows(conn, """SELECT id, module_id, date, start_time, end_time, status, source FROM study_packages
                              WHERE date >= ? AND start_time IS NOT NULL AND end_time IS NOT NULL
                              AND status NOT IN ('verschoben','uebersprungen')
                              AND id NOT IN (""" + _AUTO_SQL.replace("SELECT *", "SELECT p.id", 1) + """)
                              ORDER BY date, start_time, id""", (ti, ti)):
        if p["id"] in auto_ids:
            continue
        a, b = timetable.hm(p["start_time"]), timetable.hm(p["end_time"])
        if b <= a:
            continue
        fixed.append({"module_id": p["module_id"], "date": p["date"], "start": a, "end": b,
                      "counts": p["module_id"] in goal_mods and p["status"] not in ("erledigt", "verpasst", "teilweise")})
    modules, info = [], {}
    for g in goals:
        mid = g["module_id"]
        ex = exams[mid]
        learned = int(g["learned_before_minutes"] or 0) + cr["modules"].get(str(mid), 0)
        lecture = _lecture_minutes(occ, mid, (g["created_at"] or ti)[:10], ex["date"]) if g["include_lectures"] else 0
        st = sp.module_stats({"target_minutes": g["target_minutes"], "learned_minutes": learned, "lecture_minutes": lecture})
        info[mid] = {"goal": g, "exam": ex, "learned": learned, "lecture": lecture}
        if g["writing"]:
            modules.append({"id": mid, "exam_date": ex["date"], "remaining_minutes": st["remaining_minutes"],
                            "priority": int(g["priority"] or g["module_priority"] or 2),
                            "exam_date_2": g["exam_date_2"] if int(g["exam_attempt"] or 1) == 1 else None})
    inp = {"days": days, "modules": modules, "fixed": fixed,
           "settings": {k: s[k] for k in ("utilization", "min_block", "max_block", "break", "max_week_minutes", "max_day_minutes")},
           "accept_partial": partial}
    # bisheriger Plan: Lagen behalten, wo es geht. Teil der Pruefsumme, damit ein von Hand geloeschter Block neu verteilt
    # wird; nach dem Anwenden rechnet der naechste Aufruf einmal nach (ohne Aenderung) und steht dann still.
    inp["prefer"] = [{"module_id": p["module_id"], "date": p["date"], "start": timetable.hm(p["start_time"]), "end": timetable.hm(p["end_time"])}
                     for p in auto_rows if p["start_time"] and p["end_time"]]
    h = hashlib.sha256(json.dumps(inp, sort_keys=True).encode()).hexdigest()[:24]
    inp["now_minute"] = _now_minute()
    return {"input": inp, "hash": h, "info": info, "credit": cr, "sessions": sessions, "occ": occ, "settings": s, "goals": goals}


# ---------------------------------------------------------------- Planen und anwenden

def _apply(conn, result: dict, t: date) -> dict:
    existing = [{"id": p["id"], "module_id": p["module_id"], "date": p["date"], "start": timetable.hm(p["start_time"]),
                 "end": timetable.hm(p["end_time"])} for p in db.rows(conn, _AUTO_SQL, (t.isoformat(),)) if p["start_time"] and p["end_time"]]
    new = [b for b in result["blocks"] if b["date"] > t.isoformat() or not db.row(
        conn, "SELECT 1 FROM study_packages WHERE source='smart' AND module_id=? AND date=? AND start_time=? AND end_time=?",
        (b["module_id"], b["date"], timetable.mh(b["start"]), timetable.mh(b["end"])))]
    d = sp.diff(existing, new)
    for pid in d["remove"]:
        _drop_block(conn, pid)
    names = {r["id"]: r["name"] for r in db.rows(conn, "SELECT id, name FROM modules")}
    ts = db.now_iso()
    for b in d["add"]:
        conn.execute("""INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at,
                                                   start_time, end_time, source, locked, manual)
                        VALUES (?,?,?,?,NULL,?, 'geplant', 0, 1, ?,?,?, 'smart', 0, 0)""",
                     (b["date"], b["module_id"], names.get(b["module_id"]), BLOCK_TITLE, b["minutes"], ts,
                      timetable.mh(b["start"]), timetable.mh(b["end"])))
    return {"added": len(d["add"]), "removed": len(d["remove"]), "kept": len(d["keep"])}


def fill_materials(conn, t: date) -> dict:
    """Neue (noch nicht eingeplante) Unterlagen der Module mit Lernziel in kuenftige Bloecke desselben Moduls, im
    Budget des Blocks; der Rest ist ein Konflikt (nach Wichtigkeit), das Budget waechst nie"""
    goals = [g for g in _goals(conn) if g["writing"]]
    if not goals:
        return {"assign": [], "overflow": []}
    blocks = []
    for p in db.rows(conn, """SELECT p.id, p.module_id, p.date, p.start_time, p.end_time, p.planned_minutes,
                                     (SELECT COALESCE(SUM(est_minutes),0) FROM study_tasks t WHERE t.package_id=p.id
                                      AND t.status NOT IN ('verschoben','uebersprungen')) AS used
                              FROM study_packages p WHERE p.source='smart' AND p.date >= ? AND p.status='geplant'
                              AND p.start_time IS NOT NULL AND p.end_time IS NOT NULL""", (t.isoformat(),)):
        blocks.append({"id": p["id"], "module_id": p["module_id"], "date": p["date"], "start": timetable.hm(p["start_time"]),
                       "minutes": timetable.hm(p["end_time"]) - timetable.hm(p["start_time"]), "used": int(p["used"] or 0)})
    planned = study._planned_files(conn)
    trashed = {r["id"] for r in db.rows(conn, "SELECT id FROM files WHERE deleted_at IS NOT NULL")}
    start = study.semester_start(conn)
    mats, titles = [], {}
    for g in goals:
        for f in study._file_rows(conn, g["module_id"]):
            kind = f.get("doc_type")
            if kind not in MATERIAL_KINDS or f["id"] in planned or f["id"] in trashed or f.get("status") == "erledigt":
                continue
            w = study.file_week(start, f)
            if kind != "klausur" and w < 1:
                continue
            frm = None if kind == "klausur" else (start + timedelta(days=7 * (w - 1))).isoformat()
            mats.append({"file_id": f["id"], "module_id": g["module_id"], "kind": kind, "from_date": frm, "est": study._est(f)})
            titles[f["id"]] = (f.get("ai_title") or f.get("name") or "Unterlage", kind)
    r = sp.assign_materials(blocks, mats, settings(conn)["max_block"])
    ts = db.now_iso()
    for a in r["assign"]:
        title, kind = titles[a["file_id"]]
        if a["parts"] > 1:
            title = f"{title} (Teil {a['part']}/{a['parts']})"
        n = db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", (a["block_id"],))["n"]
        conn.execute("""INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at)
                        VALUES (?,?,?,?,?,?, 'geplant', ?)""", (a["block_id"], MATERIAL_KINDS[kind], a["file_id"], title, n, a["minutes"], ts))
    for o in r["overflow"]:
        o["title"] = titles[o["file_id"]][0]
    return r


def ensure(conn, t: date | None = None, auto: bool = True, readonly: bool = False) -> dict:
    """Beim Oeffnen von Uebersicht und Kalender: Doppel zusammenfuehren, Verpasstes markieren, bei geaenderten
    Eingaben neu planen (klein: sofort, gross oder Unterdeckung: Vorschlag). Liefert den Stand fuer die Uebersicht.
    `readonly`: nur lesen und rechnen (Schreibsperre gerade belegt), der naechste Aufruf holt das Umplanen nach."""
    t = t or study.today()
    if readonly:
        auto = False
    else:
        study.drop_unplanned(conn)                  # abgewaehlte Faecher (auch nach einem Abgleich)
        dedupe_blocks(conn)
        mark_missed(conn, t, sp.credit(_session_rows(conn), _now_ts())["blocks"])
    state = _json(conn, STATE_KEY, {})
    b = build(conn, t, partial=bool(state.get("partial")))
    if not b["input"]["modules"]:
        return {"build": b, "result": None, "state": state, "proposal": None}
    result = sp.plan(b["input"])
    proposal = _json(conn, PROPOSAL_KEY, {})
    shortfall = result["status"] == "unterdeckt"
    if state.get("hash") and state["hash"] != b["hash"] and auto and proposal and proposal.get("hash") == b["hash"] \
            and (proposal.get("kind") == "unterdeckt") == shortfall:
        pass        # Vorschlag zu genau diesen Eingaben steht schon: nicht bei jeder Uebersicht neu vergleichen und schreiben
    elif state.get("hash") and state["hash"] != b["hash"] and auto:
        if shortfall:
            proposal = {"kind": "unterdeckt", "hash": b["hash"], "message": result["message"]}
        else:
            existing = [{"id": p["id"], "module_id": p["module_id"], "date": p["date"], "start": timetable.hm(p["start_time"]),
                         "end": timetable.hm(p["end_time"])} for p in db.rows(conn, _AUTO_SQL, (t.isoformat(),)) if p["start_time"]]
            d = sp.diff(existing, [x for x in result["blocks"] if x["date"] > t.isoformat()])
            changes = len(d["add"]) + len(d["remove"])
            if changes <= AUTO_LIMIT:
                ch = _apply(conn, result, t)
                state = {**state, "hash": b["hash"], "at": db.now_iso(), "last_change": {**ch, "at": db.now_iso()} if ch["added"] or ch["removed"] else state.get("last_change")}
                proposal = {}
                _put(conn, STATE_KEY, state)
            else:
                proposal = {"kind": "umplanung", "hash": b["hash"], "added": len(d["add"]), "removed": len(d["remove"]),
                            "message": f"Größere Änderung: {len(d['add'])} neue und {len(d['remove'])} wegfallende Lernblöcke."}
        _put(conn, PROPOSAL_KEY, proposal or None)
    elif state.get("hash") == b["hash"] and proposal and not readonly:
        proposal = {}
        _put(conn, PROPOSAL_KEY, None)
    fill = fill_materials(conn, t) if state.get("hash") and not readonly else {"assign": [], "overflow": []}
    return {"build": b, "result": result, "state": state, "proposal": proposal or None, "fill": fill}


def plan_now(conn, body: dict) -> dict:
    """"Plan erstellen" / Vorschlag annehmen / Teilplan: jetzt planen und anwenden (auch grosse Aenderungen)"""
    t = study.today()
    body = body if isinstance(body, dict) else {}
    if "accept_partial" in body and not isinstance(body["accept_partial"], bool):
        raise HTTPException(400, "accept_partial: ja oder nein.")
    dedupe_blocks(conn)
    mark_missed(conn, t, sp.credit(_session_rows(conn), _now_ts())["blocks"])
    state = _json(conn, STATE_KEY, {})
    partial = body.get("accept_partial", bool(state.get("partial")))
    b = build(conn, t, partial=partial)
    if not b["input"]["modules"]:
        raise HTTPException(400, "Erst für mindestens ein Modul ein Lernziel in Stunden eintragen.")
    result = sp.plan(b["input"])
    if result["status"] == "unterdeckt":
        return {"applied": False, "result": _result_out(result)}
    ch = _apply(conn, result, t)
    _put(conn, STATE_KEY, {"hash": b["hash"], "at": db.now_iso(), "partial": partial, "last_change": {**ch, "at": db.now_iso()}})
    _put(conn, PROPOSAL_KEY, None)
    fill_materials(conn, t)
    return {"applied": True, "change": ch, "result": _result_out(result)}


def keep_plan(conn) -> dict:
    """Vorschlag ablehnen: Bloecke bleiben, die aktuellen Eingaben gelten als gesehen"""
    t = study.today()
    state = _json(conn, STATE_KEY, {})
    b = build(conn, t, partial=bool(state.get("partial")))
    _put(conn, STATE_KEY, {**state, "hash": b["hash"], "at": db.now_iso()})
    _put(conn, PROPOSAL_KEY, None)
    return {"ok": True}


def _result_out(r: dict) -> dict:
    return {k: r.get(k) for k in ("status", "feasible", "message", "deadlines", "options", "missing_minutes")}


# ---------------------------------------------------------------- Uebersicht

def overview(conn, auto: bool = True, readonly: bool = False) -> dict:
    t = study.today()
    ti = t.isoformat()
    if not readonly:
        study.ensure_modules(conn)
    e = ensure(conn, t, auto, readonly)
    b = e["build"]
    s = b["settings"]
    cr = sp.credit(_session_rows(conn), _now_ts())
    goal_ids = {g["module_id"] for g in b["goals"]}
    off_ids = study.plan_off_ids(conn)
    # kuenftige Lernzeit je Modul (vor der Klausur, nicht erledigt)
    planned_rows = db.rows(conn, """SELECT module_id, date, start_time, end_time, planned_minutes, status, source FROM study_packages
                                    WHERE date >= ? AND status NOT IN ('verschoben','uebersprungen','erledigt','verpasst','teilweise')""", (ti,))
    since = (t - timedelta(days=14)).isoformat()
    past = db.rows(conn, """SELECT id, module_id, start_time, end_time, planned_minutes FROM study_packages
                            WHERE source='smart' AND date >= ? AND date < ?""", (since, ti))
    modules = []
    next_exam = None
    for g in b["goals"]:
        mid = g["module_id"]
        info = b["info"][mid]
        ex = info["exam"]
        fut = sum(_minutes(p) for p in planned_rows if p["module_id"] == mid and (ex["date"] is None or p["date"] < ex["date"]))
        mine = [p for p in past if p["module_id"] == mid]
        plan_past = sum(_minutes(p) for p in mine)
        adherence = (sum(cr["blocks"].get(str(p["id"]), 0) for p in mine) * 100 // plan_past) if plan_past else None
        days_left = (date.fromisoformat(ex["date"]) - t).days if ex["date"] else None
        st = sp.module_stats({"target_minutes": g["target_minutes"], "learned_minutes": info["learned"], "lecture_minutes": info["lecture"],
                              "days_left": days_left, "planned_minutes": fut, "adherence": adherence})
        modules.append({"module_id": mid, "name": g["name"], "color": g["color"], "target_minutes": g["target_minutes"],
                        "learned_before_minutes": g["learned_before_minutes"] or 0, "credited_minutes": cr["modules"].get(str(mid), 0),
                        "include_lectures": bool(g["include_lectures"]), "writing": bool(g["writing"]), "exam_attempt": int(g["exam_attempt"] or 1),
                        "exam_date": ex["date"], "exam_source": ex["source"], "exam_confirmed": ex["confirmed"], "exam_date_2": g["exam_date_2"],
                        "module_exam_date": g["module_exam"], "priority": int(g["priority"] or g["module_priority"] or 2), "adherence": adherence,
                        "stats": st})
        if g["writing"] and ex["date"] and ex["date"] >= ti and (next_exam is None or ex["date"] < next_exam["date"]):
            next_exam = {"module_id": mid, "name": g["name"], "date": ex["date"], "days": days_left, "confirmed": ex["confirmed"]}
    others = [{"module_id": m["id"], "name": m["name"], "color": m["color"], "exam_date": m["exam_date"]}
              for m in db.rows(conn, "SELECT id, name, color, exam_date FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, id")
              if m["id"] not in goal_ids and m["id"] not in off_ids]
    mon = study.monday(t)
    week_days = []
    wk_sessions = [x for x in b["sessions"] if x.get("day") and mon.isoformat() <= x["day"] <= (mon + timedelta(days=6)).isoformat()]
    wk_credit = sp.credit(wk_sessions, _now_ts())
    for i in range(7):
        d = (mon + timedelta(days=i)).isoformat()
        rows = db.rows(conn, """SELECT id, module_id, start_time, end_time, planned_minutes, status FROM study_packages
                                WHERE source='smart' AND date=? AND status NOT IN ('verschoben','uebersprungen')""", (d,))
        day_credit = sp.credit([x for x in wk_sessions if x["day"] == d], _now_ts())
        week_days.append({"date": d, "planned_minutes": sum(_minutes(p) for p in rows),
                          "learned_minutes": sum(day_credit["modules"].values()), "blocks": len(rows)})
    conflicts = _conflicts(conn, t, b, e)
    r = e["result"]
    return {"enabled": bool(b["goals"]), "today": ti, "settings": public_settings(s), "next_exam": next_exam, "modules": modules,
            "modules_without_goal": others, "plan": _result_out(r) if r else None, "planned": bool(e["state"].get("hash")),
            "proposal": e["proposal"], "last_change": e["state"].get("last_change"),
            "week": {"start": mon.isoformat(), "days": week_days, "planned_minutes": sum(x["planned_minutes"] for x in week_days),
                     "learned_minutes": sum(wk_credit["modules"].values())},
            "conflicts": conflicts, "running": [session_out(x) for x in db.rows(
                conn, "SELECT * FROM study_sessions WHERE state IN ('laeuft','pause') AND deleted_at IS NULL ORDER BY id")]}


def _minutes(p: dict) -> int:
    if p.get("start_time") and p.get("end_time"):
        return max(0, timetable.hm(p["end_time"]) - timetable.hm(p["start_time"]))
    return int(p.get("planned_minutes") or 0)


def _conflicts(conn, t: date, b: dict, e: dict) -> list[dict]:
    out = []
    names = {g["module_id"]: g["name"] for g in b["goals"]}
    occ = [o for o in b["occ"] if o["date"] >= t.isoformat()]
    for p in db.rows(conn, """SELECT * FROM study_packages WHERE source='smart' AND date >= ? AND (COALESCE(locked,0)=1 OR COALESCE(manual,0)=1)
                              AND status='geplant' AND start_time IS NOT NULL AND end_time IS NOT NULL ORDER BY date, start_time""", (t.isoformat(),)):
        for c in _slot_conflicts(conn, p, date.fromisoformat(p["date"]), timetable.hm(p["start_time"]), timetable.hm(p["end_time"]),
                                 [o for o in occ if o["date"] == p["date"]]):
            out.append({"kind": c["kind"], "package_id": p["id"], "module_id": p["module_id"], "date": p["date"],
                        "text": f"{names.get(p['module_id'], p['subject'] or 'Block')} am {p['date']} {p['start_time']}: {c['text']}"})
    for g in b["goals"]:
        ex = b["info"][g["module_id"]]["exam"]
        if g["writing"] and not ex["date"]:
            out.append({"kind": "kein_termin", "module_id": g["module_id"], "text": f"{g['name']}: Klausurtermin fehlt"})
        elif g["writing"] and not ex["confirmed"]:
            out.append({"kind": "unbestaetigt", "module_id": g["module_id"], "text": f"{g['name']}: Klausurtermin {ex['date']} ist nicht bestätigt"})
    r = e["result"]
    if r and r["status"] == "unterdeckt":
        out.append({"kind": "unterdeckt", "text": r["message"]})
    for o in (e.get("fill") or {}).get("overflow", [])[:20]:
        out.append({"kind": "material", "module_id": o["module_id"], "file_id": o["file_id"],
                    "text": f"{names.get(o['module_id'], 'Modul')}: „{o['title']}“ passt nicht mehr ins Stundenbudget"})
    return out


# ---------------------------------------------------------------- Endpunkte

router = APIRouter()


def _tx(conn) -> None:
    """Schreibsperre sofort (zwei gleichzeitige Neuplanungen warten aufeinander statt doppelt zu planen)"""
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")


@router.get("/api/goals")
def api_goals():
    with db.cursor() as conn:
        try:
            _tx(conn)
        except sqlite3.OperationalError as e:
            # Schreibsperre dieses Kontos laenger belegt (z. B. dieselbe Neuplanung gerade auf einem zweiten Geraet):
            # Stand nur lesend zeigen statt Fehler 500; das Umplanen holt der naechste Aufruf nach (Lasttest 12.11.2026)
            if "locked" not in str(e):
                raise
            out = overview(conn, auto=False, readonly=True)
            out["busy"] = True
            return out
        return overview(conn)


@router.get("/api/goals/settings")
def api_goal_settings():
    with db.cursor() as conn:
        return public_settings(settings(conn))


@router.put("/api/goals/settings")
def api_goal_settings_put(body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return public_settings(save_settings(conn, body))


@router.post("/api/goals/plan")
def api_goal_plan(body: dict = Body(default={})):
    with db.cursor() as conn:
        _tx(conn)
        return plan_now(conn, body)


@router.post("/api/goals/plan/keep")
def api_goal_plan_keep():
    with db.cursor() as conn:
        _tx(conn)
        return keep_plan(conn)


@router.put("/api/goals/{module_id}")
def api_goal_put(module_id: int, body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return save_goal(conn, module_id, body)


@router.delete("/api/goals/{module_id}")
def api_goal_delete(module_id: int):
    with db.cursor() as conn:
        _tx(conn)
        delete_goal(conn, module_id)
    return {"ok": True}


@router.post("/api/goals/blocks/{package_id}/done")
def api_block_done(package_id: int, body: dict = Body(default={})):
    with db.cursor() as conn:
        _tx(conn)
        return block_done(conn, package_id, body)


@router.post("/api/goals/blocks/{package_id}/undone")
def api_block_undone(package_id: int):
    with db.cursor() as conn:
        _tx(conn)
        return block_undone(conn, package_id)


@router.patch("/api/goals/blocks/{package_id}")
def api_block_lock(package_id: int, body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return set_locked(conn, package_id, body)


@router.post("/api/goals/blocks/{package_id}/check")
def api_block_check(package_id: int, body: dict = Body(default={})):
    with db.cursor() as conn:
        return check_slot(conn, package_id, body)


@router.get("/api/sessions")
def api_sessions(module_id: int | None = None, start: str | None = None, end: str | None = None):
    with db.cursor() as conn:
        return {"items": list_sessions(conn, module_id, _check_date(start, "start"), _check_date(end, "end"))}


@router.post("/api/sessions")
def api_session_add(body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return add_session(conn, body)


@router.post("/api/sessions/start")
def api_session_start(body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return start_session(conn, body)


@router.post("/api/sessions/{uid}/pause")
def api_session_pause(uid: str):
    with db.cursor() as conn:
        _tx(conn)
        return pause_session(conn, uid)


@router.post("/api/sessions/{uid}/resume")
def api_session_resume(uid: str):
    with db.cursor() as conn:
        _tx(conn)
        return resume_session(conn, uid)


@router.post("/api/sessions/{uid}/stop")
def api_session_stop(uid: str):
    with db.cursor() as conn:
        _tx(conn)
        return stop_session(conn, uid)


@router.patch("/api/sessions/{uid}")
def api_session_patch(uid: str, body: dict = Body(...)):
    with db.cursor() as conn:
        _tx(conn)
        return correct_session(conn, uid, body)


@router.delete("/api/sessions/{uid}")
def api_session_delete(uid: str):
    with db.cursor() as conn:
        _tx(conn)
        delete_session(conn, uid)
    return {"ok": True}
