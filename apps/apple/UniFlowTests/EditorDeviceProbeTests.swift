import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Geraete-Probe der Werkzeugpalette (03.11.2026): laeuft nur mit der Umgebungsvariable `UF_DEVICE_PROBE=1` (Xcode:
/// Schema → Test → Arguments → Environment; xcodebuild: `TEST_RUNNER_UF_DEVICE_PROBE=1`), sonst uebersprungen.
/// Oeffnet ein kleines Dokument im Editor (eigener Ordner, nichts aus den Containern), zeigt die Palette und schreibt
/// ins Testprotokoll (jede Zeile mit "[Probe]"): Eintraege der Palette (`toolItems`), gewaehltes Werkzeug, `isVisible`,
/// `showsDrawingPolicyControls`, Eingabeart der Zeichenflaechen, Fenster der Szene. Dazu ein Bild der Palette als
/// Anhang des Tests (Xcode: Testbericht → Anhaenge). Gleiche Ausgabe in der App: Startargument `-UFPaletteProbe 1`.
@MainActor
final class EditorDeviceProbeTests: XCTestCase {

    private func say(_ s: String) {
        print("[Probe] " + s)
        NSLog("[Probe] %@", s)
    }

    private func pdf() -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
        "Probe der Palette".draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    func testPaletteOnTheDevice() async throws {
        guard ProcessInfo.processInfo.environment["UF_DEVICE_PROBE"] == "1" else {
            throw XCTSkip("Geräte-Probe nur mit UF_DEVICE_PROBE=1 (TEST_RUNNER_UF_DEVICE_PROBE=1 bei xcodebuild)")
        }
        say("Geraet: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), Mac-Modus \(PDFEditorController.isMac)")
        say("eigene Eintraege moeglich (iOS 18+): \(EditorPalette.supportsCustomItems)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-03T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "probe-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-probe"), .text("Probe"), .text("WiSe 2026/27"), .text("Probe"), .text("vorlesung"), .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-probe"), .text("Probe.pdf"), .integer(1_792_000_000), .text("2026-11-03T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf().write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Probe.pdf", title: "Probe", kind: "pdf", module_id: nil, subject: "Probe", doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-11-03T08:00:00", has_notes: nil, page_count: 1, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }

        // wie DocumentView: Palette aus `EditorPalette.makePicker()`, eigener Speichername wie in der App
        let picker = EditorPalette.makePicker()
        say("Palette frisch: " + EditorPalette.describe(picker, editor: nil).joined(separator: " / "))
        let editor = PDFEditorController(store: store, toolPicker: picker)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = scene?.screen.bounds ?? UIScreen.main.bounds
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        editor.showToolPicker(true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        for line in EditorPalette.describe(picker, editor: editor) { say(line) }
        XCTAssertTrue(picker.isVisible, "Palette steht")
        if EditorPalette.supportsCustomItems {
            XCTAssertTrue(EditorPalette.hasCustomItems(picker), "unsere Eintraege fehlen in der Palette")
        }

        // Bild jedes Fensters der Szene als Anhang (die Palette liegt in einem Fenster von PencilKit bzw. UIKit)
        if let scene = window.windowScene {
            for (i, w) in scene.windows.enumerated() where !w.isHidden {
                let name = String(describing: type(of: w))
                let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
                let a = XCTAttachment(image: img)
                a.name = "Fenster-\(i)-\(name)"
                a.lifetime = .keepAlways
                add(a)
                say("Bild angehaengt: Fenster \(i) \(name) \(Int(w.bounds.width))x\(Int(w.bounds.height))")
                if let out = ProcessInfo.processInfo.environment["UF_PROBE_IMAGE_DIR"] {
                    let url = URL(fileURLWithPath: out).appendingPathComponent("fenster-\(i)-\(name).png")
                    try? img.pngData()?.write(to: url)
                    say("Bild gespeichert: \(url.path)")
                }
            }
        }
    }
}
