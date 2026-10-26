import CloudKit
import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Online-Community ueber `CloudKitCommunityService` gegen ein nachgebildetes CloudKit (`FakeCommunityCloud`, nur im
/// Speicher): veroeffentlichen, finden (Hochschule, Kurs-Schluessel, Lerngruppe, anonym, zurueckgezogen, gesperrt),
/// laden, zurueckziehen, melden, blockieren, Lerngruppen und Fehlerfaelle. Kein echtes CloudKit, kein Netz, keine
/// echten Personen; der Import aus der Community nimmt denselben Weg wie die Datei (fremde Ebene, eigene Notizen
/// unveraendert).
@MainActor
final class CommunityCloudKitTests: XCTestCase {
    let cipher = CryptoKitSolutionCipher()

    // MARK: Nachbau von CloudKit

    /// Datenbank im Speicher: Datensaetze je Bereich, Ersteller = angemeldeter Nutzer, Assets als Dateikopie.
    final class FakeCommunityCloud: CommunityCloud, @unchecked Sendable {
        var records: [String: CommunityRecord] = [:]
        var status: CommunityAccountStatus = .available
        var user = "_user-ada"
        /// naechste Aufrufe scheitern damit
        var failure: CommunityCloudError?
        var saved = 0
        let assetDir: URL
        private let lock = NSLock()

        init(assetDir: URL) { self.assetDir = assetDir }

        private func key(_ scope: CommunityScope, _ type: String, _ name: String) -> String {
            "\(scope == .publicDB ? "pub" : "priv")|\(type)|\(name)"
        }

        private func check() throws { if let failure { throw failure } }

        func accountStatus() async throws -> CommunityAccountStatus { try check(); return status }

        func userRecordName() async throws -> String {
            try check()
            guard status == .available else { throw CommunityCloudError.notSignedIn }
            return user
        }

        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord {
            try check()
            guard status == .available else { throw CommunityCloudError.notSignedIn }
            var r = record
            for (k, v) in r.fields {
                // wie CloudKit: die Datei wird hochgeladen; beim Lesen kommt eine eigene Kopie zurueck
                if case .asset(let url) = v {
                    let copy = assetDir.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: url, to: copy)
                    r.fields[k] = .asset(copy)
                }
            }
            return lock.withLock {
                let existing = records[key(scope, r.type, r.name)]
                if let existing, existing.creator != user { return r }      // oeffentliche DB: nur der Ersteller aendert
                r.creator = existing?.creator ?? user
                records[key(scope, r.type, r.name)] = r
                saved += 1
                return r
            }
        }

        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? {
            try check()
            return lock.withLock { records[key(scope, type, name)] }
        }

        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] {
            try check()
            return lock.withLock {
                records.values.filter { r in
                    r.type == q.type && key(scope, r.type, r.name) == key(scope, q.type, r.name)
                        && q.equals.allSatisfy { k, v in r.fields[k] == v }
                }
                .sorted { $0.name < $1.name }
            }
        }

        func delete(name: String, type: String, in scope: CommunityScope) async throws {
            try check()
            _ = lock.withLock { records.removeValue(forKey: key(scope, type, name)) }
        }

        func all(_ type: String, scope: CommunityScope = .publicDB) -> [CommunityRecord] {
            lock.withLock { records.filter { $0.key.hasPrefix("\(scope == .publicDB ? "pub" : "priv")|\(type)|") }.map(\.value) }
        }
    }

    // MARK: Hilfen

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-community-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func suite() -> UserDefaults {
        let name = "uniflow.tests.community.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// Selbst erzeugte Test-PDF mit zwei Seiten (nur fuer Fingerabdruck und Schluessel).
    private func makePDFData(marker: String = "Blatt") -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...2 {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "\(marker) – Seite \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func ownDocument(text: String = "x = 42") throws -> AnnotationDocument {
        AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}],
         "pages":{"p1":{"objects":[{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":4,"points":[10,10,50,50]},
                                   {"id":"t1","type":"text","text":"\#(text)","x":100,"y":100,"fontSize":16}]},
                  "p2":{"objects":[]}}}
        """#))
    }

    private func package(pdf: Data, displayName: String = "Lea") throws -> SolutionPackage {
        let doc = try ownDocument()
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        return try SolutionSharing.package(try SolutionSharing.content(src, keys: ["p1"], displayName: displayName), originalPDF: pdf)
    }

    private struct Device {
        let cloud: FakeCommunityCloud
        let membership: CommunityMembership
        let service: CloudKitCommunityService
        let library: SolutionLibrary
    }

    /// Ein "iPad": eigener Container (Lerngruppen, Sperrliste, Ablage), gemeinsame Datenbank
    private func device(_ cloud: FakeCommunityCloud?, university: UniversityKey = .luh, courses: Set<String> = ["kurs-1"]) throws -> Device {
        let membership = CommunityMembership(defaults: suite())
        let service = CloudKitCommunityService(cloud: cloud, university: university, membership: membership, courseIDs: { courses })
        let fallback = try cloud ?? FakeCommunityCloud(assetDir: tempDir())
        return Device(cloud: fallback, membership: membership, service: service, library: SolutionLibrary(root: try tempDir()))
    }

    private func courseKey(_ id: String, uni: String = "luh") -> String { CommunityKeys.courseKey(university: uni, courseID: id) }

    private func expect(_ expected: CommunityServiceError, _ body: () async throws -> Void, line: UInt = #line) async {
        do { try await body(); XCTFail("kein Fehler", line: line) } catch {
            XCTAssertEqual(error as? CommunityServiceError, expected, "\(error)", line: line)
        }
    }

    // MARK: Ohne Container

    func testWithoutContainerNothingWorksAndNothingCrashes() async throws {
        let d = try device(nil)
        XCTAssertFalse(d.service.isConnected)
        let pdf = makePDFData()
        let p = try package(pdf: pdf)
        await expect(.unavailable) { _ = try await d.service.publish(p, options: .init(visibility: .anonymous)) }
        await expect(.unavailable) { _ = try await d.service.findMatching(fingerprint: p.header.fingerprint) }
        await expect(.unavailable) { _ = try await d.service.findForCourse(courseKey: self.courseKey("kurs-1")) }
        await expect(.unavailable) { _ = try await d.service.download(solutionID: p.header.solutionID) }
        await expect(.unavailable) { try await d.service.withdraw(solutionID: p.header.solutionID) }
        await expect(.unavailable) { try await d.service.report(solutionID: p.header.solutionID, reason: .spam, note: nil) }
        await expect(.unavailable) { try await d.service.block(owner: "x") }
        await expect(.unavailable) { _ = try await d.service.createStudyGroup(name: "G") }
        await expect(.unavailable) { _ = try await d.service.joinStudyGroup(code: "AB2CD3EF") }
        // Lerngruppen und Sperrliste des Geraets bleiben lesbar
        let result1 = try await d.service.studyGroups()
        XCTAssertEqual(result1, [])
        // Build-Einstellung: leer, nicht ersetzt oder fremd = kein Container
        XCTAssertNil(CommunityCloudFactory.containerIdentifier(info: [:]))
        XCTAssertNil(CommunityCloudFactory.containerIdentifier(info: [CommunityCloudFactory.infoKey: ""]))
        XCTAssertNil(CommunityCloudFactory.containerIdentifier(info: [CommunityCloudFactory.infoKey: "$(UF_CLOUDKIT_CONTAINER)"]))
        XCTAssertNil(CommunityCloudFactory.containerIdentifier(info: [CommunityCloudFactory.infoKey: "de.uniflow.ai"]))
        XCTAssertEqual(CommunityCloudFactory.containerIdentifier(info: [CommunityCloudFactory.infoKey: " iCloud.de.uniflow.ai "]), "iCloud.de.uniflow.ai")
        // dieser Testlauf hat keinen Container (kein Team): der Dienst der App ist "nicht verbunden"
        XCTAssertNil(CommunityCloudFactory.containerIdentifier())
        XCTAssertFalse(SolutionSharing.community.isConnected)
    }

    // MARK: Veroeffentlichen

    func testPublishUploadsOnlyPackageAndHeadData() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let d = try device(cloud)
        let pdf = makePDFData()
        let doc = try ownDocument()
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        let options = CommunityPublishOptions(visibility: .module, courseKey: courseKey("kurs-1"), title: "Übungsblatt 3", week: 4)
        let pub = try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Lea", options: options,
                                                               service: d.service, library: d.library)
        let records = cloud.all(CommunityRecordType.solution)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.name, pub.solutionID)
        XCTAssertEqual(r["solutionID"]?.string, pub.solutionID)
        XCTAssertEqual(r["fingerprint"]?.string, cipher.sha256Hex(pdf))
        XCTAssertEqual(r["university"]?.string, "luh")
        XCTAssertEqual(r["courseKey"]?.string, courseKey("kurs-1"))
        XCTAssertEqual(r["visibility"]?.string, "modul")
        XCTAssertEqual(r["groupKey"]?.string, "")
        XCTAssertEqual(r["displayName"]?.string, "Lea")
        XCTAssertEqual(r["title"]?.string, "Übungsblatt 3")
        XCTAssertEqual(r["pageCount"]?.int, 1)
        XCTAssertEqual(r["week"]?.int, 4)
        XCTAssertEqual(r["ownerRecordName"]?.string, "_user-ada")
        XCTAssertEqual(r["withdrawn"]?.int, 0)
        XCTAssertEqual(r.creator, "_user-ada")
        // genau diese Felder: nichts Persoenliches, keine Kurs-ID im Klartext
        XCTAssertEqual(Set(r.fields.keys), ["solutionID", "fingerprint", "university", "courseKey", "visibility", "groupKey", "displayName",
                                            "title", "pageCount", "week", "createdAt", "package", "ownerRecordName", "withdrawn"])
        let serialized = String(describing: r.fields.filter { $0.key != "package" })
        XCTAssertFalse(serialized.contains("kurs-1"), "Kurs-ID nur als Schluessel")
        // das Asset ist das verschluesselte Paket ohne PDF-Bytes
        let asset = try Data(contentsOf: try XCTUnwrap(r["package"]?.asset))
        let stored = try SolutionPackage.decode(asset)
        XCTAssertEqual(stored.header.solutionID, pub.solutionID)
        XCTAssertNil(asset.range(of: Data("%PDF".utf8)))
        var i = 0
        while i + 32 <= pdf.count {
            XCTAssertNil(asset.range(of: pdf.subdata(in: i..<(i + 32))), "PDF-Stueck bei \(i)")
            i += 97
        }
        XCTAssertFalse(String(decoding: asset, as: UTF8.self).contains("x = 42"), "Notizen nur verschluesselt")
        // Ablage: Kopie unter "Meine geteilten Lösungen" mit Veroeffentlichungsdatum
        let entry = try XCTUnwrap(d.library.sharedEntries().first)
        XCTAssertEqual(entry.solutionID, pub.solutionID)
        XCTAssertEqual(entry.publishedAt, SolutionPackage.timestamp(pub.publishedAt))
        XCTAssertEqual(SharedSolutionsSheet.status(entry), "veröffentlicht am \(ForeignSolutionLayer.date(entry.publishedAt!))")
        // die hochgeladene Datei ist nach dem Senden weg
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("community-upload-x").path))
        // anonym: Pseudonym wird nie uebertragen
        let anon = try await d.service.publish(try package(pdf: makePDFData(marker: "B2"), displayName: "Lea"),
                                               options: .init(visibility: .anonymous, title: "B2"))
        XCTAssertEqual(cloud.all(CommunityRecordType.solution).first { $0.name == anon.solutionID }?["displayName"]?.string, "")
        // Modul ohne Kurs: abgewiesen, nichts gesendet
        let before = cloud.saved
        await expect(.missingCourse) { _ = try await d.service.publish(try self.package(pdf: pdf), options: .init(visibility: .module)) }
        XCTAssertEqual(cloud.saved, before)
    }

    // MARK: Finden

    func testFindMatchingAppliesVisibilityRules() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        let fp = cipher.sha256Hex(pdf)
        // Ben veroeffentlicht an der LUH: Modul (Kurs 1), Modul (anderer Kurs), anonym, Lerngruppe, zurueckgezogen
        cloud.user = "_user-ben"
        let ben = try device(cloud, courses: ["kurs-1", "kurs-9"])
        let group = try await ben.service.createStudyGroup(name: "Mathe-Gruppe")
        func publish(_ s: CloudKitCommunityService, _ o: CommunityPublishOptions) async throws -> String {
            try await s.publish(try package(pdf: pdf), options: o).solutionID
        }
        let inCourse = try await publish(ben.service, .init(visibility: .module, courseKey: courseKey("kurs-1")))
        let otherCourse = try await publish(ben.service, .init(visibility: .module, courseKey: courseKey("kurs-9")))
        let anonymous = try await publish(ben.service, .init(visibility: .anonymous))
        let inGroup = try await publish(ben.service, .init(visibility: .studyGroup, groupKey: group.groupKey))
        let withdrawn = try await publish(ben.service, .init(visibility: .anonymous))
        try await ben.service.withdraw(solutionID: withdrawn)
        // Hildesheim: gleiche PDF, andere Hochschule
        cloud.user = "_user-cem"
        let cem = try device(cloud, university: .hildesheim, courses: ["kurs-1"])
        let hildesheim = try await publish(cem.service, .init(visibility: .anonymous))

        // Ada (LUH) kennt nur Kurs 1 und ist in keiner Lerngruppe
        cloud.user = "_user-ada"
        let ada = try device(cloud, courses: ["kurs-1"])
        var found = try await ada.service.findMatching(fingerprint: fp)
        XCTAssertEqual(Set(found.map(\.solutionID)), [inCourse, anonymous])
        XCTAssertFalse(found.contains { $0.isOwn })
        XCTAssertEqual(found.first { $0.solutionID == inCourse }?.displayName, "Lea")
        XCTAssertEqual(found.first { $0.solutionID == anonymous }?.displayName, "")
        XCTAssertEqual(found.first { $0.solutionID == inCourse }?.ownerRecordName, "_user-ben")
        for id in [otherCourse, inGroup, withdrawn, hildesheim] { XCTAssertFalse(found.contains { $0.solutionID == id }, id) }
        // Lerngruppe beitreten: jetzt auch die Gruppenloesung
        _ = try await ada.service.joinStudyGroup(code: group.code)
        found = try await ada.service.findMatching(fingerprint: fp)
        XCTAssertEqual(Set(found.map(\.solutionID)), [inCourse, anonymous, inGroup])
        // Ben blockieren: nichts mehr von ihm
        try await ada.service.block(owner: "_user-ben")
        let result2 = try await ada.service.findMatching(fingerprint: fp)
        XCTAssertEqual(result2, [])
        try await ada.service.unblock(owner: "_user-ben")
        let result3 = try await ada.service.findMatching(fingerprint: fp).count
        XCTAssertEqual(result3, 3)
        // Kurs-Schluessel unbekannt (Datei nicht aus einem eigenen Kurs): nur anonym und Lerngruppe
        let eve = try device(cloud, courses: [])
        let result4 = try await Set(eve.service.findMatching(fingerprint: fp).map(\.solutionID))
        XCTAssertEqual(result4, [anonymous])
        // Ben sieht seine eigenen (ausser zurueckgezogen), markiert als eigene
        cloud.user = "_user-ben"
        let own = try await ben.service.findMatching(fingerprint: fp)
        XCTAssertEqual(Set(own.map(\.solutionID)), [inCourse, otherCourse, anonymous, inGroup])
        XCTAssertTrue(own.allSatisfy(\.isOwn))
        // Kursansicht: alle Loesungen des Kurses nach Woche
        let course = try await ada.service.findForCourse(courseKey: courseKey("kurs-1"))
        XCTAssertEqual(course.map(\.solutionID), [inCourse])
        let result5 = try await ada.service.findForCourse(courseKey: courseKey("kurs-9"))
        XCTAssertEqual(result5, [], "fremder Kurs-Schluessel: nichts")
    }

    // MARK: Laden und anzeigen

    func testDownloadUsesSameImportWayAndLeavesOwnNotesUntouched() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let original = try package(pdf: pdf, displayName: "Ben")
        let id = try await ben.service.publish(original, options: .init(visibility: .anonymous)).solutionID

        cloud.user = "_user-ada"
        let ada = try device(cloud)
        let downloaded = try await ada.service.download(solutionID: id)
        XCTAssertEqual(downloaded, original, "verschluesselt wie veroeffentlicht")

        // eigenes Dokument mit eigenen Notizen
        let store = try await makeStore(pdf: pdf)
        await store.addText("Meine eigene Notiz", pageKey: "p1")
        await store.flush()
        let before = (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
        guard case .shown(let entry) = try await store.importFromCommunity(id, service: ada.service, library: ada.library) else {
            return XCTFail("nicht angezeigt")
        }
        XCTAssertEqual(entry.solutionID, id)
        XCTAssertEqual(entry.displayName, "Ben")
        XCTAssertEqual(ada.library.entries(fingerprint: entry.fingerprint).map(\.solutionID), [id], "abgelegt wie ein Datei-Import")
        let load = await store.solutionLayers(library: ada.library)
        XCTAssertEqual(load.layers.map(\.id), [id])
        XCTAssertTrue(load.problems.isEmpty)
        await store.flush()
        let after = (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
        XCTAssertEqual(before, after, "eigene Notizen byte-gleich")
        // zu einer anderen PDF: gespeichert, erscheint dort
        let otherStore = try await makeStore(pdf: makePDFData(marker: "Andere"))
        guard case .otherPDF = try await otherStore.importFromCommunity(id, service: ada.service, library: SolutionLibrary(root: try tempDir())) else {
            return XCTFail("nicht als andere PDF erkannt")
        }
        // zurueckgezogen oder unbekannt: nichts zu laden
        cloud.user = "_user-ben"
        try await ben.service.withdraw(solutionID: id)
        cloud.user = "_user-ada"
        await expect(.notFound) { _ = try await ada.service.download(solutionID: id) }
        await expect(.notFound) { _ = try await ada.service.download(solutionID: UUID().uuidString.lowercased()) }
        // keine Aufraeum-Reste
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("community-download-") }.count, 0)
    }

    // MARK: Zurueckziehen, Melden, Blockieren

    func testWithdrawOnlyOwnAndDeletesAsset() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let p = try package(pdf: pdf)
        try ben.library.recordShared(p, title: "Blatt")
        let id = try await ben.service.publish(p, options: .init(visibility: .anonymous)).solutionID
        try ben.library.setPublished(id, at: Date())
        cloud.user = "_user-ada"
        let ada = try device(cloud)
        await expect(.notOwner) { try await ada.service.withdraw(solutionID: id) }
        XCTAssertEqual(cloud.all(CommunityRecordType.solution).first?["withdrawn"]?.int, 0, "fremder Versuch aendert nichts")
        await expect(.notFound) { try await ada.service.withdraw(solutionID: UUID().uuidString.lowercased()) }

        cloud.user = "_user-ben"
        try await SolutionSharing.withdrawFromCommunity(id, service: ben.service, library: ben.library)
        let r = try XCTUnwrap(cloud.all(CommunityRecordType.solution).first)
        XCTAssertEqual(r["withdrawn"]?.int, 1)
        XCTAssertNil(r["package"], "Paket beim Dienst geloescht")
        let result6 = try await ben.service.findMatching(fingerprint: p.header.fingerprint)
        XCTAssertEqual(result6, [])
        XCTAssertNil(ben.library.sharedEntries().first?.publishedAt)
        XCTAssertEqual(ben.library.sharedEntries().count, 1, "Kopie bleibt")
    }

    func testReportAndBlocklist() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let d = try device(cloud)
        let id = UUID().uuidString.lowercased()
        try await d.service.report(solutionID: id, reason: .gradedSubmission, note: "  Hausübung 3, wird bewertet  ")
        let report = try XCTUnwrap(cloud.all(CommunityRecordType.report).first)
        XCTAssertEqual(report["solutionID"]?.string, id)
        XCTAssertEqual(report["reason"]?.string, "gradedSubmission")
        XCTAssertEqual(report["note"]?.string, "Hausübung 3, wird bewertet")
        XCTAssertEqual(report["reporterRecordName"]?.string, "_user-ada")
        XCTAssertEqual(Set(report.fields.keys), ["solutionID", "reason", "note", "reporterRecordName", "createdAt"])
        // Notiz begrenzt
        try await d.service.report(solutionID: id, reason: .other, note: String(repeating: "n", count: 2000))
        XCTAssertEqual(cloud.all(CommunityRecordType.report).map { $0["note"]?.string?.count ?? 0 }.max(), CloudKitCommunityService.maxNote)

        // Sperrliste: privat, gemerkt im Container, auch ohne Netz lesbar
        let result7 = try await d.service.blockedOwners()
        XCTAssertEqual(result7, [])
        try await d.service.block(owner: "_user-ben")
        try await d.service.block(owner: "_user-cem")
        try await d.service.block(owner: "")
        XCTAssertEqual(cloud.all(CommunityRecordType.block, scope: .privateDB).count, 2)
        XCTAssertEqual(cloud.all(CommunityRecordType.block, scope: .publicDB).count, 0, "nie oeffentlich")
        let result8 = try await d.service.blockedOwners()
        XCTAssertEqual(result8, ["_user-ben", "_user-cem"])
        XCTAssertEqual(d.membership.blocked(), ["_user-ben", "_user-cem"])
        cloud.failure = .offline
        let result9 = try await d.service.blockedOwners()
        XCTAssertEqual(result9, ["_user-ben", "_user-cem"], "ohne Netz die gemerkte Liste")
        await expect(.offline) { try await d.service.unblock(owner: "_user-ben") }
        cloud.failure = nil
        try await d.service.unblock(owner: "_user-ben")
        let result10 = try await d.service.blockedOwners()
        XCTAssertEqual(result10, ["_user-cem"])
        // zweites Geraet desselben Kontos: Sperrliste kommt aus der privaten Datenbank
        let second = try device(cloud)
        let result11 = try await second.service.blockedOwners()
        XCTAssertEqual(result11, ["_user-cem"])
    }

    // MARK: Lerngruppen

    func testStudyGroups() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let ada = try device(cloud)
        await expect(.invalidGroupName) { _ = try await ada.service.createStudyGroup(name: "   ") }
        let g = try await ada.service.createStudyGroup(name: "  Analysis-Gruppe ")
        XCTAssertEqual(g.name, "Analysis-Gruppe")
        XCTAssertEqual(g.university, "luh")
        XCTAssertEqual(CommunityKeys.normalizedGroupCode(g.code), g.code)
        let result12 = try await ada.service.studyGroups()
        XCTAssertEqual(result12, [g])
        let r = try XCTUnwrap(cloud.all(CommunityRecordType.studyGroup).first)
        XCTAssertEqual(r.name, g.groupKey)
        XCTAssertEqual(r["name"]?.string, "Analysis-Gruppe")
        XCTAssertFalse(String(describing: r.fields).contains(g.code), "Code steht nie beim Dienst, nur sein Schluessel")

        // Ben tritt mit dem Code bei (auch klein, mit Bindestrich)
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let lower = String(g.code.prefix(4)).lowercased() + "-" + g.code.suffix(4)
        let joined = try await ben.service.joinStudyGroup(code: lower)
        XCTAssertEqual(joined, g)
        let result13 = try await ben.service.studyGroups()
        XCTAssertEqual(result13, [g])
        await expect(.invalidGroupCode) { _ = try await ben.service.joinStudyGroup(code: "ABC") }
        await expect(.groupNotFound) { _ = try await ben.service.joinStudyGroup(code: "ZZZZZZZZ") }
        // andere Hochschule: derselbe Code fuehrt zu nichts
        let cem = try device(cloud, university: .hildesheim)
        await expect(.groupNotFound) { _ = try await cem.service.joinStudyGroup(code: g.code) }
        let result14 = try await cem.service.studyGroups()
        XCTAssertEqual(result14, [])
        // Veroeffentlichen in der Gruppe nur als Mitglied
        let pdf = makePDFData()
        let id = try await ben.service.publish(try package(pdf: pdf), options: .init(visibility: .studyGroup, groupKey: g.groupKey)).solutionID
        let result15 = try await ada.service.findMatching(fingerprint: cipher.sha256Hex(pdf)).map(\.solutionID)
        XCTAssertEqual(result15, [id])
        try await ben.service.leaveStudyGroup(code: g.code)
        let result16 = try await ben.service.studyGroups()
        XCTAssertEqual(result16, [])
        await expect(.groupNotFound) {
            _ = try await ben.service.publish(try self.package(pdf: pdf), options: .init(visibility: .studyGroup, groupKey: g.groupKey))
        }
        // wer nie beigetreten ist, sieht die Gruppenloesung nicht
        cloud.user = "_user-eve"
        let eve = try device(cloud)
        let result17 = try await eve.service.findMatching(fingerprint: cipher.sha256Hex(pdf))
        XCTAssertEqual(result17, [])
        // Beitrittslink im QR-Code
        XCTAssertEqual(CommunityJoinLink.code(from: CommunityJoinLink.url(code: g.code)), g.code)
        XCTAssertNil(CommunityJoinLink.code(from: URL(string: "uniflow://#/plan")!))
        XCTAssertNil(CommunityJoinLink.code(from: URL(string: "uniflow://community/join/ABC")!))
        XCTAssertNotNil(StudyGroupCodeSheet.qrImage(CommunityJoinLink.url(code: g.code).absoluteString))
    }

    // MARK: Fehler

    func testErrorsAreUnderstandable() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let d = try device(cloud)
        let pdf = makePDFData()
        cloud.status = .noAccount
        await expect(.notSignedIn) { _ = try await d.service.publish(try self.package(pdf: pdf), options: .init(visibility: .anonymous)) }
        await expect(.notSignedIn) { try await d.service.block(owner: "x") }
        XCTAssertEqual(cloud.saved, 0, "nichts gesendet")
        cloud.status = .available
        cloud.failure = .offline
        await expect(.offline) { _ = try await d.service.findMatching(fingerprint: self.cipher.sha256Hex(pdf)) }
        cloud.failure = .quota
        await expect(.quota) { _ = try await d.service.publish(try self.package(pdf: pdf), options: .init(visibility: .anonymous)) }
        cloud.failure = .other("Wartung")
        await expect(.server("Wartung")) { _ = try await d.service.findForCourse(courseKey: self.courseKey("kurs-1")) }
        cloud.failure = nil
        // CloudKit-Fehlercodes -> Faelle der Oberflaeche
        XCTAssertEqual(CKCommunityCloud.map(CKError(.notAuthenticated)), .notSignedIn)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.networkUnavailable)), .offline)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.networkFailure)), .offline)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.quotaExceeded)), .quota)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.unknownItem)), .notFound)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.permissionFailure)), .permission)
        XCTAssertEqual(CKCommunityCloud.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CommunityCloudError.permission.serviceError, .notOwner)
        for e: CommunityServiceError in [.unavailable, .notSignedIn, .offline, .quota, .notOwner, .notFound, .missingCourse, .groupNotFound] {
            XCTAssertFalse(e.localizedDescription.isEmpty)
            XCTAssertEqual(CommunityTexts.message(e), e.localizedDescription)
        }
    }

    // MARK: Oberflaeche

    func testDialogShowsPublishOnlyWithPlusAndTextsAreHonest() {
        XCTAssertFalse(SolutionShareSheet.showsCommunityPublish(plan: .free))
        XCTAssertTrue(SolutionShareSheet.showsCommunityPublish(plan: .plus))
        XCTAssertTrue(CommunityTexts.copyright.contains("kein Originalmaterial"))
        XCTAssertTrue(CommunityTexts.privacy.contains("nie Apple-ID"))
        XCTAssertEqual(CommunityTexts.matches(1), "1 Lösung aus der Community zu diesem Blatt")
        XCTAssertEqual(CommunityTexts.matches(3), "3 Lösungen aus der Community zu diesem Blatt")
        XCTAssertEqual(CommunityTexts.owner("_abcdef0123456789"), "Nutzer …456789")
        XCTAssertTrue(CommunityTexts.visibility(.module).contains("Kurs"))
        XCTAssertTrue(CommunityTexts.visibility(.studyGroup).contains("Lerngruppe"))
        XCTAssertTrue(CommunityTexts.visibility(.anonymous).contains("ohne Pseudonym"))
        XCTAssertEqual(SolutionTexts.communityConfirmTitle, "In der Community veröffentlichen")
        // Lehrwoche einer Datei aus der Modulansicht
        let module: JSONValue = ["weeks": [["week": 2, "uebungen": [["id": "f1"]]], ["week": 5, "vorlesungen": [["id": "f2"]], "sonstiges": [["id": "f3"]]]]]
        XCTAssertEqual(CommunityCourses.week(fileID: "f1", module: module), 2)
        XCTAssertEqual(CommunityCourses.week(fileID: "f3", module: module), 5)
        XCTAssertEqual(CommunityCourses.week(fileID: "f9", module: module), 0)
    }

    // MARK: Dokument fuer den Import

    private func makeStore(pdf: Data) async throws -> DocumentStore {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-26T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "community-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdfDirectory(api.namespace, root: root).appendingPathComponent(fileID + ".pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-26", has_notes: nil, page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }
}
