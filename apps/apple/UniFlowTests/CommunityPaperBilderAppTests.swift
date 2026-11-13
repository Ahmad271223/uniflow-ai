import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bilder fuer den Inhaber (13.11.2026): Loesung einer anderen Person neben dem eigenen Dokument, Folien auf der eigenen
/// PDF, eigene Blaetter auf ihrem Papier; einmal rechts, einmal links. Nur mit UF_SCREENSHOT_DIR (sonst uebersprungen).
@MainActor
final class CommunityPaperBilderAppTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !d.isEmpty else { throw XCTSkip("nur mit UF_SCREENSHOT_DIR") }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
    }

    @discardableResult
    private func run<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(90)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(result, "Zeitlimit").get()
    }

    private func shot(_ view: UIView, _ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func elements(in root: Any) -> [NSObject] {
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                out.append(o)
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    @discardableResult
    private func tap(containing text: String, in root: UIView) -> Bool {
        for e in elements(in: root) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, l.contains(text) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func shows(_ text: String, in root: UIView) -> Bool {
        elements(in: root).contains { ($0.accessibilityLabel ?? "").contains(text) }
    }

    func testLoesungDanebenMitPapier() throws {
        let pdf = CommunityPaperAppTests.slides(3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papier-bilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Konto der Absenderin (eigener Datenordner)
        let miaHost = LocalBackendHost(directory: root.appendingPathComponent("mia/db", isDirectory: true), clock: .fixed(berlin: "2026-11-13T10:00:00")!)
        let miaAPI = APIClient(base: APIClient.localBase, transport: LocalTransport(host: miaHost))
        let (blob, solutionID) = try run { try await CommunityPaperAppTests.authorPackage((root.appendingPathComponent("mia"), miaAPI), pdf: pdf, test: self) }
        addTeardownBlock { @MainActor in try? SolutionSharing.library.remove(solutionID) }

        // Konto des Betrachters: eigene Kopie der PDF, eigene Notiz auf Folie 1, Loesung importiert
        let benDir = root.appendingPathComponent("ben", isDirectory: true)
        let host = LocalBackendHost(directory: benDir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-13T10:00:00")!,
                                    files: LocalFiles(container: benDir, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let main: LibFile = try run {
            let src = root.appendingPathComponent("Übung 4.pdf")
            try pdf.write(to: src)
            let id = try await ExternalFileImport.create(try ExternalFileImport.stage(src, container: nil), api: api)
            let f = try await api.json("/api/files/\(id)", as: LibFile.self)
            let s = DocumentStore(file: f, api: api)
            await s.load()
            s.canvasChanged(pageKey: "p1", drawing: CommunityPaperAppTests.ink(120))
            await s.flush()
            let pkg = root.appendingPathComponent("Mia.uniflowsolution")
            try blob.write(to: pkg)
            let result = try await s.importSolution(pkg)
            if case .shown = result {} else { XCTFail("Loesung nicht angezeigt: \(result)") }
            await s.close()
            return f
        }

        let previousSwap = UserDefaults.standard.string(forKey: SplitSides.swappedKey)
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previousSwap, forKey: SplitSides.swappedKey) }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: main, api: api) }, api: api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        // Fussleiste: "1 Lösung(en) eingeblendet · daneben ansehen"
        XCTAssertTrue(env.wait(timeout: 20) { self.tap(containing: "daneben ansehen", in: env.window) }, "Lösung daneben öffnen")
        XCTAssertTrue(env.wait(timeout: 15) { self.shows("nur ansehen", in: env.window) }, "Spalte daneben")
        env.pump(2.5)
        shot(env.window, "1-loesung-daneben")
        // Seiten tauschen (wie Ziehen an der Kopfzeile bzw. "Seiten tauschen")
        let key = SplitSides.pairKey(primary: main.id, side: "loesung:" + solutionID)
        UserDefaults.standard.set(SplitSides.toggling(previousSwap ?? "", key: key), forKey: SplitSides.swappedKey)
        env.pump(2.0)
        shot(env.window, "2-loesung-daneben-getauscht")

        // ganze Spalte: alle Seiten untereinander
        let layer: ForeignSolutionLayer = try run {
            let s = DocumentStore(file: main, api: api)
            await s.load()
            let content = try SolutionPackage.decode(blob).open(originalPDF: pdf, cipher: CryptoKitSolutionCipher())
            let l = try SolutionSharing.layer(content, visible: true, pdf: try XCTUnwrap(s.originalPDF))
            await s.close()
            return l
        }
        let source = OffscreenPDF(url: AppPaths.pdf(main.id, namespace: api.namespace))
        let column = try hostWithEnvironment(SolutionSidePane(layer: layer, source: source, onClose: {}).frame(width: 520), api: api,
                                             size: CGSize(width: 520, height: 2700))
        column.pump(3.0)
        shot(column.view, "3-alle-seiten-untereinander")
    }
}
