import SwiftUI
import UniFlowCore

/// Karte "Zuletzt benutzt" (Uebersicht und KI-Start, 04.11.2026): Dokumente, KI-Gespraeche und Wochentests in einer
/// Liste nach Zeit, je Art ein Symbol. Antippen oeffnet an derselben Stelle: das Dokument auf seiner Seite, das
/// Gespraech im Dokument mit offener KI-Hilfe (ihr Verlauf kommt aus `TutorConversations`), den Wochentest; ein
/// Gespraech zu einer Aufgabe ("Frag die KI zu Aufgabe n") im Ergebnis des Tests mit offener KI-Hilfe. Die
/// Daten laedt `RecentItem.load` (GET /api/recent + Gespraeche der App); ohne Eintraege bleibt die Karte weg.
struct RecentCard: View {
    let items: [RecentItem]
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        UFCard {
            UFCardHead("Zuletzt benutzt", icon: "clock")
            let rows = items
            ForEach(rows) { it in
                // Antippen: an derselben Stelle weiter (Seite, KI-Hilfe mit Gespraech, Wochentest)
                Button { open(it) } label: {
                    UFItemRow(it.title, sub: it.subtitle, wraps: true, leading: {
                        UFIcon(it.icon, size: 16).foregroundStyle(it.kind == .conversation ? UF.accentText : UF.muted).frame(width: 18)
                    }, trailing: {
                        UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted)
                    })
                    .foregroundStyle(UF.text)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zuletzt benutzt: \(it.kindLabel) \(it.title)")
                .accessibilityIdentifier("recent.\(it.id)")
                .ufBorderBottom(it.id != rows.last?.id)
            }
        }
        .accessibilityIdentifier("recent.card")
    }

    /// Ziel je Art (reine Zuordnung, Tests)
    static func route(for it: RecentItem) -> UFRoute {
        if let ask = it.examAsk { return .exam(ask.testID) }
        switch it.kind {
        case .document, .conversation: return .doc(it.key, page: (it.page ?? 1) > 1 ? it.page : nil)
        case .test: return .exam(it.testID ?? 0)
        }
    }

    private func open(_ it: RecentItem) {
        // der Editor (bzw. das Ergebnis des Tests) oeffnet die KI-Hilfe beim Laden
        if it.kind == .conversation { router.tutorOpenRequest = it.key }
        router.go(Self.route(for: it))
    }
}

extension RecentItem {
    /// Dokumente und Tests vom Backend (`GET /api/recent`), Gespraeche aus `conversations`; ein Fehler des Backends
    /// (PC-Server ohne den Endpunkt, 404) laesst nur die Gespraeche uebrig - die Seite blockiert nie
    @MainActor
    /// `aiRecents` nil: die Fragen auf KI-Start (`AIRecents.shared`)
    static func load(api: APIClient?, conversations: TutorConversations, aiRecents: [AIRecents.Entry]? = nil, limit: Int) async -> [RecentItem] {
        var backend: JSONValue?
        if let api { backend = try? await api.value("/api/recent?limit=\(limit)") }
        return merge(backend: backend, conversations: conversations.recent(), aiRecents: aiRecents ?? AIRecents.shared.entries, limit: limit)
    }
}
