"""Hochschule Hannover (HsH): Profil, Dienste, HISinOne-Leser (Anmeldung, Stundenplan-Abo, Leistungen, angemeldete
Pruefungen, QIS-Iframe), Semesterzeiten, Anmeldefenster und Abgleich-Weiche.

Ohne Netz. Die Seiten unter packages/shared-contracts/fixtures/hsh/ sind NACHGEBAUT (Aufbau nach den anonymisierten
Strukturnotizen vom 05.11.2026, erfundene Namen, Nummern und Noten); der Swift-Kern liest dieselben Dateien
(HsHTests.swift).
"""
import json
from datetime import date
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "hsh"


@pytest.fixture
def tmp_env(monkeypatch, tmp_path):
    """.env-Zugriffe auf einen Temp-Ordner umlenken (nie die echte .env anfassen)"""
    from app import config
    monkeypatch.setattr(config, "ROOT", tmp_path)
    return tmp_path


def fx(name: str) -> str:
    return (FX / name).read_text(encoding="utf-8")


# ---------------------------------------------------------------- Profil und Dienste

def test_profile_and_services():
    from app import config, universities
    p = universities.PROFILES["hsh"]
    assert p["name"] == "Hochschule Hannover" and p["files_source"] == "Moodle"
    assert universities.valid("hsh") and config.normalize_university("HSH") == "hsh"
    assert config.data_dir_for(Path("/x"), "hsh") == Path("/x/unis/hsh"), "eigener Datenordner"
    keys = [s["key"] for s in universities.services("hsh")]
    assert keys[:2] == ["moodle", "campusmanagement"]
    assert universities.services("luh") is None and universities.services("hildesheim") == universities.HILDESHEIM_SERVICES
    for s in universities.HSH_SERVICES:
        assert s["url"].startswith("https://") and {"key", "name", "desc", "login", "icon"} <= set(s)


def test_device_login_profile_matches_launch_fixture():
    from app import server
    fxj = json.loads((ROOT / "packages/shared-contracts/fixtures/learnweb/launch.json").read_text(encoding="utf-8"))
    want = dict(fxj["profiles"]["hsh"], key="hsh", launch_scheme=fxj["launch"]["scheme"])
    assert server.university_profile("hsh") == want
    assert want["login_url"] == "https://moodle.hs-hannover.de/login/index.php"
    assert "campusmanagement.hs-hannover.de" in want["hosts"] and "idp.hs-hannover.de" in want["hosts"]


# ---------------------------------------------------------------- HISinOne

def test_login_detection_ignores_the_hidden_session_dialog():
    from app import hisinone as h
    on, off = fx("hisinone-start-angemeldet.html"), fx("hisinone-start-abgemeldet.html")
    # beide Seiten tragen das versteckte Dialogfeld mit Benutzerkennung/Passwort
    assert 'name="asdf"' in on and 'name="asdf"' in off
    assert h.is_logged_in(on) and not h.is_login_page(on)
    assert not h.is_logged_in(off) and h.is_login_page(off)
    assert h.is_logged_in(on, "https://campusmanagement.hs-hannover.de/qisserver/pages/x")
    assert not h.is_logged_in(on, "https://evil.example/qisserver/"), "nur der HISinOne-Rechner"


def test_timetable_subscription_link_from_the_popup_textarea():
    from app import hisinone as h
    link = h.ical_link(fx("hisinone-stundenplan.html"))
    assert link.startswith("https://campusmanagement.hs-hannover.de:443/qisserver/pages/cm/exa/timetable/individualTimetableCalendarExport.faces?user=")
    assert "&hash=" in link and "&amp;" not in link and h.is_export_url(link)
    # fremde Rechner und andere Pfade sind nie die Abo-Adresse
    assert not h.is_export_url(link.replace("campusmanagement.hs-hannover.de", "evil.example"))
    assert not h.is_export_url("https://campusmanagement.hs-hannover.de/qisserver/pages/other.faces?user=a&hash=b")
    assert h.ical_link("<p>kein Export</p>") is None


def test_timetable_ics_imports_as_series(tmp_env):
    from app import db, lsf
    entries = lsf.plan_entries(fx("stundenplan.ics"))
    assert [(e["title"], e["weekday"], e["start_time"], e["rrule"]) for e in entries] == [
        ("Programmieren 1 - Vorlesung", 0, "10:00", "weekly"), ("Mathematik 1 - Übung", 3, "14:00", "once")]
    db.init_db()
    with db.cursor() as conn:
        assert lsf.import_plan(conn, entries)["new"] == 2
        assert lsf.import_plan(conn, entries)["new"] == 0, "zweiter Abgleich ohne Doppelte"


def test_grades_from_the_tree_table():
    from app import hisinone as h
    g = h.parse_grades(fx("hisinone-leistungen.html"))
    assert [x["pruefungsnr"] for x in g] == ["100100", "100110", "100120", "200100", "300100"], "jede Leistung einmal"
    p1 = g[1]
    assert (p1["text"], p1["note"], p1["status"], p1["credits"], p1["versuch"], p1["datum"]) == \
        ("Programmieren 1 (Klausur)", "1,7", "bestanden", "5,0", "1", "20.02.2026")
    assert all(x["abschluss"] == "Bachelor Angewandte Informatik (PO 2019)" for x in g)
    assert not any("Erika" in x["raw"] or "0000000" in x["raw"] for x in g), "keine Stammdaten"


def test_grades_are_stored_once(tmp_env):
    from app import db, hisinone, qis
    db.init_db()
    g = hisinone.parse_grades(fx("hisinone-leistungen.html"))
    with db.cursor() as conn:
        qis.store_grades(conn, g)
        qis.store_grades(conn, g)
        assert conn.execute("SELECT COUNT(*) FROM grades").fetchone()[0] == len(g)


def test_exam_registrations_read_only():
    from app import hisinone as h
    r = h.exam_registrations(fx("hisinone-pruefungen-anmelden.html"))
    assert [(x["number"], x["state"]) for x in r] == [("100110", "angemeldet"), ("200110", "offen"), ("300120", "angemeldet")]
    assert r[0]["title"] == "Programmieren 1 (Klausur)" and "zugelassen" in r[0]["hint"]
    src = Path(h.__file__).read_text(encoding="utf-8")
    assert ".click()" not in src.split("def fetch_exam_registrations")[1], "Pruefungsanmeldung: nie klicken"


def test_old_qis_iframe_stays_on_the_campus_host():
    from app import hisinone as h
    src = h.iframe_src(fx("hisinone-iframe.html"))
    assert src.startswith("https://campusmanagement.hs-hannover.de:443/qisserver/rds?state=redirect&sso=qis")
    assert h.iframe_src('<iframe src="https://evil.example/x"></iframe>') is None
    assert h.icms_profile("https://icms.hs-hannover.de/qisserver/rds?state=user")["documents"] is False


def test_registration_periods_from_text():
    from app import hisinone as h
    t = "Anmeldezeitraum: 01.12.2026 - 15.12.2026 <br> Abmeldung bis 10.01.2027 ... Abmeldezeitraum 01.12.2026 bis 10.01.2027"
    assert h.registration_periods(t) == [{"kind": "anmeldung", "from": "2026-12-01", "to": "2026-12-15"},
                                         {"kind": "abmeldung", "from": "2026-12-01", "to": "2027-01-10"}]


# ---------------------------------------------------------------- Semesterzeiten

def test_semester_dates_from_the_public_page():
    from app import holidays
    t = holidays.default_term("hsh", date(2026, 11, 5))
    assert t == {"name": "WiSe 2026/27", "start": "2026-09-21", "end": "2027-01-31"}
    marks = holidays.day_marks(date(2026, 12, 23), date(2027, 2, 2), "hsh")
    assert {"kind": "pause", "label": "Weihnachten"} in marks["2026-12-28"]
    assert marks["2027-02-01"][0]["kind"] == "vorlesungsfrei"
    assert "2027-03-29" not in marks or marks["2027-03-29"][0]["label"] in ("Ostern", "Ostermontag")


# ---------------------------------------------------------------- Anmeldefenster, Tresor, Weiche

def test_login_window_target_is_moodle_then_campus(monkeypatch):
    from app import hsh, unilogin
    key, name, url, check, profile = unilogin._target("hsh")
    assert (key, name, url) == ("hsh", "HSH_COOKIES", "https://moodle.hs-hannover.de/login/index.php")
    assert profile.name == "browser-profile-hsh" and callable(check)
    assert unilogin.session_name("hsh") == hsh.SESSION
    assert unilogin._cookie_urls("hsh")[:2] == ["https://moodle.hs-hannover.de", "https://campusmanagement.hs-hannover.de"]


def test_window_check_switches_to_campus_after_moodle(monkeypatch):
    from app import learnweb, unilogin
    saved, visited = [], []
    monkeypatch.setattr(unilogin, "save_session", lambda n, c: saved.append(n))
    state = {"moodle": False}
    monkeypatch.setattr(learnweb.SessionClient, "is_logged_in", lambda self: state["moodle"])

    class Ctx:
        def cookies(self):
            return [{"name": "MoodleSession", "value": "x", "domain": "moodle.hs-hannover.de"}]

    class Page:
        url = "https://moodle.hs-hannover.de/login/index.php"
        context = Ctx()

        def goto(self, u, **kw):
            visited.append(u)
            self.url = u

        def content(self):
            return fx("hisinone-start-angemeldet.html") if "campusmanagement" in self.url else ""

    check, page = unilogin.hsh_window_check(), Page()
    assert check(page) is False and not visited
    state["moodle"] = True
    assert check(page) is False and saved == ["HSH_COOKIES"]
    assert visited == ["https://campusmanagement.hs-hannover.de/qisserver/api/identityprovider/redirect/4/login"]
    page.url = "https://campusmanagement.hs-hannover.de/qisserver/pages/cs/sys/portal/hisinoneStartPage.faces"
    assert check(page) is True


def test_vault_and_qis_know_hsh(tmp_env):
    from app import qis
    assert qis.credentials_for("hsh") == ("", ""), "kein Passwort an der HsH"
    assert qis.configured("hsh") is False


def test_sync_switch_runs_the_hsh_sync(monkeypatch):
    from app import config, hsh, studip_sync, universities
    monkeypatch.setattr(universities, "current_key", lambda: "hsh")
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    monkeypatch.setattr(hsh, "run_sync", lambda show_browser=False, older_only=False: {"ok": True, "new_files": [], "message": "hsh"})
    assert studip_sync.run_sync()["message"] == "hsh"


def test_sync_without_session_asks_for_login(tmp_env, monkeypatch):
    from app import hsh, unilogin
    monkeypatch.setattr(unilogin, "has_session", lambda name: False)
    r = hsh.run_sync()
    assert r["ok"] is False and "Anmeldung bei Moodle" in r["message"]


@pytest.mark.parametrize("name", ["hisinone-start-angemeldet.html", "hisinone-leistungen.html", "hisinone-stundenplan.html",
                                  "hisinone-pruefungen-anmelden.html", "hisinone-iframe.html", "stundenplan.ics"])
def test_fixtures_are_marked_as_constructed(name):
    assert "NACHGEBAUT" in fx(name)


def test_services_api_for_hsh(app, monkeypatch, tmp_env):
    from conftest import asgi_call
    from app import config
    monkeypatch.setattr(config, "UNIVERSITY", "hsh")
    st, _, raw = asgi_call(app, "GET", "/api/services")
    d = json.loads(raw)
    assert st == 200 and d["university"]["key"] == "hsh" and d["university"]["files_source"] == "Moodle"
    assert [s["key"] for s in d["services"]][:2] == ["moodle", "campusmanagement"]
    assert d["qis"]["configured"] is False, "ohne Sitzung nicht verbunden"


def test_moodle_course_titles_of_the_hsh():
    from app import learnweb
    assert learnweb.parse_course_title("Programmieren 1, WiSe 2026/27, Prof. Muster") == \
        {"semester": "WiSe 2026/27", "number": None, "title": "Programmieren 1"}
    assert learnweb.parse_course_title("SoSe 2026: 9406 Theorien")["semester"] == "SoSe 2026", "Hildesheim unveraendert"


def test_exam_registration_periods_for_hsh():
    from app import exam_registration as er
    d = er.for_university("hsh")
    assert d["university"] == "hsh" and er.system(d) == "HISinOne"
    assert er.degree_slugs("B.Eng.") == ["beng"] and er.degree_slugs("M.Eng.") == ["meng"]
    assert "beng" in er.degree_slugs(None, "Bachelor of Engineering") and "meng" in er.degree_slugs("Master")
    p = er.find_program(d, "Angewandte Informatik", "B.Sc.")
    assert p and p["table"] == "hsh-f4-informatik"
    w = er.window_state(d, p, "2026-09-10", "meldung")
    assert w and w["phase"] == "open"
    assert er.find_program(d, "Elektrotechnik und Informationstechnik", "B.Eng.")["slug"].endswith("-beng")
    # LUH unveraendert: kein Studiengang mit B.Eng.
    assert er.find_program(er.for_university("luh"), "Technische Informatik", "B.Sc.") is not None
