import Foundation
import UniFlowCore
import WebKit

// Uni-Zugang einmal speichern (Entscheidung des Inhabers 10.11.2026): Mit dem gespeicherten Zugang (Schluesselbund
// dieses Geraets, `UniAutoLogin`, gemeinsam oder je Portal, UniPortalLogins.swift) verbindet die App alle Dienste der
// Hochschule selbst - auch zum ersten Mal, nicht nur nach einer abgelaufenen Sitzung. Reihenfolge Stud.IP (WebSSO),
// QIS, Uni-Mail (SOGo); jede Verbindung holt danach ihre Daten (wie nach einer Anmeldung von Hand).
// - Nur im Vordergrund, nie in einer Schleife (`UniAutoLoginMachine`), nie zwei Laeufe zugleich.
// - Lehnt die Hochschule ein Passwort ab, wird es nie ein zweites Mal gesendet, auch nicht bei einem anderen Dienst:
//   der benutzte Eintrag (und jeder gleiche) ist danach vergessen (`UniAutoLogin.reject`). Mit dem gemeinsamen Zugang
//   stoppt das alle Dienste, mit getrennten Zugaengen nur diesen.
// - Ein Dienst, bei dem sich der Mensch bewusst abgemeldet hat, wird nicht still wieder verbunden
//   (`UniAutoLogin.signedOut`), bis er sich dort anmeldet oder in den Einstellungen neu speichert.
// - Mit Demo-Inhalten nie zur Hochschule.

/// Ergebnis von `ContainerManager.connectWithStoredLogin`
struct StoredLoginReport: Equatable {
    /// Dienste, die danach verbunden sind ("Stud.IP", "QIS", "Uni-Mail" …)
    var connected: [String] = []
    /// Dienste, die noch eine Anmeldung von Hand brauchen (auch die mit abgelehntem Passwort)
    var needsLogin: [String] = []
    /// die Hochschule hat das gespeicherte Passwort abgelehnt
    var rejected = false
    /// kein gespeicherter Zugang (oder "Automatisch anmelden" aus)
    var noCredential = false
    /// Dienste, deren Passwort die Hochschule abgelehnt hat ("Stud.IP", "QIS", "Uni-Mail"); mit dem gemeinsamen Zugang
    /// alle, die ihn benutzen
    var rejectedPortals: [String] = []
}

extension ContainerManager {
    /// Liegt ein gespeicherter, nicht abgelehnter Uni-Zugang fuer den offenen Container vor (gemeinsam oder fuer ein
    /// Portal)? Abgelehnte Passwoerter sind schon vergessen (`UniAutoLogin.reject`).
    var hasStoredLogin: Bool {
        guard active != nil, let e = UniAutoLogin.entry(studip.websiteDataStore) else { return false }
        if UniAutoLogin.resolvedCredential(nil, entry: e) != nil { return true }
        return UniAutoLogin.Portal.allCases.contains { UniAutoLogin.resolvedCredential($0, entry: e) != nil }
    }

    /// Alle Dienste der Hochschule mit dem gespeicherten Zugang verbinden bzw. abgelaufene Anmeldungen erneuern.
    /// `userAction`: der Mensch hat es eben verlangt ("Speichern", "Sync"): ohne Ruecknahme nach Fehlschlaegen.
    /// Laeuft schon ein Lauf, wartet ein zweiter darauf (mit `userAction` beginnt er danach einen eigenen).
    @discardableResult
    func connectWithStoredLogin(userAction: Bool = false) async -> StoredLoginReport {
        if let running = storedLoginRun {
            let r = await running.value
            guard userAction else { return r }
        }
        let task = Task { @MainActor in await self.performStoredLogin(userAction: userAction) }
        storedLoginRun = task
        let r = await task.value
        if storedLoginRun == task { storedLoginRun = nil }
        return r
    }

    /// Stand eines Dienstes vor dem Verbinden
    private enum PortalStand { case connected, expired, notConnected }

    private func stand(_ p: UniAutoLogin.Portal) -> PortalStand? {
        switch p {
        case .studip:
            guard studip.offersStudIP else { return nil }
            if !studip.hasStoredSession { return .notConnected }
            return studip.sessionKnownExpired ? .expired : .connected
        case .qis:
            guard let qis else { return nil }
            if !qis.isConnected { return .notConnected }
            return qis.state == .needsLogin ? .expired : .connected
        case .sogo:
            guard let uniMail else { return nil }
            if !uniMail.isConnected { return .notConnected }
            return uniMail.state == .needsLogin ? .expired : .connected
        }
    }

    /// Gilt fuer diesen Dienst ein Merker "abgelehnt"? (eigener Eintrag bei getrennten Zugaengen, sonst der gemeinsame)
    private func rejectionApplies(_ p: UniAutoLogin.Portal, store: WKWebsiteDataStore) -> Bool {
        if UniAutoLogin.isRejected(portal: nil, store: store) { return true }
        return !UniAutoLogin.sameEverywhere && UniAutoLogin.isRejected(portal: p, store: store)
    }

    private func performStoredLogin(userAction: Bool) async -> StoredLoginReport {
        guard let c = active else { return StoredLoginReport(noCredential: true) }
        let store = studip.websiteDataStore
        var r = StoredLoginReport()
        let present = UniAutoLogin.Portal.allCases.filter { stand($0) != nil }
        guard hasStoredLogin, let e = UniAutoLogin.entry(store) else {
            r.noCredential = true
            r.rejectedPortals = present.filter { rejectionApplies($0, store: store) }.map(\.reportName)
            r.rejected = !r.rejectedPortals.isEmpty
            return r
        }
        // nie im Hintergrund (dort fehlt die unsichtbare Webansicht), nie mit Demo-Inhalten
        guard UniAutoLogin.appActive else { return r }
        if await c.host.demoActive() { return r }
        for p in present {
            guard active === c, let stand = stand(p) else { break }
            let name = p.reportName
            if stand == .connected { r.connected.append(name); continue }
            // bewusst abgemeldet: nicht still wieder verbinden (und nicht als "Anmeldung nötig" melden)
            if stand == .notConnected, UniAutoLogin.signedOut(p, store: store) { continue }
            guard let used = UniAutoLogin.resolvedCredential(p, entry: e) else {
                r.needsLogin.append(name)
                if rejectionApplies(p, store: store) { r.rejectedPortals.append(name) }
                continue
            }
            let ok = stand == .expired ? await renew(p, userAction: userAction) : await connectFirst(p, userAction: userAction)
            guard active === c else { break }
            if ok {
                r.connected.append(name)
            } else {
                r.needsLogin.append(name)
                if UniAutoLogin.isRejected(portal: used.slot, store: store) { r.rejectedPortals.append(name) }
            }
        }
        // Dienste ohne eigenen Zugang je Portal (Uni Hildesheim, HsH): abgelaufene Anmeldungen still erneuern
        if active === c, let hildesheim {
            r.needsLogin += await hildesheim.renewSilently().map(\.rawValue)
        }
        if active === c, let hsh {
            for s in HsHConnection.Source.allCases where hsh.isConnected(s) && hsh.state(s) == .needsLogin {
                if await hsh.autoLogin(s) { r.connected.append(s.rawValue) } else { r.needsLogin.append(s.rawValue) }
            }
        }
        r.rejected = !r.rejectedPortals.isEmpty
        return r
    }

    /// Abgelaufene Anmeldung still erneuern (wie `renewExpiredSessions`)
    private func renew(_ p: UniAutoLogin.Portal, userAction: Bool) async -> Bool {
        switch p {
        case .studip:
            return await studip.renewSilently(trigger: userAction ? .userAction : .foreground)
        case .qis:
            return await qis?.autoLogin(userAction: userAction) ?? false
        case .sogo:
            // kein eigener Abruf hier: der Sync bzw. die naechste Aktion liest den Posteingang (nie zwei Abrufe zugleich)
            return await uniMail?.autoLogin(userAction: userAction) ?? false
        }
    }

    /// Noch nie verbunden: zum ersten Mal mit dem gespeicherten Zugang anmelden; danach holt der Dienst seine Daten
    private func connectFirst(_ p: UniAutoLogin.Portal, userAction: Bool) async -> Bool {
        switch p {
        case .studip: return await studip.connectWithStoredLogin(userAction: userAction)
        case .qis: return await qis?.connectWithStoredLogin(userAction: userAction) ?? false
        case .sogo: return await uniMail?.connectWithStoredLogin(userAction: userAction) ?? false
        }
    }
}
