"""Allgemeines Moodle am PC (app/moodle.py, app/moodle_api.py): HsH-Nachrichten lesen und beantworten, Abgabe in einer
Aufgabe (Entwurf, erst danach ausdruecklich "Jetzt abgeben") fuer HsH und Learnweb Hildesheim. Gleiche nachgebaute
Antworten wie der Swift-Kern (packages/shared-contracts/fixtures/moodle, MoodleTests.swift). Kein Netz."""
import json
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages/shared-contracts/fixtures/moodle"
BASE = "https://moodle.hs-hannover.de"
MSG_PAGE = '<script>M.cfg = {"sesskey":"sk123"};</script><div data-region="message-drawer" data-userid="42"></div>'
PDF = b"%PDF-1.4 erfunden"


def fx(name: str) -> str:
    return (FX / name).read_text(encoding="utf-8")


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


class FakeMoodle:
    """Nachgebautes Moodle: Antworten je Adresse (und Teil des Rumpfs), merkt sich jede Anfrage"""

    def __init__(self):
        self.calls: list[tuple[str, str, bytes]] = []
        self.routes: list[tuple[str, str | None, object]] = []
        self.login = False

    def on(self, url: str, resp, body: str | None = None):
        self.routes.append((url, body, resp))

    def __call__(self, method, url, data, headers):
        self.calls.append((method, url, data or b""))
        assert headers.get("Cookie"), "immer mit der gemerkten Sitzung"
        if self.login:
            return 200, b"<html>Anmelden</html>", f"{BASE}/login/index.php"
        text = (data or b"").decode("utf-8", "replace")
        for u, part, resp in self.routes:
            if url == u and (part is None or part in text):
                r = resp() if callable(resp) else resp
                if isinstance(r, tuple):
                    return r[0], r[1], url
                return 200, r if isinstance(r, bytes) else r.encode(), url
        return 404, b"", url

    def bodies(self, part: str) -> list[str]:
        return [d.decode("utf-8", "replace") for _, _, d in self.calls if part in d.decode("utf-8", "replace")]


def ajax_ok(data) -> str:
    return json.dumps([{"error": False, "data": data}])


def message_routes(f: FakeMoodle):
    f.on(f"{BASE}/message/index.php", MSG_PAGE)
    svc = f"{BASE}/lib/ajax/service.php?sesskey=sk123&info="
    f.on(svc + "core_message_get_conversations", ajax_ok(json.loads(fx("conversations.json"))))
    msgs = json.loads(fx("conversation-messages.json"))
    f.on(svc + "core_message_get_conversation_messages", ajax_ok(msgs["12"]), body='"convid": 12')
    f.on(svc + "core_message_get_conversation_messages", ajax_ok(msgs["13"]), body='"convid": 13')
    f.on(svc + "core_message_get_unread_conversations_count", ajax_ok(1))
    f.on(svc + "core_message_send_messages_to_conversation", ajax_ok([{"id": 346}]))


def assign_routes(f: FakeMoodle):
    f.on(f"{BASE}/message/index.php", MSG_PAGE)
    f.on(f"{BASE}/mod/assign/view.php?id=7001", fx("assign-view-none.html"))
    f.on(f"{BASE}/mod/assign/view.php?id=7001&action=editsubmission", fx("assign-edit.html"))
    f.on(f"{BASE}/repository/repository_ajax.php?action=upload", fx("upload-ok.json"))
    f.on(f"{BASE}/mod/assign/view.php", fx("assign-view-draft.html"), body="action=savesubmission")
    f.on(f"{BASE}/mod/assign/view.php?id=7001&action=submit", fx("assign-confirm.html"))
    f.on(f"{BASE}/mod/assign/view.php", fx("assign-view-submitted.html"), body="action=confirmsubmit")


@pytest.fixture
def fresh_db(monkeypatch, tmp_path):
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "moodle.db")
    db.init_db()
    return db


# ---------------------------------------------------------------------------- Nachrichten

def test_messages_are_stored_without_names_and_without_marking_read(fresh_db):
    from app import moodle, studip_messages
    f = FakeMoodle()
    message_routes(f)
    web = moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f)
    with fresh_db.cursor() as conn:
        r = moodle.sync_messages(web, conn, "2026-11-05T10:00:00+01:00")
        msgs, _ = studip_messages.stored_messages(conn)
    assert r["count"] == 2 and r["unread"] == 1 and r["message"] == "Nachrichten: 2 (1 ungelesen in Moodle)"
    assert [m["id"] for m in msgs] == ["moodle-13-400", "moodle-12-345"], "neueste zuerst, eigene Nachricht nicht"
    assert msgs[-1]["sender"] == "Moodle" and msgs[0]["sender"] == "Programmieren 1 – Gruppe A"
    assert "Bitte bis 12.11. abgeben." in msgs[-1]["text"] and msgs[-1]["url"] == f"{BASE}/message/index.php?convid=12"
    assert "Erfunden Lehrperson" not in json.dumps(msgs), "keine Personennamen gespeichert"
    assert not any("mark" in url for _, url, _ in f.calls), "nichts als gelesen markiert"
    assert moodle.conversation_id("moodle-12-345") == 12 and moodle.conversation_id("sp-msg-1") is None


def test_reply_sends_once_and_names_are_read_live():
    from app import moodle
    f = FakeMoodle()
    message_routes(f)
    web = moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f)
    assert moodle.member_names(web, 12) == ["Erfunden Lehrperson"]
    assert moodle.reply(web, 12, "  Danke!\nBis Donnerstag.  ") == 346
    (sent,) = f.bodies("core_message_send_messages_to_conversation")
    args = json.loads(sent)[0]["args"]
    assert args["conversationid"] == 12 and args["messages"][0]["text"] == "Danke!\nBis Donnerstag."
    # Fehler beim Senden: genau ein Versuch, kein stilles Wiederholen
    f2 = FakeMoodle()
    message_routes(f2)
    f2.routes.insert(0, (f"{BASE}/lib/ajax/service.php?sesskey=sk123&info=core_message_send_messages_to_conversation", None, (503, b"")))
    web2 = moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f2)
    with pytest.raises(moodle.MoodleError) as e:
        moodle.reply(web2, 12, "x")
    assert e.value.code == "http" and e.value.detail == "503"
    assert len(f2.bodies("core_message_send_messages_to_conversation")) == 1
    with pytest.raises(moodle.MoodleError):
        moodle.reply(web, 12, "   ")


def test_expired_session_asks_for_login(fresh_db):
    from app import moodle
    f = FakeMoodle()
    f.login = True
    with fresh_db.cursor() as conn:
        r = moodle.sync_messages(moodle.MoodleWeb(BASE, "MoodleSession=alt", http=f), conn, "t")
    assert r["needs_login"] is True and r["count"] is None
    with pytest.raises(moodle.MoodleError) as e:
        moodle.MoodleWeb(BASE, "", http=f).current()
    assert e.value.code == "login", "ohne gemerkte Sitzung gar nicht erst fragen"


def test_moodle_rules_for_pages():
    from app import moodle
    assert moodle.is_logged_in(MSG_PAGE) and moodle.sesskey_from_page(MSG_PAGE) == "sk123"
    assert not moodle.is_logged_in('<body class="notloggedin">"sesskey":"x"</body>')
    assert moodle.user_id_from_page(MSG_PAGE) == 42 and moodle.user_id_from_page("") is None
    assert moodle.is_login_url(f"{BASE}/login/index.php") and not moodle.is_login_url(f"{BASE}/my/")


# ---------------------------------------------------------------------------- Abgabe

def test_assignment_pages_are_read():
    from app import moodle
    assert moodle.status(fx("assign-view-none.html")) == {"state": "keine Abgabe", "can_edit": True, "can_submit": False,
                                                          "grading": None, "attempt": None, "has_feedback": False}
    assert moodle.status(fx("assign-view-draft.html"))["state"] == "Entwurf gespeichert"
    assert moodle.status(fx("assign-view-draft.html"))["can_submit"] is True
    assert moodle.status(fx("assign-view-submitted.html"))["state"] == "Abgegeben"
    f = moodle.edit_form(fx("assign-edit.html"))
    assert [f["draft_item_id"], f["repository_id"], f["context_id"]] == ["555666", "5", "1234"]
    assert f["fields"]["action"] == "savesubmission"
    c = moodle.confirm_form(fx("assign-confirm.html"))
    assert c["statement"] == "Diese Arbeit ist meine eigene Leistung."
    assert ("submissionstatement", "1") not in moodle.confirm_fields(c, False)
    assert ("submissionstatement", "1") in moodle.confirm_fields(c, True)
    assert moodle.cmid_from_url(f"{BASE}/mod/assign/view.php?id=7001") == 7001
    assert "Dateiabgabe" not in moodle.status_rows(fx("assign-view-submitted.html")), "Dateinamen nie gelesen"


def test_draft_upload_then_explicit_submit():
    from app import moodle
    f = FakeMoodle()
    assign_routes(f)
    web = moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f)
    st, name = moodle.save_draft(web, 7001, PDF, "Abgabe.pdf")
    assert st["state"] == "Entwurf gespeichert" and name == "Abgabe.pdf"
    uploads = [d for _, url, d in f.calls if "repository_ajax.php" in url]
    assert len(uploads) == 1
    body = uploads[0].decode("utf-8", "replace")
    for part in ['name="itemid"\r\n\r\n555666', 'name="repo_id"\r\n\r\n5', 'name="sesskey"\r\n\r\nsk123', "%PDF-1.4 erfunden"]:
        assert part in body, part
    (save,) = f.bodies("action=savesubmission")
    assert "files_filemanager=555666" in save
    assert not f.bodies("confirmsubmit"), "Entwurf ist noch keine Abgabe"
    # Erklaerung verlangt, aber nicht bestaetigt: nichts abgeschickt
    with pytest.raises(moodle.MoodleError) as e:
        moodle.submit(web, 7001, statement_accepted=False)
    assert e.value.code == "refused" and "Erklärung nicht bestätigt" in e.value.message
    assert not f.bodies("confirmsubmit")
    done = moodle.submit(web, 7001, statement_accepted=True)
    assert done["state"] == "Abgegeben"
    (confirm,) = f.bodies("confirmsubmit")
    assert "submissionstatement=1" in confirm


def _deadlines(conn):
    conn.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('lw-501', 'Programmieren 1', 'vorlesung', 1, 't')")
    for row in (("lw-ev-1", "Übungsblatt 3", "abgabe", "2026-11-12T23:59", f"{BASE}/mod/assign/view.php?id=7001"),
                ("lw-ev-2", "Test 1", "test_ende", "2026-11-13T10:00", f"{BASE}/mod/quiz/view.php?id=8001")):
        conn.execute("""INSERT INTO deadlines(id, source, course_id, title, full_title, kind, due_at, url, fetched_at)
                        VALUES (?, 'learnweb', 'lw-501', ?, ?, ?, ?, ?, 't')""", (row[0], row[1], row[1], row[2], row[3], row[4]))


def test_assignments_come_from_moodle_deadlines(fresh_db):
    from app import moodle
    with fresh_db.cursor() as conn:
        _deadlines(conn)
        assert moodle.assignments(conn) == [{"cmid": 7001, "title": "Übungsblatt 3", "due_at": "2026-11-12T23:59", "course": "Programmieren 1"}]


# ---------------------------------------------------------------------------- PC: Routen

@pytest.fixture
def hsh_pc(app, monkeypatch, fresh_db):
    from app import config, moodle, studip_messages, studip_reply
    monkeypatch.setattr(config, "UNIVERSITY", "hsh")
    f = FakeMoodle()
    message_routes(f)
    assign_routes(f)
    monkeypatch.setattr(moodle, "live", lambda inst=None: moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f))
    monkeypatch.setattr(studip_messages, "moodle_connected", lambda: True)
    with fresh_db.cursor() as conn:
        _deadlines(conn)
        moodle.sync_messages(moodle.MoodleWeb(BASE, "MoodleSession=s1", http=f), conn, "2026-11-05T10:00:00+01:00")
    f.calls.clear()
    assert studip_reply                                      # Routen sind eingebunden
    return f


def _multipart(fields, pdf=PDF):
    b = "XyZ"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="x.pdf"\r\nContent-Type: application/pdf\r\n\r\n'.encode() + pdf + b"\r\n")
    return b"".join(parts) + f"--{b}--\r\n".encode(), f"multipart/form-data; boundary={b}"


def test_pc_lists_and_answers_moodle_messages(app, hsh_pc):
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert st == 200 and d["available"] is True and d["source"] == "moodle"
    m = next(x for x in d["messages"] if x["id"] == "moodle-12-345")
    assert m["source"] == "moodle" and m["replyable"] is True and m["reply_url"].endswith("convid=12")
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages/moodle-12-345/reply"))
    assert st == 200 and d["source"] == "moodle" and d["sender"]["name"] == "Erfunden Lehrperson" and d["no_subject"] is True
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/moodle-12-345/reply", body=json.dumps({"text": "Danke!"})))
    assert st == 200 and d["sent"] is True and d["record"]["sent_id"] == "346"
    assert len(hsh_pc.bodies("core_message_send_messages_to_conversation")) == 1
    hsh_pc.login = True
    st, d = _j(asgi_call(app, "POST", "/api/studip/messages/moodle-12-345/reply", body=json.dumps({"text": "nochmal"})))
    assert st == 409 and d["code"] == "moodle_login"


def test_pc_submission_draft_first_then_jetzt_abgeben(app, hsh_pc):
    st, d = _j(asgi_call(app, "GET", "/api/moodle/assign"))
    assert st == 200 and d["source"] == "Moodle" and [a["cmid"] for a in d["assignments"]] == [7001]
    assert "Jetzt abgeben" in d["warning"]
    st, d = _j(asgi_call(app, "GET", "/api/moodle/assign/7001"))
    assert st == 200 and d["state"] == "keine Abgabe"
    body, ct = _multipart({"file_name": "Mueller_Blatt3"})
    st, d = _j(asgi_call(app, "POST", "/api/moodle/assign/7001/draft", body=body, content_type=ct))
    assert st == 200 and d["status"]["state"] == "Entwurf gespeichert" and d["record"]["step"] == "draft"
    assert not hsh_pc.bodies("confirmsubmit"), "der Entwurf gibt nicht ab"
    st, d = _j(asgi_call(app, "GET", "/api/moodle/assign/7001/confirm"))
    assert st == 200 and d["statement"] == "Diese Arbeit ist meine eigene Leistung."
    st, d = _j(asgi_call(app, "POST", "/api/moodle/assign/7001/submit", body=json.dumps({})))
    assert st == 409 and d["code"] == "moodle_refused" and not hsh_pc.bodies("confirmsubmit")
    st, d = _j(asgi_call(app, "POST", "/api/moodle/assign/7001/submit", body=json.dumps({"statement_accepted": True})))
    assert st == 200 and d["status"]["state"] == "Abgegeben" and len(hsh_pc.bodies("confirmsubmit")) == 1
    st, d = _j(asgi_call(app, "GET", "/api/moodle/assign"))
    assert [h["step"] for h in d["history"]] == ["submit", "draft"] and d["history"][0]["line"].startswith("Abgegeben am ")
    assert "Mueller" not in json.dumps(d["history"]), "kein Dateiname im Verlauf"
    body, ct = _multipart({"file_name": "x"}, pdf=b"keine pdf")
    st, d = _j(asgi_call(app, "POST", "/api/moodle/assign/7001/draft", body=body, content_type=ct))
    assert st == 400 and d["code"] == "bad_pdf"


def test_pc_submission_only_where_moodle_is(app, monkeypatch, fresh_db):
    from app import config, moodle
    monkeypatch.setattr(config, "UNIVERSITY", "luh")
    st, d = _j(asgi_call(app, "GET", "/api/moodle/assign"))
    assert st == 404 and d["code"] == "not_available"
    monkeypatch.setattr(config, "UNIVERSITY", "hildesheim")
    inst = moodle.instance()
    assert inst["name"] == "Learnweb" and inst["session"] == "LEARNWEB_COOKIES"


def test_hsh_sync_reads_moodle_messages_with_the_session(fresh_db):
    from app import hsh, studip_messages

    class Page:
        def evaluate(self, js):
            return 42

    class Client:
        def __init__(self):
            self.f = FakeMoodle()
            message_routes(self.f)
            self.web = __import__("app.moodle", fromlist=["MoodleWeb"]).MoodleWeb(BASE, "MoodleSession=s1", http=self.f)

        def ajax(self, fn, args):
            return self.web.ajax(fn, args)

    c = Client()
    assert hsh.sync_messages(c, Page(), "") == "Nachrichten: 2 (1 ungelesen in Moodle)"
    with fresh_db.cursor() as conn:
        assert [m["id"] for m in studip_messages.stored_messages(conn)[0]] == ["moodle-13-400", "moodle-12-345"]
    assert not c.f.bodies("send_messages"), "Abgleich sendet nie"
