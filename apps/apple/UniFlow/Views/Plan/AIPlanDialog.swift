import SwiftUI
import UniFlowCore

/// "KI-Lernplan" (Auftrag des Inhabers vom 07.11.2026): die KI schlaegt aus Modulen, Lehrwochen, Klausuren, Lernzeit und
/// freier Zeit Lernbloecke mit Thema und Dauer vor (`POST /api/calendar/ai-suggest`); der Nutzer waehlt und uebernimmt
/// (`POST /api/calendar/ai-apply`). Nichts wird ungefragt eingetragen. Mit eigenem ChatGPT in jedem Tarif, mit der
/// StudiNow-KI ab Pro AI (Credits); den Weg entscheidet das lokale Backend (`LocalAI.provider`).
struct AIPlanSuggestDialog: View {
    let api: APIClient?
    let start: String
    let days: Int
    /// true = uebernommen
    let onClose: (Bool) -> Void
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufStudiNowAI) private var studinowAI
    @State private var loading = true
    @State private var applying = false
    @State private var error: String?
    @State private var blocks: [JSONValue] = []
    @State private var chosen: Set<Int> = []
    @State private var message: String?
    @State private var credits: JSONValue = .null

    /// Zeile unter dem Titel: woher der Vorschlag kommt und was er kostet
    static func sourceLine(studinowAI: Bool, charged: Int?) -> String {
        if studinowAI {
            if let charged { return "Vorschlag der StudiNow-KI · \(charged) Credits" }
            return "Vorschlag der StudiNow-KI (Credits)"
        }
        return "Vorschlag über dein eigenes ChatGPT · 1 Anfrage"
    }

    /// Ueberschrift eines Tages
    static func dayTitle(_ iso: String, blocks: [JSONValue]) -> String {
        let minutes = blocks.reduce(0) { $0 + ($1.i("minutes") ?? 0) }
        return "\(UFFmt.short(iso)) · \(UFFmt.min(minutes))"
    }

    private var dates: [String] {
        var seen = Set<String>(), out: [String] = []
        for b in blocks { let d = b.s("date") ?? ""; if seen.insert(d).inserted { out.append(d) } }
        return out
    }

    var body: some View {
        UFDialog("KI-Lernplan", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Die KI schlägt Lernblöcke für \(days) Tage ab \(UFFmt.date(start)) vor – aus deinen Modulen, Lehrwochen, Klausurterminen, deiner Lernzeit und den freien Zeiten im Stundenplan. Du wählst, was übernommen wird; vorher wird nichts eingetragen.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Die KI plant …").ufFont(13.76).foregroundStyle(UF.text2)
                    }
                    .padding(.vertical, 16)
                    .accessibilityIdentifier("aiPlan.loading")
                } else if let error {
                    HStack(alignment: .top, spacing: 7.2) {
                        UFIcon("alert", size: 14)
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(13.12).foregroundStyle(UF.bad).padding(.vertical, 8)
                    .accessibilityIdentifier("aiPlan.error")
                } else {
                    Text(Self.sourceLine(studinowAI: studinowAI, charged: credits["charged"]?.int))
                        .ufFont(12.5).foregroundStyle(UF.muted)
                    ForEach(dates, id: \.self) { date in
                        let onDay = blocks.indices.filter { blocks[$0].s("date") == date }
                        Text(Self.dayTitle(date, blocks: onDay.map { blocks[$0] }))
                            .ufFont(13.6, 700).foregroundStyle(UF.text2).padding(.top, 6)
                        ForEach(onDay, id: \.self) { i in row(i) }
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { onClose(false) }
            if !loading, error != nil {
                UFButton("Erneut versuchen", icon: "sync") { Task { await load() } }
            }
            if !loading, error == nil {
                UFButton(applying ? "Übernehme …" : "\(chosen.count) Blöcke übernehmen", icon: "check", kind: .primary) { Task { await apply() } }
                    .disabled(chosen.isEmpty || applying)
                    .accessibilityIdentifier("aiPlan.apply")
            }
        }
        .task { await load() }
    }

    private func row(_ i: Int) -> some View {
        let b = blocks[i]
        let on = chosen.contains(i)
        return Button {
            if on { chosen.remove(i) } else { chosen.insert(i) }
        } label: {
            HStack(alignment: .top, spacing: 9.6) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? UF.accent : UF.muted).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(UFFmt.shortName(b.s("module"))).ufFont(13.76, 700).foregroundStyle(UF.text)
                        Text("·").foregroundStyle(UF.muted)
                        Text(b.s("title") ?? "").ufFont(13.76).foregroundStyle(UF.text).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(UFFmt.min(b.i("minutes") ?? 0)).ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    ForEach(Array(b.list("tasks").enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            UFIcon(ShellState.typeIcon[t.s("type") ?? ""] ?? "file", size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text(t.s("title") ?? "").lineLimit(1)
                            if let f = t.s("file"), !f.isEmpty { Text("(\(f))").foregroundStyle(UF.muted).lineLimit(1) }
                            Spacer(minLength: 2)
                            Text("\(t.i("minutes") ?? 0) min").foregroundStyle(UF.muted)
                        }
                        .ufFont(12.5).foregroundStyle(UF.text2)
                    }
                    if let why = b.s("why"), !why.isEmpty {
                        Text(why).ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ufBorderBottom()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("aiPlan.block.\(i)")
    }

    private func load() async {
        guard let api else { loading = false; error = "Kein Backend."; return }
        loading = true
        error = nil
        do {
            let r = try await api.value("/api/calendar/ai-suggest", method: "POST",
                                        body: ["start": .string(start), "days": .number(Double(days))])
            blocks = r.list("blocks")
            chosen = Set(blocks.indices)
            credits = r["credits"] ?? .null
            message = r.s("message")
            if blocks.isEmpty { error = message ?? "Nichts zu planen." }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func apply() async {
        guard let api else { return }
        applying = true
        let picked = blocks.indices.filter { chosen.contains($0) }.map { blocks[$0] }
        do {
            let r = try await api.value("/api/calendar/ai-apply", method: "POST", body: ["blocks": .array(picked)])
            toast.show(r.s("message") ?? "Lernblöcke übernommen")
            onClose(true)
        } catch {
            toast.show(error.localizedDescription)
            applying = false
        }
    }
}
