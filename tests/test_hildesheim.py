"""Uni Hildesheim: Uni-Einstellung, CAS, Learnweb (Moodle), LSF-Stundenplan und -Noten.

Alle Tests laufen ohne Netzwerk. Die ICS-Beispiele haben das Format des echten LSF-Exports
(DTSTART = Semesterbeginn, Wochentag nur in BYDAY, vorlesungsfreie Tage als EXDATE).
"""
import json

import pytest
from conftest import asgi_call

COURSE_ICS = """BEGIN:VCALENDAR\r
PRODID:QIS-LSF HIS eG\r
VERSION:2.0\r
BEGIN:VTIMEZONE\r
TZID:Europe/Berlin\r
BEGIN:STANDARD\r
DTSTART:19701025T030000\r
RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r
END:STANDARD\r
END:VTIMEZONE\r
METHOD:PUBLISH\r
BEGIN:VEVENT\r
DTSTART;TZID=Europe/Berlin:20261026T160000\r
DTEND;TZID=Europe/Berlin:20261026T180000\r
RRULE:FREQ=WEEKLY;UNTIL=20270205T235900Z;INTERVAL=1;BYDAY=TH\r
EXDATE;TZID=Europe/Berlin:20261224T160000,20261231T160000,\r
LOCATION:Hs 51 / Kartoffelwaschhaus - KC.51.0.02 (Domäne)\r
UID:125321:321849\r
SUMMARY:2072 - Das perfekte Zimmer. Wohnraum als Konsumkultur\r
CATEGORIES:Seminar\r
END:VEVENT\r
END:VCALENDAR\r
"""

PLAN_ICS = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;TZID=Europe/Berlin:20261026T140000
DTEND;TZID=Europe/Berlin:20261026T160000
RRULE:FREQ=WEEKLY;UNTIL=20270201T235900Z;INTERVAL=1;BYDAY=MO
LOCATION:Gebäude G (Hauptcampus) - HC.G.3.09 (Kleiner Seminarraum)
SUMMARY:0449 - Erinnerungen\\, Erzählungen & Diskurse um Erinnerungskulturen (Zimmermann)
END:VEVENT
BEGIN:VEVENT
DTSTART;TZID=Europe/Berlin:20270118T100000
DTEND;TZID=Europe/Berlin:20270118T160000
LOCATION:
SUMMARY:1528 - Mit Kunst und Kultur arbeiten
END:VEVENT
BEGIN:VEVENT
DTSTART;TZID=Europe/Berlin:20261026T100000
DTEND;TZID=Europe/Berlin:20261026T120000
RRULE:FREQ=WEEKLY;UNTIL=20270205T235900Z;INTERVAL=1;BYDAY=TU,TH
EXDATE;TZID=Europe/Berlin:20261222T100000
EXDATE;TZID=Europe/Berlin:20261224T100000
SUMMARY:1505 - Einführung in die Sozialpädagogik I
END:VEVENT
END:VCALENDAR
"""


@pytest.fixture
def tmp_env(monkeypatch, tmp_path):
    """.env-Zugriffe auf einen Temp-Ordner umlenken (nie die echte .env des Nutzers anfassen)."""
    from app import config
    monkeypatch.setattr(config, "ROOT", tmp_path)
    return tmp_path


@pytest.fixture
def uni(app, monkeypatch):
    """Hochschule der laufenden Instanz fuer einen Test setzen (wird danach automatisch zurueckgesetzt)."""
    from app import config

    def set_uni(key):
        monkeypatch.setattr(config, "UNIVERSITY", key)
    return set_uni


# ---------------------------------------------------------------- Uni-Profile & Zugangsdaten

def test_default_university_is_luh(app):
    from app import universities
    assert universities.current_key() == "luh"
    assert universities.valid("hildesheim") and not universities.valid("tuebingen")


def test_own_credentials_never_fall_back_to_luh(tmp_env):
    from app import config
    (tmp_env / ".env").write_text("STUDIP_USER=luh123\nSTUDIP_PASSWORD=geheim\n", encoding="utf-8")
    assert config.own_credentials("HILDESHEIM") == ("", "")
    assert config.service_credentials("HILDESHEIM") == ("luh123", "geheim")   # alter Rueckfall bleibt fuer LUH-Dienste
    config.save_credentials("hiuser", "pw#1 x", "HILDESHEIM")
    assert config.own_credentials("HILDESHEIM") == ("hiuser", "pw#1 x")


def test_qis_profile_credentials(tmp_env):
    from app import qis
    (tmp_env / ".env").write_text("STUDIP_USER=luh123\nSTUDIP_PASSWORD=geheim\n", encoding="utf-8")
    assert qis.credentials_for("hildesheim") == ("", "")
    assert not qis.configured("hildesheim")
    p = qis.use_profile("hildesheim")
    assert p["base"] == "https://lsf.uni-hildesheim.de" and p["documents"] is False
    assert qis._abs("rds?state=x") == "https://lsf.uni-hildesheim.de/qisserver/rds?state=x"
    qis.use_profile("luh")
    assert qis._abs("rds?state=x").startswith("https://qis.verwaltung.uni-hannover.de/")


def test_settings_university_switch_needs_restart(app, uni, tmp_env):
    st, _, _ = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"university": "nirgendwo"}))
    assert st == 400
    st, _, b = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"university": "hildesheim"}))
    d = json.loads(b)
    # die laufende Instanz bleibt bei ihrer Uni; der Wechsel gilt erst nach dem Neustart
    assert st == 200 and d["university"] == "luh" and d["university_next"] == "hildesheim"
    assert 'UNIVERSITY="hildesheim"' in (tmp_env / ".env").read_text(encoding="utf-8")
    from app import db
    with db.cursor() as conn:
        assert db.row(conn, "SELECT value FROM settings WHERE key='university'")["value"] == "luh"


# ---------------------------------------------------------------- Trennung der Hochschulen

def test_each_university_has_its_own_data_dir(tmp_path):
    from app import config
    assert config.data_dir_for(tmp_path, "luh") == tmp_path                     # bestehende LUH-Daten bleiben, wo sie sind
    assert config.data_dir_for(tmp_path, "hildesheim") == tmp_path / "unis" / "hildesheim"
    assert config.normalize_university(" Hildesheim ") == "hildesheim"
    assert config.normalize_university("../etc") == "luh"                       # kein Pfad aus der .env
    assert config.normalize_university(None) == "luh"


def test_database_refuses_other_university(app, monkeypatch):
    from app import config, db
    db.init_db()                                                                # Test-DB gehoert der LUH
    monkeypatch.setattr(config, "UNIVERSITY", "hildesheim")
    with pytest.raises(db.UniversityMismatch, match="keine Daten gemischt"):
        db.init_db()


def test_services_follow_university(app, uni, tmp_env):
    st, _, b = asgi_call(app, "GET", "/api/services")
    d = json.loads(b)
    assert st == 200 and d["university"]["key"] == "luh" and any(s["key"] == "studip" for s in d["services"])
    uni("hildesheim")
    d = json.loads(asgi_call(app, "GET", "/api/services")[2])
    assert d["university"]["files_source"] == "Learnweb" and d["university"]["grades_source"] == "LSF"
    assert {s["key"] for s in d["services"]} >= {"learnweb", "lsf"}
    assert d["credentials"]["hildesheim"]["configured"] is False and d["learnweb"]["token_set"] is False
    assert {u["key"] for u in d["universities"]} == {"luh", "hildesheim"}


def test_hildesheim_credentials_endpoint(app, tmp_env):
    st, _, _ = asgi_call(app, "PUT", "/api/credentials/hildesheim", body=json.dumps({"user": "testnutzer", "password": "x y#z"}))
    assert st == 200
    env = (tmp_env / ".env").read_text(encoding="utf-8")
    assert "HILDESHEIM_USER" in env and "STUDIP_USER" not in env


def test_learnweb_token_endpoint(app, tmp_env):
    st, _, _ = asgi_call(app, "PUT", "/api/learnweb/token", body=json.dumps({"token": "kurz"}))
    assert st == 400
    st, _, _ = asgi_call(app, "PUT", "/api/learnweb/token", body=json.dumps({"token": "abc\nSTUDIP_USER=x" + "a" * 20}))
    assert st == 400                                   # keine Zeileninjektion in die .env
    tok = "0123456789abcdef0123456789abcdef"
    st, _, b = asgi_call(app, "PUT", "/api/learnweb/token", body=json.dumps({"token": tok}))
    assert st == 200 and json.loads(b)["token_set"] is True
    from app import config
    assert config.secret("LEARNWEB_TOKEN") == tok
    st, _, b = asgi_call(app, "GET", "/api/services")
    assert tok not in b.decode()                       # der Schluessel wird nie ausgeliefert
    asgi_call(app, "PUT", "/api/learnweb/token", body=json.dumps({"clear": True}))
    assert config.secret("LEARNWEB_TOKEN") == ""


# ---------------------------------------------------------------- CAS

def test_cas_urls():
    from app import cas
    u = cas.login_url("https://www.uni-hildesheim.de/sso", "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1")
    assert u == "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1"
    assert cas.is_cas_page("https://www.uni-hildesheim.de/sso/login?service=x", "https://www.uni-hildesheim.de/sso")
    assert cas.is_cas_page("https://uni-hildesheim.de/sso/login", "https://www.uni-hildesheim.de/sso")
    assert not cas.is_cas_page("https://www.uni-hildesheim.de/learnweb2026/my/", "https://www.uni-hildesheim.de/sso")
    assert not cas.is_cas_page("https://lsf.uni-hildesheim.de/sso/login", "https://www.uni-hildesheim.de/sso")


def test_cas_login_requires_credentials():
    from app import cas

    class FakePage:
        url = "https://www.uni-hildesheim.de/sso/login?service=x"
        def goto(self, *a, **k): pass
        def wait_for_timeout(self, *_): pass

    with pytest.raises(cas.CasLoginError, match="Zugangsdaten fehlen"):
        cas.login(FakePage(), "https://www.uni-hildesheim.de/sso/login?service=x", "https://www.uni-hildesheim.de/sso", "", "", lambda: False, log=lambda m: None)


# ---------------------------------------------------------------- Learnweb

def test_parse_course_title():
    from app.learnweb import parse_course_title
    assert parse_course_title("SoSe 2026: 0406 Theorien der Erziehungswissenschaft") == \
        {"semester": "SoSe 2026", "number": "0406", "title": "0406 Theorien der Erziehungswissenschaft"}
    assert parse_course_title("WiSe 2026/27:  1532   Klein(st)kinder") == {"semester": "WiSe 2026/27", "number": "1532", "title": "1532 Klein(st)kinder"}
    assert parse_course_title("Mathe-Vorkurs") == {"semester": "", "number": None, "title": "Mathe-Vorkurs"}


def test_section_label_and_week_hint():
    from app import learnweb, study
    assert learnweb.section_label("3") == "Woche 3"
    assert learnweb.section_label("Informationen", 0) == "Informationen"
    assert learnweb.section_label("", 4) == "Abschnitt 4"
    assert study.week_hint("praesentation.pdf", "Woche 3") == 3


def test_parse_pluginfile():
    from app.learnweb import parse_pluginfile
    p = parse_pluginfile("https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/4711/mod_resource/content/3/01%20KP%20Garbade.pdf?forcedownload=1")
    assert p == {"area": "resource", "revision": 3, "filepath": "/", "filename": "01 KP Garbade.pdf"}
    p = parse_pluginfile("https://x/learnweb2026/pluginfile.php/9/mod_folder/content/12/Kapitel%201/Text.pdf")
    assert p["filepath"] == "/Kapitel 1/" and p["filename"] == "Text.pdf" and p["revision"] == 12
    assert parse_pluginfile("https://x/learnweb2026/mod/resource/view.php?id=1") is None


def test_files_from_contents_rest():
    from app import learnweb
    sections = [{"id": 1, "section": 0, "name": "Informationen", "modules": [
                    {"id": 77, "name": "Seminarplan", "modname": "resource", "contents": [
                        {"type": "file", "filename": "plan.pdf", "filepath": "/", "filesize": 1200, "timemodified": 1760000000,
                         "fileurl": "https://www.uni-hildesheim.de/learnweb2026/webservice/pluginfile.php/5/mod_resource/content/1/plan.pdf?forcedownload=1",
                         "mimetype": "application/pdf"}]},
                    {"id": 78, "name": "Forum", "modname": "forum"}]},
                {"id": 2, "section": 1, "name": "1", "modules": [
                    {"id": 80, "name": "Literatur", "modname": "folder", "contents": [
                        {"type": "file", "filename": "a.pdf", "filepath": "/Teil 1/", "filesize": 5, "timemodified": 1760000001,
                         "fileurl": "https://www.uni-hildesheim.de/learnweb2026/webservice/pluginfile.php/6/mod_folder/content/2/Teil%201/a.pdf"},
                        {"type": "url", "filename": "link", "fileurl": "https://example.org"}]}]}]
    files = learnweb.files_from_contents(sections)
    assert [f["name"] for f in files] == ["plan.pdf", "a.pdf"]
    assert files[0]["folder"] == "Informationen" and files[0]["chdate"] == 1760000000
    assert "forcedownload" not in files[0]["download_url"] and "token" not in files[0]["download_url"]
    assert files[1]["folder"] == "Woche 1/Literatur/Teil 1" and files[1]["mime"] == "application/pdf"
    assert files[0]["id"] == learnweb.file_id(77, "/", "plan.pdf")


def test_token_client_calls_and_errors():
    from app import learnweb
    calls = []

    def post(url, data):
        calls.append((url, data))
        fn = data["wsfunction"]
        if fn == "core_webservice_get_site_info":
            return json.dumps({"userid": 42}).encode()
        if fn == "core_enrol_get_users_courses":
            return json.dumps([{"id": 35, "fullname": "SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "hidden": 0}]).encode()
        return json.dumps({"exception": "moodle_exception", "errorcode": "invalidtoken", "message": "Ungültiges Token"}).encode()

    c = learnweb.TokenClient("https://www.uni-hildesheim.de/learnweb2026/", "TOKEN123", post=post)
    courses = c.courses()
    assert courses == [{"id": "lw-35", "moodle_id": 35, "title": "0406 Theorien der Erziehungswissenschaft", "number": "0406", "semester": "SoSe 2026", "hidden": False}]
    assert calls[1][1]["userid"] == 42 and calls[0][0].endswith("/learnweb2026/webservice/rest/server.php")
    with pytest.raises(learnweb.LearnwebError, match="invalidtoken"):
        c.files(35)
    assert c.download_url("https://x/pluginfile.php/1/a.pdf") == "https://x/pluginfile.php/1/a.pdf?token=TOKEN123"
    with pytest.raises(learnweb.LearnwebError):
        learnweb.TokenClient("https://x", "")


def test_files_from_state_session_mode():
    from app import learnweb
    state = {"section": [{"id": "10", "number": 0, "title": "Informationen"}, {"id": "11", "number": 1, "title": "1"}],
             "cm": [{"id": "1", "module": "resource", "name": "Folien 1", "sectionid": "11"},
                    {"id": "2", "module": "folder", "name": "Texte", "sectionid": "10"},
                    {"id": "3", "module": "forum", "name": "Forum", "sectionid": "10"},
                    {"id": "4", "module": "resource", "name": "versteckt", "sectionid": "10", "uservisible": False}]}
    base = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php"
    res = {"1": [f"{base}/5/mod_resource/content/4/Folien%201.pdf"]}
    html = f'<a href="{base}/6/mod_folder/content/2/x.pdf?forcedownload=1">x</a><a href="{base}/6/mod_folder/content/2/x.pdf">x</a>'
    files = learnweb.files_from_state(state, lambda cmid: res.get(str(cmid), []), lambda cmid: learnweb.folder_links(html))
    assert [(f["name"], f["folder"], f["chdate"]) for f in files] == [("Folien 1.pdf", "Woche 1", 4), ("x.pdf", "Informationen/Texte", 2)]


def test_store_course_files_downloads_only_changes(app, tmp_path):
    from app import db, learnweb
    from app.studip_sync import store_course_files, upsert_course
    course = {"id": "lw-35", "moodle_id": 35, "title": "0406 Theorien", "number": "0406", "semester": "SoSe 2026"}
    files = [{"id": learnweb.file_id(1, "/", "a.pdf"), "name": "a.pdf", "size": 3, "mime": "application/pdf", "author": None,
              "chdate": 1, "download_url": "https://x/pluginfile.php/5/mod_resource/content/1/a.pdf", "folder": "Woche 1"}]
    got = []

    def dl(url, target, size=0):
        got.append(url)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF")

    with db.cursor() as conn:
        upsert_course(conn, course, "2026-10-25")
        new = []
        store_course_files(conn, course, files, {files[0]["id"]: "Woche 1"}, dl, "2026-10-25", new, pause=0)
        assert new == [files[0]["id"]] and len(got) == 1
        new = []
        store_course_files(conn, course, files, {}, dl, "2026-10-25", new, pause=0)
        assert new == [] and len(got) == 1                     # unveraendert: kein zweiter Download
        files[0]["chdate"] = 2                                 # Lehrende haben die Datei ersetzt
        store_course_files(conn, course, files, {}, dl, "2026-10-25", new, pause=0)
        assert len(got) == 2
        row = db.row(conn, "SELECT studip_folder, kind, course_id FROM files WHERE id=?", (files[0]["id"],))
        c = db.row(conn, "SELECT number, semester FROM courses WHERE id='lw-35'")
    assert row == {"studip_folder": "Woche 1", "kind": "pdf", "course_id": "lw-35"}
    assert c == {"number": "0406", "semester": "SoSe 2026"}


def test_hildesheim_sync_without_credentials(app, tmp_env):
    from app import db, hildesheim
    r = hildesheim.run_sync()
    assert r["ok"] is False and "Zugangsdaten fehlen" in r["message"]
    with db.cursor() as conn:
        last = db.row(conn, "SELECT ok, message FROM sync_log ORDER BY id DESC LIMIT 1")
    assert last["ok"] == 0 and "Zugangsdaten fehlen" in last["message"]


def test_run_sync_dispatches_by_university(app, uni, monkeypatch):
    from app import db, hildesheim, studip_sync
    monkeypatch.setattr(db, "init_db", lambda: None)      # Test-DB gehoert der LUH; hier geht es nur um die Weiche
    monkeypatch.setattr(hildesheim, "run_sync", lambda show_browser=False: {"ok": True, "new_files": [], "message": "hildesheim"})
    monkeypatch.setattr(studip_sync, "run_studip_sync", lambda show_browser=False: {"ok": True, "new_files": [], "message": "studip"})
    assert studip_sync.run_sync()["message"] == "studip"
    uni("hildesheim")
    assert studip_sync.run_sync()["message"] == "hildesheim"


# ---------------------------------------------------------------- LSF: iCal-Stundenplan

def test_parse_ics_uses_byday_and_exdate():
    from app import timetable
    (e,) = timetable.parse_ics(COURSE_ICS)
    assert e["weekday"] == 3 and e["date_from"] == "2026-10-29"     # Donnerstag, nicht der Montag aus DTSTART
    assert (e["start_time"], e["end_time"], e["rrule"], e["date_to"]) == ("16:00", "18:00", "weekly", "2027-02-05")
    assert e["exdates"] == ["2026-12-24", "2026-12-31"]


def test_parse_ics_multiple_bydays_split_exdates():
    from app import timetable
    evs = [e for e in timetable.parse_ics(PLAN_ICS) if "Sozialpädagogik" in e["title"]]
    assert [(e["weekday"], e["date_from"], e["exdates"]) for e in evs] == [(1, "2026-10-27", ["2026-12-22"]), (3, "2026-10-29", ["2026-12-24"])]


def test_lsf_summary_and_link():
    from app import lsf
    assert lsf.split_summary("0449 - Erinnerungen\\, Erzählungen (Zimmermann)") == {"number": "0449", "title": "Erinnerungen, Erzählungen", "lecturer": "Zimmermann"}
    assert lsf.split_summary("1532 - Klein(st)kinder in den stationären Hilfen") == {"number": "1532", "title": "Klein(st)kinder in den stationären Hilfen", "lecturer": ""}
    html = '<a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=transform&amp;termine=1,2&amp;moduleCall=iCalendarPlan&amp;publishConfFile=reports">'
    assert lsf.plan_ics_link(html) == "https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&status=transform&termine=1,2&moduleCall=iCalendarPlan&publishConfFile=reports"
    assert lsf.plan_ics_link('<a href="rds?state=wplan&amp;moduleCall=iCalendarPlan">') == "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&moduleCall=iCalendarPlan"
    assert lsf.plan_ics_link("<html>kein Plan</html>") is None


def test_lsf_import_plan_is_idempotent(app):
    from app import db, lsf
    with db.cursor() as conn:
        conn.execute("DELETE FROM course_events WHERE source='lsf'")
        term = db.row(conn, "SELECT name FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")["name"]
        conn.execute("INSERT OR REPLACE INTO courses(id, title, number, semester, kind, created_at) VALUES ('lw-900', '0449 Erinnerungen', '0449', ?, 'seminar', '2026-10-25')", (term,))
        conn.execute("INSERT OR REPLACE INTO courses(id, title, number, semester, kind, created_at) VALUES ('lw-901', '1505 Alt', '1505', 'SoSe 2026', 'seminar', '2026-10-25')")
        r1 = lsf.import_plan(conn, lsf.plan_entries(PLAN_ICS))
        assert r1["new"] == 4 and r1["removed"] == 0 and r1["cancelled_dates"] == 2
        evs = db.rows(conn, "SELECT title, weekday, course_id, rrule, lecturer FROM course_events WHERE source='lsf' ORDER BY weekday, start_time")
        er = next(e for e in evs if e["title"].startswith("Erinnerungen"))
        assert er["course_id"] == "lw-900" and er["lecturer"] == "Zimmermann" and er["weekday"] == 0
        assert all(e["course_id"] != "lw-901" for e in evs)               # gleiche Nummer, anderes Semester
        assert {e["rrule"] for e in evs} == {"weekly", "once"}
        # Nutzer markiert einen Termin; zweiter Import aendert nichts und behaelt die Ausnahme
        eid = db.row(conn, "SELECT id FROM course_events WHERE source='lsf' AND title LIKE 'Erinnerungen%'")["id"]
        conn.execute("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?, '2026-11-02', 'skip', '2026-10-25')", (eid,))
        r2 = lsf.import_plan(conn, lsf.plan_entries(PLAN_ICS))
        assert (r2["new"], r2["removed"], r2["kept"], r2["cancelled_dates"]) == (0, 0, 4, 0)
        assert db.row(conn, "SELECT 1 FROM event_exceptions WHERE event_id=? AND type='skip'", (eid,))
        # Kurs faellt aus dem Plan: nur diese LSF-Serie verschwindet, manuelle Termine bleiben
        conn.execute("INSERT INTO course_events(title, weekday, start_time, end_time, source) VALUES ('Eigener Termin', 0, '08:00', '09:00', 'manual')")
        r3 = lsf.import_plan(conn, [e for e in lsf.plan_entries(PLAN_ICS) if e["number"] != "1528"])
        assert (r3["new"], r3["removed"]) == (0, 1)
        assert db.row(conn, "SELECT 1 FROM course_events WHERE title='Eigener Termin' AND source='manual'")
        conn.execute("DELETE FROM course_events WHERE source IN ('lsf','manual')")
        conn.execute("DELETE FROM courses WHERE id IN ('lw-900','lw-901')")


class _PlanPage:
    """Seite "Persoenlicher Stundenplan" im LSF (erfundene Termin-Nummern) mit fester iCal-Antwort; kein Netz"""

    def __init__(self, ics: str, link: bool = True):
        self.ics, self.link, self.url = ics, link, "about:blank"
        page = self

        class Request:
            @staticmethod
            def get(url):
                class R:
                    ok, status = True, 200

                    @staticmethod
                    def text():
                        return page.ics
                return R()
        self.request = Request()

    def goto(self, url, wait_until=None):
        self.url = url

    def wait_for_timeout(self, ms):
        pass

    def locator(self, selector):
        class L:
            @staticmethod
            def count():
                return 1
        return L()

    def content(self):
        link = '<a href="rds?state=verpublish&amp;status=transform&amp;moduleCall=iCalendarPlan&amp;termine=1,2">iCal</a>'
        return '<a href="rds?state=user&amp;type=4">Abmelden</a>' + (link if self.link else "")


def test_lsf_calendar_without_events_removes_nothing(app, monkeypatch):
    """Export-Link vorhanden, aber der Kalender hat keinen Termin: Fehler, LSF-Serien bleiben samt eigener Ausnahmen
    (Verlegung) und Teilnahme-Einstellung. Ein leerer Plan ist nur der Fall ohne Export-Link."""
    from app import db, hildesheim, lsf
    monkeypatch.setattr(lsf, "login", lambda page, user, password, log=print: None)
    with db.cursor() as conn:
        conn.execute("DELETE FROM course_events WHERE source='lsf'")
    assert hildesheim.sync_lsf_plan(_PlanPage(PLAN_ICS), "u", "p") == "Stundenplan: 4 neu, 0 unveraendert, 0 entfernt"
    with db.cursor() as conn:
        eid = db.row(conn, "SELECT id FROM course_events WHERE source='lsf' AND title LIKE 'Erinnerungen%'")["id"]
        conn.execute("UPDATE course_events SET attend=0 WHERE id=?", (eid,))
        conn.execute("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?, '2026-11-02', 'moved', '2026-10-25')", (eid,))
        exc_before = db.row(conn, "SELECT COUNT(*) AS n FROM event_exceptions")["n"]
    empty = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//HIS//LSF//DE\r\nEND:VCALENDAR\r\n"
    with pytest.raises(RuntimeError, match="ohne Termine"):
        hildesheim.sync_lsf_plan(_PlanPage(empty), "u", "p")
    with db.cursor() as conn:
        assert db.row(conn, "SELECT COUNT(*) AS n FROM course_events WHERE source='lsf'")["n"] == 4
        assert db.row(conn, "SELECT attend FROM course_events WHERE id=?", (eid,))["attend"] == 0
        assert db.row(conn, "SELECT 1 FROM event_exceptions WHERE event_id=? AND type='moved'", (eid,))
        assert db.row(conn, "SELECT COUNT(*) AS n FROM event_exceptions")["n"] == exc_before
    # ohne Export-Link: leerer Plan wie bisher, ebenfalls ohne etwas zu entfernen
    assert hildesheim.sync_lsf_plan(_PlanPage(empty, link=False), "u", "p") == "LSF-Stundenplan ist leer"
    with db.cursor() as conn:
        assert db.row(conn, "SELECT COUNT(*) AS n FROM course_events WHERE source='lsf'")["n"] == 4
        conn.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE source='lsf')")
        conn.execute("DELETE FROM course_events WHERE source='lsf'")


# ---------------------------------------------------------------- Live-Test 25.10.2026: Abbruch bei U+0308

def test_log_survives_console_without_unicode(monkeypatch):
    import io
    import sys
    from app import studip_sync
    raw = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", io.TextIOWrapper(raw, encoding="cp1252", errors="strict"))
    studip_sync.log("Neu: Kurs / Einführung.pdf")          # brach vorher den ganzen Sync ab
    sys.stdout.flush()
    assert b"Einfu?hrung" in raw.getvalue()


def test_names_are_nfc():
    from app import learnweb
    from app.studip_sync import safe_name
    assert safe_name("Einführung.pdf") == "Einführung.pdf"
    assert learnweb.file_id(1, "/", "Einführung.pdf") == learnweb.file_id(1, "/", "Einführung.pdf")
    p = learnweb.parse_pluginfile("https://x/pluginfile.php/1/mod_resource/content/2/Einfu%CC%88hrung.pdf")
    assert p["filename"] == "Einführung.pdf"


def test_sync_learnweb_keeps_courses_before_an_error(app, monkeypatch):
    from app import db, hildesheim, learnweb

    class Client:
        def files(self, mid):
            if mid == 102:
                raise RuntimeError("kaputt")
            return [{"id": learnweb.file_id(mid, "/", "a.pdf"), "name": "a.pdf", "size": 1, "mime": "application/pdf", "author": None,
                     "chdate": 1, "download_url": f"https://x/pluginfile.php/{mid}/mod_resource/content/1/a.pdf", "folder": "Woche 1"}]

    def fake_dl(page, url, target, token="", size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF")

    monkeypatch.setattr(hildesheim, "_download", fake_dl)
    courses = [{"id": f"lw-{i}", "moodle_id": i, "title": f"Kurs {i}", "number": None, "semester": "SoSe 2026"} for i in (101, 102, 103)]
    new = []
    n = hildesheim.sync_learnweb(None, Client(), courses, "", "2026-10-25", new)
    assert n == 3 and len(new) == 2
    with db.cursor() as conn:
        ids = {r["course_id"] for r in db.rows(conn, "SELECT course_id FROM files WHERE course_id IN ('lw-101','lw-102','lw-103')")}
        assert ids == {"lw-101", "lw-103"}
        conn.execute("DELETE FROM files WHERE course_id IN ('lw-101','lw-102','lw-103')")
        conn.execute("DELETE FROM courses WHERE id IN ('lw-101','lw-102','lw-103')")


def test_shared_hildesheim_fixtures_match_python():
    """packages/shared-contracts/fixtures/hildesheim: dieselben Erwartungen prueft die iPad-App (UniFlowCore)."""
    from pathlib import Path
    from app import learnweb, lsf, timetable
    d = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "hildesheim"
    exp = json.loads((d / "expected.json").read_text(encoding="utf-8"))
    course = timetable.parse_ics((d / "lsf-course.ics").read_text(encoding="utf-8"))
    assert [{k: e[k] for k in exp["lsf-course.ics"][0]} for e in course] == exp["lsf-course.ics"]
    plan = lsf.plan_entries((d / "lsf-plan.ics").read_text(encoding="utf-8"))
    assert [{k: e[k] for k in exp["lsf-plan.ics"][0]} for e in plan] == exp["lsf-plan.ics"]
    files = learnweb.files_from_contents(json.loads((d / "learnweb-course-contents.json").read_text(encoding="utf-8")))
    assert [{k: f[k] for k in exp["learnweb-course-contents.json"][0]} for f in files] == exp["learnweb-course-contents.json"]
    assert {t: learnweb.parse_course_title(t) for t in exp["course-titles"]} == exp["course-titles"]


def test_grade_rows_hildesheim_layout():
    """Aufbau wie im LSF Hildesheim (Werte erfunden): 'Abschluss:'-Zeile vor der Kopfzeile, 'Prüfungsnr.' mit Punkt,
    Modulzeilen ohne Note/Status, zwei Abschnitte in einer Tabelle."""
    from app.qis import parse_grade_rows
    rows = [
        ["Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022 Prüfungsordnung Studienordnung"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["5010", "Modul 1: Einführung", "", "", "12"],
        ["5011", "TM 1: Grundlagen /\n0424 Einführung", "1,7", "bestanden", "6"],
        ["5013", "TM 3: Prozesse / 0503 Methodik", "", "bestanden", "3"],
        ["5032", "TM 2: Kindheit / 0410 Kindheit", "", "angemeldet (SoSe 26)", "0"],
        ["8000", "Gesamtkonto studienbegleitender Prüfungen", "", "", "44,5"],
        ["Abschluss: [82] Bachelor Studiengang: [021] Begleitfach PO-Version: 2022"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["10010", "Pflichtmodule (mindestens 12 LP)", "", "Prüfung vorhanden", "6"],
        ["4220", "Grundlagen I / 3200 Grundlagen 1", "2,3", "bestanden", "6"],
    ]
    g = parse_grade_rows(rows, "Fallback")
    assert [(r["pruefungsnr"], r["note"], r["status"], r["credits"]) for r in g] == [
        ("5011", "1,7", "bestanden", "6"), ("5013", "", "bestanden", "3"), ("5032", "", "angemeldet (SoSe 26)", "0"), ("4220", "2,3", "bestanden", "6")]
    assert g[0]["text"] == "TM 1: Grundlagen / 0424 Einführung"
    assert g[0]["abschluss"] == "Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022"
    assert g[-1]["abschluss"].endswith("[021] Begleitfach PO-Version: 2022")


def test_store_grades_updates_rows_without_semester():
    """Leistungen aus Hildesheim haben weder Semester noch Versuch (NULL): ein zweiter Abruf aktualisiert sie, statt sie
    doppelt anzulegen (UNIQUE mit NULL greift in SQLite nie). Gleiche Regel wie UniStore.storeGrades im Swift-Kern."""
    from app import db, qis
    db.init_db()
    g = {"pruefungsnr": "5011", "text": "TM 1: Grundlagen", "note": "1,7", "status": "bestanden", "credits": "6",
         "abschluss": "Abschluss: [82] Bachelor", "raw": "5011 | TM 1"}
    luh = {"pruefungsnr": "1001", "text": "Mathematik I", "semester": "WiSe 26/27", "versuch": "1", "note": "2,0",
           "status": "bestanden", "credits": "8", "abschluss": "", "raw": "1001"}
    with db.cursor() as conn:
        conn.execute("DELETE FROM grades")
        qis.store_grades(conn, [g, {**g, "pruefungsnr": "5012", "text": "TM 2: Wohnen"}, luh])
        qis.store_grades(conn, [{**g, "note": "1,3"}, {**luh, "note": "1,7"}, {**luh, "versuch": "2", "note": "1,0"}])
        rows = db.rows(conn, "SELECT pruefungsnr, versuch, note FROM grades ORDER BY pruefungsnr, versuch")
        conn.execute("DELETE FROM grades")
    assert [(r["pruefungsnr"], r["versuch"], r["note"]) for r in rows] == [
        ("1001", "1", "1,7"), ("1001", "2", "1,0"), ("5011", None, "1,3"), ("5012", None, "1,7")]


def test_grade_rows_luh_layout_still_works():
    from app.qis import parse_grade_rows
    rows = [["Prüfungsnr", "Prüfungstext", "Semester", "Note", "Status", "Credits", "Versuch"],
            ["1001", "Mathematik I", "WiSe 26/27", "2,0", "bestanden", "8", "1"]]
    (r,) = parse_grade_rows(rows, "Abschluss 82 Bachelor of Science")
    assert (r["text"], r["semester"], r["note"], r["credits"], r["versuch"], r["abschluss"]) == \
        ("Mathematik I", "WiSe 26/27", "2,0", "8", "1", "Abschluss 82 Bachelor of Science")


# ---------------------------------------------------------------- Downloads gestreamt (Live-Test: 2,7 GB Speicher)

@pytest.fixture
def local_server():
    import http.server
    import threading
    seen = {}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            seen["cookie"] = self.headers.get("Cookie")
            if self.path.startswith("/file"):
                body = b"%PDF-1.7\n" + b"x" * 300_000
                self.send_response(200); self.send_header("Content-Type", "application/pdf")
            elif self.path.startswith("/login"):
                body = b"<!DOCTYPE html><html><body>Anmelden</body></html>"
                self.send_response(200); self.send_header("Content-Type", "text/html")
            elif self.path.startswith("/leer"):
                body = b""
                self.send_response(200); self.send_header("Content-Type", "application/pdf")
            else:
                body = b"nicht da"
                self.send_response(404)
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", seen
    srv.shutdown()


class _FakePage:
    class context:  # noqa: N801
        @staticmethod
        def cookies(urls):
            return [{"name": "MoodleSession", "value": "abc"}]

    @staticmethod
    def evaluate(js):
        return "TestBrowser/1.0"


def test_stream_download_writes_file_and_sends_cookie(local_server, tmp_path):
    from app.studip_sync import stream_download
    base, seen = local_server
    target = tmp_path / "a" / "folie.pdf"
    stream_download(_FakePage(), base + "/file", target)
    assert target.read_bytes().startswith(b"%PDF") and target.stat().st_size == 300_009
    assert seen["cookie"] == "MoodleSession=abc"
    assert not list(tmp_path.rglob("*.part"))


def test_stream_download_rejects_login_page_and_keeps_old_file(local_server, tmp_path):
    from app.studip_sync import stream_download
    base, _ = local_server
    target = tmp_path / "folie.pdf"
    target.write_bytes(b"%PDF alt")
    with pytest.raises(RuntimeError, match="Webseite"):
        stream_download(_FakePage(), base + "/login", target)
    assert target.read_bytes() == b"%PDF alt" and not list(tmp_path.glob("*.part"))


def test_empty_answer_never_replaces_a_good_file(local_server, tmp_path):
    """HTTP 200 mit 0 Bytes zu einer neuen Fassung: die alte Datei bleibt (Notizen haengen an ihr); ohne lokale
    Fassung zaehlt die Groesse laut Quelle. Gestreamt und ueber den Browser-Weg der LUH."""
    from app import studip_sync
    base, _ = local_server
    old = tmp_path / "plan.pdf"
    old.write_bytes(b"%PDF-1.7 gute alte Fassung")
    with pytest.raises(RuntimeError, match="Leere Antwort"):
        studip_sync.stream_download(_FakePage(), base + "/leer", old)
    assert old.read_bytes() == b"%PDF-1.7 gute alte Fassung" and not list(tmp_path.glob("*.part"))
    new = tmp_path / "neu.pdf"
    with pytest.raises(RuntimeError, match="Leere Antwort"):
        studip_sync.stream_download(_FakePage(), base + "/leer", new, expected_size=26)
    assert not new.exists()
    # die Quelle meldet selbst 0 Bytes und es gibt noch keine Fassung: eine wirklich leere Datei
    really_empty = tmp_path / "leer.txt"
    studip_sync.stream_download(_FakePage(), base + "/leer", really_empty)
    assert really_empty.exists() and really_empty.stat().st_size == 0

    class Resp:
        ok, status = True, 200

        def body(self):
            return b""

        def dispose(self):
            pass

    class Page(_FakePage):
        class request:  # noqa: N801
            @staticmethod
            def get(url):
                return Resp()

    with pytest.raises(RuntimeError, match="Leere Antwort"):
        studip_sync.download(Page(), base + "/leer", old, expected_size=26)
    assert old.read_bytes() == b"%PDF-1.7 gute alte Fassung"


def test_empty_answer_keeps_the_file_changed_for_the_next_sync(app, local_server):
    """store_course_files: Groesse laut Quelle geht an den Download; scheitert er an einer leeren Antwort, bleiben
    Datei, Fassung (chdate) und Inhalts-Hash, und der naechste Abgleich laedt die Datei erneut."""
    import hashlib
    from app import db
    from app.studip_sync import store_course_files, stream_download, upsert_course
    base, _ = local_server
    course = {"id": "lw-36", "moodle_id": 36, "title": "0407 Leere Antwort", "number": "0407", "semester": "SoSe 2026"}
    f = {"id": "lw-36-leer", "name": "plan.pdf", "size": 26, "mime": "application/pdf", "author": None, "chdate": 100,
         "download_url": base + "/leer"}
    sizes = []

    def good(url, target, size=0):
        sizes.append(size)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF-1.7 gute alte Fassung")

    def empty(url, target, size=0):
        sizes.append(size)
        stream_download(_FakePage(), url, target, expected_size=size)

    with db.cursor() as conn:
        upsert_course(conn, course, "2026-10-25")
        store_course_files(conn, course, [f], {}, good, "2026-10-25", [], pause=0)
        f["chdate"] = 200
        new = []
        store_course_files(conn, course, [f], {}, empty, "2026-10-25", new, pause=0)
        row = db.row(conn, "SELECT local_path, chdate, content_sha256 FROM files WHERE id=?", (f["id"],))
        assert new == [] and sizes == [26, 26]
        assert row["chdate"] == 100 and row["content_sha256"] == hashlib.sha256(b"%PDF-1.7 gute alte Fassung").hexdigest()
        from pathlib import Path
        assert Path(row["local_path"]).read_bytes() == b"%PDF-1.7 gute alte Fassung"
        store_course_files(conn, course, [f], {}, good, "2026-10-25", new, pause=0)
        assert new == [f["id"]], "gilt weiter als geaendert"
        Path(row["local_path"]).unlink(missing_ok=True)
        conn.execute("DELETE FROM files WHERE course_id='lw-36'"); conn.execute("DELETE FROM courses WHERE id='lw-36'")


def test_stream_download_error_hides_token(local_server, tmp_path):
    from app.studip_sync import stream_download
    base, _ = local_server
    with pytest.raises(RuntimeError) as e:
        stream_download(_FakePage(), base + "/missing?token=GEHEIM123", tmp_path / "x.pdf", shown_url=base + "/missing")
    assert "404" in str(e.value) and "GEHEIM123" not in str(e.value)


def test_luh_download_falls_back_to_browser_and_disposes(local_server, tmp_path):
    from app import studip_sync
    base, _ = local_server
    disposed = []

    class Resp:
        ok, status = True, 200
        def body(self):
            return b"%PDF-1.4 aus dem Browser"
        def dispose(self):
            disposed.append(True)

    class Page(_FakePage):
        class request:  # noqa: N801
            @staticmethod
            def get(url):
                return Resp()

    target = tmp_path / "blatt.pdf"
    studip_sync.download(Page(), base + "/login", target)     # Stream liefert HTML -> Browser-Weg
    assert target.read_bytes() == b"%PDF-1.4 aus dem Browser" and disposed == [True]


# ---------------------------------------------------------------- Learnweb-Instanz wechselt jaehrlich

def test_semester_label():
    from datetime import date
    from app.learnweb import semester_label
    assert [semester_label(date(2026, m, 15)) for m in (3, 4, 9, 10, 12)] == \
        ["WiSe 2025/26", "SoSe 2026", "SoSe 2026", "WiSe 2026/27", "WiSe 2026/27"]
    assert semester_label(date(2027, 1, 20)) == "WiSe 2026/27"


def test_discover_learnweb_base_across_years():
    from datetime import date
    from app import learnweb
    names = {2025: "Learnweb SoSe 2025 - WiSe 2025/26", 2026: "Learnweb SoSe 2026 - WiSe 2026/27", 2027: "Learnweb SoSe 2027 - WiSe 2027/28"}
    probe_for = lambda years: (lambda base: names.get(int(base[-4:])) if int(base[-4:]) in years else None)
    root = "https://www.uni-hildesheim.de/learnweb"
    assert learnweb.discover_base(date(2026, 10, 25), probe_for({2025, 2026})) == root + "2026"
    assert learnweb.discover_base(date(2027, 1, 20), probe_for({2025, 2026, 2027})) == root + "2026"   # Januar: noch WiSe 26/27
    assert learnweb.discover_base(date(2027, 4, 10), probe_for({2026, 2027})) == root + "2027"         # neues Sommersemester
    assert learnweb.discover_base(date(2027, 4, 10), probe_for({2026})) == root + "2026"               # neue Instanz fehlt noch
    assert learnweb.discover_base(date(2027, 4, 10), probe_for(set()), override="https://x/lw/") == "https://x/lw"
    with pytest.raises(learnweb.LearnwebError, match="HILDESHEIM_LEARNWEB_URL"):
        learnweb.discover_base(date(2027, 4, 10), probe_for(set()))


def test_moodle_launch_token():
    import base64
    import hashlib
    from app import learnweb
    base = "https://www.uni-hildesheim.de/learnweb2026"
    sig = hashlib.md5((base + "pass123").encode()).hexdigest()
    tok = base64.b64encode(f"{sig}:::abcdef0123456789:::priv99".encode()).decode()
    assert learnweb.parse_launch_token(f"moodlemobile://token={tok}", base + "/", "pass123") == {"token": "abcdef0123456789", "private_token": "priv99"}
    assert learnweb.parse_launch_token(f"moodlemobile://token={tok}", base, "falsch") is None        # fremder Passport
    assert learnweb.parse_launch_token("moodlemobile://token=%%%", base, "pass123") is None
    assert learnweb.launch_url(base, "p/1") == base + "/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=p%2F1&urlscheme=moodlemobile"
