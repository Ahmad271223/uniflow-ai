import SwiftUI
import UniFlowCore

// Eigene Karteikarten nach viewCards() in app/static/views-misc.js, fuer das iPad ohne PC erweitert: Karte anlegen
// (Frage, Antwort, optional Modul und Dokument), Liste je Modul, "Heute faellig (N)", Wiederholen mit Aufdecken und
// Richtig/Falsch, Loeschen mit Rueckfrage. Daten ueber /api/flashcards* (lokal FlashcardEndpoints in der Datenbank des
// Containers, also je Apple-Nutzer und Hochschule). Karten entstehen nur von Hand, keine KI. Lokal nur mit Plus: die
// Seite zeigt unter ihrem Kopf UFGate(.flashcards) wie die Community; ohne Plus wird nichts geladen.

/// Stapel der Karteikarten-Seite: alle Karten, die heute faelligen, die laufende Wiederholung, Anlegen und Loeschen.
/// Gehoert zu genau einer Datenquelle: wechselt sie (anderes Konto, andere Hochschule, eigener Server), beginnt der
/// Stapel von vorn, und Antworten der alten Quelle werden verworfen (Pruefpunkt 270). Eine Karte wird in einer
/// Wiederholung hoechstens einmal bewertet, auch bei schnellen Doppeltipps (Pruefpunkt 269).
@MainActor
final class FlashcardDeck: ObservableObject {
    /// Karten eines Moduls (Modul der Datei, sonst Fach der Karte, sonst "Ohne Modul")
    struct Group: Identifiable {
        let id: String
        let title: String
        let color: String?
        let cards: [JSONValue]
    }

    /// Datenquelle, zu der der Stapel gehoert
    private(set) var api: APIClient?
    @Published private(set) var all: [JSONValue] = []
    @Published private(set) var due: [JSONValue] = []
    /// Module und Dokumente der Bibliothek (Zuordnung der Karten, Auswahl beim Anlegen)
    @Published private(set) var modules: [JSONValue] = []
    @Published private(set) var files: [JSONValue] = []
    @Published private(set) var loaded = false
    /// erstes Laden gescheitert (ohne Stand)
    @Published private(set) var failed: String?
    // Wiederholung: die bei Beginn faelligen Karten in fester Reihenfolge
    @Published private(set) var inSession = false
    @Published private(set) var queue: [JSONValue] = []
    @Published private(set) var position = 0
    @Published private(set) var revealed = false
    /// Bewertung unterwegs: Knoepfe gesperrt, ein zweiter Tipp bewertet nichts
    @Published private(set) var rating = false
    @Published private(set) var right = 0
    @Published private(set) var wrong = 0
    /// in dieser Wiederholung schon bewertete Karten
    private var rated: Set<Int> = []
    /// zaehlt Wechsel der Datenquelle; Antworten einer frueheren Quelle aendern nichts mehr
    private var generation = 0

    init(api: APIClient? = nil) { self.api = api }

    /// Andere Datenquelle: alles von vorn, laufende Antworten verfallen
    func attach(_ new: APIClient?) {
        guard new !== api else { return }
        api = new
        generation += 1
        all = []
        due = []
        modules = []
        files = []
        loaded = false
        failed = nil
        endSession()
    }

    func load() async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        async let a = api.value("/api/flashcards")
        async let d = api.value("/api/flashcards?due=true")
        async let l = api.value("/api/library")
        let (av, dv, lv) = try await (a, d, l)
        guard mine == generation else { return }
        all = av.items
        due = dv.items
        modules = lv.list("modules")
        files = lv.list("files")
        loaded = true
        failed = nil
    }

    /// Laden mit sichtbarem Fehler; ohne frueheren Stand zeigt die Seite dann die Fehlerkarte
    @discardableResult
    func reload(toast: UFToastCenter) async -> Bool {
        let mine = generation
        let ok = await toast.attempt("Karteikarten laden") { try await self.load() }
        if !ok, mine == generation, !loaded { failed = "Die Karteikarten konnten nicht geladen werden." }
        return ok
    }

    // MARK: Wiederholung

    var current: JSONValue? { inSession && position < queue.count ? queue[position] : nil }
    var finished: Bool { inSession && position >= queue.count }

    func startReview() {
        guard !due.isEmpty else { return }
        queue = due
        position = 0
        revealed = false
        right = 0
        wrong = 0
        rated = []
        inSession = true
    }

    func endSession() {
        inSession = false
        queue = []
        position = 0
        revealed = false
        rating = false
        rated = []
        right = 0
        wrong = 0
    }

    func reveal() { if current != nil { revealed = true } }

    /// Bewertet die aktuelle Karte einmal: nur aufgedeckt, nicht waehrend einer laufenden Bewertung, nie zweimal
    /// dieselbe Karte. true = gespeichert, die naechste Karte ist dran. Bei einem Fehler bleibt die Karte stehen.
    @discardableResult
    func rate(correct: Bool) async throws -> Bool {
        guard let api, let card = current, revealed, !rating, let id = card.i("id"), !rated.contains(id) else { return false }
        let mine = generation
        rating = true
        defer { if mine == generation { rating = false } }
        _ = try await api.value("/api/flashcards/\(id)/review", method: "POST", body: ["correct": .bool(correct)])
        guard mine == generation else { return false }
        rated.insert(id)
        if correct { right += 1 } else { wrong += 1 }
        position += 1
        revealed = false
        return true
    }

    // MARK: Anlegen und Loeschen

    /// Eine Karte anlegen; Frage und Antwort ohne Leerraum aussen, beide Pflicht. Mit Dokument bekommt sie das Fach
    /// seines Kurses (wie `add_flashcards`).
    func create(question: String, answer: String, fileID: String?) async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines), a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { throw APIError(status: -1, message: "", text: "Frage und Antwort sind nötig.") }
        let mine = generation
        var body: [String: JSONValue] = ["cards": [["question": .string(q), "answer": .string(a)]]]
        if let fileID, !fileID.isEmpty { body["file_id"] = .string(fileID) }
        let r = try await api.value("/api/flashcards", method: "POST", body: .object(body))
        guard r.i("count") == 1 else { throw APIError(status: -1, message: "", text: "Die Karte wurde nicht gespeichert.") }
        guard mine == generation else { return }
        try await load()
    }

    func delete(_ card: JSONValue) async throws {
        guard let api, let id = card.i("id") else { return }
        let mine = generation
        _ = try await api.value("/api/flashcards/\(id)", method: "DELETE")
        guard mine == generation else { return }
        // aus der laufenden Wiederholung nehmen: eine geloeschte Karte wird nicht mehr bewertet
        if let i = queue.firstIndex(where: { $0.i("id") == id }) {
            queue.remove(at: i)
            if i < position { position -= 1 } else if i == position { revealed = false }
        }
        try await load()
    }

    // MARK: Anzeige

    var dueIDs: Set<Int> { Set(due.compactMap { $0.i("id") }) }

    /// Naechster Termin, wenn heute nichts faellig ist (alle Termine liegen dann in der Zukunft)
    var nextDue: String? { all.compactMap { $0.s("due") }.filter { !$0.isEmpty }.min() }

    /// Titel des Dokuments einer Karte (Bibliothek), sonst der Dateiname aus der Antwort
    func fileTitle(_ card: JSONValue) -> String? {
        guard let id = card.s("file_id"), !id.isEmpty else { return nil }
        return files.first { $0.s("id") == id }.flatMap { $0.s("title") ?? $0.s("name") } ?? card.s("file_name")
    }

    /// Dokumente zur Auswahl beim Anlegen (alle oder die eines Moduls)
    func documents(module: Int) -> [JSONValue] {
        files.filter { module == 0 || $0.i("module_id") == module }
    }

    func groupTitle(_ card: JSONValue) -> String { groups.first { g in g.cards.contains { $0.i("id") == card.i("id") } }?.title ?? "Ohne Modul" }

    /// Liste je Modul in der Reihenfolge der Module, danach Faecher ohne Modul, zuletzt "Ohne Modul"
    var groups: [Group] {
        let moduleOfFile = Dictionary(files.compactMap { f in f.s("id").map { ($0, f.i("module_id")) } }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(modules.compactMap { m in m.i("id").map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(modules.compactMap { m in m.s("name").map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        func key(_ c: JSONValue) -> String {
            if let f = c.s("file_id"), let mid = moduleOfFile[f] ?? nil, byID[mid] != nil { return "m\(mid)" }
            if let s = c.s("subject"), !s.isEmpty {
                if let mid = byName[s]?.i("id") { return "m\(mid)" }
                return "s" + s
            }
            return ""
        }
        var buckets: [String: [JSONValue]] = [:]
        for c in all { buckets[key(c), default: []].append(c) }
        var out: [Group] = []
        for m in modules {
            guard let mid = m.i("id"), let cards = buckets.removeValue(forKey: "m\(mid)") else { continue }
            out.append(Group(id: "m\(mid)", title: m.s("name") ?? "", color: m.s("color"), cards: cards))
        }
        for k in buckets.keys.filter({ $0.hasPrefix("s") }).sorted() {
            out.append(Group(id: k, title: String(k.dropFirst()), color: nil, cards: buckets[k] ?? []))
        }
        if let rest = buckets[""] { out.append(Group(id: "none", title: "Ohne Modul", color: nil, cards: rest)) }
        return out
    }
}

// MARK: - Seite

struct CardsPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @StateObject private var deck = FlashcardDeck()
    @ObservedObject private var ent: Entitlements

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(entitlements: Entitlements? = nil) {
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
    }

    /// Ohne PC (lokales Backend) nur mit Plus; am eigenen Server (Entwicklung) ohne Tarif
    private var needsPlus: Bool { session.api?.isLocal != false }
    private var allowed: Bool { !needsPlus || ent.allows(.flashcards) }

    var body: some View {
        UFContent(maxWidth: 820) {
            UFPageHead("Karteikarten", sub: "Selbst angelegt · Leitner-System: richtig = seltener, falsch = morgen wieder.") {
                if !needsPlus { UFButton("Tests", icon: "arrow-left", size: .small) { router.go(.exams) } }
                if allowed && deck.loaded { UFButton("Karte anlegen", icon: "plus", kind: .primary, size: .small) { openCreate() } }
            }
            if needsPlus {
                UFGate(.flashcards, entitlements: ent) { cards }
            } else {
                cards
            }
        }
    }

    /// Inhalt unter dem Kopf; laedt erst, wenn er sichtbar ist (mit Plus bzw. am eigenen Server)
    private var cards: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failed = deck.failed {
                UFCard {
                    UFEmpty(icon: "alert", text: failed) {
                        UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await deck.reload(toast: toast) } }
                    }
                }
            } else if !deck.loaded {
                UFSkeleton().frame(height: 180)
            } else if deck.all.isEmpty && !deck.inSession {
                UFCard {
                    UFEmpty(icon: "cards", text: "Noch keine Karteikarten. Lege deine erste Karte an: vorn die Frage, hinten die Antwort. Richtig beantwortete Karten kommen seltener wieder, falsche am nächsten Tag.") {
                        UFButton("Erste Karte anlegen", icon: "plus", kind: .primary, size: .small) { openCreate() }.padding(.top, 8)
                    }
                }
            } else {
                reviewCard
                list.padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.api.map(ObjectIdentifier.init)) {
            deck.attach(session.api)
            await deck.reload(toast: toast)
        }
        .ufReload { await deck.reload(toast: toast) }
    }

    // MARK: Heute faellig

    @ViewBuilder private var reviewCard: some View {
        if deck.finished {
            UFCard {
                UFCardHead("Wiederholung geschafft", icon: "check")
                let n = deck.right + deck.wrong                              // bewertete Karten (geloeschte zaehlen mit)
                Text("\(n) \(n == 1 ? "Karte" : "Karten") wiederholt: \(deck.right) richtig, \(deck.wrong) falsch.")
                    .ufFont(14.5).foregroundStyle(UF.text2)
                UFButton("Fertig", kind: .primary, size: .small) {
                    deck.endSession()
                    Task { await deck.reload(toast: toast) }
                }
                .padding(.top, 12.8)
            }
        } else if let c = deck.current {
            UFCard {
                UFCardHead("Heute fällig (\(deck.queue.count))", icon: "cards") {
                    UFButton("Beenden", size: .small) {
                        deck.endSession()
                        Task { await deck.reload(toast: toast) }
                    }
                }
                Text("Karte \(deck.position + 1) von \(deck.queue.count) · Fach \(c.i("box") ?? 1) · \(deck.groupTitle(c))")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 8)
                Button { deck.reveal() } label: {                         // .fc-card
                    VStack(spacing: 0) {
                        Text(c.s("question") ?? "").foregroundStyle(UF.text)
                        if deck.revealed {
                            Rectangle().fill(UF.line).frame(height: 1).padding(.vertical, 12.8)
                            Text(c.s("answer") ?? "").foregroundStyle(UF.accentText)
                        } else {
                            Text("Tippen zum Aufdecken").ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 9.6)
                        }
                    }
                    .ufFont(16.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(25.6 + ufB)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
                    .ufShadow(.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(deck.revealed ? "Antwort: \(c.s("answer") ?? "")" : "Frage: \(c.s("question") ?? "")")
                HStack(spacing: 9.6) {
                    if deck.revealed {
                        UFButton("Falsch", icon: "x", kind: .danger) { rate(false) }.disabled(deck.rating)
                        UFButton("Richtig", icon: "check", kind: .ok) { rate(true) }.disabled(deck.rating)
                    } else {
                        UFButton("Antwort zeigen", kind: .primary) { deck.reveal() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12.8)
            }
        } else {
            UFCard {
                UFCardHead("Heute fällig (\(deck.due.count))", icon: "cards")
                if deck.due.isEmpty {
                    Text(deck.nextDue.map { "Heute ist nichts fällig. Die nächste Wiederholung ist am \(UFFmt.date($0))." } ?? "Heute ist nichts fällig.")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                } else {
                    Text("Erst die Frage lesen, dann aufdecken und selbst bewerten.").ufFont(14.5).foregroundStyle(UF.text2)
                    UFButton("Wiederholen", icon: "play", kind: .primary, size: .small) { deck.startReview() }
                        .padding(.top, 12.8)
                }
            }
        }
    }

    private func rate(_ correct: Bool) {
        Task { _ = await toast.attempt("Bewerten") { try await deck.rate(correct: correct) } }
    }

    // MARK: Alle Karten je Modul

    private var list: some View {
        UFCard {
            UFCardHead("Alle Karten") { Text("\(deck.all.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            let due = deck.dueIDs
            ForEach(deck.groups) { g in
                HStack(spacing: 7.2) {
                    UFDot(color: g.color.map { Color(hex: $0) } ?? UF.lineStrong)
                    Text(g.title).ufFont(13.6, 650).foregroundStyle(UF.text2)
                    Text("\(g.cards.count)").ufFont(12.8).foregroundStyle(UF.muted)
                }
                .padding(.top, g.id == deck.groups.first?.id ? 0 : 14.4)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
                let rows = Row.rows(g.cards)
                ForEach(rows) { row in
                    let c = row.value
                    UFItemRow(c.s("question") ?? "", sub: subline(c, due: due)) {
                        EmptyView()
                    } trailing: {
                        UFButton(icon: "trash", kind: .ghost, size: .small) { confirmDelete(c) }
                            .accessibilityLabel("Karte löschen: \(c.s("question") ?? "")")
                    }
                    .ufBorderBottom(row.id != rows.last?.id)
                }
            }
        }
    }

    private func subline(_ c: JSONValue, due: Set<Int>) -> String {
        var parts = [c.s("answer") ?? "", "Fach \(c.i("box") ?? 1)"]
        parts.append(c.i("id").map { due.contains($0) } == true ? "heute fällig" : "fällig am \(UFFmt.date(c.s("due")))")
        if let f = deck.fileTitle(c) { parts.append(f) }
        return parts.joined(separator: " · ")
    }

    private func openCreate() {
        overlay.modal { FlashcardCreateDialog(deck: deck, entitlements: ent) }
    }

    private func confirmDelete(_ c: JSONValue) {
        overlay.modal { FlashcardDeleteDialog(deck: deck, card: c) }
    }
}

// MARK: - Dialoge

/// Karte anlegen: Frage und Antwort (Pflicht), Modul und Dokument (optional). Das Modul einer Karte ergibt sich wie am
/// PC aus dem Dokument (Fach seines Kurses); die Modulauswahl grenzt die Dokumente ein.
struct FlashcardCreateDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let entitlements: Entitlements
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var question = ""
    @State private var answer = ""
    @State private var module = 0
    @State private var file = ""
    @State private var saving = false

    var body: some View {
        UFDialog("Karte anlegen", icon: "cards") {
            UFField("Frage") { UFTextArea(placeholder: "Vorderseite", text: $question, minHeight: 64) }
            UFField("Antwort") { UFTextArea(placeholder: "Rückseite", text: $answer, minHeight: 64) }
            UFField("Modul (optional)") {
                UFSelect(options: [(0, "– keins –")] + deck.modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                         selection: $module, fill: true)
            }
            UFField("Dokument (optional)") {
                UFSelect(options: [("", "– keins –")] + deck.documents(module: module).compactMap { f in
                    f.s("id").map { ($0, f.s("title") ?? f.s("name") ?? $0) }
                }, selection: $file, fill: true)
            }
            if module != 0 && file.isEmpty {
                Text("Wähle ein Dokument des Moduls, damit die Karte unter diesem Modul steht.")
                    .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 2)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Anlegen", icon: "plus", kind: .primary) { Task { await save() } }
                .disabled(!canSave || saving)
        }
        .onChange(of: module) { _, m in
            // Dokument eines anderen Moduls passt nicht mehr
            if m != 0, !file.isEmpty, !deck.documents(module: m).contains(where: { $0.s("id") == file }) { file = "" }
        }
    }

    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard canSave, !saving else { return }
        // lokal nur mit Plus: Tarif inzwischen abgelaufen, waehrend der Dialog offen war
        if session.api?.isLocal != false && !entitlements.allows(.flashcards) {
            toast.show("Eigene Karteikarten gibt es ab \(UFPlan.plus.name).")
            return
        }
        saving = true
        defer { saving = false }
        if await toast.attempt("Karte anlegen", { try await deck.create(question: question, answer: answer, fileID: file.isEmpty ? nil : file) }) {
            toast.show("Karte angelegt")
            close()
        }
    }
}

/// Rueckfrage vor dem Loeschen einer Karte (mit ihrem Lernstand)
struct FlashcardDeleteDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let card: JSONValue
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Karte löschen?", icon: "trash") {
            Text(card.s("question") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).padding(.vertical, 5.6)
            Text("Die Karte und ihr Lernstand (Fach \(card.i("box") ?? 1)) werden gelöscht. Das lässt sich nicht rückgängig machen.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Löschen", icon: "trash", kind: .danger) {
                close()
                Task {
                    if await toast.attempt("Karte löschen", { try await deck.delete(card) }) { toast.show("Karte gelöscht") }
                }
            }
        }
    }
}
