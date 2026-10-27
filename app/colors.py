"""Fachfarben: jedes Modul (Fach) bekommt eine eigene, klar unterscheidbare Farbe. Alles, was zum Fach gehoert
(Vorlesung, Uebung, Tutorium, Lernpakete), zeigt die Farbe des Moduls.

PALETTE: 12 Farben mit deutlich verschiedenem Ton (OKLab-Abstand je Paar >= 0.12), in beiden Modi lesbar: weisse
Schrift auf der Farbe mit Kontrast >= 3.5, die Farbe auf der dunklen Flaeche (#171a23) mit >= 3.0.
PALETTE_2: dieselben Toene als abgesetzte zweite Stufe fuer das 13. bis 24. Modul (je Ton heller oder dunkler, je
nachdem, wo der Kontrast in beiden Modi reicht; Abstand zu allen 23 anderen Farben >= 0.07).

Vergeben wird der Reihe nach die erste Farbe, die noch kein Modul hat: bis 24 Module ist keine doppelt, danach geht es
reihum (Nachbarn nie gleich). Gleiche Fassung im Swift-Kern (`ModuleColors` in LocalModules.swift) und fuer die
Farbwahl in app/static/core.js (`PALETTE`); tests/test_module_colors.py vergleicht die drei.
"""
from __future__ import annotations

PALETTE = ["#175ee8", "#e95905", "#167535", "#834bbf", "#b9454c", "#1f9682",
           "#896301", "#de5797", "#0486c2", "#748e03", "#626974", "#a1826c"]
PALETTE_2 = ["#0257af", "#c25601", "#178e4b", "#9672de", "#a11e37", "#037066",
             "#ae8324", "#ca2d72", "#056083", "#657502", "#79808d", "#8b6b59"]
ALL = PALETTE + PALETTE_2

# Palette bis 26.10.2026 (fast gleiche Toene: zwei Blau, zwei Tuerkis, zwei Violett). Diese Farben hat die App selbst
# vergeben; eine andere Farbe eines Moduls stammt aus der Farbwahl des Nutzers.
OLD_PALETTE = ["#4f6df5", "#0ea5a0", "#e0803a", "#9b59d9", "#d94f6b", "#2f9e5a", "#c7891a", "#3b82c4", "#7c5cd6", "#1aa39a"]


def _key(v) -> str:
    """Vergleichsform einer gespeicherten Farbe (nur Text zaehlt, ohne Gross/klein)"""
    return v.lower() if isinstance(v, str) else ""


def next_color(conn) -> str:
    """Farbe fuer ein neues Modul: die erste aus ALL, die noch kein Modul hat; sind alle vergeben, reihum nach der
    Anzahl der Module."""
    colors = [r[0] for r in conn.execute("SELECT color FROM modules")]
    used = {_key(c) for c in colors}
    for c in ALL:
        if c not in used:
            return c
    return ALL[len(colors) % len(ALL)]


def migrate_palette(conn) -> None:
    """Einmalige Umstellung auf die neue Palette (db.init_db, beim Anlegen der Spalte modules.color_custom).

    Eine Farbe ausserhalb der alten Palette hat der Nutzer selbst gesetzt: Sie bleibt, das Modul bekommt den Merker
    color_custom = 1 (danach setzt ihn PATCH /api/modules, sobald sich die Farbe aendert). Alle anderen Module (alte
    Palette oder ohne Farbe) bekommen in der Reihenfolge der Modulliste (sort, name) der Reihe nach eindeutige Farben
    aus der neuen Palette, ohne die Farben der Nutzer."""
    old = set(OLD_PALETTE)
    mods = [(r[0], r[1]) for r in conn.execute("SELECT id, color FROM modules ORDER BY sort, name, id")]
    custom = {mid for mid, color in mods if _key(color) and _key(color) not in old}
    used = {_key(color) for mid, color in mods if mid in custom}
    for i, (mid, color) in enumerate(mods):
        if mid in custom:
            conn.execute("UPDATE modules SET color_custom=1 WHERE id=?", (mid,))
            continue
        free = [c for c in ALL if c not in used]
        new = free[0] if free else ALL[i % len(ALL)]
        conn.execute("UPDATE modules SET color=? WHERE id=?", (new, mid))
        used.add(new)
