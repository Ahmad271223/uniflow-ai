import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// KI-Hilfe breiter/schmaler ziehen (Meldung des Inhabers 11.11.2026): Grenzen (280 pt bis 60 % des Fensters, das
/// Dokument behaelt Platz neben Seitenleiste und Spalte daneben), Ziehen nach links/rechts je nach Lage der Leiste,
/// Schritte fuer VoiceOver, Merken je Geraet (UserDefaults) und Doppeltippen = Standardbreite.
@MainActor
final class TutorPanelWidthAppTests: XCTestCase {

    func testStandardWidthIsUnchanged() {
        XCTAssertEqual(TutorPanelWidth.standard(1180), 377.6, accuracy: 0.1)
        XCTAssertEqual(TutorPanelWidth.standard(700), 300)
        XCTAssertEqual(TutorPanelWidth.standard(2000), 400)
        XCTAssertEqual(DocumentView.tutorWidth(1180), TutorPanelWidth.standard(1180))
        // ohne gemerkte Breite wie bisher
        XCTAssertEqual(TutorPanelWidth.width(stored: 0, total: 1180), 377.6, accuracy: 0.1)
    }

    func testLimits() {
        XCTAssertEqual(TutorPanelWidth.minWidth, 280)
        XCTAssertEqual(TutorPanelWidth.clamp(100, total: 1180), 280, "nie schmaler als 280 pt")
        XCTAssertEqual(TutorPanelWidth.clamp(2000, total: 1180), 708, accuracy: 0.01, "hoechstens 60 % des Fensters")
        XCTAssertEqual(TutorPanelWidth.clamp(500, total: 1180), 500)
        // neben Seitenleiste (200) und Spalte daneben (30 % + Griff) behaelt das Dokument 240 pt
        let reserved: CGFloat = 201 + 1366 * 0.3 + 12
        XCTAssertEqual(TutorPanelWidth.maxWidth(total: 1366, reserved: reserved), 1366 - reserved - 240, accuracy: 0.01)
        XCTAssertEqual(TutorPanelWidth.maxWidth(total: 1180, reserved: 201 + 1180 * 0.42 + 12), 280, "zu eng: die Untergrenze gilt")
        // schmales Fenster (Slide Over, Stage Manager): die Untergrenze gewinnt
        XCTAssertEqual(TutorPanelWidth.maxWidth(total: 400), 280)
        XCTAssertEqual(TutorPanelWidth.width(stored: 600, total: 400), 280)
        // gemerkte Breite passt sich einem kleineren Fenster an (Drehen ins Hochformat) und kommt im Querformat wieder
        XCTAssertEqual(TutorPanelWidth.width(stored: 650, total: 834), 834 * 0.6, accuracy: 0.01)
        XCTAssertEqual(TutorPanelWidth.width(stored: 650, total: 1194), 650)
    }

    func testDragDirectionDependsOnTheSideOfThePanel() {
        // Leiste rechts (Griff an ihrem linken Rand): nach links ziehen = breiter
        XCTAssertEqual(TutorPanelWidth.dragged(from: 380, translation: -100, panelOnLeft: false, total: 1180), 480)
        XCTAssertEqual(TutorPanelWidth.dragged(from: 380, translation: 60, panelOnLeft: false, total: 1180), 320)
        // Leiste links (Linkshaender bzw. freie Hand links): nach rechts ziehen = breiter
        XCTAssertEqual(TutorPanelWidth.dragged(from: 380, translation: 100, panelOnLeft: true, total: 1180), 480)
        XCTAssertEqual(TutorPanelWidth.dragged(from: 380, translation: -500, panelOnLeft: true, total: 1180), 280)
        XCTAssertEqual(TutorPanelWidth.dragged(from: 380, translation: -900, panelOnLeft: false, total: 1180), 708, accuracy: 0.01)
    }

    func testVoiceOverStepsStayInsideTheLimits() {
        XCTAssertEqual(TutorPanelWidth.adjusted(380, wider: true, total: 1180), 420)
        XCTAssertEqual(TutorPanelWidth.adjusted(300, wider: false, total: 1180), 280)
        XCTAssertEqual(TutorPanelWidth.adjusted(700, wider: true, total: 1180), 708, accuracy: 0.01)
        XCTAssertEqual(TutorPanelWidth.valueText(377.6), "378 Punkt")
        XCTAssertEqual(TutorPanelWidth.label, "Breite der KI-Hilfe")
    }

    func testWidthIsRememberedPerDeviceAndDoubleTapResets() throws {
        let suite = "TutorPanelWidthAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TutorPanelWidth.stored(in: defaults), 0, "ohne Wert: Standard")
        TutorPanelWidth.save(512.4, in: defaults)
        XCTAssertEqual(TutorPanelWidth.stored(in: defaults), 512, "ganze Punkte")
        XCTAssertEqual(defaults.double(forKey: "uniflow.tutorWidth"), 512, "derselbe Schluessel wie @AppStorage der Ansichten")
        XCTAssertEqual(TutorPanelWidth.width(stored: TutorPanelWidth.stored(in: defaults), total: 1180), 512)
        TutorPanelWidth.save(nil, in: defaults)                 // Doppeltippen
        XCTAssertEqual(TutorPanelWidth.stored(in: defaults), 0)
        XCTAssertEqual(TutorPanelWidth.width(stored: 0, total: 1180), TutorPanelWidth.standard(1180))
    }

    /// Griff zeichnet sich (Linie wie bisher plus Griff) und traegt Bezeichnung und Kennung fuer VoiceOver
    func testHandleRendersWithAccessibility() throws {
        var stored = 0.0
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let host = UIHostingController(rootView: HStack(spacing: 0) {
            Color.white
            TutorResizeHandle(panelOnLeft: false, total: 1180, stored: binding)
            Color.gray.frame(width: TutorPanelWidth.width(stored: stored, total: 1180))
        }.frame(width: 1180, height: 600))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.subviews.count, 0)
        window.isHidden = true
    }
}
