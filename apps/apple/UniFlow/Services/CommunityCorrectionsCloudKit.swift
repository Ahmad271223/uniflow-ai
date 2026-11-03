import Foundation
import UniFlowCore

// Korrekturvorschlaege ueber die oeffentliche CloudKit-Datenbank (03.11.2026, Wunsch des Inhabers).
//
// Datensatz `Correction` (oeffentlich, Name = Korrektur-ID):
// - `solutionID` (abfragbar): Ziel-Loesung, klein geschrieben – alle Mitglieder sehen die Korrekturen unter der Loesung
// - `solutionOwner` (abfragbar): Nutzerkennung des Erstellers der Ziel-Loesung – sein Posteingang
// - `payload`: Inhalt verschluesselt (`CommunityCorrections.seal`, Geheimnis der Community der Loesung)
// - `createdAt`, `createdOrder`, `ownerRecordName` (Anzeige im Dashboard; Besitzer ist der Ersteller des Datensatzes)
//
// Die Loesung selbst wird nie geaendert. `solutionOwner` setzt der Absender; beim Lesen zaehlt nur, was zur Loesung
// passt (der Posteingang prueft, dass die Loesung wirklich dem Leser gehoert). Gesperrte Nutzer (eigene Sperrliste und
// `Ban`) erscheinen nicht; wer gesperrt ist (`Ban`), kann nichts schicken. Ignorieren gilt nur auf diesem Geraet
// (`CommunityCorrectionStatusStore`). Zuruecknehmen kann nur der Verfasser (Datensatz loeschen).

extension CommunityRecordType {
    /// Korrekturvorschlag zu einer Loesung (Inhalt verschluesselt)
    static let correction = "Correction"
}

extension CloudKitCommunityService.Field {
    static let solutionOwner = "solutionOwner"
}

extension CloudKitCommunityService {
    var supportsCorrections: Bool { true }

    /// Zustand der Korrekturen dieses Containers (Ignorieren); ohne aktiven Container ein Speicher je Dienst
    var correctionStatus: CommunityCorrectionStatusStore { CorrectionStatusRegistry.store(for: self) }

    func setCorrectionStatus(_ status: CommunityCorrection.Status, id: String) {
        correctionStatus.set(status, id: id)
    }

    func sendCorrection(_ correction: CommunityCorrection) async throws -> CommunityCorrection {
        let (cloud, user) = try await signedIn()
        let sid = correction.targetSolutionID.lowercased()
        let (listing, _) = try await visibleSolution(cloud, id: sid)
        guard !listing.withdrawn else { throw CommunityServiceError.notFound }
        guard listing.ownerRecordName != user else {
            throw CommunityServiceError.service("Die eigene Lösung änderst du direkt im Dokument.")
        }
        if await bannedOwners(cloud).contains(user) { throw CommunityServiceError.service("Dein Konto darf keine Korrekturen mehr schicken.") }
        let secret = try await secret(listing)
        var c = correction.content
        c.targetSolutionID = sid
        c.pseudonym = CommunityDiscussion.pseudonym(pseudonym())
        c.createdAt = SolutionPackage.timestamp(Date())
        let payload = try CommunityCorrections.seal(c, communitySecret: secret, cipher: SolutionSharing.cipher)
        var record = CommunityRecord(type: CommunityRecordType.correction, name: c.id)
        record[Field.solutionID] = .string(sid)
        record[Field.solutionOwner] = .string(listing.ownerRecordName)
        record[Field.payload] = .string(payload)
        record[Field.createdAt] = .string(c.createdAt)
        let order = Int(Date().timeIntervalSince1970 * 1_000_000)
        record[Field.order] = .int(order)
        record[Field.owner] = .string(user)
        do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
        var out = try CommunityCorrections.validated(c)
        out.author = user
        out.isMine = true
        out.order = order
        return out
    }

    /// Datensatz -> Korrektur (entschluesselt und geprueft); nil, wenn nicht lesbar oder nicht zur Loesung gehoerend
    static func correction(_ r: CommunityRecord, solutionID: String, me: String, secret: Data, cipher: SolutionCipher) -> CommunityCorrection? {
        guard r.type == CommunityRecordType.correction, r[Field.solutionID]?.string == solutionID,
              let payload = r[Field.payload]?.string,
              var c = try? CommunityCorrections.open(payload, correctionID: r.name, solutionID: solutionID, communitySecret: secret, cipher: cipher)
        else { return nil }
        c.author = owner(r, me: me)
        c.order = r[Field.order]?.int ?? 0
        return c
    }

    func corrections(solutionID: String) async throws -> [CommunityCorrection] {
        let cloud = try available()
        let sid = solutionID.lowercased()
        let (listing, v) = try await visibleSolution(cloud, id: sid)
        let secret = try await secret(listing)
        let records: [CommunityRecord]
        do {
            records = try await cloud.query(CommunityQuery(type: CommunityRecordType.correction, equals: [Field.solutionID: .string(sid)],
                                                           limit: Self.discussionLimit), in: .publicDB)
        } catch {
            throw Self.serviceError(error)
        }
        let list = records.compactMap { Self.correction($0, solutionID: sid, me: v.ownerRecordName, secret: secret, cipher: SolutionSharing.cipher) }
        return CommunityCorrections.list(list, me: v.ownerRecordName, solutionOwner: listing.ownerRecordName, blocked: v.blockedOwners,
                                         ignored: correctionStatus.ignored())
    }

    func correctionsForMyOwnSolutions() async throws -> [CommunityCorrection] {
        let (cloud, user) = try await signedIn()
        let records: [CommunityRecord]
        do {
            records = try await cloud.query(CommunityQuery(type: CommunityRecordType.correction, equals: [Field.solutionOwner: .string(user)],
                                                           limit: Self.discussionLimit), in: .publicDB)
        } catch {
            throw Self.serviceError(error)
        }
        let blocked = await viewer(cloud).blockedOwners
        let ignored = correctionStatus.ignored()
        var out: [CommunityCorrection] = []
        let bySolution = Dictionary(grouping: records) { $0[Field.solutionID]?.string ?? "" }
        for (sid, group) in bySolution where !sid.isEmpty {
            // nur eigene Loesungen (das Feld `solutionOwner` setzt der Absender), die sich noch oeffnen lassen
            guard let listing = try? await visibleSolution(cloud, id: sid).0, listing.ownerRecordName == user,
                  let secret = try? await secret(listing) else { continue }
            out += group.compactMap { Self.correction($0, solutionID: sid, me: user, secret: secret, cipher: SolutionSharing.cipher) }
        }
        return CommunityCorrections.list(out, me: user, solutionOwner: user, blocked: blocked, ignored: ignored)
            .filter { !$0.isMine }
    }

    func deleteCorrection(id: String) async throws {
        let (cloud, user) = try await signedIn()
        let record: CommunityRecord?
        do { record = try await cloud.fetch(name: id.lowercased(), type: CommunityRecordType.correction, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
        guard let record else { throw CommunityServiceError.service("Korrektur nicht gefunden.") }
        guard Self.owner(record, me: user) == user else {
            throw CommunityServiceError.service("Nur der Verfasser kann seine Korrektur zurücknehmen.")
        }
        do { try await cloud.delete(name: record.name, type: CommunityRecordType.correction, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
    }
}

/// Zustand "Ignoriert" je Dienst: im aktiven Container in dessen Einstellungen, sonst (Tests, kein Container) im Speicher
enum CorrectionStatusRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stores: [ObjectIdentifier: CommunityCorrectionStatusStore] = [:]

    static func store(for service: CloudKitCommunityService) -> CommunityCorrectionStatusStore {
        if let c = ActiveContainer.current, c.community === service { return CommunityCorrectionStatusStore(defaults: c.defaults) }
        return lock.withLock {
            if let s = stores[ObjectIdentifier(service)] { return s }
            let s = CommunityCorrectionStatusStore(defaults: nil)
            stores[ObjectIdentifier(service)] = s
            return s
        }
    }
}
