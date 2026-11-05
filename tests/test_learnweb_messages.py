"""Uni Hildesheim: Learnweb-Nachrichten lesen und beantworten, LSF-Wartungshinweis (app/learnweb_messages.py, app/lsf.py;
docs/HILDESHEIM-STAND-2026-11-05.md). Ohne Netz: das Learnweb ist nachgebildet, alle Daten
erfunden. Dieselben Faelle prueft der Swift-Kern (packages/shared-contracts/fixtures/learnweb/messages-cases.json)."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "packages/shared-contracts/fixtures/learnweb/messages-cases.json").read_text())
BASE = CASES["base"]


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-learnweb-messages-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_conversations_like_the_shared_cases():
    from app import learnweb_messages as lm
    got = lm.parse_conversations(CASES["conversations"]["input"], CASES["me"], BASE, date(2026, 11, 5))
    assert got == CASES["conversations"]["expected"]
    ids = [m["id"] for m in got]
    assert ids == ["lw-msg-13-399", "lw-msg-12-345"], "eigene Notizen, nur eigene Nachrichten und leere fehlen"
    assert "Erika" not in json.dumps(got) and "Max" not in json.dumps(got), "keine Personennamen gespeichert"
    assert got[1]["dates"] == [{"date": "2026-11-12", "time": "14:00", "kind": "ausfall"}]


def test_contexts_pages_ids_and_errors():
    from app import learnweb_messages as lm
    for c in CASES["contexts"]:
        assert lm.reply_context(c["input"], CASES["me"]) == c["expected"], c["name"]
    assert lm.reply_context(CASES["contexts"][0]["input"], CASES["me"])["recipients"] == [{"id": 815, "name": "Erika Beispiel (erfunden)"}]
    for p in CASES["pages"]:
        assert lm.user_id_from_page(p["html"]) == p["user"] and lm.sesskey_from_page(p["html"]) == p["sesskey"]
    for x in CASES["local_ids"]:
        assert lm.conversation_of(x["id"]) == x["conversation"]
    assert lm.flatten(lm.send_args(12, "Danke!\nBis dann")) == CASES["send_args"]["flat"]
    assert lm.send_args(12, "x")["messages"][0]["textformat"] == 2
    for e in CASES["errors"]:
        assert lm.error_for(e["code"]).code == e["expected"]
    with pytest.raises(lm.MessageError):
        lm.reply_context({}, 1)


# ---------------------------------------------------------------- Learnweb-Nachbildung (Sitzung mit Cookies)

class FakeLearnweb:
    def __init__(self):
        self.calls = []
        self.login = False
        self.send_error = None

    def __call__(self, url, data, headers):
        self.calls.append((url, data, headers))
        assert "MoodleSession=" in headers.get("Cookie", "")
        if self.login:
            return 200, b"<html>CAS</html>", "https://www.uni-hildesheim.de/sso/login?service=x"
        if url.endswith("/my/"):
            return 200, b'<script>M.cfg = {"sesskey":"KEY1","userId":4711};</script>', url
        assert "sesskey=KEY1" in url
        req = json.loads(data)[0]
        fn = req["methodname"]
        if fn == "core_message_get_conversation":
            assert req["args"]["conversationid"] == 12 and req["args"]["userid"] == 4711
            return 200, json.dumps([{"error": False, "data": CASES["contexts"][0]["input"]}]).encode(), url
        if fn == "core_message_send_messages_to_conversation":
            if self.send_error:
                return 200, json.dumps([{"error": True, "exception": {"errorcode": self.send_error}}]).encode(), url
            return 200, json.dumps([{"error": False, "data": [{"id": 999, "useridfrom": 4711}]}]).encode(), url
        return 200, json.dumps([{"error": True, "exception": {"errorcode": "unbekannt"}}]).encode(), url

    def sends(self):
        return [json.loads(d)[0] for (u, d, _) in self.calls if d and b"send_messages" in d]


@pytest.fixture
def learnweb(app, monkeypatch, tmp_path):
    from app import db, learnweb_messages as lm, studip_extras, studip_messages, studip_reply
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "lw.db")
    db.init_db()
    monkeypatch.setattr(studip_messages, "learnweb_offered", lambda: True)
    monkeypatch.setattr(studip_messages, "learnweb_connected", lambda: True)
    fake = FakeLearnweb()
    monkeypatch.setattr(studip_reply, "_learnweb_session", lambda: lm.LiveSession(BASE, "MoodleSession=s1", http=fake))
    items = lm.parse_conversations(CASES["conversations"]["input"], CASES["me"], BASE, date(2026, 11, 5))
    with db.cursor() as conn:
        lm.store(conn, items, "2026-11-05T10:00:00+00:00")
    return fake


def test_list_shows_learnweb_messages_without_names(app, learnweb):
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert st == 200 and d["available"] is True and d["source"] == "learnweb"
    m = next(x for x in d["messages"] if x["id"] == "lw-msg-12-345")
    assert m["sender"] == "Learnweb-Kontakt" and m["reply_url"].endswith("/message/index.php?convid=12") and m["source"] == "learnweb"
    assert "Erika" not in json.dumps(d)


def test_reply_context_and_send_once(app, learnweb):
    from app import db, studip_reply
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages/lw-msg-12-345/reply"))
    assert st == 200 and d["source"] == "learnweb" and d["sender"]["name"] == "Erika Beispiel (erfunden)" and d["no_subject"] is True
    assert d["allows_reply_all"] is False and d["web_url"].endswith("convid=12")
    assert d["quote"].startswith("Am 05.11.2026 um 10:00 Erika Beispiel (erfunden) schrieb:")
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/lw-msg-12-345/reply", body=json.dumps({"text": "Danke!", "quote": True})))
    assert st == 200 and d["sent"] is True and d["record"]["sent_id"] == "999"
    (sent,) = learnweb.sends()
    assert sent["args"]["conversationid"] == 12
    assert sent["args"]["messages"][0]["text"].startswith("Danke!\n\nAm 05.11.2026 um 10:00 Erika Beispiel (erfunden) schrieb:\n> Hallo")
    assert all(b"get_conversations" not in (c[1] or b"") for c in learnweb.calls), "nichts als gelesen markiert, nur die eine Unterhaltung"
    with db.cursor() as conn:
        dump = conn.execute("SELECT value FROM settings WHERE key='studip_replies'").fetchone()[0]
    assert "Erika" not in dump, "Verlauf ohne Namen"
    with db.cursor() as conn:
        assert studip_reply.replies(conn)[0]["message_id"] == "lw-msg-12-345"


def test_reply_errors_offer_the_learnweb(app, learnweb):
    learnweb.send_error = "usercantbemessaged"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/lw-msg-12-345/reply", body=json.dumps({"text": "x"})))
    assert st == 409 and d["code"] == "reply_not_allowed" and d["web_url"].endswith("convid=12")
    assert len(learnweb.sends()) == 1, "genau ein Versuch"
    learnweb.login = True
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages/lw-msg-12-345/reply"))
    assert st == 409 and d["code"] == "learnweb_login"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/lw-msg-12-345/reply", body=json.dumps({"text": "  "})))
    assert st == 400


def test_sync_messages_reads_only(monkeypatch, tmp_path):
    from app import db, hildesheim
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "s.db")
    db.init_db()
    calls = []

    class Client:
        base = BASE

        def ajax(self, fn, args):
            calls.append(fn)
            return CASES["conversations"]["input"]

    class Page:
        def evaluate(self, js):
            return 4711

    assert hildesheim.sync_messages(Client(), Page(), used_token=False) == "Nachrichten: 2"
    assert calls == ["core_message_get_conversations"]
    with db.cursor() as conn:
        assert {r[0] for r in conn.execute("SELECT id FROM studip_messages")} == {"lw-msg-12-345", "lw-msg-13-399"}

    class TokenClient:
        base = BASE

        def call(self, fn, **params):
            calls.append((fn, params))
            return {"userid": 4711} if fn == "core_webservice_get_site_info" else {"conversations": []}

    assert hildesheim.sync_messages(TokenClient(), None, used_token=True) == "Nachrichten: 0"
    assert calls[-1] == ("core_message_get_conversations", {"userid": "4711", "limitfrom": "0", "limitnum": "50", "mergeself": "0"})


# ---------------------------------------------------------------- LSF-Wartungshinweis

NOTICE_PAGE = ('<div class="hidden">Wenn Sie diesen Text sehen, ist noch nicht das neue Layout geladen</div>'
               '<div id="kopf"><b>+++ Wegen Wartungsarbeiten steht PLuS/LSF/POS am Montag, 09.11.2026 voraussichtlich erst ab 09.30 '
               'zur Verf&uuml;gung +++</b></div><a href="rds?state=user&type=4&category=auth.logout">Abmelden</a>')


def test_lsf_maintenance_notice():
    from app import lsf
    assert lsf.maintenance_notice(NOTICE_PAGE) == ("Wegen Wartungsarbeiten steht PLuS/LSF/POS am Montag, 09.11.2026 voraussichtlich "
                                                   "erst ab 09.30 zur Verfügung")
    assert lsf.maintenance_notice("<p>Wenn Sie diesen Text sehen, ist noch nicht das neue Layout geladen</p>") is None
    assert lsf.maintenance_notice("<p>C++ und C+++ sind keine Hinweise</p>") is None
