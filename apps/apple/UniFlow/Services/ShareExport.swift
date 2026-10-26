import Foundation
import UIKit
import UniFlowCore

/// Was geteilt wird.
enum ShareScope: Equatable, Sendable {
    case document
    /// Eine angezeigte Seite (0-basiert, Reihenfolge des Notizmodells).
    case page(Int)
}

/// Privater Export eines Dokuments: Original-PDF mit Notizen (Handschrift als Vektoren) und Angaben dazu.
/// Wird ohne Netzwerk erzeugt und nur ueber das Teilen-Menue des Systems weitergegeben (z. B. Dateien-App). Die PDF
/// enthaelt das Originalmaterial der Hochschule und ist NICHT fuer die Community bestimmt: geteilt werden dort nur
/// eigene Notizen ohne Original, als Loesungspaket (`SolutionPackage`, docs/LOESUNGEN-TEILEN.md).
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
    /// Bildobjekte der geteilten Seiten, deren Bild nicht geladen werden konnte (fehlen in der PDF).
    var missingImages = 0

    var pageCount: Int { pageRange.count }

    /// Hinweis fuer die Oberflaeche, wenn Bilder fehlen; `nil` = vollstaendig.
    var missingImagesNotice: String? {
        switch missingImages {
        case 0: return nil
        case 1: return "1 Bild nicht enthalten"
        default: return "\(missingImages) Bilder nicht enthalten"
        }
    }

    /// Dateiname fuer das Teilen-Menue: Titel.pdf (lange Titel gekuerzt, siehe `PDFExporter.fileName`)
    var fileName: String { PDFExporter.fileName(title, suffix: ".pdf") }
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

    /// Titel fuer Datensatz, PDF-Metadaten und Dateiname: ohne Endung ".pdf" (wie der Web-Export,
    /// `name.replace(/\.pdf$/i, "")`), sonst wuerde aus "Vorlesung_03.pdf" die Datei "Vorlesung_03.pdf.pdf".
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t.isEmpty ? "Dokument" : t
    }

    /// Datensatz aus Seitenaufbau und Seiten-JSON (nur die uebergebenen Bilder, kein Netzwerk).
    static func payload(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage], title: String,
                        fileID: String, moduleID: Int?, module: String?, scope: ShareScope,
                        missingImages: Int = 0, createdAt: Date = Date()) throws -> SharePayload {
        let idx = try indices(for: scope, pageCount: layout.pdf.pageCount)
        let title = cleanTitle(title)
        let data = PDFExporter.render(layout: layout, pages: pages, images: images, pageIndices: idx, title: title)
        return SharePayload(pdf: data, title: title, fileID: fileID, moduleID: moduleID, module: module,
                            pageRange: (idx[0] + 1)...(idx[idx.count - 1] + 1), createdAt: createdAt,
                            missingImages: missingImages)
    }

    // MARK: Bilder

    /// Laedt ein Bild eines Bildobjekts (`src`); `nil` = nicht verfuegbar. Muss Abbruch beachten (Zeitlimit).
    typealias ImageLoader = @Sendable (String) async -> UIImage?

    /// Zeitlimit fuer das Nachladen der Bilder vor dem Teilen.
    static let imageTimeout: TimeInterval = 10

    /// Quellen aller Bildobjekte der Seiten (sortiert, ohne Doppelte).
    static func imageSources(in pages: [String: JSONValue]) -> [String] {
        var srcs = Set<String>()
        for p in pages.values {
            for o in p["objects"]?.array ?? [] where o["type"]?.string == "image" {
                if let s = o["src"]?.string, !s.isEmpty { srcs.insert(s) }
            }
        }
        return srcs.sorted()
    }

    /// Fehlende Bilder parallel nachladen, hoechstens bis zum Zeitlimit. Gibt alle Bilder und die Quellen zurueck,
    /// die danach noch fehlen (Fehler oder Zeitlimit). Ohne Lader bleiben fehlende Bilder fehlend.
    static func completeImages(_ have: [String: UIImage], sources: [String], timeout: TimeInterval = imageTimeout,
                               load: ImageLoader?) async -> (images: [String: UIImage], missing: [String]) {
        var out = have
        let wanted = sources.filter { out[$0] == nil }
        guard let load, !wanted.isEmpty else { return (out, wanted) }
        await withTaskGroup(of: (String, UIImage?)?.self) { group in
            for src in wanted { group.addTask { (src, await load(src)) } }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil                                                      // Zeitlimit erreicht
            }
            var open = wanted.count
            while open > 0, let next = await group.next() {
                guard let result = next else { break }
                open -= 1
                if let img = result.1 { out[result.0] = img }
            }
            group.cancelAll()                                                   // Zeitlimit bzw. restliche Ladevorgaenge
        }
        return (out, wanted.filter { out[$0] == nil })
    }

    /// Bilder ueber den Server laden (gleicher Weg wie `DocumentStore.loadImage`).
    static func serverImageLoader(_ api: APIClient) -> ImageLoader {
        { src in
            guard src.hasPrefix("/"), let (data, http) = try? await api.data(src), http.statusCode == 200 else { return nil }
            return UIImage(data: data)
        }
    }

    /// Datensatz fuer einen Umfang: Objekte nur der gewaehlten Seiten lesen, deren fehlende Bilder nachladen
    /// (Zeitlimit), dann ohne Netzwerk rendern. Laeuft auf dem Hauptthread wie Editor und PDFKit-Dokument.
    @MainActor
    static func make(layout: DisplayLayout, scope: ShareScope, objects: (String) async -> [JSONValue],
                     images: [String: UIImage], title: String, fileID: String, moduleID: Int?, module: String?,
                     timeout: TimeInterval = imageTimeout, loadImage: ImageLoader?) async throws -> SharePayload {
        let idx = try indices(for: scope, pageCount: layout.pdf.pageCount)
        var pages: [String: JSONValue] = [:]
        for i in idx {
            guard let key = layout.key(at: i) else { continue }
            pages[key] = .object(["objects": .array(await objects(key))])
        }
        let loaded = await completeImages(images, sources: imageSources(in: pages), timeout: timeout, load: loadImage)
        return try payload(layout: layout, pages: pages, images: loaded.images, title: title, fileID: fileID,
                           moduleID: moduleID, module: module, scope: scope, missingImages: loaded.missing.count)
    }

    /// Schreibt die PDF als `Titel.pdf` in einen eigenen temporaeren Ordner des Containers (fuer das Teilen-Menue,
    /// `AppTemp`). Vorherige Teilen-Dateien werden dabei entfernt.
    static func writeFile(_ payload: SharePayload) throws -> URL {
        let url = try AppTemp.fresh("teilen").appendingPathComponent(payload.fileName)
        try payload.pdf.write(to: url, options: .atomic)
        return url
    }
}

extension DocumentStore {

    /// Datensatz zum Teilen aus dem geoeffneten Dokument. Vorher werden ausstehende Striche verarbeitet, damit der
    /// letzte Strich mit drin ist. Bilder der gewaehlten Seiten, die in dieser Sitzung noch nicht angezeigt wurden,
    /// werden mit `loadImage` nachgeladen; was dann noch fehlt, steht in `missingImages`.
    func sharePayload(_ scope: ShareScope, loadImage: ShareExport.ImageLoader?) async throws -> SharePayload {
        await flush()
        guard let layout else { throw ShareExportError.notLoaded }
        return try await ShareExport.make(layout: layout, scope: scope, objects: { await self.objects(forPageKey: $0) },
                                          images: images, title: file.displayTitle, fileID: file.id,
                                          moduleID: file.module_id, module: file.subject, loadImage: loadImage)
    }
}
