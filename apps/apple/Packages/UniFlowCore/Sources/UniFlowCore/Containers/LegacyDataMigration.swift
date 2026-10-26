import Foundation

/// Einmaliger Umzug der Daten aus der Zeit vor den Containern (alles LUH) in den LUH-Container des aktuellen Nutzers.
///
/// Bisher lagen die Daten ohne Container unter Application Support/UniFlow (Datenbank, Journal, Zwischenspeicher,
/// Loesungen, eigene Dokumente, Bilder) und Application Support/StudIP (Downloads). Sie werden **verschoben, nicht
/// kopiert**: Liegt noch kein Container vor, wird der ganze Ordner UniFlow in einem Schritt (atomar) zum Container
/// umbenannt, danach der Ordner StudIP in den Container. Sonst zieht jeder Eintrag einzeln um; was es am Ziel schon
/// gibt, bleibt am alten Ort liegen und wird gemeldet (nie ueberschrieben, nie geloescht).
///
/// Absturzsicher: Vor dem ersten Schritt steht in `legacy-move.json` (im Ordner aller Container) das Ziel mit
/// "running"; ein Neustart setzt mit demselben Ziel fort, auch wenn inzwischen jemand anderes angemeldet ist. Jeder
/// Schritt ist wiederholbar (umbenennen ist atomar, die Pfad-Umschreibung trifft nur alte Pfade). "done" steht erst
/// darin, wenn alles erledigt ist, auch die Schritte der App (`finishing`: Schluesselbund, Einstellungen).
///
/// In `files.local_path` (und `qis_documents.local_path`) standen Pfade relativ zum App-Container
/// ("Library/Application Support/UniFlow/files/…", "Library/Application Support/StudIP/files/…"); im Container sind sie
/// relativ zum Container ("files/…", "StudIP/files/…"). Notizen (Journal, Notizen in der Datenbank) bleiben unveraendert.
public enum LegacyDataMigration {
    /// Alte Orte relativ zu Application Support
    public struct Sources: Sendable {
        /// Application Support/UniFlow
        public let support: URL
        /// Application Support/StudIP
        public let studip: URL
        /// Anfang der alten Pfade in der Datenbank (relativ zum App-Container), mit "/" am Ende
        public let supportPrefix: String
        public let studipPrefix: String

        public init(support: URL, studip: URL, supportPrefix: String = "Library/Application Support/UniFlow/",
                    studipPrefix: String = "Library/Application Support/StudIP/") {
            self.support = support
            self.studip = studip
            self.supportPrefix = supportPrefix
            self.studipPrefix = studipPrefix
        }
    }

    /// Stand in `legacy-move.json`
    public struct State: Codable, Equatable, Sendable {
        /// "running" oder "done"
        public var state: String
        /// Ziel-Container (nil: es gab nichts umzuziehen)
        public var target: UUID?
        public var owner: String?
        public var university: String?
        public var startedAt: String
        public var finishedAt: String?
    }

    public struct Report: Equatable, Sendable {
        /// war schon erledigt (nichts getan)
        public var alreadyDone = false
        /// Ziel-Container; nil, wenn es keine alten Daten gab
        public var target: UUID?
        /// umgezogene Eintraege (relativ zu Application Support)
        public var moved: [String] = []
        /// am alten Ort geblieben, weil es am Ziel schon etwas gleichen Namens gab
        public var kept: [String] = []
        /// umgeschriebene Pfade in der Datenbank
        public var rewrittenPaths = 0
        /// Fortsetzung eines abgebrochenen Umzugs
        public var resumed = false

        /// Daten wurden (jetzt oder frueher) in einen Container verschoben
        public var movedData: Bool { target != nil }
    }

    /// Schritte (fuer Tests: Abbruch nach einem Schritt)
    public enum Step: String, Sendable { case support, manifest, studip, database, finishing }

    public static let stateFileName = "legacy-move.json"

    public static func stateURL(base: URL) -> URL { base.appendingPathComponent(stateFileName) }

    public static func state(base: URL, fileManager fm: FileManager = .default) -> State? {
        guard let d = fm.contents(atPath: stateURL(base: base).path) else { return nil }
        return try? JSONDecoder().decode(State.self, from: d)
    }

    /// Erledigt? (dann keine Pruefung der alten Orte mehr)
    public static func isDone(base: URL, fileManager fm: FileManager = .default) -> Bool {
        state(base: base, fileManager: fm)?.state == "done"
    }

    /// Gibt es alte Daten? Leere Ordner und versteckte Systemdateien zaehlen nicht.
    public static func hasLegacyData(_ sources: Sources, fileManager fm: FileManager = .default) -> Bool {
        [sources.support, sources.studip].contains { !visibleEntries($0, fm).isEmpty }
    }

    /// Umzug ausfuehren (synchron, vor dem ersten Oeffnen eines Containers). `owner`: aktueller Nutzer; sein
    /// LUH-Container ist das Ziel, ausser ein abgebrochener Umzug hat schon ein anderes Ziel festgelegt.
    /// `finishing` laeuft im Container vor dem Merker "done" (App: Schluesselbund, Einstellungen); es muss
    /// wiederholbar sein. `interrupt` nur fuer Tests (wirft nach dem genannten Schritt).
    @discardableResult
    public static func run(sources: Sources, base: URL, owner userID: String, clock: UniFlowClock = .system,
                           fileManager fm: FileManager = .default,
                           finishing: (DataContainerLayout) throws -> Void = { _ in },
                           interrupt: ((Step) throws -> Void)? = nil) throws -> Report {
        var report = Report()
        let previous = state(base: base, fileManager: fm)
        if previous?.state == "done" {
            report.alreadyDone = true
            report.target = previous?.target
            return report
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let layout: DataContainerLayout
        if let p = previous, p.state == "running", let target = p.target, let owner = p.owner,
           let uni = p.university.flatMap(UniversityKey.init(rawValue:)) {
            layout = DataContainerLayout(base: base, identifier: target, university: uni, ownerScope: owner)
            report.resumed = true
        } else {
            guard hasLegacyData(sources, fileManager: fm) else {
                // nichts umzuziehen (Neuinstallation): sofort erledigt
                try write(State(state: "done", target: nil, owner: nil, university: nil, startedAt: clock.nowISO,
                                finishedAt: clock.nowISO), base: base)
                return report
            }
            layout = DataContainerLayout(base: base, key: DataContainerKey(userID: userID, university: .luh))
            try write(State(state: "running", target: layout.identifier, owner: layout.ownerScope,
                            university: layout.university.rawValue, startedAt: clock.nowISO), base: base)
        }
        report.target = layout.identifier

        // 1. Application Support/UniFlow: als Ganzes zum Container, sonst Eintrag fuer Eintrag
        if fm.fileExists(atPath: sources.support.path) {
            if !fm.fileExists(atPath: layout.root.path) {
                try fm.moveItem(at: sources.support, to: layout.root)
                report.moved.append(sources.support.lastPathComponent)
            } else {
                try merge(from: sources.support, to: layout.root, name: sources.support.lastPathComponent, fm, &report)
            }
        }
        try interrupt?(.support)

        // 2. Kennzeichnung (Hochschule, Nutzer)
        try layout.prepare(clock: clock, fileManager: fm)
        try interrupt?(.manifest)

        // 3. Application Support/StudIP -> Container/StudIP
        if fm.fileExists(atPath: sources.studip.path) {
            try merge(from: sources.studip, to: layout.studip, name: sources.studip.lastPathComponent, fm, &report)
        }
        try interrupt?(.studip)

        // 4. Pfade in der Datenbank auf den Container umschreiben (wiederholbar: trifft nur alte Pfade)
        if fm.fileExists(atPath: layout.databaseURL.path) {
            report.rewrittenPaths = try rewritePaths(database: layout.databaseURL, sources: sources)
        }
        try interrupt?(.database)

        // 5. Schritte der App, dann erst "done"
        try finishing(layout)
        try interrupt?(.finishing)
        try write(State(state: "done", target: layout.identifier, owner: layout.ownerScope, university: layout.university.rawValue,
                        startedAt: previous?.startedAt ?? clock.nowISO, finishedAt: clock.nowISO), base: base)
        return report
    }

    /// Alte Pfade in `files.local_path` und `qis_documents.local_path` auf Pfade relativ zum Container umschreiben.
    /// Andere Pfade (absolute vom PC, schon umgeschriebene) bleiben, wie sie sind.
    static func rewritePaths(database: URL, sources: Sources) throws -> Int {
        let conn = try SQLiteConnection(path: database.path)
        defer { conn.close() }
        return try conn.transaction { c in
            var changed = 0
            for table in ["files", "qis_documents"] where try c.columnNames(table).contains("local_path") {
                for (old, new) in [(sources.supportPrefix, ""), (sources.studipPrefix, "StudIP/")] {
                    let n = old.count
                    changed += try c.execute("""
                        UPDATE \(table) SET local_path = ? || substr(local_path, ?)
                        WHERE substr(local_path, 1, ?) = ?
                        """, [.text(new), .integer(Int64(n + 1)), .integer(Int64(n)), .text(old)])
                }
            }
            return changed
        }
    }

    /// Eintrag verschieben; gibt es am Ziel schon einen Ordner, wird darin weiter zusammengefuehrt. Eine Datei, die
    /// es am Ziel schon gibt, bleibt am alten Ort (gemeldet). Leere alte Ordner verschwinden.
    static func merge(from source: URL, to target: URL, name: String, _ fm: FileManager, _ report: inout Report) throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return }
        var targetDir: ObjCBool = false
        if !fm.fileExists(atPath: target.path, isDirectory: &targetDir) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
            report.moved.append(name)
            return
        }
        guard isDir.boolValue, targetDir.boolValue else {
            report.kept.append(name)
            return
        }
        for child in try fm.contentsOfDirectory(atPath: source.path).sorted() {
            try merge(from: source.appendingPathComponent(child), to: target.appendingPathComponent(child),
                      name: name + "/" + child, fm, &report)
        }
        if visibleEntries(source, fm).isEmpty { try? fm.removeItem(at: source) }
    }

    private static func visibleEntries(_ dir: URL, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private static func write(_ s: State, base: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(s).write(to: stateURL(base: base), options: .atomic)
    }
}
