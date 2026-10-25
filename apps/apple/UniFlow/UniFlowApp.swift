import SwiftUI

/// Einstieg der nativen iPad-App. Studienfunktionen kommen vom bestehenden UniFlow-Server (FastAPI),
/// die Handschrift laeuft nativ ueber PencilKit (siehe Editor/PDFEditorController.swift).
@main
struct UniFlowApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(Color("AccentColor"))
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
