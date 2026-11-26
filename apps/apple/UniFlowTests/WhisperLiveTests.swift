import UniFlowCore
import XCTest
@testable import UniFlow

/// Echte Erkennung mit WhisperKit (docs/WHISPER-MITSCHRIFT.md): laedt ein Sprachmodell und wandelt eine deutsche
/// Probe-Vorlesung um. Braucht Internet und Minuten, laeuft deshalb nur auf Wunsch:
///   TEST_RUNNER_UF_WHISPER_LIVE=1 TEST_RUNNER_UF_WHISPER_SAMPLE=<m4a/mp4> TEST_RUNNER_UF_WHISPER_BASE=<Ordner fuer Modelle>
///   [TEST_RUNNER_UF_WHISPER_MODEL=klein|gross] [TEST_RUNNER_UF_WHISPER_OUT=<Textdatei>] [TEST_RUNNER_UF_WHISPER_WORDS=wort1,wort2]
///   [TEST_RUNNER_UF_WHISPER_TERMS=Begriff1,Begriff2  Fachwoerter als Vorgabe | TEST_RUNNER_UF_WHISPER_SCRIPT=<Textdatei mit Seiten>]
///   xcodebuild test … -only-testing:UniFlowTests/WhisperLiveTests
/// Der Modell-Ordner darf auf dem Mac liegen (der Simulator liest ihn); beim zweiten Lauf wird nichts mehr geladen.
@MainActor
final class WhisperLiveTests: XCTestCase {
    func testDownloadsTheModelAndTranscribesARecording() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["UF_WHISPER_LIVE"] == "1", let sample = env["UF_WHISPER_SAMPLE"], let basePath = env["UF_WHISPER_BASE"] else {
            throw XCTSkip("nur mit UF_WHISPER_LIVE=1, UF_WHISPER_SAMPLE und UF_WHISPER_BASE")
        }
        let suite = "whisper.live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhisperModelStore(base: URL(fileURLWithPath: basePath, isDirectory: true), defaults: defaults)
        let choice = try XCTUnwrap(WhisperModels.choice(id: env["UF_WHISPER_MODEL"] ?? "klein"))

        // Modell laden (oder vom letzten Lauf nehmen)
        let loadStart = Date()
        if !store.isReady(choice) {
            store.download(choice)
            let deadline = Date().addingTimeInterval(1800)
            var last = -1.0
            while Date() < deadline {
                let state = store.state(choice)
                if state == .ready { break }
                if case .failed(let m) = state { return XCTFail("Download: \(m)") }
                if case .downloading(let f) = state, f - last >= 0.1 { last = f; print("WHISPER-LIVE lädt \(Int(f * 100)) %") }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        XCTAssertEqual(store.state(choice), .ready)
        XCTAssertTrue(store.isReady(choice))
        store.use(choice)
        XCTAssertEqual(store.active, choice)
        XCTAssertGreaterThan(store.bytesOnDisk(choice), Int64(choice.megabytes) * 500_000)
        print("WHISPER-LIVE Modell \(choice.variant) bereit nach \(Int(Date().timeIntervalSince(loadStart))) s, \(store.bytesOnDisk(choice) / 1_000_000) MB")

        // Datei umwandeln
        let url = URL(fileURLWithPath: sample)
        let measured = await WhisperAudio.duration(of: url)
        let duration = try XCTUnwrap(measured)
        var fractions: [Double] = []
        let start = Date()
        // Fachwoerter-Hilfe: mit UF_WHISPER_TERMS geht die Liste als Vorgabe an das Modell (Vergleich mit und ohne)
        // oder UF_WHISPER_SCRIPT=<Textdatei, Seiten durch eine Zeile "---" getrennt>: die App liest im Skript mit
        // (`WhisperGlossary`) und waehlt die Begriffe je Stueck selbst
        let fixed = (env["UF_WHISPER_TERMS"] ?? "").split(separator: ",").map(String.init)
        var glossary: WhisperGlossary?
        if let path = env["UF_WHISPER_SCRIPT"] {
            let pages = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n---\n")
            glossary = WhisperGlossary(pages: pages)
            XCTAssertFalse(try XCTUnwrap(glossary).isEmpty, "Skript ohne Begriffe")
        }
        var asked: [[String]] = []
        let vocabulary: WhisperJobs.Vocabulary? = fixed.isEmpty && glossary == nil ? nil : { said in
            let terms = glossary?.terms(after: said) ?? fixed
            asked.append(terms)
            return terms
        }
        let sections = try await WhisperJobs.transcribe(url: url, language: "de", store: store, vocabulary: vocabulary) { f, _, _ in fractions.append(f) }
        for (i, terms) in asked.enumerated() {
            let tokens = await WhisperEngine.shared.prompt(terms: terms, language: "de")
            XCTAssertFalse(tokens.isEmpty, "Vorgabe leer")
            XCTAssertLessThanOrEqual(tokens.count, WhisperEngine.maxPromptTokens)
            print("WHISPER-LIVE Vorgabe Stück \(i + 1): \(tokens.count) Wortteile aus \(terms.joined(separator: ", "))")
        }
        let took = Date().timeIntervalSince(start)
        let text = TranscriptSections.plainText(sections)
        print("WHISPER-LIVE \(Int(duration)) s Ton in \(Int(took)) s (Faktor \(String(format: "%.1f", duration / max(took, 0.1)))), \(sections.count) Abschnitte, \(text.count) Zeichen")
        if let out = env["UF_WHISPER_OUT"] { try TranscriptSections.format(sections).write(toFile: out, atomically: true, encoding: .utf8) }

        XCTAssertGreaterThan(sections.count, 1)
        // Zeiten: aufsteigend, ohne Ueberlappung, bis ans Ende der Datei
        for (a, b) in zip(sections, sections.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, a.end)
            XCTAssertLessThanOrEqual(a.end, b.start + 0.5, "Abschnitte überlappen: \(a.end) > \(b.start)")
        }
        XCTAssertGreaterThan(sections.last?.end ?? 0, duration * 0.85)
        XCTAssertLessThanOrEqual(sections.last?.end ?? 0, duration + 2)
        // Fortschritt steigt bis 1
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(fractions, fractions.sorted())
        // keine Steuerzeichen, keine erfundenen Untertitel-Zeilen
        XCTAssertFalse(text.contains("<|"), text)
        XCTAssertFalse(text.lowercased().contains("amara"), text)
        // erwartete Woerter (Vorgabe: Probe-Vorlesung aus ~/Studora-Builds/whisper-probe)
        let words = (env["UF_WHISPER_WORDS"] ?? "Ableitung,Mittelwertsatz,Funktion,Tangente,Polynom,Klausur").split(separator: ",").map(String.init)
        let lower = text.lowercased()
        let missing = words.filter { !lower.contains($0.lowercased()) }
        XCTAssertTrue(missing.isEmpty, "fehlen im Text: \(missing)")

        // Weitermachen: mit den ersten Abschnitten als Stand beginnt die Erkennung an ihrem Ende, nicht bei null
        let half = Array(sections.prefix(max(1, sections.count / 2)))
        var firstFraction: Double?
        let resumed = try await WhisperJobs.transcribe(url: url, language: "de", store: store, vocabulary: vocabulary, resume: half) { f, _, _ in
            if firstFraction == nil { firstFraction = f }
        }
        XCTAssertGreaterThan(firstFraction ?? 0, 0.1)
        XCTAssertEqual(Array(resumed.prefix(half.count)), half)
        XCTAssertGreaterThan(resumed.last?.end ?? 0, duration * 0.85)
    }

    /// Sprung an eine Stelle in einer echten Datei (nur mit UF_WHISPER_SAMPLE): der Player steht danach dort und laeuft
    @MainActor
    func testJumpLandsAtTheRightPlaceAndPlays() async throws {
        guard let sample = ProcessInfo.processInfo.environment["UF_WHISPER_SAMPLE"] else { throw XCTSkip("nur mit UF_WHISPER_SAMPLE") }
        let url = URL(fileURLWithPath: sample)
        let video = TranscriptVideoPlayer()
        defer { video.stop() }
        video.seek(url, to: 61)
        let player = try XCTUnwrap(video.player)
        var landed = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let t = player.currentTime().seconds
            if t >= 59.5, t < 66, player.rate > 0 { landed = true; break }
        }
        let at = player.currentTime().seconds
        XCTAssertTrue(landed, "Stelle \(at), Tempo \(player.rate)")
        print("WHISPER-LIVE Sprung auf 61 s: steht bei \(at) s, Tempo \(player.rate)")
        // zweiter Sprung zurueck in derselben Datei
        video.seek(url, to: 12)
        XCTAssertTrue(video.player === player)
        var back = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let t = player.currentTime().seconds
            if t >= 10.5, t < 17, player.rate > 0 { back = true; break }
        }
        XCTAssertTrue(back, "Stelle \(player.currentTime().seconds)")
    }
}
