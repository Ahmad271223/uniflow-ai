"""Texterkennung fuer PDF-Seiten ohne Textebene (app/pageocr.py): Gegenstueck zu PageOCRTests.swift. Mit einem Fake-Motor
(gleiche Faelle und Grenzwerte wie in Swift), dazu die Regeln aus fixtures/ocr/rules.json, der Aufruf von Tesseract mit einem
Programm-Ersatz, das Rendern mit pypdfium2 (uebersprungen, wenn nicht installiert) und ein Lauf mit echtem Tesseract
(uebersprungen, wenn nicht installiert). Nur erfundene Daten."""
import importlib.util
import json
import os
import shutil
import stat
import sys
import threading
import zlib
from pathlib import Path

import pytest

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "ocr" / "rules.json"
FULL_PAGE = "Eigenwerte einer Matrix\nDas charakteristische Polynom liefert die Eigenwerte."
needs_pdfium = pytest.mark.skipif(importlib.util.find_spec("pypdfium2") is None, reason="pypdfium2 nicht installiert")


# ---------------------------------------------------------------- Hilfen

class FakeOCR:
    """Erkennung mit festen Texten je Seite; zaehlt, welche Seiten erkannt werden sollten (wie FakeOCR in Swift)."""

    def __init__(self, texts):
        self.texts, self.calls, self.failure, self.hook = dict(texts), [], None, None

    @property
    def pages_recognized(self):
        return [p for c in self.calls for p in c]

    def recognize(self, pdf_path, pages):
        self.calls.append(list(pages))
        if self.hook:
            self.hook(pages)
        if self.failure:
            raise self.failure
        return {p: t for p, t in self.texts.items() if p in pages}


def make_pdf(path: Path, pages) -> Path:
    """Kleines PDF; je Seite eine Liste Textzeilen, None (leer) oder ("scan",) fuer ein Bild ohne Textebene."""
    objs = [b"", b"", b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
    kids = []
    for spec in pages:
        res = b"<</Font<</F1 3 0 R>>>>"
        if spec and spec[0] == "scan":
            img = bytes(range(0, 256, 4)) * 4                         # 16 x 16 Graustufen
            objs.append(b"<</Type/XObject/Subtype/Image/Width 16/Height 16/ColorSpace/DeviceGray/BitsPerComponent 8/Length "
                        + str(len(img)).encode() + b">>stream\n" + img + b"\nendstream")
            content = b"q 595 0 0 842 0 0 cm /Im1 Do Q"
            res = b"<</XObject<</Im1 " + str(len(objs)).encode() + b" 0 R>>>>"
        else:
            content = b"".join(b"BT /F1 12 Tf 60 %d Td (%s) Tj ET\n" % (770 - 20 * i, ln.encode("latin-1").replace(b"(", b"").replace(b")", b""))
                               for i, ln in enumerate(spec or []))
        objs.append(b"<</Length " + str(len(content)).encode() + b">>stream\n" + content + b"\nendstream")
        objs.append(b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents " + str(len(objs)).encode() + b" 0 R/Resources " + res + b">>")
        kids.append(len(objs))
    objs[0] = b"<</Type/Catalog/Pages 2 0 R>>"
    objs[1] = b"<</Type/Pages/Kids[" + b" ".join(b"%d 0 R" % k for k in kids) + b"]/Count " + str(len(kids)).encode() + b">>"
    out, offs = bytearray(b"%PDF-1.4\n"), []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
    out += b"trailer\n<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    path.write_bytes(bytes(out))
    return path


SCAN = ("scan",)
_n = [0]


def seed(tmp_path, pages, chdate=1760256000, module=92):
    """Datei mit PDF auf der Platte in einem Modul; liefert die Datei-ID. Seitentexte werden aus der PDF gelesen."""
    from app import db, scriptsearch
    _n[0] += 1
    fid = f"ocr-{os.getpid()}-{_n[0]}"
    pdf = make_pdf(tmp_path / f"{fid}.pdf", pages)
    with db.cursor() as conn:
        scriptsearch.ensure_table(conn)
        conn.execute("INSERT OR IGNORE INTO modules(id, name, color, created_at) VALUES (?, ?, '#123456', '2026-10-26')", (module, f"OCR Modul Test {module}"))
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, module_id, created_at) VALUES (?, 'OCR Kurs Test', ?, 'vorlesung', ?, '2026-10-26')",
                     (f"c-ocr-{module}", f"OCR Modul Test {module}", module))
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate, local_path, studip_folder) VALUES (?, ?, ?, 'pdf', 'neu', ?, ?, 'Skript')",
                     (fid, f"c-ocr-{module}", f"{fid}.pdf", chdate, str(pdf)))
    return fid


def texts(fid, ocr=None, cancel=None):
    from app import db, scriptsearch
    with db.cursor() as conn:
        return scriptsearch.page_texts(conn, fid, ocr, cancel)


def ocr_rows(fid):
    from app import db
    with db.cursor() as conn:
        if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='page_ocr'").fetchone():
            return None
        return db.rows(conn, "SELECT page, chdate, embedded, text FROM page_ocr WHERE file_id=? ORDER BY page", (fid,))


def stored(fid):
    from app import db
    with db.cursor() as conn:
        return db.rows(conn, "SELECT page, text, search FROM page_texts WHERE file_id=? ORDER BY page", (fid,))


@pytest.fixture(autouse=True)
def _database(app):
    """Datenbank des Test-Datenordners angelegt (Start der Anwendung)."""
    yield


@pytest.fixture
def engine():
    from app import pageocr
    created = []

    def use(fake):
        pageocr.set_engine(fake)
        created.append(fake)
        return fake
    yield use
    pageocr.reset()


# ---------------------------------------------------------------- Regeln (Fixture)

def _tool():
    spec = importlib.util.spec_from_file_location("gen_ocr_fixture", ROOT / "tools" / "gen-ocr-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_fixture_matches_python():
    assert _tool().build() == json.loads(FIXTURE.read_text(encoding="utf-8")), "python tools/gen-ocr-fixture.py neu ausfuehren"


def test_rules_hold():
    """Grenzwerte unabhaengig von der Fixture-Erzeugung: 19 Buchstaben fast leer, 20 nicht; Ziffern zaehlen nicht."""
    from app import pageocr
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert (fx["minimum_letters"], fx["batch_size"]) == (20, 4) == (pageocr.MINIMUM_LETTERS, pageocr.BATCH_SIZE)
    assert pageocr.is_sparse("abcdefghijklmnopqrs") and not pageocr.is_sparse("abcdefghijklmnopqrst")
    assert pageocr.is_sparse("12 / 40 " + "1" * 50) and pageocr.is_sparse("") and pageocr.is_sparse("  3 ")
    assert pageocr.letters("Übergrößenmaß äöü") == 16
    for c in fx["sparse"]:
        assert (pageocr.letters(c["text"]), pageocr.is_sparse(c["text"])) == (c["letters"], c["sparse"]), c["text"]
    sc = {"none": lambda a: pageocr.Scope.none(), "pages": lambda a: pageocr.Scope.only(*a), "leading": lambda a: pageocr.Scope.leading(a),
          "all": lambda a: pageocr.Scope.all()}
    for c in fx["scopes"]:
        s = sc[c["kind"]](c["arg"])
        assert [p for p in range(1, 8) if s.contains(p)] == c["contains"], c
    for c in fx["batches"]:
        assert pageocr.batches(c["todo"]) == c["batches"]
    for c in fx["decisions"]:
        assert pageocr.accepts(c["embedded"], c["recognized"]) == c["accepts"], c
    e = fx["embedded"]
    assert pageocr.map_embedded(e["rows"], e["pages"]) == e["expect"]
    assert e["expect"] == ["Seite mit Text auf der Textebene", "  3 ", "  3 ", "", "", "von Hand geaendert"]


# ---------------------------------------------------------------- Fake-Motor, Faelle wie PageOCRTests.swift

def test_sparse_page_uses_ocr_text_and_is_cached(app, tmp_path, engine):
    """Leere Textebene: der erkannte Text gilt, steht in page_texts (mit Suchform, die globale Suche findet ihn) und in
    page_ocr; die Seite mit Text wird nicht erkannt; ein zweiter Aufruf erkennt nichts erneut."""
    from app import pageocr, scriptsearch
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), ["3"], SCAN])
    ocr = engine(FakeOCR({2: "Kirchhoffsche Maschenregel: Summe der Spannungen ist null", 3: "Knotenregel"}))
    first = texts(fid, pageocr.Scope.all())
    assert first[0].replace("\n", " ").startswith("Eigenwerte einer Matrix")
    assert first[1:] == ["Kirchhoffsche Maschenregel: Summe der Spannungen ist null", "Knotenregel"]
    assert ocr.pages_recognized == [2, 3], "Seite 1 hat eine Textebene"
    rows = stored(fid)
    assert [r["text"] for r in rows] == first
    assert rows[1]["search"] == scriptsearch.search_form(first[1])
    cache = ocr_rows(fid)
    assert [(r["page"], r["chdate"]) for r in cache] == [(2, 1760256000), (3, 1760256000)]
    assert cache[0]["embedded"].strip() == "3" and cache[1]["embedded"] == ""
    # zweiter Aufruf: aus page_texts, keine Erkennung
    assert texts(fid, pageocr.Scope.all()) == first
    assert len(ocr.calls) == 1
    # globale Suche findet den erkannten Text
    st, _, b = asgi_call(app, "GET", "/api/search?q=maschenregel")
    pages = json.loads(b)["pages"]
    assert [(p["file_id"], p["page"]) for p in pages] == [(fid, 2)]
    # Seitenzuordnung einer neuen Fassung vergleicht Textebene mit Textebene
    from app import db
    with db.cursor() as conn:
        emb = scriptsearch.text_layer(conn, fid, first)
    assert emb[0] == first[0] and emb[1].strip() == "3" and emb[2] == ""


def test_pages_with_text_never_call_ocr(tmp_path, engine):
    from app import pageocr
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), ["Diagonalmatrix mit Eigenwerten auf der Diagonale"]])
    ocr = engine(FakeOCR({1: "falsch", 2: "falsch"}))
    pages = texts(fid, pageocr.Scope.all())
    assert pages[1] == "Diagonalmatrix mit Eigenwerten auf der Diagonale" and "falsch" not in pages[0]
    assert ocr.calls == []
    assert ocr_rows(fid) is None or ocr_rows(fid) == []


def test_without_engine_or_scope_nothing_changes(app, tmp_path, engine):
    """Ohne Motor (Standard), mit Scope.none() und ohne Scope: alles wie bisher; der Endpunkt liefert den leeren Text."""
    from app import pageocr
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), SCAN])
    assert pageocr.engine() is None, "in Tests ist LERNAPP_OCR=off"
    assert texts(fid, pageocr.Scope.all())[1] == ""
    ocr = engine(FakeOCR({2: "Maschenregel und Knotenregel im Netzwerk"}))
    assert texts(fid)[1] == "" and texts(fid, pageocr.Scope.none())[1] == "" and texts(fid, None)[1] == ""
    assert ocr.calls == []
    # Standard-Aufrufer ohne Scope (Abgaben nachlesen, Marken, Suche im Index) erkennen nie
    from app import db, scriptsearch, weekly
    with db.cursor() as conn:
        assert weekly.page_texts(conn, fid)[1] == ""
        scriptsearch._index(conn, 93)
    assert ocr.calls == []


def test_scope_empty_result_new_version_and_failure(app, tmp_path, engine):
    """Nur die gefragte Seite (/pagetext), ein leeres Ergebnis wird gemerkt, ein Fehler der Erkennung laesst die Texte
    und versucht es beim naechsten Mal wieder, eine neue Fassung erkennt neu."""
    from app import db, pageocr
    fid = seed(tmp_path, [SCAN, SCAN, SCAN])
    ocr = engine(FakeOCR({2: "Ohmsches Gesetz und Widerstand"}))
    get = lambda page: json.loads(asgi_call(app, "GET", f"/api/files/{fid}/pagetext?page={page}")[2])   # noqa: E731
    assert get(2) == {"text": "Ohmsches Gesetz und Widerstand", "pages": 3, "kind": "pdf"}
    assert ocr.calls == [[2]], "nur die gefragte Seite"
    # Seite 1: nichts erkannt -> gemerkt, kein zweiter Versuch
    assert get(1)["text"] == "" and get(1)["text"] == ""
    assert ocr.calls == [[2], [1]]
    assert [(r["page"], r["text"]) for r in ocr_rows(fid)] == [(1, ""), (2, "Ohmsches Gesetz und Widerstand")]
    # Fehler: Texte bleiben, nichts gemerkt
    ocr.failure = RuntimeError("Motor kaputt")
    assert texts(fid, pageocr.Scope.only(3)) == ["", "Ohmsches Gesetz und Widerstand", ""]
    assert [r["page"] for r in ocr_rows(fid)] == [1, 2]
    ocr.failure = None
    ocr.texts = {3: "Leistung ist Spannung mal Strom"}
    assert texts(fid, pageocr.Scope.only(3))[2] == "Leistung ist Spannung mal Strom"
    assert ocr.calls == [[2], [1], [3], [3]]
    # neue Fassung: Textebene neu gelesen, Ergebnisse verworfen, neu erkannt
    with db.cursor() as conn:
        conn.execute("UPDATE files SET chdate=1760300000 WHERE id=?", (fid,))
    ocr.texts = {2: "Neue Fassung mit Thevenin-Ersatzschaltung"}
    assert texts(fid, pageocr.Scope.only(2)) == ["", "Neue Fassung mit Thevenin-Ersatzschaltung", ""]
    left = ocr_rows(fid)
    assert [(r["page"], r["chdate"]) for r in left] == [(2, 1760300000)]


def test_endpoint_without_engine_unchanged(app, tmp_path):
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), SCAN])
    st, _, b = asgi_call(app, "GET", f"/api/files/{fid}/pagetext?page=2")
    assert st == 200 and json.loads(b) == {"text": "", "pages": 2, "kind": "pdf"}


def test_tutor_and_related_read_recognized_page(app, tmp_path, engine):
    """KI-Hilfe ohne mitgeschickten Seitentext (server.page_text) und Skriptsuche zu einer Seite (/api/related) lesen die
    erkannte Seite; erkannt wird nur diese Seite."""
    from app import server
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), SCAN, SCAN])
    ocr = engine(FakeOCR({2: "Kirchhoffsche Maschenregel im geschlossenen Umlauf", 3: "andere Seite"}))
    assert server.page_text(fid, 2)["text"] == "Kirchhoffsche Maschenregel im geschlossenen Umlauf"
    assert ocr.calls == [[2]]
    st, _, b = asgi_call(app, "POST", "/api/related", body=json.dumps({"file_id": fid, "page": 3}))
    assert st == 200 and ocr.calls == [[2], [3]]


def test_batches_of_four_and_save_after_each(tmp_path, engine):
    from app import pageocr
    fid = seed(tmp_path, [SCAN] * 9)
    ocr = engine(FakeOCR({p: f"Erkannte Seite Nummer {p} mit genug Buchstaben" for p in range(1, 10)}))
    out = texts(fid, pageocr.Scope.all())
    assert ocr.calls == [[1, 2, 3, 4], [5, 6, 7, 8], [9]]
    assert out[8] == "Erkannte Seite Nummer 9 mit genug Buchstaben"
    assert len(ocr_rows(fid)) == 9


def test_cancel_keeps_finished_batches(tmp_path, engine):
    """Abbruch zwischen den Stapeln: OCRCancelled; der fertige Stapel ist gespeichert, der Rest bleibt fuer spaeter."""
    from app import pageocr
    fid = seed(tmp_path, [SCAN] * 6)
    ocr = engine(FakeOCR({p: f"Erkannte Seite Nummer {p} mit genug Buchstaben" for p in range(1, 7)}))
    state = {"stop": False}
    ocr.hook = lambda pages: state.update(stop=pages[0] == 5)            # waehrend des zweiten Stapels abbrechen: sein Ergebnis gilt nicht mehr
    with pytest.raises(pageocr.OCRCancelled):
        texts(fid, pageocr.Scope.all(), cancel=lambda: state["stop"])
    assert [r["page"] for r in ocr_rows(fid)] == [1, 2, 3, 4]
    assert [r["text"] for r in stored(fid)][4:] == ["", ""]
    state["stop"], ocr.hook = False, None
    out = texts(fid, pageocr.Scope.all(), cancel=lambda: state["stop"])
    assert ocr.calls == [[1, 2, 3, 4], [5, 6], [5, 6]] and out[5].startswith("Erkannte Seite Nummer 6")
    # Abbruch vor dem ersten Stapel: nichts erkannt, nichts gespeichert
    fid2 = seed(tmp_path, [SCAN, SCAN])
    ocr2 = engine(FakeOCR({1: "Erkannte Seite Nummer 1 mit genug Buchstaben"}))
    with pytest.raises(pageocr.OCRCancelled):
        texts(fid2, pageocr.Scope.all(), cancel=lambda: True)
    assert ocr2.calls == [] and not ocr_rows(fid2)


def test_ocr_text_with_fewer_letters_is_stored_but_not_applied(tmp_path, engine):
    """Die Textebene hat 15 Buchstaben (fast leer); findet die Erkennung weniger, bleibt die Textebene, das Ergebnis wird
    trotzdem gemerkt (nicht wiederholt)."""
    from app import pageocr
    fid = seed(tmp_path, [["Aufgabe Kopfzeile"]])
    ocr = engine(FakeOCR({1: "  Kopf  "}))
    assert texts(fid, pageocr.Scope.all()) == ["Aufgabe Kopfzeile"]
    assert [(r["embedded"], r["text"]) for r in ocr_rows(fid)] == [("Aufgabe Kopfzeile", "Kopf")]
    texts(fid, pageocr.Scope.all())
    assert len(ocr.calls) == 1


def test_new_version_during_recognition_discards_result(tmp_path, engine):
    """Kommt waehrend der Erkennung eine neue Fassung, gehoert das Ergebnis nicht mehr dazu und wird nicht gespeichert."""
    from app import db, pageocr
    fid = seed(tmp_path, [SCAN, SCAN])
    ocr = engine(FakeOCR({1: "Text der alten Fassung mit genug Buchstaben"}))

    def bump(pages):
        with db.cursor() as conn:
            conn.execute("UPDATE files SET chdate=1760999999 WHERE id=?", (fid,))
    ocr.hook = bump
    out = texts(fid, pageocr.Scope.all())
    assert out == ["", ""] and not ocr_rows(fid) and [r["text"] for r in stored(fid)] == ["", ""]


def test_no_write_lock_held_during_recognition(tmp_path, engine):
    """Waehrend der Erkennung (Sekunden bis Minuten) haelt die Verbindung keine Schreibsperre: ein anderer Schreiber kommt durch."""
    from app import db, pageocr
    fid = seed(tmp_path, [SCAN])
    ok = []

    def other_writer(pages):
        conn = db.connect()
        try:
            conn.execute("PRAGMA busy_timeout=300")
            conn.execute("UPDATE files SET size=7 WHERE id=?", (fid,))
            conn.commit()
            ok.append(True)
        except Exception:  # noqa: BLE001
            ok.append(False)
        finally:
            conn.close()
    ocr = engine(FakeOCR({1: "Text mit genug Buchstaben fuer die Seite"}))
    ocr.hook = other_writer
    from app import scriptsearch
    with db.cursor() as conn:
        scriptsearch.page_texts(conn, fid)                    # Seitentexte lesen und speichern (offene Schreibtransaktion)
        out = scriptsearch.page_texts(conn, fid, pageocr.Scope.all())
    assert ok == [True] and out == ["Text mit genug Buchstaben fuer die Seite"]


def test_stream_mode_file_without_disk_copy_is_left_alone(tmp_path, engine):
    """Im Dienst (Betriebsart stream) liegt die Datei nie auf der Platte: nichts zu erkennen, Texte wie sie sind."""
    from app import db, pageocr, scriptsearch
    fid = seed(tmp_path, [SCAN])
    with db.cursor() as conn:
        scriptsearch.page_texts(conn, fid)
        conn.execute("UPDATE files SET local_path=NULL WHERE id=?", (fid,))
    ocr = engine(FakeOCR({1: "Text aus dem Nichts mit genug Buchstaben"}))
    assert texts(fid, pageocr.Scope.all()) == [""] and ocr.calls == []


def test_store_pages_drops_results(tmp_path, engine):
    """Neu gelesene Seitentexte (Geraete-Abgleich PUT /pagetext, Durchreichen) verwerfen die Ergebnisse der alten Fassung."""
    from app import db, pageocr, scriptsearch
    fid = seed(tmp_path, [SCAN])
    engine(FakeOCR({1: "Text der alten Fassung mit genug Buchstaben"}))
    texts(fid, pageocr.Scope.all())
    assert len(ocr_rows(fid)) == 1
    with db.cursor() as conn:
        scriptsearch.store_pages(conn, fid, ["Neue Seitentexte vom Geraet"], 1760256000)
    assert ocr_rows(fid) == []


def test_index_with_ocr_recognizes_sources_once(tmp_path, engine):
    """Index der Skriptsuche mit Scope.all() (Hintergrund der Wochentests) erkennt die Vorlesungsseiten; der Index
    sieht den erkannten Text; ohne Scope erkennt er nie."""
    from app import db, pageocr, scriptsearch
    fid = seed(tmp_path, [SCAN, SCAN], module=93)
    ocr = engine(FakeOCR({1: "Kirchhoffsche Maschenregel Spannung Umlauf Widerstand Strom",
                          2: "Knotenregel Stromverzweigung Knoten Summe Strom Kirchhoff"}))
    with db.cursor() as conn:
        scriptsearch._index(conn, 93)
        assert ocr.calls == []
        idx = scriptsearch._index(conn, 93, pageocr.Scope.all())
    assert ocr.calls == [[1, 2]]
    assert [d["page"] for d in idx["docs"] if d["file"]["id"] == fid] == [1, 2]
    with db.cursor() as conn:
        scriptsearch._index(conn, 93, pageocr.Scope.all())
    assert ocr.calls == [[1, 2]]


def test_weekly_document_version_ignores_recognized_text(tmp_path, engine):
    """Die Dokumentversion der Wochentests zaehlt nur die Textebene: Texterkennung einer Scan-Seite macht aus einer
    unveraenderten Datei keine neue Fassung (Marker muessten sonst geprueft werden)."""
    from app import db, pageocr, weekly
    fid = seed(tmp_path, [FULL_PAGE.split("\n"), SCAN])
    with db.cursor() as conn:
        before = weekly.doc_version(conn, fid)
    engine(FakeOCR({2: "Kirchhoffsche Maschenregel im geschlossenen Umlauf"}))
    assert texts(fid, pageocr.Scope.all())[1].startswith("Kirchhoffsche")
    with db.cursor() as conn:
        assert weekly.doc_version(conn, fid) == before
        assert weekly.page_texts(conn, fid, pageocr.Scope.all())[1].startswith("Kirchhoffsche")


def test_demo_removal_and_sync_drop_results_helper(tmp_path):
    """pageocr.delete legt die Tabelle nicht an und loescht nur die Datei."""
    from app import db, pageocr
    with db.cursor() as conn:
        pageocr.delete(conn, "gibt-es-nicht")
        pageocr.ensure_table(conn)
        conn.execute("INSERT OR REPLACE INTO page_ocr(file_id, page, chdate, embedded, text) VALUES ('del-a', 1, 1, '', 'x'), ('del-b', 1, 1, '', 'y')")
        pageocr.delete(conn, "del-a")
        assert [r["file_id"] for r in db.rows(conn, "SELECT file_id FROM page_ocr WHERE file_id LIKE 'del-%'")] == ["del-b"]
        conn.execute("DELETE FROM page_ocr WHERE file_id LIKE 'del-%'")


# ---------------------------------------------------------------- Schalter und Wahl des Motors

class _Cand:
    def __init__(self, ok=True):
        self.ok = ok

    def available(self):
        return self.ok

    def describe(self):
        return "Fake"


def test_engine_choice_by_mode(monkeypatch):
    """Am PC automatisch an, wenn ein Motor gefunden wird; im gehosteten Dienst aus, ausser LERNAPP_OCR=on; off schaltet ab."""
    from app import config, pageocr
    pageocr.reset()
    found = _Cand(True)
    monkeypatch.setattr(pageocr, "TesseractOCR", lambda: found)
    try:
        monkeypatch.delenv("LERNAPP_OCR", raising=False)
        monkeypatch.delenv("LERNAPP_OCR_ENGINE", raising=False)
        monkeypatch.setattr(config, "MODE", "local")
        assert pageocr.mode() == "auto" and pageocr.engine() is found
        monkeypatch.setenv("LERNAPP_OCR", "off")
        assert pageocr.engine() is None
        monkeypatch.setenv("LERNAPP_OCR", "")
        monkeypatch.setattr(config, "MODE", "hosted")
        assert pageocr.engine() is None, "gehosteter Dienst: Standard aus (Serverlast)"
        monkeypatch.setenv("LERNAPP_OCR", "on")
        assert pageocr.mode() == "on" and pageocr.engine() is found
        # kein Motor gefunden: alles wie bisher
        monkeypatch.setattr(pageocr, "TesseractOCR", lambda: _Cand(False))
        monkeypatch.setenv("LERNAPP_OCR", "")
        monkeypatch.setattr(config, "MODE", "local")
        assert pageocr.engine() is None
        # Windows-Motor nur auf ausdruecklichen Wunsch
        monkeypatch.setattr(pageocr, "WindowsMediaOCR", lambda: found)
        monkeypatch.setenv("LERNAPP_OCR_ENGINE", "windows")
        assert pageocr.engine() is found
    finally:
        pageocr.reset()


def test_windows_engine_unavailable_off_windows():
    from app import pageocr
    if sys.platform != "win32":
        assert pageocr.WindowsMediaOCR.available() is False
        with pytest.raises(pageocr.OCRUnavailable):
            pageocr.WindowsMediaOCR().recognize("x.pdf", [1])


# ---------------------------------------------------------------- Tesseract ueber die Kommandozeile (Programm-Ersatz)

class FakeRenderer:
    def __init__(self, count=2):
        self.count = count

    @staticmethod
    def available():
        return True

    def pages(self, pdf_path, pages, cancel=None):
        for p in pages:
            if p <= self.count:
                yield p, 3, 2, bytes([0, 128, 255, 255, 128, 0])


@pytest.mark.skipif(os.name == "nt", reason="Programm-Ersatz ist ein Skript fuer Linux/macOS")
def test_tesseract_command_line(tmp_path):
    """Aufruf wie `tesseract <seite.pgm> stdout -l deu+eng --psm 3`; die Seite kommt als PGM (P5) an; Sprachen, die nicht
    installiert sind, fallen weg; ohne Sprachdaten ist der Motor nicht verfuegbar."""
    from app import pageocr
    log = tmp_path / "calls.json"
    exe = tmp_path / "tesseract"
    exe.write_text(f"""#!{sys.executable}
import json, sys
args = sys.argv[1:]
if "--list-langs" in args:
    sys.stderr.write("List of available languages in \\"/x/tessdata/\\" (3):\\neng\\nosd\\ndeu\\n")
    raise SystemExit(0)
calls = json.load(open({str(log)!r})) if __import__("os").path.exists({str(log)!r}) else []
head = open(args[0], "rb").read()[:20]
calls.append({{"args": args[1:], "head": head.decode("latin-1")}})
json.dump(calls, open({str(log)!r}, "w"))
sys.stdout.buffer.write("Maschenregel f\\u00fcr Schleifen\\n\\f".encode("utf-8"))
""")
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    t = pageocr.TesseractOCR(exe=str(exe), renderer=FakeRenderer(count=2))
    assert t.installed_languages() == ["eng", "osd", "deu"] and t.languages() == ["deu", "eng"] and t.available()
    out = t.recognize("egal.pdf", [1, 2, 3])
    assert out == {1: "Maschenregel für Schleifen", 2: "Maschenregel für Schleifen"}, "Seite 3 gibt es nicht"
    calls = json.loads(log.read_text())
    assert [c["args"] for c in calls] == [["stdout", "-l", "deu+eng", "--psm", "3"]] * 2
    assert calls[0]["head"].startswith("P5\n3 2\n255\n")
    # nur Englisch installiert: nur -l eng
    only_eng = pageocr.TesseractOCR(exe=str(exe), languages=("fra", "eng"), renderer=FakeRenderer())
    assert only_eng.languages() == ["eng"]
    # keine passende Sprache / kein Programm
    assert not pageocr.TesseractOCR(exe=str(exe), languages=("fra",), renderer=FakeRenderer()).available()
    assert not pageocr.TesseractOCR(exe=str(tmp_path / "gibt-es-nicht"), renderer=FakeRenderer()).available()
    # ein Fehler des Programms wirft (die Texte bleiben dann wie sie sind)
    bad = tmp_path / "tesseract-kaputt"
    bad.write_text(f"#!{sys.executable}\nimport sys\nif '--list-langs' in sys.argv: print('deu'); raise SystemExit(0)\nsys.stderr.write('Fehler'); raise SystemExit(1)\n")
    bad.chmod(bad.stat().st_mode | stat.S_IEXEC)
    with pytest.raises(RuntimeError):
        pageocr.TesseractOCR(exe=str(bad), renderer=FakeRenderer()).recognize("egal.pdf", [1])


def test_find_tesseract_env_and_bundle(tmp_path, monkeypatch):
    from app import pageocr
    exe = tmp_path / "mein-tesseract"
    exe.write_text("x")
    monkeypatch.setenv("LERNAPP_TESSERACT", str(exe))
    assert pageocr.find_tesseract() == str(exe)
    monkeypatch.setenv("LERNAPP_TESSERACT", str(tmp_path / "nicht-da"))
    assert pageocr.find_tesseract() is None
    monkeypatch.delenv("LERNAPP_TESSERACT")
    bundled = tmp_path / "tesseract"
    bundled.mkdir()
    (bundled / ("tesseract.exe" if os.name == "nt" else "tesseract")).write_text("x")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    assert Path(pageocr.find_tesseract()).parent == bundled


def test_png_and_pgm_bytes():
    from app import pageocr
    assert pageocr.pgm_bytes(3, 2, bytes(6)).startswith(b"P5\n3 2\n255\n") and len(pageocr.pgm_bytes(3, 2, bytes(6))) == 11 + 6
    png = pageocr.png_bytes(4, 2, bytes(range(8)))
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    pos, chunks = 8, {}
    while pos < len(png):
        n = int.from_bytes(png[pos:pos + 4], "big")
        tag, body = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + n]
        assert int.from_bytes(png[pos + 8 + n:pos + 12 + n], "big") == zlib.crc32(tag + body) & 0xFFFFFFFF
        chunks[tag] = body
        pos += 12 + n
    assert zlib.decompress(chunks[b"IDAT"]) == b"\x00\x00\x01\x02\x03\x00\x04\x05\x06\x07"


# ---------------------------------------------------------------- Rendern mit pypdfium2

@needs_pdfium
def test_pdfium_renders_gray_pages(tmp_path):
    from app import pageocr
    pdf = make_pdf(tmp_path / "r.pdf", [["Text auf Seite eins"], SCAN, None])
    r = pageocr.PdfiumRenderer(scale=1.0)
    got = list(r.pages(str(pdf), [1, 2, 3, 4]))
    assert [g[0] for g in got] == [1, 2, 3], "Seite 4 gibt es nicht"
    p, w, h, data = got[0]
    assert (w, h) == (595, 842) and len(data) == w * h and min(data) < 128 and max(data) == 255
    assert min(got[1][3]) < 200 and len(got[1][3]) == 595 * 842          # das Bild ist grau, nicht weiss
    assert set(got[2][3]) == {255}, "leere Seite: weisser Grund"
    big = list(pageocr.PdfiumRenderer(scale=10.0, max_pixels=1000).pages(str(pdf), [1]))[0]
    assert max(big[1], big[2]) == 1000, "sehr grosse Seiten werden auf max_pixels begrenzt"
    cancelled = pageocr.PdfiumRenderer(scale=1.0).pages(str(pdf), [1, 2], cancel=lambda: True)
    with pytest.raises(pageocr.OCRCancelled):
        list(cancelled)


@needs_pdfium
def test_pdfium_unreadable_file_raises(tmp_path):
    from app import pageocr
    bad = tmp_path / "kaputt.pdf"
    bad.write_bytes(b"das ist keine PDF")
    with pytest.raises(Exception):
        list(pageocr.PdfiumRenderer().pages(str(bad), [1]))


# ---------------------------------------------------------------- Echtes Tesseract (nur wenn installiert)

def _real_tesseract():
    from app import pageocr
    if importlib.util.find_spec("pypdfium2") is None or not shutil.which("tesseract"):
        return None
    t = pageocr.TesseractOCR()
    return t if t.available() else None


def _scan_pdf(path: Path, lines) -> Path:
    """Einseitige Bild-PDF (A4, 150 dpi) ohne Textebene: eine Text-PDF mit pypdfium2 rendern und das Bild als Seite einsetzen."""
    from app import pageocr
    src = make_pdf(path.with_suffix(".text.pdf"), [lines])
    _, w, h, data = next(pageocr.PdfiumRenderer(scale=150 / 72 * 2).pages(str(src), [1]))
    img = zlib.compress(data)
    objs = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
            b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</XObject<</Im1 5 0 R>>>>>>",
            b"<</Length 31>>stream\nq 595 0 0 842 0 0 cm /Im1 Do Q\nendstream",
            b"<</Type/XObject/Subtype/Image/Width %d/Height %d/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode/Length %d>>stream\n" % (w, h, len(img)) + img + b"\nendstream"]
    out, offs = bytearray(b"%PDF-1.4\n"), []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(b"%010d 00000 n \n" % o for o in offs) + b"trailer\n<</Size 6/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % x
    path.write_bytes(bytes(out))
    return path


@pytest.mark.skipif(_real_tesseract() is None, reason="tesseract oder pypdfium2 nicht installiert")
def test_real_tesseract_recognizes_scan(tmp_path):
    from app import pageocr
    pdf = _scan_pdf(tmp_path / "scan.pdf", ["Kirchhoffsche Maschenregel", "Die Summe aller Spannungen ist null."])
    from pypdf import PdfReader
    assert (PdfReader(str(pdf)).pages[0].extract_text() or "").strip() == "", "Bild-PDF ohne Textebene"
    found = _real_tesseract().recognize(str(pdf), [1, 2])
    assert "Kirchhoff" in found[1] and "Maschenregel" in found[1], found
    assert 2 not in found
