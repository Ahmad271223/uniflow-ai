"""Hochschuldateien im gehosteten Dienst ohne Speicherung (Betriebsart LERNAPP_FILES=stream, Standard im Dienst).

Der Abgleich merkt sich nur die Dateiliste (Name, Groesse, Datum, Adresse); den Inhalt holt der Dienst erst, wenn ein
Geraet die Datei oeffnet - mit der Hochschulsitzung des Kontos (Stud.IP-Cookies aus dem Abgleich bzw. Learnweb-
Schluessel, beides verschluesselt im Tresor) - und reicht ihn durch. Auf der Platte landet nichts; behalten werden
nur der Fingerabdruck (SHA-256, fuer die Community) und der Seitentext (fuer Suche und Uebung <-> Skript), beides
abgeleitete Daten, keine Folien. Ein kleiner Zwischenspeicher im Arbeitsspeicher spart doppelte Abrufe beim Oeffnen.
Laeuft die Hochschulsitzung ab, meldet sich der Dienst einmal neu an (Stud.IP) und versucht es erneut.
"""
from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.parse
import urllib.request
from collections import OrderedDict

from . import config, db

MAX_BYTES = 300 << 20                                  # groessere Dateien reicht der Dienst nicht durch
CACHE_ENTRIES, CACHE_BYTES, CACHE_SECONDS = 8, 256 << 20, 900
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) UniFlow/3.0"
_cache: "OrderedDict[tuple, tuple[float, bytes, str, str]]" = OrderedDict()
_lock = threading.Lock()


class StreamError(Exception):
    def __init__(self, code: str, message: str, status: int = 502):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def is_learnweb(file_row) -> bool:
    return str(file_row["id"]).startswith("lw-") or "pluginfile.php" in (file_row["download_url"] or "")


# ---------------------------------------------------------------- HTTP

def _http(url: str, form: dict | None = None, cookie: str = "") -> tuple[bytes, str]:
    """GET (oder POST mit Formular) mit der Hochschulsitzung; liefert (Bytes, Content-Type). In Tests ersetzt."""
    headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
    if cookie:
        headers["Cookie"] = cookie
    data = None
    if form:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if form else "GET")
    with urllib.request.urlopen(req, timeout=180) as r:
        ctype = (r.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        chunks, total = [], 0
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BYTES:
                raise StreamError("too_large", "Die Datei ist zu groß, um sie durchzureichen.", 413)
            chunks.append(chunk)
    return b"".join(chunks), ctype


def looks_like_html(data: bytes, ctype: str) -> bool:
    head = data[:600].lstrip().lower()
    return ctype.startswith("text/html") or head.startswith((b"<!doctype", b"<html"))


# ---------------------------------------------------------------- Hochschulsitzung

def cookie_header(name: str, base: str) -> str:
    """Cookies des Abgleichs (STUDIP_COOKIES / LEARNWEB_COOKIES im Tresor, JSON-Liste wie Playwright
    context.cookies()) fuer den Host von `base`, abgelaufene ausgelassen."""
    raw = config.secret(name)
    if not raw:
        return ""
    try:
        cookies = json.loads(raw)
    except ValueError:
        return ""
    host = urllib.parse.urlsplit(base).hostname or ""
    now = time.time()
    keep = [c for c in cookies if isinstance(c, dict) and c.get("name") and host.endswith(str(c.get("domain") or host).lstrip("."))
            and (not c.get("expires") or c["expires"] < 0 or c["expires"] > now)]
    return "; ".join(f"{c['name']}={c['value']}" for c in keep)


def studip_cookie_header(base: str) -> str:
    return cookie_header("STUDIP_COOKIES", base)


def save_cookies(name: str, cookies: list[dict]) -> None:
    """Nach der Anmeldung im Abgleich: Cookies verschluesselt am Konto merken (nur im Dienst, nie in der .env)."""
    if not config.is_hosted():
        return
    keep = [{k: c.get(k) for k in ("name", "value", "domain", "path", "expires")} for c in cookies if c.get("name")]
    config.set_env({name: json.dumps(keep, ensure_ascii=False)})


def save_studip_cookies(cookies: list[dict]) -> None:
    save_cookies("STUDIP_COOKIES", cookies)


def refresh_learnweb_session() -> str:
    """Ohne Learnweb-Schluessel: neu ueber das CAS anmelden (Playwright, Profil des Kontos), Cookies merken."""
    from playwright.sync_api import sync_playwright

    from . import cas, hildesheim, learnweb
    from .universities import HILDESHEIM_CAS
    user, pw = config.own_credentials("HILDESHEIM")
    if not (user and pw):
        raise StreamError("university_session_expired", "Learnweb-Sitzung abgelaufen und keine Zugangsdaten hinterlegt – bitte unter Zugang eintragen.", 409)
    base = hildesheim.learnweb_base()
    try:
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(hildesheim._profile_dir()), headless=True, locale="de-DE")
            try:
                page = ctx.new_page()
                client = learnweb.SessionClient(page, base)
                cas.login(page, f"{base}/login/index.php?authCAS=CAS", HILDESHEIM_CAS, user, pw, client.is_logged_in, lambda m: None)
                cookies = ctx.cookies()
            finally:
                ctx.close()
    except Exception as e:  # noqa: BLE001
        raise StreamError("university_login_failed", f"Anmeldung beim Learnweb fehlgeschlagen: {e}", 502) from None
    save_cookies("LEARNWEB_COOKIES", cookies)
    return cookie_header("LEARNWEB_COOKIES", base)


def refresh_studip_session() -> str:
    """Neu bei Stud.IP anmelden (Playwright, Profil des Kontos), Cookies merken, Cookie-Kopfzeile liefern."""
    from playwright.sync_api import sync_playwright

    from . import studip_sync
    try:
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(studip_sync._profile_dir()), headless=True, locale="de-DE")
            try:
                page = ctx.new_page()
                studip_sync.login(page)
                cookies = ctx.cookies()
            finally:
                ctx.close()
    except Exception as e:  # noqa: BLE001
        raise StreamError("university_login_failed", f"Anmeldung bei der Hochschule fehlgeschlagen: {e}", 502) from None
    save_studip_cookies(cookies)
    return studip_cookie_header(studip_sync.STUDIP_BASE)


# ---------------------------------------------------------------- Abruf

def fetch(file_row) -> tuple[bytes, str]:
    """Inhalt einer Hochschuldatei mit der Sitzung des Kontos; (Bytes, Content-Type)."""
    url = file_row["download_url"] or ""
    if not url:
        raise StreamError("no_source", "Für diese Datei gibt es keine Quelle bei der Hochschule.", 404)
    if is_learnweb(file_row):
        from . import learnweb
        token = config.secret("LEARNWEB_TOKEN")
        if token:                                                  # Schluessel im POST-Koerper (wie der Abgleich)
            req = learnweb.token_request(url, token)
            data, ctype = _http(req["url"], form=req["form"])
            if looks_like_html(data, ctype):
                raise StreamError("university_session_expired", "Learnweb hat die Datei nicht herausgegeben – bitte den Learnweb-Schlüssel erneuern.", 409)
            return data, ctype
        cookie = cookie_header("LEARNWEB_COOKIES", url)              # sonst die CAS-Sitzung des Abgleichs
        data, ctype = _http(url, cookie=cookie) if cookie else (b"", "text/html")
        if looks_like_html(data, ctype):
            cookie = refresh_learnweb_session()
            data, ctype = _http(url, cookie=cookie)
            if looks_like_html(data, ctype):
                raise StreamError("university_session_expired", "Learnweb hat die Datei nicht herausgegeben – Anmeldung der Hochschule prüfen.", 409)
        return data, ctype
    from . import studip_sync
    cookie = studip_cookie_header(studip_sync.STUDIP_BASE)
    data, ctype = _http(url, cookie=cookie) if cookie else (b"", "text/html")
    if looks_like_html(data, ctype):
        cookie = refresh_studip_session()                       # Sitzung abgelaufen: einmal neu anmelden
        data, ctype = _http(url, cookie=cookie)
        if looks_like_html(data, ctype):
            raise StreamError("university_session_expired", "Stud.IP hat die Datei nicht herausgegeben – Anmeldung der Hochschule prüfen.", 409)
    return data, ctype


def content(conn, file_id: str) -> tuple[bytes, str, str]:
    """(Bytes, Mime, SHA-256) einer Hochschuldatei; merkt Fingerabdruck und Seitentext, speichert die Datei nicht."""
    f = db.row(conn, "SELECT id, name, mime, size, chdate, download_url, course_id, content_sha256 FROM files WHERE id=?", (file_id,))
    if not f:
        raise StreamError("not_found", "Datei nicht gefunden.", 404)
    key = (config.current_user_id(), file_id, f["chdate"])
    with _lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < CACHE_SECONDS:
            _cache.move_to_end(key)
            return hit[1], hit[2], hit[3]
    data, ctype = fetch(f)
    sha = hashlib.sha256(data).hexdigest()
    mime = f["mime"] or ctype or "application/octet-stream"
    conn.execute("UPDATE files SET content_sha256=?, size=CASE WHEN COALESCE(size,0)=0 THEN ? ELSE size END, mime=COALESCE(mime, ?) WHERE id=?",
                 (sha, len(data), ctype or None, file_id))
    if (f["name"] or "").lower().endswith(".pdf") or mime == "application/pdf":
        from . import scriptsearch
        scriptsearch.index_bytes(conn, file_id, data, f["chdate"])
    conn.commit()
    with _lock:
        _cache[key] = (time.time(), data, mime, sha)
        _cache.move_to_end(key)
        while len(_cache) > CACHE_ENTRIES or sum(len(v[1]) for v in _cache.values()) > CACHE_BYTES:
            _cache.popitem(last=False)
    return data, mime, sha


def forget(file_id: str | None = None) -> None:
    """Zwischenspeicher leeren (Tests, Dateiwechsel)."""
    with _lock:
        for k in [k for k in _cache if file_id is None or k[1] == file_id]:
            _cache.pop(k, None)
