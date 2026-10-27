import Foundation

/// Fachfarben 1:1 wie app/colors.py: jedes Modul (Fach) bekommt eine eigene, klar unterscheidbare Farbe; alles, was
/// zum Fach gehoert (Vorlesung, Uebung, Tutorium, Lernpakete), zeigt die Farbe des Moduls.
///
/// `palette`: 12 Farben mit deutlich verschiedenem Ton (OKLab-Abstand je Paar >= 0.12), weisse Schrift darauf mit
/// Kontrast >= 3.5, auf der dunklen Flaeche (#171a23) >= 3.0. `palette2`: dieselben Toene als abgesetzte zweite Stufe
/// fuer das 13. bis 24. Modul. Vergeben wird der Reihe nach die erste Farbe, die noch kein Modul hat; sind alle 24
/// vergeben, reihum. tests/test_module_colors.py vergleicht die Listen mit Python und der Web-App.
public enum ModuleColors {
    public static let palette = ["#175ee8", "#e95905", "#167535", "#834bbf", "#b9454c", "#1f9682",
                                 "#896301", "#de5797", "#0486c2", "#748e03", "#626974", "#a1826c"]
    public static let palette2 = ["#0257af", "#c25601", "#178e4b", "#9672de", "#a11e37", "#037066",
                                  "#ae8324", "#ca2d72", "#056083", "#657502", "#79808d", "#8b6b59"]
    /// `ALL`: Vergabereihenfolge
    public static let all = palette + palette2
    /// Palette bis 26.10.2026 (fast gleiche Toene). Diese Farben hat die App selbst vergeben; eine andere Farbe eines
    /// Moduls stammt aus der Farbwahl des Nutzers.
    public static let oldPalette = ["#4f6df5", "#0ea5a0", "#e0803a", "#9b59d9", "#d94f6b", "#2f9e5a", "#c7891a", "#3b82c4", "#7c5cd6", "#1aa39a"]

    /// `_key`: Vergleichsform einer gespeicherten Farbe (nur Text zaehlt, ohne Gross/klein)
    static func key(_ v: SQLiteValue?) -> String {
        if case .text(let s)? = v { return s.lowercased() }
        return ""
    }

    /// `next_color(conn)`: die erste Farbe aus `all`, die noch kein Modul hat; sind alle vergeben, reihum nach der
    /// Anzahl der Module.
    public static func next(_ c: SQLiteConnection) throws -> String {
        let colors = try c.query("SELECT color FROM modules").map { $0[0] }
        let used = Set(colors.map { key($0) })
        return all.first { !used.contains($0) } ?? all[colors.count % all.count]
    }

    /// `migrate_palette(conn)`: einmalige Umstellung auf die neue Palette (Migrations, beim Anlegen der Spalte
    /// modules.color_custom). Eine Farbe ausserhalb der alten Palette hat der Nutzer gesetzt: Sie bleibt und bekommt
    /// den Merker color_custom = 1. Alle anderen Module (alte Palette oder ohne Farbe) bekommen in der Reihenfolge der
    /// Modulliste (sort, name) der Reihe nach eindeutige Farben aus der neuen Palette, ohne die Farben der Nutzer.
    static func migratePalette(_ c: SQLiteConnection) throws {
        let old = Set(oldPalette)
        let mods = try c.query("SELECT id, color FROM modules ORDER BY sort, name, id").map { (id: $0[0], color: $0[1]) }
        func isCustom(_ color: SQLiteValue) -> Bool { !key(color).isEmpty && !old.contains(key(color)) }
        var used = Set(mods.filter { isCustom($0.color) }.map { key($0.color) })
        for (i, m) in mods.enumerated() {
            if isCustom(m.color) {
                try c.execute("UPDATE modules SET color_custom=1 WHERE id=?", [m.id])
                continue
            }
            let new = all.first { !used.contains($0) } ?? all[i % all.count]
            try c.execute("UPDATE modules SET color=? WHERE id=?", [.text(new), m.id])
            used.insert(new)
        }
    }
}
