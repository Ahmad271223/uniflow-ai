import AVFoundation
import Foundation
import Speech
import UniFlowCore

/// Transkript einer Audiodatei (.mp3, .m4a) auf dem Geraet (docs/DATEIARTEN.md, 04.11.2026): `SFSpeechRecognizer`
/// mit `requiresOnDeviceRecognition`, Deutsch oder Englisch, nur auf Wunsch ("Transkript erstellen"), nie automatisch.
/// Das Ergebnis liegt einmal als Text neben der Datei (`OfficeText.transcriptPath`, eine Zeile je Satz); danach liest
/// das lokale Backend daraus Seiten wie bei PDF (`ScriptSearch.readPages`), fuer Suche, KI-Hilfe und Wochentests.
/// Die Aufnahme verlaesst das Geraet nicht; an die KI geht spaeter nur der Text.
@MainActor
final class AudioTranscriber: ObservableObject {
    enum State: Equatable {
        case idle
        /// laeuft; Anteil der Datei (0 ... 1), soweit bekannt
        case running(Double)
        case done(pages: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: SFSpeechRecognitionTask?

    /// Sprachen fuer das Transkript (Erkennung auf dem Geraet; welche installiert sind, entscheidet das System)
    static let languages: [(locale: String, label: String)] = [("de-DE", "Deutsch"), ("en-US", "Englisch")]

    /// Erkennung auf dem Geraet fuer diese Sprache moeglich? (Sprachpaket installiert)
    nonisolated static func onDeviceAvailable(_ locale: String) -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
    }

    /// Dateinamen, fuer die es ein Transkript geben kann
    nonisolated static func supports(_ name: String) -> Bool { OfficeText.isAudio(name) }

    /// Text des Erkenners als Absaetze: eine Zeile je Satz (nach ., ?, !), damit die Seitenbildung (`OfficeText.pages`)
    /// sinnvolle Stellen zum Trennen hat; ohne Satzzeichen etwa alle 25 Woerter
    nonisolated static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            current.append(String(word))
            let ends = word.last.map { ".?!".contains($0) } ?? false
            if ends || current.count >= 25 {
                out.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    /// Transkript erstellen und neben der Datei ablegen; `fileID` wie in der Datenbank des Containers
    func transcribe(fileID: String, locale: String, container: ActiveContainer) async {
        if case .running = state { return }
        state = .running(0)
        do {
            let backend = try await container.host.backend()
            let files = backend.context.files
            guard let files,
                  let row = try await backend.context.database.queryOne("SELECT local_path FROM files WHERE id=?", [.text(fileID)]),
                  let stored = row["local_path"]?.string, let url = files.url(stored: stored), files.exists(stored: stored) else {
                state = .failed("Die Datei liegt nicht auf dem Gerät.")
                return
            }
            guard Self.supports(stored) else { state = .failed("Nur .mp3 und .m4a lassen sich transkribieren."); return }
            let status = await Self.authorize()
            guard status == .authorized else {
                state = .failed(status == .denied ? "Spracherkennung ist in den Einstellungen nicht erlaubt." : "Spracherkennung ist auf diesem Gerät nicht verfügbar.")
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
                state = .failed("Erkennung für diese Sprache ist nicht verfügbar."); return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                state = .failed("Erkennung auf dem Gerät ist für diese Sprache nicht installiert (Einstellungen › Allgemein › Tastatur › Diktier-Sprachen)."); return
            }
            let duration = Self.duration(of: url)
            let text = try await recognize(url: url, recognizer: recognizer, duration: duration)
            let lines = Self.paragraphs(text)
            guard !lines.isEmpty else { state = .failed("Es wurde keine Sprache erkannt."); return }
            _ = try files.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: OfficeText.transcriptPath(for: stored))
            // gespeicherte Seitentexte einer frueheren Fassung weg: das Backend liest beim naechsten Abruf das Transkript
            try await backend.context.database.execute("DELETE FROM page_texts WHERE file_id=?", [.text(fileID)])
            state = .done(pages: OfficeText.pages(paragraphs: lines).count)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .running = state { state = .idle }
    }

    private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let now = SFSpeechRecognizer.authorizationStatus()
        if now != .notDetermined { return now }
        return await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
    }

    private static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    private func recognize(url: URL, recognizer: SFSpeechRecognizer, duration: Double?) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    if let duration, duration > 0, let last = result.bestTranscription.segments.last {
                        let p = min(1, (last.timestamp + last.duration) / duration)
                        Task { @MainActor in if case .running = self?.state { self?.state = .running(p) } }
                    }
                    if result.isFinal, !finished {
                        finished = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                }
                if let error, !finished {
                    finished = true
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
