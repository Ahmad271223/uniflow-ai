import SwiftUI

/// Hauptnavigation wie die Web-App: Seitenleiste + Kopfzeile (Design/AppShell.swift), Inhalt je Route, alle Seiten
/// nativ; den Stand je Funktion fuehrt WEB-IPAD-PARITAET.md. Ohne eigenen UniFlow-Server (V1) liest jede Seite das
/// lokale Backend des Geraets; fehlt der Abgleich noch, zeigt sie den Weg zu "Stud.IP verbinden" (UFServerGate,
/// Views/ConnectStudIPCard.swift).
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var overlay: UFOverlay
    /// KI ueber das ChatGPT-Abo verbunden: Wochentests auch ohne PC
    @Environment(\.ufAIEnabled) private var aiEnabled

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
            case .doc(let id, let task, let page):
                // mit der Aufgabe des Lernplans ("Erledigt" im Editor, wie views-doc.js)
                UFServerGate(.document) { LibraryView(openFile: id, openPage: page, openTask: task) }  // Editor ohne Leiste darueber
            case .exams:
                UFServerGate(aiEnabled ? .examsWithAI : .exams) { ExamsPage() }               // 1:1
            case .exam(let id, let task):
                UFServerGate(aiEnabled ? .examsWithAI : .exams) { ExamRunPage(id: id, task: task) }   // 1:1
            case .cards:
                // ohne PC nur mit Plus (UFGate(.flashcards) unter dem Seitenkopf), am eigenen Server ohne Tarif
                UFServerGate(.cards) { CardsPage() }                                            // 1:1
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
        .onAppear { shell.attach(session.api); UFSessionState.reset() }
        .modifier(DueReminderHost())                                         // Erinnerungen an Abgaben und Prüfungen
        // andere Datenquelle (eigener Server verbunden/getrennt): Kopfzeile neu, Anzeigezustaende von vorn, offene
        // Dialoge und Drawer zu – eine Aktion darin traefe sonst die neue Quelle
        .onChange(of: session.api?.base) { _, _ in shell.attach(session.api); UFSessionState.reset(); overlay.closeAll() }
    }
}

/// Sitzungsweite Anzeigezustaende der Seiten (planState, ttDate, sort/filter im Web: Modulvariablen). Sie gehoeren
/// zur Datenquelle: nach einem Konto- oder Hochschulwechsel (neuer Container, MainView entsteht neu) und beim
/// Wechsel zum oder vom eigenen Server beginnen sie von vorn – sonst filterte der Lernkalender nach einem Modul des
/// anderen Containers (leer) und zeigte den Stundenplan an dessen zuletzt gewaehlter Woche.
@MainActor
enum UFSessionState {
    static func reset() {
        PlanView.state = (view: "week", date: UFFmt.todayISO(), module: "")
        TimetableView.ttDate = UFFmt.todayISO()
        LibraryPage.sort = "date"
        LibraryPage.filter = "all"
    }
}

#Preview("Verbinden") {
    ConnectView().environmentObject(Session())
}
