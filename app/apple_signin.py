"""„Mit Apple anmelden“ am Server: Refresh-Token holen und beim Loeschen des Kontos bei Apple widerrufen.

App-Review-Richtlinie 5.1.1(v): Wer ein Konto mit „Mit Apple anmelden“ loescht, dessen Anmeldung muss der Dienst bei
Apple widerrufen (`POST https://appleid.apple.com/auth/revoke`). Dafuer braucht der Dienst ein Token von Apple:
die App schickt bei der Anmeldung den einmaligen `authorization_code` mit, der Dienst tauscht ihn bei
`https://appleid.apple.com/auth/token` gegen ein Refresh-Token (in accounts.db je Verknuepfung, mit AES-GCM
verschluesselt, app/vault.py) und widerruft es beim Loeschen.

Beide Aufrufe brauchen ein Client-Secret: ein JWT (ES256), signiert mit dem privaten Schluessel eines
„Sign in with Apple“-Keys aus dem Apple-Developer-Konto. Einstellungen (deploy/.env, Abschnitt 7):

    LERNAPP_APPLE_TEAM_ID          Team-ID (10 Zeichen, Apple Developer → Membership)
    LERNAPP_APPLE_SIGNIN_KEY_ID    Key-ID des Schluessels (Apple Developer → Keys, mit „Sign in with Apple“)
    LERNAPP_APPLE_SIGNIN_KEY_FILE  Pfad zur .p8-Datei dieses Schluessels (als Volume eingehaengt, nie im Repo)

Ohne alle drei ist der Widerruf aus (`configured()` False): Anmeldung und Loeschen laufen wie bisher, der Dienst
tauscht keinen Code und widerruft nichts (das Loeschen protokolliert es). Nichts hier wirft in die Anmeldung oder das
Loeschen durch: Fehler werden ohne Token und ohne Secret protokolliert. Netz nur ueber `post_form` (Tests tauschen
diese Funktion aus).
"""
from __future__ import annotations

import base64
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

TOKEN_URL = "https://appleid.apple.com/auth/token"
REVOKE_URL = "https://appleid.apple.com/auth/revoke"
AUDIENCE = "https://appleid.apple.com"
TIMEOUT = 10
SECRET_TTL = 300                          # Apple erlaubt bis 6 Monate; der Dienst erzeugt es je Aufruf neu
log = logging.getLogger("uniflow.apple_signin")


class AppleError(RuntimeError):
    """Apple hat abgelehnt oder war nicht erreichbar (Text ohne Token und ohne Secret)."""


def _env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def team_id() -> str:
    return _env("LERNAPP_APPLE_TEAM_ID")


def key_id() -> str:
    return _env("LERNAPP_APPLE_SIGNIN_KEY_ID")


def key_file() -> str:
    return _env("LERNAPP_APPLE_SIGNIN_KEY_FILE")


def configured() -> bool:
    """Alle drei Einstellungen gesetzt und die .p8-Datei vorhanden."""
    return bool(team_id() and key_id() and key_file() and Path(key_file()).is_file())


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def client_secret(client_id: str, now: float | None = None) -> str:
    """JWT nach Apples Vorgabe: Kopf {alg: ES256, kid}, Inhalt {iss: Team-ID, iat, exp, aud, sub: client_id}."""
    key = serialization.load_pem_private_key(Path(key_file()).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise AppleError("Der Schluessel fuer „Mit Apple anmelden“ ist kein EC-Schluessel (.p8).")
    t = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id(), "typ": "JWT"}
    payload = {"iss": team_id(), "iat": t, "exp": t + SECRET_TTL, "aud": AUDIENCE, "sub": client_id}
    signing = f"{_b64(json.dumps(header, separators=(',', ':')).encode())}.{_b64(json.dumps(payload, separators=(',', ':')).encode())}"
    r, s = decode_dss_signature(key.sign(signing.encode("ascii"), ec.ECDSA(hashes.SHA256())))
    return f"{signing}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def post_form(url: str, data: dict) -> tuple[int, dict]:
    """POST als application/x-www-form-urlencoded an Apple; (Status, JSON oder {}). Tests tauschen diese Funktion aus."""
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode("ascii"), method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
                                          "User-Agent": "StudiNow/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:  # noqa: S310 - feste https-URLs von Apple
            body = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        body, status = e.read() or b"", e.code
    try:
        out = json.loads(body.decode("utf-8")) if body else {}
    except (ValueError, UnicodeDecodeError):
        out = {}
    return status, out if isinstance(out, dict) else {}


def exchange_code(code: str, client_id: str) -> str | None:
    """Einmaligen `authorization_code` der App gegen ein Refresh-Token tauschen. None ohne Einrichtung, ohne Code
    oder bei Fehler (protokolliert, ohne Code, Token und Secret)."""
    if not configured() or not code or not client_id:
        return None
    try:
        status, out = post_form(TOKEN_URL, {"client_id": client_id, "client_secret": client_secret(client_id),
                                            "code": code, "grant_type": "authorization_code"})
    except Exception as e:  # noqa: BLE001 - Netz, Schluesseldatei: die Anmeldung laeuft trotzdem
        log.warning("Apple: Code-Tausch fehlgeschlagen (%s)", type(e).__name__)
        return None
    token = out.get("refresh_token")
    if status != 200 or not isinstance(token, str) or not token:
        log.warning("Apple: Code-Tausch abgelehnt (HTTP %s, %s)", status, out.get("error") or "ohne Fehlercode")
        return None
    return token


def revoke(token: str, client_id: str, hint: str = "refresh_token") -> None:
    """Token bei Apple widerrufen; wirft AppleError (ohne Token im Text), wenn Apple nicht mit 200 antwortet."""
    if not configured():
        raise AppleError("Widerruf bei Apple nicht eingerichtet (LERNAPP_APPLE_TEAM_ID, _SIGNIN_KEY_ID, _SIGNIN_KEY_FILE).")
    try:
        status, out = post_form(REVOKE_URL, {"client_id": client_id, "client_secret": client_secret(client_id),
                                             "token": token, "token_type_hint": hint})
    except AppleError:
        raise
    except Exception as e:  # noqa: BLE001
        raise AppleError(f"Apple nicht erreichbar ({type(e).__name__})") from None
    if status != 200:
        raise AppleError(f"Apple hat den Widerruf abgelehnt (HTTP {status}, {out.get('error') or 'ohne Fehlercode'})")
