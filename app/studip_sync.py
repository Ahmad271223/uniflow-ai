"""Stud.IP-Synchronisation: Login ueber WebSSO, Kursliste, Dateilisten, Downloads.

Ablauf:
 1. Playwright-Browser startet, oeffnet die Stud.IP-Loginseite und wird zum WebSSO weitergeleitet.
 2. LUH-ID und Passwort aus der .env werden in das SSO-Formular eingetragen.
 3. Mit der eingeloggten Sitzung werden Kurse (JSON-API) und Dateien ("Alle Dateien"-Ansicht) gelesen.
 4. Neue oder geaenderte Dateien werden nach data/files/<Kurs>/ heruntergeladen.
"""
from __future__ import annotations

import html
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import BrowserContext, Page, sync_playwright

from . import config, db
from .config import DATA_DIR, FILES_DIR, LOG_DIR, SEMESTER_FILTER, STUDIP_BASE

LOGIN_URL = f"{STUDIP_BASE}/dispatch.php/login"
# Direkter WebSSO-Einstieg (ueberspringt die Uni-Auswahl auf der Loginseite)
SSO_ENTITY_ID = "https://sso.idm.uni-hannover.de/idp/shibboleth"
SHIB_LOGIN_URL = (f"{STUDIP_BASE}/Shibboleth.sso/Login?target="
                  + quote(f"{STUDIP_BASE}/dispatch.php/login?sso=shib&again=yes&cancel_login=1", safe="")
                  + "&entityID=" + quote(SSO_ENTITY_ID, safe=""))
PROFILE_DIR = DATA_DIR / "browser-profile"       # LUH: data/browser-profile wie bisher


def console_print(line: str) -> None:
    """Konsolenausgabe, die nie abbricht: Die Windows-Konsole (cp1252) kennt z. B. U+0308 nicht."""
    try:
        print(line, flush=True)
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        print(line.encode(enc, "replace").decode(enc, "replace"), flush=True)
    except (OSError, ValueError):
        pass   # keine Konsole (z. B. Hintergrunddienst)


def log(msg: str) -> None:
    line = f"[{db.now_iso()}] {msg}"
    console_print(line)
    with open(LOG_DIR / "sync.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")


# ----------------------------------------------------------------------------
# Login
# ----------------------------------------------------------------------------

def _is_logged_in(page: Page) -> bool:
    try:
        resp = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/users/me",
                                headers={"Accept": "application/vnd.api+json"})
        return resp.ok and '"username"' in resp.text()
    except Exception:
        return False


def login(page: Page) -> None:
    """Oeffnet Stud.IP und meldet sich ueber das WebSSO an, falls noetig. Bei Fehlern: Screenshot in logs/."""
    try:
        _login(page)
    except Exception:
        try:
            page.screenshot(path=str(LOG_DIR / "login-fehler.png"), full_page=True)
            log(f"Login-Fehler, Screenshot: {LOG_DIR / 'login-fehler.png'}  URL: {page.url}")
        except Exception:  # noqa: BLE001
            pass
        raise


def _login(page: Page) -> None:
    page.goto(LOGIN_URL, wait_until="domcontentloaded")
    page.wait_for_timeout(1000)
    if _is_logged_in(page):
        log("Sitzung ist bereits angemeldet.")
        return

    user, password = config.credentials()
    if not user or not password:
        raise RuntimeError("Zugangsdaten fehlen. Bitte in der App unter Einstellungen > Stud.IP-Zugang eintragen.")

    # Direkt zum WebSSO der Uni Hannover (statt Uni-Auswahl auf der Loginseite)
    page.goto(SHIB_LOGIN_URL, wait_until="domcontentloaded")
    page.wait_for_timeout(1500)
    if _is_logged_in(page):
        log("SSO-Sitzung war noch gueltig, angemeldet.")
        return

    # Auf das sichtbare SSO-Formular warten (LUH WebSSO: Felder 'loginname' und 'password')
    pass_field = page.locator("input[type='password']:visible").first
    pass_field.wait_for(state="visible", timeout=45000)
    user_field = None
    for sel in ("input[name='loginname']:visible", "#loginname:visible", "input[name='j_username']:visible",
                "#username:visible", "input[autocomplete='username']:visible", "input[type='text']:visible"):
        loc = page.locator(sel)
        if loc.count() > 0:
            user_field = loc.first
            break
    if user_field is None:
        raise RuntimeError("Benutzername-Feld auf der SSO-Seite nicht gefunden")
    user_field.fill(user)
    pass_field.fill(password)

    # Anmelden-Button (oder Enter im Passwortfeld)
    btn = page.locator("button[name='_eventId_proceed']:visible, button:has-text('Anmelden'):visible, "
                       "input[type='submit']:visible, button[type='submit']:visible")
    if btn.count() > 0:
        btn.first.click()
    else:
        pass_field.press("Enter")
    page.wait_for_load_state("domcontentloaded")
    page.wait_for_timeout(2000)

    # Manche IdPs zeigen eine Zwischenseite (Attribut-Freigabe) mit einem weiteren Button
    for _ in range(3):
        if "studip.uni-hannover.de" in page.url and _is_logged_in(page):
            break
        proceed = page.locator("button[name='_eventId_proceed'], input[type='submit'][value*='Akzept'], button:has-text('Akzeptieren'), button:has-text('Weiter')")
        if proceed.count() > 0:
            proceed.first.click()
            page.wait_for_load_state("domcontentloaded")
            page.wait_for_timeout(2000)
        else:
            page.wait_for_timeout(1500)

    if not _is_logged_in(page):
        shot = LOG_DIR / "login-fehler.png"
        page.screenshot(path=str(shot), full_page=True)
        raise RuntimeError(f"Login fehlgeschlagen. Screenshot: {shot}  URL: {page.url}")
    log("Login erfolgreich.")


# ----------------------------------------------------------------------------
# Daten holen
# ----------------------------------------------------------------------------

def fetch_courses(page: Page) -> list[dict]:
    me = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/users/me",
                          headers={"Accept": "application/vnd.api+json"}).json()
    uid = me["data"]["id"]
    out = []
    url = f"{STUDIP_BASE}/jsonapi.php/v1/users/{uid}/courses?page[limit]=100&include=start-semester"
    while url:
        j = page.request.get(url, headers={"Accept": "application/vnd.api+json"}).json()
        sems = {i["id"]: i["attributes"].get("title", "") for i in j.get("included", []) if i["type"] == "semesters"}
        for c in j["data"]:
            a = c["attributes"]
            sem_id = (c.get("relationships", {}).get("start-semester", {}).get("data") or {}).get("id")
            out.append({
                "id": c["id"],
                "title": re.sub(r"\s+", " ", a.get("title", "")).strip(),
                "number": (a.get("course-number") or "").strip() or None,
                "semester": sems.get(sem_id, ""),
            })
        url = j.get("links", {}).get("next")
        if url and url.startswith("/"):
            url = STUDIP_BASE + url
    return out


def fetch_events(page: Page, course_id: str) -> list[dict]:
    """Termine (Sitzungen) eines Kurses aus der JSON-API: Titel, Beginn, Ende, Raum."""
    out = []
    url = f"{STUDIP_BASE}/jsonapi.php/v1/courses/{course_id}/events?page[limit]=200"
    while url:
        resp = page.request.get(url, headers={"Accept": "application/vnd.api+json"})
        if not resp.ok:
            break
        j = resp.json()
        for e in j.get("data", []):
            a = e.get("attributes", {})
            if a.get("is-cancelled"):
                continue
            out.append({"id": e["id"], "course_id": course_id, "title": a.get("title") or "", "start": (a.get("start") or "")[:19],
                        "end": (a.get("end") or "")[:19], "room": (a.get("location") or "").split(",")[0].strip()})
        url = j.get("links", {}).get("next")
        if url and url.startswith("/"):
            url = STUDIP_BASE + url
    return out


def fetch_schedule_entries(page: Page, uid: str) -> list[dict]:
    """Persoenliche Eintraege aus dem Stud.IP-Stundenplan des Nutzers (selbst angelegte Termine)."""
    resp = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/users/{uid}/schedule", headers={"Accept": "application/vnd.api+json"})
    if not resp.ok:
        return []
    out = []
    for e in resp.json().get("data", []):
        if e.get("type") != "schedule-entries":
            continue
        a = e.get("attributes", {})
        out.append({"id": e["id"], "title": a.get("title") or "Termin", "weekday": int(a.get("weekday", 1)) - 1, "start": a.get("start"), "end": a.get("end"), "description": a.get("description") or ""})
    return out


def store_schedule_entries(conn, entries: list[dict]) -> None:
    for e in entries:
        conn.execute("""INSERT INTO studip_schedule_entries(id, title, weekday, start, end, description, fetched_at) VALUES (?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET title=excluded.title, weekday=excluded.weekday, start=excluded.start, end=excluded.end, description=excluded.description, fetched_at=excluded.fetched_at""",
                     (e["id"], e["title"], e["weekday"], e["start"], e["end"], e["description"], db.now_iso()))


def store_events(conn, events: list[dict]) -> None:
    for e in events:
        conn.execute("""INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET title=excluded.title, start=excluded.start, end=excluded.end, room=excluded.room, fetched_at=excluded.fetched_at""",
                     (e["id"], e["course_id"], e["title"], e["start"], e["end"], e["room"], db.now_iso()))


def fetch_files(page: Page, course_id: str) -> list[dict]:
    resp = page.request.get(f"{STUDIP_BASE}/dispatch.php/course/files/flat?cid={course_id}")
    text = resp.text()
    m = re.search(r'data-files="([^"]*)"', text)
    if not m:
        return []
    data = json.loads(html.unescape(m.group(1)))
    files = []
    for f in data:
        url = html.unescape(f.get("download_url") or "")
        if not url:
            # Fallback: Standard-Downloadlink von Stud.IP
            url = f"{STUDIP_BASE}/sendfile.php?type=0&file_id={f['id']}&file_name={quote(f['name'])}"
        files.append({
            "id": f["id"],
            "name": f["name"],
            "size": int(f.get("size") or 0),
            "mime": f.get("mime_type"),
            "author": f.get("author_name"),
            "chdate": int(f.get("chdate") or 0),
            "download_url": url,
        })
    return files


def fetch_folder_paths(page: Page, course_id: str) -> dict[str, str]:
    """Ordnerpfad je Datei (FileRef-ID) ueber die JSON-API: /courses/{id}/folders -> /folders/{id}/folders|file-refs."""
    hdr = {"Accept": "application/vnd.api+json"}
    out: dict[str, str] = {}
    r = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/courses/{course_id}/folders?page[limit]=200", headers=hdr)
    if not r.ok:
        return out
    tops = r.json().get("data", [])
    roots = [f for f in tops if (f.get("attributes") or {}).get("folder-type") == "RootFolder"] or tops[:1]
    seen: set[str] = set()

    def walk(fid: str, path: str, depth: int) -> None:
        if fid in seen or depth > 6:
            return
        seen.add(fid)
        fr = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/folders/{fid}/file-refs?page[limit]=500", headers=hdr)
        if fr.ok:
            for x in fr.json().get("data", []):
                out[x["id"]] = path
        sub = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/folders/{fid}/folders?page[limit]=200", headers=hdr)
        if sub.ok:
            for x in sub.json().get("data", []):
                name = ((x.get("attributes") or {}).get("name") or "").strip()
                walk(x["id"], f"{path}/{name}" if path else name, depth + 1)

    for root in roots:
        walk(root["id"], "", 0)
    return out


def file_kind(name: str, mime: str | None = None) -> str:
    """pdf | image | file  (nur echte PDFs gehen in den PDF-Editor)."""
    n = (name or "").lower(); m = (mime or "").lower()
    if n.endswith(".pdf") or m == "application/pdf":
        return "pdf"
    if n.endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")) or m.startswith("image/"):
        return "image"
    return "file"


def safe_name(s: str) -> str:
    s = unicodedata.normalize("NFC", s or "")      # 'a' + U+0308 -> 'ä' (Mac-/Moodle-Dateinamen)
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", s)
    return s.strip(" .")[:120] or "datei"


HTML_STARTS = (b"<!doctype html", b"<html")


def empty_download(first: bytes, target: Path, expected_size: int = 0) -> bool:
    """Leere Antwort (0 Bytes) statt der Datei: ein Fehler dieser Datei, wenn die Quelle eine Groesse > 0 meldet
    oder schon eine lokale Fassung existiert. Dann bleibt die alte Datei stehen und die Datei gilt beim naechsten
    Abgleich weiter als geaendert (eine leere Antwort ersetzt und loescht nie etwas). Dieselbe Regel im Kern der
    iPad-App (UniDownloads.load)."""
    return not first and ((expected_size or 0) > 0 or target.exists())


def stream_download(page, url: str, target: Path, shown_url: str | None = None, timeout: int = 180,
                    expected_size: int = 0, form: dict | None = None) -> None:
    """Datei direkt auf die Platte streamen, mit den Cookies der angemeldeten Browsersitzung.
    Playwright (page.request) haelt jede Antwort komplett im Speicher; beim Live-Test mit 539 Dateien (1 GB)
    wuchs der Serverprozess so auf 2,7 GB. Hier bleibt der Speicher konstant (1-MB-Bloecke).
    Schreibt erst in <name>.part und ersetzt dann atomar: ein Abbruch zerstoert nie eine gute Datei.
    Kommt eine HTML-Seite statt der Datei (abgelaufene Anmeldung) oder eine leere Antwort (`empty_download`,
    `expected_size` = Groesse laut Quelle), wird nichts gespeichert. Mit `form` als POST mit diesem Formular
    (Learnweb-Schluessel im Koerper statt in der Adresse)."""
    import shutil
    import urllib.parse
    import urllib.request
    shown = shown_url or url
    headers = {"User-Agent": _user_agent(page), "Accept": "*/*"}
    try:
        jar = page.context.cookies([url])
    except Exception:  # noqa: BLE001
        jar = []
    if jar:
        headers["Cookie"] = "; ".join(f"{c['name']}={c['value']}" for c in jar)
    data = None
    if form:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if form else "GET")
    # Abgerissene Verbindungen (WLAN, Zeitueberschreitung) bis zu zweimal wiederholen; HTTP-Fehler und
    # Anmeldeseiten nicht, die aendern sich durch Wiederholen nicht.
    for attempt in range(3):
        try:
            _stream_once(req, target, shown, timeout, expected_size)
            return
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Download fehlgeschlagen ({e.code}): {shown}") from None
        except (ConnectionError, TimeoutError, urllib.error.URLError, OSError) as e:
            if isinstance(e, urllib.error.HTTPError) or attempt == 2:
                raise RuntimeError(f"Download abgebrochen ({type(e).__name__}): {shown}") from None
            time.sleep(1.5 * (attempt + 1))


def _stream_once(req, target: Path, shown: str, timeout: int, expected_size: int = 0) -> None:
    import shutil
    import urllib.request
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - URL stammt aus der Uni-Schnittstelle
        first = resp.read(65536)
        if first.lstrip()[:15].lower().startswith(HTML_STARTS) and target.suffix.lower() not in (".html", ".htm"):
            raise RuntimeError(f"Statt der Datei kam eine Webseite zurueck (Anmeldung abgelaufen?): {shown}")
        if empty_download(first, target, expected_size):
            raise RuntimeError(f"Leere Antwort statt der Datei: {shown}")
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_name(target.name + ".part")
        try:
            with open(part, "wb") as f:
                f.write(first)
                shutil.copyfileobj(resp, f, 1 << 20)
            os.replace(part, target)
        finally:
            part.unlink(missing_ok=True)


_UA: dict[int, str] = {}


def _user_agent(page) -> str:
    try:
        key = id(page.context)
        if key not in _UA:
            _UA[key] = page.evaluate("() => navigator.userAgent")
        return _UA[key]
    except Exception:  # noqa: BLE001
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) UniFlow-Lernapp"


def download(page: Page, url: str, target: Path, expected_size: int = 0) -> None:
    """Stud.IP: gestreamt; falls das scheitert (z. B. Cookie-Eigenheiten), einmal der alte Weg ueber
    page.request, mit sofortiger Freigabe des Antwortspeichers (dispose)."""
    try:
        stream_download(page, url, target, expected_size=expected_size)
        return
    except Exception as e:  # noqa: BLE001
        log(f"Gestreamter Download fehlgeschlagen ({e}); versuche den Browser-Weg.")
    resp = page.request.get(url)
    try:
        if not resp.ok:
            raise RuntimeError(f"Download fehlgeschlagen ({resp.status}): {url}")
        body = resp.body()
        if body.lstrip()[:15].lower().startswith(HTML_STARTS) and target.suffix.lower() not in (".html", ".htm"):
            raise RuntimeError(f"Statt der Datei kam eine Webseite zurueck (Anmeldung abgelaufen?): {url}")
        if empty_download(body, target, expected_size):
            raise RuntimeError(f"Leere Antwort statt der Datei: {url}")
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_name(target.name + ".part")
        part.write_bytes(body)
        os.replace(part, target)
    finally:
        try:
            resp.dispose()
        except Exception:  # noqa: BLE001
            pass


# ----------------------------------------------------------------------------
# Fach-Zuordnung (Vorlesung + Uebung zusammenfassen)
# ----------------------------------------------------------------------------

def classify(title: str) -> tuple[str, str]:
    """Liefert (subject, kind)."""
    t = title
    kind = "vorlesung"
    if re.search(r"Gruppenübung|Gruppenuebung", t, re.I):
        kind = "gruppenuebung"
    elif re.search(r"Hörsaalübung|Hoersaaluebung|Zentralübung", t, re.I):
        kind = "hoersaaluebung"
    elif re.search(r"\b(Übung|Uebung|Fragestunde)", t, re.I):
        kind = "uebung"
    elif re.search(r"Tutorium", t, re.I):
        kind = "tutorium"
    if re.search(r"Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester", t, re.I):
        kind = "sonstiges"
    s = t
    s = re.sub(r"^\d+\s+", "", s)                                   # Nummer vorne
    s = re.sub(r"^(Gruppenübung|Übung|Uebung|Tutorium)\s*(zu|zur|:)?\s*", "", s, flags=re.I)
    s = re.sub(r"\s*[-–]\s*(Fragestunden|Tutorium).*$", "", s, flags=re.I)
    s = re.sub(r"\s*\((Tranche[^)]*|für [^)]*|Elektrotechnische Grundlagen der Informationstechnik)\)", "", s, flags=re.I)
    s = re.sub(r",?\s*Tranche\s*\w+.*$", "", s, flags=re.I)
    s = re.sub(r"\s+", " ", s).strip(" -:,(")
    return s, kind



# ----------------------------------------------------------------------------
# Gemeinsames Speichern (Stud.IP und andere Quellen wie Learnweb)
# ----------------------------------------------------------------------------

def upsert_course(conn, c: dict, started: str) -> None:
    """Kurs anlegen/aktualisieren; Fach und Art nur setzen, wenn noch leer (der Nutzer darf sie aendern)."""
    subject, kind = classify(c["title"])
    conn.execute(
        """INSERT INTO courses(id, title, number, semester, subject, kind, created_at)
           VALUES (?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET title=excluded.title, number=excluded.number,
               semester=excluded.semester""",
        (c["id"], c["title"], c["number"], c["semester"], subject, kind, started),
    )
    conn.execute("UPDATE courses SET subject=COALESCE(subject, ?), kind=COALESCE(kind, ?) WHERE id=?",
                 (subject, kind, c["id"]))


# chdate unter dieser Grenze ist keine Unix-Zeit (vor 2001), sondern eine Learnweb-Revision der Sitzung, die vor der
# Spalte files.revision in chdate stand
LEGACY_REVISION_MAX = 1_000_000_000


def _unix(iso: str | None) -> int | None:
    """Ortszeit wie db.now_iso() -> Unix-Zeit (wie datetime.fromtimestamp in study.py zurueck)"""
    try:
        return int(datetime.fromisoformat(iso).timestamp()) if iso else None
    except ValueError:
        return None


def version_stamp(existing: dict | None, f: dict, now: int) -> tuple[int, bool]:
    """(chdate, neuere Fassung?) einer Datei der Quelle gegen den gespeicherten Stand. chdate ist immer eine Unix-Zeit:
    Lehrwoche, Lernplan und Semesterbeginn lesen sie so (study.week_index).
    - Mit Aenderungszeit (Stud.IP, Learnweb mit Schluessel): sie gilt, neuer = hoeher als gespeichert.
    - Ohne (Learnweb ueber die Sitzung, chdate None) entscheidet die Pluginfile-Revision (files.revision): eine neue
      Datei bekommt den Zeitpunkt des Abgleichs `now`, eine hoehere Revision ebenso (mindestens eine Sekunde nach dem
      gespeicherten, damit sie als neuer gilt), sonst bleibt der gespeicherte Zeitpunkt. Zeilen von vor files.revision
      (Revision stand in chdate) werden dabei repariert: Zeitpunkt first_seen. Ohne gespeicherte Revision (Zeile des
      Schluessel-Abgleichs von vorher) gilt die Datei als unveraendert; die Revision kommt mit diesem Lauf dazu."""
    if f.get("chdate") is not None:
        return f["chdate"], existing is not None and (existing["chdate"] or 0) < f["chdate"]
    if existing is None:
        return now, False
    old, rev = existing["chdate"] or 0, existing["revision"]
    if rev is None and 0 < old < LEGACY_REVISION_MAX:
        rev, old = old, _unix(existing["first_seen"]) or now
    if rev is not None and (f.get("revision") or 0) > rev:
        return max(now, old + 1), True
    return old or now, False


def store_course_files(conn, c: dict, files: list[dict], folder_paths: dict[str, str], download_fn, started: str,
                       new_files: list[str], pause: float = 0.2, now: int | None = None) -> None:
    """Dateiliste eines Kurses speichern und neue/geaenderte Dateien mit download_fn(url, target, size) holen
    (size = Groesse laut Quelle, fuer `empty_download`).
    Geaendert = neuere Fassung (version_stamp: Aenderungszeit, beim Learnweb ueber die Sitzung die Revision), ohne
    Ablageort oder lokal verschwunden. Kennt die Quelle die Groesse nicht (size None), bleibt die gespeicherte und
    nach dem Download gilt die der geladenen Datei."""
    now = int(time.time()) if now is None else now
    for f in files:
        existing = db.row(conn, "SELECT chdate, local_path, revision, first_seen FROM files WHERE id=?", (f["id"],))
        chdate, newer = version_stamp(existing, f, now)
        f = {**f, "chdate": chdate, "revision": f.get("revision")}
        changed = existing is None or newer or not existing["local_path"] or not Path(existing["local_path"]).exists()
        if existing is None:
            conn.execute(
                """INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, first_seen, status, kind, revision)
                   VALUES (?,?,?,?,?,?,?,?,?, 'neu', ?, ?)""",
                (f["id"], c["id"], f["name"], f["size"] or 0, f["mime"], f["author"], f["chdate"],
                 f["download_url"], started, file_kind(f["name"], f["mime"]), f["revision"]),
            )
        elif changed:
            # neue Fassung (Groesse, Typ, Aenderungszeit, Revision) erst mit dem Download uebernehmen: scheitert
            # er, gilt die Datei beim naechsten Abgleich weiter als geaendert und wird erneut geladen
            conn.execute("UPDATE files SET name=?, author=?, download_url=? WHERE id=?",
                         (f["name"], f["author"], f["download_url"], f["id"]))
        else:
            conn.execute(
                "UPDATE files SET name=?, size=COALESCE(?, size), mime=?, author=?, chdate=?, download_url=?, revision=? WHERE id=?",
                (f["name"], f["size"], f["mime"], f["author"], f["chdate"], f["download_url"], f["revision"], f["id"]),
            )
        if f["id"] in folder_paths:
            conn.execute("UPDATE files SET studip_folder=? WHERE id=?", (folder_paths[f["id"]], f["id"]))
        if changed:
            target = FILES_DIR / safe_name(subject_dir(c["title"])) / safe_name(f["name"])
            other = db.row(conn, "SELECT id FROM files WHERE local_path=? AND id<>?", (str(target), f["id"]))
            if other:
                # Name-Kollision (gleicher Dateiname in zwei Ordnern): Dateiid anhaengen
                suffix = safe_name(f["id"])[-8:] if str(f["id"]).startswith("lw-") else f["id"][:6]
                target = target.with_name(f"{target.stem}_{suffix}{target.suffix}")
            try:
                download_fn(f["download_url"], target, f["size"] or 0)
                from .testshare import file_sha256
                size = f["size"] if f["size"] is not None else target.stat().st_size
                conn.execute("UPDATE files SET local_path=?, downloaded_at=?, size=?, mime=?, chdate=?, revision=?, "
                             "content_sha256=? WHERE id=?",
                             (str(target), db.now_iso(), size, f["mime"], f["chdate"], f["revision"], file_sha256(target),
                              f["id"]))
                new_files.append(f["id"])
                log(f"Neu: {c['title'][:40]} / {f['name']}")
            except Exception as e:  # noqa: BLE001
                log(f"Download-Fehler {f['name']}: {e}")
            if pause:
                time.sleep(pause)


# ----------------------------------------------------------------------------
# Hauptablauf
# ----------------------------------------------------------------------------

def run_sync(show_browser: bool = False) -> dict:
    """Dateien, Kurse und Termine der gewaehlten Uni holen (LUH: Stud.IP, Hildesheim: Learnweb + LSF)."""
    from . import universities
    db.init_db()
    if universities.current_key() == "hildesheim":
        from . import hildesheim
        return hildesheim.run_sync(show_browser=show_browser)
    return run_studip_sync(show_browser=show_browser)


def run_studip_sync(show_browser: bool = False) -> dict:
    db.init_db()
    started = db.now_iso()
    new_files: list[str] = []
    message = ""
    ok = False
    try:
        with sync_playwright() as p:
            ctx: BrowserContext = p.chromium.launch_persistent_context(
                str(PROFILE_DIR), headless=not show_browser, accept_downloads=True,
                locale="de-DE",
            )
            page = ctx.new_page()
            login(page)

            courses = fetch_courses(page)
            if SEMESTER_FILTER:
                courses = [c for c in courses if SEMESTER_FILTER.lower() in (c["semester"] or "").lower()]
            log(f"{len(courses)} Kurse gefunden.")

            with db.cursor() as conn:
                try:
                    me = page.request.get(f"{STUDIP_BASE}/jsonapi.php/v1/users/me", headers={"Accept": "application/vnd.api+json"}).json()
                    store_schedule_entries(conn, fetch_schedule_entries(page, me["data"]["id"]))
                except Exception as e:  # noqa: BLE001
                    log(f"Persoenlicher Stundenplan nicht gelesen: {e}")
                for c in courses:
                    upsert_course(conn, c, started)

                for c in courses:
                    try:
                        store_events(conn, fetch_events(page, c["id"]))
                    except Exception as e:  # noqa: BLE001
                        log(f"Fehler bei Terminen {c['title']}: {e}")
                    try:
                        files = fetch_files(page, c["id"])
                    except Exception as e:  # noqa: BLE001
                        log(f"Fehler bei Dateiliste {c['title']}: {e}")
                        continue
                    try:
                        folder_paths = fetch_folder_paths(page, c["id"]) if files else {}
                    except Exception as e:  # noqa: BLE001
                        log(f"Ordnerstruktur nicht gelesen ({c['title']}): {e}"); folder_paths = {}
                    store_course_files(conn, c, files, folder_paths, lambda url, target, size: download(page, url, target, size),
                                       started, new_files)
            ctx.close()
        ok = True
        message = f"{len(new_files)} neue/geaenderte Dateien"
        # Stundenplan automatisch ergaenzen (Vorlesungen, eindeutige Termine, persoenliche Stud.IP-Eintraege)
        try:
            from . import timetable
            with db.cursor() as conn:
                r = timetable.auto_import(conn)
            if r["new"]:
                log(f"Stundenplan: {r['new']} Termine automatisch uebernommen")
                message += f", {r['new']} Stundenplan-Termine"
        except Exception as e:  # noqa: BLE001
            log(f"Stundenplan-Autoimport: {e}")
    except Exception as e:  # noqa: BLE001
        message = f"FEHLER: {e}"
        log(message)
    finally:
        with db.cursor() as conn:
            conn.execute(
                "INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,?,?)",
                (started, db.now_iso(), int(ok), len(new_files), message),
            )
    return {"ok": ok, "new_files": new_files, "message": message}


def subject_dir(course_title: str) -> str:
    return re.sub(r"\s+", " ", course_title).strip()


if __name__ == "__main__":
    res = run_sync(show_browser="--show" in sys.argv)
    print(json.dumps({k: v for k, v in res.items() if k != "new_files"} | {"new_files": len(res["new_files"])},
                     ensure_ascii=False))
