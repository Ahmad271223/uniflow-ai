"""Demo-Inhalte (app/demo.py): anlegen, in Bibliothek/Stundenplan/Kalender/Fristen/Ankuendigungen sichtbar, PDFs echt und
lesbar, nicht als Hochschuldatei (Community/Stream), rueckstandslos entfernbar, je Konto im Dienst."""
import io
import json

from conftest import asgi_call


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


def test_demo_install_is_visible_everywhere_and_removes_cleanly(app):
    from app import db, demo
    from pypdf import PdfReader
    st, d = _j(asgi_call(app, "GET", "/api/demo"))
    assert st == 200 and d["enabled"] is False and d["files"] == 0
    st, d = _j(asgi_call(app, "POST", "/api/demo", body=json.dumps({"enabled": True})))
    assert st == 200 and d["enabled"] and (d["files"], d["events"], d["packages"]) == (3, 3, 3)
    # Bibliothek: drei PDFs im Demo-Modul, Inhalt lesbar, Fingerabdruck gesetzt, Seitentext per API
    st, lib = _j(asgi_call(app, "GET", "/api/library"))
    files = [f for f in lib["files"] if f["id"].startswith("demo-")]
    assert len(files) == 3 and all(f["kind"] == "pdf" and f["source"] == "studip" and f["content_sha256"] for f in files)
    assert any(m["name"] == demo.MODULE_NAME for m in lib["modules"])
    st, _, body = asgi_call(app, "GET", "/api/files/demo-skript/content")
    assert st == 200 and body.startswith(b"%PDF") and len(PdfReader(io.BytesIO(body)).pages) == 3
    assert "Zahlensysteme" in PdfReader(io.BytesIO(body)).pages[0].extract_text()
    st, d = _j(asgi_call(app, "GET", "/api/files/demo-blatt/pagetext?page=1"))
    assert st == 200 and "Aufgabe 1" in d["text"] and d["pages"] == 2
    # Stundenplan und Kalender
    from datetime import date, timedelta
    monday = date.today() - timedelta(days=date.today().weekday())
    st, week = _j(asgi_call(app, "GET", f"/api/timetable/week?start={monday.isoformat()}"))
    assert st == 200
    titles = json.dumps(week, ensure_ascii=False)
    assert "Grundlagen der Informatik – Vorlesung" in titles and "Grundlagen der Informatik – Übung" in titles
    st, cal = _j(asgi_call(app, "GET", f"/api/calendar?start={monday.isoformat()}&end={(monday + timedelta(days=13)).isoformat()}"))
    assert st == 200
    cal_text = json.dumps(cal, ensure_ascii=False)
    assert "Übungsblatt 1" in cal_text and "Folien Woche 1" in cal_text
    st, dl = _j(asgi_call(app, "GET", "/api/deadlines"))
    assert st == 200 and any(x.get("deadline_id") == "demo-abgabe-1" and x["kind"] == "abgabe" for x in dl["deadlines"])
    st, an = _j(asgi_call(app, "GET", "/api/announcements"))
    assert st == 200 and "Raumwechsel" in json.dumps(an, ensure_ascii=False)
    # erneut anlegen = frisch (keine Doppel)
    st, d = _j(asgi_call(app, "POST", "/api/demo", body=json.dumps({"enabled": True})))
    assert (d["files"], d["events"], d["packages"]) == (3, 3, 3)
    with db.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM modules WHERE name=?", (demo.MODULE_NAME,)).fetchone()[0] == 1
        paths = [r["local_path"] for r in db.rows(conn, "SELECT local_path FROM files WHERE id LIKE 'demo-%'")]
    # entfernen: nichts bleibt
    st, d = _j(asgi_call(app, "POST", "/api/demo", body=json.dumps({"enabled": False})))
    assert st == 200 and d["enabled"] is False and d["removed"]["files"] == 3
    from pathlib import Path
    assert not any(Path(p).exists() for p in paths)
    with db.cursor() as conn:
        for sql in ("SELECT COUNT(*) FROM files WHERE id LIKE 'demo-%'", "SELECT COUNT(*) FROM courses WHERE id LIKE 'demo-%'",
                    "SELECT COUNT(*) FROM course_events WHERE source='demo'", "SELECT COUNT(*) FROM deadlines WHERE source='demo'",
                    "SELECT COUNT(*) FROM announcements WHERE source='demo'", f"SELECT COUNT(*) FROM modules WHERE name='{demo.MODULE_NAME}'",
                    "SELECT COUNT(*) FROM study_tasks WHERE file_id LIKE 'demo-%'"):
            assert conn.execute(sql).fetchone()[0] == 0, sql
    st, lib = _j(asgi_call(app, "GET", "/api/library"))
    assert not any(f["id"].startswith("demo-") for f in lib["files"])


def test_demo_pdf_builder_escapes_and_is_readable():
    from app import demo
    from pypdf import PdfReader
    data = demo.pdf_bytes([("Titel (mit) Klammern", ["Zeile \\ eins", "Umlaute äöü ß"])])
    r = PdfReader(io.BytesIO(data))
    t = r.pages[0].extract_text()
    assert "Titel (mit) Klammern" in t and "Zeile \\ eins" in t and "äöü" in t


def test_demo_is_per_account_and_not_a_university_file(app, monkeypatch):
    """Im Dienst liegen Demo-Inhalte im Konto, das sie anlegt; ohne Hochschulquelle zaehlen sie nicht fuer die Community."""
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    try:
        hs = []
        for mail in ("d1@beispiel.de", "d2@beispiel.de"):
            st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": mail, "password": "sehr-geheim-123", "university": "luh"}))
            hs.append({"Authorization": f"Bearer {json.loads(b)['token']}"})
        st, d = _j(asgi_call(app, "POST", "/api/demo", headers=hs[0], body=json.dumps({"enabled": True})))
        assert st == 200 and d["files"] == 3
        assert _j(asgi_call(app, "GET", "/api/demo", headers=hs[1]))[1]["enabled"] is False
        st, _, body = asgi_call(app, "GET", "/api/files/demo-skript/content", headers=hs[0])
        assert st == 200 and body.startswith(b"%PDF"), "gespeichert, nicht gestreamt (eigenes Dokument ohne Hochschulquelle)"
        assert asgi_call(app, "GET", "/api/files/demo-skript/content", headers=hs[1])[0] == 404
        from app import community
        t = config.set_user_context(json.loads(asgi_call(app, "GET", "/api/account/me", headers=hs[0])[2])["user"]["id"], "luh")
        try:
            assert not community.owns_file(d and __import__("hashlib").sha256(body).hexdigest()), "keine Datei aus dem Hochschul-Abgleich"
        finally:
            config.reset_user_context(t)
        assert _j(asgi_call(app, "POST", "/api/demo", headers=hs[0], body=json.dumps({"enabled": False})))[1]["enabled"] is False
    finally:
        accounts.db_path().unlink(missing_ok=True)
