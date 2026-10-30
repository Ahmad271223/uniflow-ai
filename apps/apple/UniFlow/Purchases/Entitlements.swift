import StoreKit
import SwiftUI

// Funktionen der iPad-App und ihre Tarife (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 4; docs/ABO-SYSTEM.md).
// Entscheidung des Inhabers vom 27.10.2026: vier Studora-Tarife (Plans.swift, Vertrag plans.json). Die Rechte von Plus
// bleiben auf dem iPad, wie sie waren; Pro Connect und Pro AI enthalten alles aus Plus. Was den gehosteten Dienst
// braucht (Studora-KI, Testbibliothek, Lernstatistik, Abgleich zwischen Geraeten, ChatGPT), erscheint als
// "in Vorbereitung". Die Berechtigung entsteht auf dem Geraet aus Transaction.currentEntitlements (von StoreKit signiert
// und geprueft, hoechster gueltiger Tarif). Die Pruefung im Dienst ist vorbereitet und abgeschaltet
// (BillingServiceLink.swift, V2).

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
    case uniGrades           // Uni & Noten (QIS bzw. LSF auf dem Geraet, F4), Free
    case communityRead       // Community lesen (can_read_community): Loesungen anderer finden, laden, im Editor
                             // ansehen, empfangene Dateien oeffnen, melden, blockieren, Lerngruppen beitreten,
                             // eigene Veroeffentlichungen zurueckziehen
    // Plus
    case pencilWriting       // Stift, Marker, Radierer, Lasso, Seiten einfuegen/drehen/Papierkorb, Lesezeichen
    case shareSolutions      // Eigene Loesungen teilen (can_share_solutions): als Datei, in der Community
                             // veroeffentlichen, Pseudonym, Lerngruppen anlegen
    case splitView           // Uebung und Skript nebeneinander, Skriptsuche zur Aufgabe
    case flashcards          // eigene Karteikarten mit Wiederholung
    // ab V2
    case uniflowEditor
    case deviceSync

    var id: String { rawValue }

    /// kleinster Tarif, in dem die Funktion enthalten ist (hoehere Tarife enthalten sie auch). Fuer Funktionen, die
    /// ein Recht des Vertrags umsetzen (`UFEntitlement.onDevice`), gleich dessen `from` (PlanContractTests).
    var minimumPlan: UFPlan {
        switch self {
        case .studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes,
             .uniGrades, .communityRead:
            return .free
        case .pencilWriting, .shareSolutions, .splitView, .flashcards, .uniflowEditor, .deviceSync:
            return .plus
        }
    }

    /// Teil der Community (beide haengen am iCloud-Container des Builds)
    var isCommunity: Bool { self == .communityRead || self == .shareSolutions }

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
        case .communityRead: return "Community lesen"
        case .pencilWriting: return "Schreiben mit Apple Pencil"
        case .shareSolutions: return "Eigene Lösungen teilen"
        case .splitView: return "Übung und Skript nebeneinander"
        case .flashcards: return "Eigene Karteikarten mit Wiederholung"
        case .uniflowEditor: return "Studora-Editor"
        case .deviceSync: return "Abgleich zwischen deinen Geräten"
        }
    }

    /// Zusatz unter dem Titel (Umfang der Zeile aus Abschnitt 4)
    var detail: String? {
        switch self {
        case .modulesTimetable: return "Deine Fächer geordnet nach Modulen"
        case .studyPlanning: return "Lernplan, Lernkombination, freie Zeitfenster, Nachholen, „Woche retten“"
        case .uniGrades: return "Notenspiegel aus QIS bzw. LSF direkt in der App"
        case .communityRead: return "Lösungen anderer finden, laden und im Editor ansehen, melden und blockieren, Lerngruppen beitreten"
        case .pencilWriting: return "Stift, Marker, Radierer, Lasso, Seiten einfügen, drehen und in den Papierkorb legen, Lesezeichen"
        case .shareSolutions: return "Als verschlüsselte Datei weitergeben und in der Community veröffentlichen, Lerngruppen anlegen"
        case .splitView: return "Mit Skriptsuche zur Aufgabe"
        case .flashcards: return "Selbst angelegt, Wiederholung nach dem Leitner-System"
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
        case .communityRead: return "search"
        case .pencilWriting: return "pencil"
        case .shareSolutions: return "users"
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
    /// noch nicht vorhanden (Funktionen ab V2; frueher auch Uni & Noten vor F4 und Karteikarten) – als "bald"
    /// kennzeichnen, in keinem Tarif freigeschaltet
    case comingSoon

    var isAllowed: Bool { self == .allowed }

    /// Tarif, der die Funktion freischaltet (nur bei `.locked`)
    var requiredPlan: UFPlan? {
        if case .locked(let p) = self { return p }
        return nil
    }
}

/// Regeln aus Abschnitt 4, ohne StoreKit (testbar)
enum UFFeatureMatrix {
    /// Uni & Noten: an der Uni Hildesheim liest der Abgleich den LSF-Notenspiegel auf dem Geraet, an der LUH liest
    /// `QISConnection` das QIS (F4) - in beiden Faellen vorhanden, Teil von Free (Abschnitt 4, "bald" entfaellt).
    static let uniGradesOnDevice = true

    /// Community-Funktionen (Lesen in Free, Teilen ab Plus): eigene Loesung als Datei teilen (nur eigene Notizen,
    /// verschluesselt), empfangene Loesungen im Editor ansehen und die Online-Community ueber CloudKit
    /// (docs/LOESUNGEN-TEILEN.md, Abschnitt 7). Ohne iCloud-Container im Build meldet der Dienst selbst
    /// "nicht verfuegbar"; der Dateiweg bleibt.
    static let communityAvailable = true

    /// Eigene Karteikarten ohne PC: Anlegen, Wiederholen und Loeschen im lokalen Backend (`FlashcardEndpoints`, M8) und
    /// auf der Seite "Karteikarten" (CardsPage), Teil von Plus. Vorher "bald" auf der Plus-Karte (nichts vortaeuschen,
    /// Richtlinie 3.1.2); der Schalter bleibt fuer Tests der Matrix.
    static let flashcardsOnDevice = true

    static func access(_ f: UFFeature, plan: UFPlan, uniGrades: Bool = uniGradesOnDevice,
                       community: Bool = communityAvailable, flashcards: Bool = flashcardsOnDevice) -> UFAccess {
        if f.isV2 || (f == .uniGrades && !uniGrades) || (f.isCommunity && !community) || (f == .flashcards && !flashcards) {
            return .comingSoon
        }
        return plan >= f.minimumPlan ? .allowed : .locked(f.minimumPlan)
    }

    /// Bietet der Tarif heute schon etwas, das der naechstkleinere nicht hat? Sonst sagt die Tarifkarte das offen.
    static func hasAvailableExtras(in plan: UFPlan, uniGrades: Bool = uniGradesOnDevice,
                                   community: Bool = communityAvailable, flashcards: Bool = flashcardsOnDevice) -> Bool {
        if plan == .free { return true }
        return UFFeature.allCases.contains {
            $0.minimumPlan == plan && access($0, plan: plan, uniGrades: uniGrades, community: community, flashcards: flashcards) == .allowed
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

// MARK: - Inhalt der Tarifkarten

/// Eine Zeile auf einer Tarifkarte
struct UFPlanCardRow: Equatable {
    let title: String
    var detail: String?
    var icon: String
    /// noch nicht auf dem iPad: steht unter der Marke "in Vorbereitung", nie bei "enthalten"
    var preparing = false
}

/// Was die Tarifkarten zeigen (ohne StoreKit, testbar). Regel des Inhabers: nur als enthalten zeigen, was im Vertrag
/// `available` ist und auf dem Geraet wirklich geht; alles andere traegt "in Vorbereitung". Die App verspricht nichts,
/// was sie nicht kann.
enum UFPlanCard {
    /// heute auf dem iPad enthalten: Funktionen, die der Tarif mehr bietet als der naechstkleinere
    static func included(_ plan: UFPlan) -> [UFPlanCardRow] {
        UFFeatureMatrix.added(in: plan).filter { !$0.isV2 && UFFeatureMatrix.access($0, plan: plan) == .allowed }.map {
            UFPlanCardRow(title: $0.title, detail: $0.detail, icon: $0.icon)
        }
    }

    /// in Vorbereitung: Rechte ab diesem Tarif, die das iPad noch nicht hat (brauchen den Dienst oder sind im Vertrag
    /// nicht `available`), dazu Geraete-Funktionen, deren Schalter noch aus ist
    static func preparing(_ plan: UFPlan) -> [UFPlanCardRow] {
        let features = UFFeatureMatrix.added(in: plan).filter { !$0.isV2 && UFFeatureMatrix.access($0, plan: plan) == .comingSoon }.map {
            UFPlanCardRow(title: $0.title, detail: $0.detail, icon: "clock", preparing: true)
        }
        let rights = UFEntitlement.allCases.filter {
            $0.from == plan && !$0.availableOnDevice
        }.map { UFPlanCardRow(title: $0.cardLabel, icon: "clock", preparing: true) }
        return features + rights
    }

    /// Tarif, dessen Umfang dieser Tarif auf dem iPad heute hat: der hoechste bis hierhin mit eigenen Funktionen
    /// (Pro Connect und Pro AI: Plus, solange ihre Funktionen den Dienst brauchen)
    static func sameScope(as plan: UFPlan) -> UFPlan {
        UFPlan.allCases.filter { $0 <= plan && UFFeatureMatrix.hasAvailableExtras(in: $0) }.max() ?? .free
    }

    /// Kurzbeschreibung aus dem Vertrag nur, wenn der Tarif schon etwas Eigenes bietet
    static func tagline(_ plan: UFPlan) -> String? {
        UFFeatureMatrix.hasAvailableExtras(in: plan) ? plan.tagline : nil
    }

    /// Ueberschrift ueber den Zeilen
    static func intro(_ plan: UFPlan) -> String {
        guard let lower = plan.lower else { return "Alles für den Uni-Alltag:" }
        return included(plan).isEmpty ? "Alles aus \(lower.name)." : "Alles aus \(lower.name), dazu:"
    }

    /// Hinweis unter den Zeilen: woran "in Vorbereitung" haengt und, wenn der Tarif heute nichts Eigenes bietet, dass
    /// er denselben Umfang hat wie ein kleinerer (Auftrag Abschnitt 2 Punkt 4: nichts vortaeuschen)
    static func note(_ plan: UFPlan) -> String? {
        guard !preparing(plan).isEmpty else { return nil }
        let base = "Was „in Vorbereitung“ steht, braucht den Online-Dienst von Studora und folgt mit einem Update."
        let same = sameScope(as: plan)
        return same == plan ? base : base + " Bis dahin bietet \(plan.name) denselben Umfang wie \(same.name)."
    }
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

    /// Vorgemerkter Wechsel zur naechsten Verlaengerung (Downgrade in der Abo-Gruppe; Apple stellt ihn erst dann um,
    /// wie `pending_plan` in app/billing.py). Aus RenewalInfo: verlaengert sich das Abo und mit welchem Produkt?
    static func pendingPlan(current: UFPlan, willAutoRenew: Bool, autoRenewProductID: String?) -> UFPlan? {
        guard current != .free, willAutoRenew, let id = autoRenewProductID, let next = UFPlan(productID: id),
              next != current else { return nil }
        return next
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
    private var storePlan: UFPlan = .free
    private var serviceTrial: UFPlan?
    /// gueltiger Tarif laeuft in der Gratiswoche
    @Published private(set) var inIntroOffer = false
    /// Ablauf bzw. naechste Verlaengerung des gueltigen Abos
    @Published private(set) var expiresAt: Date?
    /// zur naechsten Verlaengerung vorgemerkter kleinerer Tarif (Downgrade), sonst nil
    @Published private(set) var pendingPlan: UFPlan?
    /// verlaengert sich das gueltige Abo? false = gekuendigt, laeuft bis `expiresAt`; nil = unbekannt bzw. Free
    @Published private(set) var willRenew: Bool?
    /// Abo noch nicht geprueft (erster Abruf von currentEntitlements laeuft)
    @Published private(set) var loading = true
    /// zaehlt verifizierte Transaktionen (Kauf, Transaction.updates wie Verlaengerung oder freigegebene Kaufanfrage);
    /// die Tarifwahl liest daraufhin den Anspruch auf die Probewoche neu
    @Published private(set) var transactionCount = 0

    /// Server-Pruefung der signierten Transaktion (JWS, ab V2 ueber `UFBillingServiceLink`). In V1 nie gesetzt: das
    /// iPad hat kein Konto beim Dienst, der Tarif kommt nur aus StoreKit.
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

    /// Tarif neu aus Transaction.currentEntitlements bestimmen (nur verifizierte Transaktionen, hoechster gueltiger
    /// Tarif der Abo-Gruppe), dazu Verlaengerung und vorgemerkter Wechsel aus der RenewalInfo
    /// Laufende Probe des Studora-Kontos (docs/ABO-SYSTEM.md 3a): gilt zusaetzlich zum App-Store-Kauf, solange der
    /// Dienst sie meldet; nur im Speicher, ohne Antwort des Dienstes bleibt der Kauf allein massgeblich
    func useServiceTrial(_ trial: UFPlan?) {
        serviceTrial = trial
        plan = max(storePlan, trial ?? .free)
    }

    func refresh() async {
        var entries: [UFEntitlementEntry] = []
        var active: [String: StoreKit.Transaction] = [:]
        let now = Date()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            let e = UFEntitlementEntry(t)
            entries.append(e)
            if UFEntitlementResolver.isActive(e, now: now) { active[t.productID] = t }
        }
        var p = UFEntitlementResolver.plan(from: entries, now: now)
        var renewal: (willAutoRenew: Bool, productID: String?)?
        if let id = p.productID, let t = active[id] { renewal = await Self.renewal(of: t) }
        #if DEBUG
        // Startargument -UFPlan free|plus|pro_connect|pro_ai: fester Tarif fuer Simulator-Ablaeufe ohne
        // StoreKit-Testkonfiguration
        if let forced = DebugLaunch.forcedPlan() { p = forced; renewal = nil }
        #endif
        storePlan = p
        plan = max(p, serviceTrial ?? .free)
        inIntroOffer = UFEntitlementResolver.inIntroOffer(entries, plan: p, now: now)
        expiresAt = p.productID.flatMap { active[$0]?.expirationDate }
        willRenew = renewal?.willAutoRenew
        pendingPlan = renewal.flatMap {
            UFEntitlementResolver.pendingPlan(current: p, willAutoRenew: $0.willAutoRenew, autoRenewProductID: $0.productID)
        }
        loading = false
    }

    /// Verlaengerung des gueltigen Abos (RenewalInfo der Abo-Gruppe): verlaengert es sich, und mit welchem Produkt?
    private static func renewal(of t: StoreKit.Transaction) async -> (willAutoRenew: Bool, productID: String?)? {
        guard let group = t.subscriptionGroupID,
              let statuses = try? await Product.SubscriptionInfo.status(for: group) else { return nil }
        for s in statuses {
            guard case .verified(let latest) = s.transaction, latest.originalID == t.originalID,
                  case .verified(let info) = s.renewalInfo else { continue }
            return (info.willAutoRenew, info.autoRenewPreference)
        }
        return nil
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
                .sheet(isPresented: $sheet) { UFPlanSheet(required: access.requiredPlan, close: { sheet = false }) }
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
                Text(p.name).ufFont(10.4, 650, lh: 1.2)
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

/// Karte an Stelle einer gesperrten Ansicht: Schloss, was die Funktion kann, "Mit Studora Plus freischalten".
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
                            UFButton("Mit \(p.name) freischalten", icon: "star", kind: .primary, size: .small) { open() }
                                .padding(.top, 8)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .sheet(isPresented: $sheet) { UFPlanSheet(required: ent.access(feature).requiredPlan, close: { sheet = false }) }
        }
    }

    static func message(_ f: UFFeature, access: UFAccess) -> String {
        switch access {
        case .allowed: return ""
        case .comingSoon:
            if f.isV2 { return "Kommt mit der nächsten Version von Studora." }
            let base = f.detail.map { "\($0). " } ?? ""
            if f.isCommunity { return base + "Bald verfügbar – die Community folgt mit einem Update." }
            return base + "Bald verfügbar – kommt mit einem Update direkt auf dein iPad."
        case .locked(let p):
            let base = f.detail.map { "\($0). " } ?? ""
            return base + "Enthalten ab \(p.name). Deine Notizen und Daten bleiben in jedem Tarif erhalten."
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

/// Sperrkarte als Blatt, z. B. im Editor (Schreiben, geteilte Ansicht): Schloss, Umfang, "Mit Studora Plus freischalten".
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

/// Tarifwahl als Blatt (aus Sperren heraus); `required` = Tarif, der die gesperrte Funktion freischaltet
struct UFPlanSheet: View {
    var required: UFPlan?
    let close: () -> Void

    var body: some View {
        NavigationStack {
            PlanPickerView(context: .upgrade(required), onDone: close)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: close) } }
        }
    }
}
