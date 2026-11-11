import Foundation

/// Geraet in Texten (10.11.2026): Am Mac ("Designed for iPad", dieselbe App) sprachen viele Texte von "diesem iPad".
/// `adapt` setzt dort "diesem Mac" usw. ein; am iPad bleibt der Text unveraendert.
enum UFDevice {
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    /// Name des Geraets fuer Texte ("iPad" bzw. "Mac")
    static var name: String { isMac ? "Mac" : "iPad" }

    static func adapt(_ text: String) -> String { adapt(text, mac: isMac) }

    /// Reihenfolge wichtig: der Genitiv "dieses iPads" vor "dieses iPad" (Akkusativ: "auf dieses iPad holt")
    static func adapt(_ text: String, mac: Bool) -> String {
        guard mac, text.contains("iPad") || text.contains("Pencil") || text.contains("iOS") else { return text }
        var t = text
        // Mac (11.11.2026, Handpruefung "wirkt wie Demo"): kein Apple Pencil, Passwoerter ueber die Passwoerter-App
        for (a, b) in [("Auch iOS kann es einsetzen (Schlüssel-Symbol über der Tastatur).", "Auch die Passwörter-App des Mac kann es einsetzen."),
                       ("iOS kann das gespeicherte Passwort einsetzen", "die Passwörter-App des Mac kann das gespeicherte Passwort einsetzen"),
                       ("Apple Pencil (PencilKit) und handschriftliche Notizen", "Handschriftliche Notizen mit Maus oder Trackpad"),
                       ("der Apple Pencil schreibt weiter", "Maus und Trackpad schreiben weiter"),
                       ("mit dem Apple Pencil", "mit Maus und Trackpad"), ("Mit Apple Pencil", "Mit Maus oder Trackpad"),
                       ("mit Apple Pencil", "mit Maus oder Trackpad")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        for (a, b) in [("dieses iPads", "dieses Macs"), ("dieses iPad", "diesen Mac"), ("diesem iPad", "diesem Mac"),
                       ("Diesem iPad", "Diesem Mac"), ("deinem iPad", "deinem Mac"), ("auf dein iPad", "auf deinen Mac"),
                       ("dein iPad", "dein Mac")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
