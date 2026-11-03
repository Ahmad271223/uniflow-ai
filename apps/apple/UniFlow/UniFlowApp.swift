import SwiftUI
import UniFlowCore

/// Einstieg der nativen iPad-App. Erster Start nach docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a
/// (Views/Onboarding/OnboardingFlow.swift); die Handschrift laeuft nativ ueber PencilKit
/// (siehe Editor/PDFEditorController.swift). Der eigene UniFlow-Server ist nur noch ein Entwicklungsmodus.
@main
struct UniFlowApp: App {
    @StateObject private var account: AccountStore
    /// Container je (Apple-Nutzer, Hochschule) mit Datenbank, Dateien, Notizen und Anmeldungen
    @StateObject private var containers: ContainerManager
    @StateObject private var session: Session
    @StateObject private var router = UFRouter()
    @StateObject private var shell = ShellState()
    @StateObject private var toast = UFToastCenter()
    @StateObject private var overlay = UFOverlay()
    @StateObject private var timer = StudyTimer()
    /// Abgleich im Hintergrund (S8): Aufgaben bei iOS, Termine fruehestens 8, 15 und 20 Uhr
    @StateObject private var background: BackgroundSyncController
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase
    /// gemeinsame Wochentests im Vordergrund alle 10 min (am PC `_weekly_loop`)
    @State private var weeklyTicker = WeeklyAutoTicker()

    init() {
        // Teilen-Dateien und empfangene Kopien frueherer Laeufe liegen ausserhalb der Container: weg (AppTemp; von
        // der Inbox nur alte Kopien, die eben empfangene oeffnet onOpenURL gleich)
        AppTemp.purgeAtLaunch()
        SolutionSharing.purgeStaleInbox()
        DataSourceMigration.run()                                         // alte Journale in den Server-Namensraum, am alten Ort vor dem Umzug
        // Tarif von Anfang an beobachten (Transaction.updates: Verlaengerung, Widerruf, freigegebene Kaufanfrage, Kauf
        // auf einem anderen Geraet) und unfertige Transaktionen abschliessen – nicht erst, wenn eine Ansicht mit
        // Tarifpruefung erscheint (Pruefpunkt 223)
        _ = Entitlements.shared
        DueNotificationDelegate.install()                                 // Antippen einer Erinnerung oeffnet die Quelle; fragt nichts
        let a = AccountStore()
        DebugLaunch.prepare(account: a)                                   // -UFOnboarding/-UFUniversity vor dem ersten Bild
        let c = ContainerManager(hildesheimTransport: DebugUniStub.transportFactory, qisTransport: DebugUniStub.transportFactory)
        c.sync(account: a)                                                // alte Daten umziehen, Container der Hochschule oeffnen
        let s = Session(local: c.active?.api ?? .local(.unavailable))
        c.onChange = { [weak s] container in s?.useLocal(container?.api ?? .local(.unavailable)) }
        // Hintergrundaufgaben vor dem Ende des App-Starts bei iOS anmelden, dann den naechsten Termin bestellen ("beim
        // Start"); nie unter XCTest (Tests bauen eigene mit Attrappen)
        let b = BackgroundSyncController(containers: c, account: a)
        if !StudIPSync.isUnderTest() {
            b.register()
            Task { await b.schedule() }
        }
        _account = StateObject(wrappedValue: a)
        _containers = StateObject(wrappedValue: c)
        _session = StateObject(wrappedValue: s)
        _background = StateObject(wrappedValue: b)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Links aus KI-Antworten, Stud.IP-Texten usw.: nur http(s) ins System, alles andere verwerfen
                // (uniflow:// aus fremdem Text nie; Sicherheitspruefung 3.11.2026)
                .environment(\.openURL, OpenURLAction { SafeLinks.action(for: $0) })
                .modifier(StudyTimerHost(timer: timer, toast: toast))      // Zeitmesser unter Dialogen und Meldungen
                .modifier(UFModalHost(overlay: overlay))                 // Dialoge innerhalb der Umgebungsobjekte
                .modifier(UFToastOverlay(center: toast))
                .environmentObject(account)
                .environmentObject(containers)
                .environmentObject(session)
                .environmentObject(containers.studip)                     // Abgleich des offenen Containers
                .environment(\.ufChatGPTLink, containers.chatgpt)          // KI ueber das ChatGPT-Abo des Nutzers
                .environment(\.ufStudoraAccount, containers.account)       // Studora-Konto (mit Dienst-Adresse)
                .modifier(UFAIEnabledProvider(link: containers.chatgpt))
                .environment(\.hildesheim, containers.hildesheim)          // Learnweb und LSF (nur Uni Hildesheim)
                .environment(\.qis, containers.qis)                        // QIS-Noten (nur LUH)
                .environment(\.backgroundSync, background)                 // Karte "Im Hintergrund abgleichen"
                .environment(\.ufDemoActive, containers.demoActive)        // Demo-Inhalte: Hinweis statt "… verbinden"
                .environmentObject(router)
                .environmentObject(shell)
                .environmentObject(toast)
                .environmentObject(overlay)
                .environmentObject(timer)
                .preferredColorScheme((UFThemeMode(rawValue: theme) ?? .light).scheme)
                .tint(UF.accent)
                .onOpenURL { url in
                    // Datei *.uniflowsolution (AirDrop, Dateien, "Öffnen in"): verschluesselt ablegen; sie erscheint im
                    // passenden Dokument unter "Ebenen" (docs/LOESUNGEN-TEILEN.md)
                    if SolutionSharing.isSolutionFile(url) {
                        // Loesungen gehoeren in den Container des Kontos und der Hochschule
                        guard containers.active != nil else {
                            SolutionSharing.discardReceivedCopy(url)
                            toast.show("Melde dich zuerst an und wähle deine Hochschule. Öffne die Lösung danach erneut.", seconds: 4)
                            return
                        }
                        // Lesen und Pruefen abseits des Hauptthreads (Pakete bis rund 65 MB)
                        Task {
                            // die Kopie in Documents/Inbox gehoert zu keinem Container: danach immer weg
                            defer { SolutionSharing.discardReceivedCopy(url) }
                            do {
                                let e = try await SolutionSharing.importFileDetached(url)
                                let label = ForeignSolutionLayer.label(displayName: e.displayName, createdAt: e.createdAt)
                                toast.show(SolutionSharing.receivedMessage(label: label, canView: Entitlements.shared.allows(.communityRead)), seconds: 5)
                            } catch {
                                toast.show((error as? SolutionError)?.description ?? "Die Lösung lässt sich nicht öffnen.", seconds: 4)
                            }
                        }
                        return
                    }
                    // QR-Code einer Lerngruppe (uniflow://community/join/<Code>): beitreten (Lesen, auch in Free; nur mit
                    // Container). Anlegen braucht Plus (CommunitySettingsCard).
                    if let code = CommunityJoinLink.code(from: url) {
                        guard containers.active != nil, Entitlements.shared.allows(.communityRead) else {
                            toast.show("Lerngruppen gibt es nach Anmeldung und Hochschulwahl.", seconds: 4)
                            return
                        }
                        Task {
                            do {
                                // erst bestaetigen, mit dem Namen der Gruppe (ein fremder Link tritt nie still bei)
                                let name = try await SolutionSharing.community.studyGroupName(code: code)
                                guard await overlay.confirm(CommunityJoinLink.confirmText(name: name)) else { return }
                                let g = try await SolutionSharing.community.joinStudyGroup(code: code)
                                toast.show("Lerngruppe „\(g.name)“ beigetreten.", seconds: 4)
                            } catch {
                                toast.show(CommunityTexts.message(error), seconds: 4)
                            }
                        }
                        return
                    }
                    // uniflow://#/plan?view=week -> dieselbe Hash-Route wie in der Web-App
                    if let hash = UFRoute.hash(fromDeepLink: url) { router.go(hash: hash) }
                }
                .task {
                    #if DEBUG
                    // -UFDemo YES: Demo-Inhalte vor dem ersten Bildvergleich anlegen (wie Einstellungen -> Erweitert)
                    if UserDefaults.standard.bool(forKey: "UFDemo"), !session.isOwnServer {
                        for _ in 0..<50 where containers.active == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                        // nur anlegen, wenn sie fehlt (erneutes Anlegen entfernte die PDFs der vorhandenen Demo)
                        let on = (try? await containers.active?.api.value("/api/demo"))?["enabled"]?.bool == true
                        if !on { _ = try? await containers.setDemo(true) }
                    }
                    #endif
                    await DebugLaunch.apply(session: session, router: router, overlay: overlay, toast: toast, timer: timer)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // beim Oeffnen, hoechstens alle 30 min: Stud.IP (LUH) bzw. Learnweb und LSF (Uni Hildesheim)
            if phase == .active {
                containers.removeRememberedPasswords()                     // einmalig, falls beim Start gesperrt
                containers.studip.runIfDue()
                containers.hildesheim?.runIfDue()
                containers.qis?.runIfDue()
                weeklyTicker.resume()
                askForLoginIfDue()
                Task {
                    await containers.account.refresh()                     // Probe: Resttage, Ende
                    if await containers.account.syncNow(), !router.route.isDocument { router.reload() }
                }
            } else {
                weeklyTicker.pause()
            }
            // beim Wechsel in den Hintergrund den naechsten Termin 8/15/20 Uhr neu bestellen (S8)
            if phase == .background { Task { await background.schedule() } }
        }
    }

    /// Letzte Anmeldung 6 Stunden her: um eine neue bitten (`LoginReminder`), "OK" fuehrt zu den Anmeldungen
    private func askForLoginIfDue() {
        guard let source = background.loginReminderSource() else { return }
        background.markLoginAsked()
        Task {
            if await overlay.confirm("Bitte neu anmelden\n\nDeine letzte Anmeldung bei \(source) liegt mehr als 6 Stunden zurück. Melde dich neu an, damit der Abgleich weiterläuft.") {
                router.go(.settings(tab: "account"))
            }
        }
    }
}

/// Ziele fuer `openURL` in der ganzen App: nur http:// und https:// mit Host gehen an das System
enum SafeLinks {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return !(url.host ?? "").isEmpty
    }

    static func action(for url: URL) -> OpenURLAction.Result { allows(url) ? .systemAction : .discarded }
}

/// Begruessung -> Tarifwahl (nur beim ersten Mal) -> Hochschulwahl -> (einmal je Hochschule) Anmeldeseiten der
/// Hochschule mit Erstabgleich (FirstLoginFlow, braucht den offenen Container) -> Oberflaeche; die Oberflaeche
/// erscheint auch ohne Server, aber erst mit offenem Container der gewaehlten Hochschule
struct RootView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay
    @State private var choosingPlan = false

    /// was den Container bestimmt (Anmeldung, Hochschulwahl, Wechsel in den Einstellungen)
    private struct ContainerTrigger: Equatable {
        let user: String?
        let university: UniversityKey?
    }

    var body: some View {
        OnboardingFlow { ContainerGate { if account.stage == .universityLogin { FirstLoginFlow() } else { MainView() } } }
            .environment(\.ufSwitchPlan) { choosingPlan = true }            // "Tarif wechseln" in den Einstellungen
            .sheet(isPresented: $choosingPlan) {
                PlanPickerView(context: .settings) { choosingPlan = false }
            }
            .onChange(of: ContainerTrigger(user: account.account?.userID, university: account.university)) { _, _ in
                containers.sync(account: account)
            }
            // anderer Container (Konto, Hochschule): Dialoge und Drawer liegen ueber der Seite (UFModalHost in
            // UniFlowApp) und ueberlebten den Neuaufbau – eine Aktion darin traefe das neue Konto
            .onChange(of: containers.generation) { _, _ in overlay.closeAll() }
    }
}
