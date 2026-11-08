"""Windows-App (Einzelplatz) mit dem StudiNow-Konto im Dienst verbinden (28.10.2026).

Ein Konto fuer Windows und Apple: Die Windows-App laeuft weiter am eigenen PC (Hochschul-Abgleich, Dateien, Notizen
bleiben lokal), meldet sich fuer die Community aber am gehosteten Dienst an. Ablauf:

- Anmelden: E-Mail und StudiNow-Passwort gehen einmal ueber das lokale Backend an `{dienst}/api/account/login`. Das
  Passwort wird nie gespeichert; im Datenordner liegt nur das Sitzungs-Token (`service-account.json`), das der Dienst
  jederzeit widerrufen kann (Abmelden, "Ueberall abmelden", Konto loeschen). Das Hochschul-Passwort hat damit nichts
  zu tun und verlaesst den PC nie.
- Weiterleitung: Im Einzelplatzmodus leitet das lokale Backend jede Anfrage unter `/api/community/...` mit dem Token an
  den Dienst weiter (`proxy`). Die Oberflaeche ruft dieselben Pfade wie im Dienst auf; Rechte, Tarif und Grenzen prueft
  allein der Dienst.
- Eigene PDFs melden: Der Dienst kennt die Hochschuldateien des PCs nicht. Nach dem Anmelden und nach jedem Abgleich
  meldet die App die Fingerabdruecke (SHA-256) ihrer Hochschul-PDFs (`claim_local_files`, ergaenzend, nie ersetzend:
  das iPad desselben Kontos meldet seine eigenen). Nur der Fingerabdruck verlaesst den PC, nie die Datei.

Adresse des Dienstes: `LERNAPP_SERVICE_URL`, sonst fest `https://app.studinow.app` (DEFAULT_SERVICE_URL, 05.11.2026),
oder beim Anmelden eingegeben; nur https, ausser auf dem eigenen Rechner (127.0.0.1/localhost, fuer Tests).

Token (05.11.2026): nicht mehr in `service-account.json`, sondern in der Windows-Anmeldeinformationsverwaltung
(app/token_store.py; ausserhalb von Windows eine Datei mit Rechten 0600). `load_state` setzt es wie bisher als
`token` in den Zustand ein, `save_state` legt es dort ab; ein Token aus einer alten Datei zieht beim ersten Lesen um.
Jede Anfrage an den Dienst traegt `X-StudiNow-Client: windows` (Abo-Pflicht je Client, app/access.py).
"""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import config, db, token_store

STATE_FILE = "service-account.json"
DEVICE_NAME = "StudiNow für Windows"
DEFAULT_SERVICE_URL = "https://app.studinow.app"
CLIENT_HEADER = "X-StudiNow-Client"
CLIENT_NAME = "windows"
TIMEOUT = 30
UPLOAD_TIMEOUT = 180
MAX_BODY = 80 << 20                    # groesser als das groesste Paket des Dienstes (community.MAX_PACKAGE_BYTES)
MAX_CLAIMS = 5_000                     # je Meldung (= community.MAX_CLAIMS des Dienstes); mehr gehen in Seiten
MAX_CLAIM_PAGES = 20                   # hoechstens 100 000 Fingerabdruecke je Abgleich
CLAIM_LOG_EVERY_S = 3600               # dieselbe Fehlerart beim stillen Melden hoechstens einmal je Stunde protokollieren
MAX_QUERY = 4096
_PATH_RE = re.compile(r"^[A-Za-z0-9_\-/.]{0,200}$")
# Zeichen einer schon kodierten Abfrage (RFC 3986 query); kein Leer-, Steuer- oder Nicht-ASCII-Zeichen (Audit P19-05)
_QUERY_RE = re.compile(r"[A-Za-z0-9\-._~%!$&'()*+,;=:@/?]*")
log = logging.getLogger("uniflow.service_link")
# Zustandsdatei und Token-Ablage gehoeren zusammen: Lesen, Schreiben und das Vergessen bei 401 laufen nacheinander
# (Audit P18-08). RLock, weil save_state aus call() heraus und load_state in save_state-Ablaeufen vorkommt.
_state_lock = threading.RLock()
_claim_log: dict[str, float] = {}


class LinkError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Zustand (nur im Datenordner des PCs)

def state_path() -> Path:
    return config.DATA_DIR / STATE_FILE


def _read_file() -> dict:
    try:
        d = json.loads(state_path().read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_file(d: dict) -> None:
    """Eindeutige Temp-Datei (mkstemp: O_EXCL, 0600), dann atomar ersetzen (Audit P18-08: frueher fester Name)."""
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=p.name + ".", suffix=".tmp", dir=p.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps({k: v for k, v in d.items() if k != "token"}, ensure_ascii=False, indent=1))
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_state() -> dict:
    """Zustand aus der Datei, dazu das Token aus der Ablage (app/token_store.py). Ein Token aus einer Datei bis 0.5
    (stand frueher in service-account.json) zieht dabei einmal in die Ablage um und verschwindet aus der Datei, aber
    nur, wenn die Ablage es dauerhaft haelt (Audit P18-09: beim Notbehelf im Speicher war es nach dem Neustart weg)."""
    with _state_lock:
        d = _read_file()
        legacy = d.pop("token", None)
        if legacy:
            persisted = True
            if not token_store.get():
                try:
                    persisted = token_store.put(str(legacy))
                except token_store.TokenInvalid:
                    persisted = True          # unbrauchbar: darf aus der Datei verschwinden
            elif not token_store.persistent():
                persisted = False
            if persisted:
                _write_file(d)
        tok = token_store.get()
        if tok:
            d["token"] = tok
        return d


def save_state(d: dict) -> None:
    """Datei ohne Token schreiben; das Token (oder sein Fehlen) gilt fuer die Ablage. Ein ungueltiges Token wird
    nicht gespeichert (Audit P17-04, P18-11)."""
    tok = d.get("token") or None
    if tok is not None and not token_store.valid_token(tok):
        raise LinkError("service_error", "Unerwartete Antwort des Dienstes (ungültige Sitzung).", 502)
    with _state_lock:
        _write_file(d)
        if tok != token_store.get():
            token_store.put(tok)


def _device_id(st: dict) -> str:
    if not st.get("device_id"):
        st["device_id"] = "win-" + secrets.token_hex(12)
    return st["device_id"]


def normalize_url(url: str | None) -> str:
    """https://dienst.example oder http://127.0.0.1:8000 (nur eigener Rechner); ohne Schraegstrich am Ende."""
    u = (url or "").strip().rstrip("/")
    if not u:
        raise LinkError("service_url_missing", "Bitte die Adresse des StudiNow-Dienstes angeben.")
    p = urllib.parse.urlsplit(u)
    local = (p.hostname or "") in ("127.0.0.1", "localhost", "::1")
    if p.scheme not in ("https", "http") or not p.hostname or (p.scheme == "http" and not local):
        raise LinkError("service_url_invalid", "Die Adresse muss mit https:// beginnen.")
    if p.query or p.fragment or p.username or p.password:
        raise LinkError("service_url_invalid", "Die Adresse darf nur aus Server und Pfad bestehen.")
    return u


def service_url(st: dict | None = None) -> str:
    """Gespeicherte Adresse, sonst LERNAPP_SERVICE_URL, sonst DEFAULT_SERVICE_URL; jede wird erneut wie beim Anmelden
    geprueft (Audit P18-03). Ungueltig -> "" (call: nicht verbunden), nie stilles Ausweichen auf eine andere."""
    st = load_state() if st is None else st
    for cand in (st.get("url"), os.environ.get("LERNAPP_SERVICE_URL"), DEFAULT_SERVICE_URL):
        if cand and str(cand).strip():
            try:
                return normalize_url(str(cand))
            except LinkError:
                return ""
    return ""


def linked(st: dict | None = None) -> bool:
    st = load_state() if st is None else st
    return bool(st.get("token") and st.get("url"))


# ---------------------------------------------------------------- HTTP (austauschbar fuer Tests)

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keiner Weiterleitung folgen (Audit P18-02): urllib reicht sonst `Authorization` an jeden neuen Host weiter,
    auch von https auf http. Die API des Dienstes leitet nie weiter; ein 3xx kommt als Status zurueck."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _urllib_transport(method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with _opener.open(req, timeout=timeout) as r:  # noqa: S310 - Adresse geprueft (normalize_url)
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read(MAX_BODY + 1)
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, e.read(MAX_BODY + 1)


transport = _urllib_transport


def call(method: str, path: str, body: bytes | None = None, *, query: str = "", content_type: str = "application/json",
         st: dict | None = None, url: str | None = None, token: str | None = None, timeout: float = TIMEOUT) -> tuple[int, dict, bytes]:
    st = load_state() if st is None else st
    base = normalize_url(url) if url else service_url(st)
    if not base:
        raise LinkError("not_linked", "Die App ist mit keinem StudiNow-Konto verbunden.", 409)
    headers = {"Accept": "application/json", "User-Agent": f"{DEVICE_NAME} (StudiNow)", CLIENT_HEADER: CLIENT_NAME}
    if body is not None:
        headers["Content-Type"] = content_type or "application/json"
    tok = token if token is not None else st.get("token")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    full = base + path + (("?" + query) if query else "")
    try:
        status, hdrs, data = transport(method, full, headers, body, timeout)
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise LinkError("service_unreachable", f"Der StudiNow-Dienst ist nicht erreichbar ({getattr(e, 'reason', e)}). "
                                               "Internetverbindung prüfen und später erneut versuchen.", 502)
    if len(data) > MAX_BODY:
        raise LinkError("service_response_too_large", "Antwort des Dienstes ist zu groß.", 502)
    if status == 401 and tok and st.get("token") == tok and _detail(data, "")[0] == "unauthenticated":
        # Sitzung abgelaufen oder widerrufen: Token vergessen, Adresse und E-Mail bleiben fuer die neue Anmeldung.
        # Nur bei "unauthenticated", dem Zeichen des Dienstes fuer eine ungueltige Sitzung (server.py, *_api.py);
        # ein 401 aus anderem Grund (z. B. falsches bisheriges Passwort: credentials_invalid) meldet nicht ab (P18-10)
        with _state_lock:
            st.pop("token", None)
            st["expired_at"] = int(time.time())
            save_state(st)
    return status, hdrs, data


def _json(data: bytes) -> dict:
    try:
        d = json.loads(data or b"{}")
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def _detail(data: bytes, fallback: str) -> tuple[str, str]:
    """Fehler des Dienstes (Vertrag G1: {"detail": "...", "code": "..."})."""
    j = _json(data)
    d = j.get("detail")
    if isinstance(d, dict):
        return str(d.get("code") or "service_error"), str(d.get("detail") or fallback)
    return str(j.get("code") or "service_error"), str(d or fallback)


# ---------------------------------------------------------------- Anmelden, Status, Abmelden

def login(url: str | None, email: str, password: str) -> dict:
    base = normalize_url(url or service_url())
    if not (email or "").strip() or not password:
        raise LinkError("credentials_missing", "E-Mail und Passwort angeben.")
    st = load_state()
    body = json.dumps({"email": email.strip(), "password": password, "device_id": _device_id(st),
                       "device_name": DEVICE_NAME}).encode()
    status, _, data = call("POST", "/api/account/login", body, st=st, url=base, token="")
    if status == 404:
        raise LinkError("service_url_invalid", "Unter dieser Adresse läuft kein StudiNow-Dienst.", 400)
    if status != 200:
        code, msg = _detail(data, "Anmeldung fehlgeschlagen.")
        raise LinkError(code, msg, status if status in (400, 401, 403, 423, 429) else 502)
    d = _json(data)
    if not token_store.valid_token(d.get("token")) or not isinstance(d.get("user"), dict):
        # Typ, Laenge und Zeichen vor dem Speichern (Audit P18-11); sonst haette die Ablage ein Token, das get() verwirft
        raise LinkError("service_error", "Unerwartete Antwort des Dienstes.", 502)
    st.update({"url": base, "token": d["token"], "user": d["user"], "linked_at": int(time.time())})
    st.pop("expired_at", None)
    save_state(st)
    return status_info(st, refresh=False)


def _public_user(u: dict | None) -> dict | None:
    if not u:
        return None
    return {k: u.get(k) for k in ("id", "email", "email_verified", "university", "plan", "plan_until", "role")}


def university_mismatch(st: dict) -> str | None:
    u = st.get("user") or {}
    mine = config.university()
    if u.get("university") and mine and u["university"] != mine:
        return (f"Dein StudiNow-Konto gehört zur Hochschule „{u['university']}“, diese App ist für „{mine}“ eingerichtet. "
                "Lösungen gibt es nur innerhalb derselben Hochschule.")
    return None


def status_info(st: dict | None = None, refresh: bool = True) -> dict:
    st = load_state() if st is None else st
    out = {"linked": linked(st), "url": service_url(st) or None, "env_url": bool(os.environ.get("LERNAPP_SERVICE_URL")),
           "url_fixed": True, "token_store": token_store.kind(), "token_persistent": token_store.persistent(),
           "user": _public_user(st.get("user")), "linked_at": st.get("linked_at"), "claims": st.get("claims"),
           "expired": bool(st.get("expired_at") and not st.get("token")), "offline": False,
           "last_email": st.get("last_email") or (st.get("user") or {}).get("email")}
    if refresh and out["linked"]:
        try:
            status, _, data = call("GET", "/api/account/me", st=st)
            if status == 200 and isinstance(_json(data).get("user"), dict):
                st["user"] = _json(data)["user"]
                save_state(st)
                out["user"] = _public_user(st["user"])
            elif status == 401:
                out.update(linked=False, expired=True)
        except LinkError:
            out["offline"] = True
    out["university_mismatch"] = university_mismatch(st) if out["user"] else None
    return out


LOGOUT_LOCAL_HINT = ("Nur auf diesem PC abgemeldet: Der StudiNow-Dienst war nicht erreichbar, die Sitzung gilt dort "
                     "noch. Beende sie auf einem anderen Gerät unter StudiNow-Konto → Geräte oder melde dich hier neu "
                     "an und wieder ab.")


def logout() -> dict:
    """Beim Dienst abmelden und das Token vergessen. Ohne Antwort des Dienstes (offline, 5xx) wird trotzdem lokal
    abgemeldet, das Ergebnis sagt es aber (`logout_local_only`, `logout_hint`; Audit P19-01): die Sitzung bleibt im
    Dienst bis zum Ablauf gueltig und laesst sich auf einem anderen Geraet unter "Geraete" beenden."""
    st = load_state()
    local_only = False
    if st.get("token"):
        local_only = True
        try:
            status, _, _ = call("POST", "/api/account/logout", b"{}", st=st)
            local_only = not (200 <= status < 300 or status == 401)
        except LinkError:
            pass                        # offline: das Token wird trotzdem vergessen
    keep = {k: st[k] for k in ("url", "device_id") if st.get(k)}
    if (st.get("user") or {}).get("email"):
        keep["last_email"] = st["user"]["email"]
    save_state(keep)
    out = status_info(keep, refresh=False)
    out["logout_local_only"] = local_only
    if local_only:
        out["logout_hint"] = LOGOUT_LOCAL_HINT
    return out


def devices() -> dict:
    """Angemeldete Geraete des Kontos (Windows, iPad, Browser) mit diesem PC als `current`."""
    status, _, data = call("GET", "/api/account/me")
    if status >= 400:
        code, msg = _detail(data, "Geräte konnten nicht geladen werden.")
        raise LinkError(code, msg, status)
    return {"sessions": _json(data).get("sessions") or []}


def revoke_device(session_id: int) -> dict:
    status, _, data = call("DELETE", f"/api/account/sessions/{int(session_id)}")
    if status >= 400:
        code, msg = _detail(data, "Gerät konnte nicht abgemeldet werden.")
        raise LinkError(code, msg, status)
    d = _json(data)
    if d.get("current"):
        logout()
    return d


def resend_verification() -> dict:
    status, _, data = call("POST", "/api/account/verify-email/resend", b"{}")
    if status >= 400:
        code, msg = _detail(data, "Bestätigungsmail konnte nicht gesendet werden.")
        raise LinkError(code, msg, status)
    return _json(data)


# ---------------------------------------------------------------- eigene Hochschul-PDFs melden

def local_fingerprints(limit: int | None = None) -> list[str]:
    """SHA-256 der Hochschul-PDFs aus dem eigenen Abgleich (Stud.IP, Learnweb), fehlende werden aus der Datei auf
    der Platte berechnet und gemerkt. Eigene Dokumente (`__user__`) und geloeschte Dateien zaehlen nicht.
    Gehasht wird ausserhalb jeder Transaktion, die neuen Werte gehen danach in einem kurzen Schreibvorgang in die
    Datenbank (Audit P19-02: frueher hielt die erste UPDATE-Zeile die Schreibsperre, solange weitere PDFs gelesen
    wurden). Ohne `limit` alle (P19-03: claim_local_files meldet in Seiten)."""
    from .testshare import file_sha256
    with db.cursor() as conn:
        rows = db.rows(conn, """SELECT id, local_path, content_sha256, name, mime FROM files
                                WHERE course_id<>'__user__' AND download_url IS NOT NULL AND download_url<>''
                                  AND deleted_at IS NULL ORDER BY id""")
    out: list[str] = []
    new: list[tuple[str, str]] = []
    for r in rows:
        if limit is not None and len(out) >= limit:
            break
        is_pdf = (r.get("mime") or "").endswith("pdf") or (r.get("name") or "").lower().endswith(".pdf")
        sha = r.get("content_sha256")
        if not sha and is_pdf and r.get("local_path") and Path(r["local_path"]).is_file():
            try:
                sha = file_sha256(Path(r["local_path"]))
                new.append((sha, r["id"]))
            except OSError:
                sha = None
        if sha and is_pdf and re.fullmatch(r"[0-9a-f]{64}", sha):
            out.append(sha)
    if new:
        with db.cursor() as conn:
            conn.executemany("UPDATE files SET content_sha256=? WHERE id=? AND content_sha256 IS NULL", new)
    return sorted(set(out))


def claim_local_files() -> dict:
    st = load_state()
    if not linked(st):
        raise LinkError("not_linked", "Die App ist mit keinem StudiNow-Konto verbunden.", 409)
    if (msg := university_mismatch(st)):
        raise LinkError("university_mismatch", msg, 409)
    fps = local_fingerprints()
    # Seiten zu MAX_CLAIMS (Grenze des Dienstes je Meldung); Meldungen ergaenzen sich (replace=False), so kommen auch
    # PDFs nach der 5000. an (Audit P19-03). Hoechstens MAX_CLAIM_PAGES Seiten je Abgleich.
    pages = [fps[i:i + MAX_CLAIMS] for i in range(0, len(fps), MAX_CLAIMS)][:MAX_CLAIM_PAGES] or [[]]
    d: dict = {}
    for page in pages:
        status, _, data = call("POST", "/api/community/claims", json.dumps({"fingerprints": page}).encode(), st=st)
        if status >= 400:
            code, msg = _detail(data, "PDFs konnten nicht gemeldet werden.")
            raise LinkError(code, msg, status)
        d = _json(data)
    st = load_state()
    st["claims"] = {"at": int(time.time()), "sent": sum(len(p) for p in pages), "total": d.get("total")}
    save_state(st)
    return st["claims"]


def claim_quietly() -> None:
    """Nach einem Abgleich: melden, wenn verbunden; Fehler nur protokollieren (der Abgleich selbst ist fertig)."""
    try:
        if linked():
            claim_local_files()
    except LinkError as e:
        # Audit P19-04: frueher still verschluckt. Protokolliert werden Code und Status, nie Fingerabdruecke; dieselbe
        # Fehlerart hoechstens einmal je CLAIM_LOG_EVERY_S (ein Abgleich laeuft oft)
        now = time.monotonic()
        if now - _claim_log.get(e.code, float("-inf")) >= CLAIM_LOG_EVERY_S:
            _claim_log[e.code] = now
            log.warning("PDFs nicht an den StudiNow-Dienst gemeldet: %s (Status %s)", e.code, e.status)


# ---------------------------------------------------------------- Weiterleitung /api/community/... an den Dienst

def proxy(method: str, subpath: str, query: str, body: bytes | None, content_type: str | None) -> tuple[int, str, bytes]:
    """Anfrage der Oberflaeche an den Dienst weiterreichen. Liefert (Status, Inhaltstyp, Daten)."""
    if not _PATH_RE.match(subpath) or ".." in subpath:
        raise LinkError("path_invalid", "Ungültiger Pfad.", 400)
    # Abfrage unveraendert weiter (Schluessel und Werte prueft der Dienst je Endpunkt), aber begrenzt und nur aus
    # URL-Zeichen: Steuerzeichen liessen http.client sonst mit InvalidURL (500) scheitern (Audit P19-05)
    if len(query or "") > MAX_QUERY or not _QUERY_RE.fullmatch(query or ""):
        raise LinkError("query_invalid", "Ungültige Anfrage.", 400)
    if body is not None and len(body) > MAX_BODY:
        raise LinkError("too_large", "Die Lösung ist zu groß.", 413)
    st = load_state()
    if not linked(st):
        raise LinkError("not_linked", "Für die Community melde dich unter Einstellungen → StudiNow-Konto mit deinem "
                                      "StudiNow-Konto an (dasselbe Konto wie auf dem iPad).", 409)
    if (msg := university_mismatch(st)):
        raise LinkError("university_mismatch", msg, 409)
    upload = method in ("POST", "PUT", "PATCH") and body is not None and len(body) > 1 << 20
    status, hdrs, data = call(method, "/api/community/" + subpath.lstrip("/"), body if method not in ("GET", "HEAD") else None,
                              query=query, content_type=content_type or "application/json", st=st,
                              timeout=UPLOAD_TIMEOUT if upload or subpath.endswith("/package") else TIMEOUT)
    return status, hdrs.get("content-type") or "application/json", data
