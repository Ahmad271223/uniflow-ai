import SwiftUI

/// Community 1:1 nach viewCommunity() in app/static/views-misc.js: vorbereitet, noch nicht verbunden.
/// Ohne eigenen UniFlow-Server (V1) ohne Hinweis auf den PC, dazu die Karte "Stud.IP verbinden".
struct CommunityPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    /// Geplantes; auf dem iPad gibt es das Teilen als Datei schon (Plus, im Editor unter „Ebenen“)
    static func planned(onDevice: Bool) -> [String] {
        [onDevice ? "Lösungen in der Online-Community veröffentlichen – geplant" : "Eigene Lösungen freiwillig teilen – geplant",
         "Lösungswege anderer Studierender vergleichen – geplant", "Fragen und Antworten pro Modul – geplant"]
    }

    /// Ohne Dienst wird nichts veroeffentlicht; die Datei gibt der Nutzer selbst weiter (vorher "nichts verlässt dieses
    /// iPad", obwohl Plus Loesungen als Datei teilt)
    static func text(onDevice: Bool) -> String {
        onDevice
            ? "Eine Community braucht einen gemeinsamen Dienst mit Anmeldung, Moderation und Freigabe-Regeln. Ohne diesen Dienst wird nichts veröffentlicht. Mit Plus gibst du eigene Lösungen selbst als verschlüsselte Datei weiter (im Editor unter „Ebenen“) – nur an die, denen du sie schickst."
            : "Diese Installation läuft nur für dich auf deinem PC. Eine Community braucht einen gemeinsamen Server mit Anmeldung, Moderation und Freigabe-Regeln. Es werden keine Inhalte geteilt, nichts verlässt deinen Rechner."
    }

    var body: some View {
        let mode = UFDataMode.current(api: session.api, studip: studip)
        UFContent(maxWidth: 860) {
            UFPageHead("Community", sub: "Lösungen vergleichen, Fragen stellen, Lerngruppen.")
            if mode.showsConnectCard { ConnectStudIPCard(mode: mode).padding(.bottom, 16) }
            UFCard {
                // span.badge steht in einer Textzeile (Zeilenhoehe 1.5)
                UFBadge("Vorbereitet, noch nicht verbunden", tone: .warn, icon: "info").frame(height: 14.5 * 1.5)
                Text(Self.text(onDevice: mode.isOnDevice))
                    .ufFont(14.5).foregroundStyle(UF.text)
                    .padding(.top, 9.6)
                // ul.small.muted: Rand 1em, Einzug 40 px, Aufzaehlungspunkt aussen
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.planned(onDevice: mode.isOnDevice), id: \.self) { item in
                        Text(item)
                            .overlay(alignment: .topLeading) { Text("•").offset(x: -13) }
                    }
                }
                .ufFont(13.12).foregroundStyle(UF.muted)
                .padding(.leading, 40).padding(.vertical, 13.12)
            }
        }
    }
}
