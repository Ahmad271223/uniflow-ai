import SwiftUI
import UniFlowCore

// Demo-Inhalte nur fuer die App-Pruefung (Entscheidung des Inhabers 04.11.2026 "Nur für Prüfer", ersetzt den Stand vom
// 27.10.2026 mit dem Weg ueber Einstellungen -> Erweitert): dieselben Inhalte wie am PC (app/demo.py, im Kern
// `DemoContent`, `POST /api/demo`), im Container des angemeldeten Nutzers und der gewaehlten Hochschule. Normale Nutzer
// sehen die Demo nirgends; der EINZIGE Weg ist der kleine Textlink "Ohne Hochschulkonto ansehen (Demo)" ganz unten auf
// der Anmeldeseite der Hochschule im ersten Start (die Pruefhinweise in docs/release/APP-STORE.md nennen ihn wortgleich).
// Solange die Demo aktiv ist: schmale Leiste "Demo-Inhalte – erfunden, ohne Hochschule" mit "Beenden" ueber jeder Seite
// (App-Huelle), keine Karten "… verbinden", kein Abgleich mit der Hochschule (die Abgleiche fragen die Datenbank,
// `LocalBackendHost.demoActive`), keine Anmeldung noetig. "Beenden" entfernt alles, was die Demo angelegt hat, und
// fuehrt zurueck zur Anmeldeseite. Entwicklung: -UFDemo YES legt sie beim Start an (nur Debug).

private struct UFDemoActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct UFDemoBarHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct UFProAIOfferHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Demo-Inhalte im offenen Container aktiv (`ContainerManager.demoActive`, gesetzt in UniFlowApp)
    var ufDemoActive: Bool {
        get { self[UFDemoActiveKey.self] }
        set { self[UFDemoActiveKey.self] = newValue }
    }

    /// Nur Tests: die Demo-Leiste ausblenden (Store-Bildschirmfotos aus den Demo-Inhalten ohne "Demo"-Leiste,
    /// StoreScreenshotTests); die App setzt das nie
    var ufDemoBarHidden: Bool {
        get { self[UFDemoBarHiddenKey.self] }
        set { self[UFDemoBarHiddenKey.self] = newValue }
    }

    /// Nur Tests: kein "Pro AI holen" in der Seitenleiste und kein Knopf "KI-Hilfe" im Dokument (Store-Bildschirmfotos
    /// der Fassung nur mit Plus, StoreScreenshotV11Tests: Pro AI ist dort nicht zu kaufen); die App setzt das nie
    var ufProAIOfferHidden: Bool {
        get { self[UFProAIOfferHiddenKey.self] }
        set { self[UFProAIOfferHiddenKey.self] = newValue }
    }
}

/// Texte der Demo (eine Stelle, DemoAppTests)
enum DemoTexts {
    static let barTitle = "Demo-Inhalte – erfunden, ohne Hochschule"
    static let barEnd = "Beenden"
    static let firstStart = "Ohne Hochschulkonto ansehen (Demo)"
    static let firstStartRunning = "Demo wird angelegt …"
    static let confirmEnd = "Demo beenden? Das Demo-Modul mit PDFs, Terminen, Lernpaketen und Notizen dazu verschwindet, danach kommt wieder die Anmeldeseite der Hochschule."
    static let ended = "Demo beendet"
    static let syncBlocked = "Demo-Inhalte aktiv: StudiNow gleicht nicht mit der Hochschule ab. Zum Anmelden die Demo oben mit „Beenden“ verlassen."
}

/// Anlegen und Entfernen fuer die Oberflaeche: lokal ueber den Container (mit den Kopien auf dem Geraet), mit eigenem
/// Server (nur Entwicklung) dessen `/api/demo`
@MainActor
enum DemoActions {
    static func set(_ on: Bool, session: Session, containers: ContainerManager) async throws -> JSONValue {
        if session.isOwnServer, let api = session.api {
            return try await api.value("/api/demo", method: "POST", body: ["enabled": .bool(on)])
        }
        return try await containers.setDemo(on)
    }

    /// "Beenden": alles entfernen, was die Demo angelegt hat (`ContainerManager.setDemo(false)`), dann zurueck zur
    /// Anmeldeseite der Hochschule (`AccountStore.resetLoginStep`), dort wieder mit dem Link zur Demo
    static func end(session: Session, containers: ContainerManager, account: AccountStore, router: UFRouter) async throws {
        _ = try await set(false, session: session, containers: containers)
        router.go(.dashboard)                                    // nach erneutem Anmelden nicht auf einer Demo-Seite
        account.resetLoginStep()
    }
}

/// Schmale Leiste oben in der App-Huelle, solange die Demo aktiv ist: "Demo-Inhalte – erfunden, ohne Hochschule" mit
/// "Beenden" (Pruefer sehen, wo sie sind, und kommen wieder heraus)
struct DemoActiveBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @State private var busy = false

    var body: some View {
        HStack(spacing: 9.6) {
            UFIcon("sparkles", size: 15).foregroundStyle(UF.accentText)
            Text(DemoTexts.barTitle).ufFont(13.12, 600).foregroundStyle(UF.accentText)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            UFButton(DemoTexts.barEnd, icon: "log-out", size: .small) { Task { await end() } }
                .disabled(busy)
                .accessibilityIdentifier("demo.end")
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(UF.accentSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("demo.bar")
    }

    private func end() async {
        guard await overlay.confirm(DemoTexts.confirmEnd) else { return }
        busy = true
        defer { busy = false }
        do {
            try await DemoActions.end(session: session, containers: containers, account: account, router: router)
            toast.show(DemoTexts.ended, seconds: 3)
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }
}
