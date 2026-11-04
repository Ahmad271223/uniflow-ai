import SwiftUI
import UniFlowCore

// Bausteine des KI-Bereichs (KI-Start, Wochentest erstellen, Karteikarten aus Dokument, KI-Hilfe im Editor):
// die letzten Antworten auf dem Geraet, die Kostenzeile, Anschlussfragen und die Darstellung von Markdown-Antworten in
// den Schriften des Designsystems. Nichts davon spricht mit einem Dienst; gesendet wird nur ueber die KI-Endpunkte des
// Backends (`/api/ai/*`), und nur nach dem Antippen.

// MARK: - Letzte Antworten (lokal, je Container)

/// Die letzten KI-Antworten fuer "Zuletzt" auf KI-Start und die Zaehlung der Anfragen im Monat. Gespeichert in den
/// Einstellungen des aktiven Containers (Apple-Nutzer, Hochschule), nie in UserDefaults.standard und nie beim Dienst:
/// ein anderes Konto auf demselben iPad sieht sie nicht, "Konto löschen" nimmt sie mit.
@MainActor
final class AIRecents: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        /// Frage bzw. Beschriftung des Schnellknopfs ("Zusammenfassen")
        var question: String
        var answer: String
        var fileID: String?
        var fileName: String?
        /// ISO-Zeitpunkt
        var at: String
    }

    static let shared = AIRecents()
    /// so viele Antworten bleiben
    static let keep = 3
    static let recentKey = "ai-recent"
    static let monthKeyPrefix = "ai-requests:"

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var requestsThisMonth = 0
    private var defaults: UserDefaults
    private var scope: String
    /// ohne eigene Einstellungen (die App): dem aktiven Container folgen; Tests und Vorschauen bleiben bei ihren
    private let followsContainer: Bool

    init(defaults: UserDefaults? = nil, scope: String = "") {
        self.defaults = defaults ?? ActiveContainer.current?.defaults ?? .standard
        self.scope = scope
        followsContainer = defaults == nil
        reload()
    }

    /// Anderer Container (Konto, Hochschule): dessen Antworten lesen
    func attach(defaults: UserDefaults, scope: String) {
        guard defaults !== self.defaults || scope != self.scope else { return }
        self.defaults = defaults
        self.scope = scope
        reload()
    }

    /// Aktiven Container uebernehmen (Ansicht laedt): nur die App-Instanz; Tests und Vorschauen mit eigenen Einstellungen
    /// bleiben bei ihren
    func attachActive(defaults: UserDefaults, scope: String) {
        guard followsContainer else { return }
        attach(defaults: defaults, scope: scope)
    }

    /// Der aktive Container kann seit dem ersten Zugriff gewechselt haben (Konto, Hochschule): vor jedem Schreiben
    /// dessen Einstellungen nehmen (nur die App setzt ihn; Tests und Vorschauen bleiben bei ihren eigenen)
    private func followActiveContainer() {
        guard followsContainer, let c = ActiveContainer.current, c.defaults !== defaults else { return }
        attach(defaults: c.defaults, scope: scope)
    }

    private var key: String { scope.isEmpty ? Self.recentKey : "\(Self.recentKey):\(scope)" }
    private var monthKey: String { Self.monthKeyPrefix + (scope.isEmpty ? "" : "\(scope):") + Self.month(Date()) }

    /// "2026-11" fuer die Zaehlung je Monat (Berlin wie das Backend)
    static func month(_ d: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let p = c.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", p.year ?? 0, p.month ?? 0)
    }

    func reload() {
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        requestsThisMonth = defaults.integer(forKey: monthKey)
    }

    /// Eine Antwort merken (neueste zuerst, hoechstens `keep`) und die Anfrage des Monats zaehlen
    func record(question: String, answer: String, fileID: String? = nil, fileName: String? = nil, now: Date = Date()) {
        followActiveContainer()
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines), a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        let e = Entry(id: UUID().uuidString, question: q.isEmpty ? "Frage" : String(q.prefix(200)), answer: String(a.prefix(4000)),
                      fileID: fileID, fileName: fileName, at: ISO8601DateFormatter().string(from: now))
        entries = Array(([e] + entries).prefix(Self.keep))
        requestsThisMonth += 1
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
        defaults.set(requestsThisMonth, forKey: monthKey)
    }

    /// Nur eine Anfrage zaehlen (Wochentest, Karteikarten: die Antwort ist kein Text fuer "Zuletzt")
    func count() {
        followActiveContainer()
        requestsThisMonth += 1
        defaults.set(requestsThisMonth, forKey: monthKey)
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Kosten und Kontingent

/// Was eine KI-Aktion kostet, ehrlich: ueber das eigene ChatGPT-Abo gibt es keine Credits von StudiNow, nur die Anfrage
/// beim Abo; Credits gibt es erst mit Pro AI ueber den Dienst (in V1 nicht kaufbar). Ein gemeinsamer Wochentest, der
/// uebernommen wurde, kostet nichts.
enum AICost {
    /// Zeile unter einer Aktion: "1 Anfrage über dein ChatGPT", "≈ 10 Credits" (Pro AI) oder "0 Credits (gemeinsamer Test)"
    static func line(chatgpt: Bool, plan: UFPlan, credits: Int, calls: Int = 1, adopted: Bool = false) -> String {
        if adopted { return "0 Credits (gemeinsamer Test)" }
        if chatgpt { return calls == 1 ? "1 Anfrage über dein ChatGPT" : "\(calls) Anfragen über dein ChatGPT" }
        if plan == .proAI { return "≈ \(credits) Credits" }
        return "Braucht dein ChatGPT (Einstellungen → Erweitert)"
    }

    /// Statuszeile auf KI-Start: Anfragen des Monats und der Weg der KI; mit Credits-Stand vom Dienst (`credits`)
    /// steht der echte Rest statt der Schaetzung (`creditsLine`)
    static func status(chatgpt: Bool, model: String?, plan: UFPlan, requestsThisMonth: Int, usage: (used: Int, total: Int)? = nil,
                       credits: StudoraCredits? = nil, charge: StudoraCredits.Charge? = nil, trial: Bool = false) -> String {
        if let usage { return "\(usage.used) von \(usage.total) Credits" }
        let count = requestsThisMonth == 1 ? "1 Anfrage diesen Monat" : "\(requestsThisMonth) Anfragen diesen Monat"
        let m = chatgpt && !(model ?? "").isEmpty ? " · \(model!)" : ""
        if credits != nil, let line = creditsLine(credits: credits, chatgpt: chatgpt, charge: charge, trial: trial) {
            return "\(count) · \(line)\(m)"
        }
        if chatgpt { return "\(count) · über dein ChatGPT\(m)" }
        if plan == .proAI { return "\(count) · StudiNow-KI (Pro AI)" }
        return "Noch kein ChatGPT verbunden · \(count)"
    }

    // MARK: Echter Stand vom Dienst (Credits, docs/ABO-SYSTEM.md Abschnitt 6a)

    /// Die Kostenzeile aus dem echten Stand, in der Reihenfolge der Bezahlung: eine uebernommene gemeinsame Antwort
    /// "Schon erklärt · 0 Credits", das eigene ChatGPT "Dein ChatGPT – 0 Credits", eine berechnete Antwort
    /// "– 3 Credits (37 übrig)", sonst der Stand "Credits: 37 von 100 übrig · neu am 1. Dezember". nil ohne Stand.
    static func creditsLine(credits: StudoraCredits?, chatgpt: Bool, adopted: Bool = false, charge: StudoraCredits.Charge? = nil,
                            trial: Bool = false) -> String? {
        if adopted { return "Schon erklärt · 0 Credits" }
        if chatgpt { return "Dein ChatGPT – 0 Credits" }
        if let charge, let line = chargeLine(charge, remaining: credits?.remaining) { return line }
        return balanceLine(credits, trial: trial)
    }

    /// "Credits: 37 von 100 übrig · neu am 1. Dezember"; in der Probe mit "Probe"; ohne Rahmen im Tarif ehrlich
    /// "Keine Credits in deinem Tarif"; nil ohne Stand. `labelled: false` laesst "Credits: " weg (Einstellungen)
    static func balanceLine(_ c: StudoraCredits?, trial: Bool = false, labelled: Bool = true) -> String? {
        guard let c else { return nil }
        guard c.allowance > 0 else { return "Keine Credits in deinem Tarif" }
        var s = (labelled ? "Credits: " : "") + "\(c.remaining) von \(c.allowance) übrig"
        if trial { s += " · Probe" }
        if let reset = resetLabel(c.resetsAt) { s += " · \(reset)" }
        return s
    }

    /// Eine berechnete Antwort: "– 3 Credits (37 übrig)", "– 1 Credit (37 übrig)"; eine Wiederholung derselben Anfrage
    /// (`replay`) "Schon berechnet · 0 Credits"; nil, wenn nichts berechnet wurde (dann gilt der Stand)
    static func chargeLine(_ charge: StudoraCredits.Charge, remaining: Int?) -> String? {
        if charge.replay { return "Schon berechnet · 0 Credits" }
        guard charge.credits > 0 else { return nil }
        let n = charge.credits == 1 ? "1 Credit" : "\(charge.credits) Credits"
        guard let remaining else { return "– \(n)" }
        return "– \(n) (\(remaining) übrig)"
    }

    /// "neu am 1. Dezember" aus `resets_at` (ISO mit Versatz, Beginn des naechsten Monats in Berlin); nil ohne Datum
    static func resetLabel(_ iso: String?) -> String? {
        guard let iso, let date = isoDate(iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let p = cal.dateComponents([.day, .month], from: date)
        guard let d = p.day, let m = p.month, (1...12).contains(m) else { return nil }
        return "neu am \(d). \(germanMonths[m - 1])"
    }

    static let germanMonths = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober",
                               "November", "Dezember"]

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }
}

// MARK: - Anschlussfragen

/// Zwei bis drei Vorschlaege unter einer Antwort, je nach Modus (lokal, ohne weitere KI-Anfrage): Antippen schickt die
/// Frage als Rueckfrage im selben Gespraech
enum AIFollowUps {
    struct Suggestion: Equatable, Identifiable {
        let label: String
        /// Modus fuer die Rueckfrage (ask = die Frage im Textfeld, sonst ein Schnellknopf)
        let mode: String
        let question: String
        var id: String { mode + "|" + question }
    }

    static func suggest(after mode: String) -> [Suggestion] {
        switch mode {
        case "explain":
            return [Suggestion(label: "Einfacher erklären", mode: "explain_simple", question: ""),
                    Suggestion(label: "Ein Beispiel dazu", mode: "ask", question: "Gib mir ein konkretes Beispiel dazu."),
                    Suggestion(label: "Fachbegriffe", mode: "terms", question: "")]
        case "explain_simple":
            return [Suggestion(label: "Etwas genauer", mode: "explain", question: ""),
                    Suggestion(label: "Ein Beispiel dazu", mode: "ask", question: "Gib mir ein konkretes Beispiel dazu.")]
        case "summary":
            return [Suggestion(label: "Was muss ich können?", mode: "ask", question: "Was muss ich nach dieser Seite können? Nenne 3 Punkte."),
                    Suggestion(label: "Karteikarten daraus", mode: "flashcards", question: ""),
                    Suggestion(label: "Ähnliche Aufgabe", mode: "similar", question: "")]
        case "steps":
            return [Suggestion(label: "Warum dieser Schritt?", mode: "ask", question: "Warum ist der erste Schritt so und nicht anders?"),
                    Suggestion(label: "Ähnliche Aufgabe", mode: "similar", question: ""),
                    Suggestion(label: "Nur Hinweise", mode: "hints", question: "")]
        case "hints":
            return [Suggestion(label: "Nächster Hinweis", mode: "ask", question: "Gib mir einen weiteren, konkreteren Hinweis."),
                    Suggestion(label: "Ganz lösen", mode: "steps", question: "")]
        case "check":
            return [Suggestion(label: "Wie behebe ich den Fehler?", mode: "ask", question: "Wie behebe ich den Fehler Schritt für Schritt?"),
                    Suggestion(label: "Musterlösung", mode: "steps", question: "")]
        case "similar":
            return [Suggestion(label: "Noch eine", mode: "similar", question: ""),
                    Suggestion(label: "Lösung erklären", mode: "ask", question: "Erkläre die Lösung der Übungsaufgabe Schritt für Schritt.")]
        case "terms":
            return [Suggestion(label: "Karteikarten daraus", mode: "flashcards", question: ""),
                    Suggestion(label: "Zusammenhang", mode: "ask", question: "Wie hängen diese Begriffe zusammen?")]
        case "flashcards":
            return []
        default:
            return [Suggestion(label: "Einfacher erklären", mode: "explain_simple", question: ""),
                    Suggestion(label: "Ein Beispiel dazu", mode: "ask", question: "Gib mir ein konkretes Beispiel dazu."),
                    Suggestion(label: "Zusammenfassen", mode: "summary", question: "")]
        }
    }
}

// MARK: - Markdown-Antworten

/// Absaetze einer Markdown-Antwort der KI (Ueberschriften, Aufzaehlungen, nummerierte Listen, Codebloecke, Absaetze);
/// Fett, Kursiv und Code innerhalb einer Zeile uebernimmt `AttributedString(markdown:)`
enum AIMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullets([String])
        case numbered([String])
        case code(String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if trimmed.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(line); code = c }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if let h = heading(trimmed) { flush(); out.append(.heading(level: h.level, text: h.text)); continue }
            if let b = bullet(trimmed) {
                if !paragraph.isEmpty || !numbered.isEmpty { flush() }
                bullets.append(b)
                continue
            }
            if let n = number(trimmed) {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                numbered.append(n)
                continue
            }
            // Fortsetzungszeile einer Aufzaehlung (eingerueckt) haengt am letzten Punkt
            if line.hasPrefix("  "), !bullets.isEmpty { bullets[bullets.count - 1] += " " + trimmed; continue }
            if line.hasPrefix("  "), !numbered.isEmpty { numbered[numbered.count - 1] += " " + trimmed; continue }
            if !bullets.isEmpty || !numbered.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    private static func heading(_ s: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(s)
        while rest.first == "#", level < 6 { level += 1; rest = rest.dropFirst() }
        guard level > 0, rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func bullet(_ s: String) -> String? {
        for mark in ["- ", "* ", "• "] where s.hasPrefix(mark) {
            let t = s.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func number(_ s: String) -> String? {
        var digits = ""
        var rest = Substring(s)
        while let c = rest.first, c.isNumber, digits.count < 3 { digits.append(c); rest = rest.dropFirst() }
        guard !digits.isEmpty, rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let t = rest.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Zeile mit Fett/Kursiv/Code; unlesbares Markdown bleibt der Text
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Markdown-Antwort in den Schriften des Designsystems: Ueberschriften als h3/h4, Aufzaehlungen mit Punkt, nummerierte
/// Listen mit Zahl, Codebloecke in Festbreite auf --surface-2, Absaetze als Lesetext. Alles auswaehlbar.
struct AIMarkdownText: View {
    let text: String
    var size: CGFloat = 13.76

    init(_ text: String, size: CGFloat = 13.76) {
        self.text = text
        self.size = size
    }

    var body: some View {
        let blocks = AIMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.indices, id: \.self) { i in block(blocks[i]) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: AIMarkdown.Block) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(AIMarkdown.inline(t)).ufFont(level <= 2 ? size + 1.5 : size + 0.5, 650, em: -0.01).foregroundStyle(UF.text)
                .padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            Text(AIMarkdown.inline(t)).ufFont(size).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(UF.accent).frame(width: 5, height: 5).offset(y: -2).accessibilityHidden(true)
                        Text(AIMarkdown.inline(items[i])).ufFont(size).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").ufFont(size, 650).foregroundStyle(UF.accentText).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                        Text(AIMarkdown.inline(items[i])).ufFont(size).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let c):
            Text(c).font(.system(size: max(11, size - 1.5), design: .monospaced)).foregroundStyle(UF.text)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Bunte Aktions-Pillen (KI-Start)

/// Eine der Aktionen auf KI-Start (Feinschliff 04.11.2026): umrandete Pille in ihrer Farbe aus der Palette der
/// Community – Symbol und Titel in der Farbe der Paarung, Rand `solid`, Flaeche weiss bzw. `bg` bei `strong`.
/// `compact` (Reihe ueber dem Frage-Feld): nur Symbol und Titel, der Titel bricht bei grosser Schrift um, nichts
/// wird gekuerzt; die Unterzeile bleibt fuer VoiceOver. Sonst (schmal, sehr grosse Schrift): volle Breite mit
/// Unterzeile. Mindestens 44 pt hoch, gibt beim Druecken leicht nach (UFPressStyle).
struct AIActionPill: View {
    let title: String
    let sub: String
    let icon: String
    let pair: CommunityPair
    var strong = false
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    HStack(spacing: 8) {
                        UFIcon(icon, size: 16).foregroundStyle(pair.fg)
                        Text(title).ufFont(14.5, 650, lh: 1.3).foregroundStyle(UF.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .frame(minHeight: 44)
                } else {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(strong ? pair.solid : pair.bg)
                            UFIcon(icon, size: 18).foregroundStyle(strong ? .white : pair.fg)
                        }
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).ufFont(14.5, 650, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                            Text(sub).ufFont(12.8, lh: 1.3).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            }
            .background(RoundedRectangle(cornerRadius: compact ? 22 : UF.rLg).fill(strong ? pair.bg : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: compact ? 22 : UF.rLg).strokeBorder(pair.solid, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 22 : UF.rLg))
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel("\(title). \(sub)")
    }
}

/// Auswahl-Chip mit Haekchen (Zahl der Aufgaben, Dauer, Seiten): wie UFChip, aber als Teil einer Gruppe mit Zustand
struct AIChoiceChip: View {
    let text: String
    let on: Bool
    var icon: String?
    let action: () -> Void

    var body: some View {
        UFChip(text: text, on: on, icon: icon, action: action)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}
