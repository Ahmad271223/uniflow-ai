"""Formelblaetter (app/formelblatt.py, Auftrag des Inhabers 22.11.2026): mit Pro AI zum passenden Modul einmal fuer
feste Credits kaufen, danach jederzeit laden; andere Hochschule, anderes Modul oder ohne Pro AI: nichts."""
import json
import shutil

import pytest
from conftest import asgi_call
from test_subscriptions import _j, ent, hosted, user  # noqa: F401

PDF = b"%PDF-1.4 Formelblatt\n%%EOF\n"


@pytest.fixture
def katalog():
    from app import formelblatt
    d = formelblatt.base_dir()
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    (d / "luh-gds-kurzklausur.pdf").write_bytes(PDF)
    (d / "katalog.json").write_text(json.dumps({"stand": "2026-11-22", "blaetter": [
        {"id": "luh-gds-kurzklausur", "titel": "Formelblatt Kurzklausur", "hochschule": "luh",
         "module": ["Grundlagen digitaler Systeme"], "credits": 3, "datei": "luh-gds-kurzklausur.pdf", "seiten": 2,
         "fassung": "2026-11-22", "beschreibung": "Regeln, Rechenwege, gelöste Beispiele"},
        {"id": "kaputt", "titel": "ohne PDF", "hochschule": "luh", "module": ["Analysis"], "credits": 3, "datei": "fehlt.pdf"},
        {"id": "teuer", "titel": "zu teuer", "hochschule": "luh", "module": ["Analysis"], "credits": 500, "datei": "luh-gds-kurzklausur.pdf"},
    ]}), encoding="utf-8")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def call(app, method, path, h, body=None):
    st, _, b = asgi_call(app, method, path, headers=h, body=json.dumps(body) if body is not None else None)
    return st, b


def jcall(app, method, path, h, body=None):
    st, b = call(app, method, path, h, body)
    return st, (json.loads(b) if b else None)


def used(app, h):
    c = ent(app, h)["credits"]
    return c["used"]


def test_pro_ai_buys_once_for_three_credits_and_can_load_again(hosted, katalog):
    u, h = user(hosted, "fb-a@beispiel.de", plan="pro_ai")
    st, d = jcall(hosted, "POST", "/api/formelblatt/offer", h, {"modules": ["Mathe", "grundlagen  Digitaler-Systeme"]})
    assert st == 200 and [i["id"] for i in d["items"]] == ["luh-gds-kurzklausur"], d
    it = d["items"][0]
    assert it["credits"] == 3 and it["owned"] is False and it["module"] == "grundlagen  Digitaler-Systeme" and it["pages"] == 2

    # ohne Kauf kein PDF
    assert call(hosted, "GET", "/api/formelblatt/luh-gds-kurzklausur/pdf", h)[0] == 404

    st, d = jcall(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)
    assert st == 200 and d["credits_charged"] == 3 and d["item"]["owned"], d
    assert used(hosted, h) == 3
    st, b = call(hosted, "GET", "/api/formelblatt/luh-gds-kurzklausur/pdf", h)
    assert st == 200 and b == PDF

    # zweiter Kauf: nichts berechnet; Angebot zeigt "gekauft"
    st, d = jcall(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)
    assert st == 200 and d["credits_charged"] == 0 and used(hosted, h) == 3
    assert jcall(hosted, "POST", "/api/formelblatt/offer", h, {"modules": ["Grundlagen digitaler Systeme"]})[1]["items"][0]["owned"] is True

    # ein anderes Konto hat es nicht
    u2, h2 = user(hosted, "fb-b@beispiel.de", plan="pro_ai")
    assert call(hosted, "GET", "/api/formelblatt/luh-gds-kurzklausur/pdf", h2)[0] == 404


def test_only_matching_module_university_and_plan(hosted, katalog):
    u, h = user(hosted, "fb-modul@beispiel.de", plan="pro_ai")
    assert jcall(hosted, "POST", "/api/formelblatt/offer", h, {"modules": ["Analysis", "Lineare Algebra"]})[1] == {"items": []}, \
        "kaputte und zu teure Eintraege fallen weg, anderes Modul nichts"

    u, h = user(hosted, "fb-hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    assert jcall(hosted, "POST", "/api/formelblatt/offer", h, {"modules": ["Grundlagen digitaler Systeme"]})[1] == {"items": []}
    assert call(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)[0] == 404

    u, h = user(hosted, "fb-plus@beispiel.de", plan="plus")
    assert call(hosted, "POST", "/api/formelblatt/offer", h, {"modules": ["Grundlagen digitaler Systeme"]})[0] == 403
    assert call(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)[0] == 403

    u, h = user(hosted, "fb-pfad@beispiel.de", plan="pro_ai")
    assert call(hosted, "GET", "/api/formelblatt/..%2F..%2Fetc/pdf", h)[0] == 404
    assert call(hosted, "POST", "/api/formelblatt/offer", h, {"modules": "kein Array"})[0] == 422


def test_without_credits_nothing_is_bought(hosted, katalog):
    from app import credits
    u, h = user(hosted, "fb-leer@beispiel.de", plan="pro_ai")
    conn = credits.connect()
    try:                                       # Monats-Credits fast aufbrauchen: 2 bleiben, das Blatt kostet 3
        r = credits.reserve(conn, u["id"], "vorher", "tutor:ask", ent(hosted, h)["credits"]["remaining"] - 2)
        credits.settle(conn, u["id"], r.request_id, 0, fixed_credits=ent(hosted, h)["credits"]["reserved"])
    finally:
        conn.close()
    before = used(hosted, h)
    st, d = jcall(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)
    assert st == 429 and d["code"] == "credits_exhausted", d
    assert used(hosted, h) == before and ent(hosted, h)["credits"]["reserved"] == 0
    assert call(hosted, "GET", "/api/formelblatt/luh-gds-kurzklausur/pdf", h)[0] == 404


def test_account_export_and_delete_cover_purchases(hosted, katalog):
    from app import accounts, formelblatt
    u, h = user(hosted, "fb-export@beispiel.de", plan="pro_ai")
    assert jcall(hosted, "POST", "/api/formelblatt/luh-gds-kurzklausur/buy", h)[0] == 200
    assert [p["blatt"] for p in formelblatt.purchases(u["id"])] == ["luh-gds-kurzklausur"]
    with accounts.cursor() as conn:
        accounts._purge_user(conn, u["id"])
    assert formelblatt.purchases(u["id"]) == []
