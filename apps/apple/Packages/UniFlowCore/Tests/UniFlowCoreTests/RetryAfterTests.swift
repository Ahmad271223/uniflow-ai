import Foundation
import XCTest
@testable import UniFlowCore

/// "Retry-After" der Hochschule beachten (26.11.2026, "Abruf schonen"): eine kurze verlangte Ruhe wird abgewartet, eine
/// lange beendet die Wiederholungen dieses Laufs, statt nach 1,5 s erneut zu fragen. Kein Netz, keine echte Wartezeit
/// ausser einer Sekunde im Test fuer die kurze Ruhe.
final class RetryAfterTests: XCTestCase {
    private let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })

    // MARK: Kopfzeile lesen

    func testSecondsAndHTTPDatesAreRead() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(UniRetry.retryAfter("120", now: now), 120)
        XCTAssertEqual(UniRetry.retryAfter(" 5 ", now: now), 5)
        XCTAssertEqual(UniRetry.retryAfter("0", now: now), 0)
        XCTAssertEqual(UniRetry.retryAfter("-3", now: now), 0, "nie negativ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(UniRetry.retryAfter(f.string(from: now.addingTimeInterval(90)), now: now), 90)
        XCTAssertEqual(UniRetry.retryAfter(f.string(from: now.addingTimeInterval(-90)), now: now), 0, "Datum vorbei: sofort")
        XCTAssertNil(UniRetry.retryAfter(nil, now: now))
        XCTAssertNil(UniRetry.retryAfter("", now: now))
        XCTAssertNil(UniRetry.retryAfter("bald", now: now))
    }

    func testWaitTakesTheLongerPauseAndGivesUpBeyondTheLimit() {
        let r = UniRetry()                                       // eigene Pause 1,5 s, 3 s
        XCTAssertEqual(r.wait(attempt: 1, retryAfter: nil), 1_500_000_000)
        XCTAssertEqual(r.wait(attempt: 1, retryAfter: 1), 1_500_000_000, "die eigene Pause ist laenger")
        XCTAssertEqual(r.wait(attempt: 1, retryAfter: 10), 10_000_000_000)
        XCTAssertEqual(r.wait(attempt: 1, retryAfter: UniRetry.maxRetryAfter), 30_000_000_000)
        XCTAssertNil(r.wait(attempt: 1, retryAfter: UniRetry.maxRetryAfter + 1), "mehr Ruhe verlangt: aufgeben")
    }

    // MARK: Learnweb, LSF, QIS, Moodle (UniTransport.fetch)

    private final class Scripted: UniTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [UniResponse]
        private(set) var calls = 0
        init(_ replies: [UniResponse]) { self.replies = replies }
        func send(_ request: UniRequest) async throws -> UniResponse { next() }
        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse { next() }
        private func next() -> UniResponse {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    private let page = UniRequest(url: URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user")!)

    func testLongRetryAfterEndsTheRetriesAtOnce() async {
        let t = Scripted([UniResponse(status: 429, headers: ["Retry-After": "600"]), UniResponse(status: 200)])
        do {
            _ = try await t.fetch(page, retry: noWait)
            XCTFail("erwartet: HTTP 429")
        } catch {
            XCTAssertEqual(error as? HildesheimError, .http(status: 429, url: "https://lsf.uni-hildesheim.de/qisserver/rds"))
            XCTAssertTrue(AutoSyncOverload.mentionsOverload((error as? HildesheimError)?.description), "der Abgleich ruht dann 2 Stunden")
        }
        XCTAssertEqual(t.calls, 1, "kein zweiter Versuch, die Hochschule will 10 Minuten Ruhe")
    }

    func testShortRetryAfterIsWaitedForAndTheRequestSucceeds() async throws {
        let t = Scripted([UniResponse(status: 503, headers: ["retry-after": "1"]), UniResponse(status: 200, body: Data("ok".utf8))])
        let start = Date()
        let r = try await t.fetch(page, retry: noWait)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(t.calls, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9, "die verlangte Sekunde wurde abgewartet")
    }

    func testWithoutRetryAfterEverythingStaysAsBefore() async throws {
        let t = Scripted([UniResponse(status: 503), UniResponse(status: 502), UniResponse(status: 200)])
        let r = try await t.fetch(page, retry: noWait)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(t.calls, 3)
    }

    // MARK: Stud.IP (StudIPClient)

    private final class StudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [HTTPReply]
        private(set) var calls = 0
        init(_ replies: [HTTPReply]) { self.replies = replies }
        func get(_ url: URL, accept: String?) async throws -> HTTPReply { next() }
        func download(_ url: URL, to file: URL) async throws -> HTTPReply { next() }
        private func next() -> HTTPReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    private let json = HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(#"{"data":[]}"#.utf8))

    func testStudIPStopsTheWholeRunWhenItAsksForALongRest() async {
        let t = StudIP([HTTPReply(status: 429, retryAfter: "300"), json])
        let client = StudIPClient(base: URL(string: "https://studip.uni-hannover.de/")!, transport: t, pauseMillis: 0, retry: noWait)
        do {
            _ = try await client.json("jsonapi.php/v1/users/me/courses")
            XCTFail("erwartet: HTTP 429")
        } catch {
            XCTAssertEqual(error as? StudIPError, .http(status: 429, path: "jsonapi.php/v1/users/me/courses"))
        }
        XCTAssertEqual(t.calls, 1)
        // die naechste Anfrage desselben Laufs (z. B. ein anderer Kurs) fragt Stud.IP gar nicht erst
        do {
            _ = try await client.json("jsonapi.php/v1/courses/abc/folders")
            XCTFail("erwartet: HTTP 429 ohne Anfrage")
        } catch {
            XCTAssertTrue(AutoSyncOverload.mentionsOverload((error as? StudIPError)?.description))
        }
        XCTAssertEqual(t.calls, 1, "keine weitere Anfrage an Stud.IP")
        let rest = await client.restUntil
        XCTAssertNotNil(rest)
    }

    func testStudIPWaitsAShortRestAndCarriesOn() async throws {
        let t = StudIP([HTTPReply(status: 429, retryAfter: "1"), json])
        let client = StudIPClient(base: URL(string: "https://studip.uni-hannover.de/")!, transport: t, pauseMillis: 0, retry: noWait)
        let start = Date()
        _ = try await client.json("jsonapi.php/v1/users/me/courses")
        XCTAssertEqual(t.calls, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9)
        let rest = await client.restUntil
        XCTAssertNil(rest, "kurze Ruhe: der Lauf geht weiter")
    }

    func testStudIPWithoutRetryAfterRetriesAsBefore() async throws {
        let t = StudIP([HTTPReply(status: 429), HTTPReply(status: 500), json])
        let client = StudIPClient(base: URL(string: "https://studip.uni-hannover.de/")!, transport: t, pauseMillis: 0, retry: noWait)
        _ = try await client.json("jsonapi.php/v1/users/me/courses")
        XCTAssertEqual(t.calls, 3)
    }
}
