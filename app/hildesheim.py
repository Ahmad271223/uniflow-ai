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
    # gestreamt (konstanter Speicher); der Schluessel geht im POST-Koerper mit, nie in der Adresse
    # (learnweb.token_request, wie auf dem iPad); leere Antwort ersetzt nichts
    req = learnweb.token_request(url, token) if token else {"url": url, "form": None}
    stream_download(page, req["url"], target, shown_url=url, expected_size=size, form=req["form"], allowed_hosts=download_hosts())


def download_hosts() -> set[str]:
    """Learnweb-Host(s) fuer Downloads: die Instanzen unter LEARNWEB_ROOT und eine eigene Adresse aus der .env."""
    from urllib.parse import urlsplit
    hosts = {urlsplit(learnweb.LEARNWEB_ROOT).hostname, urlsplit(config.secret("HILDESHEIM_LEARNWEB_URL") or "").hostname}
    return {h.lower() for h in hosts if h}


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
    try:
        cas.login(page, f"{base}/login/index.php?authCAS=CAS", HILDESHEIM_CAS, user, pw, client.is_logged_in, log)
    except cas.CasLoginError as e:
        if not (user and pw):
            from .unilogin import LoginRequired
            raise LoginRequired("Learnweb-Sitzung abgelaufen: Einstellungen > Zugang > 'Im Browser anmelden'.") from e
        raise
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


def active_courses(courses: list[dict]) -> list[dict]:
    """Nur Kurse, die laut Semesterregel aktiv sind (app/semesters.py, eigene Schalter in Einstellungen -> Module).
    Kurse, die noch nicht gespeichert sind, zaehlen als aktiv (sie werden gleich mit der Regel angelegt)."""
    with db.cursor() as conn:
        off = {r["id"] for r in db.rows(conn, "SELECT id FROM courses WHERE active=0")}
    return [c for c in courses if c["id"] not in off]


def sync_learnweb(page, client, courses: list[dict], token: str, started: str, new_files: list[str],
                  older_only: bool = False) -> int:
    """Learnweb-Kurse speichern und Dateien holen. Seit 28.10.2026 (Entscheidung des Inhabers) wie bei Stud.IP nur fuer
    aktive Kurse: Kurse frueherer Semester bleiben bekannt, kosten aber keinen Abruf und keinen Download mehr.
    Ausnahme: Dateien frueherer Semester auf Wunsch (app/older_semesters.py: Frage nach dem ersten Abgleich, "Dateien
    laden" in der Bibliothek, Einstellung unter Module). `older_only`: nur diese, die aktiven Kurse bleiben unberuehrt."""
    from . import older_semesters
    courses = visible_courses(courses)
    with db.cursor() as conn:
        for c in courses:
            upsert_course(conn, c, started)
        conn.commit()
    from . import sync_order
    kept = active_courses(courses)
    with db.cursor() as conn:
        wanted = older_semesters.pending(conn)
    keep_ids = {c["id"] for c in kept}
    # Reihenfolge (app/sync_order.py, 05.11.2026): der volle Lauf holt nur aktuelle (und naechste) Kurse, aktuelle
    # zuerst; fruehere Semester kommen danach in Stufe (d) (`older_only`), neuestes Semester zuerst, gedrosselt
    staged = sync_order.split(kept, keep_ids)
    kept = staged["current"] + staged["upcoming"]
    older = sync_order.newest_first([c for c in courses if c["id"] in wanted and c["id"] not in keep_ids]) if older_only else []
    if len(kept) < len(courses) and not older_only:
        log(f"Learnweb: {len(courses) - len(kept)} Kurse aus frueheren Semestern: Dateien kommen danach im Hintergrund.")
    complete: set[str] = set()
    with db.cursor() as conn:
        # Jeder Kurs wird einzeln gespeichert: ein Fehler in einem Kurs verwirft nicht die schon geholten Dateien
        for i, c in enumerate(([] if older_only else kept) + older):
            if older_only and i > 0 and not sync_order.older_continue():
                log("Frühere Semester: angehalten, der nächste Lauf macht weiter.")
                break
            try:
                files = client.files(c["moodle_id"])
                folders = {f["id"]: f["folder"] for f in files if f.get("folder")}
                store_course_files(conn, c, files, folders, lambda url, target, size: _download(page, url, target, token, size),
                                   started, new_files)
                complete.add(c["id"])
                conn.commit()
            except Exception as e:  # noqa: BLE001
                conn.commit()
                log(f"Fehler im Kurs {c['title']}: {e}")
        older_semesters.finish(conn, [c["id"] for c in older if c["id"] in complete], db.now_iso())
    return len(older) if older_only else len(kept)


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
    """Ankuendigungsforen aller sichtbaren, aktiven Kurse; geloeschte Diskussionen verschwinden auch in der App."""
    courses = active_courses(visible_courses(courses, quiet=True))
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


def sync_messages(client, page, used_token: bool) -> str:
    """Learnweb-Nachrichten (Unterhaltungen) nur lesend in die Liste "Nachrichten" (app/learnweb_messages.py); markiert
    im Learnweb nichts als gelesen."""
    from . import learnweb_messages as lm
    if used_token:
        me, call = lm.token_user(client), lm.token_call(client)
    else:
        me, call = lm.session_user(page), client.ajax
    if not me:
        return "Learnweb-Nachrichten: eigene Kennung unbekannt, uebersprungen"
    items = lm.fetch(call, me, client.base)
    with db.cursor() as conn:
        lm.store(conn, items, db.now_iso())
    return f"Nachrichten: {len(items)}"


def sync_lsf_plan(page, user: str, pw: str) -> str:
    lsf.login(page, user, pw, log)
    ics = lsf.fetch_plan_ics(page)
    notice = None
    try:
        notice = lsf.maintenance_notice(page.content())       # "+++ Wartungsarbeiten ... +++" als Hinweis (05.11.2026)
    except Exception:  # noqa: BLE001
        pass
    hint = f", LSF-Hinweis: {notice}" if notice else ""
    if not ics:
        return "LSF-Stundenplan ist leer" + hint
    with db.cursor() as conn:
        r = lsf.import_plan(conn, lsf.plan_entries(ics))
    return f"Stundenplan: {r['new']} neu, {r['kept']} unveraendert, {r['removed']} entfernt" + hint


def run_sync(show_browser: bool = False, older_only: bool = False) -> dict:
    """`older_only`: nur die Dateien gewuenschter Kurse frueherer Semester (app/older_semesters.py), ohne Fristen,
    Ankuendigungen und Stundenplan."""
    db.init_db()
    started = db.now_iso()
    new_files: list[str] = []
    ok, parts = False, []
    from . import unilogin
    user, pw = config.own_credentials("HILDESHEIM")
    token = config.secret("LEARNWEB_TOKEN")
    session = unilogin.has_session("LEARNWEB_COOKIES")
    try:
        if not token and not (user and pw) and not session:
            raise unilogin.LoginRequired("Anmeldung beim Learnweb noetig: Einstellungen > Zugang > 'Im Browser anmelden' "
                                         "(oder UNI-Account bzw. Learnweb-Schluessel eintragen).")
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(_profile_dir()), headless=not show_browser, accept_downloads=True, locale="de-DE")
            try:
                page = ctx.new_page()
                if session:
                    try:
                        unilogin.restore(ctx, "LEARNWEB_COOKIES")       # CAS-/Moodle-Sitzung aus dem Anmeldefenster
                        log("Gemerkte Learnweb-Sitzung eingesetzt.")
                    except Exception as e:  # noqa: BLE001
                        log(f"Gemerkte Sitzung nicht eingesetzt: {e}")
                client, courses, used_token = _learnweb_client(page, user, pw, token)
                if not used_token:
                    try:
                        from . import filestream
                        filestream.save_cookies("LEARNWEB_COOKIES", ctx.cookies())   # Dienst: CAS-Sitzung fuer das Durchreichen
                    except Exception as e:  # noqa: BLE001
                        log(f"Learnweb-Sitzung nicht gemerkt: {e}")
                # Stundenplan (LSF) vor den Dateien: das aktuelle Semester samt Woche zuerst (app/sync_order.py)
                lsf_ok = (user and pw) or (session and not used_token)
                if not older_only and lsf_ok:
                    try:        # mit Sitzung: klappt, solange die CAS-Anmeldung aus dem Fenster noch gilt
                        parts.append(sync_lsf_plan(page, user, pw))
                    except Exception as e:  # noqa: BLE001
                        parts.append(f"LSF-Stundenplan: FEHLER {e}")
                        log(f"LSF-Stundenplan: {e}")
                n = sync_learnweb(page, client, courses, used_token, started, new_files, **({"older_only": True} if older_only else {}))
                parts.append(f"{len(new_files)} neue/geaenderte Dateien aus {n} Learnweb-Kursen"
                             + (" früherer Semester" if older_only else ""))
                if not older_only:
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
                    try:
                        parts.append(sync_messages(client, page, used_token))
                    except Exception as e:  # noqa: BLE001 - Nachrichten sind eine Ergaenzung, der Sync laeuft weiter
                        parts.append(f"Learnweb-Nachrichten: FEHLER {e}")
                        log(f"Learnweb-Nachrichten: {e}")
                    if not lsf_ok:
                        parts.append("LSF-Stundenplan uebersprungen (kein UNI-Account hinterlegt)")
                    from . import sync_order
                    with db.cursor() as conn:
                        sync_order.mark_current_ready(conn, db.now_iso())
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
