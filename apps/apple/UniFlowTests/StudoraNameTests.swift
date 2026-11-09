import XCTest
@testable import UniFlow

/// Die App heisst StudiNow (Entscheidung des Inhabers vom 03.11.2026, vorher Studora): Name auf dem Home-Bildschirm und alle sichtbaren
/// Texte. Bundle-ID, Produkt-IDs, Typnamen, Ordner und interne Kennungen bleiben bei uniflow, sonst gingen Daten und
/// Einstellungen verloren.
final class StudoraNameTests: XCTestCase {
    @MainActor
    func testHomeScreenNameIsStudoraAndIdentifiersStay() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "StudiNow")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "de.uniflow.ai", "Bundle-ID bleibt")
        let docTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]]
        XCTAssertEqual(docTypes?.first?["CFBundleTypeName"] as? String, "StudiNow-Lösung")
        XCTAssertEqual(UFPlan.plus.productID, "de.uniflow.plus.yearly", "Produkt-ID bleibt bei de.uniflow (nur Jahresabo, 09.11.2026)")
        XCTAssertEqual(UFLockedCard.message(.uniflowEditor, access: .comingSoon), "Kommt mit der nächsten Version von StudiNow.")
    }

    /// Kein Stringliteral der App und des Kerns nennt "UniFlow", ausser den internen Kennungen, die bleiben muessen
    func testNoVisibleTextSaysUniFlow() throws {
        let allowed = try NSRegularExpression(pattern: [
            #"appendingPathComponent\("UniFlow"#,     // Ordner in Application Support (Daten bleiben)
            #""UniFlowContainers"#,                    // Container-Ordner
            #"Application Support/UniFlow"#,           // gespeicherte Pfade in der Datenbank
            #"supportPrefix"#,                         // Umzug alter Daten
            #"beginBackgroundTask"#,                   // Name der Hintergrundaufgabe (nicht sichtbar)
            #"bytes\("BT "#,                           // Demo-PDF Byte fuer Byte wie app/demo.py
        ].joined(separator: "|"))
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        try ContainerTestBed.requireRepoSources()
        let roots = ["apps/apple/UniFlow", "apps/apple/Packages/UniFlowCore/Sources"].map { ContainerTestBed.repoURL($0) }
        var hits: [String] = []
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, root.path)
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains("UniFlow") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if allowed.firstMatch(in: line, range: range) != nil { continue }
                    for m in literal.matches(in: line, range: range) {
                        if let r = Range(m.range, in: line), line[r].contains("UniFlow") {
                            hits.append("\(file.lastPathComponent):\(i + 1): \(trimmed.prefix(120))")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }
}
