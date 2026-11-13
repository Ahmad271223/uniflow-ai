import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import UniFlowCore
@testable import UniFlow

/// ZIP (und PDF) von aussen in StudiNow (Wunsch des Inhabers 07.11.2026, Version 1.0): Dateityp in der Info.plist,
/// Weg einer erfundenen ZIP aus der Inbox bzw. der Dateien-App ueber `ExternalFileImport` ins lokale Backend
/// (`POST /api/notebooks`, kind zip), danach die Ordneransicht; abgelegte Dateien (`LibraryDropTarget`); verstaendliche
/// Meldungen bei keiner ZIP, Passwort, zu gross; Bildschirmfoto der Ordneransicht nach dem Import.
@MainActor
final class ExternalImportAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Lokales Backend mit eigener Datenbank und Dateiablage in einem Temp-Ordner (wie LocalBackendAppTests)
    private func localAPI() throws -> APIClient {
        let container = try tempDir()
        let host = LocalBackendHost(directory: container.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-07T10:00:00")!,
                                    files: LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow",
                                                      tools: AppDocumentTools()))
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    /// Erfundene ZIP wie aus der Dateien-App: Uebungsblatt mit PDF, Vorlage, Bild
    private func zipFile(name: String = "Übungsblatt 03.zip") throws -> URL {
        let url = try tempDir().appendingPathComponent(name)
        try ZipFolderAppTests.exerciseZip().write(to: url)
        return url
    }

    private func file(_ url: URL, _ data: Data) throws -> URL {
        try data.write(to: url)
        return url
    }

    // MARK: Dateityp

    func testInfoPlistRegistersZipAndPDFAfterSolution() throws {
        let docTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        XCTAssertEqual(docTypes.first?["CFBundleTypeName"] as? String, "StudiNow-Lösung", "Loesungspaket bleibt der erste Typ")
        let types = docTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(types.contains("public.zip-archive"), "\(types)")
        XCTAssertTrue(types.contains("com.pkware.zip-archive"), "\(types)")
        XCTAssertTrue(types.contains("com.adobe.pdf"), "\(types)")
        // Dateien werden in die App kopiert (Documents/Inbox), nicht an Ort und Stelle bearbeitet
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, false)
    }

    func testKindFromURL() {
        XCTAssertEqual(ExternalFileImport.kind(of: URL(fileURLWithPath: "/tmp/Blatt.ZIP")), .zip)
        XCTAssertEqual(ExternalFileImport.kind(of: URL(fileURLWithPath: "/tmp/Skript.pdf")), .pdf)
        XCTAssertNil(ExternalFileImport.kind(of: URL(fileURLWithPath: "/tmp/Loesung.uniflowsolution")))
        XCTAssertNil(ExternalFileImport.kind(of: URL(fileURLWithPath: "/tmp/Folien.pptx")))
        XCTAssertNil(ExternalFileImport.kind(of: URL(string: "https://studinow.app/x.zip")!), "nur Dateien, keine Links")
        XCTAssertNil(ExternalFileImport.kind(of: URL(string: "uniflow://#/plan")!))
    }

    // MARK: Import-Pfad mit erfundener ZIP

    func testZipFromOutsideBecomesDocumentAndOpensAsFolder() async throws {
        let api = try localAPI()
        let module = try await api.value("/api/modules", method: "POST", body: ["name": "Algorithmen"])
        let moduleID = try XCTUnwrap(module.i("id"))
        let source = try zipFile()
        let original = try Data(contentsOf: source)

        // 1. pruefen und in den Container kopieren (Sicherheitsfreigabe wie aus der Dateien-App)
        let staged = try ExternalFileImport.stage(source, container: nil)
        XCTAssertEqual(staged.kind, .zip)
        XCTAssertEqual(staged.name, "Übungsblatt 03.zip")
        XCTAssertEqual(staged.title, "Übungsblatt 03")
        XCTAssertEqual(staged.bytes, original.count)
        XCTAssertNotEqual(staged.url, source)
        XCTAssertTrue(staged.url.path.hasPrefix(AppTemp.root.path), "Kopie unter AppTemp: \(staged.url.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "die Quelle bleibt (keine Inbox-Datei)")

        // 2. als Dokument im Modul anlegen
        let id = try await ExternalFileImport.create(staged, api: api, title: "Blatt 3", moduleID: moduleID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path), "Kopie nach dem Anlegen weg")

        // 3. in der Bibliothek wie eine ZIP aus Stud.IP (kind file, Name mit .zip), im Modul (Ordner "Eigene Notizen")
        let lib = try await api.value("/api/library")
        let f = try XCTUnwrap(lib.list("files").first { $0.s("id") == id })
        XCTAssertEqual(f.s("name"), "Blatt 3.zip")
        XCTAssertEqual(f.s("title"), "Blatt 3")
        XCTAssertEqual(f.s("kind"), "file")
        XCTAssertNotNil(f.s("downloaded_at"))
        // eigene Dokumente haengen am Modul ueber den Ordner "Eigene Notizen" (wie Notizbuch und PDF-Import)
        let folder = try XCTUnwrap(lib.list("folders").first { $0.i("id") == f.i("folder_id") })
        XCTAssertEqual(folder.s("name"), "Eigene Notizen")
        XCTAssertEqual(folder.i("module_id"), moduleID)

        // 4. Weiche der Dokumentansicht: nicht Editor, nicht Text, sondern ZIP-Ordner (Views.swift)
        let files = try await api.json("/api/library", as: LibraryResponse.self).files
        let lf = try XCTUnwrap(files.first { $0.id == id })
        XCTAssertFalse(lf.opensInEditor)
        XCTAssertFalse(lf.opensAsText)
        XCTAssertTrue(lf.downloaded_at != nil && ZipArchive.isZipName(lf.name))

        // 5. Inhalt unveraendert, Ordneransicht entpackt ihn
        let (content, http) = try await api.data("/api/files/\(id)/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(content, original)
        let m = ZipFolderModel(file: lf, api: api, root: try tempDir().appendingPathComponent("ws"))
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.items.map(\.name), ["Blatt 03", "Daten.csv", "Hinweise zur Abgabe.txt"])
        XCTAssertEqual(m.totals.files, 6)
    }

    func testPDFFromOutsideOpensInEditor() async throws {
        let api = try localAPI()
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { $0.beginPage() }
        let source = try file(try tempDir().appendingPathComponent("Skript 1.pdf"), pdf)
        let staged = try ExternalFileImport.stage(source, container: nil)
        XCTAssertEqual(staged.kind, .pdf)
        let id = try await ExternalFileImport.create(staged, api: api)
        let files = try await api.json("/api/library", as: LibraryResponse.self).files
        let lf = try XCTUnwrap(files.first { $0.id == id })
        XCTAssertEqual(lf.name, "Skript 1.pdf")
        XCTAssertTrue(lf.opensInEditor)
        XCTAssertEqual(lf.page_count, 1)
    }

    /// Abgelegt aus der Dateien-App: der Anbieter liefert eine kurzlebige Adresse; die Art kommt vom Typ, nicht vom Namen
    func testDroppedFileIsStagedByType() async throws {
        let zip = try XCTUnwrap(NSItemProvider(contentsOf: try zipFile(name: "Abgabe.zip")))
        zip.suggestedName = "Abgabe"                                        // wie die Dateien-App (ohne Endung)
        XCTAssertTrue(zip.hasItemConformingToTypeIdentifier(UTType.zip.identifier))
        XCTAssertEqual(LibraryDropTarget.kind(of: zip)?.0, .zip)
        let staged = try await LibraryDropTarget.stage(zip)
        XCTAssertEqual(staged.kind, .zip)
        XCTAssertEqual(staged.name, "Abgabe.zip")
        ExternalFileImport.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
        // ohne Namen vom Anbieter: der Name der kurzlebigen Adresse (iOS: "Zip-Archiv.zip"), immer mit Endung
        let unnamed = try XCTUnwrap(NSItemProvider(contentsOf: try zipFile(name: "Blatt.zip")))
        let fallback = try await LibraryDropTarget.stage(unnamed)
        XCTAssertTrue(fallback.name.hasSuffix(".zip"), fallback.name)
        ExternalFileImport.discard(fallback)

        let text = try XCTUnwrap(NSItemProvider(contentsOf: try file(try tempDir().appendingPathComponent("Notiz.txt"), Data("x".utf8))))
        XCTAssertNil(LibraryDropTarget.kind(of: text))
        do {
            _ = try await LibraryDropTarget.stage(text)
            XCTFail("Text wird nicht importiert")
        } catch let e as ExternalFileImport.Failure {
            guard case .unsupported = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(LibraryPage.dropModule("m7/f3"), 7)
        XCTAssertEqual(LibraryPage.dropFolder("m7/f3"), 3)
        XCTAssertNil(LibraryPage.dropModule("c123"))
        XCTAssertNil(LibraryPage.dropFolder("m7"))
        XCTAssertNil(LibraryPage.dropModule(nil))
    }

    // MARK: Grenzen und Meldungen

    func testBadFilesGiveClearMessagesAndLeaveNothing() async throws {
        let dir = try tempDir()
        func stage(_ name: String, _ data: Data) -> Result<ExternalFileImport.Staged, Error> {
            Result { try ExternalFileImport.stage(try file(dir.appendingPathComponent(name), data), container: nil) }
        }
        func message(_ r: Result<ExternalFileImport.Staged, Error>) -> String {
            switch r {
            case .success(let s): ExternalFileImport.discard(s); return "OK"
            case .failure(let e): return ExternalFileImport.message(e)
            }
        }
        // keine ZIP (Textdatei mit Endung .zip), keine PDF, fremde Art
        XCTAssertEqual(message(stage("kaputt.zip", Data("kein zip".utf8))), "Die Datei ist keine ZIP-Datei.")
        XCTAssertEqual(message(stage("kaputt.pdf", Data("kein pdf".utf8))), "Die Datei ist keine PDF.")
        XCTAssertTrue(message(stage("Folien.pptx", Data("x".utf8))).contains("Es gehen PDF-, ZIP- und Bilddateien"))
        // verschluesselt (Bit 0 im lokalen Kopf und im Zentralverzeichnis, wie ZIP mit Passwort aus dem Windows-Explorer)
        var enc = try ZipArchive.pack([.init(path: "geheim.pdf", data: Data("x".utf8))])
        enc[6] |= 1
        let cd = try XCTUnwrap(enc.firstRange(of: Data([0x50, 0x4b, 0x01, 0x02])))
        enc[cd.lowerBound + 8] |= 1
        XCTAssertTrue(message(stage("geheim.zip", enc)).contains("Passwort"))
        // zu gross: Groesse zaehlt vor dem Lesen (duenn besetzte Datei ueber der Grenze, ohne 100 MB zu schreiben)
        let big = dir.appendingPathComponent("riesig.zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(ExternalFileImport.maxBytes + 1))
        try h.close()
        let tooBig = Result { try ExternalFileImport.stage(big, container: nil) }
        XCTAssertTrue(message(tooBig).contains("zu groß"), message(tooBig))
        XCTAssertTrue(message(tooBig).contains("100 MB"), message(tooBig))
        // nichts bleibt im Container liegen (nur die Import-Ordner; andere Tests exportieren dort ZIPs)
        let left = FileManager.default.enumerator(at: AppTemp.folder(container: nil), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath && $0.path.contains("/import-") } ?? []
        XCTAssertEqual(left.map(\.lastPathComponent), [], "Reste: \(left)")

        // das Backend prueft dieselben Grenzen noch einmal (ein anderer Weg zu POST /api/notebooks)
        let api = try localAPI()
        for (data, expect) in [(Data("kein zip".utf8), "keine ZIP-Datei"), (enc, "Passwort")] {
            do {
                _ = try await api.form("/api/notebooks", fields: ["kind": "zip", "title": "x"], file: ("upload", "x.zip", "application/zip", data))
                XCTFail("400 erwartet")
            } catch let e as APIError {
                XCTAssertEqual(e.status, 400)
                XCTAssertTrue(e.localizedDescription.contains(expect), e.localizedDescription)
            }
        }
        do {
            _ = try await api.form("/api/notebooks", fields: ["kind": "zip", "title": "x"])
            XCTFail("400 erwartet: ZIP ohne Datei")
        } catch let e as APIError { XCTAssertEqual(e.status, 400) }
        let after = try await api.json("/api/library", as: LibraryResponse.self)
        XCTAssertTrue(after.files.isEmpty, "nichts angelegt")
    }

    /// Eine empfangene Kopie in Documents/Inbox wird entfernt, eine Datei anderswo nie
    func testOnlyInboxCopiesAreDiscarded() throws {
        let inbox = try tempDir().appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let received = try file(inbox.appendingPathComponent("Blatt.zip"), Data("PK".utf8))
        let elsewhere = try file(try tempDir().appendingPathComponent("Blatt.zip"), Data("PK".utf8))
        SolutionSharing.discardReceivedCopy(received, inbox: inbox)
        SolutionSharing.discardReceivedCopy(elsewhere, inbox: inbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    // MARK: Ansicht im Simulator

    func testDialogAndFolderViewAfterImportWithScreenshots() async throws {
        let api = try localAPI()
        _ = try await api.value("/api/modules", method: "POST", body: ["name": "Algorithmen"])
        let staged = try ExternalFileImport.stage(try zipFile(), container: nil)
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 1032, height: 1376)

        // Dialog "Wohin?" wie nach "Teilen" -> StudiNow: Beschriftungen direkt gehostet (der
        // Bedienungshilfen-Baum eines Dialogs ueber der Abdunkelung ist im Test leer), Bild als Dialog ueber der Seite
        let direct = try hostWithEnvironment(ExternalImportDialog(staged: staged), api: api, size: size)
        direct.pump(1.5)
        let shownDialog = direct.labels().joined(separator: "\n")
        for word in ["ZIP importieren", "Übungsblatt 03.zip", "Wohin?", "Importieren", "Abbrechen"] {
            XCTAssertTrue(shownDialog.contains(word), "„\(word)“ fehlt:\n\(shownDialog)")
        }
        direct.window.isHidden = true
        let dialog = try hostWithEnvironment(Color.clear, api: api, size: size)
        dialog.window.overrideUserInterfaceStyle = .light
        dialog.overlay.modal { ExternalImportDialog(staged: staged) }
        dialog.pump(1.5)
        XCTAssertEqual(dialog.overlay.modals.count, 1)
        let dialogShot = dir.appendingPathComponent("zip-import-dialog.png")
        try XCTUnwrap(StoreScreenshotTests.pageImage(dialog, scale: 2, ink: false).pngData()).write(to: dialogShot)
        dialog.window.isHidden = true

        // nach dem Import: Ordneransicht der ZIP
        let id = try await ExternalFileImport.create(staged, api: api)
        let files = try await api.json("/api/library", as: LibraryResponse.self).files
        let lf = try XCTUnwrap(files.first { $0.id == id })
        let m = ZipFolderModel(file: lf, api: api, root: try tempDir().appendingPathComponent("ws"))
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        let env = try hostWithEnvironment(NavigationStack { ZipFolderView(model: m) }, api: api, size: size)
        env.window.overrideUserInterfaceStyle = .light
        env.pump(1.5)
        let shown = env.labels().joined(separator: "\n")
        for word in ["Blatt 03", "Daten.csv", "Hinweise zur Abgabe.txt"] {
            XCTAssertTrue(shown.contains(word), "„\(word)“ fehlt:\n\(shown)")
        }
        let out = dir.appendingPathComponent("zip-import-ordner.png")
        try XCTUnwrap(StoreScreenshotTests.pageImage(env, scale: 2, ink: false).pngData()).write(to: out)
        print("ZIP-Import Dialog: \(dialogShot.path)\nZIP-Import Ordneransicht: \(out.path)")
    }
}
