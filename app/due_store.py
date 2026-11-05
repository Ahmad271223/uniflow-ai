"""Erkannte Abgaben, Tests und Pruefungstermine in der Datenbank (Python-Fassung von DueStore.swift, 05.11.2026).

Quellen: Seitentexte der PDFs (`page_texts`), Dateinamen, Ankuendigungen (`announcements`); die Erkennung selbst ist
app/due_detection.py. Die Learnweb-Fristen (`deadlines`) bleiben, wie sie sind; ein erkannter Termin, den es dort schon
gibt (gleiches Modul bzw. gleicher Kurs, gleicher Tag, gleiche Art), wird nicht doppelt gezeigt, ebenso einer am
Klausurtermin des Moduls.

Tabellen, erst bei Bedarf angelegt (wie auf dem iPad, nicht im Grundschema von app/db.py):
- `due_hits`: jede Fundstelle. Wird neu berechnet, sobald sich die Eingaben aendern (`input_stamp`: Seitentexte,
  Dateien, Kurse, Ankuendigungen, Semester, Tag, Erkennung) - also nach einem Abgleich oder neu gelesenen Seiten,
  spaetestens beim naechsten Lesen (Kalender, Uebersicht, GET /api/due).
- `due_choices`: Entscheidungen je Kurs, Tag und Art ("stimmt nicht", bestaetigt, eigene Uhrzeit); bleiben stehen.
- `due_meta`: Stand der Erkennung.
Kennungen der Termine ("due-" + 16 Hex aus SHA-256 von Bereich|Tag|Art) sind dieselben wie auf dem iPad.
"""
from __future__ import annotations

import hashlib
import re
from datetime import date, datetime

from . import config, db, scriptsearch
from . import due_detection as D
from .holidays import DEADLINE_LABELS

DETECTOR_VERSION = "2"

TABLES_SQL = """
CREATE TABLE IF NOT EXISTS due_hits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,              -- dokument | dateiname | ankuendigung
    file_id TEXT,
    page INTEGER,
    announcement_id TEXT,
    course_id TEXT,
    date TEXT NOT NULL,                -- YYYY-MM-DD
    time TEXT,                         -- HH:MM
    kind TEXT NOT NULL,                -- abgabe | test | klausur | anmeldung | sonstiges
    label TEXT NOT NULL,
    snippet TEXT,
    name TEXT,                         -- Dateiname bzw. Titel der Ankuendigung
    url TEXT,
    detected_at TEXT
);
CREATE INDEX IF NOT EXISTS ix_due_hits_date ON due_hits(date);
CREATE INDEX IF NOT EXISTS ix_due_hits_file ON due_hits(file_id);
CREATE TABLE IF NOT EXISTS due_choices (
    key TEXT PRIMARY KEY,              -- Kurs|Tag|Art
    hidden INTEGER NOT NULL DEFAULT 0, -- "stimmt nicht"
    confirmed INTEGER NOT NULL DEFAULT 0,
    time TEXT,                         -- eigene Uhrzeit des Nutzers
    updated_at TEXT
);
CREATE TABLE IF NOT EXISTS due_meta (key TEXT PRIMARY KEY, value TEXT);
"""


def ensure_tables(conn) -> None:
    conn.executescript(TABLES_SQL)


def has_tables(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='due_hits'").fetchone() is not None


def _table(conn, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _today(today: date | None) -> date:
    if today is not None:
        return today
    from . import study
    return study.today()


def _university(conn) -> str:
    """Hochschule wie im Kalender (holidays.calendar_extras): im Dienst die des Kontos, am PC die eingestellte"""
    return config.university()


# ---------------------------------------------------------------- Rahmen

def window(conn, today: date | None = None) -> D.Window | None:
    """Laufende Semester dieser Datenbank: Hochschule aus `settings`, aktives Semester aus `terms`"""
    r = db.row(conn, "SELECT name, start, end FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")
    term = (r["name"] or "", r["start"], r["end"]) if r and r["start"] and r["end"] else None
    return D.Window.current(_university(conn), _today(today).toordinal(), term)


OLD_EXAM_NAME_RE = re.compile(r"l(?:ö|oe)sung|musterl|solution|altklausur|alte[ _-]?klausur", re.I)


def _unix_day(v) -> int | None:
    try:
        s = float(v)
    except (TypeError, ValueError):
        return None
    if s <= 0:
        return None
    from zoneinfo import ZoneInfo
    return datetime.fromtimestamp(s, ZoneInfo("Europe/Berlin")).date().toordinal()


def _row(source, file_id, page, announcement_id, course_id, hit: D.Hit, name, url=None) -> dict:
    return {"source": source, "file_id": file_id, "page": page, "announcement_id": announcement_id, "course_id": course_id,
            "hit": hit, "name": name, "url": url}


def _named(name: str) -> bool:
    form = scriptsearch.search_form(name or "")
    return any(t in form for t in D.LIKE_TERMS)


def scan_file(fid: str, name: str, chdate, course_id, pages: list[tuple[int, str]], first_page: str | None, w: D.Window) -> list[dict]:
    """Fundstellen einer Datei: Seiten und Dateiname. Nennt der Kopf ein anderes Semester, keine."""
    s = D.head_semester(first_page, name)
    if s is not None and w.semesters and s not in w.semesters:
        return []
    old = bool(OLD_EXAM_NAME_RE.search(name or ""))
    ctx = D.Context(w, reference=_unix_day(chdate), name=name, head=D.head_lines(first_page), allow_yearless=not old, allow_exams=not old)
    out = []
    for page, text in pages:
        for h in D.detect(text, ctx):
            out.append(_row("dokument", fid, page, None, course_id, h, name))
    if _named(name):
        for h in D.detect(D.name_text(name), ctx):
            out.append(_row("dateiname", fid, None, None, course_id, h, name))
    return out


FILE_FILTER = "f.deleted_at IS NULL AND c.active=1 AND f.course_id <> '__user__'"


def scan_files(conn, w: D.Window, only: str | None = None) -> list[dict]:
    """Fundstellen aller Dateien (nur aktuelle Fassung der Seitentexte, nicht im Papierkorb, gewaehlte Kurse)"""
    scriptsearch.ensure_table(conn)
    one, one_p = (" AND f.id=?", [only]) if only else ("", [])
    like = "(p.search IS NULL OR " + " OR ".join("p.search LIKE ?" for _ in D.LIKE_TERMS) + ")"
    pages_by_file: dict[str, list[tuple[int, str]]] = {}
    for r in conn.execute(f"""SELECT p.file_id, p.page, p.text, p.search FROM page_texts p JOIN files f ON f.id=p.file_id
                              JOIN courses c ON c.id=f.course_id
                              WHERE COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0) AND {FILE_FILTER}{one} AND {like}
                              ORDER BY p.file_id, p.page""", one_p + [f"%{t}%" for t in D.LIKE_TERMS]):
        text = r["text"] or ""
        if r["search"] is None:
            form = scriptsearch.search_form(text)
            if not any(t in form for t in D.LIKE_TERMS):
                continue
        pages_by_file.setdefault(r["file_id"], []).append((r["page"], text))
    out: list[dict] = []
    for f in db.rows(conn, f"SELECT f.id, f.name, f.chdate, f.course_id FROM files f JOIN courses c ON c.id=f.course_id WHERE {FILE_FILTER}{one} ORDER BY f.id", one_p):
        name = f["name"] or ""
        pages = pages_by_file.get(f["id"], [])
        if not pages and not _named(name):
            continue
        first = next((t for p, t in pages if p == 1), None)
        if first is None:
            r = conn.execute("""SELECT p.text FROM page_texts p JOIN files f ON f.id=p.file_id
                                WHERE p.file_id=? AND p.page=1 AND COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0)""", (f["id"],)).fetchone()
            first = r[0] if r else None
        out += scan_file(f["id"], name, f["chdate"], f["course_id"], pages, first, w)
    return out


def scan_announcements(conn, w: D.Window) -> list[dict]:
    """Fundstellen der Ankuendigungen; Bezugstag ist der Tag der Ankuendigung"""
    out = []
    for a in db.rows(conn, """SELECT a.id, a.course_id, a.title, a.text, a.posted_at, a.url FROM announcements a
                              LEFT JOIN courses c ON c.id=a.course_id WHERE COALESCE(c.active, 1)=1 ORDER BY a.posted_at, a.id"""):
        ref = D.parse_iso(a["posted_at"]) if len(a["posted_at"] or "") >= 10 and (len(a["posted_at"]) == 10 or a["posted_at"][10] in "T ") else None
        ctx = D.Context(w, reference=ref if ref is not None else w.today)
        title = a["title"] or ""
        for h in D.detect(title + "\n" + (a["text"] or ""), ctx):
            out.append(_row("ankuendigung", None, None, a["id"], a["course_id"], h, title, a["url"]))
    return out


def _insert(conn, rows: list[dict], now: str) -> None:
    conn.executemany("""INSERT INTO due_hits(source, file_id, page, announcement_id, course_id, date, time, kind, label, snippet, name, url, detected_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                     [(r["source"], r["file_id"], r["page"], r["announcement_id"], r["course_id"], r["hit"].date, r["hit"].time,
                       r["hit"].kind, r["hit"].label, r["hit"].snippet, r["name"], r["url"], now) for r in rows])


def _signature(conn) -> list[str]:
    return sorted("|".join(str(x) for x in r) for r in conn.execute(
        """SELECT source, COALESCE(file_id,''), COALESCE(page,0), COALESCE(announcement_id,''), COALESCE(course_id,''), date,
                  COALESCE(time,''), kind, label FROM due_hits"""))


def _set_meta(conn, key: str, value: str) -> None:
    conn.execute("INSERT INTO due_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))


def _meta(conn, key: str) -> str | None:
    r = conn.execute("SELECT value FROM due_meta WHERE key=?", (key,)).fetchone()
    return r[0] if r else None


def input_stamp(conn, today: date | None = None) -> str:
    """Stand der Eingaben; gleich -> nichts zu tun. Seitentexte nur ueber Zahl, Aenderungszeit und hoechste Zeilennummer
    (neu abgelegte Seiten bekommen neue Nummern), damit das Lesen ohne Aenderung billig bleibt."""
    scriptsearch.ensure_table(conn)
    parts = [DETECTOR_VERSION, _today(today).isoformat(), _university(conn)]
    for sql in ("SELECT COUNT(*), TOTAL(chdate), MAX(rowid) FROM page_texts",
                "SELECT COUNT(*), TOTAL(chdate), TOTAL(length(name)), TOTAL(length(course_id)), TOTAL(deleted_at IS NOT NULL) FROM files",
                "SELECT group_concat(x, ',') FROM (SELECT id || ':' || COALESCE(active, 1) AS x FROM courses ORDER BY id)",
                "SELECT COUNT(*), TOTAL(length(text)), TOTAL(length(title)), MAX(posted_at), TOTAL(length(course_id)) FROM announcements",
                "SELECT group_concat(x, ',') FROM (SELECT name || '|' || start || '|' || end || '|' || active AS x FROM terms ORDER BY id)"):
        r = conn.execute(sql).fetchone()
        parts.append(";".join("-" if v is None else str(v) for v in r))
    return "/".join(parts)


def refresh_all(conn, today: date | None = None, force: bool = False) -> dict:
    """Alles neu berechnen; ohne geaenderte Eingaben bleibt alles, wie es ist (`force` rechnet trotzdem).
    Entscheidungen des Nutzers bleiben. {hits, changed}"""
    ensure_tables(conn)
    day = _today(today).isoformat()
    stamp = input_stamp(conn, today)
    if not force and _meta(conn, "input") == stamp:
        _set_meta(conn, "refreshed_day", day)
        return {"hits": conn.execute("SELECT COUNT(*) FROM due_hits").fetchone()[0], "changed": False}
    before = _signature(conn)
    conn.execute("DELETE FROM due_hits")
    rows: list[dict] = []
    w = window(conn, today)
    if w is not None:
        rows = scan_files(conn, w) + scan_announcements(conn, w)
        _insert(conn, rows, db.now_iso())
    _set_meta(conn, "version", DETECTOR_VERSION)
    _set_meta(conn, "refreshed_day", day)
    _set_meta(conn, "refreshed_at", db.now_iso())
    _set_meta(conn, "input", stamp)
    return {"hits": len(rows), "changed": _signature(conn) != before}


def ensure_fresh(conn, today: date | None = None) -> bool:
    """Vor dem Lesen: neu rechnen, wenn sich die Eingaben geaendert haben (auch neuer Tag oder neue Erkennung).
    Am PC gibt es kein Gegenstueck zu refreshFile (neu gelesene Seiten): der Stand der Eingaben deckt es ab."""
    return refresh_all(conn, today)["changed"]


# ---------------------------------------------------------------- Lesen

def choice_key(course, day: str, kind: str) -> str:
    return f"{course or '-'}|{day}|{kind}"


def group_id(scope: str, day: str, kind: str) -> str:
    return "due-" + hashlib.sha256(f"{scope}|{day}|{kind}".encode()).hexdigest()[:16]


def learnweb_kind(k: str | None) -> str | None:
    return {"abgabe": "abgabe", "frist": "abgabe", "test_ende": "test", "test_beginn": "test"}.get(k or "")


def scope_of(module_id, course) -> str:
    return f"m{module_id}" if module_id is not None else f"c{course or '-'}"


def groups(conn, start: str, end: str) -> list[dict]:
    """Termine im Zeitraum (Tage "YYYY-MM-DD", beide eingeschlossen), nach Tag; Fundstellen geloeschter Dateien fehlen"""
    if not has_tables(conn):
        return []
    rows = db.rows(conn, """SELECT h.*, c.module_id, c.title AS course_title, m.color, m.name AS module_name, f.id AS known_file,
                                   f.deleted_at AS file_deleted
                            FROM due_hits h LEFT JOIN courses c ON c.id=h.course_id LEFT JOIN modules m ON m.id=c.module_id
                            LEFT JOIN files f ON f.id=h.file_id
                            WHERE h.date >= ? AND h.date <= ? ORDER BY h.date, h.id""", (start, end))
    if not rows:
        return []
    choices = {r["key"]: r for r in db.rows(conn, "SELECT * FROM due_choices")}
    existing = set()
    for r in db.rows(conn, """SELECT d.course_id, substr(d.due_at, 1, 10) AS day, d.kind, c.module_id FROM deadlines d
                              LEFT JOIN courses c ON c.id=d.course_id WHERE d.due_at >= ? AND d.due_at < ?""", (start, end + "T99")):
        k = learnweb_kind(r["kind"])
        if k and r["day"]:
            existing.add(f"{scope_of(r['module_id'], r['course_id'])}|{r['day']}|{k}")
    for r in db.rows(conn, "SELECT id, exam_date FROM modules WHERE exam_date >= ? AND exam_date <= ?", (start, end)):
        if r["exam_date"]:
            existing.add(f"m{r['id']}|{r['exam_date'][:10]}|klausur")
    order: list[str] = []
    by_key: dict[str, dict] = {}
    for r in rows:
        if r["file_id"] and (r["known_file"] is None or r["file_deleted"] is not None):
            continue
        s = scope_of(r["module_id"], r["course_id"])
        gk = f"{s}|{r['date']}|{r['kind']}"
        if gk not in by_key:
            order.append(gk)
            by_key[gk] = {"id": group_id(s, r["date"], r["kind"]), "date": r["date"], "kind": r["kind"], "hits": [], "keys": [],
                          "hidden": False, "confirmed": False, "user_time": None, "covered": gk in existing}
        g = by_key[gk]
        g["hits"].append(r)
        ck = choice_key(r["course_id"], r["date"], r["kind"])
        if ck not in g["keys"]:
            g["keys"].append(ck)
    out = []
    for k in order:
        g = by_key[k]
        for key in g["keys"]:
            ch = choices.get(key)
            if not ch:
                continue
            if ch["hidden"]:
                g["hidden"] = True
            if ch["confirmed"]:
                g["confirmed"] = True
            if g["user_time"] is None and ch["time"]:
                g["user_time"] = ch["time"]
        out.append(g)
    return out


SOURCE_RANK = {"dokument": 0, "dateiname": 1, "ankuendigung": 2}


def _natural(s: str):
    return [int(x) if x.isdigit() else x.casefold() for x in re.split(r"(\d+)", s or "")]


def sorted_hits(g: dict) -> list[dict]:
    return [h for _, h in sorted(enumerate(g["hits"]), key=lambda x: (SOURCE_RANK.get(x[1]["source"], 9), _natural(x[1]["name"] or ""),
                                                                       x[1]["page"] or 0, x[0]))]


def title(hits: list[dict]) -> str:
    labels = [h["label"] for h in hits if h["label"]]
    numbered = next((x for x in labels if any(c.isnumeric() for c in x)), None)
    if numbered:
        return numbered
    if not labels:
        return "Termin"
    return max(labels, key=labels.count)


def time_of(g: dict, hits: list[dict]) -> str | None:
    if g["user_time"]:
        return g["user_time"]
    times = [h["time"] for h in hits if h["time"]]
    if not times:
        return None
    best = max(times.count(t) for t in times)
    return next(t for t in times if times.count(t) == best)


def origin(h: dict) -> str:
    name = h["name"] or ""
    if h["source"] == "dokument":
        return f"erkannt in {name}, S. {h['page'] or 1}"
    if h["source"] == "dateiname":
        return f"erkannt im Dateinamen „{name}“"
    return f"erkannt in der Ankündigung „{name}“"


def origin_text(hits: list[dict]) -> str:
    if not hits:
        return ""
    more = len(hits) - 1
    return origin(hits[0]) + ("" if more == 0 else " und an 1 weiteren Stelle" if more == 1 else f" und an {more} weiteren Stellen")


def as_json(g: dict) -> dict:
    """Gemeinsame Felder eines erkannten Termins (wie DueStore.json)"""
    hits = sorted_hits(g)
    first = hits[0] if hits else {}
    t = title(hits)
    opener = next((h for h in hits if h["file_id"]), first)
    sources = [{"source": h["source"], "file_id": h["file_id"], "page": h["page"], "name": h["name"], "announcement_id": h["announcement_id"],
                "url": h["url"], "snippet": h["snippet"], "origin": origin(h)} for h in hits[:8]]
    ot = origin_text(hits)
    return {"id": g["id"], "source": "dokument", "detected": True, "date": g["date"], "time": time_of(g, hits), "kind": g["kind"],
            "kind_label": t.split(" ")[0], "title": t, "origin": ot, "full_title": f"{t} · {ot}", "snippet": first.get("snippet"),
            "course_id": first.get("course_id"), "course_title": first.get("course_title"), "module_id": first.get("module_id"),
            "module_name": first.get("module_name"), "color": first.get("color"),
            "file_id": opener.get("file_id"), "page": (opener.get("page") or 1) if opener.get("file_id") else None,
            "url": None if opener.get("file_id") else opener.get("url"),
            "announcement_ids": sorted({h["announcement_id"] for h in hits if h["announcement_id"]}), "sources": sources,
            "confirmed": g["confirmed"], "hidden": g["hidden"], "user_time": g["user_time"] is not None, "overdue": False}


def calendar_days(conn, start: date, end: date) -> dict[str, list[dict]]:
    """Erkannte Termine je Kalendertag fuer Lernkalender und Stundenplan (Feld `deadlines`); ausgeblendete und schon
    vorhandene fehlen. Rechnet vorher neu, wenn sich die Eingaben geaendert haben."""
    try:
        ensure_fresh(conn)
    except Exception as e:  # noqa: BLE001 - Erkennung darf den Kalender nie anhalten
        print(f"[due] Erkennung uebersprungen: {e}")
        return {}
    out: dict[str, list[dict]] = {}
    for g in groups(conn, start.isoformat(), end.isoformat()):
        if not g["hidden"] and not g["covered"]:
            out.setdefault(g["date"], []).append(as_json(g))
    return out


def merge_calendar(by_day: dict[str, list[dict]], conn, start: date, end: date) -> None:
    """Erkannte Termine in die Learnweb-Fristen je Tag einsortieren (ohne Uhrzeit zuerst, sonst nach Uhrzeit)."""
    for day, items in calendar_days(conn, start, end).items():
        by_day[day] = sorted(by_day.get(day, []) + items, key=lambda x: x.get("time") or "")


def upcoming(conn, today: date, now: str, limit: int) -> list[dict]:
    """Kommende erkannte Termine fuer "Nächste Termine" (Form wie study.upcoming_deadlines)"""
    try:
        ensure_fresh(conn, today)
    except Exception as e:  # noqa: BLE001
        print(f"[due] Erkennung uebersprungen: {e}")
        return []
    out = []
    t = today.toordinal()
    for g in groups(conn, today.isoformat(), D.iso(t + 400)):
        if g["hidden"] or g["covered"]:
            continue
        x = as_json(g)
        if x["time"] and f"{g['date']}T{x['time']}" < now:
            continue
        x["deadline_id"] = g["id"]
        out.append(x)
        if len(out) >= limit:
            break
    return out


def merge_upcoming(dls: list[dict], conn, today: date, now: str, limit: int) -> list[dict]:
    """Learnweb-Fristen und erkannte Termine: ueberfaellige oben, dann nach Tag und Uhrzeit (wie StudyCalendar.swift)"""
    detected = upcoming(conn, today, now, limit)
    if not detected:
        return dls
    overdue = [x for x in dls if x.get("overdue")]
    rest = sorted([x for x in dls if not x.get("overdue")] + detected, key=lambda x: (x.get("date") or "", x.get("time") or ""))
    return (overdue + rest)[:limit]


# ---------------------------------------------------------------- Liste "Abgaben & Prüfungen"

def in_days(n: int) -> str:
    return {0: "heute", 1: "morgen", -1: "gestern"}.get(n) or (f"in {n} Tagen" if n > 1 else f"vor {-n} Tagen")


def _with_days(x: dict, t: int) -> None:
    d = D.parse_iso(x.get("date"))
    n = d - t if d is not None else 0
    x["days_left"] = n
    x["in_days"] = in_days(n)
    x["due_at"] = (x.get("date") or "") + (f"T{x['time']}" if x.get("time") else "")


def list_due(conn, module_id: int | None = None, include_hidden: bool = False, days: int = 200, today: date | None = None,
             now: str | None = None) -> dict:
    """GET /api/due: kommende Abgaben, Tests und Pruefungen (erkannte, Learnweb/Courseware-Fristen, Klausurtermine der
    Module) mit days_left/in_days; `hidden` = Zahl der ausgeblendeten erkannten"""
    td = _today(today)
    refreshed = ensure_fresh(conn, td)
    t = td.toordinal()
    now = now or datetime.now().strftime("%Y-%m-%dT%H:%M")
    frm, to = td.isoformat(), D.iso(t + days)
    items, hidden = [], 0
    for g in groups(conn, frm, to):
        if g["covered"]:
            continue
        x = as_json(g)
        if x["time"] and f"{g['date']}T{x['time']}" < now:
            continue
        if module_id is not None and x["module_id"] != module_id:
            continue
        if g["hidden"]:
            hidden += 1
            if not include_hidden:
                continue
        items.append(x)
    for r in db.rows(conn, """SELECT d.*, c.title AS course_title, c.module_id, m.color, m.name AS module_name
                              FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id LEFT JOIN modules m ON m.id=c.module_id
                              WHERE d.due_at >= ? AND d.due_at <= ? ORDER BY d.due_at""", (now, to + "T99")):
        if module_id is not None and r["module_id"] != module_id:
            continue
        due, kind = r["due_at"] or "", r["kind"] or ""
        studip, demo = r["source"] == "studip", r["source"] == "demo"
        items.append({"id": r["id"], "deadline_id": r["id"], "source": "studip" if studip else "learnweb", "detected": False,
                      "date": due[:10], "time": due[11:16], "kind": learnweb_kind(kind) or "sonstiges",
                      "kind_label": DEADLINE_LABELS.get(kind, "Frist"), "title": r["title"], "full_title": r["full_title"] or r["title"],
                      "origin": "aus den Demo-Inhalten" if demo else "aus Stud.IP Courseware" if studip else "aus dem Learnweb-Kalender",
                      "course_id": r["course_id"], "course_title": r["course_title"], "module_id": r["module_id"],
                      "module_name": r["module_name"], "color": r["color"], "url": r["url"], "file_id": None, "page": None,
                      "confirmed": True, "hidden": False, "user_time": False, "overdue": bool(r["overdue"])})
    for m in db.rows(conn, """SELECT id, name, color, exam_date FROM modules WHERE exam_date >= ? AND exam_date <= ? AND COALESCE(active, 1)=1
                              ORDER BY exam_date""", (frm, to)):
        if module_id is not None and m["id"] != module_id:
            continue
        items.append({"id": f"exam-{m['id']}", "source": "modul", "detected": False, "date": m["exam_date"][:10], "time": None,
                      "kind": "klausur", "kind_label": "Klausur", "title": f"Klausur {m['name'] or ''}", "full_title": f"Klausur {m['name'] or ''}",
                      "origin": "Klausurtermin im Modul", "course_id": None, "course_title": None, "module_id": m["id"],
                      "module_name": m["name"], "color": m["color"], "url": None, "file_id": None, "page": None, "confirmed": True,
                      "hidden": False, "user_time": False, "overdue": False})
    for x in items:
        _with_days(x, t)
    items = [x for _, x in sorted(enumerate(items), key=lambda e: (e[1]["due_at"][:10], e[1]["due_at"], e[0]))]
    return {"items": items, "hidden": hidden, "today": frm, "refreshed": refreshed}


# ---------------------------------------------------------------- Entscheidungen

UNSET = object()


def update(conn, gid: str, hidden: bool | None = None, confirmed: bool | None = None, time=UNSET, today: date | None = None) -> dict | None:
    """Termin ausblenden ("stimmt nicht"), wieder zeigen, bestaetigen oder Uhrzeit setzen (time=None loescht die eigene).
    Gilt fuer alle Kurse des angezeigten Termins und bleibt beim Neuberechnen. None: Termin unbekannt."""
    ensure_tables(conn)
    g = next((x for x in groups(conn, "0000-00-00", "9999-99-99") if x["id"] == gid), None)
    if g is None:
        return None
    now = db.now_iso()
    for key in g["keys"]:
        conn.execute("INSERT OR IGNORE INTO due_choices(key, hidden, confirmed, time, updated_at) VALUES (?, 0, 0, NULL, ?)", (key, now))
        if hidden is not None:
            conn.execute("UPDATE due_choices SET hidden=?, updated_at=? WHERE key=?", (1 if hidden else 0, now, key))
        if confirmed is not None:
            conn.execute("UPDATE due_choices SET confirmed=?, updated_at=? WHERE key=?", (1 if confirmed else 0, now, key))
        if time is not UNSET:
            conn.execute("UPDATE due_choices SET time=?, updated_at=? WHERE key=?", (time, now, key))
    fresh = next((x for x in groups(conn, g["date"], g["date"]) if x["id"] == gid), None)
    if fresh is None:
        return None
    x = as_json(fresh)
    _with_days(x, _today(today).toordinal())
    return x
