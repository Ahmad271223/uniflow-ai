import StoreKit
import UniFlowCore
import SwiftUI

// Funktionen der iPad-App und ihre Tarife (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 4; docs/ABO-SYSTEM.md).
// Entscheidung des Inhabers vom 04.11.2026: drei StudiNow-Tarife Free, Plus, Pro AI (Plans.swift, Vertrag plans.json).
// Pro AI enthaelt alles aus Plus; auf dem iPad gehoeren eigene Karteikarten zu Plus, seit 05.11.2026 auch die
// Community (Lesen; Free ohne Community, "Community ab Plus"). Pro AI bringt die StudiNow-KI (KI-Hilfe, KI-Karteikarten,
// Wochentests) und den Notizen-Abgleich ueber das StudiNow-Konto (Dienst app.studinow.app, Stand 07.11.2026). Was es auf
// dem iPad nicht gibt (Testbibliothek, Lernstatistik, Empfehlungen, eigenes ChatGPT), steht auf keiner Tarifkarte, auch
// nicht als "in Vorbereitung". Die Berechtigung entsteht auf dem Geraet aus Transaction.currentEntitlements (von StoreKit signiert
// und geprueft, hoechster gueltiger Tarif). Dazu die Probe auf dem iPad (Entscheidung 04.11.2026, LocalTrial.swift):
// 7 Tage alles wie Pro AI ohne Zahlungsdaten, Vorrang Dienst > App Store > Probe > Free (UFPlanPrecedence). Die
// Pruefung im Dienst ist vorbereitet und abgeschaltet (BillingServiceLink.swift, V2).

// MARK: - Funktionen

/// Funktionen aus der Tabelle in Abschnitt 4. Jede Zeile der Tabelle ist genau ein Fall; die Reihenfolge ist die
/// Reihenfolge auf den Tarifkarten.
enum UFFeature: String, CaseIterable, Identifiable {
    // Free
    case studipSync          // Mit Apple anmelden, Stud.IP verbinden, Kurse/Ordner/neue Dateien abgleichen
    case readDocuments       // Dokumente oeffnen, lesen und durchsuchen, Bibliothek, Ordner, Favoriten
    case modulesTimetable    // Meine Module (Faecher geordnet), Stundenplan ansehen
    case studyCalendar       // Lernkalender ansehen, Aufgaben abhaken
    case studyPlanning       // Lernbloecke selbst eintragen, verschieben, nachholen, "Woche retten" (ohne Generator)
    case timer               // Stoppuhr, Countdown, Pomodoro
    case viewNotes           // vorhandene Notizen ansehen und als PDF exportieren
    case uniGrades           // Uni & Noten (QIS bzw. LSF auf dem Geraet, F4), Free
    case ownChatGPT          // Eigenes ChatGPT ueber den eigenen OpenAI-Schluessel (OpenAIKeyLink, Einstellungen → Erweitert,
                             // 07.11.2026): Fragen zu den Unterlagen, Karteikarten, Wochentests und KI-Lernplan in jedem
                             // Tarif (Entscheidung 05.11.2026; Vertrag chatgpt_connection_premium ab Free)
    // Plus
    case pencilWriting       // Stift, Marker, Radierer, Lasso, Seiten einfuegen/drehen/Papierkorb, Lesezeichen
    case communityRead       // Community lesen (can_read_community, ab Plus seit 05.11.2026, vorher Free): Loesungen
                             // anderer finden, laden, im Editor ansehen, empfangene Dateien oeffnen, melden,
                             // blockieren, Lerngruppen beitreten. Eigene Veroeffentlichungen zurueckziehen geht in
                             // jedem Tarif (Herabstufen: nichts wird geloescht)
    case shareSolutions      // Eigene Loesungen teilen (can_share_solutions): als Datei, in der Community
                             // veroeffentlichen, Pseudonym, Lerngruppen anlegen
    case splitView           // Uebung und Skript nebeneinander, Skriptsuche zur Aufgabe
    case flashcards          // eigene Karteikarten mit Wiederholung
    case dueReminders        // Erinnerungen an Abgaben, Tests und Klausuren (Mitteilungen; can_use_due_reminders, ab Plus
                             // seit 11.11.2026, vorher Free). Die Fristen-Liste bleibt in jedem Tarif
    case autoPlan            // Lernplan automatisch erstellen (GeneratePlanDialog, POST /api/calendar/generate, auch
                             // "Lerneinheit automatisch einplanen", KI-Lernplan POST /api/calendar/ai-suggest): Plus
                             // (Inhaber 07.11.2026); Ausnahme mit eigenem ChatGPT (eigener OpenAI-Schluessel arbeitet,
                             // `Entitlements.ownChatGPTConnected`): dann auch in Free (UFFeatureMatrix.access `ownChatGPT`)
    // Pro AI: StudiNow-KI und Abgleich ueber das StudiNow-Konto (UFDeviceSupport.withAccount). Die KI selbst gibt
    // `StudiNowAIAccess` frei (Pro AI bzw. Probe und angemeldet), die Matrix sagt nur, ab welchem Tarif.
    case aiHelp              // KI-Hilfe im Editor: Seite, markierter Bereich, ganzes Dokument (TutorPanel, TutorDocumentRun)
    case aiFlashcards        // Karteikarten aus einem Dokument (FlashcardComposer, POST /api/ai/flashcards)
    case weeklyTests         // Wochentest erstellen (QuizComposer, automatische Wochentests): braucht eine KI, auf dem
                             // iPad die StudiNow-KI, darum Pro AI (07.11.2026; vorher Plus mit dem eigenen ChatGPT, das aus
                             // ist). Wird das eigene ChatGPT freigegeben, hier neu entscheiden.
    case deviceSync          // Notizen auf allen Geraeten (DeviceSync G2 mit StudiNow-Konto, can_sync_annotations)
    // ab V2
    case uniflowEditor

    var id: String { rawValue }

    /// kleinster Tarif, in dem die Funktion enthalten ist (hoehere Tarife enthalten sie auch). Fuer Funktionen, die
    /// ein Recht des Vertrags umsetzen (`UFEntitlement.onDevice`), gleich dessen `from` (PlanContractTests).
    var minimumPlan: UFPlan {
        switch self {
        case .studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes,
             .uniGrades, .ownChatGPT:
            return .free
        case .communityRead, .pencilWriting, .shareSolutions, .splitView, .flashcards, .autoPlan, .uniflowEditor,
             .dueReminders:
            return .plus
        case .aiHelp, .aiFlashcards, .weeklyTests, .deviceSync:
            return .proAI
        }
    }

    /// Teil der Community (beide haengen am iCloud-Container des Builds)
    var isCommunity: Bool { self == .communityRead || self == .shareSolutions }

    /// erst ab V2 vorhanden (UniFlow-Editor)
    var isV2: Bool { self == .uniflowEditor }

    /// Bezeichnung auf der Abo-Seite und in der Sperrkarte
    var title: String {
        switch self {
        case .studipSync: return "Stud.IP verbinden und abgleichen"
        case .readDocuments: return "Dokumente öffnen, lesen und durchsuchen"
        case .modulesTimetable: return "Meine Module und Stundenplan"
        case .studyCalendar: return "Lernkalender ansehen, Aufgaben abhaken"
        case .studyPlanning: return "Lernblöcke selbst planen"
        case .timer: return "Zeitmesser (Stoppuhr, Countdown, Pomodoro)"
        case .viewNotes: return "Notizen ansehen und als PDF exportieren"
        case .uniGrades: return "Uni & Noten"
        case .ownChatGPT: return "Eigenes ChatGPT verbinden"
        case .communityRead: return "Community lesen, beitreten und mitmachen"
        case .pencilWriting: return UFDevice.adapt("Schreiben mit Apple Pencil")
        case .shareSolutions: return "Eigene Lösungen teilen"
        case .splitView: return "Übung und Skript nebeneinander"
        case .flashcards: return "Eigene Karteikarten mit Wiederholung"
        case .dueReminders: return "Erinnerungen an Abgaben und Klausuren"
        case .autoPlan: return "Lernplan automatisch erstellen"
        case .aiHelp: return "KI-Hilfe zu deinen Unterlagen"
        case .aiFlashcards: return "Karteikarten aus deinen Unterlagen"
        case .weeklyTests: return "Wochentests erstellen"
        case .deviceSync: return "Notizen auf allen deinen Geräten"
        case .uniflowEditor: return "StudiNow-Editor"
        }
    }

    /// Zusatz unter dem Titel (Umfang der Zeile aus Abschnitt 4)
    var detail: String? {
        switch self {
        case .modulesTimetable: return "Deine Fächer geordnet nach Modulen"
        case .studyPlanning: return "Eintragen, verschieben, nachholen, „Woche retten“"
        case .uniGrades: return "Notenspiegel aus \(UFReleaseUniversities.gradePlatforms) direkt in der App"
        case .ownChatGPT: return "Mit deinem eigenen OpenAI-Schlüssel: Fragen zu deinen Unterlagen und Lernplan-Vorschläge – in jedem Tarif, abgerechnet über dein OpenAI-Konto"
        case .communityRead: return "Lösungen anderer finden, laden und im Editor ansehen, melden und blockieren, Lerngruppen beitreten"
        case .pencilWriting: return "Stift, Marker, Radierer, Lasso, Seiten einfügen, drehen und in den Papierkorb legen, Lesezeichen"
        case .shareSolutions: return "Als verschlüsselte Datei weitergeben und in der Community veröffentlichen, Lerngruppen anlegen"
        case .splitView: return "Mit Skriptsuche zur Aufgabe"
        case .flashcards: return "Selbst angelegt, Wiederholung nach dem Leitner-System"
        case .dueReminders: return "Mitteilung 3 Tage, 1 Tag und am Morgen vor Abgaben, Tests und Klausuren"
        case .autoPlan: return "Lernslots in deinen freien Zeiten"
        case .aiHelp: return "Zur Seite, zu einem markierten Bereich oder zum ganzen Dokument, z. B. „Ganze Vorlesung erklären“ und „Alle Aufgaben erklären“"
        case .aiFlashcards: return "Die StudiNow-KI schlägt Karten zu einem Dokument vor, du prüfst sie vor dem Übernehmen"
        case .weeklyTests: return "Aus deinen Unterlagen, mit der StudiNow-KI"
        case .deviceSync: return "Abgleich über dein StudiNow-Konto"
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
        case .ownChatGPT: return "sparkles"
        case .communityRead: return "search"
        case .pencilWriting: return "pencil"
        case .shareSolutions: return "users"
        case .splitView: return "columns"
        case .flashcards: return "cards"
        case .dueReminders: return "bell"
        case .autoPlan: return "calendar"
        case .aiHelp: return "sparkles"
        case .aiFlashcards: return "cards"
        case .weeklyTests: return "exam"
        case .deviceSync: return "refresh"
        case .uniflowEditor: return "pen"
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

    /// Community-Funktionen (Lesen und Teilen ab Plus, Entscheidung 05.11.2026): eigene Loesung als Datei teilen (nur eigene Notizen,
    /// verschluesselt), empfangene Loesungen im Editor ansehen und die Online-Community ueber CloudKit
    /// (docs/LOESUNGEN-TEILEN.md, Abschnitt 7). Ohne iCloud-Container im Build meldet der Dienst selbst
    /// "nicht verfuegbar"; der Dateiweg bleibt.
    static let communityAvailable = true

    /// Eigene Karteikarten ohne PC: Anlegen, Wiederholen und Loeschen im lokalen Backend (`FlashcardEndpoints`, M8) und
    /// auf der Seite "Karteikarten" (CardsPage), Teil von Plus. Vorher "bald" auf der Plus-Karte (nichts vortaeuschen,
    /// Richtlinie 3.1.2); der Schalter bleibt fuer Tests der Matrix.
    static let flashcardsOnDevice = true

    /// - Parameter ownChatGPT: eigenes ChatGPT arbeitet (eigener OpenAI-Schluessel eingetragen und eingeschaltet,
    ///   `Entitlements.ownChatGPTConnected`; das Abo erst nach der Freigabe durch OpenAI). Ausnahme des Inhabers vom
    ///   07.11.2026: dann gibt es den automatischen Lernplan (auch den KI-Lernplan) auch ohne Plus.
    static func access(_ f: UFFeature, plan: UFPlan, uniGrades: Bool = uniGradesOnDevice,
                       community: Bool = communityAvailable, flashcards: Bool = flashcardsOnDevice,
                       ownChatGPT: Bool = false) -> UFAccess {
        if f.isV2 || (f == .uniGrades && !uniGrades) || (f.isCommunity && !community) || (f == .flashcards && !flashcards) {
            return .comingSoon
        }
        if f == .autoPlan && ownChatGPT { return .allowed }
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
        UFFeature.allCases.filter { $0.minimumPlan == plan && ($0 != .timer || StudyTimer.isEnabled) }
    }

    /// Herabstufen (Abschnitt 4, "Regeln"): Notizen bleiben vollstaendig erhalten, lesbar und exportierbar;
    /// nur Bearbeiten wird gesperrt. Es wird nie etwas geloescht.
    static func notes(plan: UFPlan) -> UFNoteAccess {
        UFNoteAccess(canView: true, canExport: true, canEdit: access(.pencilWriting, plan: plan).isAllowed)
    }

    /// Herabstufen bei Karteikarten (Entscheidung 04.11.2026, wie Notizen): eigene Stapel und Karten bleiben in jedem
    /// Tarif sichtbar (auch nach der Probe); Ueben, Anlegen, Bearbeiten, Teilen und Uebernehmen ab Plus.
    static func flashcards(plan: UFPlan) -> UFFlashcardAccess {
        UFFlashcardAccess(canView: true, canEdit: access(.flashcards, plan: plan).isAllowed)
    }
}

// UFAdoptQuota (Kontingent "Karteikarten-Stapel von StudiNow") steht seit 08.11.2026 in Services/AdoptQuota.swift.

/// Was mit vorhandenen Karteikarten im aktuellen Tarif moeglich ist
struct UFFlashcardAccess: Equatable {
    let canView: Bool
    /// anlegen, bearbeiten, loeschen, Stapel, teilen, uebernehmen, Wochenstapel holen
    let canEdit: Bool
    /// "Heute fällig", Wiederholen, Trainer (gehoert zu Plus wie das Bearbeiten)
    var canPractise: Bool { canEdit }

    /// ruhiger Hinweis ueber der Liste im Lesemodus
    static let readOnlyHint = "Mit Plus übst und bearbeitest du deine Karten wieder."
}

/// Was mit vorhandenen Notizen im aktuellen Tarif moeglich ist
struct UFNoteAccess: Equatable {
    let canView: Bool
    let canExport: Bool
    let canEdit: Bool
}

// MARK: - Inhalt der Tarifkarten

/// Eine Zeile auf einer Tarifkarte (immer "enthalten", mit Haken)
struct UFPlanCardRow: Equatable {
    let title: String
    var detail: String?
    var icon: String
}

/// Was die Tarifkarten zeigen (ohne StoreKit, testbar). Regel des Inhabers: nur zeigen, was im Vertrag `available` ist
/// und auf dem iPad wirklich geht (auf dem Geraet oder mit StudiNow-Konto ueber den Dienst). Was es auf dem iPad nicht
/// gibt, steht gar nicht da, auch nicht als "in Vorbereitung" (App Review 07.11.2026: keine Versprechen).
enum UFPlanCard {
    /// enthalten: Funktionen, die der Tarif mehr bietet als der naechstkleinere
    static func included(_ plan: UFPlan) -> [UFPlanCardRow] {
        UFFeatureMatrix.added(in: plan).filter { !$0.isV2 && UFFeatureMatrix.access($0, plan: plan) == .allowed }.map {
            UFPlanCardRow(title: $0.title, detail: $0.detail, icon: $0.icon)
        }
    }

    /// Kurzbeschreibung auf der Karte. Nicht wortgleich mit `UFPlan.tagline` (Vertrag): dort stehen fuer Plus die
    /// Wochentests und fuer Pro AI das eigene ChatGPT, auf dem iPad gehoeren Wochentests zu Pro AI und ChatGPT ist aus.
    static func tagline(_ plan: UFPlan) -> String? {
        guard UFFeatureMatrix.hasAvailableExtras(in: plan) else { return nil }
        switch plan {
        case .free: return plan.tagline
        case .plus: return UFDevice.adapt("Mit Apple Pencil auf deinen Unterlagen schreiben, Karteikarten und Community")
        case .proAI: return "Die StudiNow-KI für deine Unterlagen inklusive"
        }
    }

    /// Ueberschrift ueber den Zeilen
    static func intro(_ plan: UFPlan) -> String {
        guard let lower = plan.lower else { return "Alles für den Uni-Alltag:" }
        return included(plan).isEmpty ? "Alles aus \(lower.name)." : "Alles aus \(lower.name), dazu:"
    }
}

// MARK: - Tarif aus den Transaktionen

/// Das Noetige aus einer StoreKit-Transaktion (testbar ohne StoreKit)
struct UFEntitlementEntry: Equatable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded = false
    /// Ablaufdatum vorbei, Apple zaehlt das Abo aber noch: Ende der Kulanzfrist (Billing Grace Period,
    /// `RenewalState.inGracePeriod`) bzw. kurze Frist, solange die Verlaengerung unterwegs ist (`.subscribed`)
    var graceUntil: Date?
}

extension UFEntitlementEntry {
    init(_ t: StoreKit.Transaction) {
        productID = t.productID
        expirationDate = t.expirationDate
        revocationDate = t.revocationDate
        isUpgraded = t.isUpgraded
    }
}

enum UFEntitlementResolver {
    /// gueltig = nicht erstattet/widerrufen, nicht abgelaufen (oder in der Kulanzfrist), nicht durch ein hoeheres Abo
    /// ersetzt
    static func isActive(_ e: UFEntitlementEntry, now: Date) -> Bool {
        guard e.revocationDate == nil, !e.isUpgraded else { return false }
        if let exp = e.expirationDate, exp <= now { return (e.graceUntil ?? exp) > now }
        return true
    }

    /// Ende des Rechts: Ende der Kulanzfrist, sonst Ablauf des Zeitraums (nil = unbefristet)
    static func rightsEnd(_ e: UFEntitlementEntry) -> Date? { e.graceUntil ?? e.expirationDate }

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
}

// MARK: - Berechtigung zur Laufzeit

/// Aktueller Tarif der App. Beobachtet Transaction.updates (Kaeufe auf anderen Geraeten, Verlaengerung,
/// Kuendigung, Erstattung) und schliesst neue Transaktionen ab. Eine Instanz fuer die ganze App: `shared`.
@MainActor
final class Entitlements: ObservableObject {
    static let shared = Entitlements()

    /// wirksamer Tarif: Dienst > App Store > Probe auf dem iPad > Free (`UFPlanPrecedence`)
    @Published private(set) var plan: UFPlan = .free
    /// gekaufter Tarif aus Transaction.currentEntitlements (Free ohne Abo); die Tarifkarten richten sich danach, nicht
    /// nach der Probe
    @Published private(set) var purchasedPlan: UFPlan = .free
    private var serviceTrial: UFPlan?
    /// Resttage und Ende der Probe des Kontos laut Dienst (nur Anzeige, `UFShownTrial`)
    @Published private(set) var serviceTrialDaysLeft = 0
    @Published private(set) var serviceTrialEndsAt: Date?
    /// Probe auf dem iPad ohne Dienst (UFLocalTrial); nil vor der Anmeldung oder wenn noch nicht ermittelt
    @Published private(set) var localTrial: UFLocalTrial.State?
    /// "Bei Free bleiben" nach dem Ende der Probe wurde beantwortet (Hinweis auf der Uebersicht nicht mehr zeigen)
    @Published private(set) var localTrialChoiceMade = false
    private var localTrialScope: String?
    private var localTrialRecords: (any UFTrialRecording)?
    /// Startargument -UFPlan (nur Debug): fester Tarif, Proben zaehlen nicht
    private var planIsForced = false
    /// Ablauf bzw. naechste Verlaengerung des gueltigen Abos
    @Published private(set) var expiresAt: Date?
    /// Ende der Kulanzfrist, solange Apple das Abo nach gescheiterter Zahlung weiter zaehlt (sonst nil)
    @Published private(set) var graceUntil: Date?
    /// Ende des Rechts aus dem Kauf (Kulanzfrist, sonst Ablauf); dann prueft die App neu (Audit P44-11)
    private var rightsEnd: Date?
    /// Wecker fuer das naechste Ende ohne Ereignis (Probe, Abo), `UFPlanExpiry`
    private var expiryCheck: Task<Void, Never>?
    /// zur naechsten Verlaengerung vorgemerkter kleinerer Tarif (Downgrade), sonst nil
    @Published private(set) var pendingPlan: UFPlan?
    /// Zahlweise des gekauften Abos (jaehrlich; monatlich nur bei einem frueheren Monatsabo); nil ohne Abo
    @Published private(set) var purchasedBilling: UFBilling?
    /// verlaengert sich das gueltige Abo? false = gekuendigt, laeuft bis `expiresAt`; nil = unbekannt bzw. Free
    @Published private(set) var willRenew: Bool?
    /// Abo noch nicht geprueft (erster Abruf von currentEntitlements laeuft)
    @Published private(set) var loading = true
    /// zaehlt verifizierte Transaktionen (Kauf, Transaction.updates wie Verlaengerung oder freigegebene Kaufanfrage)
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

    deinit { updates?.cancel(); expiryCheck?.cancel() }

    func access(_ f: UFFeature) -> UFAccess {
        UFFeatureMatrix.access(f, plan: plan, ownChatGPT: ownChatGPTConnected)
    }

    /// eigenes ChatGPT arbeitet (setzt `OpenAIKeyLink.refresh`, sobald der eigene OpenAI-Schluessel eingetragen und
    /// eingeschaltet ist): schaltet den automatischen Lernplan auch ohne Plus frei (`UFFeature.autoPlan`)
    @Published var ownChatGPTConnected = false

    func allows(_ f: UFFeature) -> Bool { access(f).isAllowed }

    var notes: UFNoteAccess { UFFeatureMatrix.notes(plan: plan) }

    var flashcards: UFFlashcardAccess { UFFeatureMatrix.flashcards(plan: plan) }

    /// Tarif neu aus Transaction.currentEntitlements bestimmen (nur verifizierte Transaktionen, hoechster gueltiger
    /// Tarif der Abo-Gruppe), dazu Verlaengerung und vorgemerkter Wechsel aus der RenewalInfo
    /// Laufende Probe des StudiNow-Kontos (docs/ABO-SYSTEM.md 3a): gilt zusaetzlich zum App-Store-Kauf, solange der
    /// Dienst sie meldet; nur im Speicher, ohne Antwort des Dienstes bleibt der Kauf allein massgeblich
    /// `daysLeft`/`endsAt`: Resttage und Ende dieser Probe laut Dienst, nur fuer die Anzeige (`shownTrial`)
    func useServiceTrial(_ trial: UFPlan?, daysLeft: Int = 0, endsAt: Date? = nil) {
        serviceTrial = trial
        serviceTrialDaysLeft = trial == nil ? 0 : daysLeft
        serviceTrialEndsAt = trial == nil ? nil : endsAt
        recompute()
    }

    /// Stand des Kontos beim Dienst (`StudoraAccountLink.planStatus`): dessen laufende Probe fuer Freischaltung und Anzeige
    func useServiceStatus(_ s: StudoraAccount.PlanStatus?) {
        useServiceTrial(s?.trialPlan.flatMap(UFPlan.init(rawValue:)), daysLeft: s?.trialDaysLeft ?? 0, endsAt: s?.trialEndsAt)
    }

    // MARK: Probe auf dem iPad (ohne Dienst)

    /// Probe fuer diese Apple-ID beginnen bzw. ihren Stand laden (UFLocalTrial: Schluesselbund und iCloud, der fruehere
    /// Beginn gilt). Aufruf bei jeder Anmeldung; einmal je Apple-ID, nie verlaengerbar.
    func beginLocalTrial(userID: String, records: any UFTrialRecording = UFTrialRecordStore(), now: Date = Date()) {
        let scope = UFLocalTrial.scope(userID: userID)
        localTrialScope = scope
        localTrialRecords = records
        localTrial = UFLocalTrial.begin(scope: scope, records: records, now: now)
        localTrialChoiceMade = records.load(scope).choiceMade
        recompute(now: now)
    }

    /// Stand der Probe setzen, ohne etwas zu speichern (Abmeldung: nil; Tests und Vorschauen)
    func useLocalTrial(startedAt: Date?, now: Date = Date()) {
        localTrial = startedAt.map { UFLocalTrial.state(startedAt: $0, now: now) }
        if startedAt == nil { localTrialScope = nil; localTrialRecords = nil; localTrialChoiceMade = false }
        recompute(now: now)
    }

    /// Resttage neu rechnen (Vordergrund, Tageswechsel, Wecker `UFPlanExpiry`); am Ende der Probe faellt der Tarif von
    /// selbst auf Free. Mit Ablage ueber `UFLocalTrial.begin` (Uhr verstellt, Ende gesehen: Audit P44-12). Ist das Recht
    /// aus dem Kauf vorbei, liest die App die Transaktionen neu (Apple meldet den Ablauf nicht, Audit P44-11).
    func refreshLocalTrial(now: Date = Date()) {
        if let t = localTrial {
            if let scope = localTrialScope, let records = localTrialRecords {
                localTrial = UFLocalTrial.begin(scope: scope, records: records, now: now)
            } else {
                localTrial = t.updated(now: now)
            }
        }
        recompute(now: now)
        if !planIsForced, let end = rightsEnd, end <= now { Task { await refresh() } }
    }

    /// "Bei Free bleiben" nach dem Ende der Probe: der Hinweis verschwindet, Free bleibt nutzbar
    func stayOnFreeAfterLocalTrial() {
        localTrialChoiceMade = true
        if let scope = localTrialScope { localTrialRecords?.markChoice(scope) }
    }

    /// laufende Probe auf dem iPad ohne Kauf (die Tarifseite markiert dann keinen Tarif als "Aktueller Tarif"); nil mit
    /// gekauftem Abo, vor der Anmeldung, nach der Probe und waehrend des ersten Abrufs
    var runningLocalTrial: UFLocalTrial.State? {
        guard !loading, !planIsForced, purchasedPlan == .free, let t = localTrial, t.isActive else { return nil }
        return t
    }

    /// angezeigte Probe (Entscheidung 09.11.2026, `UFShownTrial`): dieselbe Quelle wie die Freischaltung; Seitenleiste,
    /// Einstellungen, Probe-Karte und Tarifseite zeigen sie. Mit -UFPlan zaehlen Proben nicht, dann keine.
    var shownTrial: UFShownTrial? {
        guard !planIsForced else { return nil }
        return UFShownTrial.make(service: serviceTrial, serviceDaysLeft: serviceTrialDaysLeft, serviceEndsAt: serviceTrialEndsAt,
                          local: localTrial, purchased: purchasedPlan)
    }

    /// Tarifseite: die angezeigte Probe, erst nach dem ersten Abruf
    var runningTrial: UFShownTrial? { loading ? nil : shownTrial }

    /// Beschriftung fuer den Tarif in den Einstellungen: waehrend der angezeigten Probe (Konto, sonst iPad ohne Kauf)
    /// deren Resttage, sonst der Tarif
    var statusLabel: String {
        shownTrial.map { UFTrialTexts.running($0.daysLeft) } ?? plan.name
    }

    /// wirksamen Tarif aus den Quellen bestimmen (UFPlanPrecedence); mit -UFPlan nur der feste Tarif. Danach den
    /// Wecker fuer das naechste Ende stellen (`now` = Uhr des Aufrufers, in Tests fest)
    private func recompute(now: Date = Date()) {
        plan = planIsForced ? purchasedPlan
            : UFPlanPrecedence.effective(service: serviceTrial, purchased: purchasedPlan, localTrial: localTrial)
        scheduleExpiryCheck(now: now)
    }

    /// Wecker auf das naechste Ende ohne Ereignis (Probe, Abo, Kulanzfrist; Audit P44-11). Ein spaeter Wecker (Geraet
    /// schlief) schadet nicht: jeder Wechsel in den Vordergrund rechnet ohnehin neu und stellt ihn neu.
    private func scheduleExpiryCheck(now: Date) {
        expiryCheck?.cancel()
        expiryCheck = nil
        guard !planIsForced, let at = UFPlanExpiry.next(localTrial: localTrial, rightsEnd: rightsEnd, now: now) else { return }
        let wait = min(at.timeIntervalSince(now) + 1, 7 * 86_400)
        expiryCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshLocalTrial()
        }
    }

    func refresh() async {
        var entries: [UFEntitlementEntry] = []
        var active: [String: StoreKit.Transaction] = [:]
        var activeEntries: [String: UFEntitlementEntry] = [:]
        var graceProducts: Set<String> = []
        let now = Date()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            var e = UFEntitlementEntry(t)
            // Zeitraum vorbei, aber noch in currentEntitlements: Kulanzfrist oder Verlaengerung unterwegs? (Audit P44-14)
            var grace = false
            if let exp = t.expirationDate, exp <= now, t.revocationDate == nil, !t.isUpgraded,
               let still = await Self.stillEntitled(t, now: now) {
                e.graceUntil = still.until
                grace = still.grace
            }
            entries.append(e)
            if UFEntitlementResolver.isActive(e, now: now) {
                active[t.productID] = t
                activeEntries[t.productID] = e
                if grace { graceProducts.insert(t.productID) }
            }
        }
        var p = UFEntitlementResolver.plan(from: entries, now: now)
        var renewal: (willAutoRenew: Bool, productID: String?)?
        // gueltige Transaktion des Tarifs: Jahresabo oder frueheres Monatsabo (UFPlan.productIDs, 09.11.2026)
        var current = p.productIDs.lazy.compactMap { active[$0] }.first
        if let t = current { renewal = await Self.renewal(of: t) }
        #if DEBUG
        // Startargument -UFPlan free|plus|pro_ai (alt: pro_connect = pro_ai): fester Tarif fuer Simulator-Ablaeufe ohne
        // StoreKit-Testkonfiguration
        if let forced = DebugLaunch.forcedPlan() { p = forced; renewal = nil; current = nil; planIsForced = true }
        #endif
        purchasedPlan = p
        if let t = localTrial { localTrial = t.updated(now: now) }
        recompute()
        expiresAt = current?.expirationDate
        let currentEntry = current.flatMap { activeEntries[$0.productID] }
        graceUntil = current.flatMap { graceProducts.contains($0.productID) ? currentEntry?.graceUntil : nil }
        rightsEnd = currentEntry.flatMap(UFEntitlementResolver.rightsEnd)
        purchasedBilling = current.flatMap { UFBilling(productID: $0.productID) }
        willRenew = renewal?.willAutoRenew
        pendingPlan = renewal.flatMap {
            UFEntitlementResolver.pendingPlan(current: p, willAutoRenew: $0.willAutoRenew, autoRenewProductID: $0.productID)
        }
        loading = false
        scheduleExpiryCheck(now: now)
    }

    /// Zaehlt Apple ein Abo mit vorbeiem Ablaufdatum noch? Kulanzfrist (inGracePeriod): bis zu deren Ende (ohne Datum
    /// einen Tag, dann neu fragen). Noch "abonniert": die Verlaengerung ist unterwegs (Wecker am Periodenende kam vor
    /// der neuen Transaktion) - eine Stunde trauen, `Transaction.updates` bringt sie meist vorher. Sonst nil.
    private static func stillEntitled(_ t: StoreKit.Transaction, now: Date) async -> (until: Date, grace: Bool)? {
        // nur, wenn Apples neueste Transaktion der Gruppe noch genau diese ist (kein Wechsel, keine Verlaengerung da)
        guard let status = await t.subscriptionStatus, case .verified(let latest) = status.transaction, latest.id == t.id
        else { return nil }
        switch status.state {
        case .inGracePeriod:
            if case .verified(let info) = status.renewalInfo, let end = info.gracePeriodExpirationDate, end > now { return (end, true) }
            return (now.addingTimeInterval(86_400), true)
        case .subscribed:
            return (now.addingTimeInterval(3_600), false)
        default:
            return nil
        }
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

// MARK: - Schloss: gesperrte Funktionen sichtbar (Auftrag des Inhabers 12.11.2026)

/// "Alle Funktionen, die in Plus und Pro AI enthalten sind, sollen bei Free ein Schloss haben, und alle, die in Pro AI
/// enthalten sind und Plus nicht hat, bei Plus ein Schloss." Gesperrte Funktionen werden darum nicht ausgeblendet,
/// sondern ueberall gleich gezeigt: Schloss-Symbol mit "ab Plus" bzw. "ab Pro AI" (`UFLockMark`), VoiceOver
/// "gesperrt, ab Plus", Antippen oeffnet die Tarifwahl mit dem noetigen Tarif vorausgewaehlt (`UFPlanSheet(required:)`).
/// Was es im Build oder auf dem Geraet gar nicht gibt (`UFAccess.comingSoon`, V2, Community ohne iCloud-Container),
/// bleibt unsichtbar (App Review 3.1.2: nur zeigen, was es mit dem Tarif wirklich gibt).
enum UFLock {
    /// Kurzname ohne "StudiNow" ("Plus", "Pro AI")
    static func short(_ p: UFPlan) -> String {
        switch p {
        case .free: return "Free"
        case .plus: return "Plus"
        case .proAI: return "Pro AI"
        }
    }

    /// Text am Schloss: "ab Plus", "ab Pro AI"
    static func badge(_ p: UFPlan) -> String { "ab \(short(p))" }

    /// VoiceOver-Wert eines gesperrten Elements: "gesperrt, ab Plus"
    static func accessibilityValue(_ p: UFPlan) -> String { "gesperrt, \(badge(p))" }

    /// VoiceOver-Hinweis: was Antippen tut
    static let hint = "Öffnet die Tarifwahl."

    /// Menuepunkt bzw. Knopf mit Text: "Geteilt (ab Plus)"
    static func label(_ title: String, _ p: UFPlan) -> String { "\(title) (\(badge(p)))" }

    /// Symbol aller Schloesser (Menue, Leisten, Karten)
    static let symbol = "lock.fill"

    /// Schloss einer Funktion im Tarif: nil = frei (oder gar nicht vorhanden, dann zeigt die Stelle nichts)
    static func plan(_ f: UFFeature, plan: UFPlan, ownChatGPT: Bool = false) -> UFPlan? {
        UFFeatureMatrix.access(f, plan: plan, ownChatGPT: ownChatGPT).requiredPlan
    }

    /// Schloss einer KI-Stelle (KI-Hilfe, "KI fragen", "Bereich an KI", KI-Karteikarten, Wochentests): mit verbundener KI
    /// (eigenes ChatGPT in jedem Tarif oder StudiNow-KI) frei; sonst das Schloss "ab Pro AI", solange der Tarif die
    /// StudiNow-KI nicht enthaelt. Pro AI ohne Anmeldung ist kein Tarif-Thema (die Stelle zeigt den Weg zur Anmeldung).
    /// `offerHidden`: Pro AI ist nicht zu kaufen (nur Store-Bilder der Fassung nur mit Plus) – dann kein Schloss.
    static func ai(_ f: UFFeature = .aiHelp, plan: UFPlan, aiEnabled: Bool, offerHidden: Bool = false) -> UFPlan? {
        guard !aiEnabled, !offerHidden else { return nil }
        return Self.plan(f, plan: plan)
    }
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
    /// so weit ragt das Schild von oben in die Flaeche des gesperrten Elements (kleiner als jeder Innenabstand der Knoepfe)
    static let lockMarkInset: CGFloat = 4
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
                // Schild ueber der oberen Kante (Unterkante 4 pt in der Knopf-Flaeche, im Innenabstand), nie ueber dem
                // Text des Knopfs (vorher um 6 pt versetzt: verdeckte z. B. "Lernplan erstellen", Abnahme 07.11.2026)
                .overlay(alignment: .topTrailing) {
                    UFLockMark(access: access)
                        .alignmentGuide(.top) { d in d[.bottom] - Self.lockMarkInset }
                        .alignmentGuide(.trailing) { d in d[.trailing] - 6 }
                }
                .contentShape(Rectangle())
                .onTapGesture { if case .locked = access { open() } }
                .accessibilityElement(children: .combine)
                .accessibilityValue(access.requiredPlan.map(UFLock.accessibilityValue) ?? "")
                .accessibilityHint(access == .comingSoon ? "Bald verfügbar" : UFLock.hint)
                .sheet(isPresented: $sheet) { UFPlanSheet(required: access.requiredPlan, close: { sheet = false }) }
        }
    }

    private func open() {
        if let showPlans { showPlans() } else { sheet = true }
    }
}

/// kleines Schloss (bzw. "bald") an gesperrten Elementen: Schloss und "ab Plus" bzw. "ab Pro AI" (`UFLock.badge`)
struct UFLockMark: View {
    let access: UFAccess

    init(access: UFAccess) { self.access = access }

    /// Schloss fuer einen Tarif (nil: nichts)
    init(_ plan: UFPlan?) { access = plan.map { .locked($0) } ?? .allowed }

    var body: some View {
        switch access {
        case .allowed:
            EmptyView()
        case .locked(let p):
            HStack(spacing: 3) {
                Image(systemName: UFLock.symbol).font(.system(size: 9, weight: .bold))
                Text(UFLock.badge(p)).ufFont(10.4, 650, lh: 1.2).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(Capsule().fill(UF.accentFill))
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

/// Tarifwahl als Blatt, sobald ein Schloss angetippt wurde (`UFPlanSheet(required:)`). Die Stelle setzt `plan`; ohne
/// gesetzte Aktion `ufShowPlans` oeffnet das Blatt selbst.
private struct UFPlanSheetHost: ViewModifier {
    @Binding var plan: UFPlan?

    func body(content: Content) -> some View {
        content.sheet(item: $plan) { p in UFPlanSheet(required: p, close: { plan = nil }) }
    }
}

extension View {
    /// Blatt der Tarifwahl fuer ein angetipptes Schloss (`plan` = noetiger Tarif)
    func ufPlanSheet(_ plan: Binding<UFPlan?>) -> some View { modifier(UFPlanSheetHost(plan: plan)) }

    /// VoiceOver eines gesperrten Elements: "gesperrt, ab Plus", Hinweis "Öffnet die Tarifwahl." (nil: unveraendert)
    @ViewBuilder
    func ufLockAccessibility(_ plan: UFPlan?) -> some View {
        if let plan {
            accessibilityValue(UFLock.accessibilityValue(plan)).accessibilityHint(UFLock.hint)
        } else {
            self
        }
    }
}

/// Knopf einer gesperrten Funktion in Leisten und Listen: Inhalt gedimmt, Schloss "ab Plus" daneben, Antippen oeffnet die
/// Tarifwahl mit dem Tarif. Fuer Stellen, die sonst ganz fehlten (Werkzeugleiste ohne Plus, "KI fragen" ohne KI).
struct UFLockedButton<Label: View>: View {
    let plan: UFPlan
    let title: String
    var identifier: String?
    @ViewBuilder var label: () -> Label
    @State private var sheet: UFPlan?

    var body: some View {
        Button { sheet = plan } label: {
            HStack(spacing: 4) {
                label().opacity(0.5)
                UFLockMark(plan)
            }
            .frame(minWidth: 44, minHeight: 44)                             // Trefferflaeche mindestens 44 x 44 pt
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(UFLock.label(title, plan))
        .accessibilityLabel(title)
        .ufLockAccessibility(plan)
        .accessibilityIdentifier(identifier ?? "lock.\(title)")
        .ufPlanSheet($sheet)
    }
}

/// Karte an Stelle einer gesperrten Ansicht: Schloss, was die Funktion kann, "Mit StudiNow Plus freischalten".
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
            if f.isV2 { return "Kommt mit der nächsten Version von StudiNow." }
            let base = f.detail.map { "\($0). " } ?? ""
            if f.isCommunity { return base + "Bald verfügbar – die Community folgt mit einem Update." }
            return base + UFDevice.adapt("Bald verfügbar – kommt mit einem Update direkt auf dein iPad.")
        case .locked(let p):
            if f == .communityRead { return communityTeaser(p) }
            let base = f.detail.map { "\($0). " } ?? ""
            return base + "Enthalten ab \(p.name). Deine Notizen und Daten bleiben in jedem Tarif erhalten."
        }
    }

    /// Hinweis "Community ab Plus" (Entscheidung 05.11.2026): Free sieht keine Community, eigene Beitraege lassen sich
    /// trotzdem zurueckziehen (nichts wird geloescht)
    static func communityTeaser(_ p: UFPlan) -> String {
        "Community ab \(p.name): Lösungen anderer finden und im Editor ansehen, Fragen stellen, Lerngruppen beitreten. "
            + "Deine eigenen Beiträge bleiben erhalten und lassen sich jederzeit zurückziehen."
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

/// Sperrkarte als Blatt, z. B. im Editor (Schreiben, geteilte Ansicht): Schloss, Umfang, "Mit StudiNow Plus freischalten".
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
