import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wissensbibliothek in der App (20.11.2026): Route und Link, Menuepunkt nur mit Schalter (Standard aus), Suchtreffer
/// mit Sprung zum Abschnitt, Formeln nur zwischen `$…$`, Seite ohne Schalter. Die Bibliothek selbst (Katalog,
/// Kopfdaten, Import, Suche) pruefen die Kern-Tests `KnowledgeLibraryTests` mit der erfundenen Testbibliothek.
@MainActor
final class KnowledgeLibraryAppTests: XCTestCase {

    private var fixture: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("packages/shared-contracts/fixtures/wissensbibliothek")
    }

    func testSettingIsOffByDefault() {
        let d = UserDefaults(suiteName: "wb-test-\(UUID().uuidString)")!
        XCTAssertFalse(d.bool(forKey: KnowledgeLibrarySetting.key))
        XCTAssertEqual(KnowledgeLibrarySetting.key, "knowledgeLibrary.enabled")
    }

    func testRouteHashRoundTripWithUmlautsAndSpaces() {
        let r = UFRoute.knowledge(subject: nil, unit: "Bibliothek/Rechnen-Übungsfach/Wochen/SoSe 2026/Woche 01", file: "02-geloest.md", anchor: "[Q1] Seite 3")
        XCTAssertEqual(UFRoute(hash: r.hash), r)
        XCTAssertEqual(UFRoute(hash: "#/wissen"), .knowledge())
        XCTAssertEqual(UFRoute(hash: "#/wissen?fach=Beispielkunde-f%C3%BCr-Tests"), .knowledge(subject: "Beispielkunde-für-Tests"))
        XCTAssertEqual(r.navKey, "knowledge")
    }

    func testNavItemOnlyWithSwitchAndInLearnGroup() {
        let off = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true)
        XCTAssertFalse(off.contains { $0.id == "knowledge" })
        let on = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, knowledge: true)
        XCTAssertEqual(on.filter { $0.id == "knowledge" }.count, 1)
        let learn = UFNavGroup.groups(on).first { $0.id == "learn" }
        XCTAssertEqual(learn?.items.last?.id, "knowledge")
        XCTAssertEqual(learn?.items.last?.title, "Wissensbibliothek")
        // iPhone: unter "Mehr"
        XCTAssertTrue(UFNavItem.more(visible: on).contains { $0.id == "knowledge" })
        XCTAssertFalse(UFNavItem.more(visible: off).contains { $0.id == "knowledge" })
        XCTAssertTrue(UFNavItem.knowledge.isActive(.knowledge(unit: "x")))
    }

    func testSearchHitsJumpToSection() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wb-app-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = KnowledgeLibraryStore(containerRoot: temp)
        _ = try store.importLibrary(from: fixture)
        let lib = try XCTUnwrap(try store.load())
        let hits = ShellState.knowledgeHits(try lib.search("zitronenfalter"), library: lib)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "[Q1] Seite 1: Titelfolie")
        XCTAssertTrue(hits[0].sub.hasPrefix("Wissensbibliothek · G0001 · "))
        XCTAssertEqual(hits[0].route, .knowledge(unit: "Beispielkunde-für-Tests/G0001", file: "01-erklaert.md", anchor: "s1"))
        XCTAssertEqual(hits[0].icon, "bookmark")
    }

    func testFormulasOnlyLeavesTextAlone() {
        XCTAssertEqual(AIMarkdown.dollarFormulas("ET2_22_F_öffentlich und x^2"), "ET2_22_F_öffentlich und x^2")
        XCTAssertEqual(AIMarkdown.dollarFormulas("Fläche $A = a^2$, Rest a_n"), "Fläche " + MathText.render("$A = a^2$") + ", Rest a_n")
        XCTAssertEqual(AIMarkdown.dollarFormulas("Preis 5 $ und $$x^2$$"), "Preis 5 $ und $$x^2$$")
        XCTAssertEqual(AIMarkdown.dollarFormulas("Preis 5 $ und $x^2$"), "Preis 5 $ und " + MathText.render("$x^2$"))
    }

    func testDateAndTexts() {
        XCTAssertEqual(UFFmt.dateDE("2026-11-20"), "20.11.2026")
        XCTAssertEqual(UFFmt.dateDE("unbekannt"), "unbekannt")
        XCTAssertTrue(KnowledgeTexts.privacy.contains("nicht an eine KI"))
    }

    func testSearchIsEmptyWhenSwitchedOff() async {
        let d = UserDefaults.standard
        let before = d.object(forKey: KnowledgeLibrarySetting.key)
        defer { if let before { d.set(before, forKey: KnowledgeLibrarySetting.key) } else { d.removeObject(forKey: KnowledgeLibrarySetting.key) } }
        d.set(false, forKey: KnowledgeLibrarySetting.key)
        XCTAssertFalse(KnowledgeLibrarySetting.isEnabled)
        let hits = await KnowledgeLibraryCenter.shared.search("zitronenfalter")
        XCTAssertEqual(hits, [])
        let units = await KnowledgeLibraryCenter.shared.units(forTitle: "bsp-folien-teil-a", fileName: nil)
        XCTAssertEqual(units, [])
    }
}
