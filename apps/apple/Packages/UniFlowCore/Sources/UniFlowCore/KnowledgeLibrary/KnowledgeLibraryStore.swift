import Foundation

// Ablage der Wissensbibliothek im Container des Nutzers: `<Container>/Wissensbibliothek/aktuell/` mit
//   katalog.json, Bibliothek/…           kopierte Dateien (ohne Pruefskripte `_pruefung.py`)
//   wb-meta.json                          je Einheit: Markierungen, Typen, Quellen (fuer Badges und die Zuordnung)
//   wb-suche.sqlite                       Volltext je Abschnitt (Suchform), fuer die lokale Suche
//   wb-import.json                        Stand, Zeitpunkt, Zahlen des Imports
// Ein neuer Import entsteht in einem eigenen Ordner und ersetzt `aktuell` erst am Ende (umbenennen), nie
// zusammenfuehren. Eigene Notizen, Datenbank und Downloads des Nutzers liegen woanders und bleiben unberuehrt.
// Nichts davon verlaesst das Geraet (kein Server, keine KI, keine Community).

/// Zahlen und Stand des letzten Imports (`wb-import.json`).
public struct KnowledgeImportManifest: Codable, Equatable, Sendable {
    /// Format der Ablage; aendert es sich, baut die App Meta-Daten und Suche aus den Dateien neu (ohne neuen Import)
    public var format: Int
    public var version: Int
    public var stand: String
    public var importedAt: String
    /// Name des gewaehlten Ordners bzw. der ZIP-Datei (nur zur Anzeige)
    public var source: String
    public var subjects: Int
    public var units: Int
    /// kopierte Dateien (ohne Pruefskripte)
    public var files: Int
    public var markdownFiles: Int
    public var sections: Int
    public var bytes: Int
    /// Dateien laut Katalog, die im Ordner fehlten (Anzahl und die ersten Pfade)
    public var missingCount: Int
    public var missing: [String]
    /// Dauer des Imports in Sekunden
    public var seconds: Double
}

/// Je Einheit: Markierungen aller ihrer Dateien, Typen, Herkunft der Loesungen, Quellen.
public struct KnowledgeUnitSummary: Codable, Equatable, Sendable {
    public var marks = KnowledgeMarks()
    /// Werte von `typ` (ohne Wiederholungen)
    public var types: [String] = []
    /// Werte von `loesung_von`
    public var solutionBy: [String] = []
    /// Quellen zur Anzeige
    public var sources: [String] = []
    /// Quellen in Vergleichsform (`KnowledgeSourceMatch.blob`)
    public var sourceBlob = ""

    public init() {}
}

public struct KnowledgeLibraryMeta: Codable, Equatable, Sendable {
    /// Titel der Faecher aus ihrem README ("Signale und Systeme (für Elektrotechnik)")
    public var subjectTitles: [String: String] = [:]
    /// Schluessel = `KnowledgeUnit.key`
    public var units: [String: KnowledgeUnitSummary] = [:]
    public init() {}
}

/// Suchtreffer: Abschnitt einer Datei einer Einheit.
public struct KnowledgeSearchHit: Equatable, Sendable, Identifiable {
    public var unitKey: String
    public var file: String
    public var section: Int
    public var heading: String?
    public var snippet: String
    public var id: String { "\(unitKey)|\(file)|\(section)" }
}

public enum KnowledgeImportError: Error, Equatable, LocalizedError {
    /// kein `katalog.json` im gewaehlten Ordner (auch nicht eine Ebene tiefer)
    case noCatalog
    case badCatalog(String)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCatalog:
            return "In diesem Ordner liegt keine Wissensbibliothek (katalog.json fehlt). Bitte den Ordner „uniflow-wissensbibliothek“ oder eine ZIP davon wählen."
        case .badCatalog(let m): return "katalog.json ist nicht lesbar: \(m)"
        case .copyFailed(let m): return "Kopieren fehlgeschlagen: \(m)"
        }
    }
}

/// Eine eingelesene Bibliothek (nur lesen).
public struct KnowledgeLibrary: Sendable {
    /// Ordner `aktuell`
    public let root: URL
    public let catalog: KnowledgeCatalog
    public let manifest: KnowledgeImportManifest
    public let meta: KnowledgeLibraryMeta

    public func title(of subject: KnowledgeSubject) -> String { meta.subjectTitles[subject.folder] ?? subject.fallbackTitle }
    public func summary(_ unit: KnowledgeUnit) -> KnowledgeUnitSummary { meta.units[unit.key] ?? KnowledgeUnitSummary() }

    public func url(_ unit: KnowledgeUnit, file: String) -> URL {
        KnowledgePaths.url(root, unit.path + "/" + KnowledgeText.nfc(file))
    }

    public func exists(_ unit: KnowledgeUnit, file: String) -> Bool {
        FileManager.default.fileExists(atPath: url(unit, file: file).path)
    }

    /// Datei als Text (UTF-8, sonst Latin-1); Pruefskripte nie
    public func read(_ unit: KnowledgeUnit, file: String) throws -> String {
        guard KnowledgeFileKind.of(file) != .checkScript else { return "" }
        return try KnowledgePaths.readText(url(unit, file: file))
    }

    /// Fachueberblick (README.md des Fachs), falls vorhanden
    public func subjectOverview(_ subject: KnowledgeSubject) -> String? {
        try? KnowledgePaths.readText(KnowledgePaths.url(root, "Bibliothek/" + subject.folder + "/README.md"))
    }

    /// Verweis "identisch mit G0035" einer Einheit: Einheit desselben Fachs
    public func resolve(_ link: KnowledgeLink, from unit: KnowledgeUnit) -> KnowledgeUnit? {
        catalog.unit(subject: unit.subject, id: link.unit)
    }

    /// Einheiten, in deren `quellen` der Titel oder Dateiname einer Stud.IP-Datei vorkommt (aktuelles Semester zuerst)
    public func units(matchingTitle title: String?, fileName: String?) -> [KnowledgeUnit] {
        let c = KnowledgeSourceMatch.candidates(title: title, fileName: fileName)
        guard !c.isEmpty else { return [] }
        return KnowledgeLibraryStore.ordered(catalog).filter { u in
            guard let blob = meta.units[u.key]?.sourceBlob, !blob.isEmpty else { return false }
            return KnowledgeSourceMatch.matches(candidates: c, blob: blob)
        }
    }

    /// Volltextsuche ueber alle Abschnitte der .md-Dateien (ohne Pruefskripte). Alle Woerter muessen im Abschnitt
    /// vorkommen; Treffer in der Ueberschrift zuerst, dann aktuelles Semester, dann Reihenfolge der Bibliothek.
    public func search(_ query: String, limit: Int = 40) throws -> [KnowledgeSearchHit] {
        let words = KnowledgeText.searchForm(query).split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty, words.joined().count >= 2 else { return [] }
        let db = try SQLiteConnection(path: root.appendingPathComponent(KnowledgeLibraryStore.indexName).path)
        defer { db.close() }
        let conds = words.indices.map { "instr(body_l, ?\($0 + 1)) > 0" }.joined(separator: " AND ")
        let sql = "SELECT unit, file, idx, heading, (instr(head_l, ?1) > 0) AS h FROM sections WHERE \(conds) ORDER BY h DESC, rank ASC, idx ASC LIMIT \(max(1, limit))"
        let rows = try db.query(sql, words.map { .text($0) })
        var docs: [String: KnowledgeDocument] = [:]
        return rows.compactMap { r in
            guard let key = r["unit"]?.string, let file = r["file"]?.string, let idx = r["idx"]?.int else { return nil }
            var snippet = ""
            if let unit = catalog.unit(key: key) {
                let docKey = key + "|" + file
                let doc = docs[docKey] ?? (try? read(unit, file: file)).map(KnowledgeDocument.parse)
                docs[docKey] = doc
                if let s = doc?.sections.first(where: { $0.index == idx }) { snippet = Self.snippet(s.markdown, words: words) }
            }
            return KnowledgeSearchHit(unitKey: key, file: file, section: idx, heading: r["heading"]?.string, snippet: snippet)
        }
    }

    /// Ausschnitt um das erste Suchwort: hoechstens 140 Zeichen, Markdown-Zeichen und Zeilen zu Leerzeichen
    static func snippet(_ markdown: String, words: [String]) -> String {
        let flat = markdown.split(whereSeparator: \.isNewline).dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "> ", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let w = words.first, let r = flat.range(of: w, options: [.caseInsensitive]) else { return String(flat.prefix(140)) }
        let start = flat.index(r.lowerBound, offsetBy: -50, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 90, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + String(flat[start..<end]) + (end < flat.endIndex ? "…" : "")
    }
}

/// Pfade: Unicode-sicher (NFC/NFD) und nie ausserhalb der Wurzel.
public enum KnowledgePaths {
    /// Pfad unter `root` (Teile in NFC, ohne ".." und leere Teile)
    public static func url(_ root: URL, _ relative: String) -> URL {
        KnowledgeText.cleanPath(relative).split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Datei oder Ordner unter `root` finden, auch wenn das Dateisystem die Namen in einer anderen Normalform fuehrt
    /// (ZIP vom Mac in NFD, Katalog in NFC; Linux unterscheidet beides). `listings` merkt sich gelesene Ordner.
    public static func resolve(_ root: URL, _ relative: String, fileManager fm: FileManager = .default,
                               listings: inout [String: [String]]) -> URL? {
        let direct = url(root, relative)
        if fm.fileExists(atPath: direct.path) { return direct }
        var cur = root
        for part in KnowledgeText.cleanPath(relative).split(separator: "/").map(String.init) {
            let candidate = cur.appendingPathComponent(part)
            if fm.fileExists(atPath: candidate.path) { cur = candidate; continue }
            let names: [String]
            if let cached = listings[cur.path] { names = cached } else {
                names = (try? fm.contentsOfDirectory(atPath: cur.path)) ?? []
                listings[cur.path] = names
            }
            guard let hit = names.first(where: { KnowledgeText.nfc($0) == part }) else { return nil }
            cur = cur.appendingPathComponent(hit)
        }
        return cur
    }

    /// Text einer Datei: UTF-8, sonst Latin-1 (nie ein Absturz an kaputten Bytes)
    public static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Import, Laden und Entfernen der Bibliothek in einem Container.
public final class KnowledgeLibraryStore: @unchecked Sendable {
    public static let folderName = "Wissensbibliothek"
    /// Format der Ablage (Meta-Daten, Suche). Erhoehen, wenn sich `wb-meta.json` oder `wb-suche.sqlite` aendern.
    /// 2 (20.11.2026): Dateien mit CRLF-Zeilenenden werden richtig gelesen (Kopfdaten, Abschnitte)
    public static let format = 2
    static let currentName = "aktuell"
    static let manifestName = "wb-import.json"
    static let metaName = "wb-meta.json"
    static let indexName = "wb-suche.sqlite"

    /// `<Container>/Wissensbibliothek`
    public let base: URL
    private let fm: FileManager

    public init(base: URL, fileManager: FileManager = .default) {
        self.base = base
        self.fm = fileManager
    }

    public convenience init(containerRoot: URL) {
        self.init(base: containerRoot.appendingPathComponent(Self.folderName, isDirectory: true))
    }

    public var currentFolder: URL { base.appendingPathComponent(Self.currentName, isDirectory: true) }

    public func manifest() -> KnowledgeImportManifest? {
        guard let data = fm.contents(atPath: currentFolder.appendingPathComponent(Self.manifestName).path) else { return nil }
        return try? JSONDecoder().decode(KnowledgeImportManifest.self, from: data)
    }

    public var isImported: Bool { manifest() != nil }

    /// Bibliothek laden; nil ohne Import. Ist die Ablage aus einer aelteren App-Fassung (`format`), werden Meta-Daten
    /// und Suche aus den vorhandenen Dateien neu gebaut.
    public func load() throws -> KnowledgeLibrary? {
        guard var manifest = manifest() else { return nil }
        let dir = currentFolder
        guard let catData = fm.contents(atPath: dir.appendingPathComponent("katalog.json").path) else { return nil }
        let catalog = try KnowledgeCatalog.parse(catData)
        var meta: KnowledgeLibraryMeta?
        if manifest.format == Self.format, let m = fm.contents(atPath: dir.appendingPathComponent(Self.metaName).path) {
            meta = try? JSONDecoder().decode(KnowledgeLibraryMeta.self, from: m)
        }
        if meta == nil || !fm.fileExists(atPath: dir.appendingPathComponent(Self.indexName).path) {
            let built = try Self.buildIndex(at: dir, catalog: catalog, fileManager: fm)
            meta = built.meta
            manifest.format = Self.format
            manifest.sections = built.sections
            try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
        }
        return KnowledgeLibrary(root: dir, catalog: catalog, manifest: manifest, meta: meta ?? KnowledgeLibraryMeta())
    }

    public enum Outcome: Equatable, Sendable {
        case imported(KnowledgeImportManifest)
        /// gleicher Stand schon eingelesen
        case alreadyCurrent(stand: String)
        /// eingelesen ist ein neuerer Stand als der angebotene
        case newerInstalled(installed: String, offered: String)
    }

    /// Ordner mit `katalog.json`: der gewaehlte selbst oder ein Unterordner (ZIP mit Hauptordner), hoechstens zwei Ebenen
    public static func locateRoot(in folder: URL, fileManager fm: FileManager = .default) -> URL? {
        if fm.fileExists(atPath: folder.appendingPathComponent("katalog.json").path) { return folder }
        var level = [folder]
        for _ in 0..<2 {
            var next: [URL] = []
            for dir in level {
                let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }.sorted()
                for n in names {
                    let u = dir.appendingPathComponent(n)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    if fm.fileExists(atPath: u.appendingPathComponent("katalog.json").path) { return u }
                    next.append(u)
                }
            }
            level = next
        }
        return nil
    }

    /// Stand einer Quelle lesen, ohne zu kopieren (fuer die Frage "neuer als eingelesen?")
    public static func offeredCatalog(in folder: URL, fileManager fm: FileManager = .default) throws -> KnowledgeCatalog {
        guard let root = locateRoot(in: folder, fileManager: fm) else { throw KnowledgeImportError.noCatalog }
        guard let data = fm.contents(atPath: root.appendingPathComponent("katalog.json").path) else { throw KnowledgeImportError.noCatalog }
        do { return try KnowledgeCatalog.parse(data) } catch { throw KnowledgeImportError.badCatalog(error.localizedDescription) }
    }

    /// Bibliothek aus einem Ordner einlesen. Neuer Stand (oder `force`): Dateien kopieren, Meta-Daten und Suche bauen,
    /// dann den alten Stand als Ganzes ersetzen. Gleicher oder aelterer Stand ohne `force`: nichts aendern.
    /// `progress(erledigt, gesamt)` wird beim Kopieren und Einlesen aufgerufen.
    public func importLibrary(from source: URL, sourceName: String? = nil, force: Bool = false, clock: UniFlowClock = .system,
                              progress: ((Int, Int) -> Void)? = nil) throws -> Outcome {
        let started = Date()
        guard let root = Self.locateRoot(in: source, fileManager: fm) else { throw KnowledgeImportError.noCatalog }
        let catData: Data
        do { catData = try Data(contentsOf: root.appendingPathComponent("katalog.json")) } catch { throw KnowledgeImportError.noCatalog }
        let catalog: KnowledgeCatalog
        do { catalog = try KnowledgeCatalog.parse(catData) } catch { throw KnowledgeImportError.badCatalog(error.localizedDescription) }
        if !force, let installed = manifest()?.stand {
            if installed == catalog.stand { return .alreadyCurrent(stand: installed) }
            if installed > catalog.stand { return .newerInstalled(installed: installed, offered: catalog.stand) }
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        Self.purgeLeftovers(base, fileManager: fm)
        let staging = base.appendingPathComponent(".neu-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try catData.write(to: staging.appendingPathComponent("katalog.json"))
            var listings: [String: [String]] = [:]
            var copied = 0, bytes = 0
            var missing: [String] = []
            let total = catalog.units.reduce(0) { $0 + $1.files.count }
            var done = 0
            for subject in catalog.subjects {
                // Fachueberblick, Fortschritt, Loesungsstil (.md direkt im Fachordner)
                let subjectRel = "Bibliothek/" + subject.folder
                if let dir = KnowledgePaths.resolve(root, subjectRel, fileManager: fm, listings: &listings) {
                    for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) where name.lowercased().hasSuffix(".md") {
                        let dst = KnowledgePaths.url(staging, subjectRel + "/" + KnowledgeText.nfc(name))
                        bytes += try Self.copy(dir.appendingPathComponent(name), to: dst, fileManager: fm)
                    }
                }
                for unit in subject.units {
                    for file in unit.files {
                        done += 1
                        if done % 50 == 0 { progress?(done, total) }
                        guard KnowledgeFileKind.of(file) != .checkScript else { continue }   // nie kopiert, nie ausgefuehrt
                        let rel = unit.path + "/" + file
                        guard let src = KnowledgePaths.resolve(root, rel, fileManager: fm, listings: &listings) else {
                            missing.append(rel)
                            continue
                        }
                        bytes += try Self.copy(src, to: KnowledgePaths.url(staging, rel), fileManager: fm)
                        copied += 1
                    }
                }
            }
            progress?(total, total)
            let built = try Self.buildIndex(at: staging, catalog: catalog, fileManager: fm)
            let manifest = KnowledgeImportManifest(
                format: Self.format, version: catalog.version, stand: catalog.stand, importedAt: clock.nowISO,
                source: sourceName ?? source.lastPathComponent, subjects: catalog.subjects.count, units: catalog.unitCount,
                files: copied, markdownFiles: built.markdownFiles, sections: built.sections, bytes: bytes,
                missingCount: missing.count, missing: Array(missing.prefix(20)), seconds: Date().timeIntervalSince(started))
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            try replaceCurrent(with: staging)
            return .imported(manifest)
        } catch {
            try? fm.removeItem(at: staging)
            if error is KnowledgeImportError { throw error }
            throw KnowledgeImportError.copyFailed(error.localizedDescription)
        }
    }

    /// Ganze Bibliothek entfernen (nur dieser Ordner; Notizen und Downloads bleiben)
    public func remove() throws {
        guard fm.fileExists(atPath: base.path) else { return }
        let trash = base.deletingLastPathComponent().appendingPathComponent(".wb-weg-" + UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: base, to: trash)
        try? fm.removeItem(at: trash)
    }

    // MARK: Intern

    private func replaceCurrent(with staging: URL) throws {
        let current = currentFolder
        if fm.fileExists(atPath: current.path) {
            let old = base.appendingPathComponent(".alt-" + UUID().uuidString, isDirectory: true)
            try fm.moveItem(at: current, to: old)
            do { try fm.moveItem(at: staging, to: current) } catch {
                try? fm.moveItem(at: old, to: current)                    // alten Stand behalten
                throw error
            }
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: staging, to: current)
        }
    }

    /// Reste abgebrochener Importe (".neu-…", ".alt-…")
    static func purgeLeftovers(_ base: URL, fileManager fm: FileManager) {
        for n in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where n.hasPrefix(".neu-") || n.hasPrefix(".alt-") {
            try? fm.removeItem(at: base.appendingPathComponent(n))
        }
    }

    @discardableResult
    static func copy(_ src: URL, to dst: URL, fileManager fm: FileManager) throws -> Int {
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Reihenfolge der Bibliothek fuer Suche und Zuordnung: aktuelles Semester zuerst, dann Faecher wie im Katalog,
    /// darin Semester neu nach alt und Einheiten natuerlich sortiert
    public static func ordered(_ catalog: KnowledgeCatalog) -> [KnowledgeUnit] {
        let bySubject = catalog.subjects.map { s in s.semesters.flatMap { $0.roles.flatMap(\.units) } }
        let current = bySubject.flatMap { $0.filter(\.isCurrentSemester) }
        let rest = bySubject.flatMap { $0.filter { !$0.isCurrentSemester } }
        return current + rest
    }

    struct Built { var meta: KnowledgeLibraryMeta; var sections: Int; var markdownFiles: Int }

    /// Meta-Daten (Markierungen, Quellen, Fachtitel) und Suchindex aus den Dateien unter `dir` bauen
    static func buildIndex(at dir: URL, catalog: KnowledgeCatalog, fileManager fm: FileManager) throws -> Built {
        var meta = KnowledgeLibraryMeta()
        for s in catalog.subjects {
            if let readme = try? KnowledgePaths.readText(KnowledgePaths.url(dir, "Bibliothek/" + s.folder + "/README.md")),
               let h = KnowledgeDocument.parse(readme).sections.first(where: { $0.level == 1 })?.heading {
                meta.subjectTitles[s.folder] = h
            }
        }
        let indexURL = dir.appendingPathComponent(indexName)
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: indexURL.path + suffix) }
        let db = try SQLiteConnection(path: indexURL.path)
        defer { db.close() }
        try db.execute("PRAGMA journal_mode=DELETE")
        try db.executeScript("""
            CREATE TABLE sections(unit TEXT NOT NULL, file TEXT NOT NULL, idx INTEGER NOT NULL, heading TEXT,
                                  rank INTEGER NOT NULL, head_l TEXT NOT NULL, body_l TEXT NOT NULL);
            """)
        var sections = 0, mdFiles = 0
        let order = ordered(catalog)
        try db.transaction { db in
            let insert = try db.prepare("INSERT INTO sections(unit, file, idx, heading, rank, head_l, body_l) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
            for (rank, unit) in order.enumerated() {
                var summary = KnowledgeUnitSummary()
                var sources: [String] = []
                for file in unit.files where KnowledgeFileKind.of(file).isMarkdown {
                    guard let text = try? KnowledgePaths.readText(KnowledgePaths.url(dir, unit.path + "/" + file)) else { continue }
                    mdFiles += 1
                    let doc = KnowledgeDocument.parse(text)
                    summary.marks.merge(KnowledgeMarks.scan(text))
                    if let f = doc.frontMatter {
                        for t in f.values("typ") where !summary.types.contains(t) { summary.types.append(t) }
                        for t in f.values("loesung_von") where !summary.solutionBy.contains(t) { summary.solutionBy.append(t) }
                        for t in f.sources where !sources.contains(t) { sources.append(t) }
                    }
                    if KnowledgeFileKind.of(file) == .readme {
                        // README-Tabelle: "| Quelle Q1 | <Titel …> |"
                        for line in doc.body.split(separator: "\n") where line.hasPrefix("| Quelle") {
                            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                            if cells.count >= 2, !sources.contains(cells[1]) { sources.append(cells[1]) }
                        }
                    }
                    for s in doc.sections {
                        let head = s.heading ?? ""
                        try insert.bind([.text(unit.key), .text(file), .integer(Int64(s.index)), s.heading.map { .text($0) } ?? .null,
                                         .integer(Int64(rank)), .text(KnowledgeText.searchForm(head)), .text(KnowledgeText.searchForm(s.markdown))]).run()
                        sections += 1
                    }
                }
                summary.sources = sources
                summary.sourceBlob = KnowledgeSourceMatch.blob(sources)
                meta.units[unit.key] = summary
            }
        }
        let data = try JSONEncoder().encode(meta)
        try data.write(to: dir.appendingPathComponent(metaName), options: .atomic)
        return Built(meta: meta, sections: sections, markdownFiles: mdFiles)
    }
}
