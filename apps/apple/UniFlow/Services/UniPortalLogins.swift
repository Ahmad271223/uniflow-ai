import Foundation
import Security
import UniFlowCore
import WebKit

// Uni-Zugang je Portal (Vorgabe des Inhabers 10.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md Abschnitt 1.0.2):
// In den Einstellungen gibt es den Schalter "Benutzername und Passwort sind überall gleich" (Vorgabe an).
// - an: EIN Eintrag (der gemeinsame, `uni-login.<container-uuid>`) fuer Stud.IP, QIS und Uni-Mail (SOGo);
// - aus: je Portal ein eigener Eintrag (`uni-login.<container-uuid>.<portal>`); fehlt er, gilt der gemeinsame.
// Alle Eintraege liegen nur im Schluesselbund dieses Geraets (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, nicht
// synchronisiert, `UniCredentialStore`). Lehnt die Hochschule ein Passwort ab, wird nur der dabei benutzte Eintrag
// vergessen (und jeder andere Eintrag mit genau demselben Benutzernamen und Passwort), der Merker "abgelehnt" bleibt
// (kein Geheimnis) bis zum naechsten Speichern; so wird ein abgelehntes Passwort nie ein zweites Mal gesendet, auch
// nicht nach einem Neustart und nicht bei einem anderen Portal. Mit dem gemeinsamen Zugang stoppt eine Ablehnung damit
// alle Portale, mit getrennten Zugaengen nur dieses.
// "Abmelden" bei einem Portal setzt den Merker "bewusst abgemeldet": danach verbindet die App dieses Portal nicht mehr
// von selbst (`ContainerManager.connectWithStoredLogin`), bis sich der Mensch dort anmeldet oder in den Einstellungen
// neu speichert.

extension UniAutoLogin {
    /// Dienste mit eigenem Anmeldeformular, fuer die die Einstellungen einen eigenen Zugang erlauben (LUH)
    enum Portal: String, CaseIterable, Identifiable, Sendable {
        case studip, qis, sogo

        var id: String { rawValue }

        /// Anzeige in den Einstellungen
        var title: String {
            switch self {
            case .studip: return "Stud.IP"
            case .qis: return "QIS"
            case .sogo: return "Uni-Mail (SOGo)"
            }
        }

        /// Name in `StoredLoginReport` (wie `connected`/`needsLogin`)
        var reportName: String {
            switch self {
            case .studip: return "Stud.IP"
            case .qis: return "QIS"
            case .sogo: return "Uni-Mail"
            }
        }
    }

    // MARK: Schalter "überall gleich" (kein Geheimnis, UserDefaults der App)

    static let sameEverywhereKey = "uniLogin.sameEverywhere"
    /// Tests: eigene UserDefaults statt `.standard`
    static var settingsDefaultsOverride: UserDefaults?
    private static var settingsDefaults: UserDefaults { settingsDefaultsOverride ?? .standard }

    /// "Benutzername und Passwort sind überall gleich" (Vorgabe an)
    static var sameEverywhere: Bool {
        get { settingsDefaults.object(forKey: sameEverywhereKey) as? Bool ?? true }
        set {
            settingsDefaults.set(newValue, forKey: sameEverywhereKey)
            // anderer Zugang gilt ab jetzt: Ruecknahme und Stand der stillen Anmeldung frisch
            for e in entries.values where e.store != nil { e.states = [:] }
        }
    }

    // MARK: Offener Container

    /// Datenspeicher des offenen Containers (`ContainerManager.activate`); fuer die Aufrufe ohne `store`
    private(set) static weak var currentStore: WKWebsiteDataStore?

    static func makeCurrent(_ store: WKWebsiteDataStore?) { currentStore = store }

    private static func resolve(_ store: WKWebsiteDataStore?) -> Entry? { (store ?? currentStore).flatMap { entry($0) } }

    // MARK: Eintraege (nil = gemeinsamer Zugang)

    static func vault(_ e: Entry, _ slot: Portal?) -> UniCredentialStore { slot.map { e.vault.portal($0) } ?? e.vault }

    /// Merker im Container: Passwort dieses Eintrags abgelehnt (kein Geheimnis)
    static func rejectedKey(_ slot: Portal?) -> String { "uniLogin.rejected." + (slot?.rawValue ?? "shared") }
    /// Merker im Container: bei diesem Portal bewusst abgemeldet
    static func signedOutKey(_ portal: Portal) -> String { "uniLogin.signedOut." + portal.rawValue }

    /// Portal zu einem Dienst von `handleExpiry` ("studip", "qis", "sogo"); andere Dienste nur mit dem gemeinsamen Zugang
    static func portal(named name: String) -> Portal? { Portal(rawValue: name) }

    /// Zugang, der fuer dieses Portal gilt, und der Eintrag, aus dem er kommt (nil = gemeinsamer). Ohne Zustimmung
    /// ("Automatisch anmelden" aus) nichts.
    static func resolvedCredential(_ portal: Portal?, entry e: Entry) -> (credential: UniCredential, slot: Portal?)? {
        guard isEnabled(e.defaults) else { return nil }
        if let portal, !sameEverywhere, let own = vault(e, portal).load() { return (own, portal) }
        return e.vault.load().map { ($0, nil) }
    }

    // MARK: Schnittstelle der Einstellungen

    /// Zugang fuer ein Portal von Hand speichern (Einstellungen, Schalter aus). Wie `saveTyped(username:password:store:)`.
    static func saveTyped(username: String, password: String, portal: Portal, store: WKWebsiteDataStore,
                          now: Date = Date()) -> TypedSave {
        save(slot: portal, username: username, password: password, store: store, now: now)
    }

    /// Benutzername eines Eintrags (nil = gemeinsamer Zugang; ohne Rueckgriff auf den gemeinsamen)
    static func storedUsername(portal: Portal?, store: WKWebsiteDataStore? = nil) -> String? {
        resolve(store).flatMap { vault($0, portal).load()?.username }
    }

    /// Liegt fuer diesen Eintrag ein Passwort im Schluesselbund? (nil = gemeinsamer Zugang)
    static func hasPassword(portal: Portal?, store: WKWebsiteDataStore? = nil) -> Bool {
        resolve(store).map { vault($0, portal).load() != nil } ?? false
    }

    /// Hat die Hochschule das Passwort dieses Eintrags abgelehnt? (Merker bis zum naechsten Speichern)
    static func isRejected(portal: Portal?, store: WKWebsiteDataStore? = nil) -> Bool {
        resolve(store)?.defaults.bool(forKey: rejectedKey(portal)) ?? false
    }

    /// "Entfernen" in den Einstellungen: nur dieser Eintrag (nil = gemeinsamer Zugang)
    static func forget(portal: Portal?, store: WKWebsiteDataStore? = nil) {
        guard let e = resolve(store) else { return }
        vault(e, portal).clear()
        e.defaults.removeObject(forKey: rejectedKey(portal))
        e.pending = nil
        e.states = [:]
    }

    /// sameEverywhere -> gemeinsamer Zugang; sonst Eintrag des Portals, fehlt er, der gemeinsame
    static func credential(for portal: Portal, store: WKWebsiteDataStore? = nil) -> (username: String, password: String)? {
        guard let e = resolve(store), let r = resolvedCredential(portal, entry: e) else { return nil }
        return (r.credential.username, r.credential.password)
    }

    // MARK: Abmelden-Sperre

    /// Bei diesem Portal bewusst abgemeldet (kein stilles Wiederverbinden)?
    static func signedOut(_ portal: Portal, store: WKWebsiteDataStore) -> Bool {
        entry(store)?.defaults.bool(forKey: signedOutKey(portal)) ?? false
    }

    /// "Abmelden" bei einem Portal
    static func markSignedOut(_ portal: Portal, store: WKWebsiteDataStore) {
        entry(store)?.defaults.set(true, forKey: signedOutKey(portal))
    }

    /// Der Mensch hat sich bei diesem Portal angemeldet (bzw. es verbunden): Sperre weg
    static func clearSignedOut(_ portal: Portal, store: WKWebsiteDataStore) {
        entry(store)?.defaults.removeObject(forKey: signedOutKey(portal))
    }

    // MARK: Intern

    /// Speichern in einen Eintrag (nil = gemeinsamer Zugang). Speichern heisst zustimmen: Schalter an, Merker
    /// "abgelehnt" weg, Ruecknahme der stillen Anmeldung frisch; die Abmelden-Sperre der betroffenen Portale faellt
    /// (der Mensch will sie jetzt verbinden).
    static func save(slot: Portal?, username: String, password: String, store: WKWebsiteDataStore, now: Date) -> TypedSave {
        guard let e = entry(store) else { return .unavailable }
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UniLoginForms.isAcceptableUsername(u) else { return .badUsername }
        guard UniLoginForms.isAcceptablePassword(password) else { return .badPassword }
        guard (try? vault(e, slot).save(UniCredential(username: u, password: password, savedAt: now))) != nil else { return .failed }
        e.defaults.set(true, forKey: enabledKey)
        e.defaults.removeObject(forKey: rejectedKey(slot))
        for p in slot.map({ [$0] }) ?? Portal.allCases { e.defaults.removeObject(forKey: signedOutKey(p)) }
        e.pending = nil
        e.states = [:]
        return .saved
    }

    /// Die Hochschule hat `credential` aus `slot` abgelehnt: diesen Eintrag vergessen und jeden anderen mit genau
    /// demselben Benutzernamen und Passwort (nie ein zweites Mal senden, auch nicht bei einem anderen Portal)
    static func reject(_ credential: UniCredential, slot: Portal?, entry e: Entry) {
        let slots: [Portal?] = [nil] + Portal.allCases.map { Optional($0) }
        for s in slots {
            let v = vault(e, s)
            guard s == slot || v.load().map({ $0.username == credential.username && $0.password == credential.password }) == true else { continue }
            v.clear()
            e.defaults.set(true, forKey: rejectedKey(s))
        }
    }

    /// Alle Eintraege des Containers vergessen (Abmelden, Schalter aus, "Gespeichertes Passwort löschen")
    @discardableResult
    static func forgetAll(entry e: Entry) -> Bool {
        let slots: [Portal?] = [nil] + Portal.allCases.map { Optional($0) }
        var ok = true
        for s in slots {
            if !vault(e, s).clear() { ok = false }
            e.defaults.removeObject(forKey: rejectedKey(s))
        }
        return ok
    }
}

extension UniCredentialStore {
    /// Eintrag eines Portals (`uni-login.<container-uuid>.<portal>`), gleicher Dienst und gleiche Schutzklasse
    func portal(_ p: UniAutoLogin.Portal) -> UniCredentialStore { UniCredentialStore(store: store, account: account + "." + p.rawValue) }

    /// Gemeinsamer Eintrag und alle Eintraege der Portale (Daten dieser Hochschule loeschen, Konto loeschen)
    @discardableResult
    func clearAll() -> Bool {
        var ok = clear()
        for p in UniAutoLogin.Portal.allCases where !portal(p).clear() { ok = false }
        return ok
    }

    /// Liegt noch irgendein Eintrag (gemeinsam oder je Portal)?
    func hasAny() -> Bool { load() != nil || UniAutoLogin.Portal.allCases.contains { portal($0).load() != nil } }
}
