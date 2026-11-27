import AVFoundation
import Foundation
import UIKit
import UniFlowCore
import WhisperKit

// "Bessere Mitschrift" mit Whisper auf dem Geraet (1.0.8, docs/WHISPER-MITSCHRIFT.md).
//
// Die Erkennung von Apple (`LectureRecorder`, `AudioTranscriber`) bleibt der Weg ohne Download. Wer will, laedt einmal
// ein Sprachmodell (WhisperKit, CoreML) und bekommt damit eine genauere Mitschrift fuer eigene Aufnahmen, Audio-Dateien
// und geladene Uni-Aufzeichnungen. Alles laeuft auf dem Geraet: geladen wird nur das Modell (vom Modell-Verzeichnis bei
// Hugging Face), Ton und Text verlassen das Geraet nicht.
//
// Aufbau: `WhisperModelStore` (Modelle laden, loeschen, Stand), `WhisperEngine` (das geladene Modell, ein Stueck Ton zu
// Text), `WhisperAudio` (Tonspur einer Audio- oder Videodatei in Stuecken als 16 kHz mono), `WhisperJobs` (eine Aufnahme
// von vorn bis hinten, mit Zwischenstand in der Datenbank, Abbrechen und Weitermachen). Die Regeln fuer Stuecke und das
// Aufraeumen der Ergebnisse stehen im Kern (`WhisperSlices`, ohne WhisperKit testbar).

enum WhisperFeature {
    /// Wird "Bessere Mitschrift" angeboten? Aus = keine Karte, keine Knoepfe, kein Download; die Erkennung von Apple
    /// bleibt wie bisher.
    static var isEnabled = true
    /// Fachwoerter-Hilfe: Begriffe aus den Vorlesungen und Skripten des Moduls gehen als Vorgabe an Whisper
    /// (`WhisperVocabulary`); aus = Erkennung ohne Vorgabe wie zuerst gebaut.
    static var usesVocabulary = true
}

struct WhisperFailure: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Tonspur lesen

enum WhisperAudio {
    static let sampleRate = 16_000.0

    /// Laenge der Tonspur in Sekunden; nil ohne Tonspur oder bei unlesbarer Datei
    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    /// Ein Stueck der Tonspur als 16 kHz mono (Float), aus Audio- und Videodateien (m4a, mp3, mp4, mov …). Liest nur
    /// das Stueck, nie die ganze Datei: 3 Minuten sind 11,5 MB.
    static func samples(url: URL, start: Double, length: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WhisperFailure("Die Datei hat keine Tonspur.") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperFailure("Die Tonspur lässt sich nicht lesen.") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 48_000),
                                       duration: CMTime(seconds: max(0, length), preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? WhisperFailure("Die Tonspur lässt sich nicht lesen.") }
        var out: [Float] = []
        out.reserveCapacity(Int(length * sampleRate) + 4096)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= 4 else { continue }
            var chunk = [Float](repeating: 0, count: bytes / 4)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (bytes / 4) * 4, destination: base)
            }
            if status == kCMBlockBufferNoErr { out.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw reader.error ?? WhisperFailure("Die Tonspur lässt sich nicht lesen.") }
        return out
    }
}

// MARK: - Geladenes Modell

/// Das geladene Sprachmodell. Ein Modell zur Zeit; `load` ist beim selben Modell sofort fertig.
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var kit: WhisperKit?
    private var loaded: String?

    var loadedVariant: String? { loaded }

    /// Modell aus dem Ordner laden. Der erste Lauf nach dem Download (und nach einem iOS-Update) richtet das Modell
    /// fuer den Chip des Geraets ein und holt das Woerterbuch; das kann eine Minute dauern.
    func load(variant: String, folder: URL, base: URL) async throws {
        if loaded == variant, kit != nil { return }
        kit = nil
        loaded = nil
        let config = WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder.path, verbose: false, logLevel: .none,
                                      prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        loaded = variant
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
        loaded = nil
    }

    /// Vorgabe und erkannter Text teilen sich bei WhisperKit einen Rahmen von 224 Wortteilen je 30 Sekunden Ton
    /// (`Constants.maxTokenContext`). 30 Sekunden Vorlesung brauchen bis etwa 170; eine lange Vorgabe schneidet den Text
    /// ab (gemessen 24.11.2026: 179 Wortteile Vorgabe -> doppelte Dauer und 30 Sekunden Text verloren). Darum kurz:
    /// rund zehn Begriffe.
    static let maxPromptTokens = 40

    private var promptKey = ""
    private var promptTokens: [Int] = []

    /// Fachwoerter als Wortteile fuer die Vorgabe, wichtigste zuerst und nur so viele, wie hineinpassen. Je Wortliste
    /// einmal gebildet.
    func prompt(terms: [String], language: String) -> [Int] {
        guard let tokenizer = kit?.tokenizer, !terms.isEmpty else { return [] }
        let key = (loaded ?? "") + "\u{1F}" + language + "\u{1F}" + terms.joined(separator: "\u{1F}")
        if key == promptKey { return promptTokens }
        var used = terms
        var tokens: [Int] = []
        while !used.isEmpty {
            tokens = tokenizer.encode(text: " " + WhisperVocabulary.prompt(terms: used, language: language))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if tokens.count <= Self.maxPromptTokens { break }
            used.removeLast(max(1, used.count / 8))
            tokens = []
        }
        promptKey = key
        promptTokens = tokens
        return tokens
    }

    /// Ein Stueck Ton (16 kHz mono) zu Segmenten mit Zeiten ab Beginn des Stuecks. `stop` wird waehrend der Erkennung
    /// gefragt; true bricht das Stueck ab. `terms`: Fachwoerter als Vorgabe (`WhisperVocabulary`); bleibt ein Stueck
    /// damit ganz ohne Text, wird es einmal ohne Vorgabe erkannt.
    func transcribe(samples: [Float], language: String, terms: [String] = [], stop: @escaping @Sendable () -> Bool) async throws -> [WhisperRawSegment] {
        guard kit != nil else { throw WhisperFailure("Das Sprachmodell ist nicht geladen.") }
        guard !samples.isEmpty else { return [] }
        let prompt = prompt(terms: terms, language: language)
        let first = try await decode(samples: samples, language: language, prompt: prompt, stop: stop)
        guard !prompt.isEmpty, !stop(), first.allSatisfy({ WhisperSlices.clean($0.text).isEmpty }) else { return first }
        return try await decode(samples: samples, language: language, prompt: [], stop: stop)
    }

    private func decode(samples: [Float], language: String, prompt: [Int], stop: @escaping @Sendable () -> Bool) async throws -> [WhisperRawSegment] {
        guard let kit else { throw WhisperFailure("Das Sprachmodell ist nicht geladen.") }
        var options = DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
                                      chunkingStrategy: ChunkingStrategy.none)
        if !prompt.isEmpty {
            options.promptTokens = prompt
            // Mit Vorgabe haelt WhisperKit ein Fenster manchmal faelschlich fuer Stille (das erste Wortteil nach der
            // Vorgabe ist dem Modell weniger sicher) und laesst 30 Sekunden Ton aus (gemessen 24.11.2026). Die Pruefung
            // gilt darum nur ohne Vorgabe.
            options.firstTokenLogProbThreshold = nil
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in stop() ? false : nil })
        return results.flatMap(\.segments).map {
            WhisperRawSegment(start: Double($0.start), end: Double($0.end), text: $0.text, noSpeech: Double($0.noSpeechProb))
        }
    }
}

// MARK: - Modelle laden und loeschen

@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    enum State: Equatable {
        case missing
        /// laedt; Anteil 0 ... 1
        case downloading(Double)
        /// geladen, wird fuer das Geraet eingerichtet
        case preparing
        case ready
        case failed(String)
    }

    static let activeKey = "whisper.model"
    /// Marke im Modellordner: Download vollstaendig und einmal geladen
    static let marker = ".studinow-bereit"

    @Published private(set) var states: [String: State] = [:]
    /// Modell, das fuer neue Mitschriften benutzt wird (Kennung aus `WhisperModels`)
    @Published private(set) var activeID: String?

    let base: URL
    private let defaults: UserDefaults
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Ordner fuer Modelle: Application Support/Whisper, nicht in der iCloud-/Geraete-Sicherung (wird neu geladen)
    nonisolated static var standardBase: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Whisper", isDirectory: true)
    }

    init(base: URL = WhisperModelStore.standardBase, defaults: UserDefaults = .standard) {
        self.base = base
        self.defaults = defaults
        refresh()
    }

    // MARK: Stand

    func folder(_ choice: WhisperModelChoice) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true).appendingPathComponent(choice.variant, isDirectory: true)
    }

    func isReady(_ choice: WhisperModelChoice) -> Bool {
        FileManager.default.fileExists(atPath: folder(choice).appendingPathComponent(Self.marker).path)
    }

    func state(_ choice: WhisperModelChoice) -> State { states[choice.id] ?? .missing }

    /// Stand von der Platte lesen (laufende Downloads bleiben)
    func refresh() {
        for c in WhisperModels.all {
            switch states[c.id] {
            case .downloading, .preparing: continue
            case .failed where !isReady(c): continue
            default: states[c.id] = isReady(c) ? .ready : .missing
            }
        }
        let saved = defaults.string(forKey: Self.activeKey)
        let ready = WhisperModels.all.filter(isReady)
        activeID = ready.first { $0.id == saved }?.id ?? ready.first?.id
    }

    /// Das Modell fuer neue Mitschriften; nil, solange keins geladen ist
    var active: WhisperModelChoice? { WhisperModels.choice(id: activeID).flatMap { isReady($0) ? $0 : nil } }

    func use(_ choice: WhisperModelChoice) {
        guard isReady(choice) else { return }
        defaults.set(choice.id, forKey: Self.activeKey)
        activeID = choice.id
    }

    /// Modelle, die WhisperKit fuer dieses Geraet freigibt (Ordnernamen)
    nonisolated static func supportedVariants() -> [String] { WhisperKit.recommendedModels().supported }

    /// Belegter Speicher eines Modells in Bytes (auch eines angefangenen Downloads)
    func bytesOnDisk(_ choice: WhisperModelChoice) -> Int64 {
        Self.size(of: folder(choice))
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Freier Speicher in Bytes; nil, wenn das System keine Zahl nennt
    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let dir = url.deletingLastPathComponent()
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Reicht der Platz fuer Download und Einrichten? (Modell plus die Haelfte obendrauf)
    nonisolated static func enoughSpace(megabytes: Int, free: Int64?) -> Bool {
        guard let free else { return true }
        return free >= Int64(Double(megabytes) * 1.5 * 1_000_000)
    }

    // MARK: Laden

    func download(_ choice: WhisperModelChoice) {
        guard WhisperFeature.isEnabled, tasks[choice.id] == nil, !isReady(choice) else { return }
        guard Self.enoughSpace(megabytes: choice.megabytes, free: Self.freeBytes(at: base)) else {
            states[choice.id] = .failed("Zu wenig freier Speicher: gebraucht werden etwa \(Int(Double(choice.megabytes) * 1.5)) MB.")
            return
        }
        states[choice.id] = .downloading(0)
        let base = self.base
        let report: @Sendable (Double) -> Void = { [weak self] f in
            Task { @MainActor in self?.progress(choice, f) }
        }
        tasks[choice.id] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var dir = base
                try? dir.setResourceValues(values)
                let folder = try await WhisperKit.download(variant: choice.variant, downloadBase: base, progressCallback: { progress in
                    report(progress.fractionCompleted)
                })
                try Task.checkCancellation()
                self?.states[choice.id] = .preparing
                // Pruefsummen, bevor CoreML die Dateien oeffnet (Sicherheitspruefung 27.11.2026)
                try await WhisperModelStore.verify(variant: choice.variant, folder: folder)
                try await WhisperEngine.shared.load(variant: choice.variant, folder: folder, base: base)
                try Task.checkCancellation()
                try Data().write(to: folder.appendingPathComponent(Self.marker))
                self?.finish(choice, error: nil)
            } catch is CancellationError {
                self?.finish(choice, error: nil)
            } catch {
                self?.finish(choice, error: Self.message(error))
            }
        }
    }

    private func progress(_ choice: WhisperModelChoice, _ fraction: Double) {
        guard case .downloading = states[choice.id] else { return }
        states[choice.id] = .downloading(min(1, max(0, fraction)))
    }

    private func finish(_ choice: WhisperModelChoice, error: String?) {
        tasks[choice.id] = nil
        if let error, !isReady(choice) {
            states[choice.id] = .failed(error)
        } else {
            states[choice.id] = isReady(choice) ? .ready : .missing
        }
        if isReady(choice), active == nil || activeID == nil { use(choice) }
        refresh()
    }

    func cancel(_ choice: WhisperModelChoice) {
        tasks[choice.id]?.cancel()
    }

    /// Modell von diesem Geraet loeschen (auch einen angefangenen Download)
    func delete(_ choice: WhisperModelChoice) async {
        tasks[choice.id]?.cancel()
        tasks[choice.id] = nil
        if await WhisperEngine.shared.loadedVariant == choice.variant { await WhisperEngine.shared.unload() }
        try? FileManager.default.removeItem(at: folder(choice))
        states[choice.id] = .missing
        refresh()
    }

    /// Meldung in einfachen Worten
    /// Marke "Pruefsummen dieses Modellordners passen" (mit dem Stand der Liste im Namen: neue Liste = neu pruefen)
    nonisolated static var verifiedMarker: String { ".geprueft-\(WhisperModelIntegrity.revision.prefix(12))" }

    /// Modellordner gegen `WhisperModelIntegrity` pruefen (im Hintergrund, mehrere hundert MB). Passt etwas nicht, wird
    /// der Ordner geloescht und nichts davon benutzt; passt alles, kommt die Marke `verifiedMarker` dazu.
    nonisolated static func verify(variant: String, folder: URL) async throws {
        let problems = await Task.detached(priority: .utility) { WhisperModelIntegrity.problems(variant: variant, folder: folder) }.value
        guard problems.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            throw WhisperFailure("Das Sprachmodell ließ sich nicht prüfen und wurde gelöscht. Bitte lade es erneut; hilft das nicht, schreib uns an support@studinow.app.")
        }
        try? Data().write(to: folder.appendingPathComponent(verifiedMarker))
    }

    nonisolated static func message(_ error: Error) -> String {
        if let f = error as? WhisperFailure { return f.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost
                ? "Keine Internetverbindung. Der Download geht später an derselben Stelle weiter."
                : "Der Download ist fehlgeschlagen (\(ns.localizedDescription))."
        }
        return error.localizedDescription
    }
}

// MARK: - Eine Aufnahme umwandeln

@MainActor
final class WhisperJobs: ObservableObject {
    static let shared = WhisperJobs()

    enum State: Equatable {
        /// wartet, bis die Aufnahme davor fertig ist
        case waiting
        case loadingModel
        /// laeuft; Anteil 0 ... 1
        case running(Double)
        /// kurze Pause, weil das Geraet warm ist (`WhisperPacing`); Anteil 0 ... 1
        case cooling(Double)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    /// zaehlt hoch, wenn eine Mitschrift fertig oder abgebrochen ist (Listen laden neu)
    @Published private(set) var revision = 0

    private var tasks: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private let store: WhisperModelStore

    init(store: WhisperModelStore? = nil) { self.store = store ?? .shared }

    func state(_ id: String) -> State? { states[id] }

    func isActive(_ id: String) -> Bool {
        switch states[id] {
        case .waiting, .loadingModel, .running, .cooling: return true
        default: return false
        }
    }

    var anyActive: Bool { states.keys.contains(where: isActive) }

    /// Mitschrift einer Aufnahme erstellen oder weitermachen. `sections`: schon fertige Abschnitte einer frueheren,
    /// unterbrochenen Whisper-Erkennung (sonst leer – eine Mitschrift von Apple wird ersetzt, sobald die neue fertig ist).
    func start(id: String, url: URL, language: String?, resume sections: [TranscriptSection] = [], api: APIClient) {
        guard WhisperFeature.isEnabled, !isActive(id) else { return }
        guard store.active != nil else {
            states[id] = .failed("Kein Sprachmodell geladen.")
            return
        }
        states[id] = .waiting
        let before = tail
        let task = Task { [weak self] in
            await before?.value
            guard let self, !Task.isCancelled else { return }
            await self.run(id: id, url: url, language: WhisperSlices.language(language), resume: sections, api: api)
        }
        tasks[id] = task
        tail = task
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        if case .waiting = states[id] { states[id] = nil }
    }

    func clearFailure(_ id: String) {
        if case .failed = states[id] { states[id] = nil }
    }

    private func run(id: String, url: URL, language: String, resume: [TranscriptSection], api: APIClient) async {
        var sections = resume
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            tasks[id] = nil
            if !anyActiveExcept(id) { UIApplication.shared.isIdleTimerDisabled = false }
            revision += 1
        }
        do {
            states[id] = .loadingModel
            let vocabulary: Vocabulary = { said in
                await Self.terms { try await api.value("/api/recordings/own/vocabulary", method: "POST", body: ["id": .string(id), "text": .string(said)]) }
            }
            let cooling: @MainActor (Bool) -> Void = { [weak self] on in
                guard let self else { return }
                switch (on, self.states[id]) {
                case (true, .running(let f)): self.states[id] = .cooling(f)
                case (true, .loadingModel): self.states[id] = .cooling(0)
                case (false, .cooling(let f)): self.states[id] = .running(f)
                default: break
                }
            }
            sections = try await Self.transcribe(url: url, language: language, store: store, vocabulary: vocabulary, resume: resume, cooling: cooling) { [weak self] fraction, duration, done in
                self?.states[id] = .running(fraction)
                var body: [String: JSONValue] = ["transcript_status": .string(done.isEmpty ? "running" : "partial"), "transcript_engine": "whisper",
                                                 "duration": .number(duration)]
                if !done.isEmpty { body["transcript"] = TranscriptSections.json(done) }
                sections = done.isEmpty ? sections : done
                _ = try? await api.value("/api/recordings/own/\(id)", method: "PATCH", body: .object(body))
            }
            _ = try await api.value("/api/recordings/own/\(id)", method: "PATCH",
                                    body: ["transcript": TranscriptSections.json(sections), "transcript_status": .string(sections.isEmpty ? "failed" : "done"),
                                           "transcript_engine": "whisper"])
            states[id] = sections.isEmpty ? .failed("Es wurde keine Sprache erkannt.") : nil
        } catch {
            // Abbruch und Fehler: was fertig ist, bleibt ("teilweise"); spaeter geht es an der Stelle weiter
            _ = try? await api.value("/api/recordings/own/\(id)", method: "PATCH", body: ["transcript_status": .string(sections.isEmpty ? "none" : "partial")])
            states[id] = error is CancellationError || Task.isCancelled ? nil : .failed(WhisperModelStore.message(error))
        }
    }

    /// Fachwoerter fuer das naechste Stueck; bekommt, was zuletzt erkannt wurde ("" am Anfang). Die App liest damit im
    /// Skript des Moduls mit (`POST /api/recordings/own/vocabulary`, `WhisperGlossary`).
    typealias Vocabulary = @MainActor (_ said: String) async -> [String]

    /// Antwort der Route zu einer Wortliste; ohne Modul, ohne lesbare Dateien oder bei einem Fehler leer – dann
    /// erkennt Whisper ohne Vorgabe.
    static func terms(_ load: () async throws -> JSONValue?) async -> [String] {
        guard WhisperFeature.usesVocabulary, let answer = try? await load() else { return [] }
        return answer["terms"]?.array?.compactMap(\.string) ?? []
    }

    /// Eine ganze Audio- oder Videodatei zu Abschnitten, Stueck fuer Stueck. `resume`: fertige Abschnitte eines
    /// frueheren Laufs (es geht an ihrem Ende weiter). `step` kommt vor dem ersten und nach jedem Stueck mit Anteil,
    /// Laenge der Datei und dem Stand der Abschnitte. `vocabulary`: Fachwoerter je Stueck als Vorgabe fuer das Modell
    /// (nil = ohne). Wirft bei Abbruch `CancellationError`.
    /// Waermestufe des Geraets (0 normal ... 3 kritisch) und das Warten – in Tests austauschbar
    static var thermalLevel: @MainActor () -> Int = { ProcessInfo.processInfo.thermalState.rawValue }
    static var pause: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// Pause vor einem Stueck, wenn das Geraet warm ist; bei "kritisch" erst weiter, wenn es kuehler ist (hoechstens
    /// zehn Minuten). `cooling` meldet Anfang und Ende der Pause fuer die Anzeige.
    static func coolDown(_ cooling: (@MainActor (Bool) -> Void)? = nil) async {
        var level = thermalLevel()
        guard WhisperPacing.pause(level: level) > 0 else { return }
        cooling?(true)
        defer { cooling?(false) }
        var waited = 0.0
        while WhisperPacing.mustCool(level: level), waited < WhisperPacing.maxWait, !Task.isCancelled {
            await pause(WhisperPacing.checkEvery)
            waited += WhisperPacing.checkEvery
            level = thermalLevel()
        }
        let rest = WhisperPacing.pause(level: level)
        if rest > 0, !Task.isCancelled { await pause(rest) }
    }

    /// `cooling`: meldet Pausen zum Abkuehlen (true = beginnt, false = vorbei).
    static func transcribe(url: URL, language: String, store: WhisperModelStore, vocabulary: Vocabulary? = nil, resume: [TranscriptSection] = [],
                           cooling: (@MainActor (Bool) -> Void)? = nil,
                           step: @MainActor (_ fraction: Double, _ duration: Double, _ sections: [TranscriptSection]) async -> Void) async throws -> [TranscriptSection] {
        guard let choice = store.active else { throw WhisperFailure("Kein Sprachmodell geladen.") }
        // vor dieser Pruefung geladene Modelle: einmal nachpruefen (Marke `verifiedMarker`), dann nicht mehr
        let folder = store.folder(choice)
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(WhisperModelStore.verifiedMarker).path) {
            try await WhisperModelStore.verify(variant: choice.variant, folder: folder)
        }
        try await WhisperEngine.shared.load(variant: choice.variant, folder: folder, base: store.base)
        guard let duration = await WhisperAudio.duration(of: url) else { throw WhisperFailure("Die Datei hat keine lesbare Tonspur.") }
        var sections = resume
        var segments: [TranscriptSegment] = []
        var position = WhisperSlices.resumePosition(resume)
        // was zuletzt gesagt wurde: beim Weitermachen das Ende der fertigen Abschnitte
        var said = String(resume.suffix(3).map(\.text).joined(separator: " ").suffix(3000))
        await step(WhisperSlices.progress(position: position, duration: duration), duration, [])
        while let slice = WhisperSlices.slice(from: position, duration: duration) {
            try Task.checkCancellation()
            await waitUntilActive()
            await coolDown(cooling)
            try Task.checkCancellation()
            let terms = await vocabulary?(said) ?? []
            let samples = try await WhisperAudio.samples(url: url, start: slice.start, length: slice.length)
            let raw: [WhisperRawSegment]
            do {
                raw = try await WhisperEngine.shared.transcribe(samples: samples, language: language, terms: terms, stop: { Task.isCancelled })
            } catch {
                // im Hintergrund darf der Grafikchip nicht rechnen: warten, bis die App wieder vorn ist, einmal neu
                guard !Task.isCancelled, !isActiveNow() else { throw error }
                await waitUntilActive()
                raw = try await WhisperEngine.shared.transcribe(samples: samples, language: language, terms: terms, stop: { Task.isCancelled })
            }
            try Task.checkCancellation()
            let placed = WhisperSlices.place(raw, sliceStart: slice.start, sliceLength: slice.length, isLast: slice.isLast, vocabulary: terms)
            segments.append(contentsOf: placed.segments)
            if !placed.segments.isEmpty { said = String(placed.segments.map(\.text).joined(separator: " ").suffix(3000)) }
            position = max(placed.next, slice.start + 1)
            sections = WhisperSlices.merge(resume, with: segments)
            await step(WhisperSlices.progress(position: position, duration: duration), duration, sections)
        }
        return sections
    }

    private func anyActiveExcept(_ id: String) -> Bool { states.keys.contains { $0 != id && isActive($0) } }

    static func isActiveNow() -> Bool { UIApplication.shared.applicationState == .active }

    /// Wartet, bis die App vorn ist (CoreML darf im Hintergrund nicht auf den Grafikchip)
    static func waitUntilActive() async {
        while !isActiveNow(), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
