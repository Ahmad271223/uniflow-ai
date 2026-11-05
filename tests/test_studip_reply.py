"""Antworten auf Stud.IP-Nachrichten am PC (app/studip_reply.py, 05.11.2026, docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md):
Regeln wie StudIPMessageReply.swift, Kontext live aus dem Posteingang, Senden genau einmal, stille Erneuerung bei 401 mit
genau einem zweiten Versuch, Fehler mit Ausweg "In Stud.IP antworten", Entwurf und Verlauf ohne Namen. Stud.IP ist
ersetzt (studip_live._send), es gibt keine echte Anfrage."""
import json

import pytest
from conftest import asgi_call

ME, PROF, BOB = "me000", "prof01", "bob02"


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


# ---------------------------------------------------------------- Regeln

def test_rules_like_the_swift_core():
    from app import studip_reply as R
    assert R.reply_subject("Tutorium") == "RE: Tutorium"
    assert R.reply_subject("Re: Tutorium") == "Re: Tutorium" and R.reply_subject("AW: x") == "AW: x"
    assert R.reply_subject("(ohne Betreff)") == "RE: "
    q = R.quote("Hallo\n\nBlatt 3", "Prof. Test", "2026-11-02T07:15:00+00:00")
    assert q == "Am 02.11.2026 um 08:15 Prof. Test schrieb:\n> Hallo\n>\n> Blatt 3"
    assert R.body("  Danke!  ", q).startswith("Danke!\n\nAm 02.11.2026")
    p = R.payload("RE: x", "t", [PROF, PROF, "", BOB])
    assert p["data"]["relationships"]["recipients"]["data"] == [{"type": "users", "id": PROF}, {"type": "users", "id": BOB}]
    assert p["data"]["attributes"] == {"subject": "RE: x", "message": "t", "priority": "normal"}
    assert R.send_error(201, b"") is None
    assert R.send_error(403, b"Invalid CSRF token").code == "security_token"
    assert R.send_error(403, b"nope").code == "forbidden"
    assert R.send_error(422, b"").code == "rejected" and R.send_error(500, b"").code == "http"
    assert R.sent_id(None, b'{"data":{"id":"n1"}}') == "n1"
    assert R.sent_id("https://x/jsonapi.php/v1/messages/n2?x", b"") == "n2"
    assert R.offers_reply_all(3) and not R.offers_reply_all(1) and not R.offers_reply_all(None) and not R.offers_reply_all(22)
    assert R.is_replyable("Lehrende") and not R.is_replyable("Stud.IP") and not R.is_replyable("")
    meta = R.parse_message_meta([{"id": "a", "relationships": {"recipients": {"data": [{"id": ME}, {"id": BOB}, {"id": BOB}]}}},
                                 {"id": "b", "relationships": {}}])
    assert meta == {"sp-msg-a": 2}


# ---------------------------------------------------------------- Stud.IP-Nachbildung

class FakeStudIP:
    def __init__(self):
        self.calls = []
        self.post_status = [201]
        self.inbox_status = 200
        self.recipients = [ME, BOB]

    def __call__(self, method, url, headers, body):
        from app.studip_live import Reply
        self.calls.append((method, url, headers, body))
        assert "Cookie" in headers and "passw" not in json.dumps(headers).lower()
        if url.endswith("/users/me"):
            return Reply(200, json.dumps({"data": {"id": ME, "attributes": {"family-name": "Beispiel"}}}).encode(), "application/vnd.api+json")
        if "/inbox" in url:
            if self.inbox_status != 200:
                return Reply(self.inbox_status, b"", "text/html")
            data = [{"id": "m1", "type": "messages", "attributes": {"subject": "Tutorium entfällt"},
                     "relationships": {"sender": {"data": {"type": "users", "id": PROF}},
                                       "recipients": {"data": [{"type": "users", "id": r} for r in self.recipients]}}},
                    {"id": "m2", "type": "messages", "attributes": {"subject": "System"},
                     "relationships": {"sender": {"data": {"type": "users", "id": "____%system%____"}}}}]
            inc = [{"type": "users", "id": PROF, "attributes": {"formatted-name": "Prof. Test"}}]
            return Reply(200, json.dumps({"data": data, "included": inc}).encode(), "application/vnd.api+json")
        if f"/users/{BOB}" in url:
            return Reply(200, json.dumps({"data": {"id": BOB, "attributes": {"given-name": "Bob", "family-name": "Muster"}}}).encode(), "application/vnd.api+json")
        if method == "POST" and url.endswith("/jsonapi.php/v1/messages"):
            st = self.post_status.pop(0) if self.post_status else 201
            if st == 201:
                return Reply(201, b'{"data":{"id":"new1"}}', "application/vnd.api+json")
            if st == 403:
                return Reply(403, b"Invalid security token (CSRF)", "text/plain")
            return Reply(st, b"", "text/plain")
        return Reply(404)

    def posts(self):
        return [c for c in self.calls if c[0] == "POST"]


@pytest.fixture
def studip(app, monkeypatch, tmp_path):
    from app import db, studip_extras, studip_live, studip_messages, studip_reply
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "antworten.db")
    db.init_db()
    monkeypatch.setattr(studip_messages, "stud_ip_offered", lambda: True)
    monkeypatch.setattr(studip_messages, "stud_ip_connected", lambda: True)
    fake = FakeStudIP()
    renewals = []
    monkeypatch.setattr(studip_live, "_send", fake)
    monkeypatch.setattr(studip_live, "_cookie", lambda: "Seminar_Session=alt")
    monkeypatch.setattr(studip_live, "_renew", lambda: renewals.append(1) or "Seminar_Session=neu")
    fake.renewals = renewals
    items = [{"id": "sp-msg-m1", "sender": "Lehrende", "subject": "Tutorium entfällt", "preview": "Das Tutorium fällt aus.",
              "sent_at": "2026-11-02T08:15:00+01:00", "url": "https://studip.uni-hannover.de/dispatch.php/messages/overview", "dates": []},
             {"id": "sp-msg-m2", "sender": "Stud.IP", "subject": "System", "preview": "x", "sent_at": "2026-11-01T08:15:00+01:00",
              "url": "https://studip.uni-hannover.de/dispatch.php/messages/overview", "dates": []}]
    with db.cursor() as conn:
        studip_extras.store_messages(conn, items, "2026-11-05T07:30:00+00:00")
        studip_reply.store_message_meta(conn, {"sp-msg-m1": 2})
    return fake


def test_context_names_only_in_the_answer(app, studip):
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages/sp-msg-m1/reply?all=1"))
    assert st == 200
    assert d["sender"] == {"id": PROF, "name": "Prof. Test"} and d["reply_subject"] == "RE: Tutorium entfällt"
    assert d["others"] == [{"id": BOB, "name": "Bob Muster"}] and d["allows_reply_all"] is True
    assert d["quote"].startswith("Am 02.11.2026 um 08:15 Prof. Test schrieb:")
    assert d["web_url"].endswith("/dispatch.php/messages/write?answer_to=m1")
    st, lst = _j(asgi_call(app, "GET", "/api/studip/messages"))
    m = next(x for x in lst["messages"] if x["id"] == "sp-msg-m1")
    assert m["recipients"] == 2 and m["replyable"] is True and m["replies"] == []
    assert "Prof. Test" not in json.dumps(lst) and "Bob" not in json.dumps(lst), "keine Namen in der Liste"


def test_send_all_quote_log_and_draft(app, studip):
    from app import db, studip_reply
    st, d = _j(asgi_call(app, "PUT", "/api/studip/messages/sp-msg-m1/draft", body=json.dumps({"text": "Entwurf", "mode": "all"})))
    assert st == 200 and d["draft"]["text"] == "Entwurf"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply",
                         body=json.dumps({"mode": "all", "text": "Danke!", "quote": True, "subject": ""})))
    assert st == 200 and d["sent"] is True and d["record"]["recipients"] == 2 and d["record"]["sent_id"] == "new1"
    assert d["record"]["line"].startswith("Beantwortet am ")
    (_, url, headers, body), = studip.posts()
    sent = json.loads(body)
    assert [r["id"] for r in sent["data"]["relationships"]["recipients"]["data"]] == [PROF, BOB], "nie an einen selbst"
    assert sent["data"]["attributes"]["subject"] == "RE: Tutorium entfällt"
    assert sent["data"]["attributes"]["message"].startswith("Danke!\n\nAm 02.11.2026 um 08:15 Prof. Test schrieb:\n> Das Tutorium")
    assert headers["X-Requested-With"] == "XMLHttpRequest" and headers["Content-Type"] == "application/vnd.api+json"
    with db.cursor() as conn:
        assert studip_reply.draft_for(conn, "sp-msg-m1") is None, "Entwurf nach dem Senden geloescht"
        dump = conn.execute("SELECT value FROM settings WHERE key='studip_replies'").fetchone()[0]
    assert "Prof. Test" not in dump and "Bob" not in dump, "Verlauf ohne Namen"
    st, lst = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert next(x for x in lst["messages"] if x["id"] == "sp-msg-m1")["replies"][0]["text"] == "Danke!"


def test_recipients_come_from_studip_not_from_the_browser(app, studip):
    studip.recipients = [ME]                                          # keine weiteren: "all" wird "sender"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply",
                         body=json.dumps({"mode": "all", "text": "x", "recipients": ["fremd"]})))
    assert st == 200 and d["record"]["mode"] == "sender"
    sent = json.loads(studip.posts()[0][3])
    assert [r["id"] for r in sent["data"]["relationships"]["recipients"]["data"]] == [PROF]


def test_expired_session_renews_once_then_asks_for_login(app, studip):
    studip.post_status = [401, 201]
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply", body=json.dumps({"text": "x"})))
    assert st == 200 and len(studip.posts()) == 2 and len(studip.renewals) == 1
    studip.calls.clear()
    studip.post_status = [401, 401]
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply", body=json.dumps({"text": "x"})))
    assert st == 409 and d["code"] == "studip_login" and len(studip.posts()) == 2


def test_errors_are_never_retried_and_offer_studip(app, studip):
    studip.post_status = [403]
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply", body=json.dumps({"text": "x"})))
    assert st == 409 and d["code"] == "reply_security_token" and "answer_to=m1" in d["web_url"]
    studip.calls.clear()
    studip.post_status = [500]
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply", body=json.dumps({"text": "x"})))
    assert st == 502 and len(studip.posts()) == 1, "5xx: kein zweites Senden"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m2/reply", body=json.dumps({"text": "x"})))
    assert st == 422 and d["code"] == "reply_system_message"
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/sp-msg-m1/reply", body=json.dumps({"text": "  "})))
    assert st == 400


def test_only_local(app, studip, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    st, _ = _j(asgi_call(app, "GET", "/api/studip/messages/sp-msg-m1/reply"))
    assert st in (401, 404)
