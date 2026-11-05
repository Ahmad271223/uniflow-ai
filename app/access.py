"""Abo-Pflicht je Client (Entscheidung des Inhabers vom 05.11.2026, docs/ENTSCHEIDUNGEN-INHABER-2026-11-04.md).

Wortlaut: „anmelden immer muss ohne abo geht nichts baue das ein“. Auslegung des Koordinators: In der Web-App des
Dienstes und in der Windows-App ist die Anmeldung mit dem StudiNow-Konto immer Pflicht, und ohne aktives Abo geht
nichts. Neue Konten haben die 7-Tage-Probe (wie Pro AI). Danach ohne Plus oder Pro AI: nur die Abo-Seite und die
eigenen Daten zum Ansehen und Exportieren (nur lesen; Daten werden nie geloescht). Die iPad-App behaelt ihren
Free-Tarif unveraendert.

Welcher Client fragt (`client_type`), im Dienst:
- Anfrage mit Sitzungs-Cookie, ohne `Authorization` -> "web" (die Web-Oberflaeche nutzt nur das Cookie).
- `Authorization: Bearer ...` mit `X-StudiNow-Client: windows` bzw. `web` -> "windows" bzw. "web".
- jede andere Bearer-Anfrage -> "app" (iPad, Android): Vertrag unveraendert, Free bleibt Free.
Faelschen bringt keine zusaetzlichen Rechte: wer die Kopfzeile weglaesst oder "ipad" behauptet, bekommt genau die
Rechte seines Tarifs wie auf dem iPad (ohne Abo also Free, nie mehr). Die Pflicht entscheidet, ob ein Konto ohne Abo
noch schreiben darf; welche Rechte ein Tarif hat, entscheidet weiter allein app/plans.py mit dem Tarif aus der Datenbank.

Zustaende (`evaluate`): trial (Probe laeuft), active (Plus oder Pro AI, gleich ob App Store, Stripe oder Betrieb),
subscription_required (Konto ohne Abo an Web/Windows), free (App ohne Abo, wie bisher). Am eigenen PC kommen
signed_out (kein Token) und unverified (Abo seit mehr als der Kulanzzeit nicht geprueft) dazu (app/account_mode.py).
Gesperrt heisst: Lesen (GET) bleibt erlaubt, Schreiben nur fuer Konto, Abo und Abmelden (`write_allowed_when_locked`).
Konten mit Rolle admin (Betrieb, Moderation) sind von der Pflicht ausgenommen.
"""
from __future__ import annotations

from datetime import datetime, timezone

CLIENT_HEADER = "x-studinow-client"
GATED_CLIENTS = ("web", "windows")

# Schreibende Anfragen, die auch ohne Abo gehen: Konto (Abmelden, Passwort, Loeschen, Hochschule), Abo abschliessen
# und verwalten, Uebergabe der Anmeldung an die Windows-App
LOCKED_WRITE_PREFIXES = ("/api/account/", "/api/billing/", "/api/app-login/")

MESSAGES = {
    "signed_out": "Bitte melde dich mit deinem StudiNow-Konto an.",
    "subscription_required": "Ohne aktives Abo kannst du deine Daten nur ansehen und exportieren. Wähle StudiNow Plus "
                             "oder Pro AI, um weiterzumachen – deine Daten bleiben in jedem Fall erhalten.",
    "unverified": "Dein Abo konnte seit mehr als {days} Tagen nicht geprüft werden. Verbinde den PC kurz mit dem "
                  "Internet; bis dahin kannst du deine Daten nur ansehen und exportieren.",
}
BLOCKED = {
    "signed_out": (401, "account_required", "Bitte melde dich mit deinem StudiNow-Konto an."),
    "subscription_required": (402, "subscription_required", "Dafür brauchst du ein aktives Abo (StudiNow Plus oder Pro AI). "
                                                            "Deine Daten kannst du weiter ansehen und exportieren."),
    "unverified": (402, "subscription_unverified", "Dein Abo konnte länger nicht geprüft werden. Bitte verbinde den PC "
                                                    "mit dem Internet; deine Daten kannst du weiter ansehen und exportieren."),
}


def client_type(request) -> str:
    """web | windows | app (siehe Kopf). Ohne Bearer-Token gilt die Anfrage als Browser."""
    headers = getattr(request, "headers", {}) or {}
    auth = (headers.get("authorization") or "").strip()
    if not auth.lower().startswith("bearer "):
        return "web"
    claimed = (headers.get(CLIENT_HEADER) or "").strip().lower()
    return claimed if claimed in GATED_CLIENTS else "app"


def _days_left(ends_at: str | None, now: datetime) -> int:
    if not ends_at:
        return 0
    try:
        ends = datetime.fromisoformat(str(ends_at).replace("Z", "+00:00"))
    except ValueError:
        return 0
    if ends.tzinfo is None:
        ends = ends.replace(tzinfo=timezone.utc)
    left = (ends - now).total_seconds()
    return int((left + 86399) // 86400) if left > 0 else 0


def evaluate(plan: str | None, source: str | None, trial: dict | None, client: str, role: str | None = None,
             now: datetime | None = None) -> dict:
    """Zustand der Abo-Pflicht aus Tarif, Quelle und Probe (Antwort von billing.status bzw. GET /api/entitlements)."""
    t = now or datetime.now(timezone.utc)
    required = client in GATED_CLIENTS
    gated = required and role != "admin"
    tr = trial or {}
    plan = plan or "free"
    days = None
    if plan != "free" and source == "trial":
        days = _days_left(tr.get("ends_at"), t)
        state = "trial" if days > 0 else ("subscription_required" if gated else "free")
    elif plan != "free":
        state = "active"
    else:
        state = "subscription_required" if gated else "free"
    locked = state == "subscription_required"
    return {"client": client, "account_required": required, "state": state, "locked": locked, "read_only": locked,
            "trial_days_left": days if state == "trial" else None,
            "trial_ends_at": tr.get("ends_at") if state == "trial" else None,
            "message": MESSAGES.get(state)}


def write_allowed_when_locked(method: str, path: str, extra: tuple[str, ...] = ()) -> bool:
    """Darf eine Anfrage trotz Sperre durch? Lesen immer; Schreiben nur Konto, Abo, Anmeldung (und `extra`)."""
    if method.upper() in ("GET", "HEAD", "OPTIONS"):
        return True
    return path.startswith(LOCKED_WRITE_PREFIXES + tuple(extra))


def blocked(state: str) -> tuple[int, dict]:
    """HTTP-Status und Koerper fuer eine gesperrte Anfrage."""
    status, code, detail = BLOCKED.get(state, BLOCKED["subscription_required"])
    return status, {"detail": detail, "code": code, "access_state": state}


def for_user(user: dict, client: str) -> dict:
    """Zustand fuer ein Konto im Dienst (liest Tarif und Probe aus accounts.db)."""
    from . import billing
    t = datetime.now(timezone.utc)
    legacy = {"plan": user.get("plan"), "plan_until": user.get("plan_until")}
    conn = billing.connect()
    try:
        plan = billing.current_plan(conn, user["id"], t, legacy)
        tr = billing.trial_info(conn, user["id"], t)
        paid = billing._paid_plan(billing.entitlement_rows(conn, user["id"]), legacy, t)
    finally:
        conn.close()
    return evaluate(plan, source_kind(plan, paid), tr, client, user.get("role"), t)


def source_kind(plan: str | None, paid_plan: str | None) -> str | None:
    """"trial", wenn nur die Probe den Tarif traegt; "paid" bei einem bezahlten Tarif; None ohne Tarif."""
    if not plan or plan == "free":
        return None
    return "paid" if paid_plan and paid_plan != "free" else "trial"


def for_status(status: dict, client: str, role: str | None = None) -> dict:
    """Zustand aus einer Antwort von billing.status (GET /api/entitlements)."""
    return evaluate(status.get("plan"), source_kind(status.get("plan"), status.get("paid_plan")), status.get("trial"), client, role)
