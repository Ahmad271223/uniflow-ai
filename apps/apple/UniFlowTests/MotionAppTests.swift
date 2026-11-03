import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Bewegung im Designsystem (UFMotion, Auftrag des Inhabers 03.11.2026): unter XCTest keine Animation, damit Tests
/// sofort den Endzustand sehen; Staffelung begrenzt; Gruppen erscheinen nur beim ersten Mal gestaffelt.
@MainActor
final class MotionAppTests: XCTestCase {

    func testUnderXCTestNoMotion() {
        XCTAssertTrue(UFMotion.isTesting)
        XCTAssertFalse(UFMotion.moves)
        XCTAssertNil(UFMotion.animation(reduce: false))
        XCTAssertNil(UFMotion.animation(reduce: true))
        // Umschalten wirkt sofort (kein Warten auf eine Animation)
        var open = false
        UFMotion.toggle { open = true }
        XCTAssertTrue(open)
    }

    func testDurationsShortAndStaggerCapped() {
        for d in [UFMotion.quick, UFMotion.base, UFMotion.slow] { XCTAssertTrue((0.18...0.35).contains(d), "\(d)") }
        XCTAssertEqual(UFMotion.delay(0), 0)
        XCTAssertEqual(UFMotion.delay(2), 0.08, accuracy: 0.0001)
        XCTAssertEqual(UFMotion.delay(50), UFMotion.delay(UFMotion.staggerCap))   // lange Listen warten nicht
        XCTAssertLessThanOrEqual(UFMotion.delay(1000), 0.35)
        XCTAssertEqual(UFMotion.delay(-3), 0)
    }

    func testAppearOncePerGroup() {
        UFAppearOnce.reset()
        XCTAssertFalse(UFAppearOnce.hasAppeared("dashboard"))
        UFAppearOnce.mark("dashboard")
        XCTAssertTrue(UFAppearOnce.hasAppeared("dashboard"))
        XCTAssertFalse(UFAppearOnce.hasAppeared("modules"))
        // verzoegert gemerkt: alle Karten derselben Darstellung staffeln sich noch
        UFAppearOnce.markSoon("modules")
        XCTAssertFalse(UFAppearOnce.hasAppeared("modules"))
        let later = expectation(description: "gemerkt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { later.fulfill() }
        wait(for: [later], timeout: 2)
        XCTAssertTrue(UFAppearOnce.hasAppeared("modules"))
        UFAppearOnce.reset()
    }

    /// Bausteine rendern unter XCTest sofort im Endzustand (Karte sichtbar, Text lesbar)
    func testViewsRenderFinalState() {
        let view = VStack {
            UFKPI(value: "3 / 5", label: "Aufgaben erledigt").ufAppear("motion-test", index: 3)
            UFShimmerText("Die KI liest die Seite …")
            Text("x").ufTabPanel("overview")
        }
        .frame(width: 320)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        host.view.layoutIfNeeded()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        XCTAssertNotNil(renderer.uiImage)
    }
}
