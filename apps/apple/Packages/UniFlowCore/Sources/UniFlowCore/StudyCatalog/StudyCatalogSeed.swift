import Foundation

/// Grundstock der Modulkataloge (docs/STUDIENGAENGE-LUH-2026-11-04.md, Abschnitt "Grundstock"): die geteilten Fakten
/// aller lesbaren Kataloge einer Hochschule, einmal am Mac gebaut (tools/build-luh-seed.py, tools/build-hildesheim-seed.py)
/// und als App-Ressource mitgeliefert (`StudyCatalogSeed/<hochschule>-index.json` + `<hochschule>.json.gz`, bei Bedarf je
/// Fakultaet geteilt; LUH: `luh-index.json`, Hildesheim: `hildesheim-index.json`). Mehrere Hochschulen fasst
/// `StudyCatalogSeeds` zusammen (`StudyCatalogSeed.bundledAll`); der Ablauf fragt mit der Hochschule des Containers
/// (`settings.university`), Bibliotheksschluessel enthalten die Hochschule. Der Ablauf sucht hier vor der
/// Bibliothek und vor jedem Download; ein Treffer wird lokal gespeichert wie ein Bibliothekstreffer (Herkunft `seed`).
/// Modultexte stehen nicht im Grundstock (nur Fakten); sie laedt das Geraet erst, wenn jemand ein Modul oeffnet.
public protocol StudyCatalogSeedSource: Sendable {
    /// Katalogsemester im Grundstock zum Kuerzel (neueste zuerst), leer = keins
    func terms(university: String, code: String) -> [String]
    /// Fakten (Text wie `study_catalogs.payload`) zum Bibliotheksschluessel, nil = nicht im Grundstock
    func payload(key: String) -> String?
}

/// Grundstock aus Verzeichnis und gzip-Dateien. Die Dateien werden erst beim ersten Treffer entpackt (einmal je Datei).
public final class StudyCatalogSeed: StudyCatalogSeedSource, @unchecked Sendable {
    public typealias FileLoader = @Sendable (_ name: String) -> Data?

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var program: String
        public var degree: String
        public var po: String
        public var term: String
        public var code: String
        public var libraryKey: String
        public var file: String
        public var modules: Int
        public var qisLabels: [String]
    }

    public let university: String
    public let entries: [Entry]
    private let loadFile: FileLoader
    private let lock = NSLock()
    private var files: [String: [String: String]] = [:]     // Datei -> {Bibliotheksschluessel: payload}

    /// Hoechstens so viel entpackt je Datei (Schutz gegen kaputte Ressourcen)
    public static let maxBytes = 64 * 1024 * 1024

    public init(index: JSONValue, loadFile: @escaping FileLoader) {
        university = index["university"]?.string ?? "luh"
        entries = (index["entries"]?.array ?? []).compactMap { e in
            guard let code = e["code"]?.string, let term = e["term"]?.string, let lk = e["library_key"]?.string,
                  let file = e["file"]?.string else { return nil }
            return Entry(key: e["key"]?.string ?? "", program: e["program"]?.string ?? "", degree: e["degree"]?.string ?? "",
                         po: StudySources.text(e["po"]), term: term, code: code, libraryKey: lk, file: file,
                         modules: e["modules"]?.int ?? 0, qisLabels: (e["qis_labels"]?.array ?? []).compactMap(\.string))
        }
        self.loadFile = loadFile
    }

    /// Hochschulen mit Grundstock (Dateiname des Verzeichnisses `<id>-index.json`)
    public static let universities = ["luh", "hildesheim", "hsh"]

    /// Grundstock einer Hochschule aus einem Bundle (App: `Bundle.main`); nil ohne Verzeichnis. Die Ressourcen liegen je
    /// nach Build flach im Bundle oder im Unterordner `StudyCatalogSeed`.
    public static func bundled(_ bundle: Bundle = .main, university: String = "luh") -> StudyCatalogSeed? {
        guard let indexURL = resource("\(university)-index.json", in: bundle), let data = try? Data(contentsOf: indexURL),
              let index = try? JSONValue.parse(data) else { return nil }
        let seed = StudyCatalogSeed(index: index) { name in resource(name, in: bundle).flatMap { try? Data(contentsOf: $0) } }
        return seed.university == university ? seed : nil
    }

    /// Grundstock aller Hochschulen im Bundle (`universities`); nil, wenn keiner da ist
    public static func bundledAll(_ bundle: Bundle = .main, universities: [String] = StudyCatalogSeed.universities) -> StudyCatalogSeeds? {
        let seeds = universities.compactMap { bundled(bundle, university: $0) }
        return seeds.isEmpty ? nil : StudyCatalogSeeds(seeds)
    }

    static func resource(_ name: String, in bundle: Bundle) -> URL? {
        let ext = name.hasSuffix(".json.gz") ? "json.gz" : (name as NSString).pathExtension
        let base = String(name.dropLast(ext.count + 1))
        return bundle.url(forResource: base, withExtension: ext) ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "StudyCatalogSeed")
    }

    public func terms(university: String, code: String) -> [String] {
        guard university == self.university else { return [] }
        var seen = Set<String>()
        return entries.filter { $0.code == code }.map(\.term)
            .filter { StudyCatalogText.termNumber($0) != nil && seen.insert($0).inserted }
            .sorted { StudyCatalogText.termNumber($0)! > StudyCatalogText.termNumber($1)! }
    }

    public func payload(key: String) -> String? {
        guard let file = entries.first(where: { $0.libraryKey == key })?.file else { return nil }
        return catalogs(in: file)[key]
    }

    /// Eintraege des Verzeichnisses zu einem Registerschluessel ("luh|informatik|b.sc.|2017")
    public func entries(registryKey: String) -> [Entry] { entries.filter { $0.key == registryKey } }

    /// Kataloge einer Datei (entpackt und je Schluessel als Text abgelegt; kaputte Datei = leer)
    func catalogs(in file: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = files[file] { return hit }
        var out: [String: String] = [:]
        if let gz = loadFile(file), let raw = Self.gunzip(gz, limit: Self.maxBytes), let j = try? JSONValue.parse(raw) {
            for c in j["catalogs"]?.array ?? [] {
                out[StudyCatalogStore.key(of: c)] = c.jsonString(sortedKeys: true)
            }
        }
        files[file] = out
        return out
    }

    /// gzip (RFC 1952) -> Klartext: Kopf (mit FEXTRA/FNAME/FCOMMENT/FHCRC) und Fuss (CRC, Laenge) ab, dazwischen raw
    /// DEFLATE (`SolutionDeflate`); nil bei kaputten Daten oder mehr als `limit` Byte
    public static func gunzip(_ data: Data, limit: Int = maxBytes) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let size = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        guard let out = try? SolutionDeflate.inflate(Data(b[i..<(b.count - 8)]), limit: limit),
              out.count & 0xffff_ffff == size else { return nil }
        return out
    }
}

/// Grundstock mehrerer Hochschulen: je Anfrage der Grundstock der genannten Hochschule (`terms`), Fakten ueber den
/// Bibliotheksschluessel (enthaelt die Hochschule, daher eindeutig)
public final class StudyCatalogSeeds: StudyCatalogSeedSource, @unchecked Sendable {
    public let seeds: [StudyCatalogSeed]

    public init(_ seeds: [StudyCatalogSeed]) { self.seeds = seeds }

    /// Grundstock einer Hochschule, nil ohne
    public func seed(university: String) -> StudyCatalogSeed? { seeds.first { $0.university == university } }

    /// Verzeichnis aller Hochschulen
    public var entries: [StudyCatalogSeed.Entry] { seeds.flatMap(\.entries) }

    public var universities: [String] { seeds.map(\.university) }

    public func terms(university: String, code: String) -> [String] {
        seed(university: university)?.terms(university: university, code: code) ?? []
    }

    public func payload(key: String) -> String? {
        for s in seeds { if let p = s.payload(key: key) { return p } }
        return nil
    }
}
