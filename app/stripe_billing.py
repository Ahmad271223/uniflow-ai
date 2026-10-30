"""Stripe fuer Abos im Web und unter Windows (gehosteter Dienst), Entscheidung des Inhabers vom 30.10.2026
(docs/PLAN-WEB-ZUERST-2026-10-30.md Stufe D): Checkout fuer den Abschluss, Kundenportal fuer Wechsel und Kuendigung,
Webhooks fuer den Stand. Das Recht am Konto setzt wie bei Apple nur der Server (app/billing.py, Quelle `stripe`).

Ohne Fremdpaket: die Stripe-API ist form-kodiertes HTTPS mit dem geheimen Schluessel als Basic-Auth. Tests tauschen
`http_post_form`/`http_get` aus und pruefen die Webhook-Signatur mit einem eigenen Geheimnis.

Konfiguration (Umgebung des Dienstes, nie in der App):
- LERNAPP_STRIPE_SECRET_KEY      sk_live_… oder sk_test_…
- LERNAPP_STRIPE_WEBHOOK_SECRET  whsec_… (Endpunkt POST /api/billing/stripe/webhook)
- LERNAPP_STRIPE_PRICES          "plus=price_…,pro_connect=price_…,pro_ai=price_…" (monatliche Preise in Stripe)
- LERNAPP_PUBLIC_URL             Basis der Rueck-Adressen nach dem Checkout

Regeln:
- Ein Stripe-Abo gehoert genau einem Konto (`original_transaction_id` = Abo-ID, wie bei Apple).
- Jedes Ereignis zaehlt hoechstens einmal (Tabelle stripe_events), Stripe schickt Ereignisse mehrfach.
- Stand aus dem Abo-Objekt: active/trialing -> active; past_due -> billing_retry; unpaid/canceled/incomplete_expired
  -> expired; `cancel_at_period_end` -> laeuft bis `current_period_end`, verlaengert nicht.
- Ein Ereignis mit unbekanntem Preis oder ohne zuordenbares Konto wird quittiert (200) und protokolliert, nie
  stillschweigend als Tarif uebernommen.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from . import billing, plans

API = "https://api.stripe.com/v1"
HTTP_TIMEOUT_S = 20
SIGNATURE_TOLERANCE_S = 300
SOURCE = "stripe"
STATUS = {"active": "active", "trialing": "active", "past_due": "billing_retry", "unpaid": "expired", "canceled": "expired",
          "incomplete_expired": "expired", "paused": "expired"}


class StripeError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Konfiguration

def _env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def secret_key() -> str:
    return _env("LERNAPP_STRIPE_SECRET_KEY")


def webhook_secret() -> str:
    return _env("LERNAPP_STRIPE_WEBHOOK_SECRET")


def prices() -> dict[str, str]:
    """Tarif -> Stripe-Preis-ID aus LERNAPP_STRIPE_PRICES; nur bekannte, kaufbare Tarife."""
    out = {}
    for part in _env("LERNAPP_STRIPE_PRICES").split(","):
        k, _, v = part.partition("=")
        k, v = k.strip(), v.strip()
        if k in plans.PLANS and k != "free" and v:
            out[k] = v
    return out


def plan_for_price(price_id: str | None) -> str | None:
    for plan, pid in prices().items():
        if pid == price_id:
            return plan
    return None


def available() -> bool:
    return bool(secret_key() and prices())


def public_url() -> str:
    from . import config
    return _env("LERNAPP_PUBLIC_URL").rstrip("/") or f"http://localhost:{config.PORT}"


# ---------------------------------------------------------------- HTTP (Tests tauschen diese zwei Funktionen aus)

def _flatten(fields: dict, prefix: str = "") -> list[tuple[str, str]]:
    """Verschachtelte Felder in Stripes Klammer-Schreibweise: {"a": {"b": 1}} -> a[b]=1, Listen mit Index."""
    out: list[tuple[str, str]] = []
    for k, v in fields.items():
        key = f"{prefix}[{k}]" if prefix else str(k)
        if isinstance(v, dict):
            out += _flatten(v, key)
        elif isinstance(v, (list, tuple)):
            for i, item in enumerate(v):
                out += _flatten(item, f"{key}[{i}]") if isinstance(item, dict) else [(f"{key}[{i}]", str(item))]
        elif v is not None:
            out.append((key, str(v).lower() if isinstance(v, bool) else str(v)))
    return out


def _request(method: str, path: str, fields: dict | None = None, idempotency_key: str | None = None) -> dict:
    key = secret_key()
    if not key:
        raise StripeError("stripe_not_configured", "Stripe ist nicht eingerichtet.", 503)
    data = urllib.parse.urlencode(_flatten(fields or {})).encode("ascii") if fields is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Authorization": "Basic " + base64.b64encode(f"{key}:".encode()).decode(),
                                          "Content-Type": "application/x-www-form-urlencoded"})
    if idempotency_key:
        req.add_header("Idempotency-Key", idempotency_key)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as r:  # noqa: S310 - feste https-Adresse
            return json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:600]
        try:
            msg = json.loads(body).get("error", {}).get("message") or body
        except ValueError:
            msg = body
        raise StripeError("stripe_error", f"Stripe antwortete mit Fehler {e.code}: {msg}", 502)
    except (urllib.error.URLError, TimeoutError, OSError):
        raise StripeError("stripe_unreachable", "Stripe ist nicht erreichbar.", 502)


def http_post_form(path: str, fields: dict, idempotency_key: str | None = None) -> dict:
    return _request("POST", path, fields, idempotency_key)


def http_get(path: str) -> dict:
    return _request("GET", path)


# ---------------------------------------------------------------- Kunde, Checkout, Portal

def customer_id(conn, user: dict, create: bool = True) -> str | None:
    """Stripe-Kunde des Kontos (Tabelle stripe_customers), bei Bedarf anlegen."""
    row = conn.execute("SELECT customer_id FROM stripe_customers WHERE user_id=?", (user["id"],)).fetchone()
    if row:
        return row[0]
    if not create:
        return None
    c = http_post_form("/customers", {"email": user["email"], "metadata": {"user_id": user["id"]}}, idempotency_key=f"customer-{user['id']}")
    cid = c.get("id")
    if not isinstance(cid, str) or not cid:
        raise StripeError("stripe_error", "Stripe hat keinen Kunden angelegt.", 502)
    conn.execute("INSERT OR IGNORE INTO stripe_customers(user_id, customer_id, created_at) VALUES (?,?,?)",
                 (user["id"], cid, datetime.now(timezone.utc).replace(microsecond=0).isoformat()))
    return cid


def user_for_customer(conn, cid: str | None) -> str | None:
    if not cid:
        return None
    row = conn.execute("SELECT user_id FROM stripe_customers WHERE customer_id=?", (cid,)).fetchone()
    return row[0] if row else None


def checkout(conn, user: dict, plan: str) -> dict:
    """Checkout-Sitzung fuer ein Monatsabo; die Oberflaeche leitet auf `url` weiter."""
    if not available():
        raise StripeError("stripe_not_configured", "Im Web gibt es noch keinen Abschluss (Stripe nicht eingerichtet).", 503)
    price = prices().get(plan)
    if not price:
        raise StripeError("plan_not_sellable", f"Der Tarif {plan!r} ist im Web nicht abschließbar.", 400)
    base = public_url()
    s = http_post_form("/checkout/sessions", {
        "mode": "subscription", "customer": customer_id(conn, user), "client_reference_id": user["id"], "locale": "de",
        "line_items": [{"price": price, "quantity": 1}],
        "subscription_data": {"metadata": {"user_id": user["id"], "plan": plan}},
        "success_url": f"{base}/#/abo?checkout=success", "cancel_url": f"{base}/#/abo?checkout=cancel",
    })
    if not isinstance(s.get("url"), str):
        raise StripeError("stripe_error", "Stripe hat keine Checkout-Adresse geliefert.", 502)
    return {"url": s["url"], "session_id": s.get("id"), "plan": plan}


def portal(conn, user: dict) -> dict:
    """Kundenportal: Zahlungsart, Wechsel, Kuendigung, Rechnungen."""
    if not available():
        raise StripeError("stripe_not_configured", "Stripe ist nicht eingerichtet.", 503)
    cid = customer_id(conn, user, create=False)
    if not cid:
        raise StripeError("no_subscription", "Für dieses Konto gibt es kein Stripe-Abo.", 404)
    s = http_post_form("/billing_portal/sessions", {"customer": cid, "return_url": f"{public_url()}/#/abo"})
    if not isinstance(s.get("url"), str):
        raise StripeError("stripe_error", "Stripe hat keine Portal-Adresse geliefert.", 502)
    return {"url": s["url"]}


# ---------------------------------------------------------------- Webhook

def verify_signature(payload: bytes, header: str | None, secret: str | None = None, now: float | None = None) -> None:
    """Stripe-Signature: t=<Zeit>,v1=<HMAC-SHA256 ueber "<Zeit>.<Body>">; hoechstens 5 Minuten alt."""
    secret = secret if secret is not None else webhook_secret()
    if not secret:
        raise StripeError("stripe_not_configured", "Webhook-Geheimnis fehlt.", 503)
    parts = dict(p.split("=", 1) for p in (header or "").split(",") if "=" in p)
    t = parts.get("t")
    sigs = [v for k, v in (p.split("=", 1) for p in (header or "").split(",") if "=" in p) if k == "v1"]
    if not t or not t.isdigit() or not sigs:
        raise StripeError("signature_invalid", "Stripe-Signature fehlt oder ist unlesbar.", 400)
    if abs((now if now is not None else time.time()) - int(t)) > SIGNATURE_TOLERANCE_S:
        raise StripeError("signature_expired", "Stripe-Signature ist zu alt.", 400)
    want = hmac.new(secret.encode("utf-8"), f"{t}.".encode("utf-8") + payload, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(want, s) for s in sigs):
        raise StripeError("signature_invalid", "Stripe-Signature passt nicht.", 400)


def _iso(epoch) -> str | None:
    try:
        return datetime.fromtimestamp(int(epoch), timezone.utc).replace(microsecond=0).isoformat() if epoch else None
    except (TypeError, ValueError, OverflowError):
        return None


def _period_end(sub: dict):
    # bis API 2025-02: am Abo; seit 2025-03-31.basil: an jedem Posten
    items = (sub.get("items") or {}).get("data") or []
    return sub.get("current_period_end") or (items[0].get("current_period_end") if items else None)


def apply_subscription(conn, sub: dict, now: datetime | None = None) -> dict:
    """Abo-Objekt von Stripe in eine Berechtigung (Quelle stripe) umsetzen. Liefert, was gesetzt wurde."""
    items = (sub.get("items") or {}).get("data") or []
    price = (items[0].get("price") or {}).get("id") if items else None
    plan = plan_for_price(price)
    meta = sub.get("metadata") or {}
    uid = meta.get("user_id") or user_for_customer(conn, sub.get("customer") if isinstance(sub.get("customer"), str) else (sub.get("customer") or {}).get("id"))
    if not uid:
        return {"applied": False, "reason": "unknown_customer", "subscription": sub.get("id")}
    if not plan:
        return {"applied": False, "reason": "unknown_price", "subscription": sub.get("id"), "price": price, "user_id": uid}
    status = STATUS.get(sub.get("status") or "", None)
    if status is None:
        return {"applied": False, "reason": f"status_{sub.get('status')}", "subscription": sub.get("id"), "user_id": uid}
    expires = _iso(_period_end(sub))
    will_renew = status == "active" and not sub.get("cancel_at_period_end")
    billing.set_entitlement(conn, uid, SOURCE, plan, original_transaction_id=sub.get("id"), expires_at=expires,
                            status=status, will_renew=will_renew, environment="livemode" if sub.get("livemode") else "test", now=now)
    return {"applied": True, "user_id": uid, "plan": plan, "status": status, "expires_at": expires, "will_renew": will_renew,
            "subscription": sub.get("id")}


def handle_event(conn, payload: bytes, signature: str | None, now: datetime | None = None, secret: str | None = None) -> dict:
    """POST /api/billing/stripe/webhook: Signatur pruefen, Ereignis hoechstens einmal verarbeiten."""
    verify_signature(payload, signature, secret, now.timestamp() if now else None)
    try:
        event = json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise StripeError("payload_invalid", "Der Webhook-Inhalt ist kein JSON.", 400)
    eid, etype = event.get("id"), event.get("type") or ""
    if not isinstance(eid, str) or not eid:
        raise StripeError("payload_invalid", "Das Ereignis hat keine ID.", 400)
    dup = conn.execute("INSERT OR IGNORE INTO stripe_events(id, type, created_at) VALUES (?,?,?)",
                       (eid, etype, (now or datetime.now(timezone.utc)).replace(microsecond=0).isoformat())).rowcount == 0
    if dup:
        return {"received": True, "duplicate": True, "type": etype}
    obj = (event.get("data") or {}).get("object") or {}
    if etype == "checkout.session.completed":
        if obj.get("mode") != "subscription" or not obj.get("subscription"):
            return {"received": True, "type": etype, "applied": False, "reason": "not_a_subscription"}
        sid = obj["subscription"] if isinstance(obj["subscription"], str) else obj["subscription"].get("id")
        cid = obj.get("customer") if isinstance(obj.get("customer"), str) else None
        uid = obj.get("client_reference_id")
        if uid and cid and not user_for_customer(conn, cid):
            conn.execute("INSERT OR IGNORE INTO stripe_customers(user_id, customer_id, created_at) VALUES (?,?,?)",
                         (uid, cid, (now or datetime.now(timezone.utc)).replace(microsecond=0).isoformat()))
        sub = http_get(f"/subscriptions/{sid}")
        if uid and not (sub.get("metadata") or {}).get("user_id"):
            sub = {**sub, "metadata": {**(sub.get("metadata") or {}), "user_id": uid}}
        return {"received": True, "type": etype, **apply_subscription(conn, sub, now)}
    if etype in ("customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"):
        return {"received": True, "type": etype, **apply_subscription(conn, obj, now)}
    return {"received": True, "type": etype, "applied": False, "reason": "ignored"}
