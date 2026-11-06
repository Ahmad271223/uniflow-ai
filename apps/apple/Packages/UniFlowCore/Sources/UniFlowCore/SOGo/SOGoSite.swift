import Foundation

/// SOGo einer Hochschule (Uni-Mail und Uni-Kalender), wie `sogo.SITES` in app/sogo.py; docs/UNI-MAIL-2026-11-05.md.
/// Wunsch des Inhabers (06.11.2026): Uni-Mail auch an der Uni Hildesheim, die dasselbe SOGo betreibt wie die LUH
/// (https://webmail.uni-hildesheim.de/ leitet auf /SOGo). Jede Hochschule hat genau einen Rechner; Konto-Adressen,
/// Anhaenge und Anfragen gelten nur auf diesem. Die Hochschule Hannover hat kein SOGo (dort keine Uni-Mail).
public struct SOGoSite: Sendable, Hashable {
    public let university: UniversityKey
    /// Rechner von SOGo (klein geschrieben)
    public let host: String
    /// Anzeigename: "Uni-Mail (LUH)", "Uni-Mail (Uni Hildesheim)"
    public let name: String
    /// Name der Hochschule fuer Texte ("Leibniz Universität Hannover")
    public let universityName: String
    /// Kurzname fuer Texte ("LUH", "Uni Hildesheim")
    public let short: String
    /// Orte der Termine als Link zum Raumfinder (nur LUH; dort gibt es den Standortfinder)
    public let roomLinks: Bool

    public var base: String { "https://\(host)/SOGo" }
    /// Anmeldeseite (Webansicht)
    public var loginURL: URL { URL(string: base + "/")! }

    public static let luh = SOGoSite(university: .luh, host: "kalender.uni-hannover.de", name: "Uni-Mail (LUH)",
                                     universityName: "Leibniz Universität Hannover", short: "LUH", roomLinks: true)
    public static let hildesheim = SOGoSite(university: .hildesheim, host: "webmail.uni-hildesheim.de", name: "Uni-Mail (Uni Hildesheim)",
                                            universityName: "Universität Hildesheim", short: "Uni Hildesheim", roomLinks: false)
    public static let all: [SOGoSite] = [.luh, .hildesheim]

    /// SOGo der Hochschule; nil, wo es keins gibt (HsH)
    public static func `for`(_ university: UniversityKey) -> SOGoSite? { all.first { $0.university == university } }

    /// Aus einem gespeicherten Schluessel ("luh", "hildesheim"); unbekannt oder ohne SOGo -> nil
    public static func `for`(university raw: String?) -> SOGoSite? { raw.flatMap(UniversityKey.init(rawValue:)).flatMap { Self.for($0) } }
}
