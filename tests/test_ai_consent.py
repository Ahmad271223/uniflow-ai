"""Einwilligung vor der StudiNow-KI in Web und Windows (app/ai_consent.py, 06.11.2026, App Store 5.1.2(i) wie auf dem
iPad): ohne Zustimmung geht nichts an einen KI-Anbieter (Windows: nichts an /api/ai/* des Dienstes; Dienst-Web: kein
Aufruf in ai_backend.complete), 428 ai_consent_required mit den Texten des Hinweises, Zustimmung je Konto und Stand
des Textes, Widerruf fragt erneut. iPad und Windows (Bearer) fragen auf dem Geraet und werden im Dienst nicht geprueft."""
import json
import re
from pathlib import Path

import pytest
from conftest import asgi_call
from test_ai_relay import account, cheap_calls, link, pc, tutor  # noqa: F401 - pc ist eine Fixture
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def enforce(monkeypatch):
    from app import ai_consent
    monkeypatch.setattr(ai_consent, "ENFORCE", True)
    return ai_consent


def consent(app, method="GET", body=None, headers=None):
    return _j(asgi_call(app, method, "/api/ai/consent", headers=headers, body=json.dumps(body) if body is not None else None))


# ---------------------------------------------------------------- Windows-App (eigener PC)

def test_pc_sends_nothing_to_the_service_ai_without_consent(pc, monkeypatch, enforce):
    app, calls, fake = pc
    cheap_calls(monkeypatch)
    account(app, "zustimmung@beispiel.de")
    link(app, "zustimmung@beispiel.de")
    st, d = tutor(app, mode="ask", page_text="Folge a_n = 1/n", question="Warum 0?")
    assert (st, d["code"]) == (428, "ai_consent_required"), d
    assert d["version"] == enforce.VERSION and d["consent"]["title"] == "KI-Hilfe: Was wird gesendet?"
    assert "OpenAI" in " ".join(d["consent"]["recipients"]) and "Amazon Bedrock" in " ".join(d["consent"]["recipients"])
    assert fake.calls == 0 and not [c for c in calls if c[1].startswith("/api/ai/")], "nichts ging an die KI des Dienstes"

    st, s = consent(app)
    assert (st, s["granted"], s["version"]) == (200, False, enforce.VERSION)
    st, s = consent(app, "POST", {"version": "alter-text"})
    assert (st, s["code"]) == (409, "consent_outdated"), "Zustimmung nur zum aktuellen Text"
    st, s = consent(app, "POST", {"version": enforce.VERSION})
    assert st == 200 and s["granted"] is True and s["granted_at"]

    st, d = tutor(app, mode="ask", page_text="Folge a_n = 1/n", question="Warum 0?")
    assert st == 200, d
    assert fake.calls == 1 and ("POST", "/api/ai/relay") in calls

    st, s = consent(app, "DELETE")
    assert (st, s["granted"]) == (200, False)
    st, d = tutor(app, mode="ask", page_text="Folge a_n = 1/n", question="Noch einmal?")
    assert (st, d["code"]) == (428, "ai_consent_required"), "nach dem Widerruf wieder gefragt"
    assert fake.calls == 1


def test_pc_consent_belongs_to_the_linked_account_and_the_text_version(pc, monkeypatch, enforce):
    app, _, fake = pc
    cheap_calls(monkeypatch)
    account(app, "eins@beispiel.de")
    link(app, "eins@beispiel.de")
    assert consent(app, "POST", {"version": enforce.VERSION})[1]["granted"] is True
    assert tutor(app, mode="ask", page_text="Seite", question="Was?")[0] == 200
    account(app, "zwei@beispiel.de")
    link(app, "zwei@beispiel.de")
    st, d = tutor(app, mode="ask", page_text="Seite", question="Was?")
    assert (st, d["code"]) == (428, "ai_consent_required"), "anderes Konto: neue Frage"
    assert consent(app)[1]["granted"] is False
    # Einstellungen schreiben die Einwilligung nicht an /api/ai/consent vorbei
    st, _ = _j(asgi_call(app, "PUT", "/api/settings", body=json.dumps({"ai_consent": json.dumps({"version": enforce.VERSION, "account": "x"})})))
    assert st == 200 and consent(app)[1]["granted"] is False
    consent(app, "POST", {"version": enforce.VERSION})
    monkeypatch.setattr(enforce, "VERSION", "2099-01-01")
    assert consent(app)[1]["granted"] is False, "neuer Text: neue Frage"
    assert fake.calls == 1


# ---------------------------------------------------------------- Dienst

def test_service_web_ui_needs_consent_but_ipad_and_windows_ask_on_the_device(hosted, monkeypatch, enforce):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, bearer = user(hosted, "web@beispiel.de", plan="pro_ai")
    web = {**bearer, "X-StudiNow-Client": "web"}
    body = json.dumps({"mode": "explain", "page_text": "Matrizen", "request_id": "w1"})
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=web, body=body))
    assert (st, d["code"]) == (428, "ai_consent_required"), d
    assert fake.calls == 0, "kein Anbieter ohne Einwilligung"
    # iPad (Bearer ohne Client-Kopfzeile) und Windows fragen selbst: hier nicht noch einmal
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=bearer, body=json.dumps({"mode": "explain", "page_text": "Matrizen", "request_id": "a1"})))
    assert st == 200, d
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/relay", headers={**bearer, "X-StudiNow-Client": "windows"},
                         body=json.dumps({"task": "tutor:explain", "prompt": "Erkläre Matrizen", "request_id": "r1"})))
    assert st == 200, d
    calls = fake.calls
    st, s = consent(hosted, "POST", {"version": enforce.VERSION}, headers=web)
    assert st == 200 and s["granted"] is True
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=web, body=json.dumps({"mode": "explain", "page_text": "Determinanten", "request_id": "w2"})))
    assert st == 200, d
    assert fake.calls == calls + 1
    # je Konto: ein anderes Konto im Web wird wieder gefragt
    _, other = user(hosted, "web2@beispiel.de", plan="pro_ai")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers={**other, "X-StudiNow-Client": "web"}, body=body))
    assert (st, d["code"]) == (428, "ai_consent_required")
    st, s = consent(hosted, "DELETE", headers=web)
    assert s["granted"] is False
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=web, body=json.dumps({"mode": "explain", "page_text": "Eigenwerte", "request_id": "w3"})))
    assert st == 428


# ---------------------------------------------------------------- Texte, iPad, Manifest

def test_texts_match_the_ipad_and_name_what_and_whom():
    from app import ai_consent
    swift = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AI/AIConsent.swift").read_text(encoding="utf-8")
    assert f'public static let version = "{ai_consent.VERSION}"' in swift, "gleicher Stand wie auf dem iPad"
    for key in ("title", "intro", "never", "service", "processors", "accept", "cancel", "privacy_link", "revoke_button"):
        assert json.dumps(ai_consent.TEXT[key], ensure_ascii=False) in swift, key
    for line in ai_consent.TEXT["what"] + ai_consent.TEXT["recipients"]:
        assert json.dumps(line, ensure_ascii=False) in swift, line
    assert "DeepSeek" not in json.dumps(ai_consent.TEXT, ensure_ascii=False), "DeepSeek ist aus"


def test_privacy_manifest_matches_the_app_store_privacy_section():
    import plistlib
    m = plistlib.loads((ROOT / "apps/apple/UniFlow/PrivacyInfo.xcprivacy").read_bytes())
    assert m["NSPrivacyTracking"] is False and m["NSPrivacyTrackingDomains"] == []
    kinds = {t["NSPrivacyCollectedDataType"]: t for t in m["NSPrivacyCollectedDataTypes"]}
    # Geraete-ID seit Audit P46-04 (08.11.2026): die zufaellige Installationskennung geht als device_id an den Dienst
    assert set(kinds) == {"NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeUserID",
                          "NSPrivacyCollectedDataTypeDeviceID", "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeOtherUserContent",
                          "NSPrivacyCollectedDataTypeProductInteraction"}
    for t in kinds.values():
        assert t["NSPrivacyCollectedDataTypeLinked"] is True and t["NSPrivacyCollectedDataTypeTracking"] is False
        assert t["NSPrivacyCollectedDataTypePurposes"] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
    reasons = {a["NSPrivacyAccessedAPIType"]: set(a["NSPrivacyAccessedAPITypeReasons"]) for a in m["NSPrivacyAccessedAPITypes"]}
    assert reasons == {"NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
                       "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
                       "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
                       "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"}}
    # dieselben sechs Zeilen stehen im Abschnitt App-Datenschutz (erfasst, verknuepft, kein Tracking)
    store = (ROOT / "docs/release/APP-STORE.md").read_text(encoding="utf-8")
    section = store.split("## App-Datenschutz", 1)[1].split("\n## ", 1)[0]
    for label in ("E-Mail-Adresse", "Nutzer-ID", "Geräte-ID", "Kaufverlauf", "Andere Nutzerinhalte", "Produktinteraktion"):
        assert re.search(rf"\| [^|\n]*{label} \| ja \| ja \| nein \| App-Funktionalität \|", section), label
    # keine weiteren Required-Reason-APIs im Code als die erklaerten
    code = "\n".join(p.read_text(encoding="utf-8") for base in ("apps/apple/UniFlow", "apps/apple/Packages/UniFlowCore/Sources")
                     for p in (ROOT / base).rglob("*.swift"))
    for api in ("systemUptime", "mach_absolute_time", "activeInputModes", "volumeTotalCapacity", "systemFreeSize"):
        assert api not in code, api
