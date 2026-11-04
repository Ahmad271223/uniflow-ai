"""Dateien frueherer Semester (Wunsch des Inhabers 03.11.2026, wie in der iPad-App: OlderSemesters.swift).

Der Abgleich laedt nur die Dateien des aktuellen Semesters (Kurse mit active=1, app/semesters.py). Kurse frueherer
Semester bleiben als Kurs bekannt (courses, inaktiv; die Community prueft daran "hat oder hatte das Modul"). Ihre Dateien
laedt der Abgleich nur auf Wunsch:

- Wahl je Datenbank (`older_semester_choice`): None = noch nicht gefragt, `current` = nur aktuelles Semester (Vorgabe),
  `all` = Dateien aller frueheren Semester mitladen.
- Einzelne Kurse ("Dateien laden" in der Bibliothek): `older_semester_courses` mit requested_at; nach einem Lauf, der
  Dateiliste und alle Downloads eines Kurses geschafft hat, loaded_at. Alte Semester aendern sich kaum, darum fragt ein
  spaeterer Abgleich einen schon geladenen Kurs nicht erneut ab (erneut "Dateien laden" schon).

Ein "frueherer" Kurs: aus (active=0) und nach der Semesterregel nicht aktuell. Ein von Hand eingeschalteter alter Kurs
(active_custom) ist aktiv und wird wie jeder aktuelle abgeglichen; ein von Hand ausgeschalteter aktueller Kurs bleibt
aus (keine Dateien).

Beide Tabellen gehoeren nur zu diesem Geraet und werden erst bei Bedarf angelegt (nicht im Geraete-Abgleich, nicht im
Schema der Pruefdaten): was ein Geraet laedt, entscheidet es selbst. Antworten wie in der iPad-App
(`GET /api/older-semesters` usw.); die Routen stehen in app/older_semesters_api.py, die Abgleiche rufen `pending` und
`finish` (app/studip_sync.py `sync_older_files`, app/hildesheim.py `sync_learnweb`).
"""
from __future__ import annotations

from datetime import date

from . import config, semesters

CHOICES = ("current", "all")

TABLES = """
CREATE TABLE IF NOT EXISTS older_semester_choice (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    choice TEXT NOT NULL,
    decided_at TEXT
);
CREATE TABLE IF NOT EXISTS older_semester_courses (
    course_id TEXT PRIMARY KEY,
    requested_at TEXT,
    loaded_at TEXT
);
"""


def _exists(conn, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def _today() -> date:
    from . import study
    return study.today()


# --- Wahl ---------------------------------------------------------------------------------------------------------

def choice(conn) -> str | None:
    """Gespeicherte Wahl (`current`/`all`); None = noch nicht gefragt."""
    if not _exists(conn, "older_semester_choice"):
        return None
    r = conn.execute("SELECT choice FROM older_semester_choice WHERE id=1").fetchone()
    return r[0] if r and r[0] in CHOICES else None


def set_choice(conn, value: str, now: str) -> None:
    if value not in CHOICES:
        raise ValueError("choice: current oder all")
    conn.executescript(TABLES)
    conn.execute("INSERT OR REPLACE INTO older_semester_choice(id, choice, decided_at) VALUES (1, ?, ?)", (value, now))


# --- Kurse --------------------------------------------------------------------------------------------------------

def courses(conn, today: date | None = None) -> list[dict]:
    """Kurse frueherer Semester (aus und nach der Regel nicht aktuell), neueste Semester zuerst, dann nach Titel.
    Je Kurs: id, title, label (Semester), key, files (bekannt, ohne Papierkorb), downloaded, requested, loaded."""
    d = today or _today()
    marks = _exists(conn, "older_semester_courses")
    rows = conn.execute(f"""
        SELECT c.id, c.title, c.semester, c.semester_end, c.semester_ends_at,
               (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL) AS files,
               (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL AND COALESCE(f.local_path, '')<>'') AS downloaded
               {", o.requested_at, o.loaded_at" if marks else ""}
        FROM courses c {"LEFT JOIN older_semester_courses o ON o.course_id=c.id" if marks else ""}
        WHERE c.id <> '__user__' AND COALESCE(c.active, 1)=0""").fetchall()
    stream = config.streams_files()               # Dienst: Inhalt kommt bei Bedarf, bekannt heisst verfuegbar
    out = []
    for r in rows:
        if semesters.is_current(r["semester"], r["semester_end"], r["semester_ends_at"], d) is not False:
            continue
        k = semesters.key(r["semester"]) or semesters.key(r["semester_end"])
        text = next((t for t in (r["semester"], r["semester_end"]) if t), None)
        requested = bool(marks and r["requested_at"])
        loaded = bool(marks and r["loaded_at"])
        out.append({"id": r["id"], "title": r["title"] or "Kurs", "key": k,
                    "label": semesters.label(k) if k else (text or "Früheres Semester"),
                    "files": r["files"], "downloaded": r["files"] if stream else r["downloaded"],
                    "requested": requested and not loaded, "loaded": loaded})
    # neueste Semester zuerst, Kurse ohne erkennbares Semester zuletzt; dann Semestertext, dann Titel
    out.sort(key=lambda c: (c["key"] is None, tuple(-x for x in c["key"]) if c["key"] else (), c["label"], c["title"].casefold()))
    return out


def pending(conn, today: date | None = None) -> set[str]:
    """Kurse frueherer Semester, deren Dateien der naechste Abgleich holen soll: bei der Wahl `all` alle noch nicht
    geladenen, sonst nur die angeforderten ("Dateien laden")."""
    everything = choice(conn) == "all"
    return {c["id"] for c in courses(conn, today) if not c["loaded"] and (everything or c["requested"])}


def needs_question(conn, today: date | None = None) -> bool:
    """Frage "Auch frühere Semester laden?" noch offen: nie entschieden und es gibt Kurse frueherer Semester."""
    return choice(conn) is None and bool(courses(conn, today))


def request(conn, course_ids: list[str], now: str, today: date | None = None) -> int:
    """"Dateien laden" fuer diese Kurse (auch erneut nach einem fertigen Laden): der naechste Lauf holt Dateiliste und
    Dateien. Rueckgabe: Zahl der Kurse frueherer Semester darunter."""
    older = {c["id"] for c in courses(conn, today)}
    ids = [i for i in dict.fromkeys(course_ids) if i in older]
    if not ids:
        return 0
    conn.executescript(TABLES)
    for i in ids:
        conn.execute("""INSERT INTO older_semester_courses(course_id, requested_at, loaded_at) VALUES (?, ?, NULL)
                        ON CONFLICT(course_id) DO UPDATE SET requested_at=excluded.requested_at, loaded_at=NULL""", (i, now))
    return len(ids)


def mark_loaded(conn, course_ids, now: str) -> None:
    """Dateiliste und alle Downloads dieser Kurse sind durch."""
    ids = list(course_ids)
    if not ids:
        return
    conn.executescript(TABLES)
    for i in ids:
        conn.execute("""INSERT INTO older_semester_courses(course_id, requested_at, loaded_at) VALUES (?, NULL, ?)
                        ON CONFLICT(course_id) DO UPDATE SET loaded_at=excluded.loaded_at""", (i, now))


def finish(conn, course_ids, now: str) -> list[str]:
    """Nach dem Abgleich: Kurse frueherer Semester als geladen merken, deren Dateiliste gelesen wurde und bei denen
    jede bekannte Datei da ist (Dienst: bekannt genuegt). Rueckgabe: die als geladen gemerkten Kurse."""
    ids = list(course_ids)
    if not ids:
        return []
    stream = config.streams_files()
    done = []
    for i in ids:
        missing = 0 if stream else conn.execute(
            "SELECT COUNT(*) FROM files WHERE course_id=? AND deleted_at IS NULL AND COALESCE(local_path, '')=''", (i,)).fetchone()[0]
        if not missing:
            done.append(i)
    mark_loaded(conn, done, now)
    return done


# --- Fuer die Bibliothek ------------------------------------------------------------------------------------------

def groups(conn, today: date | None = None) -> list[dict]:
    """Semester-Ordner der Bibliothek: je frueheres Semester seine Kurse, neuestes zuerst."""
    out: list[dict] = []
    for c in courses(conn, today):
        if out and out[-1]["label"] == c["label"]:
            out[-1]["courses"].append(c)
        else:
            out.append({"label": c["label"], "courses": [c]})
    return out


def overview(conn, today: date | None = None) -> dict:
    """`GET /api/older-semesters`: Wahl, aktuelles Semester und die frueheren mit ihren Kursen."""
    d = today or _today()
    return {"choice": choice(conn), "current": semesters.label(semesters.current(d)),
            "semesters": [{"label": g["label"], "courses": [
                {k: c[k] for k in ("id", "title", "files", "downloaded", "requested", "loaded")} for c in g["courses"]]}
                for g in groups(conn, d)]}


def course_files(conn, course_id: str) -> list[dict] | None:
    """Dateien eines Kurses (auch eines inaktiven), ohne Papierkorb, mit Einordnung wie `/api/library`; None = kein Kurs."""
    from . import db, study
    if conn.execute("SELECT 1 FROM courses WHERE id=?", (course_id,)).fetchone() is None:
        return None
    rows = db.rows(conn, """
        SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind,
               f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder, f.download_url, f.content_sha256,
               c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
               (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at,
               CASE WHEN COALESCE(f.local_path, '')<>'' THEN 1 ELSE 0 END AS downloaded
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE f.course_id=? AND f.deleted_at IS NULL ORDER BY COALESCE(f.studip_folder, ''), f.name, f.id""", (course_id,))
    stream = config.streams_files()
    out = []
    for r in rows:
        f = study.enrich_file(r)
        if stream:
            f["downloaded"] = 1
        out.append(f)
    return out
