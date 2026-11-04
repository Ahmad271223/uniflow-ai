import SwiftUI
import UniFlowCore

/// "Videos & Links" im Modulordner der Bibliothek (docs/DATEIARTEN.md, 04.11.2026): Aufzeichnungen und Video-Links
/// (YouTube, Opencast, TIB AV-Portal …), die der Abgleich schon kennt (`RecordingLibrary`, Dateilisten, Courseware und
/// Kursbeschreibungen) - als Eintraege mit Titel, ohne Download. Abspielen im vorhandenen Player, Links im Browser;
/// dieselbe Zeile wie im Bereich Aufzeichnungen (`RecordingRow`). Keine eigene Erkennung.
struct LibraryVideoLinks: View {
    let moduleID: Int
    @EnvironmentObject private var studip: StudIPSync
    @State private var entries: [OpencastEntry]?
    @State private var playing: OpencastEntry?

    var body: some View {
        Group {
            if let entries, !entries.isEmpty {
                LibraryQuickCard(title: "Videos & Links", icon: "play") {
                    VStack(spacing: 0) {
                        ForEach(entries) { e in
                            RecordingRow(entry: e, library: studip.recordings) { playing = e }
                        }
                    }
                    .accessibilityIdentifier("library.videos")
                    Text("Videos gehören den Lehrenden: nur privat ansehen, kein Teilen. Links öffnen im Browser.")
                        .ufFont(11.52).foregroundStyle(UF.muted).padding(.top, 6)
                }
            }
        }
        .task(id: "\(moduleID)-\(studip.recordings.revision)") {
            entries = await studip.recordings.blocks(moduleID: moduleID).flatMap(\.entries)
        }
        .fullScreenCover(item: $playing) { e in RecordingPlayerView(entry: e, library: studip.recordings) }
    }

    /// Modul eines Bibliothekspfads "m<id>" (nur der Modulordner selbst, nicht seine Unterordner)
    static func moduleID(path: String?) -> Int? {
        guard let path, path.hasPrefix("m"), !path.contains("/"), let id = Int(path.dropFirst()) else { return nil }
        return id
    }
}
