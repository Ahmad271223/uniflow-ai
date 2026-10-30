"""Intelligente Wochentests, Vorlesungs-Seitenmarker, Aufgabenindex, Nachtraege und Probeklausuren.

Ablauf
  1. Der Student setzt im PDF-Editor „Vorlesung bis hier“ (Marker = letzte behandelte Seite inkl.).
     Marker sind an die Dokumentversion und einen Seiten-Fingerabdruck gebunden.
  2. Aus allen Markern eines Moduls entsteht der Stoffumfang je Lehrwoche (neuer Stoff + Vorwissen).
     Nur bis zum Marker behandelte Seiten zaehlen; Dateien ohne Marker gelten als NICHT behandelt.
  3. Uebungen, Musterloesungen und Altklausuren werden auf Aufgabenebene indexiert (inkrementell, je
     Dateiversion zwischengespeichert) und per Inhaltsabgleich (BM25) den Vorlesungsseiten zugeordnet.
     Eine Aufgabe ist nur zulaessig, wenn ALLE stark passenden Vorlesungsseiten behandelt sind
     (bei Unsicherheit: ausschliessen).
  4. Pro Modul, Lehrwoche und Stoffumfang (scope_key) gibt es genau EINEN Wochentest-Plan.
     Veroeffentlichung standardmaessig 24 h nach Vorlesungsende (Stundenplan), Wartezeit auf
     erwartete Uebungen hoechstens 48 h zusaetzlich, danach mit gekennzeichneten Luecken.
  5. Erzeugung: KI-Entwurf -> feste Regelpruefung -> KI-Fachpruefung -> ggf. eine Reparaturrunde.
     Nicht bestandene Entwuerfe werden nie veroeffentlicht. Veroeffentlichte Versionen sind
     unveraenderlich (SQLite-Trigger). Spaetere Uploads werden als gemeinsamer Nachtrag angeboten.

Die App ist (noch) eine Einzelplatz-Installation ohne Konten. Alle Tabellen tragen trotzdem eine
user_id (Standard 'local'), damit Kursmarker, gemeinsame Tests und Ranglisten mit Konten funktionieren.
"""
from __future__ import annotations

import contextvars
import hashlib
import json
import math
import re
import threading
import uuid
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta

from . import ai, db, scriptsearch, study

LOCAL_USER = "local"
LECTURE_TYPES = ("vorlesung", "skript")
TASK_TYPES = ("uebung", "loesung", "klausur")
SOURCE_TXT = {"hoersaaluebung": "Hörsaalübung", "gruppenuebung": "Gruppenübung", "uebungsblatt": "Übungsblatt",
              "zusatz": "Zusatzübung", "tutorium": "Tutorium", "altklausur": "Altklausur", "loesung": "Musterlösung"}
EXPECTABLE = ("hoersaaluebung", "gruppenuebung", "uebungsblatt", "zusatz", "tutorium")
DEFAULTS = {"weekly_publish_hours": "24", "weekly_max_delay_hours": "48", "weekly_ai_daily_limit": "8",
            "weekly_questions": "15", "weekly_mode": "marker"}
STRONG = 0.6            # Vorlesungsseiten mit >= 60 % der besten Trefferguete muessen behandelt sein
MIN_REF_SCORE = 6.0     # Mindestguete einer Seitenzuordnung (BM25), sonst "kein sicherer Bezug"

_GEN_LOCK = threading.Lock()


class WeeklyError(RuntimeError):
    pass


# ============================================================================ Schema
SCHEMA = """
CREATE TABLE IF NOT EXISTS lecture_markers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL DEFAULT 'local',
    module_id INTEGER NOT NULL,
    file_id TEXT NOT NULL,
    doc_version TEXT NOT NULL,          -- Fingerabdruck der Datei (Aenderungsdatum, Seitenzahl, Text-Hash)
    page INTEGER NOT NULL,              -- letzte behandelte PDF-Seite (1-basiert, Originalseite)
    page_key TEXT,                      -- Seitenschluessel im Editor
    page_fingerprint TEXT,              -- Hash des Seitentexts zum Wiederfinden nach Dokumentaenderung
    page_count INTEGER,
    lecture_date TEXT NOT NULL,         -- YYYY-MM-DD
    lecture_end TEXT,                   -- ISO-Zeitpunkt Vorlesungsende
    lecture_source TEXT,                -- stundenplan | manuell
    iso_week TEXT,                      -- z. B. 2026-W44
    week_no INTEGER,                    -- Lehrwoche
    topic TEXT,
    scope TEXT NOT NULL DEFAULT 'personal',   -- personal | course (nur nach ausdruecklicher Freigabe)
    released_at TEXT,
    released_by TEXT,
    needs_review INTEGER DEFAULT 0,
    review_note TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS ix_markers_mod ON lecture_markers(module_id, file_id);

CREATE TABLE IF NOT EXISTS doc_index (
    file_id TEXT PRIMARY KEY,
    version TEXT NOT NULL,              -- Dateiversion + Vorlesungsstand des Moduls
    module_id INTEGER,
    role TEXT,
    tasks INTEGER,
    indexed_at TEXT
);

CREATE TABLE IF NOT EXISTS task_index (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id TEXT NOT NULL,
    version TEXT NOT NULL,
    module_id INTEGER,
    source TEXT NOT NULL,               -- hoersaaluebung | gruppenuebung | uebungsblatt | zusatz | tutorium | altklausur | loesung
    nr TEXT NOT NULL,
    label TEXT,
    page_from INTEGER,
    page_to INTEGER,
    text TEXT,
    solution_file_id TEXT,
    solution_text TEXT,
    points REAL,
    difficulty INTEGER,
    exam_term TEXT,
    lecture_refs TEXT,                  -- JSON [{file_id, page, score}]
    content_hash TEXT,
    indexed_at TEXT,
    UNIQUE(file_id, nr)
);
CREATE INDEX IF NOT EXISTS ix_task_mod ON task_index(module_id, source);

CREATE TABLE IF NOT EXISTS wt_plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id INTEGER NOT NULL,
    week_no INTEGER NOT NULL,
    part INTEGER NOT NULL DEFAULT 1,    -- 2, 3 ... wenn nach Veroeffentlichung in derselben Woche neuer Stoff markiert wurde
    scope TEXT NOT NULL,                -- personal | course
    scope_key TEXT NOT NULL,            -- Hash des Stoffumfangs (gleich fuer alle mit gleichem Kursstand)
    user_id TEXT,
    coverage TEXT NOT NULL,             -- JSON
    lecture_end TEXT NOT NULL,
    publish_at TEXT NOT NULL,
    deadline_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'geplant',   -- geplant | wartet | veroeffentlicht | fehlgeschlagen | ersetzt
    expected TEXT,                      -- JSON Liste erwarteter Quellen (aus Moduleinstellung)
    missing TEXT,                       -- JSON fehlende erwartete Quellen
    def_id INTEGER,
    last_check TEXT,
    last_error TEXT,
    attempts INTEGER DEFAULT 0,
    lock_token TEXT,
    lock_until TEXT,
    created_at TEXT,
    UNIQUE(module_id, week_no, scope_key)
);

CREATE TABLE IF NOT EXISTS wt_defs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,                 -- wochentest | nachtrag | probeklausur
    plan_id INTEGER,
    parent_id INTEGER,
    module_id INTEGER NOT NULL,
    week_no INTEGER,
    scope_key TEXT NOT NULL,
    material_hash TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    title TEXT,
    topic TEXT,
    duration_min INTEGER,
    questions TEXT NOT NULL,
    sources TEXT,
    coverage TEXT,
    qa TEXT,
    status TEXT NOT NULL DEFAULT 'entwurf',   -- entwurf | geprueft | veroeffentlicht | verworfen
    created_at TEXT,
    published_at TEXT,
    UNIQUE(kind, module_id, scope_key, material_hash)
);

CREATE TRIGGER IF NOT EXISTS trg_wt_defs_frozen
BEFORE UPDATE OF questions, sources, coverage, scope_key, material_hash, title, duration_min ON wt_defs
WHEN OLD.status = 'veroeffentlicht'
BEGIN
    SELECT RAISE(ABORT, 'veroeffentlichte Testversion ist unveraenderlich');
END;
CREATE TRIGGER IF NOT EXISTS trg_wt_defs_nodelete
BEFORE DELETE ON wt_defs WHEN OLD.status = 'veroeffentlicht'
BEGIN
    SELECT RAISE(ABORT, 'veroeffentlichte Testversion kann nicht geloescht werden');
END;
"""


def ensure_schema(conn) -> None:
    conn.executescript(SCHEMA)
    for k, v in DEFAULTS.items():
        conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", (k, v))

    def add_col(table, col, decl):
        cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if col not in cols:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
    add_col("tests", "def_id", "INTEGER")
    add_col("tests", "user_id", "TEXT DEFAULT 'local'")
    add_col("tests", "duration_sec", "INTEGER")
    add_col("modules", "expected_materials", "TEXT")      # JSON, z. B. ["hoersaaluebung", "gruppenuebung"]
    add_col("modules", "exam_reuse", "TEXT DEFAULT 'paraphrase'")   # original | paraphrase
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS ux_tests_def_user ON tests(def_id, user_id) WHERE def_id IS NOT NULL")


def _settings(conn) -> dict:
    s = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM settings")}

    def num(k):
        try:
            return float(s.get(k) or DEFAULTS[k])
        except ValueError:
            return float(DEFAULTS[k])
    return {"publish_hours": num("weekly_publish_hours"), "max_delay_hours": num("weekly_max_delay_hours"),
            "daily_limit": int(num("weekly_ai_daily_limit")), "questions": int(num("weekly_questions"))}


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now()).replace(microsecond=0)


def _h(*parts) -> str:
    return hashlib.sha1(json.dumps(parts, ensure_ascii=False, sort_keys=True, default=str).encode()).hexdigest()[:16]


def _norm(t: str) -> str:
    return re.sub(r"\s+", " ", scriptsearch.normalize(t or "")).strip().lower()


# ============================================================================ Dokumentversion, Seiten
def page_texts(conn, file_id: str) -> list[str]:
    return scriptsearch.page_texts(conn, file_id)


def page_fp(text: str) -> str:
    n = _norm(text)
    return hashlib.sha1(n.encode()).hexdigest()[:16] if len(n) >= 12 else ""


def doc_version(conn, file_id: str) -> str:
    f = db.row(conn, "SELECT chdate FROM files WHERE id=?", (file_id,))
    pages = page_texts(conn, file_id)
    return f"{(f or {}).get('chdate') or 0}-{len(pages)}-{_h([_norm(p) for p in pages])[:10]}"


def _file(conn, file_id: str) -> dict | None:
    f = db.row(conn, """SELECT f.id, f.name, f.chdate, f.studip_folder, f.local_path, f.first_seen, c.module_id, c.title AS course_title,
                               a.doc_type, a.title AS ai_title FROM files f JOIN courses c ON c.id=f.course_id
                        LEFT JOIN analysis a ON a.file_id=f.id WHERE f.id=?""", (file_id,))
    return study.enrich_file(f) if f else None


def lecture_week(conn, d: date) -> int:
    """Lehrwoche eines Datums: ab Semesterbeginn (aktives Semester, sonst erster Upload-Montag)."""
    from . import timetable
    t = timetable.term(conn)
    try:
        ts, te = date.fromisoformat(t["start"]), date.fromisoformat(t["end"])
    except (KeyError, ValueError, TypeError):
        ts = te = None
    start = study.monday(ts) if ts and ts <= d <= (te or d) + timedelta(days=21) else study.semester_start(conn)
    return max(1, (study.monday(d) - start).days // 7 + 1)


def lecture_occurrence(conn, module_id: int, d: date) -> dict | None:
    """Vorlesungstermin des Moduls an einem Tag (letzter, falls mehrere), ausgefallene ausgenommen."""
    from . import timetable
    try:
        occ = timetable.occurrences(conn, d, d)
    except Exception:  # noqa: BLE001
        return None
    occ = [o for o in occ if o.get("module_id") == module_id and o.get("kind") in ("vorlesung", None)
           and o.get("status") not in ("ausfall", "verschoben")]
    occ.sort(key=lambda o: o["end"])
    return occ[-1] if occ else None


def last_lecture_date(conn, module_id: int, today: date | None = None) -> tuple[date, dict | None]:
    t = today or date.today()
    for back in range(0, 15):
        d = t - timedelta(days=back)
        o = lecture_occurrence(conn, module_id, d)
        if o:
            return d, o
    return t, None


def _lecture_end(conn, module_id: int, d: date, now: datetime) -> tuple[str, str]:
    o = lecture_occurrence(conn, module_id, d)
    if o:
        return f"{d.isoformat()}T{o['end']}:00", "stundenplan"
    if d == now.date():
        return now.isoformat(), "manuell"
    return f"{d.isoformat()}T18:00:00", "manuell"


# ============================================================================ Marker
def _marker_row(conn, mid: int) -> dict | None:
    return db.row(conn, "SELECT * FROM lecture_markers WHERE id=? AND deleted_at IS NULL", (mid,))


def list_markers(conn, module_id: int | None = None, file_id: str | None = None, user_id: str = LOCAL_USER) -> list[dict]:
    sql = "SELECT * FROM lecture_markers WHERE deleted_at IS NULL AND (user_id=? OR scope='course')"
    p: list = [user_id]
    if module_id is not None:
        sql += " AND module_id=?"; p.append(module_id)
    if file_id is not None:
        sql += " AND file_id=?"; p.append(file_id)
    out = db.rows(conn, sql + " ORDER BY file_id, page", p)
    for m in out:
        m["page_range"] = _range_of(conn, m)
    return out


def _range_of(conn, m: dict) -> list[int]:
    prev = db.row(conn, """SELECT MAX(page) AS p FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope=?
                           AND (scope='course' OR user_id=?) AND page < ?""", (m["file_id"], m["scope"], m["user_id"], m["page"]))
    return [((prev or {}).get("p") or 0) + 1, m["page"]]


def _check_order(conn, m: dict, exclude_id: int | None = None) -> None:
    """Spaetere Seiten duerfen nicht vor frueheren Seiten behandelt worden sein (und umgekehrt)."""
    others = db.rows(conn, """SELECT id, page, lecture_date FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope=?
                              AND (scope='course' OR user_id=?) AND id IS NOT ?""", (m["file_id"], m["scope"], m["user_id"], exclude_id))
    for o in others:
        if o["page"] == m["page"]:
            raise WeeklyError(f"Auf Seite {m['page']} liegt bereits ein Marker.")
        if (o["page"] < m["page"] and o["lecture_date"] > m["lecture_date"]) or (o["page"] > m["page"] and o["lecture_date"] < m["lecture_date"]):
            raise WeeklyError(f"Reihenfolge passt nicht: Seite {o['page']} ist am {o['lecture_date']} markiert. "
                              "Spätere Seiten können nicht vor früheren behandelt worden sein.")


def suggest_topic(pages: list[str], frm: int, to: int) -> str:
    """Thema aus den Seitenueberschriften (erste sinnvolle Zeile der Seiten im Bereich)."""
    heads = Counter()
    for t in pages[max(0, frm - 1):to]:
        for line in (scriptsearch.normalize(t or "")).splitlines():
            line = line.strip(" \t•-–:")
            if 4 <= len(line) <= 70 and re.search(r"[A-Za-zÄÖÜäöü]{4}", line) and not re.match(r"^(seite|folie|page)\s*\d", line, re.I) \
                    and not re.search(r"universit|institut|hannover|prof\.|dr\.|©|\d{1,2}\.\d{1,2}\.\d{2,4}", line, re.I):
                heads[line] += 1
                break
    top = [h for h, _ in heads.most_common(3)]
    return " · ".join(top)[:120]


def marker_preview(conn, file_id: str, page: int, user_id: str = LOCAL_USER, now: datetime | None = None,
                   lecture_date: str | None = None) -> dict:
    now = _now(now)
    f = _file(conn, file_id)
    if not f or not f.get("module_id"):
        raise WeeklyError("Das Dokument gehört zu keinem Modul. Bitte zuerst einem Modul zuordnen.")
    pages = page_texts(conn, file_id)
    if not pages:
        raise WeeklyError("Für dieses Dokument liegt kein Seitentext vor (nur PDFs mit Textebene).")
    if not 1 <= page <= len(pages):
        raise WeeklyError(f"Seite {page} gibt es nicht (1–{len(pages)}).")
    prev = db.row(conn, """SELECT MAX(page) AS p FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope='personal'
                           AND user_id=? AND page < ?""", (file_id, user_id, page))
    frm = ((prev or {}).get("p") or 0) + 1
    existing = db.row(conn, """SELECT id, lecture_date, topic FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope='personal'
                               AND user_id=? AND page=?""", (file_id, user_id, page))
    if lecture_date:
        d = date.fromisoformat(lecture_date); occ = lecture_occurrence(conn, f["module_id"], d)
    elif existing:
        d = date.fromisoformat(existing["lecture_date"]); occ = lecture_occurrence(conn, f["module_id"], d)
    else:
        d, occ = last_lecture_date(conn, f["module_id"], now.date())
    if d > now.date():
        raise WeeklyError("Der Vorlesungstermin liegt in der Zukunft. Markiert wird nur bereits behandelter Stoff.")
    end, src = _lecture_end(conn, f["module_id"], d, now)
    s = _settings(conn)
    pub = datetime.fromisoformat(end) + timedelta(hours=s["publish_hours"])
    return {"file_id": file_id, "module_id": f["module_id"], "page": page, "page_count": len(pages), "range": [frm, page],
            "lecture_date": d.isoformat(), "lecture_end": end, "lecture_source": src,
            "lecture": ({"title": occ["title"], "start": occ["start"], "end": occ["end"], "room": occ.get("room")} if occ else None),
            "week_no": lecture_week(conn, d), "topic": (existing or {}).get("topic") or suggest_topic(pages, frm, page), "existing": existing,
            "publish_at": pub.isoformat(), "publish_hours": s["publish_hours"]}


def create_marker(conn, file_id: str, page: int, user_id: str = LOCAL_USER, lecture_date: str | None = None,
                  topic: str | None = None, page_key: str | None = None, now: datetime | None = None) -> dict:
    now = _now(now)
    pv = marker_preview(conn, file_id, page, user_id, now, lecture_date)
    pages = page_texts(conn, file_id)
    d = date.fromisoformat(pv["lecture_date"])
    m = {"user_id": user_id, "module_id": pv["module_id"], "file_id": file_id, "doc_version": doc_version(conn, file_id), "page": page,
         "page_key": page_key, "page_fingerprint": page_fp(pages[page - 1]), "page_count": len(pages), "lecture_date": d.isoformat(),
         "lecture_end": pv["lecture_end"], "lecture_source": pv["lecture_source"], "iso_week": f"{d.isocalendar()[0]}-W{d.isocalendar()[1]:02d}",
         "week_no": pv["week_no"], "topic": (topic or "").strip() or pv["topic"], "scope": "personal", "created_at": now.isoformat()}
    _check_order(conn, m)
    cols = ",".join(m)
    cur = conn.execute(f"INSERT INTO lecture_markers({cols}) VALUES ({','.join('?' * len(m))})", list(m.values()))
    return {**_marker_row(conn, cur.lastrowid), "page_range": pv["range"], "publish_at": pv["publish_at"]}


def update_marker(conn, marker_id: int, user_id: str = LOCAL_USER, page: int | None = None, lecture_date: str | None = None,
                  topic: str | None = None, page_key: str | None = None, now: datetime | None = None) -> dict:
    now = _now(now)
    m = _marker_row(conn, marker_id)
    if not m:
        raise WeeklyError("Marker nicht gefunden.")
    if m["scope"] == "course" and m["user_id"] != user_id:
        raise WeeklyError("Kursmarker können nur von der Person geändert werden, die sie freigegeben hat.")
    new = dict(m)
    if page is not None:
        pages = page_texts(conn, m["file_id"])
        if not 1 <= int(page) <= len(pages):
            raise WeeklyError(f"Seite {page} gibt es nicht (1–{len(pages)}).")
        new.update(page=int(page), page_fingerprint=page_fp(pages[int(page) - 1]), doc_version=doc_version(conn, m["file_id"]),
                   page_count=len(pages), needs_review=0, review_note=None, page_key=page_key)
    if lecture_date:
        d = date.fromisoformat(lecture_date)
        if d > now.date():
            raise WeeklyError("Der Vorlesungstermin liegt in der Zukunft. Markiert wird nur bereits behandelter Stoff.")
        end, src = _lecture_end(conn, m["module_id"], d, now)
        new.update(lecture_date=d.isoformat(), lecture_end=end, lecture_source=src, week_no=lecture_week(conn, d),
                   iso_week=f"{d.isocalendar()[0]}-W{d.isocalendar()[1]:02d}")
    if topic is not None:
        new["topic"] = topic.strip()
    _check_order(conn, new, exclude_id=marker_id)
    conn.execute("""UPDATE lecture_markers SET page=?, page_key=?, page_fingerprint=?, doc_version=?, page_count=?, needs_review=?, review_note=?,
                    lecture_date=?, lecture_end=?, lecture_source=?, week_no=?, iso_week=?, topic=?, updated_at=? WHERE id=?""",
                 (new["page"], new.get("page_key"), new["page_fingerprint"], new["doc_version"], new["page_count"], new["needs_review"], new["review_note"],
                  new["lecture_date"], new["lecture_end"], new["lecture_source"], new["week_no"], new["iso_week"], new["topic"], now.isoformat(), marker_id))
    return _marker_row(conn, marker_id)


def delete_marker(conn, marker_id: int, user_id: str = LOCAL_USER) -> None:
    m = _marker_row(conn, marker_id)
    if not m:
        raise WeeklyError("Marker nicht gefunden.")
    if m["user_id"] != user_id:
        raise WeeklyError("Nur eigene Marker können gelöscht werden.")
    conn.execute("UPDATE lecture_markers SET deleted_at=? WHERE id=?", (_now().isoformat(), marker_id))


def release_marker(conn, marker_id: int, user_id: str = LOCAL_USER, confirm: bool = False) -> dict:
    """Persoenlichen Marker ausdruecklich als Kursmarker freigeben (gilt dann fuer den gemeinsamen Kurstest)."""
    if not confirm:
        raise WeeklyError("Freigabe muss ausdrücklich bestätigt werden (confirm=true).")
    m = _marker_row(conn, marker_id)
    if not m or m["user_id"] != user_id:
        raise WeeklyError("Marker nicht gefunden.")
    if db.row(conn, "SELECT 1 FROM lecture_markers WHERE deleted_at IS NULL AND scope='course' AND file_id=? AND page=?", (m["file_id"], m["page"])):
        raise WeeklyError("Für diese Seite gibt es bereits einen Kursmarker.")
    course = {**m, "scope": "course"}
    _check_order(conn, course)
    cols = [k for k in m if k not in ("id",)]
    vals = [course[k] for k in cols]
    vals[cols.index("released_at")] = _now().isoformat(); vals[cols.index("released_by")] = user_id
    cur = conn.execute(f"INSERT INTO lecture_markers({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", vals)
    return _marker_row(conn, cur.lastrowid)


def revalidate_markers(conn, file_id: str | None = None) -> list[dict]:
    """Nach einer Dokumentaenderung: Marker per Seiten-Fingerabdruck wiederfinden, sonst zur Pruefung markieren."""
    changes = []
    sql = "SELECT * FROM lecture_markers WHERE deleted_at IS NULL" + (" AND file_id=?" if file_id else "")
    for m in db.rows(conn, sql, (file_id,) if file_id else ()):
        ver = doc_version(conn, m["file_id"])
        if ver == m["doc_version"]:
            continue
        pages = page_texts(conn, m["file_id"])
        fps = [page_fp(t) for t in pages]
        note, page, review = None, m["page"], 0
        if m["page"] <= len(fps) and m["page_fingerprint"] and fps[m["page"] - 1] == m["page_fingerprint"]:
            pass                                             # Seite unveraendert an gleicher Stelle
        else:
            hits = [i + 1 for i, fp in enumerate(fps) if fp and fp == m["page_fingerprint"]]
            if len(hits) == 1:
                note = f"Dokument wurde geändert: Marker von Seite {m['page']} auf Seite {hits[0]} verschoben (gleicher Seiteninhalt)."
                page = hits[0]
            else:
                review = 1
                note = ("Dokument wurde geändert und die markierte Seite ist nicht mehr eindeutig auffindbar. "
                        "Bitte Marker prüfen – bis dahin zählt dieser Stoff nicht für Wochentests.")
        conn.execute("UPDATE lecture_markers SET page=?, doc_version=?, page_count=?, needs_review=?, review_note=COALESCE(?, review_note), updated_at=? WHERE id=?",
                     (page, ver if not review else m["doc_version"], len(pages), review, note, _now().isoformat(), m["id"]))
        changes.append({"id": m["id"], "from": m["page"], "to": page, "needs_review": bool(review), "note": note})
    return changes


# ============================================================================ Stoffumfang
def coverage(conn, module_id: int, upto_week: int | None = None, user_id: str = LOCAL_USER, scope: str | None = None) -> dict:
    """Behandelter Stoff: Segmente (Datei, Seite von–bis, Lehrwoche). Kursmarker haben Vorrang, wenn freigegeben."""
    if scope is None:
        scope = "course" if db.row(conn, "SELECT 1 FROM lecture_markers WHERE deleted_at IS NULL AND module_id=? AND scope='course'", (module_id,)) else "personal"
    rows = db.rows(conn, """SELECT * FROM lecture_markers WHERE deleted_at IS NULL AND module_id=? AND scope=? AND (scope='course' OR user_id=?)
                            ORDER BY file_id, page""", (module_id, scope, user_id))
    segs, blocked = [], []
    by_file = defaultdict(list)
    for m in rows:
        by_file[m["file_id"]].append(m)
    for fid, ms in by_file.items():
        prev = 0
        for m in ms:
            if m["needs_review"]:
                blocked.append({"marker_id": m["id"], "file_id": fid, "page": m["page"], "note": m["review_note"]})
                break                                        # ab hier unsicher -> nichts weiter aus dieser Datei
            if upto_week is None or (m["week_no"] or 0) <= upto_week:
                segs.append({"file_id": fid, "version": m["doc_version"], "from": prev + 1, "to": m["page"], "week": m["week_no"],
                             "marker_id": m["id"], "topic": m["topic"], "lecture_date": m["lecture_date"], "lecture_end": m["lecture_end"]})
            prev = m["page"]
    segs.sort(key=lambda s: (s["week"] or 0, s["lecture_date"], s["file_id"], s["from"]))
    pages = {(s["file_id"], p) for s in segs for p in range(s["from"], s["to"] + 1)}
    return {"scope": scope, "segments": segs, "pages": pages, "blocked": blocked}


def scope_key(segs: list[dict]) -> str:
    return _h([(s["file_id"], s["version"], s["from"], s["to"], s["week"]) for s in segs])


# ============================================================================ Aufgabenindex
TASK_HEAD = re.compile(r"(?im)^[ \t]*(?:\d{1,2}\.\s*)?(Aufgabe|Aufg\.|Exercise|Problem|Task)\s*(\d{1,2}(?:[.,]\d{1,2})?[a-z]?)\b[ \t]*[:.)\-–]?")
POINTS = re.compile(r"\(?\s*(\d{1,2}(?:[.,]5)?)\s*(?:Punkte|Pkt\.?|P\.)\s*\)?", re.I)
TERM = re.compile(r"(WiSe|WS|SoSe|SS|Winter|Sommer)\s*(?:semester)?\s*['_ ]?(\d{2,4})(?:\s*[/_-]\s*(\d{2,4}))?", re.I)


def task_source(f: dict) -> str:
    lab = (f.get("sub_label") or "").lower()
    fl = f"{f.get('studip_folder') or ''} {f.get('name') or ''}".lower()
    if f.get("doc_type") == "loesung" or "lösung" in lab:
        return "loesung"
    if f.get("doc_type") == "klausur":
        return "altklausur"
    if "zusatz" in fl or "eigenarbeit" in fl:
        return "zusatz"
    if "hörsaal" in lab or "hoersaal" in lab:
        return "hoersaaluebung"
    if "gruppen" in lab:
        return "gruppenuebung"
    if "tutorium" in lab:
        return "tutorium"
    return "uebungsblatt"


def split_tasks(pages: list[str]) -> list[dict]:
    """Zerlegt ein Uebungsblatt/eine Klausur in Aufgaben (Ueberschrift 'Aufgabe N'). Ohne Ueberschriften: je Seite."""
    norm = [scriptsearch.normalize(t or "") for t in pages]
    flat, starts = "", []
    for t in norm:
        starts.append(len(flat))
        flat += t + "\n"

    def page_at(pos: int) -> int:
        p = 1
        for i, s in enumerate(starts, 1):
            if s <= pos:
                p = i
        return p
    found = [(mt.start(), mt.group(2).replace(",", ".")) for mt in TASK_HEAD.finditer(flat)]
    tasks = []
    if found:
        for k, (pos, nr) in enumerate(found):
            end = found[k + 1][0] if k + 1 < len(found) else len(flat)
            text = flat[pos:end].strip()
            if len(text) < 25:
                continue
            tasks.append({"nr": nr, "page_from": page_at(pos), "page_to": page_at(max(pos, end - 1)), "text": text})
        # gleiche Nummer mehrfach (z. B. Inhaltsverzeichnis): laengste Fundstelle behalten
        seen = {}
        for t in tasks:
            if t["nr"] not in seen or len(t["text"]) > len(seen[t["nr"]]["text"]):
                seen[t["nr"]] = t
        tasks = sorted(seen.values(), key=lambda t: (t["page_from"], _nr_key(t["nr"])))
    if not tasks:
        for pi, t in enumerate(pages, 1):
            t = scriptsearch.normalize(t or "").strip()
            if len(t) >= 40:
                tasks.append({"nr": f"S{pi}", "page_from": pi, "page_to": pi, "text": t})
    return tasks


def _nr_key(nr: str):
    m = re.match(r"(\d+)(?:\.(\d+))?([a-z]?)", nr)
    return (int(m.group(1)), int(m.group(2) or 0), m.group(3)) if m else (999, 0, nr)


def _solution_key(name: str) -> str:
    s = re.sub(r"\.[a-z0-9]+$", "", (name or "").lower())
    s = re.sub(r"musterl(ö|oe)sung(en)?|l(ö|oe)sung(en)?|l(ö|oe)s\b|lsg|solutions?|mit|und|_|-|\s|\(|\)", "", s)
    return s


def _difficulty(text: str, points: float | None, source: str) -> int:
    d = 2 + (len(text) > 700) + (len(text) > 1600) + (source == "altklausur") + ((points or 0) >= 10)
    return max(1, min(5, d))


def _lecture_hash(conn, module_id: int) -> str:
    files = [f for f in study._file_rows(conn, module_id) if f.get("doc_type") in LECTURE_TYPES and (f.get("name") or "").lower().endswith(".pdf")]
    return _h(sorted((f["id"], f.get("chdate") or 0) for f in files))[:8]


def _bm25_refs(conn, module_id: int, text: str, limit: int = 8) -> list[dict]:
    q = scriptsearch.tokens(text)
    if not q:
        return []
    idx = scriptsearch._index(conn, module_id)
    if not idx["n"]:
        return []
    qtf = Counter(q)
    k1, b = 1.4, 0.75
    scored = []
    for d in idx["docs"]:
        s, hits = 0.0, 0
        for t, qn in qtf.items():
            tf = d["tf"].get(t)
            if not tf:
                continue
            idf = math.log(1 + (idx["n"] - idx["df"][t] + 0.5) / (idx["df"][t] + 0.5))
            s += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * d["len"] / idx["avg"])) * min(qn, 2)
            hits += 1
        if hits >= 2:
            scored.append((s, d["file"]["id"], d["page"]))
    scored.sort(key=lambda x: -x[0])
    if not scored or scored[0][0] < MIN_REF_SCORE:
        return []                                            # kein sicherer Bezug -> Aufgabe wird ausgeschlossen
    # Die Mindestguete gilt nur fuer den besten Treffer. Fuer die Pruefung auf spaeteren Stoff zaehlt der Abstand zum
    # besten Treffer: haeufige Themen (viele Folien) haben sonst niedrige Einzelwerte und wuerden unbemerkt durchrutschen.
    # ALLE stark passenden Seiten behalten (keine Kappung!), sonst koennte spaeterer Stoff unbemerkt durchrutschen
    best = scored[0][0]
    strong = [x for x in scored if x[0] >= STRONG * best]
    weak = [x for x in scored if x[0] < STRONG * best][:limit]
    return [{"file_id": fid, "page": p, "score": round(s, 2)} for s, fid, p in strong + weak]


def index_module(conn, module_id: int, now: datetime | None = None, log=lambda *_: None) -> dict:
    """Inkrementell: nur Dateien, deren Version (oder der Vorlesungsstand des Moduls) sich geaendert hat."""
    now = _now(now)
    lec = _lecture_hash(conn, module_id)
    files = [f for f in study._file_rows(conn, module_id) if f.get("doc_type") in TASK_TYPES and (f.get("name") or "").lower().endswith(".pdf")]
    done = skipped = 0
    for f in files:
        ver = f"{doc_version(conn, f['id'])}:{lec}"
        cached = db.row(conn, "SELECT version FROM doc_index WHERE file_id=?", (f["id"],))
        if cached and cached["version"] == ver:
            skipped += 1
            continue
        pages = page_texts(conn, f["id"])
        src = task_source(f)
        term = TERM.search(f"{f.get('studip_folder') or ''} {f.get('name') or ''}")
        old = {r["nr"]: r for r in db.rows(conn, "SELECT nr, content_hash, indexed_at FROM task_index WHERE file_id=?", (f["id"],))}
        conn.execute("DELETE FROM task_index WHERE file_id=?", (f["id"],))
        tasks = split_tasks(pages)
        for t in tasks:
            pts = POINTS.search(t["text"][:300])
            points = float(pts.group(1).replace(",", ".")) if pts else None
            ch = _h(_norm(t["text"]))
            first = old.get(t["nr"], {}).get("indexed_at") if old.get(t["nr"], {}).get("content_hash") == ch else None
            conn.execute("""INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, points, difficulty,
                            exam_term, lecture_refs, content_hash, indexed_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                         (f["id"], ver, module_id, src, t["nr"], f"{SOURCE_TXT.get(src, src)} · {f.get('ai_title') or f['name']} · "
                          + (f"Aufgabe {t['nr']}" if not t["nr"].startswith("S") else f"Seite {t['nr'][1:]}"),
                          t["page_from"], t["page_to"], t["text"][:6000], points, _difficulty(t["text"], points, src),
                          term.group(0) if term else None, json.dumps(_bm25_refs(conn, module_id, t["text"])), ch, first or now.isoformat()))
        conn.execute("INSERT OR REPLACE INTO doc_index(file_id, version, module_id, role, tasks, indexed_at) VALUES (?,?,?,?,?,?)",
                     (f["id"], ver, module_id, src, len(tasks), now.isoformat()))
        done += 1
    _link_solutions(conn, module_id)
    if done:
        log(f"Aufgabenindex Modul {module_id}: {done} Dateien neu, {skipped} unverändert")
    return {"indexed": done, "unchanged": skipped}


def _link_solutions(conn, module_id: int) -> None:
    sols = db.rows(conn, """SELECT t.file_id, t.nr, t.text, f.name FROM task_index t JOIN files f ON f.id=t.file_id
                            WHERE t.module_id=? AND t.source='loesung'""", (module_id,))
    if not sols:
        return
    by_key = defaultdict(dict)
    for s in sols:
        by_key[_solution_key(s["name"])][s["nr"]] = s
    for t in db.rows(conn, """SELECT t.id, t.nr, f.name FROM task_index t JOIN files f ON f.id=t.file_id
                              WHERE t.module_id=? AND t.source!='loesung'""", (module_id,)):
        k = _solution_key(t["name"])
        cand = by_key.get(k) or next((v for kk, v in by_key.items() if kk and k and (kk in k or k in kk) and min(len(kk), len(k)) >= 4), None)
        s = (cand or {}).get(t["nr"])
        conn.execute("UPDATE task_index SET solution_file_id=?, solution_text=? WHERE id=?",
                     (s["file_id"] if s else None, s["text"][:5000] if s else None, t["id"]))


def task_scope(task: dict, cov_pages: set, new_pages: set, twin=None) -> dict:
    """Ist die Aufgabe mit dem behandelten Stoff loesbar? Alle stark passenden Vorlesungsseiten muessen behandelt sein.
    twin(file_id, page) -> (file_id, page) einer behandelten, nahezu identischen Seite (z. B. Folien aus Vorsemester) oder None."""
    refs = json.loads(task["lecture_refs"] or "[]") if isinstance(task.get("lecture_refs"), str) else (task.get("lecture_refs") or [])
    if not refs:
        return {"ok": False, "reason": "kein sicherer Bezug zu Vorlesungsseiten", "new": False}
    best = refs[0]["score"]
    strong, outside = [], []
    for r in refs:
        if r["score"] < STRONG * best:
            continue
        key = (r["file_id"], r["page"])
        if key not in cov_pages:
            tw = twin(*key) if twin else None
            if not tw:
                outside.append(r)
                continue
            r = {**r, "file_id": tw[0], "page": tw[1], "via_twin": True}
        strong.append(r)
    if outside:
        return {"ok": False, "reason": f"braucht noch nicht behandelte Seite(n) {', '.join(str(r['page']) for r in outside[:4])}", "new": False}
    hit_new = any((r["file_id"], r["page"]) in new_pages for r in strong)
    return {"ok": True, "reason": "", "new": hit_new, "refs": strong}


def _twin_finder(conn, module_id: int, cov_pages: set):
    """Nahezu identische Seiten (Token-Jaccard >= 0,8), damit Folien-Kopien aus anderen Semestern nicht blockieren."""
    idx = scriptsearch._index(conn, module_id)
    by_key = {(d["file"]["id"], d["page"]): set(d["tf"]) for d in idx["docs"]}
    covered = [(k, v) for k, v in by_key.items() if k in cov_pages and len(v) >= 8]
    memo = {}

    def twin(fid, page):
        k = (fid, page)
        if k in memo:
            return memo[k]
        toks = by_key.get(k)
        hit = None
        if toks and len(toks) >= 8:
            for ck, cv in covered:
                if ck[0] != fid and len(toks & cv) / len(toks | cv) >= 0.8:
                    hit = ck
                    break
        memo[k] = hit
        return hit
    return twin


def candidates(conn, module_id: int, cov: dict, new_pages: set) -> dict:
    rows = db.rows(conn, "SELECT * FROM task_index WHERE module_id=? AND source!='loesung' ORDER BY source, file_id, page_from", (module_id,))
    ok, excluded = [], []
    twin = _twin_finder(conn, module_id, cov["pages"])
    for t in rows:
        v = task_scope(t, cov["pages"], new_pages, twin)
        if v["ok"]:
            ok.append({**t, "is_new_week": v["new"], "refs": v["refs"]})
        else:
            excluded.append({"id": t["id"], "label": t["label"], "reason": v["reason"]})
    return {"ok": ok, "excluded": excluded}


# ============================================================================ Plaene (Zeitplan)
def _expected(conn, module_id: int) -> list[str]:
    m = db.row(conn, "SELECT expected_materials FROM modules WHERE id=?", (module_id,))
    try:
        v = json.loads((m or {}).get("expected_materials") or "[]")
    except json.JSONDecodeError:
        v = []
    return [x for x in v if x in EXPECTABLE]


def refresh_plans(conn, module_id: int, user_id: str = LOCAL_USER, now: datetime | None = None) -> list[dict]:
    """Legt je Lehrwoche mit neu markiertem Stoff einen Plan an (gleicher Stoffumfang -> gleicher Plan)."""
    now = _now(now)
    s = _settings(conn)
    full = coverage(conn, module_id, user_id=user_id)
    weeks = sorted({sg["week"] for sg in full["segments"] if sg["week"]})
    out = []
    for w in weeks:
        cov = coverage(conn, module_id, upto_week=w, user_id=user_id, scope=full["scope"])
        week_segs = [sg for sg in cov["segments"] if sg["week"] == w]
        published = db.rows(conn, "SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND status='veroeffentlicht' AND scope=? ORDER BY part",
                            (module_id, w, full["scope"]))
        done_pages = set()
        for p in published:
            for sg in json.loads(p["coverage"])["new"]:
                done_pages |= {(sg["file_id"], x) for x in range(sg["from"], sg["to"] + 1)}
        new = []
        for sg in week_segs:
            pg = [x for x in range(sg["from"], sg["to"] + 1) if (sg["file_id"], x) not in done_pages]
            if pg:
                new.append({**sg, "from": pg[0], "to": pg[-1]})
        if not new:
            continue
        key = scope_key(cov["segments"]) + (f"-t{len(published) + 1}" if published else "")
        existing = db.row(conn, "SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND scope_key=?", (module_id, w, key))
        if existing:
            out.append(existing)
            continue
        # Unveroeffentlichte Plaene mit altem Stoffumfang dieser Woche werden ersetzt (nie veroeffentlichte!)
        conn.execute("UPDATE wt_plans SET status='ersetzt' WHERE module_id=? AND week_no=? AND scope=? AND status IN ('geplant','wartet','fehlgeschlagen')",
                     (module_id, w, full["scope"]))
        end = max(sg["lecture_end"] for sg in new)
        pub = datetime.fromisoformat(end) + timedelta(hours=s["publish_hours"])
        dl = pub + timedelta(hours=s["max_delay_hours"])
        covj = {"new": new, "prior": [sg for sg in cov["segments"] if sg["week"] < w], "blocked": cov["blocked"]}
        try:
            cur = conn.execute("""INSERT INTO wt_plans(module_id, week_no, part, scope, scope_key, user_id, coverage, lecture_end, publish_at, deadline_at,
                                  status, expected, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                               (module_id, w, len(published) + 1, full["scope"], key, user_id if full["scope"] == "personal" else None,
                                json.dumps(covj, ensure_ascii=False), end, pub.isoformat(), dl.isoformat(), "geplant",
                                json.dumps(_expected(conn, module_id)), now.isoformat()))
            out.append(db.row(conn, "SELECT * FROM wt_plans WHERE id=?", (cur.lastrowid,)))
        except Exception:  # noqa: BLE001 - parallel entstanden (UNIQUE)
            out.append(db.row(conn, "SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND scope_key=?", (module_id, w, key)))
    return out


def _claim(conn, plan_id: int, now: datetime, minutes: int = 20) -> str | None:
    tok = uuid.uuid4().hex
    cur = conn.execute("""UPDATE wt_plans SET lock_token=?, lock_until=? WHERE id=? AND status IN ('geplant','wartet','fehlgeschlagen')
                          AND (lock_until IS NULL OR lock_until < ?)""", (tok, (now + timedelta(minutes=minutes)).isoformat(), plan_id, now.isoformat()))
    return tok if cur.rowcount == 1 else None


def _release(conn, plan_id: int, tok: str) -> None:
    conn.execute("UPDATE wt_plans SET lock_token=NULL, lock_until=NULL WHERE id=? AND lock_token=?", (plan_id, tok))


# ============================================================================ Hintergrundlauf (iPad: 8, 15, 20 Uhr)
# Das iPad bekommt vom System nur zu festen Zeiten einen Hintergrundlauf (BackgroundSchedule im Swift-Kern: 8, 15 und
# 20 Uhr, "fruehestens"). Ob ein Lauf etwas zu tun haette und wann der naechste noetig ist, entscheidet sich allein aus
# der Uhrzeit und dem Stand der Plaene; das steht hier als reine Logik, damit Python und Swift dieselbe Antwort geben
# (Pruefdaten `weekly.json`, Schritte "background" und "background_cases"). Am PC laeuft stattdessen `_weekly_loop`.
BACKGROUND_HOURS = (8, 15, 20)
OPEN_STATES = ("geplant", "wartet", "fehlgeschlagen")
MAX_ATTEMPTS = 3


def slot_at_or_after(t: datetime, hours=BACKGROUND_HOURS) -> datetime:
    """Erster Termin aus `hours` (volle Stunde, naive Ortszeit) am Tag von `t` ab `t` einschliesslich, sonst der erste am
    naechsten Tag. Kalendertage ohne Zeitzone, darum gilt um die Zeitumstellung weiter 8:00 Ortszeit."""
    for h in sorted(set(hours)):
        s = t.replace(hour=h, minute=0, second=0, microsecond=0)
        if s >= t:
            return s
    return (t + timedelta(days=1)).replace(hour=min(hours), minute=0, second=0, microsecond=0)


def next_slot(now: datetime, hours=BACKGROUND_HOURS) -> datetime:
    """Naechster Termin streng nach `now` (wie `BackgroundSchedule.next`)."""
    return slot_at_or_after(now + timedelta(seconds=1), hours)


def background_snapshot(conn, now: datetime) -> dict:
    """Nur lesen: alles, was `background_decision` braucht. `reusable` = es gibt schon einen geprueften oder
    veroeffentlichten Test mit demselben Stoffumfang (dann zaehlt das Tageslimit nicht, wie in `process_plan`)."""
    now = _now(now)
    s = _settings(conn)
    settings = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM settings WHERE key='auto_tests'")}
    today_n = db.row(conn, "SELECT COUNT(*) AS n FROM wt_defs WHERE substr(created_at,1,10)=?", (now.date().isoformat(),))["n"]
    plans = []
    for p in db.rows(conn, "SELECT * FROM wt_plans WHERE status IN ('geplant','wartet','fehlgeschlagen') ORDER BY id"):
        reuse = db.row(conn, "SELECT id FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht') LIMIT 1",
                       (p["module_id"], p["scope_key"]))
        plans.append({"id": p["id"], "status": p["status"], "publish_at": p["publish_at"], "deadline_at": p["deadline_at"],
                      "attempts": int(p["attempts"] or 0), "lock_until": p["lock_until"], "reusable": bool(reuse)})
    return {"auto_tests": settings.get("auto_tests", "1") == "1", "daily_limit": s["daily_limit"], "today_defs": today_n, "plans": plans}


def background_decision(snap: dict, now: datetime, ai: bool = True, busy: bool = False, hours=BACKGROUND_HOURS) -> dict:
    """Was ein Hintergrundlauf um `now` taete und wann der naechste fruehestens noetig ist.

    action: off (auto_tests aus), no_ai (keine KI verbunden), busy (anderer Auftrag laeuft), limit (faellig, aber
    Tageslimit erreicht und nichts wiederverwendbar), run (mindestens ein Plan faellig), idle (nichts faellig).
    due: die faelligen Plaene, genau die Bedingung aus `tick` und `_claim` (offen, publish_at <= now, attempts < 3,
    keine laufende Sperre). next_at: naechster Termin aus `hours`, an dem es etwas zu tun geben kann, None wenn kein
    offener Plan mit Versuchen uebrig ist oder auto_tests aus ist. Die Reihenfolge off, no_ai, busy ist die von
    `WeeklyAutoTick.run` im Swift-Kern."""
    now = _now(now)
    out = {"action": "idle", "due": [], "next_at": None}
    if not snap.get("auto_tests", True):
        out["action"] = "off"
        return out
    nxt, reusable = [], False
    for p in snap.get("plans", []):
        if p["status"] not in OPEN_STATES or int(p["attempts"]) >= MAX_ATTEMPTS:
            continue
        lock = datetime.fromisoformat(p["lock_until"]) if p.get("lock_until") else None
        pub = datetime.fromisoformat(p["publish_at"])
        if lock is not None and lock >= now:
            nxt.append(next_slot(lock, hours))                  # `_claim` braucht lock_until < now
        elif pub > now:
            nxt.append(slot_at_or_after(pub, hours))
        else:
            out["due"].append(p["id"])
            reusable = reusable or bool(p.get("reusable"))
    if out["due"]:
        if int(snap.get("today_defs", 0)) >= int(snap.get("daily_limit", 0)) and not reusable:
            out["action"] = "limit"                             # erst morgen zaehlt das Tageslimit neu
            nxt.append(slot_at_or_after((now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0), hours))
        else:
            out["action"] = "run"
            nxt.append(next_slot(now, hours))                   # wartend oder fehlgeschlagen: beim naechsten Termin wieder
    if not ai:
        out["action"] = "no_ai"
    elif busy:
        out["action"] = "busy"
    out["next_at"] = min(nxt).isoformat() if nxt else None
    return out


def tick(now: datetime | None = None, user_id: str = LOCAL_USER, log=print) -> dict:
    """Ein Durchlauf: indexieren, Plaene aktualisieren, faellige Tests erzeugen/veroeffentlichen, Nachtraege anbieten."""
    now = _now(now)
    res = {"published": [], "waiting": [], "failed": [], "nachtraege": []}
    with db.cursor() as conn:
        ensure_schema(conn)
        mods = [r["module_id"] for r in db.rows(conn, """SELECT DISTINCT l.module_id FROM lecture_markers l JOIN modules m ON m.id=l.module_id
                                                           WHERE l.deleted_at IS NULL AND COALESCE(m.weekly_test,1)=1 AND COALESCE(m.active,1)=1""")]
        for mid in mods:
            for fid in {r["file_id"] for r in db.rows(conn, "SELECT DISTINCT file_id FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", (mid,))}:
                revalidate_markers(conn, fid)
            index_module(conn, mid, now, log)
            refresh_plans(conn, mid, user_id, now)
        due = db.rows(conn, """SELECT id FROM wt_plans WHERE status IN ('geplant','wartet','fehlgeschlagen') AND publish_at <= ? AND attempts < 3
                               ORDER BY publish_at""", (now.isoformat(),))
    for p in due:
        r = process_plan(p["id"], now, log)
        if r:
            res[r["result"]].append(r)
    with db.cursor() as conn:
        pubs = db.rows(conn, "SELECT id FROM wt_plans WHERE status='veroeffentlicht'")
    for p in pubs:
        try:
            n = offer_nachtrag(p["id"], now, log)
            if n:
                res["nachtraege"].append(n)
        except Exception as e:  # noqa: BLE001
            log(f"Nachtrag Plan {p['id']}: {e}")
    return res


def process_plan(plan_id: int, now: datetime | None = None, log=print) -> dict | None:
    now = _now(now)
    with db.cursor() as conn:
        tok = _claim(conn, plan_id, now)
        if not tok:
            return None                                       # ein anderer Lauf arbeitet schon daran
        plan = db.row(conn, "SELECT * FROM wt_plans WHERE id=?", (plan_id,))
    try:
        with db.cursor() as conn:
            covj = json.loads(plan["coverage"])
            new_pages = {(sg["file_id"], x) for sg in covj["new"] for x in range(sg["from"], sg["to"] + 1)}
            cov_pages = new_pages | {(sg["file_id"], x) for sg in covj["prior"] for x in range(sg["from"], sg["to"] + 1)}
            cands = candidates(conn, plan["module_id"], {"pages": cov_pages}, new_pages)
            expected = json.loads(plan["expected"] or "[]")
            have = {c["source"] for c in cands["ok"] if c["is_new_week"]}
            missing = [e for e in expected if e not in have]
            conn.execute("UPDATE wt_plans SET last_check=?, missing=? WHERE id=?", (now.isoformat(), json.dumps(missing), plan_id))
            if missing and now < datetime.fromisoformat(plan["deadline_at"]):
                conn.execute("UPDATE wt_plans SET status='wartet' WHERE id=?", (plan_id,))
                return {"result": "waiting", "plan_id": plan_id, "missing": missing}
            s = _settings(conn)
            today_n = db.row(conn, "SELECT COUNT(*) AS n FROM wt_defs WHERE substr(created_at,1,10)=?", (now.date().isoformat(),))["n"]
            reuse = db.row(conn, "SELECT * FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht') ORDER BY id DESC LIMIT 1",
                           (plan["module_id"], plan["scope_key"]))
            if not reuse and today_n >= s["daily_limit"]:
                conn.execute("UPDATE wt_plans SET last_error=? WHERE id=?", (f"Tageslimit für KI-Tests erreicht ({s['daily_limit']}), nächster Versuch beim nächsten Lauf.", plan_id))
                return {"result": "waiting", "plan_id": plan_id, "missing": ["ki-limit"]}
            quota = _QUOTA.get()
            if not reuse and quota is not None and (why := quota.check()):
                conn.execute("UPDATE wt_plans SET status='wartet', last_error=? WHERE id=?", (why, plan_id))
                return {"result": "waiting", "plan_id": plan_id, "missing": ["kontingent"]}
            ctx = build_context(conn, plan, cands, missing)
        d = reuse or generate_weekly(ctx, now, log)
        if not reuse and quota is not None:
            quota.consume(f"weekly:{plan_id}:{d['id']}")
        with db.cursor() as conn:
            publish(conn, plan_id, d["id"], now)
        log(f"Wochentest veröffentlicht: Modul {plan['module_id']} Woche {plan['week_no']} (Def {d['id']})")
        return {"result": "published", "plan_id": plan_id, "def_id": d["id"], "missing": missing}
    except Exception as e:  # noqa: BLE001
        with db.cursor() as conn:
            conn.execute("UPDATE wt_plans SET status='fehlgeschlagen', last_error=?, attempts=attempts+1 WHERE id=?", (str(e)[:800], plan_id))
        log(f"Wochentest Plan {plan_id} fehlgeschlagen: {e}")
        return {"result": "failed", "plan_id": plan_id, "error": str(e)[:300]}
    finally:
        with db.cursor() as conn:
            _release(conn, plan_id, tok)


# ============================================================================ Material fuer die KI
def _page_text(conn, file_id: str, page: int) -> str:
    p = page_texts(conn, file_id)
    return scriptsearch.normalize(p[page - 1]) if 0 < page <= len(p) else ""


def _short(t: str, n: int) -> str:
    t = re.sub(r"[ \t]+", " ", re.sub(r"\n{2,}", "\n", t or "")).strip()
    return t if len(t) <= n else t[:n].rsplit(" ", 1)[0] + " …"


def build_context(conn, plan: dict, cands: dict, missing: list[str], n_questions: int | None = None) -> dict:
    covj = json.loads(plan["coverage"])
    mod = db.row(conn, "SELECT * FROM modules WHERE id=?", (plan["module_id"],))
    s = _settings(conn)
    pages_new = [(sg["file_id"], x) for sg in covj["new"] for x in range(sg["from"], sg["to"] + 1)]
    if len(pages_new) > 60:                                  # sehr viel Stoff (Probeklausur): gleichmaessig auswaehlen
        step = len(pages_new) / 60
        pages_new = [pages_new[int(i * step)] for i in range(60)]
    per_page = max(250, min(900, 15000 // max(1, len(pages_new))))
    lec = []
    for fid, p in pages_new:
        t = _page_text(conn, fid, p)
        if len(_norm(t)) >= 15:
            lec.append({"id": f"L{len(lec) + 1}", "file_id": fid, "page": p, "new": True, "text": _short(t, per_page)})
    prior = []
    for sg in covj["prior"][-12:]:
        prior.append({"id": f"L{len(lec) + len(prior) + 1}", "file_id": sg["file_id"], "page": sg["to"], "new": False,
                      "text": f"Bereits behandelt (Vorwissen): {sg.get('topic') or ''} – Seiten {sg['from']}–{sg['to']}: "
                              + _short(_page_text(conn, sg["file_id"], sg["from"]), 160)})
    # Aufgaben: zuerst neuer Stoff, je Quelle die besten; Altklausur getrennt
    ok = sorted(cands["ok"], key=lambda c: (not c["is_new_week"], -(c["refs"][0]["score"] if c["refs"] else 0)))
    picked, per_src = [], Counter()
    for c in ok:
        lim = 4 if c["source"] == "altklausur" else 5
        if per_src[c["source"]] >= lim:
            continue
        per_src[c["source"]] += 1
        picked.append(c)
    tasks = [{"id": f"A{i + 1}", "task_id": c["id"], "source": c["source"], "label": c["label"], "is_new_week": c["is_new_week"],
              "exam_term": c.get("exam_term"), "points": c.get("points"), "difficulty": c.get("difficulty"), "text": _short(c["text"], 1400),
              "solution": _short(c.get("solution_text") or "", 900), "file_id": c["file_id"], "page_from": c["page_from"]} for i, c in enumerate(picked)]
    topic = " · ".join(dict.fromkeys(sg.get("topic") for sg in covj["new"] if sg.get("topic")))[:160]
    return {"plan": plan, "module": mod, "lecture": lec, "prior": prior, "tasks": tasks, "missing": missing, "topic": topic,
            "excluded": cands["excluded"][:50], "n": n_questions or s["questions"], "exam_reuse": (mod or {}).get("exam_reuse") or "paraphrase",
            "material_hash": _h([(x["file_id"], x["page"]) for x in lec], sorted(t["task_id"] for t in tasks), [t["text"] for t in tasks])}


# ============================================================================ KI-Erzeugung + Pruefung
def _ask(prompt: str, system: str = "") -> str:      # in Tests ersetzt
    from . import ai, config
    if config.is_hosted():
        # Dienst: Studora-KI mit Budget und Protokoll je Konto (app/ai_backend.py); ein Fehler dort (Budget, Rate,
        # nicht eingerichtet) laesst den Plan "fehlgeschlagen" mit Grund, wie jeder andere KI-Fehler
        from . import ai_backend
        try:
            return ai_backend.complete(config.current_user_id(), "weekly_test", system, prompt).text
        except ai_backend.AIUnavailable as e:
            raise WeeklyError(f"Studora-KI: {e}") from e
    return ai.ask(prompt, system)


# Kontingent je Konto im Dienst (app/jobs.py setzt je Job ein Objekt mit check() -> Grund | None und consume(id)):
# geprueft, bevor ein neuer Test erzeugt wird; verbraucht wird je erzeugtem Test. Je Arbeiter-Thread eigener Wert.
_QUOTA = contextvars.ContextVar("weekly_quota", default=None)


def _parse(text: str):
    from . import ai
    return ai.parse_json(text)


SYSTEM = ("Du erstellst Pruefungsaufgaben fuer ein Ingenieur-/Informatikstudium an der Leibniz Universitaet Hannover. "
          "Antworte ausschliesslich mit gueltigem JSON ohne Markdown-Zaeune. Formeln als Text.")


def _materials_block(ctx: dict) -> str:
    lines = ["NEUER STOFF DIESER WOCHE (nur bis zum Seitenmarker):"]
    lines += [f"[{x['id']}] Seite {x['page']}: {x['text']}" for x in ctx["lecture"] if x["new"]]
    if ctx["prior"]:
        lines += ["", "VORWISSEN (frueher behandelt, darf vorausgesetzt werden):"]
        lines += [f"[{x['id']}] {x['text']}" for x in ctx["prior"]]
    if ctx["tasks"]:
        lines += ["", "PASSENDE UEBUNGS- UND KLAUSURAUFGABEN (bereits geprueft: nur behandelter Stoff):"]
        for t in ctx["tasks"]:
            lines.append(f"[{t['id']}] {SOURCE_TXT.get(t['source'], t['source'])}{' ' + t['exam_term'] if t.get('exam_term') else ''}"
                         f"{' (' + str(t['points']) + ' P.)' if t.get('points') else ''}: {t['text']}"
                         + (f"\n    Musterloesung: {t['solution']}" if t.get("solution") else ""))
    return "\n".join(lines)


def _exam_ids(ctx: dict) -> list[str]:
    return [t["id"] for t in ctx["tasks"] if t["source"] == "altklausur"]


def _rule_lines(ctx: dict, kind: str, ex: list[str], reuse: str) -> str:
    """Verteilung und Altklausur. Wochentest mit 15 Aufgaben: die Regel des Inhabers vom 29.10.2026 wie in app/ai.py
    (genau 4 leicht, 6 mittel, 5 schwer; mit Altklausur ist genau EINE der schweren an sie angelehnt)."""
    n = ctx["n"]
    if kind == "WOCHENTEST" and n == ai.WEEK_TEST_TOTAL:
        d = ai.WEEK_TEST_DIFFICULTY
        lines = f'- Genau {d["leicht"]} leichte (level "leicht"), genau {d["mittel"]} mittlere (level "mittel") und genau {d["schwer"]} schwere Aufgaben (level "schwer", klausurnah).'
        exam = (f'- Genau EINE der {d["schwer"]} schweren Aufgaben ist an eine dieser Altklausuraufgaben angelehnt: {", ".join(ex)} '
                f'(from_exam setzen, sie zaehlt zu den {n} Aufgaben). {reuse}' if ex else
                "- Es gibt keine passenden Altklausuraufgaben: nur neue Uebungsaufgaben (from_exam immer null).")
        return lines + "\n" + exam
    n_easy = max(1, round(n / 3))
    lines = f'- Etwa {n_easy} leichte Grundlagenaufgaben (level "leicht"), der Rest mittel bis anspruchsvoll (level "mittel" oder "schwer").'
    exam = (f"- Baue 1–2 der Altklausuraufgaben {', '.join(ex)} ein (sie zaehlen zu den {n} Aufgaben). {reuse}" if ex else
            "- Es gibt keine passenden Altklausuraufgaben: nur neue Uebungsaufgaben.")
    return lines + "\n" + exam


def _gen_prompt(ctx: dict, kind: str = "WOCHENTEST", extra: str = "") -> str:
    n = ctx["n"]
    ex = _exam_ids(ctx)
    reuse = ("Altklausuraufgaben duerfen woertlich uebernommen werden (Quelle angeben)." if ctx["exam_reuse"] == "original" else
             "Altklausuraufgaben NICHT woertlich uebernehmen: erstelle thematisch vergleichbare NEUE Aufgaben im gleichen Stil "
             "(andere Zahlen, anderer Kontext) und gib die Altklausur als Quelle an.")
    return f"""### AUFTRAG: {kind}
Modul: {ctx['module']['name']} · Lehrwoche {ctx['plan']['week_no']}{' · Thema: ' + ctx['topic'] if ctx['topic'] else ''}

Erstelle GENAU {n} Aufgaben:
{_rule_lines(ctx, kind, ex, reuse)}
- Decke ALLE neuen Themen dieser Woche ausgewogen ab. Jede Aufgabe muss NUR mit dem Material unten loesbar sein.
- NIEMALS Inhalte abfragen, die nicht im Material stehen (spaetere Kapitel sind noch nicht behandelt).
- Die Aufgabenstellung darf die Loesung nicht verraten.
- Jede Aufgabe: eindeutige Stellung, Thema, Schwierigkeit 1-5, ueberpruefte Musterloesung, nachvollziehbarer Loesungsweg, Bewertungskriterien mit Teilpunkten.
- "refs": IDs des Materials (z. B. "L3", "A2"), auf dem die Aufgabe beruht. Nur IDs aus der Liste unten.
- Punkte gesamt = 100.
{extra}
{_materials_block(ctx)}

Antworte als JSON:
{{"title": "kurzer Titel", "questions": [{{"nr": 1, "level": "leicht"|"mittel"|"schwer", "type": "mc"|"short"|"calc",
  "topic": "...", "difficulty": 1-5, "question": "...", "options": ["A ...","B ...","C ...","D ..."] (nur mc),
  "answer": "Musterloesung (bei mc die exakte Option)", "steps": ["Schritt 1", "..."],
  "rubric": [{{"criterion": "...", "points": Zahl}}], "points": Zahl, "refs": ["L1","A2"],
  "from_exam": "A-ID oder null", "exam_mode": "original"|"angelehnt"|null}}]}}"""


def _review_prompt(ctx: dict, qs: list[dict]) -> str:
    return f"""### AUFTRAG: PRUEFUNG
Du bist Fachpruefer. Pruefe jede Aufgabe streng:
1. Ist sie allein mit dem angegebenen Material loesbar (kein Stoff spaeterer Kapitel)?
2. Ist die Musterloesung fachlich korrekt und vollstaendig, der Loesungsweg nachvollziehbar?
3. Ist die Aufgabenstellung eindeutig und verraet sie die Loesung nicht?
Rechne Rechenaufgaben selbst nach.

{_materials_block(ctx)}

AUFGABEN:
{json.dumps(qs, ensure_ascii=False)}

Antworte als JSON: {{"results": [{{"nr": 1, "ok": true|false, "solvable": true|false, "solution_correct": true|false, "issue": "..."}}]}}"""


def _sim(a: str, b: str) -> float:
    ta, tb = set(scriptsearch.tokens(a)), set(scriptsearch.tokens(b))
    return len(ta & tb) / max(1, len(ta | tb))


def validate(ctx: dict, qs: list[dict], kind: str = "wochentest") -> list[str]:
    """Feste Regeln, unabhaengig von der KI. Leere Liste = bestanden."""
    probs = []
    allowed = {x["id"] for x in ctx["lecture"]} | {x["id"] for x in ctx["prior"]} | {t["id"] for t in ctx["tasks"]}
    new_ids = {x["id"] for x in ctx["lecture"] if x["new"]} | {t["id"] for t in ctx["tasks"] if t.get("is_new_week")}
    exam = set(_exam_ids(ctx))
    tasks = {t["id"]: t for t in ctx["tasks"]}
    if not isinstance(qs, list) or not qs:
        return ["keine Aufgaben"]
    n = ctx["n"]
    if kind in ("wochentest", "probeklausur") and len(qs) != n:
        probs.append(f"{len(qs)} statt {n} Aufgaben")
    if kind == "wochentest" and n == ai.WEEK_TEST_TOTAL:
        # Regel des Inhabers (29.10.2026, wie ai.check_week_test); "kurz" aus Version 3.2 zaehlt als "leicht"
        level = lambda q: "leicht" if q.get("level") == "kurz" else q.get("level")   # noqa: E731
        counts = {k: sum(1 for q in qs if level(q) == k) for k in ai.WEEK_TEST_DIFFICULTY}
        if counts != ai.WEEK_TEST_DIFFICULTY:
            probs.append("Verteilung " + ", ".join(f"{counts[k]} {k}" for k in ai.WEEK_TEST_DIFFICULTY) + " statt 4 leicht, 6 mittel, 5 schwer")
        from_exam = [q for q in qs if q.get("from_exam")]
        if exam and (len(from_exam) != 1 or level(from_exam[0]) != "schwer"):
            probs.append(f"{len(from_exam)} Altklausuraufgaben (erwartet genau eine schwere)")
        if not exam and from_exam:
            probs.append("Altklausuraufgabe angegeben, obwohl keine passende vorhanden ist")
    elif kind == "wochentest" and n >= 15:
        from_exam = [q for q in qs if q.get("from_exam")]
        if exam and not 1 <= len(from_exam) <= 2:
            probs.append(f"{len(from_exam)} Altklausuraufgaben (erwartet 1–2)")
    hit_new = 0
    for i, q in enumerate(qs, 1):
        nr = q.get("nr", i)
        for f in ("question", "answer", "topic"):
            if not str(q.get(f) or "").strip():
                probs.append(f"Aufgabe {nr}: Feld '{f}' fehlt")
        if not q.get("steps"):
            probs.append(f"Aufgabe {nr}: Lösungsweg fehlt")
        try:
            if float(q.get("points") or 0) <= 0:
                probs.append(f"Aufgabe {nr}: keine Punkte")
        except (TypeError, ValueError):
            probs.append(f"Aufgabe {nr}: Punkte ungültig")
        try:
            if not 1 <= int(q.get("difficulty") or 0) <= 5:
                probs.append(f"Aufgabe {nr}: Schwierigkeit fehlt")
        except (TypeError, ValueError):
            probs.append(f"Aufgabe {nr}: Schwierigkeit ungültig")
        refs = q.get("refs") or []
        if not refs:
            probs.append(f"Aufgabe {nr}: kein Themenbezug (refs)")
        bad = [r for r in refs if r not in allowed]
        if bad:
            probs.append(f"Aufgabe {nr}: Bezug auf nicht freigegebenes Material {bad}")
        if set(refs) & new_ids:
            hit_new += 1
        if q.get("type") == "mc":
            opts = q.get("options") or []
            if len(opts) < 3 or q.get("answer") not in opts:
                probs.append(f"Aufgabe {nr}: Multiple-Choice-Optionen/Lösung passen nicht")
        else:
            a = _norm(str(q.get("answer") or ""))
            if len(a) >= 8 and a in _norm(str(q.get("question") or "")):
                probs.append(f"Aufgabe {nr}: Lösung steht in der Aufgabenstellung")
        fe = q.get("from_exam")
        if fe:
            if fe not in exam:
                probs.append(f"Aufgabe {nr}: from_exam {fe} ist keine freigegebene Altklausuraufgabe")
            elif ctx["exam_reuse"] != "original" and _sim(q.get("question", ""), tasks[fe]["text"]) > 0.6:
                probs.append(f"Aufgabe {nr}: zu nah an der Original-Altklausur (Nutzungsrechte: nur angelehnte Aufgabe erlaubt)")
    if kind == "wochentest" and ctx["lecture"] and hit_new < max(1, int(0.6 * len(qs))):
        probs.append(f"nur {hit_new} Aufgaben behandeln den neuen Stoff dieser Woche")
    if kind == "wochentest":
        new_files = {x["file_id"] for x in ctx["lecture"] if x["new"]}
        used = {next((x["file_id"] for x in ctx["lecture"] if x["id"] == r), None) for q in qs for r in (q.get("refs") or [])}
        for fid in new_files - used:
            probs.append(f"neuer Stoff aus Dokument {fid} wird von keiner Aufgabe abgedeckt")
    return probs


def _run_ai_pipeline(ctx: dict, kind_tag: str, kind: str, log) -> tuple[dict, dict]:
    """Entwurf -> Regeln -> Fachpruefung -> hoechstens eine Reparatur. Wirft WeeklyError, wenn nicht bestanden."""
    qa = {"rounds": []}
    try:
        res = _parse(_ask(_gen_prompt(ctx, kind_tag), SYSTEM))
    except Exception as e:  # noqa: BLE001
        raise WeeklyError(f"KI-Entwurf unbrauchbar: {e}") from e
    qs = res.get("questions") if isinstance(res, dict) else None
    for rnd in range(2):
        probs = validate(ctx, qs or [], kind)
        review = []
        if not probs:
            try:
                rv = _parse(_ask(_review_prompt(ctx, qs), SYSTEM))
                review = [r for r in (rv.get("results") or []) if not (r.get("ok") and r.get("solvable", True) and r.get("solution_correct", True))]
                if len(rv.get("results") or []) < len(qs):
                    review.append({"nr": None, "issue": "Fachprüfung unvollständig"})
            except Exception as e:  # noqa: BLE001
                review = [{"nr": None, "issue": f"Fachprüfung fehlgeschlagen: {e}"}]
        qa["rounds"].append({"rules": probs, "review": review})
        if not probs and not review:
            qa["passed"] = True
            return {**res, "questions": qs}, qa
        if rnd == 1:
            break
        fix = "\n".join(probs + [f"Aufgabe {r.get('nr')}: {r.get('issue')}" for r in review])
        try:
            res = _parse(_ask(_gen_prompt(ctx, kind_tag, extra=f"\nKORREKTUR NOETIG. Behebe diese Probleme vollstaendig:\n{fix}\n"), SYSTEM))
            qs = res.get("questions") if isinstance(res, dict) else None
        except Exception as e:  # noqa: BLE001
            qa["rounds"].append({"rules": [f"Reparatur unbrauchbar: {e}"], "review": []})
            break
    qa["passed"] = False
    last = qa["rounds"][-1]
    raise WeeklyError("Test nicht freigegeben (Prüfung nicht bestanden): " + "; ".join((last["rules"] + [str(r.get("issue")) for r in last["review"]])[:6]))


def _sources_of(ctx: dict, qs: list[dict]) -> dict:
    lec = {x["id"]: x for x in ctx["lecture"] + ctx["prior"]}
    tasks = {t["id"]: t for t in ctx["tasks"]}
    per_q = []
    for q in qs:
        r = []
        for ref in q.get("refs") or []:
            if ref in lec:
                r.append({"type": "vorlesung", "file_id": lec[ref]["file_id"], "page": lec[ref]["page"], "new": lec[ref]["new"]})
            elif ref in tasks:
                t = tasks[ref]
                r.append({"type": t["source"], "task_id": t["task_id"], "file_id": t["file_id"], "label": t["label"], "page": t["page_from"]})
        per_q.append({"nr": q.get("nr"), "refs": r, "from_exam": (tasks.get(q.get("from_exam")) or {}).get("task_id")})
    return {"per_question": per_q, "candidates": [t["task_id"] for t in ctx["tasks"]],
            "lecture_pages": [[x["file_id"], x["page"]] for x in ctx["lecture"]], "missing": ctx["missing"],
            "excluded": ctx["excluded"], "exam_candidates": len(_exam_ids(ctx)),
            "used": sorted({(SOURCE_TXT.get(t["source"], t["source"]), t["label"]) for t in ctx["tasks"]
                            if any(t["id"] in (q.get("refs") or []) or t["id"] == q.get("from_exam") for q in qs)})}


def _store_def(ctx: dict, res: dict, qa: dict, kind: str, now: datetime, parent_id: int | None = None) -> dict:
    plan = ctx["plan"]
    qs = res["questions"]
    for i, q in enumerate(qs, 1):
        q["nr"] = i
    with db.cursor() as conn:
        ex = db.row(conn, "SELECT * FROM wt_defs WHERE kind=? AND module_id=? AND scope_key=? AND material_hash=?",
                    (kind, plan["module_id"], plan["scope_key"], ctx["material_hash"]))
        if ex:
            return ex
        ver = (db.row(conn, "SELECT MAX(version) AS v FROM wt_defs WHERE module_id=? AND scope_key=?", (plan["module_id"], plan["scope_key"]))["v"] or 0) + 1
        title = res.get("title") or ("Wochentest" if kind == "wochentest" else "Nachtrag")
        mod_min = (ctx["module"] or {}).get("test_minutes")
        dur = int(res.get("duration_min") or mod_min or (90 if kind == "probeklausur" else 60 if kind == "wochentest" else 20))
        cur = conn.execute("""INSERT INTO wt_defs(kind, plan_id, parent_id, module_id, week_no, scope_key, material_hash, version, title, topic, duration_min,
                              questions, sources, coverage, qa, status, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                           (kind, plan.get("id"), parent_id, plan["module_id"], plan.get("week_no"), plan["scope_key"], ctx["material_hash"], ver,
                            title, ctx["topic"], dur, json.dumps(qs, ensure_ascii=False), json.dumps(_sources_of(ctx, qs), ensure_ascii=False),
                            plan["coverage"], json.dumps(qa, ensure_ascii=False), "geprueft", now.isoformat()))
        return db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (cur.lastrowid,))


def generate_weekly(ctx: dict, now: datetime | None = None, log=print) -> dict:
    now = _now(now)
    if not ctx["lecture"]:
        raise WeeklyError("Kein Text auf den markierten Vorlesungsseiten – Test kann nicht sicher erzeugt werden.")
    with _GEN_LOCK:                                          # nie zwei KI-Laeufe fuer denselben Stoff gleichzeitig
        with db.cursor() as conn:
            ex = db.row(conn, "SELECT * FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht')",
                        (ctx["plan"]["module_id"], ctx["plan"]["scope_key"]))
        if ex:
            return ex
        res, qa = _run_ai_pipeline(ctx, "WOCHENTEST", "wochentest", log)
        return _store_def(ctx, res, qa, "wochentest", now)


# ============================================================================ Veroeffentlichen, Versuche, Rangliste
def publish(conn, plan_id: int, def_id: int, now: datetime) -> None:
    d = db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (def_id,))
    if not d or d["status"] not in ("geprueft", "veroeffentlicht"):
        raise WeeklyError("Nur geprüfte Testversionen dürfen veröffentlicht werden.")
    qa = json.loads(d["qa"] or "{}")
    if not qa.get("passed"):
        raise WeeklyError("Prüfprotokoll fehlt – keine Veröffentlichung.")
    if d["status"] != "veroeffentlicht":
        conn.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", (now.isoformat(), def_id))
    conn.execute("UPDATE wt_plans SET status='veroeffentlicht', def_id=?, last_error=NULL WHERE id=?", (def_id, plan_id))
    plan = db.row(conn, "SELECT * FROM wt_plans WHERE id=?", (plan_id,))
    attempt_for(conn, def_id, plan.get("user_id") or LOCAL_USER)
    if d["kind"] == "wochentest":
        tid = db.row(conn, "SELECT id FROM tests WHERE def_id=? AND user_id=?", (def_id, plan.get("user_id") or LOCAL_USER))["id"]
        conn.execute("""UPDATE study_tasks SET test_id=? WHERE test_id IS NULL AND type='test' AND package_id IN
                        (SELECT id FROM study_packages WHERE module_id=? AND week_no=?)""", (tid, plan["module_id"], plan["week_no"]))


def attempt_for(conn, def_id: int, user_id: str = LOCAL_USER) -> int:
    """Bearbeitungsversuch eines Teilnehmers (Kopie der unveraenderlichen Testversion in `tests`)."""
    ex = db.row(conn, "SELECT id FROM tests WHERE def_id=? AND user_id=?", (def_id, user_id))
    if ex:
        return ex["id"]
    d = db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (def_id,))
    if not d or d["status"] != "veroeffentlicht":
        raise WeeklyError("Testversion ist nicht veröffentlicht.")
    m = db.row(conn, "SELECT name FROM modules WHERE id=?", (d["module_id"],))
    label = {"wochentest": f"Lehrwoche {d['week_no']}: ", "nachtrag": f"Nachtrag Lehrwoche {d['week_no']}: ", "probeklausur": "Probeklausur: "}[d["kind"]]
    try:
        cur = conn.execute("""INSERT INTO tests(subject, week_start, title, duration_min, questions, created_at, module_id, week_no, auto, def_id, user_id)
                              VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                           ((m or {}).get("name") or "Modul", None, label + (d["title"] or ""), d["duration_min"], d["questions"], db.now_iso(),
                            d["module_id"], d["week_no"] if d["kind"] != "probeklausur" else None, 0, def_id, user_id))
        return cur.lastrowid
    except Exception:  # noqa: BLE001 - parallel angelegt
        return db.row(conn, "SELECT id FROM tests WHERE def_id=? AND user_id=?", (def_id, user_id))["id"]


def task_test(conn, module_id: int, week_no: int, user_id: str = LOCAL_USER) -> int | None:
    """Testaufgabe des Lernplans ("Gemeinsamer Wochentest Lehrwoche N") in einem Fach mit Markern: der Versuch am
    veroeffentlichten gemeinsamen Wochentest dieser Lehrwoche (erster Teil), statt daneben einen klassischen Test zu
    erzeugen. None = Fach ohne Marker (dann der klassische Wochentest aus app/planner.py)."""
    if not db.row(conn, "SELECT 1 FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", (module_id,)):
        return None
    mine = "module_id=? AND week_no=? AND (user_id=? OR scope='course')"
    p = db.row(conn, f"SELECT def_id FROM wt_plans WHERE {mine} AND status='veroeffentlicht' AND def_id IS NOT NULL ORDER BY part, id LIMIT 1",
               (module_id, week_no, user_id))
    if p:
        return attempt_for(conn, p["def_id"], user_id)
    nxt = db.row(conn, f"SELECT publish_at FROM wt_plans WHERE {mine} AND status IN ('geplant','wartet','fehlgeschlagen') ORDER BY part, id LIMIT 1",
                 (module_id, week_no, user_id))
    if nxt:
        t = datetime.fromisoformat(nxt["publish_at"])
        raise WeeklyError(f"Der gemeinsame Wochentest der Lehrwoche {week_no} erscheint voraussichtlich am {t:%d.%m.} um {t:%H:%M} Uhr.")
    if db.row(conn, "SELECT 1 FROM lecture_markers WHERE module_id=? AND week_no=? AND deleted_at IS NULL", (module_id, week_no)):
        raise WeeklyError(f"Der gemeinsame Wochentest der Lehrwoche {week_no} wird gerade geplant. Bitte später erneut versuchen.")
    raise WeeklyError(f"Für die Lehrwoche {week_no} ist noch kein Vorlesungsstoff markiert („Vorlesung bis hier“ im Skript setzen).")


def grade_consistent(questions: list[dict], answers: dict, ai_result: dict) -> dict:
    """Multiple Choice wird fuer alle Teilnehmer identisch und ohne KI bewertet; KI-Punkte werden auf die Aufgabenpunkte begrenzt."""
    per = {str(p.get("nr")): p for p in (ai_result.get("per_question") or [])}
    out = []
    for q in questions:
        nr = str(q["nr"]); mx = float(q.get("points") or 0)
        p = dict(per.get(nr) or {"nr": q["nr"], "feedback": ""})
        if q.get("type") == "mc":
            right = str(answers.get(nr, "")).strip() == str(q.get("answer", "")).strip()
            p.update(points=mx if right else 0.0, feedback=p.get("feedback") or ("richtig" if right else "falsch"))
        else:
            try:
                p["points"] = max(0.0, min(mx, float(p.get("points") or 0)))
            except (TypeError, ValueError):
                p["points"] = 0.0
        p["max"] = mx
        out.append(p)
    return {**ai_result, "per_question": out, "total": round(sum(p["points"] for p in out), 2), "max": round(sum(p["max"] for p in out), 2)}


def ranking(conn, def_id: int) -> list[dict]:
    d = db.row(conn, "SELECT kind FROM wt_defs WHERE id=?", (def_id,))
    if not d:
        return []
    rows = db.rows(conn, """SELECT user_id, score, max_score, duration_sec, submitted_at FROM tests
                            WHERE def_id=? AND submitted_at IS NOT NULL ORDER BY score DESC, COALESCE(duration_sec, 1e9) ASC, submitted_at ASC""", (def_id,))
    for i, r in enumerate(rows, 1):
        r["rank"] = i
        r["percent"] = round(100 * (r["score"] or 0) / r["max_score"]) if r["max_score"] else None
    return rows


def module_ranking(conn, module_id: int, week_no: int | None = None) -> list[dict]:
    """Rangliste nach Modul (optional Lehrwoche). Zaehlt nur Original-Wochentests, nie Nachtraege."""
    sql = """SELECT t.user_id, SUM(t.score) AS score, SUM(t.max_score) AS max_score, SUM(COALESCE(t.duration_sec,0)) AS duration_sec, COUNT(*) AS tests
             FROM tests t JOIN wt_defs d ON d.id=t.def_id WHERE d.kind='wochentest' AND d.module_id=? AND t.submitted_at IS NOT NULL"""
    p: list = [module_id]
    if week_no is not None:
        sql += " AND d.week_no=?"; p.append(week_no)
    rows = db.rows(conn, sql + " GROUP BY t.user_id ORDER BY score DESC, duration_sec ASC", p)
    for i, r in enumerate(rows, 1):
        r["rank"] = i
    return rows


# ============================================================================ Nachtraege
def offer_nachtrag(plan_id: int, now: datetime | None = None, log=print) -> dict | None:
    """Neue passende Aufgaben nach der Veroeffentlichung -> gemeinsamer ergaenzender Nachtrag (Original bleibt unveraendert)."""
    now = _now(now)
    with db.cursor() as conn:
        plan = db.row(conn, "SELECT * FROM wt_plans WHERE id=?", (plan_id,))
        base = db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (plan["def_id"],)) if plan and plan["def_id"] else None
        if not base:
            return None
        covj = json.loads(plan["coverage"])
        new_pages = {(sg["file_id"], x) for sg in covj["new"] for x in range(sg["from"], sg["to"] + 1)}
        cov_pages = new_pages | {(sg["file_id"], x) for sg in covj["prior"] for x in range(sg["from"], sg["to"] + 1)}
        cands = candidates(conn, plan["module_id"], {"pages": cov_pages}, new_pages)
        known = set(json.loads(base["sources"] or "{}").get("candidates") or [])
        for n in db.rows(conn, "SELECT sources FROM wt_defs WHERE parent_id=? AND kind='nachtrag'", (base["id"],)):
            known |= set(json.loads(n["sources"] or "{}").get("candidates") or [])
        fresh = [c for c in cands["ok"] if c["id"] not in known and c["is_new_week"] and (c.get("indexed_at") or "") > (base["published_at"] or "")]
        if not fresh:
            return None
        ctx = build_context(conn, plan, {"ok": fresh, "excluded": []}, [], n_questions=min(5, max(2, len(fresh))))
        ctx["material_hash"] = _h("nachtrag", base["id"], sorted(c["id"] for c in fresh))
    with _GEN_LOCK:                                          # Doppelte Nachtraege bei parallelen Laeufen verhindern
        with db.cursor() as conn:
            if db.row(conn, "SELECT 1 FROM wt_defs WHERE kind='nachtrag' AND module_id=? AND scope_key=? AND material_hash=?",
                      (plan["module_id"], plan["scope_key"], ctx["material_hash"])):
                return None
        res, qa = _run_ai_pipeline(ctx, "NACHTRAG", "nachtrag", log)
        d = _store_def(ctx, res, qa, "nachtrag", now, parent_id=base["id"])
    with db.cursor() as conn:
        if d["status"] != "veroeffentlicht":
            conn.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", (now.isoformat(), d["id"]))
        attempt_for(conn, d["id"], plan.get("user_id") or LOCAL_USER)
    log(f"Nachtrag zu Wochentest {base['id']}: {len(res['questions'])} Aufgaben aus {len(fresh)} neuen Quellen")
    return {"plan_id": plan_id, "def_id": d["id"], "parent_id": base["id"], "new_tasks": len(fresh)}


# ============================================================================ Probeklausur
def exam_blueprint(conn, module_id: int) -> dict:
    """Typischer Aufbau der echten Altklausuren: Aufgabenzahl, Punkte, Bearbeitungszeit."""
    rows = db.rows(conn, "SELECT file_id, nr, points, text FROM task_index WHERE module_id=? AND source='altklausur'", (module_id,))
    per = defaultdict(list)
    for r in rows:
        per[r["file_id"]].append(r)
    counts = [len(v) for v in per.values() if not all(x["nr"].startswith("S") for x in v)]
    pts = [sum(x["points"] or 0 for x in v) for v in per.values()]
    dur = []
    for fid in per:
        t = " ".join(page_texts(conn, fid)[:2])
        m = re.search(r"(?:Bearbeitungszeit|Dauer|Zeit)\s*[:=]?\s*(\d{2,3})\s*(?:Minuten|min)", t, re.I)
        if m:
            dur.append(int(m.group(1)))
    med = lambda xs, d: sorted(xs)[len(xs) // 2] if xs else d  # noqa: E731
    return {"exams": len(per), "tasks": max(4, min(10, med(counts, 6))), "points": int(med([p for p in pts if p], 100)),
            "duration_min": med(dur, 90)}


def create_mock_exam(module_id: int, full: bool = False, user_id: str = LOCAL_USER, now: datetime | None = None, log=print) -> dict:
    """Probeklausur im Stil der Altklausuren, begrenzt auf den freigegebenen Stoff (Lernstandsklausur).
    full=True nur, wenn alle Vorlesungsdokumente bis zur letzten Seite markiert sind."""
    now = _now(now)
    with db.cursor() as conn:
        ensure_schema(conn)
        index_module(conn, module_id, now)
        cov = coverage(conn, module_id, user_id=user_id)
        if not cov["segments"]:
            raise WeeklyError("Noch kein Vorlesungsstoff markiert – Probeklausur nicht möglich.")
        if full:
            lec_files = [f for f in study._file_rows(conn, module_id) if f.get("doc_type") in LECTURE_TYPES and (f.get("name") or "").lower().endswith(".pdf")]
            open_files = [f["name"] for f in lec_files if not any(sg["file_id"] == f["id"] and sg["to"] >= len(page_texts(conn, f["id"])) for sg in cov["segments"])]
            if open_files:
                raise WeeklyError("Abschlussprobeklausur erst, wenn der gesamte Stoff markiert ist. Noch offen: " + ", ".join(open_files[:5]))
        bp = exam_blueprint(conn, module_id)
        key = scope_key(cov["segments"])
        weeks = sorted({sg["week"] for sg in cov["segments"]})
        plan = {"id": None, "module_id": module_id, "week_no": weeks[-1], "scope_key": key, "user_id": user_id,
                "coverage": json.dumps({"new": cov["segments"], "prior": [], "blocked": cov["blocked"]}, ensure_ascii=False)}
        all_pages = cov["pages"]
        cands = candidates(conn, module_id, cov, all_pages)
        ctx = build_context(conn, plan, cands, [], n_questions=bp["tasks"])
        # Stoff ueber alle Wochen: kompakter pro Seite
        ctx["topic"] = " · ".join(dict.fromkeys(sg.get("topic") for sg in cov["segments"] if sg.get("topic")))[:200]
        ctx["material_hash"] = _h("probe", full, ctx["material_hash"], bp)
        ex = db.row(conn, "SELECT * FROM wt_defs WHERE kind='probeklausur' AND module_id=? AND scope_key=? AND material_hash=? AND status='veroeffentlicht'",
                    (module_id, key, ctx["material_hash"]))
        if ex:
            return {"def": ex, "test_id": attempt_for(conn, ex["id"], user_id), "blueprint": bp, "reused": True}
    extra = (f"\nDies ist eine PROBEKLAUSUR ({'Abschluss' if full else 'Lernstand'}). Orientiere dich am Aufbau der echten Klausuren: "
             f"{bp['tasks']} Aufgaben, zusammen {bp['points']} Punkte, Bearbeitungszeit {bp['duration_min']} Minuten. "
             "Mische Themen aus allen behandelten Wochen. Gib 'duration_min' im JSON an.\n")
    with _GEN_LOCK:
        prompt_ctx = {**ctx, "n": bp["tasks"]}
        qa = {"rounds": []}
        res = None
        for rnd in range(2):
            try:
                res = _parse(_ask(_gen_prompt(prompt_ctx, "PROBEKLAUSUR", extra=extra), SYSTEM))
            except Exception as e:  # noqa: BLE001
                qa["rounds"].append({"rules": [f"KI-Entwurf unbrauchbar: {e}"], "review": []}); continue
            qs = res.get("questions") or []
            probs = validate(prompt_ctx, qs, "probeklausur")
            review = []
            if not probs:
                try:
                    rv = _parse(_ask(_review_prompt(prompt_ctx, qs), SYSTEM))
                    review = [r for r in (rv.get("results") or []) if not (r.get("ok") and r.get("solvable", True) and r.get("solution_correct", True))]
                except Exception as e:  # noqa: BLE001
                    review = [{"issue": f"Fachprüfung fehlgeschlagen: {e}"}]
            qa["rounds"].append({"rules": probs, "review": review})
            if not probs and not review:
                qa["passed"] = True
                break
            extra += "\nKORREKTUR NOETIG: " + "; ".join(probs + [str(r.get("issue")) for r in review])
        if not qa.get("passed"):
            raise WeeklyError("Probeklausur nicht freigegeben (Prüfung nicht bestanden).")
        res["duration_min"] = res.get("duration_min") or bp["duration_min"]
        d = _store_def(prompt_ctx, res, qa, "probeklausur", now)
    with db.cursor() as conn:
        if d["status"] != "veroeffentlicht":
            conn.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", (now.isoformat(), d["id"]))
        tid = attempt_for(conn, d["id"], user_id)
        d = db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (d["id"],))
    return {"def": d, "test_id": tid, "blueprint": bp, "reused": False}


# ============================================================================ Uebersicht fuer die Oberflaeche
STATUS_TXT = {"geplant": "wird vorbereitet", "wartet": "wartet auf Übungen", "veroeffentlicht": "Test verfügbar",
              "fehlgeschlagen": "Erstellung fehlgeschlagen", "ersetzt": "ersetzt"}


def module_overview(conn, module_id: int, user_id: str = LOCAL_USER, now: datetime | None = None) -> dict:
    now = _now(now)
    ensure_schema(conn)
    markers = list_markers(conn, module_id, user_id=user_id)
    plans = db.rows(conn, "SELECT * FROM wt_plans WHERE module_id=? AND status!='ersetzt' ORDER BY week_no, part", (module_id,))
    weeks = defaultdict(lambda: {"plans": [], "markers": []})
    for m in markers:
        weeks[m["week_no"]]["markers"].append({k: m[k] for k in ("id", "file_id", "page", "page_range", "topic", "lecture_date", "needs_review", "review_note", "scope")})
    for p in plans:
        cj = json.loads(p["coverage"])
        d = db.row(conn, "SELECT id, title, topic, published_at, questions, sources FROM wt_defs WHERE id=?", (p["def_id"],)) if p["def_id"] else None
        nach = db.rows(conn, "SELECT id, title, published_at FROM wt_defs WHERE parent_id=? AND kind='nachtrag' ORDER BY id", (p["def_id"],)) if p["def_id"] else []
        test = db.row(conn, "SELECT id, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", (p["def_id"], user_id)) if p["def_id"] else None
        for n in nach:
            n["test"] = db.row(conn, "SELECT id, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", (n["id"], user_id))
        weeks[p["week_no"]]["plans"].append({
            "id": p["id"], "part": p["part"], "status": p["status"], "status_text": STATUS_TXT.get(p["status"], p["status"]),
            "publish_at": p["publish_at"], "deadline_at": p["deadline_at"], "missing": json.loads(p["missing"] or "[]"),
            "error": p["last_error"], "pages": [{"file_id": s["file_id"], "from": s["from"], "to": s["to"]} for s in cj["new"]],
            "topic": " · ".join(dict.fromkeys(s.get("topic") for s in cj["new"] if s.get("topic"))),
            "def_id": p["def_id"], "test": test, "nachtraege": nach,
            "question_count": len(json.loads(d["questions"])) if d else None})
    out = []
    for w in sorted(k for k in weeks if k is not None):
        v = weeks[w]
        st = v["plans"][-1]["status_text"] if v["plans"] else ("Marker gesetzt" if v["markers"] else "Noch keine Vorlesung markiert")
        out.append({"week": w, "status": st, **v, "topic": next((p["topic"] for p in v["plans"] if p["topic"]), None)
                    or " · ".join(dict.fromkeys(m["topic"] for m in v["markers"] if m["topic"]))})
    cur = lecture_week(conn, now.date())
    if not any(w["week"] == cur for w in out):
        out.append({"week": cur, "status": "Noch keine Vorlesung markiert", "plans": [], "markers": [], "topic": None})
    mocks = db.rows(conn, "SELECT id, title, created_at, duration_min FROM wt_defs WHERE module_id=? AND kind='probeklausur' AND status='veroeffentlicht' ORDER BY id DESC LIMIT 5", (module_id,))
    for mk in mocks:
        mk["test"] = db.row(conn, "SELECT id, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", (mk["id"], user_id))
    mod = db.row(conn, "SELECT expected_materials, exam_reuse FROM modules WHERE id=?", (module_id,)) or {}
    return {"weeks": sorted(out, key=lambda w: w["week"]), "current_week": cur, "mock_exams": mocks,
            "needs_review": [m for m in markers if m["needs_review"]], "settings": {**_settings(conn),
            "expected_materials": json.loads(mod.get("expected_materials") or "[]"), "exam_reuse": mod.get("exam_reuse") or "paraphrase"}}


def def_details(conn, def_id: int, user_id: str = LOCAL_USER) -> dict:
    d = db.row(conn, "SELECT * FROM wt_defs WHERE id=?", (def_id,))
    if not d:
        raise WeeklyError("Test nicht gefunden.")
    qs = json.loads(d["questions"]); src = json.loads(d["sources"] or "{}"); cj = json.loads(d["coverage"] or "{}")
    names = {r["id"]: (r["title"] or r["ai_title"] or r["name"]) for r in db.rows(conn, """SELECT f.id, f.name, f.title, a.title AS ai_title FROM files f
                                                                                       LEFT JOIN analysis a ON a.file_id=f.id""")}
    plan = db.row(conn, "SELECT status, publish_at, missing FROM wt_plans WHERE id=?", (d["plan_id"],)) if d["plan_id"] else None
    test = db.row(conn, "SELECT id, started_at, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", (def_id, user_id))
    return {"id": d["id"], "kind": d["kind"], "title": d["title"], "topic": d["topic"], "week_no": d["week_no"], "version": d["version"],
            "status": d["status"], "published_at": d["published_at"], "duration_min": d["duration_min"], "question_count": len(qs),
            "levels": dict(Counter(q.get("level") for q in qs)),
            "pages": [{"file_id": s["file_id"], "name": names.get(s["file_id"]), "from": s["from"], "to": s["to"]} for s in cj.get("new", [])],
            "prior_pages": [{"file_id": s["file_id"], "name": names.get(s["file_id"]), "from": s["from"], "to": s["to"]} for s in cj.get("prior", [])],
            "used_materials": [{"type": a, "label": b} for a, b in src.get("used", [])],
            "exam_questions": sum(1 for q in src.get("per_question", []) if q.get("from_exam")), "exam_candidates": src.get("exam_candidates", 0),
            "missing": src.get("missing") or (json.loads(plan["missing"] or "[]") if plan else []),
            "excluded_count": len(src.get("excluded") or []), "test": test,
            "ranking": ranking(conn, def_id) if d["kind"] == "wochentest" else [],
            "nachtraege": db.rows(conn, "SELECT id, title, published_at FROM wt_defs WHERE parent_id=? AND kind='nachtrag'", (def_id,))}
