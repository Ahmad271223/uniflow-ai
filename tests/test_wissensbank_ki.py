"""StudiNow-Wissensbank, Erweiterungen vom 21.11.2026 (Auftrag des Inhabers):
C. Vorab-Frage `POST /api/ai/wissensbank` (die App fragt VOR ihrem Erklaerungsspeicher), Vorrang vor dem Zwischenspeicher.

Die Bibliothek ist das kleine, ERFUNDENE Beispiel aus tests/fixtures/wissensbank (siehe tests/test_wissensbank.py)."""
import json
import uuid

from conftest import asgi_call
from test_subscriptions import _j, hosted, user  # noqa: F401 (Fixtures)
from test_wissensbank import FOLIEN, K_S2, K_S3, S2, S3, ask, ledger, wb  # noqa: F401 (Fixtures)

ANDERER_TEXT = ("Die Photosynthese wandelt Lichtenergie in chemische Energie um. Dabei entstehen aus Kohlendioxid und Wasser "
                "Traubenzucker und Sauerstoff; der Vorgang findet in den Chloroplasten der Pflanzenzellen statt.")


def vorab(app, headers, *, mode="explain", text=S2, datei=FOLIEN, seite=2, rid=None, wb_extra=None, **extra):
    body = {"mode": mode, "request_id": rid or uuid.uuid4().hex,
            "wissensbank": {"datei": datei, "kurs": "", "seite": seite, "text": text, **(wb_extra or {})}, **extra}
    return _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=headers, body=json.dumps(body)))


def quota_used(app, headers, feature="ai_assist"):
    d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))[1]
    return d["quotas"][feature]["used"]


# ================================================================== C. Vorab-Frage

def test_vorab_hit_delivers_like_the_relay_and_costs_one_credit(wb):
    app, fake = wb
    u, h = user(app, "vorab1@beispiel.de", plan="pro_ai")
    rid = uuid.uuid4().hex
    st, d = vorab(app, h, rid=rid)
    assert st == 200 and d["treffer"] is True, d
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_S2 and "ERKLAERUNG-SEITE-2" in d["answer"]
    assert d["wissensbank"] == {"badge": "Aus der StudiNow-Wissensbank", "status": "", "hinweise": []}
    assert d["task"] == "tutor:explain" and d["model"] == "wissensbank" and d["shared"] is False and d["replay"] is False
    assert d["credits"]["charged"] == 1 and d["credits"]["remaining"] == 99 and fake.calls == 0
    assert ledger(u["id"]) == [("tutor:wissensbank", 1, 0, "wissensbank")]
    assert quota_used(app, h) == 1, "zaehlt im Kontingent wie eine KI-Anfrage"
    # dieselbe Antwort wie ueber /api/ai/relay (bis auf `treffer`)
    u2, h2 = user(app, "vorab1b@beispiel.de", plan="pro_ai")
    _, r = ask(app, h2)
    assert {k: v for k, v in d.items() if k not in ("treffer", "credits")} == {k: v for k, v in r.items() if k != "credits"}
    # dieselbe request_id noch einmal (Netzfehler): dieselbe Antwort, nichts neu berechnet
    st, d2 = vorab(app, h, rid=rid)
    assert st == 200 and d2["treffer"] is True and d2["replay"] is True and d2["answer"] == d["answer"]
    assert d2["source"] == "wissensbank" and d2["wissensbank_key"] == K_S2 and d2["credits"]["charged"] == 0
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1 and fake.calls == 0


def test_vorab_without_hit_costs_nothing_and_never_calls_the_ai(wb):
    app, fake = wb
    u, h = user(app, "vorab2@beispiel.de", plan="pro_ai")
    st, d = vorab(app, h, text=ANDERER_TEXT)
    assert (st, d) == (200, {"treffer": False, "grund": "kein_treffer", "task": "tutor:explain"})
    st, d = vorab(app, h, text="   ")
    assert (st, d["treffer"], d["grund"]) == (200, False, "keine_angaben")
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps({"mode": "steps", "request_id": "x1"})))
    assert (st, d["treffer"], d["grund"], d["task"]) == (200, False, "keine_angaben", "tutor:steps")
    assert ledger(u["id"]) == [] and quota_used(app, h) == 0 and fake.calls == 0
    # schon geliefert: die Vorab-Frage liefert die Stelle demselben Konto kein zweites Mal
    assert vorab(app, h)[1]["treffer"] is True
    st, d = vorab(app, h, text="Neue Folie davor\n" + S2, seite=3)
    assert (st, d) == (200, {"treffer": False, "grund": "schon_geliefert", "task": "tutor:explain"})
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1 and fake.calls == 0
    # ueber /api/ai/relay kommt dann wie bisher die KI mit der Ja/Nein-Frage
    st, d = ask(app, h, text="Neue Folie davor\n" + S2, seite=3)
    assert d["source"] == "ki" and d["feedback_token"] and fake.calls == 1


def test_vorab_only_for_entitled_accounts_and_only_with_the_switch(wb, monkeypatch):
    app, fake = wb
    for email, kw in (("vorab-hi@beispiel.de", dict(plan="pro_ai", uni="hildesheim")), ("vorab-plus@beispiel.de", dict(plan="plus")),
                      ("vorab-frei@beispiel.de", dict()), ("vorab-unbest@beispiel.de", dict(plan="pro_ai", verified=False))):
        u, h = user(app, email, **kw)
        st, d = vorab(app, h)
        assert (st, d) == (200, {"treffer": False, "grund": "nicht_berechtigt", "task": "tutor:explain"}), email
        assert ledger(u["id"]) == []
    u, h = user(app, "vorab-luh@beispiel.de", plan="pro_ai")
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "0")
    assert vorab(app, h)[1] == {"treffer": False, "grund": "nicht_berechtigt", "task": "tutor:explain"}
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "1")
    assert vorab(app, h)[1]["treffer"] is True and fake.calls == 0


def test_vorab_errors_like_the_relay(wb):
    app, _ = wb
    _u, h = user(app, "vorab-fehler@beispiel.de", plan="pro_ai")
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", body=json.dumps({"mode": "explain", "wissensbank": {"text": S2}})))
    assert st == 401
    for body in ({"mode": "ask"}, {"task": "tutor:summary"}, {"task": "week_test"}, {}):
        st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps({**body, "wissensbank": {"text": S2, "datei": FOLIEN}})))
        assert (st, d["code"]) == (400, "task_unknown"), body
    # `task` wie in /api/ai/relay geht auch
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(
        {"task": "tutor:explain", "request_id": "r-task", "wissensbank": {"text": S2, "datei": FOLIEN, "seite": 2}})))
    assert st == 200 and d["treffer"] is True


def test_vorab_no_credits_quota_or_rate_is_an_empty_answer(wb, monkeypatch):
    from app import plans
    app, fake = wb
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "1")
    u, h = user(app, "vorab-rate@beispiel.de", plan="pro_ai")
    assert vorab(app, h)[1]["treffer"] is True
    st, d = vorab(app, h, text=S3, seite=3)
    assert (st, d["treffer"], d["grund"]) == (200, False, "rate")
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1, "Kontingent zurueckgegeben"
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "500")
    monkeypatch.setitem(plans.QUOTAS, "pro_ai", {**plans.QUOTAS["pro_ai"], "ai_assist": 1})
    st, d = vorab(app, h, text=S3, seite=3)
    assert (st, d["treffer"], d["grund"]) == (200, False, "kontingent") and len(ledger(u["id"])) == 1
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "0")
    u2, h2 = user(app, "vorab-leer@beispiel.de", plan="pro_ai")
    st, d = vorab(app, h2)
    assert (st, d["treffer"], d["grund"]) == (200, False, "credits") and fake.calls == 0 and quota_used(app, h2) == 0


def test_vorab_takes_ausschnitt_from_the_wissensbank_fields(wb):
    """Hier gibt es kein Bild: ob der Text nur ein Ausschnitt ist, sagt allein das Feld `wissensbank.ausschnitt`."""
    app, _ = wb
    from test_wissensbank import KURS_STATIK, S2_HALB
    _u, h = user(app, "vorab-teil@beispiel.de", plan="pro_ai")
    kw = dict(text=S2_HALB, datei="Statik_Folien_neu_v2.pdf")
    body = {"mode": "explain", "request_id": uuid.uuid4().hex, "wissensbank": {"datei": kw["datei"], "kurs": KURS_STATIK, "seite": 2, "text": S2_HALB}}
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(body)))
    assert d["treffer"] is False and d["grund"] == "kein_treffer"
    body["wissensbank"]["ausschnitt"] = True
    body["request_id"] = uuid.uuid4().hex
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(body)))
    assert d["treffer"] is True and d["wissensbank_key"] == K_S2


def test_relay_prefers_the_wissensbank_over_the_shared_cache(wb):
    """Im Zwischenspeicher des Dienstes liegt zur selben Anfrage schon eine KI-Antwort (0 Credits fuer alle). Ein Konto
    mit Wissensbank bekommt trotzdem die Stelle aus der Wissensbank; nur dieselbe request_id bleibt eine Wiederholung."""
    app, fake = wb
    _u, h_hi = user(app, "cache-hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    st, d = ask(app, h_hi, cache=True)
    assert st == 200 and d["source"] == "ki" and d["shared"] is False and fake.calls == 1
    st, d = ask(app, h_hi, cache=True)
    assert d["shared"] is True and d["credits"]["charged"] == 0 and fake.calls == 1, "der Zwischenspeicher ist gefuellt"
    u, h = user(app, "cache-luh@beispiel.de", plan="pro_ai")
    rid = uuid.uuid4().hex
    st, d = ask(app, h, cache=True, rid=rid)
    assert d["source"] == "wissensbank" and d["shared"] is False and d["wissensbank_key"] == K_S2 and fake.calls == 1
    assert ledger(u["id"]) == [("tutor:wissensbank", 1, 0, "wissensbank")]
    st, d = ask(app, h, cache=True, rid=rid)
    assert d["replay"] is True and d["source"] == "wissensbank" and len(ledger(u["id"])) == 1
