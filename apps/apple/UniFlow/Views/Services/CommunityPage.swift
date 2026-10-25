import SwiftUI

/// Community 1:1 nach viewCommunity() in app/static/views-misc.js: vorbereitet, noch nicht verbunden.
struct CommunityPage: View {
    private let planned = ["Eigene Lösungen freiwillig teilen – geplant", "Lösungswege anderer Studierender vergleichen – geplant",
                           "Fragen und Antworten pro Modul – geplant"]

    var body: some View {
        UFContent(maxWidth: 860) {
            UFPageHead("Community", sub: "Lösungen vergleichen, Fragen stellen, Lerngruppen.")
            UFCard {
                // span.badge steht in einer Textzeile (Zeilenhoehe 1.5)
                UFBadge("Vorbereitet, noch nicht verbunden", tone: .warn, icon: "info").frame(height: 14.5 * 1.5)
                Text("Diese Installation läuft nur für dich auf deinem PC. Eine Community braucht einen gemeinsamen Server mit Anmeldung, Moderation und Freigabe-Regeln. Es werden keine Inhalte geteilt, nichts verlässt deinen Rechner.")
                    .ufFont(14.5).foregroundStyle(UF.text)
                    .padding(.top, 9.6)
                // ul.small.muted: Rand 1em, Einzug 40 px, Aufzaehlungspunkt aussen
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(planned, id: \.self) { item in
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
