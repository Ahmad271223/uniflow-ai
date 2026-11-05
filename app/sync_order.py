"""Reihenfolge des Abgleichs: zuerst das aktuelle Semester (Wunsch des Inhabers 05.11.2026, docs/SYNC-REIHENFOLGE-2026-11-05.md).

Befund: Wer im 7. Semester ist, wartete beim ersten Abgleich, bis Dateien der Semester 1 bis 6 geladen waren, bevor
er sein Semester und seinen Stundenplan sah. Regel fuer jedes Portal (Stud.IP, Moodle/Learnweb, HISinOne/LSF/QIS),
beim ersten und bei jedem vollen Abgleich:

  (a) `current`   Stundenplan, Kurse/Module des aktuellen Semesters mit Dateien, Ankuendigungen, Pruefungsterminen
  (b) `grades`    Noten (QIS, LSF, HISinOne)
  (c) `upcoming`  naechstes Semester, falls das Portal es schon zeigt
  (d) `older`     fruehere Semester im Hintergrund: neuestes zuerst, gedrosselt, fortsetzbar, blockiert nie die
                  Oberflaeche; Einstellung "Ältere Semester laden: Automatisch / Nur WLAN / Aus"

Nach (a) zeigt die Oberflaeche das aktuelle Semester ("Aktuelles Semester ist da · ältere Semester werden im
Hintergrund geladen (3 von 6)"). Gleiche Regeln in der iPad-App: UniFlowCore/Sync/SyncOrder.swift.

Aktuelles Semester: Liste der Semester aus dem Portal mit Beginn und Ende (Stud.IP `semesters`, HISinOne/LSF
Semesterwechsel, Moodle-Kategorien "SoSe 2026"/"WiSe 2026/27") vor dem Datum; ohne Liste das Datum mit den
Semestergrenzen der Hochschule (LUH und Hildesheim: April/Oktober, HsH: Maerz/September).

Was nur zu diesem Geraet gehoert (Stand der Stufen), steht in `sync_stage_state` (erst bei Bedarf angelegt, nicht im
Geraete-Abgleich). Die Wahl fuer fruehere Semester liegt in app/older_semesters.py.
"""
from __future__ import annotations

import threading
import time
from datetime import date

from . import semesters

STAGES = ("current", "grades", "upcoming", "older")
STAGE_LABELS = {"current": "Aktuelles Semester", "grades": "Noten", "upcoming": "Nächstes Semester", "older": "Frühere Semester"}

# Semesterbeginn (Monat) je Hochschule: (Sommer, Winter). Ohne Eintrag gilt April/Oktober (app/semesters.py).
TERM_STARTS = {"luh": (4, 10), "hildesheim": (4, 10), "hsh": (3, 9)}

# Pause zwischen zwei Kursen frueherer Semester (Sekunden): schont Portal, Akku und Leitung
OLDER_PAUSE_S = 1.5

TABLE = """
CREATE TABLE IF NOT EXISTS sync_stage_state (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""


def _today() -> date:
    from . import study
    return study.today()


# --- Aktuelles Semester -------------------------------------------------------------------------------------------

def date_term(today: date, university: str | None = None) -> tuple[int, int]:
    """Semester nach dem Datum mit den Grenzen der Hochschule: LUH 1.4./1.10. ("WiSe 2026/27" ab Oktober), HsH 1.3./1.9."""
    summer, winter = TERM_STARTS.get(university or "", (4, 10))
    if summer <= today.month < winter:
        return (today.year, 1)
    return (today.year if today.month >= winter else today.year - 1, 2)


def term_key(term) -> tuple[int, int] | None:
    """Schluessel eines Semesters aus dem Portal: Text ("SoSe 2026", "WS 26/27"), LSF-Kennung ("20262" = WiSe
    2026/27, "20261" = SoSe 2026) oder ein Eintrag {"title"/"key"}."""
    if term is None:
        return None
    if isinstance(term, dict):
        if isinstance(term.get("key"), (list, tuple)) and len(term["key"]) == 2:
            return (int(term["key"][0]), int(term["key"][1]))
        return term_key(term.get("title") or term.get("name") or term.get("id"))
    if isinstance(term, (list, tuple)) and len(term) == 2:
        return (int(term[0]), int(term[1]))
    s = str(term).strip()
    if len(s) == 5 and s.isdigit() and s[4] in "12":
        return (int(s[:4]), int(s[4]))
    return semesters.key(s)


def current_term(today: date | None = None, terms=None, university: str | None = None) -> tuple[int, int]:
    """Aktuelles Semester. `terms`: Semesterliste des Portals, je Eintrag Titel oder Schluessel und, falls bekannt,
    `start`/`end` (ISO). 1. ein Semester, das heute laeuft (juengster Beginn gewinnt), 2. sonst das Datum mit den
    Grenzen der Hochschule. Ein Semester, das das Portal noch nicht kennt, wird nicht erfunden: liegt das Datum hinter
    dem neuesten bekannten Semester, bleibt es beim Datum (ein neues Semester ohne Kurse ist kein Fehler)."""
    d = today or _today()
    iso = d.isoformat()
    running = []
    for t in terms or []:
        if not isinstance(t, dict):
            continue
        k, start, end = term_key(t), (t.get("start") or "")[:10], (t.get("end") or "")[:10]
        if k and start and end and start <= iso <= end:
            running.append((start, k))
    if running:
        return max(running)[1]
    if university is None:
        try:
            from . import universities
            university = universities.current_key()
        except Exception:  # noqa: BLE001 - ohne Profil gilt April/Oktober
            university = None
    return date_term(d, university)


def course_term(c: dict) -> tuple[int, int] | None:
    """Semester eines Kurses: Startsemester (Stud.IP `start-semester`, Moodle-Kategorie), sonst das Ende."""
    return semesters.key(c.get("semester")) or semesters.key(c.get("semester_end"))


def portal_terms(courses: list[dict]) -> list[dict]:
    """Semesterliste aus den Kursen eines Portals (Stud.IP: `term` mit Beginn und Ende je Startsemester)."""
    out, seen = [], set()
    for c in courses:
        t = c.get("term")
        if isinstance(t, dict) and t.get("title") and t["title"] not in seen:
            seen.add(t["title"])
            out.append(t)
    return out


def split(courses: list[dict], active_ids: set[str], today: date | None = None, terms=None,
          university: str | None = None) -> dict[str, list[dict]]:
    """Kurse auf die Stufen verteilen: aus (Semesterregel, eigener Schalter) -> `older`; aktiv und spaeter als das
    aktuelle Semester -> `upcoming`; sonst `current` (auch ohne erkennbares Semester und noch laufende Kurse des
    Vorsemesters, z. B. in der Pruefungszeit). Reihenfolge innerhalb jeder Stufe wie geliefert, `older` neuestes zuerst."""
    cur = current_term(today, terms, university)
    out: dict[str, list[dict]] = {"current": [], "upcoming": [], "older": []}
    for c in courses:
        k = course_term(c)
        if c["id"] not in active_ids:
            out["older"].append(c)
        elif k is not None and k > cur:
            out["upcoming"].append(c)
        else:
            out["current"].append(c)
    out["older"] = newest_first(out["older"])
    return out


def newest_first(courses: list[dict]) -> list[dict]:
    """Kurse frueherer Semester: neuestes Semester zuerst, ohne erkennbares Semester zuletzt; sonst wie geliefert."""
    indexed = list(enumerate(courses))
    indexed.sort(key=lambda p: (course_term(p[1]) is None, tuple(-x for x in (course_term(p[1]) or (0, 0))), p[0]))
    return [c for _, c in indexed]


# --- Stufen ausfuehren --------------------------------------------------------------------------------------------

def run_stages(steps, log=None, on_stage=None) -> list[tuple[str, str, bool]]:
    """Schritte `(stufe, name, fn)` in der Reihenfolge der Stufen ausfuehren (innerhalb einer Stufe wie gegeben).
    Ein Fehler in einem Schritt haelt die uebrigen nicht an. `on_stage(stufe)` kommt, sobald alle Schritte einer
    Stufe durch sind (z. B. "aktuelles Semester ist da"). Rueckgabe: (stufe, name, ok) in Ausfuehrungsreihenfolge."""
    order = {s: i for i, s in enumerate(STAGES)}
    ordered = sorted(enumerate(steps), key=lambda p: (order.get(p[1][0], len(STAGES)), p[0]))
    done: list[tuple[str, str, bool]] = []
    for i, (_, (stage, name, fn)) in enumerate(ordered):
        ok = True
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - eine Stufe haelt die naechste nicht an
            ok = False
            if log:
                log(f"{STAGE_LABELS.get(stage, stage)} – {name}: {e}")
        done.append((stage, name, ok))
        last_of_stage = i + 1 == len(ordered) or ordered[i + 1][1][0] != stage
        if last_of_stage and on_stage:
            on_stage(stage)
    return done


# --- Stand je Geraet ----------------------------------------------------------------------------------------------

def _exists(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_stage_state'").fetchone() is not None


def get_state(conn, key: str) -> str | None:
    if not _exists(conn):
        return None
    r = conn.execute("SELECT value FROM sync_stage_state WHERE key=?", (key,)).fetchone()
    return r[0] if r else None


def set_state(conn, key: str, value: str | None) -> None:
    conn.executescript(TABLE)
    if value is None:
        conn.execute("DELETE FROM sync_stage_state WHERE key=?", (key,))
    else:
        conn.execute("INSERT OR REPLACE INTO sync_stage_state(key, value) VALUES (?, ?)", (key, value))


def mark_current_ready(conn, now: str) -> None:
    """Stufe (a) ist durch: die Oberflaeche zeigt das aktuelle Semester, auch wenn Spaeteres noch laeuft."""
    set_state(conn, "current_ready_at", now)


def set_older_running(conn, running: bool, paused: str | None = None) -> None:
    set_state(conn, "older_running", "1" if running else None)
    set_state(conn, "older_paused", paused)


# --- Fruehere Semester: Wahl, Bedingungen, Fortschritt ------------------------------------------------------------

def older_allowed(conn, *, low_power: bool = False, on_wifi: bool = True, app_open: bool = True) -> tuple[bool, str | None]:
    """Darf Stufe (d) jetzt laufen? Stromsparmodus -> Pause; "Nur WLAN" ohne WLAN -> Pause; am PC nur bei offener App
    (der geplante Lauf um 8 und 15 Uhr laedt keine frueheren Semester). Bei "Aus" holt Stufe (d) nur, was der Nutzer
    selbst vorgemerkt hat ("Dateien laden", `older_semesters.pending`). Rueckgabe: (ja/nein, Grund)."""
    from . import older_semesters
    mode = older_semesters.mode(conn)
    if not app_open:
        return False, "closed"
    if low_power:
        return False, "low_power"
    if mode == "wifi" and not on_wifi:
        return False, "wifi"
    return True, None


PAUSE_TEXT = {"low_power": "pausiert (Stromsparmodus)", "wifi": "warten auf WLAN", "closed": "laden weiter, sobald StudiNow offen ist",
              "user": "angehalten"}


def older_progress(conn, today: date | None = None) -> dict:
    """Stand der frueheren Semester in Semestern (nicht Kursen): `total` Semester mit Kursen, `done` Semester, deren
    Kurse alle geladen sind (Dateiliste und Dateien), `pending` Kurse, die die Stufe (d) noch holt."""
    from . import older_semesters
    courses = older_semesters.courses(conn, today)
    by_term: dict[str, list[dict]] = {}
    for c in courses:
        by_term.setdefault(c["label"], []).append(c)
    pending = older_semesters.pending(conn, today)
    done = sum(1 for cs in by_term.values() if all(c["loaded"] for c in cs))
    return {"total": len(by_term), "done": done, "pending": len(pending)}


def hint_text(current_ready: bool, mode: str, progress: dict, running: bool = False, paused: str | None = None) -> str | None:
    """Kurzer Hinweis fuer Module und Abgleich. None, wenn es nichts zu sagen gibt (alles geladen, keine frueheren)."""
    if not current_ready:
        return "Aktuelles Semester wird geladen …"
    total, done = progress.get("total", 0), progress.get("done", 0)
    if total == 0 or (not progress.get("pending") and not running):
        return None                                 # nichts mehr zu laden (oder "Aus": nur Vorgemerktes)
    if paused in PAUSE_TEXT:
        return f"Aktuelles Semester ist da · ältere Semester {PAUSE_TEXT[paused]} ({done} von {total})"
    return f"Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen ({done} von {total})"


def status(conn, today: date | None = None) -> dict:
    """`GET /api/sync-order`: Stand der Stufen fuer die Anzeige (gleiches Format in der iPad-App)."""
    from . import older_semesters
    d = today or _today()
    ready_at = get_state(conn, "current_ready_at")
    if ready_at is None:
        # Bestand von vor dem 05.11.2026: ein erfolgreicher Abgleich heisst, das aktuelle Semester ist da
        r = conn.execute("SELECT finished_at FROM sync_log WHERE ok=1 ORDER BY id DESC LIMIT 1").fetchone()
        ready_at = r[0] if r else None
    mode = older_semesters.mode(conn)
    prog = older_progress(conn, d)
    running = get_state(conn, "older_running") == "1"
    paused = get_state(conn, "older_paused")
    cur = current_term(d)
    return {"current": {"key": list(cur), "label": semesters.label(cur), "ready": ready_at is not None, "ready_at": ready_at},
            "older": {"mode": mode, "total": prog["total"], "done": prog["done"], "pending": prog["pending"],
                      "running": running, "paused": paused},
            "hint": hint_text(ready_at is not None, mode, prog, running, paused)}


# --- Stufe (b): Noten ---------------------------------------------------------------------------------------------

def run_grades_if_due(log=print, force: bool = False) -> str | None:
    """Noten (QIS, LSF, HISinOne) nach dem aktuellen Semester, hoechstens einmal in 20 Stunden (wie bisher am Ende von
    sync.py); nur mit eigenem Zugang. Rueckgabe: Meldung oder None (nicht faellig, kein Zugang)."""
    from datetime import datetime, timedelta

    from . import db, qis
    try:
        if not qis.configured():
            return None
        with db.cursor() as conn:
            last = db.row(conn, "SELECT finished_at FROM qis_runs WHERE ok=1 ORDER BY id DESC LIMIT 1")
        if not force and last and datetime.fromisoformat(last["finished_at"]) >= datetime.now() - timedelta(hours=20):
            return None
        msg = qis.run()["message"]
        log(f"QIS: {msg}")
        return msg
    except Exception as e:  # noqa: BLE001 - Noten halten den Abgleich nie an
        log(f"QIS-Fehler: {e}")
        return None


# --- Stufe (d) am PC: Hintergrund, solange die App offen ist ------------------------------------------------------

_older_stop = threading.Event()
_older_thread: threading.Thread | None = None
_older_guard = threading.Lock()


def older_continue(pause: float | None = None) -> bool:
    """Zwischen zwei Kursen frueherer Semester: kurz warten (drosseln) und pruefen, ob weitergemacht werden darf
    (kein voller Abgleich wartet, nicht angehalten). False: aufhoeren; der naechste Lauf macht dort weiter."""
    wait = OLDER_PAUSE_S if pause is None else pause
    if wait > 0:
        _older_stop.wait(wait)
    return not _older_stop.is_set()


def stop_older(wait_s: float = 30.0) -> None:
    """Laufende Stufe (d) anhalten (z. B. vor einem vollen Abgleich, der dasselbe Browserprofil braucht)."""
    t = _older_thread
    if t is None or not t.is_alive():
        return
    _older_stop.set()
    t.join(wait_s)


def older_active() -> bool:
    t = _older_thread
    return bool(t and t.is_alive())


def start_older_background(run=None, log=None) -> bool:
    """Stufe (d) in einem eigenen Faden starten (PC/Windows-App, nur waehrend die App offen ist; Dienst: der Job
    ruft `run_older_now` selbst). Startet nur, wenn die Wahl es erlaubt und etwas zu laden ist. `run`: Lauf nur fuer
    fruehere Semester (Standard: studip_sync.run_sync(older_only=True), je Hochschule)."""
    global _older_thread
    import os

    from . import config, db, older_semesters
    # Dienst: im Job (`run_older_now`); Tests (LERNAPP_NO_SCHEDULER): nie ein Abgleich im Hintergrund, nie ein Abruf
    if config.is_hosted() or (run is None and os.environ.get("LERNAPP_NO_SCHEDULER") == "1"):
        return False
    with _older_guard:
        if older_active():
            return False
        with db.cursor() as conn:
            ok, why = older_allowed(conn)
            if get_state(conn, "current_ready_at") is None and run is None:
                return False                            # erst nach einem gelungenen vollen Abgleich (Anmeldung steht)
            if not older_semesters.pending(conn):
                set_older_running(conn, False)
                return False
            if not ok:
                set_older_running(conn, False, why)
                return False
            set_older_running(conn, True)
        _older_stop.clear()

        def work():
            try:
                if run is not None:
                    run()
                else:
                    from .studip_sync import run_sync
                    run_sync(older_only=True)
            except Exception as e:  # noqa: BLE001 - Hintergrund: nie die App stoeren
                if log:
                    log(f"Frühere Semester: {e}")
            finally:
                try:
                    with db.cursor() as conn:
                        set_older_running(conn, False, "user" if _older_stop.is_set() else None)
                except Exception:  # noqa: BLE001
                    pass

        _older_thread = threading.Thread(target=work, name="older-semesters", daemon=True)
        _older_thread.start()
        return True


def run_older_now(run=None) -> dict | None:
    """Stufe (d) im aufrufenden Faden (Dienst: im selben Job nach dem vollen Abgleich, nur Dateilisten, weil der Dienst
    Dateien bei Bedarf durchreicht). None, wenn nichts zu tun oder nicht erlaubt ist."""
    from . import db, older_semesters
    with db.cursor() as conn:
        if not older_semesters.pending(conn):
            return None
    _older_stop.clear()
    if run is not None:
        return run()
    from .studip_sync import run_sync
    return run_sync(older_only=True)


def throttle_reset() -> None:
    """Fuer Tests: Stopp-Merker zuruecksetzen."""
    _older_stop.clear()


# --- Module nach Semestern ----------------------------------------------------------------------------------------

def modules_by_semester(conn, today: date | None = None) -> dict:
    """`GET /api/module-semesters`: Module je Semester fuer alle Portale. Aktuelles Semester zuerst (Modul-IDs fuer die
    Karten von /api/modules), dann das naechste, dann fruehere Semester neuestes zuerst mit ihren Modulen: echte Module
    (inaktiv, Kurse dieses Semesters) und erkannte Faecher aus Kursen ohne Modul (Fach aus dem Titel, wie beim Abgleich).
    Dateien bleiben an Kurs und Modul; gezaehlt wird je Semester."""
    from . import study
    d = today or _today()
    study.ensure_modules(conn)
    cur = current_term(d)
    courses = conn.execute("""
        SELECT c.id, c.title, c.subject, c.kind, c.semester, c.semester_end, c.module_id, COALESCE(c.active, 1) AS active,
               (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL) AS files,
               (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL AND COALESCE(f.local_path, '')<>'') AS downloaded
        FROM courses c WHERE c.id <> '__user__'""").fetchall()
    modules = {r["id"]: dict(r) for r in conn.execute("SELECT id, name, color, semester, COALESCE(active, 1) AS active FROM modules")}
    from . import config, older_semesters
    stream = config.streams_files()
    loaded = {c["id"] for c in older_semesters.courses(conn, d) if c["loaded"]}

    by_module: dict[int, list] = {}
    loose: list = []
    for c in courses:
        (by_module.setdefault(c["module_id"], []) if c["module_id"] in modules else loose).append(c)

    current_ids: list[int] = []
    upcoming: dict = {}
    older: dict[tuple, dict] = {}

    def term_group(k):
        key = k if k else None
        g = older.get(key)
        if g is None:
            g = older[key] = {"key": list(k) if k else None, "label": semesters.label(k) if k else "Ohne Semesterangabe",
                              "items": []}
        return g

    def item(name, module_id, color, cs):
        files = sum(c["files"] for c in cs)
        return {"name": name, "module_id": module_id, "color": color, "course_ids": [c["id"] for c in cs],
                "courses": len(cs), "files": files, "downloaded": files if stream else sum(c["downloaded"] for c in cs),
                "loaded": all(c["id"] in loaded or c["active"] for c in cs) if cs else True}

    for mid, m in modules.items():
        cs = by_module.get(mid, [])
        keys = [k for k in (semesters.key(c["semester"]) or semesters.key(c["semester_end"]) for c in cs) if k]
        k = max(keys) if keys else semesters.key(m["semester"])
        if m["active"] or any(c["active"] for c in cs):
            if k is not None and k > cur and all((semesters.key(c["semester"]) or cur) > cur for c in cs if c["active"]):
                g = upcoming.setdefault(k, {"key": list(k), "label": semesters.label(k), "module_ids": [], "items": []})
                g["module_ids"].append(mid)
                g["items"].append(item(m["name"], mid, m["color"], cs))
            else:
                current_ids.append(mid)
        else:
            term_group(k)["items"].append(item(m["name"], mid, m["color"], cs))

    # Kurse ohne Modul: aktive gehoeren zum aktuellen (bzw. naechsten) Semester und stehen in der Bibliothek; fruehere
    # werden je Semester nach Fach erkannt (zwei Kurse "Mathematik I" -> ein Eintrag)
    for c in loose:
        if c["active"] or (c["kind"] == "sonstiges" and not c["subject"]):
            continue
        k = semesters.key(c["semester"]) or semesters.key(c["semester_end"])
        name = (c["subject"] or c["title"] or "Kurs").strip()
        g = term_group(k)
        same = next((x for x in g["items"] if x["module_id"] is None and x["name"] == name), None)
        if same:
            cs = [x for x in courses if x["id"] in same["course_ids"]] + [c]
            g["items"][g["items"].index(same)] = item(name, None, None, cs)
        else:
            g["items"].append(item(name, None, None, [c]))

    def finish(g):
        g["items"].sort(key=lambda x: x["name"].casefold())
        g["count"] = len(g["items"])
        g["files"] = sum(x["files"] for x in g["items"])
        g["downloaded"] = sum(x["downloaded"] for x in g["items"])
        g["loaded"] = all(x["loaded"] for x in g["items"])
        return g

    older_list = [finish(g) for g in older.values()]
    older_list.sort(key=lambda g: (g["key"] is None, tuple(-x for x in (g["key"] or (0, 0)))))
    return {"current": {"key": list(cur), "label": semesters.label(cur), "module_ids": current_ids, "count": len(current_ids)},
            "upcoming": [finish(g) for _, g in sorted(upcoming.items())],
            "older": older_list,
            "status": status(conn, d)}
