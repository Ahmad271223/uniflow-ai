"""HsH-Bibliothek (docs/STUDIENGAENGE-HSH-2026-11-05.md): Leser der vier Handbuch-Bauarten (app/catalog_formats/hsh.py)
mit erfundenen Seitentexten, Auswahl der Seiten und PDFs (tools/hsh-catalogs.py), PO-Version, Vertiefung und Gruppen
je PO (tools/hsh-programs.py), Grundstock (tools/build-hsh-seed.py --check) und der Weg lokal -> Grundstock fuer eine
HsH-Person (app/study_catalog.py)."""
from __future__ import annotations

import gzip
import importlib.util
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FX = ROOT / "packages/shared-contracts/fixtures/hsh-catalog"
SEED_DIR = ROOT / "apps/apple/UniFlow/Resources/StudyCatalogSeed"

from app import study_catalog as sc  # noqa: E402
from app.catalog_formats import hsh  # noqa: E402


def _tool(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


META = {"university": "hsh", "program": "Beispiel", "degree": "B.Sc.", "po": "2022", "code": "beispiel|b.sc.|xyz|2022",
        "catalog_term": "WS 2025/26", "regular_semesters": 6, "total_lp": 180,
        "source": {"url": "https://f4.hs-hannover.de/x.pdf", "fetched_at": "2026-11-05T12:00:00Z", "sha256": "0" * 64}}


def _pages(name: str) -> list[str]:
    return json.loads((FX / f"{name}.json").read_text(encoding="utf-8"))["pages"]


def _mods(cat: dict) -> dict:
    return {m["code"]: m for m in cat["modules"]}


# ---------------------------------------------------------------- Leser

@pytest.mark.parametrize("name,fmt", [("modul-code", "hsh-modul-code"), ("modul-nummer", "hsh-modul-nummer"),
                                      ("modultitel", "hsh-modultitel"), ("wpf-tabelle", "hsh-wpf-tabelle")])
def test_detect_each_layout(name, fmt):
    assert hsh.detect(_pages(name)) == fmt


def test_modul_code_fields_toc_areas_and_texts():
    cat, texts = hsh.parse(_pages("modul-code"), META)
    assert not sc.validate(cat)
    m = _mods(cat)
    assert list(m) == ["XYZ-100", "XYZ-101", "XYZ-210", "XYZ-211"]
    ma = m["XYZ-100"]
    assert (ma["title"], ma["lp"], ma["semester"], ma["workload_h"], ma["kind"]) == ("Mathematik A", 6, 1, 180, "pflicht")
    assert ma["exam"] == "Klausur 90 Minuten" and ma["language"] == "deutsch"
    # Kerning-Luecke "T eilmodul" und Ligatur "Pﬂicht" stoeren nicht, Teilmodul liefert die Sprache
    assert m["XYZ-101"]["language"] == "englisch" and m["XYZ-101"]["prerequisites"] == ["mathematik-a"]
    assert (m["XYZ-210"]["kind"], m["XYZ-210"]["semester"]) == ("wahlpflicht", 5)
    assert m["XYZ-211"]["kind"] == "abschluss"
    areas = {a["id"]: a for a in cat["areas"]}
    assert ma["area"] == "1-studienabschnitt" and areas["wahlpflichtmodule-2-studienabschnitt"]["kind"] == "wahlpflicht"
    # Texte nur lokal
    assert "Mengen" in texts["mathematik-a"]["content"] and "content" not in ma


def test_modul_nummer_table_rows_give_code_lp_and_workload():
    cat, _ = hsh.parse(_pages("modul-nummer"), META)
    m = _mods(cat)
    assert list(m) == ["BBP-101", "BBP-102", "BBP-203"]
    assert (m["BBP-101"]["lp"], m["BBP-101"]["workload_h"], m["BBP-101"]["exam"]) == (10, 300, "Präsentation (unbenotet)")
    # zweizeiliger Titel in der Modultabelle, Studienleistung, Voraussetzung als Modul-id
    assert (m["BBP-102"]["lp"], m["BBP-102"]["coursework"]) == (15, "Referat")
    assert m["BBP-102"]["prerequisites"] == ["einfuehrung-ins-studium"]
    assert (m["BBP-203"]["kind"], m["BBP-203"]["area"]) == ("wahlpflicht", "wahlpflichtmodule")


def test_modultitel_credits_workload_turnus_and_kind_from_course():
    cat, _ = hsh.parse(_pages("modultitel"), META)
    m = _mods(cat)
    a, b = m["MBF-301"], m["MBF-302"]
    assert (a["title"], a["lp"], a["workload_h"], a["semester"], a["turnus"]) == ("Kamera: Technik und Gestaltung", 9, 270, 1, "WS")
    assert (b["lp"], b["turnus"], b["exam"], b["kind"]) == (6, "SS", "Hausarbeit", "wahlpflicht")


def test_wpf_tabelle_values_before_labels():
    cat, texts = hsh.parse(_pages("wpf-tabelle"), META)
    m = _mods(cat)
    a, b = m["Mod. 901"], m["Mod. 902"]
    assert (a["title"], a["lp"], a["workload_h"], a["turnus"], a["kind"]) == ("Beispieltechnologie flüssiger Stoffe", 6, 180, "WS", "wahlpflicht")
    assert a["exam"] == "Modulprüfung mit Labor (üblich: K90, EA)"
    assert (b["lp"], b["turnus"], b["exam"]) == (5, "SS", "Modulprüfung (üblich: K60)")
    assert "Grundoperationen" in texts[a["id"]]["content"]


def test_repeated_header_and_page_numbers_drop_but_module_heads_stay():
    pages = [f"Kopfzeile Fakultät\nModul AB-10{i} Titel {i}\nCredits 5\nSeite {i} von 6" for i in range(1, 7)]
    lines = hsh.clean_pages(pages)
    assert all("Kopfzeile Fakultät" not in ln for p in lines for ln in p)
    assert [p[0] for p in lines][:2] == ["Modul AB-101 Titel 1", "Modul AB-102 Titel 2"]
    assert hsh.dehyphen("Prüfungsord-\nnung IT-\nSicherheit") == "Prüfungsordnung IT-Sicherheit"


def test_unknown_layout_raises():
    with pytest.raises(ValueError):
        hsh.parse(["nur Fließtext ohne Module"], META)


# ---------------------------------------------------------------- Seiten und PDFs (Crawler, ohne Netz)

def test_pages_and_pdf_links_from_program_page():
    cat = _tool("hsh_catalogs_t", "hsh-catalogs.py")
    hp = cat.HP
    assert cat.page_wanted("/studium/bachelor-studiengaenge/angewandte-informatik-bin")
    assert cat.page_wanted("/studium/studiengaenge-und-programme/master-studiengaenge/sensor-und-automatisierungstechnik-esa")
    assert cat.page_wanted("/studium/studieninformationen/ordnungen/abteilung-informatik")
    assert not cat.page_wanted("/studium/bachelor-studiengaenge/angewandte-informatik-bin/lehrende")
    assert not cat.page_wanted("/aktuelles/news/ordnungen-neu")
    html = (FX / "program-page.html").read_text(encoding="utf-8")
    docs = cat.pdf_links(hp.page_links(html, "https://f4.hs-hannover.de/studium/bachelor-studiengaenge/x"))
    kinds = {d["url"].rsplit("/", 1)[-1]: d["kind"] for d in docs}
    assert kinds == {"2026-03-01-modules-XYZ-22WS-DE.pdf": "handbook", "2026-03-01-modules-XYZ-22WS-EN.pdf": "handbook",
                     "PO_XYZ_2022.pdf": "po", "Studienverlaufsplan_XYZ_2022.pdf": "plan"}
    # Campusmanagement (HISinOne) nie: robots.txt sperrt es, und es ist kein erlaubter Rechner
    assert not cat.allowed("https://campusmanagement.hs-hannover.de/qisserver/pages/x.pdf")


def test_robots_rules_of_the_hsh_sites():
    hp = _tool("hsh_programs_r", "hsh-programs.py")
    text = ("User-agent: *\nDisallow: /fileadmin/\nAllow: /fileadmin/*.pdf$\nDisallow: /fileadmin/*/Archiv/\n"
            "Disallow: /*cHash\nAllow: /*sitemap=\nUser-agent: ClaudeBot\nDisallow: /\n")
    r = hp.Robots(text, "StudiNow-Katalogpruefung/1.0 (support@studinow.app)")
    assert r.allowed("https://f4.hs-hannover.de/fileadmin/HsH/x/Modulhandbuch.pdf")
    assert not r.allowed("https://f4.hs-hannover.de/fileadmin/HsH/x/Bild.png")
    assert not r.allowed("https://f4.hs-hannover.de/fileadmin/HsH/x/Archiv/alt.pdf")
    assert r.allowed("https://f1.hs-hannover.de/sitemap.xml?sitemap=pages&cHash=abc")
    assert not r.allowed("https://www.hs-hannover.de/a?x=1&cHash=abc")
    # Campusmanagement: "User-agent: * / Disallow: /"
    assert not hp.Robots("User-agent: *\nDisallow: /\n").allowed("https://campusmanagement.hs-hannover.de/qisserver/pages/x")


# ---------------------------------------------------------------- Register: PO, Vertiefung, Gruppen

def test_po_version_variant_and_language():
    hp = _tool("hsh_programs_p", "hsh-programs.py")
    assert hp.po_of("2024-04-29-modules-BIN-19WS-DE.pdf") == "2019"
    assert hp.po_of("015-MH-BRS-PO-2021-WiSe-24-25-Stand-13.08.2024-web.pdf") == "2021"
    assert hp.po_of("ESA-Modulhandbuch_PO_WS_2025-26.pdf") == "2025"
    assert hp.po_of("MAB-AM-WS2016-Modulhandbuch.pdf") == "2016"
    assert hp.po_of("Modulhandbuch_MTV_ab_WiSe_22_23.pdf") == "2022"
    assert hp.po_of("Modulhandbuch.pdf", "Modulhandbuch", "Bachelor Angewandte Informatik, PO Version 19 WS") == "2019"
    assert hp.po_of("Modulhandbuch.pdf") is None
    assert hp.variant_of("https://f1.x/67_ADT_WS2025_Stand.pdf", "Vertiefung ADT", "EIT") == "ADT"
    assert hp.variant_of("https://f2.x/MAB-NW-WS2019-Modulhandbuch.pdf", "", "MAB") == "NW"
    assert hp.variant_of("https://f4.x/2024-modules-BIN-19WS-DE.pdf", "Modulhandbuch", "BIN") is None
    assert hp.is_english("https://f4.x/2024-04-29-modules-BIN-19WS-EN.pdf", "")
    assert not hp.is_english("https://f4.x/2024-04-29-modules-BIN-19WS-DE.pdf", "Modulhandbuch")


def test_catalog_groups_one_per_po_and_variant():
    hp = _tool("hsh_programs_g", "hsh-programs.py")

    def doc(name, po, term, fmt="hsh-modul-code", variant=None, english=False, label=""):
        return {"url": f"https://f4.hs-hannover.de/{name}", "label": label, "kind": "handbook", "format": fmt, "po": po,
                "term": term, "variant": variant, "english": english, "sha256": None, "fetched_at": None}

    docs = [doc("a-19-DE.pdf", "2019", "SS 2024"), doc("a-19-EN.pdf", "2019", "SS 2024", english=True),
            doc("a-19-alt.pdf", "2019", "WS 2019/20"), doc("a-22.pdf", "2022", "WS 2025/26"),
            doc("wpf.pdf", "2022", None, fmt="hsh-wpf-tabelle", label="Wahlpflichtkatalog"),
            doc("adt.pdf", "2022", "WS 2025/26", variant="ADT"), doc("scan.pdf", None, None, fmt="scanned")]
    groups = {(g["po"], g["variant"]): g for g in hp.catalog_groups(docs)}
    assert set(groups) == {("2019", None), ("2022", None), ("2022", "ADT")}
    g19 = groups[("2019", None)]
    assert g19["main"]["url"].endswith("a-19-DE.pdf") and [d["url"].rsplit("/", 1)[-1] for d in g19["older"]] == ["a-19-alt.pdf"]
    g22 = groups[("2022", None)]
    assert g22["main"]["url"].endswith("a-22.pdf") and [d["url"] for d in g22["extra"]] == ["https://f4.hs-hannover.de/wpf.pdf"]


# ---------------------------------------------------------------- Grundstock

def _seed_index() -> dict:
    return json.loads((SEED_DIR / "hsh-index.json").read_text(encoding="utf-8"))


def test_seed_resource_valid_small_and_matches_registry():
    index = _seed_index()
    data = json.loads(gzip.decompress((SEED_DIR / "hsh.json.gz").read_bytes()))
    assert index["university"] == "hsh" and data["university"] == "hsh"
    assert (SEED_DIR / "hsh.json.gz").stat().st_size < 500 * 1024
    reg = json.loads((ROOT / "packages/shared-contracts/study-sources-hsh.json").read_text(encoding="utf-8"))
    keys = {p["key"] for p in reg["programs"]}
    cats = {sc.catalog_key(c): c for c in data["catalogs"]}
    assert len(cats) == index["catalogs"] >= 30
    for e in index["entries"]:
        assert e["key"] in keys and e["library_key"] in cats
        c = cats[e["library_key"]]
        assert not sc.validate(c) and c["code"] == sc.seed_code(e["key"]) and len(c["modules"]) >= 3
        assert "module_texts" not in c and all("content" not in m for m in c["modules"])


def _needs_catalog_cache(tool) -> None:
    """Die Werkzeuge bauen aus dem Zwischenspeicher der HsH-Handbuecher (~/Studora-Builds/hsh-catalog, nicht im
    Repository). Ohne ihn (GitHub Actions) laesst sich der Stand nicht neu bauen: dort ueberspringen statt rot
    (Audit P47, 08.11.2026: beide Tests scheiterten in jedem CI-Lauf mit "veraltet")."""
    if not tool.CAT.DOCS.is_file():
        pytest.skip(f"Zwischenspeicher {tool.CAT.BASE} fehlt (nur auf dem Mac des Inhabers)")


def test_seed_is_current():
    build = _tool("build_hsh_seed_t", "build-hsh-seed.py")
    _needs_catalog_cache(build)
    assert build.main(["--check"]) == 0


def test_hsh_person_gets_catalog_from_seed():
    """HsH-Person: Name aus dem Notenspiegel -> gemischtes Register (Quelle hsh-grundstock) -> Grundstock, ohne Download"""
    seed = {k: c for k, c in sc.load_seed().items() if c["university"] == "hsh"}
    index = _seed_index()
    reg = sc.load_registry()
    uni = next((u for u in reg["universities"] if u["id"] == "hsh"), None)
    assert uni is not None and any(s["id"] == "hsh-grundstock" for s in uni["sources"])
    entries = [x for x in index["entries"] if x["key"].startswith("hsh|angewandte-informatik|b.sc.|bin")]
    assert entries
    hit = sc.match_program("Angewandte Informatik", "hsh", reg)
    assert hit is not None and hit["code"] in {e["code"] for e in entries}
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("CREATE TABLE grades (id INTEGER PRIMARY KEY, text TEXT, abschluss TEXT);"
                       "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);")
    conn.execute("INSERT INTO settings VALUES ('university', 'hsh')")
    conn.execute("INSERT INTO grades(text, abschluss) VALUES ('X', 'Angewandte Informatik')")
    calls = []

    def fetch(url, etag=None, last_modified=None):
        calls.append(url)
        return sc.FetchResult(404, error="HTTP 404")

    state = sc.run_sync(conn, fetch, datetime(2026, 11, 5, 12, tzinfo=timezone.utc), seed=seed)
    assert state["state"] == "seed" and state["origin"] == "seed" and calls == [], state
    assert state["code"] == hit["code"] and state["modules"] >= 20
    assert sc.run_sync(conn, fetch, datetime(2026, 11, 5, 12, tzinfo=timezone.utc), seed=seed)["origin"] == "local"


# ---------------------------------------------------------------- Pruefungsanmeldung

def test_registration_windows_from_faculty_texts():
    ex = _tool("hsh_exam_t", "hsh-exam-registration.py")
    long_ = ("Montag, 7. September bis \nMontag, 14. September 2026 \nAnmeldung zu den Prüfungen im Prüfungszeitraum A\n"
             "Montag, 02. November 2026 bis\nSonntag, 29. November 2026\nAnmeldung zu den Prüfungen im Januar 2027 im")
    assert ex.windows_long(long_) == [
        {"start": "2026-09-07", "end": "2026-09-14", "label": "Anmeldung zu den Prüfungen (Prüfungszeitraum A)"},
        {"start": "2026-11-02", "end": "2026-11-29", "label": "Anmeldung zu den Prüfungen (Januar 2027)"}]
    short = ("Prüfungsanmeldung Montag, 02.11. bis \nSonntag, 22.11.2026 \nTermin folgt\n"
             "Die Online-Anmeldung zu den Prüfungen findet wie folgt statt: \n14.10.2026 – 28.10.2026")
    assert [(w["start"], w["end"]) for w in ex.windows_short(short)] == [("2026-11-02", "2026-11-22"), ("2026-10-14", "2026-10-28")]
    yearly = "Folgende Anmeldezeiträume gelten für die Prüfungen: Sommersemester: 15.05. bis 31.05. Wintersemester: 15.11. bis 30.11."
    assert ex.windows_yearly(yearly) == {"ss": ((15, 5), (31, 5)), "ws": ((15, 11), (30, 11))}
    assert ex.withdraw_rule("Prüfung bis zu einer Woche vor der Prüfung ohne Angabe von Gründen abgemeldet") \
        == "Abmeldung bis eine Woche vor dem Prüfungstermin ohne Angabe von Gründen."
    assert ex.term_label("2026-11-15") == "WiSe 26/27" and ex.term_label("2027-05-15") == "SoSe 27"


def test_exam_registration_data_current_and_shaped_like_luh():
    ex = _tool("hsh_exam_c", "hsh-exam-registration.py")
    _needs_catalog_cache(ex)
    assert ex.main(["x", "--check"]) == 0
    data = json.loads((ROOT / "packages/shared-contracts/exam-registration-hsh.json").read_text(encoding="utf-8"))
    assert data["university"] == "hsh" and data["system"] == "HISinOne"
    assert {"hsh-f4-informatik", "hsh-f4-wi", "hsh-f4-bwl", "hsh-f2-m", "hsh-f3-ik"} <= set(data["tables"])
    for t in data["tables"].values():
        for term in t["terms"]:
            for p in term["periods"]:
                assert p["kind"] == "meldung" and p["start"] <= p["end"] and p["source"].startswith("https://")
    bin_ = next(p for p in data["programs"] if p["slug"] == "angewandte-informatik-bsc")
    assert bin_["table"] == "hsh-f4-informatik"
    assert all(p["table"] in data["tables"] or p["table"] is None for p in data["programs"])
