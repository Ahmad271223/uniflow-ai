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

Credit-Pakete (Verbrauchskaeufe, 15.11.2026, docs/KI-CREDITS-2026-11-15.md): dieselbe Pruefung der Signatur; ein Produkt
aus `plans.CREDIT_PACKS` fuellt den gekauften Topf des Kontos (`apply_credit_purchase` -> app/credits.py), jede
`transactionId` genau einmal. Wege: `POST /api/billing/credits/apple` (neue Apps), `POST /api/billing/apple/verify`
(falls eine aeltere App so einen Kauf meldet) und Apples Mitteilungen (`ONE_TIME_CHARGE` schreibt gut, `REFUND`/`REVOKE`
zieht die noch vorhandenen Credits dieses Kaufs ab, `REFUND_REVERSED` gibt sie zurueck).
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

# Meldungen, die das Recht entziehen (Erstattung; Familienfreigabe entzogen), auch falls revocationDate fehlt
REVOKING = {"REFUND", "REVOKE"}
# Meldungen nur zur Information: sie tragen die Transaktion, zu der eine Erstattung angefragt bzw. abgelehnt wurde
# (auch eine aeltere Periode) und aendern den Abo-Stand nicht (Audit P36-R4)
INFORMATIONAL = {"TEST", "CONSUMPTION_REQUEST", "REFUND_DECLINED"}

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


# Quelle der Kaeufe in credit_purchases
CREDIT_SOURCE = "app_store"
# Umgebungen ohne echtes Geld (TestFlight, Pruefung durch Apple, Xcode): Kaeufe zaehlen, aber nur bis zu einer Grenze
TEST_ENVIRONMENTS = ("Sandbox", "Xcode")


# ---------------------------------------------------------------- Konfiguration

def sandbox_credit_limit() -> int:
    """Grenze fuer Credit-Pakete aus der Testumgebung (Sandbox: TestFlight und Apples Pruefung kaufen dort ohne Geld) je
    Konto und Kalendermonat (LERNAPP_CREDITS_SANDBOX_MONTH, Standard 400 = hoechstens 2,60 EUR KI-Kosten). Ohne Grenze
    koennte ein Tester beliebig viele Pakete kostenlos kaufen - gekaufte Credits zaehlen ja nicht gegen das Monats-Budget."""
    try:
        return max(0, int(os.environ.get("LERNAPP_CREDITS_SANDBOX_MONTH") or 400))
    except ValueError:
        return 400


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
    # Kopf und Nutzdaten muessen Objekte sein, die Kette Texte: sonst endete der oeffentliche Benachrichtigungs-Endpunkt
    # mit 500 (AttributeError/TypeError; Liste 95 Nr. 4, 09.11.2026)
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise AppleError("jws_invalid", "Die signierten Kaufdaten haben keinen gültigen Kopf.")
    x5c = header.get("x5c")
    if header.get("alg") != "ES256" or not isinstance(x5c, list) or len(x5c) < 2 or not all(isinstance(c, str) for c in x5c):
        raise AppleError("jws_invalid", "Die signierten Kaufdaten haben keinen gültigen Kopf.")
    try:
        chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in x5c]
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
    if isinstance(ms, bool) or not isinstance(ms, (int, float)):
        return None
    try:                         # wird vor der Signaturpruefung gelesen: ein riesiger Wert ist kein 500 (Liste 95 Nr. 4)
        return datetime.fromtimestamp(ms / 1000, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def _ms_iso(ms) -> str | None:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat() if isinstance(ms, (int, float)) else None


# ---------------------------------------------------------------- Transaktion -> Berechtigung

def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def account_token(user_id: str) -> str:
    """appAccountToken fuer den Kauf: die UniFlow-ID (32 Hex) als UUID."""
    return str(uuid.UUID(hex=user_id))


def token_owner(tx: dict) -> str | None:
    """Konto aus `appAccountToken` (UniFlow-ID als UUID) oder None. Ein ungueltiges Token (keine UUID, kein Text) gilt
    als „kein Token“ - wie bisher in `_owner`; vorher warf `verify_purchase` dabei ValueError -> 500 (Liste 95 Nr. 1)."""
    tok = tx.get("appAccountToken")
    if not isinstance(tok, str) or not tok:
        return None
    try:
        return uuid.UUID(tok).hex
    except ValueError:
        return None


def _owner(conn: sqlite3.Connection, tx: dict) -> str | None:
    tok = token_owner(tx)
    if tok:
        return tok
    r = conn.execute("SELECT user_id FROM apple_transactions WHERE original_transaction_id=?",
                     (str(tx.get("originalTransactionId") or ""),)).fetchone()
    return r[0] if r else None


def _check_tx(tx: dict) -> tuple[str, str]:
    if tx.get("bundleId") != bundle_id():
        raise AppleError("wrong_app", "Der Kauf gehört nicht zu StudiNow.")
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
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo gehört zu einem anderen StudiNow-Konto.", 409)
    uid = user_id or owner
    if not uid:
        raise AppleError("unknown_account", "Zu diesem Abo gibt es kein StudiNow-Konto.", 404)
    t = billing._now(now)
    # Verlaengerungsinfo nur zum selben Abo (Audit P36-R2)
    if renewal and str(renewal.get("originalTransactionId") or "") != otid:
        renewal = None
    # Alter der Meldung = Signaturzeit der Transaktion. Eine frisch signierte Verlaengerungsinfo macht eine alte
    # Transaktion nicht neu: sonst holte eine vor der Erstattung signierte Transaktion das Recht zurueck (Audit P36-R1).
    signed = int(tx.get("signedDate") or 0)
    seen = conn.execute("SELECT user_id, last_signed_date FROM apple_transactions WHERE original_transaction_id=?", (otid,)).fetchone()
    if seen and seen[0] != uid:
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo gehört zu einem anderen StudiNow-Konto.", 409)
    # Durch ein Upgrade ersetzte Transaktion (isUpgraded): gilt nicht mehr, setzt den Tarif nie zurueck (Audit P36-R3)
    stale = bool(seen and signed and signed < seen[1]) or bool(tx.get("isUpgraded"))
    expires = _ms_iso(tx.get("expiresDate"))
    # Einmal bezahlt fuer Jahre (26.11.2026, plans.OFFERS kind non_renewing, "39,99 EUR einmalig fuer 5 Jahre"): Apple
    # nennt kein Ende, der Dienst rechnet es aus der Kaufzeit; eigene Quelle, damit ein Monatsabo daneben es nie ueberschreibt
    once = (plans.offer(tx.get("productId")) or {}).get("kind") == "non_renewing"
    source = "app_store_once" if once else "app_store"
    if once:
        bought = _ms_iso(tx.get("purchaseDate") or tx.get("originalPurchaseDate"))
        end = plans.offer_end(tx.get("productId"), billing._parse_utc(bought)) if bought else None
        if end is None:
            raise AppleError("jws_invalid", "Die Kaufdaten nennen keine Kaufzeit.")
        expires, renewal = end.isoformat(), None
    ntype, subtype = notification or (None, None)
    if tx.get("revocationDate") or ntype in REVOKING:
        status = "revoked"
    elif renewal and renewal.get("gracePeriodExpiresDate") and (
            (ntype == "DID_FAIL_TO_RENEW" and subtype == "GRACE_PERIOD")
            # Meldung der App mit Verlaengerungsinfo in der Frist (Audit P44-14)
            or (ntype is None and renewal.get("isInBillingRetryPeriod")
                and _ms_iso(renewal["gracePeriodExpiresDate"]) > t.isoformat())):
        status, expires = "grace", _ms_iso(renewal["gracePeriodExpiresDate"])
    elif ntype == "DID_FAIL_TO_RENEW" or (renewal and renewal.get("isInBillingRetryPeriod")):
        status = "billing_retry"
    elif ntype in ("EXPIRED", "GRACE_PERIOD_EXPIRED") or (expires and expires <= t.isoformat()):
        status = "expired"
    else:
        status = "active"
    # Kulanzfrist (Audit P44-14): die App meldet beim Start die Transaktion des abgelaufenen Zeitraums neu (ohne
    # Verlaengerungsinfo). Das ist kein Ablauf, solange die Frist aus DID_FAIL_TO_RENEW/GRACE_PERIOD fuer dieses Abo
    # laeuft; erst GRACE_PERIOD_EXPIRED bzw. das Ende der Frist beendet sie.
    if status == "expired" and ntype is None:
        cur = conn.execute("SELECT status, expires_at FROM entitlements WHERE user_id=? AND source=? "
                           "AND original_transaction_id=?", (uid, source, otid)).fetchone()
        if cur and cur[0] == "grace" and billing._row_active(cur[0], cur[1], t.isoformat()):
            stale = True
    will_renew = False if once else (bool(renewal.get("autoRenewStatus", 1)) if renewal else True)
    pending = None
    if renewal and renewal.get("autoRenewProductId"):
        nxt = plans.plan_for_product(renewal["autoRenewProductId"])
        if nxt and nxt != plan:
            pending = nxt            # Wechsel zur naechsten Verlaengerung (Downgrade); ein Upgrade wirkt bei Apple sofort
    if not stale:
        billing.set_entitlement(conn, uid, source, plan, original_transaction_id=otid, expires_at=expires,
                                status=status, will_renew=will_renew, pending_plan=pending,
                                environment=tx.get("environment"), now=t)
        conn.execute("""INSERT INTO apple_transactions(original_transaction_id, user_id, last_signed_date, product_id, updated_at)
                        VALUES (?,?,?,?,?) ON CONFLICT(original_transaction_id) DO UPDATE SET
                        last_signed_date=excluded.last_signed_date, product_id=excluded.product_id, updated_at=excluded.updated_at""",
                     (otid, uid, signed, tx.get("productId"), t.isoformat()))
    row = conn.execute("SELECT plan, status, expires_at, will_renew, pending_plan, environment FROM entitlements "
                       "WHERE user_id=? AND source=?", (uid, source)).fetchone()
    if row is None:              # nur eine ersetzte Transaktion gemeldet, noch kein Abo-Stand
        return {"plan": None, "status": None, "expires_at": None, "will_renew": False, "pending_plan": None,
                "original_transaction_id": otid, "environment": None, "stale": stale}
    return {"plan": row[0], "status": row[1], "expires_at": row[2], "will_renew": bool(row[3]), "pending_plan": row[4],
            "original_transaction_id": otid, "environment": row[5], "stale": stale}


# ---------------------------------------------------------------- Credit-Pakete (Verbrauchskaeufe)

def is_credit_pack(tx: dict) -> bool:
    return plans.credit_pack_credits(tx.get("productId") if isinstance(tx.get("productId"), str) else None) is not None


def _account_exists(conn: sqlite3.Connection, user_id: str) -> bool:
    """Gibt es das Konto noch? Ohne Tabelle `users` (reine Abrechnungsdatei in Tests und Werkzeugen) gilt: ja."""
    try:
        return conn.execute("SELECT 1 FROM users WHERE id=?", (user_id,)).fetchone() is not None
    except sqlite3.OperationalError as e:
        if "no such table" not in str(e):
            raise
        return True


def _credit_schema(conn: sqlite3.Connection) -> None:
    """Tabellen des gekauften Topfs auf dieser Verbindung sicherstellen (billing.connect legt sie nicht an)."""
    from . import accounts, credits, db
    db.schema_once(conn, "credits", accounts.db_path(), credits.ensure_schema)


def apply_credit_purchase(conn: sqlite3.Connection, user_id: str | None, tx: dict,
                          notification: tuple[str, str | None] | None = None, now: datetime | None = None) -> dict:
    """Gepruefte Transaktion eines Credit-Pakets anwenden: gutschreiben (genau einmal je `transactionId`), bei
    Erstattung/Widerruf die noch vorhandenen Credits dieses Kaufs abziehen, bei zurueckgenommener Erstattung zurueckgeben.

    Konto: das aus `appAccountToken` (wer gekauft hat, bekommt die Credits - auch wenn ein anderes Konto den Kauf
    meldet); gibt es dieses Konto nicht mehr oder fehlt das Token, das meldende Konto; ein schon verbuchter Kauf bleibt
    bei seinem Konto. Der Tarif spielt hier keine Rolle: wer bezahlt hat, bekommt seine Credits (ohne Pro AI ruhen sie).
    In einer laufenden Transaktion aufrufbar."""
    from . import credits as ledger
    if tx.get("bundleId") != bundle_id():
        raise AppleError("wrong_app", "Der Kauf gehört nicht zu StudiNow.")
    product = tx.get("productId")
    size = plans.credit_pack_credits(product if isinstance(product, str) else None)
    if size is None:
        raise AppleError("unknown_product", "Unbekanntes Credit-Paket.")
    tid = str(tx.get("transactionId") or tx.get("originalTransactionId") or "")
    if not tid:
        raise AppleError("jws_invalid", "Die Kaufdaten nennen keine Kennung des Kaufs.")
    t = billing._now(now)
    env = tx.get("environment") if isinstance(tx.get("environment"), str) else None
    ntype = (notification or (None, None))[0]
    known = conn.execute("SELECT user_id FROM credit_purchases WHERE source=? AND transaction_id=?", (CREDIT_SOURCE, tid)).fetchone()
    tok = token_owner(tx)
    if known:
        uid = known[0]
    elif tok and _account_exists(conn, tok):
        uid = tok
    else:
        uid = user_id
    limited = False
    if ntype == "REFUND_REVERSED":
        out = ledger.restore_purchase(conn, CREDIT_SOURCE, tid, now=t)
    elif tx.get("revocationDate") or ntype in REVOKING:
        out = ledger.refund_purchase(conn, CREDIT_SOURCE, tid, user_id=uid, product_id=product, credits=size, environment=env, now=t)
    elif ntype is not None and ntype != "ONE_TIME_CHARGE":
        # andere Mitteilungen zu einem Paket aendern nichts
        out = {"status": "ignored", "credits_added": 0, "credits_removed": 0, "user_id": uid}
    else:
        if not uid:
            raise AppleError("unknown_account", "Zu diesem Kauf gibt es kein StudiNow-Konto.", 404)
        if not known and env in TEST_ENVIRONMENTS:
            # Testumgebung: hoechstens sandbox_credit_limit() Credits je Konto und Kalendermonat (Berlin)
            month_start = datetime.fromisoformat(f"{ledger.period_of(t)}-01T00:00:00").replace(tzinfo=ledger.TZ).astimezone(timezone.utc)
            room = max(0, sandbox_credit_limit() - ledger.granted_since(conn, uid, month_start.isoformat(), TEST_ENVIRONMENTS))
            limited, size = size > room, min(size, room)
        out = ledger.grant_purchase(conn, uid, CREDIT_SOURCE, tid, size, product_id=product, environment=env,
                                    purchased_at=_ms_iso(tx.get("purchaseDate")), now=t)
    owner = out.get("user_id") or uid
    return {"kind": "credits", "status": out["status"], "credits_added": out["credits_added"],
            "credits_removed": out["credits_removed"], "transaction_id": tid, "product_id": product, "user_id": owner,
            "environment": env, "other_account": bool(user_id and owner and owner != user_id), "sandbox_limited": limited}


def verify_credit_purchase(conn: sqlite3.Connection, user_id: str, signed_transaction: str,
                           roots: list[x509.Certificate] | None = None, now: datetime | None = None) -> dict:
    """Credit-Paket aus der App melden (POST /api/billing/credits/apple): Signatur pruefen, genau einmal gutschreiben."""
    tx = verify_jws(signed_transaction, roots)
    _credit_schema(conn)
    return apply_credit_purchase(conn, user_id, tx, now=now)


def verify_purchase(conn: sqlite3.Connection, user_id: str, signed_transaction: str, signed_renewal: str | None = None,
                    roots: list[x509.Certificate] | None = None, now: datetime | None = None) -> dict:
    """Kauf oder Wiederherstellung aus der App (POST /api/billing/apple/verify)."""
    tx = verify_jws(signed_transaction, roots)
    if is_credit_pack(tx):
        # Credit-Paket ueber die Abo-Route (eine App, die den neuen Weg nicht kennt, meldet jede Transaktion hier und
        # schliesst sie danach ab): gutschreiben statt ablehnen, sonst waere der Kauf bezahlt und verloren. Die Antwort
        # hat die Felder der Abo-Antwort (ohne Tarif), dazu `credit_purchase`.
        _credit_schema(conn)
        done = apply_credit_purchase(conn, user_id, tx, now=now)
        return {"plan": None, "status": None, "expires_at": None, "will_renew": False, "pending_plan": None,
                "original_transaction_id": done["transaction_id"], "environment": done["environment"], "stale": False,
                "credit_purchase": done}
    renewal = verify_jws(signed_renewal, roots) if signed_renewal else None
    tok = token_owner(tx)
    if tok and tok != user_id:
        raise AppleError("subscription_owned_by_other_account", "Dieses Abo wurde mit einem anderen StudiNow-Konto gekauft.", 409)
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
        raise AppleError("wrong_app", "Die Meldung gehört nicht zu StudiNow.")
    ensure_schema(conn)
    nid = str(note.get("notificationUUID") or "")
    ntype, subtype = note.get("notificationType"), note.get("subtype")
    if ntype in INFORMATIONAL or not data.get("signedTransactionInfo"):
        return {"ok": True, "type": ntype, "applied": False}
    tx = verify_jws(data["signedTransactionInfo"], roots)
    renewal = verify_jws(data["signedRenewalInfo"], roots) if data.get("signedRenewalInfo") else None
    pack = is_credit_pack(tx)
    if pack:
        _credit_schema(conn)
    conn.execute("BEGIN IMMEDIATE")
    try:
        if nid and conn.execute("SELECT 1 FROM apple_notifications WHERE notification_uuid=?", (nid,)).fetchone():
            conn.execute("COMMIT")
            return {"ok": True, "type": ntype, "applied": False, "duplicate": True}
        if pack:
            # Credit-Paket: Kauf (ONE_TIME_CHARGE), Erstattung (REFUND/REVOKE), zurueckgenommene Erstattung
            done = apply_credit_purchase(conn, None, tx, (ntype, subtype), now=now)
            if nid:
                conn.execute("INSERT INTO apple_notifications(notification_uuid, original_transaction_id, notification_type, subtype, "
                             "signed_date, received_at) VALUES (?,?,?,?,?,?)",
                             (nid, done["transaction_id"], ntype, subtype, note.get("signedDate"), billing._now(now).isoformat()))
            conn.execute("COMMIT")
            return {"ok": True, "type": ntype, "applied": bool(done["credits_added"] or done["credits_removed"]), **done}
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
