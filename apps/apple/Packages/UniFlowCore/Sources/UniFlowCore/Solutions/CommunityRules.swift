import Foundation

// Schluessel und Sichtbarkeitsregeln der Community als reine Funktionen (docs/LOESUNGEN-TEILEN.md, Abschnitt 7).
// Der Dienst (CloudKit in der App, spaeter tauschbar) speichert nur Schluessel, nie Kurs-IDs, Kursnamen oder
// Beitrittscodes im Klartext: Wer die Kurs-ID bzw. den Kursnamen oder den Code nicht kennt, kann den Schluessel nicht
// bilden und findet nichts. Entscheidung des Inhabers (26.10.2026): diese Kenntnis reicht als Berechtigung, eine
// Bestaetigung der Hochschule gibt es nicht.

/// Schluesselbildung (SHA-256, 64 Hexziffern). Die einzige Stelle, an der Kurs- und Gruppen-Schluessel entstehen;
/// ein anderer Dienst (V2) muss dieselben Schluessel bilden.
public enum CommunityKeys {
    /// Kurs-Schluessel aus Hochschule und Stud.IP- bzw. Learnweb-Kurs-ID. Nur Kursmitglieder kennen die Kurs-ID.
    public static func courseKey(university: String, courseID: String) -> String {
        SolutionSHA256.hex(Data(("uniflow.community.course.v1\u{0}" + university + "\u{0}" + courseID).utf8))
    }

    /// Kurs-Schluessel aus Hochschule und normalisiertem Kursnamen (eigene Dokumente ohne Kurs-ID: der Name des
    /// Moduls; beim Suchenden auch die Titel seiner Kurse). Eigener Namensraum, damit ein Name nie mit einer Kurs-ID
    /// zusammenfaellt. nil, wenn vom Namen nichts uebrig bleibt.
    public static func courseKey(university: String, courseName: String) -> String? {
        let name = normalizedCourseName(courseName)
        guard !name.isEmpty else { return nil }
        return SolutionSHA256.hex(Data(("uniflow.community.coursename.v1\u{0}" + university + "\u{0}" + name).utf8))
    }

    /// Kursname fuer den Schluessel: Kleinbuchstaben, Umlaute und Eszett ausgeschrieben (ae, oe, ue, ss), nur
    /// Buchstaben und Ziffern, dazwischen je ein Leerzeichen ("Analysis I (WS 2026/27)" und "analysis i - ws 2026/27"
    /// ergeben dasselbe).
    /// Ohne Foundation-Faltung, damit Kern und ein spaeterer Dienst gleich rechnen.
    public static func normalizedCourseName(_ raw: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in raw.lowercased() {
            let mapped: String
            switch ch {
            case "ä": mapped = "ae"
            case "ö": mapped = "oe"
            case "ü": mapped = "ue"
            case "ß": mapped = "ss"
            default: mapped = ch.isLetter || ch.isNumber ? String(ch) : ""
            }
            if mapped.isEmpty {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out += " " }
                pendingSpace = false
                out += mapped
            }
        }
        return out
    }

    /// Gruppen-Schluessel aus Hochschule und Beitrittscode (normalisiert).
    public static func groupKey(university: String, code: String) -> String {
        SolutionSHA256.hex(Data(("uniflow.community.group.v1\u{0}" + university + "\u{0}" + (normalizedGroupCode(code) ?? code)).utf8))
    }

    public static let groupCodeLength = 8
    /// ohne 0/O und 1/I, damit sich der Code vorlesen und abtippen laesst
    public static let groupCodeAlphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Zufaelliger Beitrittscode (8 Zeichen, kryptografisch sicherer Zufall).
    public static func randomGroupCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return randomGroupCode(using: &rng)
    }

    public static func randomGroupCode<R: RandomNumberGenerator>(using rng: inout R) -> String {
        String((0..<groupCodeLength).map { _ in groupCodeAlphabet.randomElement(using: &rng)! })
    }

    /// Eingabe eines Codes bereinigen: Grossbuchstaben, ohne Leerzeichen und Bindestriche; nil, wenn er nicht aus
    /// genau 8 Zeichen des Alphabets besteht (0/O und 1/I werden nicht geraten).
    public static func normalizedGroupCode(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == groupCodeLength, cleaned.allSatisfy({ groupCodeAlphabet.contains($0) }) else { return nil }
        return cleaned
    }

    public static func isHex64(_ s: String) -> Bool { SolutionValidator.isHex64(s) }
}

/// Kopfdaten eines Datensatzes beim Dienst (Datensatz `Solution`), unabhaengig vom Dienst.
public struct CommunityListing: Equatable, Sendable {
    public var solutionID: String
    public var fingerprint: String
    /// "luh", "hildesheim"
    public var university: String
    /// leer, wenn die Datei zu keinem Kurs gehoert
    public var courseKey: String
    public var visibility: CommunityVisibility
    /// leer ausser bei `.studyGroup`
    public var groupKey: String
    /// Pseudonym; leer = anonym
    public var displayName: String
    public var title: String
    public var pageCount: Int
    public var week: Int
    public var createdAt: String
    public var ownerRecordName: String
    public var withdrawn: Bool

    public init(solutionID: String, fingerprint: String, university: String, courseKey: String, visibility: CommunityVisibility,
                groupKey: String = "", displayName: String = "", title: String = "", pageCount: Int = 0, week: Int = 0,
                createdAt: String, ownerRecordName: String, withdrawn: Bool = false) {
        self.solutionID = solutionID
        self.fingerprint = fingerprint
        self.university = university
        self.courseKey = courseKey
        self.visibility = visibility
        self.groupKey = groupKey
        self.displayName = displayName
        self.title = title
        self.pageCount = pageCount
        self.week = week
        self.createdAt = createdAt
        self.ownerRecordName = ownerRecordName
        self.withdrawn = withdrawn
    }
}

/// Wer sucht: Hochschule, bekannte Kurs-Schluessel (Kurs-IDs, Kurstitel und Modulnamen der lokalen Datenbank),
/// Lerngruppen und Sperrliste (eigene Sperrliste plus die vom Inhaber gesperrten Nutzer, Datensatz `Ban`).
public struct CommunityViewer: Equatable, Sendable {
    public var university: String
    public var courseKeys: Set<String>
    public var groupKeys: Set<String>
    public var blockedOwners: Set<String>
    /// eigene Nutzerkennung beim Dienst (leer, wenn unbekannt)
    public var ownerRecordName: String

    public init(university: String, courseKeys: Set<String> = [], groupKeys: Set<String> = [], blockedOwners: Set<String> = [],
                ownerRecordName: String = "") {
        self.university = university
        self.courseKeys = courseKeys
        self.groupKeys = groupKeys
        self.blockedOwners = blockedOwners
        self.ownerRecordName = ownerRecordName
    }
}

/// Sichtbarkeitsregeln und Filter (reine Funktionen, im Kern getestet).
public enum CommunityRules {
    /// Darf der Suchende diesen Eintrag sehen? Nur eigene Hochschule, nicht zurueckgezogen, Besitzer nicht gesperrt;
    /// dann je nach Sichtbarkeit: Modul nur mit passendem Kurs-Schluessel, Lerngruppe nur mit passendem
    /// Gruppen-Schluessel, anonym fuer alle an der Hochschule. Eigene Eintraege sieht man immer (ausser zurueckgezogen).
    public static func isVisible(_ l: CommunityListing, to v: CommunityViewer) -> Bool {
        guard !l.withdrawn, l.university == v.university else { return false }
        if !v.ownerRecordName.isEmpty, l.ownerRecordName == v.ownerRecordName { return true }
        guard !v.blockedOwners.contains(l.ownerRecordName) else { return false }
        switch l.visibility {
        case .module: return !l.courseKey.isEmpty && v.courseKeys.contains(l.courseKey)
        case .studyGroup: return !l.groupKey.isEmpty && v.groupKeys.contains(l.groupKey)
        case .anonymous: return true
        }
    }

    /// Sichtbare Eintraege, neueste zuerst, ohne doppelte Loesungs-IDs.
    public static func visible(_ listings: [CommunityListing], to v: CommunityViewer) -> [CommunityListing] {
        var seen = Set<String>()
        return listings.filter { isVisible($0, to: v) && seen.insert($0.solutionID).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Pseudonym, wie es beim Dienst landet: bei "anonym" immer leer, sonst getrimmt und begrenzt.
    public static func effectiveDisplayName(_ name: String, visibility: CommunityVisibility) -> String {
        guard visibility != .anonymous else { return "" }
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SolutionLimits.maxDisplayName))
    }

    /// Optionen vor dem Veroeffentlichen pruefen (dieselben Regeln wie der Dienst).
    public static func validate(_ o: CommunityPublishOptions) throws {
        switch o.visibility {
        case .module:
            guard let k = o.courseKey, CommunityKeys.isHex64(k) else { throw CommunityServiceError.missingCourse }
        case .studyGroup:
            guard let k = o.groupKey, CommunityKeys.isHex64(k) else { throw CommunityServiceError.groupNotFound }
        case .anonymous:
            break
        }
        if let k = o.courseKey, !k.isEmpty, !CommunityKeys.isHex64(k) { throw CommunityServiceError.missingCourse }
    }

    public static let maxGroupName = 60

    /// Name einer Lerngruppe: getrimmt, nicht leer, hoechstens 60 Zeichen.
    public static func validGroupName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxGroupName else { return nil }
        return t
    }

    /// Nach Lehrwoche gruppieren (0 = ohne Woche zuletzt), innerhalb der Woche neueste zuerst.
    public static func byWeek(_ list: [CommunitySolutionSummary]) -> [(week: Int, solutions: [CommunitySolutionSummary])] {
        let groups = Dictionary(grouping: list, by: \.week)
        return groups.keys.sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }.map { ($0, groups[$0]!.sorted { $0.createdAt > $1.createdAt }) }
    }
}
