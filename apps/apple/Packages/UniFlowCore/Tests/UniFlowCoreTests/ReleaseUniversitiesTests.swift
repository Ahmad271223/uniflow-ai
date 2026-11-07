import Foundation
import XCTest
@testable import UniFlowCore

/// Schalter der ausgelieferten Hochschulen (`UFReleaseUniversities`, Entscheidung des Inhabers 07.11.2026: 1.0 nur LUH,
/// HsH und Uni Hildesheim mit 1.0.1). Ohne Bundle, ohne Netz.
final class ReleaseUniversitiesTests: XCTestCase {

    override func tearDown() {
        UFReleaseUniversities.reset()
        super.tearDown()
    }

    func testParseAcceptsListsAndAll() {
        XCTAssertEqual(UFReleaseUniversities.parse("luh"), [.luh])
        XCTAssertEqual(UFReleaseUniversities.parse("luh hildesheim hsh"), [.luh, .hildesheim, .hsh])
        XCTAssertEqual(UFReleaseUniversities.parse("luh,hsh"), [.luh, .hsh])
        XCTAssertEqual(UFReleaseUniversities.parse(" LUH ; Hildesheim "), [.luh, .hildesheim], "ohne Gross-/Kleinschreibung")
        XCTAssertEqual(UFReleaseUniversities.parse("all"), Set(UniversityKey.allCases))
        XCTAssertEqual(UFReleaseUniversities.parse("luh tuebingen"), [.luh], "Unbekanntes zaehlt nicht")
        XCTAssertNil(UFReleaseUniversities.parse(""))
        XCTAssertNil(UFReleaseUniversities.parse("   "))
        XCTAssertNil(UFReleaseUniversities.parse("tuebingen"), "nur Unbekanntes: naechste Quelle, nie still alle")
        XCTAssertNil(UFReleaseUniversities.parse(nil))
    }

    func testStoreDefaultIsOnlyLUH() {
        XCTAssertEqual(UFReleaseUniversities.storeDefault, [.luh])
        XCTAssertEqual(UFReleaseUniversities.resolve(), [.luh], "ohne jede Angabe der Store-Stand")
        XCTAssertEqual(UFReleaseUniversities.resolve(info: ["UFShippedUniversities": ""]), [.luh], "leere Build-Einstellung")
        XCTAssertEqual(UFReleaseUniversities.resolve(info: ["UFShippedUniversities": "$(UF_SHIPPED_UNIVERSITIES)"]), [.luh],
                       "nicht ersetzte Variable")
    }

    func testInfoPlistDrivesReleaseAndDebugOverridesOnlyInDebug() {
        let info: [String: Any] = ["UFShippedUniversities": "luh hildesheim hsh"]
        XCTAssertEqual(UFReleaseUniversities.resolve(info: info, debug: false), [.luh, .hildesheim, .hsh])
        XCTAssertEqual(UFReleaseUniversities.resolve(info: ["UFShippedUniversities": "luh"], debug: false), [.luh])
        // Umgebung und Startargument uebersteuern nur in Debug-Builds
        let env = ["UF_SHIPPED_UNIVERSITIES": "luh hsh"]
        XCTAssertEqual(UFReleaseUniversities.resolve(environment: env, info: ["UFShippedUniversities": "luh"], debug: true), [.luh, .hsh])
        XCTAssertEqual(UFReleaseUniversities.resolve(environment: env, info: ["UFShippedUniversities": "luh"], debug: false), [.luh])
        XCTAssertEqual(UFReleaseUniversities.resolve(launchArgument: "all", environment: env, info: info, debug: true),
                       Set(UniversityKey.allCases), "Startargument vor Umgebung")
        XCTAssertEqual(UFReleaseUniversities.resolve(launchArgument: "all", debug: false), [.luh])
        XCTAssertEqual(UFReleaseUniversities.resolve(launchArgument: "quatsch", environment: env, debug: true), [.luh, .hsh],
                       "ungueltiges Startargument: naechste Quelle")
    }

    func testChoicesKeepTheCurrentUniversityAndOrder() {
        UFReleaseUniversities.withShipped([.luh]) {
            XCTAssertEqual(UFReleaseUniversities.choices(), [.luh])
            XCTAssertEqual(UFReleaseUniversities.choices(current: .luh), [.luh])
            XCTAssertEqual(UFReleaseUniversities.choices(current: .hsh), [.luh, .hsh], "verbundenes HsH-Konto bleibt waehlbar")
            XCTAssertTrue(UFReleaseUniversities.isShipped(.luh))
            XCTAssertFalse(UFReleaseUniversities.isShipped(.hildesheim))
            XCTAssertTrue(UFReleaseUniversities.moreToCome)
        }
        UFReleaseUniversities.withShipped([.hsh, .luh, .hildesheim]) {
            XCTAssertEqual(UFReleaseUniversities.choices(), UniversityKey.allCases, "feste Reihenfolge wie allCases")
            XCTAssertFalse(UFReleaseUniversities.moreToCome)
        }
    }

    /// `/api/services` nennt unter "universities" nur die Hochschulen dieses Builds, dazu immer die der Datenbank
    func testServicesEndpointListsOnlyShippedUniversities() async throws {
        let clock = UniFlowClock.fixed(berlin: "2026-11-07T14:10:00")!
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func universities(_ b: LocalBackend) async -> [String] {
            let r = await b.handle(LocalRequest(method: "GET", path: "/api/services"))
            return r.json?["universities"]?.array?.compactMap { $0["key"]?.string } ?? []
        }
        UFReleaseUniversities.shipped = [.luh]
        let luhOnly = await universities(backend)
        XCTAssertEqual(luhOnly, ["luh"], "Store-Build 1.0")
        UFReleaseUniversities.shipped = Set(UniversityKey.allCases)
        let all = await universities(backend)
        XCTAssertEqual(all, ["luh", "hildesheim", "hsh"], "Debug und 1.0.1")
        // Datenbank einer nicht ausgelieferten Hochschule (Entwickler-iPad; die Hochschule steht beim Oeffnen fest):
        // sie bleibt in der Liste
        let hsh = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "hsh")
        UFReleaseUniversities.shipped = [.luh]
        let withHsH = await universities(hsh)
        XCTAssertEqual(withHsH, ["luh", "hsh"])
    }

    func testWithShippedRestoresThePreviousState() {
        UFReleaseUniversities.shipped = [.hildesheim]
        UFReleaseUniversities.withShipped([.luh]) { XCTAssertEqual(UFReleaseUniversities.shipped, [.luh]) }
        XCTAssertEqual(UFReleaseUniversities.shipped, [.hildesheim])
        UFReleaseUniversities.reset()
        XCTAssertEqual(UFReleaseUniversities.shipped, UFReleaseUniversities.resolve(
            launchArgument: UserDefaults.standard.string(forKey: UFReleaseUniversities.launchArgumentKey),
            environment: ProcessInfo.processInfo.environment, info: Bundle.main.infoDictionary), "nach reset wieder der Prozess-Stand")
    }
}
