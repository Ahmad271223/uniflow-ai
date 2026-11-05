"""Seite "Nachrichten" (app/studip_messages.py, 05.11.2026): der lokal gespeicherte Stud.IP-Posteingang wie
`StudIPExtras.messageList` / `MessagesInbox` der iPad-App: neueste zuerst nach Zeitpunkt, Suche ohne Gross-/Kleinschreibung
und Akzente, Zaehler "neu seit dem letzten Besuch", Menuepunkt nur lokal; nie im Dienst, nie im Offline-Speicher, nur die
Liste (nie die Einzelansicht)."""
import json
import re
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


def _msg(i, sent, subject, text="", sender="Lehrende", dates=None):
    return {"id": f"sp-msg-{i}", "sender": sender, "subject": subject, "preview": text, "sent_at": sent,
            "url": "https://studip.uni-hannover.de/dispatch.php/messages/overview", "dates": dates or []}


@pytest.fixture
def inbox(app):
    """Vier Nachrichten im Posteingang (gemischte Zeitzonen-Versaetze), danach wieder leer."""
    from app import db, studip_extras
    db.init_db()
    items = [
        _msg(1, "2026-11-02T08:15:00+01:00", "Tutorium entfällt", "Das Tutorium am 12.11. fällt aus.\nBitte Blatt 3 allein bearbeiten.",
             dates=[{"date": "2026-11-12", "time": None, "kind": "ausfall"}]),
        _msg(2, "2026-11-04T10:00:00+01:00", "Prüfung angemeldet", "Anmeldung zur Klausur bestätigt.", sender="Verwaltung",
             dates=[{"date": "2026-11-19", "time": "12:00", "kind": "pruefung"}]),
        _msg(3, "2026-10-31T09:00:00+00:00", "Willkommen", "Hallo zusammen", sender="Stud.IP"),
        _msg(4, "2026-11-04T09:30:00+00:00", "Zeitzone", "gleicher Tag, andere Zone"),         # = 10:30 +01:00, nach Nr. 2
    ]
    with db.cursor() as conn:
        studip_extras.store_messages(conn, items, "2026-11-05T07:30:00+00:00")
        conn.execute("DELETE FROM settings WHERE key='messages_seen_up_to'")
    yield items
    with db.cursor() as conn:
        conn.execute("DELETE FROM studip_messages")
        conn.execute("DELETE FROM settings WHERE key='messages_seen_up_to'")


def test_list_is_newest_first_by_instant_not_by_text(app, inbox):
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert st == 200 and d["total"] == 4 and d["q"] == "" and d["fetched_at"] == "2026-11-05T07:30:00+00:00"
    # Nr. 4 (09:30 UTC = 10:30 MEZ) liegt nach Nr. 2 (10:00 MEZ), obwohl der Text "09:30" kleiner ist
    assert [m["id"] for m in d["messages"]] == ["sp-msg-4", "sp-msg-2", "sp-msg-1", "sp-msg-3"]
    m = d["messages"][2]
    assert set(m) == {"id", "sender", "subject", "text", "sent_at", "url", "dates", "recipients", "replyable", "replies", "reply_url"}
    assert m["text"].startswith("Das Tutorium am 12.11.") and "\nBitte Blatt 3" in m["text"], "ganzer Text, Zeilenumbrueche bleiben"
    assert m["dates"] == [{"date": "2026-11-12", "time": None, "kind": "ausfall"}]
    assert m["url"].endswith("/dispatch.php/messages/overview"), "Link auf den Posteingang, nie auf eine Einzelansicht"


def test_search_needs_every_word_ignores_case_and_accents(app, inbox):
    def ids(q):
        st, d = _j(asgi_call(app, "GET", "/api/studip/messages?q=" + q))
        assert st == 200 and d["total"] == 4
        return [m["id"] for m in d["messages"]]
    assert ids("PRUFUNG") == ["sp-msg-2"], "ohne Akzente und Gross-/Kleinschreibung"
    assert ids("tutorium%20blatt") == ["sp-msg-1"], "jedes Wort muss vorkommen (hier im Text)"
    assert ids("verwaltung") == ["sp-msg-2"], "Absender zaehlt"
    assert ids("tutorium%20klausur") == []
    assert ids("%20%20") == ["sp-msg-4", "sp-msg-2", "sp-msg-1", "sp-msg-3"], "nur Leerzeichen = keine Suche"


def test_new_counter_and_seen_mark(app, inbox):
    st, s = _j(asgi_call(app, "GET", "/api/studip/messages/status"))
    assert st == 200 and s["stored"] == 4 and s["new_count"] == 4, "nie geoeffnet: alle neu"
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert d["seen_up_to"] is None and d["new_count"] == 4
    st, s = _j(asgi_call(app, "POST", "/api/studip/messages/seen"))
    assert st == 200 and s["new_count"] == 0
    st, d = _j(asgi_call(app, "GET", "/api/studip/messages"))
    assert d["seen_up_to"] == "2026-11-04T09:30:00+00:00", "Marke = juengste Nachricht (nach Zeitpunkt)"
    # eine spaeter abgeglichene, neuere Nachricht zaehlt wieder; eine aeltere nicht
    from app import db, studip_extras
    with db.cursor() as conn:
        more = [_msg(5, "2026-11-05T08:00:00+01:00", "Neu heute"), _msg(6, "2026-10-01T08:00:00+02:00", "Alt")]
        studip_extras.store_messages(conn, [_msg(i["id"][len("sp-msg-"):], i["sent_at"], i["subject"]) for i in inbox] + more, "2026-11-05T08:00:00+00:00")
    st, s = _j(asgi_call(app, "GET", "/api/studip/messages/status"))
    assert s["stored"] == 6 and s["new_count"] == 1
    # die Marke geht nie zurueck
    from app import studip_messages
    with db.cursor() as conn:
        studip_messages.mark_seen(conn)
        assert studip_messages.seen_mark(conn) == "2026-11-05T08:00:00+01:00"
        conn.execute("DELETE FROM studip_messages WHERE id='sp-msg-5'")
        assert studip_messages.mark_seen(conn) == "2026-11-05T08:00:00+01:00"


def test_rules_match_the_ipad_app():
    from app import studip_messages as sm
    assert sm.is_new("2026-11-02T08:00:00+01:00", None) and not sm.is_new("", "2026-11-02T08:00:00+01:00")
    assert sm.is_new("2026-11-02T07:30:00+00:00", "2026-11-02T08:00:00+01:00"), "07:30 UTC ist nach 07:00 UTC"
    assert not sm.is_new("2026-11-02T08:00:00+01:00", "2026-11-02T07:00:00+00:00"), "gleicher Zeitpunkt"
    assert sm.is_new("zzz", "aaa") and not sm.is_new("aaa", "zzz"), "ohne lesbaren Zeitpunkt der Text"
    assert sm.instant("2026-11-02T08:15:00.5+01:00") is not None and sm.instant("2026-11-02T08:15:00") is None
    assert sm.newest([{"sent_at": "2026-11-02T08:00:00+01:00"}, {"sent_at": "2026-11-02T07:30:00+00:00"}, {"sent_at": ""}]) == "2026-11-02T07:30:00+00:00"
    assert sm.shows_nav_item(True, True, True, 0) and sm.shows_nav_item(True, False, False, 3)
    assert not sm.shows_nav_item(True, True, False, 0) and not sm.shows_nav_item(True, False, True, 0), "Hildesheim: kein Stud.IP"
    assert not sm.shows_nav_item(False, True, True, 5), "nie im Dienst"


def test_nav_item_follows_connection_and_storage(app, inbox, monkeypatch):
    from app import studip_messages as sm
    monkeypatch.setattr(sm, "stud_ip_connected", lambda: False)
    st, s = _j(asgi_call(app, "GET", "/api/studip/messages/status"))
    assert s["available"] is True, "gespeicherte Nachrichten zeigen den Menuepunkt auch ohne Verbindung"
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM studip_messages")
    st, s = _j(asgi_call(app, "GET", "/api/studip/messages/status"))
    assert s == {"available": False, "stored": 0, "new_count": 0}
    monkeypatch.setattr(sm, "stud_ip_connected", lambda: True)
    assert _j(asgi_call(app, "GET", "/api/studip/messages/status"))[1]["available"] is True
    monkeypatch.setattr(sm, "stud_ip_offered", lambda: False)             # Hochschule ohne Stud.IP (Hildesheim)
    assert _j(asgi_call(app, "GET", "/api/studip/messages/status"))[1]["available"] is False


def test_connected_means_saved_session_or_credentials(app, monkeypatch):
    from app import config, studip_messages as sm, unilogin
    monkeypatch.setattr(config, "credentials", lambda: ("", ""))
    unilogin.forget()
    assert sm.stud_ip_connected() is False
    unilogin.save_session("STUDIP_COOKIES", [{"name": "Seminar_Session", "value": "x", "domain": "studip.uni-hannover.de", "expires": 1}])   # abgelaufen zaehlt als verbunden
    assert sm.stud_ip_connected() is True
    unilogin.forget()
    monkeypatch.setattr(config, "credentials", lambda: ("abc", "geheim"))
    assert sm.stud_ip_connected() is True


def test_hosted_service_never_shows_or_stores_messages(app, inbox, monkeypatch):
    """Im Dienst: leer, kein Menuepunkt, auch wenn (alte) Zeilen in der Datenbank liegen."""
    from app import config
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    from app import studip_messages as sm
    monkeypatch.setattr(sm, "stud_ip_connected", lambda: True)
    from app import db
    with db.cursor() as conn:
        d = sm.message_list(conn, "")
        assert d["messages"] == [] and d["total"] == 0 and d["available"] is False
        assert sm.status(conn) == {"available": False, "stored": 0, "new_count": 0}


def test_messages_stay_local_and_out_of_the_offline_cache(app):
    """Datenschutz: Pfade im Offline-Speicher gesperrt, Marke nicht im Geraete-Abgleich, nur die Liste wird gelesen."""
    policy = (ROOT / "app/static/sw-policy.js").read_text(encoding="utf-8")
    assert r"/^\/api\/news(\/|$)/" in policy and r"/^\/api\/studip\/messages(\/|$)/" in policy
    from app import sync_client
    assert sync_client._setting_local("messages_seen_up_to")
    src = (ROOT / "app/studip_messages.py").read_text(encoding="utf-8")
    assert not re.search(r"urllib|requests|playwright|httpx|page\.request|http\.client|socket", src), "die Seite liest nur lokal, nie von Stud.IP"
    extras = (ROOT / "app/studip_extras.py").read_text(encoding="utf-8")
    assert "users/{uid}/inbox?" in extras and "messages/" not in extras.replace("messages/overview", ""), "nur die Liste, nie eine Einzelansicht"
