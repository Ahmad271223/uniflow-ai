import Foundation
import XCTest
@testable import UniFlow

/// Begruessung mit Namen auf der Uebersicht (04.11.2026, docs/WEITERMACHEN-2026-11-04.md): Tageszeit, leerer Name,
/// Kuerzen auf 24 Zeichen, Reihenfolge der Namensquellen und der Rufname je Container. Alle Namen sind erfunden.
final class GreetingAppTests: XCTestCase {
    func testTimeOfDay() {
        XCTAssertEqual(UFGreeting.text(name: "Ahmad", hour: 14), "Hallo Ahmad – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: "Ahmad", hour: 7), "Guten Morgen, Ahmad – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: "Ahmad", hour: 21), "Guten Abend, Ahmad – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.salutation(hour: 0), "Guten Morgen")
        XCTAssertEqual(UFGreeting.salutation(hour: 10), "Guten Morgen")
        XCTAssertEqual(UFGreeting.salutation(hour: 11), "Hallo")
        XCTAssertEqual(UFGreeting.salutation(hour: 17), "Hallo")
        XCTAssertEqual(UFGreeting.salutation(hour: 18), "Guten Abend")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        XCTAssertEqual(UFGreeting.text(name: "Lea", date: d, calendar: cal), "Hallo Lea – lass uns gemeinsam lernen.")
    }

    func testEmptyAndWhitespaceName() {
        XCTAssertEqual(UFGreeting.text(name: nil, hour: 14), "Hallo – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: "", hour: 14), "Hallo – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: "  \n ", hour: 14), "Hallo – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: nil, hour: 8), "Guten Morgen – lass uns gemeinsam lernen.")
        XCTAssertEqual(UFGreeting.text(name: "  Tobi ", hour: 14), "Hallo Tobi – lass uns gemeinsam lernen.")
    }

    func testTruncateAt24() {
        let long = "Maximiliane-Theresa-Charlotte"           // 29 Zeichen
        let shown = UFGreeting.displayName(long)!
        XCTAssertEqual(shown.count, 24)
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual(shown, "Maximiliane-Theresa-Cha…")
        let exact = String(repeating: "a", count: 24)
        XCTAssertEqual(UFGreeting.displayName(exact), exact, "genau 24 bleibt")
        XCTAssertEqual(UFGreeting.displayName("Ümit"), "Ümit")
    }

    func testSourceOrder() {
        XCTAssertEqual(UFGreeting.pick(rufname: "Ahmo", accountName: "Konto", appleGivenName: "Ahmad", appleFullName: "Ahmad Fakih"), "Ahmo")
        XCTAssertEqual(UFGreeting.pick(rufname: " ", accountName: "Konto", appleGivenName: "Ahmad", appleFullName: nil), "Konto")
        XCTAssertEqual(UFGreeting.pick(rufname: nil, accountName: nil, appleGivenName: "Ahmad", appleFullName: "Ahmad Fakih"), "Ahmad")
        XCTAssertEqual(UFGreeting.pick(rufname: nil, accountName: nil, appleGivenName: nil, appleFullName: "Lea Muster"), "Lea")
        XCTAssertNil(UFGreeting.pick(rufname: nil, accountName: "", appleGivenName: "  ", appleFullName: nil))
    }

    /// Rufname je Container; die Vormerkung aus der Begruessung wandert beim ersten Lesen in den Container
    func testRufnamePerContainerAndPending() throws {
        let appSuite = "greet-app-\(UUID().uuidString)", c1Suite = "greet-c1-\(UUID().uuidString)", c2Suite = "greet-c2-\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: appSuite)), c1 = try XCTUnwrap(UserDefaults(suiteName: c1Suite)),
            c2 = try XCTUnwrap(UserDefaults(suiteName: c2Suite))
        addTeardownBlock {
            for s in [appSuite, c1Suite, c2Suite] { UserDefaults().removePersistentDomain(forName: s) }
        }
        Rufname.setPending(" Ahmo ", app: app)
        XCTAssertEqual(Rufname.current(container: nil, app: app), "Ahmo")
        XCTAssertEqual(Rufname.current(container: c1, app: app), "Ahmo", "Vormerkung uebernommen")
        XCTAssertNil(app.string(forKey: Rufname.pendingKey), "Vormerkung geleert")
        XCTAssertNil(Rufname.current(container: c2, app: app), "anderer Container: nichts")
        Rufname.write("Lea", c2)
        XCTAssertEqual(Rufname.current(container: c2, app: app), "Lea")
        XCTAssertEqual(Rufname.current(container: c1, app: app), "Ahmo")
        Rufname.write("   ", c1)
        XCTAssertNil(Rufname.current(container: c1, app: app), "leer entfernt")
    }
}
