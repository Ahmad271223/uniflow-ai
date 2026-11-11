import Foundation

// StudiNow-Tarife und Rechte aus dem gemeinsamen Vertrag (docs/ABO-SYSTEM.md, docs/PREISLISTE.md, Entscheidung des
// Inhabers vom 04.11.2026): drei Tarife Free, Plus, Pro AI; seit 09.11.2026 nur noch als Jahresabo (Plus 19,99 EUR,
// Pro AI 39,99 EUR im Jahr, docs/release/ABO-NUR-JAHR-2026-11-09.md). Pro Connect gibt es nicht mehr; sein
// Schluessel `pro_connect` und sein Produkt gelten wie Pro AI (`UFPlan(rawValue:)`, `UFPlan(productID:)`, wie
// plans.LEGACY_PLANS im Dienst). Quelle aller Werte ist app/plans.py; tools/gen-plans-fixture.py
// schreibt daraus packages/shared-contracts/fixtures/plans/plans.json, und PlanContractTests prueft diese Tabelle
// Zeile fuer Zeile dagegen (Namen, Preise, Produkte, Rechte je Tarif, Stand). Aendert sich plans.py, hier nachziehen.
//
// Was davon auf dem iPad wirklich geht, steht nicht hier, sondern in `UFEntitlement.onDevice` (unten) und in
// `UFFeature` (Entitlements.swift): auf dem Geraet, mit StudiNow-Konto ueber den Dienst (StudiNow-KI, Notizen-Abgleich;
// Pro AI, Stand 07.11.2026) oder gar nicht. Was gar nicht geht, zeigt keine Tarifkarte (auch nicht "in Vorbereitung").

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

    /// Listenpreis in Cent (EUR, je Jahr) aus plans.json. Nur fuer den Vertragsvergleich: angezeigt wird immer
    /// `Product.displayPrice` aus StoreKit (Richtlinie 3.1.2, Preis je Storefront).
    var priceCents: Int {
        switch self {
        case .free: return 0
        case .plus: return 1999
        case .proAI: return 3999
        }
    }

    /// Credits fuer die StudiNow-KI je Kalendermonat aus plans.json (`plans.<tarif>.credits`; 1 Credit = 0,9 Cent)
    var monthlyCredits: Int {
        switch self {
        case .free, .plus: return 0
        case .proAI: return 100
        }
    }

    /// das angebotene Apple-Produkt: das Jahresabo (Entscheidung des Inhabers vom 09.11.2026, eine Abo-Gruppe, Apple
    /// regelt Upgrade und Downgrade); Free hat keins
    var productID: String? { productID(.yearly) }

    /// Apple-Produkt je Zahlweise. Angeboten wird nur `.yearly` (`UFBilling.offered`); die Monatsprodukte (bis
    /// 09.11.2026) stehen nur hier, damit ein frueherer Kauf weiter als Kauf des Tarifs gilt (`init(productID:)`)
    func productID(_ billing: UFBilling) -> String? {
        switch (self, billing) {
        case (.free, _): return nil
        case (.plus, .monthly): return "de.uniflow.plus.monthly"
        case (.plus, .yearly): return "de.uniflow.plus.yearly"
        case (.proAI, .monthly): return "de.uniflow.proai.monthly"
        case (.proAI, .yearly): return "de.uniflow.proai.yearly"
        }
    }

    /// alle Apple-Produkte, die als Kauf des Tarifs gelten (das Jahresabo und das fruehere Monatsabo); angeboten wird
    /// nur `productID`
    var productIDs: [String] { UFBilling.allCases.compactMap(productID) }

    /// Kurzbeschreibung aus plans.json (`tagline`). Die Tarifkarte zeigt sie nur, wenn der Tarif auf dem iPad schon
    /// etwas Eigenes bietet (`UFFeatureMatrix.hasAvailableExtras`); sonst wuerde sie etwas versprechen.
    var tagline: String {
        switch self {
        case .free: return "Studium organisieren und Unterlagen lesen"
        case .plus: return "Mit Stift auf deinen Unterlagen schreiben, Karteikarten und Wochentests"
        case .proAI: return "KI von StudiNow inklusive – kein eigenes ChatGPT-Konto nötig"
        }
    }

    /// naechstkleinerer Tarif (Free: keiner)
    var lower: UFPlan? { UFPlan.allCases.last { $0 < self } }

    /// Produkte frueherer Tarife, die wie ein heutiger gelten (Pro Connect -> Pro AI, wie im Dienst)
    static let legacyProductIDs: [String: UFPlan] = ["de.uniflow.proconnect.monthly": .proAI]

    /// Produkt -> Tarif; fremde und nicht mehr angebotene Produkte (z. B. das fruehere de.uniflow.pro.monthly)
    /// geben keinen Tarif, das fruehere Pro-Connect-Produkt gilt wie Pro AI
    init?(productID: String) {
        guard let p = UFPlan.allCases.first(where: { $0.productIDs.contains(productID) }) ?? UFPlan.legacyProductIDs[productID] else { return nil }
        self = p
    }

    /// Abo-Tarife in der Reihenfolge der Karten
    static var paid: [UFPlan] { allCases.filter { $0.productID != nil } }
}

/// Zahlweise eines Abos. Seit 09.11.2026 (Entscheidung des Inhabers) gibt es nur noch das Jahresabo (`offered`);
/// `monthly` bleibt nur, damit ein frueherer Kauf eines Monatsabos erkannt wird (nie angeboten, kein Umschalter).
enum UFBilling: String, CaseIterable, Identifiable {
    case monthly
    case yearly

    var id: String { rawValue }

    /// die einzige angebotene Zahlweise
    static let offered: UFBilling = .yearly

    /// Zahlweise eines Apple-Produkts (unbekannt: nil)
    init?(productID: String) {
        guard let b = UFBilling.allCases.first(where: { b in UFPlan.allCases.contains { $0.productID(b) == productID } })
        else { return nil }
        self = b
    }
}

// MARK: - Was das iPad anbietet

/// Welche Tarife die App anbietet. Entscheidung des Inhabers vom 04.11.2026 (ersetzt "nur Free und Plus" vom
/// 28.10.2026): drei Tarife StudiNow Free, Plus und Pro AI, seit 09.11.2026 nur als Jahresabo (19,99 € bzw. 39,99 €),
/// kein Apple-Einfuehrungsangebot, dafuer 7 Tage Probe mit allem auf dem iPad (LocalTrial.swift). Die Pro-AI-Karte
/// erscheint nur, wenn StoreKit das Produkt `de.uniflow.proai.yearly` liefert, sonst zeigt die Seite nur Free und
/// Plus. Pro Connect gibt es nicht mehr (Entscheidung 04.11.2026).
enum UFPlanCatalog {
    /// auf dem iPad waehlbar
    static let sellable: [UFPlan] = [.free, .plus, .proAI]

    /// Apple-Produkte, die die App laedt und anbietet: nur die Jahresabos (09.11.2026)
    static var sellableProductIDs: [String] { sellable.compactMap(\.productID) }

    /// Tarife, deren Karte nur mit geliefertem Produkt erscheint (Pro AI: erst mit dem Dienst im Store)
    static let needsProduct: Set<UFPlan> = [.proAI]

    /// Zeile auf der Pro-AI-Karte: die StudiNow-KI und der Abgleich laufen ueber das StudiNow-Konto (Anmeldung mit Apple
    /// in den Einstellungen, StudoraAccountLink), dazu die Credits aus dem Vertrag
    static let proAIServiceNote = "Braucht ein StudiNow-Konto (Anmelden mit Apple). \(UFPlan.proAI.monthlyCredits) Credits im Monat."

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

    /// Zusatz zur Karte eines Tarifs (nur Pro AI)
    static func serviceNote(_ plan: UFPlan) -> String? { plan == .proAI ? proAIServiceNote : nil }
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
    case canGenerateStudoraAITests = "can_generate_studora_ai_tests"
    /// eigene Karteikarten anlegen, bearbeiten, ueben, teilen, uebernehmen (04.11.2026); Lesen bleibt in jedem Tarif
    case canUseFlashcards = "can_use_flashcards"
    /// Erinnerungen an Abgaben, Tests und Klausuren (Mitteilungen) ab Plus (Entscheidung 11.11.2026)
    case canUseDueReminders = "can_use_due_reminders"
    // Pro AI: Lernstatistik und Planung des Dienstes (frueher Pro Connect)
    case canUseAdvancedAnalytics = "can_use_advanced_analytics"
    case canUseAdvancedPlanner = "can_use_advanced_planner"
    case canReviewWrongAnswers = "can_review_wrong_answers"
    case canUseExtendedTestHistory = "can_use_extended_test_history"
    case canGetRecommendations = "can_get_recommendations"
    // Pro AI (StudiNow-KI ueber den Dienst)
    case canUseAIExplanations = "can_use_ai_explanations"
    case canUseAIGeneratedQuestions = "can_use_ai_generated_questions"
    case canUseAISummaries = "can_use_ai_summaries"
    case canUseAIRecommendations = "can_use_ai_recommendations"
    /// Notizen-Abgleich zwischen iPad, PC und Web (Entscheidung 04.11.2026: Plus gilt je Geraet, Abgleich ab Pro AI)
    case canSyncAnnotations = "can_sync_annotations"
    /// fertige KI-Fragen je Vorlesungswoche aus der Bibliothek des Dienstes (04.11.2026)
    case canUsePreparedWeekSets = "can_use_prepared_week_sets"

    var id: String { rawValue }

    /// niedrigster Tarif mit diesem Recht (`from`)
    var from: UFPlan {
        switch self {
        case .canViewPDF, .canManageCourses, .canImportDocuments, .canViewTimetable, .canUseBasicPlanner,
             .chatgptConnectionPremium:
            return .free
        case .canReadCommunity, .canAnnotatePDF, .canUsePencilKit, .canWriteCommunityComments, .canShareSolutions,
             .canAccessSharedTests, .canGenerateStudoraAITests, .canUseFlashcards, .canUseDueReminders:
            return .plus
        case .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canUseExtendedTestHistory,
             .canGetRecommendations, .canUseAIExplanations, .canUseAIGeneratedQuestions,
             .canUseAISummaries, .canUseAIRecommendations, .canSyncAnnotations, .canUsePreparedWeekSets:
            return .proAI
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
        case .canUsePencilKit: return "Apple Pencil (PencilKit) und handschriftliche Notizen"
        case .canWriteCommunityComments: return "Community-Kommentare schreiben"
        case .canShareSolutions: return "Eigene Lösungen teilen"
        case .canAccessSharedTests: return "Tests aus der StudiNow-Bibliothek"
        case .canGenerateStudoraAITests: return "Neue KI-Tests von StudiNow"
        case .canUseFlashcards: return "Eigene Karteikarten mit Wiederholung"
        case .canUseDueReminders: return "Erinnerungen an Abgaben und Klausuren"
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
    /// App: StudiNow-KI (`StudiNowAIAccess`: Pro AI bzw. Probe und angemeldet, Credits beim Dienst) und Notizen-Abgleich
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
        case .chatgptConnectionPremium: return .onDevice([.ownChatGPT])
        // Lesen ab Plus wie im Vertrag und im Dienst (Entscheidung 05.11.2026); eigene Beitraege zurueckziehen geht
        // nach dem Herabstufen weiter (nichts wird geloescht)
        case .canReadCommunity: return .onDevice([.communityRead])
        case .canAnnotatePDF, .canUsePencilKit: return .onDevice([.pencilWriting])
        case .canShareSolutions: return .onDevice([.shareSolutions])
        // eigene Karteikarten: CardsPage, "Als Karteikarte", FlashcardComposer; ohne Plus nur lesen (UFFlashcardAccess)
        case .canUseFlashcards: return .onDevice([.flashcards])
        // Mitteilungen 3 Tage, 1 Tag und am Morgen vor Abgaben, Tests und Klausuren (DueReminderScheduler)
        case .canUseDueReminders: return .onDevice([.dueReminders])
        // StudiNow-KI (Pro AI): KI-Hilfe mit Erklaeren und Zusammenfassen, KI-Karteikarten und Wochentests
        case .canUseAIExplanations, .canUseAISummaries: return .withAccount([.aiHelp])
        case .canUseAIGeneratedQuestions: return .withAccount([.aiFlashcards, .weeklyTests])
        // Notizen-Abgleich G2 (Pro AI; Plus gilt je Geraet)
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
