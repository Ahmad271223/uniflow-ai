import Foundation
import UIKit
import UniFlowCore

/// Was geteilt wird.
enum ShareScope: Equatable, Sendable {
    case document
    /// Eine angezeigte Seite (0-basiert, Reihenfolge des Notizmodells).
    case page(Int)
}

/// Geteilter Stand eines Dokuments: PDF mit Notizen (Handschrift als Vektoren) und Angaben dazu.
/// Wird ohne Netzwerk erzeugt; das spaetere Community-Teilen laedt genau diesen Datensatz hoch.
struct SharePayload: Equatable, Sendable {
    let pdf: Data
    let title: String
    /// Datei in der Bibliothek, aus der geteilt wurde.
    let fileID: String
    let moduleID: Int?
    /// Name der Veranstaltung bzw. des Fachs (`LibFile.subject`).
    let module: String?
    /// Angezeigte Seiten, 1-basiert (wie "Seite 3 / 12" in der Dokumentansicht).
    let pageRange: ClosedRange<Int>
    let createdAt: Date

    var pageCount: Int { pageRange.count }

    /// Dateiname fuer das Teilen-Menue: Titel.pdf
    var fileName: String { PDFExporter.safeFileName(title) + ".pdf" }
}

enum ShareExportError: LocalizedError, Equatable {
    case notLoaded
    case pageOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Das Dokument ist noch nicht geladen."
        case .pageOutOfRange(let i): return "Seite \(i + 1) gibt es in diesem Dokument nicht."
        }
    }
}

enum ShareExport {

    /// Angezeigte Seiten (0-basiert) fuer den Umfang.
    static func indices(for scope: ShareScope, pageCount: Int) throws -> [Int] {
        switch scope {
        case .document:
            guard pageCount > 0 else { throw ShareExportError.notLoaded }
            return Array(0..<pageCount)
        case .page(let i):
            guard i >= 0, i < pageCount else { throw ShareExportError.pageOutOfRange(i) }
            return [i]
        }
    }

    /// Datensatz aus Seitenaufbau und Seiten-JSON (nur bereits geladene Bilder, kein Netzwerk).
    static func payload(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage], title: String,
                        fileID: String, moduleID: Int?, module: String?, scope: ShareScope,
                        createdAt: Date = Date()) throws -> SharePayload {
        let idx = try indices(for: scope, pageCount: layout.pdf.pageCount)
        let data = PDFExporter.render(layout: layout, pages: pages, images: images, pageIndices: idx, title: title)
        return SharePayload(pdf: data, title: title, fileID: fileID, moduleID: moduleID, module: module,
                            pageRange: (idx[0] + 1)...(idx[idx.count - 1] + 1), createdAt: createdAt)
    }

    /// Schreibt die PDF als `Titel.pdf` in einen eigenen temporaeren Ordner (fuer das Teilen-Menue).
    /// Vorherige Teilen-Dateien werden dabei entfernt.
    static func writeFile(_ payload: SharePayload) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? fm.removeItem(at: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(payload.fileName)
        try payload.pdf.write(to: url, options: .atomic)
        return url
    }
}

extension DocumentStore {

    /// Datensatz zum Teilen aus dem geoeffneten Dokument. Vorher werden ausstehende Striche verarbeitet, damit der
    /// letzte Strich mit drin ist. Bilder nur, soweit sie schon geladen sind.
    func sharePayload(_ scope: ShareScope) async throws -> SharePayload {
        await flush()
        guard let layout else { throw ShareExportError.notLoaded }
        let idx = try ShareExport.indices(for: scope, pageCount: layout.pdf.pageCount)
        var pages: [String: JSONValue] = [:]
        for i in idx {
            guard let key = layout.key(at: i) else { continue }
            pages[key] = .object(["objects": .array(await objects(forPageKey: key))])
        }
        return try ShareExport.payload(layout: layout, pages: pages, images: images, title: file.displayTitle,
                                       fileID: file.id, moduleID: file.module_id, module: file.subject, scope: scope)
    }
}
