"""Geraete-Regel fuer StudiNow-Konten (Auftrag des Inhabers vom 14.11.2026).

Regel:
1. Free: ein Konto gilt fuer EIN Geraet. Ein zweites Apple-Geraet (iPhone, iPad, Mac-App) bekommt `blocked` und zeigt
   statt der App einen Hinweis ("StudiNow Free gilt fuer ein Geraet ... Pro AI, 39,99 EUR im Jahr").
2. Plus: laeuft auf jedem Geraet (wird nie gesperrt: App-Review-Richtlinie 3.1.2, ein gekauftes Abo gilt auf allen
   Geraeten derselben Apple-ID), aber ohne Abgleich wie bisher. Das zweite Geraet bekommt `hint_plus` (einmaliger,
   wegtippbarer Hinweis in der App).
3. Pro AI und die laufende Probe (zaehlt wie ihr Tarif): keine Einschraenkung. Endet die Probe und das Konto ist Free,
   greift Regel 1 beim naechsten Kontakt.
4. Web und Windows zaehlen nicht als Geraet.

Technik: je Konto ein "Hauptgeraet" (users.primary_device_id, primary_device_name, primary_device_set_at). Das erste
Apple-Geraet, das sich mit der Faehigkeit `device_limit` meldet, wird Hauptgeraet. "Dieses Geraet stattdessen nutzen"
(`use_this`, POST /api/account/device/primary) macht das fragende Geraet zum Hauptgeraet; das andere sieht den Hinweis
beim naechsten Kontakt.

Abwaertsvertraeglich: Die Regel greift nur fuer Clients, die die Kopfzeile `X-StudiNow-Caps: device_limit` schicken
(neue Apple-App ab Build 41). Aeltere Apps (1.0.3, Builds 36-40), die Web-Oberflaeche und die Windows-App schicken sie
nicht: ihre Antworten bleiben Byte fuer Byte wie vorher (kein Feld `device`), und sie werden nie Hauptgeraet.

Der Dienst sperrt keine Daten-Anfragen: `blocked` ist eine Auskunft fuer die App, die danach den Hinweis-Bildschirm
zeigt. Konto, Abo und Abmelden bleiben in jedem Zustand erreichbar, damit niemand ohne Ausweg ausgesperrt ist.
"""
from __future__ import annotations

from . import access, accounts, billing, config, plans

CAP = "device_limit"
CAPS_HEADER = "x-studinow-caps"
STATES = ("ok", "blocked", "hint_plus")
# Recht, das den Betrieb auf mehreren Geraeten mit Abgleich traegt; sein Tarif ist der, den der Hinweis nennt (Pro AI)
SYNC_ENTITLEMENT = "can_sync_annotations"


def upgrade_plan() -> str:
    return plans.ENTITLEMENTS[SYNC_ENTITLEMENT]["from"]


def client_caps(request) -> frozenset[str]:
    """Faehigkeiten, die der Client meldet (`X-StudiNow-Caps: a, b`); ohne Kopfzeile leer."""
    headers = getattr(request, "headers", {}) or {}
    raw = headers.get(CAPS_HEADER) or ""
    return frozenset(p.strip().lower() for p in raw.split(",") if p.strip())


def applies(request, login: bool = False) -> bool:
    """Gilt die Regel fuer diese Anfrage? Nur im Dienst, nur mit der Faehigkeit `device_limit`, nie fuer Web und Windows.
    `login`: Anmelde-Anfragen tragen noch kein Bearer-Token; sonst muss es eine App-Anfrage sein (access.client_type)."""
    if not config.is_hosted() or CAP not in client_caps(request):
        return False
    headers = getattr(request, "headers", {}) or {}
    if (headers.get(access.CLIENT_HEADER) or "").strip().lower() in access.GATED_CLIENTS:
        return False
    return login or access.client_type(request) == "app"


def evaluate(plan: str | None, device_id: str | None, primary_id: str | None) -> str:
    """Reine Regel: Zustand dieses Geraets aus Tarif (mit Probe), Geraete-Kennung und Hauptgeraet.
    Ohne Kennung oder ohne Hauptgeraet nie sperren."""
    plan = plan if plan in plans.PLANS else "free"
    if not device_id or not primary_id or device_id == primary_id:
        return "ok"
    if plans.has(plan, SYNC_ENTITLEMENT):
        return "ok"
    return "hint_plus" if plans.rank(plan) > plans.rank("free") else "blocked"


def shown_state(server_state: str | None, local_plan: str | None) -> str:
    """Referenz fuer die Apps (Fixture device-limit/contract.json, `client_cases`): was das Geraet aus der Auskunft des
    Dienstes und seinem eigenen Tarif (Kauf im App Store bzw. laufende Probe auf dem Geraet) macht. Ein auf dem Geraet
    gueltiger Kauf geht vor: mit Pro AI nie ein Hinweis (verschwindet sofort nach dem Kauf, auch bevor der Dienst ihn
    kennt), mit Plus nie gesperrt (Richtlinie 3.1.2). Unbekannte Auskunft: nie sperren."""
    if server_state not in STATES:
        return "ok"
    plan = local_plan if local_plan in plans.PLANS else "free"
    if plans.has(plan, SYNC_ENTITLEMENT):
        return "ok"
    if server_state == "blocked" and plans.rank(plan) > plans.rank("free"):
        return "hint_plus"
    return server_state


def _payload(state: str, device_id: str | None, row) -> dict:
    up = upgrade_plan()
    p = plans.PLANS[up]
    primary = row["primary_device_id"] if row else None
    return {"state": state, "is_primary": bool(device_id and primary and device_id == primary),
            "primary_name": (row["primary_device_name"] if row else None) or None,
            "primary_set_at": (row["primary_device_set_at"] if row else None) or None,
            "upgrade_plan": up, "price_cents": p["price_cents"], "currency": p["currency"], "period": p["period"]}


def _session_device(conn, user_id: str, token: str | None):
    if not token:
        return None
    return conn.execute("SELECT device_id, device_name FROM sessions WHERE token_hash=? AND user_id=? AND revoked_at IS NULL",
                        (accounts._token_hash(token), user_id)).fetchone()


def _user_row(conn, user_id: str):
    return conn.execute("SELECT plan, plan_until, primary_device_id, primary_device_name, primary_device_set_at "
                        "FROM users WHERE id=?", (user_id,)).fetchone()


def status(user: dict, token: str | None, claim: bool = True) -> dict:
    """Zustand des Geraets dieser Sitzung. `claim`: hat das Konto noch kein Hauptgeraet, wird es dieses (das erste
    Apple-Geraet mit der Faehigkeit). Der Tarif kommt aus der Datenbank (Probe zaehlt wie ihr Tarif)."""
    uid = user["id"]
    with accounts.cursor() as conn:
        accounts._billing_schema(conn)                       # entitlements fuer current_plan; vor dem ersten Schreiben
        s = _session_device(conn, uid, token)
        device_id = s["device_id"] if s else None
        row = _user_row(conn, uid)
        if claim and device_id and row is not None and not row["primary_device_id"]:
            # WHERE ... IS NULL: zwei Geraete zugleich - nur das erste gewinnt, das zweite liest danach dessen Kennung
            conn.execute("UPDATE users SET primary_device_id=?, primary_device_name=?, primary_device_set_at=? "
                         "WHERE id=? AND primary_device_id IS NULL",
                         (device_id, s["device_name"], accounts.iso(accounts.now()), uid))
            row = _user_row(conn, uid)
        legacy = {"plan": row["plan"], "plan_until": row["plan_until"]} if row is not None else None
        plan = billing.current_plan(conn, uid, legacy=legacy)
        return _payload(evaluate(plan, device_id, row["primary_device_id"] if row is not None else None), device_id, row)


def use_this(user: dict, token: str | None) -> dict:
    """"Dieses Geraet stattdessen nutzen": das Geraet dieser Sitzung wird Hauptgeraet. Braucht eine Geraete-Kennung
    (die Apple-Apps schicken sie beim Anmelden mit); sonst 400 device_unknown."""
    uid = user["id"]
    with accounts.cursor() as conn:
        s = _session_device(conn, uid, token)
        if not s or not s["device_id"]:
            raise accounts.AccountError("device_unknown", "Dieses Gerät lässt sich nicht auswählen. Bitte melde dich "
                                                          "in der App ab und wieder an.", 400)
        conn.execute("UPDATE users SET primary_device_id=?, primary_device_name=?, primary_device_set_at=? WHERE id=?",
                     (s["device_id"], s["device_name"], accounts.iso(accounts.now()), uid))
    return status(user, token, claim=False)


def primary(user_id: str) -> dict | None:
    """Hauptgeraet des Kontos fuer den Datenexport; None, wenn keins gesetzt ist."""
    with accounts.cursor() as conn:
        row = _user_row(conn, user_id)
    if row is None or not row["primary_device_id"]:
        return None
    return {"device_id": row["primary_device_id"], "device_name": row["primary_device_name"], "set_at": row["primary_device_set_at"]}
