import Foundation

// Uni-Mail ueber IMAP/SMTP (Uni Goettingen, 27.11.2026; docs/GOETTINGEN-MAIL-2026-11-27.md). Die Universitaet Goettingen
// betreibt Exchange bei der GWDG, kein SOGo; Webmail geht nur ueber die Academic Cloud mit zweitem Faktor. Laut den
// oeffentlichen Anleitungen von studIT (https://studit.uni-goettingen.de/en/support/email/iphone_ipad_mailpostfach,
// …/thunderbird, wiki.student.uni-goettingen.de/support/email/konto) gehen IMAP und SMTP:
//   IMAP  email.gwdg.de:993 SSL/TLS, Benutzer "ug-student\<kennung>"
//   SMTP  email.gwdg.de:587 STARTTLS (Anleitung fuer Outlook nennt 25)
// Am 27.11.2026 ohne Anmeldung am Server nachgesehen: IMAP meldet "Microsoft Exchange IMAP4" mit
// AUTH=PLAIN SASL-IR UIDPLUS LITERAL+ (kein MOVE, kein SPECIAL-USE); SMTP 587 bietet STARTTLS und danach AUTH LOGIN
// (kein PLAIN); 465 antwortet nicht. Adresse: <kennung>@stud.uni-goettingen.de.
// Das Passwort tippt nur der Mensch am Geraet; es liegt nur im Schluesselbund dieses Geraets, nie auf einem Server.

/// Zugangsdaten eines IMAP/SMTP-Postfachs einer Hochschule (feste Rechner, nur diese)
public struct IMAPMailSite: Sendable, Hashable {
    public enum SMTPSecurity: String, Sendable, Hashable {
        /// unverschluesselt verbinden, sofort STARTTLS (ohne STARTTLS: abbrechen, nie im Klartext anmelden)
        case startTLS
        /// gleich mit TLS (Port 465)
        case tls
    }

    public let imapHost: String
    public let imapPort: UInt16
    public let smtpHost: String
    public let smtpPort: UInt16
    public let smtpSecurity: SMTPSecurity
    /// Domaene vor der Kennung ("ug-student\"); leer: Kennung, wie getippt
    public let loginDomain: String
    /// Teil der Adresse nach "@" ("stud.uni-goettingen.de")
    public let addressDomain: String
    /// Weitere Rechner derselben Hochschule, die die Anleitungen nennen (nur Hinweis im Dokument, nicht benutzt)
    public let alternativeHosts: [String]
    /// Gesendete E-Mail zusaetzlich in "Gesendet" ablegen (Exchange legt ueber SMTP Gesendetes nicht selbst ab)
    public let appendsSent: Bool

    public init(imapHost: String, imapPort: UInt16, smtpHost: String, smtpPort: UInt16, smtpSecurity: SMTPSecurity,
                loginDomain: String, addressDomain: String, alternativeHosts: [String] = [], appendsSent: Bool = true) {
        self.imapHost = imapHost.lowercased()
        self.imapPort = imapPort
        self.smtpHost = smtpHost.lowercased()
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.loginDomain = loginDomain
        self.addressDomain = addressDomain.lowercased()
        self.alternativeHosts = alternativeHosts
        self.appendsSent = appendsSent
    }

    public static let goettingen = IMAPMailSite(imapHost: "email.gwdg.de", imapPort: 993, smtpHost: "email.gwdg.de", smtpPort: 587,
                                                smtpSecurity: .startTLS, loginDomain: "ug-student", addressDomain: "stud.uni-goettingen.de",
                                                alternativeHosts: ["email.stud.uni-goettingen.de"])

    /// Rechner, zu denen Verbindungen erlaubt sind
    public var hosts: Set<String> { [imapHost, smtpHost] }

    /// Kennung ohne Domaene und ohne "@…" (aus "ug-student\\erika.muster", "erika.muster@stud…" oder "erika.muster"),
    /// klein geschrieben (die Uni fuehrt Kennungen in Kleinbuchstaben; iOS schreibt das erste Zeichen oft gross)
    public func account(_ typed: String) -> String {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "\\") { s = String(s[s.index(after: slash)...]) }
        if let at = s.firstIndex(of: "@"), s[s.index(after: at)...].lowercased() == addressDomain { s = String(s[..<at]) }
        return s.lowercased()
    }

    /// Benutzername fuer IMAP/SMTP ("ug-student\\<kennung>")
    public func loginName(_ typed: String) -> String {
        let a = account(typed)
        if a.contains("@") || loginDomain.isEmpty { return a }
        return loginDomain + "\\" + a
    }

    /// Absender-Adresse aus der Kennung ("<kennung>@stud.uni-goettingen.de"); eine getippte Adresse bleibt
    public func address(_ typed: String) -> String {
        let a = account(typed)
        if a.contains("@") { return a.lowercased() }
        return a.lowercased() + "@" + addressDomain
    }
}

extension SOGoSite {
    /// Uni-Mail der Uni Goettingen (Exchange der GWDG ueber IMAP/SMTP, kein SOGo und kein Uni-Kalender)
    public static let goettingen = SOGoSite(university: .goettingen, host: IMAPMailSite.goettingen.imapHost, name: "Uni-Mail (Uni Göttingen)",
                                            universityName: "Universität Göttingen", short: "Uni Göttingen", roomLinks: false,
                                            imap: .goettingen)

    /// Alle Hochschulen mit Uni-Mail (SOGo und IMAP); `all` bleibt die Liste der SOGo-Rechner (Cookies, Webansicht)
    public static let mailSites: [SOGoSite] = all + [.goettingen]

    /// Uni-Mail laeuft ueber IMAP/SMTP (ohne Webansicht, ohne Kalender)
    public var isIMAP: Bool { imap != nil }
}
