import SwiftUI
import UniFlowCore

// Karteikarten-Trainer ("Frei üben") neben der Wiederholung "Heute fällig": alle Karten im eigenen Tempo durchgehen,
// eine grosse Karte in der Mitte (Tippen dreht Begriff <-> Definition), wischen nach rechts = gewusst, nach links =
// nicht gewusst (dieselben Aktionen als Knoepfe, Tastatur-Pfeile und VoiceOver-Aktionen), "Vorherige" nimmt die letzte
// Antwort zurueck. Optionen: Alle | Lesezeichen, Fortschritt (Richtig, Falsch, Noch nicht gelernt, Versteckte Karten),
// Reihenfolge Original | Zufällig, zuerst Begriff | Definition.
//
// Der Trainer aendert den Wiederholungsplan NICHT: Fach und Termin (Leitner, POST /review) bleiben allein Sache von
// "Heute fällig". Er speichert nur das letzte eigene Urteil (last_result), Lesezeichen und "versteckt" ueber
// PATCH /api/flashcards/{id} (app/server.py patch_flashcard, lokal FlashcardEndpoints). So kann man vor einer Klausur
// beliebig oft ueben, ohne dass richtig getippte Karten wochenlang aus der Wiederholung verschwinden.

/// Fortschritt einer Karte fuer den Filter: jede Karte steht in genau einer Gruppe (versteckt geht vor dem Urteil)
enum FlashcardProgress: String, CaseIterable, Hashable {
    case right, wrong, unlearned, hidden

    var label: String {
        switch self {
        case .right: return "Richtig"
        case .wrong: return "Falsch"
        case .unlearned: return "Noch nicht gelernt"
        case .hidden: return "Versteckte Karten"
        }
    }

    static func of(_ card: JSONValue) -> FlashcardProgress {
        if (card.i("hidden") ?? 0) != 0 { return .hidden }
        switch card.s("last_result") {
        case "right": return .right
        case "wrong": return .wrong
        default: return .unlearned
        }
    }
}

/// Optionen des Trainers (Blatt "Optionen")
struct FlashcardTrainerOptions: Equatable {
    enum Scope: Hashable { case all, bookmarked }
    enum Order: Hashable { case original, random }
    enum Side: Hashable { case term, definition }

    var scope: Scope = .all
    /// Mehrfachauswahl; versteckte Karten nur, wenn "Versteckte Karten" gewaehlt ist
    var progress: Set<FlashcardProgress> = [.right, .wrong, .unlearned]
    var order: Order = .original
    var firstSide: Side = .term

    static let standard = FlashcardTrainerOptions()

    func matches(_ card: JSONValue) -> Bool {
        (scope == .all || (card.i("bookmarked") ?? 0) != 0) && progress.contains(FlashcardProgress.of(card))
    }

    /// Karten fuer einen Durchgang: gefiltert, "Original" = Reihenfolge des Anlegens (aelteste zuerst), "Zufällig"
    /// mit `shuffle` (im Test fest)
    func select(_ cards: [JSONValue], shuffle: ([JSONValue]) -> [JSONValue] = { $0.shuffled() }) -> [JSONValue] {
        let picked = cards.filter(matches).sorted { ($0.i("id") ?? 0) < ($1.i("id") ?? 0) }
        return order == .random ? shuffle(picked) : picked
    }
}

/// Ablauf des Trainers. Gehoert wie `FlashcardDeck` zu genau einer Datenquelle; nach einem Wechsel verfallen
/// laufende Antworten. Jede Antwort wird einmal gezaehlt, auch bei schnellen Doppeltipps oder Wischen + Tippen.
@MainActor
final class FlashcardTrainer: ObservableObject {
    /// eine gegebene Antwort, fuer "Vorherige"
    struct Answer: Equatable {
        let index: Int
        let id: Int
        let known: Bool
        /// last_result vor der Antwort (wird beim Zuruecknehmen wieder gespeichert)
        let before: JSONValue
    }

    private(set) var api: APIClient?
    @Published var options = FlashcardTrainerOptions.standard
    @Published private(set) var active = false
    @Published private(set) var cards: [JSONValue] = []
    @Published private(set) var position = 0
    /// Rueckseite sichtbar (die Seite, die nicht zuerst gezeigt wird)
    @Published private(set) var flipped = false
    @Published private(set) var known = 0
    @Published private(set) var unknown = 0
    @Published private(set) var answers: [Answer] = []
    /// Speichern unterwegs: weitere Antworten warten nicht, sie zaehlen nicht
    @Published private(set) var busy = false
    /// alle Karten beim Start (Neu starten, Optionen anwenden)
    private(set) var source: [JSONValue] = []
    /// Mischen fuer "Zufällig"; Tests setzen eine feste Reihenfolge
    var shuffle: ([JSONValue]) -> [JSONValue] = { $0.shuffled() }
    private var generation = 0

    init(api: APIClient? = nil) { self.api = api }

    func attach(_ new: APIClient?) {
        guard new !== api else { return }
        api = new
        generation += 1
        source = []
        end()
    }

    var current: JSONValue? { active && position < cards.count ? cards[position] : nil }
    var finished: Bool { active && !cards.isEmpty && position >= cards.count }
    /// Durchgang ohne passende Karte (Filter zu eng)
    var empty: Bool { active && cards.isEmpty }
    var canGoBack: Bool { active && !answers.isEmpty && !busy }
    /// "Erneut fragen" moeglich: eine Karte liegt vorn und danach kommt noch mindestens eine andere
    var canAskAgain: Bool { current != nil && !busy && position + 1 < cards.count }

    /// "Erneut fragen": so viele Karten spaeter kommt dieselbe Karte noch einmal (ohne Urteil, zaehlt nicht)
    static let askAgainGap = 3

    /// Die aktuelle Karte ohne Urteil nach hinten schieben: sie kommt nach `askAgainGap` Karten wieder (am Ende,
    /// wenn weniger folgen). Nichts wird gespeichert; "Vorherige" nimmt nur Antworten zurueck, nicht das Verschieben.
    @discardableResult
    func askAgain() -> Bool {
        guard canAskAgain, let card = current else { return false }
        cards.remove(at: position)
        cards.insert(card, at: min(position + Self.askAgainGap, cards.count))
        flipped = false
        return true
    }
    /// zeigt gerade die Definition (Antwort)
    var showsDefinition: Bool { (options.firstSide == .definition) != flipped }
    /// "3/20": die aktuelle Karte, am Ende die Gesamtzahl
    var progressText: String { "\(min(position + 1, cards.count))/\(cards.count)" }

    // MARK: Durchgang

    func start(with all: [JSONValue]) {
        source = all
        begin(options.select(all, shuffle: shuffle))
    }

    /// Neu starten mit denselben Optionen (Zufall mischt neu)
    func restart() { begin(options.select(source, shuffle: shuffle)) }

    /// Optionen uebernehmen und neu beginnen
    func apply(_ new: FlashcardTrainerOptions) {
        options = new
        restart()
    }

    /// Nur die Karten, die in diesem Durchgang nicht gewusst waren, in ihrer Reihenfolge
    func practiceUnknown() {
        let ids = Set(answers.filter { !$0.known }.map(\.id))
        begin(cards.filter { ($0.i("id")).map(ids.contains) == true })
    }

    func end() {
        active = false
        cards = []
        position = 0
        flipped = false
        known = 0
        unknown = 0
        answers = []
        busy = false
    }

    private func begin(_ list: [JSONValue]) {
        cards = list
        position = 0
        flipped = false
        known = 0
        unknown = 0
        answers = []
        active = true
    }

    func flip() { if current != nil { flipped.toggle() } }

    /// Antwort auf die aktuelle Karte: speichert das Urteil, zaehlt und zeigt die naechste Karte (vorn).
    /// false, wenn nichts zu bewerten war (keine Karte, Speichern unterwegs, andere Datenquelle).
    @discardableResult
    func answer(known isKnown: Bool) async throws -> Bool {
        guard let api, let card = current, !busy, let id = card.i("id") else { return false }
        let mine = generation, index = position
        busy = true
        defer { if mine == generation { busy = false } }
        let saved = try await api.value("/api/flashcards/\(id)", method: "PATCH", body: ["last_result": .string(isKnown ? "right" : "wrong")])
        guard mine == generation, active, position == index else { return false }
        answers.append(Answer(index: index, id: id, known: isKnown, before: card["last_result"] ?? .null))
        merge(saved)
        if isKnown { known += 1 } else { unknown += 1 }
        position += 1
        flipped = false
        return true
    }

    /// "Vorherige": nimmt die letzte Antwort zurueck (Zaehler und gespeichertes Urteil) und zeigt die Karte wieder vorn
    @discardableResult
    func previous() async throws -> Bool {
        guard let api, let last = answers.last, !busy else { return false }
        let mine = generation
        busy = true
        defer { if mine == generation { busy = false } }
        let saved = try await api.value("/api/flashcards/\(last.id)", method: "PATCH", body: ["last_result": last.before])
        guard mine == generation, answers.last == last else { return false }
        answers.removeLast()
        merge(saved)
        if last.known { known -= 1 } else { unknown -= 1 }
        position = last.index
        flipped = false
        return true
    }

    /// Lesezeichen der aktuellen Karte umschalten
    func toggleBookmark() async throws {
        guard let api, let card = current, !busy, let id = card.i("id") else { return }
        let mine = generation
        busy = true
        defer { if mine == generation { busy = false } }
        let on = (card.i("bookmarked") ?? 0) == 0
        let saved = try await api.value("/api/flashcards/\(id)", method: "PATCH", body: ["bookmarked": .bool(on)])
        guard mine == generation else { return }
        merge(saved)
    }

    /// Aktuelle Karte verstecken bzw. wieder zeigen. Passt sie danach nicht mehr zum Filter (versteckt, ohne
    /// "Versteckte Karten"), verlaesst sie den Durchgang; die naechste Karte rueckt nach.
    func toggleHidden() async throws {
        guard let api, let card = current, !busy, let id = card.i("id") else { return }
        let mine = generation
        busy = true
        defer { if mine == generation { busy = false } }
        let hide = (card.i("hidden") ?? 0) == 0
        let saved = try await api.value("/api/flashcards/\(id)", method: "PATCH", body: ["hidden": .bool(hide)])
        guard mine == generation else { return }
        merge(saved)
        if let now = current, now.i("id") == id, !options.matches(now) {
            cards.remove(at: position)
            flipped = false
        }
    }

    /// Gespeicherten Stand (Antwort von PATCH, ohne file_name) in Durchgang und Ausgangsliste uebernehmen; nach
    /// "Bearbeiten" (04.11.2026) auch Frage, Antwort, Fach und Stapel, die Karte bleibt an ihrer Stelle
    func merge(_ saved: JSONValue) {
        guard let id = saved.i("id") else { return }
        func updated(_ c: JSONValue) -> JSONValue {
            var c = c
            for k in ["bookmarked", "hidden", "last_result"] { c[k] = saved[k] ?? .null }
            for k in ["question", "answer", "subject", "stack_id"] where saved[k] != nil { c[k] = saved[k] }
            return c
        }
        cards = cards.map { $0.i("id") == id ? updated($0) : $0 }
        source = source.map { $0.i("id") == id ? updated($0) : $0 }
    }

    /// Zahl der Karten je Gruppe (Optionen, Startkarte)
    static func counts(_ cards: [JSONValue]) -> [FlashcardProgress: Int] {
        Dictionary(grouping: cards, by: FlashcardProgress.of).mapValues(\.count)
    }
}

// MARK: - Buehne: Fortschritt, grosse Karte, grosse Antworten (Trainer und "Heute fällig")

// Neugestaltung 04.11.2026 (Vorbild-Vergleich): Karteikarten wirken wie Gegenstaende. Oben "Karte 3 von 12" mit
// Balken, in der Mitte eine grosse Karte (Tippen dreht sie um die senkrechte Achse; bei "Bewegung reduzieren" nur
// Ueberblenden), darunter die beiden grossen Antworten in Gruen und Rot. Dieselben Bausteine nutzt die Wiederholung
// "Heute fällig" auf der Karteikarten-Seite.

/// Fortschritt oben: "Karte 3 von 12" gross, Zusatz darunter, Zaehler rechts, Balken der erledigten Karten
struct FlashcardProgressHeader<Trailing: View>: View {
    /// aktuelle Karte, 1-basiert
    let current: Int
    let total: Int
    /// erledigte Karten (fuer den Balken)
    let done: Int
    var detail: String?
    @ViewBuilder var trailing: Trailing

    init(current: Int, total: Int, done: Int, detail: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.current = current
        self.total = total
        self.done = done
        self.detail = detail
        self.trailing = trailing()
    }

    /// "Karte 3 von 12"; am Ende die letzte Karte, nie "Karte 0"
    static func label(current: Int, total: Int) -> String { "Karte \(min(max(current, 1), max(total, 1))) von \(total)" }

    /// Anteil fuer den Balken (0...1)
    static func fraction(done: Int, total: Int) -> Double { total <= 0 ? 0 : min(1, max(0, Double(done) / Double(total))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    titles
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { trailing }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titles
                    HStack(spacing: 8) { trailing }
                }
            }
            UFProgress(value: Self.fraction(done: done, total: total), height: 8)
                .accessibilityHidden(true)
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.label(current: current, total: total))
                .ufFont(19.2, 700, em: -0.01).monospacedDigit().foregroundStyle(UF.text)
            if let detail {
                Text(detail).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Grosse Karte: Vorder- und Rueckseite. Mit Bewegung dreht sie sich um die senkrechte Achse (die Seite wechselt bei
/// 90 Grad, die Rueckseite steht nie spiegelverkehrt); bei "Bewegung reduzieren" und unter XCTest nur Ueberblenden.
struct FlashcardFlip<Front: View, Back: View>: View {
    let flipped: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || !UFMotion.moves {
            ZStack {
                if flipped { back.transition(.opacity) } else { front.transition(.opacity) }
            }
        } else {
            FlashcardFlipEffect(angle: flipped ? 180 : 0, front: front, back: back)
        }
    }
}

/// Drehung mit animierbarem Winkel: bis 90 Grad die Vorderseite, danach die (gegengedrehte) Rueckseite
private struct FlashcardFlipEffect<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 { front } else { back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0)) }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
    }
}

/// Hoehe der grossen Lernkarte (Frei ueben und "Heute fällig"): quer wie bisher 340 pt; hochkant waechst sie mit
/// der sichtbaren Seite (die Haelfte der Hoehe, hoechstens 720 pt), damit unter den Knoepfen keine leere Flaeche
/// bleibt. Bedienungshilfen-Schriftgroessen: Kopf, Hinweis und Knoepfe sind hoeher, darum waechst die Karte bei den
/// ersten beiden Stufen nur auf 40 % und ab der dritten (dort endet die Schriftskalierung) gar nicht; die Knoepfe
/// bleiben so ohne Scrollen sichtbar.
enum FlashcardCardLayout {
    static let baseMinHeight: CGFloat = 340
    static let portraitCap: CGFloat = 720

    /// Anteil der sichtbaren Hoehe hochkant (0 = nicht wachsen)
    static func portraitFraction(_ typeSize: DynamicTypeSize) -> CGFloat {
        if typeSize >= .accessibility3 { return 0 }
        return typeSize.isAccessibilitySize ? 0.4 : 0.5
    }

    /// `viewport`: sichtbare Flaeche der Seite (Scrollbereich); `.zero` (noch nicht gemessen) = Grundhoehe
    static func minHeight(viewport: CGSize, typeSize: DynamicTypeSize) -> CGFloat {
        guard viewport.height > viewport.width, viewport.width > 0 else { return baseMinHeight }
        return min(portraitCap, max(baseMinHeight, (viewport.height * portraitFraction(typeSize)).rounded()))
    }
}

/// Eine Seite der grossen Karte: Etikett oben links, Text gross in der Mitte, optional die Frage klein darueber
struct FlashcardFace: View {
    let label: String
    let text: String
    /// Vorderseite: groesser und fett; Rueckseite: ruhiger
    var front = true
    /// Frage klein ueber der Antwort (Rueckseite der Wiederholung)
    var context: String?
    var tint: Color = UF.accentText
    /// Rand (beim Wischen gruen bzw. rot)
    var stroke: Color?
    var minHeight: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(label.uppercased()).ufFont(11.84, 700, em: 0.08).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 16)
            if let context, !context.isEmpty {
                Text(FormulaText.render(context)).ufFont(14.5, 500).foregroundStyle(UF.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            Text(FormulaText.render(text))
                .ufFont(front ? 26 : 20.8, front ? 650 : 450, lh: 1.35, em: front ? -0.01 : 0)
                .foregroundStyle(UF.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 28)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(stroke ?? UF.line, lineWidth: stroke == nil ? 1 : 2.5))
        .ufShadow(.md)
    }
}

/// Grosse Antwort unter der Karte (mindestens 60 pt hoch): Gruen fuer gewusst/richtig, Rot fuer nicht gewusst/falsch,
/// Akzent fuer "Antwort zeigen". Weiche Flaeche, kraeftiger Rand und Schrift: lesbar in hell und dunkel.
struct FlashcardAnswerButton: View {
    let title: String
    let icon: String
    let tone: UFTone
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let (fg, bg, border): (Color, Color, Color) = switch tone {
        case .ok: (UF.okText, UF.okSoft, UF.ok)
        case .bad: (UF.badText, UF.badSoft, UF.bad)
        default: (.white, UF.accentFill, UF.accentFill)
        }
        Button(action: action) {
            HStack(spacing: 10) {
                UFIcon(icon, size: 20)
                Text(title).lineLimit(1).minimumScaleFactor(0.75)
            }
            .ufFont(17.6, 650)
            .foregroundStyle(fg)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(border, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - Lernansicht

struct FlashcardTrainerView: View {
    @ObservedObject var trainer: FlashcardTrainer
    /// Unterzeile im Kopf (Name des Stapels, "Woche 3 komplett")
    var subtitle: String?
    /// Trainer verlassen (die Seite laedt danach neu)
    let onClose: () -> Void
    /// "Bearbeiten" im Menue der Karte: oeffnet den Dialog der Seite; der neue Text kommt ueber `trainer.merge`
    var onEdit: ((JSONValue) -> Void)?
    /// Mindesthoehe der Karte (`FlashcardCardLayout.minHeight`, hochkant hoeher)
    var cardMinHeight: CGFloat = FlashcardCardLayout.baseMinHeight
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// schmal (iPhone): Karte so hoch wie Platz ist, "Nicht gewusst"/"Gewusst" ganz unten in Daumennaehe
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnSheets) private var sheets
    @State private var drag: CGSize = .zero

    private var compact: Bool { UFCompactLearn.isCompact(sizeClass, shell: shellCompact) }

    /// ab dieser Strecke zaehlt ein Wischen als Antwort
    private let swipeThreshold: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.bottom, compact ? 8 : 16)
            if trainer.empty {
                UFCard {
                    UFEmpty(icon: "filter", text: trainer.options.scope == .bookmarked
                            ? "Keine Karte mit Lesezeichen passt zu diesen Optionen."
                            : "Keine Karte passt zu diesen Optionen.") {
                        UFButton("Optionen", icon: "filter", size: .small) { openOptions() }.padding(.top, 8)
                    }
                }
            } else if trainer.finished {
                summary
            } else if let c = trainer.current, compact {
                // schmal: Fortschritt, Karte (fuellt die Hoehe), kleine Zeile, ganz unten die beiden Antworten
                FlashcardProgressHeader(current: trainer.position + 1, total: trainer.cards.count, done: trainer.position) { counters }
                    .padding(.bottom, 12)
                card(c)
                secondaryBar.padding(.top, 10)
                answerButtons.padding(.top, 10)
            } else if let c = trainer.current {
                FlashcardProgressHeader(current: trainer.position + 1, total: trainer.cards.count, done: trainer.position) { counters }
                    .padding(.bottom, 20)
                card(c)
                Text("Tippen oder Leertaste zum Umdrehen · → gewusst · ← nicht gewusst · auch wischen")
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                answerBar.padding(.top, 16)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    // MARK: Kopf: Beenden, Neu starten, Optionen

    private var topBar: some View {
        HStack(spacing: 8) {
            TrainerIconButton(icon: "arrow-left", label: "Üben beenden") { onClose() }
            VStack(alignment: .leading, spacing: 0) {
                Text("Frei üben").ufFont(17.6, 700, em: -0.01).foregroundStyle(UF.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            TrainerIconButton(icon: "refresh", label: "Neu starten") { trainer.restart() }
                .disabled(trainer.busy || trainer.source.isEmpty)
            TrainerIconButton(icon: "filter", label: "Optionen") { openOptions() }
        }
    }

    // MARK: Zaehler: nicht gewusst | gewusst

    private var counters: some View {
        HStack(spacing: 8) {
            CounterPill(label: "Nicht gewusst", value: trainer.unknown, tone: .bad)
            CounterPill(label: "Gewusst", value: trainer.known, tone: .ok)
        }
    }

    // MARK: Karte

    private func card(_ c: JSONValue) -> some View {
        let definition = trainer.showsDefinition
        let text = (definition ? c.s("answer") : c.s("question")) ?? ""
        let side = definition ? "Definition" : "Begriff"
        let bookmarked = (c.i("bookmarked") ?? 0) != 0
        let hidden = (c.i("hidden") ?? 0) != 0
        let lean = drag.width / swipeThreshold                          // -1 ... 1 und weiter
        // Vorderseite = die zuerst gezeigte Seite (Optionen: Begriff oder Definition)
        let firstIsTerm = trainer.options.firstSide == .term
        let frontText = (firstIsTerm ? c.s("question") : c.s("answer")) ?? ""
        let backText = (firstIsTerm ? c.s("answer") : c.s("question")) ?? ""
        return FlashcardFlip(flipped: trainer.flipped) {
            FlashcardFace(label: firstIsTerm ? "Begriff" : "Definition", text: frontText, front: firstIsTerm,
                          tint: UF.accentText, stroke: swipeTint(lean), minHeight: cardMinHeight)
        } back: {
            FlashcardFace(label: firstIsTerm ? "Definition" : "Begriff", text: backText, front: !firstIsTerm,
                          tint: UF.okText, stroke: swipeTint(lean), minHeight: cardMinHeight)
        }
        .id(c.i("id") ?? 0)                                             // neue Karte: neue Ansicht, keine Rueckdrehung
        .overlay(alignment: .top) { swipeBadge(lean) }
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .offset(x: drag.width)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width) / 30))
        .onTapGesture { flip() }
        .simultaneousGesture(swipe)
        // VoiceOver: Karte als Knopf (Doppeltippen dreht), Antworten als Aktionen
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(side): \(text)")
        .accessibilityHint("Doppeltippen dreht die Karte. Aktionen: Gewusst, Nicht gewusst, Erneut fragen.")
        .accessibilityAction { flip() }
        .accessibilityAction(named: "Gewusst") { answer(true) }
        .accessibilityAction(named: "Nicht gewusst") { answer(false) }
        .accessibilityAction(named: "Erneut fragen") { askAgain() }
        .accessibilityAction(named: bookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen") { bookmark() }
        .accessibilityAction(named: hidden ? "Karte wieder zeigen" : "Karte verstecken") { hide() }
        .accessibilityAction(named: "Bearbeiten") { edit() }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if onEdit != nil {
                    TrainerIconButton(icon: "pen", label: "Bearbeiten") { edit() }
                }
                TrainerIconButton(icon: "bookmark", label: bookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen",
                                  on: bookmarked) { bookmark() }
                Button { hide() } label: {
                    Text(hidden ? "Wieder zeigen" : "Verstecken")
                        .ufFont(12.8, 500).foregroundStyle(UF.text2)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "Karte wieder zeigen" : "Karte verstecken")
            }
            .disabled(trainer.busy)
            .padding(6)
            .offset(x: drag.width)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width) / 30))
        }
    }

    private func swipeTint(_ lean: CGFloat) -> Color? {
        if lean > 0.25 { return UF.ok }
        if lean < -0.25 { return UF.bad }
        return nil
    }

    @ViewBuilder private func swipeBadge(_ lean: CGFloat) -> some View {
        if abs(lean) > 0.25 {
            let known = lean > 0
            Text(known ? "Gewusst" : "Nicht gewusst")
                .ufFont(13.12, 650)
                .foregroundStyle(known ? UF.okText : UF.badText)
                .padding(.vertical, 4).padding(.horizontal, 12)
                .background(Capsule().fill(known ? UF.okSoft : UF.badSoft))
                .opacity(min(1, Double(abs(lean))))
                .padding(.top, 12)
                .offset(x: drag.width)
                .accessibilityHidden(true)
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                // nur waagerecht: senkrechtes Ziehen scrollt die Seite
                guard abs(v.translation.width) > abs(v.translation.height), !trainer.busy else { return }
                drag = CGSize(width: v.translation.width, height: 0)
            }
            .onEnded { v in
                let w = v.translation.width
                let horizontal = abs(w) > abs(v.translation.height)
                if horizontal && abs(w) >= swipeThreshold && !trainer.busy {
                    answer(w > 0)
                }
                settle(.zero)
            }
    }

    private func settle(_ to: CGSize) {
        if let a = UFMotion.animation(reduce: reduceMotion, fadeWhenReduced: false) { withAnimation(a) { drag = to } } else { drag = to }
    }

    // MARK: Knoepfe unten: Nicht gewusst | Gewusst, darunter Vorherige | Umdrehen | Erneut fragen

    private var answerButtons: some View {
        HStack(spacing: compact ? 10 : 12) {
            FlashcardAnswerButton(title: "Nicht gewusst", icon: "x", tone: .bad) { answer(false) }
                .disabled(trainer.busy)
                .keyboardShortcut(.leftArrow, modifiers: [])
            FlashcardAnswerButton(title: "Gewusst", icon: "check", tone: .ok) { answer(true) }
                .disabled(trainer.busy)
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    /// schmal: Vorherige, Umdrehen, Erneut fragen als drei gleich breite, flache Knoepfe ueber den Antworten
    private var secondaryBar: some View {
        HStack(spacing: 8) {
            TrainerWideButton(title: "Vorherige", icon: "undo", tone: .neutral, compact: true) { previous() }
                .disabled(!trainer.canGoBack)
            TrainerWideButton(title: "Umdrehen", icon: "rotate", tone: .neutral, compact: true) { flip() }
            TrainerWideButton(title: "Erneut fragen", icon: "refresh", tone: .neutral, compact: true) { askAgain() }
                .disabled(!trainer.canAskAgain)
                .accessibilityIdentifier("trainer.askAgain")
        }
    }

    private var answerBar: some View {
        VStack(spacing: 12) {
            answerButtons
            HStack(spacing: 10) {
                TrainerWideButton(title: "Vorherige", icon: "undo", tone: .neutral) { previous() }
                    .disabled(!trainer.canGoBack)
                    .keyboardShortcut("z", modifiers: .command)
                Spacer(minLength: 0)
                TrainerWideButton(title: "Umdrehen", icon: "rotate", tone: .neutral) { flip() }
                    .keyboardShortcut(.space, modifiers: [])
                Spacer(minLength: 0)
                // Karte ein paar Fragen spaeter noch einmal (Wunsch des Inhabers 03.11.2026), ohne Urteil
                TrainerWideButton(title: "Erneut fragen", icon: "refresh", tone: .neutral) { askAgain() }
                    .disabled(!trainer.canAskAgain)
                    .keyboardShortcut("r", modifiers: [])
                    .accessibilityIdentifier("trainer.askAgain")
            }
        }
    }

    // MARK: Ende des Durchgangs

    private var summary: some View {
        let n = trainer.known + trainer.unknown
        return VStack(spacing: 0) {
            ZStack {
                Circle().fill(UF.okSoft)
                UFIcon("check", size: 30).foregroundStyle(UF.okText)
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            Text("Durchgang geschafft").ufFont(23.2, 700, em: -0.01).foregroundStyle(UF.text).padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text("\(n) \(n == 1 ? "Karte" : "Karten") geübt: \(trainer.known) gewusst, \(trainer.unknown) nicht gewusst.")
                .ufFont(15.2).foregroundStyle(UF.text2).multilineTextAlignment(.center).padding(.top, 6)
            HStack(spacing: 12) {
                summaryStat(trainer.known, "gewusst", tone: .ok)
                summaryStat(trainer.unknown, "nicht gewusst", tone: .bad)
            }
            .padding(.top, 18)
            .accessibilityHidden(true)
            Text("Der Wiederholungsplan („Heute fällig“) bleibt davon unverändert.")
                .ufFont(13.12).foregroundStyle(UF.muted).multilineTextAlignment(.center).padding(.top, 14)
            UFFlexWrap(gap: 9.6, rowGap: 9.6) {
                if trainer.unknown > 0 {
                    UFButton("Nicht gewusste üben (\(trainer.unknown))", icon: "play", kind: .primary) { trainer.practiceUnknown() }
                }
                UFButton("Neu starten", icon: "refresh") { trainer.restart() }
                UFButton("Vorherige", icon: "undo") { previous() }.disabled(!trainer.canGoBack)
                UFButton("Fertig", icon: "check") { onClose() }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.md)
    }

    private func summaryStat(_ value: Int, _ label: String, tone: UFTone) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").ufFont(28.8, 750).monospacedDigit().foregroundStyle(tone.fg)
            Text(label).ufFont(12.8, 500).foregroundStyle(UF.muted)
        }
        .frame(minWidth: 120)
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.bg))
    }

    // MARK: Aktionen

    private func flip() {
        guard trainer.current != nil else { return }
        if let a = UFMotion.animation(reduce: reduceMotion) { withAnimation(a) { trainer.flip() } } else { trainer.flip() }
    }

    private func answer(_ known: Bool) {
        Task { _ = await toast.attempt("Antwort speichern") { try await trainer.answer(known: known) } }
    }

    private func previous() {
        Task { _ = await toast.attempt("Zurücknehmen") { try await trainer.previous() } }
    }

    private func askAgain() {
        guard trainer.canAskAgain else { return }
        if let a = UFMotion.animation(reduce: reduceMotion) { withAnimation(a) { trainer.askAgain() } } else { trainer.askAgain() }
        toast.show("Kommt in \(FlashcardTrainer.askAgainGap) Karten wieder", seconds: 1.5)
    }

    private func bookmark() {
        Task { _ = await toast.attempt("Lesezeichen") { try await trainer.toggleBookmark() } }
    }

    /// "Bearbeiten": Dialog der Seite mit der aktuellen Karte (Frage, Antwort, Modul, Stapel), Lernstand bleibt
    private func edit() {
        guard let c = trainer.current, !trainer.busy else { return }
        onEdit?(c)
    }

    private func hide() {
        let hiding = (trainer.current?.i("hidden") ?? 0) == 0
        Task {
            if await toast.attempt(hiding ? "Verstecken" : "Wieder zeigen", { try await trainer.toggleHidden() }) {
                toast.show(hiding ? "Karte versteckt" : "Karte wird wieder gezeigt")
            }
        }
    }

    private func openOptions() {
        overlay.learnModal(sheets) { FlashcardTrainerOptionsDialog(trainer: trainer) }
    }
}

// MARK: - Optionen

struct FlashcardTrainerOptionsDialog: View {
    @ObservedObject var trainer: FlashcardTrainer
    @Environment(\.ufClose) private var close
    @State private var draft: FlashcardTrainerOptions

    init(trainer: FlashcardTrainer) {
        self.trainer = trainer
        _draft = State(initialValue: trainer.options)
    }

    var body: some View {
        let counts = FlashcardTrainer.counts(trainer.source)
        let bookmarks = trainer.source.filter { ($0.i("bookmarked") ?? 0) != 0 }.count
        let matching = draft.select(trainer.source, shuffle: { $0 }).count
        UFDialog("Optionen", icon: "filter") {
            section("Lernen") {
                TrainerSegments(options: [(.all, "Alle"), (.bookmarked, "Lesezeichen (\(bookmarks))")], selection: $draft.scope)
            }
            section("Nach Fortschritt filtern") {
                UFFlexWrap(gap: 8, rowGap: 8) {
                    ForEach(FlashcardProgress.allCases, id: \.self) { p in
                        TrainerFilterChip(text: "\(p.label) (\(counts[p] ?? 0))", on: draft.progress.contains(p)) {
                            if draft.progress.contains(p) { draft.progress.remove(p) } else { draft.progress.insert(p) }
                        }
                    }
                }
            }
            section("Reihenfolge") {
                TrainerSegments(options: [(.original, "Original"), (.random, "Zufällig")], selection: $draft.order)
            }
            section("Zuerst zeigen") {
                TrainerSegments(options: [(.term, "Begriff"), (.definition, "Definition")], selection: $draft.firstSide)
            }
            Text(matching == 1 ? "1 Karte passt." : "\(matching) Karten passen.")
                .ufFont(13.12).foregroundStyle(matching == 0 ? UF.badText : UF.muted)
                .padding(.top, 14)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Zurücksetzen") { draft = .standard }
                .disabled(draft == .standard)
            UFButton("Filter anwenden", icon: "check", kind: .primary) {
                trainer.apply(draft)
                close()
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .ufFont(11.84, 650, em: 0.06).foregroundStyle(UF.muted)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(title)
            content()
        }
        .padding(.top, 12)
    }
}

// MARK: - Bausteine (44-pt-Ziele)

/// Symbolknopf mit 44 x 44 pt Trefferflaeche
private struct TrainerIconButton: View {
    let icon: String
    let label: String
    var on = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            UFIcon(icon, size: 18)
                .foregroundStyle(on ? UF.accentText : UF.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(on ? UF.accentSoft : Color.clear))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Zaehler oben: rot bzw. gruen umrandet, Zahl gross
private struct CounterPill: View {
    let label: String
    let value: Int
    let tone: UFTone

    var body: some View {
        let fg = tone == .bad ? UF.badText : UF.okText
        HStack(spacing: 6) {
            Text(label).ufFont(12.8, 500)
            Text("\(value)").ufFont(15.2, 700).monospacedDigit()
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(tone == .bad ? UF.badSoft : UF.okSoft).opacity(0.6))
        .overlay(Capsule().strokeBorder(tone == .bad ? UF.bad : UF.ok, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Breiter Knopf unten (mindestens 48 pt hoch)
private struct TrainerWideButton: View {
    let title: String
    let icon: String
    let tone: UFTone
    /// schmal: gleich breit in einer Reihe, 44 pt hoch, kleinere Schrift
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let (fg, bg, border): (Color, Color, Color) = switch tone {
        case .bad: (UF.badText, UF.surface, UF.bad.opacity(0.5))
        case .ok: (.white, UF.okFill, UF.okFill)
        default: (UF.text, UF.surface, UF.lineStrong)
        }
        Button(action: action) {
            HStack(spacing: compact ? 5 : 7.2) {
                UFIcon(icon, size: compact ? 14 : 16)
                Text(title).lineLimit(1).minimumScaleFactor(compact ? 0.7 : 0.8)
            }
            .ufFont(compact ? 13.12 : 14.5, 600)
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 6 : 16)
            .frame(maxWidth: compact ? .infinity : nil, minHeight: compact ? 44 : 48)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: UF.r))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(title)
    }
}

/// Einfachauswahl (Segmente, je 44 pt hoch)
private struct TrainerSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let active = o.value == selection
                Button { selection = o.value } label: {
                    Text(o.label)
                        .ufFont(14.5, active ? 600 : 500)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(active ? .white : UF.text2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(active ? UF.accentFill : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(o.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(UF.surface2))
    }
}

/// Mehrfachauswahl-Chip mit Haken (44 pt hoch)
private struct TrainerFilterChip: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if on { UFIcon("check", size: 14) }
                Text(text)
            }
            .ufFont(13.6, on ? 600 : 500)
            .foregroundStyle(on ? UF.accentText : UF.text2)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(on ? UF.accentSoft : UF.surface))
            .overlay(Capsule().strokeBorder(on ? UF.accent.opacity(0.5) : UF.lineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
