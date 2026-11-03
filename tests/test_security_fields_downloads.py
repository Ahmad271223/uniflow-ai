"""Sicherheitspruefung 3.11.2026, Fund 10 (Terminfelder, Modulfarbe nur in fester Form) und Fund 11 (Downloads nur
ueber https:// auf dem Stud.IP- bzw. Learnweb-Host, auch nach Weiterleitungen)."""
import json

import pytest
from conftest import asgi_call


def _post(app, path, body, method="POST"):
    st, _, b = asgi_call(app, method, path, body=json.dumps(body))
    return st, (json.loads(b) if b else None)


@pytest.fixture
def no_leftovers(app):
    """Termine und Module dieser Tests wieder entfernen (gemeinsame Testdatenbank, andere Tests rechnen freie Zeit)."""
    from app import db
    with db.cursor() as conn:
        ev = conn.execute("SELECT COALESCE(MAX(id), 0) FROM course_events").fetchone()[0]
        mod = conn.execute("SELECT COALESCE(MAX(id), 0) FROM modules").fetchone()[0]
    yield app
    with db.cursor() as conn:
        conn.execute("DELETE FROM event_exceptions WHERE event_id > ?", (ev,))
        conn.execute("DELETE FROM course_events WHERE id > ?", (ev,))
        conn.execute("DELETE FROM modules WHERE id > ?", (mod,))


def test_event_fields_are_whitelisted(no_leftovers):
    app = no_leftovers
    ok = {"title": "VL", "kind": "vorlesung", "weekday": 1, "start_time": "08:15", "end_time": "09:45", "color": "#175ee8"}
    st, ev = _post(app, "/api/timetable/events", ok)
    assert st == 200, ev
    for bad in ({"kind": "<img src=x onerror=alert(1)>"}, {"color": "red;background:url(//boese)"}, {"start_time": "8:00\"><script>"},
                {"end_time": "25:00"}, {"source": "<b>x</b>"}):
        assert _post(app, "/api/timetable/events", {**ok, **bad})[0] == 400, bad
        if "source" not in bad:
            assert _post(app, f"/api/timetable/events/{ev['id']}", bad, "PATCH")[0] == 400, bad
    assert _post(app, f"/api/timetable/events/{ev['id']}", {"kind": "uebung", "color": "#167535"}, "PATCH")[0] == 200


def test_import_confirm_checks_kind_and_times(no_leftovers):
    app = no_leftovers
    e = {"title": "Uebung", "kind": "javascript:alert(1)", "weekday": 2, "start_time": "10:00", "end_time": "11:30"}
    st, res = _post(app, "/api/timetable/import/confirm", {"entries": [e], "source": "manual"})
    assert st == 200, res
    rows = json.loads(asgi_call(app, "GET", "/api/timetable/events")[2])
    assert all(r["kind"] in ("uebung", "vorlesung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar", "sonstiges", "persoenlich")
               for r in rows)
    assert _post(app, "/api/timetable/import/confirm", {"entries": [{**e, "start_time": "x"}], "source": "manual"})[0] == 400
    assert _post(app, "/api/timetable/import/confirm", {"entries": [e], "source": "<script>"})[0] == 400


def test_module_color_is_whitelisted(no_leftovers):
    app = no_leftovers
    st, m = _post(app, "/api/modules", {"name": "Farbtest", "color": "#e95905"})
    assert st == 200
    assert _post(app, "/api/modules", {"name": "Boese", "color": "x\" onmouseover=\"alert(1)"})[0] == 400
    assert _post(app, f"/api/modules/{m['id']}", {"color": "url(javascript:alert(1))"}, "PATCH")[0] == 400
    assert _post(app, f"/api/modules/{m['id']}", {"color": "#0486c2"}, "PATCH")[0] == 200


def test_download_only_https_on_the_studip_host():
    from app import studip_sync
    host = studip_sync.download_hosts().pop()
    assert studip_sync.download_allowed(f"https://{host}/sendfile.php?file_id=1")
    for bad in (f"http://{host}/sendfile.php", "https://boese.example/x.pdf", f"https://{host}.boese.example/x", "file:///etc/passwd",
                f"https://user@boese.example/{host}", "javascript:alert(1)", ""):
        assert not studip_sync.download_allowed(bad), bad
    with pytest.raises(RuntimeError, match="nicht erlaubt"):
        studip_sync.stream_download(None, "https://boese.example/x.pdf", __import__("pathlib").Path("/tmp/egal.pdf"))


def test_foreign_download_url_from_studip_falls_back_to_sendfile(monkeypatch):
    from app import studip_sync
    files = [{"id": "f1", "name": "a.pdf", "download_url": "https://boese.example/steal?x=1"},
             {"id": "f2", "name": "b.pdf", "download_url": "/sendfile.php?type=0&amp;file_id=f2"}]
    page_html = '<div data-files="' + json.dumps(files).replace('"', "&quot;") + '"></div>'

    class Resp:
        def text(self):
            return page_html

    class Page:
        class request:  # noqa: N801
            @staticmethod
            def get(url):
                return Resp()
    out = studip_sync.fetch_files(Page(), "c1")
    assert out[0]["download_url"].startswith(studip_sync.STUDIP_BASE + "/sendfile.php?") and "boese" not in out[0]["download_url"]
    assert out[1]["download_url"] == studip_sync.STUDIP_BASE + "/sendfile.php?type=0&file_id=f2"


def test_redirect_to_foreign_host_is_refused():
    from app import studip_sync
    h = studip_sync._CheckedRedirect({"studip.example"})
    with pytest.raises(RuntimeError, match="nicht erlaubte"):
        h.redirect_request(None, None, 302, "Found", {}, "https://boese.example/x")


def test_learnweb_hosts():
    from app import hildesheim
    assert "www.uni-hildesheim.de" in hildesheim.download_hosts()
