import Foundation
import XCTest
@testable import UniFlowCore

/// Community als reine Funktionen (docs/LOESUNGEN-TEILEN.md, Abschnitt 7): Schluesselbildung (Kurs, Lerngruppe),
/// Sichtbarkeitsregeln, Filter (Hochschule, zurueckgezogen, gesperrt), Optionen, Veroeffentlichungsdatum in der
/// Ablage und die Standardimplementierungen des Protokolls. Kein Dienst, kein Netz.
final class CommunityRulesTests: XCTestCase {

    private let luh = "luh", hil = "hildesheim"

    // MARK: Schluessel

    func testCourseKeyIsStableAndDistinct() {
        let k = CommunityKeys.courseKey(university: luh, courseID: "abc123")
        XCTAssertEqual(k, CommunityKeys.courseKey(university: luh, courseID: "abc123"))
        XCTAssertTrue(CommunityKeys.isHex64(k))
        XCTAssertNotEqual(k, CommunityKeys.courseKey(university: hil, courseID: "abc123"), "andere Hochschule, anderer Schluessel")
        XCTAssertNotEqual(k, CommunityKeys.courseKey(university: luh, courseID: "abc124"))
        XCTAssertNotEqual(k, CommunityKeys.courseKey(university: "lu", courseID: "habc123"), "Trennzeichen zwischen den Teilen")
        XCTAssertFalse(k.contains("abc123"), "Kurs-ID steht nie im Klartext im Schluessel")
        // fester Wert: ein anderer Dienst muss dieselben Schluessel bilden (Umzug auf Supabase)
        XCTAssertEqual(k, SolutionSHA256.hex(Data("uniflow.community.course.v1\u{0}luh\u{0}abc123".utf8)))
    }

    func testGroupCodeAndKey() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let code = CommunityKeys.randomGroupCode(using: &rng)
            XCTAssertEqual(code.count, 8)
            XCTAssertTrue(code.allSatisfy { CommunityKeys.groupCodeAlphabet.contains($0) }, code)
            XCTAssertFalse(code.contains("0") || code.contains("O") || code.contains("1") || code.contains("I"), code)
            XCTAssertEqual(CommunityKeys.normalizedGroupCode(code), code)
        }
        XCTAssertEqual(CommunityKeys.normalizedGroupCode(" ab2c-d3ef "), "AB2CD3EF")
        XCTAssertNil(CommunityKeys.normalizedGroupCode("AB2CD3E"), "zu kurz")
        XCTAssertNil(CommunityKeys.normalizedGroupCode("AB2CD3EF9"), "zu lang")
        XCTAssertNil(CommunityKeys.normalizedGroupCode("AB2CD3E0"), "0 nicht im Alphabet")
        XCTAssertNil(CommunityKeys.normalizedGroupCode("AB2CD3EI"))
        XCTAssertNil(CommunityKeys.normalizedGroupCode(""))
        let key = CommunityKeys.groupKey(university: luh, code: "ab2cd3ef")
        XCTAssertEqual(key, CommunityKeys.groupKey(university: luh, code: "AB2C-D3EF"), "normalisiert vor dem Hashen")
        XCTAssertTrue(CommunityKeys.isHex64(key))
        XCTAssertNotEqual(key, CommunityKeys.groupKey(university: hil, code: "AB2CD3EF"))
        XCTAssertEqual(CommunityStudyGroup(code: "AB2CD3EF", name: "Gruppe", university: luh).groupKey, key)
    }

    // MARK: Sichtbarkeit

    private func listing(_ id: String = "s1", uni: String = "luh", course: String = "c", visibility: CommunityVisibility = .module,
                         group: String = "", owner: String = "owner-a", withdrawn: Bool = false,
                         createdAt: String = "2026-10-26T10:00:00Z") -> CommunityListing {
        CommunityListing(solutionID: id, fingerprint: String(repeating: "a", count: 64), university: uni,
                         courseKey: course.isEmpty ? "" : CommunityKeys.courseKey(university: uni, courseID: course),
                         visibility: visibility, groupKey: group.isEmpty ? "" : CommunityKeys.groupKey(university: uni, code: group),
                         displayName: visibility == .anonymous ? "" : "Lea", title: "Blatt 3", pageCount: 2, week: 3,
                         createdAt: createdAt, ownerRecordName: owner, withdrawn: withdrawn)
    }

    private var viewer: CommunityViewer {
        CommunityViewer(university: "luh", courseKeys: [CommunityKeys.courseKey(university: "luh", courseID: "c")],
                        groupKeys: [CommunityKeys.groupKey(university: "luh", code: "AB2CD3EF")], blockedOwners: ["owner-bad"],
                        ownerRecordName: "me")
    }

    func testModuleVisibilityNeedsCourseKey() {
        XCTAssertTrue(CommunityRules.isVisible(listing(), to: viewer))
        XCTAssertFalse(CommunityRules.isVisible(listing(course: "other"), to: viewer), "Kurs-ID unbekannt: nichts zu finden")
        XCTAssertFalse(CommunityRules.isVisible(listing(course: ""), to: viewer), "Modul ohne Kurs")
        var v = viewer
        v.courseKeys = []
        XCTAssertFalse(CommunityRules.isVisible(listing(), to: v))
    }

    func testStudyGroupVisibilityNeedsGroupKey() {
        XCTAssertTrue(CommunityRules.isVisible(listing(visibility: .studyGroup, group: "AB2CD3EF"), to: viewer))
        XCTAssertFalse(CommunityRules.isVisible(listing(visibility: .studyGroup, group: "ZZZZZZZZ"), to: viewer))
        XCTAssertFalse(CommunityRules.isVisible(listing(visibility: .studyGroup, group: ""), to: viewer))
        // Kurs allein reicht bei Lerngruppe nicht
        var v = viewer
        v.groupKeys = []
        XCTAssertFalse(CommunityRules.isVisible(listing(visibility: .studyGroup, group: "AB2CD3EF"), to: v))
    }

    func testAnonymousVisibleWithinUniversityOnly() {
        var v = viewer
        v.courseKeys = []
        v.groupKeys = []
        XCTAssertTrue(CommunityRules.isVisible(listing(course: "", visibility: .anonymous), to: v))
        XCTAssertFalse(CommunityRules.isVisible(listing(uni: hil, course: "", visibility: .anonymous), to: v), "andere Hochschule")
    }

    func testWithdrawnBlockedAndOtherUniversityAreHidden() {
        XCTAssertFalse(CommunityRules.isVisible(listing(withdrawn: true), to: viewer))
        XCTAssertFalse(CommunityRules.isVisible(listing(owner: "owner-bad"), to: viewer), "gesperrter Nutzer")
        XCTAssertFalse(CommunityRules.isVisible(listing(uni: hil, course: "c"), to: viewer))
        // eigene Eintraege immer (ausser zurueckgezogen), auch wenn der Kurs-Schluessel nicht mehr bekannt ist
        var v = viewer
        v.courseKeys = []
        XCTAssertTrue(CommunityRules.isVisible(listing(owner: "me"), to: v))
        XCTAssertFalse(CommunityRules.isVisible(listing(owner: "me", withdrawn: true), to: v))
    }

    func testFilterSortsNewestFirstAndDropsDuplicates() {
        let list = [
            listing("a", createdAt: "2026-10-20T10:00:00Z"),
            listing("b", createdAt: "2026-10-26T10:00:00Z"),
            listing("a", createdAt: "2026-10-20T10:00:00Z"),
            listing("c", course: "other"),
            listing("d", withdrawn: true),
            listing("e", owner: "owner-bad"),
            listing("f", uni: hil),
            listing("g", course: "", visibility: .anonymous, createdAt: "2026-10-23T10:00:00Z"),
        ]
        XCTAssertEqual(CommunityRules.visible(list, to: viewer).map(\.solutionID), ["b", "g", "a"])
    }

    func testEffectiveDisplayNameAndOptions() throws {
        XCTAssertEqual(CommunityRules.effectiveDisplayName("  Lea ", visibility: .module), "Lea")
        XCTAssertEqual(CommunityRules.effectiveDisplayName("Lea", visibility: .anonymous), "", "anonym: nie ein Pseudonym")
        XCTAssertEqual(CommunityRules.effectiveDisplayName(String(repeating: "x", count: 80), visibility: .studyGroup).count,
                       SolutionLimits.maxDisplayName)
        let course = CommunityKeys.courseKey(university: luh, courseID: "c")
        let group = CommunityKeys.groupKey(university: luh, code: "AB2CD3EF")
        XCTAssertNoThrow(try CommunityRules.validate(.init(visibility: .module, courseKey: course)))
        XCTAssertNoThrow(try CommunityRules.validate(.init(visibility: .studyGroup, courseKey: nil, groupKey: group)))
        XCTAssertNoThrow(try CommunityRules.validate(.init(visibility: .anonymous)))
        XCTAssertThrowsError(try CommunityRules.validate(.init(visibility: .module))) {
            XCTAssertEqual($0 as? CommunityServiceError, .missingCourse)
        }
        XCTAssertThrowsError(try CommunityRules.validate(.init(visibility: .module, courseKey: "abc"))) {
            XCTAssertEqual($0 as? CommunityServiceError, .missingCourse)
        }
        XCTAssertThrowsError(try CommunityRules.validate(.init(visibility: .studyGroup, courseKey: course))) {
            XCTAssertEqual($0 as? CommunityServiceError, .groupNotFound)
        }
        XCTAssertEqual(CommunityRules.validGroupName("  Lerngruppe A "), "Lerngruppe A")
        XCTAssertNil(CommunityRules.validGroupName("   "))
        XCTAssertNil(CommunityRules.validGroupName(String(repeating: "n", count: 61)))
        XCTAssertEqual(CommunityVisibility.allCases.map(\.rawValue), ["modul", "lerngruppe", "anonym"])
    }

    func testByWeekPutsUnknownWeekLast() {
        func s(_ id: String, week: Int, at: String) -> CommunitySolutionSummary {
            CommunitySolutionSummary(solutionID: id, fingerprint: "", displayName: "", createdAt: at, pageCount: 1, week: week)
        }
        let grouped = CommunityRules.byWeek([s("a", week: 0, at: "2026-10-26T10:00:00Z"), s("b", week: 3, at: "2026-10-20T10:00:00Z"),
                                             s("c", week: 1, at: "2026-10-21T10:00:00Z"), s("d", week: 3, at: "2026-10-25T10:00:00Z")])
        XCTAssertEqual(grouped.map(\.week), [1, 3, 0])
        XCTAssertEqual(grouped[1].solutions.map(\.solutionID), ["d", "b"])
    }

    // MARK: Ablage

    func testSharedEntryKeepsPublishedAt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-community-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = SolutionLibrary(root: dir)
        let pdf = Data("%PDF-1.4 erfunden".utf8)
        let cipher = TestHMACCipher()
        let content = SolutionContent(solutionID: UUID().uuidString.lowercased(), createdAt: "2026-10-26T10:00:00Z", title: "Blatt",
                                      displayName: "", fingerprint: cipher.sha256Hex(pdf), pdfPageCount: 1,
                                      pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                                           objects: [.object(["type": "stroke", "points": .array([1, 2, 3, 4])])])])
        let package = try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher)
        let id = package.header.solutionID
        try lib.recordShared(package, title: "Blatt")
        XCTAssertNil(lib.sharedEntries().first?.publishedAt)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try lib.setPublished(id, at: at)
        XCTAssertEqual(lib.sharedEntries().first?.publishedAt, SolutionPackage.timestamp(at))
        // erneut als Datei teilen: Datum bleibt
        try lib.recordShared(package, title: "Blatt")
        XCTAssertEqual(lib.sharedEntries().first?.publishedAt, SolutionPackage.timestamp(at))
        // Index neu lesen (zweite Instanz)
        XCTAssertEqual(SolutionLibrary(root: dir).sharedEntries().first?.publishedAt, SolutionPackage.timestamp(at))
        try lib.setPublished(id, at: nil)
        XCTAssertNil(lib.sharedEntries().first?.publishedAt)
        XCTAssertEqual(lib.sharedEntries().count, 1)
    }

    // MARK: Protokoll

    func testProtocolDefaultsReportNotConnected() async throws {
        let service: CommunityService = NotConnectedCommunityService()
        func expectNotConnected(_ body: () async throws -> Void) async {
            do { try await body(); XCTFail("kein Fehler") } catch {
                XCTAssertEqual(error as? CommunityServiceError, .notConnected)
            }
        }
        await expectNotConnected { _ = try await service.findForCourse(courseKey: "x") }
        await expectNotConnected { try await service.block(owner: "x") }
        await expectNotConnected { try await service.unblock(owner: "x") }
        await expectNotConnected { _ = try await service.blockedOwners() }
        await expectNotConnected { _ = try await service.createStudyGroup(name: "x") }
        await expectNotConnected { _ = try await service.joinStudyGroup(code: "AB2CD3EF") }
        await expectNotConnected { try await service.leaveStudyGroup(code: "AB2CD3EF") }
        await expectNotConnected { _ = try await service.studyGroups() }
        // Meldungen sind verstaendlich und nennen den Weg
        XCTAssertEqual(CommunityServiceError.unavailable.localizedDescription, "Die Community ist in diesem Build nicht verfügbar (kein iCloud-Container).")
        XCTAssertTrue(CommunityServiceError.notSignedIn.localizedDescription.contains("iCloud"))
        XCTAssertTrue(CommunityServiceError.offline.localizedDescription.contains("Netz"))
        XCTAssertTrue(CommunityServiceError.quota.localizedDescription.contains("Kontingent"))
        XCTAssertEqual(CommunityReportReason.allCases.count, 5)
    }
}
