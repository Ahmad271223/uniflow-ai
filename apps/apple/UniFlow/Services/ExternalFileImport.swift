import Foundation
import ImageIO
import UniformTypeIdentifiers
import UniFlowCore

/// Dateien von aussen in StudiNow (Wunsch des Inhabers 07.11.2026, Version 1.0): PDF und ZIP aus der Dateien-App, aus
/// Safari-Downloads, aus Mail ("Teilen" -> "In StudiNow öffnen" bzw. "Kopieren nach StudiNow") und per Drag & Drop in
/// die Bibliothek. iOS kopiert eine geteilte Datei nach Documents/Inbox (`LSSupportsOpeningDocumentsInPlace` = false,
/// Dateitypen in apps/apple/project.yml) und ruft `onOpenURL` (UniFlowApp.swift); beim Ablegen kommt eine Adresse
/// mit Sicherheitsfreigabe (`LibraryDropTarget`). Beide Wege enden hier:
///
/// 1. `stage`: Groesse pruefen (hoechstens `maxBytes`, wie der PDF-Import), Datei mit Sicherheitsfreigabe in einen
///    eigenen Ordner des Containers kopieren (`AppTemp`, weg spaetestens beim naechsten Start), dann den Inhalt pruefen:
///    PDF am Kopf, ZIP ueber das ganze Verzeichnis mit den Grenzen von `ZipArchive` (keine ZIP, beschaedigt, Passwort,
///    zu viele Eintraege, ZIP-Bombe). Eine empfangene Kopie in der Inbox wird danach immer entfernt (`discardSource`).
/// 2. `create`: als eigenes Dokument im gewaehlten Modul anlegen (`POST /api/notebooks`, kind pdf|zip; das Backend prueft
///    dieselben Grenzen noch einmal). Eine ZIP oeffnet sich danach als Ordner (`ZipFolderView`, Zip-Slip beim Entpacken
///    abgewehrt), eine PDF im Editor mit Stift.
enum ExternalFileImport {
    enum Kind: String, Sendable, CaseIterable {
        /// `image` (12.11.2026): "Bild importieren" (Fotomediathek, Dateien) und abgelegte Bilder gehen durch denselben
        /// Dialog "Wohin?"; das Backend legt das Bild als einseitige PDF an
        case pdf, zip, image

        var label: String {
            switch self {
            case .pdf: return "PDF"
            case .zip: return "ZIP"
            case .image: return "Bild"
            }
        }

        /// Erlaubte Endungen (Bild: wie `LibraryEndpoints.createNotebook`)
        var extensions: [String] {
            switch self {
            case .pdf: return ["pdf"]
            case .zip: return ["zip"]
            case .image: return ["png", "jpg", "jpeg", "gif", "webp", "heic"]
            }
        }
    }

    /// Typ beim Hochladen: PDF, ZIP bzw. der Bildtyp der Endung
    static func mime(_ staged: Staged) -> String {
        switch staged.kind {
        case .pdf: return "application/pdf"
        case .zip: return "application/zip"
        case .image: return UTType(filenameExtension: (staged.name as NSString).pathExtension)?.preferredMIMEType ?? "image/jpeg"
        }
    }

    /// Gepruefte Kopie im Container, bereit zum Anlegen
    struct Staged: Sendable, Equatable {
        let kind: Kind
        /// Dateiname wie von aussen (bereinigt, mit passender Endung)
        let name: String
        /// Kopie in `AppTemp`
        let url: URL
        let bytes: Int

        /// Titel des Dokuments: Name ohne Endung
        var title: String { (name as NSString).deletingPathExtension }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unsupported(String)
        case tooLarge(Int)
        case notPDF
        case notImage
        case zip(ZipArchive.Failure)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "„\(name)“ kann StudiNow nicht importieren. Es gehen PDF-, ZIP- und Bilddateien."
            case .tooLarge(let bytes):
                return "Die Datei ist zu groß (\(ExternalFileImport.megabytes(bytes)) MB). StudiNow importiert höchstens \(ExternalFileImport.megabytes(ExternalFileImport.maxBytes)) MB."
            case .notPDF: return "Die Datei ist keine PDF."
            case .notImage: return "Die Datei ist kein lesbares Bild."
            case .zip(let f): return f.errorDescription
            case .unreadable: return "Die Datei lässt sich nicht lesen."
            }
        }
    }

    /// Groesste Datei wie beim PDF-Import des Backends (100 MB)
    static let maxBytes = LibraryEndpoints.maxImportBytes

    static func megabytes(_ bytes: Int) -> Int { max(1, Int((Double(bytes) / 1_048_576).rounded())) }

    /// Art nach der Endung; nil fuer alles andere (auch fuer uniflow:// und https-Links). Nur PDF und ZIP: Bilder
    /// meldet iOS StudiNow nicht ("Öffnen in" ist fuer PDF und ZIP registriert), sie kommen mit vorgegebener Art
    static func kind(of url: URL) -> Kind? {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "zip": return .zip
        default: return nil
        }
    }

    // MARK: Kopieren und pruefen

    /// Datei in den Container kopieren und pruefen. `kind` und `name` vorgeben, wenn der Anbieter sie kennt (Ablegen:
    /// die kurzlebige Adresse heisst dort nur "Zip-Archiv.zip"); sonst entscheidet die Adresse. Bei einem Fehler bleibt
    /// nichts liegen.
    static func stage(_ url: URL, kind given: Kind? = nil, name givenName: String? = nil,
                      container: UUID? = ActiveContainer.current?.layout.identifier) throws -> Staged {
        guard let kind = given ?? kind(of: url) else { throw Failure.unsupported(givenName ?? url.lastPathComponent) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Groesse vor dem Lesen; laesst sie sich nicht bestimmen, wird nicht gelesen (wie SolutionSharing.importFile)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { throw Failure.unreadable }
        guard size <= maxBytes else { throw Failure.tooLarge(size) }
        var name = givenName.flatMap { $0.isEmpty ? nil : $0 } ?? (url.lastPathComponent.isEmpty ? "Dokument" : url.lastPathComponent)
        name = fixedName(name, kind: kind, type: kind == .image ? imageType(at: url) : nil)
        let dest = try AppTemp.file("import-" + UUID().uuidString, name: name, container: container)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            try check(kind, at: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
            throw error
        }
        return Staged(kind: kind, name: dest.lastPathComponent, url: dest, bytes: size)
    }

    /// Name mit passender Endung: PDF und ZIP mit ihrer, ein Bild mit der seines Formats (Fotomediathek und Ablegen
    /// liefern Namen ohne Endung, z. B. "IMG_0042")
    static func fixedName(_ name: String, kind: Kind, type: UTType?) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !kind.extensions.contains(ext) else { return name }
        let wanted = kind == .image ? (type?.preferredFilenameExtension.map { $0 == "jpeg" ? "jpg" : $0 } ?? "jpg") : kind.rawValue
        return name + "." + wanted
    }

    /// Bildformat einer Datei (HEIC, PNG, JPEG …); nil, wenn es kein Bild ist
    static func imageType(at url: URL) -> UTType? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let id = CGImageSourceGetType(src) else { return nil }
        return UTType(id as String)
    }

    /// Bild aus der Fotomediathek (nur Daten, keine Datei) wie `stage` in den Container legen und pruefen
    static func stage(image data: Data, name: String, container: UUID? = ActiveContainer.current?.layout.identifier) throws -> Staged {
        guard data.count <= maxBytes else { throw Failure.tooLarge(data.count) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let id = CGImageSourceGetType(src) else { throw Failure.notImage }
        let dest = try AppTemp.file("import-" + UUID().uuidString, name: fixedName(name, kind: .image, type: UTType(id as String)), container: container)
        do { try data.write(to: dest, options: .atomic) } catch {
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
            throw Failure.unreadable
        }
        return Staged(kind: .image, name: dest.lastPathComponent, url: dest, bytes: data.count)
    }

    /// Wie `stage`, aber Kopieren und Pruefen abseits des Hauptthreads (Dateien bis 100 MB)
    static func stageDetached(_ url: URL, kind: Kind? = nil) async throws -> Staged {
        let container = ActiveContainer.current?.layout.identifier
        return try await Task.detached(priority: .userInitiated) { try stage(url, kind: kind, container: container) }.value
    }

    /// Inhalt pruefen: PDF am Kopf; ZIP ueber das ganze Verzeichnis (`ZipArchive.entries`: keine ZIP, beschaedigt,
    /// Passwort, zu viele Eintraege, entpackt zu gross)
    static func check(_ kind: Kind, at url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw Failure.unreadable }
        switch kind {
        case .pdf:
            guard data.starts(with: Array("%PDF".utf8)) else { throw Failure.notPDF }
        case .zip:
            do { _ = try ZipArchive.entries(data) } catch let f as ZipArchive.Failure { throw Failure.zip(f) }
        case .image:
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(src) != nil,
                  CGImageSourceGetCount(src) > 0 else { throw Failure.notImage }
        }
    }

    /// Kopie entfernen (abgebrochen oder angelegt)
    static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent())
    }

    /// Empfangene Kopie in Documents/Inbox entfernen; eine Datei aus "Dateien" bleibt, wo sie ist
    static func discardSource(_ url: URL) { SolutionSharing.discardReceivedCopy(url) }

    // MARK: Anlegen

    /// Als eigenes Dokument anlegen (`POST /api/notebooks`); liefert die ID. Die Kopie ist danach weg.
    static func create(_ staged: Staged, api: APIClient, title: String? = nil, moduleID: Int? = nil, folderID: Int? = nil) async throws -> String {
        var fields = ["kind": staged.kind.rawValue, "title": (title ?? "").isEmpty ? staged.title : title!]
        if let moduleID, moduleID != 0 { fields["module_id"] = "\(moduleID)" }
        if let folderID { fields["folder_id"] = "\(folderID)" }
        let data: Data
        do { data = try Data(contentsOf: staged.url, options: .mappedIfSafe) } catch { throw Failure.unreadable }
        let r = try await api.form("/api/notebooks", fields: fields, file: ("upload", staged.name, mime(staged), data))
        guard let id = r.s("id") else { throw APIError(status: 502, message: "keine ID", text: "Ungültige Antwort beim Anlegen des Dokuments.") }
        discard(staged)
        return id
    }

    /// Meldung fuer den Nutzer (eigene Fehler, Backend-Fehler, Systemfehler)
    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Hinweis ohne Container: die Datei wird nicht angelegt
    static let needsAccountText = "Melde dich zuerst an und wähle deine Hochschule. Öffne die Datei danach erneut."
}
