import Foundation
import XCTest
@testable import UniFlowCore

/// Datentrennung je (Apple-Nutzer, Hochschule) und Umzug der Daten von vor den Containern
/// (docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 2). Nur Temp-Ordner, erfundene Nutzer und Dateien.
final class DataContainerTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:15:00")!
    private let user = "001234.erfunden-ada.0001"
    private let other = "009876.erfunden-bob.0002"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func backend(_ layout: DataContainerLayout) async throws -> LocalBackend {
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        return try await LocalBackend.open(path: layout.databaseURL.path, clock: clock, files: layout.files(),
                                           university: layout.university.rawValue)
    }

    private func get(_ b: LocalBackend, _ path: String) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!, headers: [:], body: nil))
        XCTAssertEqual(r.status, 200, path)
        return try JSONValue.parse(r.body)
    }

    private func put(_ b: LocalBackend, _ path: String, _ body: JSONValue) async throws {
        let r = await b.handle(LocalRequest(method: "PUT", url: URL(string: "uniflow-local://device" + path)!,
                                            headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(r.status, 200, path)
    }

    // MARK: Schluessel

    /// Die eine Fassung der Unterordner: Namen wie bisher in Application Support/UniFlow, PDF-Zwischenspeicher je Datenquelle
    func testFolderNamesAreDefinedOnce() {
        let layout = DataContainerLayout(base: URL(fileURLWithPath: "/tmp/c", isDirectory: true),
                                         key: DataContainerKey(userID: "nutzer-erfunden", university: .luh))
        let names = DataContainerLayout.Folder.allCases.map { layout.url($0).lastPathComponent }
        XCTAssertEqual(names, ["db", "journal", "sources", "thumbs", "cache", "solutions", "StudIP", "Learnweb"])
        XCTAssertEqual(layout.journal, layout.root.appendingPathComponent("journal", isDirectory: true))
        XCTAssertEqual(layout.databaseURL.deletingLastPathComponent().lastPathComponent, "db")
        XCTAssertTrue(DataContainerLayout.pdfDirectory(.local, in: layout.root).path.hasSuffix("/sources/local/pdf"))
        XCTAssertEqual(StudIPImport.relativePath(fileID: "../a", name: "Blatt/1.pdf"),
                       "files/\(StudIPImport.safeFileName("../a"))/\(StudIPImport.safeFileName("Blatt/1.pdf"))")
    }

    func testKeyIsFixedPerUserAndUniversityAndHidesTheAppleID() {
        let luh = DataContainerKey(userID: user, university: .luh)
        let hi = DataContainerKey(userID: user, university: .hildesheim)
        XCTAssertEqual(luh.identifier, DataContainerKey(userID: user, university: .luh).identifier, "fest, kein Zufall")
        XCTAssertNotEqual(luh.identifier, hi.identifier)
        XCTAssertNotEqual(luh.identifier, DataContainerKey(userID: other, university: .luh).identifier)
        XCTAssertEqual(luh.userScope, hi.userScope, "ein Nutzer, eine Kurzkennung")
        XCTAssertNotEqual(luh.userScope, DataContainerKey(userID: other, university: .luh).userScope)
        // Version 8, Variante RFC 9562
        let s = luh.identifier.uuidString
        XCTAssertEqual(Array(s)[14], "8")
        XCTAssertTrue("89AB".contains(Array(s)[19]))
        // die Apple-Nutzer-ID steht weder im Ordnernamen noch in Beschreibung oder Kurzkennung
        for text in [s, luh.userScope, "\(luh)", DataContainerLayout(base: URL(fileURLWithPath: "/x"), key: luh).root.path] {
            XCTAssertFalse(text.contains("erfunden"), text)
            XCTAssertFalse(text.contains("001234"), text)
        }
        XCTAssertEqual(luh.userScope.count, 17)
    }

    // MARK: Zwei Hochschulen nacheinander befuellen

    func testTwoUniversitiesFilledOneAfterTheOtherSeeNothingOfEachOther() async throws {
        let base = try tempDir()
        let luh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        let hi = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim))
        XCTAssertNotEqual(luh.root, hi.root)

        // 1. LUH befuellen: Einstellung, Datei-Eintrag, eigene Datei, Journal, Loesungsordner
        let lb = try await backend(luh)
        try await put(lb, "/api/settings", ["user_name": "Ada LUH"])
        let ownFile = try luh.files().write(Data("%PDF-LUH".utf8), to: "files/Eigene Dokumente/Testblatt.pdf")
        try await lb.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, created_at) VALUES ('c-luh', 'Testkurs LUH', '2026-10-26')")
            try c.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('f-luh', 'c-luh', 'Testblatt.pdf', 'files/Eigene Dokumente/Testblatt.pdf')")
        }
        let luhJournal = LocalJournal(store: FileBlobStore(root: luh.journal), documentID: "f-luh", namespace: .local)
        try luhJournal.writePage("p1", JournalPage(page: page(["s1"]), localRev: 1))
        try FileManager.default.createDirectory(at: luh.solutions, withIntermediateDirectories: true)

        // 2. Hildesheim danach befuellen
        let hb = try await backend(hi)
        try await put(hb, "/api/settings", ["user_name": "Ada Hildesheim"])
        let hiJournal = LocalJournal(store: FileBlobStore(root: hi.journal), documentID: "f-hi", namespace: .local)
        try hiJournal.writePage("p1", JournalPage(page: page(["s2"]), localRev: 1))

        // 3. gegenseitig nichts lesbar
        let ls = try await get(lb, "/api/settings")
        let hs = try await get(hb, "/api/settings")
        XCTAssertEqual(ls["user_name"]?.string, "Ada LUH")
        XCTAssertEqual(hs["user_name"]?.string, "Ada Hildesheim")
        XCTAssertEqual(ls["university"]?.string, "luh")
        XCTAssertEqual(hs["university"]?.string, "hildesheim")
        let hiFiles = try await hb.context.database.withConnection { try $0.scalar("SELECT COUNT(*) FROM files")?.int64 }
        XCTAssertEqual(hiFiles, 0, "keine Datei-Eintraege der LUH")
        let hiCourses = try await hb.context.database.withConnection { try $0.scalar("SELECT COUNT(*) FROM courses WHERE id='c-luh'")?.int64 }
        XCTAssertEqual(hiCourses, 0)
        // derselbe gespeicherte Pfad zeigt im anderen Container ins Leere, aus dem Container heraus gar nicht
        XCTAssertTrue(luh.files().exists(stored: "files/Eigene Dokumente/Testblatt.pdf"))
        XCTAssertFalse(hi.files().exists(stored: "files/Eigene Dokumente/Testblatt.pdf"))
        XCTAssertNil(hi.files().url(stored: "../\(luh.identifier.uuidString)/files/Eigene Dokumente/Testblatt.pdf"))
        XCTAssertNil(hi.files().url(stored: ownFile.path))
        XCTAssertNil(hi.files().stored(ownFile), "Datei der LUH gilt im Hildesheimer Container nicht als lokal")
        // Journal: jede Hochschule sieht nur ihre Notizen
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: hi.journal), documentID: "f-luh", namespace: .local).load())
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: luh.journal), documentID: "f-hi", namespace: .local).load())
        XCTAssertEqual(try luhJournal.load()?.pages["p1"]?.page, page(["s1"]))
        XCTAssertEqual(try hiJournal.load()?.pages["p1"]?.page, page(["s2"]))
        // Kennzeichnung je Container
        XCTAssertEqual(try luh.manifest()?.university, "luh")
        XCTAssertEqual(try hi.manifest()?.university, "hildesheim")
        XCTAssertEqual(try hi.manifest()?.owner, DataContainerKey.userScope(user))
    }

    func testRemovingOneUniversityLeavesTheOtherUntouched() async throws {
        let base = try tempDir()
        let luh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        let hi = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim))
        let lb = try await backend(luh)
        try await put(lb, "/api/settings", ["user_name": "Ada LUH"])
        let hb = try await backend(hi)
        try await put(hb, "/api/settings", ["user_name": "Ada Hildesheim"])
        _ = try hi.files().write(Data("%PDF-HI".utf8), to: "Learnweb/k1/Folien.pdf")

        try luh.remove()
        XCTAssertFalse(luh.exists())
        XCTAssertTrue(hi.exists())
        XCTAssertTrue(hi.files().exists(stored: "Learnweb/k1/Folien.pdf"))
        let reopened = try await LocalBackend.open(path: hi.databaseURL.path, clock: clock, files: hi.files(), university: "hildesheim")
        let s = try await get(reopened, "/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Ada Hildesheim")
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).contains { $0.hasPrefix(".geloescht-") },
                       "Papierkorb sofort geleert")

        // ein neu angelegter LUH-Container ist leer
        let fresh = try await backend(luh)
        let fs = try await get(fresh, "/api/settings")
        XCTAssertEqual(fs["user_name"]?.string, "")

        // Reste eines abgebrochenen Loeschens raeumt purgeTrash weg
        let stale = base.appendingPathComponent(".geloescht-\(UUID().uuidString)/db", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        DataContainerLayout.purgeTrash(base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.deletingLastPathComponent().path))
        XCTAssertTrue(hi.exists())
    }

    // MARK: Falscher Container wird nicht geoeffnet

    func testContainerOfOtherUniversityOrUserIsNotOpened() throws {
        let base = try tempDir()
        let luh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        try luh.prepare(clock: clock)
        // vertauschte Kennzeichnung: gehoert laut container.json zu Hildesheim
        let wrong = DataContainerManifest(university: "hildesheim", owner: luh.ownerScope, createdAt: "2026-10-26T09:00:00")
        try JSONEncoder().encode(wrong).write(to: luh.manifestURL)
        XCTAssertThrowsError(try luh.prepare(clock: clock)) { e in
            XCTAssertEqual(e as? UniversityMismatch, UniversityMismatch(stored: "hildesheim", expected: "luh"))
            XCTAssertTrue("\(e)".contains("Universität Hildesheim"), "\(e)")
            XCTAssertTrue("\(e)".contains("Leibniz Universität Hannover"), "\(e)")
        }
        // anderer Nutzer
        let foreign = DataContainerManifest(university: "luh", owner: DataContainerKey.userScope(other), createdAt: "2026-10-26T09:00:00")
        try JSONEncoder().encode(foreign).write(to: luh.manifestURL)
        XCTAssertThrowsError(try luh.verify()) { XCTAssertEqual($0 as? DataContainerError, .ownerMismatch) }
        // kaputt
        try Data("{kaputt".utf8).write(to: luh.manifestURL)
        XCTAssertThrowsError(try luh.verify()) { XCTAssertEqual($0 as? DataContainerError, .unreadableManifest) }
        XCTAssertEqual(try Data(contentsOf: luh.manifestURL), Data("{kaputt".utf8), "nichts ueberschrieben")
    }

    func testDatabaseOfOtherUniversityIsNotOpened() async throws {
        let base = try tempDir()
        let luh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        let hi = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim))
        let lb = try await backend(luh)
        try await put(lb, "/api/settings", ["user_name": "Ada LUH"])
        _ = try await lb.context.database.query("PRAGMA wal_checkpoint(TRUNCATE)")      // alles in der Hauptdatei
        // LUH-Datenbank landet (z. B. durch einen Fehler) im Hildesheimer Container
        try hi.prepare(clock: clock)
        try FileManager.default.createDirectory(at: hi.databaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: luh.databaseURL, to: hi.databaseURL)
        do {
            _ = try await LocalBackend.open(path: hi.databaseURL.path, clock: clock, files: hi.files(), university: "hildesheim")
            XCTFail("LUH-Datenbank als Hildesheim geoeffnet")
        } catch let e as UniversityMismatch {
            XCTAssertEqual(e, UniversityMismatch(stored: "luh", expected: "hildesheim"))
            XCTAssertEqual(e.description, "Diese Daten gehören zur Hochschule „Leibniz Universität Hannover“, gewählt ist „Universität Hildesheim“. Sie werden nicht geöffnet, damit keine Daten gemischt werden.")
        }
        // die Datei bleibt unveraendert die der LUH
        let c = try SQLiteConnection(path: hi.databaseURL.path)
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='university'")?.string, "luh")
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='user_name'")?.string, "Ada LUH")
    }

    func testServicesListFollowsTheUniversityOfTheDatabase() async throws {
        let base = try tempDir()
        let hb = try await backend(DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim)))
        let lb = try await backend(DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh)))
        let hiKeys = try await get(hb, "/api/services")["services"]?.array?.compactMap { $0["key"]?.string } ?? []
        let luhKeys = try await get(lb, "/api/services")["services"]?.array?.compactMap { $0["key"]?.string } ?? []
        XCTAssertEqual(hiKeys, ["learnweb", "lsf", "lsf-ausfall", "uni"])
        XCTAssertTrue(luhKeys.contains("studip"))
        XCTAssertFalse(luhKeys.contains("learnweb"))
        XCTAssertFalse(hiKeys.contains("studip"))
    }

    // MARK: Namen je (Nutzer, Hochschule): eine Fassung fuer Ordner, Schluesselbund und Webdaten

    /// Frueher zusaetzlich `UniversityStorage` (PC-Sitzung): Ordner, Schluesselbund-Dienst und WebsiteDataStore-UUID
    /// kommen jetzt alle aus `DataContainerKey`.
    func testStorageNamesPerUserAndUniversityComeFromOneKey() {
        let root = URL(fileURLWithPath: "/x")
        let hi = DataContainerKey(userID: user, university: .hildesheim)
        let luh = DataContainerKey(userID: user, university: .luh)
        XCTAssertNotEqual(DataContainerLayout(base: root, key: hi).root, DataContainerLayout(base: root, key: luh).root)
        // nur bekannte Hochschulen, nur mit Nutzer (kein Pfad aus Eingaben, kein Raten)
        XCTAssertNil(DataContainerKey(userID: "x", universityKey: "../etc"))
        XCTAssertNil(DataContainerKey(userID: "", universityKey: "luh"))
        XCTAssertNil(DataContainerKey(userID: "x", universityKey: nil))
        XCTAssertNil(DataContainerKey(userID: "x", universityKey: "Hildesheim"))
        XCTAssertEqual(DataContainerKey(userID: user, universityKey: "hildesheim"), hi)
        // Webdaten (Cookies) je Container, fest und getrennt
        XCTAssertEqual(hi.websiteDataStoreID, hi.identifier)
        XCTAssertNotEqual(hi.websiteDataStoreID, luh.websiteDataStoreID)
        XCTAssertEqual(hi.websiteDataStoreID, DataContainerKey(userID: user, university: .hildesheim).websiteDataStoreID, "bleibt gleich")
        XCTAssertNotEqual(hi.websiteDataStoreID, DataContainerKey(userID: other, university: .hildesheim).websiteDataStoreID)
        // Schluesselbund: ein Dienst, Eintraege mit Nutzer-Kurzkennung und Hochschule
        XCTAssertEqual(DataContainerKey.keychainService, "de.uniflow.ai.university")
        XCTAssertEqual(hi.university.profile.tokenKeychainAccount(service: "learnweb", userScope: hi.userScope), "\(hi.userScope).hildesheim.learnweb.token")
        XCTAssertNil(luh.university.profile.tokenKeychainAccount(service: "learnweb", userScope: luh.userScope), "kein Rueckfall auf die andere Hochschule")
        XCTAssertNotEqual(hi.university.profile.tokenKeychainAccount(service: "learnweb", userScope: hi.userScope),
                          UniversityProfile.hildesheim.tokenKeychainAccount(service: "learnweb",
                                                                            userScope: DataContainerKey(userID: other, university: .hildesheim).userScope))
        for name in [hi.university.profile.tokenKeychainAccount(service: "learnweb", userScope: hi.userScope) ?? "", hi.websiteDataStoreID.uuidString, "\(hi)"] {
            XCTAssertFalse(name.contains("erfunden"), name)
            XCTAssertFalse(name.contains("001234"), name)
        }
    }

    // MARK: Stud.IP und Learnweb in ihrem Container

    /// Learnweb mit Schluessel ohne Netz: ein Kurs mit zwei Dateien
    private func learnwebTransport() -> FakeUniTransport {
        let base = "https://www.uni-hildesheim.de/learnweb2026"
        let t = FakeUniTransport()
        let rest = "\(base)/webservice/rest/server.php"
        t.on(rest, body: "wsfunction=core_webservice_get_site_info", okJSON(["userid": 7]))
        t.on(rest, body: "wsfunction=core_enrol_get_users_courses", okJSON([["id": 35, "fullname": "WiSe 2026/27: 0435 Testkurs Hildesheim"]]))
        t.on(rest, body: "wsfunction=core_course_get_contents", ok("""
            [{"section": 1, "name": "1", "modules": [{"id": 80, "modname": "resource", "name": "Folien", "contents": [
              {"type": "file", "filename": "Folien.pdf", "filepath": "/", "timemodified": 3,
               "fileurl": "\(base)/webservice/pluginfile.php/6/mod_resource/content/1/Folien.pdf"}]}]}]
            """))
        t.on("\(base)/webservice/pluginfile.php", ok("%PDF-1.7 Hildesheim"))
        return t
    }

    private func hildesheimSync(_ db: SQLiteDatabase, _ layout: DataContainerLayout, _ t: FakeUniTransport) -> HildesheimSync {
        let api = LearnwebAPI(base: "https://www.uni-hildesheim.de/learnweb2026", mode: .token(LearnwebToken("ERFUNDEN0123")!), transport: t,
                              retry: .none)
        return HildesheimSync(db: db, container: layout, learnweb: api, lsf: nil, transport: t, clock: clock, retry: .none)
    }

    func testStudIPAndLearnwebWriteOnlyIntoTheirOwnContainer() async throws {
        let base = try tempDir()
        let luh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        let hi = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim))
        let lb = try await backend(luh)
        let hb = try await backend(hi)

        // 1. LUH: Stud.IP-Datei ueber dieselbe Fassung wie StudIPSync (UniStore, Datei unter StudIP/files/...)
        let studipFile = try luh.files().write(Data("%PDF-1.7 LUH".utf8), to: "StudIP/files/Testkurs/Blatt1.pdf")
        let stored = try XCTUnwrap(luh.files().stored(studipFile))
        try await lb.context.database.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "c-luh", title: "Testkurs LUH", number: nil, semester: nil), now: "t")
            let row = UniStore.FileRow(id: "f-luh", name: "Blatt1.pdf", size: 12, mime: "application/pdf", chdate: 1,
                                       downloadURL: "https://studip.test/f-luh", folder: "")
            _ = try UniStore.storeFiles(c, courseID: "c-luh", [row], now: "t", fileExists: { _ in false })
            try UniStore.markDownloaded(c, row, localPath: stored, sha256: nil, now: "t")
        }

        // 2. Hildesheim danach: Learnweb ueber HildesheimSync in den Hildesheimer Container
        let report = await hildesheimSync(hb.context.database, hi, learnwebTransport()).run()
        XCTAssertTrue(report.ok, report.messages.joined(separator: "; "))
        XCTAssertEqual(report.newFiles.count, 1)
        let hiPath = try await hb.context.database.scalar("SELECT local_path FROM files WHERE course_id='lw-35'")?.string ?? ""
        XCTAssertTrue(hiPath.hasPrefix("Learnweb/files/lw-80-"), hiPath)
        XCTAssertTrue(hi.files().exists(stored: hiPath))

        // 3. gegenseitig unsichtbar: Datenbank, Dateien, gespeicherte Pfade
        let luhLearnweb = try await lb.context.database.scalar("SELECT COUNT(*) FROM courses WHERE id LIKE 'lw-%'")?.int
        XCTAssertEqual(luhLearnweb, 0)
        let hiStudIP = try await hb.context.database.scalar("SELECT COUNT(*) FROM files WHERE id='f-luh'")?.int
        XCTAssertEqual(hiStudIP, 0)
        XCTAssertFalse(luh.files().exists(stored: hiPath))
        XCTAssertFalse(hi.files().exists(stored: stored))
        XCTAssertNil(hi.files().stored(studipFile))
        XCTAssertNil(luh.files().stored(hi.root.appendingPathComponent(hiPath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: luh.learnweb.path), "kein Learnweb-Ordner bei der LUH")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hi.studip.path), "kein Stud.IP-Ordner in Hildesheim")
        let hiList = try await get(hb, "/api/files").jsonString()
        let luhList = try await get(lb, "/api/files").jsonString()
        XCTAssertTrue(hiList.contains("Folien.pdf"))
        XCTAssertFalse(hiList.contains("Blatt1.pdf"), "Dokumente der LUH nicht in Hildesheim")
        XCTAssertTrue(luhList.contains("Blatt1.pdf"))
        XCTAssertFalse(luhList.contains("Folien.pdf"), "Learnweb-Dateien nicht bei der LUH")

        // 4. Hildesheim-Abgleich mit der LUH-Datenbank, in den LUH-Container oder fuer ein anderes Konto: nichts
        let before = try await lb.context.database.scalar("SELECT COUNT(*) FROM sync_log")?.int
        let t = learnwebTransport()
        let wrongDB = await hildesheimSync(lb.context.database, hi, t).run()
        XCTAssertNotNil(wrongDB.refused)
        XCTAssertTrue(wrongDB.refused?.contains("Leibniz Universität Hannover") ?? false, wrongDB.refused ?? "")
        let wrongContainer = await hildesheimSync(lb.context.database, luh, t).run()
        XCTAssertNotNil(wrongContainer.refused)
        XCTAssertFalse(wrongDB.ok || wrongContainer.ok)
        XCTAssertTrue(t.requests.isEmpty, "keine Anfrage an die Uni")
        let after = try await lb.context.database.scalar("SELECT COUNT(*) FROM sync_log")?.int
        XCTAssertEqual(before, after, "nichts in die LUH-Datenbank geschrieben")
        let stranger = DataContainerLayout(base: base, identifier: hi.identifier, university: .hildesheim, ownerScope: DataContainerKey.userScope(other))
        let foreign = await hildesheimSync(hb.context.database, stranger, t).run()
        XCTAssertEqual(foreign.refused, DataContainerError.ownerMismatch.description)
        XCTAssertTrue(t.requests.isEmpty)
    }

    // MARK: Umzug der alten Daten

    /// Alter Stand ohne Container: Application Support/UniFlow (Datenbank, Journal, eigene Datei, Bild, Cache) und
    /// Application Support/StudIP (Download, index.json). Pfade in der Datenbank wie bisher relativ zum App-Container.
    private struct Legacy {
        let appSupport: URL
        let sources: LegacyDataMigration.Sources
        let base: URL
    }

    private func legacy() async throws -> Legacy {
        let appSupport = try tempDir()
        let support = appSupport.appendingPathComponent("UniFlow", isDirectory: true)
        let studip = appSupport.appendingPathComponent("StudIP", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: support.appendingPathComponent("db"), withIntermediateDirectories: true)
        let b = try await LocalBackend.open(path: support.appendingPathComponent("db/uniflow.sqlite").path, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO settings(key, value) VALUES ('user_name', 'Ada alt') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try c.execute("INSERT INTO courses(id, title, created_at) VALUES ('c1', 'Testkurs Analysis', '2026-10-20')")
            try c.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('s1', 'c1', 'Blatt 1.pdf', 'Library/Application Support/StudIP/files/Testkurs Analysis/Blatt 1.pdf')")
            try c.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('o1', '__user__', 'Notizbuch.pdf', 'Library/Application Support/UniFlow/files/Eigene Dokumente/Notizbuch.pdf')")
            try c.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('p1', 'c1', 'PC.pdf', '/home/erfunden/UniFlow/files/PC.pdf')")
            try c.execute("INSERT INTO annotations(file_id, data, updated_at) VALUES ('o1', '{\"pages\":{\"p1\":{\"objects\":[]}}}', '2026-10-20')")
        }
        func write(_ text: String, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("%PDF-eigen", support.appendingPathComponent("files/Eigene Dokumente/Notizbuch.pdf"))
        try write("PNG-erfunden", support.appendingPathComponent("assets/o1/bild.png"))
        try write("{\"cache\":1}", support.appendingPathComponent("cache/a.json"))
        try write("%PDF-zwischen", support.appendingPathComponent("sources/local/pdf/s1.pdf"))
        let journal = LocalJournal(store: FileBlobStore(root: support.appendingPathComponent("journal")), documentID: "s1", namespace: .local)
        try journal.writePage("p1", JournalPage(page: page(["tinte-1", "tinte-2"]), localRev: 3))
        try journal.writeAcks(serverVersion: 2, acked: ["p1": 2], metaAckedRev: 0)
        try write("%PDF-studip", studip.appendingPathComponent("files/Testkurs Analysis/Blatt 1.pdf"))
        try write("[]", studip.appendingPathComponent("index.json"))
        return Legacy(appSupport: appSupport, sources: LegacyDataMigration.Sources(support: support, studip: studip),
                      base: appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true))
    }

    /// Alles im LUH-Container von `owner`: Dateien, Pfade, Notizen, Kennzeichnung
    private func assertMigrated(_ l: Legacy, owner: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let layout = DataContainerLayout(base: l.base, key: DataContainerKey(userID: owner, university: .luh))
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: l.sources.support.path), "verschoben, nicht kopiert", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: l.sources.studip.path), "verschoben, nicht kopiert", file: file, line: line)
        XCTAssertTrue(LegacyDataMigration.isDone(base: l.base), file: file, line: line)
        XCTAssertEqual(try layout.manifest()?.university, "luh", file: file, line: line)
        XCTAssertEqual(try layout.manifest()?.owner, DataContainerKey.userScope(owner), file: file, line: line)
        let b = try await LocalBackend.open(path: layout.databaseURL.path, clock: clock, files: layout.files(), university: "luh")
        let paths = try await b.context.database.withConnection { c in
            try c.query("SELECT id, local_path FROM files ORDER BY id").map { ($0[0].string ?? "", $0[1].string ?? "") }
        }
        XCTAssertEqual(paths.map(\.0), ["o1", "p1", "s1"], file: file, line: line)
        XCTAssertEqual(paths.map(\.1), ["files/Eigene Dokumente/Notizbuch.pdf", "/home/erfunden/UniFlow/files/PC.pdf",
                                        "StudIP/files/Testkurs Analysis/Blatt 1.pdf"], file: file, line: line)
        let files = layout.files()
        XCTAssertEqual(files.url(stored: paths[0].1).flatMap { try? Data(contentsOf: $0) }, Data("%PDF-eigen".utf8), file: file, line: line)
        XCTAssertEqual(files.url(stored: paths[2].1).flatMap { try? Data(contentsOf: $0) }, Data("%PDF-studip".utf8), file: file, line: line)
        XCTAssertFalse(files.exists(stored: paths[1].1), "PC-Pfad bleibt 'nicht lokal'", file: file, line: line)
        XCTAssertTrue(fm.fileExists(atPath: layout.root.appendingPathComponent("assets/o1/bild.png").path), file: file, line: line)
        XCTAssertTrue(fm.fileExists(atPath: layout.root.appendingPathComponent("sources/local/pdf/s1.pdf").path), file: file, line: line)
        XCTAssertTrue(fm.fileExists(atPath: layout.studip.appendingPathComponent("index.json").path), file: file, line: line)
        // Notizen: Journal und Datenbank unveraendert
        let snap = try LocalJournal(store: FileBlobStore(root: layout.journal), documentID: "s1", namespace: .local).load()
        XCTAssertEqual(snap?.pages["p1"], JournalPage(page: page(["tinte-1", "tinte-2"]), localRev: 3), file: file, line: line)
        XCTAssertEqual(snap?.acked["p1"], 2, "ungesendete Seite bleibt ungesendet", file: file, line: line)
        let notes = try await b.context.database.withConnection { try $0.scalar("SELECT data FROM annotations WHERE file_id='o1'")?.string }
        XCTAssertEqual(notes, "{\"pages\":{\"p1\":{\"objects\":[]}}}", file: file, line: line)
        let s = try await get(b, "/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Ada alt", file: file, line: line)
    }

    func testLegacyDataMovesIntoTheLUHContainerOfTheCurrentUser() async throws {
        let l = try await legacy()
        var finished: [UUID] = []
        let report = try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: user, clock: clock,
                                                 finishing: { finished.append($0.identifier) })
        let target = DataContainerKey(userID: user, university: .luh).identifier
        XCTAssertEqual(report.target, target)
        XCTAssertEqual(report.moved, ["UniFlow", "StudIP"], "UniFlow als Ganzes, StudIP in den Container")
        XCTAssertEqual(report.kept, [])
        XCTAssertEqual(report.rewrittenPaths, 2)
        XCTAssertEqual(finished, [target])
        try await assertMigrated(l, owner: user)
        XCTAssertFalse(DataContainerLayout(base: l.base, key: DataContainerKey(userID: user, university: .hildesheim)).exists(),
                       "Hildesheim bekommt nichts von den alten Daten")

        // zweiter Lauf (naechster Start): nichts mehr zu tun, auch fuer einen anderen Nutzer
        let again = try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: other, clock: clock,
                                                finishing: { _ in XCTFail("nicht erneut") })
        XCTAssertTrue(again.alreadyDone)
        XCTAssertEqual(again.target, target)
        XCTAssertFalse(DataContainerLayout(base: l.base, key: DataContainerKey(userID: other, university: .luh)).exists())
        try await assertMigrated(l, owner: user)
    }

    private struct Crash: Error {}

    func testInterruptedMigrationResumesWithTheSameTarget() async throws {
        for step in [LegacyDataMigration.Step.support, .manifest, .studip, .database, .finishing] {
            let l = try await legacy()
            XCTAssertThrowsError(try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: user, clock: clock,
                                                             interrupt: { if $0 == step { throw Crash() } }), "\(step)")
            let state = try XCTUnwrap(LegacyDataMigration.state(base: l.base), "\(step)")
            XCTAssertEqual(state.state, "running", "Merker erst nach Abschluss (\(step))")
            XCTAssertEqual(state.target, DataContainerKey(userID: user, university: .luh).identifier)
            // nichts verloren: jede Datei liegt am alten oder am neuen Ort
            let layout = DataContainerLayout(base: l.base, key: DataContainerKey(userID: user, university: .luh))
            for (old, new) in [(l.sources.support.appendingPathComponent("files/Eigene Dokumente/Notizbuch.pdf"),
                                layout.root.appendingPathComponent("files/Eigene Dokumente/Notizbuch.pdf")),
                               (l.sources.studip.appendingPathComponent("files/Testkurs Analysis/Blatt 1.pdf"),
                                layout.studip.appendingPathComponent("files/Testkurs Analysis/Blatt 1.pdf"))] {
                XCTAssertNotEqual(FileManager.default.fileExists(atPath: old.path), FileManager.default.fileExists(atPath: new.path),
                                  "\(step): \(old.lastPathComponent)")
            }
            // Neustart, inzwischen ist ein anderer Nutzer angemeldet: der Umzug endet beim urspruenglichen Ziel
            var finished = 0
            let report = try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: other, clock: clock,
                                                     finishing: { _ in finished += 1 })
            XCTAssertTrue(report.resumed, "\(step)")
            XCTAssertEqual(report.target, layout.identifier, "\(step)")
            XCTAssertEqual(finished, 1, "\(step)")
            XCTAssertEqual(report.rewrittenPaths, step == .database || step == .finishing ? 0 : 2, "Pfade nur einmal umgeschrieben (\(step))")
            try await assertMigrated(l, owner: user)
            XCTAssertFalse(DataContainerLayout(base: l.base, key: DataContainerKey(userID: other, university: .luh)).exists(), "\(step)")
        }
    }

    /// Ein Dateisystemfehler mitten im Umzug (StudIP laesst sich nicht verschieben): Abbruch ohne Verlust, der
    /// naechste Start macht weiter
    func testFailingMoveStopsWithoutLossAndContinuesLater() async throws {
        final class FailingStudIPMove: FileManager, @unchecked Sendable {
            var fail = true
            override func moveItem(at srcURL: URL, to dstURL: URL) throws {
                if fail, srcURL.path.contains("/StudIP") { throw CocoaError(.fileWriteOutOfSpace) }
                try super.moveItem(at: srcURL, to: dstURL)
            }
        }
        let l = try await legacy()
        let fm = FailingStudIPMove()
        XCTAssertThrowsError(try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: user, clock: clock, fileManager: fm))
        XCTAssertEqual(LegacyDataMigration.state(base: l.base)?.state, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: l.sources.studip.appendingPathComponent("files/Testkurs Analysis/Blatt 1.pdf").path))
        fm.fail = false
        let report = try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: user, clock: clock, fileManager: fm)
        XCTAssertTrue(report.resumed)
        try await assertMigrated(l, owner: user)
    }

    func testWithoutLegacyDataNothingIsCreated() throws {
        let appSupport = try tempDir()
        let sources = LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow"),
                                                  studip: appSupport.appendingPathComponent("StudIP"))
        // leerer alter Ordner (z. B. nur versteckte Systemdateien) zaehlt nicht
        try FileManager.default.createDirectory(at: sources.support, withIntermediateDirectories: true)
        try Data().write(to: sources.support.appendingPathComponent(".DS_Store"))
        let base = appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true)
        let report = try LegacyDataMigration.run(sources: sources, base: base, owner: user, clock: clock,
                                                 finishing: { _ in XCTFail("ohne alte Daten nichts zu tun") })
        XCTAssertNil(report.target)
        XCTAssertFalse(report.movedData)
        XCTAssertTrue(LegacyDataMigration.isDone(base: base))
        XCTAssertFalse(DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh)).exists())
    }

    func testExistingContainerIsMergedWithoutOverwriting() async throws {
        let l = try await legacy()
        let layout = DataContainerLayout(base: l.base, key: DataContainerKey(userID: user, university: .luh))
        try layout.prepare(clock: clock)
        let mine = layout.root.appendingPathComponent("cache/a.json")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"neu\":1}".utf8).write(to: mine)

        let report = try LegacyDataMigration.run(sources: l.sources, base: l.base, owner: user, clock: clock)
        XCTAssertEqual(report.kept, ["UniFlow/cache/a.json"])
        XCTAssertTrue(report.moved.contains("UniFlow/db"))
        XCTAssertEqual(try Data(contentsOf: mine), Data("{\"neu\":1}".utf8), "nie ueberschrieben")
        XCTAssertEqual(try Data(contentsOf: l.sources.support.appendingPathComponent("cache/a.json")), Data("{\"cache\":1}".utf8),
                       "der alte Stand bleibt am alten Ort")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.databaseURL.path))
        XCTAssertTrue(LegacyDataMigration.isDone(base: l.base))
    }
}
