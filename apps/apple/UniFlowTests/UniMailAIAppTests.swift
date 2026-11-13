import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Uni-Mail "Mit KI verbessern" (13.11.2026): Knopf mit Schloss "ab Pro AI" ohne Pro AI, Vorschlag mit "Übernehmen"
/// und X; gesendet wird nie aus dem Vorschlag.
@MainActor
final class UniMailAIAppTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func labels(_ view: UIView) -> [String] { elements(in: view).compactMap(\.accessibilityLabel) }

    private func tap(_ label: String, in view: UIView) -> Bool {
        elements(in: view).contains { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label && $0.accessibilityActivate() }
    }

    func testButtonShowsLockWithoutProAIAndOpensOnTap() throws {
        var taps = 0
        let locked = try hostWithEnvironment(UniMailAIButton(access: .planRequired, busy: false, empty: true) { taps += 1 },
                                             size: CGSize(width: 600, height: 200))
        XCTAssertTrue(locked.wait { self.labels(locked.view).contains("Mit KI verbessern (ab Pro AI)") }, labels(locked.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Mit KI verbessern (ab Pro AI)", in: locked.view), "Schloss: Antippen auch ohne Text (oeffnet die Tarifwahl)")
        XCTAssertEqual(taps, 1)

        let ready = try hostWithEnvironment(UniMailAIButton(access: .ready, busy: false, empty: false) { taps += 1 },
                                            size: CGSize(width: 600, height: 200))
        XCTAssertTrue(ready.wait { self.labels(ready.view).contains("Mit KI verbessern") }, labels(ready.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Mit KI verbessern", in: ready.view))
        XCTAssertEqual(taps, 2)

        let busy = try hostWithEnvironment(UniMailAIButton(access: .ready, busy: true, empty: false) { taps += 1 },
                                           size: CGSize(width: 600, height: 200))
        XCTAssertTrue(busy.wait { self.labels(busy.view).contains("KI verbessert …") }, labels(busy.view).joined(separator: "\n"))
    }

    func testProposalAcceptAndDismiss() throws {
        var decisions: [String] = []
        let env = try hostWithEnvironment(UniMailAIProposal(text: "Sehr geehrter Herr Meier,\nich habe eine Frage.",
                                                            accept: { decisions.append("übernehmen") }, dismiss: { decisions.append("x") }),
                                          size: CGSize(width: 700, height: 400))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Vorschlag der KI") }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(labels(env.view).contains { $0.contains("Sehr geehrter Herr Meier") })
        XCTAssertTrue(tap("Vorschlag nicht übernehmen", in: env.view))
        XCTAssertTrue(tap("Übernehmen", in: env.view))
        XCTAssertEqual(decisions, ["x", "übernehmen"])
    }
}
