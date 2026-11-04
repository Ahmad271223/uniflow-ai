import SwiftUI
import UniFlowCore

// Seite "Nachrichten" (Auftrag des Inhabers 04.11.2026): der Stud.IP-Posteingang, wie ihn der Abgleich auf dem Geraet
// speichert (`StudIPExtras`, nur die Liste, nie die Einzelansicht, die in Stud.IP als gelesen markieren koennte).
// Liste mit Absender (Rolle statt Name), Betreff, Datum und Punkt "neu seit dem letzten Besuch", Suchfeld, Leser mit dem
// ganzen Text (`UFLongText`), den erkannten Tagen als Chips und "In Stud.IP öffnen". Quer (Fenster breiter als 900 pt)
// Liste und Leser nebeneinander, hochkant schiebt der Leser die Liste weg (Zurueck). Ziehen nach unten startet den
// kurzen Stud.IP-Abgleich (`StudIPSync.run(scope: .lists)`, der auch die Nachrichten holt). Daten: GET
// /api/studip/messages?q= (nur lokales Backend). Nachrichten gehen von hier an keine KI und keinen Dienst.

/// Texte und reine Regeln an einer Stelle (MessagesAppTests)
enum MessagesText {
    static let title = "Nachrichten"
    static let open = "In Stud.IP öffnen"
    static let empty = "Keine Nachrichten"
    static let searchPrompt = "Nachrichten durchsuchen"
    static let back = "Nachrichten"
    static let pick = "Wähle links eine Nachricht aus."
    static let privacy = "Nachrichten bleiben nur auf diesem Gerät; StudiNow markiert sie in Stud.IP nicht als gelesen."

    static func noHits(_ q: String) -> String { "Keine Treffer für „\(q)“" }

    /// "3 Nachrichten", "1 Nachricht"
    static func count(_ n: Int) -> String { n == 1 ? "1 Nachricht" : "\(n) Nachrichten" }

    private static let syncF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = Fmt.zone
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    /// "Zuletzt abgeglichen: 04.11.2026, 09:30 Uhr" bzw. "Noch nicht mit Stud.IP abgeglichen"
    static func syncLine(_ lastRun: Date?) -> String {
        guard let lastRun else { return "Noch nicht mit Stud.IP abgeglichen" }
        return "Zuletzt abgeglichen: \(syncF.string(from: lastRun)) Uhr"
    }

    /// "Mo., 02.11.2026, 08:15 Uhr" aus `sent_at` (Ortszeit wie von Stud.IP genannt)
    static func fullDate(_ sentAt: String?) -> String {
        guard let s = sentAt, s.count >= 10 else { return "" }
        let day = String(s.prefix(10))
        let wd = UFFmt.weekdayShort(day)
        let date = (wd.isEmpty ? "" : "\(wd)., ") + UFFmt.date(day)
        return s.count >= 16 ? "\(date), \(s.dropFirst(11).prefix(5)) Uhr" : date
    }

    /// Chip eines erkannten Tags: "Frist 19.11., 12:00" mit Symbol und Ton wie im Kalender (`UFHint.noticeKind`);
    /// vergangene Tage gedaempft
    static func chip(_ d: JSONValue, today: String) -> (label: String, icon: String, tone: UFTone)? {
        guard let day = d.s("date"), day.count >= 10 else { return nil }
        let k = UFHint.noticeKind(d.s("kind") ?? "")
        let dm = "\(day.dropFirst(8).prefix(2)).\(day.dropFirst(5).prefix(2))."
        let time = d.s("time").flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
        return ("\(k.text) \(dm)\(time)", k.icon, day < today ? .neutral : k.tone)
    }

    /// Erkannte Tage einer Nachricht ohne Doppelte (gleiche Beschriftung)
    static func chips(_ m: JSONValue, today: String) -> [(label: String, icon: String, tone: UFTone)] {
        var seen = Set<String>()
        return m.list("dates").compactMap { chip($0, today: today) }.filter { seen.insert($0.label).inserted }
    }

    /// VoiceOver je Zeile: "Neu, Tutorium entfällt, von Lehrende, 08:15"
    static func rowAccessibility(_ m: JSONValue, isNew: Bool, today: String) -> String {
        var parts = [m.s("subject") ?? "(ohne Betreff)"]
        if let s = m.s("sender"), !s.isEmpty { parts.append("von \(s)") }
        let t = NewsRow.time(m.s("sent_at"), today: today)
        if !t.isEmpty { parts.append(t) }
        return ((isNew ? ["Neu"] : []) + parts).joined(separator: ", ")
    }
}

struct MessagesPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.openURL) private var openURL
    @ObservedObject private var inbox = MessagesInbox.shared

    /// Tag fuer "heute"/"gestern" (Tests: fest)
    var today: String = UFFmt.todayISO()
    /// Tests: Liste und Leser nebeneinander erzwingen (nil: nach Fensterbreite)
    var splitOverride: Bool?

    @State private var messages: [JSONValue] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var failed: String?
    @State private var query = ""
    @State private var selectedID: String?
    /// Marke vor diesem Besuch: Nachrichten danach tragen den Punkt "neu" (bleibt fuer die Dauer des Besuchs)
    @State private var previousMark: String?
    @State private var markTaken = false

    /// `initialQuery`: Suche beim Oeffnen (Tests, Bildvergleich)
    init(today: String = UFFmt.todayISO(), splitOverride: Bool? = nil, initialQuery: String = "") {
        self.today = today
        self.splitOverride = splitOverride
        _query = State(initialValue: initialQuery)
    }

    private var split: Bool { splitOverride ?? (windowWidth > 900) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selected: JSONValue? { messages.first { $0.s("id") == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if split || selected == nil {
                head
                    .padding(EdgeInsets(top: 22.4, leading: 25.6, bottom: 0, trailing: 25.6))
            }
            content
                .padding(EdgeInsets(top: split || selected == nil ? 0 : 12, leading: 25.6, bottom: 20, trailing: 25.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(UF.bg)
        .task(id: trimmedQuery) {
            if loaded { try? await Task.sleep(nanoseconds: 220_000_000) }        // Suche entprellt, erstes Laden sofort
            guard !Task.isCancelled else { return }
            await load()
        }
        .ufReload { await load() }
    }

    // MARK: Kopf

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            UFPageHead(MessagesText.title, sub: subline)
            if total > 0 { searchField.padding(.bottom, 14) }
        }
    }

    private var subline: String {
        total > 0 ? "\(MessagesText.count(total)) · \(MessagesText.syncLine(studip.lastRun))" : MessagesText.syncLine(studip.lastRun)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            UFIcon("search", size: 16).foregroundStyle(UF.muted)
            TextField(MessagesText.searchPrompt, text: $query)
                .ufFont(14.5)
                .foregroundStyle(UF.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(MessagesText.searchPrompt)
                .accessibilityIdentifier("messages.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    UFIcon("x", size: 14).foregroundStyle(UF.muted).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ufHitArea()
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 11.2)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .background(Capsule().fill(UF.surface))
        .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: Inhalt

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if total == 0 || failed != nil {
            pane { scrollList { emptyState } }
        } else if split {
            HStack(alignment: .top, spacing: 0) {
                scrollList { listRows }
                    .frame(width: min(400, max(300, windowWidth * 0.3)))
                Rectangle().fill(UF.line).frame(width: 1).accessibilityHidden(true)
                Group {
                    if let m = selected { reader(m, back: false) } else {
                        UFEmpty(icon: "mail", text: messages.isEmpty ? MessagesText.noHits(trimmedQuery) : MessagesText.pick)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .modifier(MessagesPane())
        } else if let m = selected {
            reader(m, back: true).modifier(MessagesPane())
        } else {
            pane { scrollList { listRows } }
        }
    }

    private func pane<V: View>(@ViewBuilder _ v: () -> V) -> some View { v().modifier(MessagesPane()) }

    /// Liste mit "Ziehen zum Aktualisieren"
    private func scrollList<V: View>(@ViewBuilder _ rows: () -> V) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { rows() }
        }
        .refreshable { await pullRefresh() }
        .accessibilityIdentifier("messages.list")
    }

    @ViewBuilder private var listRows: some View {
        if messages.isEmpty {
            UFEmpty(icon: "search", text: MessagesText.noHits(trimmedQuery))
        } else {
            ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                row(m).ufBorderBottom(i < messages.count - 1)
            }
        }
    }

    private var emptyState: some View {
        UFEmpty(icon: "mail", text: failed.map { "Nachrichten nicht lesbar: \($0)" } ?? MessagesText.empty) {
            Text(MessagesText.syncLine(studip.lastRun)).ufFont(12.8).foregroundStyle(UF.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messages.empty")
    }

    // MARK: Zeile

    private func row(_ m: JSONValue) -> some View {
        let id = m.s("id") ?? ""
        let isNew = MessagesInbox.isNew(m.s("sent_at"), since: previousMark)
        let isSelected = split && id == selectedID
        return Button { select(id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(isNew ? UF.accent : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.s("sender") ?? "Stud.IP").ufFont(12.8, 600).foregroundStyle(UF.text2).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(NewsRow.time(m.s("sent_at"), today: today)).ufFont(12.8).foregroundStyle(UF.muted).fixedSize()
                    }
                    // ganzer Betreff, umbrechend, nie "…" (wie die Karte "Neuigkeiten")
                    Text(m.s("subject") ?? "(ohne Betreff)")
                        .ufFont(14.5, isNew ? 650 : 500, lh: 1.3)
                        .foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !m.list("dates").isEmpty {
                        HStack(spacing: 4) {
                            UFIcon("calendar", size: 12)
                            Text(MessagesText.chips(m, today: today).first?.label ?? "").ufFont(11.84, 500).lineLimit(1)
                        }
                        .foregroundStyle(UF.muted)
                        .padding(.top, 1)
                    }
                }
                if !split { UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted).padding(.top, 4) }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? UF.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MessagesText.rowAccessibility(m, isNew: isNew, today: today))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Öffnet die Nachricht")
        .accessibilityIdentifier("messages.row.\(id)")
    }

    // MARK: Leser

    private func reader(_ m: JSONValue, back: Bool) -> some View {
        let chips = MessagesText.chips(m, today: today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if back {
                    Button { UFMotion.toggle { selectedID = nil } } label: {
                        HStack(spacing: 4) {
                            UFIcon("chevron-left", size: 16)
                            Text(MessagesText.back).ufFont(14.5, 550)
                        }
                        .foregroundStyle(UF.accentText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zurück zu den Nachrichten")
                    .accessibilityIdentifier("messages.back")
                }
                Text(m.s("subject") ?? "(ohne Betreff)")
                    .ufFont(21.6, 700, lh: 1.25, em: -0.01)
                    .foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UFBadge(m.s("sender") ?? "Stud.IP", tone: .info, icon: "user")
                    Text(MessagesText.fullDate(m.s("sent_at"))).ufFont(12.8).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if !chips.isEmpty {
                    UFFlexWrap(gap: 6.4) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, c in UFBadge(c.label, tone: c.tone, icon: c.icon) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Erkannte Termine: " + chips.map(\.label).joined(separator: ", "))
                    .accessibilityIdentifier("messages.dates")
                }
                Rectangle().fill(UF.line).frame(height: 1).accessibilityHidden(true)
                if let text = m.s("text"), !text.isEmpty {
                    UFLongText(text: text, size: 15, lh: 1.6, color: UF.text)
                } else {
                    Text("Diese Nachricht hat keinen Text.").ufFont(14.5).foregroundStyle(UF.muted)
                }
                if let url = UFDayExtras.safeURL(m.s("url")) {
                    UFButton(MessagesText.open, icon: "arrow-right") { openURL(url) }
                        .accessibilityHint("Öffnet den Posteingang in Stud.IP")
                        .accessibilityIdentifier("messages.open")
                        .padding(.top, 4)
                }
                Text(MessagesText.privacy).ufFont(12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: back ? 8 : 22, leading: 24, bottom: 28, trailing: 24))
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(m.s("id"))                                                          // neue Nachricht: oben beginnen
        .accessibilityIdentifier("messages.reader")
    }

    // MARK: Laden

    private func select(_ id: String) {
        if split { selectedID = id } else { UFMotion.toggle { selectedID = id } }
    }

    func load() async {
        guard let api = session.api else { loaded = true; return }
        let q = trimmedQuery
        do {
            let r = try await api.value("/api/studip/messages" + (q.isEmpty ? "" : "?q=\(APIClient.queryValue(q))"))
            guard q == trimmedQuery else { return }                              // inzwischen anders gesucht
            messages = r.list("messages")
            total = r.i("total") ?? messages.count
            failed = nil
        } catch {
            messages = []
            failed = error.localizedDescription
        }
        if let id = selectedID, !messages.contains(where: { $0.s("id") == id }) { selectedID = nil }
        if split, selectedID == nil { selectedID = messages.first?.s("id") }
        loaded = true
        // die Seite ist offen: alles Gespeicherte gilt als gesehen; die Punkte bleiben fuer diesen Besuch (beim ersten
        // Laden zeigt die Liste bis zur Marke alles als neu, danach bleibt `previousMark`)
        await inbox.refresh(api: api)
        let before = inbox.markSeen()
        if !markTaken { previousMark = before; markTaken = true }
    }

    /// Ziehen nach unten: kurzer Stud.IP-Abgleich (holt auch die Nachrichten), dann neu lesen
    private func pullRefresh() async {
        if MessagesInbox.studipConnected(studip), !studip.isRunning { await studip.run(scope: .lists) }
        await load()
    }
}

/// Flaeche der Liste bzw. des Lesers: Karte ueber die ganze Hoehe
private struct MessagesPane: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .clipShape(RoundedRectangle(cornerRadius: UF.r))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }
}
