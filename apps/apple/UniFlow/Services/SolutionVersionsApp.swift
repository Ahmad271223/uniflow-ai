import Foundation
import PDFKit
import UIKit
import UniFlowCore

// Loesungen fuer alle Fassungen einer PDF (Freigabe des Inhabers 23.11.2026; Regeln im Kern: `SolutionVersions`,
// `CommunityKeys.familyKey`; docs/LOESUNGEN-TEILEN.md, Nachtrag 23.11.2026 "Fassungen").
//
// - Datei-Familie einer Datei aus dem Abgleich: `CommunityCourses.family` (Kurs-ID und Datei-ID bleiben auf dem Geraet).
// - Seitenkennzeichen einer PDF: `SolutionPDFFacts` aus einer EIGENEN, getrennt geoeffneten PDF-Instanz abseits des
//   Hauptthreads (wie `OffscreenPDF`, nie die PDF der PDFView).
// - Lage jeder Seite einer fremden Loesung: `SolutionVersionView` (eigene PDF, aufbewahrte Fassung des Absenders, Lage).

/// Seitenzahl, Kennzeichen des Seitentexts und CropBox-Groesse je Seite einer PDF-Datei
struct SolutionPDFFacts: Sendable, Equatable {
    let keys: [String]
    /// CropBox ohne Drehung je Seite (Breite, Hoehe)
    let sizes: [CGSize]

    var pageCount: Int { keys.count }

    /// Liest die Datei in einer eigenen Instanz abseits des Hauptthreads; nil, wenn sie fehlt oder nicht lesbar ist
    static func read(_ url: URL?) async -> SolutionPDFFacts? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> SolutionPDFFacts? in
            guard FileManager.default.fileExists(atPath: url.path), let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
            var keys: [String] = [], sizes: [CGSize] = []
            for i in 0..<doc.pageCount {
                let page = doc.page(at: i)
                keys.append(SolutionVersions.pageKey(page?.string ?? ""))
                sizes.append(page?.bounds(for: .cropBox).size ?? .zero)
            }
            return SolutionPDFFacts(keys: keys, sizes: sizes)
        }.value
    }

    /// Passt die eigene Seite `index` (1-basiert) in der Groesse zur Seite des Absenders? (wie `SolutionSharing.layer`)
    func fits(_ p: SolutionPage, _ index: Int) -> Bool {
        guard sizes.indices.contains(index - 1) else { return false }
        let s = sizes[index - 1]
        return abs(Double(s.width) - p.width) < 0.5 && abs(Double(s.height) - p.height) < 0.5
    }
}

/// Datenbank, Hochschule und Community-Schluessel des angemeldeten Containers (ohne Netz); Tests setzen `override`
struct CommunityLocalContext {
    let host: LocalBackendHost
    let university: String
    let spaces: @Sendable () async -> [CommunitySpace]

    nonisolated(unsafe) static var override: CommunityLocalContext?

    static var current: CommunityLocalContext? {
        if let override { return override }
        guard let c = ActiveContainer.current else { return nil }
        return CommunityLocalContext(host: c.host, university: c.key.university.rawValue,
                                     spaces: { await CommunityCourses.localSpaces(container: c) })
    }
}

/// Wie eine fremde Loesung beim Betrachter steht: eigene PDF, aufbewahrte Fassung des Absenders, Lage je PDF-Seite
struct SolutionVersionView {
    /// eigene PDF (dieselbe oder eine andere Fassung derselben Datei); nil = keine
    var own: OffscreenPDF?
    /// aufbewahrte Fassung des Absenders (S7), nil wenn nicht auf dem Geraet
    var old: OffscreenPDF?
    /// leer = dieselbe PDF (jede Seite auf ihrer eigenen), sonst die Lage je Seitenschluessel
    var placements: [String: SolutionVersions.Placement] = [:]
    /// eigene Datei (fuer "Lösung neben deinem Dokument öffnen")
    var fileID: String?

    var isOtherVersion: Bool { !placements.isEmpty }

    /// Lage einer Seite der Loesung (nil = eigenes Blatt des Absenders bzw. ohne eigene PDF)
    func placement(_ p: SolutionPage) -> SolutionVersions.Placement? {
        guard p.kind == .pdf else { return nil }
        if placements.isEmpty { return own == nil ? nil : p.pdfIndex.map { .own($0) } }
        return placements[p.key] ?? .changed
    }
}

extension CommunityCourses {
    /// Dateien aus dem eigenen Abgleich mit Ablageort (Kurs-ID und Datei-ID bleiben auf dem Geraet)
    private static let syncedFiles = """
        SELECT id, course_id, local_path, content_sha256 FROM files
        WHERE course_id <> '__user__' AND download_url IS NOT NULL AND download_url <> '' AND deleted_at IS NULL
        """

    /// Datei-Familie einer Datei aus dem Abgleich (`CommunityKeys.familyKey`); nil fuer eigene Dokumente, alte
    /// Fassungen (`FileVersions.documentID`) und unbekannte Dateien
    static func family(fileID: String, host: LocalBackendHost, university: String) async -> String? {
        guard !fileID.contains("/versions/"), let backend = try? await host.backend() else { return nil }
        let row = try? await backend.context.database.withConnection {
            try $0.rows(syncedFiles + " AND id=?", [.text(fileID)]).first
        }
        guard let row, let course = row["course_id"]?.string, !course.isEmpty else { return nil }
        return CommunityKeys.familyKey(university: university, courseID: course, fileID: fileID)
    }

    /// Eigene Datei derselben Familie (eine andere Fassung als die der Loesung), mit Ort und Fingerabdruck
    static func localFile(family: String, host: LocalBackendHost, university: String) async -> (id: String, url: URL, fingerprint: String)? {
        guard CommunityKeys.isHex64(family), let files = host.files, let backend = try? await host.backend() else { return nil }
        let rows = (try? await backend.context.database.withConnection {
            try $0.rows(syncedFiles + " AND local_path IS NOT NULL AND content_sha256 IS NOT NULL")
        }) ?? []
        for r in rows {
            guard let id = r["id"]?.string, let course = r["course_id"]?.string, let path = r["local_path"]?.string,
                  let fp = r["content_sha256"]?.string,
                  CommunityKeys.familyKey(university: university, courseID: course, fileID: id) == family,
                  files.exists(stored: path), let url = files.url(stored: path) else { continue }
            return (id, url, fp)
        }
        return nil
    }

    /// Eigene Datei, neben der eine Community-Loesung geoeffnet wird ("Lösung neben deinem Dokument öffnen"): dieselbe
    /// PDF (Fingerabdruck), sonst die eigene Fassung derselben Datei (`SolutionVersionView.fileID`). Eine Bedingung
    /// fuer beide Leser der Community (`community.reader.beside`); nil = keine eigene PDF auf dem Geraet.
    static func besideFile(for c: SolutionContent, version: SolutionVersionView, host: LocalBackendHost) async -> String? {
        await localFile(fingerprint: c.fingerprint, host: host) ?? version.fileID
    }

    /// Datei derselben Familie, die der Abgleich kennt, die aber noch nicht auf dem Geraet liegt (gelistet, nicht
    /// geladen): fuer "PDF jetzt laden" im Leser der Community. nil = die App kennt die Datei nicht (kein eigener
    /// Kurs) oder sie liegt schon da (dann gilt `besideFile`). Nur lesen, kein Netz.
    static func knownUnloadedFile(family: String?, host: LocalBackendHost, university: String) async -> String? {
        guard let family, CommunityKeys.isHex64(family), let backend = try? await host.backend() else { return nil }
        let rows = (try? await backend.context.database.withConnection { try $0.rows(syncedFiles) }) ?? []
        for r in rows {
            guard let id = r["id"]?.string, let course = r["course_id"]?.string,
                  CommunityKeys.familyKey(university: university, courseID: course, fileID: id) == family else { continue }
            // liegt schon da (ohne Dateiablage nicht pruefbar: dann gilt der Eintrag)
            if let path = r["local_path"]?.string, !path.isEmpty, host.files?.exists(stored: path) != false { return nil }
            return id
        }
        return nil
    }

    /// Aufbewahrte alte Fassung (S7, `file_versions`) mit diesem Fingerabdruck, nil wenn keine auf dem Geraet liegt
    static func keptVersion(fingerprint: String, host: LocalBackendHost) async -> URL? {
        guard CommunityKeys.isHex64(fingerprint), let files = host.files, let backend = try? await host.backend() else { return nil }
        let paths = (try? await backend.context.database.withConnection { c -> [String] in
            guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='file_versions'") != nil else { return [] }
            return try c.rows("SELECT local_path FROM file_versions WHERE content_sha256=? AND local_path IS NOT NULL ORDER BY version DESC",
                              [.text(fingerprint)]).compactMap { $0["local_path"]?.string }
        }) ?? []
        for p in paths where files.exists(stored: p) { if let url = files.url(stored: p) { return url } }
        return nil
    }

    /// Schluessel der Communities dieses Containers ohne Netz (Module aus der Datenbank, Lerngruppen dieses Geraets):
    /// zum Oeffnen gespeicherter Loesungen anderer Fassungen beim Oeffnen des Dokuments
    static func localSpaces(container: ActiveContainer?) async -> [CommunitySpace] {
        guard let container else { return [] }
        let modules = await spaces(host: container.host, university: container.key.university.rawValue)
        return modules + container.membership.groups().map(CommunitySpace.group)
    }

    /// Lage einer fremden Loesung beim Betrachter: gleiche PDF (alle Seiten auf ihrer eigenen), sonst die eigene Datei
    /// derselben Familie (`family`, vom Dienst) mit Zuordnung ueber den Seitentext und, falls aufbewahrt, die Fassung
    /// des Absenders. Ohne beides: keine eigene PDF (die Seiten zeigen dann den Hinweis, nie nur Striche).
    static func view(for c: SolutionContent, family: String?, host: LocalBackendHost, university: String) async -> SolutionVersionView {
        if let own = await ownPDF(for: c, host: host) {
            return SolutionVersionView(own: own, fileID: await localFile(fingerprint: c.fingerprint, host: host))
        }
        guard let family, let file = await localFile(family: family, host: host, university: university),
              file.fingerprint != c.fingerprint, let facts = await SolutionPDFFacts.read(file.url) else { return SolutionVersionView() }
        let keptURL = await keptVersion(fingerprint: c.fingerprint, host: host)
        let kept = await SolutionPDFFacts.read(keptURL)
        let usable = kept.flatMap { $0.pageCount == c.pdfPageCount ? $0 : nil }
        let placements = SolutionVersions.placements(c, ownFingerprint: file.fingerprint, ownKeys: facts.keys, oldVersion: usable?.keys,
                                                     fits: { facts.fits($0, $1) })
        return SolutionVersionView(own: OffscreenPDF(url: file.url), old: usable != nil ? keptURL.map(OffscreenPDF.init(url:)) : nil,
                                   placements: placements, fileID: file.id)
    }
}

extension SolutionSharing {
    /// Ebene einer Loesung zu einer anderen Fassung (Dokument mit `ownFingerprint`): Lage je Seite aus dem Seitentext,
    /// Bilder in den Grenzen (sonst die ganze Loesung abgewiesen, wie `layer`). Gehoert sie doch zu dieser PDF, gilt
    /// die normale Seitenpruefung.
    static func otherVersionLayer(_ content: SolutionContent, visible: Bool, pdf: PDFDocument, ownFingerprint: String,
                                  own: SolutionPDFFacts, kept: SolutionPDFFacts?, keptURL: URL?) throws -> ForeignSolutionLayer {
        if content.fingerprint == ownFingerprint { return try layer(content, visible: visible, pdf: pdf) }
        let usable = kept.flatMap { $0.pageCount == content.pdfPageCount ? $0 : nil }
        var placements = SolutionVersions.placements(content, ownFingerprint: ownFingerprint, ownKeys: own.keys, oldVersion: usable?.keys,
                                                     fits: { own.fits($0, $1) })
        // aufbewahrte Seite nur, wenn sie in der Groesse passt
        if let usable {
            for p in content.pages where placements[p.key] != nil {
                if case .oldVersion(let i) = placements[p.key], !usable.fits(p, i) { placements[p.key] = .changed }
            }
        }
        var layer = ForeignSolutionLayer(id: content.solutionID, displayName: content.displayName, createdAt: content.createdAt,
                                         visible: visible, pages: content.pages, images: try ForeignSolutionLayer.uiImages(content.images),
                                         missingImages: content.missingImages.count)
        // ohne PDF-Seiten (nur eigene Blaetter) bleibt `placements` leer: alles steht auf seinem Papier
        layer.placements = placements
        layer.oldVersionURL = usable != nil ? keptURL : nil
        layer.otherVersion = true
        return layer
    }
}

extension DocumentStore {
    /// Datei-Familie dieses Dokuments (nil: eigenes Dokument, alte Fassung, kein Container)
    func communityFamily() async -> String? {
        guard let c = CommunityLocalContext.current else { return nil }
        return await CommunityCourses.family(fileID: file.id, host: c.host, university: c.university)
    }

    /// Gespeicherte Loesungen zu anderen Fassungen derselben Datei (`SolutionLibrary.Entry.family`): mit den Schluesseln
    /// der Communities dieses Geraets oeffnen (ohne Netz), Seiten ueber den Text zuordnen. Laeuft abseits des
    /// Hauptthreads bis auf die Pruefung gegen die eigene PDF.
    func otherVersionLayers(library: SolutionLibrary, pdf: PDFDocument, fingerprint fp: String) async -> SolutionLayerLoad {
        var out = SolutionLayerLoad()
        guard let context = CommunityLocalContext.current, let family = await communityFamily() else { return out }
        let entries = library.entries(family: family, except: fp) + library.entries(fingerprint: fp).filter { $0.family != nil }
        guard !entries.isEmpty else { return out }
        let spaces = await context.spaces()
        guard let own = await SolutionPDFFacts.read(originalPDFURL) else { return out }
        let host: LocalBackendHost? = context.host
        for entry in entries {
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            do {
                let package = try library.package(entry.solutionID)
                let content = try await Task.detached(priority: .userInitiated) { try SolutionSharing.openCommunity(package, spaces: spaces) }.value
                var keptURL: URL?
                if let host { keptURL = await CommunityCourses.keptVersion(fingerprint: content.fingerprint, host: host) }
                let kept = await SolutionPDFFacts.read(keptURL)
                out.layers.append(try SolutionSharing.otherVersionLayer(content, visible: entry.visible, pdf: pdf, ownFingerprint: fp,
                                                                         own: own, kept: kept, keptURL: keptURL))
            } catch {
                out.problems.append(.init(id: entry.solutionID, label: label, message: SolutionSharing.message(error)))
            }
        }
        return out
    }
}
