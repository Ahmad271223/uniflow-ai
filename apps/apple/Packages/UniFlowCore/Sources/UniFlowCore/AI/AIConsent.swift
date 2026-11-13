import Foundation

// Einwilligung vor der ersten Anfrage an die StudiNow-KI (06.11.2026, App Store Review Guideline 5.1.2(i)): Bevor
// persoenliche Daten (Seitentext, Bild eines Bereichs, Frage) an einen fremden KI-Anbieter gehen, sagt die App
// deutlich, WAS gesendet wird und an WEN, und holt die ausdrueckliche Zustimmung ein. Durchgesetzt wird das zentral in
// `StudiNowAI.json` (jede Anfrage an `/api/ai/relay` und `/api/ai/document/*`), nicht nur in den Ansichten.
// Anbieter wie app/ai_router.py und docs/release/DATENSCHUTZ.md Abschnitt 8c: OpenAI (USA) und Claude von Anthropic
// ueber Amazon Bedrock (Frankfurt, EU); DeepSeek ist aus. Aendert sich der Text, `version` hochzaehlen: dann fragt
// die App erneut (gleicher Stand in app/ai_consent.py fuer Web und Windows).

/// Fragt vor einer Anfrage an die StudiNow-KI nach der Einwilligung. `true`: liegt vor oder wurde eben erteilt;
/// `false`: abgelehnt bzw. nicht erfragbar - dann geht nichts an den Dienst.
public protocol AIConsentGate: Sendable {
    func ensureConsent() async -> Bool
}

/// Texte des Hinweises "KI-Hilfe: Was wird gesendet?" (iPad; Web und Windows lesen dieselben Saetze aus
/// app/ai_consent.py)
public enum AIConsentText {
    /// Stand des Textes; neuer Stand = neue Frage
    public static let version = "2026-11-06"
    public static let title = "KI-Hilfe: Was wird gesendet?"
    public static let intro = "Für die StudiNow-KI schickt StudiNow deine Anfrage an einen KI-Anbieter. Bevor das zum ersten Mal passiert, brauchen wir deine Zustimmung."
    /// Kurzfassung, die der Hinweis zuerst zeigt (Wunsch des Inhabers 13.11.2026: kurz statt der langen Seite); sie
    /// nennt weiter was und an wen (5.1.2(i)), alles Weitere steht hinter "Genauer ansehen"
    public static let short = "StudiNow schickt den Text deiner Seite (oder einen Bildausschnitt) und deine Frage an einen KI-Anbieter: OpenAI (USA) oder Claude über Amazon Bedrock (EU). Dein Name, deine E-Mail, deine Zugangsdaten und deine Noten werden nie gesendet."
    public static let details = "Genauer ansehen"
    public static let whatHeading = "Was gesendet wird"
    public static let what: [String] = [
        "der Text der Seite oder deiner Markierung, bei „Ganzes Dokument“ der Text der gewählten Seiten",
        "das Bild eines Bereichs, wenn du „Bereich an KI“ nutzt",
        "deine Frage oder Lösung, die Namen von Kurs und Datei und passende Stellen aus deinen Unterlagen",
        "für Karteikarten und Wochentests die Texte deiner Unterlagen",
    ]
    public static let never = "Nie gesendet werden dein Name, deine E-Mail-Adresse, deine Hochschul-Zugangsdaten und deine Noten."
    public static let whereHeading = "Wohin es geht"
    public static let service = "An den StudiNow-Dienst (app.studinow.app). Er gibt jede Anfrage an einen dieser KI-Anbieter weiter:"
    public static let recipients: [String] = [
        "OpenAI (ChatGPT-Modelle, Verarbeitung in den USA)",
        "Anthropic Claude über Amazon Web Services (Amazon Bedrock, Frankfurt, Verarbeitung in der EU)",
    ]
    public static let processors = "Beide verarbeiten die Daten nur in unserem Auftrag (Auftragsverarbeitung nach Art. 28 DSGVO)."
    public static let revoke = "Du kannst die Einwilligung jederzeit widerrufen: Einstellungen → Zugang & Darstellung → StudiNow-Konto → „KI-Einwilligung widerrufen“. Ohne Einwilligung sendet StudiNow nichts an die KI."
    public static let privacyURL = "https://studinow.app/datenschutz"
    public static let privacyLink = "Datenschutzerklärung (Abschnitt 8c)"
    public static let accept = "Okay, los"
    public static let cancel = "Abbrechen"
    public static let revokeButton = "KI-Einwilligung widerrufen"
    /// Meldung, wenn die Einwilligung fehlt (Abbrechen); Code `ai_consent_required`
    public static let declined = "Ohne deine Zustimmung sendet StudiNow nichts an die KI. Beim nächsten Versuch fragen wir dich erneut."
    public static let code = "ai_consent_required"
}

/// Einwilligung je StudiNow-Konto auf diesem Geraet (UserDefaults, Schluessel mit `AIConsentText.version`: ein neuer
/// Text fragt erneut). Gespeichert wird nur der Zeitpunkt der Zustimmung.
public struct AIConsentStore: @unchecked Sendable {
    public static let keyPrefix = "studinow.aiConsent."
    public let defaults: UserDefaults
    public let version: String

    public init(defaults: UserDefaults = .standard, version: String = AIConsentText.version) {
        self.defaults = defaults
        self.version = version
    }

    func key(_ account: String) -> String { Self.keyPrefix + version + "." + account }

    /// Zeitpunkt der Zustimmung zum aktuellen Text; nil = nicht (oder nur zu einem alten Text) zugestimmt
    public func grantedAt(_ account: String) -> Date? {
        guard !account.isEmpty, let t = defaults.object(forKey: key(account)) as? Double else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    public func isGranted(_ account: String) -> Bool { grantedAt(account) != nil }

    public func grant(_ account: String, at date: Date = Date()) {
        guard !account.isEmpty else { return }
        defaults.set(date.timeIntervalSince1970, forKey: key(account))
    }

    /// Widerruf: alle Staende dieses Kontos entfernen
    public func revoke(_ account: String) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(Self.keyPrefix) {
            // "<prefix><version>.<konto>": Stand ohne Punkt, Konto ist der ganze Rest
            let rest = k.dropFirst(Self.keyPrefix.count)
            guard let dot = rest.firstIndex(of: "."), rest[rest.index(after: dot)...] == account else { continue }
            defaults.removeObject(forKey: k)
        }
    }
}
