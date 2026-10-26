"""Stundenplan: Veranstaltungsserien, Ausnahmen, Teilnahme, freie Zeitfenster und Import.

Zeiten werden als "HH:MM" gespeichert, intern als Minuten seit Mitternacht gerechnet.
"""
from __future__ import annotations

import difflib
import json
import re
from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone

from . import db

WEEKDAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
KIND_WORDS = {"uebung": ["übung", "uebung", "ü:", "exercise", "tutorium", "gruppenübung", "zentralübung"], "labor": ["labor", "praktikum", "lab"], "seminar": ["seminar"]}
# TZID-Werte, die UTC bedeuten (ohne Zeitzonendatenbank erkannt, unter Windows fehlt sie ohne tzdata)
UTC_TZIDS = {"UTC", "ETC/UTC", "GMT", "ETC/GMT", "Z", "UNIVERSAL", "ETC/UNIVERSAL", "ZULU", "ETC/ZULU", "UCT", "ETC/UCT"}


def hm(t: str) -> int:
    h, m = (int(x) for x in str(t or "00:00").split(":")[:2])
    return h * 60 + m


def mh(m: int) -> str:
    m = max(0, int(m))
    return f"{m // 60:02d}:{m % 60:02d}"


def term(conn) -> dict:
    t = db.row(conn, "SELECT * FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")
    return t or {"name": "Semester", "start": "2026-10-12", "end": "2027-01-30"}


# ----------------------------------------------------------------------------
# Vorkommen (Occurrences)
# ----------------------------------------------------------------------------

UNI_KINDS = {"vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar"}


def occurrences(conn, start: date, end: date, include_skipped: bool = True) -> list[dict]:
    """Alle Termine im Zeitraum, mit Ausnahmen (verschoben, ausgefallen, nicht besucht) angewendet."""
    events = db.rows(conn, "SELECT e.*, m.name AS module_name, m.color AS module_color FROM course_events e LEFT JOIN modules m ON m.id=e.module_id")
    if not events:
        return []
    ids = [e["id"] for e in events]
    exc = defaultdict(dict)
    for x in db.rows(conn, f"SELECT * FROM event_exceptions WHERE event_id IN ({','.join('?' * len(ids))})", ids):
        exc[x["event_id"]][x["date"]] = x
    t = term(conn)
    # Serien ohne eigene Daten (z. B. persoenliche Stud.IP-Stundenplan-Eintraege) kennen weder Ferien noch Feiertage:
    # an Feiertagen, in Unterbrechungen und in der vorlesungsfreien Zeit fallen Uni-Veranstaltungen aus (app/holidays.py).
    # Serien mit Daten aus der Quelle (LSF-EXDATE, Stud.IP-Einzeltermine) regeln das selbst; persoenliche Termine nie.
    from . import config, holidays
    free = holidays.day_marks(start, end, config.university())
    notes = {r["event_id"]: r["note"] for r in db.rows(conn, "SELECT event_id, note FROM event_notes")}
    out = []
    d = start
    while d <= end:
        di = d.isoformat()
        for e in events:
            if not _matches(e, d, t):
                continue
            x = exc[e["id"]].get(di)
            occ = {"event_id": e["id"], "date": di, "start": e["start_time"], "end": e["end_time"], "title": e["title"], "kind": e["kind"],
                   "module_id": e["module_id"], "module_name": e["module_name"], "color": e["color"] or e["module_color"] or "#4f5bd5", "room": e["room"],
                   "lecturer": e["lecturer"], "course_id": e["course_id"], "status": "teilnahme" if e["attend"] else "nicht_teilnahme", "permanent_skip": not e["attend"], "exception": None}
            if notes.get(e["id"]):
                occ["note"] = notes[e["id"]]          # nur mit Bemerkung (Antwortform sonst unveraendert)
            if x:
                occ["exception"] = x["type"]
                if x["type"] == "skip":
                    occ["status"] = "nicht_teilnahme"
                elif x["type"] == "attend":
                    occ["status"] = "teilnahme"
                elif x["type"] == "cancelled":
                    occ["status"] = "ausfall"
                elif x["type"] in ("moved", "edit"):
                    occ["start"] = x["new_start"] or occ["start"]
                    occ["end"] = x["new_end"] or occ["end"]
                    if x["type"] == "moved" and x["new_date"] and x["new_date"] != di:
                        occ["moved_to"] = x["new_date"]
                        occ["status"] = "verschoben"
            if (not x and e["attend"] and di in free and not e["date_from"] and not e["date_to"]
                    and (e["kind"] or "vorlesung") in UNI_KINDS):
                occ["status"], occ["exception"] = "ausfall", "vorlesungsfrei"
                occ["note"] = " / ".join(dict.fromkeys(m["label"] for m in free[di])) + (f" · {notes[e['id']]}" if notes.get(e["id"]) else "")
            if occ["status"] == "nicht_teilnahme" and not include_skipped:
                continue
            out.append(occ)
        # Hierher verschobene Termine anderer Tage
        for x in db.rows(conn, "SELECT x.*, e.* , x.id AS xid FROM event_exceptions x JOIN course_events e ON e.id=x.event_id WHERE x.type='moved' AND x.new_date=? AND x.date!=?", (di, di)):
            m = db.row(conn, "SELECT name, color FROM modules WHERE id=?", (x["module_id"],)) if x["module_id"] else None
            out.append({"event_id": x["event_id"], "date": di, "start": x["new_start"] or x["start_time"], "end": x["new_end"] or x["end_time"], "title": x["title"], "kind": x["kind"],
                        "module_id": x["module_id"], "module_name": m["name"] if m else None, "color": x["color"] or (m["color"] if m else None) or "#4f5bd5", "room": x["room"], "lecturer": x["lecturer"],
                        "course_id": x["course_id"], "status": "teilnahme", "permanent_skip": False, "exception": "moved_here", "moved_from": x["date"]})
        d += timedelta(days=1)
    out.sort(key=lambda o: (o["date"], o["start"]))
    return out


def _matches(e: dict, d: date, t: dict) -> bool:
    df = e["date_from"] or t["start"]
    dt = e["date_to"] or t["end"]
    if not (df <= d.isoformat() <= dt):
        return False
    if e["rrule"] == "once":
        return d.isoformat() == (e["date_from"] or "")
    if d.weekday() != e["weekday"]:
        return False
    if e["rrule"] == "biweekly":
        weeks = (d - date.fromisoformat(df)).days // 7
        return weeks % 2 == 0
    return True


# ----------------------------------------------------------------------------
# Freie Zeitfenster
# ----------------------------------------------------------------------------

def busy_blocks(conn, d: date, settings: dict, include_packages: bool = True) -> list[dict]:
    """Belegte Bloecke eines Tages (Hochschultermine mit Teilnahme, Sperrzeiten, bereits geplante Lernslots)."""
    blocks = []
    for o in occurrences(conn, d, d):
        if o["status"] == "teilnahme":
            blocks.append({"start": hm(o["start"]), "end": hm(o["end"]), "kind": "event", "title": o["title"], "campus": True})
    for b in settings.get("blocked_times", []):
        if int(b.get("weekday", -1)) == d.weekday():
            blocks.append({"start": hm(b["start"]), "end": hm(b["end"]), "kind": "blocked", "title": b.get("title") or "Sperrzeit", "campus": False})
    if include_packages:
        for p in db.rows(conn, "SELECT start_time, end_time, subject FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status NOT IN ('verschoben','uebersprungen')", (d.isoformat(),)):
            blocks.append({"start": hm(p["start_time"]), "end": hm(p["end_time"]), "kind": "study", "title": p["subject"], "campus": False})
    return sorted(blocks, key=lambda b: b["start"])


def free_windows(conn, d: date, settings: dict | None = None, include_packages: bool = True) -> list[dict]:
    """Freie Fenster zwischen Lernbeginn und Lernende, abzueglich Termine, Sperrzeiten, Fahrtzeit und Lernslots."""
    s = settings or db.get_settings(conn)
    lo, hi = hm(s["learn_start"]), hm(s["learn_end"])
    blocks = busy_blocks(conn, d, s, include_packages)
    travel = s["travel_minutes"]
    campus = [b for b in blocks if b["kind"] == "event"]
    # Fahrtzeit: vor dem ersten und nach dem letzten Campus-Termin
    if campus:
        first, last = campus[0], campus[-1]
        blocks.append({"start": first["start"] - travel, "end": first["start"], "kind": "travel", "title": "Fahrt zur Uni", "campus": False})
        blocks.append({"start": last["end"], "end": last["end"] + travel, "kind": "travel", "title": "Heimfahrt", "campus": False})
    blocks.sort(key=lambda b: b["start"])
    windows, cur = [], lo
    for b in blocks:
        if b["end"] <= cur:
            continue
        if b["start"] > cur:
            windows.append({"start": cur, "end": min(b["start"], hi)})
        cur = max(cur, b["end"])
        if cur >= hi:
            break
    if cur < hi:
        windows.append({"start": cur, "end": hi})
    out = []
    for w in windows:
        if w["end"] - w["start"] >= s["min_slot_minutes"]:
            on_campus = any(c["end"] <= w["start"] for c in campus) and any(c["start"] >= w["end"] for c in campus)
            out.append({"start": w["start"], "end": w["end"], "minutes": w["end"] - w["start"], "start_hm": mh(w["start"]), "end_hm": mh(w["end"]), "campus": on_campus})
    return out


def day_timeline(conn, d: date) -> dict:
    s = db.get_settings(conn)
    occ = occurrences(conn, d, d)
    pk = db.rows(conn, "SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date=? ORDER BY p.start_time, p.id", (d.isoformat(),))
    return {"date": d.isoformat(), "events": occ, "packages": pk, "free": free_windows(conn, d, s), "blocked": [b for b in s["blocked_times"] if int(b.get("weekday", -1)) == d.weekday()],
            "learn_start": s["learn_start"], "learn_end": s["learn_end"]}


# ----------------------------------------------------------------------------
# Ausnahmen / Teilnahme
# ----------------------------------------------------------------------------

def set_exception(conn, event_id: int, d: str, typ: str, new_date: str | None = None, new_start: str | None = None, new_end: str | None = None, note: str = "") -> None:
    conn.execute("DELETE FROM event_exceptions WHERE event_id=? AND date=?", (event_id, d))
    if typ != "reset":
        conn.execute("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,?,?,?,?,?,?)",
                     (event_id, d, typ, new_date, new_start, new_end, note, db.now_iso()))


def set_attendance(conn, event_id: int, d: str, mode: str) -> None:
    """mode: today_skip | today_attend | permanent_skip | permanent_attend | cancelled | reset"""
    if mode == "permanent_skip":
        conn.execute("UPDATE course_events SET attend=0 WHERE id=?", (event_id,))
        conn.execute("DELETE FROM event_exceptions WHERE event_id=? AND date>=? AND type IN ('skip','attend')", (event_id, d))
    elif mode == "permanent_attend":
        conn.execute("UPDATE course_events SET attend=1 WHERE id=?", (event_id,))
        conn.execute("DELETE FROM event_exceptions WHERE event_id=? AND date>=? AND type IN ('skip','attend')", (event_id, d))
    elif mode == "today_skip":
        set_exception(conn, event_id, d, "skip")
    elif mode == "today_attend":
        set_exception(conn, event_id, d, "attend")
    elif mode == "cancelled":
        set_exception(conn, event_id, d, "cancelled")
    elif mode == "reset":
        set_exception(conn, event_id, d, "reset")


def materials_for_event(conn, event: dict, d: date) -> list[dict]:
    """Passende Unterlagen zum Termin: Dateien des Moduls aus derselben Semesterwoche, sonst die neuesten."""
    if not event.get("module_id"):
        return []
    from . import study
    start = study.semester_start(conn)
    files = study._file_rows(conn, event["module_id"])
    # Woche des Termins nach derselben Regel wie die der Dateien (study.week_index): vor dem Vorlesungsbeginn Woche
    # 0, vor dem Stichtag -1. Ohne Begrenzung fand ein Termin zwischen Stichtag und Vorlesungsbeginn (Woche -1, -2,
    # ...) die Unterlagen seiner Woche (0) nie, bei -1 stattdessen die des aelteren Semesters.
    w = study.day_week(start, d)
    same = [f for f in files if study.week_index(start, f["chdate"]) == w and f.get("doc_type") in ("vorlesung", "uebung", "skript", "loesung")]
    if not same:
        same = [f for f in files if f.get("doc_type") in ("vorlesung", "uebung")][-4:]
    return same[:8]


# ----------------------------------------------------------------------------
# Import
# ----------------------------------------------------------------------------

def guess_kind(title: str) -> str:
    t = (title or "").lower()
    for k, words in KIND_WORDS.items():
        if any(w in t for w in words):
            return k
    return "vorlesung"


def guess_module(conn, title: str) -> int | None:
    mods = db.rows(conn, "SELECT id, name FROM modules")
    courses = db.rows(conn, "SELECT module_id, title FROM courses WHERE module_id IS NOT NULL")
    t = (title or "").lower()
    best, score = None, 0.0
    for m in mods:
        n = m["name"].lower()
        sc = difflib.SequenceMatcher(None, t, n).ratio()
        if n in t or t in n:
            sc = max(sc, 0.9)
        # Kurztitel wie "Mathe I", "DuA", "GDS", "ET"
        toks = [x for x in re.findall(r"[a-zäöü0-9]+", n) if len(x) > 2]
        hit = sum(1 for x in toks if x in t)
        if toks and hit / len(toks) >= 0.5:
            sc = max(sc, 0.6 + 0.4 * hit / len(toks))
        if sc > score:
            best, score = m["id"], sc
    for c in courses:
        n = c["title"].lower()
        sc = difflib.SequenceMatcher(None, t, n).ratio()
        if n in t or t in n:
            sc = max(sc, 0.9)
        if sc > score:
            best, score = c["module_id"], sc
    return best if score >= 0.55 else None


def parse_ics(text: str) -> list[dict]:
    """Minimaler ICS-Parser: VEVENT mit DTSTART/DTEND/SUMMARY/LOCATION/RRULE."""
    lines = []
    for ln in text.replace("\r\n", "\n").split("\n"):
        if ln.startswith((" ", "\t")) and lines:
            lines[-1] += ln[1:]
        else:
            lines.append(ln)
    events, cur = [], None
    for ln in lines:
        if ln.startswith("BEGIN:VEVENT"):
            cur = {}
        elif ln.startswith("END:VEVENT") and cur is not None:
            events.append(cur)
            cur = None
        elif cur is not None and ":" in ln:
            k, v = ln.split(":", 1)
            key = k.split(";")[0].upper()
            cur[key] = v.strip()
            if key in ("DTSTART", "DTEND"):
                cur[key + "_PARAMS"] = k
            elif key == "EXDATE":
                # mehrere EXDATE-Zeilen moeglich, jede mit eigener TZID
                cur.setdefault("EXDATE_LIST", []).append((v.strip(), k))
    out = []
    for ev in events:
        try:
            st = _ics_dt(ev.get("DTSTART", ""), ev.get("DTSTART_PARAMS", ""))
            en = _ics_dt(ev.get("DTEND", ""), ev.get("DTEND_PARAMS", "")) if ev.get("DTEND") else st + timedelta(minutes=90)
        except ValueError:
            continue
        rr = ev.get("RRULE", "")
        weekly = "FREQ=WEEKLY" in rr
        interval = re.search(r"INTERVAL=(\d+)", rr)
        title = ev.get("SUMMARY", "Veranstaltung").replace("\\,", ",")
        # BYDAY bestimmt den Wochentag; DTSTART ist z. B. im LSF der Semesterbeginn (Montag), auch fuer Donnerstags-Kurse
        byday = re.search(r"BYDAY=([A-Z,0-9+-]+)", rr) if weekly else None
        days = [ICS_DAYS[d[-2:]] for d in byday.group(1).split(",") if d[-2:] in ICS_DAYS] if byday else []
        exd = _ics_exdates(ev.get("EXDATE_LIST", []))
        until = _ics_until(rr, st)
        for wd in days or [st.weekday()]:
            first = st.date() + timedelta(days=(wd - st.weekday()) % 7)
            out.append({"title": title, "kind": guess_kind(title), "weekday": wd, "start_time": st.strftime("%H:%M"), "end_time": en.strftime("%H:%M"),
                        "room": (ev.get("LOCATION") or "").replace("\\,", ","), "rrule": ("biweekly" if interval and interval.group(1) == "2" else "weekly") if weekly else "once",
                        "date_from": first.isoformat(), "date_to": until, "uncertain": False,
                        # mehrere BYDAY: jede Serie bekommt nur die Ausfaelle an ihrem Wochentag
                        "exdates": [d for d in exd if not days or date.fromisoformat(d).weekday() == wd],
                        "uid": ev.get("UID"), "description": (ev.get("DESCRIPTION") or "").replace("\\n", "\n").replace("\\,", ",")})
    return out


ICS_DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def _ics_dt(v: str, params: str = "") -> datetime:
    """Zeitpunkt aus DTSTART/DTEND/EXDATE als Ortszeit Europe/Berlin (ohne Zone). "...Z" ist UTC, TZID=... eine
    Zeitzone: UTC-Namen und Europe/Berlin ohne Datenbank, andere ueber zoneinfo; unbekannte (z. B. Windows-Namen
    wie "W. Europe Standard Time") und Zeiten ohne Angabe gelten als Berliner Zeit. Reine Daten beginnen um 00:00."""
    v = v.strip()
    if "T" in v:
        dt = datetime.strptime(v[:15], "%Y%m%dT%H%M%S")
        if v[15:16].upper() == "Z":
            return _berlin_from_utc(dt)
        tz = _tzid(params)
        if tz and tz.upper() in UTC_TZIDS:
            return _berlin_from_utc(dt)
        if tz and tz != "Europe/Berlin":
            try:
                from zoneinfo import ZoneInfo
                return _berlin_from_utc(dt.replace(tzinfo=ZoneInfo(tz)).astimezone(timezone.utc).replace(tzinfo=None))
            except Exception:  # noqa: BLE001 - unbekannte Zone oder keine Zeitzonendatenbank: Berliner Zeit
                pass
        return dt
    return datetime.strptime(v[:8], "%Y%m%d")


def _tzid(params: str) -> str | None:
    """TZID aus den Parametern einer Zeile ("DTSTART;TZID=Europe/Berlin"), ohne Anfuehrungszeichen."""
    for p in params.split(";")[1:]:
        if p.upper().startswith("TZID="):
            return p[5:].strip().strip('"') or None
    return None


def _last_sunday(year: int, month: int) -> date:
    last = (date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)) - timedelta(days=1)
    return last - timedelta(days=(last.weekday() - 6) % 7)


def _berlin_from_utc(u: datetime) -> datetime:
    """UTC (ohne Zone) -> Ortszeit Europe/Berlin (ohne Zone), EU-Regel seit 1996 wie BerlinClock in der App:
    Sommerzeit vom letzten Sonntag im Maerz bis zum letzten Sonntag im Oktober, jeweils ab 01:00 UTC."""
    begin = datetime.combine(_last_sunday(u.year, 3), time(1))
    end = datetime.combine(_last_sunday(u.year, 10), time(1))
    return u + timedelta(hours=2 if begin <= u < end else 1)


def _ics_until(rrule: str, start: datetime) -> str | None:
    """Letzter Tag aus RRULE UNTIL (Ortszeit Berlin). Liegt UNTIL mit Uhrzeit vor dem Beginn des Termins
    (z. B. 23:59:59Z = 00:59 Uhr am Folgetag), zaehlt der Vortag; Mitternacht und reine Daten zaehlen ganz."""
    m = re.search(r"UNTIL=(\d{8})(T\d{6}Z?)?", rrule)
    if not m:
        return None
    day = f"{m.group(1)[:4]}-{m.group(1)[4:6]}-{m.group(1)[6:]}"
    if not m.group(2):
        return day
    try:
        u = _ics_dt(m.group(1) + m.group(2))
    except ValueError:
        return day
    minutes = u.hour * 60 + u.minute
    last = u.date()
    if minutes != 0 and minutes < start.hour * 60 + start.minute:
        last -= timedelta(days=1)
    return last.isoformat()


def _ics_exdates(items: list[tuple[str, str]]) -> list[str]:
    """Ausfaelle (EXDATE, auch mehrere Werte je Zeile) als ISO-Daten in Ortszeit Berlin, sortiert."""
    out = set()
    for value, params in items:
        for part in value.split(","):
            if part.strip():
                try:
                    out.add(_ics_dt(part, params).date().isoformat())
                except ValueError:
                    continue
    return sorted(out)


def merge_weekly(entries: list[dict]) -> list[dict]:
    """Viele Einzeltermine (z. B. aus Stud.IP oder ICS ohne RRULE) zu woechentlichen Serien zusammenfassen.

    Wochen ohne Termin innerhalb der Serie (Weihnachtspause, Feiertage, einzelne Ausfaelle) kommen als `exdates`
    mit: Stud.IP legt an vorlesungsfreien Tagen keine Termine an, die Serie wuerde die Luecke sonst wieder mit
    Vorlesungen fuellen (Befund 26.10.2026: LUH 23.12.-05.01. ohne Termine, im Kalender aber belegt).
    Alle 14 Tage: alle Abstaende sind Vielfache von 14 (auch mit einer Luecke von 28 Tagen ueber Weihnachten)."""
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for e in entries:
        groups[(e["title"], e["weekday"], e["start_time"], e["end_time"])].append(e)
    out = []
    for (title, wd, st, en), lst in groups.items():
        dates = sorted({x["date_from"] for x in lst if x.get("date_from")})
        if len(lst) >= 3 and len(dates) >= 2:
            days = [date.fromisoformat(d) for d in dates]
            gaps = [(b - a).days for a, b in zip(days, days[1:])]
            step = 14 if all(g % 14 == 0 for g in gaps) else 7
            missing, d = [], days[0]
            while d <= days[-1]:
                if d.isoformat() not in dates:
                    missing.append(d.isoformat())
                d += timedelta(days=step)
            out.append({**lst[0], "rrule": "biweekly" if step == 14 else "weekly", "date_from": dates[0], "date_to": dates[-1],
                        "count": len(lst), **({"exdates": missing} if missing else {})})   # Feld nur bei Luecken
        else:
            out.extend(lst)
    return out


def studip_entries(conn) -> list[dict]:
    rows = db.rows(conn, """SELECT s.*, c.title AS course_title, c.module_id, c.kind AS course_kind FROM studip_events s JOIN courses c ON c.id=s.course_id
                            WHERE c.active=1 AND c.kind != 'sonstiges' ORDER BY s.start""")
    entries = []
    for r in rows:
        try:
            st = datetime.fromisoformat(r["start"]); en = datetime.fromisoformat(r["end"])
        except (ValueError, TypeError):
            continue
        title = r["course_title"]
        entries.append({"title": title, "kind": "uebung" if r["course_kind"] == "uebung" else guess_kind(title), "weekday": st.weekday(), "start_time": st.strftime("%H:%M"), "end_time": en.strftime("%H:%M"),
                        "room": r["room"] or "", "rrule": "once", "date_from": st.date().isoformat(), "date_to": st.date().isoformat(), "module_id": r["module_id"], "course_id": r["course_id"], "uncertain": False})
    merged = merge_weekly(entries)
    # Uebungen mit vielen parallelen Gruppenterminen: nur eine Gruppe wird besucht -> Auswahl noetig
    per_course = defaultdict(int)
    for e in merged:
        per_course[e["course_id"]] += 1
    for e in merged:
        e["group_slots"] = per_course[e["course_id"]]
        e["selected"] = per_course[e["course_id"]] <= 2
        e["uncertain"] = per_course[e["course_id"]] > 2
        if per_course[e["course_id"]] > 2:
            e["hint"] = f"{per_course[e['course_id']]} parallele Gruppen – nur deine Gruppe auswählen"
    # Persoenliche Eintraege aus dem Stud.IP-Stundenplan (z. B. die gewaehlte Uebungsgruppe)
    for r in db.rows(conn, "SELECT * FROM studip_schedule_entries"):
        title = r["title"] or "Termin"
        biweekly = bool(re.search(r"alle 2 Wochen|zweiw[öo]chentlich|14-?t[äa]g", (title + " " + (r["description"] or "")), re.I))
        merged.append({"title": title, "kind": guess_kind(title), "weekday": int(r["weekday"]), "start_time": r["start"], "end_time": r["end"], "room": "",
                       "rrule": "biweekly" if biweekly else "weekly", "date_from": None, "date_to": None, "module_id": guess_module(conn, title), "course_id": None,
                       "uncertain": False, "selected": True, "group_slots": 1, "personal": True, "hint": "persönlicher Eintrag aus deinem Stud.IP-Stundenplan"})
    merged.sort(key=lambda e: (e["weekday"], e["start_time"]))
    return merged


def auto_import(conn) -> dict:
    """Uebernimmt automatisch alle eindeutigen Stud.IP-Termine (Vorlesungen, Kurse mit hoechstens zwei Terminen,
    persoenliche Stundenplan-Eintraege). Parallele Uebungsgruppen bleiben der manuellen Auswahl vorbehalten.
    Zuerst ensure_modules: run_sync ruft auto_import direkt nach dem Speichern neuer Kurse auf, deren Modul sonst erst
    die naechste Seite anlegt. Ohne Modul blieben die neuen Termine dauerhaft ohne module_id (ein spaeterer Abgleich
    uebernimmt nur neue Termine) und ohne Unterlagen zum Termin (Korrektur vom 26.10.2026)."""
    from . import study
    study.ensure_modules(conn)
    entries = enrich(conn, [e for e in studip_entries(conn) if e.get("selected")])
    diff = diff_against_existing(conn, entries)
    res = apply_import(conn, diff["new"], "studip")
    # Bestehende Stud.IP-Serien bekommen fehlende Ausfaelle nachgetragen (Luecken wie die Weihnachtspause); nur Serien
    # aus Stud.IP, nie manuell angelegte; Tage mit eigener Ausnahme des Nutzers bleiben unveraendert.
    # Zuordnung genau ueber Kurs, Wochentag und Uhrzeit (diff_against_existing unterscheidet zwei Serien desselben
    # Kurses am selben Wochentag nicht, z. B. 09:00 und 15:00).
    for e in entries:
        if not e.get("exdates"):
            continue
        for ev in db.rows(conn, """SELECT id FROM course_events WHERE source LIKE 'studip%' AND weekday=? AND start_time=? AND end_time=?
                                   AND (course_id=? OR (course_id IS NULL AND title=?))""",
                          (int(e["weekday"]), e["start_time"], e["end_time"], e.get("course_id"), e["title"])):
            _add_cancellations(conn, ev["id"], e["exdates"], "Ausfall laut Stud.IP")
    conn.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES ('studip-auto', ?, 'auto', '', ?, 1)",
                 (db.now_iso(), json.dumps(diff["new"], ensure_ascii=False)))
    return {"new": res["new"], "pending_groups": len([e for e in studip_entries(conn) if not e.get("selected")])}


def ai_parse(conn, text: str = "", image_path: str | None = None) -> list[dict]:
    from . import ai
    t = term(conn)
    mods = ", ".join(m["name"] for m in db.rows(conn, "SELECT name FROM modules"))
    instr = f"""Extrahiere aus dem Stundenplan alle Lehrveranstaltungen. Semester: {t['name']} ({t['start']} bis {t['end']}).
Meine Module heißen: {mods}.
Antworte NUR mit JSON: [{{"title": "...", "kind": "vorlesung|uebung|tutorium|labor|seminar|sonstiges", "weekday": 0-6 (0=Montag),
"start_time": "HH:MM", "end_time": "HH:MM", "room": "...", "lecturer": "...", "rrule": "weekly|biweekly|once", "uncertain": true/false}}]
Erfinde keine Veranstaltungen und keine Uhrzeiten. Wenn etwas unleserlich oder unsicher ist, setze "uncertain": true."""
    if image_path:
        prompt = f"Lies die Bilddatei {image_path} (Stundenplan als Screenshot/Foto) mit dem Read-Werkzeug.\n{instr}"
        raw = ai.ask(prompt, "Du bist ein praeziser Datenextraktor. Antworte ausschliesslich mit JSON.", allowed_tools=["Read"])
    else:
        prompt = f"{instr}\n\nSTUNDENPLAN-TEXT:\n<<<\n{text[:12000]}\n>>>"
        raw = ai.ask(prompt, "Du bist ein praeziser Datenextraktor. Antworte ausschliesslich mit JSON.")
    data = ai.parse_json(raw)
    out = []
    for e in data if isinstance(data, list) else []:
        try:
            out.append({"title": str(e.get("title") or "Veranstaltung"), "kind": e.get("kind") or guess_kind(e.get("title", "")), "weekday": int(e.get("weekday", 0)) % 7,
                        "start_time": mh(hm(e.get("start_time", "08:00"))), "end_time": mh(hm(e.get("end_time", "09:30"))), "room": e.get("room") or "", "lecturer": e.get("lecturer") or "",
                        "rrule": e.get("rrule") if e.get("rrule") in ("weekly", "biweekly", "once") else "weekly", "date_from": None, "date_to": None, "uncertain": bool(e.get("uncertain"))})
        except (ValueError, TypeError):
            continue
    return out


def enrich(conn, entries: list[dict]) -> list[dict]:
    for e in entries:
        if not e.get("module_id"):
            e["module_id"] = guess_module(conn, e["title"])
        e["module_guess_uncertain"] = e.get("module_id") is None
    return entries


def diff_against_existing(conn, entries: list[dict]) -> dict:
    """Vergleicht Importvorschau mit vorhandenen Serien: neu / geaendert / unveraendert / entfernt."""
    existing = db.rows(conn, "SELECT * FROM course_events WHERE source != 'personal'")
    key = lambda e: (re.sub(r"\W+", "", (e["title"] or "").lower())[:30], int(e["weekday"]))
    ex_map = {key(e): e for e in existing}
    new, changed, same, seen = [], [], [], set()
    for e in entries:
        k = key(e)
        seen.add(k)
        if k in ex_map:
            x = ex_map[k]
            if x["start_time"] != e["start_time"] or x["end_time"] != e["end_time"]:
                changed.append({**e, "old_start": x["start_time"], "old_end": x["end_time"], "existing_id": x["id"]})
            else:
                same.append({**e, "existing_id": x["id"]})
        else:
            new.append(e)
    removed = [x for k, x in ex_map.items() if k not in seen]
    return {"new": new, "changed": changed, "same": same, "removed": removed}


def apply_import(conn, entries: list[dict], source: str, remove_ids: list[int] | None = None) -> dict:
    n_new = n_upd = 0
    new_ids: list[int] = []
    note = "Ausfall laut Stud.IP" if str(source).startswith("studip") else "Ausfall laut Kalender"
    for e in entries:
        if e.get("existing_id"):
            conn.execute("UPDATE course_events SET start_time=?, end_time=?, room=COALESCE(NULLIF(?,''), room), kind=?, module_id=COALESCE(?, module_id) WHERE id=?",
                         (e["start_time"], e["end_time"], e.get("room") or "", e.get("kind") or "vorlesung", e.get("module_id"), e["existing_id"]))
            event_id = e["existing_id"]
            _drop_stale_cancellations(conn, event_id, e.get("exdates"), note)
            n_upd += 1
        else:
            cur = conn.execute("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)""",
                         (e.get("module_id"), e.get("course_id"), e["title"], e.get("kind") or "vorlesung", int(e["weekday"]), e["start_time"], e["end_time"], e.get("room") or "", e.get("lecturer") or "",
                          e.get("rrule") or "weekly", e.get("date_from"), e.get("date_to"), source, db.now_iso()))
            event_id = cur.lastrowid
            new_ids.append(event_id)
            n_new += 1
        _add_cancellations(conn, event_id, e.get("exdates"), note)
    for rid in remove_ids or []:
        conn.execute("DELETE FROM event_notes WHERE event_id=?", (rid,))
        conn.execute("DELETE FROM course_events WHERE id=?", (rid,))
    return {"new": n_new, "updated": n_upd, "removed": len(remove_ids or []), "ids": new_ids}


def _add_cancellations(conn, event_id, dates, note: str) -> None:
    """Ausfaelle einer Serie (EXDATE aus Kalenderdateien, EXDATES der Stud.IP-Kurszeiten) als Ausnahme "cancelled".
    Tage mit vorhandener Ausnahme (z. B. vom Nutzer verschoben) bleiben unveraendert."""
    if not isinstance(dates, list) or not db.row(conn, "SELECT 1 FROM course_events WHERE id=?", (event_id,)):
        return
    for d in dates:
        if not (isinstance(d, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", d)):
            continue
        if db.row(conn, "SELECT 1 FROM event_exceptions WHERE event_id=? AND date=?", (event_id, d)):
            continue
        conn.execute("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,'cancelled',NULL,NULL,NULL,?,?)",
                     (event_id, d, note, db.now_iso()))


def _drop_stale_cancellations(conn, event_id, dates, note: str) -> None:
    """Erneuter Import einer vorhandenen Serie: Ausfaelle derselben Quelle (gleiche Notiz), die die neue Fassung nicht
    mehr meldet, entfallen (Kalenderdatei ohne diesen EXDATE, andere Uebungsgruppe gewaehlt). Ausnahmen des Nutzers
    (andere Art oder Notiz) bleiben. Ohne Liste der Ausfaelle (KI, Stud.IP-Einzeltermine) aendert sich nichts."""
    if not isinstance(dates, list):
        return
    keep = {d for d in dates if isinstance(d, str)}
    for r in db.rows(conn, "SELECT id, date FROM event_exceptions WHERE event_id=? AND type='cancelled' AND note=? ORDER BY id", (event_id, note)):
        if r["date"] not in keep:
            conn.execute("DELETE FROM event_exceptions WHERE id=?", (r["id"],))


def week_grid(conn, start: date) -> dict:
    end = start + timedelta(days=6)
    occ = occurrences(conn, start, end)
    pk = db.rows(conn, "SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.start_time", (start.isoformat(), end.isoformat()))
    s = db.get_settings(conn)
    from . import holidays
    marks, dls = holidays.calendar_extras(conn, start, end)
    from . import announcements
    notes = announcements.by_day(conn, start, end)
    days = []
    d = start
    while d <= end:
        days.append({"date": d.isoformat(), "weekday": d.weekday(), "events": [o for o in occ if o["date"] == d.isoformat()], "packages": [p for p in pk if p["date"] == d.isoformat()],
                     "marks": marks.get(d.isoformat(), []), "deadlines": dls.get(d.isoformat(), []), "notices": notes.get(d.isoformat(), []),
                     "free": free_windows(conn, d, s), "blocked": [b for b in s["blocked_times"] if int(b.get("weekday", -1)) == d.weekday()]})
        d += timedelta(days=1)
    return {"start": start.isoformat(), "end": end.isoformat(), "days": days, "learn_start": s["learn_start"], "learn_end": s["learn_end"], "term": term(conn)}
