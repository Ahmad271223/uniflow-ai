import SwiftUI
import UniFlowCore

/// Zeigt Laden, Fehler, Offline-Stand und Leerzustand einer `RemoteData`-Abfrage einheitlich an.
struct RemoteContent<Content: View>: View {
    @ObservedObject var data: RemoteData
    var emptyTitle = "Keine Einträge"
    var isEmpty: (JSONValue) -> Bool = { _ in false }
    @ViewBuilder var content: (JSONValue) -> Content

    var body: some View {
        switch data.state {
        case .loading:
            ProgressView("Lädt…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Nicht geladen", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut versuchen") { Task { await data.load() } }.buttonStyle(.borderedProminent)
            }
        case .loaded(let value, let offlineSince):
            VStack(spacing: 0) {
                if let offlineSince {
                    Label("Offline – Stand \(Fmt.relative(offlineSince))", systemImage: "icloud.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity).padding(6).background(.orange.opacity(0.1))
                }
                if isEmpty(value) {
                    ContentUnavailableView(emptyTitle, systemImage: "tray")
                } else {
                    content(value)
                }
            }
        }
    }
}

/// Karte im UniFlow-Stil (helle Fläche, runde Ecken, violetter Akzent).
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle").font(.headline).foregroundStyle(.primary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Fortschritt als Balken mit Prozentangabe.
struct ProgressBar: View {
    let value: Double          // 0…1
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: min(max(value, 0), 1)).tint(color)
            Text("\(Int((min(max(value, 0), 1) * 100).rounded())) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct ModuleDot: View {
    let hex: String?
    var body: some View { Circle().fill(Color(hex: hex)).frame(width: 10, height: 10) }
}
