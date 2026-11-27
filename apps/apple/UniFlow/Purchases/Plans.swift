import Foundation

// StudiNow-Tarife und Rechte aus dem gemeinsamen Vertrag (docs/ABO-SYSTEM.md, docs/PREISLISTE.md). Seit 26.11.2026
// (Entscheidung des Inhabers, neues Tarifmodell, docs/TARIFE-CREDITS-2026-11-26.md): StudiNow Free (0 EUR); StudiNow
// Plus mit allen Funktionen, 1,99 EUR im Monat (Auto-Abo) oder 39,99 EUR einmalig fuer 5 Jahre (nicht verlaengerndes
// Abo, `UFOffer`); StudiNow Pro AI, 39,99 EUR im Jahr = Plus und 120 Credits je Monat. Die StudiNow-KI geht in jedem
// Tarif nur mit Credits (Rechte mit `needsCredits`). Pro Connect gibt es nicht mehr; sein Schluessel `pro_connect` und
// sein Produkt gelten wie Pro AI (`UFPlan(rawValue:)`, `UFPlan(productID:)`, wie plans.LEGACY_PLANS im Dienst). Quelle
// aller Werte ist app/plans.py; tools/gen-plans-fixture.py schreibt daraus
// packages/shared-contracts/fixtures/plans/plans.json, und PlanContractTests prueft diese Tabelle Zeile fuer Zeile
// dagegen (Namen, Preise, Produkte, Angebote, Rechte je Tarif, Stand). Aendert sich plans.py, hier nachziehen.
//
// Was davon auf dem iPad wirklich geht, steht nicht hier, sondern in `UFEntitlement.onDevice` (unten) und in
// `UFFeature` (Entitlements.swift): auf dem Geraet, mit StudiNow-Konto ueber den Dienst (StudiNow-KI mit Credits,
// Notizen-Abgleich) oder gar nicht. Was gar nicht geht, zeigt keine Tarifkarte (auch nicht "in Vorbereitung").

// MARK: - Tarif

/// StudiNow-Tarif. Rohwerte wie die Schluessel in plans.json (`order`), auch fuer das Startargument -UFPlan.
enum UFPlan: String, CaseIterable, Comparable, Identifiable {
    case free
    case plus
    case proAI = "pro_ai"

    /// frueherer Tarif Pro Connect (bis 04.11.2026): gilt wie Pro AI, nur fuer alte Werte und Aufrufer
    static var proConnect: UFPlan { .proAI }

    /// alte Schluessel, die wie ein heutiger Tarif gelten (plans.LEGACY_PLANS)
    static let legacyKeys: [String: UFPlan] = ["pro_connect": .proAI]

    /// Schluessel aus plans.json, dem Dienst oder -UFPlan; `pro_connect` gilt wie Pro AI
    init?(rawValue: String) {
        switch rawValue {
        case "free": self = .free
        case "plus": self = .plus
        case "pro_ai": self = .proAI
        default:
            guard let p = UFPlan.legacyKeys[rawValue] else { return nil }
            self = p
        }
    }

    var id: String { rawValue }

    /// `rank` aus plans.json; jeder Tarif enthaelt alle Rechte der niedrigeren
    var rank: Int {
        switch self {
        case .free: return 0
        case .plus: return 1
        case .proAI: return 2
        }
    }

    static func < (a: UFPlan, b: UFPlan) -> Bool { a.rank < b.rank }

    /// Name wie in plans.json (`name`); der App-Name bleibt UniFlow
    var name: String {
        switch self {
        case .free: return "StudiNow Free"
        case .plus: return "StudiNow Plus"
        case .proAI: return "StudiNow Pro AI"
        }
    }

    /// Listenpreis in Cent (EUR) des Hauptprodukts aus plans.json (`price_cents` je `period`: Plus 1,99 im Monat, Pro AI
    /// 39,99 im Jahr). Nur fuer den Vertragsvergleich: angezeigt wird immer `Product.displayPrice` aus StoreKit
    /// (Richtlinie 3.1.2, Preis je Storefront).
    var priceCents: Int {
        switch self {
        case .free: return 0
        case .plus: return 199
        case .proAI: return 3999
        }
    }

    /// Zeitraum zu `priceCents` wie in plans.json (`period`): Free keiner
    var period: String? {
        switch self {
        case .free: return nil
        case .plus: return "month"
        case .proAI: return "year"
        }
    }

    /// Credits fuer die StudiNow-KI je Kalendermonat aus plans.json (`plans.<tarif>.credits`; 1 Credit = 1 Cent). Pro AI
    /// 120 seit 26.11.2026 (Inhaber), am 1. neu aufgeladen, der Rest verfaellt; Plus und Free keine (Plus kauft dazu).
    var monthlyCredits: Int {
        switch self {
        case .free, .plus: return 0
        case .proAI: return 120
        }
    }

    /// das Hauptprodukt des Tarifs (plans.json `apple_product_id`): Plus das Monatsabo, Pro AI das Jahresabo; Free keins.
    /// Alle angebotenen Produkte stehen in `UFOffer` (Plus zusaetzlich 5 Jahre einmalig).
    var productID: String? {
        switch self {
        case .free: return nil
        case .plus: return UFOffer.plusMonthly.productID
        case .proAI: return UFOffer.proAIYearly.productID
        }
    }

    /// angebotene Produkte des Tarifs in der Reihenfolge der Knoepfe
    var offers: [UFOffer] { UFOffer.allCases.filter { $0.plan == self } }

    /// alle Apple-Produkte, die als Kauf des Tarifs gelten: die Angebote und fruehere Produkte (`legacyProductIDs`)
    var productIDs: [String] {
        offers.map(\.productID) + UFPlan.legacyProductIDs.filter { $0.value == self }.map(\.key).sorted()
    }

    /// Kurzbeschreibung aus plans.json (`tagline`). Die Tarifkarte zeigt sie nur, wenn der Tarif auf dem iPad schon
    /// etwas Eigenes bietet (`UFFeatureMatrix.hasAvailableExtras`); sonst wuerde sie etwas versprechen.
    var tagline: String {
        switch self {
        case .free: return "Studium organisieren und Unterlagen lesen"
        case .plus: return "Alle Funktionen ohne KI – KI mit Credits dazu"
        case .proAI: return "Alles aus Plus und 120 Credits für die StudiNow-KI – jeden Monat neu"
        }
    }

    /// naechstkleinerer Tarif (Free: keiner)
    var lower: UFPlan? { UFPlan.allCases.last { $0 < self } }

    /// Produkte frueherer Angebote, die wie ein heutiger Tarif gelten (plans.LEGACY_PRODUCTS im Dienst): das Plus-
    /// Jahresabo 19,99 EUR (bis 26.11.2026), das Pro-AI-Monatsabo (bis 09.11.2026) und Pro Connect (bis 04.11.2026). Sie
    /// werden nicht mehr angeboten, ein Kauf damit gilt weiter.
    static let legacyProductIDs: [String: UFPlan] = ["de.uniflow.plus.yearly": .plus,
                                                     "de.uniflow.proai.monthly": .proAI,
                                                     "de.uniflow.proconnect.monthly": .proAI]

    /// Produkt -> Tarif; fremde und nicht mehr gueltige Produkte (z. B. das fruehere de.uniflow.pro.monthly) geben
    /// keinen Tarif
    init?(productID: String) {
        guard let p = UFOffer(productID: productID)?.plan ?? UFPlan.legacyProductIDs[productID] else { return nil }
        self = p
    }

    /// Abo-Tarife in der Reihenfolge der Karten
    static var paid: [UFPlan] { allCases.filter { $0.productID != nil } }
}

/// Ein angebotenes Apple-Produkt (plans.json `offers`, 26.11.2026). Reihenfolge = Reihenfolge der Knoepfe.
enum UFOffer: String, CaseIterable, Identifiable {
    /// StudiNow Plus, 1,99 EUR im Monat (Auto-Abo in der Gruppe "StudiNow")
    case plusMonthly = "de.uniflow.plus.monthly"
    /// StudiNow Plus, 39,99 EUR einmalig fuer 5 Jahre (nicht verlaengerndes Abo, StoreKit `.nonRenewable`)
    case plusFiveYears = "de.uniflow.plus.fuenfjahre"
    /// StudiNow Pro AI, 39,99 EUR im Jahr (Auto-Abo in der Gruppe "StudiNow")
    case proAIYearly = "de.uniflow.proai.yearly"

    /// `kind` in plans.json
    enum Kind: String {
        case autoRenewable = "auto_renewable"
        case nonRenewing = "non_renewing"
    }

    var id: String { rawValue }
    var productID: String { rawValue }

    init?(productID: String) { self.init(rawValue: productID) }

    var plan: UFPlan {
        switch self {
        case .plusMonthly, .plusFiveYears: return .plus
        case .proAIYearly: return .proAI
        }
    }

    var kind: Kind { self == .plusFiveYears ? .nonRenewing : .autoRenewable }

    /// Listenpreis in Cent (nur Vertrag und Tests; angezeigt wird der Preis aus StoreKit)
    var priceCents: Int {
        switch self {
        case .plusMonthly: return 199
        case .plusFiveYears, .proAIYearly: return 3999
        }
    }

    /// Zeitraum eines Abos (`period`): month, year; nil beim einmaligen Kauf
    var period: String? {
        switch self {
        case .plusMonthly: return "month"
        case .proAIYearly: return "year"
        case .plusFiveYears: return nil
        }
    }

    /// Laufzeit eines einmaligen Kaufs in Jahren (`years`); nil bei einem Abo
    var years: Int? { self == .plusFiveYears ? 5 : nil }

    /// Text aus plans.json (`label`)
    var label: String {
        switch self {
        case .plusMonthly: return "1,99 € im Monat"
        case .plusFiveYears: return "39,99 € einmalig für 5 Jahre"
        case .proAIYearly: return "39,99 € im Jahr"
        }
    }

    /// Ende eines einmaligen Kaufs: Kaufzeit plus `years` Jahre, wie `plans.offer_end` im Dienst (29.02. -> 28.02.,
    /// Kalender in UTC). nil bei einem Abo (dessen Ende meldet Apple).
    func end(purchasedAt: Date) -> Date? {
        guard kind == .nonRenewing, let years else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: purchasedAt)
        var e = c
        e.year = (c.year ?? 0) + years
        // 29. Februar in einem Nicht-Schaltjahr: 28. Februar (wie der Dienst, nicht der 1. Maerz)
        if c.month == 2, c.day == 29, let y = e.year, !(y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) { e.day = 28 }
        return cal.date(from: e)
    }
}

// MARK: - Was das iPad anbietet

/// Welche Tarife die App anbietet (Entscheidung des Inhabers vom 26.11.2026): StudiNow Free, Plus (Monatsabo oder 5 Jahre
/// einmalig) und Pro AI (Jahresabo), kein Apple-Einfuehrungsangebot, dafuer 7 Tage Probe wie Plus mit 25 Credits
/// (LocalTrial.swift). Die Pro-AI-Karte erscheint nur, wenn StoreKit das Produkt `de.uniflow.proai.yearly` liefert,
/// sonst zeigt die Seite nur Free und Plus. Pro Connect gibt es nicht mehr (Entscheidung 04.11.2026).
enum UFPlanCatalog {
    /// auf dem iPad waehlbar
    static let sellable: [UFPlan] = [.free, .plus, .proAI]

    /// Apple-Produkte, die die App laedt und anbietet (plans.json `offers`): Plus monatlich, Plus 5 Jahre, Pro AI jaehrlich
    static var sellableProductIDs: [String] { UFOffer.allCases.map(\.productID) }

    /// Tarife, deren Karte nur mit geliefertem Produkt erscheint (Pro AI: erst mit dem Dienst im Store)
    static let needsProduct: Set<UFPlan> = [.proAI]

    /// Zeile auf der Pro-AI-Karte: die Credits laufen ueber das StudiNow-Konto (Anmeldung mit Apple in den Einstellungen,
    /// StudoraAccountLink), dazu die Zahl aus dem Vertrag
    static let proAIServiceNote = "Braucht ein StudiNow-Konto (Anmelden mit Apple). \(UFPlan.proAI.monthlyCredits) Credits im Monat, am 1. neu aufgeladen, weitere Credits zum Nachkaufen."

    /// Zeile auf der Plus-Karte: die StudiNow-KI nur mit gekauften Credits (26.11.2026)
    static let plusServiceNote = "Die StudiNow-KI nutzt du mit Credits, die du in der App dazukaufst (StudiNow-Konto mit Apple)."

    /// dezenter, nicht anklickbarer Hinweis unter den Karten, wenn der Store das Pro-AI-Produkt gerade nicht liefert
    /// (Pro AI wird mit 1.0 verkauft, Entscheidung 07.11.2026: kein "folgt"/"kommt später", nur der ehrliche Grund)
    static let proAIMissingNote = "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden. Öffne die Seite später noch einmal."

    /// Karten der Tarifwahl: Free und Plus immer, Pro AI nur mit Produkt aus dem Store (`loaded`), dazu ein laufender
    /// Tarif, der gerade nicht angeboten wird – wer ihn hat, sieht ihn mit "Abo verwalten" (nie eine Karte, die fehlt)
    static func cards(current: UFPlan, loaded: Set<String>) -> [UFPlan] {
        UFPlan.allCases.filter { p in
            guard p != current else { return true }
            guard sellable.contains(p) else { return false }
            return !needsProduct.contains(p) || p.productID.map(loaded.contains) == true
        }
    }

    /// Zusatz zur Karte eines Tarifs (Plus: KI mit Credits, Pro AI: Konto und Monats-Credits)
    static func serviceNote(_ plan: UFPlan) -> String? {
        switch plan {
        case .free: return nil
        case .plus: return plusServiceNote
        case .proAI: return proAIServiceNote
        }
    }
}

// MARK: - Rechte aus dem Vertrag

/// `status` eines Rechts in plans.json: nur `available` darf als enthalten beworben werden
enum UFContractStatus: String {
    case available
    case comingSoon = "coming_soon"
    case disabled
}

/// Rechte wie in plans.json (`entitlements`), in derselben Reihenfolge. Rohwert = Name im Vertrag.
enum UFEntitlement: String, CaseIterable, Identifiable {
    // Free
    case canViewPDF = "can_view_pdf"
    case canManageCourses = "can_manage_courses"
    case canImportDocuments = "can_import_documents"
    case canViewTimetable = "can_view_timetable"
    case canUseBasicPlanner = "can_use_basic_planner"
    /// eigenes ChatGPT verbinden: seit 05.11.2026 in jedem Tarif (Name historisch). Auf dem iPad ueber den eigenen
    /// OpenAI-Schluessel (07.11.2026, `UFFeature.ownChatGPT`); "Mit ChatGPT anmelden" (plans.json `integrations.chatgpt`)
    /// bleibt aus, bis OpenAI es freigibt
    case chatgptConnectionPremium = "chatgpt_connection_premium"
    // Plus
    /// Community lesen, beitreten und mitmachen: ab Plus (Entscheidung 05.11.2026, vorher Free)
    case canReadCommunity = "can_read_community"
    case canAnnotatePDF = "can_annotate_pdf"
    case canUsePencilKit = "can_use_pencilkit"
    case canWriteCommunityComments = "can_write_community_comments"
    case canShareSolutions = "can_share_solutions"
    case canAccessSharedTests = "can_access_shared_tests"
    /// neue KI-Tests von StudiNow (`needs_credits`)
    case canGenerateStudoraAITests = "can_generate_studora_ai_tests"
    /// eigene Karteikarten anlegen, bearbeiten, ueben, teilen, uebernehmen (04.11.2026); Lesen bleibt in jedem Tarif
    case canUseFlashcards = "can_use_flashcards"
    /// Erinnerungen an Abgaben, Tests und Klausuren (Mitteilungen, auch "Neuer Klausurtermin erkannt") ab Plus
    /// (26.11.2026; 18.-26.11.2026 ab Pro AI, 11.-17.11.2026 ab Plus). Steht hier wegen der Reihenfolge im Vertrag
    case canUseDueReminders = "can_use_due_reminders"
    /// KI-Chat: die freie Frage an die KI ab Plus, nur mit Credits (`needs_credits`)
    case canUseAIChat = "can_use_ai_chat"
    // seit 26.11.2026 ab Plus: Lernstatistik und Planung des Dienstes (frueher Pro Connect, dann Pro AI)
    case canUseAdvancedAnalytics = "can_use_advanced_analytics"
    case canUseAdvancedPlanner = "can_use_advanced_planner"
    case canReviewWrongAnswers = "can_review_wrong_answers"
    case canUseExtendedTestHistory = "can_use_extended_test_history"
    case canGetRecommendations = "can_get_recommendations"
    // StudiNow-KI ueber den Dienst: seit 26.11.2026 ab Plus, nur mit Credits (`needs_credits`)
    case canUseAIExplanations = "can_use_ai_explanations"
    case canUseAIGeneratedQuestions = "can_use_ai_generated_questions"
    case canUseAISummaries = "can_use_ai_summaries"
    case canUseAIRecommendations = "can_use_ai_recommendations"
    /// Notizen-Abgleich zwischen iPad, PC und Web (seit 26.11.2026 ab Plus; vorher ab Pro AI)
    case canSyncAnnotations = "can_sync_annotations"
    /// fertige KI-Fragen je Vorlesungswoche aus der Bibliothek des Dienstes (04.11.2026)
    case canUsePreparedWeekSets = "can_use_prepared_week_sets"

    var id: String { rawValue }

    /// niedrigster Tarif mit diesem Recht (`from`). Seit 26.11.2026 hat Plus alle Rechte (Pro AI bringt nur die
    /// Monats-Credits dazu); die KI-Rechte gelten nur mit Credits (`needsCredits`).
    var from: UFPlan {
        switch self {
        case .canViewPDF, .canManageCourses, .canImportDocuments, .canViewTimetable, .canUseBasicPlanner,
             .chatgptConnectionPremium:
            return .free
        default:
            return .plus
        }
    }

    /// Recht der StudiNow-KI, das nur mit Credits gilt (plans.json `needs_credits`, 26.11.2026): der Tarif allein reicht
    /// nicht, das Konto braucht Credits (Monats-Credits von Pro AI, Probe-Credits oder gekaufte)
    var needsCredits: Bool {
        switch self {
        case .canGenerateStudoraAITests, .canUseAIChat, .canUseAIExplanations, .canUseAIGeneratedQuestions,
             .canUseAISummaries, .canUseAIRecommendations, .canUsePreparedWeekSets:
            return true
        default:
            return false
        }
    }

    /// Text aus plans.json (`label`)
    var label: String {
        switch self {
        case .canViewPDF: return "PDFs öffnen und lesen"
        case .canManageCourses: return "Hochschulkurse und Module verwalten"
        case .canImportDocuments: return "Automatischer Dokumentimport aus Stud.IP bzw. Learnweb"
        case .canViewTimetable: return "Stundenplan ansehen"
        case .canUseBasicPlanner: return "Lernkalender und Lernplanung"
        case .canReadCommunity: return "Community lesen, beitreten und mitmachen"
        case .canAnnotatePDF: return "PDF-Annotationen, Textmarker, Radierer, Zeichenwerkzeuge, Textfelder"
        case .canUsePencilKit: return UFDevice.adapt("Apple Pencil (PencilKit) und handschriftliche Notizen")
        case .canWriteCommunityComments: return "Community-Kommentare schreiben"
        case .canShareSolutions: return "Eigene Lösungen teilen"
        case .canAccessSharedTests: return "Tests aus der StudiNow-Bibliothek"
        case .canGenerateStudoraAITests: return "Neue KI-Tests von StudiNow"
        case .canUseFlashcards: return "Eigene Karteikarten mit Wiederholung"
        case .canUseDueReminders: return "Erinnerungen an Abgaben und Klausuren"
        case .canUseAIChat: return "KI-Chat mit gekauften Credits (Fragen an die KI)"
        case .canUseAdvancedAnalytics: return "Lernstatistik über alle Module"
        case .canUseAdvancedPlanner: return "Intelligente Lernplanung (Empfehlungen für die Woche)"
        case .canReviewWrongAnswers: return "Automatische Wiederholung falscher Antworten"
        case .canUseExtendedTestHistory: return "Vollständige Testliste (Free und Plus: die letzten 10)"
        case .canGetRecommendations: return "Personalisierte Lernempfehlungen"
        case .chatgptConnectionPremium: return "Eigenes ChatGPT verbinden: Fragen zu Folien und KI-Lernplan"
        case .canUseAIExplanations: return "KI-Erklärungen zu Aufgaben"
        case .canUseAIGeneratedQuestions: return "Automatische Lernfragen und Wiederholungsaufgaben"
        case .canUseAISummaries: return "KI-Zusammenfassungen"
        case .canUseAIRecommendations: return "KI-gestützte Lernempfehlungen"
        case .canSyncAnnotations: return "Notizen auf allen Geräten (Abgleich zwischen iPad, PC und Web)"
        case .canUsePreparedWeekSets: return "Fertige KI-Fragen zu jeder Vorlesungswoche mit Erklärungen"
        }
    }

    /// `status` aus plans.json
    var status: UFContractStatus {
        switch self {
        // Endpunkte (/api/learning/*) ohne Oberflaeche bzw. noch gar nicht gebaut: nie als enthalten beworben
        case .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canGetRecommendations,
             .canUseAIRecommendations:
            return .comingSoon
        default: return .available
        }
    }

    /// Hat der Tarif dieses Recht laut Vertrag? (wie plans.has)
    func included(in plan: UFPlan) -> Bool { plan >= from }

}

// MARK: - Umsetzung auf dem iPad

/// Wie ein Recht aus dem Vertrag auf dem iPad umgesetzt ist
enum UFDeviceSupport: Equatable {
    /// geht auf dem Geraet, ueber diese Funktionen der App (Sperren, Tarifkarten: `UFFeature`)
    case onDevice([UFFeature])
    /// geht auf dem iPad ueber den StudiNow-Dienst mit StudiNow-Konto (Anmeldung mit Apple), ueber diese Funktionen der
    /// App: StudiNow-KI (`StudiNowAIAccess`: Plus, Pro AI bzw. Probe und angemeldet, nur mit Credits) und Notizen-Abgleich
    /// (DeviceSync, der Dienst prueft can_sync_annotations). Auf der Tarifkarte enthalten, mit dem Konto-Hinweis.
    case withAccount([UFFeature])
    /// auf dem iPad nicht gebaut (Testbibliothek, Lernstatistik, Empfehlungen, Kommentare ueber den Dienst, ChatGPT):
    /// in keinem Tarif freigeschaltet und auf keiner Tarifkarte. Kein KI-Schluessel in der App.
    case needsService
}

extension UFEntitlement {
    var onDevice: UFDeviceSupport {
        switch self {
        case .canViewPDF: return .onDevice([.readDocuments])
        case .canManageCourses: return .onDevice([.studipSync, .modulesTimetable])
        case .canImportDocuments: return .onDevice([.studipSync])
        case .canViewTimetable: return .onDevice([.modulesTimetable])
        case .canUseBasicPlanner: return .onDevice([.studyCalendar, .studyPlanning])
        // eigenes ChatGPT ueber den eigenen OpenAI-Schluessel (07.11.2026): Einstellungen → Erweitert, jeder Tarif
        case .chatgptConnectionPremium: return OpenAIKeyLink.isOffered ? .onDevice([.ownChatGPT]) : .needsService
        // Lesen ab Plus wie im Vertrag und im Dienst (Entscheidung 05.11.2026); eigene Beitraege zurueckziehen geht
        // nach dem Herabstufen weiter (nichts wird geloescht)
        case .canReadCommunity: return .onDevice([.communityRead])
        case .canAnnotatePDF, .canUsePencilKit: return .onDevice([.pencilWriting])
        case .canShareSolutions: return .onDevice([.shareSolutions])
        // eigene Karteikarten: CardsPage, "Als Karteikarte", FlashcardComposer; ohne Plus nur lesen (UFFlashcardAccess)
        case .canUseFlashcards: return .onDevice([.flashcards])
        // Mitteilungen 7 Tage (Klausuren), 3 Tage, 1 Tag und am Morgen vor Abgaben, Tests und Klausuren und "Neuer
        // Klausurtermin erkannt" (DueReminderScheduler), ab Plus (26.11.2026), auf dem Geraet ohne StudiNow-Konto
        case .canUseDueReminders: return .onDevice([.dueReminders])
        // KI-Chat ab Plus: die freie Frage an die StudiNow-KI, mit StudiNow-Konto und Credits
        case .canUseAIChat: return .withAccount([.aiChat])
        // StudiNow-KI (ab Plus mit Credits): KI-Hilfe mit Erklaeren und Zusammenfassen, KI-Karteikarten und Wochentests
        case .canUseAIExplanations, .canUseAISummaries: return .withAccount([.aiHelp])
        case .canUseAIGeneratedQuestions: return .withAccount([.aiFlashcards, .weeklyTests])
        // Notizen-Abgleich G2 (ab Plus seit 26.11.2026)
        case .canSyncAnnotations: return .withAccount([.deviceSync])
        case .canWriteCommunityComments, .canAccessSharedTests, .canGenerateStudoraAITests,
             .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canUseExtendedTestHistory,
             .canGetRecommendations, .canUseAIRecommendations, .canUsePreparedWeekSets:
            return .needsService
        }
    }

    /// Funktionen der App, die das Recht umsetzen (leer: auf dem iPad nicht gebaut)
    var deviceFeatures: [UFFeature] {
        switch onDevice {
        case .onDevice(let f), .withAccount(let f): return f
        case .needsService: return []
        }
    }

    /// Auf dem iPad nutzbar und als enthalten zu zeigen: im Vertrag `available` und auf dem Geraet oder mit
    /// StudiNow-Konto umgesetzt
    var availableOnDevice: Bool { status == .available && !deviceFeatures.isEmpty }
}
