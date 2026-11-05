"""Studienverlauf fuer die Universitaet Hildesheim (docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md): Register aller
Studiengaenge (study-sources-hildesheim.json, tools/hildesheim-programs.py), Leser der beiden Formate
(app/catalog_formats/hildesheim.py) an ERFUNDENEN Seiten im Aufbau der Hildesheimer Vorlagen, Grundstock
(tools/build-hildesheim-seed.py) aus einem erfundenen Zwischenspeicher samt --check, die mitgelieferte Ressource,
gemischtes Register mit LSF-Bezeichnungen und der Abgleich am PC mit settings.university = hildesheim."""
from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
NOW = datetime(2026, 11, 5, 9, 0, tzinfo=timezone.utc)

from app import study_catalog as sc  # noqa: E402
from app.catalog_formats import FORMATS, get_parser  # noqa: E402
from app.catalog_formats import hildesheim as H  # noqa: E402


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


programs_tool = _load("hildesheim_programs", "hildesheim-programs.py")
seed_tool = _load("build_hildesheim_seed", "build-hildesheim-seed.py")
fixture_tool = _load("gen_study_catalog_fixture", "gen-study-catalog-fixture.py")

REGISTER = json.loads(sc.HILDESHEIM_REGISTRY_PATH.read_text(encoding="utf-8"))
FOOT = "Verkündungsblatt der Universität Hildesheim - Heft 999 - Nr. 01 / 2026 (01.01.2026) - Seite {} -"
META = {"university": "hildesheim", "program": "Erfunden", "degree": "B.A.", "po": "2026", "code": "erfunden|b.a.|2026",
        "catalog_term": "SS 2026", "regular_semesters": 6, "total_lp": 180, "source": {"url": "https://www.uni-hildesheim.de/x.pdf"}}


# ---------------------------------------------------------------------------------------------------------- Register

def test_register_shape_and_only_public_sources():
    progs = REGISTER["programs"]
    assert REGISTER["university"] == "hildesheim" and len(progs) >= 100
    keys = [e["key"] for e in progs]
    assert len(keys) == len(set(keys)), "Schluessel eindeutig"
    kinds = {e["kind"] for e in progs}
    assert kinds <= {"studiengang", "vertiefung", "fach"} and {"studiengang", "fach"} <= kinds
    urls = []
    for e in progs:
        assert e["key"].startswith("hildesheim|") and e["university"] == "hildesheim"
        assert e["program"] and e["degree"] and e["qis_labels"], e["key"]
        c = e["catalog"]
        assert c["format"] in set(FORMATS) | {"none"}, e["key"]
        if c["format"] != "none":
            assert c["url"] and sc.term_number(c["term"]) and c["modules_est"] >= 3, e["key"]
        urls += [d["url"] for d in e["po_documents"]] + [c.get("url")] + [m["url"] for m in e["more_catalogs"]]
        urls += [e.get("program_page"), e.get("ordnungen_page")]
    urls = [u for u in urls if u]
    assert all(u.startswith("https://www.uni-hildesheim.de/") for u in urls)
    assert not any(x in u for u in urls for x in ("lsf.", "/learnweb", "/sso", "login"))
    # Studiengaenge, Faecher im Zwei-Faecher-Bachelor und im Master Lehramt, Pruefungsordnungen, Modulbeschreibungen
    assert sum(1 for e in progs if e["kind"] == "studiengang") >= 50
    assert sum(1 for e in progs if e["kind"] == "fach" and e["degree"].startswith("B")) >= 20
    assert sum(1 for e in progs if e["kind"] == "fach" and e["degree"] == "M.Ed.") >= 20
    assert sum(1 for e in progs if e["po_documents"]) >= 100
    assert sum(1 for e in progs if e["catalog"]["format"] != "none") >= 80
    by = {(e["program"], e["degree"]): e for e in progs}
    ai = by[("Angewandte Informatik", "B.Sc.")]
    assert ai["catalog"]["format"] == "hildesheim-it-modulhandbuch" and ai["po"] == "2024"
    winf = by[("Wirtschaftsinformatik", "B.Sc.")]
    assert winf["catalog"]["usage_program"] == "BSc Wirtschaftsinformatik" and len(winf["more_catalogs"]) == 2
    bio = by[("Biologie im Polyvalenten Zwei-Fächer-Bachelor", "B.A./B.Sc.")]
    assert bio["parent_program"] == "Polyvalenter Zwei-Fächer-Bachelor-Studiengang"
    assert any(l.startswith("Abschluss: Bachelor Studiengang: B.A. Biologie") for l in bio["qis_labels"])


def test_fetcher_never_touches_login_systems_and_works_offline(tmp_path, monkeypatch):
    for url in ("https://lsf.uni-hildesheim.de/qisserver/rds", "https://www.uni-hildesheim.de/learnweb2026/",
                "https://www.uni-hildesheim.de/sso/login", "https://www.uni-hildesheim.de/qm/login.php?target=x",
                "http://www.uni-hildesheim.de/studium/", "https://www.uni-hannover.de/"):
        assert not programs_tool.allowed(programs_tool.norm_url(url)) or url.startswith("http://"), url
    assert not programs_tool.allowed("http://www.uni-hildesheim.de/studium/")
    assert programs_tool.allowed("https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=1")
    # ohne Netz: nichts geholt, Zaehler unveraendert
    monkeypatch.setattr(programs_tool, "CRAWL", tmp_path)
    monkeypatch.setattr(programs_tool, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(programs_tool, "INDEX", tmp_path / "index.json")
    monkeypatch.setattr(programs_tool, "_IDX", None)
    monkeypatch.setattr(programs_tool, "NETWORK", [False])

    def boom(*a, **k):
        raise AssertionError("keine Anfrage erlaubt")
    monkeypatch.setattr(programs_tool, "_raw_get", boom)
    assert programs_tool.fetch("https://www.uni-hildesheim.de/studium/studienangebot/") is None
    assert programs_tool.idx()["requests"] == 0


def test_register_helpers():
    assert programs_tool._split_title("Wirtschaftsinformatik (M.Sc.)") == ("Wirtschaftsinformatik", ["M.Sc."])
    assert programs_tool._split_title("Polyvalenter Zwei-Fächer-Bachelorstudiengang (B.A., B.Sc.)")[1] == ["B.A.", "B.Sc."]
    assert programs_tool._split_title("Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor, M.Ed.)") == \
        ("Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor)", ["M.Ed."])
    assert programs_tool._qm_label({"label": "Psychologie, B. Sc."}) == ("Psychologie", "B.Sc.")
    assert programs_tool._qm_label({"label": "Rechtspsychologie, M.Sc., M.Sc"}) == ("Rechtspsychologie", "M.Sc.")
    assert programs_tool._subject("Studienordnung für das Fach Biologie Polyvalente Zwei-Fächer-Bachelor-Studiengänge (B.A. / B.Sc.)") == "Biologie"
    assert programs_tool._subject("Neufassung der Studienordnung für das Fach Kunst Master-Studiengänge „Lehramt an Grundschulen“") == "Kunst"
    labels = programs_tool.qis_labels("Biologie", "B.A./B.Sc.", "2026")
    assert labels[0] == "Abschluss: Bachelor Studiengang: B.A. Biologie PO-Version: 2026" and "Biologie" in labels
    assert sc.parse_abschluss(labels[0]) == {"name": "Biologie", "po": "2026", "degree": "B"}


# ------------------------------------------------------------------------------------------- Leser (erfundene Seiten)

# erfundene Studienordnung im Aufbau der Hildesheimer Vorlage: Feldnamen umbrochen, Fusszeile des Verkuendungsblatts
# angeklebt, Bereichsueberschrift, Tabellenkopf auf der Folgeseite wiederholt
SO_PAGES = [
    "\n".join([
        "Studienordnung für das Fach Beispielkunde", "§ 1 Aufgaben", "Die Module stehen in Anlage 2.",
        "Anlage 2 – Modulhandbuch", "Module des Faches Beispielkunde",
        "Basismodul (BM) 1: Grundlagen der Beispielkunde",
        "Modulnummer: 2-Fach-Ba_Bsp01", "ModulleiterIn: N. N.",
        "Kompetenz- und Lernziele: Die Studierenden kennen erfundene Grundlagen.",
        "Verwendbarkeit des Moduls: 2-Fach-Ba Bsp-Us", "Pflicht- oder", "Wahlpflichtmodul:", "Pflicht",
        "Lehr- und Lernformen: TM 1 Vorlesung (3 LP)", "Lehrinhalte: Erfundene Inhalte.",
        "Zugangsvoraussetzungen: keine", "Anzahl der Leistungs-", "punkte*:", "6",
        "Workload getrennt nach", "Präsenzstudium und", "Selbststudium:", "Gesamt: 180 h",
        "Kontaktstunden: 60 h", "Dauer in Semestern: 1", "Häufigkeit des Angebots: jedes Wintersemester",
        "Empfohlenes Studiensemes-", "ter:", "1. Semester",
        "Prüfungsleistungen (Art,", "Umfang):", "Klausur im Umfang von 60 Minuten",
        "Studienleistungen (Art", "und Umfang):", "Regelmäßige Teilnahme",
        "Zuständige Ständige", "Prüfungskommission:", "Ständige Prüfungskommission Beispiel " + FOOT.format(10),
    ]),
    "\n".join([
        "Aufbaumodul (AM) 2: Vertiefte Beispielkunde",
        "Modulnummer: 2-Fach-Ba_Bsp02", "Modulleitung: N. N.",
        "Pflicht- oder Wahlpflichtmodul: Wahlpflicht",
        "Zugangsvoraussetzungen: Basismodul (BM) 1: Grundlagen der Beispielkunde",
        "Anzahl der Leistungspunkte: 9", "Workload: 270 h",
        "Häufigkeit des Angebots: jedes Sommersemester", "Empfohlenes Studiensemester: 3. oder 4. Semester " + FOOT.format(11),
    ]),
    "\n".join([
        "Aufbaumodul (AM) 2: Vertiefte Beispielkunde",
        "Modulnummer: 2-Fach-Ba_Bsp02",
        "Prüfungsleistungen (Art, Umfang): Hausarbeit (15 Seiten)",
        "Unterrichts- und Prüfungssprache: Deutsch",
        "Bezeichnung Modul 3: Bachelorarbeit im Fach Beispielkunde",
        "Leistungspunkte 9", "Arbeitsaufwand (Workload) 270 Stunden", "Prüfungsleistung Bachelorarbeit",
        "Zuständige Ständige Prüfungskommission Beispiel",
        "Modulverantwortliche Siehe Webseite " + FOOT.format(12),
    ]),
]


def test_modulbeschreibung_reader_on_constructed_pages():
    cat, texts = get_parser("hildesheim-modulbeschreibung")(SO_PAGES, META)
    assert sc.validate(cat) == []
    mods = {m["title"]: m for m in cat["modules"]}
    assert list(mods) == ["Basismodul (BM) 1: Grundlagen der Beispielkunde", "Aufbaumodul (AM) 2: Vertiefte Beispielkunde",
                          "Modul 3: Bachelorarbeit im Fach Beispielkunde"], "Folgeseite mit gleichem Titel: ein Modul"
    bm, am, ba = mods.values()
    assert (bm["code"], bm["lp"], bm["workload_h"], bm["turnus"], bm["semester"], bm["kind"]) == \
        ("2-Fach-Ba_Bsp01", 6, 180, "WS", 1, "pflicht")
    assert bm["exam"] == "Klausur im Umfang von 60 Minuten" and bm["coursework"] == "Regelmäßige Teilnahme"
    assert (am["lp"], am["turnus"], am["semester"], am["kind"], am["language"]) == (9, "SS", 3, "wahlpflicht", "deutsch")
    assert am["exam"] == "Hausarbeit (15 Seiten)", "Fakten der Folgeseite ergaenzt"
    assert am["prerequisites"] == [bm["id"]]
    assert (ba["kind"], ba["lp"], ba["workload_h"]) == ("abschluss", 9, 270)
    areas = {a["id"]: a for a in cat["areas"]}
    assert areas[bm["area"]]["name"] == "Basismodule" and areas[am["area"]]["name"] == "Aufbaumodule"
    assert not any("Verkündungsblatt" in str(v) for m in cat["modules"] for v in m.values())
    assert texts[bm["id"]]["goals"].startswith("Die Studierenden kennen erfundene")
    assert not any(k in m for m in cat["modules"] for k in ("content", "goals", "literature"))


def _it_pages(english: bool = False) -> list[str]:
    """Erfundenes FB-4-Handbuch: Titelseite, Verzeichnis (Seitenzahlen im Handbuch), drei Module, Kolumnentitel"""
    if english:
        toc = ["Compulsory Modules", "Module Type/HPW CPs P .", "Example Learning 2 HPW lecture, 2 HPW tutorial 6 3",
               "Elective Modules", "Methods", "Module Type/HPW CPs P .", "Example Vision 2 HPW lecture 4 4",
               "Master Thesis", "Module Type/HPW CPs P .", "Master Thesis Master Thesis 30 5"]
        mods = [("Module: Example Learning", ["Responsible N. N.", "Credit Points 6 CPs", "Workload presence: 42 hours; self-study: 108 hours",
                                              "Exam written exam (90 min)", "Recommended Term MSc 1", "Turn every winter term",
                                              "Use", "• MSc Example – Compulsory Modules", "Language English"]),
                ("Module: Example Vision", ["Responsible N. N.", "Credit Points 4 CPs", "Requirements Example Learning",
                                            "Exam oral exam (30 min)", "Recommended Term MSc 2", "Turn every summer term",
                                            "Language English"]),
                ("Module: Master Thesis", ["Credit Points 30 CPs", "Exam Master Thesis", "Recommended Term MSc 4",
                                           "Turn every semester"])]
    else:
        toc = ["Pﬂichtmodule im Bachelor", "Informatik", "Modul Lehrform/SWS LP S.",
               "Beispielprogrammierung 2 SWS Vorlesung, 2 SWS Übung 6 3",
               "Wahlbereich Bachelor", "Informatik", "Gebiet Beispielsysteme", "Modul Lehrform/SWS LP S.",
               "Beispielsysteme 2 SWS Vorlesung 4 4",
               "Wahlmodule im Master", "Informatik", "Gebiet Beispielsysteme", "Modul Lehrform/SWS LP S.",
               "Beispielsysteme 2 SWS Vorlesung 4 4", "Seminar Beispiel (Master) 2 SWS Seminar 4 5"]
        mods = [("Modul: Beispielprogrammierung", ["Modulverantwortlicher N. N.", "Lehrform/SWS 2 SWS Vorlesung, 2 SWS Übung",
                                                   "Leistungspunkte 6 LP", "Arbeitsaufwand Präsenzzeit: 60 Stunden; Selbststudium: 90 Stunden",
                                                   "Lernziele/Kompetenzen Erfundene Ziele.", "Prüfungsleistung Klausur (90 Minuten)",
                                                   "empfohlenes Semester BSc 1", "Turnus jedes Wintersemester", "Dauer des Moduls 1 Semester",
                                                   "Verwendung", "• BSc Beispielinformatik – Pﬂichtmodule – Informatik"]),
                ("Modul: Beispielsysteme", ["Modulverantwortlicher N. N.", "Leistungspunkte 4 LP",
                                            "Voraussetzungen für die", "Teilnahme Beispielprogrammierung",
                                            "Prüfungsleistung mündliche Prüfung", "empfohlenes Semester BSc 4, MSc 1",
                                            "Turnus jedes Sommersemester", "Verwendung",
                                            "• BSc Beispielinformatik – Wahlbereich – Informa-", "tik"]),
                ("Modul: Seminar Beispiel (Master)", ["Leistungspunkte 4 LP", "Prüfungsleistung Vortrag und Ausarbeitung",
                                                      "empfohlenes Semester MSc 1-3", "Turnus jedes Semester"])]
    pages = ["Universität Hildesheim\nModulhandbuch\n" + FOOT.format(1), "\n".join(toc) + "\n2\n" + FOOT.format(2)]
    for n, (head, body) in enumerate(mods):
        pages.append("\n".join(["Bereich – " + head.split(": ", 1)[1], head] + body + [str(n + 3), FOOT.format(n + 3)]))
    return pages


def test_it_reader_bachelor_master_toc_and_usage():
    parse = get_parser("hildesheim-it-modulhandbuch")
    b, texts = parse(_it_pages(), dict(META, degree="B.Sc."))
    m, _ = parse(_it_pages(), dict(META, degree="M.Sc."))
    assert sc.validate(b) == [] and sc.validate(m) == []
    assert [x["title"] for x in b["modules"]] == ["Beispielprogrammierung", "Beispielsysteme"]
    assert [x["title"] for x in m["modules"]] == ["Beispielsysteme", "Seminar Beispiel (Master)"]
    bp = b["modules"][0]
    assert (bp["lp"], bp["workload_h"], bp["semester"], bp["turnus"], bp["kind"]) == (6, 150, 1, "WS", "pflicht")
    assert bp["exam"] == "Klausur (90 Minuten)"
    bs = b["modules"][1]
    assert bs["kind"] == "wahlpflicht" and bs["prerequisites"] == [bp["id"]]
    assert {a["name"] for a in b["areas"]} == {"Pflichtmodule im Bachelor – Informatik",   # Ligatur aufgeloest (NFKC)
                                                "Wahlbereich Bachelor – Informatik – Gebiet Beispielsysteme"}
    assert texts[bp["id"]]["goals"] == "Erfundene Ziele."
    # Studiengang ohne eigenes Handbuch: Module aus der "Verwendung"
    u, _ = parse(_it_pages(), dict(META, degree="B.Sc.", usage_program="BSc Beispielinformatik"))
    assert {x["title"]: next(a["name"] for a in u["areas"] if a["id"] == x["area"]) for x in u["modules"]} == \
        {"Beispielprogrammierung": "Pflichtmodule – Informatik", "Beispielsysteme": "Wahlbereich – Informatik"}
    # englische Fassung (Data Analytics, Software Engineering): ohne gedruckte Seitenzahlen
    pages = [p.replace("\n3\n", "\n").replace("\n4\n", "\n").replace("\n5\n", "\n") for p in _it_pages(english=True)]
    e, _ = parse(pages, dict(META, degree="M.Sc."))
    assert [(x["title"], x["kind"], x["lp"], x["language"]) for x in e["modules"]] == [
        ("Example Learning", "pflicht", 6, "englisch"), ("Example Vision", "wahlpflicht", 4, "englisch"),
        ("Master Thesis", "abschluss", 30, None)]


def test_lsf_label_and_matching_in_full_registry():
    reg = sc.load_registry()
    assert [u["id"] for u in reg["universities"]][:2] == ["luh", "hildesheim"]
    assert sc.parse_abschluss("Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022") == \
        {"name": "Erziehungswissenschaft", "po": "2022", "degree": "B"}
    assert sc.parse_abschluss("Technische Informatik (PO-Version 2017)") == {"name": "Technische Informatik", "po": "2017", "degree": None}
    m = sc.match_program("Abschluss: [82] Bachelor Studiengang: [079] B.Sc. Angewandte Informatik PO-Version: 2024", "hildesheim", reg)
    assert m["code"] == "angewandte-informatik|b.sc.|2024" and m["needs_confirmation"] is False
    assert sc.source_urls(reg, "hildesheim", m["code"], "WS 2026/27") == [], "nur aus dem Grundstock"
    assert sc.match_program("Abschluss: [82] Bachelor Studiengang: [079] B.Sc. Angewandte Informatik PO-Version: 2024", "luh", reg) is None
    uni = next(u for u in reg["universities"] if u["id"] == "hildesheim")
    assert uni["name"] == "Universität Hildesheim"
    assert {s["id"] for s in uni["sources"]} == {"hildesheim-grundstock"}
    # LUH unveraendert
    assert sc.match_program("Technische Informatik (PO-Version 2017)")["code"] == "TIBSc25"


# --------------------------------------------------------------------------------------------- Grundstock (Bauen)

def _tiny(tmp: Path) -> dict:
    """Erfundener Zwischenspeicher mit einer Studienordnung (SO_PAGES als PDF) und Register mit zwei Eintraegen"""
    crawl = tmp / "crawl"
    (crawl / "cache").mkdir(parents=True)
    pdf = fixture_tool.make_pdf([p.split("\n") for p in SO_PAGES])
    url = "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=999999"
    (crawl / "cache" / "x.pdf").write_bytes(pdf)
    (crawl / "index.json").write_text(json.dumps({"requests": 1, "urls": {url: {"status": 200, "path": "cache/x.pdf"}},
                                                   "log": [{"t": 1793869200, "url": url, "status": 200}]}))
    entry = {"key": "hildesheim|beispielkunde-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026", "university": "hildesheim",
             "program": "Beispielkunde im Polyvalenten Zwei-Fächer-Bachelor", "degree": "B.A./B.Sc.", "kind": "fach",
             "faculty": "Fachbereich 9", "po": "2026", "po_documents": [],
             "catalog": {"url": url, "term": "SS 2026", "format": "hildesheim-modulbeschreibung"}, "more_catalogs": [],
             "qis_labels": ["Beispielkunde"], "regular_semesters": None, "total_lp": None}
    missing = dict(entry, key="hildesheim|fehlt|b.a.|2026", program="Fehlt",
                   catalog={"url": url.replace("999999", "1"), "term": "SS 2026", "format": "hildesheim-modulbeschreibung"})
    register = {"v": 1, "university": "hildesheim", "programs": [entry, missing]}
    reg_path = tmp / "register.json"
    reg_path.write_text(json.dumps(register, ensure_ascii=False))
    doc = tmp / "doc.md"
    doc.write_text("# Bericht\n", encoding="utf-8")
    return {"crawl": crawl, "register": reg_path, "out": tmp / "out", "doc": doc, "pdf": pdf, "url": url}


def _args(t: dict, *extra: str) -> list[str]:
    return ["--crawl-dir", str(t["crawl"]), "--register", str(t["register"]), "--out-dir", str(t["out"]), "--doc", str(t["doc"]), *extra]


def test_build_tiny_seed_index_report_and_check(tmp_path, capsys):
    t = _tiny(tmp_path)
    assert seed_tool.main(_args(t)) == 0
    assert sorted(p.name for p in t["out"].iterdir()) == ["hildesheim-index.json", "hildesheim.json.gz"]
    data = json.loads(gzip.decompress((t["out"] / "hildesheim.json.gz").read_bytes()))
    assert data["university"] == "hildesheim" and len(data["catalogs"]) == 1
    c = data["catalogs"][0]
    assert sc.validate(c) == [] and c["code"] == "beispielkunde-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026"
    assert c["university"] == "hildesheim" and c["catalog_term"] == "SS 2026" and len(c["modules"]) == 3
    assert c["source"]["sha256"] == hashlib.sha256(t["pdf"]).hexdigest() and c["source"]["fetched_at"]
    assert not any(k in m for m in c["modules"] for k in ("content", "goals", "literature"))
    index = json.loads((t["out"] / "hildesheim-index.json").read_text())
    assert index["university"] == "hildesheim" and index["catalogs"] == 1 and index["modules"] == 3
    e = index["entries"][0]
    assert e["library_key"] == sc.library_key("hildesheim", c["code"], "SS 2026") and e["file"] == "hildesheim.json.gz"
    doc = t["doc"].read_text()
    assert seed_tool.DOC_START in doc and "PDF fehlt im Zwischenspeicher" in doc
    # --check: aktuell -> 0; Ressource veraendert -> 1
    assert seed_tool.main(_args(t, "--check")) == 0
    (t["out"] / "hildesheim-index.json").write_text("{}")
    assert seed_tool.main(_args(t, "--check")) == 1
    assert "Grundstock veraltet" in capsys.readouterr().out


# ---------------------------------------------------------------------------------- mitgelieferte Ressource, Ablauf

def test_bundled_hildesheim_resource_valid_and_matches_registry():
    index = json.loads((seed_tool.OUT_DIR / "hildesheim-index.json").read_text())
    cats = {k: c for k, c in sc.load_seed().items() if c["university"] == "hildesheim"}
    assert len(cats) == index["catalogs"] >= 80 and sum(len(c["modules"]) for c in cats.values()) == index["modules"] >= 1500
    assert {e["library_key"] for e in index["entries"]} == set(cats)
    reg = sc.load_registry()
    for c in cats.values():
        assert sc.validate(c) == [], c["code"]
        assert sc.program_entry(reg, "hildesheim", c["code"]) is not None, c["code"]
        for m in c["modules"]:
            assert not any(k in m for k in ("content", "goals", "literature"))
            assert len(m.get("exam") or "") <= 200 and len(m.get("coursework") or "") <= 200
            assert "Verkündungsblatt" not in m["title"]
    by_code = {c["code"]: c for c in cats.values()}
    ai = by_code["angewandte-informatik|b.sc.|2024"]
    assert len(ai["modules"]) >= 60 and any(a["kind"] == "wahlpflicht" for a in ai["areas"])
    # beide Hochschulen im Grundstock, Semester je Hochschule getrennt
    unis = {c["university"] for c in sc.load_seed().values()}
    assert {"luh", "hildesheim"} <= unis
    assert sc.seed_terms(sc.load_seed(), "luh", "angewandte-informatik|b.sc.|2024") == []


def _conn(label: str, university: str):
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("CREATE TABLE grades (id INTEGER PRIMARY KEY, text TEXT, abschluss TEXT);"
                       "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);")
    conn.execute("INSERT INTO settings VALUES ('university', ?)", (university,))
    conn.execute("INSERT INTO grades(text, abschluss) VALUES ('X', ?)", (label,))
    return conn


def test_sync_with_hildesheim_takes_seed_without_download():
    calls = []

    def fetch(url, etag=None, last_modified=None):
        calls.append(url)
        return sc.FetchResult(404, error="HTTP 404")
    label = "Abschluss: [82] Bachelor Studiengang: [079] B.Sc. Angewandte Informatik PO-Version: 2024"
    conn = _conn(label, "hildesheim")
    s = sc.run_sync(conn, fetch, NOW, seed=sc.load_seed())
    assert s["state"] == "seed" and s["code"] == "angewandte-informatik|b.sc.|2024", s
    assert calls == [], "nur aus dem Grundstock"
    assert sc.get_catalog(conn, s["key"])["university"] == "hildesheim"
    # gleiche Zeile bei einer LUH-Instanz: kein Treffer
    assert sc.run_sync(_conn(label, "luh"), fetch, NOW, seed=sc.load_seed())["state"] == "not_found"
    # Auswahl im Web: Studiengaenge der eigenen Hochschule
    progs = sc.programs(university="hildesheim", seed=sc.load_seed())
    ai = next(p for p in progs if p["program"] == "Angewandte Informatik" and p["degree"] == "B.Sc.")
    assert ai["pos"] and ai["pos"][0]["loadable"] is True


@pytest.mark.parametrize("name", ["hildesheim-modulbeschreibung", "hildesheim-it-modulhandbuch"])
def test_formats_registered(name):
    assert get_parser(name) is not None and name in REGISTER["formats"]


def test_text_helpers():
    assert H._fold("Prüfungs-\nleistungen (Art,") == "pruefungsleistungenart"
    assert H._workload("Gesamt: 180 h\nKontaktstunden: 60 h", 6) == 180
    assert H._workload("Präsenzzeit: 60 Stunden; Selbststudium: 90 Stunden", 6) == 150
    assert H._kind("Pflichtmodul") == "pflicht" and H._kind("Wahlpflicht") == "wahlpflicht" and H._kind("PFM") is None
    assert H._first_int("2. Semester oder 4. Semester") == 2 and H._first_int("1-2 BA") == 1
    assert H._clean_title("Modul „Theoretische Philosophie“") == "Theoretische Philosophie"
    assert H._clean_title("Modultitel*: Basismodul I (BM 1): „Theologie – Reflexion“") == "Basismodul I (BM 1): Theologie – Reflexion"
    assert H._usage_items("• BSc Wirtschaftsin-\nformatik – Wahlbereich\n• MSc X") == ["BSc Wirtschaftsinformatik – Wahlbereich", "MSc X"]


# erfundene Modultabellen im Layout-Modus: FB 2 (Feldname links, Wert rechts, umbrochene Feldnamen) und FB 3 (Kopfzeile
# Studiensemester | Dauer | Haeufigkeit | Status, Zeile "Modul Gesamt" mit Kontaktzeit, Selbststudium, SWS, LP)
TABLE_FB2 = "\n".join([
    "Modulübersicht",
    "Modul 1.1: Einführung in die Beispielkunst      2 SWS/ 6 LP",
    "2. Modulhandbuch",
    "",
    "        Studienbereich 1: Beispielkunst",
    "        Modul 1.1",
    "        Einführung in die Beispielkunst",
    "",
    "        Inhaltliche                 Erfundene Inhalte der",
    "        Beschreibung                Beispielkunst",
    "        Qualifikations- und         Die Studierenden kennen",
    "        Kompetenzziele              erfundene Grundlagen.",
    "        empfohlenes Semester        1.-2. Semester",
    "        Kennzeichnung               Pflichtmodul",
    "        Workload                    4 SWS / 6 LP",
    "        Studienleistun-             aktive Teilnahme",
    "        gen",
    "        Modulprüfungs-              Hausarbeit (ca. 3000 Wörter)",
    "        leistung",
    "        Präsenz des Mo-             Jedes Semester",
    "        duls im Studien-",
    "        angebot",
    "",
    "        Modul 1.2",
    "        Beispielprojekt",
    "        Kennzeichnung               Wahlpflichtmodul",
    "        Workload                    2 SWS / 3 LP",
    "        Modulprüfungs-              Präsentation",
    "        leistung",
    "        Präsenz des Mo-             Jährlich im Wintersemester",
    "        duls im Studien-",
    "        angebot",
    FOOT.format(30),
])
TABLE_FB3 = "\n".join([
    "                                         Anlage 4: Modulbeschreibung",
    "Modul 1: Grundlagen der Beispielsprache",
    "Studiensemester           Dauer des              Häufigkeit des               Status Modul",
    "                          Moduls                 Angebots",
    "1.-2. Semester            2 Semester             TM 1 jedes WiSe,             Pflicht",
    "                                                 TM 2 jedes SoSe              Status Teilmodule",
    "                                                                              Pflicht",
    "",
    "Lehr-/                    Nr.      Lehr-     Titel                     Kontakt-     Selbst-      SWS               LP",
    "Lernformen;               B        form                                zeit         studium",
    "Arbeitsaufwand            1",
    "                          Modul                                        150h         360h         10                17",
    "                          Gesamt",
    "Studienleistungen         regelmäßige aktive Teilnahme",
    "Voraussetzung für         keine",
    "die Teilnahme",
    FOOT.format(41),
])


def test_modultabelle_reader_on_constructed_layout_pages():
    parse = get_parser("hildesheim-modultabelle")
    cat, _ = parse([TABLE_FB2], META)
    assert sc.validate(cat) == []
    assert [m["title"] for m in cat["modules"]] == ["Modul 1.1 Einführung in die Beispielkunst", "Modul 1.2 Beispielprojekt"], \
        "Zeile der Moduluebersicht vor dem Modulhandbuch zaehlt nicht"
    a, b = cat["modules"]
    assert (a["lp"], a["semester"], a["turnus"], a["kind"], a["coursework"], a["exam"]) == \
        (6, 1, "WS+SS", "pflicht", "aktive Teilnahme", "Hausarbeit (ca. 3000 Wörter)")
    assert (b["lp"], b["turnus"], b["kind"], b["exam"]) == (3, "WS", "wahlpflicht", "Präsentation")
    assert next(x for x in cat["areas"] if x["id"] == a["area"])["name"] == "Studienbereich 1: Beispielkunst"
    cat3, _ = parse([TABLE_FB3], META)
    (m,) = cat3["modules"]
    assert (m["title"], m["lp"], m["workload_h"], m["semester"], m["turnus"], m["kind"], m["coursework"]) == \
        ("Modul 1: Grundlagen der Beispielsprache", 17, 510, 1, "WS+SS", "pflicht", "regelmäßige aktive Teilnahme")
    assert H._unbold("MMMMoooodddduuuullll 8888::::") == "Modul 8:"


def test_area_patterns_and_quality_report():
    rules = {"x|b.sc.|2024": {"area_patterns": [{"match": "^Wahlbereich", "set": {"kind": "wahl", "lp_max": 12, "rule": "höchstens 12 LP"}}],
                              "add_areas": [{"id": "nebenfach", "name": "Nebenfach", "kind": "wahl", "lp_required": 30}]}}
    cat = {"v": 1, "university": "hildesheim", "program": "X", "degree": "B.Sc.", "po": "2024", "catalog_term": "SS 2024",
           "code": "x|b.sc.|2024", "regular_semesters": 6, "total_lp": 180, "source": {"url": "https://www.uni-hildesheim.de/x"},
           "areas": [{"id": "wb-a", "name": "Wahlbereich – Gebiet A", "kind": "wahlpflicht", "lp_required": None, "lp_max": None},
                     {"id": "p", "name": "Pflichtmodule", "kind": "pflicht", "lp_required": None, "lp_max": None}],
           "modules": [{"id": "m", "title": "M", "code": None, "area": "wb-a", "kind": "wahlpflicht", "lp": 6, "semester": 2,
                        "turnus": "WS", "exam": "Klausur", "coursework": None, "prerequisites": [], "language": None,
                        "workload_h": 180, "source_page": 1}]}
    stats = {"kinds_fixed": 0, "dropped_modules": 0, "area_rules": 0}
    out, errors = seed_tool.postprocess(cat, rules, stats)
    assert errors == [] and stats["area_rules"] == 1
    areas = {a["id"]: a for a in out["areas"]}
    assert areas["wb-a"]["kind"] == "wahl" and areas["wb-a"]["lp_max"] == 12 and areas["wb-a"]["rule"] == "höchstens 12 LP"
    assert areas["nebenfach"]["lp_required"] == 30 and areas["p"]["kind"] == "pflicht"
    assert seed_tool.completeness(out["modules"]) == ["100 %", "100 %", "100 %", "100 %", "0 %", "0 %", "0 %", "100 %"]
    item = {"catalog": out, "registry_keys": ["hildesheim|x|b.sc.|2024"], "format": "hildesheim-modultabelle", "faculty": "FB 9",
            "library_key": sc.catalog_key(out)}
    _, index = seed_tool.bundle([item], {"programs": []})
    reg = {"programs": [{"key": "hildesheim|y|b.a.|2024", "program": "Y", "degree": "B.A.",
                         "catalog": {"format": "none", "reason": "Studienordnung ohne lesbare Modulbeschreibungen"}}]}
    text = seed_tool.report([item], index, [], dict(stats, dropped_invalid=0, missing=0), reg)
    assert "| `hildesheim-modultabelle` | 1 | 1 | 100 % | 100 % | 100 % | 100 % | 0 % | 0 % | 0 % | 100 % |" in text
    assert "- Y (B.A.): Studienordnung ohne lesbare Modulbeschreibungen" in text


def test_committed_rules_reference_existing_catalogs():
    rules = json.loads(seed_tool.AREA_RULES.read_text(encoding="utf-8"))["catalogs"]
    codes = {c["code"] for c in sc.load_seed().values() if c["university"] == "hildesheim"}
    assert len(rules) >= 15 and set(rules) <= codes, set(rules) - codes
    winf = next(c for c in sc.load_seed().values() if c["code"] == "wirtschaftsinformatik|m.sc.|2024")
    assert any(a["id"] == "forschungsmethodik" and a["lp_required"] == 21 for a in winf["areas"])
    assert any(a.get("rule", "").startswith("Spezialisierungs- und Vertiefungsbereich") for a in winf["areas"])
