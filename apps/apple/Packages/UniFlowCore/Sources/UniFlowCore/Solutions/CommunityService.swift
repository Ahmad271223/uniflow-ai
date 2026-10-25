import Foundation

/// Schnittstelle der spaeteren Online-Community fuer Loesungspakete (docs/LOESUNGEN-TEILEN.md, Abschnitt
/// "Community-Schnittstelle"). Der Dienst bekommt nur das verschluesselte Paket; Stud.IP-Sitzungen, Cookies oder
/// Tokens gehen nie an ihn.
///
/// Heute gibt es KEINEN Dienst: `NotConnectedCommunityService` wirft bei jedem Aufruf `CommunityServiceError.notConnected`.
/// Es wird nichts gesendet und kein Erfolg vorgetaeuscht. Ein echter Dienst braucht vor dem Einschalten eine
/// Berechtigungspruefung (z. B. signierter Beleg der Hochschule oder OAuth2-Scope), Moderation sowie Melden und
/// Blockieren.
public protocol CommunityService: Sendable {
    /// Dienst erreichbar und angemeldet.
    var isConnected: Bool { get }
    /// Paket veroeffentlichen; Ergebnis ist die Kennung beim Dienst.
    func publish(_ package: SolutionPackage) async throws -> CommunityPublication
    /// Veroeffentlichte Loesungen zu einer Original-PDF (Fingerabdruck dient nur der Zuordnung).
    func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary]
    /// Paket laden (verschluesselt; geoeffnet wird es lokal mit der eigenen PDF).
    func download(solutionID: String) async throws -> SolutionPackage
    /// Eigene Veroeffentlichung zurueckziehen.
    func withdraw(solutionID: String) async throws
    /// Fremde Loesung melden (App-Store-Richtlinie 1.2).
    func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws
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
    public var displayName: String
    public var createdAt: String
    public var pageCount: Int

    public init(solutionID: String, fingerprint: String, displayName: String, createdAt: String, pageCount: Int) {
        self.solutionID = solutionID
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.createdAt = createdAt
        self.pageCount = pageCount
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
}

public enum CommunityServiceError: Error, Equatable, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Community-Dienst noch nicht verbunden."
        }
    }
}

/// Stand heute: kein Dienst. Jeder Aufruf scheitert mit einer klaren Meldung, nichts verlaesst das Geraet.
public struct NotConnectedCommunityService: CommunityService {
    public init() {}

    public var isConnected: Bool { false }

    public func publish(_ package: SolutionPackage) async throws -> CommunityPublication {
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
