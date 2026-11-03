"""Lernstoff aus Stud.IP (app/studip_texts.py, 2.11.2026): Vertrag fuer das iPad, Datenschutz im Forum, Endpunkte
der Modulansicht, Quellen fuer KI-Hilfe, Skriptsuche und Wochentest."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-texts" / "texte.json"


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-studip-texts-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", timeout=300)
    assert r.returncode == 0, f"python tools/gen-studip-texts-fixture.py neu ausfuehren\n{r.stdout}\n{r.stderr}"


def test_fixture_runs_say_what_the_owner_asked_for():
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    runs = {r["name"]: r for r in fx["runs"]}
    first, second, later = runs["erst"], runs["zweit"], runs["spaeter"]
    # Fristen: offen und verlaengert, abgegebene nicht, Quelle Stud.IP Courseware mit Link
    assert [(d["id"], d["due_at"]) for d in first["deadlines"]] == [
        ("sp-cw-t1", "2026-11-12T23:59"), ("sp-cw-t3", "2026-11-26T12:30"), ("sp-cw-t4", "2026-12-01T23:59")]
    assert all(d["source"] == "studip" and d["module"] == "courseware" and d["kind"] == "abgabe" and "courseware/tasks?cid=" in d["url"]
               for d in first["deadlines"])
    # Aenderungserkennung: der zweite Lauf laedt keinen Inhalt neu und fragt Fehlendes nicht erneut
    assert second["result"]["texts"] == 0 and second["requests"] < first["requests"]
    assert not any("c-prog/wiki-pages" in p or "c-prog/courseware-units" in p for p in second["log"])
    # nach 14 Tagen wird wieder geprueft; was Stud.IP nicht mehr liefert, verschwindet
    assert "wiki-w2" not in [t["id"] for t in later["texts"]] and later["result"]["texts"] == 3
    # Grenze: Teilstand, nichts geloescht
    assert runs["knapp"]["requests"] == 5 and runs["knapp"]["stopped"]
    # nirgends vorhanden: an der Hochschule gemerkt, danach keine Anfrage. Forum: 404 heisst "noch keine Kategorie im
    # Kurs" (je Kurs gemerkt), nie "an der Hochschule nicht vorhanden"
    assert {s["key"] for s in runs["fehlt"]["state"]} >= {"absent|tasks", "absent|courseware", "absent|wiki", "absent|forum|x-1", "absent|forum|x-2"}
    assert "absent|forum" not in {s["key"] for s in runs["fehlt"]["state"]}
    assert runs["fehlt-danach"]["requests"] == 0
    # Datenschutz: kein Autorenname, kein Zitat mit Namen, keine Erwaehnung
    forum = next(t for t in first["texts"] if t["kind"] == "forum")
    assert "Mustermann" not in forum["text"] and "lisa" not in forum["text"] and "Cauchy-Kriterium" in forum["text"]
    # nur lesen: jede Anfrage ist ein GET-Pfad der JSON:API, nichts markiert oder abonniert
    for r in fx["runs"]:
        assert all(p.startswith("/jsonapi.php/v1/") for p in r["log"])
        assert len(r["log"]) <= fx["max_requests"]


def _seed(conn):
    from app import studip_texts as st
    mid = conn.execute("INSERT INTO modules(name) VALUES ('Lernstoff-Test')").lastrowid
    conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('lt-kurs', 'Testanalysis', ?, 1)", (mid,))
    d = {"courses": [{"course_id": "lt-kurs", "complete": {k: True for k in st.KINDS}, "seen": {k: [] for k in st.KINDS},
                      "deadlines": None, "deadlines_complete": False,
                      "rows": [{"id": "wiki-lt", "kind": "wiki", "title": "Klausurinfos", "text": "Klausur am Termin mit Hilfsmittel Formelsammlung",
                                "url": "https://studip.test/w", "changed": "2026-10-20T12:00:00+02:00"},
                               {"id": "cw-lt", "kind": "courseware", "title": "Grenzwerte", "text": "Konvergenz einer Folge und Grenzwert der Folge",
                                "url": "https://studip.test/c", "changed": "2026-10-30T10:00:00+01:00"}]}],
         "state_set": {}, "state_del": []}
    st.store(conn, d, "2026-11-02T09:00:00")
    return mid


def _cleanup(conn, mid):
    conn.execute("DELETE FROM studip_texts WHERE course_id='lt-kurs'")
    conn.execute("DELETE FROM courses WHERE id='lt-kurs'")
    conn.execute("DELETE FROM modules WHERE id=?", (mid,))


def test_module_endpoints_overview_and_reader(app):
    from app import db
    db.init_db()
    with db.cursor() as conn:
        mid = _seed(conn)
    try:
        st, _, b = asgi_call(app, "GET", f"/api/modules/{mid}/studip")
        d = json.loads(b)
        assert st == 200 and d["total"] == 2
        assert [(g["kind"], g["count"], g["changed"]) for g in d["groups"]] == [("courseware", 1, "2026-10-30"), ("wiki", 1, "2026-10-20")]
        st, _, b = asgi_call(app, "GET", "/api/studip-texts/wiki-lt")
        x = json.loads(b)
        assert st == 200 and x["kind_label"] == "Wiki" and x["course_title"] == "Testanalysis" and "Formelsammlung" in x["text"]
        st, _, _ = asgi_call(app, "GET", "/api/studip-texts/gibt-es-nicht")
        assert st == 404
    finally:
        with db.cursor() as conn:
            _cleanup(conn, mid)


def test_sources_for_tutor_and_weekly_test(app):
    from app import ai, db, studip_texts, weekly
    db.init_db()
    with db.cursor() as conn:
        mid = _seed(conn)
        try:
            src = studip_texts.tutor_sources(conn, mid, "Konvergenz der Folge", 2)
            assert [(s["n"], s["studip_id"], s["title"]) for s in src] == [(2, "cw-lt", "Courseware: Grenzwerte")]
            prompt = ai.tutor_prompt("ask", "Seite", question="Konvergenz?", sources=[{"n": 1, "file_id": "f", "title": "Blatt", "page": 1, "current": True}] + src)
            assert "[2] Courseware: Grenzwerte (Stud.IP): Konvergenz einer Folge" in prompt
            lines = studip_texts.weekly_lines(conn, mid, "Grenzwert Folge Konvergenz")
            assert lines == ["Courseware „Grenzwerte“: Konvergenz einer Folge und Grenzwert der Folge"]
            ctx = {"lecture": [], "prior": [], "tasks": [], "studip": lines}
            assert "ERGAENZEND AUS STUD.IP" in weekly._materials_block(ctx) and "- Courseware „Grenzwerte“" in weekly._materials_block(ctx)
            assert "ERGAENZEND" not in weekly._materials_block({**ctx, "studip": []})
            assert studip_texts.search(conn, mid, "Hilfsmittel Formelsammlung", kinds=("forum",)) == []
        finally:
            _cleanup(conn, mid)


def test_session_expiry_stops_and_nothing_is_written():
    from app import studip_texts as st
    calls = []

    def get(path):
        calls.append(path)
        return 401, None
    try:
        st.fetch(get, [{"id": "c1"}, {"id": "c2"}], {}, {}, date(2026, 11, 2), "https://studip.test")
        raise AssertionError("SessionExpired erwartet")
    except st.SessionExpired:
        pass
    assert len(calls) == 1
