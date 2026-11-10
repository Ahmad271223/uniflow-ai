"""Bescheinigungen (06.11.2026, app/certificates.py, docs/BESCHEINIGUNGEN-2026-11-06.md): Art und Semester aus dem Titel,
Angebote der QIS-/LSF-Seiten (nur Links, kein asi), HISinOne-Berichtsknoepfe (HsH und PLuS, live bestaetigt), Anzeige
GET /api/certificates, PDF nur aus dem eigenen QIS-Ordner, Herunterladen nicht im Dienst, automatischer Notenabruf ohne
PDF. Gemeinsame Fixture packages/shared-contracts/fixtures/certificates/cases.json (nachgebaute Seiten). Dazu die echte
Seite "Meine Bescheinigungen" der LUH vom 10.11.2026 (qis-echt-bescheinigungen.html, anonymisiert). Kein Netz."""
import json
import subprocess
import sys
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = json.loads((ROOT / "packages/shared-contracts/fixtures/certificates/cases.json").read_text(encoding="utf-8"))


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-certificates-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_text_rules():
    from app import certificates as C
    for c in FX["kinds"]:
        assert C.kinds_of(c["title"]) == c["kinds"]
    assert C.kinds_of("Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG") == ["immatrikulation", "bafoeg"]
    assert C.semester_of("Zahlungsnachweis (ab WS 2021/22)") is None, "ab-Angabe ist kein Semester des Dokuments"
    assert C.semester_of("WS 26/27") == "WiSe 2026/27" and C.semester_of("Sommersemester 25") == "SoSe 2025"
    assert C.clean_title("PDF-Notenspiegel zum Drucken") == "Notenspiegel"
    assert C.semester_rank("WiSe 2026/27") > C.semester_rank("SoSe 2026") > C.semester_rank(None)


def test_qis_offers_only_links_without_session():
    from app import certificates as C
    for p in FX["qis"]:
        got = C.qis_offers(p["html"], p["url"], p["source"], p["university"], p["confirmed"])
        assert got == p["offers"]
        for o in got:
            assert "asi=" not in o["address"] and "jsessionid" not in o["address"].lower()
    luh = FX["qis"][0]["offers"]
    assert len(luh) == 1 and "publishContainer=bafoegbescheinigung" in luh[0]["address"], "einziger Eintrag wie live gesehen"
    assert FX["qis"][3]["offers"] == [], "LSF Hildesheim: keine Bescheinigungen"


def test_real_luh_page_offers_german_and_english_certificate():
    """Echte Seite "Meine Bescheinigungen" der LUH (10.11.2026, nur gelesen, anonymisiert): zwei Eintraege (deutsch und
    englisch), jeder Link steht zweimal auf der Seite; Start- und Menueseite tragen kein asi (Sitzung per Cookie)."""
    from app import certificates as C
    fx = ROOT / "packages/shared-contracts/fixtures"
    base = "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet"
    start = (fx / "exam-registration/qis-echt-start.html").read_text(encoding="utf-8")
    page = (fx / "certificates/qis-echt-bescheinigungen.html").read_text(encoding="utf-8")
    menu = [a for a in C.anchors(start, base + "?state=user&type=0&application=lsf") if C._menu_priority(a) == 0]
    assert [a["text"] for a in menu] == ["Meine Bescheinigungen"]
    assert "moduleParameter=studentReportsMenu" in menu[0]["address"] and "asi=" not in menu[0]["raw"]
    assert C.qis_offers(start, base + "?state=user&type=0&application=lsf", "bescheinigungen", "luh", True) == []
    got = C.qis_offers(page, menu[0]["raw"], "bescheinigungen", "luh", True)
    assert [o["title"] for o in got] == [
        "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG",
        "Certificate of study period and enrolment / Certificate in accordance with § 9 BAföG"]
    assert [o["address"] for o in got] == [base + "?state=verpublish&publishContainer=bafoegbescheinigung&menuid=bafoeg",
                                           base + "?state=verpublish&publishContainer=studienbescheinigungEN&menuid=studbeschEN"]
    assert [o["id"] for o in got] == ["d595729c4608", "c93f794f4b7b"], "dieselben Kennungen wie auf dem iPad"
    for o in got:
        assert o["kinds"] == ["immatrikulation", "bafoeg"] and o["kind"] == "immatrikulation"
        assert o["source"] == "bescheinigungen" and o["portal"] == "qis" and o["confirmed"] is True
        assert o["semester"] is None and o["semesters"] == []
    assert not any("state=verify" in o["address"] for o in got), "der Link verifizierbar ist kein Dokument"
    # Pruefungsanmeldung, Abmelden, Dokumente und der Pruefdienst sind nie ein Menue zum Weitergehen
    studium = (fx / "exam-registration/qis-echt-studium.html").read_text(encoding="utf-8")
    for html in (start, page, studium):
        for a in C.anchors(html, base):
            if C._menu_priority(a) is not None:
                low = a["address"].lower()
                assert not any(w in low for w in ("prfanm", "logout", "verpublish", "state=verify", "hisreports")), a["address"]
    assert "asi=" not in start and "asi=" not in page, "Start und Menue ohne Sitzungsparameter, wie live gesehen"


def test_hisinone_job_buttons_hsh_and_plus():
    from app import certificates as C
    by = {p["name"]: p for p in FX["hisinone"]}
    hsh = by["hsh-berichte-knoepfe"]
    assert [o["title"] for o in C.hisinone_offers(hsh["html"], "hsh")][:3] == [
        "Zahlungsbeleg mit Zahlungshistorie", "Payment receipt and payment history", "Bescheinigung über angemeldete Prüfungen"]
    assert C.hisinone_poll(hsh["html"]).endswith("jobDownloadPoll:pollOnStop")
    plus = C.hisinone_offers(by["plus-hildesheim-berichte"]["html"], "hildesheim")
    assert {o["kind"] for o in plus} >= {"immatrikulation", "bafoeg", "bescheid"} and all(o["confirmed"] for o in plus)
    assert C.hisinone_offers(by["hsh-bescheide-leer"]["html"], "hsh") == []
    # versteckter Block "Sitzung abgelaufen / Anmelden" aendert den Anmeldestand nie
    assert C._hisinone_logged_in(hsh["html"], "https://campusmanagement.hs-hannover.de/qisserver/pages/x", "https://campusmanagement.hs-hannover.de")
    assert not C._hisinone_logged_in(hsh["html"], "https://idp.hs-hannover.de/x", "https://campusmanagement.hs-hannover.de")


def test_summary_route_and_file_only_from_own_folder(app):
    from app import certificates as C, config, db
    db.init_db()
    case = FX["summary"][0]
    with db.cursor() as conn:
        C.save(conn, case["state"])
    st, _, body = asgi_call(app, "GET", "/api/certificates")
    got = json.loads(body)
    assert st == 200 and got["documents"] == []
    got.pop("documents")
    want = dict(case["summary"], university=got["university"], portal=got["portal"], note=got["note"])
    assert got == want
    oid = case["state"]["offers"][0]["id"]
    assert asgi_call(app, "GET", f"/api/certificates/{oid}/file")[0] == 404
    with db.cursor() as conn:
        p = C.store_file(conn, case["state"]["offers"][0], b"%PDF-1.4 erfunden", None, "2026-11-06T14:03:00")
    assert p.parent == config.data_dir() / "qis"
    st, hdrs, body = asgi_call(app, "GET", f"/api/certificates/{oid}/file")
    assert st == 200 and body == b"%PDF-1.4 erfunden"
    s = json.loads(asgi_call(app, "GET", "/api/certificates")[2])
    row = next(o for o in s["offers"] if o["id"] == oid)
    assert row["file"]["fetched_at"] == "2026-11-06T14:03:00" and row["file"]["url"] == f"/api/certificates/{oid}/file"
    # Pfad ausserhalb des QIS-Ordners wird nie ausgeliefert
    with db.cursor() as conn:
        s2 = C.load(conn)
        s2["files"][oid]["path"] = "../geheim.pdf"
        C.save(conn, s2)
    (config.data_dir().parent / "geheim.pdf").write_bytes(b"%PDF geheim")
    assert asgi_call(app, "GET", f"/api/certificates/{oid}/file")[0] == 404


def test_download_rejects_unknown_ids_and_never_runs_in_hosted(app, monkeypatch):
    from app import certificates as C, config
    called = []
    monkeypatch.setattr(C, "download", lambda *a, **k: called.append(a) or {"ok": True, "message": "x"})
    assert asgi_call(app, "POST", "/api/certificates/zzz/download", body="{}")[0] == 404
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    assert asgi_call(app, "POST", "/api/certificates/0123456789ab/download", body="{}")[0] in (409, 401, 403)
    assert called == []


def test_automatic_grade_run_never_creates_pdfs(monkeypatch):
    from app import qis, sync_order
    seen = {}
    monkeypatch.setattr(qis, "configured", lambda key=None: True)
    monkeypatch.setattr(qis, "run", lambda **kw: seen.update(kw) or {"message": "0 Leistungen"})
    sync_order.run_grades_if_due(force=True)
    assert seen.get("with_documents") is False
