import SwiftUI

/// Hauptnavigation wie die Web-App: Seitenleiste + Kopfzeile (Design/AppShell.swift), Inhalt je Route.
/// Bereiche ohne 1:1-Umsetzung zeigen vorerst die bisherige native Ansicht bzw. die Web-Ansicht des Servers;
/// den Stand je Funktion fuehrt WEB-IPAD-PARITAET.md. Ohne eigenen UniFlow-Server (V1) zeigt jede Seite ihren
/// leeren Zustand mit dem Weg zu "Stud.IP verbinden" (UFServerGate, Views/ConnectStudIPCard.swift).
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shell: ShellState

    var body: some View {
        AppShell { route in
            switch route {
            case .dashboard:
                DashboardView(api: session.api).id(session.api?.base)                         // 1:1
            case .plan(let v, let d, let m):
                UFServerGate(.plan) { PlanView(params: (v, d, m)) }                           // 1:1
            case .modules:
                UFServerGate(.modules) { ModulesPage() }                                      // 1:1
            case .module(let id):
                UFServerGate(.modules) { ModulePage(id: id) }                                 // 1:1
            case .files(let s, let p, let q):
                UFServerGate(.library) { LibraryPage(section: s, path: p, q: q) }             // 1:1
            case .doc(let id, _, _):
                UFServerGate(.library) { LibraryView(openFile: id) }
            case .exams:
                UFServerGate(.exams) { ExamsPage() }                                          // 1:1
            case .exam(let id, let task):
                UFServerGate(.exams) { ExamRunPage(id: id, task: task) }                      // 1:1
            case .cards:
                UFServerGate(.cards) { CardsPage() }                                          // 1:1
            case .settings(let t):
                SettingsPage(initialTab: t)
            case .timetable(let d):
                UFServerGate(.timetable) { TimetableView(date: d) }                           // 1:1
            case .services:
                UFServerGate(.services) { ServicesPage() }
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
