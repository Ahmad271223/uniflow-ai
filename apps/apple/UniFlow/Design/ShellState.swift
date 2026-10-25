import SwiftUI
import UniFlowCore

/// Gemeinsamer Zustand der Kopfzeile wie in app.js: Sync-Chip (updateSyncChip), Sync starten und
/// Hintergrundaufgabe beobachten (pollBg), globale Suche (globalSearch), Initialen (Avatar).
@MainActor
final class ShellState: ObservableObject {
    struct SearchHit: Identifiable {
        let id: String
        let title: String
        let sub: String
        let icon: String
        let color: Color?
        let route: UFRoute
    }

    @Published private(set) var syncChip: String?
    @Published private(set) var syncRunning = false
    @Published private(set) var lastSyncOK = true
    @Published private(set) var searchHits: [SearchHit] = []
    /// Initialen aus dem Anzeigenamen des Servers (/api/settings); leer ohne Server
    @Published private(set) var initials = ""
    /// wird nach einem abgeschlossenen Sync erhoeht; Ansichten laden dann neu (route() im Web)
    @Published private(set) var reloadToken = 0

    var api: APIClient?
    private var searchTask: Task<Void, Never>?

    /// Symbol je Dokument-/Aufgabentyp (TYPE_ICON in core.js)
    static let typeIcon: [String: String] = [
        "vorlesung": "book", "uebung": "pencil", "test": "exam", "wiederholung": "rotate", "frei": "clock", "loesung": "check",
        "skript": "file-text", "klausur": "flag", "organisatorisch": "info", "sonstiges": "file", "notebook": "note",
        "whiteboard": "square", "pdf": "file-text", "image": "image",
    ]

    /// "Ahmad H." -> "AH": erste Buchstaben der ersten zwei Woerter
    nonisolated static func initials(of name: String?) -> String {
        String((name ?? "").split(whereSeparator: \.isWhitespace).compactMap(\.first).prefix(2)).uppercased()
    }

    func attach(_ api: APIClient?) {
        self.api = api
        Task { await refresh() }
    }

    func refresh() async {
        guard let api else { syncChip = nil; return }
        if let s = try? await api.value("/api/settings"), let name = s.s("user_name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            initials = Self.initials(of: name)
        }
        // lokal gleicht StudIPSync direkt ab (eigener Fortschritt); ein Sync-Protokoll gibt es erst mit S3
        guard !api.isLocal else { syncChip = nil; return }
        await updateSyncChip()
        if let bg = try? await api.value("/api/bg"), bg["running"]?.bool == true { await poll() }
    }

    private func updateSyncChip() async {
        guard let api, let s = try? await api.value("/api/sync/status") else { return }
        if let l = s["log"]?.array?.first {
            lastSyncOK = (l["ok"]?.int ?? (l["ok"]?.bool == true ? 1 : 0)) == 1
            syncChip = "Zuletzt synchronisiert: \(Self.time(l.s("finished_at")))"
        } else {
            lastSyncOK = true
            syncChip = "Noch kein Sync"
        }
    }

    /// POST /api/sync, danach /api/bg alle 3 s bis fertig; Meldung wie im Web.
    func startSync(toast: UFToastCenter) async {
        guard let api else { toast.show("Nicht mit dem UniFlow-Server verbunden"); return }
        do {
            _ = try await api.value("/api/sync", method: "POST")
            toast.show("Synchronisierung gestartet")
            await poll(toast: toast)
        } catch {
            toast.show(error.localizedDescription)
        }
    }

    /// window.pollBg(): Hintergrundaufgabe (Test erstellen, Noten abrufen …) beobachten, danach Meldung und Neuladen
    func pollBackground(toast: UFToastCenter) async { await poll(toast: toast) }

    private func poll(toast: UFToastCenter? = nil) async {
        guard let api else { return }
        var was = false
        while true {
            guard let bg = try? await api.value("/api/bg") else { break }
            if bg["running"]?.bool == true {
                was = true
                syncRunning = true
                syncChip = "\(bg.s("task") ?? "Aufgabe") läuft…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            syncRunning = false
            if was {
                toast?.show(bg.s("message") ?? "Fertig")
                reloadToken += 1
            }
            break
        }
        await updateSyncChip()
    }

    /// GET /api/search?q= ab 2 Zeichen, 220 ms entprellt (debounce in app.js)
    func search(_ q: String) {
        searchTask?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, let api else { searchHits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let enc = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            guard let r = try? await api.value("/api/search?q=\(enc)"), !Task.isCancelled else { return }
            var hits: [SearchHit] = []
            for m in r["modules"]?.array ?? [] {
                guard let id = m.i("id") else { continue }
                hits.append(SearchHit(id: "m\(id)", title: m.s("name") ?? "Modul", sub: "Modul", icon: "book",
                                      color: Color(hex: m.s("color")), route: .module(id)))
            }
            for f in r["files"]?.array ?? [] {
                guard let id = f.s("id") else { continue }
                let type = f.s("doc_type") ?? ""
                let sub = [f.s("subject") ?? "", Self.typeText[type] ?? (f.s("name") ?? "")].filter { !$0.isEmpty }.joined(separator: " · ")
                hits.append(SearchHit(id: "f\(id)", title: f.s("ai_title") ?? f.s("name") ?? "Datei", sub: sub,
                                      icon: Self.typeIcon[type] ?? "file", color: nil, route: .doc(id)))
            }
            searchHits = hits
        }
    }

    /// Bezeichnung je Dokument-/Aufgabentyp (TYPE_TXT in core.js)
    static let typeText: [String: String] = [
        "vorlesung": "Vorlesung", "uebung": "Übung", "test": "Wochentest", "wiederholung": "Wiederholung", "frei": "Lernen",
        "loesung": "Lösung", "skript": "Skript", "klausur": "Klausur", "organisatorisch": "Organisatorisches",
        "sonstiges": "Sonstiges", "notebook": "Notizbuch", "whiteboard": "Whiteboard", "pdf": "PDF", "image": "Bild",
    ]

    /// Wochentage kurz (DAYS in core.js)
    nonisolated static let days = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    static func time(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "–" }
        let t = iso.dropFirst(11).prefix(5)
        return String(t)
    }
}
