import SwiftUI

/// Hauptnavigation wie die Web-App: Seitenleiste + Kopfzeile (Design/AppShell.swift), Inhalt je Route.
/// Bereiche ohne 1:1-Umsetzung zeigen vorerst die bisherige native Ansicht bzw. die Web-Ansicht des Servers;
/// den Stand je Funktion fuehrt WEB-IPAD-PARITAET.md.
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shell: ShellState

    var body: some View {
        AppShell { route in
            switch route {
            case .dashboard:
                DashboardView(api: session.api)                       // 1:1
            case .plan(let v, let d, let m):
                PlanView(params: (v, d, m))                           // 1:1
            case .modules:
                ModulesPage()                                         // 1:1
            case .module(let id):
                ModulePage(id: id)                                    // 1:1
            case .files(let s, let p, let q):
                LibraryPage(section: s, path: p, q: q)                // 1:1
            case .doc(let id, _, _):
                LibraryView(openFile: id)
            case .exams:
                ExamsPage()                                           // 1:1
            case .exam(let id, let task):
                ExamRunPage(id: id, task: task)                       // 1:1
            case .cards:
                CardsPage()                                           // 1:1
            case .settings:
                SettingsView(api: session.api)                        // alt, wird 1:1 ersetzt
            case .timetable(let d):
                TimetableView(date: d)                                // 1:1
            case .services:
                ServicesPage()
            case .community:
                CommunityPage()
            }
        }
        .onAppear { shell.attach(session.api) }
        .onChange(of: session.api?.base) { _, _ in shell.attach(session.api) }
    }
}

#Preview("Verbinden") {
    ConnectView().environmentObject(Session())
}
