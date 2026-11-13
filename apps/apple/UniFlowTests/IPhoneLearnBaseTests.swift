import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gemeinsame Hilfen der iPhone-Pruefungen der Lernbereiche (KI-Start, Karteikarten, Tests, Bibliothek, Community;
/// docs/IPHONE-2026-11-04.md): gehostet in 402 x 874 pt (iPhone 17 hoch) mit schmaler Groessenklasse, iPad-Gegenprobe
/// in 1180 x 820 mit breiter. Elemente werden im ganzen Fenster gesucht (Blaetter von unten liegen ausserhalb der
/// gehosteten Ansicht). Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreiben die Tests Bilder
/// hell und dunkel. Nur erfundene Daten, kein Netz.
@MainActor
class IPhoneLearnTestCase: XCTestCase {
    static let phone = CGSize(width: 402, height: 874)
    static let phoneSmall = CGSize(width: 390, height: 844)
    static let phoneMax = CGSize(width: 440, height: 956)
    static let pad = CGSize(width: 1180, height: 820)

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    /// Schmal gehostet (iPhone): Groessenklasse compact, Fensterbreite wie das Geraet
    func hostPhone<V: View>(_ view: V, api: APIClient, size: CGSize = IPhoneLearnTestCase.phone) throws -> HostedEnvironment {
        // wie in der Huelle (`AppShell` setzt `ufCompact` schmal fuer alle Seiten)
        let env = try hostWithEnvironment(view.environment(\.ufWindowWidth, size.width).environment(\.ufCompact, true), api: api, size: size)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.pump(0.3)
        return env
    }

    /// Breit gehostet (iPad quer): Groessenklasse regular
    func hostPad<V: View>(_ view: V, api: APIClient, size: CGSize = IPhoneLearnTestCase.pad) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(view.environment(\.ufWindowWidth, size.width), api: api, size: size)
        env.hosting.traitOverrides.horizontalSizeClass = .regular
        env.pump(0.3)
        return env
    }

    /// Schein-Transport mit festen Antworten je Pfad
    final class Canned: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: JSONValue] = [:]
        private var log: [(method: String, path: String, body: JSONValue?)] = []

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { answers[path] = v } }
        func bodies(_ path: String) -> [JSONValue] { lock.withLock { log.filter { $0.path == path }.compactMap(\.body) } }
        func count(_ path: String) -> Int { lock.withLock { log.filter { $0.path == path }.count } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            let a: JSONValue? = lock.withLock { log.append((request.httpMethod ?? "GET", path, body)); return answers[path] }
            let data = (a ?? ["detail": "nicht da"]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: a == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func remote(_ t: Canned) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }
    func local(_ t: Canned) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    // MARK: Elemente im ganzen Fenster

    func elements(_ env: HostedEnvironment) -> [NSObject] {
        env.window.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 80 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false || identifier(o) != nil { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 600) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(env.window, depth: 0)
        return out
    }

    /// Kennung eines Elements; SwiftUI-Elemente melden sie teils ohne erklaerte Protokoll-Konformitaet
    func identifier(_ o: NSObject) -> String? {
        let id = Self.ident(o)
        return id?.isEmpty == false ? id : nil
    }

    /// Kennung eines Elements; SwiftUI-Elemente melden sie ohne erklaerte Protokoll-Konformitaet
    static func ident(_ o: NSObject) -> String? {
        if let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier { return id }
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue() as? String
    }

    func texts(_ env: HostedEnvironment) -> [String] {
        elements(env).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: " | ") }

    func element(_ env: HostedEnvironment, label: String, prefix: Bool = false) -> NSObject? {
        elements(env).first { e in
            guard let l = e.accessibilityLabel else { return false }
            return prefix ? l.hasPrefix(label) : l == label
        }
    }

    func element(_ env: HostedEnvironment, id: String) -> NSObject? { elements(env).first { identifier($0) == id } }

    func button(_ env: HostedEnvironment, _ label: String, prefix: Bool = false) -> NSObject? {
        elements(env).first { e in
            guard e.accessibilityTraits.contains(.button), let l = e.accessibilityLabel else { return false }
            return prefix ? l.hasPrefix(label) : l == label
        }
    }

    @discardableResult
    func tap(_ env: HostedEnvironment, _ label: String, prefix: Bool = false) -> Bool {
        for e in elements(env) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { env.pump(0.2); return true }
        }
        return false
    }

    /// Lage eines Elements im Fenster (Bildschirmkoordinaten = Fenster, es liegt bei 0,0)
    func frame(_ e: NSObject?) -> CGRect { e?.accessibilityFrame ?? .null }

    /// Ein Blatt von unten ist offen
    func sheetOpen(_ env: HostedEnvironment) -> Bool { env.hosting.presentedViewController != nil }

    /// Wartet auf ein offenes Blatt mit `text`
    @discardableResult
    func waitSheet(_ env: HostedEnvironment, showing text: String) -> Bool {
        env.wait(timeout: 10) { self.sheetOpen(env) && self.shows(env, text) }
    }

    /// Blatt schliessen und warten, bis es weg ist
    func dismissSheet(_ env: HostedEnvironment) {
        env.hosting.dismiss(animated: false)
        env.wait(timeout: 5) { !self.sheetOpen(env) }
        env.pump(0.3)
    }

    // MARK: Pruefungen

    /// Nichts ragt rechts oder links ueber das Fenster (Inhalt waagerecht scrollender Reihen ausgenommen)
    func assertFits(_ env: HostedEnvironment, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        env.pump(0.3)
        // die Abdunkelung hinter einem Blatt (UIDimmingView) ist absichtlich groesser als das Fenster
        let found = LayoutWidthAuditTests.overflows(in: env.window).filter { !$0.text.contains("UIDimmingView") }
        XCTAssertTrue(found.isEmpty, "\(name): \(found.count) zu breit\n" + found.prefix(20).map(\.text).joined(separator: "\n"), file: file, line: line)
    }

    /// Prueft dieselbe Ansicht in den drei iPhone-Groessen (390, 402, 440 pt hoch)
    func assertFitsOnAllPhones(_ env: HostedEnvironment, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for size in [Self.phoneSmall, Self.phone, Self.phoneMax] {
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.pump(0.4)
            assertFits(env, "\(name) @ \(Int(size.width))", file: file, line: line)
        }
        env.window.frame = CGRect(origin: .zero, size: Self.phone)
        env.view.frame = env.window.bounds
        env.pump(0.3)
    }

    // MARK: Bilder

    /// Bild des ganzen Fensters (mit Blaettern) hell und dunkel nach UF_SCREENSHOT_DIR; ohne die Variable nichts
    func shoot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.5)
            let window = env.window
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        env.window.overrideUserInterfaceStyle = .unspecified
        env.pump(0.2)
    }

    /// Ergebnis einer async-Aufgabe aus einem synchronen Test
    func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
}
