import Foundation

// Datentrennung je (Apple-Nutzer, Hochschule), docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 2. Die eine Fassung fuer
// alle Speicherorte (Ordner, Schluesselbund-Namen, Webdaten-Speicher); der Stud.IP-Abgleich der App und
// `HildesheimSync` schreiben in denselben Container:
// Jede Kombination hat einen eigenen Ordner (Container) mit allem, was die App fuer sie speichert: SQLite-Datenbank,
// Journal der Notizen, PDF-Zwischenspeicher und Vorschaubilder, Loesungs-Bibliothek, eigene Dokumente und Bilder,
// Stud.IP- bzw. Learnweb-Downloads. Der Ordnername ist eine feste UUID aus Nutzer und Hochschule; dieselbe UUID
// benennt in der App den WKWebsiteDataStore der Anmelde-Webansichten (`websiteDataStoreID`). Gemerkte Zugangsdaten
// liegen im Schluesselbund-Dienst `keychainService` unter `keychainAccount(service:field:)`. Die Apple-Nutzer-ID
// steht nirgends im Dateisystem und im Schluesselbund, nur ihr Hash.
//
// Jeder Container traegt in `container.json` seine Hochschule und seinen Nutzer (Hash). Passt das beim Oeffnen
// nicht, wird er nicht geoeffnet (wie `UniversityMismatch` der Datenbank, die ihre Hochschule zusaetzlich selbst
// in `settings` fuehrt).

/// Schluessel eines Speichers: (Apple-Nutzer-ID, Hochschule).
public struct DataContainerKey: Hashable, Sendable, CustomStringConvertible {
    public let userID: String
    public let university: UniversityKey

    public init(userID: String, university: UniversityKey) {
        self.userID = userID
        self.university = university
    }

    /// Aus gespeicherten Werten: nur eine bekannte Hochschule (kein Pfad aus Eingaben, kein Raten) und ein
    /// angemeldeter Nutzer; sonst nil.
    public init?(userID: String, universityKey raw: String?) {
        guard !userID.isEmpty, let uni = raw.flatMap(UniversityKey.init(rawValue:)) else { return nil }
        self.init(userID: userID, university: uni)
    }

    /// Feste UUID je (Nutzer, Hochschule): erste 16 Byte von SHA-256 ueber beide, Version 8 (RFC 9562, frei belegt).
    public var identifier: UUID {
        Self.uuid(from: SolutionSHA256.hash(Data(("uniflow.container.v1\u{0}" + userID + "\u{0}" + university.rawValue).utf8)))
    }

    /// Kurzkennung des Nutzers ohne die Apple-ID selbst (Schluesselbund-Praefix, Einstellungen, Container-Merker)
    public var userScope: String { Self.userScope(userID) }

    /// Kennung fuer `WKWebsiteDataStore(forIdentifier:)`: eigene Cookies und Webdaten je (Nutzer, Hochschule); die
    /// UUID des Containers. Abmelden oder Loeschen raeumt genau diesen Speicher.
    public var websiteDataStoreID: UUID { identifier }

    /// Schluesselbund-Dienst der gemerkten Hochschul-Zugangsdaten (nur dieses Geraet, nicht synchronisiert)
    public static let keychainService = "de.uniflow.ai.university"

    /// Schluesselbund-Eintrag fuer Zugangsdaten dieses Containers, z. B. "u1a2b….hildesheim.cas.password" oder
    /// "u1a2b….hildesheim.learnweb.token"; nil fuer Dienste einer anderen Hochschule (`UniversityProfile.keychainAccount`)
    public func keychainAccount(service: String, field: String) -> String? {
        university.profile.keychainAccount(service: service, field: field, userScope: userScope)
    }

    /// "u" und 16 Hex-Zeichen aus SHA-256 der Nutzerkennung
    public static func userScope(_ userID: String) -> String {
        "u" + SolutionSHA256.hexString(Array(SolutionSHA256.hash(Data(("uniflow.user.v1\u{0}" + userID).utf8)).prefix(8)))
    }

    /// nie die Nutzer-ID ausgeben (Protokolle, Fehlermeldungen)
    public var description: String { "DataContainerKey(\(userScope), \(university.rawValue))" }

    static func uuid(from hash: [UInt8]) -> UUID {
        var b = Array(hash.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80                 // Version 8
        b[8] = (b[8] & 0x3F) | 0x80                 // Variante RFC 9562
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Inhalt von `container.json`: wem der Ordner gehoert.
public struct DataContainerManifest: Codable, Equatable, Sendable {
    public var format: Int
    /// Hochschule wie `settings.university` ("luh", "hildesheim")
    public var university: String
    /// `DataContainerKey.userScope` des Nutzers
    public var owner: String
    public var createdAt: String

    public init(format: Int = 1, university: String, owner: String, createdAt: String) {
        self.format = format
        self.university = university
        self.owner = owner
        self.createdAt = createdAt
    }
}

/// Fehler beim Oeffnen eines Containers, der nicht zu (Nutzer, Hochschule) passt oder sich nicht lesen laesst.
/// Eine abweichende Hochschule meldet `UniversityMismatch` (wie die Datenbank).
public enum DataContainerError: Error, Equatable, CustomStringConvertible {
    /// der Ordner gehoert einem anderen Nutzer
    case ownerMismatch
    /// `container.json` ist kaputt
    case unreadableManifest
    /// keine Kennzeichnung (mehr): der Container wurde geloescht ("Daten dieser Hochschule löschen", "Konto löschen")
    case missing

    public var description: String {
        switch self {
        case .ownerMismatch:
            return "Dieser Speicher gehört zu einem anderen Konto. Er wird nicht geöffnet, damit keine Daten gemischt werden."
        case .unreadableManifest:
            return "Die Kennzeichnung dieses Speichers ist beschädigt. Er wird nicht geöffnet, damit keine Daten gemischt werden."
        case .missing:
            return "Dieser Speicher wurde gelöscht. Es wird nichts mehr hineingeschrieben."
        }
    }
}

/// Ordner eines Containers. Darin dieselbe Aufteilung wie bisher in Application Support/UniFlow
/// (db, journal, sources, thumbs, cache, solutions, files, assets) und `StudIP` fuer die Stud.IP-Downloads.
public struct DataContainerLayout: Hashable, Sendable {
    /// Ordner aller Container (in der App Application Support/UniFlowContainers)
    public let base: URL
    public let identifier: UUID
    public let university: UniversityKey
    /// `DataContainerKey.userScope` des Besitzers
    public let ownerScope: String

    public static let manifestName = "container.json"

    public init(base: URL, key: DataContainerKey) {
        self.init(base: base, identifier: key.identifier, university: key.university, ownerScope: key.userScope)
    }

    init(base: URL, identifier: UUID, university: UniversityKey, ownerScope: String) {
        self.base = base
        self.identifier = identifier
        self.university = university
        self.ownerScope = ownerScope
    }

    public var root: URL { base.appendingPathComponent(identifier.uuidString, isDirectory: true) }
    public var databaseDirectory: URL { root.appendingPathComponent("db", isDirectory: true) }
    public var databaseURL: URL { databaseDirectory.appendingPathComponent("uniflow.sqlite") }
    /// Journal der Notizen (FileBlobStore-Wurzel, darin `spaces/<namensraum>/docs`)
    public var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    /// Loesungs-Bibliothek (SolutionLibrary)
    public var solutions: URL { root.appendingPathComponent("solutions", isDirectory: true) }
    /// Stud.IP-Downloads (ohne iCloud-Backup)
    public var studip: URL { root.appendingPathComponent("StudIP", isDirectory: true) }
    /// Learnweb-Downloads der Universitaet Hildesheim (ohne iCloud-Backup)
    public var learnweb: URL { root.appendingPathComponent("Learnweb", isDirectory: true) }
    public var manifestURL: URL { root.appendingPathComponent(Self.manifestName) }

    /// Dateiablage des lokalen Backends: Pfade in `files.local_path` relativ zum Container, nie ausserhalb
    public func files(tools: LocalDocumentTools = NoDocumentTools()) -> LocalFiles {
        LocalFiles(container: root, dataDirectory: "", tools: tools)
    }

    public func exists(fileManager fm: FileManager = .default) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: root.path, isDirectory: &dir) && dir.boolValue
    }

    /// Kennzeichnung lesen; nil, wenn es keine gibt
    public func manifest(fileManager fm: FileManager = .default) throws -> DataContainerManifest? {
        guard fm.fileExists(atPath: manifestURL.path) else { return nil }
        guard let data = fm.contents(atPath: manifestURL.path),
              let m = try? JSONDecoder().decode(DataContainerManifest.self, from: data) else {
            throw DataContainerError.unreadableManifest
        }
        return m
    }

    /// Prueft die Kennzeichnung gegen (Nutzer, Hochschule): andere Hochschule -> `UniversityMismatch`, anderer
    /// Nutzer -> `DataContainerError.ownerMismatch`. Ohne Kennzeichnung gibt es nichts zu pruefen.
    public func verify(fileManager fm: FileManager = .default) throws {
        guard let m = try manifest(fileManager: fm) else { return }
        guard m.university == university.rawValue else {
            throw UniversityMismatch(stored: m.university, expected: university.rawValue)
        }
        guard m.owner == ownerScope else { throw DataContainerError.ownerMismatch }
    }

    /// Streng wie `verify`, aber ohne Kennzeichnung ein Fehler (`DataContainerError.missing`): vor jedem Schreiben
    /// eines Abgleichs (`HildesheimSync`, `UniDownloads`). Wurde der Container waehrend eines Laufs geloescht, legt der
    /// Lauf ihn so nicht ohne Kennzeichnung neu an.
    public func verifyPresent(fileManager fm: FileManager = .default) throws {
        guard try manifest(fileManager: fm) != nil else { throw DataContainerError.missing }
        try verify(fileManager: fm)
    }

    /// Ordner anlegen und kennzeichnen bzw. eine vorhandene Kennzeichnung pruefen (vor dem ersten Oeffnen).
    public func prepare(clock: UniFlowClock = .system, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if try manifest(fileManager: fm) != nil {
            try verify(fileManager: fm)
            return
        }
        let m = DataContainerManifest(university: university.rawValue, owner: ownerScope, createdAt: clock.nowISO)
        let data = try JSONEncoder().encode(m)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Container entfernen: erst atomar in einen Papierkorb-Ordner umbenennen, dann loeschen. Bricht das Loeschen
    /// ab, raeumt `purgeTrash` den Rest beim naechsten Start weg; der Container selbst ist sofort verschwunden.
    public func remove(fileManager fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: root.path) else { return }
        let trash = base.appendingPathComponent(Self.trashPrefix + UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: root, to: trash)
        try? fm.removeItem(at: trash)
    }

    static let trashPrefix = ".geloescht-"

    /// Reste abgebrochener Loeschvorgaenge entfernen
    public static func purgeTrash(base: URL, fileManager fm: FileManager = .default) {
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(trashPrefix) {
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
    }

    /// Container aller Hochschulen eines Nutzers (fuer "Konto löschen")
    public static func all(base: URL, userID: String) -> [DataContainerLayout] {
        UniversityKey.allCases.map { DataContainerLayout(base: base, key: DataContainerKey(userID: userID, university: $0)) }
    }
}
