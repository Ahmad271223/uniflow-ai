"""„Mit Google anmelden“ / „Mit Apple anmelden“: Pruefung der ID-Tokens auf dem Server.

Die Apps (Android, iPad) und die Web-Anmeldeseite bekommen vom Anbieter ein ID-Token (JWT, RS256 oder ES256). Der
Server prueft Signatur und Inhalt gegen die oeffentlichen Schluessel des Anbieters (JWKS, mit urllib geladen und eine
Stunde zwischengespeichert) und liefert nur dann eine stabile Kennung (`subject`) zurueck. Ohne gueltige Pruefung
gibt es kein Konto und keine Sitzung.

Erlaubte Client-IDs (Audience): LERNAPP_GOOGLE_CLIENT_IDS und LERNAPP_APPLE_CLIENT_IDS, kommagetrennt (Android-,
Web-, iOS-Client-IDs bzw. Bundle-ID und Services-ID). Fuer die Web-Anmeldeseite zusaetzlich
LERNAPP_GOOGLE_WEB_CLIENT_ID / LERNAPP_APPLE_WEB_CLIENT_ID (werden automatisch mit erlaubt). Ohne Client-ID ist der
Anbieter nicht eingerichtet (API: 501 provider_not_configured).

Geprueft werden: Signatur (cryptography, RSA PKCS#1 v1.5 mit SHA-256 bzw. ECDSA P-256), `iss`, `aud`, `exp` (60 s
Toleranz), `iat`/`nbf` (falls vorhanden) und `nonce`, wenn der Client einen mitschickt (Apple: im Token steht
entweder der Wert selbst oder dessen SHA-256, je nach SDK). Keine neue Abhaengigkeit: nur Standardbibliothek und das
vorhandene Paket `cryptography`.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import threading
import time
import urllib.request

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

PROVIDERS = {
    "google": {"jwks": "https://www.googleapis.com/oauth2/v3/certs",
               "issuers": ("accounts.google.com", "https://accounts.google.com"),
               "env": "LERNAPP_GOOGLE_CLIENT_IDS", "web_env": "LERNAPP_GOOGLE_WEB_CLIENT_ID"},
    "apple": {"jwks": "https://appleid.apple.com/auth/keys",
              "issuers": ("https://appleid.apple.com",),
              "env": "LERNAPP_APPLE_CLIENT_IDS", "web_env": "LERNAPP_APPLE_WEB_CLIENT_ID"},
}
JWKS_TTL = 3600
JWKS_TIMEOUT = 10
LEEWAY = 60
MAX_TOKEN_LEN = 8192


class TokenError(ValueError):
    """Das Token ist ungueltig (Signatur, Ablauf, Aussteller, Audience, Nonce, Form)."""


# ---------------------------------------------------------------- Konfiguration

def _split(value: str | None) -> list[str]:
    return [v.strip() for v in (value or "").split(",") if v.strip()]


def client_ids(provider: str) -> list[str]:
    p = PROVIDERS.get(provider)
    if not p:
        return []
    ids = _split(os.environ.get(p["env"]))
    web = web_client_id(provider)
    if web and web not in ids:
        ids.append(web)
    return ids


def web_client_id(provider: str) -> str | None:
    p = PROVIDERS.get(provider)
    return ((os.environ.get(p["web_env"]) or "").strip() or None) if p else None


def configured(provider: str) -> bool:
    return bool(client_ids(provider))


def status() -> dict:
    """Fuer GET /api/account/providers: welche Anbieter gehen, und die Client-ID fuer die Web-Anmeldeseite."""
    out: dict = {}
    for name in PROVIDERS:
        out[name] = configured(name)
        out[f"{name}_web_client_id"] = web_client_id(name) if configured(name) else None
    return out


# ---------------------------------------------------------------- JWKS laden (mit Cache)

_jwks_cache: dict[str, tuple[float, dict]] = {}
_jwks_lock = threading.Lock()


def fetch_jwks(url: str) -> dict:
    """Laedt die Schluessel des Anbieters (Tests tauschen diese Funktion aus)."""
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "UniFlow/1.0"})
    with urllib.request.urlopen(req, timeout=JWKS_TIMEOUT) as r:  # noqa: S310 - feste https-URLs aus PROVIDERS
        return json.loads(r.read().decode("utf-8"))


def _keys(provider: str, force: bool = False) -> list[dict]:
    url = PROVIDERS[provider]["jwks"]
    with _jwks_lock:
        hit = _jwks_cache.get(url)
        if hit and not force and time.monotonic() - hit[0] < JWKS_TTL:
            return hit[1].get("keys") or []
        data = fetch_jwks(url)
        if not isinstance(data, dict) or not isinstance(data.get("keys"), list):
            raise TokenError("Die Schluesselliste des Anbieters ist unbrauchbar.")
        _jwks_cache[url] = (time.monotonic(), data)
        return data["keys"]


def clear_cache() -> None:
    with _jwks_lock:
        _jwks_cache.clear()


# ---------------------------------------------------------------- JWT lesen und pruefen

def _b64url_decode(s: str) -> bytes:
    s = s.strip()
    if not s or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=" for c in s):
        raise TokenError("Das Token ist nicht base64url-kodiert.")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _b64url_uint(s: str) -> int:
    return int.from_bytes(_b64url_decode(s), "big")


def _public_key(jwk: dict):
    kty = jwk.get("kty")
    if kty == "RSA":
        return rsa.RSAPublicNumbers(_b64url_uint(jwk["e"]), _b64url_uint(jwk["n"])).public_key()
    if kty == "EC" and jwk.get("crv") == "P-256":
        return ec.EllipticCurvePublicNumbers(_b64url_uint(jwk["x"]), _b64url_uint(jwk["y"]), ec.SECP256R1()).public_key()
    raise TokenError("Unbekannter Schluesseltyp beim Anbieter.")


def _verify_signature(jwk: dict, alg: str, signing_input: bytes, signature: bytes) -> None:
    key = _public_key(jwk)
    try:
        if alg == "RS256":
            if not isinstance(key, rsa.RSAPublicKey):
                raise TokenError("Schluessel passt nicht zum Algorithmus.")
            key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
        elif alg == "ES256":
            if not isinstance(key, ec.EllipticCurvePublicKey) or len(signature) != 64:
                raise TokenError("Schluessel passt nicht zum Algorithmus.")
            der = encode_dss_signature(int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big"))
            key.verify(der, signing_input, ec.ECDSA(hashes.SHA256()))
        else:
            raise TokenError("Algorithmus nicht erlaubt.")
    except InvalidSignature:
        raise TokenError("Die Signatur des Tokens stimmt nicht.")


def decode_unverified(token: str) -> tuple[dict, dict, bytes, bytes]:
    """(Kopf, Inhalt, Signatur, signierter Teil) - noch ohne jede Pruefung."""
    if not isinstance(token, str) or not token or len(token) > MAX_TOKEN_LEN:
        raise TokenError("Kein Token.")
    parts = token.split(".")
    if len(parts) != 3:
        raise TokenError("Das Token hat nicht die Form eines JWT.")
    try:
        header = json.loads(_b64url_decode(parts[0]))
        payload = json.loads(_b64url_decode(parts[1]))
    except (ValueError, UnicodeDecodeError):
        raise TokenError("Das Token laesst sich nicht lesen.")
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise TokenError("Das Token laesst sich nicht lesen.")
    return header, payload, _b64url_decode(parts[2]), f"{parts[0]}.{parts[1]}".encode("ascii")


def _nonce_ok(expected: str | None, claim) -> bool:
    if not expected:
        return True
    if not isinstance(claim, str) or not claim:
        return False
    return claim == expected or claim == hashlib.sha256(expected.encode("utf-8")).hexdigest()


def verify(provider: str, token: str, nonce: str | None = None, now: float | None = None) -> dict:
    """Prueft das ID-Token und liefert {"provider", "subject", "email", "email_verified"}. Wirft TokenError."""
    p = PROVIDERS.get(provider)
    if not p:
        raise TokenError("Unbekannter Anbieter.")
    allowed = client_ids(provider)
    if not allowed:
        raise TokenError("Anbieter nicht eingerichtet.")
    header, payload, signature, signing_input = decode_unverified(token)
    alg = header.get("alg")
    if alg not in ("RS256", "ES256"):
        raise TokenError("Algorithmus nicht erlaubt.")
    kid = header.get("kid")
    jwk = None
    for force in (False, True):              # unbekannte kid: Schluessel einmal frisch laden (Rotation)
        keys = _keys(provider, force=force)
        jwk = next((k for k in keys if k.get("kid") == kid or (kid is None and len(keys) == 1)), None)
        if jwk:
            break
    if not jwk:
        raise TokenError("Der Signaturschluessel des Tokens ist dem Anbieter nicht bekannt.")
    _verify_signature(jwk, alg, signing_input, signature)

    if payload.get("iss") not in p["issuers"]:
        raise TokenError("Der Aussteller des Tokens passt nicht.")
    aud = payload.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if not any(isinstance(a, str) and a in allowed for a in auds):
        raise TokenError("Das Token ist nicht fuer diese App ausgestellt.")
    t = time.time() if now is None else now
    exp = payload.get("exp")
    if not isinstance(exp, (int, float)) or exp + LEEWAY < t:
        raise TokenError("Das Token ist abgelaufen.")
    for claim in ("nbf", "iat"):
        v = payload.get(claim)
        if isinstance(v, (int, float)) and v - LEEWAY > t:
            raise TokenError("Das Token ist noch nicht gueltig.")
    if not _nonce_ok(nonce, payload.get("nonce")):
        raise TokenError("Die Nonce stimmt nicht.")
    sub = payload.get("sub")
    if not isinstance(sub, str) or not sub:
        raise TokenError("Das Token enthaelt keine Kennung.")
    email = payload.get("email")
    email = email.strip().lower() if isinstance(email, str) and email.strip() else None
    ev = payload.get("email_verified")
    verified = ev is True or (isinstance(ev, str) and ev.lower() == "true")
    return {"provider": provider, "subject": sub, "email": email, "email_verified": bool(email) and verified}
