"""Block "Klausuren & Altklausuren" geordnet (17.11.2026, Wunsch des Inhabers: zu jeder Klausur genau ihre Loesung):
app/exam_pairs.py (links, term, groups), study.module_detail (`exam_groups`) und der Aufgabenindex (weekly.index_module
liest eine Datei neu, wenn sich ihre Einordnung geaendert hat).

Gleiche Regeln im Swift-Kern: ExamPairsTests.swift gegen packages/shared-contracts/fixtures/local-backend/exam-pairs.json.
Ausgedachte Dateinamen nach dem Muster echter Kurse.
"""
import subprocess
import sys
from pathlib import Path

import pytest

from test_weekly import env  # noqa: F401  (Fixture: frische Datenbank, Modul 1, FakeAI)

ROOT = Path(__file__).resolve().parent.parent
MOD = 1


def _f(fid, name, folder, doc_type, course="cu"):
    return {"id": fid, "name": name, "course_id": course, "studip_folder": folder, "doc_type": doc_type}


def test_fixture_for_the_swift_core_is_current():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-exam-pairs-fixture.py"), "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("folder, name, label", [
    ("Alte Klausuren/WS 22/23", "KK1.pdf", "WS 22/23"),
    ("Alte Klausuren/WS25/26", "KK1.pdf", "WS 25/26"),
    ("Alte Klausuren", "KK2bWS2122lsg.pdf", "WS 21/22"),
    ("Alte Klausuren", "Klausur SS23.pdf", "SS 23"),
    ("Klausuren", "Klausur WiSe 2022/23.pdf", "WS 22/23"),
    ("Klausuren/Sommersemester 2018", "Klausur.pdf", "SS 18"),
    ("Klausuren/2019", "Klausur.pdf", "2019"),
    ("Alte Klausuren/WS 22/23", "Klausur SS 21.pdf", "WS 22/23"),      # der Ordner geht vor
    ("Alte Kurzklausuren", "gk.pdf", None),
    ("Klausuren", "news24.pdf", None),
    ("Klausuren", "Klasse 12.pdf", None),
])
def test_term_from_folder_and_name(folder, name, label):
    from app import exam_pairs
    t = exam_pairs.term(folder, name)
    assert (t[1] if t else None) == label


def test_newer_terms_rank_higher():
    from app import exam_pairs
    ranks = [exam_pairs.term(f, "x.pdf")[0] for f in ("SS 21", "WS 21/22", "SS 22", "WS 22/23", "WS25/26")]
    assert ranks == sorted(ranks) and len(set(ranks)) == 5


def test_order_of_the_exam_block():
    """Freigegebene Ordnung: neuester Jahrgang zuerst, jede Klausur mit ihrer Loesung direkt darunter, Sammel-Loesung am
    Ende des Jahrgangs, eine Klausur ohne Loesung ohne Platzhalter, keine Datei verschwindet"""
    from app import exam_pairs
    k, l = "klausur", "loesung"
    files = [
        _f("a1", "KK1.pdf", "Alte Klausuren/WS 22/23", k), _f("a1s", "KK1loes.pdf", "Alte Klausuren/WS 22/23", l),
        _f("a10", "KK10.pdf", "Alte Klausuren/WS 22/23", k), _f("a2", "KK2.pdf", "Alte Klausuren/WS 22/23", k),
        _f("b1", "kk1b.pdf", "Alte Klausuren/WS 23/24", k), _f("b1s", "sol1b.pdf", "Alte Klausuren/WS 23/24", l),
        _f("c1", "KK1.pdf", "Alte Klausuren/WS 20/21", k), _f("c2", "KK2.pdf", "Alte Klausuren/WS 20/21", k),
        _f("cs", "Lösungen.pdf", "Alte Klausuren/WS 20/21", l), _f("x", "Lösung ohne Klausur.pdf", "Alte Klausuren/WS 22/23", l),
        _f("g", "gk.pdf", "Alte Kurzklausuren", k), _f("gs", "gk_lsg.pdf", "Alte Kurzklausuren", l), _f("p", "Probeklausur.pdf", "", k),
    ]
    groups = exam_pairs.groups(files, exam_pairs.links(files))
    assert [g["label"] for g in groups] == ["WS 23/24", "WS 22/23", "WS 20/21", "Alte Kurzklausuren", "Ohne Ordner"]
    rows = [[(f["id"], f["exam_role"], f["solution_of"]) for f in g["files"]] for g in groups]
    assert rows[0] == [("b1", "klausur", None), ("b1s", "loesung", "b1")]
    assert rows[1] == [("a1", "klausur", None), ("a1s", "loesung", "a1"), ("a2", "klausur", None), ("a10", "klausur", None),
                       ("x", "weitere_loesung", None)]
    assert rows[2] == [("c1", "klausur", None), ("c2", "klausur", None), ("cs", "weitere_loesung", None)]
    assert rows[3] == [("g", "klausur", None), ("gs", "loesung", "g")]
    assert rows[4] == [("p", "klausur", None)]
    assert sorted(f[0] for r in rows for f in r) == sorted(f["id"] for f in files), "jede Datei genau einmal"


def test_solution_of_another_term_is_never_taken():
    from app import exam_pairs
    files = [_f("old", "KK2.pdf", "Alte Klausuren/WS 19/20", "klausur"), _f("new", "KK2.pdf", "Alte Klausuren/WS 21/22", "klausur"),
             _f("s", "KK2loes.pdf", "Alte Klausuren/WS 21/22", "loesung"),
             _f("b", "Blatt 2.pdf", "Übungsblätter", "uebung"), _f("bs", "Lösung Blatt 2.pdf", "Lösungen", "loesung")]
    found = exam_pairs.links(files)
    assert found["new"] == ["name", ["s"]] and "old" not in found
    assert found["b"] == ["modul", ["bs"]], "Loesungen im eigenen Ordner finden weiter ueber das Modul"


def test_the_own_folder_claims_a_solution_before_the_module():
    from app import exam_pairs
    files = [_f("A", "Klausur SS 22.pdf", "Klausuren", "klausur", "cv"), _f("b", "klausur ss 22.pdf", "Klausuren", "klausur"),
             _f("s", "klausur ss 22 lsg.pdf", "Klausuren", "loesung")]
    rows = [(f["id"], f["solution_of"]) for g in exam_pairs.groups(files, exam_pairs.links(files)) for f in g["files"]]
    assert rows == [("A", None), ("b", None), ("s", "b")]


def test_module_detail_orders_the_exam_block_and_leaves_other_weeks_alone(env):  # noqa: F811
    from app import study
    text = ["Aufgabe 1: Text mit genug Inhalt fuer eine Aufgabe."]
    for fid, name, folder in [("e1", "KK1.pdf", "Alte Klausuren/WS 22/23"), ("s1", "KK1loes.pdf", "Alte Klausuren/WS 22/23"),
                              ("e2", "kk3a.pdf", "Alte Klausuren/WS 21/22"), ("s2", "sol3a.pdf", "Alte Klausuren/WS 21/22"),
                              ("e3", "KK2.pdf", "Alte Klausuren/WS 20/21"), ("s3", "Lösungen.pdf", "Alte Klausuren/WS 20/21")]:
        env.add_file(fid, name, folder, text, chdate=1676000000)
    with env.conn() as c:
        d = study.module_detail(c, MOD)
    block = next(w for w in d["weeks"] if w["week"] == -2)
    mine = [[f["id"] for f in g["files"] if f["id"] in ("e1", "s1", "e2", "s2", "e3", "s3")] for g in block["exam_groups"]]
    assert [m for m in mine if m] == [["e1", "s1"], ["e2", "s2"], ["e3", "s3"]]
    labels = [g["label"] for g in block["exam_groups"] if any(f["id"] in ("e1", "e2", "e3") for f in g["files"])]
    assert labels == ["WS 22/23", "WS 21/22", "WS 20/21"]
    in_groups = sorted(f["id"] for g in block["exam_groups"] for f in g["files"])
    assert in_groups == sorted(f["id"] for f in block["klausuren"] + block["loesungen"]), "jede Datei des Blocks genau einmal"
    assert all("exam_groups" not in w for w in d["weeks"] if w["week"] != -2)


def test_index_reads_a_file_again_when_its_role_changed(env):  # noqa: F811
    """"sol3a.pdf" stand vor dem 17.11.2026 als Altklausur im Aufgabenindex; mit unveraenderter Datei waere sie nie zur
    Loesung geworden (doc_index merkt sich nur die Dateiversion)"""
    from app import weekly
    folder = "Alte Klausuren/WS 21/22"
    env.add_file("kx", "kk3a.pdf", folder, ["Aufgabe 1: Berechnen Sie den Grenzwert der Folge a_n mit genug Text fuer eine Aufgabe."])
    env.add_file("sx", "sol3a.pdf", folder, ["Aufgabe 1: Der Grenzwert der Folge ist 2, Herleitung mit genug Text fuer eine Aufgabe."])
    with env.conn() as c:
        weekly.index_module(c, MOD)
        # Stand von vorher: die Loesung als Altklausur im Index, Klausur ohne Loesung
        c.execute("UPDATE task_index SET source='altklausur' WHERE file_id='sx'")
        c.execute("UPDATE doc_index SET role='altklausur' WHERE file_id='sx'")
        c.execute("UPDATE task_index SET solution_file_id=NULL, solution_text=NULL")
        r = weekly.index_module(c, MOD)
        assert r["indexed"] == 1, "nur die Datei mit neuer Einordnung"
        assert c.execute("SELECT source FROM task_index WHERE file_id='sx'").fetchone()[0] == "loesung"
        assert c.execute("SELECT solution_file_id FROM task_index WHERE file_id='kx' AND nr='1'").fetchone()[0] == "sx"
