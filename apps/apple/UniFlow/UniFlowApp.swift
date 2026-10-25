import SwiftUI

/// Einstieg der nativen iPad-App. Studienfunktionen kommen vom bestehenden UniFlow-Server (FastAPI),
/// die Handschrift laeuft nativ ueber PencilKit (siehe Editor/PDFEditorController.swift).
@main
struct UniFlowApp: App {
    @StateObject private var session = Session()
    @StateObject private var studip = StudIPSync()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(studip)
                .tint(Color("AccentColor"))
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
