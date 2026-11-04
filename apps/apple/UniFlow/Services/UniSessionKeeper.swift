import Foundation

// Angemeldet bleiben, solange die Hochschule es erlaubt (Wunsch des Inhabers 04.11.2026: "Wenn man sich mit Stud.IP
// usw. angemeldet hat, soll man beim naechsten Mal direkt angemeldet sein"). Feste Entscheidung vom 03.11.2026 bleibt:
// nie ein Hochschul-Passwort, auch nicht mit Face ID. Erlaubt sind die Cookies der Hochschul-Rechner im Schluesselbund
// (`UniWebSessions`), die stille Erneuerung ueber eine unsichtbare Webansicht und das Passwort-Autofill von iOS.
// Hier stehen nur die reinen Regeln (testbar ohne Netz): welche Cookies gemerkt werden und wann erneuert wird.
// Beschreibung fuer Menschen: docs/IPAD-STUDIP-SYNC.md, Abschnitt 13.

/// Welche Cookies der Webansicht die App merkt (Schluesselbund, `UniWebSessions`) und wieder einsetzt
enum UniCookiePolicy {
    /// Namen, die nie gemerkt werden, auch wenn eine Seite sie als Cookie setzt (Schutz: nie etwas, das nach Passwort
    /// aussieht; die Hochschulen setzen solche Cookies nicht)
    static func looksLikeSecretField(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["password", "passwort", "passwd", "pwd", "kennwort"].contains { n.contains($0) }
    }

    /// Gehoert das Cookie zu einem Rechner der Hochschule (`UniWebSessions.domains`, registrierbare Domain)?
    static func matches(_ c: HTTPCookie, _ domains: [String]) -> Bool {
        let d = (c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain).lowercased()
        return domains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// Abgelaufen (nur Cookies mit Ablaufdatum koennen ablaufen; Sitzungs-Cookies beendet der Server)
    static func isExpired(_ c: HTTPCookie, now: Date) -> Bool {
        guard let e = c.expiresDate else { return false }
        return e <= now
    }

    /// Merken? Alle Cookies der Hochschul-Rechner, die noch gelten: Sitzungs-Cookies ohne Ablauf (`shib_idp_session`
    /// des WebSSO der LUH, `TGC` des CAS, `Seminar_Session` von Stud.IP, `JSESSIONID` des LSF, `MoodleSession`) und
    /// dauerhafte mit ihrem Ablaufdatum (z. B. die "Angemeldet bleiben"-Cookies der Anmeldeseiten, falls die Hochschule
    /// sie setzt). Dauerhafte behaelt zwar auch WebKit, schreibt sie aber verzoegert auf die Platte; beendet iOS die App
    /// direkt nach der Anmeldung, waeren sie sonst weg. Nie fremde Rechner, nie Abgelaufenes.
    static func keep(_ c: HTTPCookie, domains: [String], now: Date) -> Bool {
        matches(c, domains) && !isExpired(c, now: now) && !looksLikeSecretField(c.name)
    }

    static func kept(_ all: [HTTPCookie], domains: [String], now: Date) -> [HTTPCookie] {
        all.filter { keep($0, domains: domains, now: now) }
    }

    /// Gleiche Stelle (Name, Domain, Pfad) - WebKit fuehrt je Stelle ein Cookie
    static func sameSlot(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.name == b.name && a.domain.lowercased() == b.domain.lowercased() && a.path == b.path
    }

    /// Gemerkte Cookies, die im Datenspeicher fehlen und noch gelten. Was im Datenspeicher steht, ist neuer (eine
    /// spaetere Anmeldung oder Erneuerung) und wird nie ueberschrieben.
    static func missing(_ wanted: [HTTPCookie], in present: [HTTPCookie], now: Date) -> [HTTPCookie] {
        wanted.filter { w in !isExpired(w, now: now) && !present.contains { sameSlot($0, w) } }
    }

    /// Unterscheiden sich zwei Cookie-Mengen (Name, Domain, Pfad, Wert)? Reihenfolge egal.
    static func differs(_ a: [HTTPCookie], _ b: [HTTPCookie]) -> Bool {
        func key(_ c: HTTPCookie) -> String { [c.name, c.domain.lowercased(), c.path, c.value].joined(separator: "\u{1}") }
        return Set(a.map(key)) != Set(b.map(key))
    }
}

/// Anlass einer Pruefung bzw. stillen Erneuerung
enum UniRenewalTrigger: Equatable, Sendable {
    /// App kommt in den Vordergrund (bzw. der Container oeffnet)
    case foreground
    /// ein Abgleich will gleich beginnen
    case beforeSync
    /// eine Anfrage meldete "Anmeldung abgelaufen"
    case requestFailed
    /// der Mensch hat gerade selbst etwas getan (In-App-Browser geschlossen, "Erneut anmelden"): ohne Wartezeit
    case userAction
}

/// Was jetzt zu tun ist
enum UniRenewalDecision: Equatable, Sendable {
    case nothing
    /// mit einer leichten Anfrage pruefen, ob die gemerkte Sitzung noch gilt (Stud.IP: `users/me`)
    case check
    /// still ueber das WebSSO bzw. CAS erneuern (unsichtbare Webansicht, kein Passwort)
    case renew
    /// stiller Versuch scheiterte zuletzt; erst ab diesem Zeitpunkt wieder (Ruecknahme, `UniRenewalPolicy.backoff`)
    case wait(until: Date)
}

/// Stand der Erneuerung einer Quelle (nur im Arbeitsspeicher; ein Neustart beginnt frisch)
struct UniRenewalState: Equatable, Sendable {
    /// Sitzung zuletzt bestaetigt (Pruefung, Abgleich ohne "abgelaufen" oder neue Anmeldung)
    var lastVerified: Date?
    /// letzter stiller Erneuerungsversuch
    var lastAttempt: Date?
    /// stille Versuche ohne Erfolg seit der letzten Anmeldung
    var failures = 0

    mutating func verified(at now: Date) {
        lastVerified = now
        failures = 0
    }

    mutating func attempted(at now: Date, ok: Bool) {
        lastAttempt = now
        if ok { verified(at: now) } else { failures += 1 }
    }
}

/// Wann geprueft und still erneuert wird. Die Erneuerung braucht die offene App (unsichtbare Webansicht im Fenster);
/// im Hintergrund wird nie erneuert, dort merkt sich der Abgleich nur "abgelaufen".
enum UniRenewalPolicy {
    /// Rueckkehr in die App: hoechstens so oft eine Pruefung, wenn nichts als abgelaufen bekannt ist
    static let foregroundCheckInterval: TimeInterval = 15 * 60
    /// vor einem Abgleich: keine zweite Pruefung, wenn die Sitzung eben erst bestaetigt wurde
    static let syncCheckInterval: TimeInterval = 5 * 60
    /// Wartezeit nach dem ersten gescheiterten stillen Versuch; verdoppelt sich je weiterem, hoechstens `maxBackoff`
    static let baseBackoff: TimeInterval = 10 * 60
    static let maxBackoff: TimeInterval = 4 * 3600

    /// Wartezeit nach `failures` gescheiterten stillen Versuchen (0: keine)
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(min(failures - 1, 16)))
        return min(baseBackoff * factor, maxBackoff)
    }

    /// - Parameters:
    ///   - appActive: App im Vordergrund (nur dann gibt es eine unsichtbare Webansicht)
    ///   - connected: Quelle verbunden (gespeicherte Sitzung vorhanden)
    ///   - knownExpired: Sitzung als abgelaufen bekannt ("Anmeldung nötig")
    static func decide(_ trigger: UniRenewalTrigger, appActive: Bool, connected: Bool, knownExpired: Bool,
                       state: UniRenewalState, now: Date) -> UniRenewalDecision {
        guard connected, appActive else { return .nothing }
        if knownExpired || trigger == .requestFailed {
            if trigger == .userAction { return .renew }
            if state.failures > 0, let last = state.lastAttempt {
                let until = last.addingTimeInterval(backoff(failures: state.failures))
                if now < until { return .wait(until: until) }
            }
            return .renew
        }
        let interval: TimeInterval
        switch trigger {
        case .userAction: return .check
        case .beforeSync: interval = syncCheckInterval
        case .foreground: interval = foregroundCheckInterval
        case .requestFailed: return .renew                     // oben behandelt
        }
        guard let v = state.lastVerified else { return .check }
        return now.timeIntervalSince(v) >= interval ? .check : .nothing
    }
}

/// Ergebnis einer Pruefung der gemerkten Sitzung
enum UniSessionCheck: Equatable, Sendable {
    case valid
    case expired
    /// nicht entscheidbar (kein Netz, Hochschule gestoert): nichts aendern, der Abgleich meldet es selbst
    case unknown
}
