"""Einwilligung vor der StudiNow-KI in Web und Windows (06.11.2026, wie auf dem iPad: App Store Review Guideline 5.1.2(i),
docs/release/DATENSCHUTZ.md Abschnitt 8c).

Bevor Seitentext, Bild eines Bereichs oder Frage zum ersten Mal an einen KI-Anbieter gehen, zeigt die Oberflaeche den
Hinweis "KI-Hilfe: Was wird gesendet?" (was, an wen, Link zur Datenschutzerklaerung) und braucht ein ausdrueckliches
"Zustimmen und fortfahren". Durchgesetzt wird das auf dem Server, nicht in einzelnen Ansichten:

- Windows-App (eigener PC, StudiNow-KI ueber das Konto): `ai_relay.service_json` schickt nichts an `/api/ai/*` des
  Dienstes ohne Einwilligung (`require_for_relay`, 428 `ai_consent_required`).
- Dienst, Web-Oberflaeche (Sitzungs-Cookie, `access.client_type` == "web"): `ai_backend.complete` ruft keinen Anbieter
  ohne Einwilligung des Kontos (`require_hosted`). iPad und Windows-App (Bearer) fragen auf dem Geraet selbst
  (iPad: AIConsentCenter, PC: wie oben) und werden hier nicht noch einmal geprueft.

Die Oberflaeche faengt 428 `ai_consent_required` an einer Stelle ab (static/ai-consent.js, Hilfe um `fetch`), zeigt
den Hinweis, speichert die Zustimmung mit `POST /api/ai/consent` und wiederholt die Anfrage einmal; "Abbrechen" laesst
den Fehler mit `DECLINED` stehen. Gespeichert wird in der vorhandenen Tabelle `settings` (Schluessel `ai_consent`, im
Dienst je Konto ohnehin getrennt, am PC mit der Konto-ID des verbundenen StudiNow-Kontos), mit dem Stand des Textes:
ein neuer `VERSION` fragt erneut. Widerruf: `DELETE /api/ai/consent` (Einstellungen → Erweitert → KI-Einwilligung).
"""
from __future__ import annotations

import contextvars
import json
from datetime import datetime, timezone

from fastapi import APIRouter, Body, HTTPException

from . import config, db

router = APIRouter(tags=["ai"])

# Stand des Textes; gleich AIConsentText.version (iPad, UniFlowCore/AI/AIConsent.swift)
VERSION = "2026-11-06"
CODE = "ai_consent_required"
SETTING = "ai_consent"
PRIVACY_URL = "https://studinow.app/datenschutz"
DECLINED = "Ohne deine Zustimmung sendet StudiNow nichts an die KI. Beim nächsten Versuch fragen wir dich erneut."
ASK = "Bitte stimme zuerst zu, dass StudiNow deine Anfrage an den KI-Anbieter senden darf."

# Texte wie auf dem iPad (AIConsentText); die Oberflaeche zeigt sie aus GET /api/ai/consent
TEXT = {
    "title": "KI-Hilfe: Was wird gesendet?",
    "intro": "Für die StudiNow-KI schickt StudiNow deine Anfrage an einen KI-Anbieter. Bevor das zum ersten Mal passiert, "
             "brauchen wir deine Zustimmung.",
    "what_heading": "Was gesendet wird",
    "what": [
        "der Text der Seite oder deiner Markierung, bei „Ganzes Dokument“ der Text der gewählten Seiten",
        "das Bild eines Bereichs, wenn du „Bereich an KI“ nutzt",
        "deine Frage oder Lösung, die Namen von Kurs und Datei und passende Stellen aus deinen Unterlagen",
        "für Karteikarten und Wochentests die Texte deiner Unterlagen",
    ],
    "never": "Nie gesendet werden dein Name, deine E-Mail-Adresse, deine Hochschul-Zugangsdaten und deine Noten.",
    "where_heading": "Wohin es geht",
    "service": "An den StudiNow-Dienst (app.studinow.app) von IT solutions by Ahmad Fakih. Er gibt jede Anfrage an einen "
               "dieser KI-Anbieter weiter:",
    "recipients": [
        "OpenAI (ChatGPT-Modelle, Verarbeitung in den USA)",
        "Anthropic Claude über Amazon Web Services (Amazon Bedrock, Frankfurt, Verarbeitung in der EU)",
    ],
    "processors": "Beide verarbeiten die Daten nur in unserem Auftrag (Auftragsverarbeitung nach Art. 28 DSGVO).",
    "revoke": "Du kannst die Einwilligung jederzeit widerrufen: Einstellungen → Erweitert → „KI-Einwilligung widerrufen“. "
              "Ohne Einwilligung sendet StudiNow nichts an die KI.",
    "privacy_url": PRIVACY_URL,
    "privacy_link": "Datenschutzerklärung (Abschnitt 8c)",
    "accept": "Zustimmen und fortfahren",
    "cancel": "Abbrechen",
    "revoke_button": "KI-Einwilligung widerrufen",
}

# Tests (tests/conftest.py) schalten die Pflicht fuer alle uebrigen Tests aus; tests/test_ai_consent.py prueft sie
ENFORCE = True

# Im Dienst: diese Anfrage kommt aus der Web-Oberflaeche (Cookie) -> ai_backend.complete prueft die Einwilligung
_WEB: contextvars.ContextVar[bool] = contextvars.ContextVar("ai_consent_web", default=False)


def mark_web(on: bool):
    """hosted_guard (app/server.py): Anfrage der Web-Oberflaeche markieren; Rueckgabe fuer `unmark`."""
    return _WEB.set(bool(on))


def unmark(token) -> None:
    _WEB.reset(token)


def account_key() -> str:
    """Konto der Einwilligung: im Dienst das angemeldete Konto, am PC das verbundene StudiNow-Konto ("pc" ohne)."""
    if config.is_hosted():
        return "konto:" + str(config.current_user_id() or "")
    try:
        from . import service_link
        uid = (service_link.load_state().get("user") or {}).get("id")
    except Exception:  # noqa: BLE001 - ohne Ablage: Einwilligung dieses PCs
        uid = None
    return "konto:" + str(uid) if uid else "pc"


def _stored() -> dict:
    with db.cursor() as conn:
        raw = db.get_settings(conn).get(SETTING)
    try:
        d = json.loads(raw) if isinstance(raw, str) and raw else {}
    except ValueError:
        d = {}
    return d if isinstance(d, dict) else {}


def granted() -> bool:
    d = _stored()
    return d.get("version") == VERSION and d.get("account") == account_key()


def status() -> dict:
    d = _stored()
    ok = d.get("version") == VERSION and d.get("account") == account_key()
    return {"granted": ok, "granted_at": d.get("at") if ok else None, "version": VERSION, "text": TEXT}


def grant(version: str | None = None) -> dict:
    if version is not None and version != VERSION:
        raise HTTPException(409, {"detail": "Der Hinweis hat sich geändert. Bitte lies ihn noch einmal.", "code": "consent_outdated",
                                  "version": VERSION})
    value = {"version": VERSION, "account": account_key(), "at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    with db.cursor() as conn:
        db.set_setting(conn, SETTING, json.dumps(value))
    return status()


def revoke() -> dict:
    with db.cursor() as conn:
        conn.execute("DELETE FROM settings WHERE key=?", (SETTING,))
    return status()


def required_fields() -> dict:
    """Zusatzfelder der 428-Antwort: Stand und Texte fuer den Hinweis"""
    return {"version": VERSION, "consent": TEXT}


def require_for_relay() -> None:
    """Windows-App: vor jeder Anfrage an /api/ai/* des Dienstes (ai_relay.service_json)."""
    if config.is_hosted() or not ENFORCE or granted():
        return
    from . import ai_relay
    raise ai_relay.RelayError(428, CODE, ASK, required_fields())


def require_hosted(library: bool = False) -> None:
    """Dienst, Web-Oberflaeche: vor jedem Aufruf eines KI-Anbieters (ai_backend.complete). Vorarbeit der Bibliothek
    (`library`, ohne Konto) und Anfragen von iPad/Windows (fragen selbst) bleiben unberuehrt."""
    if not config.is_hosted() or library or not ENFORCE or not _WEB.get() or granted():
        return
    from . import ai_backend
    raise ai_backend.AIUnavailable(CODE, ASK, 428, required_fields())


# ================================================================== Routen

@router.get("/api/ai/consent")
def get_consent():
    return status()


@router.post("/api/ai/consent")
def post_consent(body: dict = Body(default={})):
    v = body.get("version") if isinstance(body, dict) else None
    return grant(str(v) if v is not None else None)


@router.delete("/api/ai/consent")
def delete_consent():
    return revoke()
