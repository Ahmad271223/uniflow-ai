import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Raumfinder auf dem iPhone (docs/IPHONE-2026-11-04.md, docs/RAUMFINDER-2026-11-05.md): Suchfeld und "Suchen" in
/// voller Breite untereinander, Beispiele als Reihe, Treffer als Karten, Ort als Blatt von unten (halb/ganz) mit
/// "In Google Maps öffnen" und "Route" in voller Breite untereinander; Standorte ebenso. Gegenprobe iPad: Knoepfe in
/// einer Reihe wie bisher. Daten: lokales Backend mit den Demo-Treffern des Standortfinders, kein Netz.
final class IPhoneRoomFinderTests: IPhoneLearnTestCase {

    private func device() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-rooms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func presentedFrame(_ env: HostedEnvironment) -> CGRect {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed,
              let v = p.presentationController?.presentedView ?? p.view else { return .null }
        return v.convert(v.bounds, to: nil)
    }

    /// Knopf mit diesem Namen innerhalb des offenen Blatts (die Seite darunter hat dieselben Knoepfe bei den Standorten)
    private func inSheet(_ env: HostedEnvironment, _ label: String) -> NSObject? {
        let sheet = presentedFrame(env)
        return elements(env).first { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
            && sheet.insetBy(dx: -1, dy: -1).contains(frame($0)) }
    }

    func testSearchFullWidthAndPlaceAsBottomSheetWithWideMapsButtons() throws {
        let env = try hostPhone(RoomFinderPage(), api: try device())
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Hauptgebäude (Welfengarten)") }, dump(env))
        let width = env.window.bounds.width
        let field = frame(element(env, label: "Raum, Gebäude, Einrichtung"))
        let go = frame(button(env, "Suchen"))
        XCTAssertGreaterThan(go.width, width * 0.8, "Suchen in voller Breite: \(go)")
        XCTAssertGreaterThan(go.minY, field.minY, "Suchen unter dem Feld")
        // Standorte: Google Maps und Route in voller Breite untereinander
        let google = frame(button(env, "In Google Maps öffnen"))
        let route = frame(button(env, "Route zu Fuß in Google Maps"))
        XCTAssertGreaterThan(google.width, width * 0.7, "\(google)")
        XCTAssertGreaterThan(route.minY, google.maxY - 1, "Route unter Google Maps")
        XCTAssertGreaterThanOrEqual(google.height, 39.5)
        assertFitsOnAllPhones(env, "Raumfinder")
        shoot(env, "iphone-raumfinder")

        // Beispiel antippen -> ein Treffer als Karte -> Ort als Blatt von unten
        XCTAssertTrue(tap(env, "F102"))
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "1 Treffer") }, dump(env))
        let card = frame(button(env, "Raum F102", prefix: true))
        XCTAssertGreaterThan(card.width, width * 0.8, "Treffer als Karte in voller Breite")
        XCTAssertTrue(tap(env, "Raum F102", prefix: true))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetOpen(env) && self.inSheet(env, "In Google Maps öffnen") != nil }, dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(Set(sheet.sheetPresentationController?.detents.map(\.identifier) ?? []), [.medium, .large], "halb und ganz")
        env.pump(0.6)
        let s = presentedFrame(env)
        let g = frame(inSheet(env, "In Google Maps öffnen")), r = frame(inSheet(env, "Route zu Fuß in Google Maps"))
        XCTAssertGreaterThan(g.width, s.width * 0.8, "Google Maps in voller Breite: \(g) in \(s)")
        XCTAssertEqual(r.width, g.width, accuracy: 1, "Route gleich breit")
        XCTAssertGreaterThan(r.minY, g.maxY - 1, "untereinander")
        XCTAssertTrue(shows(env, "Route zu Fuß in Google Maps"))
        assertFits(env, "Ort")
        shoot(env, "iphone-raumfinder-ort")
        dismissSheet(env)
    }

    func testPadKeepsMapsButtonsInARow() throws {
        let env = try hostPad(RoomFinderPage(), api: try device())
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "In Google Maps öffnen") != nil }, dump(env))
        let google = frame(button(env, "In Google Maps öffnen")), route = frame(button(env, "Route zu Fuß in Google Maps"))
        XCTAssertEqual(google.midY, route.midY, accuracy: 2, "iPad: in einer Reihe")
        XCTAssertLessThan(google.width, 300)
        let field = frame(element(env, label: "Raum, Gebäude oder Einrichtung (z. B. F102, 1101, Bibliothek)")), go = frame(button(env, "Suchen"))
        XCTAssertGreaterThan(go.minX, field.minX, "iPad: Suchen neben dem Feld")
    }
}
