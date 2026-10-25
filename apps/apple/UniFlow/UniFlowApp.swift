import SwiftUI
import UniFlowCore

/// Einstieg der nativen iPad-App. Erster Start nach docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a
/// (Views/Onboarding/OnboardingFlow.swift); die Handschrift laeuft nativ ueber PencilKit
/// (siehe Editor/PDFEditorController.swift). Der eigene UniFlow-Server ist nur noch ein Entwicklungsmodus.
@main
struct UniFlowApp: App {
    @StateObject private var account: AccountStore
    @StateObject private var session = Session()
    @StateObject private var studip = StudIPSync()
    @StateObject private var recordingLibrary = RecordingLibrary()          // geladene Aufzeichnungen (nur auf Wunsch)
    @StateObject private var router = UFRouter()
    @StateObject private var shell = ShellState()
    @StateObject private var toast = UFToastCenter()
    @StateObject private var overlay = UFOverlay()
    @StateObject private var timer = StudyTimer()
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DataSourceMigration.run()                                         // alte Journale in den Server-Namensraum, vor dem ersten Dokument
        let a = AccountStore()
        DebugLaunch.prepare(account: a)                                   // -UFOnboarding vor dem ersten Bild
        _account = StateObject(wrappedValue: a)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(StudyTimerHost(timer: timer, toast: toast))      // Zeitmesser unter Dialogen und Meldungen
                .modifier(UFModalHost(overlay: overlay))                 // Dialoge innerhalb der Umgebungsobjekte
                .modifier(UFToastOverlay(center: toast))
                .environmentObject(account)
                .environmentObject(session)
                .environmentObject(studip)
                .environmentObject(recordingLibrary)
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
                        do {
                            let e = try SolutionSharing.importFile(url)
                            let label = ForeignSolutionLayer.label(displayName: e.displayName, createdAt: e.createdAt)
                            toast.show("\(label) gespeichert – sie erscheint in der passenden PDF unter „Ebenen“.", seconds: 4)
                        } catch {
                            toast.show((error as? SolutionError)?.description ?? "Die Lösung lässt sich nicht öffnen.", seconds: 4)
                        }
                        return
                    }
                    // uniflow://#/plan?view=week -> dieselbe Hash-Route wie in der Web-App
                    if let hash = UFRoute.hash(fromDeepLink: url) { router.go(hash: hash) }
                }
                .task { await DebugLaunch.apply(session: session, router: router, overlay: overlay, toast: toast, timer: timer) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Stud.IP direkt: beim Oeffnen, hoechstens alle 30 min; nie unter XCTest oder mit Debug-Startargumenten
            if phase == .active { studip.runIfDue() }
        }
    }
}

/// Begruessung -> Tarifwahl (nur beim ersten Mal) -> Oberflaeche; die Oberflaeche erscheint auch ohne Server
struct RootView: View {
    @State private var choosingPlan = false

    var body: some View {
        OnboardingFlow { MainView() }
            .environment(\.ufSwitchPlan) { choosingPlan = true }            // "Tarif wechseln" in den Einstellungen
            .sheet(isPresented: $choosingPlan) {
                PlanPickerView(context: .settings) { choosingPlan = false }
            }
    }
}
