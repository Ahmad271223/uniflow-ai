"""Fixture Word/PowerPoint-Text (docs/DATEIARTEN.md): kleine echte .docx/.pptx-Dateien (nur Standardbibliothek) und
die Seiten, die app/extract.py daraus liest. Der Kern (`OfficeText`, Swift) und die Web-Tests lesen dieselben Dateien
und muessen dieselben Seiten liefern.

Aufruf:  python tools/gen-office-fixture.py          # schreibt packages/shared-contracts/fixtures/office-text/
         python tools/gen-office-fixture.py --check  # Exitcode 1, wenn veraltet
"""
from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "office-text"

from app import extract  # noqa: E402

STAMP = (2026, 11, 4, 12, 0, 0)     # feste Zeit in den Zip-Eintraegen, sonst aendert sich die Datei bei jedem Lauf


def put(z: zipfile.ZipFile, name: str, text: str, stored: bool = False) -> None:
    info = zipfile.ZipInfo(name, date_time=STAMP)
    info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
    z.writestr(info, text)

W_NS = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
        'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
        'xmlns:v="urn:schemas-microsoft-com:vml" mc:Ignorable="w14"')
A_NS = ('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"')
CT_DOCX = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>"""
RELS_DOCX = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""
DOC_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""
STYLES = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles {W_NS}><w:style w:type="paragraph" w:styleId="Normal" w:default="1"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
<w:style w:type="paragraph" w:styleId="berschrift2"><w:name w:val="Überschrift 2"/></w:style></w:styles>"""


def esc(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def p(text: str, style: str | None = None, runs: list[str] | None = None) -> str:
    ppr = f'<w:pPr><w:pStyle w:val="{style}"/></w:pPr>' if style else ""
    body = "".join(f'<w:r><w:t xml:space="preserve">{esc(r)}</w:t></w:r>' for r in (runs or [text]))
    return f"<w:p>{ppr}{body}</w:p>"


def long_text(seed: str, n: int) -> str:
    """Absatz mit etwa n Zeichen aus einem wiederholten Satz (deterministisch)."""
    s = f"{seed} Die Kirchhoffsche Maschenregel besagt, dass die Summe aller Spannungen in einer Masche null ist. "
    out = s
    while len(out) < n:
        out += s
    return out[:n].rstrip()


def bericht_docx() -> bytes:
    parts = [
        p("Grundlagen der Elektrotechnik – Bericht", "Title"),
        p("1 Einleitung", "Heading1"),
        p("Dieser Bericht erklärt Maschen- und Knotenregel. Umlaute: äöü ÄÖÜ ß, Formel U = R · I."),
        # Tabulator und Zeilenumbruch im Absatz, zwei Runs
        '<w:p><w:r><w:t>Spannung</w:t><w:tab/><w:t>12 V</w:t><w:br/><w:t xml:space="preserve">Strom</w:t><w:tab/><w:t>2 A</w:t></w:r></w:p>',
        # leerer Absatz und Absatz nur mit Leerzeichen fallen weg
        "<w:p/>", p("   "),
        # Tabelle: jede Zelle ein Absatz
        "<w:tbl><w:tr><w:tc>" + p("Größe") + "</w:tc><w:tc>" + p("Wert") + "</w:tc></w:tr>"
        "<w:tr><w:tc>" + p("Widerstand") + "</w:tc><w:tc>" + p("6 Ω") + "</w:tc></w:tr></w:tbl>",
        # Textkasten: Choice und Fallback tragen denselben Text, er darf nur einmal erscheinen
        '<w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wps:txbx><w:txbxContent>'
        + p("Merke: Knotenregel – Summe der Ströme ist null.")
        + "</w:txbxContent></wps:txbx></w:drawing></mc:Choice><mc:Fallback><w:pict><v:shape><v:textbox><w:txbxContent>"
        + p("Merke: Knotenregel – Summe der Ströme ist null.")
        + "</w:txbxContent></v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>",
        # Feldcode (instrText) ist kein Text; geloeschter Text (delText) auch nicht
        '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r><w:del><w:r><w:delText>gelöscht</w:delText></w:r></w:del>'
        "<w:r><w:t>Seite eins endet hier.</w:t></w:r></w:p>",
        # echter Seitenumbruch: der naechste Absatz beginnt Seite 2
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
        p("2 Grundlagen", "Heading1"),
    ]
    # Seite 2 waechst ueber 3000 Zeichen; die naechste Ueberschrift beginnt dann Seite 3
    for i in range(4):
        parts.append(p(long_text(f"Absatz {i + 1}.", 800)))
    parts.append(p("2.1 Zwischenüberschrift (Überschrift per outlineLvl)",
                   None).replace("<w:p>", '<w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr>', 1))
    parts.append(p("3 Ohne Überschriften bis zur harten Grenze", "berschrift2"))
    # Seite 3: sieben Absaetze zu je 1000 Zeichen ohne Ueberschrift -> harte Grenze 6000 trennt vor dem siebten
    for i in range(7):
        parts.append(p(long_text(f"Lang {i + 1}.", 1000)))
    parts.append(p("Schluss.", "Heading1"))
    doc = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document {W_NS}><w:body>' + "".join(parts)
           + '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>')
    return docx_package(doc)


def docx_package(document_xml: str) -> bytes:
    import io
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        put(z, "[Content_Types].xml", CT_DOCX)
        put(z, "_rels/.rels", RELS_DOCX)
        put(z, "word/_rels/document.xml.rels", DOC_RELS)
        put(z, "word/document.xml", document_xml)
        put(z, "word/styles.xml", STYLES)
    return b.getvalue()


def leer_docx() -> bytes:
    return docx_package(f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document {W_NS}><w:body><w:p/>'
                        + p("  ") + "</w:body></w:document>")


def sp(name: str, paragraphs: list[list[str]], ph: str | None = None, idx: int = 2) -> str:
    """Form mit Textrahmen; `paragraphs`: je Absatz die Textstuecke (ein "\\n"-Stueck wird a:br)."""
    nv = f'<p:nvSpPr><p:cNvPr id="{idx}" name="{esc(name)}"/><p:cNvSpPr/><p:nvPr>{f"<p:ph type=\"{ph}\"/>" if ph else ""}</p:nvPr></p:nvSpPr>'
    body = ""
    for para in paragraphs:
        body += "<a:p>" + "".join("<a:br/>" if s == "\n" else f'<a:r><a:rPr lang="de-DE"/><a:t>{esc(s)}</a:t></a:r>' for s in para) + "</a:p>"
    return f'<p:sp>{nv}<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>{body}</p:txBody></p:sp>'


def slide_xml(shapes: str) -> str:
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld {A_NS}><p:cSld><p:spTree>'
            '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
            f"{shapes}</p:spTree></p:cSld></p:sld>")


def notes_xml(shapes: str) -> str:
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:notes {A_NS}><p:cSld><p:spTree>'
            '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
            f"{shapes}</p:spTree></p:cSld></p:notes>")


def folien_pptx() -> bytes:
    import io
    slides = {
        # Folie 1: Titel und Aufzaehlung, Foliennummer-Platzhalter wird uebergangen
        "slide1.xml": slide_xml(sp("Titel 1", [["Netzwerkanalyse"]], "title")
                                + sp("Inhalt 2", [["Maschenregel: ΣU = 0"], ["Knotenregel: ΣI = 0"], ["Zwei", "\n", "Zeilen"]], "body", 3)
                                + sp("Foliennummer 3", [["1"]], "sldNum", 4)),
        # Folie 2: nur Text in einer freien Form, dazu Notizen
        "slide2.xml": slide_xml(sp("Textfeld 2", [["Beispiel: R1 = 2 Ω, R2 = 4 Ω in Reihe → R = 6 Ω"]])),
        # Folie 3: ohne Text (Bild) -> leere Seite
        "slide3.xml": slide_xml(""),
        # Folie 4: wird in der Praesentation vor Folie 3 gezeigt (Reihenfolge aus sldIdLst, nicht aus dem Dateinamen)
        "slide4.xml": slide_xml(sp("Textfeld 2", [["Zusammenfassung"], ["Masche und Knoten"]])),
    }
    notes2 = notes_xml(sp("Folienbild 1", [], "sldImg") + sp("Notizenplatzhalter 2", [["Hier den Spannungsteiler herleiten."], ["Zeit: 5 Minuten"]], "body", 3)
                       + sp("Foliennummer 3", [["2"]], "sldNum", 4))
    order = ["slide1.xml", "slide2.xml", "slide4.xml", "slide3.xml"]
    rid = {name: f"rId{i + 10}" for i, name in enumerate(order)}
    pres = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation {A_NS}><p:sldIdLst>'
            + "".join(f'<p:sldId id="{256 + i}" r:id="{rid[n]}"/>' for i, n in enumerate(order))
            + '</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/></p:presentation>')
    pres_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                 + "".join(f'<Relationship Id="{rid[n]}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/{n}"/>' for n in order)
                 + "</Relationships>")
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
          + "".join(f'<Override PartName="/ppt/slides/{n}" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' for n in slides)
          + '<Override PartName="/ppt/notesSlides/notesSlide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/></Types>')
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        put(z, "[Content_Types].xml", ct)
        put(z, "_rels/.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>')
        put(z, "ppt/presentation.xml", pres)
        put(z, "ppt/_rels/presentation.xml.rels", pres_rels)
        for name, xml in slides.items():
            put(z, f"ppt/slides/{name}", xml)
        put(z, "ppt/slides/_rels/slide2.xml.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>')
        put(z, "ppt/notesSlides/notesSlide1.xml", notes2, stored=True)   # auch ungepackte Eintraege
    return b.getvalue()


def paragraph_cases() -> list[dict]:
    a = "a" * 1500
    return [
        {"name": "leer", "paragraphs": ["", "  "], "headings": [], "breaks": [], "pages": []},
        {"name": "kurz", "paragraphs": ["Erster", " zweiter ", "", "dritter"], "headings": [], "breaks": [], "pages": ["Erster\nzweiter\ndritter"]},
        {"name": "ueberschrift unter 3000 trennt nicht", "paragraphs": [a, "Kapitel", "x"], "headings": [1], "breaks": [], "pages": [a + "\nKapitel\nx"]},
        {"name": "ueberschrift ab 3000 trennt", "paragraphs": [a, a, "Kapitel", "x"], "headings": [2], "breaks": [], "pages": [a + "\n" + a, "Kapitel\nx"]},
        {"name": "harte grenze 6000", "paragraphs": [a, a, a, a, "Rest"], "headings": [], "breaks": [], "pages": ["\n".join([a] * 4), "Rest"]},
        {"name": "seitenumbruch", "paragraphs": ["eins", "zwei", "drei"], "headings": [], "breaks": [1], "pages": ["eins", "zwei\ndrei"]},
        {"name": "seitenumbruch am anfang", "paragraphs": ["eins", "zwei"], "headings": [], "breaks": [0], "pages": ["eins\nzwei"]},
    ]


KINDS = [("Vorlesung 3.pdf", "pdf"), ("Skript.PDF", "pdf"), ("bericht.docx", "docx"), ("Folien.PPTX", "pptx"), ("aufnahme.mp3", "audio"),
         ("Vorlesung.m4a", "audio"), ("alt.doc", None), ("alt.ppt", None), ("bild.png", None), ("ohne-endung", None), ("", None)]


def build() -> tuple[dict, dict[str, bytes]]:
    files = {"bericht.docx": bericht_docx(), "leer.docx": leer_docx(), "folien.pptx": folien_pptx()}
    cases = {
        "_": "Erzeugt von tools/gen-office-fixture.py - nicht von Hand aendern. Seiten aus app/extract.py (Referenz).",
        "soft_page_chars": extract.SOFT_PAGE_CHARS, "hard_page_chars": extract.HARD_PAGE_CHARS,
        "files": [{"file": n, "kind": extract.text_kind(n), "pages": extract.office_pages_bytes(d, "." + n.rsplit(".", 1)[1])} for n, d in files.items()],
        "kinds": [{"name": n, "kind": k} for n, k in KINDS],
        "paragraph_pages": paragraph_cases(),
    }
    for c in cases["paragraph_pages"]:
        got = extract.pages_from_paragraphs(c["paragraphs"], set(c["headings"]), set(c["breaks"]))
        assert got == c["pages"], (c["name"], got)
    for n, k in KINDS:
        assert extract.text_kind(n) == k, n
    return cases, files


if __name__ == "__main__":
    cases, files = build()
    text = json.dumps(cases, ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        ok = (OUT / "cases.json").read_text(encoding="utf-8") == text and all((OUT / n).read_bytes() == d for n, d in files.items())
        print("aktuell" if ok else "veraltet: python tools/gen-office-fixture.py")
        sys.exit(0 if ok else 1)
    OUT.mkdir(parents=True, exist_ok=True)
    for n, d in files.items():
        (OUT / n).write_bytes(d)
    (OUT / "cases.json").write_text(text, encoding="utf-8", newline="")
    print("geschrieben:", OUT, [f"{n} ({len(d)} B)" for n, d in files.items()])
