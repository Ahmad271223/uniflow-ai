"""Fristen- und Termin-Chips im Stundenplan und Lernkalender: ein Klick zeigt, was gemeint ist (Detailfenster mit Titel,
Kurs, Zeit, Satz aus der Ankündigung, ganzer Ankündigung und Link zur Quelle) statt nur eines Tooltips (27.10.2026)."""
import re
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "app" / "static"


def test_chips_open_a_detail_window_instead_of_a_bare_link():
    core = (STATIC / "core.js").read_text(encoding="utf-8")
    for name in ("dlChips", "noteChips"):
        line = next(l for l in core.splitlines() if l.startswith(f"export const {name} "))
        assert 'data-chip="${chipRef(' in line, f"{name}: Chip ohne Kennung für das Detailfenster"
        assert 'target="_blank"' not in line, f"{name}: der Klick soll das Detailfenster öffnen, nicht die Seite"
    assert "export function chipDetail(key)" in core and 'closest("[data-chip]")' in core
    for text in ("Ganze Ankündigung", 'api("/announcements?days=365")', 'target="_blank" rel="noopener"', "überfällig", "data-close"):
        assert text in core, text
    app = (STATIC / "app.js").read_text(encoding="utf-8")
    assert 'chipRef({ ...u, id: u.deadline_id' in app, "Fristen unter „Nächste Termine“ ebenso"


def test_core_js_cache_busting_is_consistent():
    """Jede Änderung an core.js braucht dieselbe neue ?v= in allen Modulen, sonst laden Browser eine Mischung."""
    versions = set()
    for p in STATIC.glob("*.js"):
        versions |= set(re.findall(r'from "\./core\.js\?v=(\d+)"', p.read_text(encoding="utf-8")))
    assert len(versions) == 1, f"core.js wird mit verschiedenen Versionen geladen: {versions}"
    index = (STATIC / "index.html").read_text(encoding="utf-8")
    assert re.search(r'src="app\.js\?v=\d+"', index)
