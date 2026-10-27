"""Fachfarben (app/colors.py): 12 klar verschiedene, in beiden Modi lesbare Farben, der Reihe nach vergeben, eine
zweite Stufe ab dem 13. Modul, einmalige Umstellung alter Datenbanken und der Merker fuer selbst gewaehlte Farben.
Alles auf eigenen Temp-Datenbanken, nie auf data/."""
import itertools
import json
import math
import re
import sqlite3
from pathlib import Path

import pytest

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- Farbmetrik (WCAG-Kontrast, OKLab-Abstand)

def _lin(c: int) -> float:
    c = c / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _rgb(h: str) -> list[float]:
    return [_lin(int(h[i:i + 2], 16)) for i in (1, 3, 5)]


def _lum(h: str) -> float:
    r, g, b = _rgb(h)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a: str, b: str) -> float:
    la, lb = sorted((_lum(a), _lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def _oklab(h: str) -> tuple[float, float, float]:
    r, g, b = _rgb(h)
    l_ = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m_ = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s_ = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)


def _dist(a: str, b: str) -> float:
    return math.dist(_oklab(a), _oklab(b))


DARK_SURFACE = "#171a23"        # --surface im dunklen Modus (style.css, UFTheme.surface)


def test_palette_has_twelve_clearly_different_readable_colors():
    from app import colors
    assert len(colors.PALETTE) >= 12 and len(colors.PALETTE_2) == len(colors.PALETTE)
    assert all(re.fullmatch(r"#[0-9a-f]{6}", c) for c in colors.ALL), "klein geschriebenes #rrggbb"
    assert len(set(colors.ALL)) == len(colors.ALL)
    assert not set(colors.ALL) & set(colors.OLD_PALETTE), "neue Farben unterscheiden sich von der alten Palette"
    # erste Stufe: je Paar deutlich verschieden (die alte Palette hatte Paare mit 0.009 und 0.053)
    assert min(_dist(a, b) for a, b in itertools.combinations(colors.PALETTE, 2)) >= 0.12
    assert min(_dist(a, b) for a, b in itertools.combinations(colors.ALL, 2)) >= 0.07
    for c in colors.PALETTE:
        assert _contrast(c, "#ffffff") >= 3.5, f"{c}: weisse Schrift im Stundenplan"
        assert _contrast(c, DARK_SURFACE) >= 3.0, f"{c}: auf der dunklen Flaeche"
    for c in colors.PALETTE_2:
        assert _contrast(c, "#ffffff") >= 3.0 and _contrast(c, DARK_SURFACE) >= 2.2, c
    # Nachbarn in der Vergabereihenfolge (auch ueber die Stufengrenze und reihum) nie aehnlich
    assert min(_dist(colors.ALL[i], colors.ALL[(i + 1) % len(colors.ALL)]) for i in range(len(colors.ALL))) >= 0.08
    # alte Palette: wirklich fast gleiche Toene (Grund der Umstellung)
    assert min(_dist(a, b) for a, b in itertools.combinations(colors.OLD_PALETTE, 2)) < 0.02


def test_palettes_in_swift_and_web_match_python():
    from app import colors
    swift = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Study/ModuleColors.swift").read_text(encoding="utf-8")
    for name, values in (("palette", colors.PALETTE), ("palette2", colors.PALETTE_2), ("oldPalette", colors.OLD_PALETTE)):
        m = re.search(rf"static let {name}(?:: \[String\])? = \[([^\]]*)\]", swift)
        assert m, name
        assert re.findall(r'"(#[0-9a-fA-F]{6})"', m.group(1)) == values, name
    js = (ROOT / "app/static/core.js").read_text(encoding="utf-8")
    m = re.search(r"export const PALETTE = \[([^\]]*)\]", js)
    assert m and re.findall(r'"(#[0-9a-f]{6})"', m.group(1)) == colors.PALETTE


# ---------------------------------------------------------------- Vergabe und Umstellung

@pytest.fixture()
def fresh_db(tmp_path, monkeypatch):
    from app import db
    path = tmp_path / "farben.db"
    monkeypatch.setattr(db, "DB_PATH", path)
    db.init_db()
    return path


def _colors(path) -> list[tuple]:
    c = sqlite3.connect(path)
    try:
        return c.execute("SELECT name, color, color_custom FROM modules ORDER BY id").fetchall()
    finally:
        c.close()


def test_new_modules_get_unique_colors_in_order(fresh_db):
    from app import colors, db, study
    with db.cursor() as conn:
        for i in range(26):
            conn.execute("INSERT INTO courses(id, title, subject, kind, created_at) VALUES (?,?,?, 'vorlesung', '2026-10-27')",
                         (f"k{i}", f"Testfach {i:02d}", f"Testfach {i:02d}"))
        study.ensure_modules(conn)
    got = [c for _, c, _ in _colors(fresh_db)]
    assert got[:24] == colors.ALL, "bis 24 Faecher keine Farbe doppelt, der Reihe nach"
    assert got[24:] == [colors.ALL[24 % 24], colors.ALL[25 % 24]], "danach reihum"
    assert all(a != b for a, b in zip(got, got[1:])), "nie zwei gleiche nebeneinander"


def test_next_color_skips_colors_in_use(fresh_db):
    from app import colors, db
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(name, color, sort) VALUES ('A', ?, 0)", (colors.PALETTE[0].upper(),))
        conn.execute("INSERT INTO modules(name, color, sort) VALUES ('B', ?, 1)", (colors.PALETTE[2],))
        assert colors.next_color(conn) == colors.PALETTE[1]
        conn.execute("INSERT INTO modules(name, color, sort) VALUES ('C', ?, 2)", (colors.PALETTE[1],))
        assert colors.next_color(conn) == colors.PALETTE[3], "Luecke nach geloeschtem Modul wird nicht doppelt belegt"


OLD_DB = """
CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, semester TEXT, color TEXT, icon TEXT,
                      priority INTEGER DEFAULT 2, exam_date TEXT, sort INTEGER DEFAULT 0, created_at TEXT);
INSERT INTO modules(name, color, sort) VALUES ('Testmathematik I', '#4f6df5', 0);
INSERT INTO modules(name, color, sort) VALUES ('Testphysik', '#3b82c4', 1);
INSERT INTO modules(name, color, sort) VALUES ('Eigenes Testfach', '#ff00aa', 2);
INSERT INTO modules(name, color, sort) VALUES ('Testchemie', '#0ea5a0', 3);
INSERT INTO modules(name, color, sort) VALUES ('Testbiologie', '#1aa39a', 4);
INSERT INTO modules(name, color, sort) VALUES ('Testgeologie', '#4f6df5', 5);
INSERT INTO modules(name, color, sort) VALUES ('Ohne Farbe', NULL, 6);
"""


def test_old_palette_is_replaced_once_and_own_colors_stay(tmp_path, monkeypatch):
    from app import colors, db
    path = tmp_path / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript(OLD_DB)
    c.close()
    monkeypatch.setattr(db, "DB_PATH", path)
    db.init_db()
    rows = _colors(path)
    assert rows[2] == ("Eigenes Testfach", "#ff00aa", 1), "selbst gesetzte Farbe bleibt, mit Merker"
    auto = [c for n, c, k in rows if k == 0]
    assert auto == colors.PALETTE[:6], "alte Palettenfarben der Reihe nach durch eindeutige neue ersetzt"
    assert len({c for _, c, _ in rows}) == len(rows)
    # nur einmal: eine spaetere Farbe (auch eine der alten Palette) bleibt beim naechsten Start
    with db.cursor() as conn:
        conn.execute("UPDATE modules SET color='#4f6df5' WHERE name='Testphysik'")
    db.init_db()
    assert dict((n, c) for n, c, _ in _colors(path))["Testphysik"] == "#4f6df5"


def test_patch_marks_only_a_changed_color_as_own(app, fresh_db):
    from app import colors
    st, _, b = asgi_call(app, "POST", "/api/modules", body=json.dumps({"name": "Testfach A"}))
    assert st == 200
    m = json.loads(b)
    assert (m["color"], m["color_custom"]) == (colors.PALETTE[0], 0)
    # Dialog speichert Prioritaet und schickt die unveraenderte Farbe mit: bleibt automatisch
    st, _, b = asgi_call(app, "PATCH", f"/api/modules/{m['id']}", body=json.dumps({"color": colors.PALETTE[0], "priority": 3}))
    assert st == 200 and json.loads(b)["color_custom"] == 0
    st, _, b = asgi_call(app, "PATCH", f"/api/modules/{m['id']}", body=json.dumps({"color": colors.PALETTE[5]}))
    assert st == 200 and (json.loads(b)["color"], json.loads(b)["color_custom"]) == (colors.PALETTE[5], 1)
    # neues Modul nimmt die naechste freie Farbe (PALETTE[0] ist wieder frei)
    st, _, b = asgi_call(app, "POST", "/api/modules", body=json.dumps({"name": "Testfach B"}))
    assert json.loads(b)["color"] == colors.PALETTE[0]
    st, _, b = asgi_call(app, "POST", "/api/modules", body=json.dumps({"name": "Testfach C", "color": "#123456"}))
    assert (json.loads(b)["color"], json.loads(b)["color_custom"]) == ("#123456", 1), "mitgeschickte Farbe ist gewaehlt"
    assert asgi_call(app, "PATCH", "/api/modules/999", body=json.dumps({"color": "#000000"}))[0] == 404
