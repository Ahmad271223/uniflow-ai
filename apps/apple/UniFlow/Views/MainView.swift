import SwiftUI

/// Hauptnavigation der iPad-App.
struct MainView: View {
    @EnvironmentObject private var session: Session
    @SceneStorage("uniflow.tab") private var tab = "docs"

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(api: session.api)
                .tabItem { Label("Übersicht", systemImage: "house") }.tag("home")
            LibraryView()
                .tabItem { Label("Dokumente", systemImage: "doc.richtext") }.tag("docs")
            ModulesView(api: session.api)
                .tabItem { Label("Module", systemImage: "books.vertical") }.tag("modules")
            CalendarView(api: session.api)
                .tabItem { Label("Kalender", systemImage: "calendar") }.tag("calendar")
            TestsView(api: session.api)
                .tabItem { Label("Tests", systemImage: "graduationcap") }.tag("tests")
            SettingsView(api: session.api)
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }.tag("settings")
        }
    }
}

#Preview("Verbinden") {
    ConnectView().environmentObject(Session())
}

#Preview("Karte") {
    Card(title: "Heute", systemImage: "sun.max") {
        ProgressBar(value: 0.4)
        Text("2 von 5 Aufgaben")
    }
    .padding()
}
