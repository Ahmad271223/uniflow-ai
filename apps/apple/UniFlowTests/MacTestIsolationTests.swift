import XCTest
@testable import UniFlow

/// Was der Testprozess beim Laden des Testbundles vorfand, also vor dem ersten Test (`UniFlowTestsPrincipal.init`):
/// der Stand, den die App beim Start selbst hergestellt hat. Im Simulator und am Mac mit eigener Kennung ist das eine
/// leere App. Am Mac mit der Kennung der echten App waere es der Datenordner des Nutzers (Befund 14.11.2026,
/// docs/MAC-DURCHLAUF-2026-11-14.md, Abschnitt 6.3). Es werden nur Anzahlen gemerkt, keine Inhalte.
struct TestStartSnapshot {
    let bundleID: String?
    let onMac: Bool
    /// die App hat beim Start einen Container geoeffnet (jemand ist angemeldet und hat eine Hochschule gewaehlt)
    let activeContainer: Bool
    /// Container-Ordner im Datenordner der App (Application Support/UniFlowContainers); Tests nehmen Temp-Ordner
    let containerFolders: Int
    /// Stud.IP-Cookies im Schluesselbund-Dienst der App (`StudIPCookieStore.service`): aktiver Container,
    /// Container-Ordner und Alt-Eintrag. Tests nehmen eigene Dienste ("de.uniflow.ai.studip.test.…").
    let studipCookies: Int
    /// KI-Ablagen (`tutor-conversations.json`) in den Container-Ordnern
    let tutorFiles: Int
    /// Gespraeche, die die gemeinsame KI-Ablage der App (`TutorConversations.shared`) zeigt
    let tutorConversations: Int

    @MainActor static func take() -> TestStartSnapshot {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: ContainerPaths.base, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        var cookies = ActiveContainer.current?.cookies.load().count ?? 0
        cookies += StudIPCookieStore(account: StudIPCookieStore.legacyAccount).load().count
        for folder in folders {
            if let id = UUID(uuidString: folder.lastPathComponent) { cookies += StudIPCookieStore(container: id).load().count }
        }
        return TestStartSnapshot(
            bundleID: Bundle.main.bundleIdentifier, onMac: ProcessInfo.processInfo.isiOSAppOnMac,
            activeContainer: ActiveContainer.current != nil, containerFolders: folders.count, studipCookies: cookies,
            tutorFiles: folders.filter { fm.fileExists(atPath: $0.appendingPathComponent(TutorConversations.fileName).path) }.count,
            tutorConversations: TutorConversations.shared.recent().count)
    }
}

#if DEBUG
/// Ein Testlauf darf die echten Daten der App nie sehen (14.11.2026, docs/MAC-TESTLAUF-EIGENER-ORDNER-2026-11-14.md).
/// Am Mac ("Designed for iPad") sorgt dafuer die eigene Kennung des Testlaufs (tools/mac-test.sh) und der Riegel beim
/// App-Start (`MacTestGuard`). Diese Tests schlagen fehl, wenn der Testprozess trotzdem einen aktiven Container,
/// Stud.IP-Cookies oder eine KI-Ablage der App vorfindet – am Mac waeren das die des Nutzers.
final class MacTestIsolationTests: XCTestCase {
    /// Der Riegel: nur ein Testlauf am Mac ohne die eigene Kennung wird beendet
    func testGuardStopsOnlyMacTestRunsWithoutTheirOwnBundleID() {
        let shipped = MacTestGuard.shippedBundleID, own = MacTestGuard.macTestBundleID
        XCTAssertNotEqual(shipped, own)
        XCTAssertTrue(own.hasPrefix(shipped + "."), "eigene Kennung unter der der App (Signier-Profil des Teams)")
        XCTAssertTrue(MacTestGuard.wouldTouchRealData(underTest: true, onMac: true, bundleID: shipped), "Mac-Test mit echter Kennung")
        XCTAssertTrue(MacTestGuard.wouldTouchRealData(underTest: true, onMac: true, bundleID: nil))
        XCTAssertTrue(MacTestGuard.wouldTouchRealData(underTest: true, onMac: true, bundleID: "de.uniflow.ai.anders"))
        XCTAssertFalse(MacTestGuard.wouldTouchRealData(underTest: true, onMac: true, bundleID: own), "Mac-Test mit eigener Kennung")
        XCTAssertFalse(MacTestGuard.wouldTouchRealData(underTest: true, onMac: false, bundleID: shipped), "iPad, iPhone, Simulator")
        XCTAssertFalse(MacTestGuard.wouldTouchRealData(underTest: false, onMac: true, bundleID: shipped), "normaler Start am Mac")
        XCTAssertFalse(MacTestGuard.wouldTouchRealData(underTest: false, onMac: false, bundleID: shipped))
        XCTAssertFalse(MacTestGuard.wouldTouchRealData, "dieser Lauf")
        XCTAssertTrue(MacTestGuard.message.contains("tools/mac-test.sh"), "die Meldung nennt den richtigen Weg")
    }

    /// Am Mac laeuft der Test mit der eigenen Kennung (eigener Datenordner, eigener Schluesselbund, eigene
    /// Einstellungen), sonst ueberall mit der Kennung der App
    func testMacRunHasItsOwnBundleIDAndEverythingElseTheShippedOne() throws {
        let start = try XCTUnwrap(UniFlowTestsPrincipal.start)
        XCTAssertEqual(start.bundleID, start.onMac ? MacTestGuard.macTestBundleID : MacTestGuard.shippedBundleID)
        XCTAssertEqual(Bundle.main.bundleIdentifier, start.bundleID)
    }

    /// Die App im Testprozess ist leer gestartet: kein aktiver Container, keine Stud.IP-Cookies, keine KI-Ablage
    func testTestProcessStartedWithoutAnyAppData() throws {
        let start = try XCTUnwrap(UniFlowTestsPrincipal.start, "Stand beim Laden des Testbundles fehlt")
        let whose = start.onMac ? "am Mac wären das die echten Daten der installierten App; Tests nur über tools/mac-test.sh"
                                : "die Test-App ist nicht leer (jemand ist darin angemeldet)"
        XCTAssertFalse(start.activeContainer, "Die App hat beim Start einen Container geöffnet – \(whose)")
        XCTAssertEqual(start.containerFolders, 0, "Container-Ordner im Datenordner der App – \(whose)")
        XCTAssertEqual(start.studipCookies, 0, "Stud.IP-Cookies im Schlüsselbund der App – \(whose)")
        XCTAssertEqual(start.tutorFiles, 0, "KI-Ablage im Datenordner der App – \(whose)")
        XCTAssertEqual(start.tutorConversations, 0, "Gespräche in der KI-Ablage der App – \(whose)")
    }
}
#endif
