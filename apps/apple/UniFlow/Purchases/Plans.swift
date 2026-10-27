import Foundation

// Studora-Tarife und Rechte aus dem gemeinsamen Vertrag (docs/ABO-SYSTEM.md, Entscheidung des Inhabers 27.10.2026):
// vier Tarife Free, Plus, Pro Connect, Pro AI. Quelle aller Werte ist app/plans.py; tools/gen-plans-fixture.py
// schreibt daraus packages/shared-contracts/fixtures/plans/plans.json, und PlanContractTests prueft diese Tabelle
// Zeile fuer Zeile dagegen (Namen, Preise, Produkte, Rechte je Tarif, Stand). Aendert sich plans.py, hier nachziehen.
//
// Was davon auf dem iPad heute wirklich geht, steht nicht hier, sondern in `UFEntitlement.onDevice` (unten) und in
// `UFFeature` (Entitlements.swift): V1 laeuft ohne Konto beim Studora-Dienst, alles, was den Dienst braucht,
// erscheint als "in Vorbereitung".

// MARK: - Tarif

/// Studora-Tarif. Rohwerte wie die Schluessel in plans.json (`order`), auch fuer das Startargument -UFPlan.
enum UFPlan: String, CaseIterable, Comparable, Identifiable {
    case free
    case plus
    case proConnect = "pro_connect"
    case proAI = "pro_ai"

    var id: String { rawValue }

    /// `rank` aus plans.json; jeder Tarif enthaelt alle Rechte der niedrigeren
    var rank: Int {
        switch self {
        case .free: return 0
        case .plus: return 1
        case .proConnect: return 2
        case .proAI: return 3
        }
    }

    static func < (a: UFPlan, b: UFPlan) -> Bool { a.rank < b.rank }

    /// Name wie in plans.json (`name`); der App-Name bleibt UniFlow
    var name: String {
        switch self {
        case .free: return "Studora Free"
        case .plus: return "Studora Plus"
        case .proConnect: return "Studora Pro Connect"
        case .proAI: return "Studora Pro AI"
        }
    }

    /// Listenpreis in Cent (EUR, je Monat) aus plans.json. Nur fuer den Vertragsvergleich: angezeigt wird immer
    /// `Product.displayPrice` aus StoreKit (Richtlinie 3.1.2, Preis je Storefront).
    var priceCents: Int {
        switch self {
        case .free: return 0
        case .plus: return 199
        case .proConnect: return 299
        case .proAI: return 399
        }
    }

    /// Apple-Produkt (eine Abo-Gruppe, Apple regelt Upgrade und Downgrade); Free hat keins
    var productID: String? {
        switch self {
        case .free: return nil
        case .plus: return "de.uniflow.plus.monthly"
        case .proConnect: return "de.uniflow.proconnect.monthly"
        case .proAI: return "de.uniflow.proai.monthly"
        }
    }

    /// Kurzbeschreibung aus plans.json (`tagline`). Die Tarifkarte zeigt sie nur, wenn der Tarif auf dem iPad schon
    /// etwas Eigenes bietet (`UFFeatureMatrix.hasAvailableExtras`); sonst wuerde sie etwas versprechen.
    var tagline: String {
        switch self {
        case .free: return "Studium organisieren und Unterlagen lesen"
        case .plus: return "Mit Stift auf deinen Unterlagen schreiben"
        case .proConnect: return "Lernstatistiken, intelligente Planung und Wiederholung"
        case .proAI: return "KI von Studora inklusive – kein eigenes ChatGPT-Konto nötig"
        }
    }

    /// naechstkleinerer Tarif (Free: keiner)
    var lower: UFPlan? { UFPlan.allCases.last { $0 < self } }

    /// Produkt -> Tarif; fremde und nicht mehr angebotene Produkte (z. B. das fruehere de.uniflow.pro.monthly)
    /// geben keinen Tarif
    init?(productID: String) {
        guard let p = UFPlan.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = p
    }

    /// Abo-Tarife in der Reihenfolge der Karten
    static var paid: [UFPlan] { allCases.filter { $0.productID != nil } }
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
    case canReadCommunity = "can_read_community"
    // Plus
    case canAnnotatePDF = "can_annotate_pdf"
    case canUsePencilKit = "can_use_pencilkit"
    case canSyncAnnotations = "can_sync_annotations"
    case canWriteCommunityComments = "can_write_community_comments"
    case canShareSolutions = "can_share_solutions"
    case canAccessSharedTests = "can_access_shared_tests"
    case canGenerateStudoraAITests = "can_generate_studora_ai_tests"
    // Pro Connect
    case canUseAdvancedAnalytics = "can_use_advanced_analytics"
    case canUseAdvancedPlanner = "can_use_advanced_planner"
    case canReviewWrongAnswers = "can_review_wrong_answers"
    case canUseExtendedTestHistory = "can_use_extended_test_history"
    case canGetRecommendations = "can_get_recommendations"
    case chatgptConnectionPremium = "chatgpt_connection_premium"
    // Pro AI (Studora-KI ueber den Dienst)
    case canUseAIExplanations = "can_use_ai_explanations"
    case canUseAIGeneratedQuestions = "can_use_ai_generated_questions"
    case canUseAISummaries = "can_use_ai_summaries"
    case canUseAIRecommendations = "can_use_ai_recommendations"

    var id: String { rawValue }

    /// niedrigster Tarif mit diesem Recht (`from`)
    var from: UFPlan {
        switch self {
        case .canViewPDF, .canManageCourses, .canImportDocuments, .canViewTimetable, .canUseBasicPlanner, .canReadCommunity:
            return .free
        case .canAnnotatePDF, .canUsePencilKit, .canSyncAnnotations, .canWriteCommunityComments, .canShareSolutions,
             .canAccessSharedTests, .canGenerateStudoraAITests:
            return .plus
        case .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canUseExtendedTestHistory,
             .canGetRecommendations, .chatgptConnectionPremium:
            return .proConnect
        case .canUseAIExplanations, .canUseAIGeneratedQuestions, .canUseAISummaries, .canUseAIRecommendations:
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
        case .canReadCommunity: return "Community-Beiträge lesen"
        case .canAnnotatePDF: return "PDF-Annotationen, Textmarker, Radierer, Zeichenwerkzeuge, Textfelder"
        case .canUsePencilKit: return "Apple Pencil (PencilKit) und handschriftliche Notizen"
        case .canSyncAnnotations: return "Notizen auf allen Geräten"
        case .canWriteCommunityComments: return "Community-Kommentare schreiben"
        case .canShareSolutions: return "Eigene Lösungen teilen"
        case .canAccessSharedTests: return "Tests aus der Studora-Bibliothek"
        case .canGenerateStudoraAITests: return "Neue KI-Tests von Studora"
        case .canUseAdvancedAnalytics: return "Erweiterte Lernstatistiken"
        case .canUseAdvancedPlanner: return "Intelligente Lernplanung (Empfehlungen für die Woche)"
        case .canReviewWrongAnswers: return "Automatische Wiederholung falscher Antworten"
        case .canUseExtendedTestHistory: return "Erweiterte Testhistorie"
        case .canGetRecommendations: return "Personalisierte Lernempfehlungen"
        case .chatgptConnectionPremium: return "Eigenes ChatGPT-Konto verbinden (in Vorbereitung)"
        case .canUseAIExplanations: return "KI-Erklärungen zu Aufgaben"
        case .canUseAIGeneratedQuestions: return "Automatische Lernfragen und Wiederholungsaufgaben"
        case .canUseAISummaries: return "KI-Zusammenfassungen"
        case .canUseAIRecommendations: return "KI-gestützte Lernempfehlungen"
        }
    }

    /// `status` aus plans.json
    var status: UFContractStatus {
        switch self {
        case .canWriteCommunityComments: return .comingSoon
        case .chatgptConnectionPremium: return .disabled
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
    /// braucht den gehosteten Studora-Dienst (Konto, Studora-KI, Testbibliothek, Lernstatistik, Abgleich zwischen
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
        // Abweichung (iPadDeviations): die Community laeuft auf dem iPad ueber CloudKit und bleibt ganz in Plus
        case .canReadCommunity: return .onDevice([.community])
        case .canAnnotatePDF, .canUsePencilKit: return .onDevice([.pencilWriting])
        case .canShareSolutions: return .onDevice([.community])
        case .canSyncAnnotations, .canWriteCommunityComments, .canAccessSharedTests, .canGenerateStudoraAITests,
             .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canReviewWrongAnswers, .canUseExtendedTestHistory,
             .canGetRecommendations, .chatgptConnectionPremium, .canUseAIExplanations, .canUseAIGeneratedQuestions,
             .canUseAISummaries, .canUseAIRecommendations:
            return .needsService
        }
    }

    /// Bewusste Abweichungen vom Vertrag auf dem iPad: Recht -> Tarif, ab dem es das iPad freischaltet.
    /// `can_read_community` ist im Vertrag Free; auf dem iPad gehoert die ganze Community (Lesen, Teilen, Veroeffentlichen
    /// ueber CloudKit) weiter zu Plus (Entscheidung des Inhabers 26.10.2026 und Auftrag vom 27.10.2026, Punkt 2).
    static let iPadDeviations: [UFEntitlement: UFPlan] = [.canReadCommunity: .plus]

    /// Auf dem iPad heute nutzbar und als enthalten zu zeigen: im Vertrag `available` und auf dem Geraet umgesetzt
    var availableOnDevice: Bool {
        guard status == .available, case .onDevice = onDevice else { return false }
        return true
    }
}
