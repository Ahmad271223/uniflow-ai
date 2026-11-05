"""Stud.IP live am PC (Windows-App/Einzelplatz, 05.11.2026): die wenigen Anfragen, die nicht der Abgleich macht, sondern
der Mensch per Knopfdruck ausloest - Antworten auf Nachrichten (app/studip_reply.py) und Abgeben in Stud.IP
(app/studip_submit.py). Gleiche Regeln wie `URLSessionStudIPWriter`/`StudIPClient.perform` der iPad-App
(docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md, docs/ABGEBEN-STUDIP-2026-11-05.md):

- Anmeldung nur ueber das Sitzungs-Cookie, das der Abgleich bzw. das Anmeldefenster gemerkt hat
  (`unilogin.saved_cookies("STUDIP_COOKIES")`, Datei im Datenordner); nie ein Passwort in einer Anfrage.
- Abgelaufen (401, Weiterleitung auf die Anmeldung, Anmeldeseite statt JSON): einmal still erneuern
  (`filestream.refresh_studip_session`, gleiches Browser-Profil wie der Abgleich) und **genau einmal** neu versuchen.
  Das ist auch beim Schreiben sicher: bei 401 hat Stud.IP nichts angenommen. Alles andere wird nie wiederholt (eine
  Nachricht oder Abgabe kaeme sonst doppelt an).
- Nur der Stud.IP-Rechner (`config.STUDIP_BASE`), nur https, Weiterleitungen werden nicht verfolgt (das Cookie ginge
  sonst mit).
- Nie im gehosteten Dienst: dort gibt es keine Cookies auf eigenen Servern (docs/IPAD-STUDIP-SYNC.md par. 8).

In Tests wird `_send` ersetzt; es gibt keine echte Anfrage an die Hochschule.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

from . import config

JSONAPI = "application/vnd.api+json"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) StudiNow/1.0"
TIMEOUT = 120
LOGIN_MARKERS = ('type="password"', "type='password'", "shibboleth.sso", "dispatch.php/login", "name=\"j_username\"",
                 "idp/profile/saml2", "loginname", "username_input")


class NotAvailable(Exception):
    """Im Dienst oder an einer Hochschule ohne Stud.IP"""


class NotConnected(Exception):
    """Keine Stud.IP-Sitzung gemerkt und keine Zugangsdaten: der Mensch muss sich erst anmelden"""


class SessionExpired(Exception):
    """Stud.IP will eine neue Anmeldung und die stille Erneuerung ging nicht"""


@dataclass
class Reply:
    status: int
    body: bytes = b""
    content_type: str = ""
    location: str = ""
    headers: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def text(self, limit: int = 200_000) -> str:
        return self.body[:limit].decode("utf-8", "replace")

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8")) if self.body else None
        except (ValueError, UnicodeDecodeError):
            return None


def base() -> str:
    return config.STUDIP_BASE.rstrip("/")


def available() -> bool:
    """Nur am PC (nicht im Dienst) und nur an Hochschulen mit Stud.IP."""
    if config.is_hosted():
        return False
    from . import studip_messages
    return studip_messages.stud_ip_offered()


def connected() -> bool:
    from . import studip_messages
    return studip_messages.stud_ip_connected()


def looks_like_login(reply: Reply) -> bool:
    """Abgelaufene Sitzung: 401, Weiterleitung auf die Anmeldung oder eine Anmeldeseite statt JSON."""
    if reply.status == 401:
        return True
    if 300 <= reply.status < 400:
        loc = (reply.location or "").lower()
        return any(k in loc for k in ("login", "shibboleth", "sso", "saml", "cas"))
    if "html" in (reply.content_type or "").lower() and reply.status < 400:
        page = reply.text(200_000).lower()
        return any(k in page for k in LOGIN_MARKERS)
    return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401 - Weiterleitungen nie verfolgen (Cookie ginge mit)
        return None


def _send(method: str, url: str, headers: dict, body: bytes | None) -> Reply:
    """Eine Anfrage ohne Weiterleitungen. In Tests ersetzt."""
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=TIMEOUT) as r:
            return Reply(r.status, r.read(50 << 20), (r.headers.get("Content-Type") or "").split(";")[0].strip().lower(),
                         r.headers.get("Location") or "", dict(r.headers.items()))
    except urllib.error.HTTPError as e:
        data = e.read(1 << 20) if e.fp else b""
        return Reply(e.code, data, (e.headers.get("Content-Type") or "").split(";")[0].strip().lower() if e.headers else "",
                     (e.headers.get("Location") or "") if e.headers else "", dict(e.headers.items()) if e.headers else {})


def _cookie() -> str:
    from . import filestream
    return filestream.studip_cookie_header(base())


def _renew() -> str:
    """Still neu anmelden (Profil des Abgleichs). Ohne gemerkte WebSSO-Sitzung und ohne Zugangsdaten: SessionExpired."""
    from . import filestream
    try:
        return filestream.refresh_studip_session()
    except Exception as e:  # noqa: BLE001
        raise SessionExpired(str(getattr(e, "message", e)) or "Stud.IP-Anmeldung abgelaufen") from None


def url_for(path: str) -> str:
    """Pfad relativ zu Stud.IP ("jsonapi.php/v1/...") oder volle Adresse auf demselben Rechner."""
    if path.startswith("http://") or path.startswith("https://"):
        u = urllib.parse.urlsplit(path)
        if u.scheme != "https" and not base().startswith("http://"):
            raise ValueError("nur https")
        if (u.hostname or "").lower() != (urllib.parse.urlsplit(base()).hostname or "").lower():
            raise ValueError("fremder Rechner")
        return path
    return base() + "/" + path.lstrip("/")


def call(method: str, path: str, *, headers: dict | None = None, body: bytes | None = None) -> Reply:
    """Eine Anfrage mit der gemerkten Sitzung; abgelaufen -> einmal still erneuern und genau einmal neu senden."""
    if not available():
        raise NotAvailable("Stud.IP gibt es hier nicht.")
    url = url_for(path)
    h = {"User-Agent": USER_AGENT, "Accept": JSONAPI}
    h.update(headers or {})
    cookie = _cookie()
    if not cookie:
        if not connected():
            raise NotConnected("Stud.IP ist nicht verbunden.")
        cookie = _renew()
    r = _send(method, url, {**h, "Cookie": cookie}, body)
    if not looks_like_login(r):
        return r
    cookie = _renew()
    r = _send(method, url, {**h, "Cookie": cookie}, body)
    if looks_like_login(r):
        raise SessionExpired("Bitte bei Stud.IP anmelden.")
    return r


def get_json(path: str) -> dict:
    """Lesen (JSON:API); anderer Status als 2xx -> HTTPError-artige RuntimeError mit Status."""
    r = call("GET", path)
    if not r.ok:
        raise StudIPHTTPError(r.status)
    j = r.json()
    if not isinstance(j, dict):
        raise StudIPHTTPError(r.status, "keine JSON-Antwort")
    return j


def list_all(path: str, max_pages: int = 10) -> list[dict]:
    """Alle Seiten einer Liste (`links.next`)."""
    out: list[dict] = []
    nxt: str | None = path
    pages = 0
    while nxt and pages < max_pages:
        j = get_json(nxt)
        pages += 1
        data = j.get("data")
        out += [d for d in data if isinstance(d, dict)] if isinstance(data, list) else []
        link = (j.get("links") or {}).get("next") if isinstance(j.get("links"), dict) else None
        if isinstance(link, dict):
            link = link.get("href")
        nxt = _next_path(link) if isinstance(link, str) and link else None
    return out


def _next_path(link: str) -> str:
    """`links.next` kann absolut, relativ zu jsonapi.php/v1 oder ab "/" sein."""
    if link.startswith("http"):
        return link
    if link.startswith("/"):
        return link.lstrip("/")
    if link.startswith("jsonapi.php"):
        return link
    return "jsonapi.php/v1/" + link


class StudIPHTTPError(Exception):
    def __init__(self, status: int, message: str = ""):
        super().__init__(message or f"HTTP {status}")
        self.status = status


def current_user() -> dict:
    """`users/me`: {"id", "attributes"}"""
    j = get_json("jsonapi.php/v1/users/me")
    d = j.get("data") if isinstance(j.get("data"), dict) else {}
    if not d.get("id"):
        raise StudIPHTTPError(200, "users/me ohne Kennung")
    return d
