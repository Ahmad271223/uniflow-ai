import StoreKit
import SwiftUI

// Tarife und Berechtigungen in V1 (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 4 und 5).
// Entscheidung des Inhabers vom 25.10.2026: nur Free und Plus; Pro und KI entfallen vorerst.
// Die Berechtigung entsteht auf dem Geraet aus Transaction.currentEntitlements (von StoreKit signiert und
// geprueft). Ab V2 prueft zusaetzlich der Server (app/billing.py, /api/billing/apple/verify).

// MARK: - Tarif

/// Free / Plus (Abschnitt 4). Pro aus app/billing.py gibt es in der App vorerst nicht.
enum UFPlan: String, CaseIterable, Comparable, Identifiable {
    case free, plus

    var id: String { rawValue }

    var rank: Int {
        switch self {
        case .free: return 0
        case .plus: return 1
        }
    }

    static func < (a: UFPlan, b: UFPlan) -> Bool { a.rank < b.rank }

    var title: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        }
    }

    /// Apple-Produkt (nur StoreKit-Testkonfiguration); Free hat keins
    var productID: String? {
        switch self {
        case .free: return nil
        case .plus: return "de.uniflow.plus.monthly"
        }
    }

    /// Produkt -> Tarif; fremde und nicht mehr angebotene Produkte (z. B. das fruehere Pro) geben keinen Tarif
    init?(productID: String) {
        guard let p = UFPlan.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = p
    }
}

// MARK: - Funktionen

/// Funktionen aus der Tabelle in Abschnitt 4. Jede Zeile der Tabelle ist genau ein Fall; die Reihenfolge ist die
/// Reihenfolge auf den Tarifkarten.
enum UFFeature: String, CaseIterable, Identifiable {
    // Free
    case studipSync          // Mit Apple anmelden, Stud.IP verbinden, Kurse/Ordner/neue Dateien abgleichen
    case readDocuments       // Dokumente oeffnen, lesen und durchsuchen, Bibliothek, Ordner, Favoriten
    case modulesTimetable    // Meine Module (Faecher geordnet), Stundenplan ansehen
    case studyCalendar       // Lernkalender ansehen, Aufgaben abhaken
    case studyPlanning       // Lernplan, Lernkombination, freie Zeitfenster, Nachholen, "Woche retten"
    case timer               // Stoppuhr, Countdown, Pomodoro
    case viewNotes           // vorhandene Notizen ansehen und als PDF exportieren
    case uniGrades           // Uni & Noten (QIS), vorerst ausserhalb der Tarife: "bald", bis nativ vorhanden (F4)
    // Plus
    case pencilWriting       // Stift, Marker, Radierer, Lasso, Seiten einfuegen/drehen/Papierkorb, Lesezeichen
    case community           // Loesungen als Datei teilen und im Editor ansehen; Online-Community folgt
    case splitView           // Uebung und Skript nebeneinander, Skriptsuche zur Aufgabe
    case flashcards          // eigene Karteikarten mit Wiederholung
    // ab V2
    case uniflowEditor
    case deviceSync

    var id: String { rawValue }

    /// kleinster Tarif, in dem die Funktion enthalten ist
    var minimumPlan: UFPlan {
        switch self {
        case .studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes,
             .uniGrades:
            return .free
        case .pencilWriting, .community, .splitView, .flashcards, .uniflowEditor, .deviceSync:
            return .plus
        }
    }

    /// erst ab V2 vorhanden (UniFlow-Editor, Abgleich zwischen Geraeten)
    var isV2: Bool { self == .uniflowEditor || self == .deviceSync }

    /// Bezeichnung auf der Abo-Seite und in der Sperrkarte
    var title: String {
        switch self {
        case .studipSync: return "Stud.IP verbinden und abgleichen"
        case .readDocuments: return "Dokumente öffnen, lesen und durchsuchen"
        case .modulesTimetable: return "Meine Module und Stundenplan"
        case .studyCalendar: return "Lernkalender ansehen, Aufgaben abhaken"
        case .studyPlanning: return "Lernplanung"
        case .timer: return "Zeitmesser (Stoppuhr, Countdown, Pomodoro)"
        case .viewNotes: return "Notizen ansehen und als PDF exportieren"
        case .uniGrades: return "Uni & Noten"
        case .pencilWriting: return "Schreiben mit Apple Pencil"
        case .community: return "Community"
        case .splitView: return "Übung und Skript nebeneinander"
        case .flashcards: return "Eigene Karteikarten mit Wiederholung"
        case .uniflowEditor: return "UniFlow-Editor"
        case .deviceSync: return "Abgleich zwischen deinen Geräten"
        }
    }

    /// Zusatz unter dem Titel (Umfang der Zeile aus Abschnitt 4)
    var detail: String? {
        switch self {
        case .modulesTimetable: return "Deine Fächer geordnet nach Modulen"
        case .studyPlanning: return "Lernplan, Lernkombination, freie Zeitfenster, Nachholen, „Woche retten“"
        case .uniGrades: return "Notenspiegel und Bescheinigungen aus QIS"
        case .pencilWriting: return "Stift, Marker, Radierer, Lasso, Seiten einfügen, drehen und in den Papierkorb legen, Lesezeichen"
        case .community: return "Lösungen als Datei teilen und im Editor ansehen – Online-Community folgt"
        case .splitView: return "Mit Skriptsuche zur Aufgabe"
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .studipSync: return "sync"
        case .readDocuments: return "book"
        case .modulesTimetable: return "calendar"
        case .studyCalendar: return "tasks"
        case .studyPlanning: return "calendar"
        case .timer: return "clock"
        case .viewNotes: return "download"
        case .uniGrades: return "graduation"
        case .pencilWriting: return "pencil"
        case .community: return "users"
        case .splitView: return "columns"
        case .flashcards: return "cards"
        case .uniflowEditor: return "pen"
        case .deviceSync: return "refresh"
        }
    }
}

// MARK: - Funktionsmatrix

/// Zugang zu einer Funktion
enum UFAccess: Equatable {
    case allowed
    /// gesperrt, freigeschaltet ab diesem Tarif
    case locked(UFPlan)
    /// noch nicht vorhanden (Uni & Noten vor F4, Community, Funktionen ab V2) – als "bald" kennzeichnen, in keinem
    /// Tarif freigeschaltet
    case comingSoon

    var isAllowed: Bool { self == .allowed }
}

/// Regeln aus Abschnitt 4, ohne StoreKit (testbar)
enum UFFeatureMatrix {
    /// Uni & Noten laeuft heute ueber den PC-Server; direkt auf dem iPad erst mit F4 (Pruefbericht). Bis dahin ist
    /// die Funktion in keinem Tarif freigeschaltet ("bald" bei Free, Abschnitt 4).
    static let uniGradesOnDevice = false

    /// Community-Funktionen auf dem Geraet: eigene Loesung als Datei teilen (nur eigene Notizen, verschluesselt) und
    /// empfangene Loesungen im Editor ansehen, ohne Server (docs/LOESUNGEN-TEILEN.md). Die Online-Community
    /// (Veroeffentlichen, Suchen) braucht einen zentralen Dienst und ist im Dialog deaktiviert
    /// ("Community-Dienst noch nicht verbunden").
    static let communityAvailable = true

    static func access(_ f: UFFeature, plan: UFPlan, uniGrades: Bool = uniGradesOnDevice,
                       community: Bool = communityAvailable) -> UFAccess {
        if f.isV2 || (f == .uniGrades && !uniGrades) || (f == .community && !community) { return .comingSoon }
        return plan >= f.minimumPlan ? .allowed : .locked(f.minimumPlan)
    }

    /// Bietet der Tarif heute schon etwas, das der naechstkleinere nicht hat? Sonst sagt die Tarifkarte das offen.
    static func hasAvailableExtras(in plan: UFPlan, uniGrades: Bool = uniGradesOnDevice,
                                   community: Bool = communityAvailable) -> Bool {
        if plan == .free { return true }
        return UFFeature.allCases.contains {
            $0.minimumPlan == plan && access($0, plan: plan, uniGrades: uniGrades, community: community) == .allowed
        }
    }

    /// Funktionen, die ein Tarif mehr bietet als der naechstkleinere (Inhalt der Tarifkarten)
    static func added(in plan: UFPlan) -> [UFFeature] {
        UFFeature.allCases.filter { $0.minimumPlan == plan }
    }

    /// Herabstufen (Abschnitt 4, "Regeln"): Notizen bleiben vollstaendig erhalten, lesbar und exportierbar;
    /// nur Bearbeiten wird gesperrt. Es wird nie etwas geloescht.
    static func notes(plan: UFPlan) -> UFNoteAccess {
        UFNoteAccess(canView: true, canExport: true, canEdit: access(.pencilWriting, plan: plan).isAllowed)
    }
}

/// Was mit vorhandenen Notizen im aktuellen Tarif moeglich ist
struct UFNoteAccess: Equatable {
    let canView: Bool
    let canExport: Bool
    let canEdit: Bool
}

// MARK: - Tarif aus den Transaktionen

/// Das Noetige aus einer StoreKit-Transaktion (testbar ohne StoreKit)
struct UFEntitlementEntry: Equatable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded = false
    /// Einfuehrungsangebot ("1 Woche gratis")
    var isIntroOffer = false
}

extension UFEntitlementEntry {
    init(_ t: StoreKit.Transaction) {
        productID = t.productID
        expirationDate = t.expirationDate
        revocationDate = t.revocationDate
        isUpgraded = t.isUpgraded
        isIntroOffer = t.offerType == .introductory
    }
}

enum UFEntitlementResolver {
    /// gueltig = nicht erstattet/widerrufen, nicht abgelaufen, nicht durch ein hoeheres Abo ersetzt
    static func isActive(_ e: UFEntitlementEntry, now: Date) -> Bool {
        guard e.revocationDate == nil, !e.isUpgraded else { return false }
        if let exp = e.expirationDate, exp <= now { return false }
        return true
    }

    /// hoechster gueltiger Tarif wie current_plan() in app/billing.py, sonst Free
    static func plan(from entries: [UFEntitlementEntry], now: Date = Date()) -> UFPlan {
        entries.filter { isActive($0, now: now) }.compactMap { UFPlan(productID: $0.productID) }.max() ?? .free
    }

    /// Laeuft der gueltige Tarif gerade in der Gratiswoche?
    static func inIntroOffer(_ entries: [UFEntitlementEntry], plan: UFPlan, now: Date = Date()) -> Bool {
        entries.contains { isActive($0, now: now) && UFPlan(productID: $0.productID) == plan && $0.isIntroOffer }
    }
}

// MARK: - Berechtigung zur Laufzeit

/// Aktueller Tarif der App. Beobachtet Transaction.updates (Kaeufe auf anderen Geraeten, Verlaengerung,
/// Kuendigung, Erstattung) und schliesst neue Transaktionen ab. Eine Instanz fuer die ganze App: `shared`.
@MainActor
final class Entitlements: ObservableObject {
    static let shared = Entitlements()

    @Published private(set) var plan: UFPlan = .free
    /// gueltiger Tarif laeuft in der Gratiswoche
    @Published private(set) var inIntroOffer = false
    /// Ablauf bzw. naechste Verlaengerung des gueltigen Abos
    @Published private(set) var expiresAt: Date?
    /// Abo noch nicht geprueft (erster Abruf von currentEntitlements laeuft)
    @Published private(set) var loading = true
    /// zaehlt verifizierte Transaktionen (Kauf, Transaction.updates wie Verlaengerung oder freigegebene Kaufanfrage);
    /// die Tarifwahl liest daraufhin den Anspruch auf die Probewoche neu
    @Published private(set) var transactionCount = 0

    /// Server-Pruefung der signierten Transaktion (JWS, ab V2). In V1 nicht gesetzt.
    var verifyOnServer: ((String) async -> Bool)?

    private var updates: Task<Void, Never>?

    /// `observe: false` nur fuer Tests und Vorschauen mit festem Tarif
    init(observe: Bool = true, plan: UFPlan = .free) {
        self.plan = plan
        guard observe else { loading = false; return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await refresh() }
    }

    deinit { updates?.cancel() }

    func access(_ f: UFFeature) -> UFAccess { UFFeatureMatrix.access(f, plan: plan) }

    func allows(_ f: UFFeature) -> Bool { access(f).isAllowed }

    var notes: UFNoteAccess { UFFeatureMatrix.notes(plan: plan) }

    /// Tarif neu aus Transaction.currentEntitlements bestimmen (nur verifizierte Transaktionen)
    func refresh() async {
        var entries: [UFEntitlementEntry] = []
        var expiry: [String: Date] = [:]
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            entries.append(UFEntitlementEntry(t))
            if let e = t.expirationDate { expiry[t.productID] = e }
        }
        let now = Date()
        var p = UFEntitlementResolver.plan(from: entries, now: now)
        #if DEBUG
        // Startargument -UFPlan free|plus: fester Tarif fuer Simulator-Ablaeufe ohne StoreKit-Testkonfiguration
        if let forced = DebugLaunch.forcedPlan() { p = forced }
        #endif
        plan = p
        inIntroOffer = UFEntitlementResolver.inIntroOffer(entries, plan: p, now: now)
        expiresAt = p.productID.flatMap { expiry[$0] }
        loading = false
    }

    /// Ergebnis eines Kaufs oder einer Aktualisierung. false = nicht verifiziert bzw. vom Server abgelehnt.
    @discardableResult
    func handle(_ result: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else { return false }
        transactionCount += 1
        var ok = true
        if let verify = verifyOnServer { ok = await verify(result.jwsRepresentation) }
        await transaction.finish()
        await refresh()
        return ok
    }

    #if DEBUG
    /// nur Tests und Vorschauen
    func setPlanForTesting(_ p: UFPlan) { plan = p; loading = false }
    #endif
}

// MARK: - Gesperrte Funktionen sichtbar machen

/// Weg zur Abo-Seite. Ohne gesetzte Aktion oeffnet der Baustein die Tarifwahl selbst als Blatt.
private struct UFShowPlansKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// z. B. im App-Rahmen auf "Einstellungen -> Tarif" setzen
    var ufShowPlans: (() -> Void)? {
        get { self[UFShowPlansKey.self] }
        set { self[UFShowPlansKey.self] = newValue }
    }
}

extension View {
    /// Funktion nur im passenden Tarif: sonst sichtbar, aber gedimmt, mit Schloss; Tippen fuehrt zur Abo-Seite.
    /// Beispiel: `UFButton("Stift", icon: "pen") { … }.ufRequires(.pencilWriting)`
    /// `entitlements: nil` = `Entitlements.shared` (erst im MainActor-Kontext aufgeloest, Swift 6).
    @MainActor
    func ufRequires(_ feature: UFFeature, entitlements: Entitlements? = nil) -> some View {
        modifier(UFRequiresModifier(feature: feature, ent: entitlements ?? .shared))
    }
}

private struct UFRequiresModifier: ViewModifier {
    let feature: UFFeature
    @ObservedObject var ent: Entitlements
    @Environment(\.ufShowPlans) private var showPlans
    @State private var sheet = false

    func body(content: Content) -> some View {
        let access = ent.access(feature)
        if access.isAllowed {
            content
        } else {
            content
                .allowsHitTesting(false)
                .opacity(0.55)
                .overlay(alignment: .topTrailing) { UFLockMark(access: access).offset(x: 6, y: -6) }
                .contentShape(Rectangle())
                .onTapGesture { if case .locked = access { open() } }
                .accessibilityElement(children: .combine)
                .accessibilityHint(access == .comingSoon ? "Bald verfügbar" : "Gesperrt. Öffnet die Tarifwahl.")
                .sheet(isPresented: $sheet) { UFPlanSheet(close: { sheet = false }) }
        }
    }

    private func open() {
        if let showPlans { showPlans() } else { sheet = true }
    }
}

/// kleines Schloss (bzw. "bald") an gesperrten Elementen
struct UFLockMark: View {
    let access: UFAccess

    var body: some View {
        switch access {
        case .allowed:
            EmptyView()
        case .locked(let p):
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                Text(p.title).ufFont(10.4, 650, lh: 1.2)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(Capsule().fill(UF.accent))
            .accessibilityHidden(true)
        case .comingSoon:
            Text("bald").ufFont(10.4, 650, lh: 1.2)
                .foregroundStyle(UF.text2)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(Capsule().fill(UF.surface2))
                .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

/// Karte an Stelle einer gesperrten Ansicht: Schloss, was die Funktion kann, "Mit Plus freischalten".
/// Ist die Funktion erlaubt, zeigt die Karte nichts.
struct UFLockedCard: View {
    let feature: UFFeature
    @ObservedObject var ent: Entitlements
    @Environment(\.ufShowPlans) private var showPlans
    @State private var sheet = false

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(_ feature: UFFeature, entitlements: Entitlements? = nil) {
        self.feature = feature
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
    }

    var body: some View {
        let access = ent.access(feature)
        if !access.isAllowed {
            UFCard {
                HStack(alignment: .top, spacing: 14.4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UF.r).fill(UF.accentSoft)
                        Image(systemName: access == .comingSoon ? "hourglass" : "lock.fill")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(UF.accentText)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(feature.title).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                            UFLockMark(access: access)
                        }
                        Text(Self.message(feature, access: access)).ufFont(13.12).foregroundStyle(UF.muted)
                        if case .locked(let p) = access {
                            UFButton("Mit \(p.title) freischalten", icon: "star", kind: .primary, size: .small) { open() }
                                .padding(.top, 8)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .sheet(isPresented: $sheet) { UFPlanSheet(close: { sheet = false }) }
        }
    }

    static func message(_ f: UFFeature, access: UFAccess) -> String {
        switch access {
        case .allowed: return ""
        case .comingSoon:
            if f.isV2 { return "Kommt mit der nächsten Version von UniFlow." }
            let base = f.detail.map { "\($0). " } ?? ""
            if f == .community { return base + "Bald verfügbar – die Community folgt mit einem Update." }
            return base + "Bald verfügbar – kommt mit einem Update direkt auf dein iPad."
        case .locked(let p):
            let base = f.detail.map { "\($0). " } ?? ""
            return base + "Enthalten in \(p.title). Deine Notizen und Daten bleiben in jedem Tarif erhalten."
        }
    }

    private func open() {
        if let showPlans { showPlans() } else { sheet = true }
    }
}

/// Ansicht nur im passenden Tarif, sonst die Sperrkarte. Beobachtet den Tarif selbst, damit nach Kauf, Ablauf oder
/// Erstattung sofort neu gezeichnet wird (ein blosses `if Entitlements.shared.allows(…)` im Aufrufer tut das nicht).
/// Beispiel: `UFGate(.flashcards) { CardsPage() }`
struct UFGate<Content: View>: View {
    let feature: UFFeature
    @ObservedObject private var ent: Entitlements
    private let content: () -> Content

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(_ feature: UFFeature, entitlements: Entitlements? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.feature = feature
        self.content = content
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
    }

    var body: some View {
        if ent.allows(feature) {
            content()
        } else {
            UFLockedCard(feature, entitlements: ent)
        }
    }
}

/// Sperrkarte als Blatt, z. B. im Editor (Schreiben, geteilte Ansicht): Schloss, Umfang, "Mit Plus freischalten".
/// Nach einem Kauf zeigt das Blatt, dass die Funktion frei ist.
struct UFLockedSheet: View {
    let feature: UFFeature
    let close: () -> Void

    init(_ feature: UFFeature, close: @escaping () -> Void) {
        self.feature = feature
        self.close = close
    }

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 640, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(feature) {
                    UFCard { Text("„\(feature.title)“ ist freigeschaltet.").ufFont(14.5).foregroundStyle(UF.text) }
                }
            }
            .navigationTitle(feature.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: close) } }
        }
    }
}

/// Tarifwahl als Blatt (aus Sperren heraus)
struct UFPlanSheet: View {
    let close: () -> Void

    var body: some View {
        NavigationStack {
            PlanPickerView(context: .upgrade, onDone: close)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: close) } }
        }
    }
}
