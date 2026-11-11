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
        guard mac, text.contains("iPad") else { return text }
        var t = text
        for (a, b) in [("dieses iPads", "dieses Macs"), ("dieses iPad", "diesen Mac"), ("diesem iPad", "diesem Mac"),
                       ("Diesem iPad", "Diesem Mac"), ("deinem iPad", "deinem Mac"), ("auf dein iPad", "auf deinen Mac"),
                       ("dein iPad", "dein Mac")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
