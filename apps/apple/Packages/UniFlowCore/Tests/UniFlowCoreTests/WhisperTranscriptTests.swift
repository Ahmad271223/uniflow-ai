import Foundation
import XCTest
@testable import UniFlowCore

// "Bessere Mitschrift" mit Whisper (docs/WHISPER-MITSCHRIFT.md): der Teil ohne WhisperKit – Modellwahl, Stuecke,
// Aufraeumen der Ergebnisse. Die Segmente sind erfunden; die echte Erkennung prueft der Lauf in der App
// (`WhisperLiveTests`, nur mit UF_WHISPER_LIVE=1).
final class WhisperTranscriptTests: XCTestCase {

    // MARK: Modelle

    func testModelChoiceFollowsWhatTheDeviceSupports() {
        XCTAssertEqual(WhisperModels.suggested(supported: [WhisperModels.gross.variant, "openai_whisper-tiny"]), WhisperModels.gross)
        XCTAssertEqual(WhisperModels.suggested(supported: ["openai_whisper-tiny", "openai_whisper-base"]), WhisperModels.klein)
        XCTAssertEqual(WhisperModels.suggested(supported: []), WhisperModels.klein)
        XCTAssertTrue(WhisperModels.offered(WhisperModels.klein, supported: []))
        XCTAssertFalse(WhisperModels.offered(WhisperModels.gross, supported: ["openai_whisper-small_216MB"]))
        XCTAssertEqual(WhisperModels.choice(id: "gross"), WhisperModels.gross)
        XCTAssertNil(WhisperModels.choice(id: "riesig"))
        XCTAssertNil(WhisperModels.choice(id: nil))
        // beide Modelle koennen Deutsch (keine ".en"-Fassung) und nennen ihre Groesse
        for m in WhisperModels.all {
            XCTAssertFalse(m.variant.contains(".en"), m.variant)
            XCTAssertTrue(m.variant.hasSuffix("_\(m.megabytes)MB"), m.variant)
        }
    }

    func testLanguageFromRecordingLocale() {
        XCTAssertEqual(WhisperSlices.language("de-DE"), "de")
        XCTAssertEqual(WhisperSlices.language("en-US"), "en")
        XCTAssertEqual(WhisperSlices.language("en_GB"), "en")
        XCTAssertEqual(WhisperSlices.language("fr-FR"), "de")
        XCTAssertEqual(WhisperSlices.language(nil), "de")
    }

    // MARK: Aufraeumen

    func testCleanRemovesWhisperControlTokens() {
        XCTAssertEqual(WhisperSlices.clean("<|startoftranscript|><|de|><|transcribe|><|0.00|> Die Ableitung von x²  ist 2x.<|4.20|>"),
                       "Die Ableitung von x² ist 2x.")
        XCTAssertEqual(WhisperSlices.clean(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(WhisperSlices.clean("Das Intervall [0, 1] ist kompakt."), "Das Intervall [0, 1] ist kompakt.")
    }

    func testInventedSubtitleLinesAreDropped() {
        XCTAssertTrue(WhisperSlices.isInvented("Untertitel der Amara.org-Community"))
        XCTAssertTrue(WhisperSlices.isInvented("untertitelung des ZDF."))
        XCTAssertTrue(WhisperSlices.isInvented("Vielen Dank fürs Zuschauen!"))
        // kurze Floskeln nur, wenn Whisper selbst an Sprache zweifelt
        XCTAssertFalse(WhisperSlices.isInvented("Tschüss.", noSpeech: 0.1))
        XCTAssertTrue(WhisperSlices.isInvented("Tschüss.", noSpeech: 0.7))
        XCTAssertFalse(WhisperSlices.isInvented("Vielen Dank fürs Zuschauen, wir sehen uns am Donnerstag zur Übung."))
        XCTAssertFalse(WhisperSlices.isInvented("Die Musik spielt hier keine Rolle."))
    }

    // MARK: Stuecke

    func testSlicesCoverTheRecording() {
        XCTAssertNil(WhisperSlices.slice(from: 0, duration: 0))
        XCTAssertNil(WhisperSlices.slice(from: 600, duration: 600))
        let first = WhisperSlices.slice(from: 0, duration: 400)
        XCTAssertEqual(first?.start, 0)
        XCTAssertEqual(first?.length, 180)
        XCTAssertEqual(first?.isLast, false)
        let last = WhisperSlices.slice(from: 350, duration: 400)
        XCTAssertEqual(last?.start, 350)
        XCTAssertEqual(last?.length, 50)
        XCTAssertEqual(last?.isLast, true)
        XCTAssertEqual(WhisperSlices.progress(position: 100, duration: 400), 0.25)
        XCTAssertEqual(WhisperSlices.progress(position: 500, duration: 400), 1)
        XCTAssertEqual(WhisperSlices.progress(position: 5, duration: 0), 0)
    }

    func testSentenceCutAtTheEdgeIsRecognisedAgainInTheNextSlice() {
        let raw = [WhisperRawSegment(start: 0, end: 80, text: " Wir beginnen mit Folgen."),
                   WhisperRawSegment(start: 80, end: 172, text: " Eine Folge ist eine Abbildung."),
                   WhisperRawSegment(start: 172, end: 180, text: " Der Grenzwert ist")]
        let r = WhisperSlices.place(raw, sliceStart: 360, sliceLength: 180, isLast: false)
        XCTAssertEqual(r.segments.map(\.text), ["Wir beginnen mit Folgen.", "Eine Folge ist eine Abbildung."])
        XCTAssertEqual(r.segments.map(\.start), [360, 440])
        XCTAssertEqual(r.next, 532)                         // Beginn des abgeschnittenen Satzes
        // im letzten Stueck bleibt alles
        let last = WhisperSlices.place(raw, sliceStart: 360, sliceLength: 180, isLast: true)
        XCTAssertEqual(last.segments.count, 3)
        XCTAssertEqual(last.next, 540)
    }

    func testSliceAlwaysAdvancesEvenWithOneLongSegmentOrSilence() {
        // ein einziges Segment ueber das ganze Stueck: nicht wegwerfen, sonst kaeme die Erkennung nie voran
        let long = WhisperSlices.place([WhisperRawSegment(start: 2, end: 180, text: "Ein sehr langer Satz")], sliceStart: 0, sliceLength: 180, isLast: false)
        XCTAssertEqual(long.segments.count, 1)
        XCTAssertEqual(long.next, 180)
        // Stille: nichts erkannt, weiter mit dem naechsten Stueck
        let silent = WhisperSlices.place([], sliceStart: 180, sliceLength: 180, isLast: false)
        XCTAssertEqual(silent.segments, [])
        XCTAssertEqual(silent.next, 360)
    }

    func testLoopsInventedLinesAndBrokenTimesAreRemoved() {
        let raw = [WhisperRawSegment(start: 0, end: 4, text: "Also."),
                   WhisperRawSegment(start: 4, end: 8, text: "Also."),
                   WhisperRawSegment(start: 8, end: 12, text: "also"),
                   WhisperRawSegment(start: 12, end: 16, text: "Also."),
                   WhisperRawSegment(start: 16, end: 20, text: "Untertitel der Amara.org-Community"),
                   WhisperRawSegment(start: 20, end: 20, text: "ohne Dauer"),
                   WhisperRawSegment(start: 30, end: 26, text: "rückwärts"),
                   WhisperRawSegment(start: 40, end: 44, text: "<|de|> "),
                   WhisperRawSegment(start: 50, end: 60, text: "Weiter im Stoff.")]
        let r = WhisperSlices.place(raw, sliceStart: 0, sliceLength: 180, isLast: false)
        XCTAssertEqual(r.segments.map(\.text), ["Also.", "Also.", "Weiter im Stoff."])
        XCTAssertEqual(r.next, 180)
    }

    func testResumeKeepsFinishedSectionsAndAddsTheRest() {
        let done = [TranscriptSection(start: 0, end: 60, text: "Erster Abschnitt."), TranscriptSection(start: 60, end: 118, text: "Zweiter Abschnitt.")]
        XCTAssertEqual(WhisperSlices.resumePosition(done), 118)
        XCTAssertEqual(WhisperSlices.resumePosition([]), 0)
        let more = [TranscriptSegment(start: 100, duration: 10, text: "schon enthalten"),
                    TranscriptSegment(start: 118, duration: 20, text: "Dritter Abschnitt."),
                    TranscriptSegment(start: 138, duration: 20, text: "Noch ein Satz.")]
        let merged = WhisperSlices.merge(done, with: more)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[2].start, 118)
        XCTAssertEqual(merged[2].text, "Dritter Abschnitt. Noch ein Satz.")
    }
}
