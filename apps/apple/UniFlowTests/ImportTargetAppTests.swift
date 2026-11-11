import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Import-Ziel (Meldung des Inhabers 11.11.2026): beim Import von aussen ("Teilen"/"Öffnen in", Ablegen, "Neu" ->
/// "PDF importieren") waehlt man ein Modul, einen eigenen Ordner (auch Unterordner), "Neuer Ordner …" oder "Ohne Ordner";
/// mehrere Dateien landen am selben Ort. Erfundene Bibliothek und erfundene Dateien, lokales Backend im Temp-Ordner.
@MainActor
final class ImportTargetAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func localAPI() throws -> APIClient {
        let container = try tempDir()
        let host = LocalBackendHost(directory: container.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-11T10:00:00")!,
                                    files: LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow",
                                                      tools: AppDocumentTools()))
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func pdf(_ name: String) throws -> ExternalFileImport.Staged {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { $0.beginPage() }
        let url = try tempDir().appendingPathComponent(name)
        try data.write(to: url)
        return try ExternalFileImport.stage(url, container: nil)
    }

    private func zip(_ name: String) throws -> ExternalFileImport.Staged {
        let url = try tempDir().appendingPathComponent(name)
        try ZipFolderAppTests.exerciseZip().write(to: url)
        return try ExternalFileImport.stage(url, container: nil)
    }

    // MARK: Orte

    /// Auswahl "Wohin?" aus `/api/library`: ohne Ordner, je Modul das Modul und seine Ordner der Tiefe nach, dann die
    /// eigenen Ordner, zuletzt "Neuer Ordner …"; Pfade wie die Bibliothek, Felder fuer das Backend
    func testPlacesFollowTheLibrary() {
        let lib = LibraryViewsFolderAppTests.library
        let options = ImportPlaces.options(lib)
        XCTAssertEqual(options.map(\.value), [.loose, .module(1), .folder(5), .folder(9), .folder(3), .newFolder])
        XCTAssertEqual(options.map(\.label), ["Ohne Ordner (Eigene Dokumente)", "Analysis", "Analysis › Übungen", "Analysis › Übungen › Blatt 1",
                                              "Privat", "Neuer Ordner …"])
        XCTAssertEqual(ImportPlaces.parents(lib).map(\.label), ["Oberste Ebene", "Analysis", "Analysis › Übungen", "Analysis › Übungen › Blatt 1", "Privat"])
        XCTAssertEqual(ImportPlaces.path(.folder(9), in: lib), "m1/f5/f9")
        XCTAssertEqual(ImportPlaces.path(.folder(3), in: lib), "f3")
        XCTAssertEqual(ImportPlaces.path(.module(1), in: lib), "m1")
        XCTAssertNil(ImportPlaces.path(.loose, in: lib))
        XCTAssertEqual(ImportPlaces.path(newFolder: 12, under: .folder(9), in: lib), "m1/f5/f9/f12")
        XCTAssertEqual(ImportPlaces.path(newFolder: 12, under: .loose, in: lib), "f12")
        // Ziel zum offenen Ort der Bibliothek
        XCTAssertEqual(ImportTarget.from(path: "m1/f5/f9"), .folder(9))
        XCTAssertEqual(ImportTarget.from(path: "m1/vorlesung"), .module(1))
        XCTAssertEqual(ImportTarget.from(path: "f3"), .folder(3))
        XCTAssertEqual(ImportTarget.from(path: "c4711"), .loose)
        XCTAssertEqual(ImportTarget.from(path: nil), .loose)
        XCTAssertEqual(ExternalImportInbox.preset(for: .files(path: "m1/f5")), .folder(5))
        XCTAssertEqual(ExternalImportInbox.preset(for: .files(section: "trash")), .loose)
        XCTAssertEqual(ExternalImportInbox.preset(for: .dashboard), .loose)
        XCTAssertEqual(LibraryDropTarget.target(moduleID: 1, folderID: 9), .folder(9))
        XCTAssertEqual(LibraryDropTarget.target(moduleID: 1, folderID: nil), .module(1))
        // Felder: ein Ordner traegt sein Modul selbst
        XCTAssertTrue(ImportTarget.folder(9).fields == (nil, 9))
        XCTAssertTrue(ImportTarget.module(1).fields == (1, nil))
        XCTAssertTrue(ImportTarget.loose.fields == (nil, nil))
        // neuer Ordner: unter einem Ordner eines Moduls mit dem Modul (wie "Neu" -> "Ordner")
        XCTAssertEqual(ImportPlaces.newFolderBody(name: " Klausur ", parent: .folder(9), in: lib), ["name": "Klausur", "parent_id": 9, "module_id": 1])
        XCTAssertEqual(ImportPlaces.newFolderBody(name: "X", parent: .module(1), in: lib), ["name": "X", "parent_id": .null, "module_id": 1])
        XCTAssertEqual(ImportPlaces.newFolderBody(name: "X", parent: .loose, in: lib), ["name": "X", "parent_id": .null, "module_id": .null])
        // verschwundener Ort: Auswahl faellt auf "ohne Ordner" zurueck; Kreise in kaputten Daten enden
        XCTAssertFalse(ImportPlaces.contains(.folder(77), in: lib))
        let loop: JSONValue = ["modules": [], "folders": [["id": 1, "name": "A", "parent_id": 2], ["id": 2, "name": "B", "parent_id": 1]]]
        XCTAssertEqual(ImportPlaces.chain(1, in: loop).count, 2)
        XCTAssertEqual(ImportPlaces.options(.null).map(\.value), [.loose, .newFolder])
    }

    // MARK: Import an jeden Ort

    /// Drei Dateien auf einmal in einen neuen Unterordner eines Modulordners; danach ohne Ordner, ins Modul und in
    /// einen eigenen Ordner
    func testMultipleFilesIntoNewFolderAndEveryOtherPlace() async throws {
        let api = try localAPI()
        let module = try await api.value("/api/modules", method: "POST", body: ["name": "Analysis"])
        let mid = try XCTUnwrap(module.i("id"))
        let topRow = try await api.value("/api/folders", method: "POST", body: ["name": "Übungen", "module_id": .number(Double(mid))])
        let top = try XCTUnwrap(topRow.i("id"))
        let ownRow = try await api.value("/api/folders", method: "POST", body: ["name": "Privat"])
        let own = try XCTUnwrap(ownRow.i("id"))
        var lib = try await api.value("/api/library")

        let files = [try pdf("Blatt 4.pdf"), try pdf("Lösung 4.pdf"), try zip("Abgabe 4.zip")]
        let out = try await ExternalImportDialog.perform(files, api: api, target: .newFolder, title: "egal", newFolder: ("Woche 4", .folder(top)), lib: lib)
        XCTAssertEqual(out.created.count, 3)
        XCTAssertEqual(out.failed, [])
        guard case .folder(let fresh) = out.target else { return XCTFail("\(out.target)") }
        XCTAssertEqual(out.path, "m\(mid)/f\(top)/f\(fresh)")
        lib = try await api.value("/api/library")
        let folder = try XCTUnwrap(lib.list("folders").first { $0.i("id") == fresh })
        XCTAssertEqual(folder.s("name"), "Woche 4")
        XCTAssertEqual(folder.i("parent_id"), top)
        XCTAssertEqual(folder.i("module_id"), mid)
        let inFolder = lib.list("files").filter { $0.i("folder_id") == fresh }
        XCTAssertEqual(Set(inFolder.compactMap { $0.s("title") }), ["Blatt 4", "Lösung 4", "Abgabe 4"], "mehrere Dateien: eigene Titel, nicht der eine Titel")
        for s in files { XCTAssertFalse(FileManager.default.fileExists(atPath: s.url.path), "Kopie weg: \(s.name)") }

        // ohne Ordner: oberste Ebene ("Eigene Dokumente")
        let loose = try await ExternalImportDialog.perform([try pdf("Lose.pdf")], api: api, target: .loose, title: "Lose Seite", lib: lib)
        // ins Modul: Ordner "Eigene Notizen" des Moduls
        let mod = try await ExternalImportDialog.perform([try pdf("Modul.pdf")], api: api, target: .module(mid), lib: lib)
        // eigener Ordner ohne Modul
        let priv = try await ExternalImportDialog.perform([try pdf("Privat.pdf")], api: api, target: .folder(own), lib: lib)
        lib = try await api.value("/api/library")
        func file(_ id: String?) -> JSONValue? { lib.list("files").first { $0.s("id") == id } }
        let l = try XCTUnwrap(file(loose.created.first?.id))
        XCTAssertEqual(l.s("title"), "Lose Seite", "eine Datei: Titel aus dem Dialog")
        XCTAssertTrue(l["folder_id"]?.isNull ?? true)
        let notes = try XCTUnwrap(lib.list("folders").first { $0.s("name") == "Eigene Notizen" && $0.i("module_id") == mid })
        XCTAssertEqual(file(mod.created.first?.id)?.i("folder_id"), notes.i("id"))
        XCTAssertEqual(file(priv.created.first?.id)?.i("folder_id"), own)
        XCTAssertEqual(ImportPlaces.path(.folder(own), in: lib), "f\(own)")
    }

    /// Ordner laesst sich nicht anlegen: nichts wird importiert, die Kopien bleiben fuer einen zweiten Versuch
    func testFailedNewFolderImportsNothing() async throws {
        let t = LibraryViewsFolderAppTests.Transport()                     // kein /api/folders: 404
        let api = APIClient(base: APIClient.localBase, transport: t)
        let s = try pdf("Blatt.pdf")
        do {
            _ = try await ExternalImportDialog.perform([s], api: api, target: .newFolder, newFolder: ("Neu", .loose), lib: .null)
            XCTFail("Fehler erwartet")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.url.path))
        ExternalFileImport.discard(s)
    }

    // MARK: Mehrere geteilte Dateien

    /// "Teilen" mit mehreren Dateien: iOS meldet jede einzeln (`onOpenURL`); sie landen im selben offenen Dialog. Nach
    /// dem Schliessen oeffnet die naechste Datei einen neuen.
    func testSharedFilesCollectInOneDialog() throws {
        let overlay = UFOverlay()
        ExternalImportInbox.open?.finished = true                          // kein offener Dialog aus anderen Tests
        let a = try pdf("A.pdf"), b = try pdf("B.pdf"), c = try zip("C.zip")
        defer { [a, b, c].forEach(ExternalFileImport.discard) }
        ExternalImportInbox.receive([a], overlay: overlay)
        ExternalImportInbox.receive([b], overlay: overlay)
        XCTAssertEqual(overlay.modals.count, 1, "ein Dialog fuer beide")
        let batch = try XCTUnwrap(ExternalImportInbox.open)
        XCTAssertEqual(batch.files.map(\.name), ["A.pdf", "B.pdf"])
        batch.finished = true
        ExternalImportInbox.receive([c], overlay: overlay)
        XCTAssertEqual(overlay.modals.count, 2, "nach dem Schliessen ein neuer Dialog")
        XCTAssertEqual(ExternalImportInbox.open?.files.map(\.name), ["C.zip"])
        ExternalImportInbox.open?.finished = true
        overlay.modals.map(\.id).forEach(overlay.close)
    }

    /// Dialog mit zwei Dateien und vorgewaehltem "Neuer Ordner …": Ueberschrift, Dateien, Ziel, Name und Ort
    func testDialogShowsFilesTargetAndNewFolderFields() throws {
        let t = LibraryViewsFolderAppTests.Transport()
        t.answer("/api/library", LibraryViewsFolderAppTests.library)
        let api = APIClient(base: APIClient.localBase, transport: t)
        let a = try pdf("Skript 1.pdf"), b = try zip("Blatt 1.zip")
        defer { [a, b].forEach(ExternalFileImport.discard) }
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(ExternalImportDialog(batch: ExternalImportBatch([a, b]), preset: .newFolder).padding(),
                                          api: api, size: CGSize(width: 700, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Name des neuen Ordners") }, env.labels().joined(separator: "\n"))
        let shown = env.labels().joined(separator: "\n")
        for word in ["2 Dateien importieren", "Skript 1.pdf", "Blatt 1.zip", "Wohin?", "Neuer Ordner …", "Anlegen in", "Oberste Ebene",
                     "Alle Dateien landen am selben Ort.", "Importieren", "Abbrechen"] {
            XCTAssertTrue(shown.contains(word), "„\(word)“ fehlt:\n\(shown)")
        }
        XCTAssertFalse(shown.contains("Titel"), "mehrere Dateien: kein gemeinsamer Titel")
        env.window.isHidden = true

        // abgelegt im Unterordner: vorgewaehlt mit seinem ganzen Pfad, eine Datei mit Titel
        let one = try hostWithEnvironment(ExternalImportDialog(batch: ExternalImportBatch([a]), preset: .folder(9)).padding(),
                                          api: api, size: CGSize(width: 700, height: 900))
        XCTAssertTrue(one.wait { one.labels().contains("Analysis › Übungen › Blatt 1") }, one.labels().joined(separator: "\n"))
        XCTAssertTrue(one.labels().contains("PDF importieren"))
        XCTAssertTrue(one.labels().contains("Titel"))
    }
}
