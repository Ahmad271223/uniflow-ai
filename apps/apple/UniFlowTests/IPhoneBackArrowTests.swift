import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Zurueck-Pfeil auf dem iPhone (develop 06.11.2026, docs/IPHONE-2026-11-04.md): die Bereiche der unteren Leiste
/// (Start, Kalender, Module, Dokumente) sind Wurzeln ohne Pfeil, jede andere Seite hat genau einen in der kompakten
/// Kopfzeile; ist in einer Wurzel etwas offen (`ufLocalBack`), fuehrt er zuerst dorthin zurueck. Im Dokument steht
/// genau einer in der Werkzeugleiste (das System-Zurueck ist aus), auch in der alten Fassung.
final class IPhoneBackArrowTests: IPhoneLearnTestCase {

    func testCompactRules() {
        for r in [UFRoute.dashboard, .plan(), .plan(view: "month"), .modules, .files(), .files(section: "shelf")] {
            XCTAssertFalse(UFRouter.showsCompactBackArrow(on: r, local: false), "Wurzel der Leiste: \(r)")
            XCTAssertTrue(UFRouter.showsCompactBackArrow(on: r, local: true), "mit Offenem in der Seite: \(r)")
        }
        for r in [UFRoute.rooms, .uniMail, .mensa, .messages, .settings(), .module(3), .communitySpace("k"), .exam(1), .services, .timetable(),
                  .lecturers, .certificates] {
            XCTAssertTrue(UFRouter.showsCompactBackArrow(on: r, local: false), "\(r)")
        }
    }

    /// Knoepfe "Zurück" an verschiedenen Stellen (derselbe Knopf ueber zwei Wege zaehlt einmal)
    private func arrows(_ env: HostedEnvironment) -> [NSObject] {
        var seen = Set<String>()
        return elements(env).filter { e in
            guard e.accessibilityLabel == UFBackButton.title, e.accessibilityTraits.contains(.button) else { return false }
            let f = frame(e)
            return seen.insert("\(Int(f.midX.rounded())),\(Int(f.midY.rounded()))").inserted
        }
    }

    func testCompactShellShowsExactlyOneArrowOutsideTheTabRoots() throws {
        let env = try hostWithEnvironment(AppShell { route in Text("Seite \(route.navKey)") }, size: Self.phone)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        XCTAssertTrue(env.wait { self.shows(env, "Seite dashboard") }, dump(env))
        XCTAssertEqual(arrows(env).count, 0, "Start ohne Pfeil")
        env.router.go(.plan())
        XCTAssertTrue(env.wait { self.shows(env, "Seite plan") })
        XCTAssertEqual(arrows(env).count, 0, "Kalender (Leiste) ohne Pfeil")
        env.router.go(.rooms)
        XCTAssertTrue(env.wait { self.arrows(env).count == 1 }, "Raumfinder (aus Mehr): genau ein Pfeil: \(dump(env))")
        let arrow = frame(arrows(env).first), home = frame(element(env, id: "header.home"))
        XCTAssertLessThan(arrow.maxX, home.minX + 1, "Pfeil vor dem Logo")
        assertFits(env, "Kopfzeile mit Pfeil")
        XCTAssertTrue(arrows(env).first?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait { env.router.route == .plan() }, "zurueck zur vorigen Seite: \(env.router.route)")
        XCTAssertTrue(env.wait { self.arrows(env).count == 0 })
        // Wurzel mit Offenem in der Seite: Pfeil erscheint und schliesst zuerst das
        var closed = 0
        env.router.go(.modules)
        env.router.setLocalBack(id: "probe") { closed += 1 }
        XCTAssertTrue(env.wait { self.arrows(env).count == 1 }, dump(env))
        XCTAssertTrue(arrows(env).first?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait { closed == 1 && self.arrows(env).count == 0 })
        XCTAssertEqual(env.router.route, .modules)
        env.router.go(.uniMail)
        XCTAssertTrue(env.wait { self.arrows(env).count == 1 })
    }

    /// iPad (breit): weiter der Pfeil der breiten Kopfzeile auf jeder Seite ausser der Startseite, auch auf Wurzeln
    func testPadUnchanged() throws {
        let env = try hostWithEnvironment(AppShell { route in Text("Seite \(route.navKey)") }, size: Self.pad)
        env.hosting.traitOverrides.horizontalSizeClass = .regular
        XCTAssertTrue(env.wait { self.shows(env, "Seite dashboard") })
        XCTAssertEqual(arrows(env).count, 0)
        env.router.go(.modules)
        XCTAssertTrue(env.wait { self.arrows(env).count == 1 }, "iPad: Module mit Pfeil")
    }
}
