import UniFlowCore
import XCTest
@testable import UniFlow

/// Store-Build 1.0 nur mit der Leibniz Universitaet Hannover (Entscheidung des Inhabers 07.11.2026; HsH und Uni Hildesheim
/// mit 1.0.1): Hochschulwahl beim ersten Start, "Hochschule wechseln" und der Loeschdialog folgen `UFReleaseUniversities`
/// (Build-Einstellung UF_SHIPPED_UNIVERSITIES -> Info.plist). Der Debug-Host der Tests bietet alle drei an, damit die
/// HsH- und Hildesheim-Tests unveraendert laufen; der Store-Stand wird hier je Fall gesetzt.
@MainActor
final class ReleaseUniversitiesAppTests: XCTestCase {

    override func tearDown() {
        UFReleaseUniversities.reset()
        super.tearDown()
    }

    func testDebugBuildCarriesAllThreeInItsInfoPlist() {
        // project.yml: Debug "luh hildesheim hsh", Release "luh" (tests/test_release_texts.py prueft den Release-Wert)
        let raw = Bundle.main.infoDictionary?[UFReleaseUniversities.infoKey] as? String
        XCTAssertEqual(UFReleaseUniversities.parse(raw), Set(UniversityKey.allCases), "Debug-Host: \(raw ?? "nil")")
        XCTAssertEqual(UFReleaseUniversities.resolve(info: Bundle.main.infoDictionary, debug: false), Set(UniversityKey.allCases))
        XCTAssertEqual(UFReleaseUniversities.resolve(info: [UFReleaseUniversities.infoKey: "luh"], debug: false), [.luh], "Store-Build")
    }

    func testStoreBuildOffersOnlyLUH() {
        UFReleaseUniversities.withShipped(UFReleaseUniversities.storeDefault) {
            XCTAssertEqual(UniversityPickerView.choices(), [.luh], "Hochschulwahl beim ersten Start")
            XCTAssertEqual(UniversitySwitchDialog.choices(current: .luh), [.luh])
            XCTAssertEqual(UniversitySwitchDialog.choices(current: nil), [.luh])
            XCTAssertFalse(UniversitySettingsCard.offersSwitch(current: .luh), "kein Wechsel-Dialog mit einer einzigen Karte")
            XCTAssertTrue(UniversitySettingsCard.offersSwitch(current: nil), "ohne Wahl fuehrt der Dialog zur LUH")
            XCTAssertTrue(UFReleaseUniversities.moreToCome)
            XCTAssertEqual(UniversityPickerView.moreNote, "Weitere Hochschulen folgen mit einem Update.")
            let text = DeleteUniversityDataDialog.explanation(.luh)
            XCTAssertTrue(text.contains("Die Daten anderer Hochschulen bleiben unberührt"), text)
            XCTAssertFalse(text.contains("Hildesheim") || text.contains("Hochschule Hannover"), text)
        }
    }

    func testConnectedOtherUniversityStaysUsableInTheStoreBuild() {
        // Entwickler-iPad mit HsH-Container: bleibt im Wechsel-Dialog und im Loeschdialog, nichts wird geloescht
        UFReleaseUniversities.withShipped([.luh]) {
            XCTAssertEqual(UniversitySwitchDialog.choices(current: .hsh), [.luh, .hsh])
            XCTAssertEqual(UniversitySwitchDialog.choices(current: .hildesheim), [.luh, .hildesheim])
            XCTAssertTrue(UniversitySettingsCard.offersSwitch(current: .hsh))
            XCTAssertTrue(DeleteUniversityDataDialog.explanation(.hsh).contains("Die Daten der Leibniz Universität Hannover bleiben unberührt"))
            XCTAssertTrue(UniversityOption.services(.hsh).contains("Moodle"), "Karte der HsH bleibt beschrieben")
        }
    }

    func testDebugAndUpdate101OfferAllThree() {
        UFReleaseUniversities.withShipped(Set(UniversityKey.allCases)) {
            XCTAssertEqual(UniversityPickerView.choices(), [.luh, .hildesheim, .hsh], "feste Reihenfolge")
            XCTAssertEqual(UniversitySwitchDialog.choices(current: .hildesheim), [.luh, .hildesheim, .hsh])
            XCTAssertTrue(UniversitySettingsCard.offersSwitch(current: .luh))
            XCTAssertFalse(UFReleaseUniversities.moreToCome)
            XCTAssertTrue(DeleteUniversityDataDialog.explanation(.luh).contains("Die Daten der Universität Hildesheim bleiben unberührt"))
        }
    }
}
