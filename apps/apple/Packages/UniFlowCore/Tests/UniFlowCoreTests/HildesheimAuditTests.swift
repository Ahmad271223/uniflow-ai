import Foundation
import XCTest
@testable import UniFlowCore

/// Audit Uni Hildesheim (docs/HILDESHEIM-STAND-2026-11-05.md): Funktionen, die fuer jede Hochschule gleich sein muessen,
/// mit Learnweb-Kurstiteln (erfundene Titel im Format "WiSe 2026/27: 9072 Titel").
final class HildesheimAuditTests: XCTestCase {
    /// Community je Modul: die LSF-Veranstaltungsnummer vor dem Titel trennt Vorlesung und Uebung nicht
    func testCommunityModuleKeyForLearnwebTitles() {
        let lecture = Learnweb.parseCourseTitle("WiSe 2026/27: 9072 Einführung in die Erziehungswissenschaft").title
        let exercise = Learnweb.parseCourseTitle("WiSe 2026/27: 9073 Einführung in die Erziehungswissenschaft - Übung").title
        let k1 = CommunityKeys.moduleKey(university: "hildesheim", courseTitle: lecture)
        let k2 = CommunityKeys.moduleKey(university: "hildesheim", courseTitle: exercise)
        XCTAssertNotNil(k1)
        XCTAssertEqual(k1, k2, "\(CommunityKeys.moduleName(courseTitle: lecture)) / \(CommunityKeys.moduleName(courseTitle: exercise))")
        XCTAssertEqual(k1, CommunityKeys.moduleKey(university: "hildesheim", courseTitle: "Einführung in die Erziehungswissenschaft"))
        XCTAssertNotEqual(k1, CommunityKeys.moduleKey(university: "luh", courseTitle: lecture), "je Hochschule getrennt")
    }
}
