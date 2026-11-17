import UniFlowCore
import XCTest
@testable import UniFlow

/// Datei-Eingang (18.11.2026): aus, bis der Nutzer zustimmt; die Zustimmung nennt, was nie gesendet wird.
final class CourseFileIntakeAppTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "intake-\(UUID().uuidString)")
    }

    func testOffUntilConsent() {
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults), "ohne Zustimmung aus")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        CourseFileIntakeSetting.set(true, defaults, now: now)
        XCTAssertTrue(CourseFileIntakeSetting.isOn(defaults))
        XCTAssertEqual(defaults.object(forKey: CourseFileIntakeSetting.consentKey) as? Date, now, "Zeitpunkt der Zustimmung gemerkt")
        CourseFileIntakeSetting.set(false, defaults)
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults))
        XCTAssertNil(defaults.object(forKey: CourseFileIntakeSetting.consentKey))
    }

    func testBuildSwitchTurnsEverythingOff() {
        CourseFileIntakeSetting.set(true, defaults)
        CourseFileIntakeSetting.isOffered = false
        defer { CourseFileIntakeSetting.isOffered = true }
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults))
    }

    func testConsentNamesWhatIsNeverSent() {
        let all = CourseFileIntakeSetting.consentPoints.joined(separator: " ")
        for word in ["Name", "Konto", "Notizen", "eigene Dokumente", "Matrikelnummern", "Noten", "WLAN", "Ausschalten", "einmal"] {
            XCTAssertTrue(all.contains(word), word)
        }
    }

    func testNeverRunsUnderTests() {
        XCTAssertTrue(StudIPSync.isUnderTest(), "unter XCTest schickt der Eingang nichts")
    }
}
