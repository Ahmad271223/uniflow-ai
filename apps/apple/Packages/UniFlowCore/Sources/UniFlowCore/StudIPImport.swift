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

// Welche Dateien geladen werden, entscheidet die Datenbank (`UniStore.storeFiles`); "in Stud.IP nicht mehr
// vorhanden" ebenso (`StudIPLibrary.goneRemotely`). Die frueheren eigenen Regeln (`plan`, nach Groesse und
// Aenderungstext aus index.json) gibt es nicht mehr.

public enum StudIPImport {
    /// Auswahl der abzugleichenden Kurse nach einer Kursliste aus Stud.IP
    public struct Selection: Sendable, Equatable {
        /// abzugleichende Kurse
        public var selected: Set<String>
        /// alle Kurse, die der Abgleich je gesehen hat (abgewaehlt = bekannt und nicht ausgewaehlt)
        public var known: Set<String>
        /// neue Kurse aelterer Semester, die nicht von selbst dazukamen ("n neue Kurse – auswählen")
        public var newUnselected: [StudIPCourse]
    }

    /// Kursauswahl wie run_sync (Python gleicht alle Kurse ab, gefiltert nur mit SEMESTER_FILTER), aber mit Wahl:
    /// - erster Abgleich (`known` nil): Vorauswahl des juengsten Semesters (`defaultSelection`), eine schon getroffene
    ///   Auswahl bleibt; alle Kurse gelten danach als bekannt
    /// - danach kommen neue Kurse des juengsten Semesters von selbst dazu (spaeter belegt, naechstes Semester), neue
    ///   aeltere werden nur gemeldet; abgewaehlte bleiben abgewaehlt, eine leere Auswahl bleibt leer
    /// Vorher legte nur der erste Abgleich die Auswahl fest: neue Kurse kamen still nie an, und wer alles abwaehlte,
    /// bekam beim naechsten Lauf wieder die Vorauswahl.
    public static func selection(courses: [StudIPCourse], selected: Set<String>, known: Set<String>?) -> Selection {
        let ids = Set(courses.map(\.id))
        guard let known else {
            return Selection(selected: selected.isEmpty ? defaultSelection(courses) : selected, known: ids, newUnselected: [])
        }
        let newest = courses.compactMap(\.semesterStart).max()
        var out = Selection(selected: selected, known: known.union(ids), newUnselected: [])
        for c in courses where !known.contains(c.id) {
            if newest == nil || c.semesterStart == nil || c.semesterStart == newest { out.selected.insert(c.id) } else { out.newUnselected.append(c) }
        }
        return out
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
