"""Textextraktion aus heruntergeladenen Dateien (fuer die KI-Analyse, die Suche und die Seitentexte).

Seit 04.11.2026 (docs/DATEIARTEN.md) auch Word (.docx) und PowerPoint (.pptx) nur mit der Standardbibliothek
(zipfile, xml.etree): das Swift-Gegenstueck `OfficeText` im Kern liefert auf denselben Dateien dieselben Seiten
(packages/shared-contracts/fixtures/office-text). Nie geht die Datei selbst an eine KI, nur der Text.

- docx: Absaetze in Dokumentreihenfolge (auch Tabellenzellen), Tabulator und Zeilenumbruch im Absatz; Seiten entstehen
  an Ueberschriften ab SOFT_PAGE_CHARS Zeichen, spaetestens nach HARD_PAGE_CHARS Zeichen und an echten Seitenumbruechen.
- pptx: jede Folie eine Seite in der Reihenfolge der Praesentation, Platzhalter fuer Foliennummer, Datum, Kopf- und
  Fusszeile ausgelassen, die Notizen der Folie als Anhang ("Notizen:").
"""
from __future__ import annotations

import io
import re
import zipfile
import zlib
import xml.etree.ElementTree as ET
from pathlib import Path

from .config import TEXT_EXTENSIONS

MAX_CHARS = 14000
#: Seiten eines Word-Dokuments: neue Seite an einer Ueberschrift ab so vielen Zeichen ...
SOFT_PAGE_CHARS = 3000
#: ... und spaetestens vor dem Absatz, mit dem diese Zahl erreicht ist (Dokumente ohne Ueberschriften)
HARD_PAGE_CHARS = 6000
#: Dateien, deren Seitentexte Suche, Skriptsuche, KI-Hilfe und Wochentests nutzen (wie PDF)
TEXT_SOURCE_SUFFIXES = (".pdf", ".docx", ".pptx")
#: Art fuer `kind` in Antworten (/pagetext, Seitentreffer der Suche); Audio nur auf dem iPad (Transkript)
KINDS = {".pdf": "pdf", ".docx": "docx", ".pptx": "pptx", ".mp3": "audio", ".m4a": "audio"}
#: Grenzen gegen Dekompressionsbomben (Sicherheitspruefung 04.11.2026): je gelesener Teil-Datei entpackt, je Archiv
#: entpackt (alle gelesenen Teile zusammen), Eintraege im Archiv und Folien je Praesentation. Gelesen wird stueckweise
#: und gegen die Grenze gezaehlt, nicht nach der (faelschbaren) Groesse im Kopf des Eintrags.
MAX_ZIP_ENTRY = 40 << 20
MAX_ZIP_TOTAL = 200 << 20
MAX_ZIP_ENTRIES = 20_000
MAX_SLIDES = 2_000
_ZIP_CHUNK = 1 << 20
#: Fehler beim Entpacken oder Parsen, die eine Datei "nicht lesbar" machen (nie ein Absturz des Aufrufers)
_UNREADABLE = (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error, EOFError, RuntimeError, ET.ParseError)

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
MC = "{http://schemas.openxmlformats.org/markup-compatibility/2006}"
R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PR = "{http://schemas.openxmlformats.org/package/2006/relationships}"
HEADING_STYLE = re.compile(r"^(heading|berschrift|überschrift|title|titel)", re.I)
#: Platzhalter ohne Inhalt der Folie (Foliennummer, Datum, Kopf- und Fusszeile)
SKIP_PLACEHOLDERS = {"sldNum", "dt", "ftr", "hdr"}


def text_kind(name: str | None) -> str | None:
    """pdf | docx | pptx | audio zu einem Dateinamen, sonst None."""
    return KINDS.get(Path(name or "").suffix.lower())


def is_text_source(name: str | None) -> bool:
    """Liefert die Datei Seitentexte (PDF, Word, PowerPoint)?"""
    return (name or "").lower().endswith(TEXT_SOURCE_SUFFIXES)


def pages_from_paragraphs(paragraphs: list[str], headings: set[int] | None = None, breaks: set[int] | None = None) -> list[str]:
    """Seiten aus Absaetzen (Text je Absatz, Zeilen mit \\n): `headings` sind die Indizes der Ueberschriften, `breaks`
    die der Absaetze, vor denen ein echter Seitenumbruch steht. Leere Absaetze fallen weg. Regel: neue Seite vor einer
    Ueberschrift, wenn die Seite schon SOFT_PAGE_CHARS Zeichen hat; vor jedem Absatz, wenn sie HARD_PAGE_CHARS hat;
    vor einem Seitenumbruch immer (wenn die Seite nicht leer ist)."""
    headings = headings or set()
    breaks = breaks or set()
    pages: list[str] = []
    cur: list[str] = []
    size = 0
    for i, raw in enumerate(paragraphs):
        t = raw.strip()
        if not t:
            continue
        if cur and (i in breaks or size >= HARD_PAGE_CHARS or (i in headings and size >= SOFT_PAGE_CHARS)):
            pages.append("\n".join(cur))
            cur, size = [], 0
        cur.append(t)
        size += len(t) + 1
    if cur:
        pages.append("\n".join(cur))
    return pages


class _Archive:
    """OOXML-Paket (Zip) mit Grenzen: hoechstens MAX_ZIP_ENTRIES Eintraege, je gelesener Teil-Datei MAX_ZIP_ENTRY und je
    Archiv MAX_ZIP_TOTAL entpackte Bytes. Namen im Archiv sind nur Schluessel fuer `getinfo`; nichts wird auf die
    Platte geschrieben, ein Name wie "../x" kann also nirgends hinfuehren."""

    def __init__(self, data: bytes):
        self.z = zipfile.ZipFile(io.BytesIO(data))
        if len(self.z.namelist()) > MAX_ZIP_ENTRIES:
            raise ValueError("Archiv mit zu vielen Eintraegen")
        self.left = MAX_ZIP_TOTAL

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.z.close()

    def names(self) -> list[str]:
        return self.z.namelist()

    def read(self, name: str) -> bytes | None:
        try:
            info = self.z.getinfo(name)
        except KeyError:
            return None
        if info.file_size > MAX_ZIP_ENTRY or info.compress_size > MAX_ZIP_ENTRY:
            raise ValueError("Eintrag zu gross")
        cap = min(MAX_ZIP_ENTRY, self.left)
        parts: list[bytes] = []
        n = 0
        with self.z.open(info) as f:
            while True:
                chunk = f.read(_ZIP_CHUNK)
                if not chunk:
                    break
                n += len(chunk)
                if n > cap:
                    raise ValueError("Eintrag zu gross" if n > MAX_ZIP_ENTRY else "Archiv entpackt zu gross")
                parts.append(chunk)
        self.left -= n
        return b"".join(parts)


def _read_entry(z: _Archive, name: str) -> bytes | None:
    return z.read(name)


def _rels(z: _Archive, name: str) -> dict[str, tuple[str, str]]:
    """Beziehungen einer Teil-Datei: Id -> (Type, Target)."""
    data = _read_entry(z, name)
    if not data:
        return {}
    out = {}
    for el in ET.fromstring(data).iter(PR + "Relationship"):
        out[el.get("Id", "")] = (el.get("Type", ""), el.get("Target", ""))
    return out


def _resolve(base_dir: str, target: str) -> str:
    """Ziel einer Beziehung relativ zur Teil-Datei ("../slides/slide1.xml" neben ppt/_rels -> ppt/slides/slide1.xml)."""
    if target.startswith("/"):
        base_dir, target = "", target.lstrip("/")
    parts = [p for p in base_dir.split("/") if p]
    for seg in target.split("/"):
        if seg == "..":
            if parts:
                parts.pop()
        elif seg and seg != ".":
            parts.append(seg)
    return "/".join(parts)


class _Paragraphs:
    """Absaetze aus einem OOXML-Teil, ereignisgesteuert (wie `XMLParser` im Kern): Text gehoert zum innersten offenen
    Absatz, Tabulator und Zeilenumbruch werden Zeichen, `mc:Fallback` (zweite Fassung desselben Inhalts) und
    ausgelassene Platzhalter zaehlen nicht."""

    def __init__(self, p_tag: str, t_tag: str, tab_tag: str | None, br_tag: str, style_tag: str | None):
        self.p_tag, self.t_tag, self.tab_tag, self.br_tag, self.style_tag = p_tag, t_tag, tab_tag, br_tag, style_tag
        self.paragraphs: list[str] = []
        self.headings: set[int] = set()
        self.breaks: set[int] = set()

    def parse(self, data: bytes) -> None:
        stack: list[list[str]] = []          # offene Absaetze (Textstuecke)
        heading: list[bool] = []
        fallback = 0
        skip_shape = 0                        # Tiefe des Formelements, dessen Platzhalter uebergangen wird
        depth = 0
        shape_depth: list[int] = []
        pending_break = False
        parser = ET.XMLPullParser(events=("start", "end"))
        parser.feed(data)
        for event, el in parser.read_events():
            tag = el.tag
            if event == "start":
                depth += 1
                if tag == MC + "Fallback":
                    fallback += 1
                elif tag == P + "sp":
                    shape_depth.append(depth)
                elif tag == P + "ph" and shape_depth and not skip_shape and el.get("type") in SKIP_PLACEHOLDERS:
                    skip_shape = shape_depth[-1]
                elif tag == self.p_tag:
                    stack.append([])
                    heading.append(False)
                continue
            # end
            if fallback == 0 and skip_shape == 0:
                if tag == self.t_tag and stack:
                    stack[-1].append(el.text or "")
                elif tag == self.tab_tag and stack:
                    stack[-1].append("\t")
                elif tag == self.br_tag and stack:
                    if el.get(W + "type") == "page":
                        pending_break = True
                    else:
                        stack[-1].append("\n")
                elif tag == self.style_tag and stack and HEADING_STYLE.match(el.get(W + "val") or ""):
                    heading[-1] = True
                elif tag == W + "outlineLvl" and stack:
                    heading[-1] = True
                elif tag == self.p_tag and stack:
                    text = "".join(stack.pop())
                    h = heading.pop()
                    if text.strip():
                        i = len(self.paragraphs)
                        if pending_break:
                            self.breaks.add(i)
                            pending_break = False
                        if h:
                            self.headings.add(i)
                        self.paragraphs.append(text)
                    elif pending_break:
                        pass        # Umbruch gilt fuer den naechsten Absatz mit Text
            elif tag == self.p_tag and stack and (fallback or skip_shape):
                stack.pop()
                heading.pop()
            if tag == MC + "Fallback":
                fallback -= 1
            elif tag == P + "sp":
                if shape_depth and shape_depth[-1] == skip_shape:
                    skip_shape = 0
                if shape_depth:
                    shape_depth.pop()
            depth -= 1
            el.clear()


def docx_pages(data: bytes) -> list[str]:
    """Seiten eines Word-Dokuments (siehe Modulkopf); [] ohne Text, ValueError bei kaputter Datei."""
    try:
        with _Archive(data) as z:
            doc = _read_entry(z, "word/document.xml")
            if doc is None:
                raise ValueError("word/document.xml fehlt")
            ps = _Paragraphs(W + "p", W + "t", W + "tab", W + "br", W + "pStyle")
            ps.parse(doc)
    except _UNREADABLE as e:
        raise ValueError(f"Word-Datei nicht lesbar: {e}") from e
    return pages_from_paragraphs(ps.paragraphs, ps.headings, ps.breaks)


def pptx_pages(data: bytes) -> list[str]:
    """Seiten einer PowerPoint-Datei: je Folie der Text ihrer Formen, dahinter die Notizen; eine Folie ohne Text bleibt
    eine leere Seite (die Seitenzahl ist die Foliennummer)."""
    try:
        with _Archive(data) as z:
            pres = _read_entry(z, "ppt/presentation.xml")
            if pres is None:
                raise ValueError("ppt/presentation.xml fehlt")
            rels = _rels(z, "ppt/_rels/presentation.xml.rels")
            slides: list[str] = []
            for sid in ET.fromstring(pres).iter(P + "sldId"):
                rel = rels.get(sid.get(R + "id", ""))
                if rel and rel[0].endswith("/slide"):
                    slides.append(_resolve("ppt", rel[1]))
            if not slides:      # ohne Liste: slide1.xml, slide2.xml ... in Nummernreihenfolge
                names = [n for n in z.names() if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)]
                slides = sorted(names, key=lambda n: int(re.search(r"(\d+)\.xml$", n).group(1)))
            if len(slides) > MAX_SLIDES:
                raise ValueError(f"zu viele Folien (hoechstens {MAX_SLIDES})")
            pages = []
            for slide in slides:
                body = _slide_text(z, slide)
                srels = _rels(z, slide.rsplit("/", 1)[0] + "/_rels/" + slide.rsplit("/", 1)[1] + ".rels")
                notes = ""
                for typ, target in srels.values():
                    if typ.endswith("/notesSlide"):
                        notes = _slide_text(z, _resolve(slide.rsplit("/", 1)[0], target))
                        break
                pages.append(body + ("\n\nNotizen:\n" + notes if notes else "") if body or notes else "")
    except _UNREADABLE as e:
        raise ValueError(f"PowerPoint-Datei nicht lesbar: {e}") from e
    return pages


def _slide_text(z: _Archive, name: str) -> str:
    data = _read_entry(z, name)
    if data is None:
        return ""
    ps = _Paragraphs(A + "p", A + "t", None, A + "br", None)
    ps.parse(data)
    return "\n".join(p.strip() for p in ps.paragraphs if p.strip())


def office_pages(path: str | Path) -> list[str] | None:
    """Seitentexte einer Word- oder PowerPoint-Datei auf der Platte; None fuer andere Dateien oder wenn sie sich nicht
    lesen laesst (wie `page_texts` bei einer kaputten PDF: keine Seiten)."""
    p = Path(path)
    suffix = p.suffix.lower()
    if suffix not in (".docx", ".pptx"):
        return None
    try:
        return office_pages_bytes(p.read_bytes(), suffix)
    except (OSError, ValueError):
        return None


def office_pages_bytes(data: bytes, suffix: str) -> list[str]:
    return docx_pages(data) if suffix == ".docx" else pptx_pages(data)


def _joined(pages: list[str], total: int, max_chars: int) -> str:
    parts: list[str] = []
    used = 0
    for i, t in enumerate(pages):
        parts.append(f"--- Seite {i + 1} ---\n{t}")
        used += len(t)
        if used > max_chars:
            break
    text = "\n".join(parts)
    return text[:max_chars] + (f"\n[... gekuerzt, insgesamt {total} Seiten]" if len(text) > max_chars else "")


def extract_text(path: str | Path, max_chars: int = MAX_CHARS) -> str:
    p = Path(path)
    if not p.exists() or p.suffix.lower() not in TEXT_EXTENSIONS:
        return ""
    try:
        if p.suffix.lower() == ".pdf":
            from pypdf import PdfReader

            reader = PdfReader(str(p))
            pages = []
            total = 0
            for page in reader.pages:
                t = page.extract_text() or ""
                pages.append(t)
                total += len(t)
                if total > max_chars:
                    break
            return _joined(pages, len(reader.pages), max_chars)
        if p.suffix.lower() in (".docx", ".pptx"):
            pages = office_pages_bytes(p.read_bytes(), p.suffix.lower())
            return _joined(pages, len(pages), max_chars)
        return p.read_text(encoding="utf-8", errors="replace")[:max_chars]
    except Exception as e:  # noqa: BLE001
        return f"[Textextraktion fehlgeschlagen: {e}]"


def page_count(path: str | Path) -> int | None:
    p = Path(path)
    if not p.exists():
        return None
    if p.suffix.lower() in (".docx", ".pptx"):
        pages = office_pages(p)
        return len(pages) if pages else None
    if p.suffix.lower() != ".pdf":
        return None
    try:
        from pypdf import PdfReader

        return len(PdfReader(str(p)).pages)
    except Exception:  # noqa: BLE001
        return None
