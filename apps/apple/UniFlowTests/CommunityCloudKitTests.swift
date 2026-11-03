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
                records.filter { entry in
                    entry.key == key(scope, q.type, entry.value.name) && q.equals.allSatisfy { k, v in entry.value.fields[k] == v }
                        && q.anyOf.allSatisfy { k, values in entry.value.fields[k]?.string.map(values.contains) ?? false }
                }
                .map(\.value)
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

    /// Ein "iPad": eigener Container (Lerngruppen, Sperrliste, Ablage), gemeinsame Datenbank. `courses` sind Kurs-IDs,
    /// `courseNames` Kurstitel bzw. Modulnamen der lokalen Datenbank (werden zu Kurs-Schluesseln)
    private func device(_ cloud: FakeCommunityCloud?, university: UniversityKey = .luh, courses: Set<String> = ["kurs-1"],
                        courseNames: Set<String> = []) throws -> Device {
        let membership = CommunityMembership(defaults: suite())
        let keys = Set(courses.map { CommunityKeys.courseKey(university: university.rawValue, courseID: $0) })
            .union(courseNames.compactMap { CommunityKeys.courseKey(university: university.rawValue, courseName: $0) })
        let service = CloudKitCommunityService(cloud: cloud, university: university, membership: membership, courseKeys: { keys },
                                               courses: { [.course(university: university.rawValue, id: "kurs-1", title: "Lineare Algebra")] })
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
        // Ohne Team hat der Build keinen Container: der Dienst der App ist "nicht verbunden". Mit Team (Config/Team.xcconfig,
        // nicht im Repo) setzt der Build den Container; dann nur pruefen, dass es der richtige ist
        if let id = CommunityCloudFactory.containerIdentifier() {
            XCTAssertEqual(id, "iCloud.de.uniflow.ai", "mit Team: Container aus der Build-Einstellung")
        } else {
            XCTAssertFalse(SolutionSharing.community.isConnected)
        }
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
                                                               space: .course(university: "luh", id: "kurs-1", title: "Lineare Algebra"), service: d.service, library: d.library)
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
        // die hochgeladene Datei (Zwischenspeicher des Containers, AppTemp) ist nach dem Senden weg
        let uploads = AppTemp.folder(container: nil).appendingPathComponent("community-upload", isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: uploads.path))?.count ?? 0, 0)
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
        // keine Aufraeum-Reste: das geladene Paket lag im Zwischenspeicher des Containers (AppTemp) und ist weg
        let downloads = AppTemp.folder(container: nil).appendingPathComponent("community-download", isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.count ?? 0, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("community-download-") }.count, 0, "nicht mehr im gemeinsamen tmp-Ordner")
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
        XCTAssertTrue(CommunityTexts.visibility(.module).contains("Modul"))
        XCTAssertTrue(CommunityTexts.visibility(.studyGroup).contains("Lerngruppe"))
        XCTAssertTrue(CommunityTexts.visibility(.anonymous).contains("ohne Pseudonym"))
        XCTAssertEqual(SolutionTexts.communityConfirmTitle, "In der Community veröffentlichen")
        // Lehrwoche einer Datei aus der Modulansicht
        let module: JSONValue = ["weeks": [["week": 2, "uebungen": [["id": "f1"]]], ["week": 5, "vorlesungen": [["id": "f2"]], "sonstiges": [["id": "f3"]]]]]
        XCTAssertEqual(CommunityCourses.week(fileID: "f1", module: module), 2)
        XCTAssertEqual(CommunityCourses.week(fileID: "f3", module: module), 5)
        XCTAssertEqual(CommunityCourses.week(fileID: "f9", module: module), 0)
    }

    // MARK: Kurs-Schluessel aus Kurs-ID oder Kursname (Entscheidung des Inhabers 26.10.2026)

    func testOwnDocumentPublishesUnderModuleNameAndCourseTitleFindsIt() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        let fp = cipher.sha256Hex(pdf)
        // Ben hat ein eigenes Dokument im Modul "Analysis I" (keine Kurs-ID): Sichtbarkeit Modul ueber den Namen
        cloud.user = "_user-ben"
        let ben = try device(cloud, courses: [], courseNames: ["Analysis I"])
        let nameKey = try XCTUnwrap(CommunityKeys.courseKey(university: "luh", courseName: "Analysis I"))
        let id = try await ben.service.publish(try package(pdf: pdf), options: .init(visibility: .module, courseKey: nameKey)).solutionID
        XCTAssertFalse(String(describing: cloud.all(CommunityRecordType.solution).first?.fields).contains("Analysis"), "Kursname nur als Schluessel")
        // Ada hat den Stud.IP-Kurs "analysis i" (andere Schreibweise) – findet sie
        cloud.user = "_user-ada"
        let ada = try device(cloud, courses: ["kurs-7"], courseNames: ["ANALYSIS I"])
        let found = try await ada.service.findMatching(fingerprint: fp).map(\.solutionID)
        XCTAssertEqual(found, [id])
        let course = try await ada.service.findForCourse(courseKey: nameKey).map(\.solutionID)
        XCTAssertEqual(course, [id])
        // Eve kennt weder Kurs noch Namen: nichts
        let eve = try device(cloud, courses: ["kurs-7"], courseNames: ["Analysis II"])
        let none = try await eve.service.findMatching(fingerprint: fp)
        XCTAssertEqual(none, [])
        // Schluessel eines Moduls aus der Detailansicht: Vorlesung und Uebung ergeben einen, ohne den Pseudokurs
        let detail: JSONValue = ["module": ["name": "Analysis I"], "courses": [["id": "kurs-7", "title": "Analysis I"], ["id": "__user__", "title": "Eigene"],
                                                                               ["id": "kurs-8", "title": "Übung: Analysis I"]]]
        XCTAssertEqual(CommunityCourses.courseKeys(module: detail, university: "luh"), [nameKey])
        XCTAssertEqual(CommunityCourses.courseKeys(module: ["module": ["name": "  "]], university: "luh"), [])
    }

    func testFingerprintsOnlyFromOwnSyncedPDFs() async throws {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-26T14:30:05")!)
        let backend = try await host.backend()
        let sha = { (c: Character) in String(repeating: c, count: 64) }
        try await backend.context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('kurs-1', 'Lineare Algebra', 'vorlesung', 1)")
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('kurs-2', 'Analysis', 'vorlesung', 1)")
            for (id, course, name, url, hash, deleted) in [
                ("a", "kurs-1", "Blatt.pdf", "https://x/1", sha("a"), nil), ("b", "kurs-2", "Blatt.PDF", "https://x/2", sha("b"), nil),
                ("c", "__user__", "Eigen.pdf", "https://x/3", sha("c"), nil), ("d", "kurs-1", "Weg.pdf", "https://x/4", sha("d"), "2026-10-26"),
                ("e", "kurs-1", "Video.mp4", "https://x/5", sha("e"), nil), ("f", "kurs-1", "Ohne.pdf", "", sha("f"), nil),
            ] as [(String, String, String, String, String, String?)] {
                try c.execute("INSERT INTO files(id, course_id, name, download_url, content_sha256, deleted_at) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(course), .text(name), .text(url), .text(hash), deleted.map(SQLiteValue.text) ?? .null])
            }
        }
        let local = await CommunityCourses.localFingerprints(host: host)
        XCTAssertEqual(local, [sha("a"), sha("b")], "keine eigenen, geloeschten, fremden oder Nicht-PDFs")
    }

    func testCommunityReachesMembersOnlyAndOpensWithoutThePDF() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let defaults = UserDefaults(suiteName: "community-" + UUID().uuidString)
        let membership = CommunityMembership(defaults: defaults)
        let course = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Analysis")
        let service = CloudKitCommunityService(cloud: cloud, university: .luh, membership: membership,
                                               courseKeys: { membership.joinedCourses() }, courses: { [course] })
        let start = try await service.communities()
        XCTAssertEqual(start.map(\.joined), [false])
        do { _ = try await service.solutions(in: course); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notAMember) }
        try await service.join(course)
        var joined = course
        joined.joined = true
        let after = try await service.communities()
        XCTAssertEqual(after.map(\.joined), [true])
        let list = try await service.solutions(in: joined)
        XCTAssertEqual(list, [])
        try await service.leave(joined)
        XCTAssertTrue(membership.joinedCourses().isEmpty)
    }

    func testCommentStaysOnThePageAndRowNamesCounts() {
        XCTAssertEqual(CommunityReaderPage.clamped(-0.2), 0)
        XCTAssertEqual(CommunityReaderPage.clamped(1.4), 1)
        XCTAssertEqual(CommunityReaderPage.clamped(.nan), 0)
        var s = CommunitySolutionSummary(solutionID: "1", fingerprint: "f", displayName: "Lea", createdAt: "2026-10-26T10:00:00Z", pageCount: 1)
        s.likes = 1
        s.commentCount = 2
        XCTAssertTrue(CommunitySpaceSheet.detail(s, account: true).hasSuffix("1 Like · 2 Kommentare"))
        XCTAssertFalse(CommunitySpaceSheet.detail(s, account: false).contains("Like"), "ohne Konto keine Zahlen, die es nicht gibt")
    }

    func testAccountTextsDoNotPromiseThePDFAsTheOnlyWay() {
        XCTAssertTrue(CommunityTexts.visibilityMembers.contains("leeren Seiten"))
        XCTAssertFalse(CommunityPage.howItWorks.contains { $0.text.contains("Modul oder") })
    }

    /// Communities des aktuellen Semesters vorn, fruehere nur hinter "Frühere Kurse" (03.11.2026); ein Modul mit einem
    /// aktuellen Kurs zaehlt als aktuell
    func testSpacesMarkOlderSemesterModules() async throws {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-26T14:30:05")!)
        let backend = try await host.backend()
        try await backend.context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('a', 'Messtechnik I', 'vorlesung', 1)")
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('b', 'Mathematik I', 'vorlesung', 0)")
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('c', 'Messtechnik I (Übung)', 'uebung', 0)")
        }
        let spaces = await CommunityCourses.spaces(host: host, university: "luh")
        XCTAssertEqual(spaces.map(\.name).sorted(), spaces.map(\.name))
        XCTAssertEqual(spaces.first { $0.name.hasPrefix("Mathematik") }?.current, false)
        XCTAssertEqual(spaces.first { $0.name.hasPrefix("Messtechnik") }?.current, true, "Vorlesung aktuell, Übung alt: aktuell")
        XCTAssertEqual(spaces.count, 2)
        XCTAssertTrue(CommunitySpacesCard.detail(spaces.first { !$0.current }!).contains("früheres Semester"))
    }

    func testCourseKeysComeFromTheLocalDatabase() async throws {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-26T14:30:05")!)
        let backend = try await host.backend()
        try await backend.context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, kind, active) VALUES ('kurs-1', 'Lineare Algebra (WS 2026/27)', 'vorlesung', 1)")
            try c.execute("INSERT INTO modules(id, name, created_at) VALUES (5, 'Analysis I', '2026-10-26')")
            try c.execute("INSERT INTO folders(id, name, parent_id, module_id, created_at) VALUES (9, 'Eigene Notizen', NULL, 5, '2026-10-26')")
            try c.execute("INSERT INTO files(id, course_id, name, folder_id) VALUES ('f-studip', 'kurs-1', 'Blatt 1.pdf', NULL)")
            try c.execute("INSERT INTO files(id, course_id, name, folder_id) VALUES ('f-own', '__user__', 'Notizbuch', 9)")
            try c.execute("INSERT INTO files(id, course_id, name, folder_id) VALUES ('f-loose', '__user__', 'Lose.pdf', NULL)")
        }
        let titleKey = try XCTUnwrap(CommunityKeys.moduleKey(university: "luh", courseTitle: "Lineare Algebra (WS 2026/27)"))
        let moduleKey = try XCTUnwrap(CommunityKeys.courseKey(university: "luh", courseName: "Analysis I"))
        // Datei aus dem Abgleich: Modul ihres Kurses; eigenes Dokument nur in einem Modul aus dem Abgleich (03.11.2026:
        // nur wer das Modul hat oder hatte), "Analysis I" ist selbst angelegt; ohne beides: nichts
        let studip = await CommunityCourses.courseKey(fileID: "f-studip", host: host, university: "luh")
        XCTAssertEqual(studip, titleKey)
        let own = await CommunityCourses.courseKey(fileID: "f-own", host: host, university: "luh")
        XCTAssertNil(own)
        let loose = await CommunityCourses.courseKey(fileID: "f-loose", host: host, university: "luh")
        XCTAssertNil(loose)
        let unknown = await CommunityCourses.courseKey(fileID: "nope", host: host, university: "luh")
        XCTAssertNil(unknown)
        // der Suchende kennt nur die Module seiner Kurse aus dem Abgleich, keine selbst angelegten Modulnamen
        let keys = await CommunityCourses.courseKeys(host: host, university: "luh")
        XCTAssertEqual(keys, [titleKey])
        XCTAssertFalse(keys.contains(moduleKey))
        // eigenes Dokument in einem Modul mit dem Namen eines Abgleich-Moduls: dessen Community
        let synced = CommunityKeys.moduleName(courseTitle: "Lineare Algebra (WS 2026/27)")
        try await backend.context.database.withConnection { c in
            try c.execute("INSERT INTO modules(id, name, created_at) VALUES (6, ?, '2026-10-26')", [.text(synced)])
            try c.execute("INSERT INTO folders(id, name, parent_id, module_id, created_at) VALUES (10, 'Notizen', NULL, 6, '2026-10-26')")
            try c.execute("INSERT INTO files(id, course_id, name, folder_id) VALUES ('f-own2', '__user__', 'Notizbuch 2', 10)")
        }
        let own2 = await CommunityCourses.courseKey(fileID: "f-own2", host: host, university: "luh")
        XCTAssertEqual(own2, titleKey)
        XCTAssertFalse(keys.contains(CommunityKeys.courseKey(university: "luh", courseID: "__user__")))
    }

    // MARK: Besitzer vom Dienst, Sperren durch den Inhaber

    func testOwnerIsTheCreatorSetByTheServiceNotTheField() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        let fp = cipher.sha256Hex(pdf)
        // Eve veroeffentlicht und faelscht danach das Feld ownerRecordName auf Ben
        cloud.user = "_user-eve"
        let eve = try device(cloud)
        let id = try await eve.service.publish(try package(pdf: pdf), options: .init(visibility: .anonymous)).solutionID
        for (k, stored) in cloud.records where stored.name == id {
            var r = stored
            r[CloudKitCommunityService.Field.owner] = .string("_user-ben")
            cloud.records[k] = r
        }
        // Ben sieht sie nicht als eigene, Ada ordnet sie Eve zu und kann Eve blockieren
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let seenByBen = try await ben.service.findMatching(fingerprint: fp)
        XCTAssertEqual(seenByBen.map(\.isOwn), [false])
        XCTAssertEqual(seenByBen.first?.ownerRecordName, "_user-eve")
        await expect(.notOwner) { try await ben.service.withdraw(solutionID: id) }
        cloud.user = "_user-ada"
        let ada = try device(cloud)
        try await ada.service.block(owner: "_user-eve")
        let hidden = try await ada.service.findMatching(fingerprint: fp)
        XCTAssertEqual(hidden, [])
        // Eve selbst darf zurueckziehen
        cloud.user = "_user-eve"
        try await eve.service.withdraw(solutionID: id)
        XCTAssertEqual(cloud.all(CommunityRecordType.solution).first?["withdrawn"]?.int, 1)
        // CloudKit meldet fuer eigene Datensaetze "__defaultOwner__": das ist der Nutzer selbst
        var r = CommunityRecord(type: CommunityRecordType.solution, name: "x", creator: CloudKitCommunityService.defaultOwner)
        r[CloudKitCommunityService.Field.owner] = .string("_user-eve")
        XCTAssertEqual(CloudKitCommunityService.owner(r, me: "_user-ada"), "_user-ada")
        r.creator = nil
        XCTAssertEqual(CloudKitCommunityService.owner(r, me: "_user-ada"), "_user-eve", "ohne Ersteller zaehlt das Feld")
    }

    func testBanFromDashboardHidesUserEverywhere() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        let fp = cipher.sha256Hex(pdf)
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let id = try await ben.service.publish(try package(pdf: pdf), options: .init(visibility: .anonymous)).solutionID
        cloud.user = "_user-ada"
        let visible = try await device(cloud).service.findMatching(fingerprint: fp).map(\.solutionID)
        XCTAssertEqual(visible, [id])
        // der Inhaber legt im Dashboard einen Ban-Datensatz an (die App schreibt ihn nie)
        cloud.user = "_owner"
        var ban = CommunityRecord(type: CommunityRecordType.ban, name: "ban-_user-ben")
        ban[CloudKitCommunityService.Field.owner] = .string("_user-ben")
        try await cloud.save(ban, in: .publicDB)
        cloud.user = "_user-ada"
        let ada = try device(cloud)
        let afterBan = try await ada.service.findMatching(fingerprint: fp)
        XCTAssertEqual(afterBan, [])
        await expect(.notFound) { _ = try await ada.service.download(solutionID: id) }
        XCTAssertEqual(ada.membership.blocked(), [], "Ban ist keine eigene Sperre")
        // Ben sieht seine eigene weiterhin (und kann sie zurueckziehen)
        cloud.user = "_user-ben"
        let own = try await ben.service.findMatching(fingerprint: fp).map(\.isOwn)
        XCTAssertEqual(own, [true])
        XCTAssertEqual(cloud.all(CommunityRecordType.ban).count, 1)
    }

    // MARK: Ablauf ueber zwei iPads

    func testFlowPublishFindLoadWithdraw() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let pdf = makePDFData()
        let fp = cipher.sha256Hex(pdf)
        let matches = CommunityMatches.shared
        matches.invalidate()
        // Ben veroeffentlicht fuer seinen Kurs
        cloud.user = "_user-ben"
        let ben = try device(cloud)
        let src = SolutionSource(document: try ownDocument(text: "Lösungsweg"), originalPDF: pdf, pdf: PDFDocument(data: pdf)!,
                                 fingerprint: fp, images: [:], title: "Übungsblatt 3")
        let pub = try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Ben",
                                                               options: .init(visibility: .module, courseKey: courseKey("kurs-1"), title: "Übungsblatt 3"),
                                                               space: .course(university: "luh", id: "kurs-1", title: "Lineare Algebra"), service: ben.service, library: ben.library)
        // Ada (gleicher Kurs) findet sie beim Oeffnen des Blatts, laedt sie und sieht die fremde Ebene
        cloud.user = "_user-ada"
        let ada = try device(cloud)
        let found = try await matches.load(fingerprint: fp, service: ada.service, force: true)
        XCTAssertEqual(found.map(\.solutionID), [pub.solutionID])
        XCTAssertEqual(CommunityTexts.matches(found.count), "1 Lösung aus der Community zu diesem Blatt")
        let store = try await makeStore(pdf: pdf)
        guard case .shown = try await store.importFromCommunity(pub.solutionID, service: ada.service, library: ada.library) else {
            return XCTFail("nicht angezeigt")
        }
        let layers = await store.solutionLayers(library: ada.library).layers
        XCTAssertEqual(layers.map(\.id), [pub.solutionID])
        XCTAssertEqual(layers.first?.displayName, "Ben")
        // Ben zieht zurueck: aus dem Zwischenspeicher sofort, beim Dienst als zurueckgezogen, Ada findet nichts mehr
        cloud.user = "_user-ben"
        try await SolutionSharing.withdrawFromCommunity(pub.solutionID, service: ben.service, library: ben.library)
        XCTAssertEqual(matches.cached(fp), [])
        cloud.user = "_user-ada"
        let again = try await matches.load(fingerprint: fp, service: ada.service, force: true)
        XCTAssertEqual(again, [])
        // die schon geladene Ebene bleibt bei Ada (ehrlich im Dialog gesagt)
        let still = await store.solutionLayers(library: ada.library).layers
        XCTAssertEqual(still.map(\.id), [pub.solutionID])
    }

    // MARK: Eine Loesung je PDF und Community (03.11.2026)

    /// Erneut teilen zu derselben PDF: der Dialog fragt "Aktualisieren?" statt eine zweite Loesung anzulegen; mit Ja
    /// kommen die neuen Seiten zur bisherigen Loesung dazu (gleiche ID, gleicher Datensatz).
    func testSharingAgainAsksToUpdateAndMergesIntoTheSameSolution() async throws {
        XCTAssertEqual(SolutionTexts.updateQuestion, "Du hast zu dieser PDF schon eine Lösung geteilt. Aktualisieren?")
        XCTAssertEqual(CommunityServiceError.alreadyPublished("x").errorDescription, SolutionTexts.updateQuestion)
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let d = try device(cloud)
        let pdf = makePDFData()
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}],
         "pages":{"p1":{"objects":[{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":4,"points":[10,10,50,50]}]},
                  "p2":{"objects":[{"id":"t2","type":"text","text":"Seite 2","x":100,"y":100,"fontSize":16}]}}}
        """#))
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        let options = CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Übungsblatt 3", communityKey: space.key)
        // erstes Mal: veroeffentlicht, keine Frage
        guard case .published(let first) = try await SolutionSharing.publishOrAskUpdate(src, keys: ["p1"], displayName: "Lea", options: options,
                                                                                       space: space, service: d.service, library: d.library) else {
            return XCTFail("erstes Teilen fragt nicht")
        }
        let own = try await d.service.ownSolution(fingerprint: src.fingerprint, communityKey: space.key)
        XCTAssertEqual(own?.solutionID, first.solutionID)
        let elsewhere = try await d.service.ownSolution(fingerprint: src.fingerprint, communityKey: courseKey("kurs-2"))
        XCTAssertNil(elsewhere, "andere Community: keine eigene Loesung")
        // zweites Mal (andere Seite): Frage, nichts gesendet, keine zweite Kopie
        let saved = cloud.saved
        let step = try await SolutionSharing.publishOrAskUpdate(src, keys: ["p2"], displayName: "Lea", options: options,
                                                                space: space, service: d.service, library: d.library)
        XCTAssertEqual(step, .askUpdate(solutionID: first.solutionID))
        XCTAssertEqual(cloud.saved, saved)
        XCTAssertEqual(d.library.sharedEntries().map(\.solutionID), [first.solutionID])
        // auch ohne Pruefung vorab weist der Dienst ein Doppel ab, die angelegte Kopie verschwindet wieder
        await expect(.alreadyPublished(first.solutionID)) {
            _ = try await SolutionSharing.publishToCommunity(src, keys: ["p2"], displayName: "Lea", options: options, space: space,
                                                              service: d.service, library: d.library)
        }
        XCTAssertEqual(cloud.all(CommunityRecordType.solution).count, 1)
        XCTAssertEqual(d.library.sharedEntries().map(\.solutionID), [first.solutionID])
        // Aktualisieren: gleicher Datensatz, beide Seiten, gleiche ID, Kurs und Sichtbarkeit bleiben
        let pub = try await SolutionSharing.updateInCommunity(src, keys: ["p2"], displayName: "Lea", options: options, space: space,
                                                              existingID: first.solutionID, service: d.service, library: d.library)
        XCTAssertEqual(pub.solutionID, first.solutionID)
        let records = cloud.all(CommunityRecordType.solution)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r["pageCount"]?.int, 2)
        XCTAssertEqual(r["courseKey"]?.string, space.key)
        XCTAssertEqual(r["visibility"]?.string, "modul")
        let stored = try SolutionPackage.decode(try Data(contentsOf: try XCTUnwrap(r["package"]?.asset)))
        let opened = try stored.open(communitySecret: try XCTUnwrap(space.secret), cipher: cipher)
        XCTAssertEqual(opened.solutionID, first.solutionID)
        XCTAssertEqual(opened.pages.map(\.key), ["p1", "p2"])
        XCTAssertEqual(d.library.sharedEntries().map(\.pageCount), [2], "Kopie unter Meine geteilten Lösungen ersetzt")
        XCTAssertNotNil(d.library.sharedEntries().first?.publishedAt)
        // nur der Autor ersetzt sein Paket
        cloud.user = "_user-bob"
        let bob = try device(cloud)
        await expect(.notOwner) { _ = try await bob.service.update(solutionID: first.solutionID, package: stored, options: options) }
    }

    // MARK: Kommentare und Likes ueber CloudKit (03.11.2026)

    /// Mitglied der Community "kurs-1" mit eigenem Dienst und Pseudonym (gemeinsame Datenbank, Nutzer wechselt)
    private func member(_ cloud: FakeCommunityCloud, _ user: String, pseudonym: String = "") -> CloudKitCommunityService {
        cloud.user = user
        let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        return CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                        courseKeys: { [space.key] }, courses: { [space] }, pseudonym: { pseudonym })
    }

    private func publishForDiscussion(_ cloud: FakeCommunityCloud) async throws -> String {
        let lea = member(cloud, "_user-ada", pseudonym: "Lea")
        let pdf = makePDFData()
        let src = SolutionSource(document: try ownDocument(), originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        let options = CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Übungsblatt 3", communityKey: space.key)
        return try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Lea", options: options, space: space,
                                                            service: lea, library: SolutionLibrary(root: try tempDir())).solutionID
    }

    func testCommentsAndLikesOverCloudKitAreEncryptedAndFollowTheServiceRules() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let sid = try await publishForDiscussion(cloud)
        XCTAssertTrue(member(cloud, "_user-ada").supportsDiscussion)

        // Ben kommentiert eine Stelle und liked (idempotent)
        let ben = member(cloud, "_user-ben", pseudonym: "Ben")
        let c1 = try await ben.addComment(solutionID: sid, text: "  Danke! Warum Vorzeichen in 2b?  ", parentID: nil, pageKey: "p1",
                                          anchor: .init(x: 0.3, y: 0.4))
        XCTAssertEqual(c1.text, "Danke! Warum Vorzeichen in 2b?")
        XCTAssertEqual(c1.pseudonym, "Ben")
        XCTAssertTrue(c1.isMine)
        let liked = try await ben.setLiked(solutionID: sid, true)
        XCTAssertEqual(liked, 1)
        let again = try await ben.setLiked(solutionID: sid, true)
        XCTAssertEqual(again, 1)
        XCTAssertEqual(cloud.all(CommunityRecordType.like).count, 1, "ein Like je Nutzer")
        await expect(.service("Der Kommentar ist leer.")) { _ = try await ben.addComment(solutionID: sid, text: " ", parentID: nil, pageKey: nil, anchor: nil) }

        // beim Dienst nur Chiffrat: weder Text noch Pseudonym noch Seite im Klartext
        let stored = try XCTUnwrap(cloud.all(CommunityRecordType.comment).first)
        XCTAssertEqual(stored["solutionID"]?.string, sid)
        XCTAssertNil(stored["text"])
        let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(stored["payload"]?.string)))
        for plain in ["Vorzeichen", "Ben", "p1"] { XCTAssertNil(raw.range(of: Data(plain.utf8)), plain) }

        // Lea (Autorin) liest, antwortet (Stelle vom Kommentar), darf die eigene Loesung nicht liken
        let lea = member(cloud, "_user-ada", pseudonym: "Lea")
        let read = try await lea.comments(solutionID: sid)
        XCTAssertEqual(read.map(\.text), ["Danke! Warum Vorzeichen in 2b?"])
        XCTAssertEqual(read.first?.anchor, .init(x: 0.3, y: 0.4))
        XCTAssertEqual(read.first?.pageKey, "p1")
        XCTAssertEqual(read.first?.isMine, false)
        let reply = try await lea.addComment(solutionID: sid, text: "Siehe Zeile 3.", parentID: c1.id, pageKey: nil, anchor: nil)
        XCTAssertEqual(reply.parentID, c1.id)
        XCTAssertEqual(reply.pageKey, "p1")
        XCTAssertTrue(reply.byAuthor)
        await expect(.service("Die eigene Lösung lässt sich nicht liken.")) { _ = try await lea.setLiked(solutionID: sid, true) }
        await expect(.service("Nur der Verfasser kann seinen Kommentar ändern.")) { _ = try await lea.editComment(id: c1.id, text: "x") }
        let listed = try await lea.findForCourse(courseKey: CommunityKeys.courseKey(university: "luh", courseID: "kurs-1"))
        XCTAssertEqual(listed.first?.likes, 1)
        XCTAssertEqual(listed.first?.likedByMe, false)
        XCTAssertEqual(listed.first?.commentCount, 2)

        // Antwort auf eine Antwort haengt am ersten Kommentar
        let ben2 = member(cloud, "_user-ben", pseudonym: "Ben")
        let nested = try await ben2.addComment(solutionID: sid, text: "Danke", parentID: reply.id, pageKey: nil, anchor: nil)
        XCTAssertEqual(nested.parentID, c1.id)
        let benList = try await ben2.findForCourse(courseKey: CommunityKeys.courseKey(university: "luh", courseID: "kurs-1"))
        XCTAssertEqual(benList.first?.likedByMe, true)
        // bearbeiten und loeschen nur eigene
        let edited = try await ben2.editComment(id: nested.id, text: "Danke, verstanden")
        XCTAssertTrue(edited.edited)
        try await ben2.deleteComment(id: nested.id)
        let afterDelete = try await ben2.comments(solutionID: sid)
        XCTAssertEqual(afterDelete.map(\.id), [c1.id, reply.id], "geloeschte Antwort faellt weg")
        let unliked = try await ben2.setLiked(solutionID: sid, false)
        XCTAssertEqual(unliked, 0)

        // Lea entfernt Bens Kommentar unter ihrer Loesung: bleibt mit Antwort als "geloescht" stehen
        let lea2 = member(cloud, "_user-ada", pseudonym: "Lea")
        try await lea2.deleteComment(id: c1.id)
        let afterRemoval = try await lea2.comments(solutionID: sid)
        XCTAssertEqual(afterRemoval.map(\.deleted), [true, false])
        XCTAssertEqual(afterRemoval.first?.text, "")
        // eine Entfernung von jemand anderem als der Autorin zaehlt nicht
        let mallory = member(cloud, "_user-mallory")
        let own = try await mallory.addComment(solutionID: sid, text: "Hallo", parentID: nil, pageKey: nil, anchor: nil)
        await expect(.service("Nur der Verfasser kann das.")) { try await mallory.deleteComment(id: reply.id) }
        let still = try await mallory.comments(solutionID: sid)
        XCTAssertEqual(still.map(\.id), [c1.id, reply.id, own.id])
    }

    func testCommentReportsHideAfterThreeAndOutsidersSeeNothing() async throws {
        let cloud = FakeCommunityCloud(assetDir: try tempDir())
        let sid = try await publishForDiscussion(cloud)
        let ben = member(cloud, "_user-ben", pseudonym: "Ben")
        let c = try await ben.addComment(solutionID: sid, text: "Werbung", parentID: nil, pageKey: nil, anchor: nil)
        await expect(.service("Den eigenen Kommentar kannst du löschen statt melden.")) { try await ben.reportComment(id: c.id, reason: .spam) }
        for (i, user) in ["_user-1", "_user-2", "_user-3"].enumerated() {
            let s = member(cloud, user)
            let visible = try await s.comments(solutionID: sid)
            XCTAssertEqual(visible.count, 1, "vor Meldung \(i + 1) noch sichtbar")
            try await s.reportComment(id: c.id, reason: .spam)
            if i == 0 { await expect(.service("Du hast diesen Kommentar schon gemeldet.")) { try await s.reportComment(id: c.id, reason: .spam) } }
        }
        let report = try XCTUnwrap(cloud.all(CommunityRecordType.report).first)
        XCTAssertEqual(report["commentID"]?.string, c.id)
        let hidden = try await member(cloud, "_user-4").comments(solutionID: sid)
        XCTAssertEqual(hidden, [], "ab drei Meldungen ausgeblendet")

        // andere Hochschule bzw. ohne die Community: keine Kommentare, kein Like
        cloud.user = "_user-fremd"
        let outsider = CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                                courseKeys: { [] }, courses: { [] })
        await expect(.notFound) { _ = try await outsider.comments(solutionID: sid) }
        await expect(.notFound) { _ = try await outsider.setLiked(solutionID: sid, true) }
        await expect(.notFound) { _ = try await outsider.addComment(solutionID: sid, text: "x", parentID: nil, pageKey: nil, anchor: nil) }
    }

    // MARK: Dokument fuer den Import

    private func makeStore(pdf: Data) async throws -> DocumentStore {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-26T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "community-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-26", has_notes: nil, page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.originalPDFURL, pdfURL)
        return store
    }
}
