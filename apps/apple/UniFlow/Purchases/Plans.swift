import Foundation

// StudiNow-Tarife und Rechte aus dem gemeinsamen Vertrag (docs/ABO-SYSTEM.md, docs/PREISLISTE.md, Entscheidung des
// Inhabers vom 04.11.2026): drei Tarife Free, Plus (1,99 EUR), Pro AI (3,99 EUR). Pro Connect gibt es nicht mehr; sein
// Schluessel `pro_connect` und sein Produkt gelten wie Pro AI (`UFPlan(rawValue:)`, `UFPlan(productID:)`, wie
// plans.LEGACY_PLANS im Dienst). Quelle aller Werte ist app/plans.py; tools/gen-plans-fixture.py
// schreibt daraus packages/shared-contracts/fixtures/plans/plans.json, und PlanContractTests prueft diese Tabelle
// Zeile fuer Zeile dagegen (Namen, Preise, Produkte, Rechte je Tarif, Stand). Aendert sich plans.py, hier nachziehen.
//
// Was davon auf dem iPad heute wirklich geht, steht nicht hier, sondern in `UFEntitlement.onDevice` (unten) und in
// `UFFeature` (Entitlements.swift): V1 laeuft ohne Konto beim StudiNow-Dienst, alles, was den Dienst braucht,
// erscheint als "in Vorbereitung".

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

    /// Listenpreis in Cent (EUR, je Monat) aus plans.json. Nur fuer den Vertragsvergleich: angezeigt wird immer
    /// `Product.displayPrice` aus StoreKit (Richtlinie 3.1.2, Preis je Storefront).
    var priceCents: Int {
        switch self {
        case .free: return 0
        case .plus: return 199
        case .proAI: return 399
        }
    }

    /// Apple-Produkt (eine Abo-Gruppe, Apple regelt Upgrade und Downgrade); Free hat keins
    var productID: String? {
        switch self {
        case .free: return nil
        case .plus: return "de.uniflow.plus.monthly"
        case .proAI: return "de.uniflow.proai.monthly"
        }
    }

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
        guard let p = UFPlan.allCases.first(where: { $0.productID == productID }) ?? UFPlan.legacyProductIDs[productID] else { return nil }
        self = p
    }

    /// Abo-Tarife in der Reihenfolge der Karten
    static var paid: [UFPlan] { allCases.filter { $0.productID != nil } }
}

// MARK: - Was das iPad anbietet

/// Welche Tarife die App anbietet. Entscheidung des Inhabers vom 04.11.2026 (ersetzt "nur Free und Plus" vom
/// 28.10.2026): drei Tarife StudiNow Free, Plus (1,99 €) und Pro AI (3,99 €), kein Apple-Einfuehrungsangebot, dafuer
/// 7 Tage Probe mit allem auf dem iPad (LocalTrial.swift). Die Pro-AI-Karte erscheint nur, wenn StoreKit das Produkt
/// liefert: vor dem StudiNow-Dienst steht `de.uniflow.proai.monthly` nicht im Store, dann zeigt die Seite nur Free und
/// Plus. Pro Connect gibt es nicht mehr (Entscheidung 04.11.2026).
enum UFPlanCatalog {
    /// auf dem iPad waehlbar
    static let sellable: [UFPlan] = [.free, .plus, .proAI]

    /// Apple-Produkte, die die App laedt und anbietet
    static var sellableProductIDs: [String] { sellable.compactMap(\.productID) }

    /// Tarife, deren Karte nur mit geliefertem Produkt erscheint (Pro AI: erst mit dem Dienst im Store)
    static let needsProduct: Set<UFPlan> = [.proAI]

    /// ehrliche Zeile auf der Pro-AI-Karte: braucht den StudiNow-Dienst
    static let proAIServiceNote = "StudiNow Pro AI braucht den StudiNow-Dienst. Ohne ihn bietet es auf dem iPad denselben Umfang wie StudiNow Plus."

    /// dezenter, nicht anklickbarer Hinweis unter den Karten, solange der Store kein Pro-AI-Produkt liefert
    static let proAIMissingNote = "StudiNow Pro AI folgt mit dem StudiNow-Dienst."

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
    /// eigenes ChatGPT verbinden und zu Folien fragen: seit 05.11.2026 in jedem Tarif (Name historisch); die
    /// Verbindung selbst ist aus, bis OpenAI sie freigibt (plans.json `integrations.chatgpt`)
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
             .canAccessSharedTests, .canGenerateStudoraAITests, .canUseFlashcards:
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
        case .canUseAdvancedAnalytics: return "Lernstatistik über alle Module"
        case .canUseAdvancedPlanner: return "Intelligente Lernplanung (Empfehlungen für die Woche)"
        case .canReviewWrongAnswers: return "Automatische Wiederholung falscher Antworten"
        case .canUseExtendedTestHistory: return "Vollständige Testliste (Free und Plus: die letzten 10)"
        case .canGetRecommendations: return "Personalisierte Lernempfehlungen"
        case .chatgptConnectionPremium: return "Eigenes ChatGPT verbinden und zu Folien fragen (in Vorbereitung)"
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
        case .chatgptConnectionPremium: return .disabled
        // Endpunkte (/api/learning/*) ohne Oberflaeche bzw. noch gar nicht gebaut: nie als enthalten beworben
        case .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canGetRecommendations,
             .canUseAIRecommendations:
            return .comingSoon
        default: return .available
        }
    }

    /// Hat der Tarif dieses Recht laut Vertrag? (wie plans.has)
    func included(in plan: UFPlan) -> Bool { plan >= from }

    /// Text fuer die Zeile "in Vorbereitung": ohne den Zusatz "(in Vorbereitung)", den die Marke schon traegt
    var cardLabel: String { label.replacingOccurrences(of: " (in Vorbereitung)", with: "") }
}

// MARK: - Umsetzung auf dem iPad (V1, ohne Konto beim Dienst)

/// Wie ein Recht aus dem Vertrag auf dem iPad umgesetzt ist
enum UFDeviceSupport: Equatable {
    /// geht auf dem Geraet, ueber diese Funktionen der App (Sperren, Tarifkarten: `UFFeature`)
    case onDevice([UFFeature])
    /// braucht den gehosteten StudiNow-Dienst (Konto, StudiNow-KI, Testbibliothek, Lernstatistik, Abgleich zwischen
    /// Geraeten, ChatGPT): bis der Dienst laeuft "in Vorbereitung", in keinem Tarif freigeschaltet. Kein KI-Schluessel
    /// in der App.
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
        // Lesen ab Plus wie im Vertrag und im Dienst (Entscheidung 05.11.2026); eigene Beitraege zurueckziehen geht
        // nach dem Herabstufen weiter (nichts wird geloescht)
        case .canReadCommunity: return .onDevice([.communityRead])
        case .canAnnotatePDF, .canUsePencilKit: return .onDevice([.pencilWriting])
        case .canShareSolutions: return .onDevice([.shareSolutions])
        // eigene Karteikarten: CardsPage, "Als Karteikarte", FlashcardComposer; ohne Plus nur lesen (UFFlashcardAccess)
        case .canUseFlashcards: return .onDevice([.flashcards])
        case .canSyncAnnotations, .canWriteCommunityComments, .canAccessSharedTests, .canGenerateStudoraAITests,
             .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canUseExtendedTestHistory,
             .canGetRecommendations, .chatgptConnectionPremium, .canUseAIExplanations, .canUseAIGeneratedQuestions,
             .canUseAISummaries, .canUseAIRecommendations, .canUsePreparedWeekSets:
            return .needsService
        }
    }

    /// Auf dem iPad heute nutzbar und als enthalten zu zeigen: im Vertrag `available` und auf dem Geraet umgesetzt
    var availableOnDevice: Bool {
        guard status == .available, case .onDevice = onDevice else { return false }
        return true
    }
}
