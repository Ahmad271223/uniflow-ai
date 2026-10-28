"""Windows-App (Einzelplatz) mit dem Studora-Konto im Dienst verbinden (28.10.2026).

Ein Konto fuer Windows und Apple: Die Windows-App laeuft weiter am eigenen PC (Hochschul-Abgleich, Dateien, Notizen
bleiben lokal), meldet sich fuer die Community aber am gehosteten Dienst an. Ablauf:

- Anmelden: E-Mail und Studora-Passwort gehen einmal ueber das lokale Backend an `{dienst}/api/account/login`. Das
  Passwort wird nie gespeichert; im Datenordner liegt nur das Sitzungs-Token (`service-account.json`), das der Dienst
  jederzeit widerrufen kann (Abmelden, "Ueberall abmelden", Konto loeschen). Das Hochschul-Passwort hat damit nichts
  zu tun und verlaesst den PC nie.
- Weiterleitung: Im Einzelplatzmodus leitet das lokale Backend jede Anfrage unter `/api/community/...` mit dem Token an
  den Dienst weiter (`proxy`). Die Oberflaeche ruft dieselben Pfade wie im Dienst auf; Rechte, Tarif und Grenzen prueft
  allein der Dienst.
- Eigene PDFs melden: Der Dienst kennt die Hochschuldateien des PCs nicht. Nach dem Anmelden und nach jedem Abgleich
  meldet die App die Fingerabdruecke (SHA-256) ihrer Hochschul-PDFs (`claim_local_files`, ergaenzend, nie ersetzend:
  das iPad desselben Kontos meldet seine eigenen). Nur der Fingerabdruck verlaesst den PC, nie die Datei.

Adresse des Dienstes: `LERNAPP_SERVICE_URL` oder beim Anmelden eingegeben; nur https, ausser auf dem eigenen Rechner
(127.0.0.1/localhost, fuer Tests).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import config, db

STATE_FILE = "service-account.json"
DEVICE_NAME = "Studora für Windows"
TIMEOUT = 30
UPLOAD_TIMEOUT = 180
MAX_BODY = 80 << 20                    # groesser als das groesste Paket des Dienstes (community.MAX_PACKAGE_BYTES)
MAX_CLAIMS = 5_000
_PATH_RE = re.compile(r"^[A-Za-z0-9_\-/.]{0,200}$")


class LinkError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Zustand (nur im Datenordner des PCs)

def state_path() -> Path:
    return config.DATA_DIR / STATE_FILE


def load_state() -> dict:
    try:
        d = json.loads(state_path().read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(d: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, p)


def _device_id(st: dict) -> str:
    if not st.get("device_id"):
        st["device_id"] = "win-" + secrets.token_hex(12)
    return st["device_id"]


def normalize_url(url: str | None) -> str:
    """https://dienst.example oder http://127.0.0.1:8000 (nur eigener Rechner); ohne Schraegstrich am Ende."""
    u = (url or "").strip().rstrip("/")
    if not u:
        raise LinkError("service_url_missing", "Bitte die Adresse des Studora-Dienstes angeben.")
    p = urllib.parse.urlsplit(u)
    local = (p.hostname or "") in ("127.0.0.1", "localhost", "::1")
    if p.scheme not in ("https", "http") or not p.hostname or (p.scheme == "http" and not local):
        raise LinkError("service_url_invalid", "Die Adresse muss mit https:// beginnen.")
    if p.query or p.fragment or p.username or p.password:
        raise LinkError("service_url_invalid", "Die Adresse darf nur aus Server und Pfad bestehen.")
    return u


def service_url(st: dict | None = None) -> str:
    st = load_state() if st is None else st
    return (st.get("url") or os.environ.get("LERNAPP_SERVICE_URL") or "").strip().rstrip("/")


def linked(st: dict | None = None) -> bool:
    st = load_state() if st is None else st
    return bool(st.get("token") and st.get("url"))


# ---------------------------------------------------------------- HTTP (austauschbar fuer Tests)

def _urllib_transport(method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - Adresse geprueft (normalize_url)
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read(MAX_BODY + 1)
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, e.read(MAX_BODY + 1)


transport = _urllib_transport


def call(method: str, path: str, body: bytes | None = None, *, query: str = "", content_type: str = "application/json",
         st: dict | None = None, url: str | None = None, token: str | None = None, timeout: float = TIMEOUT) -> tuple[int, dict, bytes]:
    st = load_state() if st is None else st
    base = url or service_url(st)
    if not base:
        raise LinkError("not_linked", "Die App ist mit keinem Studora-Konto verbunden.", 409)
    headers = {"Accept": "application/json", "User-Agent": f"{DEVICE_NAME} (Studora)"}
    if body is not None:
        headers["Content-Type"] = content_type or "application/json"
    tok = token if token is not None else st.get("token")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    full = base + path + (("?" + query) if query else "")
    try:
        status, hdrs, data = transport(method, full, headers, body, timeout)
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise LinkError("service_unreachable", f"Der Studora-Dienst ist nicht erreichbar ({getattr(e, 'reason', e)}). "
                                               "Internetverbindung prüfen und später erneut versuchen.", 502)
    if len(data) > MAX_BODY:
        raise LinkError("service_response_too_large", "Antwort des Dienstes ist zu groß.", 502)
    if status == 401 and tok and st.get("token") == tok:
        # Sitzung abgelaufen oder widerrufen: Token vergessen, Adresse und E-Mail bleiben fuer die neue Anmeldung
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
        raise LinkError("service_url_invalid", "Unter dieser Adresse läuft kein Studora-Dienst.", 400)
    if status != 200:
        code, msg = _detail(data, "Anmeldung fehlgeschlagen.")
        raise LinkError(code, msg, status if status in (400, 401, 403, 423, 429) else 502)
    d = _json(data)
    if not d.get("token") or not isinstance(d.get("user"), dict):
        raise LinkError("service_error", "Unerwartete Antwort des Dienstes.", 502)
    prev = st.get("synced_account")
    if prev and prev.get("id") != d["user"].get("id"):
        # anderes Konto als beim letzten Abgleich (Pruefpunkt 1203): die Daten dieses PCs gehoerten bisher zu einem
        # anderen Konto. Erst nach Bestaetigung abgleichen, sonst landen sie ungefragt im neuen Konto.
        st["sync_enabled"] = False
        st["sync_confirm"] = {"previous_email": prev.get("email"), "since": int(time.time())}
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
        return (f"Dein Studora-Konto gehört zur Hochschule „{u['university']}“, diese App ist für „{mine}“ eingerichtet. "
                "Lösungen gibt es nur innerhalb derselben Hochschule.")
    return None


def status_info(st: dict | None = None, refresh: bool = True) -> dict:
    st = load_state() if st is None else st
    out = {"linked": linked(st), "url": service_url(st) or None, "sync_confirm": st.get("sync_confirm"), "env_url": bool(os.environ.get("LERNAPP_SERVICE_URL")),
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


def logout() -> dict:
    st = load_state()
    if st.get("token"):
        try:
            call("POST", "/api/account/logout", b"{}", st=st)
        except LinkError:
            pass                        # offline: das Token wird trotzdem vergessen
    keep = {k: st[k] for k in ("url", "device_id") if st.get(k)}
    if st.get("user", {}).get("email"):
        keep["last_email"] = st["user"]["email"]
    save_state(keep)
    return status_info(keep, refresh=False)


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

def local_fingerprints(limit: int = MAX_CLAIMS) -> list[str]:
    """SHA-256 der Hochschul-PDFs aus dem eigenen Abgleich (Stud.IP, Learnweb), fehlende werden aus der Datei auf
    der Platte berechnet und gemerkt. Eigene Dokumente (`__user__`) und geloeschte Dateien zaehlen nicht."""
    from .testshare import file_sha256
    out: list[str] = []
    with db.cursor() as conn:
        rows = db.rows(conn, """SELECT id, local_path, content_sha256, name, mime FROM files
                                WHERE course_id<>'__user__' AND download_url IS NOT NULL AND download_url<>''
                                  AND deleted_at IS NULL ORDER BY id""")
        for r in rows:
            if len(out) >= limit:
                break
            is_pdf = (r.get("mime") or "").endswith("pdf") or (r.get("name") or "").lower().endswith(".pdf")
            sha = r.get("content_sha256")
            if not sha and is_pdf and r.get("local_path") and Path(r["local_path"]).is_file():
                try:
                    sha = file_sha256(Path(r["local_path"]))
                    conn.execute("UPDATE files SET content_sha256=? WHERE id=?", (sha, r["id"]))
                except OSError:
                    sha = None
            if sha and is_pdf and re.fullmatch(r"[0-9a-f]{64}", sha):
                out.append(sha)
    return sorted(set(out))


def claim_local_files() -> dict:
    st = load_state()
    if not linked(st):
        raise LinkError("not_linked", "Die App ist mit keinem Studora-Konto verbunden.", 409)
    if (msg := university_mismatch(st)):
        raise LinkError("university_mismatch", msg, 409)
    fps = local_fingerprints()
    status, _, data = call("POST", "/api/community/claims", json.dumps({"fingerprints": fps}).encode(), st=st)
    if status >= 400:
        code, msg = _detail(data, "PDFs konnten nicht gemeldet werden.")
        raise LinkError(code, msg, status)
    d = _json(data)
    st = load_state()
    st["claims"] = {"at": int(time.time()), "sent": len(fps), "total": d.get("total")}
    save_state(st)
    return st["claims"]


def claim_quietly() -> None:
    """Nach einem Abgleich: melden, wenn verbunden; Fehler nur protokollieren (der Abgleich selbst ist fertig)."""
    try:
        if linked():
            claim_local_files()
    except LinkError:
        pass


# ---------------------------------------------------------------- Weiterleitung /api/community/... an den Dienst

def proxy(method: str, subpath: str, query: str, body: bytes | None, content_type: str | None) -> tuple[int, str, bytes]:
    """Anfrage der Oberflaeche an den Dienst weiterreichen. Liefert (Status, Inhaltstyp, Daten)."""
    if not _PATH_RE.match(subpath) or ".." in subpath:
        raise LinkError("path_invalid", "Ungültiger Pfad.", 400)
    if body is not None and len(body) > MAX_BODY:
        raise LinkError("too_large", "Die Lösung ist zu groß.", 413)
    st = load_state()
    if not linked(st):
        raise LinkError("not_linked", "Für die Community melde dich unter Einstellungen → Studora-Konto mit deinem "
                                      "Studora-Konto an (dasselbe Konto wie auf dem iPad).", 409)
    if (msg := university_mismatch(st)):
        raise LinkError("university_mismatch", msg, 409)
    upload = method in ("POST", "PUT", "PATCH") and body is not None and len(body) > 1 << 20
    status, hdrs, data = call(method, "/api/community/" + subpath.lstrip("/"), body if method not in ("GET", "HEAD") else None,
                              query=query, content_type=content_type or "application/json", st=st,
                              timeout=UPLOAD_TIMEOUT if upload or subpath.endswith("/package") else TIMEOUT)
    return status, hdrs.get("content-type") or "application/json", data
