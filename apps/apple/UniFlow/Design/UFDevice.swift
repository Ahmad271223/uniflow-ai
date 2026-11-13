import Foundation

/// Geraet in Texten (10.11.2026): Am Mac ("Designed for iPad", dieselbe App) sprachen viele Texte von "diesem iPad".
/// `adapt` setzt dort "diesem Mac" usw. ein, auf dem iPhone (Universal-App, 11.11.2026) "diesem iPhone"; am iPad bleibt
/// der Text unveraendert. Eine Geraetefrage, keine Layoutfrage (Layout: `UFLayout.isCompact` nach Platz).
enum UFDevice {
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    /// iPhone aus der Modellkennung, ohne UIKit (darf in jedem Kontext gelesen werden); im Simulator die Kennung des
    /// simulierten Geraets
    static let isPhone: Bool = {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var u = utsname()
            uname(&u)
            id = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return id.hasPrefix("iPhone")
    }()

    /// Name des Geraets fuer Texte ("iPad", "iPhone" bzw. "Mac")
    static var name: String { isMac ? "Mac" : (isPhone ? "iPhone" : "iPad") }

    /// Fuer Texte, die bis Build 32 fest "iPad" sagten (auch am Mac): am iPhone "iPhone", sonst "iPad" wie bisher
    /// (Vorgabe 11.11.2026: an der iPad-Fassung, also auch am Mac, aendert sich nichts)
    static var textName: String { isPhone ? "iPhone" : "iPad" }

    static func adapt(_ text: String) -> String { isMac ? adapt(text, mac: true) : adapt(text, phone: isPhone) }

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

    /// iPhone: "iPhone" ist wie "iPad" ein Neutrum, alle Faelle bleiben ("dieses iPads" -> "dieses iPhones"). Nur die
    /// Wendungen mit Bezug auf dieses Geraet, damit Saetze ueber das iPad selbst ("Notizen schreibst du am iPad")
    /// stehen bleiben.
    static func adapt(_ text: String, phone: Bool) -> String {
        guard phone, text.contains("iPad") else { return text }
        var t = text
        for (a, b) in [("dieses iPads", "dieses iPhones"), ("dieses iPad", "dieses iPhone"), ("diesem iPad", "diesem iPhone"),
                       ("Diesem iPad", "Diesem iPhone"), ("deinem iPad", "deinem iPhone"), ("dein iPad", "dein iPhone"),
                       ("des iPads", "des iPhones"), ("Wie iPad", "Wie iPhone")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
