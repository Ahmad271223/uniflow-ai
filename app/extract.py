"""Textextraktion aus heruntergeladenen Dateien (fuer die KI-Analyse)."""
from __future__ import annotations

from pathlib import Path

from .config import TEXT_EXTENSIONS

MAX_CHARS = 14000


def extract_text(path: str | Path, max_chars: int = MAX_CHARS) -> str:
    p = Path(path)
    if not p.exists() or p.suffix.lower() not in TEXT_EXTENSIONS:
        return ""
    try:
        if p.suffix.lower() == ".pdf":
            from pypdf import PdfReader

            reader = PdfReader(str(p))
            parts: list[str] = []
            total = 0
            for i, page in enumerate(reader.pages):
                t = page.extract_text() or ""
                parts.append(f"--- Seite {i + 1} ---\n{t}")
                total += len(t)
                if total > max_chars:
                    break
            text = "\n".join(parts)
            return text[:max_chars] + (f"\n[... gekuerzt, insgesamt {len(reader.pages)} Seiten]" if len(text) > max_chars else "")
        return p.read_text(encoding="utf-8", errors="replace")[:max_chars]
    except Exception as e:  # noqa: BLE001
        return f"[Textextraktion fehlgeschlagen: {e}]"


def page_count(path: str | Path) -> int | None:
    p = Path(path)
    if p.suffix.lower() != ".pdf" or not p.exists():
        return None
    try:
        from pypdf import PdfReader

        return len(PdfReader(str(p)).pages)
    except Exception:  # noqa: BLE001
        return None
