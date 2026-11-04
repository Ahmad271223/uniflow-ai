"""Word (.docx) und PowerPoint (.pptx) als Seitentexte (docs/DATEIARTEN.md, 04.11.2026): dieselben Dateien und
Erwartungen wie der Kern (packages/shared-contracts/fixtures/office-text, tools/gen-office-fixture.py). Dazu: die
Skriptsuche liest Word/PowerPoint von der Platte wie PDF, /pagetext und Seitentreffer nennen `kind`."""
import json
from pathlib import Path

from conftest import asgi_call

FX = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "office-text"
CASES = json.loads((FX / "cases.json").read_text(encoding="utf-8"))


def test_fixture_is_current():
    import subprocess, sys
    r = subprocess.run([sys.executable, "tools/gen-office-fixture.py", "--check"], cwd=FX.parents[3], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_pages_match_fixture():
    from app import extract
    for c in CASES["files"]:
        data = (FX / c["file"]).read_bytes()
        assert extract.office_pages_bytes(data, Path(c["file"]).suffix) == c["pages"], c["file"]
        assert extract.text_kind(c["file"]) == c["kind"]
        assert extract.office_pages(FX / c["file"]) == c["pages"]


def test_paragraph_pages_and_kinds():
    from app import extract
    assert (extract.SOFT_PAGE_CHARS, extract.HARD_PAGE_CHARS) == (CASES["soft_page_chars"], CASES["hard_page_chars"])
    for c in CASES["paragraph_pages"]:
        assert extract.pages_from_paragraphs(c["paragraphs"], set(c["headings"]), set(c["breaks"])) == c["pages"], c["name"]
    for k in CASES["kinds"]:
        assert extract.text_kind(k["name"]) == k["kind"], k["name"]
        assert extract.is_text_source(k["name"]) == (k["kind"] in ("pdf", "docx", "pptx")), k["name"]


def test_broken_and_foreign_files():
    from app import extract
    import pytest
    with pytest.raises(ValueError):
        extract.docx_pages(b"kein zip")
    with pytest.raises(ValueError):
        extract.pptx_pages(b"PK\x03\x04 kaputt")
    assert extract.office_pages(FX / "cases.json") is None            # keine Office-Datei
    assert extract.office_pages(FX / "gibt-es-nicht.docx") is None


def test_extract_text_pages_word():
    from app import extract
    t = extract.extract_text(FX / "folien.pptx")
    assert t.startswith("--- Seite 1 ---\nNetzwerkanalyse") and "--- Seite 2 ---" in t and "Notizen:" in t
    assert extract.page_count(FX / "folien.pptx") == 4 and extract.page_count(FX / "leer.docx") is None


MODULE = 1934   # eigene Modul-ID: test_pageocr nutzt 92 und 93 in derselben Datenbank der Testsitzung


def _seed(conn, file_id, src: Path, module_id=MODULE):
    conn.execute("INSERT OR IGNORE INTO modules(id, name, color, created_at) VALUES (?, 'Dateiarten Test', '#223344', '2026-11-04')", (module_id,))
    conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, module_id, created_at) VALUES ('c-arten', 'Dateiarten Kurs', 'Dateiarten Test', 'vorlesung', ?, '2026-11-04')", (module_id,))
    conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, chdate, local_path, studip_folder) VALUES (?, 'c-arten', ?, 'file', 'neu', 1762250000, ?, 'Vorlesung')",
                 (file_id, src.name, str(src)))
    conn.execute("INSERT OR REPLACE INTO analysis(file_id, doc_type, title) VALUES (?, 'vorlesung', ?)", (file_id, src.stem))


def test_pagetext_search_and_related_use_office_pages(app, tmp_path):
    from app import db, scriptsearch
    docx = tmp_path / "bericht.docx"; docx.write_bytes((FX / "bericht.docx").read_bytes())
    pptx = tmp_path / "folien.pptx"; pptx.write_bytes((FX / "folien.pptx").read_bytes())
    with db.cursor() as conn:
        scriptsearch.ensure_table(conn)
        _seed(conn, "f-word", docx)
        _seed(conn, "f-folien", pptx)
    st, _, b = asgi_call(app, "GET", "/api/files/f-folien/pagetext?page=2")
    assert st == 200
    r = json.loads(b)
    assert r["pages"] == 4 and r["kind"] == "pptx" and r["text"].startswith("Beispiel: R1 = 2 Ω") and "Notizen:" in r["text"]
    st, _, b = asgi_call(app, "GET", "/api/files/f-word/pagetext?page=1")
    r = json.loads(b)
    assert r["kind"] == "docx" and r["pages"] == 4 and "Knotenregel" in r["text"]
    # Seitentreffer der globalen Suche mit `kind`
    st, _, b = asgi_call(app, "GET", "/api/search?q=spannungsteiler")
    hits = [(p["file_id"], p["page"], p["kind"]) for p in json.loads(b)["pages"]]
    assert hits == [("f-folien", 2, "pptx")]
    # Skriptsuche: Word-Seiten sind Quellen des Moduls (vorher nur PDF)
    with db.cursor() as conn:
        srcs = scriptsearch._sources(conn, MODULE, None)
        assert sorted(f["id"] for f in srcs) == ["f-folien", "f-word"]
        idx = scriptsearch._index(conn, MODULE)
    assert {(d["file"]["id"], d["page"]) for d in idx["docs"]} >= {("f-word", 2), ("f-word", 3), ("f-folien", 2)}
    # Seitenzahl: `page_count` kennt Word und PowerPoint
    from app import extract
    assert extract.page_count(docx) == 4
    # Zeilen wieder entfernen: die Datenbank bleibt fuer die ganze Testsitzung, andere Tests zaehlen Dateien je Modul
    with db.cursor() as conn:
        conn.execute("DELETE FROM page_texts WHERE file_id IN ('f-word', 'f-folien')")
        conn.execute("DELETE FROM analysis WHERE file_id IN ('f-word', 'f-folien')")
        conn.execute("DELETE FROM files WHERE id IN ('f-word', 'f-folien')")
        conn.execute("DELETE FROM courses WHERE id='c-arten'")
        conn.execute("DELETE FROM modules WHERE id=?", (MODULE,))
