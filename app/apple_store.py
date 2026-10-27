"""App-Store-Kaeufe serverseitig pruefen (StoreKit 2, App Store Server Notifications V2).

Die App schickt nach jedem Kauf, jeder Verlaengerung und beim Wiederherstellen die signierte Transaktion
(`Transaction.jwsRepresentation`) an `POST /api/billing/apple/verify`. Apple schickt Statusaenderungen (Verlaengerung,
Upgrade/Downgrade, Kuendigung, Ablauf, Erstattung) an `POST /api/billing/apple/notifications`. Beides sind JWS
(ES256) mit Zertifikatskette im Kopf (`x5c`). Geprueft wird:

1. die Kette Blatt -> Zwischenzertifikat -> Wurzel, wobei die Wurzel genau eines der konfigurierten Wurzelzertifikate
   ist (`LERNAPP_APPLE_ROOT_CERTS`, Pfade zu PEM/DER, z. B. „Apple Root CA - G3“ von apple.com/certificateauthority –
   der Betrieb legt sie ab, die App laedt nichts herunter);
2. Apples Kennzeichnung der Zertifikate (OID 1.2.840.113635.100.6.11.1 am Blatt, 1.2.840.113635.100.6.2.1 am
   Zwischenzertifikat) und ihre Gueltigkeit zum Signaturzeitpunkt;
3. die Signatur der Nutzdaten mit dem Schluessel des Blattzertifikats;
4. Bundle-ID (`LERNAPP_APPLE_BUNDLE_ID`, Standard de.uniflow.ai) und das Produkt (app/plans.py).

Zuordnung zum Konto: `appAccountToken` der Transaktion = UniFlow-ID als UUID (die App setzt sie beim Kauf). Ohne
Token gilt das Konto, das die Transaktion zuerst meldet; dieselbe `originalTransactionId` kann nie ein zweites Konto
freischalten (app/billing.py). Ohne konfigurierte Wurzel antwortet der Server ehrlich 503 `apple_not_configured`.
"""
from __future__ import annotations

import base64
import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from . import billing, plans

OID_LEAF = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
OID_INTERMEDIATE = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")

SCHEMA = """
CREATE TABLE IF NOT EXISTS apple_notifications (
    notification_uuid TEXT PRIMARY KEY,
    original_transaction_id TEXT,
    notification_type TEXT,
    subtype TEXT,
    signed_date INTEGER,
    received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS apple_transactions (
    original_transaction_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    last_signed_date INTEGER NOT NULL DEFAULT 0,
    product_id TEXT,
    updated_at TEXT NOT NULL
);
"""


class AppleError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Konfiguration

def bundle_id() -> str:
    return os.environ.get("LERNAPP_APPLE_BUNDLE_ID", "de.uniflow.ai")


def _load_cert(path: Path) -> x509.Certificate:
    raw = path.read_bytes()
    return x509.load_pem_x509_certificate(raw) if b"-----BEGIN" in raw else x509.load_der_x509_certificate(raw)


def root_certs() -> list[x509.Certificate]:
    paths = [p.strip() for p in (os.environ.get("LERNAPP_APPLE_ROOT_CERTS") or "").split(",") if p.strip()]
    return [_load_cert(Path(p)) for p in paths if Path(p).is_file()]


def configured() -> bool:
    return bool(root_certs())


# ---------------------------------------------------------------- JWS pruefen

def _b64url(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _fp(cert: x509.Certificate) -> bytes:
    return cert.fingerprint(hashes.SHA256())


def verify_jws(token: str, roots: list[x509.Certificate] | None = None, at: datetime | None = None) -> dict:
    """Prueft Kette, Kennzeichnung und Signatur; liefert die Nutzdaten. Wirft AppleError bei jedem Fehler."""
    roots = root_certs() if roots is None else roots
    if not roots:
        raise AppleError("apple_not_configured", "Die Prüfung von App-Store-Käufen ist auf dem Server nicht eingerichtet.", 503)
    try:
        head_b64, body_b64, sig_b64 = (token or "").split(".")
        header = json.loads(_b64url(head_b64))
        payload = json.loads(_b64url(body_b64))
        sig = _b64url(sig_b64)
    except (ValueError, json.JSONDecodeError):
        raise AppleError("jws_invalid", "Die signierten Kaufdaten sind beschädigt.")
    if header.get("alg") != "ES256" or not isinstance(header.get("x5c"), list) or len(header["x5c"]) < 2:
        raise AppleError("jws_invalid", "Die signierten Kaufdaten haben keinen gültigen Kopf.")
    try:
        chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in header["x5c"]]
    except ValueError:
        raise AppleError("jws_invalid", "Die Zertifikate der Kaufdaten sind beschädigt.")
    leaf, inter = chain[0], chain[1]
    root_fps = {_fp(r): r for r in roots}
    # Wurzel: das letzte Zertifikat der Kette muss eine konfigurierte Wurzel sein, oder das Zwischenzertifikat ist
    # direkt von einer konfigurierten Wurzel ausgestellt (Kette ohne mitgesendete Wurzel)
    anchor = root_fps.get(_fp(chain[-1])) if len(chain) >= 3 else None
    if anchor is None:
        for r in roots:
            try:
                inter.verify_directly_issued_by(r)
                anchor = r
                break
            except (ValueError, TypeError, InvalidSignature):
                continue
    if anchor is None:
        raise AppleError("jws_untrusted", "Die Kaufdaten stammen nicht von Apple.")
    try:
        leaf.verify_directly_issued_by(inter)
        inter.verify_directly_issued_by(anchor)
    except (ValueError, TypeError, InvalidSignature):
        raise AppleError("jws_untrusted", "Die Zertifikatskette der Kaufdaten ist ungültig.")
    for cert, oid in ((leaf, OID_LEAF), (inter, OID_INTERMEDIATE)):
        try:
            cert.extensions.get_extension_for_oid(oid)
        except x509.ExtensionNotFound:
            raise AppleError("jws_untrusted", "Die Zertifikate der Kaufdaten sind keine App-Store-Zertifikate.")
    when = at or _signed_at(payload) or datetime.now(timezone.utc)
    for cert in (leaf, inter):
        if not (cert.not_valid_before_utc <= when <= cert.not_valid_after_utc):
            raise AppleError("jws_untrusted", "Ein Zertifikat der Kaufdaten war zum Signaturzeitpunkt nicht gültig.")
    if len(sig) != 64:
        raise AppleError("jws_invalid", "Die Signatur der Kaufdaten hat eine falsche Länge.")
    der = encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big"))
    pub = leaf.public_key()
    if not isinstance(pub, ec.EllipticCurvePublicKey):
        raise AppleError("jws_untrusted", "Unerwarteter Schlüsseltyp in den Kaufdaten.")
    try:
        pub.verify(der, f"{head_b64}.{body_b64}".encode("ascii"), ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise AppleError("jws_untrusted", "Die Signatur der Kaufdaten stimmt nicht.")
    return payload


def _signed_at(payload: dict) -> datetime | None:
    ms = payload.get("signedDate")
    return datetime.fromtimestamp(ms / 1000, timezone.utc) if isinstance(ms, (int, float)) else None


def _ms_iso(ms) -> str | None:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat() if isinstance(ms, (int, float)) else None


# ---------------------------------------------------------------- Transaktion -> Berechtigung

def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def account_token(user_id: str) -> str:
    """appAccountToken fuer den Kauf: die UniFlow-ID (32 Hex) als UUID."""
    return str(uuid.UUID(hex=user_id))


def _owner(conn: sqlite3.Connection, tx: dict) -> str | None:
    tok = tx.get("appAccountToken")
    if tok:
        try:
            return uuid.UUID(str(tok)).hex
        except ValueError:
            return None
    r = conn.execute("SELECT user_id FROM apple_transactions WHERE original_transaction_id=?",
                     (str(tx.get("originalTransactionId") or ""),)).fetchone()
    return r[0] if r else None


def _check_tx(tx: dict) -> tuple[str, str]:
    if tx.get("bundleId") != bundle_id():
        raise AppleError("wrong_app", "Der Kauf gehört nicht zu Studora.")
    plan = plans.plan_for_product(tx.get("productId"))
    if not plan:
        raise AppleError("unknown_product", "Unbekanntes Abo-Produkt.")
    otid = str(tx.get("originalTransactionId") or "")
    if not otid:
        raise AppleError("jws_invalid", "Die Kaufdaten nennen keine Abo-Kennung.")
    return plan, otid


def apply_transaction(conn: sqlite3.Connection, user_id: str | None, tx: dict, renewal: dict | None = None,
                      notification: tuple[str, str | None] | None = None, now: datetime | None = None) -> dict:
    """Gepruefte Transaktion (und Verlaengerungsinfo) auf das Konto anwenden. Aeltere Meldungen als die zuletzt
    verarbeitete aendern nichts (Apple liefert nicht immer in Reihenfolge). Liefert den Abo-Stand der Transaktion."""
    plan, otid = _check_tx(tx)
    owner = _owner(conn, tx)
    if user_id and owner and owner != user_id:
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo gehört zu einem anderen Studora-Konto.", 409)
    uid = user_id or owner
    if not uid:
        raise AppleError("unknown_account", "Zu diesem Abo gibt es kein Studora-Konto.", 404)
    t = billing._now(now)
    signed = int(tx.get("signedDate") or 0)
    if renewal and int(renewal.get("signedDate") or 0) > signed:
        signed = int(renewal["signedDate"])
    seen = conn.execute("SELECT user_id, last_signed_date FROM apple_transactions WHERE original_transaction_id=?", (otid,)).fetchone()
    if seen and seen[0] != uid:
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo gehört zu einem anderen Studora-Konto.", 409)
    stale = bool(seen and signed and signed < seen[1])
    expires = _ms_iso(tx.get("expiresDate"))
    ntype, subtype = notification or (None, None)
    if tx.get("revocationDate"):
        status = "revoked"
    elif ntype == "DID_FAIL_TO_RENEW" and subtype == "GRACE_PERIOD" and renewal and renewal.get("gracePeriodExpiresDate"):
        status, expires = "grace", _ms_iso(renewal["gracePeriodExpiresDate"])
    elif ntype == "DID_FAIL_TO_RENEW" or (renewal and renewal.get("isInBillingRetryPeriod")):
        status = "billing_retry"
    elif ntype in ("EXPIRED", "GRACE_PERIOD_EXPIRED") or (expires and expires <= t.isoformat()):
        status = "expired"
    else:
        status = "active"
    will_renew = bool(renewal.get("autoRenewStatus", 1)) if renewal else True
    pending = None
    if renewal and renewal.get("autoRenewProductId"):
        nxt = plans.plan_for_product(renewal["autoRenewProductId"])
        if nxt and nxt != plan:
            pending = nxt            # Wechsel zur naechsten Verlaengerung (Downgrade); ein Upgrade wirkt bei Apple sofort
    if not stale:
        billing.set_entitlement(conn, uid, "app_store", plan, original_transaction_id=otid, expires_at=expires,
                                status=status, will_renew=will_renew, pending_plan=pending,
                                environment=tx.get("environment"), now=t)
        conn.execute("""INSERT INTO apple_transactions(original_transaction_id, user_id, last_signed_date, product_id, updated_at)
                        VALUES (?,?,?,?,?) ON CONFLICT(original_transaction_id) DO UPDATE SET
                        last_signed_date=excluded.last_signed_date, product_id=excluded.product_id, updated_at=excluded.updated_at""",
                     (otid, uid, signed, tx.get("productId"), t.isoformat()))
    row = conn.execute("SELECT plan, status, expires_at, will_renew, pending_plan, environment FROM entitlements "
                       "WHERE user_id=? AND source='app_store'", (uid,)).fetchone()
    return {"plan": row[0], "status": row[1], "expires_at": row[2], "will_renew": bool(row[3]), "pending_plan": row[4],
            "original_transaction_id": otid, "environment": row[5], "stale": stale}


def verify_purchase(conn: sqlite3.Connection, user_id: str, signed_transaction: str, signed_renewal: str | None = None,
                    roots: list[x509.Certificate] | None = None, now: datetime | None = None) -> dict:
    """Kauf oder Wiederherstellung aus der App (POST /api/billing/apple/verify)."""
    tx = verify_jws(signed_transaction, roots)
    renewal = verify_jws(signed_renewal, roots) if signed_renewal else None
    tok = tx.get("appAccountToken")
    if tok and uuid.UUID(str(tok)).hex != user_id:
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo wurde mit einem anderen Studora-Konto gekauft.", 409)
    ensure_schema(conn)
    conn.execute("BEGIN IMMEDIATE")
    try:
        out = apply_transaction(conn, user_id, tx, renewal, now=now)
        conn.execute("COMMIT")
        return out
    except Exception:
        conn.execute("ROLLBACK")
        raise


def handle_notification(conn: sqlite3.Connection, signed_payload: str, roots: list[x509.Certificate] | None = None,
                        now: datetime | None = None) -> dict:
    """App Store Server Notification V2. Doppelte Meldungen (gleiche notificationUUID) zaehlen einmal."""
    note = verify_jws(signed_payload, roots)
    data = note.get("data") or {}
    if data.get("bundleId") and data["bundleId"] != bundle_id():
        raise AppleError("wrong_app", "Die Meldung gehört nicht zu Studora.")
    ensure_schema(conn)
    nid = str(note.get("notificationUUID") or "")
    ntype, subtype = note.get("notificationType"), note.get("subtype")
    if ntype == "TEST" or not data.get("signedTransactionInfo"):
        return {"ok": True, "type": ntype, "applied": False}
    tx = verify_jws(data["signedTransactionInfo"], roots)
    renewal = verify_jws(data["signedRenewalInfo"], roots) if data.get("signedRenewalInfo") else None
    conn.execute("BEGIN IMMEDIATE")
    try:
        if nid and conn.execute("SELECT 1 FROM apple_notifications WHERE notification_uuid=?", (nid,)).fetchone():
            conn.execute("COMMIT")
            return {"ok": True, "type": ntype, "applied": False, "duplicate": True}
        out = apply_transaction(conn, None, tx, renewal, (ntype, subtype), now=now)
        if nid:
            conn.execute("INSERT INTO apple_notifications(notification_uuid, original_transaction_id, notification_type, subtype, "
                         "signed_date, received_at) VALUES (?,?,?,?,?,?)",
                         (nid, out["original_transaction_id"], ntype, subtype, note.get("signedDate"), billing._now(now).isoformat()))
        conn.execute("COMMIT")
        return {"ok": True, "type": ntype, "applied": not out["stale"], **out}
    except Exception:
        conn.execute("ROLLBACK")
        raise


def public_pem(cert: x509.Certificate) -> bytes:
    return cert.public_bytes(serialization.Encoding.PEM)
