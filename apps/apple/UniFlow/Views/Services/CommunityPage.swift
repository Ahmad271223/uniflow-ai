import SwiftUI
import UniFlowCore

/// Bereich "Community" (docs/LOESUNGEN-TEILEN.md, Abschnitt 7). Mit CloudKit-Dienst im Build (nur dann steht der
/// Eintrag in der Seitenleiste): wo Loesungen auftauchen, Pseudonym, Lerngruppen, Sperrliste, "Meine geteilten
/// Lösungen". Ohne Dienst (Build ohne iCloud-Container, eigener Server in der Entwicklung): ehrlicher Hinweis statt
/// Versprechen – nach viewCommunity() in app/static/views-misc.js, ohne Hinweis auf den PC (V1).
struct CommunityPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo
    @State private var showingShared = false

    /// Geplantes bzw. in diesem Build nicht Verfuegbares; auf dem iPad gibt es das Teilen als Datei schon (Plus,
    /// im Editor unter „Ebenen“)
    static func planned(onDevice: Bool) -> [String] {
        onDevice
            ? ["Lösungen in der Community veröffentlichen und finden – in diesem Build nicht verfügbar (kein iCloud-Container)",
               "Lerngruppen mit Beitrittscode – ebenso",
               "Fragen und Antworten pro Modul – geplant"]
            : ["Eigene Lösungen freiwillig teilen – geplant", "Lösungswege anderer Studierender vergleichen – geplant",
               "Fragen und Antworten pro Modul – geplant"]
    }

    /// Ohne Dienst wird nichts veroeffentlicht; die Datei gibt der Nutzer selbst weiter (vorher "nichts verlässt dieses
    /// iPad", obwohl Plus Loesungen als Datei teilt)
    static func text(onDevice: Bool) -> String {
        onDevice
            ? "Die Community läuft über CloudKit und braucht einen Build mit iCloud-Container (Apple Developer Program). In diesem Build wird nichts veröffentlicht und nichts gesucht. Ab \(UFPlan.plus.name) gibst du eigene Lösungen selbst als verschlüsselte Datei weiter (im Editor unter „Ebenen“) – nur an die, denen du sie schickst."
            : "Diese Installation läuft nur für dich auf deinem PC. Eine Community braucht einen gemeinsamen Server mit Anmeldung, Moderation und Freigabe-Regeln. Es werden keine Inhalte geteilt, nichts verlässt deinen Rechner."
    }

    /// Mit Dienst: wo die Community in der App steckt (sie lebt im Dokument und im Modul, nicht auf dieser Seite)
    static let howItWorks: [(icon: String, text: String)] = [
        ("layers", "Im Dokument unter „Ebenen“: „n Lösungen aus der Community zu diesem Blatt“ – laden und als eigene, nicht bearbeitbare Ebene über deiner PDF ansehen."),
        ("book", "Im Modul unter „Community“: alle veröffentlichten Lösungen zu den Dateien des Moduls, nach Lehrwoche."),
        ("users", "Ab \(UFPlan.plus.name) im Editor „Lösung teilen …“ → „In der Community veröffentlichen“: nur deine eigenen Notizen, sichtbar für dein Modul, deine Lerngruppe oder anonym an deiner Hochschule."),
    ]

    var body: some View {
        let mode = UFDataMode.current(api: session.api, studip: studip, demo: demo)
        let connected = mode.isOnDevice && SolutionSharing.community.isConnected
        UFContent(maxWidth: 860) {
            UFPageHead("Community", sub: connected ? "Lösungen teilen und vergleichen – nur eigene Notizen, verschlüsselt." : "Lösungen vergleichen, Fragen stellen, Lerngruppen.")
            if mode.showsConnectCard { ConnectStudIPCard(mode: mode).padding(.bottom, 16) }
            if connected {
                connectedContent
            } else {
                unavailableCard(onDevice: mode.isOnDevice)
            }
        }
        .sheet(isPresented: $showingShared) { SharedSolutionsSheet { showingShared = false } }
    }

    @ViewBuilder private var connectedContent: some View {
        UFGate(.communityRead) {
            UFCard {
                UFCardHead("So funktioniert die Community", icon: "info") {
                    UFButton("Meine geteilten Lösungen", icon: "users", size: .small) { showingShared = true }
                }
                VStack(alignment: .leading, spacing: 9.6) {
                    ForEach(Array(Self.howItWorks.enumerated()), id: \.offset) { row in
                        HStack(alignment: .top, spacing: 10) {
                            UFIcon(row.element.icon, size: 18).foregroundStyle(UF.accentText).padding(.top, 1)
                            Text(row.element.text).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(SolutionTexts.examRules).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
            }
            .padding(.bottom, 16)
        }
        CommunitySettingsCard()                                              // Pseudonym, Lerngruppen, Sperrliste
    }

    private func unavailableCard(onDevice: Bool) -> some View {
        UFCard {
            // span.badge steht in einer Textzeile (Zeilenhoehe 1.5)
            UFBadge(onDevice ? "In diesem Build nicht verfügbar" : "Vorbereitet, noch nicht verbunden", tone: .warn, icon: "info").frame(height: 14.5 * 1.5)
            Text(Self.text(onDevice: onDevice))
                .ufFont(14.5).foregroundStyle(UF.text)
                .padding(.top, 9.6)
            // ul.small.muted: Rand 1em, Einzug 40 px, Aufzaehlungspunkt aussen
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.planned(onDevice: onDevice), id: \.self) { item in
                    Text(item)
                        .overlay(alignment: .topLeading) { Text("•").offset(x: -13) }
                }
            }
            .ufFont(13.12).foregroundStyle(UF.muted)
            .padding(.leading, 40).padding(.vertical, 13.12)
        }
    }
}
