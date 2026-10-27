import Foundation

// Abgleich im Hintergrund (S8, docs/STUDIFLOW-PLAN.md "Abgleich um 8, 15 und 20 Uhr", docs/AUFGABENTEILUNG-APPLE-PC.md
// M12): der plattformunabhaengige Teil. Die App (UniFlow/Services/BackgroundSync.swift) meldet die Aufgaben beim
// BGTaskScheduler an, startet den Abgleich des offenen Containers und zeigt lokale Benachrichtigungen; hier stehen die
// Regeln, die sich ohne iOS pruefen lassen:
// - naechster Termin 8:00, 15:00 oder 20:00 Ortszeit (`BackgroundSchedule`; iOS behandelt ihn nur als "fruehestens")
// - wann ein Lauf ausfaellt (`BackgroundSyncGate`: aus, kein passender Container, Wechsel, Abgleich laeuft schon, keine
//   gueltige Sitzung)
// - Texte der Benachrichtigungen ohne Dateinamen (`BackgroundNotice`) und "Bitte bei … anmelden" nur einmal je Ablauf
//   der Sitzung (`BackgroundSyncState`, in den Einstellungen des Containers, also getrennt je Nutzer und Hochschule)
// - genau ein Abschluss je Aufgabe, auch wenn iOS die Zeit vorher beendet (`BackgroundTaskRun`)

/// Naechster Termin des Hintergrundabgleichs
public enum BackgroundSchedule {
    /// Wunsch des Inhabers: 8, 15 und 20 Uhr Ortszeit. iOS startet fruehestens dann, oft spaeter, manchmal gar nicht.
    public static let hours = [8, 15, 20]

    /// Naechster volle Stunde aus `hours` streng nach `now` in `timeZone`: vor 8 Uhr 8 Uhr, ab 8 Uhr 15 Uhr, ab 15 Uhr
    /// 20 Uhr, ab 20 Uhr 8 Uhr am naechsten Tag. Gerechnet in Ortszeit (Kalendertage), daher gilt um die Umstellung von
    /// Sommer- und Winterzeit weiter 8:00 Ortszeit, auch wenn bis dahin 23 oder 25 Stunden liegen. Faellt eine Stunde in
    /// eine Luecke der Zeitzone (gibt es fuer 8, 15, 20 Uhr in Europa nicht), nimmt Foundation die naechste gueltige Zeit.
    public static func next(after now: Date, timeZone: TimeZone, hours: [Int] = hours) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let wanted = Set(hours.filter { (0...23).contains($0) }).sorted()
        guard !wanted.isEmpty else { return now.addingTimeInterval(24 * 3600) }
        let today = cal.startOfDay(for: now)
        for offset in 0...2 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let ymd = cal.dateComponents([.year, .month, .day], from: day)
            for h in wanted {
                var c = ymd
                c.hour = h
                c.minute = 0
                c.second = 0
                if let d = cal.date(from: c), d > now { return d }
            }
        }
        // nur bei einer kaputten Zeitzone: einen Tag spaeter
        return now.addingTimeInterval(24 * 3600)
    }

    /// Einen schon bestellten Termin (`earliest`, nil = ohne Uhrzeit) behalten statt ihn durch `next` zu ersetzen?
    /// Ja, wenn er nicht spaeter liegt, auch ein ueberfaelliger (iOS darf ihn ab jetzt jederzeit starten): ersetzen
    /// hiesse ihn nach hinten schieben, und der lange Lauf mit Downloads kaeme nie dran, weil jeder kurze Lauf neu
    /// plant. Ein spaeterer (z. B. nach dem Wechsel der Zeitzone) wird ersetzt. Die gerade gelaufene Aufgabe bestellt
    /// immer neu (ihr Termin ist verbraucht).
    public static func keepsPending(_ earliest: Date?, next: Date) -> Bool {
        guard let earliest else { return true }
        return earliest <= next
    }
}

/// Umfang eines Hochschul-Abgleichs
public enum UniSyncScope: String, Sendable, Codable, Equatable {
    /// alles: Kurse, Dateilisten, Downloads, Stundenplan (beim Oeffnen, auf Knopfdruck, BGProcessingTask)
    case full
    /// nur die Listen ohne Downloads: Kurse, Dateilisten, Stundenplan (BGAppRefreshTask, rund 30 Sekunden)
    case lists
}

/// Die beiden Hintergrundaufgaben der App
public enum BackgroundSyncKind: String, Sendable, Codable, CaseIterable, Equatable {
    /// BGAppRefreshTask: kurz, nur die Listen (neue Kurse, Dateilisten, Stundenplan)
    case refresh
    /// BGProcessingTask mit Netz: zusaetzlich neue Dateien laden
    case processing

    public var scope: UniSyncScope { self == .refresh ? .lists : .full }
}

/// Warum ein Hintergrundlauf ausfaellt
public enum BackgroundSkipReason: String, Sendable, Codable, Equatable {
    /// "Im Hintergrund abgleichen" aus
    case disabled
    /// kein Container offen (nicht angemeldet, keine Hochschule gewaehlt, Speicher nicht geoeffnet)
    case noContainer
    /// Konto- oder Hochschulwechsel laeuft (offener Container passt nicht zur Wahl) oder die Einrichtung ist nicht fertig
    case switching
    /// auf diesem Container laeuft schon ein Abgleich (Sperre des Abgleichs)
    case alreadyRunning
    /// keine gueltige Sitzung (nie angemeldet, abgemeldet, als abgelaufen bekannt): nie eine Anmeldeseite, nie
    /// Zugangsdaten
    case noSession
    /// iPad gesperrt und die Sitzung nur entsperrt lesbar (Learnweb-Schluessel im Schluesselbund, WhenUnlocked)
    case deviceLocked
    /// Demo-Inhalte aktiv (`DemoContent`): kein Abgleich mit der Hochschule, bis sie entfernt sind
    case demo

    /// Anzeige in den Einstellungen
    public var text: String {
        switch self {
        case .disabled: return "ausgeschaltet"
        case .noContainer: return "keine Hochschule geöffnet"
        case .switching: return "Wechsel von Konto oder Hochschule"
        case .alreadyRunning: return "ein Abgleich lief bereits"
        case .noSession: return "keine gültige Anmeldung"
        case .deviceLocked: return "iPad gesperrt"
        case .demo: return "Demo-Inhalte aktiv"
        }
    }
}

/// Lage zu Beginn eines Hintergrundlaufs
public struct BackgroundSyncSituation: Sendable, Equatable {
    public var enabled: Bool
    /// Container des angemeldeten Nutzers und der gewaehlten Hochschule ist offen
    public var hasContainer: Bool
    /// Konto- oder Hochschulwechsel bzw. Einrichtung (offener Container passt nicht zur Wahl, Anmeldeseiten der
    /// Hochschule noch nicht durch)
    public var switching: Bool
    /// ein Abgleich laeuft schon auf diesem Container
    public var syncRunning: Bool
    /// mindestens eine Quelle mit gespeicherter, nicht als abgelaufen bekannter Sitzung
    public var usableSession: Bool
    /// Demo-Inhalte im offenen Container aktiv: nie zur Hochschule
    public var demo: Bool

    public init(enabled: Bool, hasContainer: Bool, switching: Bool, syncRunning: Bool, usableSession: Bool, demo: Bool = false) {
        self.enabled = enabled
        self.hasContainer = hasContainer
        self.switching = switching
        self.syncRunning = syncRunning
        self.usableSession = usableSession
        self.demo = demo
    }
}

public enum BackgroundSyncGate {
    /// nil = abgleichen; sonst der erste Grund in dieser Reihenfolge
    public static func skipReason(_ s: BackgroundSyncSituation) -> BackgroundSkipReason? {
        if !s.enabled { return .disabled }
        if !s.hasContainer { return .noContainer }
        if s.switching { return .switching }
        if s.demo { return .demo }
        if s.syncRunning { return .alreadyRunning }
        if !s.usableSession { return .noSession }
        return nil
    }
}

/// Ergebnis eines Hintergrundlaufs fuer Stand und Benachrichtigung
public struct BackgroundSyncReport: Sendable, Equatable {
    /// Dateien, die dieser Lauf zum ersten Mal gesehen hat (neu in der Quelle, nicht geaenderte Fassungen)
    public var newFiles: Int
    /// Quellen, deren Sitzung in diesem Lauf als abgelaufen erkannt wurde ("Stud.IP", "Learnweb", "LSF")
    public var loginNeeded: [String]
    /// abgebrochen (Zeit von iOS abgelaufen, Container wird geloescht)
    public var cancelled: Bool
    /// Fehler (kein Netz, Hochschule gestoert); nil ohne Fehler
    public var failure: String?
    /// gar nicht gelaufen (Sperre griff erst im Abgleich selbst)
    public var skipped: BackgroundSkipReason?

    public init(newFiles: Int = 0, loginNeeded: [String] = [], cancelled: Bool = false, failure: String? = nil,
                skipped: BackgroundSkipReason? = nil) {
        self.newFiles = newFiles
        self.loginNeeded = loginNeeded
        self.cancelled = cancelled
        self.failure = failure
        self.skipped = skipped
    }

    public static func skipped(_ r: BackgroundSkipReason) -> BackgroundSyncReport { BackgroundSyncReport(skipped: r) }
}

/// Stand des letzten Hintergrundlaufs eines Containers (Einstellungen: "Letzter Hintergrundlauf")
public struct BackgroundSyncRecord: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case done(newFiles: Int)
        case loginNeeded([String])
        /// iOS hat die Zeit beendet, bevor der Lauf fertig war (was bis dahin gelesen war, ist gespeichert)
        case expired
        case failed(String)
        case skipped(BackgroundSkipReason)
    }

    public var finishedAt: Date
    public var kind: BackgroundSyncKind
    public var outcome: Outcome

    public init(finishedAt: Date, kind: BackgroundSyncKind, outcome: Outcome) {
        self.finishedAt = finishedAt
        self.kind = kind
        self.outcome = outcome
    }

    /// Ergebnis eines Laufs als Stand (Abbruch vor Anmeldung vor Fehler vor Erfolg)
    public static func outcome(_ r: BackgroundSyncReport) -> Outcome {
        if let s = r.skipped { return .skipped(s) }
        if r.cancelled { return .expired }
        if !r.loginNeeded.isEmpty { return .loginNeeded(r.loginNeeded) }
        if let f = r.failure { return .failed(f) }
        return .done(newFiles: r.newFiles)
    }

    /// Kurzer Text fuer die Karte in den Einstellungen
    public var text: String {
        let what = kind == .refresh ? "Listen" : "Listen und Dateien"
        switch outcome {
        case .done(let n): return "\(what): " + (n == 0 ? "nichts Neues" : BackgroundNotice.newFilesText(n, source: nil))
        case .loginNeeded(let s): return "Anmeldung nötig (\(s.joined(separator: ", ")))"
        case .expired: return "von iOS vorzeitig beendet – der nächste Lauf macht weiter"
        case .failed(let m): return "Fehler: \(m)"
        case .skipped(let r): return "übersprungen: \(r.text)"
        }
    }
}

/// Stand des Hintergrundabgleichs eines Containers in dessen Einstellungs-Suite (geht mit dem Loeschen der Daten der
/// Hochschule und des Kontos; ein anderer Nutzer oder die andere Hochschule sieht nichts davon)
public struct BackgroundSyncState {
    public enum Keys {
        public static let last = "uniflow.background.last"
        public static func loginNotice(_ source: String) -> String {
            "uniflow.background.loginNotice." + source.lowercased().filter { $0.isLetter || $0.isNumber }
        }
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// letzter Hintergrundlauf (nil: noch keiner)
    public var last: BackgroundSyncRecord? {
        guard let data = defaults.data(forKey: Keys.last) else { return nil }
        return try? JSONDecoder().decode(BackgroundSyncRecord.self, from: data)
    }

    public func record(_ r: BackgroundSyncRecord) {
        if let data = try? JSONEncoder().encode(r) { defaults.set(data, forKey: Keys.last) }
    }

    /// Hinweis "Bitte bei … anmelden" fuer diese Quelle schon gezeigt (in diesem Ablauf der Sitzung)
    public func loginNoticeSent(_ source: String) -> Bool { defaults.bool(forKey: Keys.loginNotice(source)) }

    public func markLoginNoticeSent(_ source: String) { defaults.set(true, forKey: Keys.loginNotice(source)) }

    /// Sitzung wieder gueltig (neu angemeldet): beim naechsten Ablauf darf der Hinweis wieder kommen. Nur schreiben,
    /// wenn etwas zu loeschen ist (ein frischer Container bleibt leer).
    public func sessionUsable(_ source: String) {
        if defaults.object(forKey: Keys.loginNotice(source)) != nil { defaults.removeObject(forKey: Keys.loginNotice(source)) }
    }

    /// Quellen, fuer die nach diesem Lauf "Bitte bei … anmelden" kommt: in diesem Lauf als abgelaufen erkannt und noch
    /// ohne Hinweis (einmal, nicht bei jedem Lauf)
    public func loginNoticeDue(_ report: BackgroundSyncReport) -> [String] {
        var seen = Set<String>()
        return report.loginNeeded.filter { !loginNoticeSent($0) && seen.insert($0).inserted }
    }
}

/// Texte der lokalen Benachrichtigungen. Nie Dateinamen, Kursnamen oder Inhalte: der Sperrbildschirm zeigt nur Zahl
/// und Quelle (bei ausgeblendeter Vorschau den Platzhalter).
public enum BackgroundNotice {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Text auf dem Sperrbildschirm, wenn die Vorschau ausgeblendet ist (iOS-Einstellung "Vorschauen")
    public static let hiddenPreviewPlaceholder = "Neues aus deiner Hochschule"

    /// "1 neue Datei aus Stud.IP", "3 neue Dateien aus Learnweb"; ohne Quelle "3 neue Dateien"
    public static func newFilesText(_ count: Int, source: String?) -> String {
        let n = count == 1 ? "1 neue Datei" : "\(count) neue Dateien"
        return source.map { "\(n) aus \($0)" } ?? n
    }

    /// Benachrichtigung nach einem Lauf mit neuen Dateien; nil ohne neue
    public static func newFiles(_ count: Int, source: String) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue Dateien", body: newFilesText(count, source: source))
    }

    /// "bei Stud.IP", "bei Learnweb", "beim LSF"
    static func at(_ source: String) -> String { source == "LSF" ? "beim LSF" : "bei \(source)" }

    /// Einmal je Ablauf der Sitzung: "Bitte bei Stud.IP anmelden" (mehrere Quellen in einem Satz)
    public static func loginNeeded(_ sources: [String]) -> Content? {
        guard !sources.isEmpty else { return nil }
        let names = sources.map(at)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " und " + names[names.count - 1]
        return Content(title: "Bitte \(list) anmelden",
                       body: "Die Anmeldung ist abgelaufen. Öffne UniFlow und melde dich neu an, dann geht der Abgleich weiter. Im Hintergrund meldet sich UniFlow nie selbst an.")
    }
}

/// Eine Hintergrundaufgabe von iOS: genau ein Abschluss (`onEnd`), ob der Lauf fertig wird oder iOS die Zeit vorher
/// beendet (`expire`, expirationHandler). Beim Ablauf wird der Lauf abgebrochen (`Task.cancel`, die Abgleiche enden als
/// "abgebrochen", was gelesen war, steht in der Datenbank; halbe Dateien gibt es dank `.part` und `rename` nie); die
/// Aufgabe endet, sobald der Lauf steht, spaetestens nach `grace` (iOS beendet sonst die App).
public final class BackgroundTaskRun: @unchecked Sendable {
    public enum End: Equatable, Sendable {
        case finished(success: Bool)
        case expired
    }

    private let lock = NSLock()
    private var ended: End?
    private var expiredFlag = false
    private var work: Task<Void, Never>?
    private let graceNanos: UInt64
    private let onEnd: @Sendable (End) -> Void

    public init(graceNanos: UInt64 = 2_000_000_000, onEnd: @escaping @Sendable (End) -> Void) {
        self.graceNanos = graceNanos
        self.onEnd = onEnd
    }

    public var isExpired: Bool { lock.withLock { expiredFlag } }

    /// Abschluss, falls schon geschehen
    public var end: End? { lock.withLock { ended } }

    /// Lauf starten; `body` liefert den Erfolg. Kam der Ablauf schon vorher, wird er sofort abgebrochen.
    public func start(_ body: @escaping @Sendable () async -> Bool) {
        let t = Task { [self] in
            let ok = await body()
            finish(isExpired ? .expired : .finished(success: ok))
        }
        let cancelNow = lock.withLock { () -> Bool in
            work = t
            return expiredFlag
        }
        if cancelNow { t.cancel() }
    }

    /// expirationHandler von iOS (beliebiger Thread): abbrechen, Abschluss mit dem Ende des Laufs, spaetestens nach
    /// der Gnadenfrist
    public func expire() {
        let t = lock.withLock { () -> Task<Void, Never>? in
            expiredFlag = true
            return work
        }
        t?.cancel()
        let grace = graceNanos
        Task { [self] in
            try? await Task.sleep(nanoseconds: grace)
            finish(.expired)
        }
    }

    /// Lauf beendet (auch fuer Laeufe, die gar nicht erst starten)
    public func finish(_ e: End) {
        let first = lock.withLock { () -> Bool in
            guard ended == nil else { return false }
            ended = e
            return true
        }
        if first { onEnd(e) }
    }
}

extension UniStore {
    /// Kennungen aller Dateien aus Hochschul-Quellen (ohne eigene Dokumente): vor und nach einem Hintergrundlauf
    /// gelesen ergibt der Unterschied die neuen Dateien (Zeitstempel helfen nicht, eingefrorene Uhren in Tests und
    /// mehrere Laeufe in einer Sekunde)
    public static func sourceFileIDs(_ c: SQLiteConnection) throws -> Set<String> {
        Set(try c.query("SELECT id FROM files WHERE course_id <> '__user__'").compactMap { $0["id"]?.string })
    }
}
