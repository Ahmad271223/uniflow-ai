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
    bodies = [b.split('\n"""#', 1)[0] for b in swift.split('#"""\n')[1:]]
    assert len(bodies) == 3
    assert json.loads(bodies[0]) == er.load_data()
    assert json.loads(bodies[1]) == er.for_university("hildesheim")
    assert json.loads(bodies[2]) == er.for_university("hsh")


# ---------------------------------------------------------------- Uni Hildesheim (gelesen am 05.11.2026)

def test_hildesheim_data_has_sources_and_no_guessed_end():
    d = er.for_university("hildesheim")
    assert _gen().check_data(d, "hildesheim") == []
    assert d["system"] == "LSF" and d["qis_menu"] == "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0"
    assert all(s["url"].startswith("https://www.uni-hildesheim.de/") and s["checked_at"] == "2026-11-05" for s in d["sources"])
    periods = [p for t in d["tables"].values() for term in t["terms"] for p in term["periods"]]
    assert periods == [{"kind": "meldung", "n": 1, "label": "POS-Anmeldung im LSF (Fristen je Prüfung im LSF)", "start": "2026-11-11",
                        "end": "2027-03-31", "open_end": True,
                        "source": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/"}]
    assert "Verbindliche Anmeldung" in {r["form"] for r in d["rules"]}
    assert not any(r["withdraw_days_before"] for r in d["rules"]), "keine erfundenen Ruecktrittsfristen"
    assert sum(1 for p in d["programs"] if p.get("default")) == 1
    assert len(d["programs"]) >= 60
    assert er.for_university("tu-berlin") is None


def test_hildesheim_programs_and_open_end_window():
    d = er.for_university("hildesheim")
    ai = er.find_program(d, "Angewandte Informatik (PO-Version 2019)", "B.Sc.")
    assert ai["slug"] == "angewandte-informatik-bsc" and ai["url"].endswith("/pruefungsamt-4/")
    assert er.find_program(d, "Kochkunst", "B.Sc.") is None
    assert er.resolve_program(d, "Kochkunst", "B.Sc.")["slug"] == "alle-bachelor-und-masterstudiengaenge"
    wb = er.find_program(d, "Weiterbildungsprogramm Inklusive Bildung, Inklusive Pädagogik und Kommunikation", "M.A.")
    assert wb is not None and wb["table"] is None, "Weiterbildungsmaster: nur Link"
    w = er.window_state(d, ai, "2026-11-05")
    assert (w["phase"], w["start"], w["days_until"], w["open_end"]) == ("soon", "2026-11-11", 6, True)
    assert er.window_state(d, ai, "2026-12-01")["phase"] == "open"
    assert er.window_state(d, ai, "2027-04-01") is None, "SoSe 27 noch nicht veroeffentlicht -> nur Link"
    luh = er.window_state(er.load_data(), er.find_program(er.load_data(), "Informatik", "B.Sc."), "2026-11-05")
    assert luh["open_end"] is False


def test_hildesheim_zustaendigkeiten_parser():
    g = _gen()
    assert g.hildesheim_degrees("Erziehungswissenschaft (B. A. und M. A.)") == ("Erziehungswissenschaft", ["ba", "ma"])
    assert g.hildesheim_degrees("Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - mit Lehramtsoption") == (
        "Polyvalenter Zwei-Fächer-Bachelor Studiengang mit Lehramtsoption", ["ba", "bsc"])
    assert g.hildesheim_degrees("Angewandte Informatik (Studienvariante im Studiengang X) (B. Sc. und M. Sc.)") == (
        "Angewandte Informatik (Studienvariante im Studiengang X)", ["bsc", "msc"])
    assert g.hildesheim_degrees("Austauschstudierende") == ("Austauschstudierende", [])
    html = """<details><summary><span>Fachbereich IV: Informatik</span></summary><div>
      <a href="/studium/studierende/pruefungsamt/pruefungsamt-4/">Angewandte Informatik (B. Sc. und M. Sc.)</a>
      <a href="https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/">A (M.A.), B (M.A.))</a>
      <a href="/studium/studierende/pruefungsamt/pruefungsamt-1/">Weiterbildungsprogramm X (M.A. berufsbegleitend)</a>
      <a href="/anderes/">Ohne Pruefungsamt (B. A.)</a></div></details>"""
    progs = g.hildesheim_programs(html, "2026-11-05")
    assert [(p["slug"], p["table"]) for p in progs] == [
        ("angewandte-informatik-bsc", "hildesheim-pos"), ("angewandte-informatik-msc", "hildesheim-pos"),
        ("a-ma", "hildesheim-pos"), ("b-ma", "hildesheim-pos"), ("weiterbildungsprogramm-x-ma", None),
        ("alle-bachelor-und-masterstudiengaenge", "hildesheim-pos")]
    assert progs[0]["url"] == "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/"
    assert progs[0]["faculty"] == "Fachbereich IV: Informatik" and progs[-1]["default"] is True
