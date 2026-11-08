"""Anmeldung der Windows-App ueber den Systembrowser (Dienst, 05.11.2026; Gegenstueck: app/account_mode.py).

Ablauf wie OAuth fuer native Apps (RFC 8252) mit PKCE (S256), ohne fremdes Paket:
1. Die Windows-App oeffnet `/login?app=windows&redirect_uri=http://127.0.0.1:<port>/konto/rueckkehr&state=..&
   code_challenge=..` im Systembrowser. Die Anmeldeseite meldet an (Passwort, Apple, Google, neues Konto).
2. Die Seite ruft mit der Browser-Sitzung `POST /api/app-login/code {redirect_uri, state, code_challenge}` und
   leitet auf `redirect_uri?code=..&state=..` weiter. Der Code ist 2 Minuten gueltig, einmal nutzbar, an Konto,
   Challenge und Rueckleitung gebunden und wird nur als SHA-256 gespeichert.
3. Die App tauscht ihn mit `POST /api/app-login/token {code, code_verifier, redirect_uri, device_id, device_name}`
   (oeffentlich) gegen eine eigene Sitzung des Geraets. Ohne passenden Verifier, nach Ablauf oder beim zweiten
   Versuch: 400 code_invalid.

Rueckleitungen nur auf den eigenen Rechner (http://127.0.0.1|localhost|[::1]:<port>/konto/rueckkehr): ein fremder
Server kann so nie einen Code bekommen; ein Programm auf demselben PC scheitert am Verifier.
"""
from __future__ import annotations

import base64
import hashlib
import re
import secrets
import urllib.parse
from datetime import timedelta

from fastapi import APIRouter, Body, HTTPException, Request

from . import accounts, config

from .account_api import NoStoreRoute  # noqa: E402 - Antworten mit Einmal-Code bzw. Sitzung nie zwischenspeichern (P55-11)

router = APIRouter(prefix="/api/app-login", tags=["app-login"], route_class=NoStoreRoute)
PUBLIC = {"/api/app-login/token"}
CODE_SECONDS = 120
REDIRECT_RE = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})/konto/rueckkehr$")
CHALLENGE_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
VERIFIER_RE = re.compile(r"^[A-Za-z0-9._~-]{43,128}$")
SCHEMA = """CREATE TABLE IF NOT EXISTS app_login_codes (
    code_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    challenge TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    client TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
)"""


def _hosted() -> None:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Gibt es nur im StudiNow-Dienst.", "code": "not_hosted"})


def _bad(detail: str, code: str = "request_invalid") -> HTTPException:
    return HTTPException(400, {"detail": detail, "code": code})


def valid_redirect(uri: str) -> bool:
    m = REDIRECT_RE.fullmatch(uri or "")              # fullmatch: "$" liesse ein angehaengtes "\n" durch (Audit P26-11)
    return bool(m and 0 < int(m.group(2)) < 65536)


def _hash(code: str) -> str:
    return hashlib.sha256(code.encode("utf-8")).hexdigest()


@router.post("/code")
def make_code(request: Request, body: dict = Body(...)):
    """Einmal-Code fuer die Windows-App (braucht die Browser-Sitzung)."""
    _hosted()
    user = getattr(request.state, "user", None)
    if not user:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    redirect = str(body.get("redirect_uri") or "")
    challenge = str(body.get("code_challenge") or "")
    state = str(body.get("state") or "")
    if not valid_redirect(redirect):
        raise _bad("Die Rückleitung muss auf diesen PC zeigen.", "redirect_invalid")
    if not CHALLENGE_RE.match(challenge) or not (8 <= len(state) <= 200) or not re.fullmatch(r"[A-Za-z0-9_-]+", state):
        raise _bad("Die Anfrage der App ist unvollständig.")
    code = secrets.token_urlsafe(32)
    t = accounts.now()
    with accounts.cursor() as conn:
        conn.execute(SCHEMA)
        conn.execute("DELETE FROM app_login_codes WHERE expires_at < ?", (accounts.iso(t - timedelta(days=1)),))
        conn.execute("INSERT INTO app_login_codes(code_hash, user_id, challenge, redirect_uri, client, created_at, expires_at) "
                     "VALUES (?,?,?,?,?,?,?)", (_hash(code), user["id"], challenge, redirect, "windows", accounts.iso(t),
                                                accounts.iso(t + timedelta(seconds=CODE_SECONDS))))
    return {"redirect": redirect + "?" + urllib.parse.urlencode({"code": code, "state": state}), "expires_in": CODE_SECONDS}


@router.post("/token")
def exchange(request: Request, body: dict = Body(...)):
    """Code und Verifier gegen eine Sitzung des Geraets tauschen (oeffentlich, einmal je Code)."""
    _hosted()
    code = str(body.get("code") or "")
    verifier = str(body.get("code_verifier") or "")
    redirect = str(body.get("redirect_uri") or "")
    invalid = _bad("Der Anmeldecode ist ungültig oder abgelaufen. Bitte in der App erneut anmelden.", "code_invalid")
    if not code or len(code) > 200 or not VERIFIER_RE.match(verifier):
        raise invalid
    t = accounts.now()
    with accounts.cursor() as conn:
        conn.execute(SCHEMA)
        r = conn.execute("SELECT * FROM app_login_codes WHERE code_hash=?", (_hash(code),)).fetchone()
        if not r or r["used_at"] or r["expires_at"] <= accounts.iso(t):
            raise invalid
        # jeder Versuch verbraucht den Code, auch ein falscher Verifier (kein Raten). Nur wer ihn wirklich verbraucht
        # (rowcount 1), darf weiter: zwei gleichzeitige Einloesungen ergaben sonst zwei Sitzungen (Audit P26-04).
        used = conn.execute("UPDATE app_login_codes SET used_at=? WHERE code_hash=? AND used_at IS NULL",
                            (accounts.iso(t), r["code_hash"])).rowcount
        conn.commit()
        if used != 1:
            raise invalid
        expect = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        if not secrets.compare_digest(expect, r["challenge"]) or redirect != r["redirect_uri"]:
            raise invalid
        u = conn.execute("SELECT * FROM users WHERE id=? AND status='active'", (r["user_id"],)).fetchone()
        if not u:
            raise invalid
        token = accounts.create_session(conn, u["id"], str(body.get("device_id") or "") or None,
                                        str(body.get("device_name") or "StudiNow für Windows")[:120])
        return {"user": accounts._public(u), "token": token}
