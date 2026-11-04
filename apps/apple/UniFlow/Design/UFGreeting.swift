import Foundation

/// Begruessung mit Namen auf der Uebersicht (Wunsch des Inhabers 04.11.2026): "Hallo Ahmad – lass uns gemeinsam
/// lernen." Morgens und abends mit der Tageszeit, sonst "Hallo"; ohne Namen dieselben Saetze ohne Namen. Reine
/// Funktionen (UniFlowTests/GreetingAppTests.swift). Der Name kommt in dieser Reihenfolge: der selbst gewaehlte
/// Rufname (Einstellungen -> Konto, Begruessung beim ersten Start), sonst der Anzeigename des StudiNow-Kontos (hat in
/// V1 keinen), sonst der Vorname aus "Mit Apple anmelden" (nur bei der ersten Anmeldung geliefert, seitdem im
/// Schluesselbund), sonst nichts.
enum UFGreeting {
    /// laengere Namen werden gekuerzt, damit die Ueberschrift eine Zeile bleibt
    static let maxNameLength = 24
    static let tail = "lass uns gemeinsam lernen."

    /// Anrede nach der Stunde: vor 11 Uhr "Guten Morgen", ab 18 Uhr "Guten Abend", dazwischen "Hallo"
    static func salutation(hour: Int) -> String {
        hour < 11 ? "Guten Morgen" : hour < 18 ? "Hallo" : "Guten Abend"
    }

    /// "Hallo Ahmad – lass uns gemeinsam lernen." / "Guten Morgen, Ahmad – …" / ohne Namen "Hallo – …"
    static func text(name: String?, hour: Int) -> String {
        let s = salutation(hour: hour)
        guard let n = displayName(name) else { return "\(s) – \(tail)" }
        return s == "Hallo" ? "Hallo \(n) – \(tail)" : "\(s), \(n) – \(tail)"
    }

    static func text(name: String?, date: Date = Date(), calendar: Calendar = .current) -> String {
        text(name: name, hour: calendar.component(.hour, from: date))
    }

    /// Name fuer die Anzeige: ohne Rand-Leerzeichen, leer = nil, laenger als `maxNameLength` mit "…" gekuerzt
    static func displayName(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        guard t.count > maxNameLength else { return t }
        return String(t.prefix(maxNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Vorname aus dem vollen Namen der Apple-Anmeldung ("Ahmad Fakih" -> "Ahmad"), fuer Konten von vor dem
    /// getrennt gespeicherten Vornamen
    static func givenName(fromFullName full: String?) -> String? {
        guard let first = full?.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).first else { return nil }
        return displayName(String(first))
    }

    /// Reihenfolge der Quellen (siehe oben); jede Quelle gilt nur, wenn sie nicht leer ist
    static func pick(rufname: String?, accountName: String?, appleGivenName: String?, appleFullName: String?) -> String? {
        displayName(rufname) ?? displayName(accountName) ?? displayName(appleGivenName) ?? givenName(fromFullName: appleFullName)
    }
}

/// Rufname fuer die Begruessung: je Container (Konto und Hochschule) in dessen Einstellungen; vor der Anmeldung
/// (Begruessung beim ersten Start) vorgemerkt in den gemeinsamen Einstellungen und beim ersten Lesen in den
/// Container uebernommen. Verlaesst das Geraet nie.
enum Rufname {
    static let key = "uniflow.greeting.rufname"
    static let pendingKey = "uniflow.greeting.rufname.pending"

    static func read(_ defaults: UserDefaults) -> String? { UFGreeting.displayName(defaults.string(forKey: key)) }

    static func write(_ value: String?, _ defaults: UserDefaults) {
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { defaults.set(v, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    /// Vormerkung aus der Begruessung (noch kein Container)
    static func setPending(_ value: String?, app: UserDefaults = .standard) {
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { app.set(v, forKey: pendingKey) }
        else { app.removeObject(forKey: pendingKey) }
    }

    /// Rufname des Containers; eine Vormerkung wandert beim ersten Lesen in den Container (nur wenn er keinen hat)
    static func current(container: UserDefaults?, app: UserDefaults = .standard) -> String? {
        if let container {
            if let own = read(container) { return own }
            if let pending = UFGreeting.displayName(app.string(forKey: pendingKey)) {
                write(pending, container)
                app.removeObject(forKey: pendingKey)
                return pending
            }
            return nil
        }
        return UFGreeting.displayName(app.string(forKey: pendingKey))
    }

    /// `ActiveContainer.current` ist ueber eine Sperre lesbar (kein Hauptthread noetig, auch aus @State-Vorgaben)
    static func current() -> String? { current(container: ActiveContainer.current?.defaults) }

    static func save(_ value: String?) {
        if let d = ActiveContainer.current?.defaults { write(value, d) } else { setPending(value) }
    }
}
