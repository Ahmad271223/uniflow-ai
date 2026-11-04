import SwiftUI

/// Hauptnavigation wie die Web-App: Seitenleiste + Kopfzeile (Design/AppShell.swift), Inhalt je Route, alle Seiten
/// nativ; den Stand je Funktion fuehrt WEB-IPAD-PARITAET.md. Ohne eigenen UniFlow-Server (V1) liest jede Seite das
/// lokale Backend des Geraets; fehlt der Abgleich noch, zeigt sie den Weg zu "Stud.IP verbinden" (UFServerGate,
/// Views/ConnectStudIPCard.swift).
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var overlay: UFOverlay
    /// Router dieses Fensters (Weitermachen wie zuvor: `router.resume`)
    @EnvironmentObject private var router: UFRouter
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
            case .aiStart:
                // KI-Start (03.11.2026): auch ohne verbundene KI erreichbar, die Seite zeigt dann den Weg dorthin
                UFServerGate(.aiStart) { AIStartView() }
            case .settings(let t):
                SettingsPage(initialTab: t)
            case .timetable(let d):
                UFServerGate(.timetable) { TimetableView(date: d) }                           // 1:1
            case .services:
                UFServerGate(.services) { ServicesPage() }
            case .community:
                CommunityPage()
            case .communitySpace(let key):
                CommunitySpacePage(key: key).id(key)
            }
        }
        .onAppear { shell.attach(session.api); UFSessionState.reset() }
        // Weitermachen wie zuvor (Services/ResumeState.swift): nach dem ersten Bild das zuletzt offene Dokument wieder
        // oeffnen (einmal je Fenster, nie blockierend, still bei Fehlern); nicht unter XCTest und nicht mit
        // Startparametern, die selbst eine Seite waehlen (-UFRoute/-UFAction der Bildvergleiche)
        .task(id: session.api?.base) {
            guard Self.restoresAtLaunch() else { return }
            await router.resume.restoreIfNeeded(api: session.api, router: router)
        }
        .modifier(CommunityBadgeHost())                                      // Zahl neuer Korrekturhinweise an "Community"
        .modifier(DueReminderHost())                                         // Erinnerungen an Abgaben und Prüfungen
        .modifier(OlderSemestersQuestionHost())                              // einmal: "Auch frühere Semester laden?"
        // andere Datenquelle (eigener Server verbunden/getrennt): Kopfzeile neu, Anzeigezustaende von vorn, offene
        // Dialoge und Drawer zu – eine Aktion darin traefe sonst die neue Quelle
        .onChange(of: session.api?.base) { _, _ in shell.attach(session.api); UFSessionState.reset(); overlay.closeAll() }
    }

    /// Wiederherstellung nur in der laufenden App ohne Startparameter fuer eine Seite
    static func restoresAtLaunch(defaults d: UserDefaults = .standard, underTest: Bool = StudIPSync.isUnderTest()) -> Bool {
        if underTest { return false }
        return d.string(forKey: "UFRoute") == nil && d.string(forKey: "UFAction") == nil && d.string(forKey: "UFDocPanel") == nil
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
