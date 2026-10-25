import SwiftUI

/// Einstieg der nativen iPad-App. Studienfunktionen kommen vom bestehenden UniFlow-Server (FastAPI),
/// die Handschrift laeuft nativ ueber PencilKit (siehe Editor/PDFEditorController.swift).
@main
struct UniFlowApp: App {
    @StateObject private var session = Session()
    @StateObject private var studip = StudIPSync()
    @StateObject private var router = UFRouter()
    @StateObject private var shell = ShellState()
    @StateObject private var toast = UFToastCenter()
    @StateObject private var overlay = UFOverlay()
    @StateObject private var timer = StudyTimer()
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(StudyTimerHost(timer: timer, toast: toast))      // Zeitmesser unter Dialogen und Meldungen
                .modifier(UFModalHost(overlay: overlay))                 // Dialoge innerhalb der Umgebungsobjekte
                .modifier(UFToastOverlay(center: toast))
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

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        if session.api != nil {
            MainView()
        } else {
            ConnectView()
        }
    }
}
