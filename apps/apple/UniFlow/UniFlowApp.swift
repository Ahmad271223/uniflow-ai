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
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue     // wie localStorage "theme" im Web
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(studip)
                .environmentObject(router)
                .environmentObject(shell)
                .environmentObject(toast)
                .modifier(UFToastOverlay(center: toast))
                .preferredColorScheme((UFThemeMode(rawValue: theme) ?? .light).scheme)
                .tint(UF.accent)
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
