"""Sync fuer die Hochschule Hannover (HsH): Moodle (Kurse, Dateien, Fristen, Ankuendigungen) und Campusmanagement
(HISinOne: persoenlicher Stundenplan als iCal, Leistungen). docs/HSH-2026-11-05.md.

Anmeldung nur im Anmeldefenster (app/unilogin.py): der Mensch tippt seinen SSO-Account auf den echten Seiten von
Moodle und HISinOne, die App merkt nur die Sitzung (HSH_COOKIES), nie ein Passwort. Optional ein selbst erzeugter
Moodle-Schluessel (HSH_MOODLE_TOKEN, "Moodle mobile web service"), falls die HsH den Webservice anbietet (unbekannt).

Moodle-Teil: dieselben Leser wie das Learnweb der Uni Hildesheim (app/learnweb.py, ein Moodle), nur mit fester
Adresse (kein jaehrlicher Wechsel wie learnweb2026). HISinOne-Teil: app/hisinone.py.
"""
from __future__ import annotations

from pathlib import Path

from . import config, db, hisinone, learnweb, lsf, qis
from .config import DATA_DIR
from .studip_sync import log, stream_download
from .universities import HSH_MOODLE_BASE

PROFILE_DIR = DATA_DIR / "browser-profile-hsh"
SESSION = "HSH_COOKIES"
TOKEN = "HSH_MOODLE_TOKEN"


def _profile_dir() -> Path:
    return config.data_dir() / "browser-profile-hsh" if config.current_user_id() else PROFILE_DIR


def moodle_base() -> str:
    return (config.secret("HSH_MOODLE_URL") or HSH_MOODLE_BASE).rstrip("/")


def login_url() -> str:
    return f"{moodle_base()}/login/index.php"


def download_hosts() -> set[str]:
    from urllib.parse import urlsplit
    return {h.lower() for h in {urlsplit(moodle_base()).hostname} if h}


def _download(page, url: str, target: Path, token: str = "", size: int = 0) -> None:
    req = learnweb.token_request(url, token) if token else {"url": url, "form": None}
    stream_download(page, req["url"], target, shown_url=url, expected_size=size, form=req["form"], allowed_hosts=download_hosts())


def _moodle_client(page, token: str):
    """Schluessel bevorzugt; sonst die Moodle-Sitzung aus dem Anmeldefenster (kein automatisches Anmelden)."""
    base = moodle_base()
    if token:
        client = learnweb.TokenClient(base, token)
        try:
            courses = client.courses()
            log(f"Moodle (HsH): Zugriff mit Schluessel, {len(courses)} Kurse.")
            return client, courses, token
        except Exception as e:  # noqa: BLE001
            log(f"Moodle-Schluessel funktioniert nicht ({e}); versuche die gemerkte Sitzung.")
    client = learnweb.SessionClient(page, base)
    page.goto(f"{base}/my/", wait_until="domcontentloaded")
    if not client.is_logged_in():
        from .unilogin import LoginRequired
        raise LoginRequired("Moodle-Sitzung abgelaufen: Einstellungen > Zugang > 'Im Browser anmelden'.")
    courses = client.courses()
    log(f"Moodle (HsH): angemeldet, {len(courses)} Kurse.")
    return client, courses, ""


def sync_moodle(page, client, courses, token: str, started: str, new_files: list[str], older_only: bool = False) -> int:
    """Wie hildesheim.sync_learnweb (Kurse speichern, Dateien aktiver Kurse holen), mit HsH-Downloads"""
    from . import hildesheim
    original = hildesheim._download
    hildesheim._download = _download               # Downloads nur vom HsH-Moodle (allowed_hosts)
    try:
        return hildesheim.sync_learnweb(page, client, courses, token, started, new_files, older_only=older_only)
    finally:
        hildesheim._download = original


ICAL_SECRET = "HSH_ICAL_URL"


def _ics_from_saved(page) -> str | None:
    """Gemerkte Abo-Adresse des Stundenplans (persoenlich, nur in der .env/im Tresor, nie im Protokoll)"""
    url = config.secret(ICAL_SECRET)
    if not hisinone.is_export_url(url):
        return None
    r = page.request.get(url)
    text = r.text() if r.ok else ""
    return text if "BEGIN:VCALENDAR" in text and "BEGIN:VEVENT" in text else None


def sync_plan(page) -> str:
    try:
        ics = hisinone.fetch_plan_ics(page)
        link = hisinone.ical_link(page.content())
        if link and link != config.secret(ICAL_SECRET):
            config.set_env({ICAL_SECRET: link})
    except hisinone.SessionExpired:
        ics = _ics_from_saved(page)                 # Abo-Adresse braucht keine Sitzung
        if ics is None:
            raise
    if not ics:
        return "Stundenplan (Campusmanagement) ist leer"
    entries = lsf.plan_entries(ics)
    with db.cursor() as conn:
        r = lsf.import_plan(conn, entries)
    return f"Stundenplan: {r['new']} neu, {r['kept']} unveraendert, {r['removed']} entfernt"


def sync_grades(page) -> str:
    grades = hisinone.fetch_grades(page)
    started = db.now_iso()
    with db.cursor() as conn:
        qis.store_grades(conn, grades)
        conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,1,?,?,0)",
                     (started, db.now_iso(), f"{len(grades)} Leistungen", len(grades)))
    return f"Leistungen: {len(grades)}"


def sync_registrations(page) -> str:
    """Nur lesen, welche Pruefungen angemeldet sind (nie an- oder abmelden)"""
    from . import qis_registrations
    rows = hisinone.fetch_exam_registrations(page)
    with db.cursor() as conn:
        qis_registrations.store(conn, rows, db.now_iso())
    return qis_registrations.message(len(rows), "Campusmanagement")


def sync_messages(client, page, used_token: str) -> str:
    """Moodle-Nachrichten nur lesend in die Liste "Nachrichten" (app/moodle.py wie MoodleMessages auf dem iPad); markiert
    in Moodle nichts als gelesen, speichert keine Namen"""
    from . import learnweb_messages as lm, moodle
    if used_token:
        me, call = lm.token_user(client), lm.token_call(client)
    else:
        me, call = lm.session_user(page), client.ajax
    with db.cursor() as conn:
        r = moodle.sync_messages(moodle.MoodleWeb(moodle_base(), ""), conn, db.now_iso(), call=call, me=me)
    return r["message"]


def run_sync(show_browser: bool = False, older_only: bool = False) -> dict:
    from playwright.sync_api import sync_playwright

    from . import hildesheim, unilogin
    db.init_db()
    started = db.now_iso()
    new_files: list[str] = []
    ok, parts = False, []
    token = config.secret(TOKEN)
    session = unilogin.has_session(SESSION)
    try:
        if not token and not session:
            raise unilogin.LoginRequired("Anmeldung bei Moodle nötig: Einstellungen > Zugang > 'Im Browser anmelden'.")
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(_profile_dir()), headless=not show_browser, accept_downloads=True, locale="de-DE")
            try:
                page = ctx.new_page()
                if session:
                    try:
                        unilogin.restore(ctx, SESSION)
                    except Exception as e:  # noqa: BLE001
                        log(f"Gemerkte Sitzung nicht eingesetzt: {e}")
                client, courses, used = _moodle_client(page, token)
                if older_only:
                    n = sync_moodle(page, client, courses, used, started, new_files, older_only=True)
                    parts.append(f"{len(new_files)} neue/geaenderte Dateien aus {n} Moodle-Kursen früherer Semester")
                else:
                    # Reihenfolge (app/sync_order.py, 05.11.2026): (a) Stundenplan vor den Dateien, dann Fristen,
                    # Ankuendigungen und angemeldete Pruefungen des aktuellen Semesters; (b) Leistungen. Fruehere
                    # Semester holt danach Stufe (d) im Hintergrund (older_only)
                    from . import sync_order

                    def extras(steps):
                        for label, fn in steps:
                            try:
                                parts.append(fn())
                            except Exception as e:  # noqa: BLE001 - Ergaenzungen: der Lauf geht weiter
                                parts.append(f"{label}: FEHLER {e}")
                                log(f"{label}: {e}")
                    extras((("Campusmanagement-Stundenplan", lambda: sync_plan(page)),))
                    n = sync_moodle(page, client, courses, used, started, new_files)
                    parts.append(f"{len(new_files)} neue/geaenderte Dateien aus {n} Moodle-Kursen")
                    extras((("Moodle-Fristen", lambda: hildesheim.sync_deadlines(client)),
                            ("Moodle-Ankuendigungen", lambda: hildesheim.sync_announcements(client, courses)),
                            ("Angemeldete Pruefungen", lambda: sync_registrations(page)),
                            ("Moodle-Nachrichten", lambda: sync_messages(client, page, used))))
                    with db.cursor() as conn:
                        sync_order.mark_current_ready(conn, db.now_iso())
                    extras((("Campusmanagement-Leistungen", lambda: sync_grades(page)),))
                    try:
                        unilogin.save_session(SESSION, ctx.cookies())   # erneuerte Sitzung (Moodle und HISinOne)
                    except Exception as e:  # noqa: BLE001
                        log(f"Sitzung nicht gemerkt: {e}")
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
    log(f"HsH-Sync: {message}")
    return {"ok": ok, "new_files": new_files, "message": message}


def run_grades(show_browser: bool = False) -> dict:
    """"Noten abrufen" (qis.run) an der HsH: nur die Leistungen, mit der gemerkten Sitzung"""
    from playwright.sync_api import sync_playwright

    from . import unilogin
    db.init_db()
    started = db.now_iso()
    if not unilogin.has_session(SESSION):
        msg = "Anmeldung beim Campusmanagement nötig (Einstellungen > Zugang > im Browser anmelden)."
        n, ok = 0, False
    else:
        try:
            with sync_playwright() as p:
                ctx = p.chromium.launch_persistent_context(str(_profile_dir()), headless=not show_browser, locale="de-DE")
                try:
                    unilogin.restore(ctx, SESSION)
                    page = ctx.new_page()
                    grades = hisinone.fetch_grades(page)
                finally:
                    ctx.close()
            with db.cursor() as conn:
                qis.store_grades(conn, grades)
            n, ok = len(grades), True
            msg = f"{n} Leistungen" + ("" if n else " – im Campusmanagement stehen noch keine Leistungen")
        except Exception as e:  # noqa: BLE001
            n, ok, msg = 0, False, f"FEHLER: {e}"
    with db.cursor() as conn:
        conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,?,?,?,0)",
                     (started, db.now_iso(), int(ok), msg, n))
    return {"ok": ok, "message": msg, "grades": n, "documents": 0}
