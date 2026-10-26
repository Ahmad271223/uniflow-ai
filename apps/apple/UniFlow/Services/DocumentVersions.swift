import Foundation
import UniFlowCore

/// Alte Original-Fassung einer Datei mit Notizen (S7), wie `GET /api/files/{id}/versions` des lokalen Backends sie
/// liefert (`FileVersionEndpoints`).
struct FileVersionInfo: Identifiable, Equatable {
    struct Check: Equatable {
        /// Seite in der alten und in der neuen Fassung (1-basiert)
        let old: Int
        let new: Int
        /// Art der Zuordnung (`PageMatch.Kind`): "aehnlich" = Text geaendert, sonst unsicher zugeordnet
        /// ("wiederholt": gleicher Text mehrfach, "position": ohne Text)
        var kind: String = "aehnlich"

        var changedText: Bool { kind == "aehnlich" }
    }

    let version: Int
    /// Kennung fuer den Editor (`FileVersions.documentID`)
    let documentID: String
    let name: String?
    let source: String
    let replacedAt: String?
    /// aufbewahrte PDF vorhanden
    let available: Bool
    let seen: Bool
    /// Seiten mit Notizen, deren Text sich geaendert hat oder die nur nach Position zugeordnet sind
    let check: [Check]
    /// alte Seiten mit Notizen, die es in der neuen Fassung nicht mehr gibt
    let removed: [Int]

    var id: Int { version }

    init?(_ v: JSONValue) {
        guard let version = v.i("version"), let doc = v.s("document_id") else { return nil }
        self.version = version
        documentID = doc
        name = v.s("name")
        source = v.s("source") ?? "Stud.IP"
        replacedAt = v.s("replaced_at")
        available = v["available"]?.bool ?? false
        seen = v["seen"]?.bool ?? false
        check = v.list("check").compactMap { c in
            c.i("old").flatMap { o in c.i("new").map { Check(old: o, new: $0, kind: c.s("kind") ?? "aehnlich") } }
        }
        removed = v.list("removed").compactMap(\.int)
    }

    /// Seiten, die der Nutzer pruefen sollte (geaendert, unsicher zugeordnet oder nur noch in der alten Fassung)
    var pagesToCheck: Int { check.count + removed.count }

    /// "Neue Fassung aus Stud.IP – Notizen übernommen (2 Seiten prüfen)"
    var noticeTitle: String {
        let n = pagesToCheck
        return "Neue Fassung aus \(source) – Notizen übernommen" + (n > 0 ? " (\(n) \(n == 1 ? "Seite" : "Seiten") prüfen)" : "")
    }

    /// Welche Seiten: "Geänderte Seite 4 · Unsicher zugeordnet: Seite 6 · Nur in der alten Fassung: Seite 7"
    var noticeDetail: String? {
        var parts: [String] = []
        let changed = check.filter(\.changedText), unsure = check.filter { !$0.changedText }
        if !changed.isEmpty {
            parts.append((changed.count == 1 ? "Geänderte Seite " : "Geänderte Seiten ") + changed.map { "\($0.new)" }.joined(separator: ", "))
        }
        if !unsure.isEmpty {
            parts.append("Unsicher zugeordnet: " + (unsure.count == 1 ? "Seite " : "Seiten ") + unsure.map { "\($0.new)" }.joined(separator: ", "))
        }
        if !removed.isEmpty {
            parts.append("Nur in der alten Fassung: " + (removed.count == 1 ? "Seite " : "Seiten ") + removed.map(String.init).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Fassung bis 26.10.2026" (bis zu diesem Tag die aktuelle Fassung)
    var label: String {
        guard let r = replacedAt, r.count >= 10 else { return "Alte Fassung \(version)" }
        let d = r.prefix(10).split(separator: "-")
        return d.count == 3 ? "Fassung bis \(d[2]).\(d[1]).\(d[0])" : "Alte Fassung \(version)"
    }
}

extension DocumentStore {
    /// Ist dies selbst eine alte Fassung (`FileVersions.documentID`)?
    var isOldVersion: Bool { file.id.contains("/versions/") }

    /// Datei neben dem PDF-Zwischenspeicher mit dem Stand, aus dem er stammt
    var stampURL: URL { originalPDFURL.appendingPathExtension("stand") }

    /// Stand der Original-PDF laut Quelle: Ladezeitpunkt und Inhalts-Hash aus `GET /api/files/{id}` (fuer eine alte
    /// Fassung, die sich nie aendert, fragt der Store nicht)
    nonisolated static func stamp(_ meta: JSONValue) -> String {
        (meta.s("downloaded_at") ?? "") + "|" + (meta.s("content_sha256") ?? "")
    }

    /// Alte Fassungen und Hinweis laden (am PC-Server gibt es den Pfad nicht: nichts anzeigen)
    func loadVersions() async {
        guard !isOldVersion, let r = try? await api.value("/api/files/\(file.id)/versions") else { return }
        versions = r.list("versions").compactMap(FileVersionInfo.init)
        versionNotice = r["notice"].flatMap(FileVersionInfo.init)
    }

    /// Hinweis zur neuen Fassung gesehen
    func dismissVersionNotice() async {
        versionNotice = nil
        _ = try? await api.value("/api/files/\(file.id)/versions/seen", method: "POST", body: [:])
    }

    /// Die alte Fassung als Dokument fuer den Editor (nur zum Ansehen)
    func oldVersionFile(_ v: FileVersionInfo) -> LibFile {
        LibFile(id: v.documentID, name: v.name ?? file.name, title: "\(file.displayTitle) – \(v.label)", kind: "pdf",
                module_id: file.module_id, subject: file.subject, doc_type: file.doc_type, ai_title: nil, sub_label: file.sub_label,
                downloaded_at: v.replacedAt, has_notes: 1, page_count: nil, studip_folder: file.studip_folder)
    }

    /// Seitentexte fuer Suche und Skriptsuche beim Oeffnen bereitstellen (lokal: einmal mit PDFKit gelesen und
    /// gespeichert, danach aus der Datenbank); ohne Wirkung auf die Anzeige
    func indexPageTexts() {
        guard api.isLocal, !isOldVersion, !isNotebook else { return }
        let api = self.api, id = file.id
        Task.detached(priority: .utility) { _ = try? await api.value("/api/files/\(id)/pagetext?page=1") }
    }
}
