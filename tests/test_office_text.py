"""Word (.docx) und PowerPoint (.pptx) als Seitentexte (docs/DATEIARTEN.md, 04.11.2026): dieselben Dateien und
Erwartungen wie der Kern (packages/shared-contracts/fixtures/office-text, tools/gen-office-fixture.py). Dazu: die
Skriptsuche liest Word/PowerPoint von der Platte wie PDF, /pagetext und Seitentreffer nennen `kind`."""
import json
from pathlib import Path

import pytest
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


# ---------------------------------------------------------------- Sicherheitspruefung 04.11.2026: Grenzen beim Entpacken

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _zip(entries: dict, compression=None) -> bytes:
    import io
    import zipfile
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression or zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            z.writestr(name, data)
    return buf.getvalue()


def _docx(body_xml: str) -> bytes:
    return _zip({"word/document.xml": f'<?xml version="1.0"?><w:document xmlns:w="{W_NS}"><w:body>{body_xml}</w:body></w:document>'})


def _para(text: str) -> str:
    return f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>"


def _pptx(n_slides: int, extra: dict | None = None) -> bytes:
    a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    entries = {"ppt/presentation.xml": f'<p:presentation xmlns:p="{p}"/>'}
    for i in range(1, n_slides + 1):
        entries[f"ppt/slides/slide{i}.xml"] = (f'<p:sld xmlns:p="{p}" xmlns:a="{a}"><p:cSld><p:spTree><p:sp><p:txBody>'
                                               f'<a:p><a:r><a:t>Folie {i}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>')
    entries.update(extra or {})
    return _zip(entries)


def test_small_files_still_read():
    from app import extract
    assert extract.docx_pages(_docx(_para("Hallo Welt"))) == ["Hallo Welt"]
    assert extract.pptx_pages(_pptx(3)) == ["Folie 1", "Folie 2", "Folie 3"]


def test_zip_bomb_entry_is_refused_by_size_and_ratio():
    """Ein Eintrag ueber MAX_ZIP_ENTRY (40 MiB entpackt, gepackt nur wenige KiB) wird abgewiesen, ohne ihn zu entpacken."""
    import time
    from app import extract
    bomb = _docx(_para(" " * (extract.MAX_ZIP_ENTRY + 1024)))
    assert len(bomb) < 200_000, "hohes Packverhaeltnis"
    t = time.monotonic()
    with pytest.raises(ValueError, match="zu gross"):
        extract.docx_pages(bomb)
    assert time.monotonic() - t < 2.0


def test_forged_size_in_the_header_does_not_bypass_the_cap(monkeypatch):
    """Die Groesse im Kopf des Eintrags ist faelschbar: gelesen wird stueckweise, gezaehlt wird, was wirklich kommt.
    Ein Eintrag, der kleiner tut, als er ist, scheitert an der Pruefsumme oder der Grenze, nie mit vollem Speicher."""
    import struct
    from app import extract
    monkeypatch.setattr(extract, "MAX_ZIP_ENTRY", 64 * 1024)
    data = bytearray(_docx(_para("x" * (512 * 1024))))
    # Groesse (entpackt) im Zentralverzeichnis und im lokalen Kopf auf 1000 Bytes faelschen
    cd = data.rfind(b"PK\x01\x02")
    struct.pack_into("<I", data, cd + 24, 1000)
    struct.pack_into("<I", data, 22, 1000)
    with pytest.raises(ValueError):
        extract.docx_pages(bytes(data))


def test_archive_total_entry_count_and_slide_caps(monkeypatch):
    from app import extract
    # Summe aller gelesenen Teile
    monkeypatch.setattr(extract, "MAX_ZIP_TOTAL", 3000)
    deck = _pptx(40)
    with pytest.raises(ValueError, match="Archiv entpackt zu gross"):
        extract.pptx_pages(deck)
    monkeypatch.setattr(extract, "MAX_ZIP_TOTAL", 200 << 20)
    assert len(extract.pptx_pages(deck)) == 40
    # Eintraege im Archiv
    monkeypatch.setattr(extract, "MAX_ZIP_ENTRIES", 10)
    with pytest.raises(ValueError, match="zu vielen Eintraegen"):
        extract.pptx_pages(_pptx(10))
    assert len(extract.pptx_pages(_pptx(9))) == 9
    monkeypatch.setattr(extract, "MAX_ZIP_ENTRIES", 20_000)
    # Folien je Praesentation
    monkeypatch.setattr(extract, "MAX_SLIDES", 5)
    with pytest.raises(ValueError, match="zu viele Folien"):
        extract.pptx_pages(_pptx(6))
    assert len(extract.pptx_pages(_pptx(5))) == 5
    assert extract.office_pages_bytes(_pptx(5), ".pptx") == [f"Folie {i}" for i in range(1, 6)]


def test_default_caps_are_documented():
    from app import extract
    assert (extract.MAX_ZIP_ENTRY, extract.MAX_ZIP_TOTAL, extract.MAX_ZIP_ENTRIES, extract.MAX_SLIDES) == (40 << 20, 200 << 20, 20_000, 2_000)


def test_path_traversal_names_only_address_entries_in_the_archive(tmp_path, monkeypatch):
    """Namen wie ../../x oder /etc/passwd sind nur Schluessel im Archiv: nichts wird geschrieben, nichts ausserhalb
    gelesen; Beziehungsziele bleiben im Paket (hoechstens bis zur Wurzel)."""
    from app import extract
    assert extract._resolve("ppt", "../../../../etc/passwd") == "etc/passwd"
    assert extract._resolve("ppt/slides", "/etc/passwd") == "etc/passwd"
    assert extract._resolve("ppt/slides", "../notesSlides/n1.xml") == "ppt/notesSlides/n1.xml"
    p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    pr = "http://schemas.openxmlformats.org/package/2006/relationships"
    evil = _pptx(1, {
        "../../outside.txt": "boese",
        "/abs/outside.txt": "boese",
        "ppt/presentation.xml": f'<p:presentation xmlns:p="{p}" xmlns:r="{r}"><p:sldIdLst><p:sldId r:id="rId1"/><p:sldId r:id="rId2"/>'
                                f'</p:sldIdLst></p:presentation>',
        "ppt/_rels/presentation.xml.rels": f'<Relationships xmlns="{pr}">'
                                           f'<Relationship Id="rId1" Type="x/slide" Target="slides/slide1.xml"/>'
                                           f'<Relationship Id="rId2" Type="x/slide" Target="../../../../../etc/passwd"/></Relationships>',
    })
    monkeypatch.chdir(tmp_path)
    pages = extract.pptx_pages(evil)
    assert pages[0] == "Folie 1" and all("root:" not in pg for pg in pages)
    assert list(tmp_path.iterdir()) == [] and not (tmp_path.parent / "outside.txt").exists()


def test_xml_entity_expansion_and_external_entities_are_refused():
    import time
    from app import extract
    lol = ('<?xml version="1.0"?><!DOCTYPE w:document [<!ENTITY a "aaaaaaaaaa">'
           + "".join(f'<!ENTITY {chr(98 + i)} "{("&" + chr(97 + i) + ";") * 10}">' for i in range(9))
           + f']><w:document xmlns:w="{W_NS}"><w:body><w:p><w:r><w:t>&j;</w:t></w:r></w:p></w:body></w:document>')
    t = time.monotonic()
    with pytest.raises(ValueError, match="nicht lesbar"):
        extract.docx_pages(_zip({"word/document.xml": lol}))
    assert time.monotonic() - t < 5.0, "Ausdehnung wird frueh abgebrochen"
    ext = (f'<?xml version="1.0"?><!DOCTYPE w:document [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
           f'<w:document xmlns:w="{W_NS}"><w:body><w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>')
    try:
        pages = extract.docx_pages(_zip({"word/document.xml": ext}))
    except ValueError:
        pages = []
    assert all("root:" not in pg for pg in pages)


def test_unsupported_compression_or_encryption_is_unreadable_not_a_crash():
    import struct
    from app import extract
    data = bytearray(_docx(_para("x")))
    cd = data.rfind(b"PK\x01\x02")
    struct.pack_into("<H", data, cd + 10, 99)          # Kompressionsverfahren 99 (AES), nicht unterstuetzt
    struct.pack_into("<H", data, 8, 99)
    with pytest.raises(ValueError):
        extract.docx_pages(bytes(data))
    data = bytearray(_docx(_para("x")))
    cd = data.rfind(b"PK\x01\x02")
    struct.pack_into("<H", data, cd + 8, 1)            # Bit 0: verschluesselt
    struct.pack_into("<H", data, 6, 1)
    with pytest.raises(ValueError):
        extract.docx_pages(bytes(data))
