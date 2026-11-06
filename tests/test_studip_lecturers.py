"""Lehrende und Kontakte (LUH, Stud.IP), 06.11.2026 (app/studip_lecturers.py, docs/LEHRENDE-KONTAKTE-2026-11-06.md):
Lesen nur der Rollen Dozent/in und Tutor/in, E-Mail nur wenn plausibel, Sprechzeiten, Abruf nach Stufe (a), je Kurs
hoechstens alle 7 Tage, nur an der LUH, nie im Dienst, Nachricht ueber Stud.IP nur an Lehrende der eigenen Kurse.
Gemeinsame Fixture packages/shared-contracts/fixtures/studip-lecturers/lecturers.json (erfundene Namen, example.org).
Stud.IP ist ersetzt; es gibt keine echte Anfrage."""
import json
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = json.loads((ROOT / "packages/shared-contracts/fixtures/studip-lecturers/lecturers.json").read_text(encoding="utf-8"))


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-studip-lecturers-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_only_lecturers_and_tutors_never_students():
    from app import studip_lecturers as L
    first = FX["members"][0]
    items = L.parse_members(first["response"])
    assert [(m["user_id"], m["role"]) for m in items] == [("u-prof", "dozent"), ("u-doz2", "dozent")]
    assert "kommi" not in json.dumps(FX["sync"]["after"]), "Studierende werden nie gespeichert"
    assert items[0]["email"] == "erika.beispiel@example.org" and items[1]["email"] == ""
    assert all("example.org" in m["email"] for m in sum((x["items"] for x in FX["members"]), []) if m["email"])


def test_rules():
    from app import studip_lecturers as L
    for c in FX["clean_email"]:
        assert L.clean_email(c["value"]) == c["email"]
    for c in FX["display_name"]:
        assert L.display_name(c["attrs"]) == c["name"]
    assert L.role_label(["tutor", "dozent"]) == "Dozent/in, Tutor/in"
    assert L.message_url("https://studip.test/", "a b") == "https://studip.test/dispatch.php/messages/write?rec_uname=a%20b"
    assert L.mailto("") is None
    prof = next(p for p in FX["profiles"] if p["path"].startswith("users/u-prof"))
    assert prof["parsed"] == {"office_hours": "Di 10–11 Uhr\nund nach Vereinbarung", "location": "Raum F 303 (1101)",
                              "institute": "Institut für Testmathematik"}, "Standard-Einrichtung vor der anderen"


def test_sync_order_ttl_and_missing_route():
    s = FX["sync"]
    assert s["requests"][0].endswith("&include=user") and s["result"]["courses"] == 4
    assert s["second"]["requests"] == [], "am selben Tag keine zweite Anfrage"
    assert not any(r.startswith(("users/u-tut1/institute", "users/u-tut2/institute")) for r in s["requests"]), "Sprechzeiten nur fuer Dozent/innen"
    assert "courses/k-neu/memberships" not in " ".join(s["requests"]), "vor 2 Tagen gelesen: nicht dran"
    assert ["k-zu", "2026-11-06T10:00:00+01:00"] in s["after"]["studip_lecturer_courses"], "403: als leer gemerkt"
    m = FX["sync_missing"]
    assert m["again"]["requests"] == 0 and json.loads(m["settings"][0][1]) == {"course-memberships": "2026-11-06"}


def test_due_after_seven_days():
    from app import studip_lecturers as L
    assert [d["due"] for d in FX["due"]] == [["a", "b"], ["a", "c", "d"]], "kaputter Stand: neu lesen"
    assert L.REFRESH_DAYS == 7


def test_overview_hides_for_hsh_hildesheim_and_service():
    by = {json.dumps(o["query"], sort_keys=True): o["result"] for o in FX["overview"]}
    assert by['{"university": "hsh"}']["available"] is False
    assert by['{"course_id": "k-ana", "university": "hildesheim"}']["people"] == []
    assert by['{"allowed": false, "university": "luh"}']["available"] is False
    allp = by['{"university": "luh"}']
    assert "u-alt" not in [p["id"] for p in allp["people"]], "fruehere Semester nicht in der Liste"
    course = by['{"course_id": "k-ana", "university": "luh"}']
    assert [p["id"] for p in course["people"]] == ["u-prof", "u-doz2", "u-tut1"], "Dozent/innen vor Tutor/innen"
    assert course["people"][1]["no_email"] == "Nachricht über Stud.IP" and course["people"][1]["mailto"] is None
    assert by['{"q": "zzz", "university": "luh"}']["hint"] == "Keine Lehrenden gefunden."


# ---------------------------------------------------------------- Routen

@pytest.fixture
def seeded(app, monkeypatch, tmp_path):
    from app import db, studip_lecturers as L
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "lehrende.db")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'luh')")
        conn.execute("INSERT INTO modules(id, name) VALUES (1, 'Analysis I')")
        conn.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('k-ana', 'Analysis I – Vorlesung', 1, 1)")
        L.store_course(conn, "k-ana", [{"user_id": "u-prof", "role": "dozent", "position": 0, "label": "", "name": "Prof. Dr. Erika Beispiel",
                                        "username": "beispiel", "email": "erika.beispiel@example.org"}], "2026-11-06T10:00:00+01:00")
    return db


def test_route_lists_and_filters(app, seeded):
    st, d = _j(asgi_call(app, "GET", "/api/lecturers?module_id=1"))
    assert st == 200 and d["available"] is True and d["people"][0]["email"] == "erika.beispiel@example.org"
    assert d["people"][0]["message_url"].endswith("/dispatch.php/messages/write?rec_uname=beispiel")
    st, d = _j(asgi_call(app, "GET", "/api/lecturers?q=beisp"))
    assert d["count"] == 1
    st, d = _j(asgi_call(app, "GET", "/api/lecturers?course_id=k-ana&q=nein"))
    assert d["count"] == 0 and d["total"] == 1


def test_route_in_service_shows_nothing(app, seeded, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    st, d = _j(asgi_call(app, "GET", "/api/lecturers"))
    assert st == 401 or (st == 200 and d["available"] is False and d["people"] == []), "im Dienst nie Adressen"
    from app import db, studip_lecturers as L
    with db.cursor() as conn:
        assert L.overview(conn, "luh", config.STUDIP_BASE, allowed=not config.is_hosted())["people"] == []


def test_route_hsh_hides(app, seeded):
    with seeded.cursor() as conn:
        conn.execute("UPDATE settings SET value='hsh' WHERE key='university'")
    st, d = _j(asgi_call(app, "GET", "/api/lecturers"))
    assert d["available"] is False


def test_message_only_to_known_lecturers(app, seeded, monkeypatch):
    from app import studip_live, studip_reply
    sent = []
    monkeypatch.setattr(studip_live, "available", lambda: True)
    monkeypatch.setattr(studip_reply, "send", lambda s, t, ids: sent.append((s, t, ids)) or "n1")
    st, d = _j(asgi_call(app, "POST", "/api/lecturers/fremd/message", body=json.dumps({"subject": "x", "text": "y"})))
    assert st == 404 and sent == []
    st, d = _j(asgi_call(app, "POST", "/api/lecturers/u-prof/message", body=json.dumps({"subject": "Frage", "text": " "})))
    assert st == 400
    st, d = _j(asgi_call(app, "POST", "/api/lecturers/u-prof/message", body=json.dumps({"subject": "Frage zu Blatt 3", "text": "Hallo"})))
    assert st == 200 and d["sent"] is True and sent == [("Frage zu Blatt 3", "Hallo", ["u-prof"])]
    monkeypatch.setattr(studip_reply, "send", lambda s, t, ids: (_ for _ in ()).throw(studip_reply.ReplyError("security_token", 403)))
    st, d = _j(asgi_call(app, "POST", "/api/lecturers/u-prof/message", body=json.dumps({"subject": "a", "text": "b"})))
    assert st == 409 and d["code"] == "reply_security_token" and d["web_url"].endswith("rec_uname=beispiel")
    assert "Schreib bitte direkt in Stud.IP" in d["detail"]


def test_sync_runs_only_after_the_current_semester_is_ready():
    src = (ROOT / "app" / "studip_sync.py").read_text(encoding="utf-8")
    assert src.index("sync_order.mark_current_ready(conn") < src.index("studip_lecturers.sync(")


def test_sync_in_service_is_off(monkeypatch):
    from app import config, studip_lecturers as L
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    assert L.lecturers_allowed() is False
