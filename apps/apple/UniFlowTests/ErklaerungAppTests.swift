import UniFlowCore
import XCTest
@testable import UniFlow

/// Erklaerungen von StudiNow (22.11.2026): wann der Kreis an der Datei steht, Kauf mit Attrappe des Geraete-Dienstes,
/// Abholen von selbst. Angebot, Ablage und Merker prueft der Kern (`ErklaerungShopTests`).
@MainActor
final class ErklaerungAppTests: XCTestCase {
    private typealias Offer = StudiNowErklaerungen.Offer

    /// Attrappe von `/api/erklaerungen/offer` und `/api/files/{id}/erklaerung/buy`
    private final class Device {
        var enabled = true
        var items: [JSONValue] = []
        var calls: [(String, JSONValue)] = []
        var buyError: Error?

        func answer(_ path: String, _ body: JSONValue) throws -> JSONValue {
            calls.append((path, body))
            if path == "/api/erklaerungen/offer" {
                let ids = Set((body["file_ids"]?.array ?? []).compactMap(\.string))
                return ["enabled": .bool(enabled), "price": 15, "items": .array(items.filter { ids.contains($0["file_id"]?.string ?? "") })]
            }
            if path.hasSuffix("/erklaerung/buy") {
                if let buyError { throw buyError }
                return ["owned": true, "charged": 15, "file_id": "f-vl3", "local_file_id": "u-erkl-1", "folder": "StudiNow-Erklärungen"]
            }
            return .null
        }
    }

    private func shop(_ device: Device, proAI: Bool = true) -> StudiNowErklaerungen {
        let s = StudiNowErklaerungen()
        s.call = { try device.answer($0, $1) }
        s.allowed = { proAI }
        return s
    }

    private static let vl3: JSONValue = ["file_id": "f-vl3", "sha256": .string(String(repeating: "a", count: 64)), "title": "Erklärung zu VL 3",
                                         "kind": "Erklärung Seite für Seite", "pages": 12, "owned": false, "price": 15, "stand": "2026-11-22"]

    func testBadgeOnlyWithProAIAnEnabledOfferAndAnOfferForThatFile() async {
        let device = Device()
        device.items = [Self.vl3]
        let s = shop(device)
        await s.load(fileIDs: ["f-vl3", "f-ub2"], api: nil)
        XCTAssertEqual(s.badge(for: "f-vl3")?.title, "Erklärung zu VL 3")
        XCTAssertEqual(s.badge(for: "f-vl3")?.kind, "Erklärung Seite für Seite")
        XCTAssertEqual(s.badge(for: "f-vl3")?.pages, 12)
        XCTAssertEqual(s.badge(for: "f-vl3")?.owned, false)
        XCTAssertNil(s.badge(for: "f-ub2"), "ohne Angebot kein Kreis")

        // Tarif faellt weg (Abo vorbei): sofort kein Kreis mehr, keine Werbung
        s.allowed = { false }
        XCTAssertNil(s.badge(for: "f-vl3"))

        // Angebot beim Dienst ausgeschaltet
        let off = Device()
        off.enabled = false
        off.items = [Self.vl3]
        let s2 = shop(off)
        await s2.load(fileIDs: ["f-vl3"], api: nil)
        XCTAssertNil(s2.badge(for: "f-vl3"))
    }

    func testWithoutProAINothingIsAsked() async {
        let device = Device()
        device.items = [Self.vl3]
        let s = shop(device, proAI: false)
        await s.load(fileIDs: ["f-vl3"], api: nil)
        XCTAssertTrue(device.calls.isEmpty)
        XCTAssertNil(s.badge(for: "f-vl3"))
        let collected = await s.refresh(force: true)
        XCTAssertNil(collected)
    }

    func testUnderTestNothingIsAskedWithoutOverride() async {
        let s = StudiNowErklaerungen()
        s.allowed = { true }
        await s.load(fileIDs: ["f-vl3"], api: nil)
        XCTAssertTrue(s.offers.isEmpty)
        let collected = await s.refresh(force: true)
        XCTAssertNil(collected)
    }

    func testReloadDropsOffersThatAreGone() async {
        let device = Device()
        device.items = [Self.vl3]
        let s = shop(device)
        await s.load(fileIDs: ["f-vl3"], api: nil)
        XCTAssertNotNil(s.badge(for: "f-vl3"))
        device.items = []
        await s.load(fileIDs: ["f-vl3"], api: nil)
        XCTAssertNil(s.badge(for: "f-vl3"))
    }

    func testTapDecidesBetweenOpenFetchAndAsk() {
        var o = Offer(fileID: "f", title: "T", kind: "K", pages: 3)
        XCTAssertEqual(ErklaerungAction.next(for: o), .ask, "nicht gekauft: Kauf-Blatt")
        o.owned = true
        XCTAssertEqual(ErklaerungAction.next(for: o), .fetch, "gekauft, aber nicht hier: kostenlos holen")
        o.localFileID = "u1"
        XCTAssertEqual(ErklaerungAction.next(for: o), .open("u1"))
    }

    func testBuyStoresAndTheBadgeTurnsIntoOpen() async throws {
        let device = Device()
        device.items = [Self.vl3]
        let s = shop(device)
        await s.load(fileIDs: ["f-vl3"], api: nil)
        let offer = try XCTUnwrap(s.badge(for: "f-vl3"))
        let local = try await s.obtain(offer, api: nil)
        XCTAssertEqual(local, "u-erkl-1")
        XCTAssertEqual(device.calls.last?.0, "/api/files/f-vl3/erklaerung/buy")
        XCTAssertEqual(s.badge(for: "f-vl3")?.owned, true)
        XCTAssertEqual(s.badge(for: "f-vl3").map(ErklaerungAction.next(for:)), .open("u-erkl-1"))
    }

    func testCreditsExhaustedKeepsTheOfferAndCarriesTheCode() async throws {
        let device = Device()
        device.items = [Self.vl3]
        device.buyError = APIError(status: 429, body: Data(#"{"detail": {"detail": "Deine Credits reichen nicht.", "code": "credits_exhausted"}}"#.utf8))
        let s = shop(device)
        await s.load(fileIDs: ["f-vl3"], api: nil)
        let offer = try XCTUnwrap(s.badge(for: "f-vl3"))
        do {
            _ = try await s.obtain(offer, api: nil)
            XCTFail("Kauf darf nicht klappen")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "credits_exhausted", "das Blatt oeffnet dann „Credits kaufen“")
            XCTAssertEqual(e.localizedDescription, "Deine Credits reichen nicht.")
        }
        XCTAssertEqual(s.badge(for: "f-vl3")?.owned, false)
    }

    func testTexts() {
        XCTAssertEqual(ErklaerungText.kindLine(kind: "Lösung Schritt für Schritt", pages: 1), "Lösung Schritt für Schritt · 1 Seite")
        XCTAssertEqual(ErklaerungText.kindLine(kind: "Erklärung Seite für Seite", pages: 0), "Erklärung Seite für Seite")
        XCTAssertEqual(ErklaerungText.price(15), "15 Credits")
        typealias A = StudiNowErklaerungen.Added
        XCTAssertEqual(ErklaerungText.notice([A(fileID: "f", localFileID: "u", module: "Analysis")]),
                       "Erklärung von StudiNow ist da: Bibliothek, Modul „Analysis“, Ordner „StudiNow-Erklärungen“.")
        XCTAssertEqual(ErklaerungText.notice([A(fileID: "f", localFileID: "u", module: "Analysis"), A(fileID: "g", localFileID: "v", module: "Physik")]),
                       "2 Erklärungen von StudiNow sind da: Bibliothek, Ordner „StudiNow-Erklärungen“ im jeweiligen Modul.")
        XCTAssertNil(ErklaerungText.notice([]))
    }

    func testCollectAtMostOncePerMinuteAndMarksTheBadgeOwned() async {
        let device = Device()
        device.items = [Self.vl3]
        let s = shop(device)
        await s.load(fileIDs: ["f-vl3"], api: nil)
        var calls = 0
        s.collectOverride = {
            calls += 1
            return calls == 1 ? [StudiNowErklaerungen.Added(fileID: "f-vl3", localFileID: "u-erkl-9", module: "Analysis")] : []
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        s.now = { clock }
        let toast = UFToastCenter()
        let router = UFRouter()
        s.attach(router: router, toast: toast, api: nil)
        for _ in 0..<200 where calls < 1 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(s.badge(for: "f-vl3")?.localFileID, "u-erkl-9")
        XCTAssertEqual(toast.message, "Erklärung von StudiNow ist da: Bibliothek, Modul „Analysis“, Ordner „StudiNow-Erklärungen“.")
        XCTAssertEqual(router.reloadToken, 1)
        _ = await s.refresh()
        XCTAssertEqual(calls, 1, "Vordergrund kurz danach: keine zweite Abfrage")
        clock += StudiNowErklaerungen.minInterval + 1
        _ = await s.refresh()
        XCTAssertEqual(calls, 2)
    }
}
