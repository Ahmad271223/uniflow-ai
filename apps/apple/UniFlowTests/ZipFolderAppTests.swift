import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// ZIP-Dateien in StudiNow (07.11.2026): ZIP aus der Bibliothek als Ordner, PDF daraus mit Stift (Import ins Modul,
/// Verknuepfung bleibt), Bearbeiten und wieder als ZIP packen, verschluesselte ZIP mit klarer Meldung, Ansicht im
/// Simulator. Die Bibliothek ist ein Transport im Speicher (erfundene Daten), kein Server.
@MainActor
final class ZipFolderAppTests: XCTestCase {

    /// Bibliothek mit einer ZIP-Datei: /content, Import nach /api/notebooks, /api/files/{id}
    final class FakeLibrary: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        var zip: Data
        private(set) var uploads: [String] = []
        private var created: [String: String] = [:]

        init(zip: Data) { self.zip = zip }

        var uploadCount: Int { lock.withLock { uploads.count } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            func reply(_ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
                (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!)
            }
            if path == "/api/files/zip1/content" { return reply(200, lock.withLock { zip }) }
            if path == "/api/notebooks", method == "POST" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let id: String = lock.withLock {
                    let id = "pdf\(uploads.count + 1)"
                    uploads.append(body)
                    created[id] = id
                    return id
                }
                return reply(200, Data(#"{"id":"\#(id)"}"#.utf8))
            }
            if path.hasPrefix("/api/files/pdf"), method == "GET" {
                let id = String(path.dropFirst("/api/files/".count))
                guard lock.withLock({ created[id] != nil }) else { return reply(404, Data(#"{"detail":"Not Found"}"#.utf8)) }
                return reply(200, Data(#"{"id":"\#(id)","name":"aufgabe.pdf","title":"aufgabe","kind":"pdf","module_id":7,"downloaded_at":"2026-11-07","has_notes":0,"page_count":1}"#.utf8))
            }
            return reply(404, Data(#"{"detail":"Not Found"}"#.utf8))
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static func pdf(_ text: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
    }

    /// Uebungs-ZIP wie aus Stud.IP: Blatt, Vorlage, Quelltext, Bild, Unterordner
    static func exerciseZip() throws -> Data {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try ZipArchive.pack([
            .init(path: "Blatt 03", data: nil),
            .init(path: "Blatt 03/Aufgabenblatt 03.pdf", data: pdf("Übungsblatt 3")),
            .init(path: "Blatt 03/Vorlage", data: nil),
            .init(path: "Blatt 03/Vorlage/main.py", data: Data("def loesung():\n    return 42\n".utf8)),
            .init(path: "Blatt 03/Vorlage/README.md", data: Data("# Abgabe\nNamen eintragen.\n".utf8)),
            .init(path: "Blatt 03/skizze.png", data: png),
            .init(path: "Hinweise zur Abgabe.txt", data: Data("Abgabe bis Freitag.\n".utf8)),
            .init(path: "Daten.csv", data: Data("x,y\n1,2\n".utf8)),
        ])
    }

    private func file(name: String = "Übungsblatt 03.zip") -> LibFile {
        LibFile(id: "zip1", name: name, title: "Übungsblatt 03", kind: "file", module_id: 7, subject: "Algorithmen", doc_type: nil,
                ai_title: nil, sub_label: nil, downloaded_at: "2026-11-07", has_notes: 0, page_count: nil, studip_folder: nil)
    }

    private func model(_ lib: FakeLibrary) throws -> ZipFolderModel {
        ZipFolderModel(file: file(), api: APIClient(base: APIClient.localBase, transport: lib), root: try tempDir().appendingPathComponent("ws"))
    }

    // MARK: Laden, Ordner, Bearbeiten

    func testOpensZipAsFolderAndNavigates() async throws {
        let m = try model(FakeLibrary(zip: try Self.exerciseZip()))
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.items.map(\.name), ["Blatt 03", "Daten.csv", "Hinweise zur Abgabe.txt"])
        XCTAssertEqual(m.totals.files, 6)
        m.open(folder: "Blatt 03")
        XCTAssertEqual(m.items.map(\.name), ["Vorlage", "Aufgabenblatt 03.pdf", "skizze.png"])
        XCTAssertEqual(m.breadcrumbs.map(\.name), ["Übungsblatt 03", "Blatt 03"])
        XCTAssertEqual(m.items.map(ZipOpenKind.of), [.folder, .pdf, .preview])
        m.open(folder: "Blatt 03/Vorlage")
        XCTAssertEqual(m.items.map(ZipOpenKind.of), [.text, .text])
        m.up()
        XCTAssertEqual(m.dir, "Blatt 03")
    }

    func testPDFOpensInEditorOnceAndEditsRepack() async throws {
        let lib = FakeLibrary(zip: try Self.exerciseZip())
        let m = try model(lib)
        await m.load()
        m.open(folder: "Blatt 03")
        let pdf = try XCTUnwrap(m.items.first { $0.name == "Aufgabenblatt 03.pdf" })
        let doc = await m.editorDocument(for: pdf)
        XCTAssertEqual(doc?.id, "pdf1")
        XCTAssertTrue(doc?.isPDF == true)
        XCTAssertEqual(lib.uploadCount, 1)
        XCTAssertTrue(lib.uploads[0].contains("Aufgabenblatt 03 (Übungsblatt 03)"), "Titel nennt die ZIP")
        XCTAssertTrue(lib.uploads[0].contains("name=\"module_id\"") && lib.uploads[0].contains("\r\n7\r\n"), "im Modul der ZIP")
        XCTAssertTrue(m.hasNotesLink(pdf))
        // zweites Oeffnen: dasselbe Dokument (Notizen bleiben), kein neuer Import
        let again = await m.editorDocument(for: pdf)
        XCTAssertEqual(again?.id, "pdf1")
        XCTAssertEqual(lib.uploadCount, 1)

        // bearbeiten: Text aendern, Ordner, Datei hinzufuegen, umbenennen, loeschen
        m.open(folder: "Blatt 03/Vorlage")
        m.saveText("def loesung():\n    return 41 + 1\n", to: "Blatt 03/Vorlage/main.py")
        let extra = try tempDir().appendingPathComponent("Abgabe Gruppe 4.pdf")
        try Self.pdf("Unsere Lösung").write(to: extra)
        m.add([extra])
        m.makeFolder("Tests")
        let readme = try XCTUnwrap(m.items.first { $0.name == "README.md" })
        m.rename(readme, to: "LIESMICH.md")
        m.open(folder: "")
        m.delete(try XCTUnwrap(m.items.first { $0.name == "Daten.csv" }))
        XCTAssertNil(m.error)
        XCTAssertTrue(m.changed)

        let url = await m.export(withNotes: false)
        let zipURL = try XCTUnwrap(url)
        XCTAssertEqual(zipURL.lastPathComponent, "Übungsblatt 03.zip")
        let out = try tempDir()
        try ZipArchive.extract(Data(contentsOf: zipURL), to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out.appendingPathComponent("Blatt 03/Vorlage/main.py")), as: UTF8.self),
                       "def loesung():\n    return 41 + 1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Blatt 03/Vorlage/Abgabe Gruppe 4.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Blatt 03/Vorlage/LIESMICH.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Blatt 03/Vorlage/Tests").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Daten.csv").path))

        // geaenderter Stand bleibt beim erneuten Oeffnen; eine neue Fassung in der Bibliothek wird nur angeboten
        let reopened = ZipFolderModel(file: file(), api: m.api, root: m.workspace.root)
        await reopened.load()
        XCTAssertFalse(reopened.items.contains { $0.name == "Daten.csv" })
        lib.zip = try ZipArchive.pack([.init(path: "Blatt 03 neu.pdf", data: Self.pdf("neu"))])
        await reopened.load()
        XCTAssertNotNil(reopened.newerSource)
        await reopened.reset()
        XCTAssertEqual(reopened.items.map(\.name), ["Blatt 03 neu.pdf"])
        XCTAssertFalse(reopened.changed)
    }

    func testEncryptedAndBrokenZipShowClearMessage() async throws {
        // Bit 0 = verschluesselt (wie ZIP mit Passwort aus dem Windows-Explorer)
        var enc = try ZipArchive.pack([.init(path: "geheim.pdf", data: Data("x".utf8))])
        enc[6] |= 1
        let cdSig: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        let cd = try XCTUnwrap(enc.firstRange(of: Data(cdSig)))
        enc[cd.lowerBound + 8] |= 1
        let m = try model(FakeLibrary(zip: enc))
        await m.load()
        guard case .failed(let msg) = m.phase else { return XCTFail("\(m.phase)") }
        XCTAssertTrue(msg.contains("Passwort"), msg)

        let broken = try model(FakeLibrary(zip: Data("kein zip".utf8)))
        await broken.load()
        XCTAssertEqual(broken.phase, .failed(ZipArchive.Failure.notZip.localizedDescription))
    }

    func testRoutingAndNames() {
        XCTAssertTrue(ZipArchive.isZipName("Blatt.ZIP"))
        XCTAssertFalse(ZipArchive.isZipName("Blatt.pdf"))
        XCTAssertEqual(ZipFolderModel.exportName("Blatt 3.zip"), "Blatt 3.zip")
        XCTAssertEqual(ZipFolderModel.exportName("Blatt 3"), "Blatt 3.zip")
        XCTAssertEqual(ZipFolderModel.skippedNotice(unsafe: 2, unreadable: 1), "2 Einträge mit unsicherem Pfad und 1 Eintrag nicht lesbar – nicht entpackt.")
        let root = ZipFolderModel.root(fileID: "../x", namespace: APIClient(base: APIClient.localBase, transport: FakeLibrary(zip: Data())).namespace,
                                       base: URL(fileURLWithPath: "/tmp/c"))
        XCTAssertFalse(root.path.contains(".."), root.path)
        XCTAssertTrue(root.path.hasPrefix("/tmp/c/zip/"))
    }

    // MARK: Ansicht im Simulator

    func testZipViewRendersAndScreenshot() async throws {
        let m = try model(FakeLibrary(zip: try Self.exerciseZip()))
        await m.load()
        m.open(folder: "Blatt 03")
        let pdf = try XCTUnwrap(m.items.first { $0.name == "Aufgabenblatt 03.pdf" })
        _ = await m.editorDocument(for: pdf)
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(NavigationStack { ZipFolderView(model: m) }, api: m.api, size: CGSize(width: 1032, height: 1376))
        env.window.overrideUserInterfaceStyle = .light
        env.pump(1.5)
        let shown = env.labels().joined(separator: "\n")
        for word in ["Aufgabenblatt 03.pdf", "Vorlage", "skizze.png", "Notizen"] {
            XCTAssertTrue(shown.contains(word), "„\(word)“ fehlt:\n\(shown)")
        }
        let image = StoreScreenshotTests.pageImage(env, scale: 2, ink: false)
        let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("zip-ansicht.png")
        try XCTUnwrap(image.pngData()).write(to: out)
        print("ZIP-Ansicht: \(out.path)")
    }
}
