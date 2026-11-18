"""Altklausur-Loesungen (17.11.2026): Einordnung der Datei (app/study.py effective_type) und Klausur und Loesung
zusammenfuehren (app/weekly.py _solution_key, _link_solutions).

Gemeldet: "Die App zeigt Altklausuren-Loesungen nicht an." Nachgerechnet mit den Namensmustern echter Kurse (hier
ausgedachte Namen nach demselben Muster):
- "sol3a.pdf" neben "kk3a.pdf" blieb "Altklausur", "Lsg_SS21.pdf" blieb ohne Einordnung, eine Loesung im Ordner
  "Alte Prüfungen" oder "Exam" war nur "Lösung" und stand in einer normalen Woche statt im Block
  "Klausuren & Altklausuren"
- "kk3a"/"sol3a", "TK"/"Lösungen zu TK", "…-WS1920"/"A4-Loesung-…-WS1920" und die Sammeldatei "Lösungen.pdf" fanden
  ihre Klausur nicht
Gleiche Regeln im Swift-Kern: AltklausurLoesungenTests.swift, Tabelle in study-modules.json (effective_type).
"""
from datetime import date

import pytest

from test_weekly import env  # noqa: F401  (Fixture: frische Datenbank, Modul 1, FakeAI)

MOD = 1


# ---------------------------------------------------------------------------------------------- Einordnung der Datei
@pytest.mark.parametrize("name, folder, expected", [
    # "sol" + Kennung neben "kk" + Kennung
    ("sol0b.pdf", "Alte Klausuren/WS 21/22", ("loesung", "Klausur-Lösung")),
    ("sol3a.pdf", "Alte Klausuren/WS 21/22", ("loesung", "Klausur-Lösung")),
    ("kk3a.pdf", "Alte Klausuren/WS 21/22", ("klausur", "Altklausur")),
    ("kk3a_sol.pdf", "Kurzklausuren", ("loesung", "Klausur-Lösung")),
    ("sol.pdf", "Probeklausur", ("loesung", "Klausur-Lösung")),
    # "Lsg" am Namensanfang mit Unterstrich
    ("Lsg_SS21.pdf", "", ("loesung", "Lösung")),
    ("Lsg_SS21.pdf", "Klausuren", ("loesung", "Klausur-Lösung")),
    ("lsg2.pdf", "Übung 2", ("loesung", "Lösung")),
    # Ordner mit "Prüfung" oder "Exam" statt "Klausur"
    ("Loesung.pdf", "Alte Prüfungen/SS 21", ("loesung", "Klausur-Lösung")),
    ("Musterlösung.pdf", "Pruefung WS 20", ("loesung", "Klausur-Lösung")),
    ("Probeprüfung Lösung.pdf", "", ("loesung", "Klausur-Lösung")),
    ("solution.pdf", "Exam 2021", ("loesung", "Klausur-Lösung")),
    ("Solutions.pdf", "Old Exams", ("loesung", "Klausur-Lösung")),
    ("Pruefung_SS21.pdf", "Alte Prüfungen/SS 21", ("klausur", "Altklausur")),
    ("Aufgaben.pdf", "Prüfung", ("klausur", "Klausur")),
    # normale Dateien bleiben, was sie waren
    ("Lösung Blatt 3.pdf", "Übungen", ("loesung", "Lösung")),
    ("Blatt3_lsg.pdf", "Übungsblätter", ("loesung", "Lösung")),
    ("Example_solution.pdf", "Übung", ("loesung", "Lösung")),
    ("Lösung.pdf", "Prüfungsvorleistung", ("loesung", "Lösung")),
    ("Lösung Selbstüberprüfung.pdf", "Übung", ("loesung", "Lösung")),
    ("Solar.pdf", "Vorlesung", ("vorlesung", "Vorlesung")),
    ("Konsole.pdf", "Vorlesung", ("vorlesung", "Vorlesung")),
    ("Sol-Gel-Verfahren.pdf", "Vorlesung", ("vorlesung", "Vorlesung")),
    ("Prüfungsordnung.pdf", "", ("sonstiges", "Sonstiges")),
    ("Blatt3.pdf", "Prüfungsvorleistungen", ("uebung", "Übung")),
])
def test_type_of_exam_solutions_and_normal_files(name, folder, expected):
    from app.study import effective_type
    assert effective_type(name, folder, None) == expected


def test_exam_solutions_go_to_the_exam_block_and_normal_solutions_stay_in_their_week():
    from app import study
    start = date(2026, 10, 12)

    def week(name, folder):
        f = study.enrich_file({"name": name, "studip_folder": folder, "doc_type": None, "chdate": None, "id": "x"})
        return study.week_label(start, study.auto_week(start, f))

    for name, folder in [("sol3a.pdf", "Alte Klausuren/WS 21/22"), ("Lsg_SS21.pdf", "Klausuren"), ("Loesung.pdf", "Alte Prüfungen/SS 21"),
                         ("solution.pdf", "Exam 2021"), ("kk3a.pdf", "Alte Klausuren/WS 21/22")]:
        assert week(name, folder) == "Klausuren & Altklausuren", (name, folder)
    for name, folder in [("Lösung Blatt 3.pdf", "Übungen"), ("Lsg_SS21.pdf", ""), ("Lösung.pdf", "Prüfungsvorleistung")]:
        assert week(name, folder) != "Klausuren & Altklausuren", (name, folder)


# ------------------------------------------------------------------------------- Klausur und Loesung zusammenfuehren
@pytest.mark.parametrize("task, solution", [
    ("kk3a.pdf", "sol3a.pdf"),
    ("TK.pdf", "Lösungen zu TK.pdf"),
    ("Muster-Klausuraufgaben-WS1920.pdf", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf"),
    # diese Paare fanden sich schon vorher
    ("KK1.pdf", "KK1loes.pdf"),
    ("gk.pdf", "gk_lsg.pdf"),
    ("KK2bWS2122auf.pdf", "KK2bWS2122lsg.pdf"),
    ("kkw17_auf.pdf", "kkw17_loes.pdf"),
    ("A4.pdf", "A4_lsg.pdf"),
])
def test_keys_of_exam_and_solution_fit(task, solution):
    from app import weekly
    a, b = weekly._solution_key(task), weekly._solution_key(solution)
    pa, pb = weekly._plain_key(task), weekly._plain_key(solution)
    tail = weekly.ID_TAIL.match(a)
    same = a == b or pa == pb
    part = min(len(a), len(b)) >= 4 and (a in b or b in a) and weekly._numbers(a) == weekly._numbers(b)
    assert same or part or (tail and tail.group(1) == b), (a, b, pa, pb)


def test_sol_counts_only_as_a_piece_of_its_own_in_the_key():
    from app import weekly
    assert weekly._solution_key("sol3a.pdf") == "3a" and weekly._solution_key("kk3a_sol.pdf") == "kk3a"
    assert weekly._solution_key("Konsole 1.pdf") == "konsole1" and weekly._solution_key("Solar_2.pdf") == "solar2"
    assert weekly._solution_key("Zusatzaufgaben.pdf") == "zusatzaufgaben", "'zu' faellt nur als eigenes Wort weg"


def _task(c, file_id, source, nr):
    c.execute("""INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, lecture_refs,
                 content_hash, indexed_at) VALUES (?, 'v', ?, ?, ?, ?, 1, 1, ?, '[]', 'h', '2026-11-01T10:00:00')""",
              (file_id, MOD, source, nr, f"{file_id} {nr}", f"Text von {file_id}, Aufgabe {nr}"))


def _solution(c, file_id, nr="1"):
    r = c.execute("SELECT solution_file_id, solution_text FROM task_index WHERE file_id=? AND nr=?", (file_id, nr)).fetchone()
    assert r is not None, f"Aufgabe {file_id}/{nr} fehlt"
    assert (r[0] is None) == (r[1] is None), "Datei und Text der Loesung gehoeren zusammen"
    return r[0]


def _files(env, files):  # noqa: F811
    """files: (ID, Name, Ordner, Quelle, Aufgabennummern)"""
    for fid, name, folder, _source, _nrs in files:
        env.add_file(fid, name, folder, ["Aufgabe 1: Text mit genug Inhalt fuer eine Aufgabe."])
    from app import weekly
    with env.conn() as c:
        c.execute("DELETE FROM task_index")
        for fid, _name, _folder, source, nrs in files:
            for nr in nrs:
                _task(c, fid, source, nr)
        weekly._link_solutions(c, MOD)


def test_pairs_in_the_same_folder(env):  # noqa: F811
    old = "Alte Klausuren/WS 21/22"
    _files(env, [
        # "kk" + Kennung und "sol" + Kennung
        ("k0", "kk0b.pdf", old, "altklausur", ["1", "2"]), ("s0", "sol0b.pdf", old, "loesung", ["1", "2"]),
        ("k3", "kk3a.pdf", old, "altklausur", ["1"]), ("s3", "sol3a.pdf", old, "loesung", ["1"]),
        ("k4", "kk4a.pdf", old, "altklausur", ["1"]),                                         # ohne Loesung
        # "Lösungen zu …" mit kurzem Namen
        ("tk", "TK.pdf", "Probeklausur", "altklausur", ["1"]), ("tks", "Lösungen zu TK.pdf", "Probeklausur", "loesung", ["1"]),
        # Papierformat vor dem Namen
        ("mk", "Muster-Klausuraufgaben-WS1920.pdf", "Klausur", "altklausur", ["1"]),
        ("mks", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf", "Klausur", "loesung", ["1"]),
        # schon vorher gefunden
        ("a", "KK1.pdf", "Kurzklausuren", "altklausur", ["1"]), ("as", "KK1loes.pdf", "Kurzklausuren", "loesung", ["1"]),
        ("b", "gk.pdf", "Kurzklausuren", "altklausur", ["1"]), ("bs", "gk_lsg.pdf", "Kurzklausuren", "loesung", ["1"]),
        ("d", "KK2bWS2122auf.pdf", "Kurzklausuren", "altklausur", ["1"]), ("ds", "KK2bWS2122lsg.pdf", "Kurzklausuren", "loesung", ["1"]),
        ("e", "kkw17_auf.pdf", "Kurzklausuren", "altklausur", ["1"]), ("es", "kkw17_loes.pdf", "Kurzklausuren", "loesung", ["1"]),
    ])
    with env.conn() as c:
        assert _solution(c, "k0") == "s0" and _solution(c, "k0", "2") == "s0"
        assert _solution(c, "k3") == "s3"
        assert _solution(c, "k4") is None, "kk4a hat keine Loesung, nie die von kk3a"
        assert _solution(c, "tk") == "tks"
        assert _solution(c, "mk") == "mks"
        assert [_solution(c, f) for f in ("a", "b", "d", "e")] == ["as", "bs", "ds", "es"]


def test_same_names_in_two_term_folders_stay_in_their_folder(env):  # noqa: F811
    _files(env, [
        ("k21", "kk1b.pdf", "Alte Klausuren/WS 21/22", "altklausur", ["1"]), ("s21", "sol1b.pdf", "Alte Klausuren/WS 21/22", "loesung", ["1"]),
        ("k20", "kk1b.pdf", "Alte Klausuren/WS 20/21", "altklausur", ["1"]), ("s20", "sol1b.pdf", "Alte Klausuren/WS 20/21", "loesung", ["1"]),
        ("k19", "kk1b.pdf", "Alte Klausuren/WS 19/20", "altklausur", ["1"]),                # Ordner ohne Loesung
        ("p21", "KK2.pdf", "Alte Klausuren/WS 21/22", "altklausur", ["1"]), ("q21", "KK2loes.pdf", "Alte Klausuren/WS 21/22", "loesung", ["1"]),
        ("p20", "KK2.pdf", "Alte Klausuren/WS 20/21", "altklausur", ["1"]), ("q20", "KK2loes.pdf", "Alte Klausuren/WS 20/21", "loesung", ["1"]),
    ])
    with env.conn() as c:
        assert (_solution(c, "k21"), _solution(c, "k20")) == ("s21", "s20")
        assert _solution(c, "k19") is None, "die Kennung zaehlt nur im eigenen Ordner"
        assert (_solution(c, "p21"), _solution(c, "p20")) == ("q21", "q20"), "gleicher Name in zwei Semestern: der eigene Ordner gilt"


def test_identifier_pairs_only_when_unique_and_never_sheet_one_with_ten(env):  # noqa: F811
    _files(env, [
        ("u3", "Übung 3.pdf", "Übungen", "uebungsblatt", ["1"]), ("l3", "Lösung 3.pdf", "Übungen", "loesung", ["1"]),
        ("b1", "Blatt 1.pdf", "Blätter", "uebungsblatt", ["1"]), ("b10", "Blatt 10.pdf", "Blätter", "uebungsblatt", ["1"]),
        ("l10", "Lösung 10.pdf", "Blätter", "loesung", ["1"]),
        # zwei Aufgabendateien mit derselben Kennung: nicht eindeutig
        ("g2", "GU 2.pdf", "Gemischt", "gruppenuebung", ["1"]), ("h2", "HU 2.pdf", "Gemischt", "hoersaaluebung", ["1"]),
        ("l2", "Lösung 2.pdf", "Gemischt", "loesung", ["1"]),
        # andere Ordner: die Kennung allein reicht nicht
        ("x5", "Blatt 5.pdf", "Aufgaben", "uebungsblatt", ["1"]), ("y5", "Lösung 5.pdf", "Lösungen", "loesung", ["1"]),
    ])
    with env.conn() as c:
        assert _solution(c, "u3") == "l3"
        assert _solution(c, "b10") == "l10"
        assert _solution(c, "b1") is None, "Blatt 1 nie mit der Loesung von Blatt 10 (Audit P49-06)"
        assert _solution(c, "g2") is None and _solution(c, "h2") is None
        assert _solution(c, "x5") is None


def test_solutions_in_their_own_folder_still_fit_by_name(env):  # noqa: F811
    _files(env, [
        ("b2", "Blatt 2.pdf", "Übungsblätter", "uebungsblatt", ["1"]), ("l2", "Lösung Blatt 2.pdf", "Lösungen", "loesung", ["1"]),
        ("b7", "Übungsblatt 7.pdf", "Übungsblätter", "uebungsblatt", ["1"]), ("l7", "Übungsblatt 7 Musterlösung.pdf", "Lösungen", "loesung", ["1"]),
    ])
    with env.conn() as c:
        assert _solution(c, "b2") == "l2" and _solution(c, "b7") == "l7"


def test_collective_solution_file_only_where_the_task_number_is_unique(env):  # noqa: F811
    one, many, split = "Alte Klausuren/SS 21", "Alte Klausuren/WS 20/21", "Alte Klausuren/SS 20"
    _files(env, [
        # eine Klausur und "Lösung.pdf": sauber
        ("k", "Klausur.pdf", one, "altklausur", ["1", "2"]), ("ks", "Lösung.pdf", one, "loesung", ["1", "2"]),
        # KK1 bis KK4, jede mit Aufgabe 1 und 2, und eine Sammeldatei: nicht zu trennen
        ("m1", "KK1.pdf", many, "altklausur", ["1", "2"]), ("m2", "KK2.pdf", many, "altklausur", ["1", "2"]),
        ("m3", "KK3.pdf", many, "altklausur", ["1", "2"]), ("m4", "KK4.pdf", many, "altklausur", ["1", "2", "3"]),
        ("ms", "Lösungen.pdf", many, "loesung", ["1", "2", "3"]),
        # durchgezaehlte Aufgaben: jede Nummer gehoert zu genau einer Klausur
        ("n1", "KK1.pdf", split, "altklausur", ["1", "2"]), ("n2", "KK2.pdf", split, "altklausur", ["3", "4"]),
        ("ns", "Lösungen.pdf", split, "loesung", ["1", "2", "3", "4"]),
        # ohne Ordner und fuer Uebungsblaetter gilt die Sammeldatei nicht
        ("r", "Probeklausur.pdf", "", "altklausur", ["1"]), ("rs", "Lösung.pdf", "", "loesung", ["1"]),
        ("u", "Blatt 4.pdf", "Übungen", "uebungsblatt", ["1"]), ("us", "Lösungen.pdf", "Übungen", "loesung", ["1"]),
    ])
    with env.conn() as c:
        assert _solution(c, "k") == "ks" and _solution(c, "k", "2") == "ks"
        for f in ("m1", "m2", "m3", "m4"):
            assert _solution(c, f, "1") is None and _solution(c, f, "2") is None, "Aufgabe 1 steht in vier Klausuren"
        assert _solution(c, "m4", "3") == "ms", "Aufgabe 3 gibt es nur in KK4"
        assert [_solution(c, "n1", "1"), _solution(c, "n1", "2"), _solution(c, "n2", "3"), _solution(c, "n2", "4")] == ["ns"] * 4
        assert _solution(c, "r") is None and _solution(c, "u") is None


def test_two_collective_files_in_one_folder_link_nothing(env):  # noqa: F811
    folder = "Alte Klausuren/SS 19"
    _files(env, [("k", "Klausur.pdf", folder, "altklausur", ["1"]), ("s1", "Lösung.pdf", folder, "loesung", ["1"]),
                 ("s2", "Musterlösung.pdf", folder, "loesung", ["1"])])
    with env.conn() as c:
        assert _solution(c, "k") is None


def test_index_module_classifies_and_links_real_files(env):  # noqa: F811
    """Ganzer Weg ueber index_module: Einordnung aus Name und Ordner, Aufgaben aus dem Text, dann die Loesung"""
    from app import weekly
    folder = "Alte Klausuren/WS 21/22"
    env.add_file("kx", "kk3a.pdf", folder, ["Aufgabe 1: Berechnen Sie den Grenzwert der Folge a_n mit genug Text.\n"
                                            "Aufgabe 2: Zeigen Sie die Konvergenz der Reihe mit genug Text."])
    env.add_file("sx", "sol3a.pdf", folder, ["Aufgabe 1: Der Grenzwert der Folge ist 2, Herleitung mit genug Text.\n"
                                             "Aufgabe 2: Die Reihe konvergiert nach dem Quotientenkriterium."])
    with env.conn() as c:
        weekly.index_module(c, MOD)
        rows = {(r[0], r[1]): (r[2], r[3], r[4]) for r in c.execute(
            "SELECT file_id, nr, source, solution_file_id, solution_text FROM task_index WHERE file_id IN ('kx', 'sx')")}
    assert rows[("sx", "1")][0] == "loesung", "sol3a.pdf ist eine Loesung, keine zweite Altklausur"
    assert rows[("kx", "1")][:2] == ("altklausur", "sx") and "Grenzwert der Folge ist 2" in rows[("kx", "1")][2]
    assert rows[("kx", "2")][1] == "sx" and "Quotientenkriterium" in rows[("kx", "2")][2]
