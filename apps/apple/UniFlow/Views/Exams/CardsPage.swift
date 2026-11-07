import SwiftUI
import UniFlowCore

// Eigene Karteikarten nach viewCards() in app/static/views-misc.js, fuer das iPad ohne PC erweitert, seit 04.11.2026
// mit geschlossenen Stapeln (docs/KARTEIKARTEN-STAPEL-2026-11-04.md): jede Karte gehoert zu genau einem Stapel (Name,
// Modul, optional Quelldokument). Die Seite zeigt zuerst die Stapel je Modul (Name, Modul, Zahl der Karten, "Heute
// faellig (n)", zuletzt geuebt); in einem gewaehlten Stapel laufen "Heute faellig", Wiederholen und "Frei ueben" nur
// mit seinen Karten, nie gemischt. Karten lassen sich anlegen (mit Stapelwahl), bearbeiten (Frage, Antwort, Modul,
// Stapel; der Lernstand bleibt) und loeschen; Stapel umbenennen, verschieben und loeschen (Karten mit oder Umzug).
// Daten ueber /api/flashcards* und /api/flashcard-stacks (lokal FlashcardEndpoints in der Datenbank des Containers).
// Tarif (Entscheidung 04.11.2026, docs/TARIF-MATRIX-2026-11-04.md): lokal sind Ueben, Anlegen, Bearbeiten, Teilen,
// Uebernehmen und "Karten fuer Woche n holen" Plus. Free (auch nach der Probe) sieht die eigenen Stapel und Karten
// weiter, nur lesend (UFFlashcardAccess, wie Notizen): oben der Hinweis "Mit Plus übst und bearbeitest du deine Karten
// wieder." mit dem Weg zur Tarifwahl, Wochenstapel und "Übernehmen" mit Schloss (ufRequires), ohne eigene Karten die
// Sperrkarte UFLockedCard(.flashcards). Mit Dienst prueft der Dienst (403 "Karteikarten gibt es ab StudiNow Plus.").
// Geteilte Wochenstapel und "Stapel teilen" (Entscheidung des Inhabers vom 04.11.2026, CardStackEndpoints im Kern,
// CardStackCloudKit.swift): "Karten fuer Woche n holen" bringt je Modul und Woche die Stapel "Vorlesung Woche n" und
// "Übung Woche n" (einmal erzeugt, von allen uebernommen, 0 Credits), "Woche n komplett" uebt beide nacheinander
// (bewusste Wahl, kein Mischen); eigene Stapel lassen sich je Stapel in die Modul-Community teilen, geteilte Stapel
// anderer stehen je Modul mit Pseudonym, "Übernehmen" (eigene Kopie, Lernstand getrennt), Like und Melden.
// Neugestaltung 04.11.2026 (Vorbild-Vergleich): die Stapel stehen als Kacheln (quer 2-3, hochkant 1-2 Spalten) mit
// farbiger Kante nach Art (Vorlesung gruen, Uebung blau, Eigene violett, von anderen bernstein), "heute fällig" gross,
// den Leitner-Faechern als kleinem Balken und einem grossen Knopf "Üben" (faellige Karten zuerst, sonst frei ueben);
// Bearbeiten, Teilen und Loeschen im Menue (…). Wiederholung und Trainer zeigen eine grosse Karte (FlashcardTrainer.swift).

/// Stand der Karteikarten-Seite: alle Karten, die Stapel, der gewaehlte Stapel, die laufende Wiederholung, Anlegen,
/// Bearbeiten und Loeschen. Gehoert zu genau einer Datenquelle: wechselt sie (anderes Konto, andere Hochschule,
/// eigener Server), beginnt alles von vorn, und Antworten der alten Quelle werden verworfen (Pruefpunkt 270). Eine
/// Karte wird in einer Wiederholung hoechstens einmal bewertet, auch bei schnellen Doppeltipps (Pruefpunkt 269).
@MainActor
final class FlashcardDeck: ObservableObject {
    /// Stapel eines Moduls in der Stapelliste (Modul mit dem Namen des Fachs, sonst das Fach, sonst "Ohne Modul")
    struct Group: Identifiable {
        let id: String
        let title: String
        let color: String?
        let stacks: [JSONValue]
    }

    /// Kennung fuer "Neuer Stapel …" in den Auswahlfeldern
    static let newStack = -1
    /// Arten eines Stapels (Ergaenzung 04.11.2026): KI-Karten aus einem Dokument bekommen die Art seiner Einordnung
    static let kinds: [(value: String, label: String)] = [("eigene", "Eigene"), ("vorlesung", "Vorlesung"), ("uebung", "Übung")]
    /// Wochenfilter der Stapelliste: 0 = "Allgemein" (ohne Lehrwoche), sonst die Woche; nil = alle
    static let generalWeek = 0

    static func kindLabel(_ kind: String?) -> String { kinds.first { $0.value == kind }?.label ?? "Eigene" }

    /// Etikett eines Stapels: Art und Lehrwoche ("Übung · W3", "Vorlesung", "Eigene · Allgemein")
    static func badge(_ s: JSONValue) -> String {
        var out = kindLabel(s.s("kind")) + " · " + (s.i("week").map { "W\($0)" } ?? "Allgemein")
        if s.s("source") == "week" { out += " · gemeinsam" } else if s.s("source") == "community" { out += " · übernommen" }
        if let shared = s.s("shared_id"), !shared.isEmpty { out += " · geteilt" }
        return out
    }

    /// Arten der geteilten Wochenstapel in der Reihenfolge von "Woche n komplett": erst Vorlesung, dann Uebung
    static let weekKinds = ["vorlesung", "uebung"]
    /// Meldegruende wie bei Loesungen (`CommunityReportReason`)
    static let reportReasons: [(value: String, label: String)] = CommunityReportReason.allCases.map { ($0.rawValue, $0.title) }

    /// Datenquelle, zu der der Stand gehoert
    private(set) var api: APIClient?
    @Published private(set) var all: [JSONValue] = []
    /// heute faellig ueber alle Stapel (Zaehler); geuebt wird nur je Stapel (`due`)
    @Published private(set) var dueAll: [JSONValue] = []
    @Published private(set) var stacks: [JSONValue] = []
    /// gewaehlter Stapel (nil = Stapelliste)
    @Published private(set) var selected: Int?
    /// Module und Dokumente der Bibliothek (Zuordnung der Stapel, Auswahl beim Anlegen)
    @Published private(set) var modules: [JSONValue] = []
    @Published private(set) var files: [JSONValue] = []
    @Published private(set) var loaded = false
    /// erstes Laden gescheitert (ohne Stand)
    @Published private(set) var failed: String?
    /// Geteilte Stapel der Modul-Community je Modul-Kennung (`loadShared`); leer ohne Dienst
    @Published private(set) var shared: [Int: [JSONValue]] = [:]
    /// false, sobald der Dienst "nicht verfuegbar" meldet (kein iCloud-Container): Teilen-Knoepfe bleiben weg
    @Published private(set) var sharingAvailable = true
    /// Module, fuer die gerade "Karten fuer Woche n holen" laeuft
    @Published private(set) var fetchingWeek: Set<Int> = []
    // Wiederholung: die bei Beginn faelligen Karten des Stapels in fester Reihenfolge
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
    /// Kontingent "Karteikarten-Stapel von StudiNow" ohne Dienst (Plus 4 je Monat, 05.11.2026); Tests geben eigene
    /// UserDefaults
    var adoptQuota = UFAdoptQuota()
    /// Tarif fuer Community und Kontingent ohne Dienst; die Seite setzt ihre eigenen Berechtigungen
    var entitlements: Entitlements = .shared

    init(api: APIClient? = nil) { self.api = api }

    /// Andere Datenquelle: alles von vorn, laufende Antworten verfallen
    func attach(_ new: APIClient?) {
        guard new !== api else { return }
        api = new
        generation += 1
        all = []
        dueAll = []
        stacks = []
        selected = nil
        modules = []
        files = []
        loaded = false
        failed = nil
        shared = [:]
        sharingAvailable = true
        fetchingWeek = []
        endSession()
    }

    func load() async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        async let a = api.value("/api/flashcards")
        async let d = api.value("/api/flashcards?due=true")
        async let s = api.value("/api/flashcard-stacks")
        async let l = api.value("/api/library")
        let (av, dv, sv, lv) = try await (a, d, s, l)
        guard mine == generation else { return }
        all = av.items
        dueAll = dv.items
        stacks = sv.items
        modules = lv.list("modules")
        files = lv.list("files")
        if let selected, !stacks.contains(where: { $0.i("id") == selected }) { select(nil) }   // Stapel inzwischen weg
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

    // MARK: Stapel

    /// der gewaehlte Stapel
    var stack: JSONValue? { stacks.first { $0.i("id") == selected } }
    /// Karten des gewaehlten Stapels (neueste zuerst wie die Antwort)
    var cards: [JSONValue] { all.filter { $0.i("stack_id") == selected } }
    /// heute faellig im gewaehlten Stapel: nur dieser Stapel wird abgefragt
    var due: [JSONValue] { selected == nil ? [] : dueAll.filter { $0.i("stack_id") == selected } }

    /// Stapel waehlen (nil = zurueck zur Liste); eine laufende Wiederholung endet
    func select(_ id: Int?) {
        guard id != selected else { return }
        endSession()
        selected = id
    }

    func stackName(_ id: Int?) -> String? { stacks.first { $0.i("id") == id }?.s("name") }

    /// Name des Stapels einer Karte (aus der Liste, sonst aus der Antwort)
    func stackTitle(_ card: JSONValue) -> String { stackName(card.i("stack_id")) ?? card.s("stack_name") ?? "Stapel" }

    /// Modul eines Fachs (Name = Fach), sonst nil
    func module(named subject: String?) -> JSONValue? {
        guard let subject, !subject.isEmpty else { return nil }
        return modules.first { $0.s("name") == subject }
    }

    /// Fach eines Moduls (0 = keins)
    func subject(ofModule id: Int) -> String? { id == 0 ? nil : modules.first { $0.i("id") == id }?.s("name") }

    /// Stapel eines Fachs (nil = ohne Modul), zuletzt geuebte zuerst, dann die neuesten
    func stacks(subject: String?) -> [JSONValue] {
        stacks.filter { ($0.s("subject") ?? "") == (subject ?? "") }
            .sorted { ($0.s("last_practised") ?? "", $0.i("id") ?? 0) > ($1.s("last_practised") ?? "", $1.i("id") ?? 0) }
    }

    /// Vorgabe beim Anlegen: der zuletzt benutzte Stapel des Moduls (zuletzt geuebt, sonst der neueste), sonst nil
    func lastUsedStack(subject: String?) -> JSONValue? { stacks(subject: subject).first }

    /// Lehrwochen, die in Stapeln vorkommen (Filterzeile "Alle · Allgemein · W1 … Wn"); nur, wenn es Wochen gibt
    var weeks: [Int] { Array(Set(stacks.compactMap { $0.i("week") })).sorted() }

    /// Stapel nach Woche (nil = alle, `generalWeek` = ohne Lehrwoche)
    func stacks(week: Int?) -> [JSONValue] {
        guard let week else { return stacks }
        return stacks.filter { week == Self.generalWeek ? $0.i("week") == nil : $0.i("week") == week }
    }

    /// Stapelliste je Modul in der Reihenfolge der Module, danach Faecher ohne Modul, zuletzt "Ohne Modul"
    var stackGroups: [Group] { stackGroups(week: nil) }

    func stackGroups(week: Int?) -> [Group] {
        var buckets: [String: [JSONValue]] = [:]
        for s in stacks(week: week) { buckets[s.s("subject") ?? "", default: []].append(s) }
        var out: [Group] = []
        for m in modules {
            guard let name = m.s("name"), let list = buckets.removeValue(forKey: name) else { continue }
            out.append(Group(id: "m\(m.i("id") ?? 0)", title: name, color: m.s("color"), stacks: list))
        }
        for k in buckets.keys.filter({ !$0.isEmpty }).sorted() {
            out.append(Group(id: "s" + k, title: k, color: nil, stacks: buckets[k] ?? []))
        }
        if let rest = buckets[""] { out.append(Group(id: "none", title: "Ohne Modul", color: nil, stacks: rest)) }
        return out
    }

    // MARK: Geteilte Wochenstapel und Stapel teilen (04.11.2026)

    /// uebernommener Wochenstapel eines Fachs (source = week) fuer Woche und Art
    func weekStack(subject: String?, week: Int, kind: String) -> JSONValue? {
        stacks.first { $0.s("source") == "week" && ($0.s("subject") ?? "") == (subject ?? "") && $0.i("week") == week && $0.s("kind") == kind }
    }

    /// beide Wochenstapel da: "Woche n komplett" laesst sich ueben
    func hasCompleteWeek(subject: String?, week: Int) -> Bool {
        Self.weekKinds.allSatisfy { weekStack(subject: subject, week: week, kind: $0) != nil }
    }

    /// Karten fuer "Woche n komplett": erst der Vorlesungsstapel, dann der Uebungsstapel, je in der Reihenfolge des
    /// Anlegens (bewusste Wahl des Nutzers, kein automatisches Mischen)
    func weekCompleteCards(subject: String?, week: Int) -> [JSONValue] {
        Self.weekKinds.flatMap { kind -> [JSONValue] in
            guard let id = weekStack(subject: subject, week: week, kind: kind)?.i("id") else { return [] }
            return all.filter { $0.i("stack_id") == id }.sorted { ($0.i("id") ?? 0) < ($1.i("id") ?? 0) }
        }
    }

    /// Ergebnis je Art beim Holen
    struct WeekFetch: Equatable {
        let kind: String
        /// exists | adopted | generated | unshared | no_materials
        let status: String
        let cards: Int
        let message: String
    }

    /// Text einer Zeile des Ergebnisses ("Vorlesung: übernommen · 20 Karten · 0 Credits")
    static func fetchLabel(kind: String, status: String, cards: Int, variant: Int?) -> String {
        let name = kind == "vorlesung" ? "Vorlesung" : "Übung"
        let n = "\(cards) \(cards == 1 ? "Karte" : "Karten")"
        switch status {
        case "exists": return "\(name): Stapel ist schon da"
        case "adopted": return "\(name): übernommen · \(n) · 0 Credits" + (variant.map { " · Variante \($0) von 3" } ?? "")
        case "generated": return "\(name): neu erzeugt und geteilt · \(n)"
        case "unshared": return "\(name): eigener Stapel · \(n)"
        case "no_materials": return "\(name): keine Unterlagen in dieser Woche"
        default: return "\(name): \(status)"
        }
    }

    /// "Karten fuer Woche n holen": Vorlesung und Uebung nacheinander (vorhandener oder gemeinsamer Stapel = 0 Credits,
    /// sonst erzeugt die KI einmal fuer alle). Ohne Unterlagen einer Art steht das im Ergebnis, andere Fehler brechen ab.
    func fetchWeek(moduleID: Int, week: Int) async throws -> [WeekFetch] {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        fetchingWeek.insert(moduleID)
        defer { if mine == generation { fetchingWeek.remove(moduleID) } }
        var out: [WeekFetch] = []
        // Kontingent `card_stacks_adopted` (Plus 4 je Monat) ohne Dienst: aufgebraucht = diese Art wird nicht geholt;
        // gezaehlt wird nur ein aus dem Pool uebernommener Stapel (nicht der mit dem eigenen ChatGPT erzeugte)
        let quota = api.isLocal ? adoptQuota : nil, plan = entitlements.plan
        for kind in Self.weekKinds {
            let qid = "week:\(moduleID):\(week):\(kind)"
            if let quota, !quota.allows(qid, plan: plan) {
                let name = kind == "vorlesung" ? "Vorlesung" : "Übung"
                out.append(WeekFetch(kind: kind, status: "quota_exhausted", cards: 0,
                                     message: "\(name): " + UFAdoptQuota.exhaustedMessage(limit: UFAdoptQuota.limit(plan) ?? 0)))
                continue
            }
            do {
                let r = try await api.value("/api/flashcard-stacks/week/\(moduleID)/\(week)/\(kind)", method: "POST", body: .object([:]))
                let status = r.s("status") ?? "", cards = r["stack"]?.i("cards") ?? 0
                if status == "adopted" { quota?.record(qid) }
                out.append(WeekFetch(kind: kind, status: status, cards: cards, message: Self.fetchLabel(kind: kind, status: status, cards: cards, variant: r.i("variant"))))
            } catch let e as APIError where e.code == "no_materials" {
                out.append(WeekFetch(kind: kind, status: "no_materials", cards: 0, message: Self.fetchLabel(kind: kind, status: "no_materials", cards: 0, variant: nil)))
            }
            guard mine == generation else { return out }
        }
        try await load()
        return out
    }

    /// Geteilte Stapel aller Module nachladen (Beiwerk: ein Fehler laesst die Liste des Moduls leer; "nicht verfuegbar"
    /// blendet das Teilen aus)
    func loadShared() async {
        guard let api else { return }
        // Community ab Plus (05.11.2026): ohne Dienst liest Free keine geteilten Stapel aus CloudKit; mit Dienst sperrt
        // der Dienst selbst (403, die Liste bleibt leer)
        if api.isLocal && !entitlements.allows(.communityRead) {
            shared = [:]
            return
        }
        let mine = generation
        var out: [Int: [JSONValue]] = [:]
        var available = true
        for m in modules {
            guard let id = m.i("id") else { continue }
            do {
                out[id] = try await api.value("/api/community/card-stacks?module_id=\(id)").list("stacks")
            } catch let e as APIError where e.code == "not_available" {
                available = false
                break
            } catch {
                out[id] = []
            }
        }
        guard mine == generation else { return }
        shared = out
        sharingAvailable = available
    }

    /// Geteilte Stapel eines Moduls nach Woche (nil = alle, `generalWeek` = Allgemein), meistgelikte zuerst wie die Antwort
    func shared(module id: Int, week: Int?) -> [JSONValue] {
        let list = shared[id] ?? []
        guard let week else { return list }
        return list.filter { week == Self.generalWeek ? $0.i("week") == nil : $0.i("week") == week }
    }

    /// "Stapel teilen": Kopie der Karten in die Modul-Community; danach traegt der Stapel `shared_id`
    @discardableResult
    func share(_ stack: JSONValue) async throws -> JSONValue {
        guard let api, let id = stack.i("id") else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        let r = try await api.value("/api/flashcard-stacks/\(id)/share", method: "POST", body: .object([:]))
        guard mine == generation else { return r }
        try await load()
        await loadShared()
        return r
    }

    /// Teilen zurueckziehen (nur der eigene Stapel); wer ihn schon uebernommen hat, behaelt seine Kopie
    func unshare(_ stack: JSONValue) async throws {
        guard let api, let id = stack.i("id") else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        _ = try await api.value("/api/flashcard-stacks/\(id)/share", method: "DELETE")
        guard mine == generation else { return }
        try await load()
        await loadShared()
    }

    /// "Übernehmen": eigener Stapel mit Kopie der Karten (Fach 1, Lernstand getrennt); schon uebernommen = der vorhandene
    @discardableResult
    func adopt(_ sharedStack: JSONValue) async throws -> (stack: JSONValue, already: Bool) {
        guard let api, let id = sharedStack.s("id") else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        // Kontingent `card_stacks_adopted` (Plus 4 je Monat): ohne Dienst zaehlt das Geraet, mit Dienst der Dienst
        let quota = api.isLocal ? adoptQuota : nil, plan = entitlements.plan, qid = "community:\(id)"
        if let quota, !quota.allows(qid, plan: plan) { throw quota.error(plan: plan) }
        let mine = generation
        let r = try await api.value("/api/community/card-stacks/\(id)/adopt", method: "POST", body: .object([:]))
        if r["already"]?.bool != true { quota?.record(qid) }
        guard mine == generation else { return (r["stack"] ?? .null, r["already"]?.bool ?? false) }
        try await load()
        await loadShared()
        return (r["stack"] ?? .null, r["already"]?.bool ?? false)
    }

    /// Gefaellt mir setzen oder entfernen (nicht beim eigenen)
    func like(_ sharedStack: JSONValue) async throws {
        guard let api, let id = sharedStack.s("id") else { return }
        let mine = generation
        let on = !(sharedStack["liked_by_me"]?.bool ?? false)
        _ = try await api.value("/api/community/card-stacks/\(id)/like", method: on ? "POST" : "DELETE")
        guard mine == generation else { return }
        await loadShared()
    }

    func report(_ sharedStack: JSONValue, reason: String, note: String) async throws {
        guard let api, let id = sharedStack.s("id") else { return }
        let mine = generation
        _ = try await api.value("/api/community/card-stacks/\(id)/report", method: "POST", body: ["reason": .string(reason), "note": .string(note)])
        guard mine == generation else { return }
        await loadShared()
    }

    /// Unterzeile eines geteilten Stapels: Pseudonym, Karten, Likes
    static func sharedLine(_ s: JSONValue) -> String {
        let n = s.i("cards") ?? 0, likes = s.i("likes") ?? 0
        var parts = ["von \(s.s("pseudonym") ?? "Anonym")", "\(n) \(n == 1 ? "Karte" : "Karten")", "\(likes) \(likes == 1 ? "Like" : "Likes")"]
        if s["mine"]?.bool == true { parts.append("dein Stapel") }
        if s["adopted"]?.bool == true { parts.append("übernommen") }
        return parts.joined(separator: " · ")
    }

    /// Neuer Stapel (Name Pflicht, Fach des Moduls, optional Quelldokument, Lehrwoche und Art; ohne Angabe kommen Art
    /// und Woche aus dem Dokument); liefert seine Kennung und laedt neu
    @discardableResult
    func createStack(name: String, subject: String?, fileID: String? = nil, week: Int?? = nil, kind: String? = nil) async throws -> Int {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw APIError(status: -1, message: "", text: "Der Stapel braucht einen Namen.") }
        let mine = generation
        var body: [String: JSONValue] = ["name": .string(n), "subject": subject.map(JSONValue.string) ?? .null]
        if let fileID, !fileID.isEmpty { body["file_id"] = .string(fileID) }
        if let week { body["week"] = week.map { .number(Double($0)) } ?? .null }
        if let kind { body["kind"] = .string(kind) }
        let r = try await api.value("/api/flashcard-stacks", method: "POST", body: .object(body))
        guard let id = r.i("id") else { throw APIError(status: -1, message: "", text: "Der Stapel wurde nicht gespeichert.") }
        guard mine == generation else { return id }
        try await load()
        return id
    }

    /// Umbenennen, in ein anderes Modul verschieben (die Karten folgen), Lehrwoche und Art aendern
    func updateStack(_ id: Int, name: String, subject: String?, week: Int?? = nil, kind: String? = nil) async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw APIError(status: -1, message: "", text: "Der Stapel braucht einen Namen.") }
        let mine = generation
        var body: [String: JSONValue] = ["name": .string(n), "subject": subject.map(JSONValue.string) ?? .null]
        if let week { body["week"] = week.map { .number(Double($0)) } ?? .null }
        if let kind { body["kind"] = .string(kind) }
        _ = try await api.value("/api/flashcard-stacks/\(id)", method: "PATCH", body: .object(body))
        guard mine == generation else { return }
        try await load()
    }

    /// Stapel loeschen: ohne `moveTo` samt Karten, sonst wandern die Karten mit Lernstand in den anderen Stapel
    func deleteStack(_ id: Int, moveTo: Int? = nil) async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let mine = generation
        _ = try await api.value("/api/flashcard-stacks/\(id)" + (moveTo.map { "?move_to=\($0)" } ?? ""), method: "DELETE")
        guard mine == generation else { return }
        if selected == id { select(moveTo) }
        try await load()
    }

    // MARK: Wiederholung

    var current: JSONValue? { inSession && position < queue.count ? queue[position] : nil }
    var finished: Bool { inSession && position >= queue.count }

    /// Wiederholung der heute faelligen Karten des gewaehlten Stapels (nie gemischt)
    func startReview() {
        let list = due
        guard !list.isEmpty else { return }
        queue = list
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

    // MARK: Anlegen, Bearbeiten und Loeschen

    /// Eine Karte anlegen; Frage und Antwort ohne Leerraum aussen, beide Pflicht. Stapel: `stackID` (vorhanden) oder
    /// `newStackName` (neuer Stapel mit `subject`, Dokument als Quelle), sonst der Stapel des Dokuments bzw.
    /// "Allgemein"/"Ohne Modul" (wie `add_flashcards`). Danach ist der Stapel der Karte gewaehlt.
    func create(question: String, answer: String, fileID: String?, stackID: Int? = nil, newStackName: String? = nil,
                subject: String? = nil) async throws {
        guard let api else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines), a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { throw APIError(status: -1, message: "", text: "Frage und Antwort sind nötig.") }
        let mine = generation
        var sid = stackID
        if sid == nil, let newStackName {
            sid = try await createStack(name: newStackName, subject: subject, fileID: fileID)
            guard mine == generation else { return }
        }
        var body: [String: JSONValue] = ["cards": [["question": .string(q), "answer": .string(a)]]]
        if let fileID, !fileID.isEmpty { body["file_id"] = .string(fileID) }
        if let sid { body["stack_id"] = .number(Double(sid)) }
        let r = try await api.value("/api/flashcards", method: "POST", body: .object(body))
        guard r.i("count") == 1 else { throw APIError(status: -1, message: "", text: "Die Karte wurde nicht gespeichert.") }
        guard mine == generation else { return }
        try await load()
        if let id = r.i("stack_id") ?? sid { select(id) }
    }

    /// Karte nachtraeglich aendern (PATCH): Frage, Antwort, Fach und Stapel; Fach und Termin der Wiederholung bleiben.
    /// Eine laufende Wiederholung zeigt den neuen Text, die Karte bleibt an ihrer Stelle.
    @discardableResult
    func update(_ card: JSONValue, question: String, answer: String, subject: String?, stackID: Int) async throws -> JSONValue {
        guard let api, let id = card.i("id") else { throw APIError(status: -1, message: "", text: "Keine Datenquelle.") }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines), a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { throw APIError(status: -1, message: "", text: "Frage und Antwort sind nötig.") }
        let mine = generation
        let saved = try await api.value("/api/flashcards/\(id)", method: "PATCH",
                                        body: ["question": .string(q), "answer": .string(a), "subject": subject.map(JSONValue.string) ?? .null,
                                               "stack_id": .number(Double(stackID))])
        guard mine == generation else { return saved }
        queue = queue.map { c in
            guard c.i("id") == id else { return c }
            var c = c
            for k in ["question", "answer", "subject", "stack_id"] { c[k] = saved[k] ?? c[k] }
            return c
        }
        try await load()
        return saved
    }

    /// Lesezeichen bzw. "versteckt" einer Karte setzen (PATCH, Leitner bleibt unberuehrt), danach neu laden
    func setFlag(_ card: JSONValue, _ key: String, _ on: Bool) async throws {
        guard let api, let id = card.i("id"), key == "bookmarked" || key == "hidden" else { return }
        let mine = generation
        _ = try await api.value("/api/flashcards/\(id)", method: "PATCH", body: .object([key: .bool(on)]))
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

    var dueIDs: Set<Int> { Set(dueAll.compactMap { $0.i("id") }) }

    /// Naechster Termin im gewaehlten Stapel, wenn heute nichts faellig ist (alle Termine liegen dann in der Zukunft).
    /// Versteckte Karten zaehlen nicht: sie sind nie faellig (der Server laesst sie bei ?due=true weg).
    var nextDue: String? {
        cards.filter { ($0.i("hidden") ?? 0) == 0 }.compactMap { $0.s("due") }.filter { !$0.isEmpty }.min()
    }

    /// Titel des Dokuments einer Karte (Bibliothek), sonst der Dateiname aus der Antwort
    func fileTitle(_ card: JSONValue) -> String? {
        guard let id = card.s("file_id"), !id.isEmpty else { return nil }
        return files.first { $0.s("id") == id }.flatMap { $0.s("title") ?? $0.s("name") } ?? card.s("file_name")
    }

    /// Dokumente zur Auswahl beim Anlegen (alle oder die eines Moduls)
    func documents(module: Int) -> [JSONValue] {
        files.filter { module == 0 || $0.i("module_id") == module }
    }

    /// Unterzeile eines Stapels in der Liste: Modul, Karten, heute faellig, zuletzt geuebt
    static func stackLine(_ s: JSONValue) -> String {
        let n = s.i("cards") ?? 0
        var parts = [s.s("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "Ohne Modul", "\(n) \(n == 1 ? "Karte" : "Karten")",
                     "Heute fällig (\(s.i("due") ?? 0))"]
        if let p = s.s("last_practised"), !p.isEmpty { parts.append("zuletzt geübt am \(UFFmt.date(String(p.prefix(10))))") } else { parts.append("noch nicht geübt") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Kacheln: Art, Leitner-Faecher, Faelligkeit (Neugestaltung 04.11.2026)

/// Art eines Stapels fuer Farbe und Symbol der Kachel: Vorlesung gruen, Uebung blau, Eigene violett, von anderen
/// uebernommen (Community) bernsteinfarben. Die Farben sind Paare aus `CommunityPalette` (hell und dunkel lesbar).
enum FlashcardStackKind: String, CaseIterable {
    case lecture, exercise, own, community

    static func of(_ stack: JSONValue) -> FlashcardStackKind {
        if stack.s("source") == "community" { return .community }
        switch stack.s("kind") {
        case "vorlesung": return .lecture
        case "uebung": return .exercise
        default: return .own
        }
    }

    var label: String {
        switch self {
        case .lecture: return "Vorlesung"
        case .exercise: return "Übung"
        case .own: return "Eigene"
        case .community: return "Von anderen"
        }
    }

    var icon: String {
        switch self {
        case .lecture: return "book"
        case .exercise: return "pen"
        case .own: return "cards"
        case .community: return "users"
        }
    }

    var pair: CommunityPair {
        switch self {
        case .lecture: return CommunityPalette.mint
        case .exercise: return CommunityPalette.sky
        case .own: return CommunityPalette.lavender
        case .community: return CommunityPalette.butter
        }
    }
}

extension FlashcardDeck {
    /// Zahl der Leitner-Faecher (1 = neu oder falsch, 5 = sitzt)
    static let boxCount = 5

    /// Karten je Fach 1...5 (Fach ausserhalb wird auf 1 bzw. 5 begrenzt, fehlendes Fach = 1)
    static func boxCounts(_ cards: [JSONValue]) -> [Int] {
        var out = Array(repeating: 0, count: boxCount)
        for c in cards { out[min(boxCount, max(1, c.i("box") ?? 1)) - 1] += 1 }
        return out
    }

    /// Faecher eines Stapels aus den geladenen Karten
    func boxCounts(stack id: Int?) -> [Int] { Self.boxCounts(all.filter { $0.i("stack_id") == id }) }

    /// VoiceOver und Test: "Fach 1: 3 · Fach 2: 0 · …"
    static func boxSummary(_ counts: [Int]) -> String {
        counts.enumerated().map { "Fach \($0.offset + 1): \($0.element)" }.joined(separator: " · ")
    }

    /// heute faellig in einem Stapel (Feld der Stapelliste)
    static func dueCount(_ stack: JSONValue) -> Int { stack.i("due") ?? 0 }

    /// Chip der Lehrwoche: "Woche 3" bzw. "Allgemein"
    static func weekChip(_ stack: JSONValue) -> String { stack.i("week").map { "Woche \($0)" } ?? "Allgemein" }

    /// "Üben" auf der Kachel: mit faelligen Karten zuerst die Wiederholung (Leitner), sonst frei ueben
    static func practiceStartsReview(_ stack: JSONValue) -> Bool { dueCount(stack) > 0 }

    /// Zeile unter "Üben"
    static func practiceHint(_ stack: JSONValue) -> String {
        let due = dueCount(stack), n = stack.i("cards") ?? 0
        if n == 0 { return "Noch keine Karte im Stapel" }
        if due > 0 { return "Zuerst \(due == 1 ? "die fällige Karte" : "die \(due) fälligen Karten")" }
        return "Frei üben, der Plan bleibt"
    }
}

/// Eine Kachel je Stapel: farbige Kante und Symbol nach Art, Name, Modul, Woche, "heute fällig" gross, Karten,
/// die Leitner-Faecher als kleiner Balken und ein grosser Knopf "Üben"; Bearbeiten, Teilen und Loeschen im Menue (…).
struct FlashcardStackTile: View {
    let stack: JSONValue
    let boxes: [Int]
    let canEdit: Bool
    let entitlements: Entitlements
    let menuOpen: Bool
    let open: () -> Void
    let practise: () -> Void
    let toggleMenu: () -> Void

    var body: some View {
        let kind = FlashcardStackKind.of(stack)
        let pair = kind.pair
        let name = stack.s("name") ?? ""
        let due = FlashcardDeck.dueCount(stack)
        let n = stack.i("cards") ?? 0
        let badge = FlashcardDeck.badge(stack)
        let line = FlashcardDeck.stackLine(stack)
        VStack(alignment: .leading, spacing: 0) {
            // oberer Teil: oeffnet den Stapel (Karten lesen, Wiederholen, Frei ueben)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(pair.bg)
                            UFIcon(kind.icon, size: 20).foregroundStyle(pair.fg)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).ufFont(15.2, 650, lh: 1.3, em: -0.01).foregroundStyle(UF.text)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(stack.s("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "Ohne Modul")
                                .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    UFFlexWrap(gap: 6, rowGap: 6) {
                        chip(kind.label, fg: pair.fg, bg: pair.bg)
                        chip(FlashcardDeck.weekChip(stack), fg: UF.text2, bg: UF.surface2)
                        if stack.s("source") == "week" { chip("gemeinsam", fg: UF.text2, bg: UF.surface2) }
                        if !(stack.s("shared_id") ?? "").isEmpty { chip("geteilt", fg: UF.accentText, bg: UF.accentSoft) }
                    }
                    .padding(.top, 12)
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(due)").ufFont(32, 750, lh: 1.1, em: -0.02).monospacedDigit()
                            .foregroundStyle(due > 0 ? UF.accentText : UF.muted)
                        Text("heute fällig").ufFont(13.6, 600).foregroundStyle(due > 0 ? UF.text : UF.muted)
                        Spacer(minLength: 4)
                        Text("\(n) \(n == 1 ? "Karte" : "Karten")").ufFont(13.12, 500).foregroundStyle(UF.text2)
                    }
                    .padding(.top, 14)
                    FlashcardBoxBar(counts: boxes, tint: pair.solid).padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stapel öffnen: \(name)")
            .accessibilityValue(badge + " · " + line + " · " + FlashcardDeck.boxSummary(boxes))
            Spacer(minLength: 14)
            // unten: der eine starke Knopf und das Menue
            HStack(spacing: 8) {
                practiseButton(name: name, cards: n)
                if canEdit {
                    Button(action: toggleMenu) {
                        UFIcon("more", size: 18)
                            .foregroundStyle(menuOpen ? UF.accentText : UF.text2)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(menuOpen ? UF.accentSoft : UF.surface2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .anchorPreference(key: FlashcardMenuAnchor.self, value: .bounds) { menuOpen ? $0 : nil }
                    .accessibilityLabel("Aktionen für Stapel: \(name)")
                    .accessibilityHint("Bearbeiten, teilen oder löschen")
                    .accessibilityAddTraits(menuOpen ? .isSelected : [])
                }
            }
            Text(FlashcardDeck.practiceHint(stack)).ufFont(12.16).foregroundStyle(UF.muted).lineLimit(1)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .padding(.top, 18 + 4).padding(.bottom, 16).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UF.surface))
        .overlay(alignment: .top) { Rectangle().fill(pair.solid).frame(height: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func practiseButton(name: String, cards: Int) -> some View {
        let button = Button(action: practise) {
            HStack(spacing: 8) {
                UFIcon("play", size: 16)
                Text("Üben")
            }
            .ufFont(15.2, 650)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.accentFill))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(cards == 0 ? 0.5 : 1)
        }
        .buttonStyle(UFPressStyle())
        .disabled(cards == 0)
        .accessibilityLabel("Üben: \(name)")
        .accessibilityHint(FlashcardDeck.practiceHint(stack))
        // Lesemodus (Free): sichtbar mit Schloss, Tippen oeffnet die Tarifwahl
        if canEdit { button } else { button.ufRequires(.flashcards, entitlements: entitlements) }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).ufFont(11.52, 650).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(bg))
    }
}

/// Leitner-Faecher als kleine Saeulen 1...5 mit Zahl darunter; die Hoehe zeigt den Anteil am groessten Fach
struct FlashcardBoxBar: View {
    let counts: [Int]
    var tint: Color = UF.accent

    var body: some View {
        let top = max(1, counts.max() ?? 0)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Lernstand").ufFont(11.2, 650).foregroundStyle(UF.muted)
                Spacer(minLength: 4)
                Text("Fach 1 → 5").ufFont(11.2).foregroundStyle(UF.muted)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3).fill(UF.surface2)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(tint.opacity(0.45 + 0.55 * Double(i) / Double(max(1, counts.count - 1))))
                                .frame(height: n == 0 ? 0 : max(3, 22 * CGFloat(n) / CGFloat(top)))
                        }
                        .frame(height: 22)
                        Text("\(n)").ufFont(10.88, 600).monospacedDigit().foregroundStyle(n == 0 ? UF.muted : UF.text2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leitner-Fächer")
        .accessibilityValue(FlashcardDeck.boxSummary(counts))
    }
}

/// Ort des geoeffneten Menues (…) einer Kachel; die Seite legt das Menue darueber
struct FlashcardMenuAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Wochenfilter als Segmentzeile, die bei vielen Wochen waagerecht scrollt ("Alle · Allgemein · W1 … Wn")
struct FlashcardWeekFilter: View {
    let weeks: [Int]
    @Binding var selection: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                segment(nil, "Alle", spoken: "Alle Wochen")
                segment(FlashcardDeck.generalWeek, "Allgemein", spoken: "Allgemein, ohne Lehrwoche")
                ForEach(weeks, id: \.self) { w in segment(w, "W\(w)", spoken: "Woche \(w)") }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.surface2))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lehrwoche")
    }

    private func segment(_ value: Int?, _ label: String, spoken: String) -> some View {
        let on = selection == value
        return Button { selection = value } label: {
            // Breite immer die der fetten Schrift: beim Umschalten verrutscht nichts (Geraetetest 07.11.2026)
            ZStack {
                Text(label).ufFont(14.08, 650).fixedSize().hidden()
                Text(label).ufFont(14.08, on ? 650 : 500).fixedSize()
            }
                .foregroundStyle(on ? UF.text : UF.text2)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? UF.surface : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? UF.line : .clear, lineWidth: 1))
                .contentShape(Rectangle())
                .ufHitArea(slop: EdgeInsets(top: .infinity, leading: 1, bottom: .infinity, trailing: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Seite

struct CardsPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var deck = FlashcardDeck()
    @StateObject private var trainer = FlashcardTrainer()
    @ObservedObject private var ent: Entitlements
    /// Wochenfilter der Stapelliste (nil = alle)
    @State private var weekFilter: Int?
    /// Stapel, dessen Menue (…) offen ist
    @State private var menuStack: JSONValue?
    /// Unterzeile des Trainers (Stapel bzw. "Woche n komplett")
    @State private var trainerTitle: String?
    /// sichtbare Flaeche der Seite: hochkant waechst die Lernkarte mit (`FlashcardCardLayout`)
    @State private var viewport: CGSize = .zero

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(entitlements: Entitlements? = nil) {
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
    }

    /// Ohne PC (lokales Backend) gilt der Tarif der App; am Dienst bzw. eigenen Server entscheidet der Server
    private var needsPlus: Bool { session.api?.isLocal != false }
    /// Ueben, Anlegen, Bearbeiten, Teilen, Uebernehmen; sonst Lesemodus (Free, nach der Probe)
    private var canEdit: Bool { !needsPlus || ent.flashcards.canEdit }
    /// noch keine Karte und kein Stapel
    private var isEmpty: Bool { deck.all.isEmpty && deck.stacks.isEmpty && !deck.inSession }
    /// gerade wird geuebt (Trainer oder Wiederholung): der Kopf wird ruhig
    private var practising: Bool { (trainer.active && canEdit) || deck.inSession }

    /// Knopf, der Plus braucht: im Lesemodus sichtbar mit Schloss, Tippen oeffnet die Tarifwahl
    @ViewBuilder private func plusOnly<V: View>(_ v: V) -> some View {
        if canEdit { v } else { v.ufRequires(.flashcards, entitlements: ent) }
    }

    var body: some View {
        UFContent(maxWidth: 1120) {
            UFPageHead("Karteikarten", sub: practising ? nil : "Deine Stapel je Modul · Leitner-System: richtig = seltener, falsch = morgen wieder.") {
                if !needsPlus { UFButton("Tests", icon: "exam", size: .small) { router.go(.exams) } }      // Pfeil nur oben links
                if deck.loaded {
                    if deck.selected != nil && !(trainer.active && canEdit) {
                        UFButton("Alle Stapel", icon: "layers", size: .small) { deck.select(nil) }
                    }
                    if canEdit && !practising && !isEmpty && deck.selected == nil {
                        UFButton("Neuer Stapel", icon: "layers", size: .small) { openStack(nil) }
                    }
                    if canEdit && !practising && !isEmpty {
                        UFButton("Karte anlegen", icon: "plus", kind: .primary, size: .small) { openCreate() }
                    }
                }
            }
            cards
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
    }

    private var cardMinHeight: CGFloat { FlashcardCardLayout.minHeight(viewport: viewport, typeSize: typeSize) }

    /// Inhalt unter dem Kopf; laedt in jedem Tarif (Lesen bleibt frei), im Lesemodus ohne Ueben und Bearbeiten
    private var cards: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !canEdit && deck.loaded && deck.failed == nil && !(deck.all.isEmpty && deck.stacks.isEmpty) {
                FlashcardReadOnlyHint().padding(.bottom, 16)
            }
            if let failed = deck.failed {
                UFCard {
                    UFEmpty(icon: "alert", text: failed) {
                        UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await deck.reload(toast: toast) } }
                    }
                }
            } else if !deck.loaded {
                UFGridLayout(spacing: 14, minWidth: 260) {
                    ForEach(0..<3, id: \.self) { _ in UFSkeleton().frame(height: 260) }
                }
            } else if trainer.active && canEdit {
                FlashcardTrainerView(trainer: trainer, subtitle: trainerTitle, onClose: {
                    trainer.end()
                    Task { await deck.reload(toast: toast) }
                }, onEdit: { c in openEdit(c) }, cardMinHeight: cardMinHeight)
            } else if isEmpty && !canEdit {
                UFLockedCard(.flashcards, entitlements: ent)
            } else if isEmpty {
                emptyState
            } else if deck.selected == nil {
                stackList
            } else if !canEdit {
                stackHead.padding(.bottom, 16)
                list                                                   // Lesemodus: Karten des Stapels ohne Ueben
            } else if deck.inSession {
                reviewCard
            } else {
                stackHead.padding(.bottom, 16)
                stackPanels
                list.padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.api.map(ObjectIdentifier.init)) {
            deck.entitlements = ent
            deck.attach(session.api)
            trainer.attach(session.api)
            if await deck.reload(toast: toast) { await deck.loadShared() }
        }
        .ufReload { if await deck.reload(toast: toast) { await deck.loadShared() } }
        .onChange(of: deck.selected) { _, _ in menuStack = nil }
    }

    // MARK: Leerer Zustand: eine klare Aktion

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CommunityPalette.lavender.bg)
                    .frame(width: 64, height: 76).rotationEffect(.degrees(-8)).offset(x: -10)
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UF.surface)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
                    .overlay(UFIcon("cards", size: 28).foregroundStyle(CommunityPalette.lavender.fg))
                    .frame(width: 64, height: 76).rotationEffect(.degrees(6)).offset(x: 8)
                    .ufShadow(.sm)
            }
            .frame(height: 96)
            .accessibilityHidden(true)
            Text("Noch keine Karteikarten").ufFont(21.6, 700, em: -0.01).foregroundStyle(UF.text).padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text("Lege deine erste Karte an: vorn die Frage, hinten die Antwort. Richtig beantwortete Karten kommen seltener wieder, falsche am nächsten Tag.")
                .ufFont(15.2).foregroundStyle(UF.text2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .padding(.top, 6)
            Button { openCreate() } label: {
                HStack(spacing: 8) { UFIcon("plus", size: 16); Text("Erste Karte anlegen") }
                    .ufFont(15.2, 650).foregroundStyle(.white)
                    .padding(.horizontal, 22).frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.accentFill))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(UFPressStyle())
            .accessibilityLabel("Erste Karte anlegen")
            .padding(.top, 20)
            if !deck.modules.isEmpty {
                UFButton("Karten für eine Woche holen …", icon: "download", kind: .ghost, size: .small) { openWeekFetch(moduleID: nil, week: nil) }
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40).padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }

    // MARK: Stapel je Modul als Kacheln

    /// Spalten: so viele 260-pt-Kacheln wie passen (quer 2-3, hochkant 1-2); grosse Schrift eine Spalte
    private var tileGrid: UFGridLayout {
        typeSize.isAccessibilitySize ? UFGridLayout(columns: 1, spacing: 14) : UFGridLayout(spacing: 14, minWidth: 250)
    }

    private var stackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewBar.padding(.bottom, 14)
            // Filterzeile "Alle · Allgemein · W1 … Wn" nur mit Lehrwochen, die vorkommen
            // "Alle · Allgemein" immer (das Teilen-Fenster nennt "Allgemein"), auch waehrend des Ladens: sonst tauchte die
            // Zeile erst nach ein paar Sekunden auf und verschwand beim Neuladen kurz (Geraetetest 07.11.2026)
            FlashcardWeekFilter(weeks: deck.weeks, selection: $weekFilter).padding(.bottom, 18)
            let groups = deck.stackGroups(week: weekFilter)
            if groups.isEmpty && !deck.stacks.isEmpty {
                UFCard {
                    UFEmpty(icon: "filter", text: "Kein Stapel in dieser Woche.", small: true) {
                        UFButton("Alle Wochen zeigen", size: .small) { weekFilter = nil }.padding(.top, 4)
                    }
                }
            }
            ForEach(groups) { g in
                group(g, first: g.id == groups.first?.id)
            }
        }
        .overlayPreferenceValue(FlashcardMenuAnchor.self) { anchor in
            GeometryReader { geo in
                if let anchor, let s = menuStack {
                    let r = geo[anchor]
                    ZStack(alignment: .topLeading) {
                        // Tippen daneben schliesst das Menue
                        Color.clear.contentShape(Rectangle()).onTapGesture { menuStack = nil }
                            .accessibilityHidden(true)
                        stackMenu(s)
                            .alignmentGuide(.top) { d in d[.bottom] - (r.minY - 8) }
                            .alignmentGuide(.leading) { d in d[.trailing] - r.maxX }
                    }
                }
            }
        }
    }

    /// Kopfleiste der Liste: heute faellig gesamt (gross), Stapel und Karten, "Karten fuer eine Woche holen"
    private var overviewBar: some View {
        let n = deck.dueAll.count
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { overviewStats(n); Spacer(minLength: 8); overviewActions }
            VStack(alignment: .leading, spacing: 12) { overviewStats(n); overviewActions }
        }
        .padding(.vertical, 14).padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }

    private func overviewStats(_ due: Int) -> some View {
        HStack(alignment: .center, spacing: 18) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(due)").ufFont(28.8, 750, lh: 1.1, em: -0.02).monospacedDigit().foregroundStyle(due > 0 ? UF.accentText : UF.muted)
                Text("heute fällig").ufFont(14.5, 600).foregroundStyle(UF.text)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(due) heute fällig")
            Rectangle().fill(UF.line).frame(width: 1, height: 28).accessibilityHidden(true)
            Text("\(deck.stacks.count) \(deck.stacks.count == 1 ? "Stapel" : "Stapel") · \(deck.all.count) \(deck.all.count == 1 ? "Karte" : "Karten")")
                .ufFont(13.6).foregroundStyle(UF.text2).fixedSize()
        }
    }

    @ViewBuilder private var overviewActions: some View {
        if !deck.modules.isEmpty {
            plusOnly(UFButton("Karten für eine Woche holen …", icon: "download", size: .small) { openWeekFetch(moduleID: nil, week: nil) })
        }
    }

    /// Ein Modul: Kopf (Farbe, Name, Zahl, Wochenaktionen), Kacheln, darunter geteilte Stapel der Community
    @ViewBuilder private func group(_ g: FlashcardDeck.Group, first: Bool) -> some View {
        let moduleID = g.id.hasPrefix("m") ? Int(g.id.dropFirst()) : nil
        HStack(spacing: 8) {
            UFDot(color: g.color.map { Color(hex: $0) } ?? UF.lineStrong)
            Text(g.title).ufFont(16, 700, em: -0.01).foregroundStyle(UF.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text("\(g.stacks.count)").ufFont(12.8, 600).foregroundStyle(UF.muted)
                .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(UF.surface2))
            Spacer(minLength: 0)
            // bei gewaehlter Lehrwoche: die gemeinsamen Stapel holen bzw. "Woche n komplett" ueben (Vorlesung, dann Uebung)
            if let moduleID, let w = weekFilter, w != FlashcardDeck.generalWeek {
                if deck.hasCompleteWeek(subject: g.title, week: w) && !canEdit {
                    EmptyView()                                // ueben ab Plus
                } else if deck.hasCompleteWeek(subject: g.title, week: w) {
                    UFButton("Woche \(w) komplett", icon: "play", kind: .primary, size: .small) {
                        trainerTitle = "\(g.title) · Woche \(w) komplett"
                        trainer.start(with: deck.weekCompleteCards(subject: g.title, week: w))
                    }
                    .accessibilityLabel("Woche \(w) komplett üben: \(g.title)")
                } else {
                    plusOnly(UFButton("Karten für Woche \(w) holen", icon: "download", size: .small) { openWeekFetch(moduleID: moduleID, week: w) }
                        .disabled(deck.fetchingWeek.contains(moduleID))
                        .accessibilityLabel("Karten für Woche \(w) holen: \(g.title)"))
                }
            }
        }
        .padding(.top, first ? 0 : 22)
        .padding(.bottom, 10)
        tileGrid {
            ForEach(Array(Row.rows(g.stacks).enumerated()), id: \.element.id) { i, row in
                let s = row.value
                FlashcardStackTile(stack: s, boxes: deck.boxCounts(stack: s.i("id")), canEdit: canEdit, entitlements: ent,
                                   menuOpen: menuStack?.i("id") != nil && menuStack?.i("id") == s.i("id"),
                                   open: { menuStack = nil; deck.select(s.i("id")) },
                                   practise: { practise(s) },
                                   toggleMenu: { menuStack = menuStack?.i("id") == s.i("id") ? nil : s })
                    .ufAppear("cards.tiles", index: i)
            }
        }
        .environment(\.ufFillsCell, true)
        // Geteilte Stapel anderer im Modul (Filter nach Woche): uebernehmen, liken, melden
        if let moduleID {
            // auch die eigenen geteilten Stapel (Geraetetest 06.11.2026: "habe einen Stapel geteilt, sehe ihn nicht"),
            // markiert mit "Von dir", ohne Uebernehmen/Melden
            let sharedRows = Row.rows(deck.shared(module: moduleID, week: weekFilter))
            if !sharedRows.isEmpty {
                sharedList(sharedRows).padding(.top, 12)
            }
        }
    }

    /// Menue (…) einer Kachel: Bearbeiten, Teilen bzw. Teilen zurueckziehen, Loeschen
    private func stackMenu(_ s: JSONValue) -> some View {
        let name = s.s("name") ?? ""
        let shared = !(s.s("shared_id") ?? "").isEmpty
        let canShare = deck.sharingAvailable && !(s.s("subject") ?? "").isEmpty && (s.i("cards") ?? 0) > 0
        return VStack(alignment: .leading, spacing: 0) {
            menuRow("Bearbeiten", icon: "pen", label: "Stapel bearbeiten: \(name)") { openStack(s) }
            if canShare {
                menuRow(shared ? "Teilen zurückziehen" : "In der Community teilen", icon: "users",
                        label: shared ? "Teilen zurückziehen: \(name)" : "Stapel teilen: \(name)") { shared ? confirmUnshare(s) : openShare(s) }
            }
            Rectangle().fill(UF.line).frame(height: 1).padding(.vertical, 4).accessibilityHidden(true)
            menuRow("Löschen", icon: "trash", label: "Stapel löschen: \(name)", danger: true) { confirmDeleteStack(s) }
        }
        .padding(6)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UF.lineStrong, lineWidth: 1))
        .ufShadow(.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aktionen für \(name)")
    }

    private func menuRow(_ title: String, icon: String, label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            menuStack = nil
            action()
        } label: {
            HStack(spacing: 10) {
                UFIcon(icon, size: 16)
                Text(title).ufFont(14.5, 500)
                Spacer(minLength: 0)
            }
            .foregroundStyle(danger ? UF.badText : UF.text)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func sharedList(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CommunityPalette.butter.bg)
                    UFIcon("users", size: 14).foregroundStyle(CommunityPalette.butter.fg)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                Text("Geteilte Stapel aus der Community").ufFont(13.6, 650).foregroundStyle(UF.text2)
            }
            .padding(.bottom, 4)
            ForEach(rows) { row in
                let sh = row.value
                let name = sh.s("name") ?? ""
                let adopted = sh["adopted"]?.bool ?? false
                let liked = sh["liked_by_me"]?.bool ?? false
                let mine = sh["mine"]?.bool ?? false
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(name).ufFont(14.5, 550).foregroundStyle(UF.text).lineLimit(1)
                            Text(FlashcardDeck.badge(sh)).ufFont(11.5, 600).foregroundStyle(UF.text2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(UF.surface2))
                            if mine {
                                Text("Von dir").ufFont(11.5, 600).foregroundStyle(UF.accentText)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(UF.accentSoft))
                                    .accessibilityIdentifier("cards.shared.mine")
                            }
                        }
                        Text(FlashcardDeck.sharedLine(sh)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    if !mine { HStack(spacing: 2) {
                        plusOnly(UFButton(adopted ? "Übernommen" : "Übernehmen", icon: "download", kind: adopted ? .ghost : .primary, size: .small) { adopt(sh) }
                            .disabled(adopted)
                            .accessibilityLabel(adopted ? "Schon übernommen: \(name)" : "Übernehmen: \(name)"))
                        UFButton(icon: "star", kind: .ghost, size: .small) { like(sh) }
                            .ufHitSlop(leading: 1, trailing: 1)
                            .foregroundStyle(liked ? UF.accentText : UF.text2)
                            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(liked ? UF.accentSoft : .clear))
                            .accessibilityLabel(liked ? "Like entfernen: \(name)" : "Like: \(name)")
                            .accessibilityAddTraits(liked ? .isSelected : [])
                        UFButton(icon: "flag", kind: .ghost, size: .small) { openReport(sh) }
                            .ufHitSlop(leading: 1)
                            .disabled(sh["reported_by_me"]?.bool == true)
                            .accessibilityLabel("Melden: \(name)")
                    } }
                }
                .padding(.vertical, 8)
                .ufBorderBottom(row.id != rows.last?.id)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }

    /// "Üben" auf der Kachel: Stapel waehlen, dann die faelligen Karten (Leitner) oder frei ueben
    private func practise(_ s: JSONValue) {
        guard let id = s.i("id"), canEdit else { return }
        menuStack = nil
        deck.select(id)
        if FlashcardDeck.practiceStartsReview(s), !deck.due.isEmpty {
            deck.startReview()
        } else {
            trainerTitle = s.s("name")
            trainer.start(with: deck.cards)
        }
    }

    // MARK: Gewaehlter Stapel: Kopf, Heute faellig, Frei ueben

    @ViewBuilder private var stackHead: some View {
        if let s = deck.stack {
            let kind = FlashcardStackKind.of(s)
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(kind.pair.bg)
                    UFIcon(kind.icon, size: 24).foregroundStyle(kind.pair.fg)
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.s("name") ?? "").ufFont(19.2, 700, em: -0.01).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(FlashcardDeck.badge(s) + " · " + (s.s("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "Ohne Modul"))
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(kind.pair.solid).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
        }
    }

    /// "Heute fällig" und "Frei üben" nebeneinander (schmal untereinander)
    private var stackPanels: some View {
        let grid = windowWidth < 760 || typeSize.isAccessibilitySize ? UFGridLayout(columns: 1, spacing: 16) : UFGridLayout(columns: 2, spacing: 16)
        return grid {
            reviewCard
            practiceCard
        }
        .environment(\.ufFillsCell, true)
    }

    // MARK: Heute faellig (im gewaehlten Stapel)

    @ViewBuilder private var reviewCard: some View {
        let stackName = deck.stack?.s("name") ?? "Stapel"
        if deck.finished {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(UF.okSoft)
                    UFIcon("check", size: 30).foregroundStyle(UF.okText)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
                Text("Wiederholung geschafft").ufFont(23.2, 700, em: -0.01).foregroundStyle(UF.text).padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                let n = deck.right + deck.wrong                              // bewertete Karten (geloeschte zaehlen mit)
                Text("\(n) \(n == 1 ? "Karte" : "Karten") aus „\(stackName)“ wiederholt: \(deck.right) richtig, \(deck.wrong) falsch.")
                    .ufFont(15.2).foregroundStyle(UF.text2).multilineTextAlignment(.center).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                UFButton("Fertig", icon: "check", kind: .primary) {
                    deck.endSession()
                    Task { await deck.reload(toast: toast) }
                }
                .padding(.top, 18)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32).padding(.horizontal, 24)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
            .ufShadow(.md)
        } else if let c = deck.current {
            reviewStage(c, stackName: stackName)
        } else {
            UFCard {
                UFCardHead("Heute fällig (\(deck.due.count))", icon: "cards")
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(deck.due.count)").ufFont(36, 750, lh: 1.1, em: -0.02).monospacedDigit()
                        .foregroundStyle(deck.due.isEmpty ? UF.muted : UF.accentText)
                    Text(deck.due.count == 1 ? "Karte wartet" : "Karten warten").ufFont(14.5, 600).foregroundStyle(UF.text2)
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 6)
                if deck.due.isEmpty {
                    Text(deck.nextDue.map { "In diesem Stapel ist heute nichts fällig. Die nächste Wiederholung ist am \(UFFmt.date($0))." }
                         ?? "In diesem Stapel ist heute nichts fällig.")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Erst die Frage lesen, dann aufdecken und selbst bewerten. Nur dieser Stapel wird abgefragt.")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    UFButton("Wiederholen", icon: "play", kind: .primary) { deck.startReview() }
                        .padding(.top, 12.8)
                }
            }
        }
    }

    /// Wiederholung "Heute fällig": Fortschritt oben, die grosse Karte (Tippen deckt auf und dreht sie), darunter
    /// "Antwort zeigen" bzw. die grossen Knoepfe "Falsch" und "Richtig" (Leitner: richtig = naechstes Fach)
    private func reviewStage(_ c: JSONValue, stackName: String) -> some View {
        let q = c.s("question") ?? "", a = c.s("answer") ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Heute fällig (\(deck.queue.count))").ufFont(17.6, 700, em: -0.01).foregroundStyle(UF.text)
                    Text(stackName).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                UFButton("Bearbeiten", icon: "pen", size: .small) { openEdit(c) }.disabled(deck.rating)
                UFButton("Beenden", size: .small) {
                    deck.endSession()
                    Task { await deck.reload(toast: toast) }
                }
            }
            .padding(.bottom, 16)
            FlashcardProgressHeader(current: deck.position + 1, total: deck.queue.count, done: deck.position,
                                    detail: "Fach \(c.i("box") ?? 1) · Nur dieser Stapel wird abgefragt")
                .padding(.bottom, 20)
            Button { reveal() } label: {
                FlashcardFlip(flipped: deck.revealed) {
                    FlashcardFace(label: "Frage", text: q, minHeight: cardMinHeight)
                } back: {
                    FlashcardFace(label: "Antwort", text: a, front: false, context: q, tint: UF.okText, minHeight: cardMinHeight)
                }
                .id(c.i("id") ?? 0)
                .contentShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deck.revealed ? "Antwort: \(a)" : "Frage: \(q)")
            .accessibilityHint(deck.revealed ? "" : "Doppeltippen deckt die Antwort auf.")
            Text(deck.revealed ? "Wie war's? → richtig · ← falsch" : "Tippen oder Leertaste deckt die Antwort auf")
                .ufFont(12.8).foregroundStyle(UF.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                if deck.revealed {
                    FlashcardAnswerButton(title: "Falsch", icon: "x", tone: .bad) { rate(false) }
                        .disabled(deck.rating)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    FlashcardAnswerButton(title: "Richtig", icon: "check", tone: .ok) { rate(true) }
                        .disabled(deck.rating)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                } else {
                    FlashcardAnswerButton(title: "Antwort zeigen", icon: "rotate", tone: .accent) { reveal() }
                        .keyboardShortcut(.space, modifiers: [])
                }
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func reveal() {
        if let a = UFMotion.animation(reduce: UIAccessibility.isReduceMotionEnabled) { withAnimation(a) { deck.reveal() } } else { deck.reveal() }
    }

    // MARK: Frei ueben (Trainer, nur dieser Stapel)

    private var practiceCard: some View {
        UFCard {
            UFCardHead("Frei üben", icon: "layers")
            let stackCards = deck.cards
            let counts = FlashcardTrainer.counts(stackCards)
            let bookmarks = stackCards.filter { ($0.i("bookmarked") ?? 0) != 0 }.count
            Text("Die Karten dieses Stapels im eigenen Tempo: umdrehen, nach rechts wischen für gewusst, nach links für nicht gewusst. Ändert den Wiederholungsplan nicht.")
                .ufFont(14.5).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
            FlashcardBoxBar(counts: FlashcardDeck.boxCounts(stackCards), tint: FlashcardStackKind.of(deck.stack ?? .null).pair.solid)
                .padding(.top, 12)
            Text("\(counts[.right] ?? 0) richtig · \(counts[.wrong] ?? 0) falsch · \(counts[.unlearned] ?? 0) noch nicht gelernt"
                 + (bookmarks > 0 ? " · \(bookmarks) mit Lesezeichen" : "") + ((counts[.hidden] ?? 0) > 0 ? " · \(counts[.hidden] ?? 0) versteckt" : ""))
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            UFFlexWrap(gap: 9.6, rowGap: 9.6) {
                UFButton("Üben", icon: "play") {
                    trainerTitle = deck.stack?.s("name")
                    trainer.start(with: stackCards)
                }
                .disabled(stackCards.isEmpty)
                UFButton("Optionen", icon: "filter", kind: .ghost) {
                    trainerTitle = deck.stack?.s("name")
                    trainer.start(with: stackCards)
                    overlay.modal { FlashcardTrainerOptionsDialog(trainer: trainer) }
                }
                .disabled(stackCards.isEmpty)
            }
            .padding(.top, 12.8)
        }
    }

    private func setFlag(_ c: JSONValue, _ key: String, _ on: Bool) {
        Task { _ = await toast.attempt(key == "hidden" ? "Karte zeigen" : "Lesezeichen") { try await deck.setFlag(c, key, on) } }
    }

    private func rate(_ correct: Bool) {
        Task { _ = await toast.attempt("Bewerten") { try await deck.rate(correct: correct) } }
    }

    // MARK: Karten des Stapels

    private var list: some View {
        UFCard {
            UFCardHead("Karten im Stapel") { Text("\(deck.cards.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            let due = deck.dueIDs
            let rows = Row.rows(deck.cards)
            if rows.isEmpty {
                Text("Noch keine Karte in diesem Stapel.").ufFont(14.5).foregroundStyle(UF.text2).padding(.vertical, 8)
            }
            ForEach(rows) { row in
                let c = row.value
                UFItemRow(c.s("question") ?? "", sub: subline(c, due: due)) {
                    EmptyView()
                } trailing: {
                    let q = c.s("question") ?? ""
                    let marked = (c.i("bookmarked") ?? 0) != 0
                    if canEdit { HStack(spacing: 2) {
                        if (c.i("hidden") ?? 0) != 0 {
                            UFButton("Zeigen", kind: .ghost, size: .small) { setFlag(c, "hidden", false) }
                                .ufHitSlop(trailing: 1)
                                .accessibilityLabel("Karte wieder zeigen: \(q)")
                        }
                        // 28-pt-Symbole 2 pt auseinander: zwischen ihnen je die halbe Luecke, der Rest der 44 pt
                        // nach aussen (links frei, ausser "Zeigen" steht davor)
                        UFButton(icon: "pen", kind: .ghost, size: .small) { openEdit(c) }
                            .ufHitSlop(leading: (c.i("hidden") ?? 0) != 0 ? 1 : .infinity, trailing: 1)
                            .accessibilityLabel("Karte bearbeiten: \(q)")
                        UFButton(icon: "bookmark", kind: .ghost, size: .small) { setFlag(c, "bookmarked", !marked) }
                            .ufHitSlop(leading: 1, trailing: 1)
                            .foregroundStyle(marked ? UF.accentText : UF.text2)
                            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(marked ? UF.accentSoft : .clear))
                            .accessibilityLabel(marked ? "Lesezeichen entfernen: \(q)" : "Lesezeichen setzen: \(q)")
                            .accessibilityAddTraits(marked ? .isSelected : [])
                        UFButton(icon: "trash", kind: .ghost, size: .small) { confirmDelete(c) }
                            .ufHitSlop(leading: 1)
                            .accessibilityLabel("Karte löschen: \(q)")
                    } }
                }
                .ufBorderBottom(row.id != rows.last?.id)
            }
        }
    }

    private func subline(_ c: JSONValue, due: Set<Int>) -> String {
        var parts = [c.s("answer") ?? "", "Fach \(c.i("box") ?? 1)"]
        // versteckt: nie faellig, also kein Termin (der Termin bleibt gespeichert und gilt wieder nach "Zeigen")
        if (c.i("hidden") ?? 0) == 0 {
            parts.append(c.i("id").map { due.contains($0) } == true ? "heute fällig" : "fällig am \(UFFmt.date(c.s("due")))")
        }
        if let f = deck.fileTitle(c) { parts.append(f) }
        if (c.i("bookmarked") ?? 0) != 0 { parts.append("Lesezeichen") }
        if (c.i("hidden") ?? 0) != 0 { parts.append("versteckt, nicht in „Heute fällig“") }
        return parts.joined(separator: " · ")
    }

    private func openCreate() {
        let stack = deck.stack
        overlay.modal {
            FlashcardCreateDialog(deck: deck, entitlements: ent, question: "", moduleID: deck.module(named: stack?.s("subject"))?.i("id"),
                                  fileID: nil, stackID: stack?.i("id"))
        }
    }

    /// "Bearbeiten": derselbe Dialog wie beim Anlegen, mit der Karte vorbelegt; der Trainer uebernimmt den neuen Text
    private func openEdit(_ c: JSONValue) {
        overlay.modal {
            FlashcardCreateDialog(deck: deck, entitlements: ent, card: c) { saved in trainer.merge(saved) }
        }
    }

    private func confirmDelete(_ c: JSONValue) {
        overlay.modal { FlashcardDeleteDialog(deck: deck, card: c) }
    }

    private func openStack(_ s: JSONValue?) {
        overlay.modal { FlashcardStackDialog(deck: deck, stack: s) }
    }

    private func confirmDeleteStack(_ s: JSONValue) {
        overlay.modal { FlashcardStackDeleteDialog(deck: deck, stack: s) }
    }

    // MARK: Geteilte Wochenstapel und Stapel teilen

    private func openWeekFetch(moduleID: Int?, week: Int?) {
        overlay.modal { FlashcardWeekFetchDialog(deck: deck, moduleID: moduleID, week: week) }
    }

    private func openShare(_ s: JSONValue) {
        overlay.modal { FlashcardShareDialog(deck: deck, stack: s) }
    }

    private func confirmUnshare(_ s: JSONValue) {
        overlay.modal { FlashcardUnshareDialog(deck: deck, stack: s) }
    }

    private func openReport(_ sh: JSONValue) {
        overlay.modal { FlashcardSharedReportDialog(deck: deck, shared: sh) }
    }

    private func adopt(_ sh: JSONValue) {
        Task {
            var already = false
            if await toast.attempt("Stapel übernehmen", { already = try await deck.adopt(sh).already }) {
                toast.show(already ? "Diesen Stapel hast du schon übernommen" : "Stapel übernommen – „\(sh.s("name") ?? "")“ ist jetzt deiner")
            }
        }
    }

    private func like(_ sh: JSONValue) {
        Task { _ = await toast.attempt("Like") { try await deck.like(sh) } }
    }
}

/// Lesemodus der Karteikarten (Free, nach der Probe): ruhiger Hinweis ueber der Liste mit dem Weg zur Tarifwahl. Die
/// Karten bleiben erhalten und sichtbar; Ueben und Bearbeiten gibt es wieder mit Plus.
struct FlashcardReadOnlyHint: View {
    @Environment(\.ufShowPlans) private var showPlans
    @State private var sheet = false

    var body: some View {
        UFCard {
            HStack(alignment: .top, spacing: 14.4) {
                ZStack {
                    RoundedRectangle(cornerRadius: UF.r).fill(UF.accentSoft)
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 17, weight: .semibold)).foregroundStyle(UF.accentText)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UFFlashcardAccess.readOnlyHint).ufFont(14.5, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Deine Stapel und Karten bleiben erhalten – hier kannst du sie lesen.").ufFont(13.12).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    UFButton("Tarife ansehen", icon: "star", size: .small) { if let showPlans { showPlans() } else { sheet = true } }
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
        }
        .sheet(isPresented: $sheet) { UFPlanSheet(required: .plus, close: { sheet = false }) }
    }
}

/// "Karten fuer Woche n holen": Modul (wenn nicht vorgegeben) und Lehrwoche waehlen; holt Vorlesung und Uebung
/// nacheinander und zeigt je Art, was geschah (uebernommen = 0 Credits, erzeugt, eigener Stapel, keine Unterlagen)
struct FlashcardWeekFetchDialog: View {
    @ObservedObject var deck: FlashcardDeck
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var module: Int
    @State private var week: Int
    @State private var running = false
    @State private var results: [FlashcardDeck.WeekFetch] = []

    static let costNote = "Je Woche gibt es zwei gemeinsame Stapel: „Vorlesung Woche n“ aus den Vorlesungsunterlagen und „Übung Woche n“ aus den Übungsblättern. "
        + "Sie werden einmal erzeugt und von allen übernommen, die dieselben Unterlagen haben – übernehmen kostet 0 Credits. "
        + "Nur wenn noch niemand sie hat, erzeugt deine KI den Stapel (eine Anfrage je Stapel, bis zu 20 Karten). Geübt wird danach privat."

    @MainActor
    init(deck: FlashcardDeck, moduleID: Int?, week: Int?) {
        self.deck = deck
        _module = State(initialValue: moduleID ?? deck.modules.first?.i("id") ?? 0)
        _week = State(initialValue: week ?? max(1, deck.weeks.last ?? 1))
    }

    private var weekOptions: [(Int, String)] { Array(Set(Array(1...16) + deck.weeks + [week])).sorted().map { ($0, "Woche \($0)") } }

    var body: some View {
        UFDialog("Karten für eine Woche holen", icon: "download") {
            UFField("Modul") {
                UFSelect(options: deck.modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } }, selection: $module, fill: true)
            }
            UFField("Lehrwoche") { UFSelect(options: weekOptions, selection: $week, fill: true) }
            Text(Self.costNote).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results, id: \.kind) { r in
                        Text(r.message).ufFont(13.12, r.status == "no_materials" ? 400 : 600).foregroundStyle(r.status == "no_materials" ? UF.muted : UF.text)
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
            }
        } foot: {
            UFButton(results.isEmpty ? "Abbrechen" : "Fertig") { close() }
            if results.isEmpty {
                UFButton(running ? "Wird geholt …" : "Karten für Woche \(week) holen", icon: "download", kind: .primary) { Task { await run() } }
                    .disabled(running || module == 0)
            }
        }
    }

    private func run() async {
        guard !running, module != 0 else { return }
        running = true
        defer { running = false }
        var got: [FlashcardDeck.WeekFetch] = []
        if await toast.attempt("Karten holen", { got = try await deck.fetchWeek(moduleID: module, week: week) }) {
            results = got
            if got.allSatisfy({ $0.status == "no_materials" }) {
                toast.show("Für Woche \(week) gibt es in diesem Modul keine Unterlagen.")
            } else if got.allSatisfy({ $0.status == "no_materials" || $0.status == "quota_exhausted" }) {
                toast.show(UFAdoptQuota.exhaustedMessage(limit: UFAdoptQuota.limit(deck.entitlements.plan) ?? 0))
            } else if got.contains(where: { $0.status == "adopted" }) {
                toast.show("Karten für Woche \(week) übernommen – 0 Credits")
            } else {
                toast.show("Karten für Woche \(week) sind da")
            }
        }
    }
}

/// Rueckfrage vor "Stapel teilen": was geteilt wird (Kopie der Karten, Pseudonym, Modul-Community), was nicht (Lernstand)
struct FlashcardShareDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let stack: JSONValue
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var saving = false

    static func note(cards: Int, module: String) -> String {
        "Eine Kopie der \(cards) \(cards == 1 ? "Karte" : "Karten") erscheint für alle im Modul „\(module)“ unter deinem Pseudonym"
            + " – ohne Lehrwoche unter „Allgemein“, sonst in der Woche des Stapels. Dein Lernstand wird nicht geteilt; wer den Stapel übernimmt, lernt mit eigener Kopie."
            + " Du kannst das Teilen jederzeit zurückziehen. Teile nur eigene Karten, keine fremden Folien oder Aufgabenstellungen."
    }

    var body: some View {
        UFDialog("Stapel teilen?", icon: "users") {
            Text(stack.s("name") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).padding(.vertical, 5.6)
            Text(Self.note(cards: stack.i("cards") ?? 0, module: stack.s("subject") ?? ""))
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Stapel teilen", icon: "users", kind: .primary) { Task { await share() } }.disabled(saving)
        }
    }

    private func share() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if await toast.attempt("Stapel teilen", { try await deck.share(stack) }) {
            toast.show("Stapel geteilt – sichtbar für alle im Modul")
            close()
        }
    }
}

/// Teilen zurueckziehen: der geteilte Stapel verschwindet aus der Community, Kopien anderer bleiben
struct FlashcardUnshareDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let stack: JSONValue
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Teilen zurückziehen?", icon: "users") {
            Text(stack.s("name") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).padding(.vertical, 5.6)
            Text("Der Stapel verschwindet aus der Community des Moduls. Wer ihn schon übernommen hat, behält seine Kopie. Dein eigener Stapel bleibt.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Zurückziehen", icon: "x", kind: .danger) {
                close()
                Task { if await toast.attempt("Teilen zurückziehen", { try await deck.unshare(stack) }) { toast.show("Teilen zurückgezogen") } }
            }
        }
    }
}

/// Geteilten Stapel melden (Grund und Hinweis), wie bei Loesungen
struct FlashcardSharedReportDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let shared: JSONValue
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var reason = CommunityReportReason.foreignMaterial.rawValue
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        UFDialog("Stapel melden", icon: "flag") {
            Text(shared.s("name") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).padding(.vertical, 5.6)
            UFField("Grund") { UFSelect(options: FlashcardDeck.reportReasons.map { ($0.value, $0.label) }, selection: $reason, fill: true) }
            UFField("Hinweis (optional, keine persönlichen Daten)") { UFTextArea(placeholder: "Was ist das Problem?", text: $note, minHeight: 64) }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Melden", icon: "flag", kind: .danger) { Task { await send() } }.disabled(sending)
        }
    }

    private func send() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        if await toast.attempt("Melden", { try await deck.report(shared, reason: reason, note: note) }) {
            toast.show("Danke, die Meldung ist eingegangen")
            close()
        }
    }
}

// MARK: - Dialoge

/// Karte anlegen oder bearbeiten: Frage und Antwort (Pflicht), Modul (optional), Stapel (Pflicht: ein Stapel des
/// Moduls, Vorgabe der zuletzt benutzte, sonst "Neuer Stapel …" mit Namen) und beim Anlegen das Dokument (optional).
/// Beim Bearbeiten bleibt der Lernstand (Fach, Termin) unberuehrt.
struct FlashcardCreateDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let entitlements: Entitlements
    /// zu bearbeitende Karte (nil = anlegen)
    let card: JSONValue?
    /// nach dem Speichern (Bearbeiten): die gespeicherte Karte, z. B. fuer den Trainer
    var onSaved: ((JSONValue) -> Void)?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var question = ""
    @State private var answer = ""
    @State private var module = 0
    @State private var file = ""
    @State private var stack = FlashcardDeck.newStack
    @State private var newStackName = ""
    @State private var saving = false

    /// Leer (Karteikarten-Seite) oder vorbelegt: "Als Karteikarte" aus markiertem PDF-Text im Editor (Vorderseite
    /// der Text, Modul und Dokument der offenen Datei, Rueckseite leer); `stackID` = Vorgabe des Stapels (sonst der
    /// zuletzt benutzte des Moduls, sonst "Neuer Stapel …")
    init(deck: FlashcardDeck, entitlements: Entitlements, question: String = "", moduleID: Int? = nil, fileID: String? = nil, stackID: Int? = nil) {
        self.deck = deck
        self.entitlements = entitlements
        card = nil
        let p = Self.prefill(question: question, moduleID: moduleID, fileID: fileID, modules: deck.modules, files: deck.files)
        _question = State(initialValue: p.question)
        _module = State(initialValue: p.module)
        _file = State(initialValue: p.file)
        let subject = deck.subject(ofModule: p.module)
        let known = stackID.flatMap { id in deck.stacks.first { $0.i("id") == id } }
        let s = Self.defaultStack(known: known, subject: subject, deck: deck)
        _stack = State(initialValue: s.stack)
        _newStackName = State(initialValue: s.name ?? Self.suggestedName(fileID: p.file, subject: subject, deck: deck))
    }

    /// Bearbeiten: Felder aus der Karte, Modul ueber ihr Fach, Stapel ihr Stapel
    init(deck: FlashcardDeck, entitlements: Entitlements, card: JSONValue, onSaved: ((JSONValue) -> Void)? = nil) {
        self.deck = deck
        self.entitlements = entitlements
        self.card = card
        self.onSaved = onSaved
        _question = State(initialValue: card.s("question") ?? "")
        _answer = State(initialValue: card.s("answer") ?? "")
        _module = State(initialValue: deck.module(named: card.s("subject"))?.i("id") ?? 0)
        _file = State(initialValue: card.s("file_id") ?? "")
        _stack = State(initialValue: card.i("stack_id") ?? FlashcardDeck.newStack)
    }

    /// Vorbelegung: Modul und Dokument nur, wenn der Stapel sie kennt (sonst "– keins –", wie in der Auswahl)
    static func prefill(question: String, moduleID: Int?, fileID: String?, modules: [JSONValue], files: [JSONValue])
        -> (question: String, module: Int, file: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = files.first { $0.s("id") == fileID }
        let known = moduleID.flatMap { id in modules.contains { $0.i("id") == id } ? id : nil }
        // Modul der Datei, sonst das uebergebene Modul (Dokument eines anderen Moduls bliebe sonst ohne Auswahl)
        let module = file?.i("module_id") ?? known ?? 0
        return (q, module, file?.s("id") ?? "")
    }

    /// Vorgabe des Stapels: der uebergebene (wenn er zum Fach passt), sonst der zuletzt benutzte des Fachs, sonst
    /// "Neuer Stapel …"
    @MainActor
    static func defaultStack(known: JSONValue?, subject: String?, deck: FlashcardDeck) -> (stack: Int, name: String?) {
        if let known, let id = known.i("id"), (known.s("subject") ?? "") == (subject ?? "") { return (id, nil) }
        if let last = deck.lastUsedStack(subject: subject), let id = last.i("id") { return (id, nil) }
        return (FlashcardDeck.newStack, nil)
    }

    /// Name fuer "Neuer Stapel …": Titel des Dokuments, sonst "Allgemein" im Modul, sonst "Ohne Modul" (wie die Vorgabe
    /// des Servers fuer Karten ohne Stapel)
    @MainActor
    static func suggestedName(fileID: String, subject: String?, deck: FlashcardDeck) -> String {
        if !fileID.isEmpty, let f = deck.files.first(where: { $0.s("id") == fileID }), let t = f.s("title") ?? f.s("name"), !t.isEmpty { return t }
        return subject == nil ? "Ohne Modul" : "Allgemein"
    }

    private var editing: Bool { card != nil }
    private var subject: String? { deck.subject(ofModule: module) }
    private var stackOptions: [(Int, String)] {
        [(FlashcardDeck.newStack, "Neuer Stapel …")] + deck.stacks(subject: subject).compactMap { s in s.i("id").map { ($0, s.s("name") ?? "") } }
    }

    var body: some View {
        UFDialog(editing ? "Karte bearbeiten" : "Karte anlegen", icon: editing ? "pen" : "cards") {
            UFField("Frage") { UFTextArea(placeholder: "Vorderseite", text: $question, minHeight: 64) }
            UFField("Antwort") { UFTextArea(placeholder: "Rückseite", text: $answer, minHeight: 64) }
            UFField("Modul (optional)") {
                UFSelect(options: [(0, "– keins –")] + deck.modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                         selection: $module, fill: true)
            }
            UFField("Stapel") {
                UFSelect(options: stackOptions, selection: $stack, fill: true)
            }
            if stack == FlashcardDeck.newStack {
                UFField("Name des neuen Stapels") { UFTextInput("z. B. Klausur, Kapitel 3", text: $newStackName) }
            }
            if !editing {
                UFField("Dokument (optional)") {
                    UFSelect(options: [("", "– keins –")] + deck.documents(module: module).compactMap { f in
                        f.s("id").map { ($0, f.s("title") ?? f.s("name") ?? $0) }
                    }, selection: $file, fill: true)
                }
            }
            if editing {
                Text("Fach \(card?.i("box") ?? 1) und Termin der Wiederholung bleiben beim Bearbeiten erhalten.")
                    .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 2)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(editing ? "Speichern" : "Anlegen", icon: editing ? "check" : "plus", kind: .primary) { Task { await save() } }
                .disabled(!canSave || saving)
        }
        .onChange(of: module) { _, m in
            // Dokument eines anderen Moduls passt nicht mehr; Stapel neu vorbelegen (zuletzt benutzter des Moduls)
            if m != 0, !file.isEmpty, !deck.documents(module: m).contains(where: { $0.s("id") == file }) { file = "" }
            let subject = deck.subject(ofModule: m)
            if !deck.stacks(subject: subject).contains(where: { $0.i("id") == stack }) {
                stack = Self.defaultStack(known: nil, subject: subject, deck: deck).stack
            }
            if stack == FlashcardDeck.newStack, !editing { newStackName = Self.suggestedName(fileID: file, subject: subject, deck: deck) }
        }
        .onChange(of: file) { _, f in
            if stack == FlashcardDeck.newStack, !editing { newStackName = Self.suggestedName(fileID: f, subject: subject, deck: deck) }
        }
    }

    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (stack != FlashcardDeck.newStack || !newStackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let newName = stack == FlashcardDeck.newStack ? newStackName : nil
        if let card {
            let ok = await toast.attempt("Karte speichern") {
                var sid = stack
                if let newName { sid = try await deck.createStack(name: newName, subject: subject, fileID: card.s("file_id")) }
                let saved = try await deck.update(card, question: question, answer: answer, subject: subject, stackID: sid)
                onSaved?(saved)
            }
            if ok {
                toast.show("Karte gespeichert")
                close()
            }
        } else if await toast.attempt("Karte anlegen", {
            try await deck.create(question: question, answer: answer, fileID: file.isEmpty ? nil : file,
                                  stackID: newName == nil ? stack : nil, newStackName: newName, subject: subject)
        }) {
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

/// Stapel anlegen bzw. umbenennen und in ein anderes Modul verschieben (die Karten folgen)
struct FlashcardStackDialog: View {
    @ObservedObject var deck: FlashcardDeck
    /// zu bearbeitender Stapel (nil = neu)
    let stack: JSONValue?
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var name: String
    @State private var module: Int
    /// Lehrwoche, 0 = Allgemein
    @State private var week: Int
    @State private var kind: String
    @State private var saving = false

    /// waehlbare Lehrwochen (1…16, dazu vorkommende groessere)
    static func weekOptions(_ deck: FlashcardDeck, current: Int) -> [(Int, String)] {
        let all = Array(Set(Array(1...16) + deck.weeks + (current > 0 ? [current] : []))).sorted()
        return [(FlashcardDeck.generalWeek, "Allgemein")] + all.map { ($0, "W\($0)") }
    }

    @MainActor
    init(deck: FlashcardDeck, stack: JSONValue?) {
        self.deck = deck
        self.stack = stack
        _name = State(initialValue: stack?.s("name") ?? "")
        _module = State(initialValue: deck.module(named: stack?.s("subject"))?.i("id") ?? 0)
        _week = State(initialValue: stack?.i("week") ?? FlashcardDeck.generalWeek)
        _kind = State(initialValue: stack?.s("kind") ?? "eigene")
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        UFDialog(stack == nil ? "Neuer Stapel" : "Stapel bearbeiten", icon: "layers") {
            UFField("Name") { UFTextInput("z. B. Klausur, Kapitel 3", text: $name) }
            UFField("Modul") {
                UFSelect(options: [(0, "– keins –")] + deck.modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                         selection: $module, fill: true)
            }
            UFField("Lehrwoche") { UFSelect(options: Self.weekOptions(deck, current: week), selection: $week, fill: true) }
            UFField("Art") { UFSelect(options: FlashcardDeck.kinds.map { ($0.value, $0.label) }, selection: $kind, fill: true) }
            if let n = stack?.i("cards"), n > 0 {
                Text("Die \(n) \(n == 1 ? "Karte" : "Karten") des Stapels wechseln das Modul mit.")
                    .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 2)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(stack == nil ? "Anlegen" : "Speichern", icon: stack == nil ? "plus" : "check", kind: .primary) { Task { await save() } }
                .disabled(!canSave || saving)
        }
    }

    private func save() async {
        guard canSave, !saving else { return }
        saving = true
        defer { saving = false }
        let subject = deck.subject(ofModule: module)
        let w: Int?? = .some(week == FlashcardDeck.generalWeek ? nil : week)
        if let id = stack?.i("id") {
            if await toast.attempt("Stapel speichern", { try await deck.updateStack(id, name: name, subject: subject, week: w, kind: kind) }) {
                toast.show("Stapel gespeichert")
                close()
            }
        } else if await toast.attempt("Stapel anlegen", { try await deck.createStack(name: name, subject: subject, week: w, kind: kind) }) {
            toast.show("Stapel angelegt")
            close()
        }
    }
}

/// Rueckfrage vor dem Loeschen eines Stapels: Karten mitloeschen oder in einen anderen Stapel verschieben
struct FlashcardStackDeleteDialog: View {
    @ObservedObject var deck: FlashcardDeck
    let stack: JSONValue
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    /// 0 = Karten loeschen, sonst Zielstapel
    @State private var target = 0

    private var others: [(Int, String)] {
        deck.stacks.filter { $0.i("id") != stack.i("id") }.compactMap { s in
            s.i("id").map { ($0, (s.s("name") ?? "") + (s.s("subject").map { " (\($0))" } ?? "")) }
        }
    }

    var body: some View {
        let n = stack.i("cards") ?? 0
        UFDialog("Stapel löschen?", icon: "trash") {
            Text(stack.s("name") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).padding(.vertical, 5.6)
            if n == 0 {
                Text("Der Stapel ist leer und wird gelöscht.").ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            } else {
                Text("Was soll mit \(n == 1 ? "der Karte" : "den \(n) Karten") geschehen?").ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                UFField("Karten") {
                    UFSelect(options: [(0, "Mit dem Stapel löschen")] + others.map { ($0.0, "Verschieben in: \($0.1)") }, selection: $target, fill: true)
                }
                Text(target == 0 ? "Die Karten und ihr Lernstand werden gelöscht. Das lässt sich nicht rückgängig machen."
                                 : "Die Karten behalten ihren Lernstand und bekommen das Modul des Zielstapels.")
                    .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(target == 0 ? "Löschen" : "Verschieben und löschen", icon: "trash", kind: .danger) {
                close()
                let moveTo = target == 0 ? nil : target
                Task {
                    if await toast.attempt("Stapel löschen", { try await deck.deleteStack(stack.i("id") ?? 0, moveTo: moveTo) }) {
                        toast.show(moveTo == nil ? "Stapel gelöscht" : "Karten verschoben, Stapel gelöscht")
                    }
                }
            }
        }
    }
}
