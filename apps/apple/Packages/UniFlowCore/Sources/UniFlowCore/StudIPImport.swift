import Foundation

/// Eine heruntergeladene Stud.IP-Datei im lokalen Verzeichnis der App.
public struct StudIPLocalEntry: Sendable, Equatable, Codable {
    public let id: String
    public let courseID: String
    public let courseTitle: String
    public let folderPath: String
    public let name: String
    public let size: Int
    public let changed: String
    public let mimeType: String?
    /// Pfad relativ zum Stud.IP-Ordner der App, z. B. "files/<id>/Folien.pdf".
    public let relativePath: String
    public let downloadedAt: String

    public init(id: String, courseID: String, courseTitle: String, folderPath: String, name: String, size: Int,
                changed: String, mimeType: String?, relativePath: String, downloadedAt: String) {
        self.id = id
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.folderPath = folderPath
        self.name = name
        self.size = size
        self.changed = changed
        self.mimeType = mimeType
        self.relativePath = relativePath
        self.downloadedAt = downloadedAt
    }

    public init(file f: StudIPFile, courseTitle: String, relativePath: String, downloadedAt: String) {
        self.init(id: f.id, courseID: f.courseID, courseTitle: courseTitle, folderPath: f.folderPath, name: f.name,
                  size: f.size, changed: f.changed, mimeType: f.mimeType, relativePath: relativePath, downloadedAt: downloadedAt)
    }
}

public struct StudIPImportPlan: Sendable, Equatable {
    /// neu in Stud.IP oder seit dem letzten Download geaendert (Groesse, Aenderungszeit) oder lokal verschwunden
    public var download: [StudIPFile] = []
    public var unchanged = 0
    /// in Stud.IP sichtbar, aber nicht herunterladbar (z. B. gesperrt)
    public var notDownloadable: [StudIPFile] = []
    /// lokal vorhanden, in einem abgeglichenen Kurs aber nicht mehr gefunden. Wird nur gemeldet, nie geloescht.
    public var goneRemotely: [String] = []

    public init() {}
}

public enum StudIPImport {
    /// Vergleicht die Dateiliste aus Stud.IP mit dem lokalen Stand. `checkedCourses` sind die Kurse, deren Liste in
    /// diesem Durchgang vollstaendig geladen wurde; nur dort gilt "nicht mehr gefunden".
    public static func plan(remote: [StudIPFile], local: [String: StudIPLocalEntry], checkedCourses: Set<String>,
                            fileExists: (String) -> Bool) -> StudIPImportPlan {
        var p = StudIPImportPlan()
        var remoteIDs = Set<String>()
        for f in remote {
            remoteIDs.insert(f.id)
            guard f.isDownloadable else { p.notDownloadable.append(f); continue }
            if let l = local[f.id], l.size == f.size, l.changed == f.changed, fileExists(l.relativePath) {
                p.unchanged += 1
            } else {
                p.download.append(f)
            }
        }
        p.goneRemotely = local.values
            .filter { checkedCourses.contains($0.courseID) && !remoteIDs.contains($0.id) }
            .map(\.id).sorted()
        return p
    }

    /// Dateiname ohne Pfadtrenner und Steuerzeichen, hoechstens 120 Zeichen, Endung bleibt erhalten.
    /// Zuerst NFC wie `safe_name` in app/studip_sync.py ("u" + U+0308 -> U+00FC, 46ec3d1): Dateinamen kommen teils
    /// zerlegt (Mac, Moodle). Der Name in der Datenbank bleibt wie geliefert (Python speichert f["name"] unveraendert).
    /// Auf Apple-Systemen zerlegt Foundation Namen in Datei-URLs ohnehin wieder (gemessen unter macOS:
    /// `appendingPathComponent` und die Datei auf APFS sind NFD); APFS vergleicht beide Formen gleich, die Datei wird
    /// also immer gefunden.
    public static func safeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var scalars = String.UnicodeScalarView()
        let underscore: Unicode.Scalar = "_"
        // erst Leerraum am Rand entfernen, sonst wird ein Zeilenumbruch zu "_"
        let nfc = name.precomposedStringWithCanonicalMapping
        for u in nfc.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars { scalars.append(forbidden.contains(u) ? underscore : u) }
        var s = String(scalars)
        while s.hasPrefix(".") { s.removeFirst() }      // keine versteckten Dateien, kein ".."
        if s.isEmpty { s = "datei" }
        if s.count > 120 {
            var ext = ""
            if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 11 { ext = String(s[dot...]) }
            s = String(s.prefix(120 - ext.count)) + ext
        }
        return s
    }

    /// Ablageort einer Datei: je Datei-ID ein eigener Ordner, damit gleich benannte Dateien sich nicht ueberschreiben.
    public static func relativePath(for f: StudIPFile) -> String {
        "files/\(safeFileName(f.id))/\(safeFileName(f.name))"
    }

    /// Vorauswahl beim ersten Abgleich: Kurse des juengsten Startsemesters (aeltere Semester bleiben aus).
    public static func defaultSelection(_ courses: [StudIPCourse]) -> Set<String> {
        guard let newest = courses.compactMap(\.semesterStart).max() else { return Set(courses.map(\.id)) }
        return Set(courses.filter { $0.semesterStart == newest }.map(\.id))
    }
}
