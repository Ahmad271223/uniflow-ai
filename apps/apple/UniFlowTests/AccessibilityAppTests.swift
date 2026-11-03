import SwiftUI
import XCTest
@testable import UniFlow

/// Bedienungshilfen (F20): Textgroesse aus den Einstellungen, ohne die Web-Masse in der Standardgroesse zu veraendern.
final class AccessibilityAppTests: XCTestCase {

    func testStandardSizeKeepsTheWebSizes() {
        for s: CGFloat in [11.84, 13.12, 14.5, 17.6, 23.2] {
            XCTAssertEqual(UFScaledFont.scaled(s, .large), s, "Standardgroesse = Masse der Web-App")
        }
    }

    func testTextSizeFollowsTheSettingAndStopsAtAccessibility3() {
        let body: CGFloat = 14.5
        let small = UFScaledFont.scaled(body, .xSmall)
        let big = UFScaledFont.scaled(body, .xxxLarge)
        let ax3 = UFScaledFont.scaled(body, .accessibility3)
        XCTAssertLessThan(small, body)
        XCTAssertGreaterThan(big, body)
        XCTAssertGreaterThan(ax3, big)
        XCTAssertEqual(UFScaledFont.scaled(body, .accessibility5), ax3, "begrenzt auf Stufe 3")
        XCTAssertEqual(big * 4, (big * 4).rounded(), "Viertelpunkte, damit der Schrift-Zwischenspeicher klein bleibt")
    }
}

/// VoiceOver: Knoepfe nur mit Symbol haben einen deutschen Namen statt des Symbolnamens
final class AccessibilityLabelAppTests: XCTestCase {
    func testIconOnlyButtonsHaveGermanNames() {
        for icon in ["x", "trash", "chevron-left", "chevron-right", "settings", "panel-right", "more", "menu", "clock", "book", "sun", "moon"] {
            XCTAssertNotEqual(UFButton.spoken(icon), icon, icon)
        }
        XCTAssertEqual(UFButton.spoken("x"), "Schließen")
    }
}

/// Trefferflaechen (Apple: mindestens 44 x 44 pt): kleine Knoepfe, Chips, Kalender-Hinweis-Chips und das Logo bleiben
/// sichtbar und im Layout gleich gross, sind aber auf 44 x 44 pt antippbar (`ufHitArea`). Gemessen wird die gelegte
/// Flaeche selbst: eingefaerbt gerendert (`ufShowHitAreas`) und die roten Bildpunkte ausgemessen.
@MainActor
final class AccessibilityHitAreaAppTests: XCTestCase {

    func testRectGrowsToMinimumAndRespectsSlop() {
        XCTAssertEqual(UFHit.rect(for: CGSize(width: 28, height: 28)), CGRect(x: -8, y: -8, width: 44, height: 44))
        XCTAssertEqual(UFHit.rect(for: CGSize(width: 120, height: 50)), CGRect(x: 0, y: 0, width: 120, height: 50), "gross genug: nichts")
        // gestapelter Chip: oben halbe Luecke, der Rest nach unten
        let chip = UFHit.rect(for: CGSize(width: 120, height: 18),
                              slop: EdgeInsets(top: 1.2, leading: .infinity, bottom: .infinity, trailing: .infinity))
        XCTAssertEqual(chip.height, 44, accuracy: 0.001)
        XCTAssertEqual(chip.minY, -1.2, accuracy: 0.001)
        // Symbol zwischen zwei Nachbarn: beidseitig begrenzt, mehr geht nicht
        let tight = UFHit.rect(for: CGSize(width: 28, height: 28), slop: EdgeInsets(top: .infinity, leading: 1, bottom: .infinity, trailing: 1))
        XCTAssertEqual(tight.width, 30, accuracy: 0.001)
    }

    func testSmallButtonChipLogoAndHintChipAreTappableOn44pt() throws {
        let logo = UFLogoMenuTargets(items: [], go: { _ in })
        let cases: [(String, AnyView, CGFloat)] = [
            ("kleiner Symbolknopf", AnyView(UFButton(icon: "trash", kind: .ghost, size: .small) {}), 28),
            ("kleiner Knopf mit Text", AnyView(UFButton("Gesehen", kind: .ghost, size: .small) {}), 30),
            ("normaler Symbolknopf", AnyView(UFButton(icon: "clock", kind: .ghost) {}), 34),
            ("Chip", AnyView(UFChip(text: "Mo") {}), 30),
            ("Logo", AnyView(UFLogoMenu().environment(\.ufLogoMenu, logo)), 28),
        ]
        for (name, view, maxVisual) in cases {
            let visual = layoutSize(view)
            XCTAssertLessThanOrEqual(visual.height, maxVisual, "\(name): Layout unveraendert klein (\(visual))")
            let hit = try hitBox(view)
            XCTAssertGreaterThanOrEqual(hit.width, 43.5, "\(name): Trefferbreite \(hit)")
            XCTAssertGreaterThanOrEqual(hit.height, 43.5, "\(name): Trefferhoehe \(hit)")
        }
    }

    func testFlashcardIconPairSplitsTheGapAndStays44High() throws {
        let pair = AnyView(HStack(spacing: 2) {
            UFButton(icon: "bookmark", kind: .ghost, size: .small) {}.ufHitSlop(trailing: 1)
            UFButton(icon: "trash", kind: .ghost, size: .small) {}.ufHitSlop(leading: 1)
        })
        XCTAssertEqual(layoutSize(pair).width, 58, accuracy: 0.5, "zwei 28-pt-Symbole, 2 pt Luecke: Layout wie vorher")
        let hit = try hitBox(pair)
        XCTAssertGreaterThanOrEqual(hit.width, 2 * 44 - 0.5, "jedes Symbol 44 pt breit, ohne Ueberlappung")
        XCTAssertGreaterThanOrEqual(hit.height, 43.5)
    }

    // MARK: Hilfen

    private func layoutSize(_ view: AnyView) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 400, height: 400))
    }

    /// Rendert die Ansicht mittig auf 240 x 160 pt mit eingefaerbter Trefferflaeche und misst die roten Punkte aus
    private func hitBox(_ view: AnyView) throws -> CGRect {
        let canvas = view
            .environment(\.ufShowHitAreas, true)
            .frame(width: 240, height: 160)
            .background(Color.white)
        let r = ImageRenderer(content: canvas)
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let rr = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if rr - g > 40 && rr - b > 40 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        XCTAssertGreaterThanOrEqual(maxX, 0, "keine Trefferflaeche gezeichnet")
        return CGRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2, width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
    }
}
