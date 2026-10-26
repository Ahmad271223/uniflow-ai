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
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Teilen-Dateien und empfangene Kopien frueherer Laeufe liegen ausserhalb der Container: weg (AppTemp; von
        // der Inbox nur alte Kopien, die eben empfangene oeffnet onOpenURL gleich)
        AppTemp.purgeAtLaunch()
        SolutionSharing.purgeStaleInbox()
        DataSourceMigration.run()                                         // alte Journale in den Server-Namensraum, am alten Ort vor dem Umzug
        let a = AccountStore()
        DebugLaunch.prepare(account: a)                                   // -UFOnboarding/-UFUniversity vor dem ersten Bild
        let c = ContainerManager(hildesheimTransport: DebugUniStub.transportFactory, qisTransport: DebugUniStub.transportFactory)
        c.sync(account: a)                                                // alte Daten umziehen, Container der Hochschule oeffnen
        let s = Session(local: c.active?.api ?? .local(.unavailable))
        c.onChange = { [weak s] container in s?.useLocal(container?.api ?? .local(.unavailable)) }
        _account = StateObject(wrappedValue: a)
        _containers = StateObject(wrappedValue: c)
        _session = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(StudyTimerHost(timer: timer, toast: toast))      // Zeitmesser unter Dialogen und Meldungen
                .modifier(UFModalHost(overlay: overlay))                 // Dialoge innerhalb der Umgebungsobjekte
                .modifier(UFToastOverlay(center: toast))
                .environmentObject(account)
                .environmentObject(containers)
                .environmentObject(session)
                .environmentObject(containers.studip)                     // Abgleich des offenen Containers
                .environment(\.hildesheim, containers.hildesheim)          // Learnweb und LSF (nur Uni Hildesheim)
                .environment(\.qis, containers.qis)                        // QIS-Noten (nur LUH)
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
                        // die Kopie in Documents/Inbox gehoert zu keinem Container: danach immer weg
                        defer { SolutionSharing.discardReceivedCopy(url) }
                        // Loesungen gehoeren in den Container des Kontos und der Hochschule
                        guard containers.active != nil else {
                            toast.show("Melde dich zuerst an und wähle deine Hochschule. Öffne die Lösung danach erneut.", seconds: 4)
                            return
                        }
                        do {
                            let e = try SolutionSharing.importFile(url)
                            let label = ForeignSolutionLayer.label(displayName: e.displayName, createdAt: e.createdAt)
                            toast.show(SolutionSharing.receivedMessage(label: label, canView: Entitlements.shared.allows(.community)), seconds: 5)
                        } catch {
                            toast.show((error as? SolutionError)?.description ?? "Die Lösung lässt sich nicht öffnen.", seconds: 4)
                        }
                        return
                    }
                    // QR-Code einer Lerngruppe (uniflow://community/join/<Code>): beitreten (nur mit Plus und Container)
                    if let code = CommunityJoinLink.code(from: url) {
                        guard containers.active != nil, Entitlements.shared.allows(.community) else {
                            toast.show("Lerngruppen gibt es mit Plus, nach Anmeldung und Hochschulwahl.", seconds: 4)
                            return
                        }
                        Task {
                            do {
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
                .task { await DebugLaunch.apply(session: session, router: router, overlay: overlay, toast: toast, timer: timer) }
        }
        .onChange(of: scenePhase) { _, phase in
            // beim Oeffnen, hoechstens alle 30 min: Stud.IP (LUH) bzw. Learnweb und LSF (Uni Hildesheim)
            if phase == .active {
                containers.studip.runIfDue()
                containers.hildesheim?.runIfDue()
                containers.qis?.runIfDue()
            }
        }
    }
}

/// Begruessung -> Tarifwahl (nur beim ersten Mal) -> Hochschulwahl -> (einmal je Hochschule) Anmeldeseiten der
/// Hochschule mit Erstabgleich (FirstLoginFlow, braucht den offenen Container) -> Oberflaeche; die Oberflaeche
/// erscheint auch ohne Server, aber erst mit offenem Container der gewaehlten Hochschule
struct RootView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
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
    }
}
