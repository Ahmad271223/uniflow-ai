import SwiftUI
import UniFlowCore

// V1 ohne PC-Server (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a): Ohne eigenen UniFlow-Server zeigt jede Seite einen
// ehrlichen leeren Zustand mit dem Weg zu "Stud.IP verbinden" – keine Beispieldaten, keine Hinweise auf PC oder PIN.
// Mit Server (Entwicklungsmodus des Inhabers) laden die Seiten wie bisher.

/// Stand der Stud.IP-Verbindung aus Sicht der Oberflaeche.
enum StudIPLink: Equatable {
    case notConnected
    /// Sitzung abgelaufen: erneut anmelden
    case expired
    /// angemeldet; auch waehrend eines Abgleichs und nach einem Abgleichfehler (z. B. offline)
    case connected

    init(_ phase: StudIPSync.Phase) {
        switch phase {
        case .signedOut: self = .notConnected
        case .needsLogin: self = .expired
        case .idle, .running, .failed: self = .connected
        }
    }
}

/// Welchen Zustand eine Seite zeigt.
enum UFDataMode: Equatable {
    /// eigener UniFlow-Server verbunden: Seite laedt wie bisher
    case server
    /// kein Server, Stud.IP nicht verbunden: leerer Zustand mit Karte "Stud.IP verbinden"
    case connectStudIP
    /// kein Server, Stud.IP-Anmeldung abgelaufen: leerer Zustand mit Karte "Erneut anmelden"
    case reconnectStudIP
    /// kein Server, Stud.IP verbunden: leerer Zustand ohne Karte (das lokale Backend fuellt die Seiten spaeter)
    case empty

    static func resolve(hasServer: Bool, studIP: StudIPLink) -> UFDataMode {
        if hasServer { return .server }
        switch studIP {
        case .notConnected: return .connectStudIP
        case .expired: return .reconnectStudIP
        case .connected: return .empty
        }
    }

    /// Karte "Stud.IP verbinden" zeigen
    var showsConnectCard: Bool { self == .connectStudIP || self == .reconnectStudIP }
}

/// Karte "Stud.IP verbinden": kurzer Satz und Knopf, oeffnet die echte Stud.IP-Anmeldung (StudIPLoginView);
/// das Passwort tippt der Nutzer selbst auf der Seite der Universitaet. Ist Stud.IP verbunden, zeigt die Karte
/// nichts – sie verschwindet also nach erfolgreicher Anmeldung von selbst (auch in den Einstellungen nutzbar).
struct ConnectStudIPCard: View {
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false

    var body: some View {
        let link = StudIPLink(studip.phase)
        if link != .connected {
            UFCard {
                UFCardHead(link == .expired ? "Stud.IP-Anmeldung abgelaufen" : "Stud.IP verbinden", icon: "graduation")
                Text(link == .expired
                     ? "Melde dich erneut bei Stud.IP an, damit UniFlow deine Kurse und Dateien weiter abgleicht."
                     : "Melde dich bei Stud.IP der Leibniz Universität an, damit UniFlow deine Kurse und Dateien auf dieses iPad holt.")
                    .ufFont(14.5).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dein Passwort gibst du nur auf der Seite der Universität ein.")
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .padding(.top, 4)
                UFButton(link == .expired ? "Erneut anmelden" : "Stud.IP verbinden", icon: "arrow-right", kind: .primary) { showLogin = true }
                    .padding(.top, 12.8)
            }
            .sheet(isPresented: $showLogin) {
                StudIPLoginView(base: StudIPSync.base) { cookies in
                    showLogin = false
                    studip.signedIn(cookies: cookies)
                }
            }
        }
    }
}

/// Leerer Zustand einer Seite ohne Server: Kopf wie die Seite, Karte "Stud.IP verbinden", leere Karte.
struct UFNoServerPage: View {
    struct Spec {
        let title: String
        var sub: String?
        let icon: String
        let text: String
        var maxWidth: CGFloat?
    }

    let spec: Spec

    var body: some View {
        UFContent(maxWidth: spec.maxWidth) {
            UFPageHead(spec.title, sub: spec.sub)
            UFNoServerBody(icon: spec.icon, text: spec.text)
        }
    }
}

/// Inhalt unter dem Seitenkopf ohne Server (auch fuer die Uebersicht mit eigener Begruessung).
struct UFNoServerBody: View {
    let icon: String
    let text: String
    @EnvironmentObject private var studip: StudIPSync
    @State private var showFiles = false

    var body: some View {
        let mode = UFDataMode.resolve(hasServer: false, studIP: StudIPLink(studip.phase))
        VStack(alignment: .leading, spacing: 16) {
            if mode.showsConnectCard { ConnectStudIPCard() }
            UFCard {
                UFEmpty(icon: icon, text: text) {
                    // verbunden: die heruntergeladenen Stud.IP-Dateien sind echte Daten auf diesem iPad
                    if mode == .empty, !studip.entries.isEmpty {
                        UFButton("Stud.IP-Dateien ansehen (\(studip.entries.count))", icon: "folder") { showFiles = true }
                            .padding(.top, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                StudIPView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showFiles = false } } }
            }
        }
    }
}

extension UFNoServerPage.Spec {
    static let plan = Self(title: "Lernkalender", icon: "calendar", text: "Noch keine Lernpakete geplant.", maxWidth: 1600)
    static let timetable = Self(title: "Stundenplan", icon: "clock", text: "Noch keine Termine im Stundenplan.", maxWidth: 1600)
    static let modules = Self(title: "Meine Module", sub: "Alle Module deines Studiums – Vorlesungen, Übungen, Materialien und Tests an einem Ort.",
                              icon: "book", text: "Noch keine Module.", maxWidth: 1480)
    static let library = Self(title: "Dokumente & Notizen", sub: "Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.",
                              icon: "folder", text: "Noch keine Dokumente.")
    static let exams = Self(title: "Tests & Wiederholung", sub: "Ein gemeinsamer Wochentest pro Modul und Lehrwoche, dazu Karteikarten zum Wiederholen.",
                            icon: "exam", text: "Noch keine Wochentests.")
    static let cards = Self(title: "Karteikarten", icon: "cards", text: "Noch keine Karteikarten.", maxWidth: 820)
    static let services = Self(title: "Uni & Noten", sub: "Alle Dienste der Leibniz Universität an einem Ort, Notenspiegel direkt in der App.",
                               icon: "graduation", text: "Noch keine Noten geladen.", maxWidth: 1120)
    /// Rueckfall fuer Ansichten ohne eigene Angaben (UFRemote)
    static let generic = Self(title: "UniFlow", icon: "info", text: "Hier ist noch nichts.")
}

/// Seite nur mit eigenem UniFlow-Server laden, sonst den leeren Zustand zeigen. Die Inhaltsansicht (und ihr
/// .task zum Laden) entsteht nur mit Server.
struct UFServerGate<Content: View>: View {
    let spec: UFNoServerPage.Spec
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var session: Session

    init(_ spec: UFNoServerPage.Spec, @ViewBuilder content: @escaping () -> Content) {
        self.spec = spec
        self.content = content
    }

    var body: some View {
        if session.api != nil { content() } else { UFNoServerPage(spec: spec) }
    }
}
