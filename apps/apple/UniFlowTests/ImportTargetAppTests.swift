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

    // MARK: Jeder Weg (Meldung des Inhabers 12.11.2026)

    private func localHost() throws -> (LocalBackendHost, APIClient) {
        let container = try tempDir()
        let host = LocalBackendHost(directory: container.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-12T10:00:00")!,
                                    files: LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow",
                                                      tools: AppDocumentTools()))
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    private func png(_ size: CGFloat = 24) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).pngData { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// Punkt 2 der Meldung: frisch angelegter eigener Ordner auf der obersten Ebene (kein Modul, wie "Neu" -> "Ordner"
    /// dort) -> hineingehen (`#/files?path=f<id>`) -> importieren. Jeder Weg waehlt genau diesen Ordner vor, die Datei
    /// landet dort (kein "Eigene Notizen" eines Moduls); "Neuer Ordner …" legt den Ordner im offenen Ordner bzw. auf
    /// der obersten Ebene an und die Dateien hinein
    func testFreshOwnFolderWithoutModuleIsTargetOfEveryWay() async throws {
        let (_, api) = try localHost()
        _ = try await api.value("/api/modules", method: "POST", body: ["name": "Analysis"])          // ein Modul daneben
        let row = try await api.value("/api/folders", method: "POST", body: ["name": "Klausurvorbereitung", "parent_id": .null, "module_id": .null])
        let own = try XCTUnwrap(row.i("id"))
        var lib = try await api.value("/api/library")
        let path = "f\(own)"
        // vorgewaehlt: "Neu" -> "PDF/Bild importieren" (Pfad des Dialogs "Neu"), Ablegen, Teilen und Ablage -> "Importieren …"
        XCTAssertEqual(ImportTarget.from(path: path), .folder(own))
        XCTAssertEqual(LibraryDropTarget.target(moduleID: LibraryPage.dropModule(path), folderID: LibraryPage.dropFolder(path)), .folder(own))
        XCTAssertEqual(ExternalImportInbox.preset(for: .files(path: path)), .folder(own))
        // ein Ordner ohne Modul ist ein erlaubtes Ziel (Auswahl, "Anlegen in", Pfad)
        XCTAssertTrue(ImportPlaces.contains(.folder(own), in: lib))
        XCTAssertTrue(ImportPlaces.options(lib).contains { $0.value == .folder(own) && $0.label == "Klausurvorbereitung" }, "\(ImportPlaces.options(lib).map(\.label))")
        XCTAssertTrue(ImportPlaces.parents(lib).contains { $0.value == .folder(own) })
        XCTAssertEqual(ImportPlaces.path(.folder(own), in: lib), path)

        let into = try await ExternalImportDialog.perform([try pdf("Altklausur.pdf")], api: api, target: .folder(own), lib: lib)
        XCTAssertEqual(into.path, path)
        let sub = try await ExternalImportDialog.perform([try pdf("Lösung.pdf"), try pdf("Blatt.pdf")], api: api, target: .newFolder,
                                                          newFolder: ("2025", .folder(own)), lib: lib)
        let top = try await ExternalImportDialog.perform([try pdf("Neu.pdf")], api: api, target: .newFolder, newFolder: ("Sommer", .loose), lib: lib)
        lib = try await api.value("/api/library")
        func folderOf(_ id: String?) -> Int? { lib.list("files").first { $0.s("id") == id }?.i("folder_id") }
        XCTAssertEqual(folderOf(into.created.first?.id), own, "im frisch angelegten Ordner")
        guard case .folder(let subID) = sub.target, case .folder(let topID) = top.target else { return XCTFail("\(sub.target) \(top.target)") }
        let subRow = try XCTUnwrap(lib.list("folders").first { $0.i("id") == subID })
        XCTAssertEqual(subRow.s("name"), "2025")
        XCTAssertEqual(subRow.i("parent_id"), own)
        XCTAssertTrue(subRow["module_id"]?.isNull ?? true, "Unterordner eines Ordners ohne Modul bleibt ohne Modul")
        XCTAssertEqual(sub.path, "f\(own)/f\(subID)")
        XCTAssertEqual(sub.created.map { folderOf($0.id) }, [subID, subID], "beide Dateien im neuen Ordner")
        let topRow = try XCTUnwrap(lib.list("folders").first { $0.i("id") == topID })
        XCTAssertTrue(topRow["parent_id"]?.isNull ?? true)
        XCTAssertTrue(topRow["module_id"]?.isNull ?? true)
        XCTAssertEqual(top.path, "f\(topID)")
        XCTAssertEqual(folderOf(top.created.first?.id), topID)
        XCTAssertFalse(lib.list("folders").contains { $0.s("name") == "Eigene Notizen" }, "nichts in einen Modulordner gelegt")
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    /// Dialog im frisch angelegten eigenen Ordner (lokales Backend): "Wohin?" zeigt genau diesen Ordner vorgewaehlt
    func testDialogInFreshOwnFolderPresetsIt() throws {
        let (_, api) = try localHost()
        let own = try awaiting { try await api.value("/api/folders", method: "POST", body: ["name": "Klausurvorbereitung"]).i("id") }
        let id = try XCTUnwrap(own)
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let s = try pdf("Skript.pdf")
        defer { ExternalFileImport.discard(s) }
        let env = try hostWithEnvironment(ExternalImportDialog(batch: ExternalImportBatch([s]), preset: ImportTarget.from(path: "f\(id)")).padding(),
                                          api: api, size: CGSize(width: 700, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Klausurvorbereitung") }, env.labels().joined(separator: "\n"))
        XCTAssertFalse(env.labels().contains("Ohne Ordner (Eigene Dokumente)"), "nicht auf „ohne Ordner“ zurueckgefallen")
        env.window.isHidden = true
        // importiert (wie "Importieren" im Dialog): die Bibliothek zeigt das Dokument in genau diesem Ordner
        let out = try awaiting {
            try await ExternalImportDialog.perform([s], api: api, target: .folder(id), title: "Altklausur 2025",
                                                   lib: try await api.value("/api/library"))
        }
        XCTAssertEqual(out.path, "f\(id)")
        let page = try hostWithEnvironment(LibraryPage(section: nil, path: out.path, q: nil), api: api, size: CGSize(width: 1180, height: 1000))
        XCTAssertTrue(page.wait { page.labels().contains { $0.contains("Altklausur 2025") } }, page.labels().joined(separator: "\n"))
        XCTAssertTrue(page.labels().contains("Klausurvorbereitung"), "Brotkrume des Ordners")
    }

    /// Vorgewaehlter Ort je Stelle der Bibliothek ("Neu" im offenen Ort, Ablegen, Teilen): oberste Ebene, Modul,
    /// eigener Ordner, Unterordner eines eigenen Ordners, Modulordner, Unterordner eines Modulordners, Art-Ordner
    /// ("Vorlesung") eines Moduls, Kursordner
    func testPresetForEveryPlaceOfTheLibrary() {
        let cases: [(String?, ImportTarget)] = [(nil, .loose), ("", .loose), ("m1", .module(1)), ("f3", .folder(3)), ("f3/f7", .folder(7)),
                                                ("m1/f5", .folder(5)), ("m1/f5/f9", .folder(9)), ("m1/vorlesung", .module(1)), ("c4711", .loose)]
        for (path, want) in cases {
            XCTAssertEqual(ImportTarget.from(path: path), want, "Neu/Importieren in \(path ?? "nil")")
            XCTAssertEqual(LibraryDropTarget.target(moduleID: LibraryPage.dropModule(path), folderID: LibraryPage.dropFolder(path)), want,
                           "Ablegen in \(path ?? "nil")")
            XCTAssertEqual(ExternalImportInbox.preset(for: .files(path: path)), want, "Teilen in \(path ?? "nil")")
        }
        // Unterordner eines eigenen Ordners: Auswahl mit ganzem Pfad, neuer Ordner darunter ohne Modul
        var lib = LibraryViewsFolderAppTests.library
        if case .object(var o) = lib, case .array(var folders)? = o["folders"] {
            folders.append(["id": 7, "name": "Sommer", "parent_id": 3, "module_id": .null, "color": .null])
            o["folders"] = .array(folders)
            lib = .object(o)
        }
        XCTAssertEqual(ImportPlaces.label(.folder(7), in: lib), "Privat › Sommer")
        XCTAssertEqual(ImportPlaces.path(.folder(7), in: lib), "f3/f7")
        XCTAssertEqual(ImportPlaces.newFolderBody(name: "Juli", parent: .folder(7), in: lib), ["name": "Juli", "parent_id": 7, "module_id": .null])
        XCTAssertEqual(ImportPlaces.path(newFolder: 20, under: .folder(7), in: lib), "f3/f7/f20")
    }

    /// "Neu" -> "Bild importieren" (Fotomediathek und Dateien) und abgelegte Bilder: vorher ohne Frage in den offenen
    /// Ort, ohne "Neuer Ordner …"; jetzt dieselbe Kopie wie PDF/ZIP und derselbe Dialog
    func testImagesGoThroughWohinIntoNewFolder() async throws {
        let (_, api) = try localHost()
        let row = try await api.value("/api/folders", method: "POST", body: ["name": "Fotos Tafel"])
        let own = try XCTUnwrap(row.i("id"))
        let lib = try await api.value("/api/library")
        // Fotomediathek: nur Daten, Endung aus dem Format
        let photo = try ExternalFileImport.stage(image: png(), name: "Bild 1", container: nil)
        XCTAssertEqual(photo.kind, .image)
        XCTAssertEqual(photo.name, "Bild 1.png")
        XCTAssertEqual(ExternalFileImport.mime(photo), "image/png")
        // Dateien: Bild mit Endung
        let file = try tempDir().appendingPathComponent("Tafel.jpg")
        try XCTUnwrap(UIImage(data: png())?.jpegData(compressionQuality: 0.8)).write(to: file)
        let picked = try await ExternalFileImport.stageDetached(file, kind: .image)
        XCTAssertEqual(picked.name, "Tafel.jpg")
        XCTAssertEqual(ExternalFileImport.mime(picked), "image/jpeg")
        // kein Bild: klare Meldung
        XCTAssertThrowsError(try ExternalFileImport.stage(image: Data("kein Bild".utf8), name: "x", container: nil)) { e in
            XCTAssertEqual(ExternalFileImport.message(e), "Die Datei ist kein lesbares Bild.")
        }
        let fake = try tempDir().appendingPathComponent("falsch.png")
        try Data("kein Bild".utf8).write(to: fake)
        XCTAssertThrowsError(try ExternalFileImport.stage(fake, kind: .image, container: nil))

        let out = try await ExternalImportDialog.perform([photo, picked], api: api, target: .newFolder, newFolder: ("Woche 2", .folder(own)), lib: lib)
        XCTAssertEqual(out.failed, [])
        XCTAssertEqual(out.created.count, 2)
        guard case .folder(let fresh) = out.target else { return XCTFail("\(out.target)") }
        XCTAssertEqual(out.path, "f\(own)/f\(fresh)")
        let after = try await api.value("/api/library")
        let docs = after.list("files").filter { $0.i("folder_id") == fresh }
        XCTAssertEqual(Set(docs.compactMap { $0.s("title") }), ["Bild 1", "Tafel"])
        XCTAssertTrue(docs.allSatisfy { $0.s("kind") == "image" }, "\(docs)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.url.path), "Kopie weg")
    }

    /// Bilder aus Fotos bzw. Dateien in die Bibliothek ziehen: der Anbieter meldet ein Bild, der Name bekommt die
    /// Endung des Formats (Fotos liefert "IMG_0042" ohne Endung)
    func testDroppedImageIsStaged() async throws {
        XCTAssertTrue(LibraryDropTarget.types.contains(.image))
        let url = try tempDir().appendingPathComponent("Foto.png")
        try png().write(to: url)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
        provider.suggestedName = "IMG_0042"
        XCTAssertEqual(LibraryDropTarget.kind(of: provider)?.0, .image)
        let staged = try await LibraryDropTarget.stage(provider)
        XCTAssertEqual(staged.kind, .image)
        XCTAssertEqual(staged.name, "IMG_0042.png")
        ExternalFileImport.discard(staged)
        // eine PDF bleibt eine PDF (kein Bild)
        let pdfURL = try tempDir().appendingPathComponent("Skript.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { $0.beginPage() }.write(to: pdfURL)
        XCTAssertEqual(LibraryDropTarget.kind(of: try XCTUnwrap(NSItemProvider(contentsOf: pdfURL)))?.0, .pdf)
    }

    /// "PDF importieren" in der Dokumentleiste (Dokument offen): vorgewaehlt ist der Ordner des offenen Dokuments,
    /// sonst das Modul (vorher immer "ohne Ordner")
    func testDocumentBarPresetsPlaceOfOpenDocument() throws {
        func file(_ json: String) throws -> LibFile { try JSONDecoder().decode(LibFile.self, from: Data(json.utf8)) }
        let inOwn = try file(#"{"id":"u1","name":"A","folder_id":3}"#)
        let studip = try file(#"{"id":"s1","name":"VL01.pdf","module_id":1}"#)
        let loose = try file(#"{"id":"u2","name":"B"}"#)
        XCTAssertEqual(inOwn.folder_id, 3)
        XCTAssertEqual(LibraryView.importPreset(open: inOwn, module: "all"), .folder(3))
        XCTAssertEqual(LibraryView.importPreset(open: studip, module: "all"), .module(1))
        XCTAssertEqual(LibraryView.importPreset(open: loose, module: "m4"), .module(4))
        XCTAssertEqual(LibraryView.importPreset(open: loose, module: "all"), .loose)
        XCTAssertEqual(LibraryView.importPreset(open: nil, module: nil), .loose)
    }

    /// Ablage -> "Importieren …" (Mac, iPad mit Tastatur): PDF, ZIP und Bilder, danach "Wohin?" mit dem offenen Ort
    func testFileMenuImportAcceptsPDFZipAndImages() {
        XCTAssertEqual(Set(LibraryImportHost.types), [.pdf, .zip, .image])
        XCTAssertEqual(LibraryImportHost.kind(of: URL(fileURLWithPath: "/tmp/Skript.PDF")), .pdf)
        XCTAssertEqual(LibraryImportHost.kind(of: URL(fileURLWithPath: "/tmp/Abgabe.zip")), .zip)
        XCTAssertEqual(LibraryImportHost.kind(of: URL(fileURLWithPath: "/tmp/Tafel.HEIC")), .image)
        XCTAssertEqual(LibraryImportHost.kind(of: URL(fileURLWithPath: "/tmp/Tafel.jpeg")), .image)
        XCTAssertNil(LibraryImportHost.kind(of: URL(fileURLWithPath: "/tmp/Folien.pptx")))
        // "Öffnen in"/Teilen bleibt bei PDF und ZIP (nur die sind fuer StudiNow registriert)
        XCTAssertNil(ExternalFileImport.kind(of: URL(fileURLWithPath: "/tmp/Tafel.jpg")))
        XCTAssertEqual(ExternalImportInbox.preset(for: .files(path: "f3/f7")), .folder(7))
    }

    /// "In Ordner verschieben" (auch Stud.IP-Dateien in eigene Ordner): alle Ordner mit Pfad, jetziger Ordner
    /// vorgewaehlt, "Neuer Ordner …" legt an und das Dokument hinein (vorher nur Namen ohne Pfad, kein neuer Ordner)
    func testMoveStudIPFileIntoOwnAndNewFolder() async throws {
        let (host, api) = try localHost()
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES ('k-ana','Analysis I','WiSe 2026/27','Analysis I','vorlesung','2026-10-01T08:00:00')")
            try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES ('s-vl1','k-ana','VL01.pdf','Vorlesung',5,'neu','pdf')")
        }
        let row = try await api.value("/api/folders", method: "POST", body: ["name": "Klausur"])
        let own = try XCTUnwrap(row.i("id"))
        var lib = try await api.value("/api/library")
        XCTAssertNotNil(lib.list("files").first { $0.s("id") == "s-vl1" }, "Stud.IP-Datei in der Bibliothek")
        XCTAssertEqual(LibraryMoveDialog.current("s-vl1", in: lib), .loose)
        let options = LibraryMoveDialog.options(lib)
        XCTAssertEqual(options.first?.label, LibraryMoveDialog.looseLabel)
        XCTAssertEqual(options.last?.value, .newFolder)
        XCTAssertTrue(options.contains { $0.value == .folder(own) && $0.label == "Klausur" })
        XCTAssertFalse(options.contains { if case .module = $0.value { return true } else { return false } }, "Verschieben geht in Ordner, nicht in Module")

        let moved = try await LibraryMoveDialog.perform(id: "s-vl1", api: api, target: .folder(own), lib: lib)
        XCTAssertEqual(moved, own)
        lib = try await api.value("/api/library")
        XCTAssertEqual(LibraryMoveDialog.current("s-vl1", in: lib), .folder(own), "jetziger Ordner vorgewaehlt")
        let fresh = try await LibraryMoveDialog.perform(id: "s-vl1", api: api, target: .newFolder, newFolder: ("Altklausuren", .folder(own)), lib: lib)
        lib = try await api.value("/api/library")
        let f = try XCTUnwrap(fresh)
        XCTAssertEqual(lib.list("folders").first { $0.i("id") == f }?.i("parent_id"), own)
        XCTAssertEqual(lib.list("files").first { $0.s("id") == "s-vl1" }?.i("folder_id"), f)
        XCTAssertEqual(ImportPlaces.label(.folder(f), in: lib), "Klausur › Altklausuren")
        _ = try await LibraryMoveDialog.perform(id: "s-vl1", api: api, target: .loose, lib: lib)
        lib = try await api.value("/api/library")
        XCTAssertTrue(lib.list("files").first { $0.s("id") == "s-vl1" }?["folder_id"]?.isNull ?? false)
    }

    /// Dialog "Verschieben nach": jetziger Ordner mit ganzem Pfad vorgewaehlt
    func testMoveDialogShowsCurrentFolderWithPath() throws {
        let api = APIClient(base: APIClient.localBase, transport: LibraryViewsFolderAppTests.Transport())
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(LibraryMoveDialog(id: "u2", lib: LibraryViewsFolderAppTests.library).padding(),
                                          api: api, size: CGSize(width: 700, height: 600))
        XCTAssertTrue(env.wait { env.labels().contains("Analysis › Übungen › Blatt 1") }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Verschieben"))
    }
}
