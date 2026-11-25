import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Absturzmeldung (25.11.2026, docs/ABSTURZMELDUNG-2026-11-25.md) gegen den Vertrag
// packages/shared-contracts/fixtures/crash-report/: aus Apples MetricKit-Daten (erfunden) baut die App genau
// `upload.json`; der Dienst nimmt genau diese Datei an (tests/test_crash_reports.py). Dazu: was das Geraet nie
// verlaesst, die Warteschlange und das Senden.

private func crashFixture(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/crash-report/\(name)"))
}

/// Schein-Dienst: merkt sich jede Anfrage, antwortet der Reihe nach mit den eingestellten Statuswerten (dann 200)
private final class CrashService: ServiceHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Int]
    private var seen: [AIHTTPRequest] = []
    var offline = false

    init(_ answers: [Int] = []) { self.answers = answers }

    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        let status: Int = try lock.withLock {
            seen.append(request)
            if offline { throw URLError(.notConnectedToInternet) }
            return answers.isEmpty ? 200 : answers.removeFirst()
        }
        return ServiceHTTPResponse(status: status, body: Data("{}".utf8))
    }

    var requests: [AIHTTPRequest] { lock.withLock { seen } }
    func ids(_ i: Int) throws -> [String] {
        let body = try JSONValue.parse(try XCTUnwrap(requests[i].body))
        return (body["reports"]?.array ?? []).compactMap { $0["id"]?.string }
    }
}

final class CrashReportTests: XCTestCase {
    private static let install = "0123456789abcdef0123456789abcdef"
    private static let context = MetricKitReports.Context(appVersion: "1.0.7", appBuild: "49", deviceClass: "ipad", channel: "store",
                                                          appBinaries: ["UniFlow"])

    private func date(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }

    /// fortlaufende Kennungen wie in der Fixture: …01, …02, …
    private func counter() -> () -> String {
        var n = 0
        return { n += 1; return String(repeating: "0", count: 32 - String(n).count) + String(n) }
    }

    private func fixtureReports() throws -> [CrashReport] {
        let id = counter()
        let diag = MetricKitReports.diagnostics(json: try crashFixture("metrickit-diagnostic.json"), at: try date("2026-11-24T08:15:00Z"),
                                                context: Self.context, newID: id)
        let exits = MetricKitReports.exits(json: try crashFixture("metrickit-metric.json"), at: try date("2026-11-23T23:00:00Z"),
                                           context: Self.context, newID: id)
        return diag + exits
    }

    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-outbox-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("absturzmeldungen.json")
    }

    private func report(_ n: Int, at: Date = Date()) -> CrashReport {
        CrashReport(id: String(format: "%032x", n), kind: .crash, at: at, appVersion: "1.0.7", appBuild: "49", deviceClass: "iphone",
                    channel: "store", signal: 11, frames: [.init(b: "UniFlow", o: 4096)])
    }

    // MARK: Vertrag

    func testAppleDataBecomesExactlyTheUploadOfTheContract() throws {
        let reports = try fixtureReports()
        XCTAssertEqual(reports.map(\.kind), [.crash, .crash, .hang, .exit, .exit])
        let body = CrashReportClient.body(install: Self.install, reports: reports)
        let expected = try JSONValue.parse(try crashFixture("upload.json"))
        XCTAssertEqual(body, expected, body.jsonString(sortedKeys: true))
        // und so, wie es wirklich ueber die Leitung geht (serialisiert und wieder gelesen)
        XCTAssertEqual(try JSONValue.parse(body.serialized()), expected)
    }

    /// Apples Paket enthaelt mehr, als gemeldet wird: Text der Ausnahme (mit Dateiname), Speicherangaben, Region,
    /// Prozessnummer, Kennung der App, Speicheradressen, Kennungen fremder Programmdateien. Nichts davon geht hinaus.
    func testNothingBeyondTheAgreedFieldsLeavesTheDevice() throws {
        let sent = CrashReportClient.body(install: Self.install, reports: try fixtureReports()).jsonString()
        for secret in ["Müller", "Klausur", "nicht gefunden", "composedMessage", "arguments", "not in any region", "virtualMemory",
                       "de.uniflow.ai", "bundleIdentifier", "regionFormat", "\"DE\"", "4711", "pid", "arm64e",
                       "4374642104", "address", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "11111111-2222"] {
            XCTAssertFalse(sent.contains(secret), secret)
        }
        // die Kennung der eigenen Programmdatei bleibt (zum Zuordnen des Builds), fremde fehlen
        XCTAssertTrue(sent.contains("70B89F27-1634-3580-A695-57CDB41D7743"))
        let allowed: Set<String> = ["id", "kind", "at", "app_version", "app_build", "device_class", "device_model", "os_version", "channel",
                                    "signal", "exception_type", "exception_code", "termination", "exception_name", "hang_seconds",
                                    "reason", "count", "frames"]
        for r in try fixtureReports() {
            XCTAssertTrue(Set(r.json.object?.keys.map { $0 } ?? []).isSubset(of: allowed))
        }
    }

    // MARK: Lesen von Apples Daten

    func testVersionOfTheCrashedAppWinsOverTheRunningOne() throws {
        // Absturz in 1.0.5, gemeldet nach dem Update von 1.0.7: es zaehlt 1.0.5 (44); TestFlight -> Quelle "test"
        let r = try fixtureReports()[1]
        XCTAssertEqual([r.appVersion, r.appBuild ?? "", r.channel], ["1.0.5", "44", "test"])
        // ohne Angaben von Apple: Version und Build der laufenden App
        let bare = Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"signal":"6"}}]}"#.utf8)
        let b = try XCTUnwrap(MetricKitReports.diagnostics(json: bare, at: Date(), context: Self.context).first)
        XCTAssertEqual([b.appVersion, b.appBuild ?? "", b.channel, b.deviceClass], ["1.0.7", "49", "store", "ipad"])
        XCTAssertEqual(b.signal, 6)                                           // Zahl als Text
        XCTAssertTrue(b.frames.isEmpty)
        XCTAssertEqual(b.id.count, 32)
        // fremde Version ohne Build: nicht den Build der laufenden App dazudichten
        let other = Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"appVersion":"1.0.6"}}]}"#.utf8)
        XCTAssertNil(MetricKitReports.diagnostics(json: other, at: Date(), context: Self.context).first?.appBuild)
    }

    func testUnreadableOrEmptyDataGivesNoReport() {
        for raw in ["", "kein json", "[]", "{}", #"{"crashDiagnostics":"x","hangDiagnostics":7}"#] {
            XCTAssertTrue(MetricKitReports.diagnostics(json: Data(raw.utf8), at: Date(), context: Self.context).isEmpty, raw)
            XCTAssertTrue(MetricKitReports.exits(json: Data(raw.utf8), at: Date(), context: Self.context).isEmpty, raw)
        }
        // Tageszaehlung nur mit Nullen: nichts zu melden
        let zeros = Data(#"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAbnormalExitCount":0,"cumulativeNormalAppExitCount":9}}}"#.utf8)
        XCTAssertTrue(MetricKitReports.exits(json: zeros, at: Date(), context: Self.context).isEmpty)
    }

    func testBackgroundExitsAndNormalExitsAreNotReported() throws {
        let exits = try fixtureReports().filter { $0.kind == .exit }
        XCTAssertEqual(exits.map { "\($0.reason ?? "")=\($0.count ?? 0)" }, ["memory_limit=2", "bad_access=1"])
    }

    /// Form eines echten Messwerte-Pakets (am 25.11.2026 per Kabel von einem iPad gelesen, Build 49; hier nur die Teile,
    /// die die App liest): `appVersion` oben, Build und Modell in `metaData`, in `foregroundExitData` stehen nur Gruende
    /// mit einer Zahl groesser 0, Zeitstempel als "yyyy-MM-dd HH:mm:ss".
    func testShapeOfARealMetricPayloadFromADevice() throws {
        func payload(_ foreground: String) -> Data {
            Data(#"{"timeStampBegin":"2026-11-24 00:00:00","timeStampEnd":"2026-11-25 00:00:00","appVersion":"1.0.7","metaData":{"appBuildVersion":"49","pid":-1,"regionFormat":"DE","isTestFlightApp":false,"osVersion":"iPhone OS 27.2.1 (24B156)","deviceType":"iPad15,7","bundleIdentifier":"de.uniflow.ai","platformArchitecture":"arm64e","lowPowerModeEnabled":false},"applicationExitMetrics":{"backgroundExitData":{"cumulativeNormalAppExitCount":1,"cumulativeMemoryPressureExitCount":1},"foregroundExitData":\#(foreground)}}"#.utf8)
        }
        let old = MetricKitReports.Context(appVersion: "1.0.8", appBuild: "50", deviceClass: "ipad", channel: "test", appBinaries: ["UniFlow"])
        // so kam es wirklich: vorn nur ein normales Ende -> nichts zu melden
        XCTAssertTrue(MetricKitReports.exits(json: payload(#"{"cumulativeNormalAppExitCount":1}"#), at: Date(), context: old).isEmpty)
        XCTAssertTrue(MetricKitReports.exits(json: payload("{}"), at: Date(), context: old).isEmpty)
        // dieselbe Form mit einem Speicher-Ende
        let r = try XCTUnwrap(MetricKitReports.exits(json: payload(#"{"cumulativeMemoryResourceLimitExitCount":1}"#), at: Date(), context: old).first)
        XCTAssertEqual([r.appVersion, r.appBuild ?? "", r.deviceModel ?? "", r.osVersion ?? "", r.channel, r.reason ?? ""],
                       ["1.0.7", "49", "iPad15,7", "iPhone OS 27.2.1 (24B156)", "test", "memory_limit"])
        XCTAssertEqual(r.count, 1)
    }

    func testLongCallChainKeepsBothEnds() {
        func chain(_ n: Int) -> JSONValue {
            var frame: JSONValue = .object(["binaryName": .string("dyld"), "offsetIntoBinaryTextSegment": .number(Double(n))])
            for i in stride(from: n - 1, through: 1, by: -1) {
                frame = .object(["binaryName": .string("UniFlow"), "offsetIntoBinaryTextSegment": .number(Double(i)), "subFrames": .array([frame])])
            }
            return .object(["callStacks": .array([.object(["threadAttributed": .bool(true), "callStackRootFrames": .array([frame])])])])
        }
        let short = MetricKitReports.frames(chain(MetricKitReports.maxFrames), context: Self.context)
        XCTAssertEqual(short.count, MetricKitReports.maxFrames)
        XCTAssertFalse(short.contains { $0.b == MetricKitReports.cutMarker })
        let long = MetricKitReports.frames(chain(100), context: Self.context)
        XCTAssertEqual(long.count, MetricKitReports.maxFrames)
        XCTAssertEqual(long.prefix(20).map(\.o), Array(1...20))
        XCTAssertEqual(long[20], CrashReport.Frame(b: MetricKitReports.cutMarker, o: 69))    // 100 - 20 - 11 ausgelassen
        XCTAssertEqual(long.suffix(11).map(\.o), Array(90...100))
        XCTAssertEqual(long.last?.b, "dyld")
    }

    func testHangDurationIsReadInSeconds() {
        let cases: [(JSONValue, Double?)] = [(.string("20 sec"), 20), (.string("1500 ms"), 1.5), (.string("2 min"), 120),
                                             (.string("0,75 s"), 0.75), (.number(3.5), 3.5), (.string("lange"), nil),
                                             (.number(-1), nil), (.null, nil)]
        for (value, expected) in cases { XCTAssertEqual(MetricKitReports.seconds(value), expected, "\(value)") }
    }

    func testTextsAreCutToHarmlessCharacters() {
        XCTAssertEqual(MetricKitReports.plain("Namespace SIGNAL, Code 0xb <Müller.pdf>\n\"x\"", limit: 160), "Namespace SIGNAL, Code 0xb Mller.pdfx")
        XCTAssertEqual(MetricKitReports.plain(String(repeating: "a", count: 300), limit: 48)?.count, 48)
        XCTAssertNil(MetricKitReports.plain("„“", limit: 10))
        XCTAssertNil(MetricKitReports.name("NSException mit Text"))
        XCTAssertEqual(MetricKitReports.name("NSInvalidArgumentException"), "NSInvalidArgumentException")
        XCTAssertNil(MetricKitReports.model("iPad14,3; x"))
        XCTAssertEqual(CrashReport.timestamp(Date(timeIntervalSince1970: 1_795_508_100.9)), "2026-11-24T08:15:00Z")
    }

    // MARK: Senden

    func testRequestGoesWithoutAccountToTheCrashPath() async throws {
        let service = CrashService()
        let client = CrashReportClient(base: "https://dienst.example/", http: service)
        let outcome = await client.send(install: Self.install, reports: [report(1)])
        XCTAssertEqual(outcome, .done)
        let r = try XCTUnwrap(service.requests.first)
        XCTAssertEqual([r.method, r.url], ["POST", "https://dienst.example/api/diagnose/crashes"])
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertNil(r.headers["Authorization"])                              // kein Konto, keine Sitzung
        let body = try JSONValue.parse(try XCTUnwrap(r.body))
        XCTAssertEqual(Set(body.object?.keys.map { $0 } ?? []), ["v", "install", "reports"])
        XCTAssertEqual(body["v"]?.int, 1)
    }

    func testOutcomeFollowsTheAnswerOfTheService() async {
        for (status, expected) in [(200, CrashReportClient.Outcome.done), (400, .refused), (413, .refused), (422, .refused),
                                   (401, .later), (404, .later), (429, .later), (500, .later), (503, .later)] {
            let client = CrashReportClient(base: "https://dienst.example", http: CrashService([status]))
            let outcome = await client.send(install: Self.install, reports: [report(1)])
            XCTAssertEqual(outcome, expected, "\(status)")
        }
        let service = CrashService()
        service.offline = true
        let outcome = await CrashReportClient(base: "https://dienst.example", http: service).send(install: Self.install, reports: [report(1)])
        XCTAssertEqual(outcome, .later)
    }

    // MARK: Warteschlange

    func testOutboxKeepsReportsAcrossAppStarts() async throws {
        let file = tempFile()
        let first = CrashReportOutbox(file: file)
        await first.add(try fixtureReports(), now: try date("2026-11-25T08:00:00Z"))
        await first.add([try fixtureReports()[0]], now: try date("2026-11-25T08:00:00Z"))      // dieselbe Meldung noch einmal
        let again = CrashReportOutbox(file: file)                             // "naechster Start"
        let pending = await again.pending()
        XCTAssertEqual(pending, try fixtureReports())
        await again.clear()
        let after = await CrashReportOutbox(file: file).pending()
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOutboxDropsOldReportsAndKeepsOnlyTheNewest() async throws {
        let now = try date("2026-11-25T08:00:00Z")
        let box = CrashReportOutbox(file: tempFile())
        await box.add([report(1, at: now.addingTimeInterval(-31 * 86_400)), report(2, at: now.addingTimeInterval(-29 * 86_400))], now: now)
        let kept = await box.pending().map(\.id)
        XCTAssertEqual(kept, [String(format: "%032x", 2)])
        await box.add((10..<(10 + CrashReportOutbox.maxPending + 5)).map { report($0, at: now) }, now: now)
        let all = await box.pending()
        XCTAssertEqual(all.count, CrashReportOutbox.maxPending)
        XCTAssertEqual(all.last?.id, String(format: "%032x", 10 + CrashReportOutbox.maxPending + 4))
    }

    func testFlushSendsInBatchesAndEmptiesTheOutbox() async throws {
        let now = Date()
        let box = CrashReportOutbox(file: tempFile())
        await box.add((1...45).map { report($0, at: now) }, now: now)
        let service = CrashService()
        let gone = await box.flush(install: Self.install, client: CrashReportClient(base: "https://dienst.example", http: service), now: now)
        XCTAssertEqual(gone, 45)
        XCTAssertEqual(try (0..<3).map { try service.ids($0).count }, [20, 20, 5])
        XCTAssertEqual(service.requests.count, 3)
        let rest = await box.pending()
        XCTAssertTrue(rest.isEmpty)
    }

    func testFlushKeepsReportsWhenTheServiceIsNotReachable() async throws {
        let now = Date()
        let box = CrashReportOutbox(file: tempFile())
        await box.add((1...25).map { report($0, at: now) }, now: now)
        let service = CrashService([200, 429])                                // erstes Paket angenommen, dann Grenze erreicht
        let client = CrashReportClient(base: "https://dienst.example", http: service)
        let gone = await box.flush(install: Self.install, client: client, now: now)
        XCTAssertEqual(gone, 20)
        let waiting = await box.pending().count
        XCTAssertEqual(waiting, 5)
        service.offline = true
        let none = await box.flush(install: Self.install, client: client, now: now)
        XCTAssertEqual(none, 0)
        service.offline = false                                               // naechster Start: Rest geht hinaus
        let rest = await box.flush(install: Self.install, client: client, now: now)
        XCTAssertEqual(rest, 5)
        XCTAssertEqual(try service.ids(service.requests.count - 1).first, String(format: "%032x", 21))
    }

    func testRefusedReportsAreDroppedInsteadOfSentForever() async throws {
        let now = Date()
        let box = CrashReportOutbox(file: tempFile())
        await box.add([report(1, at: now)], now: now)
        let gone = await box.flush(install: Self.install, client: CrashReportClient(base: "https://dienst.example", http: CrashService([400])), now: now)
        XCTAssertEqual(gone, 1)
        let rest = await box.pending()
        XCTAssertTrue(rest.isEmpty)
    }
}

// Durchlauf gegen den echten Dienst (tools/absturz-durchlauf.sh startet ihn mit einem Wegwerf-Datenordner und liest
// danach die Auswertung): Apples (erfundene) Daten -> Warteschlange -> POST /api/diagnose/crashes. Ohne
// CRASH_TEST_SERVICE uebersprungen.
final class CrashReportLiveTests: XCTestCase {
    private struct LiveHTTP: ServiceHTTPTransport {
        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            var q = URLRequest(url: URL(string: r.url)!)
            q.httpMethod = r.method
            q.httpBody = r.body
            for (k, v) in r.headers { q.setValue(v, forHTTPHeaderField: k) }
            let (d, resp) = try await URLSession.shared.data(for: q)
            return ServiceHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
        }
    }

    func testMadeUpCrashTravelsFromTheDeviceCodeToTheService() async throws {
        guard let base = ProcessInfo.processInfo.environment["CRASH_TEST_SERVICE"] else { throw XCTSkip("CRASH_TEST_SERVICE fehlt") }
        let context = MetricKitReports.Context(appVersion: "1.0.7", appBuild: "49", deviceClass: "ipad", channel: "store", appBinaries: ["UniFlow"])
        let now = Date()
        let reports = MetricKitReports.diagnostics(json: try crashFixture("metrickit-diagnostic.json"), at: now, context: context)
            + MetricKitReports.exits(json: try crashFixture("metrickit-metric.json"), at: now, context: context)
        XCTAssertEqual(reports.count, 5)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-live-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let box = CrashReportOutbox(file: dir.appendingPathComponent("absturzmeldungen.json"))
        await box.add(reports, now: now)
        let client = CrashReportClient(base: base, http: LiveHTTP())
        let install = CrashReport.newID()
        let gone = await box.flush(install: install, client: client, now: now)
        XCTAssertEqual(gone, 5)
        let rest = await box.pending()
        XCTAssertTrue(rest.isEmpty)
        // dieselben Meldungen noch einmal (Antwort ging verloren): der Dienst nimmt an, legt aber nichts doppelt ab
        let again = await client.send(install: install, reports: reports)
        XCTAssertEqual(again, .done)
    }
}
