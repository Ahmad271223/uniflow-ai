import Foundation

/// Was die Oberflaeche zu einem Dienstfehler anbieten kann (Knopf neben der Meldung)
public enum ServiceErrorAction: String, Sendable, Equatable {
    /// E-Mail-Adresse bestaetigen: Einstellungen → StudiNow-Konto, dort "Bestaetigungslink erneut senden"
    case verifyEmail
    /// Kontoeinstellungen oeffnen (Anmeldewege, Passwort)
    case accountSettings
}

/// Die EINE Stelle fuer Texte zu Fehlercodes des StudiNow-Dienstes (`{detail, code}`, Vertrag G1/G4 und
/// docs/SICHERHEITSKORREKTUREN-2026-11-02.md). Unbekannte Codes behalten die Meldung des Dienstes.
///
/// Herkunft der Codes: `email_unverified`, `email_taken` und die Grenze `report_user` stehen in
/// packages/shared-contracts/fixtures/account/contract.json; `duplicate_request` (app/entitlements.py),
/// `ai_trial_budget_exhausted`, `ai_not_configured_prices` (app/ai_backend.py), `last_login_method` (app/accounts.py),
/// `provider_not_configured` (app/account_api.py), `subscription_owned_by_other_account`, `apple_not_configured`
/// (app/apple_store.py) und `cross_site` (app/account_api.py) nur im Dienst.
public enum ServiceErrorText {
    /// `rules.limits.report_user` im Kontovertrag: 10 Meldungen je Konto und Tag
    public static let reportsPerDay = 10

    /// Eigener Text fuer einen bekannten Code; nil = Meldung des Dienstes zeigen
    public static func known(code: String) -> String? {
        switch code {
        case "email_unverified":
            return "Bestätige zuerst deine E-Mail-Adresse. Den Link findest du in der Willkommensmail; unter Einstellungen → StudiNow-Konto kannst du ihn erneut anfordern."
        case "duplicate_request":
            return "Diese Anfrage wurde schon verarbeitet und nicht noch einmal berechnet. Starte sie bei Bedarf neu."
        case "ai_trial_budget_exhausted":
            return "Das Kontingent der StudiNow-KI für Probekonten ist in diesem Monat aufgebraucht. Ab dem nächsten Monat geht es weiter."
        case "ai_not_configured_prices":
            return "Die StudiNow-KI ist im Dienst noch nicht freigeschaltet. Bitte versuche es später erneut."
        case "email_taken":
            return "Für diese E-Mail-Adresse gibt es schon ein StudiNow-Konto. Melde dich dort mit E-Mail und Passwort an und bestätige die Adresse; danach lässt sich die Anmeldung verknüpfen."
        case "last_login_method":
            return "Das ist der einzige Anmeldeweg deines Kontos. Lege zuerst ein Passwort fest oder verknüpfe einen anderen Weg, dann kannst du diesen entfernen."
        case "subscription_owned_by_other_account":
            return "Dieses App-Store-Abo ist schon mit einem anderen StudiNow-Konto verbunden. Melde dich mit jenem Konto an, dann gilt es auch für die StudiNow-KI."
        case "apple_not_configured":
            return "Der StudiNow-Dienst kann App-Store-Käufe gerade noch nicht prüfen. Dein Abo gilt auf dem iPad trotzdem; bitte versuche es später erneut."
        case "provider_not_configured":
            return "„Mit Apple anmelden“ ist beim StudiNow-Dienst noch nicht eingerichtet. Melde dich vorerst mit E-Mail und Passwort an."
        case "cross_site":
            return "Die Anfrage wurde aus Sicherheitsgründen abgelehnt, weil sie nicht direkt aus StudiNow kam. Starte sie bitte in der App oder auf der StudiNow-Webseite selbst."
        default:
            return nil
        }
    }

    /// Handlung zur Meldung (nil: nur Text)
    public static func action(code: String) -> ServiceErrorAction? {
        switch code {
        case "email_unverified": return .verifyEmail
        case "last_login_method", "email_taken": return .accountSettings
        default: return nil
        }
    }

    /// Zusatz "in N min erneut versuchen" aus Retry-After (Sekunden); ab 2 Stunden in Stunden (Tagesgrenzen)
    public static func retryHint(_ retryAfter: Int?) -> String? {
        guard let s = retryAfter, s > 0 else { return nil }
        let minutes = max(1, s / 60)
        if minutes >= 120 { return "in etwa \((minutes + 30) / 60) Std. erneut versuchen" }
        return "in \(minutes) min erneut versuchen"
    }

    /// Text fuer die Oberflaeche: eigener Text fuer bekannte Codes, sonst die Meldung des Dienstes; mit Retry-After
    /// der Hinweis, wann es wieder geht
    public static func text(code: String, serverMessage: String, retryAfter: Int? = nil) -> String {
        let base = known(code: code) ?? serverMessage
        return retryHint(retryAfter).map { "\(base) (\($0))" } ?? base
    }

    /// Grenze `report_user` erreicht (Dienst: 429 `rate_limited` beim Melden)
    public static func reportLimit(retryAfter: Int?) -> String {
        let base = "Du hast heute schon \(reportsPerDay) Meldungen abgegeben, mehr sind pro Tag nicht möglich."
        return retryHint(retryAfter).map { "\(base) (\($0))" } ?? base
    }
}

extension AccountError {
    /// Text fuer die Oberflaeche (`ServiceErrorText`)
    public var userMessage: String { ServiceErrorText.text(code: code, serverMessage: message, retryAfter: retryAfter) }
    /// Handlung zur Meldung, z. B. E-Mail bestaetigen
    public var action: ServiceErrorAction? { ServiceErrorText.action(code: code) }
}
