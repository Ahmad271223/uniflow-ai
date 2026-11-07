"""Uni-Mail und Uni-Kalender der LUH und der Uni Hildesheim (SOGo, docs/UNI-MAIL-2026-11-05.md): gemeinsame Faelle (fixtures/sogo), Abruf mit
nachgebauten Antworten (nie ins Netz, nie ein Passwort), Senden nur auf ausdruecklichen Knopfdruck, Routen am PC, im
Dienst nicht vorhanden, Termine im Stundenplan."""
from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

import pytest

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "sogo"
USER = "erika.muster@stud.uni-hannover.de"
UB = f"https://kalender.uni-hannover.de/SOGo/so/{USER}"


def raw(name):
    return json.loads((FX / "raw" / name).read_text(encoding="utf-8"))


def _j(r):
    st, _, body = r
    return st, json.loads(body or b"null")


def test_shared_cases_are_current():
    sys.path.insert(0, str(ROOT / "tools"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_sogo", ROOT / "tools" / "gen-sogo-fixture.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    assert gen.cases() == json.loads((FX / "cases.json").read_text(encoding="utf-8"))


def test_rules_from_cases():
    from app import sogo
    c = json.loads((FX / "cases.json").read_text(encoding="utf-8"))
    for x in c["css"]:
        assert sogo.css_identifier(x["in"]) == x["css"]
    for x in c["user_from_url"]:
        assert sogo.user_from_url(x["url"]) == x["user"], x["url"]
    for x in c["expired"]:
        assert sogo.expired(x["status"], x["final"], x["body"]) is x["expired"]
    assert c["login_page"] is True
    # bereinigtes HTML: nie Skript, Ereignis-Attribut, javascript: oder ein Bild aus dem Netz
    for x in c["sanitize"]:
        h = x["out"]["html"].lower()
        assert "<script" not in h and "onclick" not in h and "onload" not in h and "javascript:" not in h and "<iframe" not in h
        assert ' src="http' not in h and " src='http" not in h and " src='//" not in h


class FakeSOGo:
    """Nachgebautes SOGo: Antworten je (Methode, Pfadende); merkt Anfragen (ohne Netz)."""

    def __init__(self):
        self.calls: list[tuple[str, str, dict, bytes | None]] = []
        self.login = False
        self.send_status = 200

    def __call__(self, method, url, data, headers):
        self.calls.append((method, url, headers, data))
        if self.login:
            return 200, b'<form name="loginForm"></form>', "https://kalender.uni-hannover.de/SOGo/", {"content-type": "text/html"}
        path = url.split("?")[0]
        j = lambda o, st=200: (st, json.dumps(o).encode(), url, {"content-type": "application/json"})  # noqa: E731
        if path == f"{UB}/Mail/0/view":
            return j(raw("mailboxes.json"))
        if path == f"{UB}/Mail/0/folderINBOX/view":
            return j(raw("folder-inbox.json"))
        if path == f"{UB}/Mail/0/folderINBOX/headers":
            return j(raw("headers-page2.json"))
        if path == f"{UB}/Mail/0/folderJunk/view" or path == f"{UB}/Mail/0/folderJunk/headers":
            return 204, b"", url, {}                               # leerer Ordner: SOGo antwortet 204 ohne Inhalt
        if path == f"{UB}/Mail/0/folderTemplates/view":
            return 200, b"", url, {"content-type": "application/json"}
        if path == f"{UB}/Mail/0/folderINBOX/128/view":
            return j(raw("message-html.json"))
        if path.endswith("/128/reply") or path.endswith("/128/replyall") or path.endswith("/128/forward"):
            return j(raw("created-reply.json"), 201)
        if path == f"{UB}/Mail/0/compose":
            return j(raw("created-compose.json"), 201)
        if path.endswith("/newDraft1730800001-1/edit"):
            return j(raw("edit-reply-html.json"))
        if path.endswith("/newDraft1730800002-2/edit"):
            return j(raw("edit-compose.json"))
        if path.endswith("/save"):
            if headers.get("Content-Type", "").startswith("multipart/"):
                return j({"uid": 41, "lastAttachmentAttrs": [{"filename": "Blatt3.pdf", "size": "12 KB"}]})
            return j({"uid": 40})
        if path.endswith("/send"):
            return j(raw("send-ok.json") if self.send_status == 200 else raw("send-fail.json"), self.send_status)
        if path.endswith("/markMessageRead") or path.endswith("/markMessageUnread") or path.endswith("/markMessageFlagged") \
                or path.endswith("/markMessageUnflagged") or path.endswith("/batchDelete") or path.endswith("/moveMessages"):
            return j({})
        if path == f"{UB}/Mail/unseenCount":
            return j(raw("unseen.json"))
        if path == f"{UB}/Calendar/eventslist":
            return j(raw("events.json"))
        if "/asAttachment/" in path:
            return 200, b"%PDF-1.4 erfunden", url, {"content-type": "application/pdf"}
        return 404, b"{}", url, {"content-type": "application/json"}

    def paths(self, suffix=""):
        return [(m, u.split("?")[0]) for m, u, _, _ in self.calls if u.split("?")[0].endswith(suffix)]


COOKIES = [{"name": "0xHIGHFLYxSOGo", "value": "sitzung", "domain": "kalender.uni-hannover.de", "path": "/SOGo"},
           {"name": "XSRF-TOKEN", "value": "tok%2B1", "domain": "kalender.uni-hannover.de", "path": "/SOGo"},
           {"name": "fremd", "value": "x", "domain": "evil.example", "path": "/"}]


def web(f):
    from app import sogo
    return sogo.SOGoWeb(USER, COOKIES, http=f)


def test_reading_uses_session_and_xsrf_header_only_for_sogo():
    f = FakeSOGo()
    w = web(f)
    boxes = w.mailboxes()
    assert boxes[0]["type"] == "inbox" and boxes[3]["name"] == "Papierkorb"
    listing = w.folder("INBOX")
    assert listing["total"] == 64 and [m["uid"] for m in listing["messages"]] == [128, 127, 126, 125] and listing["unseen"] == 2
    page2 = w.headers("INBOX", [79, 78])
    assert [m["uid"] for m in page2] == [79, 78]
    msg = w.message("INBOX", 128)
    assert msg["attachments"][0]["name"] == "Blatt3.pdf" and "<script" not in msg["html"]
    data, ctype = w.attachment(msg["attachments"][0]["path"])
    assert data.startswith(b"%PDF") and ctype == "application/pdf"
    for m, u, h, _ in f.calls:
        assert u.startswith("https://kalender.uni-hannover.de/SOGo/")
        assert h["Cookie"] == "0xHIGHFLYxSOGo=sitzung; XSRF-TOKEN=tok%2B1"
        assert h["X-XSRF-TOKEN"] == "tok+1"
    body = json.loads(f.calls[1][3])
    assert body == {"sortingAttributes": {"sort": "arrival", "asc": 0}}
    assert json.loads(f.calls[2][3]) == {"uids": [79, 78]}
    # keine fremde Adresse fuer Anhaenge
    from app import sogo
    with pytest.raises(sogo.SOGoError):
        w.attachment("https://evil.example/SOGo/so/x/a.pdf")


def test_empty_folder_204_or_empty_body_is_zero_mails_not_an_error():
    # echtes iPad 07.11.2026: Spam und Vorlagen meldeten "Fehler 204"; 204 / leerer Koerper = leerer Ordner
    f = FakeSOGo()
    w = web(f)
    junk = w.folder("Junk")
    assert junk["folder"] == "Junk" and junk["total"] == 0 and junk["messages"] == [] and junk["unseen"] is None
    assert w.headers("Junk", [5]) == []
    tpl = w.folder("Templates")
    assert tpl["total"] == 0 and tpl["messages"] == []
    assert f.paths("/view")[-2:] == [("POST", f"{UB}/Mail/0/folderJunk/view"), ("POST", f"{UB}/Mail/0/folderTemplates/view")]


def test_expired_session_is_login_needed():
    from app import sogo
    f = FakeSOGo()
    f.login = True
    with pytest.raises(sogo.SOGoError) as e:
        web(f).folder("INBOX")
    assert e.value.code == "login"


def test_reply_save_attach_and_send_only_on_send():
    from app import sogo
    f = FakeSOGo()
    w = web(f)
    d = w.new_draft("reply", "INBOX", 128)
    assert d["to"] == ["Prof. Dr. Max Beispiel <max.beispiel@example.uni-hannover.de>"] and d["text"].startswith("Am 05.11.2026")
    assert f.paths("/send") == [], "Antworten anlegen sendet nichts"
    body = sogo.payload(d, d["to"], d["cc"], [], d["subject"], "Danke!\n\n" + d["text"])
    assert w.save(d, body) == {"uid": 40}
    att = w.attach(d, "Blatt3.pdf", b"%PDF-1.4", "application/pdf")
    assert att["name"] == "Blatt3.pdf"
    assert f.paths("/send") == [], "Speichern und Anhang senden nichts"
    r = w.send(d, body)
    assert r == {"ok": True, "message": "Gesendet."}
    sends = f.paths("/send")
    assert sends == [("POST", f"{UB}/Mail/0/folderDrafts/newDraft1730800001-1/send")]
    sent = json.loads([c for c in f.calls if c[1].endswith("/send")][0][3])
    assert sent["isHTML"] is False and sent["to"] == d["to"] and sent["from"].endswith(f"<{USER}>")
    # ohne Empfaenger: keine Anfrage
    with pytest.raises(sogo.SOGoError) as e:
        w.send(d, {**body, "to": [], "cc": [], "bcc": []})
    assert e.value.code == "input" and len(f.paths("/send")) == 1
    # Ablehnung von SOGo: Meldung, kein zweiter Versuch
    f.send_status = 405
    assert w.send(d, body) == {"ok": False, "message": "Tried to send too many mails. Please wait."}
    assert len(f.paths("/send")) == 2


def test_flags_trash_restore_and_never_delete_for_good():
    f = FakeSOGo()
    w = web(f)
    w.mark_read("INBOX", 128, False)
    w.flag("INBOX", 128, True)
    w.trash("INBOX", [128])
    w.move("Trash", [5], "INBOX")
    assert [u for _, u, _, _ in f.calls] == [
        f"{UB}/Mail/0/folderINBOX/128/markMessageUnread", f"{UB}/Mail/0/folderINBOX/128/markMessageFlagged",
        f"{UB}/Mail/0/folderINBOX/batchDelete", f"{UB}/Mail/0/folderTrash/moveMessages"]
    assert json.loads(f.calls[2][3]) == {"uids": [128]}, "nie withoutTrash"
    assert json.loads(f.calls[3][3]) == {"uids": [5], "folder": "/0/folderINBOX"}
    assert not any("expunge" in u or "emptyTrash" in u or "withoutTrash" in (d or b"").decode() for _, u, _, d in f.calls)


def test_calendar_import_into_timetable(monkeypatch, tmp_path):
    from app import db, sogo, timetable
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "sogo.db")
    db.init_db()
    f = FakeSOGo()
    events = web(f).events(date(2026, 11, 9), 7)
    assert f.calls[-1][1].split("?")[1] == "asc=1&day=20261109&filterpopup=view_next7&search=title_Category_Location&sort=start&value="
    with db.cursor() as conn:
        n = sogo.store_events(conn, events, date(2026, 11, 9), date(2026, 11, 16), "2026-11-09T08:00:00")
        assert n == 8
        occ = timetable.occurrences(conn, date(2026, 11, 9), date(2026, 11, 15))
    mine = [o for o in occ if o["source"] == "uni-kalender"]
    assert [(o["date"], o["start"], o["title"]) for o in mine][:2] == [("2026-11-09", "10:15", "Tutorium Analysis"),
                                                                       ("2026-11-10", "14:00", "Sprechstunde Prof. Beispiel")]
    assert mine[0]["room"] == "1101 - F102" and mine[0]["event_id"] is None
    assert not any(o["title"] == "Exkursion" for o in mine), "ganztaegige nicht im Stundenplan"
    assert next(o for o in mine if o["title"] == "Abgesagt: Seminar")["status"] == "ausfall"


@pytest.fixture
def pc(app, monkeypatch, tmp_path):
    from app import config, db, sogo
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "pc.db")
    db.init_db()
    monkeypatch.setattr(config, "MODE", "single")
    f = FakeSOGo()
    monkeypatch.setattr(sogo, "live", lambda http=None: sogo.SOGoWeb(USER, COOKIES, http=f))
    return f


def test_pc_routes_list_read_reply_and_send_needs_confirm(app, pc):
    st, d = _j(asgi_call(app, "GET", "/api/sogo/mailboxes"))
    assert st == 200 and d["mailboxes"][0]["name"] == "Posteingang"
    st, d = _j(asgi_call(app, "GET", "/api/sogo/messages?folder=INBOX"))
    assert st == 200 and d["total"] == 64 and len(d["messages"]) == 4
    uids = ",".join(str(u) for u in d["uids"])
    st, d = _j(asgi_call(app, "GET", f"/api/sogo/messages?folder=INBOX&page=1&uids={uids}"))
    assert st == 200 and d["page"] == 1 and [m["uid"] for m in d["messages"]] == [78], "Seite 2 = UIDs 78..29, Antwort kennt 79 und 78"
    assert json.loads(pc.calls[-1][3])["uids"][:2] == [78, 77] and len(json.loads(pc.calls[-1][3])["uids"]) == 14
    st, d = _j(asgi_call(app, "GET", "/api/sogo/message?folder=INBOX&uid=128"))
    assert st == 200 and d["subject"].startswith("Übungsblatt")
    st, draft = _j(asgi_call(app, "POST", "/api/sogo/draft", body=json.dumps({"action": "reply", "folder": "INBOX", "uid": 128})))
    assert st == 200 and draft["draft_id"] == "newDraft1730800001-1"
    body = {"draft": draft, "to": draft["to"], "cc": [], "bcc": [], "subject": draft["subject"], "text": "Danke"}
    st, d = _j(asgi_call(app, "POST", "/api/sogo/draft/save", body=json.dumps(body)))
    assert st == 200 and d["uid"] == 40
    st, d = _j(asgi_call(app, "POST", "/api/sogo/draft/send", body=json.dumps(body)))
    assert st == 400 and d["code"] == "sogo_confirm"
    assert pc.paths("/send") == []
    st, d = _j(asgi_call(app, "POST", "/api/sogo/draft/send", body=json.dumps({**body, "confirm": True})))
    assert st == 200 and d["ok"] is True and len(pc.paths("/send")) == 1
    st, d = _j(asgi_call(app, "POST", "/api/sogo/trash", body=json.dumps({"folder": "INBOX", "uids": [128]})))
    assert st == 200
    st, d = _j(asgi_call(app, "POST", "/api/sogo/calendar/import", body=json.dumps({"days": 30})))
    assert st == 200 and d["days"] == 30
    assert "view_next31" in pc.calls[-1][1]
    st, d = _j(asgi_call(app, "DELETE", "/api/sogo/session"))
    assert st == 200


def test_pc_expired_and_hosted(app, pc, monkeypatch):
    from app import config
    pc.login = True
    st, d = _j(asgi_call(app, "GET", "/api/sogo/messages"))
    assert st == 409 and d["code"] == "sogo_login"
    monkeypatch.setattr(config, "MODE", "hosted")
    from app import sogo
    assert sogo.SOGoWeb  # Abruf gibt es, die Routen sagen im Dienst aber nein
    from app import sogo_api
    with pytest.raises(Exception) as e:
        sogo_api._guard()
    assert getattr(e.value, "status_code", None) == 404 and "nie über den StudiNow-Dienst" in str(e.value.detail)


def test_login_window_target_and_session_name(monkeypatch):
    from app import sogo, unilogin
    key, name, url, check, profile = unilogin._target("sogo")
    assert (key, name, url) == ("sogo", "SOGO_COOKIES", "https://kalender.uni-hannover.de/SOGo/")
    assert profile.name == "browser-profile-sogo"

    class P:
        url = f"{UB}/Calendar/view"
    assert check(P()) is True
    P.url = "https://kalender.uni-hannover.de/SOGo/"
    assert check(P()) is False
    assert unilogin._cookie_urls("sogo") == [sogo.BASE + "/"]
    calls = []

    def http(method, url, data, headers):
        calls.append(url)
        return 200, b"<html>angemeldet</html>", f"{UB}/Calendar/view", {}
    assert sogo.discover_user(COOKIES, http) == USER
    assert calls == ["https://kalender.uni-hannover.de/SOGo/so/"]
    assert sogo.discover_user([], http) is None


# ---------------------------------------------------------------------------------------------- Uni Hildesheim (06.11.2026)

HI = "webmail.uni-hildesheim.de"
HI_USER = "muster"
HI_COOKIES = [{"name": "0xHIGHFLYxSOGo", "value": "sitzung", "domain": HI, "path": "/SOGo"},
              {"name": "XSRF-TOKEN", "value": "hi%2B2", "domain": HI, "path": "/SOGo"},
              {"name": "0xHIGHFLYxSOGo", "value": "luh", "domain": "kalender.uni-hannover.de", "path": "/SOGo"}]


def test_sites_from_cases():
    from app import sogo
    c = json.loads((FX / "cases.json").read_text(encoding="utf-8"))["sites"]
    assert [s["host"] for s in c["list"]] == ["kalender.uni-hannover.de", HI]
    assert [s["name"] for s in c["list"]] == ["Uni-Mail (LUH)", "Uni-Mail (Uni Hildesheim)"]
    assert c["hsh"] is None and sogo.site("hsh") is None and sogo.site("unbekannt") is None
    for key, chk in c["checks"].items():
        host = sogo.SITES[key]["host"]
        for x in chk["user_from_url"]:
            assert sogo.user_from_url(x["url"], host) == x["user"], (key, x["url"])
            if x["user"] is not None:
                assert host in x["url"].lower(), "nur der eigene Rechner"
        for x in chk["attachment_path"]:
            assert sogo.attachment_path(x["in"], host) == x["out"], (key, x["in"])
    hi = c["checks"]["hildesheim"]
    assert [x["user"] for x in hi["user_from_url"][:3]] == [HI_USER, "erika.muster@uni-hildesheim.de", HI_USER]
    assert all(x["user"] is None for x in hi["user_from_url"][3:]), "andere Rechner, http, Port, LUH abgelehnt"
    assert [a["name"] for a in hi["message_attachments"]] == ["a.pdf", "hi.pdf"]
    assert [a["name"] for a in c["checks"]["luh"]["message_attachments"]] == ["a.pdf", "luh.pdf"]
    assert [x["expired"] for x in hi["expired"]] == [False, False, False, True]


def test_hildesheim_client_only_talks_to_its_host():
    from app import sogo
    calls = []

    def http(method, url, data, headers):
        calls.append((url, headers))
        return 200, json.dumps(raw("mailboxes.json")).encode(), url, {"content-type": "application/json"}
    w = sogo.SOGoWeb(HI_USER, HI_COOKIES, http=http, host=HI)
    assert w.base == f"https://{HI}/SOGo/so/{HI_USER}"
    assert w.mailboxes()[0]["type"] == "inbox"
    url, headers = calls[-1]
    assert url == f"https://{HI}/SOGo/so/{HI_USER}/Mail/0/view"
    assert headers["X-XSRF-TOKEN"] == "hi+2" and headers["Cookie"] == "0xHIGHFLYxSOGo=sitzung; XSRF-TOKEN=hi%2B2", "nur Cookies dieses Rechners"
    with pytest.raises(sogo.SOGoError) as e:
        w._req("GET", "https://kalender.uni-hannover.de/SOGo/so/x/Mail/0/view")
    assert e.value.code == "bad"
    # Anhang eines anderen Rechners wird nicht geladen
    with pytest.raises(sogo.SOGoError):
        w.attachment(f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/folderINBOX/1/2/asAttachment/a.pdf")
    # Weiterleitung auf den Rechner der LUH gilt als abgelaufen (fremder Rechner)
    w.http = lambda m, u, d, h: (200, b"{}", f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/view", {"content-type": "application/json"})
    with pytest.raises(sogo.SOGoError) as e:
        w.mailboxes()
    assert e.value.code == "login"


def test_hildesheim_login_window_status_and_live(app, monkeypatch, tmp_path):
    from app import config, db, sogo, unilogin
    monkeypatch.setattr(config, "UNIVERSITY", "hildesheim")
    monkeypatch.setattr(config, "MODE", "single")
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "hi.db")
    db.init_db()
    key, name, url, check, _ = unilogin._target("sogo")
    assert (key, name, url) == ("sogo", "SOGO_COOKIES", f"https://{HI}/SOGo/")

    class P:
        url = f"https://{HI}/SOGo/so/{HI_USER}/Mail/view"
    assert check(P()) is True
    P.url = f"{UB}/Calendar/view"
    assert check(P()) is False, "LUH-Adresse zaehlt an der Uni Hildesheim nicht"
    assert unilogin._cookie_urls("sogo") == [f"https://{HI}/SOGo/"]
    calls = []

    def http(method, u, data, headers):
        calls.append(u)
        return 200, b"<html>angemeldet</html>", f"https://{HI}/SOGo/so/{HI_USER}/Calendar/view", {}
    assert sogo.discover_user(HI_COOKIES, http) == HI_USER
    assert calls == [f"https://{HI}/SOGo/so/"]
    st, d = _j(asgi_call(app, "GET", "/api/sogo/status"))
    assert st == 200 and d["available"] is True and d["university"] == "hildesheim" and d["name"] == "Uni-Mail (Uni Hildesheim)"
    assert d["room_links"] is False and d["host"] == HI and "Uni Hildesheim" in d["hint"]
    monkeypatch.setattr(unilogin, "saved_cookies", lambda n: HI_COOKIES)
    monkeypatch.setattr(sogo, "saved_user", lambda: HI_USER)
    w = sogo.live(http=FakeSOGo())
    assert w.host == HI and w.base.startswith(f"https://{HI}/")


def test_hsh_has_no_uni_mail(app, monkeypatch, tmp_path):
    from app import config, db, sogo
    monkeypatch.setattr(config, "UNIVERSITY", "hsh")
    monkeypatch.setattr(config, "MODE", "single")
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "hsh.db")
    db.init_db()
    st, d = _j(asgi_call(app, "GET", "/api/sogo/status"))
    assert st == 200 and d["available"] is False and d["university"] is None and d["room_links"] is False
    st, d = _j(asgi_call(app, "POST", "/api/sogo/login"))
    assert st == 404 and d["code"] == "not_available"
    with pytest.raises(sogo.SOGoError) as e:
        sogo.live()
    assert e.value.code == "refused"
    assert sogo.discover_user(HI_COOKIES, lambda *a: (_ for _ in ()).throw(AssertionError("kein Abruf"))) is None


def test_luh_status_names_luh(app, monkeypatch, tmp_path):
    from app import config, db
    monkeypatch.setattr(config, "UNIVERSITY", "luh")
    monkeypatch.setattr(config, "MODE", "single")
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "luh.db")
    db.init_db()
    st, d = _j(asgi_call(app, "GET", "/api/sogo/status"))
    assert d["available"] is True and d["university"] == "luh" and d["name"] == "Uni-Mail (LUH)" and d["room_links"] is True
