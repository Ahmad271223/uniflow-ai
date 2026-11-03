"""Texterkennung (OCR) fuer PDF-Seiten ohne Textebene (Scans, abfotografierte Blaetter, Folien als Bild), Windows und Web.

Gegenstueck zu apps/apple/Packages/UniFlowCore/.../Search/PageOCR.swift (iPad, Apple Vision); das Verhalten ist
dasselbe, Regeln und Grenzwerte stehen in packages/shared-contracts/fixtures/ocr/rules.json (tools/gen-ocr-fixture.py):

- Die eingebettete Textebene bleibt die erste Wahl. Erkannt wird nur eine Seite, deren Textebene "fast leer" ist
  (weniger als MINIMUM_LETTERS Buchstaben), und nur, wenn ihr Text gebraucht wird (Scope: keine / bestimmte Seiten /
  die ersten n / alle), nie beim blossen Oeffnen fuer alle Seiten.
- Stapel von BATCH_SIZE Seiten; nach jedem Stapel wird gespeichert (ein Abbruch verliert hoechstens diese Seiten).
- Ergebnis je Datei, Seite und Aenderungszeit in `page_ocr` (file_id, page, chdate, embedded, text), einmal; "" heisst
  "nichts erkannt" und wird nicht wiederholt. Ein erkannter Text ersetzt den fast leeren Text in `page_texts` (mit
  Suchform), aber nur, wenn er mehr Buchstaben hat als die Textebene.
- Eine neue Fassung der Datei (andere Aenderungszeit, scriptsearch.store_pages) verwirft die Ergebnisse. Die
  Seitenzuordnung einer neuen Fassung vergleicht Textebene mit Textebene (`embedded`).
- Ein Fehler der Erkennung laesst die Texte unveraendert (der naechste Bedarf versucht es erneut); Abbruch ueber
  `cancel` (OCRCancelled).

Motor austauschbar (Protokoll `PageOCR`): `TesseractOCR` (Kommandozeile, Deutsch + Englisch, nur wenn installiert) oder
`WindowsMediaOCR` (Windows.Media.Ocr, UNGEPRUEFT, nur auf ausdruecklichen Wunsch). Die Seiten werden mit pypdfium2
(BSD-3/Apache-2.0) als Graustufenbild gerendert; fehlt es, gibt es keinen Motor. Ohne Motor bleibt alles wie bisher.

Schalter LERNAPP_OCR: on / off / (leer = automatisch). Automatisch: am PC an, wenn ein Motor gefunden wird; im
gehosteten Dienst aus (Serverlast). LERNAPP_OCR_ENGINE: tesseract (Standard) oder windows. Siehe docs/OCR-WINDOWS.md.
"""
from __future__ import annotations

import inspect
import logging
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unicodedata
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Protocol, runtime_checkable

from . import config, db

log = logging.getLogger("uniflow.pageocr")

MINIMUM_LETTERS = 20      # "fast leer": weniger Buchstaben als das (Seitenzahl, Kopfzeile, einzelnes Wort bleiben darunter)
BATCH_SIZE = 4            # so viele Seiten je Erkennung, danach wird gespeichert
RENDER_SCALE = 4.0        # Faktor zur PDF-Groesse in Punkten (72 dpi): 4 = 288 dpi, Tesseract mag etwa 300 dpi
MAX_PIXELS = 4000         # laengste Bildseite (A4 bei 4x: 3368); ein Poster wird verkleinert statt Hunderte MB zu belegen
LANGUAGES = ("deu", "eng")  # Deutsch zuerst (Umlaute und ss)
PAGE_TIMEOUT = 180        # Sekunden je Seite fuer das Programm

TABLE_SQL = """CREATE TABLE IF NOT EXISTS page_ocr (
    file_id TEXT NOT NULL,
    page INTEGER NOT NULL,
    chdate INTEGER,
    embedded TEXT,                     -- Textebene der Seite vor der Erkennung
    text TEXT,                         -- erkannter Text ("" = nichts erkannt)
    PRIMARY KEY (file_id, page))"""


class OCRCancelled(Exception):
    """Die Erkennung wurde abgebrochen (`cancel` lieferte True)."""


class OCRUnavailable(Exception):
    """Der Motor kann nicht arbeiten (Programm, Sprache oder Renderer fehlt)."""


# ---------------------------------------------------------------- Regeln (rein, ohne Datenbank)

def letters(text: str) -> int:
    """Buchstaben eines Textes (Unicode, auch Umlaute); wie Swifts CharacterSet.letters: Kategorien L* und M*."""
    return sum(1 for ch in text or "" if unicodedata.category(ch)[0] in "LM")


def is_sparse(text: str) -> bool:
    return letters(text) < MINIMUM_LETTERS


def accepts(embedded: str, recognized: str) -> bool:
    """Ersetzt der erkannte Text die Textebene? Nur bei mehr Buchstaben."""
    return letters(recognized) > letters(embedded)


def batches(todo: list[int]) -> list[list[int]]:
    return [todo[i:i + BATCH_SIZE] for i in range(0, len(todo), BATCH_SIZE)]


@dataclass(frozen=True)
class Scope:
    """Welche Seiten `scriptsearch.page_texts` bei fast leerer Textebene erkennen darf (wie OCRScope in Swift)."""
    kind: str = "none"            # none | pages | leading | all
    pages: frozenset = frozenset()
    count: int = 0

    @staticmethod
    def none() -> "Scope":
        """keine (Hintergrund ueber viele Dateien, z. B. Abgaben nachlesen, Seitenzuordnung einer neuen Fassung)"""
        return Scope("none")

    @staticmethod
    def only(*pages: int) -> "Scope":
        """nur diese Seiten (1-basiert), z. B. die offene Seite fuer die KI-Hilfe"""
        return Scope("pages", frozenset(int(p) for p in pages))

    @staticmethod
    def leading(n: int) -> "Scope":
        """die ersten n Seiten (Auszug fuer einen Test)"""
        return Scope("leading", count=int(n))

    @staticmethod
    def all() -> "Scope":
        """alle Seiten (Wochentests, Index der Skriptsuche)"""
        return Scope("all")

    def contains(self, page: int) -> bool:
        if self.kind == "pages":
            return page in self.pages
        if self.kind == "leading":
            return page <= self.count
        return self.kind == "all"

    @property
    def is_none(self) -> bool:
        return self.kind == "none"


def map_embedded(rows: list[dict], pages: list[str]) -> list[str]:
    """Textebene statt erkanntem Text: eine Zeile von `page_ocr` gilt nur, wenn die Seite noch genau den erkannten Text
    traegt (nicht leer)."""
    out = list(pages)
    for r in rows:
        p, t = r.get("page"), r.get("text")
        if not isinstance(p, int) or not 1 <= p <= len(out) or not t or out[p - 1] != t:
            continue
        out[p - 1] = r.get("embedded") or ""
    return out


# ---------------------------------------------------------------- Tabelle page_ocr

def ensure_table(conn) -> None:
    conn.execute(TABLE_SQL)


def has_table(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_ocr'").fetchone() is not None


def delete(conn, file_id: str) -> None:
    """Ergebnisse einer Datei verwerfen (neue Seitentexte, neue Fassung, Demo entfernt); legt die Tabelle nicht an."""
    if has_table(conn):
        conn.execute("DELETE FROM page_ocr WHERE file_id=?", (file_id,))


def embedded(conn, file_id: str, pages: list[str]) -> list[str]:
    """Textebene der Seiten (ohne erkannten Text): fuer die Seitenzuordnung einer neuen Fassung und die Dokumentversion."""
    if not has_table(conn):
        return list(pages)
    return map_embedded(db.rows(conn, "SELECT page, embedded, text FROM page_ocr WHERE file_id=?", (file_id,)), pages)


# ---------------------------------------------------------------- Motor

@runtime_checkable
class PageOCR(Protocol):
    """Erkennung der Seiten einer PDF. `pages` sind 1-basiert; eine Seite ohne erkannten Text fehlt oder ist ""."""

    def recognize(self, pdf_path: str, pages: list[int]) -> dict[int, str]:
        """Wirft, wenn sich die Datei nicht lesen laesst oder der Motor scheitert (dann bleiben die Texte wie sie sind)."""


def pgm_bytes(width: int, height: int, data: bytes) -> bytes:
    """Graustufenbild als binaeres PGM (P5): Tesseract/Leptonica liest es ohne Pillow."""
    return b"P5\n%d %d\n255\n" % (width, height) + data


def png_bytes(width: int, height: int, data: bytes) -> bytes:
    """Graustufenbild als PNG (8 Bit), ohne Bibliothek; fuer Windows.Media.Ocr und fuer Test-Scans."""
    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + data[y * width:(y + 1) * width] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


class PdfiumRenderer:
    """Seiten mit pypdfium2 als Graustufenbild rendern (weisser Grund, Drehung beachtet). Jede Seite einzeln; das Bild
    wird gleich wieder freigegeben. Lizenz: pypdfium2 BSD-3-Clause/Apache-2.0, PDFium BSD-3 (kein Copyleft)."""

    def __init__(self, scale: float = RENDER_SCALE, max_pixels: int = MAX_PIXELS):
        self.scale, self.max_pixels = scale, max_pixels

    @staticmethod
    def available() -> bool:
        try:
            import pypdfium2  # noqa: F401
            return True
        except Exception:  # noqa: BLE001 - nicht installiert oder Bibliothek nicht ladbar
            return False

    def open(self, pdf_path: str):
        import pypdfium2 as pdfium
        return pdfium.PdfDocument(pdf_path)

    def render(self, doc, index: int) -> tuple[int, int, bytes]:
        """(Breite, Hoehe, Grauwerte Zeile fuer Zeile) der Seite `index` (0-basiert)."""
        page = doc[index]
        try:
            w, h = page.get_size()
            scale = min(self.scale, self.max_pixels / max(w, h, 1.0))
            bitmap = page.render(scale=scale, grayscale=True)
            try:
                width, height, stride = bitmap.width, bitmap.height, bitmap.stride
                buf = bytes(bitmap.buffer)
            finally:
                bitmap.close()
        finally:
            page.close()
        if stride != width:                       # Zeilen sind auf eine Breite aufgefuellt
            buf = b"".join(buf[y * stride:y * stride + width] for y in range(height))
        return width, height, buf

    def pages(self, pdf_path: str, pages: list[int], cancel: Optional[Callable[[], bool]] = None):
        """Erzeugt (Seite, Breite, Hoehe, Bytes) fuer die vorhandenen Seiten; eine Seite, die es nicht gibt, fehlt."""
        doc = self.open(pdf_path)
        try:
            count = len(doc)
            for p in pages:
                if cancel and cancel():
                    raise OCRCancelled()
                if 1 <= p <= count:
                    yield (p, *self.render(doc, p - 1))
        finally:
            doc.close()


def _no_window() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


def _bundled_dirs() -> list[Path]:
    """Ordner `tesseract` neben der exe bzw. im PyInstaller-Paket (siehe docs/OCR-WINDOWS.md)."""
    out = []
    for base in (getattr(sys, "_MEIPASS", None), Path(sys.executable).parent if getattr(sys, "frozen", False) else None):
        if base:
            out.append(Path(base) / "tesseract")
    return out


def find_tesseract() -> Optional[str]:
    """Pfad der tesseract-Programmdatei: LERNAPP_TESSERACT, Ordner `tesseract` im Paket, PATH, Standardordner von Windows."""
    env = (os.environ.get("LERNAPP_TESSERACT") or "").strip()
    if env:
        return env if Path(env).is_file() else None
    names = ("tesseract.exe", "tesseract") if os.name == "nt" else ("tesseract",)
    for d in _bundled_dirs():
        for n in names:
            if (d / n).is_file():
                return str(d / n)
    found = shutil.which("tesseract")
    if found:
        return found
    if os.name == "nt":
        for root in (os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")):
            if root and (Path(root) / "Tesseract-OCR" / "tesseract.exe").is_file():
                return str(Path(root) / "Tesseract-OCR" / "tesseract.exe")
    return None


def _tessdata_dir(exe: str) -> Optional[str]:
    """tessdata neben dem gebuendelten Programm (sonst gilt TESSDATA_PREFIX bzw. der Standard des Programms)."""
    if os.environ.get("TESSDATA_PREFIX"):
        return None
    d = Path(exe).parent / "tessdata"
    return str(d) if d.is_dir() else None


class TesseractOCR:
    """Tesseract ueber die Kommandozeile: `tesseract <seite.pgm> stdout -l deu+eng`. Gebraucht werden das Programm und
    mindestens `eng.traineddata` (besser `deu`); Seiten rendert `renderer` (pypdfium2). Programm nur starten, nicht
    einbinden: die Lizenz (Apache-2.0) verlangt dann nur den Hinweistext im Paket."""

    name = "tesseract"

    def __init__(self, exe: Optional[str] = None, languages: tuple = LANGUAGES, renderer=None, timeout: int = PAGE_TIMEOUT):
        self.exe = exe or find_tesseract()
        self.wanted = tuple(languages)
        self.renderer = renderer if renderer is not None else PdfiumRenderer()
        self.timeout = timeout
        self._langs: Optional[list[str]] = None

    def _run(self, args: list[str], timeout: int):
        env = dict(os.environ)
        env.setdefault("OMP_THREAD_LIMIT", "1")       # ein Kern je Seite; mehrere Seiten laufen nicht gleichzeitig
        return subprocess.run([self.exe, *args], capture_output=True, timeout=timeout, creationflags=_no_window(), env=env)

    def installed_languages(self) -> list[str]:
        if self._langs is None:
            self._langs = []
            if self.exe:
                try:
                    extra = ["--tessdata-dir", d] if (d := _tessdata_dir(self.exe)) else []
                    r = self._run([*extra, "--list-langs"], 30)
                    lines = (r.stdout + b"\n" + r.stderr).decode("utf-8", "replace").splitlines()   # alte Fassungen schreiben auf stderr
                    self._langs = [ln.strip() for ln in lines if ln.strip() and not ln.startswith("List of") and ":" not in ln]
                except Exception as e:  # noqa: BLE001
                    log.warning("tesseract --list-langs gescheitert: %s", e)
        return self._langs

    def languages(self) -> list[str]:
        have = set(self.installed_languages())
        return [lang for lang in self.wanted if lang in have]

    def available(self) -> bool:
        return bool(self.exe) and bool(self.languages()) and getattr(self.renderer, "available", lambda: True)()

    def describe(self) -> str:
        return f"Tesseract ({self.exe}; Sprachen {'+'.join(self.languages()) or 'keine'})"

    def recognize(self, pdf_path: str, pages: list[int], cancel: Optional[Callable[[], bool]] = None) -> dict[int, str]:
        langs = self.languages()
        if not self.exe or not langs:
            raise OCRUnavailable("Tesseract oder seine Sprachdaten fehlen.")
        extra = ["--tessdata-dir", d] if (d := _tessdata_dir(self.exe)) else []
        out: dict[int, str] = {}
        with tempfile.TemporaryDirectory(prefix="uniflow-ocr-") as tmp:
            image = Path(tmp) / "seite.pgm"
            for p, w, h, data in self.renderer.pages(pdf_path, pages, cancel):
                image.write_bytes(pgm_bytes(w, h, data))
                r = self._run([str(image), "stdout", "-l", "+".join(langs), "--psm", "3", *extra], self.timeout)
                if r.returncode != 0:
                    raise RuntimeError(f"tesseract Rueckgabe {r.returncode}: {r.stderr.decode('utf-8', 'replace')[:200]}")
                out[p] = r.stdout.decode("utf-8", "replace").replace("\f", "").strip()
        return out


class WindowsMediaOCR:
    """Windows.Media.Ocr (in Windows eingebaut, nichts mitzuliefern). UNGEPRUEFT: nie auf Windows gelaufen, hier nur
    als Schnittstelle. Braucht die Pakete `winrt-Windows.Media.Ocr`, `winrt-Windows.Graphics.Imaging`,
    `winrt-Windows.Storage.Streams`, `winrt-Windows.Globalization` (pip, Windows). Wird nie von selbst gewaehlt, nur mit
    LERNAPP_OCR_ENGINE=windows. Die Seitenbilder sind auf OcrEngine.MaxImageDimension (2600 Pixel) begrenzt."""

    name = "windows"
    MAX_DIMENSION = 2600

    def __init__(self, language: str = "de", renderer=None):
        self.language = language
        self.renderer = renderer if renderer is not None else PdfiumRenderer(scale=3.0, max_pixels=self.MAX_DIMENSION)

    @staticmethod
    def available() -> bool:
        if sys.platform != "win32":
            return False
        try:
            import winrt.windows.media.ocr  # noqa: F401
            return PdfiumRenderer.available()
        except Exception:  # noqa: BLE001
            return False

    def describe(self) -> str:
        return f"Windows-Texterkennung ({self.language}, ungeprueft)"

    def recognize(self, pdf_path: str, pages: list[int], cancel: Optional[Callable[[], bool]] = None) -> dict[int, str]:
        if not self.available():
            raise OCRUnavailable("Windows.Media.Ocr ist hier nicht verfuegbar.")
        import asyncio
        out: dict[int, str] = {}
        for p, w, h, data in self.renderer.pages(pdf_path, pages, cancel):
            out[p] = asyncio.run(self._recognize_png(png_bytes(w, h, data))).strip()
        return out

    async def _recognize_png(self, png: bytes) -> str:
        from winrt.windows.globalization import Language
        from winrt.windows.graphics.imaging import BitmapDecoder
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream
        engine = OcrEngine.try_create_from_language(Language(self.language)) or OcrEngine.try_create_from_user_profile_languages()
        if engine is None:
            raise OCRUnavailable("Keine Sprache fuer die Windows-Texterkennung installiert.")
        stream = InMemoryRandomAccessStream()
        writer = DataWriter(stream)
        writer.write_bytes(png)
        await writer.store_async()
        await writer.flush_async()
        stream.seek(0)
        decoder = await BitmapDecoder.create_async(stream)
        bitmap = await decoder.get_software_bitmap_async()
        result = await engine.recognize_async(bitmap)
        return "\n".join(line.text for line in result.lines)


# ---------------------------------------------------------------- Wahl des Motors

_ENGINE_LOCK = threading.Lock()
_engine_override: Optional[object] = None      # fuer Tests / Einbettung: set_engine()
_engine_override_set = False
_engine_cache: tuple = ()                      # (Schluessel, Motor oder None)


def mode() -> str:
    """on / off / auto aus LERNAPP_OCR."""
    v = (os.environ.get("LERNAPP_OCR") or "").strip().lower()
    if v in ("on", "1", "true", "ja", "an"):
        return "on"
    if v in ("off", "0", "false", "nein", "aus"):
        return "off"
    return "auto"


def set_engine(engine) -> None:
    """Motor fest setzen (Tests, Einbettung); None = Wahl aus Umgebung/Suche wie ohne Aufruf."""
    global _engine_override, _engine_override_set, _engine_cache
    with _ENGINE_LOCK:
        _engine_override, _engine_override_set, _engine_cache = engine, engine is not None, ()


def reset() -> None:
    set_engine(None)


def engine() -> Optional[PageOCR]:
    """Der Motor, der jetzt gilt, oder None (aus, gehosteter Dienst ohne `on`, kein Motor gefunden). Gefunden wird einmal
    je Schalterstellung und Prozess."""
    global _engine_cache
    with _ENGINE_LOCK:
        if _engine_override_set:
            return _engine_override
        m = mode()
        if m == "off" or (m == "auto" and config.is_hosted()):
            return None
        pref = (os.environ.get("LERNAPP_OCR_ENGINE") or "tesseract").strip().lower()
        key = (m, pref, os.environ.get("LERNAPP_TESSERACT"))
        if _engine_cache and _engine_cache[0] == key:
            return _engine_cache[1]
        found = None
        try:
            cand = WindowsMediaOCR() if pref == "windows" else TesseractOCR()
            if cand.available():
                found = cand
                log.info("Texterkennung: %s", cand.describe())
            else:
                log.info("Texterkennung: kein Motor gefunden (%s)", pref)
        except Exception as e:  # noqa: BLE001
            log.warning("Texterkennung nicht verfuegbar: %s", e)
        _engine_cache = (key, found)
        return found


def active() -> bool:
    return engine() is not None


# ---------------------------------------------------------------- Erkennen und speichern

_FILE_LOCKS: dict[str, threading.Lock] = {}
_FILE_LOCKS_GUARD = threading.Lock()
_SLOTS = threading.BoundedSemaphore(max(1, int(os.environ.get("LERNAPP_OCR_JOBS") or 2)))   # gleichzeitige Erkennungen


def _file_lock(file_id: str) -> threading.Lock:
    with _FILE_LOCKS_GUARD:
        return _FILE_LOCKS.setdefault(file_id, threading.Lock())


def _check(cancel) -> None:
    if cancel and cancel():
        raise OCRCancelled()


def fill(conn, file_id: str, pages: list[str], scope: Scope, ocr: PageOCR, cancel: Optional[Callable[[], bool]] = None,
         on_change: Optional[Callable[[], None]] = None) -> list[str]:
    """Fast leere Seiten in `scope` erkennen, die noch nicht erkannt wurden, und speichern; `pages` sind die Texte aus
    `page_texts`. Nur fuer eine lokale PDF derselben Aenderungszeit. Fehler der Erkennung lassen die Texte wie sie sind;
    ein Abbruch wirft OCRCancelled. `on_change` wird gerufen, wenn page_texts geaendert wurde (Index verwerfen)."""
    from . import scriptsearch
    sparse = [p for p in range(1, len(pages) + 1) if scope.contains(p) and is_sparse(pages[p - 1])]
    if not sparse:
        return pages
    with _file_lock(file_id):
        # nur lesen (haeufiger Fall: alle fast leeren Seiten schon erkannt); die Tabelle entsteht beim ersten Speichern
        f = db.row(conn, "SELECT local_path, chdate FROM files WHERE id=?", (file_id,))
        path = (f or {}).get("local_path") or ""
        if not path or not path.lower().endswith(".pdf") or not Path(path).is_file():
            return pages
        stamp = f["chdate"] or 0
        done = set()
        if has_table(conn):
            done = {r["page"] for r in db.rows(conn, "SELECT page FROM page_ocr WHERE file_id=? AND COALESCE(chdate, 0)=?", (file_id, stamp))}
        todo = [p for p in sparse if p not in done]
        if not todo:
            return pages
        out = list(pages)
        conn.commit()          # keine Schreibsperre waehrend der Erkennung halten (Minuten)
        for batch in batches(todo):
            _check(cancel)
            try:
                with _SLOTS:
                    found = _recognize(ocr, path, batch, cancel)
            except OCRCancelled:
                raise
            except Exception as e:  # noqa: BLE001 - Fehler der Erkennung: Texte unveraendert, naechster Bedarf versucht es neu
                log.warning("Texterkennung %s Seiten %s gescheitert: %s", file_id, batch, e)
                return out
            _check(cancel)
            current = list(out)
            try:
                now = db.row(conn, "SELECT chdate FROM files WHERE id=?", (file_id,))
                n = conn.execute("SELECT COUNT(*) FROM page_texts WHERE file_id=? AND COALESCE(chdate, 0)=?", (file_id, stamp)).fetchone()[0]
                # inzwischen eine neue Fassung oder neu gelesene Texte: die Erkennung gehoert nicht mehr dazu
                if not now or (now["chdate"] or 0) != stamp or n != len(current):
                    conn.rollback()
                    return out
                ensure_table(conn)
                applied = {}
                for p in batch:
                    emb = current[p - 1]
                    text = (found.get(p) or "").strip()
                    conn.execute("INSERT OR REPLACE INTO page_ocr(file_id, page, chdate, embedded, text) VALUES (?,?,?,?,?)",
                                 (file_id, p, stamp, emb, text))
                    if not accepts(emb, text):        # nur, wenn die Erkennung mehr Text findet als die Textebene
                        continue
                    conn.execute("UPDATE page_texts SET text=?, search=? WHERE file_id=? AND page=?",
                                 (text, scriptsearch.search_form(text), file_id, p))
                    applied[p] = text
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            for p, t in applied.items():
                out[p - 1] = t
            if applied and on_change:
                on_change()
    return out


def _recognize(ocr, path: str, batch: list[int], cancel) -> dict[int, str]:
    """Motoren, die `cancel` kennen, bekommen es (Abbruch zwischen den Seiten), einfache Motoren nicht."""
    try:
        takes_cancel = "cancel" in inspect.signature(ocr.recognize).parameters
    except (TypeError, ValueError):
        takes_cancel = False
    return ocr.recognize(path, batch, cancel) if takes_cancel else ocr.recognize(path, batch)
