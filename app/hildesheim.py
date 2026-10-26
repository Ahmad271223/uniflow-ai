"""Sync fuer die Uni Hildesheim: Learnweb (Kurse, Dateien) + LSF (persoenlicher Stundenplan).

Zugangsdaten nur aus der lokalen .env:
  HILDESHEIM_USER / HILDESHEIM_PASSWORD  UNI-Account fuer das CAS (Learnweb ohne Schluessel, LSF)
  LEARNWEB_TOKEN                         optionaler Learnweb-Sicherheitsschluessel (Moodle mobile web service)
Der Schluessel wird nie in die Datenbank oder ins Protokoll geschrieben.
"""
from __future__ import annotations

import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from . import announcements, cas, config, db, learnweb, lsf
from .config import DATA_DIR
from .studip_sync import log, store_course_files, stream_download, upsert_course
from .universities import HILDESHEIM_CAS

PROFILE_DIR = DATA_DIR / "browser-profile-hildesheim"


def _profile_dir() -> Path:
    return config.data_dir() / "browser-profile-hildesheim" if config.current_user_id() else PROFILE_DIR


def learnweb_base() -> str:
    """Learnweb-Instanz des aktuellen Semesters (wechselt jaehrlich), siehe learnweb.discover_base."""
    return learnweb.discover_base(override=config.secret("HILDESHEIM_LEARNWEB_URL") or None)


def _download(page, url: str, target: Path, token: str = "", size: int = 0) -> None:
    # gestreamt (konstanter Speicher); Fehlermeldungen zeigen die URL ohne Token; leere Antwort ersetzt nichts
    stream_download(page, learnweb.with_token(url, token) if token else url, target, shown_url=url, expected_size=size)


def _learnweb_client(page, user: str, pw: str, token: str):
    """Schluessel bevorzugt; bei fehlendem/ungueltigem Schluessel die CAS-Sitzung."""
    base = learnweb_base()
    log(f"Learnweb: {base}")
    if token:
        client = learnweb.TokenClient(base, token)
        try:
            courses = client.courses()
            log(f"Learnweb: Zugriff mit Sicherheitsschluessel, {len(courses)} Kurse.")
            return client, courses, token
        except Exception as e:  # noqa: BLE001
            log(f"Learnweb-Schluessel funktioniert nicht ({e}); versuche die Anmeldung mit dem UNI-Account.")
            if not (user and pw):
                raise
    client = learnweb.SessionClient(page, base)
    cas.login(page, f"{base}/login/index.php?authCAS=CAS", HILDESHEIM_CAS, user, pw, client.is_logged_in, log)
    courses = client.courses()
    log(f"Learnweb: angemeldet ueber das CAS, {len(courses)} Kurse.")
    return client, courses, ""


def visible_courses(courses: list[dict], quiet: bool = False) -> list[dict]:
    courses = [c for c in courses if not c.get("hidden")]
    # Eigener Filter fuer Hildesheim; der LUH-Filter SEMESTER_FILTER gilt hier nicht (anderes Semester-Schema)
    flt = config.secret("HILDESHEIM_SEMESTER_FILTER")
    if flt:
        kept = [c for c in courses if flt.lower() in (c["semester"] or "").lower()]
        if len(kept) < len(courses) and not quiet:
            log(f"Learnweb: {len(kept)} von {len(courses)} Kursen passen zum Semesterfilter '{flt}'.")
        courses = kept
    return courses


def sync_learnweb(page, client, courses: list[dict], token: str, started: str, new_files: list[str]) -> int:
    courses = visible_courses(courses)
    with db.cursor() as conn:
        for c in courses:
            upsert_course(conn, c, started)
        conn.commit()
        # Jeder Kurs wird einzeln gespeichert: ein Fehler in einem Kurs verwirft nicht die schon geholten Dateien
        for c in courses:
            try:
                files = client.files(c["moodle_id"])
                folders = {f["id"]: f["folder"] for f in files if f.get("folder")}
                store_course_files(conn, c, files, folders, lambda url, target, size: _download(page, url, target, token, size),
                                   started, new_files)
                conn.commit()
            except Exception as e:  # noqa: BLE001
                conn.commit()
                log(f"Fehler im Kurs {c['title']}: {e}")
    return len(courses)


def store_deadlines(conn, items: list[dict], fetched_at: str, window_from: str) -> dict:
    """Learnweb-Fristen speichern. Was im abgefragten Zeitfenster (ab window_from, 120 Tage zurueck) nicht mehr kommt,
    ist im Learnweb geloescht oder erledigt und wird entfernt; aeltere Fristen bleiben als Verlauf stehen."""
    known = {r["id"] for r in db.rows(conn, "SELECT id FROM deadlines WHERE source='learnweb'")}
    for d in items:
        conn.execute("""INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                        VALUES (?, 'learnweb', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title,
                          full_title=excluded.full_title, kind=excluded.kind,
                          module=excluded.module, due_at=excluded.due_at, url=excluded.url, overdue=excluded.overdue, fetched_at=excluded.fetched_at""",
                     (d["id"], d.get("course_id"), d["title"], d.get("full_title") or d["title"], d["kind"], d.get("module"), d["due_at"], d.get("url"), int(bool(d.get("overdue"))), fetched_at))
    ids = [d["id"] for d in items]
    gone = conn.execute(f"""DELETE FROM deadlines WHERE source='learnweb' AND due_at >= ?
                            AND id NOT IN ({",".join("?" * len(ids)) or "''"})""", (window_from, *ids)).rowcount
    return {"new": len(set(ids) - known), "total": len(ids), "removed": gone}


def sync_deadlines(client) -> str:
    now = int(time.time())
    items = client.deadlines(now)
    with db.cursor() as conn:
        r = store_deadlines(conn, items, db.now_iso(), learnweb.local_iso(now - learnweb.DEADLINE_DAYS_BACK * 86400))
    return f"Fristen: {r['total']} ({r['new']} neu, {r['removed']} entfernt)"


def sync_announcements(client, courses: list[dict]) -> str:
    """Ankuendigungsforen aller sichtbaren Kurse; geloeschte Diskussionen verschwinden auch in der App."""
    courses = visible_courses(courses, quiet=True)
    with db.cursor() as conn:
        known = announcements.known_discussions(conn)
    items, seen = client.announcements(courses, known)
    with db.cursor() as conn:
        r = announcements.store(conn, items, "learnweb", db.now_iso())
        gone = 0
        for cid, ids in seen.items():
            gone += conn.execute(f"""DELETE FROM announcements WHERE source='learnweb' AND course_id=?
                                     AND (discussion IS NULL OR discussion NOT IN ({",".join("?" * len(ids)) or "''"}))""",
                                 (cid, *ids)).rowcount
        n_dates = sum(1 for a in items if a["dates"])
    return f"Ankuendigungen: {r['new']} neu ({n_dates} mit Termin), {gone} entfernt"


def sync_lsf_plan(page, user: str, pw: str) -> str:
    lsf.login(page, user, pw, log)
    ics = lsf.fetch_plan_ics(page)
    if not ics:
        return "LSF-Stundenplan ist leer"
    with db.cursor() as conn:
        r = lsf.import_plan(conn, lsf.plan_entries(ics))
    return f"Stundenplan: {r['new']} neu, {r['kept']} unveraendert, {r['removed']} entfernt"


def run_sync(show_browser: bool = False) -> dict:
    db.init_db()
    started = db.now_iso()
    new_files: list[str] = []
    ok, parts = False, []
    user, pw = config.own_credentials("HILDESHEIM")
    token = config.secret("LEARNWEB_TOKEN")
    try:
        if not token and not (user and pw):
            raise RuntimeError("Zugangsdaten fehlen. Bitte unter Einstellungen > Zugang den UNI-Account "
                               "oder einen Learnweb-Schluessel eintragen.")
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(_profile_dir()), headless=not show_browser, accept_downloads=True, locale="de-DE")
            try:
                page = ctx.new_page()
                client, courses, used_token = _learnweb_client(page, user, pw, token)
                n = sync_learnweb(page, client, courses, used_token, started, new_files)
                parts.append(f"{len(new_files)} neue/geaenderte Dateien aus {n} Learnweb-Kursen")
                try:
                    parts.append(sync_deadlines(client))
                except Exception as e:  # noqa: BLE001 - Fristen sind eine Ergaenzung, der Sync laeuft weiter
                    parts.append(f"Learnweb-Fristen: FEHLER {e}")
                    log(f"Learnweb-Fristen: {e}")
                try:
                    parts.append(sync_announcements(client, courses))
                except Exception as e:  # noqa: BLE001 - ebenso Ergaenzung
                    parts.append(f"Learnweb-Ankuendigungen: FEHLER {e}")
                    log(f"Learnweb-Ankuendigungen: {e}")
                if user and pw:
                    try:
                        parts.append(sync_lsf_plan(page, user, pw))
                    except Exception as e:  # noqa: BLE001
                        parts.append(f"LSF-Stundenplan: FEHLER {e}")
                        log(f"LSF-Stundenplan: {e}")
                else:
                    parts.append("LSF-Stundenplan uebersprungen (kein UNI-Account hinterlegt)")
            finally:
                ctx.close()
        ok = True
    except Exception as e:  # noqa: BLE001
        parts.append(f"FEHLER: {e}")
        log(f"FEHLER: {e}")
    message = ", ".join(parts)
    with db.cursor() as conn:
        conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,?,?)",
                     (started, db.now_iso(), int(ok), len(new_files), message))
    log(f"Hildesheim-Sync: {message}")
    return {"ok": ok, "new_files": new_files, "message": message}
