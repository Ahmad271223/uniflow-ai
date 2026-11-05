"""Pruefungsanmeldung (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Datendatei der LUH-Meldezeitraeume, Zuordnung
Studiengang -> Terminseite, Phase je Tag (app/exam_registration.py, gleiche Faelle wie der Swift-Kern), Leser der
gespeicherten Terminseiten im Erzeuger. Nur erfundene oder oeffentliche Daten, kein Netz."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

from app import exam_registration as er

ROOT = Path(__file__).resolve().parents[1]


def _gen():
    spec = importlib.util.spec_from_file_location("gen_exam_registration", ROOT / "tools" / "gen-exam-registration-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ROOT / "tools"))
    spec.loader.exec_module(mod)
    return mod


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-exam-registration-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_data_file_is_valid_and_has_source():
    d = er.load_data()
    assert _gen().check_data(d) == []
    assert d["general"]["url"].startswith("https://www.uni-hannover.de/")
    verified = [p for p in d["programs"] if p["table"]]
    assert {p["slug"] for p in verified} >= {"technische-informatik-bsc", "informatik-bsc", "mathematik-bsc"}
    assert all(p["checked_at"] == "2026-11-05" for p in verified)
    assert len(d["programs"]) >= 90


def test_technische_informatik_winter_2026():
    d = er.load_data()
    p = er.find_program(d, "Technische Informatik (PO-Version 2017)", "B.Sc.")
    assert p["slug"] == "technische-informatik-bsc"
    w = er.window_state(d, p, "2026-11-05")
    assert (w["term"], w["start"], w["end"], w["phase"], w["days_until"]) == ("WiSe 26/27", "2026-11-09", "2026-11-22", "soon", 4)
    assert er.window_state(d, p, "2026-11-22")["phase"] == "open"
    assert er.window_state(d, p, "2026-11-23")["term"] == "SoSe 27"
    assert er.window_state(d, p, "2027-10-01") is None, "Daten zu alt -> nur Link"
    # Variante 2: zweiter Meldezeitraum
    m = er.find_program(d, "Mathematik", "B.Sc.")
    w2 = er.window_state(d, m, "2027-03-02")
    assert (w2["n"], w2["start"], w2["end"], w2["phase"]) == (2, "2027-03-01", "2027-03-07", "open")


def test_unknown_or_ambiguous_program_gives_no_dates():
    d = er.load_data()
    assert er.find_program(d, "Technische Informatik", None) is None, "B.Sc. und M.Sc. -> nicht eindeutig"
    assert er.find_program(d, "Kochkunst", "B.Sc.") is None
    arch = er.find_program(d, "Architektur", "B.Sc.")
    assert arch["table"] is None and er.window_state(d, arch, "2026-11-10") is None


def test_parser_reads_termine_page_and_skips_dates_without_year():
    html = """<main><h3>Für diesen Studiengang gilt die Variante 2.</h3>
    <h3>Sommersemester 2026</h3><table class="contenttable"><tr><td>Meldezeitraum VbP*</td><td>15.04. - 30.04.</td></tr></table>
    <h3>Wintersemester 2026/27</h3><table class="contenttable"><tbody>
    <tr><td>Meldezeitraum für VbP*</td><td>Mo, 19.10.2026 - So, 01.11.2026</td></tr>
    <tr><td>Bewertungsfrist für VbP*</td><td>Do, 18.03.2027</td></tr>
    <tr><td>2. Meldezeitraum&nbsp; - <span>alle anderen Prüfungsformen</span>**</td><td>Mo, 01.03.2027 - So, 07.03.2027</td></tr>
    </tbody></table></main>"""
    variant, terms = _gen().read_page(html)
    assert variant == "2"
    assert [t["term"] for t in terms] == ["WiSe 26/27"], "SoSe 2026 ohne Jahr bleibt weg"
    assert terms[0]["periods"] == [
        {"kind": "vbp_meldung", "n": 1, "label": "Meldezeitraum für VbP", "start": "2026-10-19", "end": "2026-11-01"},
        {"kind": "vbp_bewertung", "n": 1, "label": "Bewertungsfrist für VbP", "start": "2027-03-18", "end": "2027-03-18"},
        {"kind": "meldung", "n": 2, "label": "Meldezeitraum alle anderen Prüfungsformen", "start": "2027-03-01", "end": "2027-03-07"},
    ]


def test_swift_copy_is_the_data_file():
    swift = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/ExamRegistration/ExamRegistrationData.swift").read_text(encoding="utf-8")
    body = swift.split('#"""\n', 1)[1].rsplit('\n"""#', 1)[0]
    assert json.loads(body) == er.load_data()
