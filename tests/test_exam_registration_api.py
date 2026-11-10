"""Pruefungsanmeldung am PC (05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): GET /api/exam-registration mit der
gleichen Antwort wie der Swift-Kern (ExamRegistrationTests.swift, gleiche Daten und Erwartungen) und der Leser fuer "Info
über angemeldete Prüfungen" (app/qis_registrations.py) mit den erfundenen QIS-Seiten und den echten, anonymisierten
LUH-Seiten (qis-echt-*.html, 10.11.2026) aus packages/shared-contracts/fixtures/exam-registration. Nie eine echte
Anfrage, nie die Pruefungsanmeldung selbst."""
import json
from datetime import date
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "exam-registration"
START = "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf"
ASI = "S1abcDEF"
LOGIN = '<html><body><form action="rds?state=user&amp;type=1"><input type="password" name="fdsa"></form></body></html>'


def _page(name):
    return (FX / name).read_text(encoding="utf-8")


def qis(info="tree", logged_in=True):
    """QIS mit festen Seiten (wie der Swift-Test): ohne asi nur die Anmeldeseite; Pruefungsanmeldung waere VERBOTEN"""
    pages = {k: _page(f"qis-{k}.html") for k in ("start", "studium", "info-tree", "info-expanded", "info-list", "info-empty", "info-direct")}
    calls = []

    def get(u):
        calls.append(u)
        if not logged_in:
            return 200, LOGIN, u
        if u == START:
            return 200, pages["start"], u
        if f"asi={ASI}" not in u:
            return 200, LOGIN, u
        if "prfAnmStudent" in u:
            return 200, "<html><body>VERBOTEN</body></html>", u
        if "moduleParameter=studyPOSMenu" in u:
            return 200, pages["studium"], u
        if "state=pruefungsinfoStudent" in u:
            if info != "tree":
                return 200, pages[f"info-{info}"], u
            if "next=list.vm" in u:
                return 200, pages["info-list"], u
            if "nodeID=" in u:
                return 200, pages["info-expanded"], u
            return 200, pages["info-tree"], u
        return 404, "", u
    return get, calls


# ---------------------------------------------------------------- Leser

def test_rows_tolerate_headers_status_and_dates():
    from app import qis_registrations as Q
    rows = Q.parse_rows([
        ["Prüfungs-Nr.", "Bezeichnung", "Sem.", "Termin", "Ort", "Vermerk", "Abmeldung bis", "Form"],
        ["Pflichtmodule", "", "", "", "", "", "", ""],
        ["1", "Analysis", "WS 26/27", "Fr, 12.02.2027, 10:15 Uhr", "Audimax", "AN", "05.02.2027", "Klausur"],
        ["2", "Physik", "WS 26/27", "2027-02-20", "", "AMD", "", ""],
        ["3", "Seminar", "WS 26/27", "", "", "", "", "VbP"],
        ["Matrikelnummer", "7654321", "", "", "", "", "", ""],
    ])
    v = [Q.row_view(r) for r in rows]
    assert [r["text"] for r in v] == ["Analysis", "Physik", "Seminar"]
    assert [r["registered"] for r in v] == [True, False, True]
    assert (v[0]["iso_date"], v[0]["clock"], v[0]["iso_withdraw"], v[0]["room"]) == ("2027-02-12", "10:15", "2027-02-05", "Audimax")
    assert v[1]["iso_date"] == "2027-02-20" and v[1]["clock"] is None
    assert v[2]["form"] == "VbP"
    assert not Q.is_header(Q.header_map(["Prüfungsnr", "Prüfungstext", "Semester", "Note", "Status"])), "Notenspiegel"
    assert Q.is_header(Q.header_map(["Prüfungsnr.", "Prüfungstext", "Datum"]))
    for s in ["", "AN", "angemeldet", "zugelassen", "PV"]:
        assert Q.is_registered(s), s
    for s in ["AMD", "abgemeldet", "RTE", "RTU", "BE", "nicht bestanden", "bestanden"]:
        assert not Q.is_registered(s), s
    assert Q.iso_date("31.02.2027") is None
    assert Q.clock("12.02.2027") is None, "ein Datum ist keine Uhrzeit"
    assert Q.clock("9.15 Uhr") == "09:15"


def test_forbidden_links_are_never_info():
    from app import qis_registrations as Q

    def link(text, query):
        return Q.Link(text, "https://qis.verwaltung.uni-hannover.de/qisserver/rds?" + query)
    assert Q.is_forbidden(link("Prüfungsanmeldung/-abmeldung", "state=prfAnmStudent&next=wait.vm"))
    assert Q.is_forbidden(link("Weiter", "state=prfAnmStudent")), "Parameter genuegt"
    assert Q.is_forbidden(link("abmelden", "state=x&pordnr=1"))
    assert Q.is_forbidden(link("Rücktritt", "state=x"))
    assert Q.is_forbidden(link("Info", "state=x&menuid=abmeldungInfo"))
    assert Q.is_forbidden(link("PDF-Übersicht", "state=verpublish"))
    assert Q.is_forbidden(link("Abmelden", "state=user&type=4"))
    assert Q.is_info(link("Info über angemeldete Prüfungen", "state=pruefungsinfoStudent&next=tree.vm"))
    assert Q.is_info(link("Angemeldete Prüfungen für TI anzeigen", "state=pruefungsinfoStudent&next=list.vm"))
    assert not Q.is_info(link("Prüfungsanmeldung", "state=pruefungsinfoStudent"))
    assert not Q.is_info(link("Info über angemeldete Prüfungen", "state=prfAnmStudent"))


def test_walk_reads_tree_and_never_touches_registration():
    from app import qis_registrations as Q
    get, calls = qis()
    r = Q.walk(get, START)
    regs = [Q.row_view(x) for x in r["registrations"]]
    assert [x["text"] for x in regs] == ["Rechnernetze", "Algorithmen und Datenstrukturen", "Mündliche Prüfung Seminar"]
    assert [x["registered"] for x in regs] == [True, False, True]
    assert (regs[0]["iso_date"], regs[0]["clock"], regs[0]["iso_withdraw"]) == ("2027-03-01", "09:00", "2027-02-22")
    assert regs[0]["pruefer"] == "Prof. Dr. Erfunden"
    assert regs[0]["abschluss"] == "Technische Informatik (PO-Version 2017)"
    assert r["tables"] == 1 and r["pages"] == 5, "Start, Mein Studium, Info, Abschluss, Liste"
    assert not any("prfAnmStudent" in u for u in calls), "nie Pruefungsanmeldung/-abmeldung"
    assert not any("verpublish" in u for u in calls), "nie eine Bescheinigung"
    assert not any("type=4" in u for u in calls), "nie abmelden"
    assert not any("expand=1" in u for u in calls), "aufgeklappter Knoten wird nicht wieder zugeklappt"


# ---------------------------------------------------------------- echte LUH-Seiten (10.11.2026, anonymisiert)

def qis_echt(expanded=False):
    """QIS mit den echten, anonymisierten Seiten (qis-echt-*.html). Wie der Server merkt sich der Baum das Aufklappen;
    Pruefungsanmeldung, PDF-Druck (hisreports), Bescheinigung und Abmelden waeren VERBOTEN."""
    pages = {k: _page(f"qis-echt-{k}.html") for k in ("start", "studium", "tree", "expanded", "list")}
    calls, tree = [], {"open": expanded}

    def get(u):
        calls.append(u)
        if u == START:
            return 200, pages["start"], u
        if any(k in u for k in ("prfAnmStudent", "hisreports", "verpublish", "type=4")):
            return 200, "<html><body>VERBOTEN</body></html>", u
        if "moduleParameter=studyPOSMenu" in u:
            return 200, pages["studium"], u
        if f"asi={ASI}" not in u:
            return 200, LOGIN, u
        if "state=examsinfosStudent" in u:
            if "next=list.vm" in u:
                return 200, pages["list"], u
            if "nodeID=" in u:
                tree["open"] = "expand=0" in u
            return 200, pages["expanded" if tree["open"] else "tree"], u
        return 404, "", u
    return get, calls


@pytest.mark.parametrize("expanded,n_pages", [(False, 5), (True, 4)])
def test_walk_reads_the_real_luh_pages(expanded, n_pages):
    """Fehler 10.11.2026: die echte Tabelle heisst "PrfNr." und "Prüfungsbezeichnung"; beides kannte der Leser nicht und
    meldete "Im QIS sind keine Prüfungen angemeldet", obwohl fuenf Pruefungen angemeldet waren."""
    from app import qis_registrations as Q
    get, calls = qis_echt(expanded)
    r = Q.walk(get, START)
    regs = [Q.row_view(x) for x in r["registrations"]]
    assert [x["pruefungsnr"] for x in regs] == ["110", "310", "2010", "2210", "851"]
    assert [x["text"] for x in regs] == [
        "Programmieren I", "Datenstrukturen und Algorithmen", "Mathematik für die Ingenieurwissenschaften I",
        "Mathematik für die Ingenieurwissenschaften III - Numerik", "Einführung in die Informatik"]
    assert all(x["registered"] for x in regs), "die Seite hat keine Status-Spalte: jede Zeile ist eine Anmeldung"
    assert [x["iso_date"] for x in regs] == ["2027-03-12", "2027-02-22", None, "2027-02-12", None], "Prüfungsdatum, nicht Anmeldedatum"
    assert [x["iso_withdraw"] for x in regs] == ["2027-03-05", "2027-02-15", None, "2027-02-05", None]
    assert {x["semester"] for x in regs} == {"WiSe 26/27 (01)"}
    assert regs[0]["pruefer"] == "Muster"
    assert {x["abschluss"] for x in regs} == {"Technische Informatik (PO-Version 2017)"}
    assert r["tables"] == 1 and r["pages"] == n_pages
    assert Q.message(len(regs)) == "5 angemeldete Prüfungen gelesen."
    assert not any("prfAnmStudent" in u for u in calls), "nie Pruefungsanmeldung/-abmeldung"
    assert not any("hisreports" in u or "verpublish" in u for u in calls), "nie PDF-Druck oder Bescheinigung"
    assert not any("type=4" in u for u in calls), "nie abmelden"
    assert not any("expand=1" in u for u in calls), "ein aufgeklappter Zweig wird nicht zugeklappt"
    dump = json.dumps(r["registrations"], ensure_ascii=False)
    for secret in ("Erika", "1234567", "Musterweg", ASI):
        assert secret not in dump, secret


def test_real_luh_links_and_headers():
    from app import qis_registrations as Q
    base = "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?"

    def link(text, query):
        return Q.Link(text, base + query)
    lst = link("angemeldete Prüfungen anzeigen für Technische Informatik  (PO-Version 2017) ",
               "state=examsinfosStudent&next=list.vm&nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%2Cstgnr%3D1%7Cstudiengang%3Astg%3D223&expand=0")
    assert Q.is_info(lst) and Q.studiengang(lst) == "Technische Informatik (PO-Version 2017)"
    assert Q.is_info(link("Info über angemeldete Prüfungen", "state=examsinfosStudent&next=tree.vm&menuid=examsinfosStudent&breadcrumb=infoexams"))
    assert Q.is_forbidden(link("Prüfungsanmeldung/-abmeldung", "state=info&moduleParameter=prfAnmStudent"))
    assert Q.is_forbidden(link("PDF-Druck", "state=hisreports&status=receive&publishid=82,1234567&moduleCall=AngemeldeteInstudiengang"))
    assert Q.is_forbidden(link("Liste drucken", "state=hisreports&status=receive")), "Parameter genuegt"
    hm = Q.header_map(["PrfNr.", "Prüfungsbezeichnung", "Prüfer/in", "Semester (Termin)", "Anmeldedatum *)",
                       "Rücktritt über QIS möglich bis", "Prüfungsdatum"])
    assert hm == ["pruefungsnr", "text", "pruefer", "semester", None, "withdraw", "datum"]
    assert Q.is_header(hm)
    # der Zweig eines zweiten Abschlusses wird weiter aufgeklappt, der offene nicht angefasst
    expanded = Q.Page(_page("qis-echt-expanded.html").replace(
        "</body>", f'<a href="{base}state=examsinfosStudent&amp;next=tree.vm&amp;nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D88%2Cstgnr%3D2'
                   f'&amp;expand=0&amp;asi={ASI}" title="Diesen Zweig aufklappen">Abschluss 88 Master of Science</a></body>'), base + "state=examsinfosStudent&next=tree.vm")
    info = next(l for l in Q.Page(_page("qis-echt-studium.html"), base + "state=change").links if Q.is_info(l))
    assert info.state == "examsinfosStudent"
    nxt = Q.next_links(expanded, info, {info.address})
    assert [l.parameters.get("next") for l in nxt][:1] == ["list.vm"], "Liste zuerst"
    assert [l.parameters["nodeid"] for l in nxt if l.parameters.get("next") != "list.vm"] == ["auswahlBaum|abschluss:abschl=88,stgnr=2"]


def test_empty_direct_missing_and_expired():
    from app import qis_registrations as Q
    assert Q.walk(qis("empty")[0], START)["registrations"] == []
    direct = [Q.row_view(x) for x in Q.walk(qis("direct")[0], START)["registrations"]]
    assert [x["text"] for x in direct] == ["Mathematik I", "Labor Technische Informatik"]
    assert direct[0]["clock"] == "10:15" and direct[0]["iso_withdraw"] == "2027-02-05"
    with pytest.raises(Q.SessionExpired):
        Q.walk(qis(logged_in=False)[0], START)
    start = _page("qis-start.html")
    calls = []

    def no_info(u):
        calls.append(u)
        if u == START:
            return 200, start, u
        return 200, ('<html><body><a href="rds?state=user&amp;type=4&amp;asi=S1abcDEF">Abmelden</a>'
                     '<a href="rds?state=prfAnmStudent&amp;asi=S1abcDEF">Prüfungsanmeldung/-abmeldung</a></body></html>'), u
    with pytest.raises(Q.InfoNotFound):
        Q.walk(no_info, START)
    assert not any("prfAnm" in u for u in calls)


# ---------------------------------------------------------------- LSF Uni Hildesheim ("Meine POS-Anmeldungen", erfundene Seiten)

LSF_START = "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0"


def lsf(overview="anmeldungen", expired=False):
    """LSF mit festen Seiten: Start -> POS-Management -> Meine POS-Anmeldungen; An-/Abmeldung waere VERBOTEN"""
    pages = {k: _page(f"lsf-{k}.html") for k in ("start", "pos", "anmeldungen", "anmeldungen-empty")}
    calls = []

    def get(u):
        calls.append(u)
        if expired:
            return 200, LOGIN, "https://www.uni-hildesheim.de/sso/login?service=x"
        if u == LSF_START:
            return 200, pages["start"], u
        if "subitem=posManagement" in u:
            return 200, pages["pos"], u
        if "moduleParameter=myPOSAnmeldungen" in u:
            return 200, pages[overview], u
        return 200, "<html><body>VERBOTEN</body></html>", u
    return get, calls


def test_lsf_walk_reads_pos_overview_and_never_registers():
    from app import qis_registrations as Q
    get, calls = lsf()
    r = Q.walk(get, LSF_START, profile="hildesheim")
    regs = [Q.row_view(x) for x in r["registrations"]]
    assert [x["text"] for x in regs] == ["Grundlagen der Informatik (Klausur)", "Seminar Medienpädagogik", "Statistik I"]
    assert [x["registered"] for x in regs] == [True, True, False], "zugelassen, AN, storniert"
    assert (regs[0]["pruefungsnr"], regs[0]["iso_date"], regs[0]["clock"], regs[0]["room"]) == ("4711", "2027-02-15", "10:00", "Forum HS 1")
    assert regs[0]["abschluss"].startswith("Abschluss: [82] Bachelor") and regs[0]["abschluss"].endswith("PO-Version: 2019")
    assert regs[1]["pruefer"].startswith("vgl. Lehrkr")
    assert r["pages"] == 3 and r["tables"] == 1
    assert len(calls) == 3, calls
    assert not any(k in u for u in calls for k in ("studyPOSAnmeldung", "prfAnm", "storno", "belegen", "type=4")), calls
    assert Q.walk(lsf("anmeldungen-empty")[0], LSF_START, profile="hildesheim")["registrations"] == []
    with pytest.raises(Q.SessionExpired):
        Q.walk(lsf(expired=True)[0], LSF_START, profile="hildesheim")
    with pytest.raises(Q.POSOverviewNotFound):
        Q.walk(lambda u: (200, _page("lsf-start.html"), u) if u == LSF_START else (200, _page("lsf-start.html"), u),
               LSF_START, profile="hildesheim")
    # das LUH-Profil kennt "POS-Management" nicht
    with pytest.raises(Q.InfoNotFound):
        Q.walk(lsf()[0], LSF_START)


def test_lsf_links_overview_allowed_registration_never():
    from app import qis_registrations as Q

    def link(text, query):
        return Q.Link(text, "https://lsf.uni-hildesheim.de/qisserver/rds?" + query)
    assert Q.is_info(link("Meine POS-Anmeldungen", "state=posAnmeldungen&next=list.vm"))
    assert Q.is_pos_menu(link("POS-Management", "state=user&type=8&subitem=posManagement"))
    for text, q in [("An-/Abmeldung zu Studien-/Prüfungsleistungen", "state=change&moduleParameter=studyPOSAnmeldung"),
                    ("Zur Anmeldung", "state=x"), ("Zur Stornierung der Anmeldung", "state=posAnmeldungen&storno=1"),
                    ("Meine POS-Anmeldungen", "state=prfAnmStudent"), ("Meine POS-Anmeldungen", "state=posAnmeldungen&stornieren=1"),
                    ("Belegen/Abmelden", "state=wplan&act=belegen"), ("Weiter", "state=x&moduleParameter=posAnmeldung")]:
        assert Q.is_forbidden(link(text, q)), text + " " + q
        assert not Q.is_info(link(text, q))
    for st in ("storniert", "Storniert am 01.12.2026", "abgelehnt", "nicht zugelassen"):
        assert not Q.is_registered(st), st
    assert Q.is_registered("zugelassen")


def test_lsf_run_message_says_lsf(monkeypatch, tmp_path):
    from app import db, qis_registrations as Q
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "pruefungsanmeldung.db")
    db.init_db()
    assert Q.run(lsf("anmeldungen-empty")[0], LSF_START, profile="hildesheim")["message"] == "Im LSF sind keine Prüfungen angemeldet."
    rep = Q.run(lsf()[0], LSF_START, profile="hildesheim")
    assert rep["count"] == 2 and rep["message"] == "2 angemeldete Prüfungen gelesen."
    with db.cursor() as conn:
        dump = json.dumps([dict(r) for r in conn.execute("SELECT * FROM exam_registrations")], ensure_ascii=False)
    for secret in ("Erika", "7654321", "Beispielweg"):
        assert secret not in dump, secret
    expired = Q.run(lsf(expired=True)[0], LSF_START, profile="hildesheim")
    assert expired["needs_login"] and expired["message"] == "Bitte im LSF anmelden."


def test_run_stores_rows_without_secrets(monkeypatch, tmp_path):
    from app import db, qis_registrations as Q
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "pruefungsanmeldung.db")
    db.init_db()
    rep = Q.run(qis()[0], START, now="2026-11-20T10:00:00")
    assert rep["count"] == 2 and rep["message"] == "2 angemeldete Prüfungen gelesen."
    with db.cursor() as conn:
        rows = Q.rows(conn)
        run = Q.last_run(conn)
        dump = json.dumps([dict(r) for r in conn.execute("SELECT * FROM exam_registrations")] +
                          [dict(r) for r in conn.execute("SELECT * FROM settings")], ensure_ascii=False)
    assert len(rows) == 3 and run["ok"] is True and run["count"] == 2
    for secret in ("Erika", "7654321", "Beispielweg", ASI):
        assert secret not in dump, secret
    expired = Q.run(qis(logged_in=False)[0], START)
    assert expired["needs_login"] and expired["count"] is None
    with db.cursor() as conn:
        assert len(Q.rows(conn)) == 3, "Zeilen bleiben bei einem Fehler"
        assert Q.last_run(conn)["ok"] is False


# ---------------------------------------------------------------- Vorschlaege (gleiche Daten wie ExamRegistrationTests.swift)

def _mod(i, title, sem, turnus="WS", exam="Klausur 90 min", kind="pflicht", code=None):
    return {"id": i, "title": title, "code": code, "area": "a", "kind": kind, "lp": 5, "semester": sem, "turnus": turnus,
            "exam": exam, "coursework": None, "prerequisites": [], "language": "deutsch", "workload_h": 150, "source_page": 1}


CATALOG = {
    "v": 1, "university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022",
    "catalog_term": "WS 2025/26", "code": "TIBSc22", "regular_semesters": 6, "total_lp": 180,
    "source": {"url": "https://modkat.example/x.pdf", "fetched_at": "t", "sha256": "x"},
    "areas": [{"id": "a", "name": "Pflicht", "lp_required": 150, "kind": "pflicht"}],
    "modules": [
        _mod("programmieren-1", "Programmieren I", 1),
        _mod("mathematik-1", "Mathematik I", 1, exam="Klausur 120 min"),
        _mod("digitale-systeme", "Grundlagen digitaler Systeme", 1),
        _mod("algorithmen", "Algorithmen und Datenstrukturen", 3),
        _mod("datenbanken", "Grundlagen der Datenbanksysteme", 3),
        _mod("rechnernetze", "Rechnernetze", 3, code="4711"),
        _mod("labor", "Labor Technische Informatik", 3, exam="VbP (Laborübung)"),
        _mod("studium-generale", "Studium Generale", 3, exam="keine"),
        _mod("bachelorarbeit", "Bachelorarbeit", 3, kind="abschluss"),
        _mod("softwaretechnik", "Softwaretechnik", 4, turnus="SS"),
    ],
}


@pytest.fixture
def plan_db(monkeypatch, tmp_path):
    from app import db, qis, qis_registrations, study_plan
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "pruefungsanmeldung.db")
    db.init_db()
    ab = "Technische Informatik (PO-Version 2017)"
    with db.cursor() as conn:
        qis.store_grades(conn, [
            {"pruefungsnr": "1", "text": "Programmieren I", "semester": "WiSe 25/26", "note": "1,7", "status": "bestanden", "credits": "5", "versuch": "1", "abschluss": ab},
            {"pruefungsnr": "2", "text": "Mathematik I", "semester": "WiSe 25/26", "note": "5,0", "status": "nicht bestanden", "credits": "5", "versuch": "1", "abschluss": ab},
            {"pruefungsnr": "3", "text": "Grundlagen der Datenbanksysteme", "semester": "WiSe 26/27", "status": "AN", "versuch": "1", "abschluss": ab},
        ])
        conn.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Algorithmen und Datenstrukturen', '#4f5bd5', 't')")
        conn.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES ('c-algo', 'Algorithmen und Datenstrukturen', 'vorlesung', 1, 1, 't')")
        conn.execute("""INSERT INTO studip_events(id, course_id, title, start, "end", room, description, cancelled, category, fetched_at)
                        VALUES ('e1', 'c-algo', 'Klausur', '2027-02-15T09:00:00', '2027-02-15T11:00:00', 'HS A', '', 0, 'Klausur', 't')""")
        qis_registrations.store(conn, [{"pruefungsnr": "4711", "text": "Rechnernetze", "semester": "WiSe 26/27", "datum": "01.03.2027",
                                        "time": "09:00", "status": "AN", "raw": ""}], "t")
    src = study_plan.MemoryCatalogSource([CATALOG])
    return src


def _resp(today, source):
    from app import db, exam_registration_api
    with db.cursor() as conn:
        return exam_registration_api.response(conn, today, source=source)


def test_suggestions_from_plan_with_reasons_dates_and_ticks(plan_db):
    v = _resp("2026-11-20", plan_db)
    assert v["supported"] is True
    assert v["program"]["slug"] == "technische-informatik-bsc" and v["program"]["verified"] is True
    assert v["term"] == "WiSe 26/27"
    assert v["window"]["phase"] == "open" and v["window"]["days_left"] == 2
    assert v["show_card"] is True and len(v["periods"]) == 6
    s = v["suggestions"]
    assert [x["id"] for x in s] == ["algorithmen", "mathematik-1", "digitale-systeme", "labor", "rechnernetze", "datenbanken"]
    one = {x["id"]: x for x in s}
    a = one["algorithmen"]
    assert a["reason"] == "laut deinem Plan im 3. Semester"
    assert (a["exam_date"], a["exam_time"], a["exam_room"]) == ("2027-02-15", "09:00", "HS A")
    assert a["withdraw_until"] == "2027-02-08", "Klausur: 7 Tage vorher"
    assert a["app_module_ids"] == [1]
    assert one["mathematik-1"]["reason_kind"] == "wiederholung"
    assert one["mathematik-1"]["reason"] == "Wiederholung – 2. Versuch (nicht bestanden im WiSe 25/26)"
    assert one["digitale-systeme"]["reason"] == "nachholen – laut Plan im WiSe 25/26"
    assert one["labor"]["period"] == "vbp" and one["labor"]["withdraw_until"] is None
    assert one["datenbanken"]["registered_via"] == "notenspiegel", "Vermerk AN im Notenspiegel"
    assert one["rechnernetze"]["registered_via"] == "qis_info", "Pruefungsnummer = Modulkuerzel"
    assert one["rechnernetze"]["exam_date"] == "2027-03-01", "Termin aus der Info-Seite"
    assert v["open_count"] == 4 and v["registered_count"] == 2
    assert [w["text"] for w in v["warnings"]] == ["Die Anmeldung endet in 2 Tagen. 3 geplante Prüfungen sind noch nicht angemeldet."]
    assert len(v["registered"]) == 1
    assert v["qis_url"].startswith("https://qis.verwaltung.uni-hannover.de/")


def test_card_only_around_the_period_and_fallback_without_plan(plan_db):
    from app import study_plan
    soon = _resp("2026-11-05", plan_db)
    assert soon["window"]["phase"] == "soon" and soon["show_card"] is True and soon["warnings"] == []
    later = _resp("2026-12-10", plan_db)
    assert later["window"]["term"] == "SoSe 27" and later["show_card"] is False
    no_plan = _resp("2026-11-20", study_plan.MemoryCatalogSource([]))
    assert no_plan["plan_available"] is False and no_plan["program"] is None and no_plan["window"] is None
    assert no_plan["source"]["url"].endswith("/pruefungsanmeldung")
    assert [x["title"] for x in no_plan["suggestions"]] == ["Algorithmen und Datenstrukturen", "Prüfung Rechnernetze"]
    assert no_plan["suggestions"][0]["reason_kind"] == "klausur"
    # Termin aus der gelesenen Anmeldung ("Nächste Klausuren"): abgehakt ueber die Info-Seite
    rn = no_plan["suggestions"][1]
    assert (rn["registered"], rn["registered_via"], rn["exam_date"], rn["exam_time"]) == (True, "qis_info", "2027-03-01", "09:00")


def test_reminders_like_the_ipad_plan(plan_db):
    """Gleiche Zeitpunkte wie ExamRegistrationReminders (Erster Tag, 7 und 2 Tage vor dem Ende, 9:00); ohne
    Windows-Mitteilungen zeigt die App sie als Hinweis."""
    v = _resp("2026-11-05", plan_db)
    r = v["reminders"]
    assert [x["id"] for x in r] == ["examreg.wise-26-27.meldung1.start", "examreg.wise-26-27.meldung1.d7", "examreg.wise-26-27.meldung1.d2"]
    assert [x["day"] for x in r] == ["2026-11-09", "2026-11-15", "2026-11-20"]
    assert r[2]["title"] == "Prüfungsanmeldung endet übermorgen"
    assert r[2]["body"] == "WiSe 26/27: bis So, 22.11. · 3 Prüfungen laut Plan noch nicht angemeldet"
    assert r[0]["route"] == "#/studyplan"


def test_route_answers_luh_hildesheim_and_others_unsupported(app, plan_db, monkeypatch):
    from app import db, study, study_plan
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 20))
    monkeypatch.setattr(study_plan, "DbCatalogSource", lambda conn: plan_db)
    st, _, b = asgi_call(app, "GET", "/api/exam-registration")
    v = json.loads(b)
    assert st == 200 and v["window"]["days_left"] == 2 and v["open_count"] == 4
    assert v["system"] == "QIS" and v["open_label"] == "Im QIS zur Prüfung anmelden"
    # gleiche Schluessel wie der Kern (app-paths.json)
    keys = json.loads((ROOT / "packages/shared-contracts/fixtures/local-backend/app-paths.json").read_text(encoding="utf-8"))
    want = next(e for e in keys["paths"] if e["shape"] == "/api/exam-registration")["expect"]["keys"]
    assert set(want) <= set(v)
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value='hildesheim' WHERE key='university'")
    st, _, b = asgi_call(app, "GET", "/api/exam-registration")
    hi = json.loads(b)
    assert hi["supported"] is True and hi["system"] == "LSF" and hi["open_label"] == "Im LSF zur Prüfung anmelden"
    assert hi["qis_url"] == "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0"
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value='tu-berlin' WHERE key='university'")
    st, _, b = asgi_call(app, "GET", "/api/exam-registration")
    other = json.loads(b)
    assert other["supported"] is False and other["show_card"] is False


def test_hildesheim_pos_start_without_deadline(plan_db):
    """Uni Hildesheim: Start der POS-Anmeldung 11.11.2026 fuer alle Bachelor/Master, kein Ende -> keine Warnung "endet in",
    Karte nur bis 14 Tage nach dem Start, Erinnerung nur am ersten Tag, Texte mit LSF"""
    from app import db, qis_registrations
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value='hildesheim' WHERE key='university'")
        qis_registrations.store(conn, [{"pruefungsnr": "4711", "text": "Rechnernetze", "semester": "WiSe 26/27", "datum": "01.03.2027",
                                        "time": "09:00", "status": "zugelassen", "raw": ""}], "t")
    v = _resp("2026-11-05", plan_db)
    assert v["supported"] is True and v["system"] == "LSF" and v["open_label"] == "Im LSF zur Prüfung anmelden"
    assert v["program"]["slug"] == "alle-bachelor-und-masterstudiengaenge" and v["program"]["all_programs"] is True
    assert v["source"]["url"].startswith("https://www.uni-hildesheim.de/") and v["source"]["checked_at"] == "2026-11-05"
    w = v["window"]
    assert (w["phase"], w["start"], w["days_until"], w["open_end"]) == ("soon", "2026-11-11", 6, True)
    assert v["show_card"] is True and v["warnings"] == []
    assert v["period_note"].startswith("Die Uni Hildesheim hat keine einheitliche Anmeldefrist")
    assert "LSF" in v["hint"] and "POS-Management" in v["hint"]
    assert v["periods"][0]["open_end"] is True
    assert all(s["withdraw_until"] is None for s in v["suggestions"] if s["id"] != "rechnernetze"), "keine erfundene Ruecktrittsfrist"
    rn = next(s for s in v["suggestions"] if s["id"] == "rechnernetze")
    assert rn["registered_via"] == "qis_info" and rn["exam_source"] == "aus deinen angemeldeten Prüfungen"
    r = v["reminders"]
    assert [x["id"] for x in r] == ["examreg.wise-26-27.meldung1.start"] and r[0]["day"] == "2026-11-11"
    assert r[0]["until"] == "2026-11-25" and r[0]["body"].startswith("WiSe 26/27: Anmeldung im LSF freigeschaltet, Fristen je Prüfung")
    late = _resp("2027-03-30", plan_db)
    assert late["window"]["phase"] == "open" and late["window"]["days_left"] == 1
    assert late["warnings"] == [], "ohne Ende kein 'endet morgen'"
    assert late["show_card"] is False, "nur die ersten 14 Tage"
    assert _resp("2026-11-25", plan_db)["show_card"] is True
    assert _resp("2026-11-26", plan_db)["show_card"] is False
    assert _resp("2027-04-02", plan_db)["window"] is None, "SoSe 27 noch nicht bekannt -> nur Link"
