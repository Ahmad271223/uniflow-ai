"""Unicode-Schrift finden und bei reportlab registrieren.

Gesucht wird eine Schrift, die alle Zeichen aus ``PFLICHTZEICHEN`` enthält
(√ ‖ ∠ ℝ π ₀ … ). Reihenfolge: Umgebungsvariable ``KLAUSUR_PDF_FONT``
(Pfad zu .ttf/.ttc, optional ``pfad#index`` für .ttc), danach typische Pfade
unter Linux, macOS und Windows.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

PFLICHTZEICHEN = "√‖∠ℝπ×·≠≤≥∈→₀₁₂²³äöüßÄÖÜ„“–−▶"

_KANDIDATEN = [
    # Linux
    ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
    ("/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"),
    ("/usr/share/fonts/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"),
    # macOS
    ("/Library/Fonts/DejaVuSans.ttf", "/Library/Fonts/DejaVuSans-Bold.ttf"),
    # Arial Unicode hat keinen fetten Schnitt; Arial Bold passt dazu und liegt auf jedem Mac.
    # Zeichen, die Arial Bold nicht kann (∠ ℝ ∈ ₀ ▶), setzt render.fett() in der Grundschrift.
    ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    ("/Library/Fonts/Arial Unicode.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    ("/System/Library/Fonts/Supplemental/STIXTwoText.ttf", None),
    # Windows
    ("C:/Windows/Fonts/DejaVuSans.ttf", "C:/Windows/Fonts/DejaVuSans-Bold.ttf"),
    ("C:/Windows/Fonts/cambria.ttc#1", "C:/Windows/Fonts/cambriab.ttf"),  # Cambria Math
    ("C:/Windows/Fonts/seguisym.ttf", None),
    ("C:/Windows/Fonts/arialuni.ttf", None),
]


@dataclass
class Schrift:
    normal: str
    fett: str
    pfad: str
    fehlend: str  # Zeichen, die in der Schrift fehlen (leer = alles da)
    titel: str = "KP-Normal"  # Fettschrift, auch wenn ihr einzelne Mathezeichen fehlen (siehe render.fett)


def _lade(name: str, spec: str) -> TTFont | None:
    pfad, _, idx = spec.partition("#")
    if not os.path.isfile(pfad):
        return None
    try:
        if pfad.lower().endswith(".ttc"):
            return TTFont(name, pfad, subfontIndex=int(idx or 0))
        return TTFont(name, pfad)
    except Exception:  # defekte oder nicht unterstützte Schrift
        return None


def _fehlende(font: TTFont, zeichen: str = PFLICHTZEICHEN) -> str:
    cmap = font.face.charToGlyph
    return "".join(z for z in zeichen if ord(z) not in cmap)


_CACHE: Schrift | None = None


def registriere() -> Schrift:
    """Registriert die beste verfügbare Schrift und gibt ihre Namen zurück."""
    global _CACHE
    if _CACHE is not None:
        return _CACHE
    kandidaten = []
    env = os.environ.get("KLAUSUR_PDF_FONT")
    if env:
        kandidaten.append((env, os.environ.get("KLAUSUR_PDF_FONT_BOLD")))
    kandidaten += _KANDIDATEN
    bestes = None
    for normal, fett in kandidaten:
        f = _lade("KP-Normal", normal)
        if f is None:
            continue
        fehlt = _fehlende(f)
        if bestes is None or len(fehlt) < len(bestes[2]):
            bestes = (f, fett, fehlt, normal)
        if not fehlt:
            break
    if bestes is None:
        raise RuntimeError(
            "Keine Unicode-Schrift gefunden. Bitte KLAUSUR_PDF_FONT auf eine .ttf-Datei "
            "setzen, die √ ‖ ∠ ℝ π enthält (zum Beispiel DejaVuSans.ttf)."
        )
    font, fett_spec, fehlt, pfad = bestes
    pdfmetrics.registerFont(font)
    fett_name = "KP-Normal"
    titel_name = "KP-Normal"
    if fett_spec:
        fb = _lade("KP-Fett", fett_spec)
        if fb is not None:
            # Für Fettdruck reicht eine Fettschrift mit Grundzeichen; render.fett()
            # setzt Zeichen, die ihr fehlen, einzeln in der Grundschrift.
            pdfmetrics.registerFont(fb)
            titel_name = "KP-Fett"
        # Fettschrift nur nehmen, wenn sie genauso viele Zeichen kann wie die
        # Grundschrift; sonst Fettdruck mit der Grundschrift (Ergebnisse sind
        # zusätzlich farbig hinterlegt und bleiben damit erkennbar).
        if fb is not None and len(_fehlende(fb)) <= len(fehlt):
            fett_name = "KP-Fett"
    pdfmetrics.registerFontFamily("KP", normal="KP-Normal", bold=fett_name,
                                  italic="KP-Normal", boldItalic=fett_name)
    _CACHE = Schrift(normal="KP-Normal", fett=fett_name, pfad=pfad, fehlend=fehlt, titel=titel_name)
    return _CACHE


def kann(fontname: str, text: str) -> bool:
    """True, wenn die registrierte Schrift alle Zeichen von text darstellen kann."""
    cmap = pdfmetrics.getFont(fontname).face.charToGlyph
    return all(ord(z) in cmap or z in "\n\t" for z in text)
