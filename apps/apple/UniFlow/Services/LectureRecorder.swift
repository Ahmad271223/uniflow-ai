import AVFoundation
import Foundation
import Speech
import UniFlowCore

// Vorlesung aufnehmen (docs/VORLESUNG-AUFNEHMEN.md): Mikrofon ueber AVAudioEngine, die Puffer gehen gleichzeitig in
// eine m4a-Datei (AAC, im Container unter recordings/eigene/) und in die Spracherkennung von iOS, die nur auf dem
// Geraet laeuft (`requiresOnDeviceRecognition`). Die Erkennung laeuft in Anlaeufen von etwa einer Minute (ein neuer
// Anlauf an einer Sprechpause, spaetestens nach 75 s), die Segmente aller Anlaeufe werden mit ihrem Zeitversatz zu
// Abschnitten (`TranscriptSections.build`). Die Aufnahme laeuft im Hintergrund weiter (UIBackgroundModes audio in
// Info.plist, Kategorie .record). Nichts davon verlaesst das Geraet; die KI bekommt spaeter nur Text und nur auf Antippen.

@MainActor
final class LectureRecorder: ObservableObject {
    enum State: Equatable {
        case idle, recording, paused, finishing, done
        case failed(String)
    }

    /// Stand der Spracherkennung wie `own_recordings.transcript_status`
    enum TranscriptState: String { case none, running, partial, done, failed, unavailable }

    @Published private(set) var state: State = .idle
    /// Pegel 0…1 (RMS des letzten Puffers, fuer die Anzeige geglaettet)
    @Published private(set) var level: Double = 0
    /// aufgenommene Sekunden (ohne Pausen)
    @Published private(set) var seconds: Double = 0
    /// fertige Abschnitte aller abgeschlossenen Anlaeufe (Vorschau waehrend der Aufnahme, Ergebnis danach)
    @Published private(set) var sections: [TranscriptSection] = []
    /// laufende Erkennung des aktuellen Anlaufs (noch nicht endgueltig)
    @Published private(set) var partial = ""
    @Published private(set) var transcript: TranscriptState = .none
    /// Hinweis, warum es kein oder nur ein Teil-Transkript gibt (Erlaubnis, Sprachpaket, Fehler)
    @Published private(set) var transcriptNote: String?

    let id: String
    let fileURL: URL
    /// Sprache der Erkennung ("de-DE", "en-US")
    let locale: Locale

    private let engine = AVAudioEngine()
    private let sink = TapSink()
    private var recognizer: SFSpeechRecognizer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Segmente je Anlauf (Kennung -> Segmente mit absoluten Zeiten)
    private var runs: [Int: [TranscriptSegment]] = [:]
    private var finalRuns = Set<Int>()
    private var runCounter = 0
    private var currentRun: Run?
    /// wartet beim Stoppen auf das letzte Ergebnis
    private var finishing: CheckedContinuation<Void, Never>?

    /// Ein Anlauf der Erkennung: ab `offset` Sekunden der Aufnahme
    private struct Run {
        let id: Int
        let offset: Double
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var startedAt: Double
        var lastSpeech: Double
    }

    /// Dauer eines Anlaufs, ab der eine Sprechpause einen neuen beginnt; spaetestens nach `runHardSeconds`
    static let runTargetSeconds = 60.0
    static let runHardSeconds = 75.0
    /// Pegel, unter dem "Pause" gilt (fuer den Anlaufwechsel)
    static let quietLevel = 0.04

    init(id: String = LocalContext.randomHex(), fileURL: URL, language: String = "de-DE") {
        self.id = id
        self.fileURL = fileURL
        self.locale = Locale(identifier: language)
    }

    /// Sprachen der Erkennung, die die App anbietet (Vorlesungen auf Deutsch oder Englisch)
    static let languages: [(value: String, label: String)] = [("de-DE", "Deutsch"), ("en-US", "Englisch")]

    // MARK: Erlaubnis

    enum Permission: Equatable { case granted, denied, undetermined }

    static func microphonePermission() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Mikrofon-Erlaubnis erfragen (Systemdialog mit NSMicrophoneUsageDescription)
    static func requestMicrophone() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    static func speechPermission() -> Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
    }

    /// Erlaubnis zur Spracherkennung (NSSpeechRecognitionUsageDescription); abgelehnt heisst: Aufnahme ohne Transkript
    static func requestSpeech() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    /// Erkennung auf dem Geraet fuer diese Sprache moeglich? (Sprachpaket geladen, Geraet unterstuetzt sie)
    static func onDeviceAvailable(_ language: String) -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)) else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
    }

    // MARK: Aufnahme

    func start() {
        guard state == .idle else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError("Kein Mikrofon gefunden.") }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: Int(format.channelCount), AVEncoderBitRateKey: 64_000]
            let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            sink.open(file: file, sampleRate: format.sampleRate)
            let sink = self.sink
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in sink.consume(buffer) }
            engine.prepare()
            try engine.start()
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            state = .recording
            observeInterruptions()
            startTimer()
            startSpeech()
        } catch {
            state = .failed("Aufnahme nicht möglich: \(error.localizedDescription)")
            cleanup()
        }
    }

    func pause() {
        guard state == .recording else { return }
        engine.pause()
        endRun(final: false)
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            state = .recording
            beginRun()
        } catch {
            state = .failed("Aufnahme nicht fortsetzbar: \(error.localizedDescription)")
            cleanup()
        }
    }

    /// Aufnahme beenden, auf das letzte Erkennungsergebnis warten (hoechstens 4 s), Datei schliessen
    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        seconds = sink.seconds
        sink.close()
        if let run = currentRun, !finalRuns.contains(run.id) {
            endRun(final: true)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in await self?.waitForFinal() }
                group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        currentRun?.task?.cancel()
        currentRun = nil
        rebuildSections()
        if transcript == .running { transcript = sections.isEmpty ? .failed : .done }
        state = .done
        level = 0
        cleanup()
    }

    /// wartet auf das Endergebnis des letzten Anlaufs (`handle` loest aus); nichts zu warten, wenn es schon da ist
    private func waitForFinal() async {
        if let run = currentRun, finalRuns.contains(run.id) { return }
        await withCheckedContinuation { c in finishing = c }
    }

    /// Alles abbrechen und die Datei verwerfen (Dialog geschlossen, bevor gespeichert wurde)
    func discard() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        currentRun?.task?.cancel()
        currentRun = nil
        sink.close()
        cleanup()
        try? FileManager.default.removeItem(at: fileURL)
        state = .idle
    }

    private func cleanup() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard state == .recording else { return }
        let l = sink.level
        level = level * 0.6 + l * 0.4
        seconds = sink.seconds
        guard var run = currentRun else { return }
        if l >= Self.quietLevel { run.lastSpeech = seconds }
        currentRun = run
        let elapsed = seconds - run.startedAt
        // neuer Anlauf an einer Sprechpause nach 60 s, spaetestens nach 75 s
        if elapsed >= Self.runHardSeconds || (elapsed >= Self.runTargetSeconds && seconds - run.lastSpeech >= 0.6) {
            endRun(final: false)
            beginRun()
        }
    }

    /// Unterbrechung (Anruf, Siri): Aufnahme anhalten; weiter geht es nur auf Antippen
    private func observeInterruptions() {
        let o = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init), type == .began else { return }
            Task { @MainActor [weak self] in self?.pause() }
        }
        observers.append(o)
    }

    // MARK: Spracherkennung auf dem Geraet

    private func startSpeech() {
        guard Self.speechPermission() == .granted else {
            transcript = .unavailable
            transcriptNote = "Ohne Erlaubnis zur Spracherkennung wird nur aufgenommen, nicht mitgeschrieben."
            return
        }
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
            transcript = .unavailable
            transcriptNote = "Spracherkennung für diese Sprache ist auf diesem iPad nicht verfügbar."
            return
        }
        guard r.supportsOnDeviceRecognition else {
            transcript = .unavailable
            transcriptNote = "Die Spracherkennung auf dem Gerät ist für diese Sprache nicht geladen (Einstellungen → Allgemein → Tastatur → Diktieren). Aufgenommen wird trotzdem."
            return
        }
        recognizer = r
        transcript = .running
        beginRun()
    }

    private func beginRun() {
        guard let recognizer, state == .recording || state == .idle else { return }
        runCounter += 1
        let id = runCounter
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true          // nie an Apple-Server
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let offset = seconds
        var run = Run(id: id, offset: offset, request: request, task: nil, startedAt: offset, lastSpeech: offset)
        run.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in self?.handle(runID: id, offset: offset, result: result, error: error) }
        }
        currentRun = run
        sink.setRequest(request)
    }

    /// laufenden Anlauf beenden: keine weiteren Puffer, das Endergebnis kommt noch
    private func endRun(final: Bool) {
        guard let run = currentRun else { return }
        sink.setRequest(nil)
        run.request.endAudio()
        if !final { currentRun = nil }
    }

    private func handle(runID: Int, offset: Double, result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let segs = result.bestTranscription.segments.map {
                TranscriptSegment(start: $0.timestamp + offset, duration: $0.duration, text: $0.substring)
            }
            runs[runID] = segs
            if result.isFinal {
                finalRuns.insert(runID)
                if currentRun?.id == runID { partial = "" }
                rebuildSections()
            } else if currentRun?.id == runID {
                partial = result.bestTranscription.formattedString
            }
        }
        if let error {
            // Abbruch des eigenen Anlaufs (endAudio ohne Sprache) ist kein Fehler; echte Fehler merken, weiter aufnehmen
            let ns = error as NSError
            if !(ns.domain == "kAFAssistantErrorDomain" && (ns.code == 216 || ns.code == 1110 || ns.code == 301)) && runs[runID] == nil {
                transcriptNote = "Spracherkennung unterbrochen: \(error.localizedDescription)"
                if transcript == .running { transcript = .partial }
            }
            finalRuns.insert(runID)
        }
        if result?.isFinal == true || error != nil, currentRun?.id == runID, state == .finishing {
            finishing?.resume()
            finishing = nil
        }
    }

    private func rebuildSections() {
        let all = runs.keys.sorted().flatMap { runs[$0] ?? [] }
        sections = TranscriptSections.build(all)
    }

    /// Stand fuer `transcript_status` beim Eintragen
    var transcriptStatus: String {
        switch transcript {
        case .running: return sections.isEmpty ? "failed" : "partial"
        default: return transcript.rawValue
        }
    }

    // MARK: Transkript nachtraeglich aus der Datei (ohne Mikrofon, z. B. nach verweigerter Erlaubnis)

    struct RecorderError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Erkennung der ganzen Datei auf dem Geraet; wirft mit Meldung, wenn Erlaubnis oder Sprachpaket fehlen
    static func transcribe(url: URL, language: String) async throws -> [TranscriptSection] {
        guard await requestSpeech() else { throw RecorderError("Spracherkennung nicht erlaubt (Einstellungen → StudiNow).") }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.isAvailable else {
            throw RecorderError("Spracherkennung für diese Sprache ist nicht verfügbar.")
        }
        guard r.supportsOnDeviceRecognition else { throw RecorderError("Spracherkennung auf dem Gerät ist für diese Sprache nicht geladen.") }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let segments: [TranscriptSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            r.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.segments.map { TranscriptSegment(start: $0.timestamp, duration: $0.duration, text: $0.substring) })
                } else if let error {
                    done = true
                    c.resume(throwing: error)
                }
            }
        }
        return TranscriptSections.build(segments)
    }
}

/// Nimmt die Puffer des Mikrofons ausserhalb des Hauptthreads entgegen: schreibt die Datei, reicht sie an die
/// Erkennung weiter und misst den Pegel. Alles unter einer Sperre, weil der Tap auf einem eigenen Thread laeuft.
final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var frames: Int64 = 0
    private var sampleRate = 44_100.0
    private var lastLevel = 0.0

    func open(file: AVAudioFile, sampleRate: Double) {
        lock.lock()
        self.file = file
        self.sampleRate = sampleRate
        frames = 0
        lastLevel = 0
        lock.unlock()
    }

    func close() { lock.lock(); file = nil; request = nil; lock.unlock() }

    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    var level: Double { lock.lock(); defer { lock.unlock() }; return lastLevel }
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(frames) / sampleRate }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        try? file.write(from: buffer)
        request?.append(buffer)
        frames += Int64(buffer.frameLength)
        lastLevel = Self.rms(buffer)
    }

    /// Effektivwert des ersten Kanals, 0…1 (Mikrofonpegel ist meist leise: mal 4, gedeckelt)
    static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum = 0.0
        let ch = data[0]
        for i in 0..<n { sum += Double(ch[i] * ch[i]) }
        return min(1, (sum / Double(n)).squareRoot() * 4)
    }
}
