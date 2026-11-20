import Foundation

// Wissensbibliothek (Auftrag des Inhabers 20.11.2026, docs/STAND-MAC-SITZUNG.md): eine private, seitengenaue
// Lernbibliothek (Erklaerungen und Loesungen zu den eigenen Stud.IP-Unterlagen), die der Nutzer als Ordner oder ZIP in
// die App holt. Sie ist NUTZERDATEN: nichts davon liegt im Repo, im App-Bundle oder auf einem Server. Die App liest
// sie nur aus dem eigenen Container (`KnowledgeLibraryStore`).
//
// Aufbau des Ordners (MAC-ANLEITUNG.md der Bibliothek, Abschnitt 3):
//   katalog.json                                    Index aller Faecher und Einheiten
//   Bibliothek/<Fach>/README.md                     Fachueberblick
//   Bibliothek/<Fach>/Einheiten/<Semester>/<Rolle>/G0001/   eine Einheit
//   Bibliothek/<Fach>/Wochen/SoSe 2026/Woche 01/            nur Mathe I

/// Inhalt von `katalog.json`: Version, Stand (Datum `JJJJ-MM-TT`) und Faecher mit Einheiten.
public struct KnowledgeCatalog: Equatable, Sendable {
    public var version: Int
    /// Datum des Exports (`JJJJ-MM-TT`); ein neuerer Stand ersetzt beim Import den alten
    public var stand: String
    public var subjects: [KnowledgeSubject]

    public init(version: Int, stand: String, subjects: [KnowledgeSubject]) {
        self.version = version
        self.stand = stand
        self.subjects = subjects
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// keine JSON-Datei oder kein Objekt
        case unreadable
        /// `faecher` fehlt
        case noSubjects

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "katalog.json lässt sich nicht lesen."
            case .noSubjects: return "katalog.json enthält keine Fächer."
            }
        }
    }

    /// Tolerant lesen: unbekannte Felder werden ignoriert, fehlende Listen sind leer, Zahlen duerfen Text sein.
    /// Pfade und Namen werden in NFC gebracht (macOS/iOS liefern Dateinamen oft in NFD).
    public static func parse(_ data: Data) throws -> KnowledgeCatalog {
        guard let root = try? JSONValue.parse(data), case .object = root else { throw Failure.unreadable }
        guard let subjects = root["faecher"]?.array else { throw Failure.noSubjects }
        func text(_ v: JSONValue?) -> String? {
            if let s = v?.string { return s }
            if let i = v?.int { return String(i) }
            return nil
        }
        let version = root["version"]?.int ?? text(root["version"]).flatMap { Int($0) } ?? 0
        let stand = KnowledgeText.nfc(text(root["stand"]) ?? "")
        var out: [KnowledgeSubject] = []
        for s in subjects {
            guard let folder = text(s["ordner"]).map(KnowledgeText.nfc), !folder.isEmpty else { continue }
            var units: [KnowledgeUnit] = []
            for u in s["einheiten"]?.array ?? [] {
                guard let id = text(u["id"]).map(KnowledgeText.nfc), !id.isEmpty,
                      let path = text(u["pfad"]).map(KnowledgeText.cleanPath), !path.isEmpty else { continue }
                let files = (u["dateien"]?.array ?? []).compactMap { $0.string.map(KnowledgeText.nfc) }
                units.append(KnowledgeUnit(subject: folder, id: id, path: path, title: KnowledgeText.nfc(text(u["titel"]) ?? id), files: files))
            }
            out.append(KnowledgeSubject(folder: folder, units: units))
        }
        return KnowledgeCatalog(version: version, stand: stand, subjects: out)
    }

    public var units: [KnowledgeUnit] { subjects.flatMap(\.units) }
    public var unitCount: Int { subjects.reduce(0) { $0 + $1.units.count } }
    /// Dateien laut Katalog (mit den Pruefskripten)
    public var fileCount: Int { subjects.reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.files.count } } }

    public func subject(_ folder: String) -> KnowledgeSubject? {
        let f = KnowledgeText.nfc(folder)
        return subjects.first { $0.folder == f }
    }

    public func unit(key: String) -> KnowledgeUnit? {
        let k = KnowledgeText.nfc(key)
        for s in subjects { if let u = s.units.first(where: { $0.key == k }) { return u } }
        return nil
    }

    /// Einheit eines Fachs ueber ihre Kennung (`G0035`), fuer Verweise "identisch mit G0035"
    public func unit(subject folder: String, id: String) -> KnowledgeUnit? {
        subject(folder)?.units.first { $0.id == id }
    }
}

/// Ein Fach (`ordner` im Katalog).
public struct KnowledgeSubject: Equatable, Sendable, Identifiable {
    public var folder: String
    public var units: [KnowledgeUnit]
    public var id: String { folder }

    public init(folder: String, units: [KnowledgeUnit]) {
        self.folder = folder
        self.units = units
    }

    /// Name aus dem Ordner, falls der Fachueberblick keinen Titel hat: Bindestriche als Leerzeichen
    public var fallbackTitle: String { folder.replacingOccurrences(of: "-", with: " ") }

    /// Semester (aktuelles zuerst, dann das neueste) mit Rollen und Einheiten
    public var semesters: [KnowledgeSemesterGroup] {
        var bySemester: [String: [KnowledgeUnit]] = [:]
        for u in units { bySemester[u.semester, default: []].append(u) }
        return bySemester.map { sem, list in
            var byRole: [String: [KnowledgeUnit]] = [:]
            for u in list { byRole[u.role, default: []].append(u) }
            let roles = byRole.map { KnowledgeRoleGroup(role: $0.key, area: $0.value.first?.area ?? "", units: $0.value.sorted(by: KnowledgeUnit.naturalOrder)) }
                .sorted(by: KnowledgeRoleGroup.order)
            return KnowledgeSemesterGroup(semester: sem, roles: roles)
        }
        .sorted { KnowledgeSemester.sortKey($0.semester) > KnowledgeSemester.sortKey($1.semester) }
    }
}

public struct KnowledgeSemesterGroup: Equatable, Sendable, Identifiable {
    public var semester: String
    public var roles: [KnowledgeRoleGroup]
    public var id: String { semester }
    public var label: String { KnowledgeSemester.label(semester) }
    public var isCurrent: Bool { KnowledgeSemester.isCurrent(semester) }
    public var unitCount: Int { roles.reduce(0) { $0 + $1.units.count } }
}

public struct KnowledgeRoleGroup: Equatable, Sendable, Identifiable {
    public var role: String
    /// "Einheiten", "Wochen" oder "Folien"
    public var area: String
    public var units: [KnowledgeUnit]
    public var id: String { area + "/" + role }
    public var label: String { KnowledgeRole.label(role, area: area) }

    /// "direkt" (ohne Unterordner) zuerst, dann nach Namen
    static func order(_ a: KnowledgeRoleGroup, _ b: KnowledgeRoleGroup) -> Bool {
        let da = a.role == "direkt" || a.role.isEmpty, db = b.role == "direkt" || b.role.isEmpty
        if da != db { return da }
        return a.label.compare(b.label, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}

/// Eine Einheit (Ordner mit README, Erklaerung, Loesung).
public struct KnowledgeUnit: Equatable, Hashable, Sendable, Identifiable {
    /// Ordner des Fachs
    public var subject: String
    /// "G0034" bzw. "Woche 05" (nur innerhalb eines Fachs eindeutig)
    public var id: String
    /// relativ zur Wurzel der Bibliothek ("Bibliothek/<Fach>/Einheiten/…/G0034")
    public var path: String
    public var title: String
    /// Dateinamen laut Katalog (mit `_pruefung.py`)
    public var files: [String]

    public init(subject: String, id: String, path: String, title: String, files: [String]) {
        self.subject = subject
        self.id = id
        self.path = path
        self.title = title
        self.files = files
    }

    /// Eindeutiger Schluessel (MAC-ANLEITUNG 3): `ordner + "/" + id`; bei Mathe I (Wochen, Folien), deren Kennungen
    /// keine G-Nummern sind, der Pfad
    public var key: String { Self.isGID(id) ? subject + "/" + id : path }

    /// Teile des Pfads nach "Bibliothek/<Fach>/": [Bereich, Semester, Rolle …, Einheit]
    private var inner: [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: subject) else { return Array(parts.dropFirst(2)) }
        return Array(parts[(i + 1)...])
    }

    /// "Einheiten", "Wochen" oder "Folien"
    public var area: String { inner.first ?? "" }
    /// Semesterordner ("WiSe_2024_25", "SoSe 2026", "_aeltere-PC-Version")
    public var semester: String { inner.count >= 3 ? inner[1] : "" }
    /// Rolle ("Vorlesungsfolien", "Alte-Klausuren", "direkt"); leer bei Wochen und Folien (ohne Rollenordner)
    public var role: String { inner.count >= 4 ? inner[2..<(inner.count - 1)].joined(separator: "/") : "" }
    public var isCurrentSemester: Bool { KnowledgeSemester.isCurrent(semester) }

    /// Titel ohne die vorangestellte Kennung ("G0034: Klausur …" -> "Klausur …")
    public var shortTitle: String {
        let prefix = id + ":"
        guard title.hasPrefix(prefix) else { return title }
        return String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Dateien zum Anzeigen in fester Reihenfolge (README, 01-…, 02-…, weitere .md, Hilfsdateien), ohne Pruefskript
    public var visibleFiles: [String] { KnowledgeFileKind.ordered(files) }
    /// `_pruefung.py` vorhanden: "maschinell nachgeprüft" (das Skript wird nie gezeigt oder ausgefuehrt)
    public var hasCheckScript: Bool { files.contains { KnowledgeFileKind.of($0) == .checkScript } }

    static func isGID(_ id: String) -> Bool {
        id.count >= 2 && id.first == "G" && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// G0002 vor G0010, Woche 2 vor Woche 10
    public static func naturalOrder(_ a: KnowledgeUnit, _ b: KnowledgeUnit) -> Bool {
        a.id.compare(b.id, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}

/// Semesterordner lesbar machen und sortieren.
public enum KnowledgeSemester {
    /// Ordner des aktuellen Semesters. Trotz des Namens: Er enthaelt das laufende Semester des Inhabers
    /// (MAC-ANLEITUNG 3) und steht in der Anzeige zuerst.
    public static let currentFolder = "_aeltere-PC-Version"
    public static let currentName = "WiSe 2026/27"

    public static func isCurrent(_ raw: String) -> Bool { raw == currentFolder }

    /// "WiSe_2024_25" -> "WiSe 2024/25", "SoSe_2026" -> "SoSe 2026", aktueller Ordner -> "Aktuelles Semester (WiSe 2026/27)"
    public static func label(_ raw: String) -> String {
        if isCurrent(raw) { return "Aktuelles Semester (\(currentName))" }
        if raw.isEmpty { return "Ohne Semester" }
        let parts = raw.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        if parts.count == 3, parts[0] == "WiSe" { return "WiSe \(parts[1])/\(parts[2])" }
        return parts.joined(separator: " ")
    }

    /// Groesser = weiter oben: aktuelles Semester, dann nach Jahr (Wintersemester nach dem Sommer desselben Jahres)
    public static func sortKey(_ raw: String) -> Double {
        if isCurrent(raw) { return 100_000 }
        let parts = raw.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        guard parts.count >= 2, let year = Double(parts[1]) else { return 0 }
        return year + (parts[0] == "WiSe" ? 0.5 : 0)
    }
}

/// Rollenordner lesbar machen ("Alte-Klausuren" -> "Alte Klausuren", "Gruppenuebung" -> "Gruppenübung").
public enum KnowledgeRole {
    public static func label(_ raw: String, area: String) -> String {
        if raw.isEmpty { return area.isEmpty ? "Einheiten" : area }
        if raw == "direkt" { return "Ohne Unterordner" }
        return KnowledgeText.umlauts(raw.replacingOccurrences(of: "-", with: " "))
    }
}

/// Art einer Datei in einer Einheit.
public enum KnowledgeFileKind: Int, Equatable, Sendable, Comparable {
    case readme = 0
    case explained = 1
    case solved = 2
    case markdown = 3
    case plainText = 4
    /// `_pruefung.py`: nie zeigen, nie ausfuehren
    case checkScript = 5
    case other = 6

    public static func < (a: KnowledgeFileKind, b: KnowledgeFileKind) -> Bool { a.rawValue < b.rawValue }

    public static let textExtensions: Set<String> = ["c", "h", "cpp", "java", "csv", "json", "txt", "pf", "py", "m", "tex", "yaml", "yml", "xml", "vhd", "asm"]

    public static func of(_ name: String) -> KnowledgeFileKind {
        let lower = name.lowercased()
        // `_pruefung.py`, auch `_pruefung_F01.py` (Mathe-I-Folien): Pruefskripte des PCs, nie zeigen oder ausfuehren
        if lower.hasPrefix("_pruefung"), lower.hasSuffix(".py") { return .checkScript }
        let ext = (lower as NSString).pathExtension
        if ext == "md" {
            if lower == "readme.md" { return .readme }
            if lower.hasPrefix("01-") && lower.contains("erklaert") { return .explained }
            if lower.hasPrefix("02-") && lower.contains("geloest") { return .solved }
            return .markdown
        }
        return textExtensions.contains(ext) ? .plainText : .other
    }

    public var isMarkdown: Bool { self == .readme || self == .explained || self == .solved || self == .markdown }

    /// sichtbare Dateien: README, 01-, 02-, weitere .md, Hilfsdateien; ohne Pruefskript und ohne Unbekanntes
    public static func ordered(_ files: [String]) -> [String] {
        files.filter { let k = of($0); return k != .checkScript && k != .other }
            .sorted { a, b in
                let ka = of(a), kb = of(b)
                if ka != kb { return ka < kb }
                return a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
            }
    }

    /// Name im Reiter: "Überblick", "Erklärung", "Lösungen", "Vorlesung erklärt", "Übungsblatt 13 gelöst"
    public static func displayName(_ name: String) -> String {
        let lower = name.lowercased()
        switch lower {
        case "readme.md": return "Überblick"
        case "01-erklaert.md": return "Erklärung"
        case "02-geloest.md": return "Lösungen"
        default: break
        }
        guard (lower as NSString).pathExtension == "md" else { return name }
        var base = (name as NSString).deletingPathExtension
        if base.count > 3, base.prefix(2).allSatisfy(\.isNumber), base.dropFirst(2).first == "-" { base = String(base.dropFirst(3)) }
        if base.hasPrefix("_") { base.removeFirst() }
        return KnowledgeText.umlauts(base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
    }
}

/// Textwerkzeuge: Unicode-Normalform, Umlaute aus Ordnernamen, Suchform.
public enum KnowledgeText {
    /// NFC (Dateinamen unter macOS/iOS kommen oft in NFD)
    public static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// NFC und Zeilenenden "\n" (CRLF und einzelnes CR werden zu LF)
    public static func lines(_ s: String) -> String {
        nfc(s).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Pfad aus dem Katalog: NFC, "/" als Trenner, ohne fuehrendes "./" oder "/", ohne ".."
    public static func cleanPath(_ raw: String) -> String {
        let parts = nfc(raw).replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }

    /// "Uebung" -> "Übung" u. a. (nur fuer Anzeigenamen aus Ordnern und Dateien, nie fuer Inhalte)
    public static func umlauts(_ s: String) -> String {
        var t = s
        for (a, b) in [("Uebung", "Übung"), ("uebung", "übung"), ("Hoersaal", "Hörsaal"), ("Loesung", "Lösung"), ("loesung", "lösung"),
                       ("Pruefung", "Prüfung"), ("pruefung", "prüfung"), ("blaetter", "blätter"), ("Blaetter", "Blätter"),
                       ("erklaert", "erklärt"), ("geloest", "gelöst"), ("Grossklausur", "Großklausur"), ("GUe", "GÜ"), ("HUe", "HÜ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// Suchform: NFC und klein (Laenge bleibt fuer deutsche Texte gleich; Umlaute bleiben Umlaute)
    public static func searchForm(_ s: String) -> String { nfc(s).lowercased() }

    /// Vergleichsform fuer Dateititel: NFC, klein, `_`/`-`/Leerraum als ein Leerzeichen
    public static func titleForm(_ s: String) -> String {
        var out = ""
        var space = false
        for ch in nfc(s).lowercased() {
            if ch == "_" || ch == "-" || ch.isWhitespace {
                if !out.isEmpty { space = true }
                continue
            }
            if space { out.append(" "); space = false }
            out.append(ch)
        }
        return out
    }
}
