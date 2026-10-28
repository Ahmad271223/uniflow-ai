"""Word ansehen (app/docx_view.py, Entscheidung 28.10.2026): Ueberschriften, Formatierung, Listen, Tabellen, Bilder,
Links; nichts aus dem Dokument wird als HTML oder Skript ausgefuehrt."""
import io
import json
import zipfile

import pytest
from conftest import asgi_call

NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000")


def docx(body: str, extra: dict | None = None) -> bytes:
    rels = """<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rLink" Type="hyperlink" Target="https://www.uni-hannover.de/" TargetMode="External"/>
      <Relationship Id="rEvil" Type="hyperlink" Target="javascript:alert(1)" TargetMode="External"/>
      <Relationship Id="rImg" Type="image" Target="media/bild.png"/></Relationships>"""
    styles = f"""<w:styles {NS}><w:style w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
      <w:style w:styleId="berschrift2"><w:name w:val="Überschrift 2"/></w:style></w:styles>"""
    numbering = f"""<w:numbering {NS}><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
      <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"""
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("word/document.xml", f'<w:document {NS}><w:body>{body}</w:body></w:document>')
        z.writestr("word/_rels/document.xml.rels", rels)
        z.writestr("word/styles.xml", styles)
        z.writestr("word/numbering.xml", numbering)
        z.writestr("word/media/bild.png", PNG)
        for k, v in (extra or {}).items():
            z.writestr(k, v)
    return b.getvalue()


def p(text, style=None, b=False, num=None):
    ppr = (f'<w:pPr>{f"<w:pStyle w:val=\"{style}\"/>" if style else ""}'
           f'{f"<w:numPr><w:ilvl w:val=\"{num[1]}\"/><w:numId w:val=\"{num[0]}\"/></w:numPr>" if num else ""}</w:pPr>')
    rpr = "<w:rPr><w:b/></w:rPr>" if b else ""
    return f'<w:p>{ppr}<w:r>{rpr}<w:t xml:space="preserve">{text}</w:t></w:r></w:p>'


def test_structure_formatting_lists_tables_images_links():
    from app.docx_view import to_html
    body = (p("Übungsblatt 3", "Heading1") + p("Aufgabe 1", "berschrift2") + p("fett", b=True)
            + p("erstens", num=("1", 0)) + p("Unterpunkt", num=("1", 1)) + p("zweitens", num=("1", 0)) + p("danach")
            + '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
            + '<w:p><w:hyperlink r:id="rLink"><w:r><w:t>LUH</w:t></w:r></w:hyperlink><w:hyperlink r:id="rEvil"><w:r><w:t>böse</w:t></w:r></w:hyperlink></w:p>'
            + '<w:p><w:r><w:drawing><a:blip r:embed="rImg"/></w:drawing></w:r></w:p>'
            + '<w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/><w:color w:val="FF0000"/></w:rPr><w:t>2</w:t></w:r></w:p>')
    out = to_html(docx(body))
    h = out["html"]
    assert "<h1>Übungsblatt 3</h1>" in h and "<h2>Aufgabe 1</h2>" in h and "<b>fett</b>" in h
    assert "<ol><li>erstens</li><ul><li>Unterpunkt</li></ul><li>zweitens</li></ol><p>danach</p>" in h
    assert '<table class="dx-table"><tr><td><p>a</p></td><td><p>b</p></td></tr></table>' in h
    assert '<a href="https://www.uni-hannover.de/" target="_blank" rel="noopener noreferrer">LUH</a>' in h
    assert "javascript" not in h and "böse" in h, "nur http(s)-Links"
    assert 'src="data:image/png;base64,' in h and out["images"] == 1
    assert '<span style="color:#FF0000"><sup>2</sup></span>' in h


def test_nothing_from_the_document_becomes_markup():
    from app.docx_view import to_html
    h = to_html(docx(p("&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=alert(1)&gt;")))["html"]
    assert "<script" not in h and "<img" not in h and "&lt;script&gt;" in h
    h = to_html(docx('<w:p><w:r><w:rPr><w:color w:val="red;background:url(x)"/><w:highlight w:val="yellow;x"/></w:rPr><w:t>x</w:t></w:r></w:p>'))["html"]
    assert "url(" not in h and "style=" not in h


def test_old_word_macros_and_broken_files_are_refused():
    from app.docx_view import DocxError, to_html
    with pytest.raises(DocxError, match=r"\.doc"):
        to_html(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"0" * 100)
    with pytest.raises(DocxError, match="Makros"):
        to_html(docx(p("x"), {"word/vbaProject.bin": b"x"}))
    with pytest.raises(DocxError, match="kein Word"):
        to_html(b"kein zip")


def test_endpoint_serves_html_for_a_local_docx(app, tmp_path):
    from app import db
    f = tmp_path / "Blatt.docx"
    f.write_bytes(docx(p("Hallo Word", "Heading1")))
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id='dx-1'")
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('dx-kurs', 'Kurs')")
        conn.execute("INSERT INTO files(id, course_id, name, status, local_path) VALUES ('dx-1', 'dx-kurs', 'Blatt.docx', 'neu', ?)", (str(f),))
    try:
        st, _, b = asgi_call(app, "GET", "/api/files/dx-1/docx")
        d = json.loads(b)
        assert st == 200 and "<h1>Hallo Word</h1>" in d["html"] and d["name"] == "Blatt.docx"
        f.write_bytes(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"0" * 10)
        st, _, b = asgi_call(app, "GET", "/api/files/dx-1/docx")
        assert st == 422 and json.loads(b)["code"] == "docx_unreadable"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM files WHERE id='dx-1'")
