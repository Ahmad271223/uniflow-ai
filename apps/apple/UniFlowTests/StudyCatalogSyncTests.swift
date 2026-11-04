import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Katalogsuche auf dem iPad (StudyCatalogSync.swift, StudyCatalogCloudKit.swift, docs/STUDIENVERLAUF-2026-11-04.md)
/// gegen ein nachgebildetes CloudKit (`WeeklyTestCloudKitTests.FakeWeeklyCloud`, mehrere Geraete auf einem Speicher)
/// und einen Lader ohne Netz: lokal -> Bibliothek (uebernehmen, 0 Downloads) -> Laden der erfundenen Katalog-PDF
/// (PDFKit auf dem Geraet), Datensatz nur mit Fakten, nie ueberschreiben, Varianten beim Wettlauf, Fehler mit 24 Stunden
/// Pause, Lader ohne Cookies. Kein echtes CloudKit, kein Netz.
@MainActor
final class StudyCatalogSyncTests: XCTestCase {
    typealias Store = WeeklyTestCloudKitTests.Store
    typealias FakeCloud = WeeklyTestCloudKitTests.FakeWeeklyCloud

    final class StubLoader: StudyCatalogLoader, @unchecked Sendable {
        let lock = NSLock()
        var responses: [String: StudyCatalogFetchResult] = [:]
        var calls: [String] = []
        func fetch(url: String, etag: String?, lastModified: String?) async -> StudyCatalogFetchResult {
            lock.withLock {
                calls.append(url)
                return responses[url] ?? StudyCatalogFetchResult(status: 404, error: "HTTP 404")
            }
        }
        var catalogCalls: Int { lock.withLock { calls.filter { $0.contains("WS_2025_26") }.count } }
    }

    static let mirror = "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc22-WS_2025_26.pdf"
    static let key = StudyCatalogText.libraryKey(university: "luh", code: "TIBSc22", term: "WS 2025/26")
    static let now = Date(timeIntervalSince1970: 1_793_786_400)       // 2026-11-04

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private var pdf: Data { get throws { try repo("packages/shared-contracts/fixtures/study-catalog/modkat-sample.pdf") } }

    /// `po`: bestaetigte PO (die Faelle zu Bibliothek und Laden nutzen TIBSc22 mit dem Spiegel WS 2025/26; ohne
    /// Bestaetigung schlaegt "PO-Version 2017" TIBSc25 vor)
    private func host(label: String? = "Technische Informatik (PO-Version 2017)", po: String? = "TIBSc22") async throws -> LocalBackendHost {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studycatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let h = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        if let label {
            try await h.backend().context.database.transaction { c in
                _ = try c.execute("INSERT INTO grades(pruefungsnr, text, semester, status, abschluss) VALUES ('1', 'Programmieren I', 'WiSe 22/23', 'BE', ?)", [.text(label)])
                if let po {
                    _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)", [.text("{\"po\": \"\(po)\"}")])
                }
            }
        }
        return h
    }

    /// ohne Grundstock (die Faelle unten pruefen Bibliothek und Laden); der Grundstock hat eigene Faelle
    private func sync(_ h: LocalBackendHost, _ loader: StubLoader, _ library: StudyCatalogLibrary?,
                      seed: StudyCatalogSeedSource? = nil) -> StudyCatalogSync {
        StudyCatalogSync(host: h, loader: loader, library: { library }, seed: { seed }, now: { Self.now })
    }

    // MARK: Ablauf

    func testFirstDeviceDownloadsSecondAdoptsFromLibraryThenLocal() async throws {
        let store = Store()
        let ada = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-ada"), now: { Self.now })
        let ben = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-ben"), now: { Self.now })

        // Geraet 1: nichts lokal, nichts in der Bibliothek -> laden (Primaer 404, Spiegel), PDFKit, speichern, teilen
        let loaderA = StubLoader()
        loaderA.responses[Self.mirror] = StudyCatalogFetchResult(status: 200, data: try pdf, etag: "\"e1\"")
        let hostA = try await host()
        let s1Raw = await sync(hostA, loaderA, ada).run()
        let s1 = try XCTUnwrap(s1Raw)
        XCTAssertEqual(s1["state"]?.string, "ready", "\(s1)")
        XCTAssertEqual(s1["origin"]?.string, "download")
        XCTAssertEqual(s1["modules"]?.int, 6)
        XCTAssertEqual(s1["shared"], .bool(true))
        XCTAssertEqual(loaderA.catalogCalls, 2)

        // Datensatz wie dokumentiert: nur Fakten, keine Modultexte, keine Personendaten
        let records = (ada.cloud as! FakeCloud).all()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.type, "StudyCatalog")
        XCTAssertEqual(r.name, "\(Self.key)#0")
        XCTAssertEqual(Set(r.fields.keys), ["catalogKey", "variant", "payload", "version", "createdAt", "ownerRecordName"])
        XCTAssertEqual(r["catalogKey"]?.string, Self.key)
        XCTAssertEqual(r["version"]?.int, 1)
        XCTAssertEqual(r["createdAt"]?.string, "2026-11-04T10:00:00Z")
        let payload = try XCTUnwrap(r["payload"]?.string)
        XCTAssertEqual(StudyCatalogValidator.validate(try JSONValue.parse(payload)), [])
        XCTAssertFalse(payload.contains("Variablen, Schleifen"), "Modultexte bleiben auf dem Geraet")
        XCTAssertFalse(payload.contains("Programmieren I"), "keine Noten, keine QIS-Zeilen")
        let expected = try JSONValue.parse(repo("packages/shared-contracts/fixtures/study-catalog/expected.json"))
        XCTAssertEqual(try JSONValue.parse(payload)["modules"], expected["catalog"]?["modules"], "PDFKit auf dem Geraet = pypdf am PC")

        // Geraet 2: aus der Bibliothek, 0 Downloads
        let loaderB = StubLoader()
        let hostB = try await host()
        let s2Raw = await sync(hostB, loaderB, ben).run()
        let s2 = try XCTUnwrap(s2Raw)
        XCTAssertEqual(s2["state"]?.string, "library", "\(s2)")
        XCTAssertEqual(loaderB.catalogCalls, 0)
        XCTAssertEqual((ben.cloud as! FakeCloud).all().count, 1, "nichts neu angelegt")
        // Status-Endpunkt
        let st = await hostB.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-catalog/status")!, headers: [:], body: nil)).json
        XCTAssertEqual(st?["state"]?.string, "library")

        // dritter Lauf: lokal, weder Bibliothek noch Netz (die 2 Anfragen oben: WS 2026/27 gibt es noch nicht, 404 gemerkt)
        XCTAssertEqual(loaderB.calls.filter { $0.contains("WS_2026_27") }.count, 2)
        let callsBefore = loaderB.calls.count
        let s3Raw = await sync(hostB, loaderB, ben).run()
        let s3 = try XCTUnwrap(s3Raw)
        XCTAssertEqual(s3["origin"]?.string, "local")
        XCTAssertEqual(loaderB.calls.count, callsBefore)
    }

    func testRaceUsesNextVariantAndNeverOverwrites() async throws {
        let store = Store()
        let ada = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-ada"), now: { Self.now })
        let ben = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-ben"), now: { Self.now })
        let meta = StudyCatalogMeta(university: "luh", program: "Technische Informatik", degree: "B.Sc.", po: "2022", code: "TIBSc22", catalogTerm: "WS 2025/26")
        let okA = try await ada.publish(key: Self.key, meta: meta, payload: "{\"a\": 1}")
        XCTAssertTrue(okA)
        // zweites Geraet baute zugleich: Variante 0 gehoert Ada -> Ben bekommt Variante 1, Adas Datensatz bleibt
        let okB = try await ben.publish(key: Self.key, meta: meta, payload: "{\"b\": 1}")
        XCTAssertTrue(okB)
        let all = (ada.cloud as! FakeCloud).all().sorted { $0.name < $1.name }
        XCTAssertEqual(all.map(\.name), ["\(Self.key)#0", "\(Self.key)#1"])
        XCTAssertEqual(all[0]["payload"]?.string, "{\"a\": 1}")
        XCTAssertEqual(all[1]["ownerRecordName"]?.string, "_user-ben")
        // derselbe Inhalt noch einmal: kein neuer Datensatz
        let again = try await ben.publish(key: Self.key, meta: meta, payload: "{\"b\": 1}")
        XCTAssertTrue(again)
        XCTAssertEqual((ada.cloud as! FakeCloud).all().count, 2)
        // hoechstens drei Varianten
        let cleo = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-cleo"), now: { Self.now })
        let dora = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-dora"), now: { Self.now })
        let okC = try await cleo.publish(key: Self.key, meta: meta, payload: "{\"c\": 1}")
        let okD = try await dora.publish(key: Self.key, meta: meta, payload: "{\"d\": 1}")
        XCTAssertTrue(okC)
        XCTAssertFalse(okD)
        let lookup = try await dora.lookup(key: Self.key)
        XCTAssertEqual(lookup, ["{\"a\": 1}", "{\"b\": 1}", "{\"c\": 1}"])
        // Fremde Form (falscher Name) wird nie gelesen
        let fake = FakeCloud(store: store, user: "_user-eve")
        var odd = CommunityRecord(type: "StudyCatalog", name: "anders")
        odd["catalogKey"] = .string(Self.key); odd["variant"] = .int(0); odd["payload"] = .string("{}")
        _ = try await fake.save(odd, in: .publicDB)
        let lookup2 = try await dora.lookup(key: Self.key)
        XCTAssertEqual(lookup2.count, 3)
    }

    func testBrokenLibraryEntryIsIgnoredAndWithoutICloudOnlyDownload() async throws {
        let store = Store()
        let eve = FakeCloud(store: store, user: "_user-eve")
        var bad = CommunityRecord(type: "StudyCatalog", name: "\(Self.key)#0")
        bad["catalogKey"] = .string(Self.key); bad["variant"] = .int(0); bad["payload"] = .string("{\"v\": 1}")
        _ = try await eve.save(bad, in: .publicDB)
        let noAccount = FakeCloud(store: store, user: "_user-ohne")
        noAccount.status = .noAccount
        let lib = CloudKitStudyCatalogLibrary(cloud: noAccount, now: { Self.now })
        let loader = StubLoader()
        loader.responses[Self.mirror] = StudyCatalogFetchResult(status: 200, data: try pdf)
        let sRaw = await sync(try await self.host(), loader, lib).run()
        let s = try XCTUnwrap(sRaw)
        XCTAssertEqual(s["state"]?.string, "ready", "ungueltiger Eintrag -> selbst laden")
        XCTAssertEqual(s["shared"], .bool(false), "ohne iCloud-Konto nichts veroeffentlicht")
        XCTAssertEqual(store.records.count, 1)
        // ohne Container im Build (Simulator, CI): Bibliothek nil, Download
        let s2Raw = await sync(try await self.host(), loader, nil).run()
        let s2 = try XCTUnwrap(s2Raw)
        XCTAssertEqual(s2["origin"]?.string, "download")
    }

    func testErrorIsStatusAndNotRetriedWithin24Hours() async throws {
        let loader = StubLoader()
        loader.responses[Self.mirror] = StudyCatalogFetchResult(status: 0, error: "offline")
        let h = try await host()
        let sRaw = await sync(h, loader, nil).run()
        let s = try XCTUnwrap(sRaw)
        XCTAssertEqual(s["state"]?.string, "error")
        XCTAssertEqual(s["message"]?.string, "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut.")
        let n = loader.calls.count
        _ = await sync(h, loader, nil).run()
        XCTAssertEqual(loader.calls.count, n)
    }

    func testNoQISProgramMeansNotFound() async throws {
        let sRaw = await sync(try await host(label: nil), StubLoader(), nil).run()
        let s = try XCTUnwrap(sRaw)
        XCTAssertEqual(s["state"]?.string, "not_found")
        XCTAssertEqual(s["message"]?.string, "Noch kein Studiengang bekannt. Verbinde QIS oder wähle deine Prüfungsordnung.")
    }

    // MARK: Grundstock (Ressource StudyCatalogSeed)

    static let seedKey = StudyCatalogText.libraryKey(university: "luh", code: "TIBSc25", term: "WS 2026/27")
    static let seedSource = "https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc25-WS_2026_27.pdf"

    /// gzip wie Pythons gzip.compress (Kopf, raw DEFLATE, CRC-32, Laenge)
    private func gzip(_ data: Data) throws -> Data {
        var crc: UInt32 = 0xffff_ffff
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        crc ^= 0xffff_ffff
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 2, 255])
        out.append(try SolutionDeflate.deflate(data))
        for v in [crc, UInt32(truncatingIfNeeded: data.count)] { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    /// Nachgebildetes Bundle mit StudyCatalogSeed/luh-index.json und luh.json.gz: der Fixture-Katalog als TIBSc25
    private func stubBundle() throws -> Bundle {
        let exp = try JSONValue.parse(repo("packages/shared-contracts/fixtures/study-catalog/expected.json"))
        var cat = try XCTUnwrap(exp["catalog"]?.object)
        cat["code"] = "TIBSc25"; cat["po"] = "2025"; cat["catalog_term"] = "WS 2026/27"
        cat["source"] = ["url": .string(Self.seedSource), "fetched_at": "2026-11-04T09:00:00Z", "sha256": .null]
        let catalog = JSONValue.object(cat)
        XCTAssertEqual(StudyCatalogValidator.validate(catalog), [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString).bundle", isDirectory: true)
        let sub = dir.appendingPathComponent("StudyCatalogSeed", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let body = JSONValue.object(["v": 1, "university": "luh", "catalogs": .array([catalog])]).jsonString(sortedKeys: true)
        try gzip(Data(body.utf8)).write(to: sub.appendingPathComponent("luh.json.gz"))
        let index: JSONValue = ["v": 1, "university": "luh", "entries": .array([[
            "key": "luh|technische-informatik|b.sc.|2017", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2017",
            "term": "WS 2026/27", "modules": 6, "qis_labels": ["Technische Informatik (PO-Version 2017)"], "code": "TIBSc25",
            "library_key": .string(Self.seedKey), "file": "luh.json.gz"]])]
        try Data(index.jsonString().utf8).write(to: sub.appendingPathComponent("luh-index.json"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    func testAppBundleShipsTheSeed() throws {
        let seed = try XCTUnwrap(StudyCatalogSync.bundledSeed, "Ressource StudyCatalogSeed fehlt im App-Bundle (xcodegen generate)")
        XCTAssertGreaterThan(seed.entries.count, 20)
        XCTAssertEqual(seed.terms(university: "luh", code: "TIBSc25"), ["WS 2026/27"])
        let p = try XCTUnwrap(seed.payload(key: Self.seedKey))
        XCTAssertEqual(StudyCatalogValidator.validate(try JSONValue.parse(p)), [])
    }

    /// Entscheidung des Abgleichs: Grundstock vor Bibliothek und Download (0 Anfragen fuer den Katalog, nichts geteilt),
    /// Stand "seed"; Modultexte erst beim Oeffnen eines Moduls, einmal je Katalog
    func testSyncTakesSeedBeforeLibraryAndLoadsTextsLazily() async throws {
        let seed = try XCTUnwrap(StudyCatalogSeed.bundled(try stubBundle()))
        let store = Store()
        let lib = CloudKitStudyCatalogLibrary(cloud: FakeCloud(store: store, user: "_user-ada"), now: { Self.now })
        let loader = StubLoader()
        loader.responses[Self.seedSource] = StudyCatalogFetchResult(status: 200, data: try pdf, etag: "\"s1\"")
        let h = try await host(po: nil)
        let sRaw = await sync(h, loader, lib, seed: seed).run()
        let s = try XCTUnwrap(sRaw)
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["message"]?.string, "Aus dem StudiNow-Grundstock")
        XCTAssertEqual(s["code"]?.string, "TIBSc25")
        XCTAssertEqual(s["needs_confirmation"], .bool(true))
        XCTAssertFalse(loader.calls.contains(Self.seedSource), "kein Katalog-Download")
        XCTAssertEqual(store.records.count, 0, "Grundstock wird nicht geteilt")
        let st = await h.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-catalog/status")!, headers: [:], body: nil)).json
        XCTAssertEqual(st?["state"]?.string, "seed")
        XCTAssertEqual(StudyCatalogStatus(st ?? .null).ready, true)
        XCTAssertEqual(StudyCatalogStatus(st ?? .null).text, "Aus dem StudiNow-Grundstock")
        // Modultexte: einmal die oeffentliche PDF, dann lokal
        let sy = sync(h, loader, lib, seed: seed)
        let tRaw = await sy.loadTexts(key: Self.seedKey)
        let t = try XCTUnwrap(tRaw)
        XCTAssertEqual(t["state"]?.string, "loaded", "\(t)")
        XCTAssertEqual(loader.calls.filter { $0 == Self.seedSource }.count, 1)
        let againRaw = await sy.loadTexts(key: Self.seedKey)
        let again = try XCTUnwrap(againRaw)
        XCTAssertEqual(again["state"]?.string, "have")
        XCTAssertEqual(loader.calls.filter { $0 == Self.seedSource }.count, 1, "einmal je Katalog")
        let m = await h.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-plan/module/beispielprogrammierung-1")!,
                                            headers: [:], body: nil)).json
        let d = StudyModuleDetail(m ?? .null)
        XCTAssertFalse(d.sections.isEmpty)
        XCTAssertFalse(d.textsLoading)
        // dritter Lauf: lokal
        let s3Raw = await sync(h, loader, lib, seed: seed).run()
        let s3 = try XCTUnwrap(s3Raw)
        XCTAssertEqual(s3["origin"]?.string, "local")
    }

    // MARK: Lader

    func testLoaderSendsNoCookiesAndConditionalHeaders() {
        let session = URLSessionStudyCatalogLoader.makeSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCache)
        let r = URLSessionStudyCatalogLoader.request(url: URL(string: Self.mirror)!, etag: "\"e1\"", lastModified: "Wed, 10 Jun 2026 14:39:51 GMT")
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"), "\"e1\"")
        XCTAssertEqual(r.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 10 Jun 2026 14:39:51 GMT")
        XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
    }

    func testLoaderRefusesPlainHTTP() async {
        let r = await URLSessionStudyCatalogLoader().fetch(url: "http://modkat.example/x.pdf", etag: nil, lastModified: nil)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.error, "nur https")
    }

    func testAutomaticRunsAreOffUnderXCTest() async throws {
        let h = try await host()
        StudyCatalogSync.attach(host: h)
        StudyCatalogSync.trigger(host: h)
        XCTAssertFalse(StudyCatalogTriggers.fire(databasePath: h.databaseURL.path), "unter XCTest kein Ausloeser")
    }
}
