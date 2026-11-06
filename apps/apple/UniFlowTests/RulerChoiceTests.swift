import XCTest
@testable import UniFlow

/// Lineal in der geteilten Ansicht (06.11.2026): links, rechts oder beide statt immer auf beiden Seiten
@MainActor
final class RulerChoiceTests: XCTestCase {
    private func choice() throws -> RulerChoice {
        let suite = "ruler-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return RulerChoice(defaults: d)
    }

    func testWithoutSplitOnlyTheDocumentGetsTheRuler() throws {
        let c = try choice()
        c.target = .right
        XCTAssertTrue(c.applies(primary: true), "ein Dokument: Lineal immer dort")
        XCTAssertFalse(c.applies(primary: false))
    }

    func testSplitWithPrimaryLeft() throws {
        let c = try choice()
        c.setSplit(true, primaryIsLeft: true)
        c.target = .left
        XCTAssertTrue(c.applies(primary: true)); XCTAssertFalse(c.applies(primary: false))
        c.target = .right
        XCTAssertFalse(c.applies(primary: true)); XCTAssertTrue(c.applies(primary: false))
        c.target = .both
        XCTAssertTrue(c.applies(primary: true)); XCTAssertTrue(c.applies(primary: false))
    }

    func testSplitWithPrimaryRightForLeftHanders() throws {
        let c = try choice()
        c.setSplit(true, primaryIsLeft: false)
        c.target = .left
        XCTAssertFalse(c.applies(primary: true), "Hauptdokument steht rechts")
        XCTAssertTrue(c.applies(primary: false))
    }

    func testChoiceIsRemembered() throws {
        let suite = "ruler-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        RulerChoice(defaults: d).target = .both
        XCTAssertEqual(RulerChoice(defaults: d).target, .both)
        XCTAssertEqual(RulerChoice(defaults: try XCTUnwrap(UserDefaults(suiteName: "ruler-leer-\(UUID().uuidString)"))).target, .left)
    }
}
