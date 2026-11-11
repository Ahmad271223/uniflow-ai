import Foundation
import Security
import SwiftUI
import UniFlowCore

/// Eigener OpenAI-Schluessel im Schluesselbund dieses Geraets, je Apple-Nutzer (`DataContainerKey.userScope`):
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (Standard von `KeychainStore`), nie synchronisiert, nie beim
/// Dienst, nie im Geraete-Abgleich. Konto loeschen entfernt ihn (`ContainerManager.deleteAllData`).
struct OpenAIKeyKeychainStore: OpenAIKeyStateStore {
    static let service = "de.uniflow.ai.openai-key"
    let userScope: String
    private var keychain: KeychainStore { KeychainStore(service: Self.service) }

    func load() -> OpenAIKeyState? {
        keychain.data(userScope).flatMap { try? JSONDecoder().decode(OpenAIKeyState.self, from: $0) }
    }

    func save(_ state: OpenAIKeyState) throws { try keychain.write(JSONEncoder().encode(state), account: userScope) }

    func remove() throws {
        guard keychain.remove(userScope) else { throw KeychainStore.Failure(status: errSecInteractionNotAllowed) }
    }

    /// true, wenn danach nichts mehr da ist
    @discardableResult
    static func remove(userScope: String) -> Bool { KeychainStore(service: service).remove(userScope) }
}

/// "Eigenes ChatGPT" ueber den eigenen OpenAI-API-Schluessel (Auftrag des Inhabers vom 07.11.2026): Schluessel
/// eintragen und pruefen (`GET /v1/models`), Modell waehlen, Schalter, Schluessel loeschen. Ist er eingetragen und
/// eingeschaltet, beantwortet das lokale Backend die KI-Endpunkte damit (`LocalAI.setKey`) - in jedem Tarif, auch
/// Free (Entscheidung 05.11.2026) - und der automatische Lernplan ist auch ohne Plus frei
/// (`Entitlements.ownChatGPTConnected`). Braucht keine Freigabe von OpenAI (anders als Sign in with ChatGPT, `ChatGPTLink`).
@MainActor
final class OpenAIKeyLink: ObservableObject {
    /// Schalter "Eigenes ChatGPT" (Vorgabe des Inhabers 11.11.2026: „dein ChatGPT erstmal überall entfernen“): aus =
    /// keine Karte unter Einstellungen → Erweitert, keine Zeile auf den Tarifkarten, keine Hinweise darauf; ein frueher
    /// eingetragener Schluessel bleibt im Schluesselbund, wird aber nicht benutzt (die KI kommt nur ueber die
    /// StudiNow-KI). Wieder an: auf true setzen. Tests der Funktion schalten ihn fuer sich ein.
    nonisolated(unsafe) static var isOffered = false

    @Published private(set) var status: OpenAIKeySession.Status?
    @Published private(set) var models: [String] = []
    @Published private(set) var busy = false
    /// Meldung unter der Karte (Fehler oder Erfolg der Pruefung)
    @Published var message: String?
    /// letzte Pruefung in dieser Sitzung gelungen (gruener Hinweis)
    @Published private(set) var lastCheckOK = false

    private(set) var session: OpenAIKeySession?
    private var scope: String?
    private var host: LocalBackendHost?
    /// Transport (Tests: Schein-OpenAI)
    var transport: AIHTTPTransport = URLSessionAITransport()

    /// Hinweis vor dem Eintragen: was passiert, was gesendet wird, was es kostet
    static let consentText = UFDevice.adapt("Dein Schlüssel bleibt im Schlüsselbund dieses iPads und geht nie an StudiNow. Wenn du eine KI-Funktion antippst (Frage im Editor, Karteikarten, Wochentest, KI-Lernplan), schickt StudiNow den Text der Seite oder deiner Markierung, deine Frage und die Namen von Kurs und Datei – beim Lernplan nur Modultitel, Lehrwochen, Dateinamen und Zeiten – direkt an OpenAI. Die Anfragen rechnet OpenAI über dein Konto ab (platform.openai.com); es gelten die Bedingungen und die Datenschutzerklärung von OpenAI.")

    static let checkedText = "Schlüssel geprüft – OpenAI hat geantwortet."

    /// KI-Anfragen gerade moeglich
    var enabled: Bool { Self.isOffered && status?.enabledForAI == true }

    /// Container geoeffnet oder geschlossen: Schluessel des Apple-Nutzers laden und ins Backend haengen
    func use(userScope: String?, host: LocalBackendHost?) {
        self.host = host
        if userScope != scope {
            scope = userScope
            models = []
            message = nil
            lastCheckOK = false
            session = userScope.map { OpenAIKeySession(store: OpenAIKeyKeychainStore(userScope: $0), http: transport) }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let session, Self.isOffered else {
            status = nil
            await attach(nil)
            publishEntitlement(false)
            return
        }
        let s = await session.status
        status = s
        await attach(s.enabledForAI ? session : nil)
        publishEntitlement(s.enabledForAI)
    }

    private func attach(_ provider: AIProvider?) async {
        guard let host, let backend = try? await host.backend() else { return }
        backend.context.ai.setKey(provider)
    }

    /// Automatischer Lernplan auch ohne Plus, sobald der eigene Schluessel arbeitet (UFFeature.autoPlan)
    private func publishEntitlement(_ on: Bool) {
        if Entitlements.shared.ownChatGPTConnected != on { Entitlements.shared.ownChatGPTConnected = on }
    }

    // MARK: Schluessel

    /// Schluessel eintragen und gleich pruefen; bei ungueltiger Form bleibt der alte Stand
    func save(key: String) async {
        guard let session, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        lastCheckOK = false
        do {
            try await session.setKey(key)
        } catch let e as AIError {
            message = e.message
            return
        } catch {
            message = "Schlüssel konnte nicht gespeichert werden: \(error.localizedDescription)"
            return
        }
        await refresh()
        await test()
    }

    /// "Verbindung testen": Modelle laden; ein abgelehnter Schluessel meldet sich hier
    func test() async {
        guard let session else { return }
        let wasBusy = busy
        busy = true
        defer { busy = wasBusy }
        do {
            models = try await session.test()
            lastCheckOK = true
            message = models.isEmpty ? "OpenAI hat geantwortet, nennt aber kein Chat-Modell für diesen Schlüssel." : Self.checkedText
        } catch let e as AIError {
            lastCheckOK = false
            message = e.message
        } catch {
            lastCheckOK = false
            message = error.localizedDescription
        }
        await refresh()
    }

    func loadModels() async {
        guard let session, status?.hasKey == true else { return }
        do { models = try await session.models() } catch let e as AIError { message = e.message } catch {}
        await refresh()
    }

    func setModel(_ slug: String) async {
        do { try await session?.setModel(slug) } catch let e as AIError { message = e.message } catch {}
        await refresh()
    }

    func setUseForAI(_ on: Bool) async {
        try? await session?.setUseForAI(on)
        await refresh()
    }

    /// Schluessel vom Geraet loeschen
    func remove() async {
        guard let session else { return }
        do { try await session.removeKey() } catch { message = "Löschen fehlgeschlagen: \(error.localizedDescription)" }
        models = []
        lastCheckOK = false
        if message == Self.checkedText { message = nil }
        await refresh()
    }
}
