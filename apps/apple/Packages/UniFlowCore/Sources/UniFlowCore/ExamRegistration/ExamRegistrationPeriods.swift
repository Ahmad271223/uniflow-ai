import Foundation

// Pruefungsanmeldung (Entscheidung des Inhabers 05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Meldezeitraeume der
// LUH je Studiengang aus der Datendatei (packages/shared-contracts/exam-registration-luh.json, eingebettet als
// `ExamRegistrationData`), Zuordnung Studiengang -> Terminseite des Pruefungsamts und Phase des Fensters je Tag.
// Dieselben Regeln wie app/exam_registration.py (Faelle fixtures/exam-registration/period-cases.json). Ohne sichere
// Daten (Studiengang nicht geprueft, Daten zu alt) gibt es kein Fenster, nur den Link - es wird nie geraten.

/// Ein Zeitraum einer Terminseite ("Meldezeitraum für alle anderen Prüfungsformen" vom ... bis ...)
public struct ExamRegistrationPeriod: Sendable, Equatable {
    /// meldung | pruefung | bewertung | vbp_meldung | vbp_pruefung | vbp_bewertung
    public let kind: String
    /// 1 oder 2 (Variante 2: zweiter Melde- und Pruefungszeitraum)
    public let n: Int
    public let label: String
    /// "YYYY-MM-DD"
    public let start: String
    public let end: String

    var json: JSONValue {
        ["kind": .string(kind), "n": .number(Double(n)), "label": .string(label), "start": .string(start), "end": .string(end)]
    }
}

/// Terminseite eines Studiengangs; `table` nil = nur Link (nicht geprueft)
public struct ExamRegistrationProgram: Sendable, Equatable {
    public let slug: String
    public let url: String
    public let table: String?
    public let variant: String?
    public let checkedAt: String?
}

/// Fenster der Art `kind`, das heute laeuft, sonst das naechste (`window_state` in Python)
public struct ExamRegistrationWindow: Sendable, Equatable {
    public enum Phase: String, Sendable { case open, soon, later }
    public let term: String
    public let period: ExamRegistrationPeriod
    public let phase: Phase
    /// Tage bis zum Ende (0 = heute letzter Tag)
    public let daysLeft: Int
    /// Tage bis zum Beginn (0 = laeuft schon)
    public let daysUntil: Int

    public var json: JSONValue {
        ["term": .string(term), "kind": .string(period.kind), "n": .number(Double(period.n)), "label": .string(period.label),
         "start": .string(period.start), "end": .string(period.end), "phase": .string(phase.rawValue),
         "days_left": .number(Double(daysLeft)), "days_until": .number(Double(daysUntil))]
    }
}

/// Die Daten der LUH (Terminseiten, Regeln, QIS-Menue)
public struct ExamRegistrationPeriods: Sendable {
    /// Fenster, das in hoechstens so vielen Tagen beginnt, ist "soon" (Karte auf der Uebersicht)
    public static let soonDays = 7

    public let university: String
    public let checkedAt: String?
    public let generalURL: String
    public let generalTitle: String
    public let qisMenu: String
    /// Rucktrittsregeln als Text ("Klausur ...: Abmeldung bis 7 Tage vor dem Prüfungstermin im QIS.")
    public let rules: [(form: String, days: Int?, text: String)]
    public let programs: [ExamRegistrationProgram]
    let tables: [String: [(term: String, periods: [ExamRegistrationPeriod])]]

    /// Eingebettete Daten der LUH (einmal gelesen)
    public static let luh: ExamRegistrationPeriods = {
        // die Datei prueft der Erzeuger; scheitert das Lesen trotzdem, gibt es nur Links
        (try? ExamRegistrationPeriods(json: JSONValue.parse(ExamRegistrationData.json))) ?? ExamRegistrationPeriods.empty
    }()

    static let empty = ExamRegistrationPeriods(university: "luh", checkedAt: nil,
                                               generalURL: "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/pruefungsanmeldung",
                                               generalTitle: "Prüfungsanmeldung", qisMenu: UniversityProfile.luhQISStart.absoluteString,
                                               rules: [], programs: [], tables: [:])

    init(university: String, checkedAt: String?, generalURL: String, generalTitle: String, qisMenu: String,
         rules: [(form: String, days: Int?, text: String)], programs: [ExamRegistrationProgram],
         tables: [String: [(term: String, periods: [ExamRegistrationPeriod])]]) {
        self.university = university
        self.checkedAt = checkedAt
        self.generalURL = generalURL
        self.generalTitle = generalTitle
        self.qisMenu = qisMenu
        self.rules = rules
        self.programs = programs
        self.tables = tables
    }

    public init(json d: JSONValue) {
        var tables: [String: [(term: String, periods: [ExamRegistrationPeriod])]] = [:]
        for (key, t) in d["tables"]?.object ?? [:] {
            tables[key] = (t["terms"]?.array ?? []).compactMap { term in
                guard let name = term["term"]?.string else { return nil }
                let periods = (term["periods"]?.array ?? []).compactMap { p -> ExamRegistrationPeriod? in
                    guard let kind = p["kind"]?.string, let s = p["start"]?.string, let e = p["end"]?.string,
                          BerlinClock.parseISODate(s) != nil, BerlinClock.parseISODate(e) != nil else { return nil }
                    return ExamRegistrationPeriod(kind: kind, n: p["n"]?.int ?? 1, label: p["label"]?.string ?? "", start: s, end: e)
                }
                return (name, periods)
            }
        }
        self.init(university: d["university"]?.string ?? "luh", checkedAt: d["checked_at"]?.string,
                  generalURL: d["general"]?["url"]?.string ?? ExamRegistrationPeriods.empty.generalURL,
                  generalTitle: d["general"]?["title"]?.string ?? "Prüfungsanmeldung",
                  qisMenu: d["qis_menu"]?.string ?? UniversityProfile.luhQISStart.absoluteString,
                  rules: (d["rules"]?.array ?? []).map { r in (r["form"]?.string ?? "", r["withdraw_days_before"]?.int, r["text"]?.string ?? "") },
                  programs: (d["programs"]?.array ?? []).compactMap { p in
                      guard let slug = p["slug"]?.string, let url = p["url"]?.string else { return nil }
                      return ExamRegistrationProgram(slug: slug, url: url, table: p["table"]?.string, variant: p["variant"]?.string,
                                                     checkedAt: p["checked_at"]?.string)
                  },
                  tables: tables)
    }

    // MARK: Studiengang -> Terminseite

    /// klein, Umlaute ausgeschrieben (`fold`)
    static func fold(_ text: String) -> String {
        var out = ""
        for ch in text.precomposedStringWithCanonicalMapping.lowercased() {
            switch ch {
            case "ä": out += "ae"
            case "ö": out += "oe"
            case "ü": out += "ue"
            case "ß": out += "ss"
            default: out.append(ch)
            }
        }
        return out
    }

    /// "Geodäsie und Geoinformatik" -> "geodaesie-und-geoinformatik"
    public static func slugify(_ text: String) -> String {
        var out = ""
        var dash = false
        for u in fold(text).unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) {
                if dash && !out.isEmpty { out += "-" }
                dash = false
                out.unicodeScalars.append(u)
            } else {
                dash = true
            }
        }
        return out
    }

    /// "Technische Informatik (PO-Version 2017)" -> "Technische Informatik"
    public static func programName(_ name: String) -> String {
        let cut = name.firstIndex(of: "(").map { String(name[..<$0]) } ?? name
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let degreeSlugs: Set<String> = ["bsc", "msc", "ba", "ma", "med", "bed", "llb", "llm"]
    static let bachelor = ["bsc", "ba", "bed"]
    static let master = ["msc", "ma", "med"]

    /// "B.Sc." -> ["bsc"]; ohne Angabe "Bachelor"/"Master" im Text -> alle passenden; sonst []
    public static func degreeSlugs(_ degree: String?, text: String = "") -> [String] {
        let d = String(fold(degree ?? "").unicodeScalars.filter { ("a"..."z").contains($0) }.map(Character.init))
        if degreeSlugs.contains(d) { return [d] }
        for (word, slugs) in [("bachelor", bachelor), ("master", master)] where d.contains(word) || fold(text).contains(word) {
            return slugs
        }
        return []
    }

    /// Terminseite des Studiengangs; nil ohne oder ohne eindeutigen Treffer
    public func program(name: String?, degree: String?) -> ExamRegistrationProgram? {
        let base = Self.slugify(Self.programName(name ?? ""))
        guard !base.isEmpty else { return nil }
        var cands = Self.degreeSlugs(degree, text: name ?? "")
        if cands.isEmpty { cands = Self.degreeSlugs.sorted() }
        let wanted = Set(cands.map { base + "-" + $0 })
        let hits = programs.filter { wanted.contains($0.slug) }
        return hits.count == 1 ? hits[0] : nil
    }

    // MARK: Fenster

    func table(_ program: ExamRegistrationProgram?) -> [(term: String, periods: [ExamRegistrationPeriod])]? {
        guard let key = program?.table else { return nil }
        return tables[key]
    }

    /// Fenster der Art `kind` ("meldung", "vbp_meldung"), das am Tag `today` laeuft, sonst das naechste; nil ohne Daten
    public func window(_ program: ExamRegistrationProgram?, today: String, kind: String = "meldung") -> ExamRegistrationWindow? {
        guard let table = table(program), let t = BerlinClock.parseISODate(today) else { return nil }
        var cands: [(start: Int, end: Int, term: String, period: ExamRegistrationPeriod)] = []
        for term in table {
            for p in term.periods where p.kind == kind {
                guard let s = BerlinClock.parseISODate(p.start), let e = BerlinClock.parseISODate(p.end) else { continue }
                cands.append((s, e, term.term, p))
            }
        }
        cands = cands.enumerated().sorted { ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset) }
            .map(\.element)
        if let c = cands.first(where: { $0.start <= t && t <= $0.end }) {
            return ExamRegistrationWindow(term: c.term, period: c.period, phase: .open, daysLeft: c.end - t, daysUntil: 0)
        }
        if let c = cands.first(where: { $0.start > t }) {
            return ExamRegistrationWindow(term: c.term, period: c.period, phase: c.start - t <= Self.soonDays ? .soon : .later,
                                          daysLeft: c.end - t, daysUntil: c.start - t)
        }
        return nil
    }

    /// Alle Zeitraeume eines Semesters (Anzeige)
    public func periods(_ program: ExamRegistrationProgram?, term: String?) -> [ExamRegistrationPeriod] {
        guard let term, let table = table(program) else { return [] }
        return table.first { $0.term == term }?.periods ?? []
    }
}
