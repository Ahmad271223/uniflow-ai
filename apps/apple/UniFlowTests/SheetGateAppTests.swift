import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Blaetter am Mac ("Designed for iPad", Befund 14.11.2026, docs/MAC-DURCHLAUF-2026-11-14.md): SwiftUI baut den Inhalt
/// eines Blatts dort einmal zu frueh auf, mit leerer Umgebung. Liest eine Ansicht mit Verzweigung im `body` dabei ein
/// Umgebungsobjekt, stuerzt die App ab ("No ObservableObject of type … found"; im Mac-Lauf vom 14.11.2026 dreimal:
/// "Wochentest erstellen" und "Frag die KI" als Blatt). `ufSheet`, `ufFullScreenCover` und `ufPopover` bauen den Inhalt
/// am Mac erst auf, wenn die Umgebung da ist (`UFSheetGate`). Am Mac waeren diese Tests ohne die Schranke ein Absturz;
/// am iPad pruefen sie, dass der Inhalt wie bisher erscheint und die Einstellungen des Blatts ankommen.
@MainActor
final class SheetGateAppTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var show = false
        @Published var name = "da"
    }

    nonisolated(unsafe) static var built = 0

    /// Verzweigung im `body` und ein Umgebungsobjekt: die Form, die am Mac abstuerzte
    struct Content: View {
        @EnvironmentObject var model: Model
        var body: some View {
            let _ = SheetGateAppTests.built += 1
            VStack {
                if model.name == "da" { Text("Inhalt da") } else { Text("Inhalt anders") }
            }
            .presentationDetents([.medium])
            .interactiveDismissDisabled(true)
        }
    }

    enum Kind { case sheet, itemSheet, cover, itemCover, popover }

    struct Token: Identifiable { let id = 1 }

    struct Root: View {
        @EnvironmentObject var model: Model
        let kind: Kind

        private var item: Binding<Token?> {
            Binding(get: { model.show ? Token() : nil }, set: { if $0 == nil { model.show = false } })
        }

        var body: some View {
            switch kind {
            case .sheet: Text("Wurzel").ufSheet(isPresented: $model.show) { Content() }
            case .itemSheet: Text("Wurzel").ufSheet(item: item) { _ in Content() }
            case .cover: Text("Wurzel").ufFullScreenCover(isPresented: $model.show) { Content() }
            case .itemCover: Text("Wurzel").ufFullScreenCover(item: item) { _ in Content() }
            case .popover: Text("Wurzel").ufPopover(isPresented: $model.show, arrowEdge: .top) { Content() }
            }
        }
    }

    private func present(_ kind: Kind) -> (presented: UIViewController?, built: Int) {
        Self.built = 0
        let model = Model()
        let frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let host = UIHostingController(rootView: Root(kind: kind).environmentObject(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.show = true
        let end = Date().addingTimeInterval(8)
        while (host.presentedViewController == nil || Self.built == 0) && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let presented = host.presentedViewController
        addTeardownBlock { @MainActor in
            host.dismiss(animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.isHidden = true
            window.rootViewController = nil
        }
        return (presented, Self.built)
    }

    func testSheetBuildsContentWithEnvironmentObjectAndKeepsItsSettings() throws {
        let r = present(.sheet)
        let presented = try XCTUnwrap(r.presented, "Blatt offen")
        XCTAssertGreaterThan(r.built, 0, "Inhalt aufgebaut")
        XCTAssertEqual(presented.sheetPresentationController?.detents.count, 1, "Höhe des Blatts kommt aus dem Inhalt")
        XCTAssertTrue(presented.isModalInPresentation, "Wegwischen gesperrt wie im Inhalt verlangt")
    }

    func testItemSheetBuildsContent() {
        let r = present(.itemSheet)
        XCTAssertNotNil(r.presented)
        XCTAssertGreaterThan(r.built, 0)
    }

    func testFullScreenCoverBuildsContent() {
        let r = present(.cover)
        XCTAssertNotNil(r.presented)
        XCTAssertGreaterThan(r.built, 0)
    }

    func testItemFullScreenCoverBuildsContent() {
        let r = present(.itemCover)
        XCTAssertNotNil(r.presented)
        XCTAssertGreaterThan(r.built, 0)
    }

    func testPopoverBuildsContent() {
        let r = present(.popover)
        XCTAssertNotNil(r.presented)
        XCTAssertGreaterThan(r.built, 0)
    }

    /// Am iPad und iPhone sofort, am Mac erst mit der Umgebung
    func testGateOpensAtOnceExceptOnTheMacBeforeTheEnvironmentArrived() {
        XCTAssertTrue(UFSheetGate<EmptyView>.open(mac: false, arrived: false), "iPad und iPhone: wie bisher sofort")
        XCTAssertTrue(UFSheetGate<EmptyView>.open(mac: false, arrived: true))
        XCTAssertFalse(UFSheetGate<EmptyView>.open(mac: true, arrived: false), "Mac: nicht mit leerer Umgebung")
        XCTAssertTrue(UFSheetGate<EmptyView>.open(mac: true, arrived: true))
    }

    /// Kein Blatt der App oeffnet an der Schranke vorbei (Quellen; am Mac nicht lesbar, dann uebersprungen)
    func testAppOpensSheetsOnlyThroughTheGate() throws {
        try ContainerTestBed.requireRepoSources()
        let root = ContainerTestBed.repoURL("apps/apple/UniFlow")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UFSheetGate.swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, root.path)
        let direct = try NSRegularExpression(pattern: #"\.(sheet|fullScreenCover|popover)\("#)
        var hits: [String] = []
        var gated = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if direct.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(file.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(100))")
                }
                if line.contains(".ufSheet(") || line.contains(".ufFullScreenCover(") || line.contains(".ufPopover(") { gated += 1 }
            }
        }
        XCTAssertEqual(hits, [], "Blätter nur über ufSheet, ufFullScreenCover, ufPopover öffnen (Absturz am Mac)")
        XCTAssertGreaterThan(gated, 90, "die Blätter der App laufen über die Schranke")
    }
}
