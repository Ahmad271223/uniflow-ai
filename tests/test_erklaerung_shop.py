"""StudiNow-Erklärungen zum Kaufen (app/erklaerung_shop.py): je Kursdatei ein PDF, Preis in Credits, gekauft bleibt
gekauft (Auftrag des Inhabers vom 22.11.2026)."""
import json
import shutil

import pytest
from conftest import asgi_call
from test_subscriptions import _j, ent, hosted, user  # noqa: F401

SHA_VL, SHA_UB, SHA_NEU = "a" * 64, "b" * 64, "c" * 64
PDF = b"%PDF-1.4\n% StudiNow Probe\n%%EOF\n"


@pytest.fixture
def ablage(monkeypatch):
    from app import erklaerung_shop
    d = erklaerung_shop.directory()
    shutil.rmtree(d, ignore_errors=True)
    (d / "pdf" / "aa").mkdir(parents=True)
    (d / "pdf" / "bb").mkdir(parents=True)
    (d / "pdf" / "aa" / f"{SHA_VL}.pdf").write_bytes(PDF)
    (d / "pdf" / "bb" / f"{SHA_UB}.pdf").write_bytes(PDF + b"blatt")
    index = {SHA_VL: {"titel": "03A.pdf – Erklärung Seite für Seite", "art": "Erklärung Seite für Seite", "pdf_seiten": 3,
                      "pfad": f"pdf/aa/{SHA_VL}.pdf", "datei": "03A.pdf", "fach": "Mathe I", "stand": "2026-11-22 18:00"},
             SHA_UB: {"titel": "GÜ03.pdf – Lösung Schritt für Schritt", "art": "Lösung Schritt für Schritt", "pdf_seiten": 4,
                      "pfad": f"pdf/bb/{SHA_UB}.pdf"},
             "d" * 64: {"titel": "böse", "pfad": "../../accounts.db"}}
    (d / "index.json").write_text(json.dumps(index), encoding="utf-8")
    monkeypatch.setenv("LERNAPP_ERKLAERUNGEN", "1")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def jcall(app, method, path, h, body=None):
    st, _, b = asgi_call(app, method, path, headers=h, body=json.dumps(body) if body is not None else None)
    return st, (json.loads(b) if b and not b.startswith(b"%PDF") else b)


def code(d):
    return d.get("code") or (d.get("detail") or {}).get("code")


def used(app, h):
    return ent(app, h)["credits"]["used"]


def test_offer_buy_pdf_and_mine(hosted, ablage):
    ua, ha = user(hosted, "erkl-a@beispiel.de", plan="pro_ai")
    ub, hb = user(hosted, "erkl-b@beispiel.de", plan="pro_ai")

    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", ha, {"sha256": [SHA_VL, SHA_NEU, SHA_UB.upper(), "kaputt"]})
    assert st == 200 and d["enabled"] and d["price"] == 15, d
    assert [(i["sha256"], i["kind"], i["pages"], i["owned"]) for i in d["items"]] == \
        [(SHA_VL, "Erklärung Seite für Seite", 3, False), (SHA_UB, "Lösung Schritt für Schritt", 4, False)]
    assert "datei" not in json.dumps(d) and "fach" not in json.dumps(d), "keine Dateinamen oder Fächer nach außen"

    # ohne Kauf kein PDF
    st, d = jcall(hosted, "GET", f"/api/erklaerungen/{SHA_VL}/pdf", ha)
    assert st == 402 and code(d) == "not_owned"

    st, d = jcall(hosted, "POST", "/api/erklaerungen/buy", ha, {"sha256": SHA_VL})
    assert st == 200 and d["owned"] and d["charged"] == 15, d
    assert used(hosted, ha) == 15
    st, b = jcall(hosted, "GET", f"/api/erklaerungen/{SHA_VL}/pdf", ha)
    assert st == 200 and b == PDF

    # zweiter Kauf kostet nichts, das Angebot zeigt „gekauft“
    st, d = jcall(hosted, "POST", "/api/erklaerungen/buy", ha, {"sha256": SHA_VL})
    assert st == 200 and d["charged"] == 0 and used(hosted, ha) == 15
    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", ha, {"sha256": [SHA_VL, SHA_UB]})
    assert [i["owned"] for i in d["items"]] == [True, False]
    st, d = jcall(hosted, "GET", "/api/erklaerungen/mine", ha)
    assert st == 200 and [i["sha256"] for i in d["items"]] == [SHA_VL]

    # ein anderes Konto hat davon nichts
    assert jcall(hosted, "GET", f"/api/erklaerungen/{SHA_VL}/pdf", hb)[0] == 402
    assert jcall(hosted, "GET", "/api/erklaerungen/mine", hb)[1] == {"items": []}

    # gekauft bleibt gekauft, auch nach einer neuen Fassung des PDFs
    (ablage / "pdf" / "aa" / f"{SHA_VL}.pdf").write_bytes(PDF + b"neu")
    assert jcall(hosted, "GET", f"/api/erklaerungen/{SHA_VL}/pdf", ha)[1] == PDF + b"neu"


def test_unknown_and_unsafe_entries(hosted, ablage):
    u, h = user(hosted, "erkl-c@beispiel.de", plan="pro_ai")
    st, d = jcall(hosted, "POST", "/api/erklaerungen/buy", h, {"sha256": SHA_NEU})
    assert st == 404 and code(d) == "not_available" and used(hosted, h) == 0
    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", h, {"sha256": ["d" * 64]})
    assert d["items"] == [], "Eintrag mit Pfad außerhalb des Ordners wird nie angeboten"
    assert jcall(hosted, "POST", "/api/erklaerungen/buy", h, {"sha256": "d" * 64})[0] == 404
    assert jcall(hosted, "POST", "/api/erklaerungen/offer", h, {"sha256": ["a" * 64] * 2001})[0] == 422
    assert jcall(hosted, "POST", "/api/erklaerungen/buy", h, {"sha256": "../x"})[0] == 422


def test_only_pro_ai_and_switch(hosted, ablage, monkeypatch):
    u, h = user(hosted, "erkl-plus@beispiel.de", plan="plus")
    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", h, {"sha256": [SHA_VL]})
    assert st == 403 and code(d) == "plan_required"

    u, h = user(hosted, "erkl-aus@beispiel.de", plan="pro_ai")
    monkeypatch.setenv("LERNAPP_ERKLAERUNGEN", "0")
    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", h, {"sha256": [SHA_VL]})
    assert st == 200 and d["enabled"] is False and d["items"] == []
    assert jcall(hosted, "POST", "/api/erklaerungen/buy", h, {"sha256": SHA_VL})[0] == 404 and used(hosted, h) == 0


def test_price_and_credits_exhausted(hosted, ablage, monkeypatch):
    from app import accounts
    monkeypatch.setenv("LERNAPP_ERKLAERUNG_PREIS", "9000")
    u, h = user(hosted, "erkl-teuer@beispiel.de", plan="pro_ai")
    st, d = jcall(hosted, "POST", "/api/erklaerungen/offer", h, {"sha256": [SHA_VL]})
    assert d["price"] == 1000, "höchstens 1000 Credits"
    st, d = jcall(hosted, "POST", "/api/erklaerungen/buy", h, {"sha256": SHA_VL})
    assert st == 429 and code(d) == "credits_exhausted", d
    assert jcall(hosted, "GET", "/api/erklaerungen/mine", h)[1] == {"items": []}, "nichts gekauft"

    # Konto löschen: die Käufe sind weg
    monkeypatch.setenv("LERNAPP_ERKLAERUNG_PREIS", "15")
    u2, h2 = user(hosted, "erkl-weg@beispiel.de", plan="pro_ai")
    assert jcall(hosted, "POST", "/api/erklaerungen/buy", h2, {"sha256": SHA_UB})[0] == 200
    assert "erklaerung_kaeufe" in accounts.ACCOUNT_TABLES
