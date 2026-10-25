import SwiftUI

/// Einstieg der nativen iPad-App. Erster Start nach docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a
/// (Views/Onboarding/OnboardingFlow.swift); die Handschrift laeuft nativ ueber PencilKit
/// (siehe Editor/PDFEditorController.swift). Der eigene UniFlow-Server ist nur noch ein Entwicklungsmodus.
@main
struct UniFlowApp: App {
    @StateObject private var account: AccountStore
    @StateObject private var session = Session()
    @StateObject private var studip = StudIPSync()
    @StateObject private var router = UFRouter()
    @StateObject private var shell = ShellState()
    @StateObject private var toast = UFToastCenter()
    @StateObject private var overlay = UFOverlay()
    @StateObject private var timer = StudyTimer()
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
                .environmentObject(router)
                .environmentObject(shell)
                .environmentObject(toast)
                .environmentObject(overlay)
                .environmentObject(timer)
                .preferredColorScheme((UFThemeMode(rawValue: theme) ?? .light).scheme)
                .tint(UF.accent)
                .onOpenURL { url in
                    // uniflow://#/plan?view=week -> dieselbe Hash-Route wie in der Web-App
                    if let hash = UFRoute.hash(fromDeepLink: url) { router.go(hash: hash) }
                }
                .task { await DebugLaunch.apply(session: session, router: router, overlay: overlay, toast: toast, timer: timer) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { studip.runIfDue() }      // Stud.IP direkt: beim Oeffnen, hoechstens alle 30 min
        }
    }
}

/// Begruessung -> Tarifwahl (nur beim ersten Mal) -> Oberflaeche; die Oberflaeche erscheint auch ohne Server
struct RootView: View {
    var body: some View {
        OnboardingFlow { MainView() }
    }
}
