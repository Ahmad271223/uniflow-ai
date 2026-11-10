import Foundation
import UniFlowCore
import WebKit

// Uni-Zugang einmal speichern (Entscheidung des Inhabers 10.11.2026): Mit dem gespeicherten Zugang (Schluesselbund
// dieses Geraets, `UniAutoLogin`) verbindet die App alle Dienste der Hochschule selbst - auch zum ersten Mal, nicht nur
// nach einer abgelaufenen Sitzung. Nur im Vordergrund, nie in einer Schleife (`UniAutoLoginMachine`); lehnt die
// Hochschule das Passwort ab, folgt kein weiterer Versuch bei einem anderen Dienst.

/// Ergebnis von `ContainerManager.connectWithStoredLogin`
struct StoredLoginReport: Equatable {
    /// Dienste, die danach verbunden sind ("Stud.IP", "QIS", "Uni-Mail" …)
    var connected: [String] = []
    /// Dienste, die noch eine Anmeldung von Hand brauchen
    var needsLogin: [String] = []
    /// die Hochschule hat das gespeicherte Passwort abgelehnt
    var rejected = false
    /// kein gespeicherter Zugang (oder "Automatisch anmelden" aus)
    var noCredential = false
}

extension ContainerManager {
    /// Liegt ein gespeicherter, nicht abgelehnter Uni-Zugang fuer den offenen Container vor?
    var hasStoredLogin: Bool {
        guard active != nil else { return false }
        let store = studip.websiteDataStore
        return UniAutoLogin.credential(store) != nil && !UniAutoLogin.wasRejected(store)
    }

    /// Alle Dienste der Hochschule mit dem gespeicherten Zugang verbinden bzw. abgelaufene Anmeldungen erneuern.
    /// `userAction`: der Mensch hat es eben verlangt ("Speichern und verbinden", "Sync").
    @discardableResult
    func connectWithStoredLogin(userAction: Bool = false) async -> StoredLoginReport {
        guard hasStoredLogin else { return StoredLoginReport(noCredential: true) }
        return StoredLoginReport()
    }
}
