import Foundation

/// Loesungen zu einer anderen Fassung derselben PDF (Freigabe des Inhabers 23.11.2026, docs/LOESUNGEN-TEILEN.md,
/// Nachtrag 23.11.2026 "Fassungen").
///
/// Lehrende laden oft eine geaenderte PDF hoch; der Fingerabdruck (SHA-256 der Datei) passt dann nicht mehr. Die
/// Community findet Loesungen darum auch ueber die Datei-Familie (`CommunityKeys.familyKey`). Welche Seiten der
/// fremden Fassung auf die eigene passen, entscheidet der Seitentext:
/// - Der Absender legt in den verschluesselten Inhalt je Seite seiner PDF ein Kennzeichen des Seitentexts
///   (`SolutionContent.versionPages`, `pageKey`). Der Text selbst geht nie mit.
/// - Der Empfaenger bildet dieselben Kennzeichen aus seiner PDF und ordnet die Seiten mit derselben Regel zu wie bei
///   einer neuen Fassung mit Notizen (`PageMatch`, S7). Gleich geblieben ist eine Seite, deren Text in beiden Fassungen
///   gleich ist (`PageMatch.Kind.same` oder `.repeated`); sie erscheint 1:1 auf der eigenen PDF-Seite.
/// - Alle anderen Seiten der Loesung: liegt die Fassung des Absenders auf dem Geraet (aufbewahrte alte Fassung, S7),
///   auf deren Seite, so wie sie geschrieben wurde; sonst steht an der Stelle `pageChanged`. Nie nur Striche auf Weiss.
public enum SolutionVersions {
    /// Text an der Stelle einer Seite, die sich in der eigenen Fassung geaendert hat (Wortlaut des Inhabers)
    public static let pageChanged = "Diese Seite hat sich in deiner Fassung geändert"

    /// Laenge eines Kennzeichens: 16 Byte des SHA-256, je halbes Byte ein Buchstabe a...p
    public static let pageKeyLength = 32
    private static let alphabet = Array("abcdefghijklmnop".utf8)

    /// Kennzeichen des Texts einer Seite: Woerter wie `PageMatch.words` (Ziffern als "#", Leerraum zusammengefasst,
    /// klein), darueber SHA-256; "" fuer eine Seite ohne Text. Nur Buchstaben a...p, damit `PageMatch` das Kennzeichen
    /// als genau ein Wort liest (Ziffern faltet es zu "#").
    public static func pageKey(_ text: String) -> String {
        let words = PageMatch.words(text)
        guard !words.isEmpty else { return "" }
        let hash = SolutionSHA256.hash(Data(("uniflow.page-text.v1\u{0}" + words.joined(separator: " ")).utf8))
        var out: [UInt8] = []
        for b in hash.prefix(pageKeyLength / 2) { out.append(alphabet[Int(b >> 4)]); out.append(alphabet[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    public static func pageKeys(_ texts: [String]) -> [String] { texts.map(pageKey) }

    /// "" oder genau `pageKeyLength` Buchstaben a...p
    public static func isPageKey(_ s: String) -> Bool {
        s.isEmpty || (s.utf8.count == pageKeyLength && s.utf8.allSatisfy { (0x61...0x70).contains($0) })
    }

    /// Wo eine PDF-Seite der Loesung beim Betrachter steht
    public enum Placement: Equatable, Sendable {
        /// auf der eigenen PDF-Seite (1-basiert)
        case own(Int)
        /// auf der Seite (1-basiert) der aufbewahrten Fassung des Absenders
        case oldVersion(Int)
        /// in der eigenen Fassung geaendert, die Fassung des Absenders liegt nicht auf dem Geraet: `pageChanged`
        case changed
    }

    /// Gleich gebliebene Seiten: Seite des Absenders -> eigene Seite (beide 1-basiert)
    public static func unchangedPages(sender: [String], own: [String]) -> [Int: Int] {
        guard !sender.isEmpty, !own.isEmpty else { return [:] }
        var out: [Int: Int] = [:]
        for p in PageMatch.match(old: sender, new: own).pairs where p.kind == .same || p.kind == .repeated {
            out[p.old] = p.new
        }
        return out
    }

    /// Lage jeder PDF-Seite der Loesung (nach `SolutionPage.key`; eigene Blaetter des Absenders fehlen, sie stehen
    /// immer auf ihrem Papier).
    /// - `ownFingerprint`, `ownKeys`: eigene PDF (Fingerabdruck, Kennzeichen je Seite)
    /// - `oldVersion`: Kennzeichen der aufbewahrten Fassung des Absenders, nil wenn sie nicht auf dem Geraet liegt.
    ///   Ohne Kennzeichen im Paket (aeltere Absender) dienen sie zur Zuordnung.
    /// - `fits`: passt die eigene Seite (1-basiert) in Groesse zur Seite des Absenders? (sonst stuenden die Striche
    ///   daneben; die App vergleicht die CropBox)
    public static func placements(_ content: SolutionContent, ownFingerprint: String, ownKeys: [String],
                                  oldVersion: [String]? = nil,
                                  fits: (SolutionPage, Int) -> Bool = { _, _ in true }) -> [String: Placement] {
        var out: [String: Placement] = [:]
        let same = content.fingerprint == ownFingerprint
        var unchanged: [Int: Int] = [:]
        if !same {
            let sender = [content.versionPages, oldVersion].compactMap { $0 }.first { $0.count == content.pdfPageCount }
            unchanged = sender.map { unchangedPages(sender: $0, own: ownKeys) } ?? [:]
        }
        for p in content.pages where p.kind == .pdf {
            guard let i = p.pdfIndex else { continue }
            if same {
                out[p.key] = .own(i)
            } else if let j = unchanged[i], fits(p, j) {
                out[p.key] = .own(j)
            } else {
                out[p.key] = oldVersion != nil ? .oldVersion(i) : .changed
            }
        }
        return out
    }
}
