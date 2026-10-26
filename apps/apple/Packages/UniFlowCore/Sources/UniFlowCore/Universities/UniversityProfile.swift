import Foundation

// Hochschul-Profile wie app/universities.py: welche Hochschule die App abgleicht, ihre Dienste, Anmelde- und
// Datenadressen. Die eine Quelle fuer Schluessel und Adressen der Hochschulen im Kern (HildesheimCAS, Learnweb,
// LSFClient, Datenbank-Einstellung `university`, Container). Jede Hochschule hat einen eigenen Schluessel-Praefix fuer
// den Schluesselbund ("luh.studip.user", "hildesheim.cas.user", "hildesheim.learnweb.token"); es gibt keinen
// Rueckfall von einer Hochschule auf die andere.
//
// luh        -> Stud.IP (WebSSO/Shibboleth) + QIS der Leibniz Universitaet Hannover
// hildesheim -> Learnweb (Moodle) + LSF der Universitaet Hildesheim, Anmeldung ueber das zentrale CAS

/// Schluessel einer Hochschule (Werte wie `universities.PROFILES` in Python).
public enum UniversityKey: String, Sendable, CaseIterable, Codable, Hashable {
    case luh
    case hildesheim

    /// Wie `universities.DEFAULT`
    public static let `default`: UniversityKey = .luh

    /// Wie `universities.valid`: nur bekannte Schluessel, ohne Raten (kein Trimmen, keine Gross-/Kleinschreibung).
    public static func valid(_ key: String?) -> Bool { key.flatMap(UniversityKey.init(rawValue:)) != nil }

    public var profile: UniversityProfile { UniversityProfile.profile(for: self) }
}

/// Ein Ort, an dem die Hochschule nach Benutzername und Passwort fragt: nur HTTPS, genau dieser Rechner und
/// ein Pfad, der mit `pathPrefix` beginnt. Alles andere ist keine Anmeldeseite dieser Hochschule.
public struct UniversityLoginTarget: Sendable, Hashable, Codable {
    public let host: String
    public let pathPrefix: String

    public init(host: String, pathPrefix: String) {
        self.host = host.lowercased()
        self.pathPrefix = pathPrefix
    }

    /// `https://<host><pathPrefix>...` ohne Port-Angabe (oder mit 443); Rechner ohne Gross-/Kleinschreibung.
    public func matches(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return matches(scheme: c.scheme, host: c.host, port: c.port, path: c.percentEncodedPath)
    }

    /// Dieselbe Pruefung mit den Teilen einer Herkunft (z. B. `WKSecurityOrigin`, Port 0 = Standard).
    public func matches(scheme: String?, host: String?, port: Int?, path: String) -> Bool {
        guard scheme?.lowercased() == "https", host?.lowercased() == self.host else { return false }
        if let port, port != 0, port != 443 { return false }
        return path.hasPrefix(pathPrefix)
    }
}

/// Dienst mit eigener Anmeldung (eigene Zugangsdaten im Schluesselbund).
public struct UniversityLoginService: Sendable, Hashable {
    /// Schluessel des Dienstes innerhalb der Hochschule: "studip", "qis", "cas"
    public let key: String
    public let name: String
    /// Bezeichnung des Benutzernamens auf der Anmeldeseite ("LUH-ID", "Zugangskennung (UNI-Account)")
    public let userLabel: String
    /// Seiten, die die App zum Anmelden oeffnet (z. B. Learnweb und LSF ueber dasselbe CAS)
    public let entryURLs: [URL]
    /// Anmeldeseiten, auf denen die App Benutzername und Passwort merken und vorausfuellen darf
    public let targets: [UniversityLoginTarget]
    /// CSS-Selektoren fuer das Benutzerfeld (erster Treffer gewinnt); sonst das Textfeld vor dem Passwortfeld
    public let userSelectors: [String]
    /// CSS-Selektoren fuer das Passwortfeld; sonst das erste `input[type=password]`
    public let passwordSelectors: [String]
    /// Dienst derselben Hochschule, dessen gemerkte Zugangsdaten beim Vorausfuellen gelten, solange dieser Dienst
    /// keine eigenen hat (LUH: QIS mit der LUH-ID aus Stud.IP wie `config.service_credentials("QIS")` am PC).
    /// Nie ein Dienst einer anderen Hochschule; gespeichert wird immer unter dem eigenen Dienst.
    public let prefillFallback: String?

    public func allows(_ url: URL?) -> Bool { targets.contains { $0.matches(url) } }
}

/// Eintrag der Dienste-Liste wie `HILDESHEIM_SERVICES` bzw. `/api/services` (gleiche Felder).
public struct UniversityServiceLink: Sendable, Hashable {
    public let key: String
    public let name: String
    public let url: String
    public let desc: String
    public let login: String
    public let icon: String
    public let connected: Bool
    public let connector: Bool

    public var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "name": .string(name), "url": .string(url), "desc": .string(desc),
                                      "login": .string(login), "icon": .string(icon)]
        if connected { o["connected"] = true }
        if connector { o["connector"] = true }
        return .object(o)
    }
}

/// Profil einer Hochschule (Felder wie `universities.PROFILES`).
public struct UniversityProfile: Sendable, Hashable {
    public let key: UniversityKey
    public let name: String
    public let short: String
    public let filesSource: String
    public let gradesSource: String
    public let login: String
    public let userLabel: String
    /// Praefix aller Schluesselbund-Eintraege dieser Hochschule ("luh", "hildesheim")
    public let keychainPrefix: String
    /// Aufbau des Notenspiegels (QIS der LUH bzw. LSF Hildesheim)
    public let gradeLayout: QISGradeLayout
    /// Bescheinigungen aus dem QIS/LSF wie `qis.PROFILES[<uni>]["documents"]` (LUH ja, Hildesheim nein)
    public var qisDocuments: Bool { gradeLayout.collectsDocuments }
    public let loginServices: [UniversityLoginService]
    /// Dienste mit gespeichertem Schluessel statt Benutzername und Passwort (Hildesheim: "learnweb" aus dem Moodle-SSO)
    public let tokenServices: [String]
    /// Dienste-Liste fuer `/api/services` (LUH: SERVICES in app/server.py, Hildesheim: HILDESHEIM_SERVICES)
    public let services: [UniversityServiceLink]

    // Datenadressen (nil, wenn die Hochschule den Dienst nicht hat)
    public let studipBase: URL?
    public let qisStart: URL?
    public let casBase: URL?
    public let learnwebBase: URL?
    public let lsfBase: URL?

    public func loginService(_ key: String) -> UniversityLoginService? { loginServices.first { $0.key == key } }

    /// Schluesselbund-Eintrag eines Dienstes dieser Hochschule, z. B. "hildesheim.cas.user" oder
    /// "hildesheim.learnweb.token"; mit `userScope` (Kurzkennung des Apple-Nutzers, `DataContainerKey.userScope`)
    /// davor: "u1a2b….hildesheim.cas.user". Die eine Funktion fuer die Namen aller gemerkten Zugangsdaten (App:
    /// `UniversityCredentialStore`, Learnweb-Schluessel). nil fuer Dienste einer anderen Hochschule (kein Rueckfall)
    /// und fuer Felder, die der Dienst nicht hat (Benutzer/Passwort nur fuer Anmeldeseiten, Schluessel nur fuer
    /// `tokenServices`).
    public func keychainAccount(service: String, field: String, userScope: String? = nil) -> String? {
        let known: Bool
        switch field {
        case "user", "password": known = loginService(service) != nil
        case "token": known = tokenServices.contains(service)
        default: known = false
        }
        guard known else { return nil }
        let account = "\(keychainPrefix).\(service).\(field)"
        return userScope.map { "\($0).\(account)" } ?? account
    }

    /// Alle Schluesselbund-Eintraege, die zu dieser Hochschule gehoeren koennen (zum Loeschen je Hochschule).
    public func ownsKeychainAccount(_ account: String) -> Bool { account.hasPrefix(keychainPrefix + ".") }

    /// `"university"` in `/api/services` wie api_services in app/server.py (diese sieben Felder aus `universities.PROFILES`)
    public var json: JSONValue {
        ["key": .string(key.rawValue), "name": .string(name), "short": .string(short), "files_source": .string(filesSource),
         "grades_source": .string(gradesSource), "login": .string(login), "user_label": .string(userLabel)]
    }

    public static let all: [UniversityProfile] = [luh, hildesheim]

    public static func profile(for key: UniversityKey) -> UniversityProfile {
        switch key {
        case .luh: return luh
        case .hildesheim: return hildesheim
        }
    }

    /// Profil zu einem gespeicherten Schluessel; unbekannte Werte ergeben nil (nie still die LUH).
    public static func profile(forKey raw: String?) -> UniversityProfile? { raw.flatMap(UniversityKey.init(rawValue:))?.profile }
}

// MARK: - Die beiden Hochschulen

extension UniversityProfile {
    // Adressen wie app/universities.py, app/config.py (STUDIP_BASE), app/qis.py (QIS_BASE, QIS_START)
    static let luhStudIP = URL(string: "https://studip.uni-hannover.de")!
    static let luhQISStart = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf")!
    /// WebSSO (Shibboleth-IdP) der LUH, entityID in app/studip_sync.py
    static let luhSSOHost = "sso.idm.uni-hannover.de"

    /// HILDESHEIM_CAS, LSF_BASE (app/universities.py)
    public static let hildesheimCAS = URL(string: "https://www.uni-hildesheim.de/sso")!
    /// LEARNWEB_BASE: nur fuer Links in der Oberflaeche und die Anmeldeseite; der Abgleich ermittelt die Instanz des
    /// Semesters selbst (`Learnweb.discoverBase`, jaehrlicher Wechsel learnweb2026 -> learnweb2027)
    public static let hildesheimLearnweb = URL(string: Learnweb.root + "/learnweb2026")!
    public static let hildesheimLSF = URL(string: "https://lsf.uni-hildesheim.de")!
    /// Startseite des LSF (LSF_START in app/lsf.py), aus der Basis
    public static let hildesheimLSFStart = URL(string: hildesheimLSF.absoluteString + "/qisserver/rds?state=user&type=0")!

    public static let luh = UniversityProfile(
        key: .luh, name: "Leibniz Universität Hannover", short: "LUH", filesSource: "Stud.IP", gradesSource: "QIS",
        login: "WebSSO (LUH-ID)", userLabel: "LUH-ID", keychainPrefix: "luh", gradeLayout: .luh,
        loginServices: [
            UniversityLoginService(
                key: "studip", name: "Stud.IP", userLabel: "LUH-ID",
                entryURLs: [luhStudIP.appendingPathComponent("dispatch.php/login")],
                // Stud.IP-Anmeldeseite und das WebSSO der LUH (Felder 'loginname' und 'password', app/studip_sync.py)
                targets: [UniversityLoginTarget(host: luhSSOHost, pathPrefix: "/idp/"),
                          UniversityLoginTarget(host: luhStudIP.host ?? "", pathPrefix: "/dispatch.php/login")],
                userSelectors: ["input[name='loginname']", "#loginname", "input[name='j_username']", "#username",
                                "input[autocomplete='username']"],
                passwordSelectors: ["input[name='password']", "#password"], prefillFallback: nil),
            UniversityLoginService(
                key: "qis", name: "QIS", userLabel: "LUH-ID",
                entryURLs: [luhQISStart],
                // HIS-QIS: Benutzer 'asdf', Passwort 'fdsa' (app/qis.py)
                targets: [UniversityLoginTarget(host: "qis.verwaltung.uni-hannover.de", pathPrefix: "/qisserver/")],
                userSelectors: ["input[name='asdf']", "#asdf"],
                passwordSelectors: ["input[name='fdsa']", "#fdsa"],
                // ohne eigene QIS-Daten die LUH-ID aus Stud.IP (PC: same_as_studip, solange QIS nichts Eigenes hat)
                prefillFallback: "studip"),
        ],
        tokenServices: [],
        // SERVICES in app/server.py (gleich mit Python laut Fixture app-paths.json)
        services: [
            UniversityServiceLink(key: "studip", name: "Stud.IP", url: luhStudIP.absoluteString + "/",
                                  desc: "Kurse, Dateien, Termine, Ankündigungen", login: "WebSSO (LUH-ID)", icon: "book",
                                  connected: true, connector: false),
            UniversityServiceLink(key: "ilias", name: "ILIAS", url: "https://ilias.uni-hannover.de/",
                                  desc: "Lernplattform: Kurse, Tests, Lernmodule", login: "WebSSO (LUH-ID)", icon: "layers",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "qis", name: "QIS / LSF (Prüfungsverwaltung)", url: luhQISStart.absoluteString,
                                  desc: "Notenspiegel, Prüfungsanmeldung, Bescheinigungen", login: "LUH-ID", icon: "exam",
                                  connected: false, connector: true),
            UniversityServiceLink(key: "idm", name: "IDM Account-Manager", url: "https://login.uni-hannover.de/",
                                  desc: "LUH-ID verwalten, Passwort ändern, WebSSO", login: "LUH-ID", icon: "user",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "mail", name: "E-Mail (LUIS)", url: "https://www.luis.uni-hannover.de/de/services/kommunikation/e-mail",
                                  desc: "Studentisches E-Mail-Postfach und Webmail", login: "LUH-ID", icon: "bell",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "matrix", name: "Matrix-Chat",
                                  url: "https://www.luis.uni-hannover.de/de/services/kommunikation/messenger-chat-dienst-matrix",
                                  desc: "Messenger der Uni, auch in Stud.IP-Kursen", login: "LUH-ID", icon: "users",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "luhki", name: "LUHKI", url: "https://www.luis.uni-hannover.de/de/services/anwendungen/luhki-2",
                                  desc: "KI-Plattform der LUH", login: "LUH-ID", icon: "sparkles", connected: false, connector: false),
            UniversityServiceLink(key: "gitlab", name: "GitLab (LUIS)",
                                  url: "https://www.luis.uni-hannover.de/de/services/anwendungen/versionsverwaltung-von-software-projekten-gitlab",
                                  desc: "Versionsverwaltung für Programmieren-Projekte", login: "LUH-ID", icon: "file-text",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "tib", name: "TIB Bibliothek", url: "https://www.tib.eu/", desc: "Literatur, Lernplätze, Ausleihe",
                                  login: "Bibliotheksausweis", icon: "book", connected: false, connector: false),
            UniversityServiceLink(key: "mensa", name: "Mensa (Studentenwerk)", url: "https://www.studentenwerk-hannover.de/essen/speiseplaene",
                                  desc: "Speisepläne der Mensen", login: "–", icon: "sun", connected: false, connector: false),
            UniversityServiceLink(key: "servicecenter", name: "ServiceCenter",
                                  url: "https://www.uni-hannover.de/de/studium/beratung-hilfe/servicecenter",
                                  desc: "Immatrikulation, Rückmeldung, Beratung", login: "–", icon: "info", connected: false, connector: false),
            UniversityServiceLink(key: "luis", name: "LUIS IT-Support",
                                  url: "https://www.luis.uni-hannover.de/de/services/kurse-beratung-und-support/it-support",
                                  desc: "WLAN, VPN, Software, Zugänge", login: "–", icon: "settings", connected: false, connector: false),
        ],
        studipBase: luhStudIP, qisStart: luhQISStart, casBase: nil, learnwebBase: nil, lsfBase: nil)

    public static let hildesheim = UniversityProfile(
        key: .hildesheim, name: "Universität Hildesheim", short: "Uni Hildesheim", filesSource: "Learnweb",
        gradesSource: "LSF", login: "UNI-Account (CAS)", userLabel: "Zugangskennung (UNI-Account)",
        keychainPrefix: "hildesheim", gradeLayout: .hildesheim,
        loginServices: [
            UniversityLoginService(
                key: "cas", name: "UNI-Account (CAS)", userLabel: "Zugangskennung (UNI-Account)",
                // Learnweb (LEARNWEB_LOGIN in app/hildesheim.py) und LSF (SSO_ENTRY in app/lsf.py) ueber dasselbe CAS
                entryURLs: [URL(string: HildesheimCAS.learnwebLoginURL(base: hildesheimLearnweb.absoluteString))!,
                            URL(string: HildesheimCAS.lsfLoginURL)!],
                // is_cas_page: mit und ohne "www."
                targets: [UniversityLoginTarget(host: "www.uni-hildesheim.de", pathPrefix: "/sso/login"),
                          UniversityLoginTarget(host: "uni-hildesheim.de", pathPrefix: "/sso/login")],
                userSelectors: HildesheimCAS.userSelectors, passwordSelectors: HildesheimCAS.passwordSelectors, prefillFallback: nil),
        ],
        // Learnweb-Schluessel aus dem Moodle-SSO ("hildesheim.learnweb.token")
        tokenServices: ["learnweb"],
        // HILDESHEIM_SERVICES
        services: [
            UniversityServiceLink(key: "learnweb", name: "Learnweb", url: hildesheimLearnweb.absoluteString + "/my/courses.php",
                                  desc: "Kurse, Folien, Skripte, Aufgaben (Moodle)", login: "UNI-Account (CAS)", icon: "book",
                                  connected: true, connector: false),
            UniversityServiceLink(key: "lsf", name: "LSF", url: hildesheimLSFStart.absoluteString,
                                  desc: "Vorlesungsverzeichnis, Stundenplan, Notenspiegel, Prüfungsanmeldung",
                                  login: "UNI-Account (CAS)", icon: "exam", connected: false, connector: true),
            UniversityServiceLink(key: "lsf-ausfall", name: "Ausfälle & Raumwechsel",
                                  url: hildesheimLSF.absoluteString + "/qisserver/rds?state=currentLectures&type=1&next=CurrentLectures.vm&nextdir=ressourcenManager",
                                  desc: "Heute ausfallende oder verlegte Veranstaltungen", login: "–", icon: "alert",
                                  connected: false, connector: false),
            UniversityServiceLink(key: "uni", name: "Uni Hildesheim", url: "https://www.uni-hildesheim.de/",
                                  desc: "Webseite der Universität", login: "–", icon: "info", connected: false, connector: false),
        ],
        studipBase: nil, qisStart: hildesheimLSFStart,
        casBase: hildesheimCAS, learnwebBase: hildesheimLearnweb, lsfBase: hildesheimLSF)
}
