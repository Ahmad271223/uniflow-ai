import Foundation

// Gemeinsame Wochentests mit Varianten (docs/GEMEINSAME-WOCHENTESTS.md, Regel des Inhabers vom 04.11.2026): Wer dieselben
// Dateien hat, teilt sich hoechstens DREI Tests. Dieser Teil des Kerns kennt keinen Dienst: `WeeklyTestShareProvider`
// ist die schmale Schnittstelle (Plaetze lesen, Platz belegen, veroeffentlichen, freigeben), die die App mit CloudKit
// umsetzt (WeeklyTestCloudKit.swift) und V2 mit dem Dienst (`/api/v2/shared-tests`, app/library_api.py). Der Ablauf
// (`WeeklyTestShare.obtain`) ist derselbe wie `testshare.obtain` am PC:
//   1. eigene Variante fertig          -> uebernehmen (keine KI)
//   2. eigene Variante in Arbeit       -> kurz warten, dann uebernehmen
//   3. weniger als drei Plaetze belegt -> Platz belegen (eigene, bei Wettlauf die naechste freie), erzeugen, veroeffentlichen
//   4. drei belegt, eine andere fertig -> die naechste fertige uebernehmen; nie erzeugen, wenn drei fertig sind
//   5. ohne Dienst, ohne Anmeldung, Dienst nicht erreichbar oder alle Plaetze belegt und keiner fertig -> eigener Test
// Inhalt beim Dienst nur verschluesselt (`WeeklyTestCrypto`): Schluessel per HKDF aus den Inhalts-Hashes der Dateien,
// die nie den Dienst sehen; nur wer dieselben Dateien hat, kann lesen.

/// Gemeinsamer Wochentest, wie er beim Dienst liegt: Titel ohne Lehrwoche, Aufgaben als Python-JSON (Reihenfolge und
/// Zahlen bleiben byte-gleich wie in der Datenbank des Erzeugers)
public struct SharedWeeklyTest: Equatable, Sendable {
    public var title: String
    public var questions: PyJSON

    public init(title: String, questions: PyJSON) {
        self.title = title
        self.questions = questions
    }

    /// Klartext des Chiffrats: `{"questions": [...], "title": "..."}` wie `json.dumps(..., ensure_ascii=False)`
    var plaintext: Data {
        Data(PyJSON.object([.init("questions", questions), .init("title", .string(title))]).dumps(ensureASCII: false).utf8)
    }

    /// Gelesen wird nur, was auch geschrieben wird (fremde Datensaetze sind ungeprueft): Titel als Text, Aufgaben als Liste
    init(plaintext: Data) throws {
        let json = try PyJSON.parse(plaintext)
        guard case .string(let title)? = AIPrompts.get(json, "title"), case .array? = AIPrompts.get(json, "questions") else {
            throw SolutionError.decryptionFailed
        }
        self.init(title: title, questions: AIPrompts.get(json, "questions") ?? .array([]))
    }
}

/// Schluessel und Material eines gemeinsamen Tests. Die Inhalts-Hashes bleiben auf dem Geraet (Schluesselmaterial);
/// nur der Schluessel (ein Hash darueber) geht zum Dienst.
public struct WeeklyTestMaterial: Equatable, Sendable {
    public let key: String
    /// sortiert und eindeutig (`TestShare.shareKey` rechnet genauso)
    public let contentHashes: [String]

    public init?(university: String, minutes: Int?, contentHashes: [String?]) {
        guard let key = TestShare.shareKey(university: university, minutes: minutes, contentHashes: contentHashes) else { return nil }
        self.key = key
        self.contentHashes = Set(contentHashes.compactMap { $0 }).sorted()
    }

    public init(key: String, contentHashes: [String]) {
        self.key = key
        self.contentHashes = Set(contentHashes).sorted()
    }
}

/// Zustand eines Platzes (Variante) beim Dienst
public enum WeeklyTestSlot: Equatable, Sendable {
    /// fertig, lesbar
    case ready(SharedWeeklyTest)
    /// belegt, Inhalt kommt noch (UTC-Sekunden der Belegung)
    case pending(since: Double)
    /// vorhanden, aber nicht lesbar (anderer Schluessel, beschaedigt): zaehlt als belegt, wird nie uebernommen
    case broken
}

/// Dienst fuer gemeinsame Wochentests (CloudKit in der App, V2 der Dienst). Alle Aufrufe duerfen werfen (offline,
/// nicht angemeldet); der Kern weicht dann auf einen eigenen Test aus.
public protocol WeeklyTestShareProvider: Sendable {
    /// Quelle fuer `tests.adopted_from` (`TestShare.adoptedCloudKit`, `adoptedService`)
    var sourceName: String { get }
    /// Nutzerkennung beim Dienst (nur fuer die Zuteilung der Variante); nil = nicht angemeldet, dann wird nicht geteilt
    func userID() async throws -> String?
    /// Vorhandene Plaetze zum Schluessel
    func slots(_ material: WeeklyTestMaterial) async throws -> [Int: WeeklyTestSlot]
    /// Platz atomar belegen; false, wenn ihn gerade ein anderer belegt hat
    func claim(_ material: WeeklyTestMaterial, variant: Int) async throws -> Bool
    /// Fertigen Test in den eigenen Platz schreiben
    func publish(_ material: WeeklyTestMaterial, variant: Int, test: SharedWeeklyTest) async throws
    /// Eigenen leeren Platz wieder freigeben (Erzeugen gescheitert)
    func release(_ material: WeeklyTestMaterial, variant: Int) async throws
}

/// Halter des Dienstes im `LocalContext` (wie `LocalAI`), von der App gesetzt
public final class LocalTestShare: @unchecked Sendable {
    private let lock = NSLock()
    private var current: WeeklyTestShareProvider?
    private var currentWaiting = WeeklyTestShare.Waiting.standard

    public init() {}

    public var provider: WeeklyTestShareProvider? { lock.withLock { current } }
    /// Warte- und Abfragezeiten (Tests setzen kurze)
    public var waiting: WeeklyTestShare.Waiting { lock.withLock { currentWaiting } }

    public func set(_ provider: WeeklyTestShareProvider?, waiting: WeeklyTestShare.Waiting = .standard) {
        lock.withLock {
            current = provider
            currentWaiting = waiting
        }
    }
}

public enum WeeklyTestShare {
    /// Wie lange auf die Variante gewartet wird, die ein anderer gerade erzeugt, und ab wann eine Belegung ohne
    /// Inhalt als verwaist gilt (`testshare.PENDING_STALE_S`)
    public struct Waiting: Sendable {
        public var pollSeconds: Double
        public var maxWaitSeconds: Double
        public var staleSeconds: Double
        public var sleep: @Sendable (Double) async throws -> Void

        public init(pollSeconds: Double, maxWaitSeconds: Double, staleSeconds: Double = 10 * 60,
                    sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
            self.pollSeconds = pollSeconds
            self.maxWaitSeconds = maxWaitSeconds
            self.staleSeconds = staleSeconds
            self.sleep = sleep
        }

        public static let standard = Waiting(pollSeconds: 5, maxWaitSeconds: 120)
        /// ohne Warten (Tests, Hintergrund ohne Zeit)
        public static let none = Waiting(pollSeconds: 0, maxWaitSeconds: 0, sleep: { _ in })
    }

    /// Stand fuer die Oberflaeche waehrend des Hintergrundauftrags (`/api/bg` → `phase`): "Suche gemeinsamen Test …"
    public enum Phase: String, Sendable {
        case lookup = "shared_lookup", waiting = "shared_wait", generating = "generate", adopted = "shared_adopted"
    }

    public enum Outcome: Equatable, Sendable {
        /// vom Dienst uebernommen (keine KI)
        case adopted(variant: Int, SharedWeeklyTest, from: String)
        /// selbst erzeugt und als Variante veroeffentlicht (`published` false: Veroeffentlichen gescheitert, Test bleibt lokal)
        case generated(variant: Int, SharedWeeklyTest, published: Bool)
        /// eigener Test ohne Dienst (nicht angemeldet, Dienst nicht erreichbar, alle Plaetze belegt und keiner fertig);
        /// die Variante wird gemerkt, wenn der Nutzer bekannt ist
        case unshared(variant: Int?, SharedWeeklyTest)

        public var test: SharedWeeklyTest {
            switch self {
            case .adopted(_, let t, _), .generated(_, let t, _), .unshared(_, let t): return t
            }
        }

        /// (`tests.share_variant`, `tests.adopted_from`)
        public var columns: (variant: Int?, adoptedFrom: String?) {
            switch self {
            case .adopted(let v, _, let from): return (v, from)
            case .generated(let v, _, _): return (v, nil)
            case .unshared(let v, _): return (v, nil)
            }
        }
    }

    /// Fehler der KI (nicht des Dienstes) gehen unveraendert nach oben
    private struct GenerationFailed: Error { let underlying: Error }

    /// Den gemeinsamen Test zum Material holen oder erzeugen (Ablauf oben). `now`: UTC-Sekunden (Uhr des Backends),
    /// `phase`: Stand fuer die Oberflaeche, `generate`: die KI des Nutzers (laeuft hoechstens einmal).
    public static func obtain(_ material: WeeklyTestMaterial, provider: WeeklyTestShareProvider?, waiting: Waiting = .standard,
                              now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                              phase: @escaping @Sendable (Phase) async -> Void = { _ in },
                              generate: @escaping @Sendable () async throws -> SharedWeeklyTest) async throws -> Outcome {
        let gen: @Sendable () async throws -> SharedWeeklyTest = {
            do { return try await generate() } catch { throw GenerationFailed(underlying: error) }
        }
        guard let provider else {
            await phase(.generating)
            return .unshared(variant: nil, try await generate())
        }
        var assigned: Int?
        do {
            await phase(.lookup)
            guard let user = try await provider.userID() else {
                await phase(.generating)
                return .unshared(variant: nil, try await generate())
            }
            let mine = TestShare.variant(userID: user, key: material.key)
            assigned = mine
            var waited = 0.0
            for _ in 0...TestShare.maxVariants {
                await phase(.lookup)
                let slots = try await provider.slots(material)
                if case .ready(let t)? = slots[mine] {
                    await phase(.adopted)
                    return .adopted(variant: mine, t, from: provider.sourceName)
                }
                if case .pending(let since)? = slots[mine], now() - since < waiting.staleSeconds, waited < waiting.maxWaitSeconds {
                    // ein anderer erzeugt genau diese Variante: abwarten statt doppelt erzeugen
                    await phase(.waiting)
                    var released = false
                    while waited < waiting.maxWaitSeconds {
                        let step = min(max(waiting.pollSeconds, 0.001), waiting.maxWaitSeconds - waited)
                        try await waiting.sleep(step)
                        waited += step
                        let again = try await provider.slots(material)
                        if case .ready(let t)? = again[mine] {
                            await phase(.adopted)
                            return .adopted(variant: mine, t, from: provider.sourceName)
                        }
                        guard case .pending(let s)? = again[mine], now() - s < waiting.staleSeconds else { released = true; break }
                    }
                    if released { continue }                  // freigegeben oder verwaist: Lage neu ansehen
                }
                // fertige Plaetze, belegte ohne Inhalt (auch verwaiste und unlesbare: die kann niemand ueberschreiben)
                let ready = Set(slots.compactMap { k, s -> Int? in if case .ready = s { return k } else { return nil } })
                let (action, picked) = TestShare.pick(ready: ready, assigned: mine, pending: Set(slots.keys).subtracting(ready))
                switch action {
                case .adopt:
                    guard let k = picked, case .ready(let t)? = slots[k] else { continue }
                    await phase(.adopted)
                    return .adopted(variant: k, t, from: provider.sourceName)
                case .none:
                    // alle drei belegt, keiner lesbar: eigener Test ohne Veroeffentlichung
                    await phase(.generating)
                    return .unshared(variant: mine, try await gen())
                case .generate:
                    break
                }
                guard let v = picked, try await provider.claim(material, variant: v) else { continue }     // Wettlauf: neu ansehen
                await phase(.generating)
                let test: SharedWeeklyTest
                do { test = try await gen() } catch {
                    try? await provider.release(material, variant: v)
                    throw error
                }
                do {
                    try await provider.publish(material, variant: v, test: test)
                    return .generated(variant: v, test, published: true)
                } catch {
                    try? await provider.release(material, variant: v)
                    return .generated(variant: v, test, published: false)
                }
            }
            await phase(.generating)
            return .unshared(variant: mine, try await gen())
        } catch let e as GenerationFailed {
            throw e.underlying
        } catch {
            // Dienst nicht erreichbar oder nicht angemeldet: eigener Test wie bisher
            await phase(.generating)
            return .unshared(variant: assigned, try await generate())
        }
    }
}

/// Verschluesselung des Inhalts beim Dienst (Datensatz `WeeklyTest`, Feld `payload`): Schluessel per HKDF-SHA256 aus
/// den sortierten Inhalts-Hashes der Dateien (`keyMaterial`) mit Salz je Datensatz, AES-256-GCM ueber `SolutionCipher`;
/// Zusatzdaten binden das Chiffrat an Schluessel und Variante (kein Umhaengen). Der Schluessel liegt nie beim Dienst:
/// wer die Dateien nicht hat, kann weder das Material bilden noch lesen.
public enum WeeklyTestCrypto {
    static let format = "uniflow-weekly-test"
    static let payloadVersion: UInt8 = 1
    static let saltBytes = 32, nonceBytes = 12, tagBytes = 16
    /// Chiffrat hoechstens so gross (Base64); groessere werden ungeprueft verworfen
    public static let maxPayloadChars = 512 * 1024

    /// Datensatzname "<Schluessel>#<Variante>": das Anlegen beim Dienst ist damit atomar und eindeutig
    public static func recordName(key: String, variant: Int) -> String { "\(key)#\(variant)" }

    /// Schluesselmaterial (HKDF-Eingabe): die sortierten, eindeutigen Inhalts-Hashes, mit Zeilenumbruch verbunden
    public static func keyMaterial(contentHashes: [String]) -> Data {
        Data(Set(contentHashes).sorted().joined(separator: "\n").utf8)
    }

    static func keyInfo(key: String) -> Data { Data("\(format)/v\(payloadVersion)|\(key)".utf8) }

    static func aad(key: String, variant: Int) -> Data { Data("\(format)/v\(payloadVersion)|\(key)#\(variant)".utf8) }

    /// Test verschluesseln: Base64 aus Version (1 Byte), Salz (32), Nonce (12) und Chiffrat mit Tag
    public static func seal(_ test: SharedWeeklyTest, material: WeeklyTestMaterial, variant: Int, cipher: SolutionCipher,
                            salt: Data? = nil, nonce: Data? = nil) throws -> String {
        let salt = salt ?? SolutionPackage.randomBytes(saltBytes), nonce = nonce ?? SolutionPackage.randomBytes(nonceBytes)
        guard salt.count == saltBytes, nonce.count == nonceBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let plaintext = test.plaintext
        let sealed = try cipher.seal(plaintext, keyMaterial: keyMaterial(contentHashes: material.contentHashes), salt: salt,
                                     info: keyInfo(key: material.key), nonce: nonce, aad: aad(key: material.key, variant: variant))
        guard sealed.count == plaintext.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        return (Data([payloadVersion]) + salt + nonce + sealed).base64EncodedString()
    }

    /// Test entschluesseln und pruefen; falsches Material (andere Dateien), veraendertes oder umgehaengtes Chiffrat werfen
    public static func open(_ payload: String, material: WeeklyTestMaterial, variant: Int, cipher: SolutionCipher) throws -> SharedWeeklyTest {
        guard payload.count <= maxPayloadChars, let raw = Data(base64Encoded: payload),
              raw.count > 1 + saltBytes + nonceBytes + tagBytes, raw[raw.startIndex] == payloadVersion else {
            throw SolutionError.decryptionFailed
        }
        let salt = raw.subdata(in: 1..<(1 + saltBytes)), nonce = raw.subdata(in: (1 + saltBytes)..<(1 + saltBytes + nonceBytes))
        let sealed = raw.subdata(in: (1 + saltBytes + nonceBytes)..<raw.count)
        let plaintext: Data
        do {
            plaintext = try cipher.open(sealed, keyMaterial: keyMaterial(contentHashes: material.contentHashes), salt: salt,
                                        info: keyInfo(key: material.key), nonce: nonce, aad: aad(key: material.key, variant: variant))
        } catch {
            throw SolutionError.decryptionFailed
        }
        return try SharedWeeklyTest(plaintext: plaintext)
    }
}
