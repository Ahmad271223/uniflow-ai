import Foundation

#if DEBUG
/// Riegel fuer Testlaeufe am Mac ("Designed for iPad"; 14.11.2026, docs/MAC-TESTLAUF-EIGENER-ORDNER-2026-11-14.md).
///
/// Im Simulator ist die Test-App leer. Am Mac ist der Testwirt dagegen dieselbe App wie die installierte: gleiche
/// Kennung, also derselbe Datenordner (`~/Library/Containers/…`), derselbe Schluesselbund und dieselben Einstellungen.
/// Tests lasen dort die echte Stud.IP-Sitzung und schrieben Test-Gespraeche in die echte KI-Ablage
/// (docs/MAC-DURCHLAUF-2026-11-14.md, Abschnitt 6.3). Darum laufen Tests am Mac nur noch mit einer eigenen Kennung
/// (`macTestBundleID`, gesetzt von tools/mac-test.sh ueber UF_DEBUG_BUNDLE_ID): das System gibt ihr einen eigenen,
/// leeren Datenordner und einen eigenen Schluesselbund-Bereich.
///
/// Der Riegel steht ganz am Anfang des App-Starts: Ein Testlauf am Mac ohne die eigene Kennung beendet sich, bevor die
/// App ein Konto, einen Container oder eine Datei anfasst. Nur im Debug-Bau; im Release (TestFlight, App Store) gibt es
/// diesen Code nicht. iPad, iPhone und Simulator betrifft er nie (`onMac` ist dort false), ebenso wenig einen normalen
/// Start am Mac ohne XCTest.
enum MacTestGuard {
    /// Kennung der ausgelieferten App (project.yml)
    static let shippedBundleID = "de.uniflow.ai"
    /// Kennung nur fuer Testlaeufe am Mac
    static let macTestBundleID = "de.uniflow.ai.mactest"
    /// Ende-Code des abgebrochenen Testlaufs (EX_CONFIG)
    static let exitCode: Int32 = 78

    static let message = """
    StudiNow: Testlauf am Mac abgebrochen. Mit der Kennung der echten App liefe er im Datenordner der installierten \
    Mac-App (Konto, Stud.IP-Sitzung, KI-Gespräche, Einstellungen). Tests am Mac nur über tools/mac-test.sh starten \
    (setzt UF_DEBUG_BUNDLE_ID=de.uniflow.ai.mactest, eigener leerer Datenordner).
    """

    /// true: dieser Prozess ist ein Testlauf am Mac ohne eigene Kennung und saehe die echten Daten der Mac-App
    nonisolated static func wouldTouchRealData(underTest: Bool, onMac: Bool, bundleID: String?) -> Bool {
        underTest && onMac && bundleID != macTestBundleID
    }

    /// Fuer diesen Prozess
    nonisolated static var wouldTouchRealData: Bool {
        wouldTouchRealData(underTest: StudIPSync.isUnderTest(), onMac: ProcessInfo.processInfo.isiOSAppOnMac,
                           bundleID: Bundle.main.bundleIdentifier)
    }

    /// Erste Zeile des App-Starts (`UniFlowApp.init`)
    static func stopIfTestWouldTouchRealData() {
        guard wouldTouchRealData else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        NSLog("%@", message)
        exit(exitCode)
    }
}
#endif
