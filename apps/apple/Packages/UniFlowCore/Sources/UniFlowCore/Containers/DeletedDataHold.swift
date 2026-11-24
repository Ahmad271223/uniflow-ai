import Foundation

// "Konto löschen" mit 30 Tagen Aufbewahrung auf dem Geraet (24.11.2026, nach dem versehentlichen Loeschen auf dem iPad
// des Inhabers in der Nacht zuvor): Die Container eines Kontos werden nicht sofort entfernt, sondern in einen eigenen
// Bereich neben den Containern verschoben (Application Support/UniFlowDeleted/<eintrag>/), ohne iCloud-Backup und ohne
// Zugriff fuer die App, bis dieselbe Apple-ID sich wieder anmeldet und "Daten zurückholen" waehlt. Nach 30 Tagen
// entfernt `purgeExpired` den Eintrag endgueltig (beim Start der App). "Auch sofort endgültig löschen" in der
// Rueckfrage umgeht den Bereich ganz (dann wie vorher `DataContainerLayout.remove`).
//
// Was hier liegt: nur die Ordner der Container (Datenbank, Notizen, eigene Dokumente, Downloads) und je Container die
// Einstellungen als Datei. Schluesselbund (Uni-Passwoerter, Sitzungen, Schluessel), Webdaten und Cookies loescht
// "Konto löschen" weiterhin sofort. Kennung des Besitzers ist nur `DataContainerKey.userScope` (Hash), nie die Apple-ID.

/// Ein Eintrag im Aufbewahrungsbereich: die Container eines Kontos von einem Loeschvorgang
public struct DeletedDataHold: Equatable, Sendable {
    /// so lange bleibt ein Eintrag liegen (Datenschutzerklaerung Abschnitt 15, Rueckfrage "Konto löschen")
    public static let retentionDays = 30
    public static var retention: TimeInterval { TimeInterval(retentionDays) * 24 * 3600 }
    public static let manifestName = "eintrag.json"
    /// Name des Bereichs neben `UniFlowContainers`
    public static let folderName = "UniFlowDeleted"

    public struct Container: Codable, Equatable, Sendable {
        /// `DataContainerLayout.identifier` (= Ordnername im Bereich und unter UniFlowContainers)
        public var identifier: String
        /// `UniversityKey.rawValue`
        public var university: String
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var format = 1
        /// `DataContainerKey.userScope` des Besitzers
        public var owner: String
        /// ISO 8601 (UTC)
        public var deletedAt: String
        public var expiresAt: String
        public var containers: [Container]
    }

    /// Ordner des Eintrags
    public let folder: URL
    public let manifest: Manifest

    public var owner: String { manifest.owner }
    public var deletedAt: Date? { Self.iso.date(from: manifest.deletedAt) }
    public var expiresAt: Date? { Self.iso.date(from: manifest.expiresAt) }

    public func isExpired(at now: Date) -> Bool {
        guard let e = expiresAt else { return true }
        return now >= e
    }

    /// Ordner eines Containers im Eintrag
    public func containerFolder(_ c: Container) -> URL { folder.appendingPathComponent(c.identifier, isDirectory: true) }

    /// Datei mit den Einstellungen (UserDefaults-Suite) eines Containers
    public func settingsFile(_ c: Container) -> URL { folder.appendingPathComponent(c.identifier + ".einstellungen.plist") }

    /// Bereich neben dem Ordner der Container (`base` = Application Support/UniFlowContainers)
    public static func area(besides base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: Ablegen

    /// Die vorhandenen Container verschieben (atomar je Ordner, derselbe Datentraeger) und den Eintrag kennzeichnen.
    /// Container ohne Ordner fehlen im Eintrag; ohne einen einzigen gibt es keinen Eintrag (nil).
    /// `settings`: je Container-Kennung die Einstellungen (Plist-faehig), die mit abgelegt werden.
    @discardableResult
    public static func store(_ layouts: [DataContainerLayout], owner: String, in area: URL, settings: [UUID: [String: Any]] = [:],
                             clock: UniFlowClock = .system, fileManager fm: FileManager = .default) throws -> DeletedDataHold? {
        let present = layouts.filter { $0.exists(fileManager: fm) }
        guard !present.isEmpty else { return nil }
        try prepareArea(area, fileManager: fm)
        let now = clock.now
        let folder = area.appendingPathComponent(owner + "-" + stamp.string(from: now) + "-" + String(UUID().uuidString.prefix(8)),
                                                 isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? DataContainerLayout.setExcludedFromBackup(folder)
        var moved: [Container] = []
        for layout in present {
            let target = folder.appendingPathComponent(layout.identifier.uuidString, isDirectory: true)
            try fm.moveItem(at: layout.root, to: target)
            // die Container selbst sind ausdruecklich im Backup (`ContainerManager.protect`): hier nicht mehr
            try? DataContainerLayout.setExcludedFromBackup(target)
            let c = Container(identifier: layout.identifier.uuidString, university: layout.university.rawValue)
            moved.append(c)
            if let s = settings[layout.identifier], !s.isEmpty,
               let data = try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0) {
                try? data.write(to: folder.appendingPathComponent(c.identifier + ".einstellungen.plist"), options: .atomic)
            }
        }
        let m = Manifest(owner: owner, deletedAt: iso.string(from: now), expiresAt: iso.string(from: now.addingTimeInterval(retention)),
                         containers: moved)
        try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(manifestName), options: .atomic)
        return DeletedDataHold(folder: folder, manifest: m)
    }

    private static func prepareArea(_ area: URL, fileManager fm: FileManager) throws {
        try fm.createDirectory(at: area, withIntermediateDirectories: true)
        try? DataContainerLayout.setExcludedFromBackup(area)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: area.path)
        #endif
    }

    // MARK: Lesen

    /// Eintraege eines Besitzers, die noch nicht abgelaufen sind, der neueste zuerst
    public static func all(in area: URL, owner: String, clock: UniFlowClock = .system,
                           fileManager fm: FileManager = .default) -> [DeletedDataHold] {
        entries(in: area, fileManager: fm)
            .filter { $0.owner == owner && !$0.isExpired(at: clock.now) }
            .sorted { $0.manifest.deletedAt > $1.manifest.deletedAt }
    }

    private static func entries(in area: URL, fileManager fm: FileManager) -> [DeletedDataHold] {
        ((try? fm.contentsOfDirectory(atPath: area.path)) ?? []).sorted().compactMap { name in
            let folder = area.appendingPathComponent(name, isDirectory: true)
            guard let data = fm.contents(atPath: folder.appendingPathComponent(manifestName).path),
                  let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
            return DeletedDataHold(folder: folder, manifest: m)
        }
    }

    // MARK: Endgueltig loeschen

    /// Abgelaufene Eintraege entfernen; dazu Ordner ohne lesbare Kennzeichnung (abgebrochenes Ablegen), sobald sie
    /// laenger als die Frist liegen. Rueckgabe: Zahl der entfernten Eintraege.
    @discardableResult
    public static func purgeExpired(in area: URL, clock: UniFlowClock = .system, fileManager fm: FileManager = .default) -> Int {
        let now = clock.now
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: area.path)) ?? [] {
            let folder = area.appendingPathComponent(name, isDirectory: true)
            let expired: Bool
            if let data = fm.contents(atPath: folder.appendingPathComponent(manifestName).path),
               let m = try? JSONDecoder().decode(Manifest.self, from: data) {
                expired = DeletedDataHold(folder: folder, manifest: m).isExpired(at: now)
            } else {
                let created = (try? fm.attributesOfItem(atPath: folder.path)[.creationDate] as? Date) ?? .distantPast
                expired = now.timeIntervalSince(created) >= retention
            }
            if expired, (try? fm.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }

    /// Diesen Eintrag sofort endgueltig loeschen ("Aufbewahrte Daten jetzt löschen")
    public func discard(fileManager fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: folder.path) else { return }
        try fm.removeItem(at: folder)
    }

    // MARK: Zurueckholen

    /// Die Container des Eintrags zurueck nach `base` verschieben. Ein Container gleicher Kennung, der dort inzwischen
    /// liegt (neu angelegt nach der neuen Anmeldung), geht nicht verloren: er kommt vorher als eigener Eintrag in den
    /// Bereich (`store`). Danach ist dieser Eintrag leer und wird entfernt.
    /// - Returns: die zurueckgeholten Container (Kennung) mit ihren Einstellungen (leer, wenn keine abgelegt waren)
    public func restore(into base: URL, clock: UniFlowClock = .system,
                        fileManager fm: FileManager = .default) throws -> [(identifier: UUID, settings: [String: Any])] {
        let area = folder.deletingLastPathComponent()
        let containers = manifest.containers.compactMap { c -> (Container, UUID, UniversityKey)? in
            guard let id = UUID(uuidString: c.identifier), let uni = UniversityKey(rawValue: c.university),
                  fm.fileExists(atPath: containerFolder(c).path) else { return nil }
            return (c, id, uni)
        }
        let occupied = containers.map { DataContainerLayout(base: base, identifier: $0.1, university: $0.2, ownerScope: owner) }
            .filter { $0.exists(fileManager: fm) }
        if !occupied.isEmpty { try Self.store(occupied, owner: owner, in: area, clock: clock, fileManager: fm) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var out: [(identifier: UUID, settings: [String: Any])] = []
        for (c, id, _) in containers {
            try fm.moveItem(at: containerFolder(c), to: base.appendingPathComponent(c.identifier, isDirectory: true))
            var settings: [String: Any] = [:]
            if let data = fm.contents(atPath: settingsFile(c).path),
               let s = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                settings = s
            }
            out.append((id, settings))
        }
        try? fm.removeItem(at: folder)
        return out
    }

    // MARK: Datumsformate

    static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static var stamp: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }
}
