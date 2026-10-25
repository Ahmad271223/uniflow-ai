"""Sync fuer die Uni Hildesheim: Learnweb (Kurse, Dateien) + LSF (persoenlicher Stundenplan).

Zugangsdaten nur aus der lokalen .env:
  HILDESHEIM_USER / HILDESHEIM_PASSWORD  UNI-Account fuer das CAS (Learnweb ohne Schluessel, LSF)
  LEARNWEB_TOKEN                         optionaler Learnweb-Sicherheitsschluessel (Moodle mobile web service)
Der Schluessel wird nie in die Datenbank oder ins Protokoll geschrieben.
"""
from __future__ import annotations

from pathlib import Path

from playwright.sync_api import sync_playwright

from . import cas, config, db, learnweb, lsf
from .config import DATA_DIR, SEMESTER_FILTER
from .studip_sync import log, store_course_files, upsert_course
from .universities import HILDESHEIM_CAS, LEARNWEB_BASE

PROFILE_DIR = DATA_DIR / "browser-profile-hildesheim"
LEARNWEB_LOGIN = f"{LEARNWEB_BASE}/login/index.php?authCAS=CAS"


def _download(page, url: str, target: Path, token: str = "") -> None:
    r = page.request.get(learnweb.with_token(url, token) if token else url)
    if not r.ok:
        raise RuntimeError(f"Download fehlgeschlagen ({r.status}): {url}")   # url ohne Token
    body = r.body()
    if body[:15].lower().startswith((b"<!doctype html", b"<html")) and not target.suffix.lower() in (".html", ".htm"):
        raise RuntimeError(f"Statt der Datei kam eine Webseite zurueck (Anmeldung abgelaufen?): {url}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(body)


def _learnweb_client(page, user: str, pw: str, token: str):
    """Schluessel bevorzugt; bei fehlendem/ungueltigem Schluessel die CAS-Sitzung."""
    if token:
        client = learnweb.TokenClient(LEARNWEB_BASE, token)
        try:
            courses = client.courses()
            log(f"Learnweb: Zugriff mit Sicherheitsschluessel, {len(courses)} Kurse.")
            return client, courses, token
        except Exception as e:  # noqa: BLE001
            log(f"Learnweb-Schluessel funktioniert nicht ({e}); versuche die Anmeldung mit dem UNI-Account.")
            if not (user and pw):
                raise
    client = learnweb.SessionClient(page, LEARNWEB_BASE)
    cas.login(page, LEARNWEB_LOGIN, HILDESHEIM_CAS, user, pw, client.is_logged_in, log)
    courses = client.courses()
    log(f"Learnweb: angemeldet ueber das CAS, {len(courses)} Kurse.")
    return client, courses, ""


def sync_learnweb(page, client, courses: list[dict], token: str, started: str, new_files: list[str]) -> int:
    if SEMESTER_FILTER:
        courses = [c for c in courses if SEMESTER_FILTER.lower() in (c["semester"] or "").lower()]
    courses = [c for c in courses if not c.get("hidden")]
    with db.cursor() as conn:
        for c in courses:
            upsert_course(conn, c, started)
        for c in courses:
            try:
                files = client.files(c["moodle_id"])
            except Exception as e:  # noqa: BLE001
                log(f"Fehler bei Dateiliste {c['title']}: {e}")
                continue
            folders = {f["id"]: f["folder"] for f in files if f.get("folder")}
            store_course_files(conn, c, files, folders, lambda url, target: _download(page, url, target, token), started, new_files)
    return len(courses)


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
            ctx = p.chromium.launch_persistent_context(str(PROFILE_DIR), headless=not show_browser, accept_downloads=True, locale="de-DE")
            try:
                page = ctx.new_page()
                client, courses, used_token = _learnweb_client(page, user, pw, token)
                n = sync_learnweb(page, client, courses, used_token, started, new_files)
                parts.append(f"{len(new_files)} neue/geaenderte Dateien aus {n} Learnweb-Kursen")
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
