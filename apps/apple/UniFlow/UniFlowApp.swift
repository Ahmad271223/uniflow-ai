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
    // Navigation, Seitenleiste, Meldungen und Dialoge gibt es je Fenster (`SceneObjects`, Audit Robustheit 03.11.2026,
    // P3-3); vorher sprangen zwei Fenster gemeinsam zwischen Seiten, Meldungen erschienen in beiden
    @State private var scenes = SceneRegistry()
    @StateObject private var timer = StudyTimer()
    /// Abgleich im Hintergrund (S8): Aufgaben bei iOS, Termine fruehestens 8, 15 und 20 Uhr
    @StateObject private var background: BackgroundSyncController
    @AppStorage("theme") private var theme = UFThemeMode.standardRaw     // wie localStorage "theme" im Web; Vorgabe: wie das iPad
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
            // je Fenster eigene Navigation, Seitenleiste, Meldungen und Dialoge; Konto, Container, Sitzung, Abgleich
            // und Zeitmesser gelten fuer alle Fenster
            SceneObjects(scenes: scenes) { router, shell, toast, overlay in
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
                    .environment(\.ufStudoraAccount, containers.account)       // StudiNow-Konto (mit Dienst-Adresse)
                    .modifier(UFAIEnabledProvider(link: containers.chatgpt))
                    .environment(\.hildesheim, containers.hildesheim)          // Learnweb und LSF (nur Uni Hildesheim)
                    .environment(\.qis, containers.qis)                        // QIS-Noten (nur LUH)
                    .environment(\.backgroundSync, background)                 // Karte "Im Hintergrund abgleichen"
                    .environment(\.ufDemoActive, containers.demoActive)        // Demo-Inhalte: Hinweis statt "… verbinden"
                    .environment(\.ufShowHitAreas, UFHit.debugOverlay)        // nur Debug: Trefferflaechen sichtbar
                    .environmentObject(router)
                    .environmentObject(shell)
                    .environmentObject(toast)
                    .environmentObject(overlay)
                    .environmentObject(timer)
                    .preferredColorScheme((UFThemeMode(rawValue: theme) ?? .standard).scheme)
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
                        // Einladung https://studinow.app/i/<CODE> (Universal Link) oder uniflow://invite/<CODE> (QR "App-Code"):
                        // Code merken, bis das StudiNow-Konto da ist, dann einmal einloesen (Views/Settings/InviteView.swift)
                        if let code = InviteLink.code(from: url) {
                            PendingInvite.store(code)
                            Task {
                                let out = await containers.account.redeemPendingInvite()
                                if let text = PendingInvite.toast(out) { toast.show(text, seconds: 5) }
                            }
                            return
                        }
                        // uniflow://#/plan?view=week -> dieselbe Hash-Route wie in der Web-App
                        if let hash = UFRoute.hash(fromDeepLink: url) { router.go(hash: hash) }
                    }
                    .task {
                        // Startparameter (nur Debug) gelten fuer das erste Fenster, nicht fuer jedes weitere
                        guard scenes.claimLaunchSetup() else { return }
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
                    if await containers.account.syncNow() {
                        for router in scenes.routers where !router.route.isDocument { router.reload() }   // jedes Fenster
                    }
                }
            } else {
                weeklyTicker.pause()
            }
            // beim Wechsel in den Hintergrund den naechsten Termin 8/15/20 Uhr neu bestellen (S8) und die Uni-Anmeldung
            // der Webansicht merken: beendet iOS die App, ist sie beim naechsten Oeffnen wieder da (`UniWebSessions`)
            if phase == .background {
                Task { await containers.saveWebSessions() }
                Task { await background.schedule() }
            }
        }
    }

    /// Abgelaufene Anmeldung: zuerst still ueber das WebSSO bzw. CAS erneuern; nur wenn das nicht reicht (die Uni will
    /// das Passwort) und die letzte Frage 6 Stunden her ist, um eine neue bitten (`LoginReminder`), "OK" fuehrt zu den
    /// Anmeldungen. Eine gueltige Anmeldung fuehrt zu keiner Frage mehr (vorher alle 6 Stunden, auch ohne Grund).
    private func askForLoginIfDue() {
        Task {
            await containers.renewExpiredSessions()
            // die Frage erscheint einmal, im zuletzt aktiven Fenster
            guard let source = background.loginReminderSource(), let scene = scenes.active else { return }
            background.markLoginAsked()
            if await scene.overlay.confirm("Bitte neu anmelden\n\nDeine Anmeldung bei \(source) ist abgelaufen, und die Universität möchte dein Passwort erneut sehen. Melde dich neu an (iOS kann das gespeicherte Passwort einsetzen), damit der Abgleich weiterläuft.") {
                scene.router.go(.settings(tab: "account"))
            }
        }
    }
}

/// Navigation, Seitenleiste, Meldungen und Dialoge je Fenster (Audit Robustheit 03.11.2026, P3-3): iPadOS erlaubt
/// mehrere Fenster (`UIApplicationSupportsMultipleScenes`); vorher waren `UFRouter`, `ShellState`, `UFToastCenter` und
/// `UFOverlay` Objekte der App, zwei Fenster sprangen gemeinsam zwischen Seiten und zeigten dieselben Dialoge. Jedes
/// Fenster legt sie hier selbst an und meldet sich bei `SceneRegistry` (app-weite Fragen und Neuladen).
struct SceneObjects<Content: View>: View {
    let scenes: SceneRegistry
    let content: (UFRouter, ShellState, UFToastCenter, UFOverlay) -> Content
    @StateObject private var router = UFRouter()
    @StateObject private var shell = ShellState()
    @StateObject private var toast = UFToastCenter()
    @StateObject private var overlay = UFOverlay()
    @Environment(\.scenePhase) private var scenePhase
    /// Kennung dieses Fensters fuer "Weitermachen wie zuvor" (iOS legt sie mit dem Fenster wieder an; nach einem
    /// Beenden durch den Nutzer neu, dann gilt der zuletzt geschriebene Stand, `ResumeTracker`)
    @SceneStorage("uniflow.scene") private var sceneID = ""

    init(scenes: SceneRegistry, @ViewBuilder content: @escaping (UFRouter, ShellState, UFToastCenter, UFOverlay) -> Content) {
        self.scenes = scenes
        self.content = content
    }

    var body: some View {
        content(router, shell, toast, overlay)
            .onAppear {
                scenes.register(router: router, overlay: overlay)
                if sceneID.isEmpty { sceneID = UUID().uuidString }
                router.resume.sceneID = sceneID
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { scenes.activate(router: router, overlay: overlay) }
            }
    }
}

/// Fenster der App (schwach gehalten): das zuletzt aktive bekommt app-weite Fragen (abgelaufene Anmeldung), jedes
/// laedt nach einem Abgleich des StudiNow-Kontos neu
@MainActor
final class SceneRegistry {
    struct Window {
        let router: UFRouter
        let overlay: UFOverlay
    }

    private struct Entry {
        weak var router: UFRouter?
        weak var overlay: UFOverlay?
        var window: Window? { router.flatMap { r in overlay.map { Window(router: r, overlay: $0) } } }
    }

    private var entries: [Entry] = []
    private var activeEntry: Entry?
    private var launchSetupDone = false

    /// Fenster bekannt machen (beim Erscheinen); das erste gilt bis zum ersten Wechsel als aktiv
    func register(router: UFRouter, overlay: UFOverlay) {
        entries.removeAll { $0.router == nil }
        if !entries.contains(where: { $0.router === router }) { entries.append(Entry(router: router, overlay: overlay)) }
        if activeEntry?.window == nil { activeEntry = Entry(router: router, overlay: overlay) }
    }

    /// Fenster ist vorn (scenePhase .active)
    func activate(router: UFRouter, overlay: UFOverlay) {
        register(router: router, overlay: overlay)
        activeEntry = Entry(router: router, overlay: overlay)
    }

    /// zuletzt aktives Fenster, das noch offen ist (sonst irgendein offenes)
    var active: Window? { activeEntry?.window ?? entries.lazy.compactMap(\.window).first }

    /// Navigation aller offenen Fenster
    var routers: [UFRouter] { entries.compactMap(\.router) }

    /// Einrichtung aus den Startparametern genau einmal (erstes Fenster); true fuer den ersten Aufruf
    func claimLaunchSetup() -> Bool {
        defer { launchSetupDone = true }
        return !launchSetupDone
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
    @Environment(\.scenePhase) private var scenePhase
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
            // Probe auf dem iPad (LocalTrial.swift): beginnt mit der Anmeldung, einmal je Apple-ID; nie unter XCTest
            // (Tests bauen eigene Entitlements, der Testhost soll den Schluesselbund nicht fuellen)
            .onChange(of: account.account?.userID, initial: true) { _, id in
                guard !StudIPSync.isUnderTest() else { return }
                if let id { Entitlements.shared.beginLocalTrial(userID: id) } else { Entitlements.shared.useLocalTrial(startedAt: nil) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Entitlements.shared.refreshLocalTrial() }   // Resttage nach dem Tageswechsel
            }
            // anderer Container (Konto, Hochschule): Dialoge und Drawer liegen ueber der Seite (UFModalHost in
            // UniFlowApp) und ueberlebten den Neuaufbau – eine Aktion darin traefe das neue Konto
            .onChange(of: containers.generation) { _, _ in overlay.closeAll() }
    }
}
