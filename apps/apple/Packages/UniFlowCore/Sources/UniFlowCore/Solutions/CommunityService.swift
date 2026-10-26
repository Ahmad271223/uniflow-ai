import Foundation

/// Schnittstelle der Online-Community fuer Loesungspakete (docs/LOESUNGEN-TEILEN.md, Abschnitte 6 und 7). Der
/// Dienst bekommt nur das verschluesselte Paket und die Kopfdaten; Stud.IP-Sitzungen, Cookies oder Tokens gehen
/// nie an ihn, ebenso wenig Apple-ID, Name, E-Mail oder Matrikelnummer.
///
/// Umsetzungen: `NotConnectedCommunityService` (Kern, kein Dienst: jeder Aufruf wirft `notConnected`) und in der
/// App `CloudKitCommunityService` (oeffentliche CloudKit-Datenbank, V1). Der Dienst ist hinter diesem Protokoll
/// tauschbar (spaeter Supabase). Die neuen Aufrufe (Kurs, Sperrliste, Lerngruppen) haben Standardimplementierungen,
/// die "nicht verbunden" melden, damit aeltere Umsetzungen weiter bauen.
///
/// Sichtbarkeit und Filter sind reine Funktionen im Kern (`CommunityRules`), die Schluessel ebenso (`CommunityKeys`):
/// Wer die Kurs-ID nicht kennt, kann den Kurs-Schluessel nicht bilden und findet nichts.
public protocol CommunityService: Sendable {
    /// Dienst vorhanden (Build mit iCloud-Container) – sagt nichts ueber Netz oder iCloud-Anmeldung.
    var isConnected: Bool { get }
    /// Paket veroeffentlichen; Ergebnis ist die Kennung beim Dienst.
    func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication
    /// Veroeffentlichte Loesungen zu einer Original-PDF (Fingerabdruck dient nur der Zuordnung), schon gefiltert
    /// nach Hochschule, Sichtbarkeit, Zurueckgezogen und eigener Sperrliste.
    func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary]
    /// Paket laden (verschluesselt; geoeffnet wird es lokal mit der eigenen PDF).
    func download(solutionID: String) async throws -> SolutionPackage
    /// Eigene Veroeffentlichung zurueckziehen (Paket wird beim Dienst geloescht, der Eintrag als zurueckgezogen markiert).
    func withdraw(solutionID: String) async throws
    /// Fremde Loesung melden (App-Store-Richtlinie 1.2).
    func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws
    /// Loesungen zu allen Dateien eines Kurses (Kurs-Schluessel aus `CommunityKeys.courseKey`), neueste zuerst.
    func findForCourse(courseKey: String) async throws -> [CommunitySolutionSummary]
    /// Nutzer sperren (nur die eigene Sperrliste, privat); seine Loesungen erscheinen nicht mehr.
    func block(owner: String) async throws
    func unblock(owner: String) async throws
    /// Eigene Sperrliste (Nutzerkennungen des Dienstes, nie Apple-ID oder E-Mail).
    func blockedOwners() async throws -> [String]
    /// Lerngruppe anlegen; der Beitrittscode steht im Ergebnis.
    func createStudyGroup(name: String) async throws -> CommunityStudyGroup
    /// Lerngruppe ueber ihren Code beitreten (Mitgliedschaft = Kenntnis des Codes).
    func joinStudyGroup(code: String) async throws -> CommunityStudyGroup
    func leaveStudyGroup(code: String) async throws
    /// Lerngruppen, denen dieses Geraet beigetreten ist.
    func studyGroups() async throws -> [CommunityStudyGroup]
}

extension CommunityService {
    /// Veroeffentlichen mit Standardoptionen (Sichtbarkeit Modul ohne Kurs-Schluessel: der Dienst weist das ab).
    public func publish(_ package: SolutionPackage) async throws -> CommunityPublication {
        try await publish(package, options: CommunityPublishOptions())
    }

    public func findForCourse(courseKey: String) async throws -> [CommunitySolutionSummary] { throw CommunityServiceError.notConnected }
    public func block(owner: String) async throws { throw CommunityServiceError.notConnected }
    public func unblock(owner: String) async throws { throw CommunityServiceError.notConnected }
    public func blockedOwners() async throws -> [String] { throw CommunityServiceError.notConnected }
    public func createStudyGroup(name: String) async throws -> CommunityStudyGroup { throw CommunityServiceError.notConnected }
    public func joinStudyGroup(code: String) async throws -> CommunityStudyGroup { throw CommunityServiceError.notConnected }
    public func leaveStudyGroup(code: String) async throws { throw CommunityServiceError.notConnected }
    public func studyGroups() async throws -> [CommunityStudyGroup] { throw CommunityServiceError.notConnected }
}

/// Wer eine veroeffentlichte Loesung sehen darf (docs/LOESUNGEN-TEILEN.md, Abschnitt 7).
public enum CommunityVisibility: String, CaseIterable, Sendable {
    /// alle, die denselben Kurs in Stud.IP bzw. Learnweb haben (Kurs-Schluessel passt)
    case module = "modul"
    /// nur Mitglieder der Lerngruppe (Gruppen-Schluessel passt)
    case studyGroup = "lerngruppe"
    /// alle an derselben Hochschule, ohne Pseudonym
    case anonymous = "anonym"

    public var title: String {
        switch self {
        case .module: return "Modul"
        case .studyGroup: return "Lerngruppe"
        case .anonymous: return "Anonym"
        }
    }
}

/// Was beim Veroeffentlichen ausser dem Paket mitgeht (alles aus dem Paketkopf, der lokalen Datenbank und der
/// Auswahl im Dialog; nichts Persoenliches).
public struct CommunityPublishOptions: Equatable, Sendable {
    public var visibility: CommunityVisibility
    /// `CommunityKeys.courseKey` der Datei aus Kurs-ID oder Modulname (Pflicht bei `.module`; sonst, wenn bekannt,
    /// fuer die Kursansicht)
    public var courseKey: String?
    /// `CommunityKeys.groupKey` der Lerngruppe (Pflicht bei `.studyGroup`)
    public var groupKey: String?
    /// Titel des Blatts (nur Anzeige in der Trefferliste)
    public var title: String
    /// Lehrwoche aus der lokalen Einordnung (0 = unbekannt), fuer die Kursansicht nach Woche
    public var week: Int

    public init(visibility: CommunityVisibility = .module, courseKey: String? = nil, groupKey: String? = nil,
                title: String = "", week: Int = 0) {
        self.visibility = visibility
        self.courseKey = courseKey
        self.groupKey = groupKey
        self.title = title
        self.week = week
    }
}

public struct CommunityPublication: Equatable, Sendable {
    public var solutionID: String
    public var publishedAt: Date

    public init(solutionID: String, publishedAt: Date) {
        self.solutionID = solutionID
        self.publishedAt = publishedAt
    }
}

/// Eintrag in der Trefferliste des Dienstes (nur Kopfdaten).
public struct CommunitySolutionSummary: Equatable, Sendable {
    public var solutionID: String
    public var fingerprint: String
    /// Pseudonym; leer = anonym
    public var displayName: String
    public var createdAt: String
    public var pageCount: Int
    public var title: String
    public var visibility: CommunityVisibility
    /// Lehrwoche (0 = unbekannt)
    public var week: Int
    /// Nutzerkennung des Dienstes (nur zum Zurueckziehen, Melden und Blockieren; nie Apple-ID oder E-Mail)
    public var ownerRecordName: String
    /// eigene Veroeffentlichung
    public var isOwn: Bool

    public init(solutionID: String, fingerprint: String, displayName: String, createdAt: String, pageCount: Int,
                title: String = "", visibility: CommunityVisibility = .module, week: Int = 0,
                ownerRecordName: String = "", isOwn: Bool = false) {
        self.solutionID = solutionID
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.title = title
        self.visibility = visibility
        self.week = week
        self.ownerRecordName = ownerRecordName
        self.isOwn = isOwn
    }

    public init(listing l: CommunityListing, isOwn: Bool) {
        self.init(solutionID: l.solutionID, fingerprint: l.fingerprint, displayName: l.displayName, createdAt: l.createdAt,
                  pageCount: l.pageCount, title: l.title, visibility: l.visibility, week: l.week,
                  ownerRecordName: l.ownerRecordName, isOwn: isOwn)
    }
}

/// Lerngruppe: Beitritt ueber den Code (8 Zeichen, auch als QR). Beim Dienst liegt nur der Gruppen-Schluessel
/// (Hash aus Hochschule und Code), der Name und die Hochschule.
public struct CommunityStudyGroup: Equatable, Sendable, Hashable {
    public var code: String
    public var name: String
    public var university: String
    public var groupKey: String

    public init(code: String, name: String, university: String, groupKey: String) {
        self.code = code
        self.name = name
        self.university = university
        self.groupKey = groupKey
    }

    public init(code: String, name: String, university: String) {
        self.init(code: code, name: name, university: university, groupKey: CommunityKeys.groupKey(university: university, code: code))
    }
}

public enum CommunityReportReason: String, CaseIterable, Sendable {
    /// enthaelt fremdes Material (Folien, Aufgabenstellungen)
    case foreignMaterial
    /// bewertete Abgabe (Pruefungsordnung)
    case gradedSubmission
    case offensive
    case spam
    case other

    public var title: String {
        switch self {
        case .foreignMaterial: return "Fremdes Material (Folien, Aufgabenstellungen)"
        case .gradedSubmission: return "Bewertete Abgabe (Prüfungsordnung)"
        case .offensive: return "Beleidigend oder verletzend"
        case .spam: return "Spam oder Werbung"
        case .other: return "Sonstiges"
        }
    }
}

/// Fehler des Dienstes, verstaendlich fuer die Oberflaeche.
public enum CommunityServiceError: Error, Equatable, LocalizedError {
    /// kein Dienst (Kern-Umsetzung)
    case notConnected
    /// Build ohne iCloud-Container (kein bezahltes Team)
    case unavailable
    /// auf diesem iPad nicht bei iCloud angemeldet (oder iCloud eingeschraenkt)
    case notSignedIn
    case offline
    /// Kontingent beim Dienst erschoepft
    case quota
    /// nur eigene Veroeffentlichungen lassen sich zurueckziehen
    case notOwner
    case notFound
    /// Datei ohne Kurs und ohne Modul (eigener Upload ohne Zuordnung): Sichtbarkeit "Modul" nicht moeglich
    case missingCourse
    case invalidGroupCode
    case groupNotFound
    case invalidGroupName
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Community-Dienst noch nicht verbunden."
        case .unavailable: return "Die Community ist in diesem Build nicht verfügbar (kein iCloud-Container)."
        case .notSignedIn: return "Melde dich auf diesem iPad bei iCloud an (Einstellungen → Apple-ID), um die Community zu nutzen."
        case .offline: return "Keine Verbindung zum Community-Dienst. Prüfe dein Netz und versuche es erneut."
        case .quota: return "Das Kontingent des Community-Dienstes ist erschöpft. Bitte später erneut versuchen."
        case .notOwner: return "Nur eigene Veröffentlichungen lassen sich zurückziehen."
        case .notFound: return "Diese Lösung gibt es in der Community nicht mehr."
        case .missingCourse: return "Diese Datei gehört zu keinem Kurs und keinem Modul. Wähle „Lerngruppe“ oder „Anonym“."
        case .invalidGroupCode: return "Ein Beitrittscode hat 8 Zeichen (Buchstaben und Ziffern)."
        case .groupNotFound: return "Keine Lerngruppe mit diesem Code an deiner Hochschule."
        case .invalidGroupName: return "Gib der Lerngruppe einen Namen (höchstens 60 Zeichen)."
        case .server(let m): return "Community-Dienst: \(m)"
        }
    }
}

/// Stand ohne Dienst (Kern): Jeder Aufruf scheitert mit einer klaren Meldung, nichts verlaesst das Geraet.
public struct NotConnectedCommunityService: CommunityService {
    public init() {}

    public var isConnected: Bool { false }

    public func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        throw CommunityServiceError.notConnected
    }

    public func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] {
        throw CommunityServiceError.notConnected
    }

    public func download(solutionID: String) async throws -> SolutionPackage {
        throw CommunityServiceError.notConnected
    }

    public func withdraw(solutionID: String) async throws {
        throw CommunityServiceError.notConnected
    }

    public func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {
        throw CommunityServiceError.notConnected
    }
}
