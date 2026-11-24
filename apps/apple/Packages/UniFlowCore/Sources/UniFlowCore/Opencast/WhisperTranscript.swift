import Foundation

// "Bessere Mitschrift" mit Whisper auf dem Geraet (1.0.8, docs/WHISPER-MITSCHRIFT.md) – der Teil ohne WhisperKit und
// ohne Apple-Frameworks: Auswahl der Sprachmodelle, Zerlegen langer Aufnahmen in Stuecke, Aufraeumen der Ergebnisse.
// Die Erkennung selbst (CoreML ueber WhisperKit) und das Lesen der Tonspur liegen in der App
// (`UniFlow/Services/WhisperMitschrift.swift`). Ergebnis sind dieselben `TranscriptSegment`/`TranscriptSection` wie bei
// der Erkennung von Apple; Ablage, Suche und KI-Hilfe bleiben unveraendert.

/// Ein Sprachmodell zur Auswahl (Ordnername im Modell-Verzeichnis `argmaxinc/whisperkit-coreml`).
public struct WhisperModelChoice: Equatable, Sendable, Identifiable {
    public let id: String
    /// Ordnername des Modells, wie WhisperKit ihn erwartet
    public let variant: String
    /// Groesse des Downloads in MB (gerundet, fuer den Hinweis vor dem Laden)
    public let megabytes: Int
    public let title: String
    public let note: String
}

public enum WhisperModels {
    /// Bestes Modell fuer deutsche Vorlesungen, das auf iPad und iPhone noch gut laeuft (large-v3-turbo, verkleinert)
    public static let gross = WhisperModelChoice(
        id: "gross", variant: "openai_whisper-large-v3-v20240930_626MB", megabytes: 626, title: "Genau",
        note: "Beste Mitschrift, auch bei Fachbegriffen und Englisch im Satz. Braucht ein neueres Gerät.")
    /// Kleineres Modell fuer aeltere Geraete und wenig Speicher
    public static let klein = WhisperModelChoice(
        id: "klein", variant: "openai_whisper-small_216MB", megabytes: 216, title: "Kompakt",
        note: "Kleiner und schneller, etwas mehr Fehler bei Fachbegriffen.")

    public static let all = [gross, klein]

    public static func choice(id: String?) -> WhisperModelChoice? { all.first { $0.id == id } }

    /// Vorschlag fuer ein Geraet: das genaue Modell, wenn WhisperKit es fuer das Geraet freigibt (`supported`: Ordnernamen
    /// aus `WhisperKit.recommendedModels().supported`), sonst das kompakte. Ohne Angabe (unbekanntes Geraet) kompakt.
    public static func suggested(supported: [String]) -> WhisperModelChoice {
        supported.contains(gross.variant) ? gross : klein
    }

    /// Darf das Modell auf diesem Geraet angeboten werden?
    public static func offered(_ choice: WhisperModelChoice, supported: [String]) -> Bool {
        choice == klein || supported.contains(choice.variant)
    }
}

/// Ein Stueck Erkennung, wie WhisperKit es liefert (Zeiten in Sekunden ab Beginn des Stuecks).
public struct WhisperRawSegment: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    /// Wahrscheinlichkeit "keine Sprache" (0 ... 1)
    public let noSpeech: Double

    public init(start: Double, end: Double, text: String, noSpeech: Double = 0) {
        self.start = start
        self.end = end
        self.text = text
        self.noSpeech = noSpeech
    }
}

public enum WhisperSlices {
    /// Laenge eines Stuecks: lang genug fuer wenig Verlust an den Raendern, kurz genug fuer wenig Arbeitsspeicher
    /// (3 Minuten bei 16 kHz = 11,5 MB) und damit Fortschritt, Abbrechen und Zwischenspeichern oft genug drankommen
    public static let sliceSeconds = 180.0
    /// So weit muss ein Stueck mindestens vorankommen; sonst zaehlt die ganze Laenge (kein Stillstand bei Stille)
    public static let minAdvance = 60.0
    /// Ein Satz, der so nah am Ende des Stuecks aufhoert, ist vermutlich abgeschnitten und wird im naechsten Stueck
    /// noch einmal erkannt
    public static let edgeSeconds = 1.0

    /// Sprache fuer Whisper aus der Sprache der Aufnahme ("de-DE" -> "de"); unbekannt -> Deutsch
    public static func language(_ locale: String?) -> String {
        let code = (locale ?? "").split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        return ["de", "en"].contains(code) ? code : "de"
    }

    /// Steuerzeichen von Whisper (`<|de|>`, `<|0.00|>`, `[BLANK_AUDIO]`, `(Musik)`) und doppelte Leerzeichen entfernen
    public static func clean(_ text: String) -> String {
        var s = text
        for pattern in ["<\\|[^|>]*\\|>", "\\[[A-Za-z_ ]{2,20}\\]"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Vergleichsform: klein, nur Buchstaben und Ziffern
    static func form(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Saetze, die Whisper bei Stille oder Rauschen erfindet (aus Untertiteln gelernt). In einer Vorlesung sagt sie
    /// niemand woertlich; sie fallen deshalb immer weg.
    static let inventedForms: Set<String> = Set([
        "Untertitel der Amara.org-Community", "Untertitel von der Amara.org-Community", "Untertitel im Auftrag des ZDF",
        "Untertitel im Auftrag des ZDF für funk", "Untertitelung des ZDF", "Untertitelung im Auftrag des ZDF",
        "Untertitelung aufgrund der Amara.org-Community", "Untertitel von Stephanie Geiges", "Copyright WDR",
        "SWR 2020", "SWR 2021", "Vielen Dank fürs Zuschauen", "Vielen Dank für's Zuschauen", "Danke fürs Zuschauen",
        "Bis zum nächsten Mal", "Tschüss", "Thanks for watching", "Thank you for watching", "Subtitles by the Amara.org community",
        "Musik", "Applaus", "Stille",
    ].map(form))

    /// Kurze Floskeln aus der Liste zaehlen nur als erfunden, wenn Whisper selbst an Sprache zweifelt
    static let onlyWhenSilent: Set<String> = Set(["Tschüss", "Bis zum nächsten Mal", "Musik", "Applaus", "Stille"].map(form))

    public static func isInvented(_ text: String, noSpeech: Double = 0) -> Bool {
        let f = form(text)
        guard inventedForms.contains(f) else { return false }
        return onlyWhenSilent.contains(f) ? noSpeech >= 0.4 : true
    }

    /// Ergebnis eines Stuecks: gueltige Segmente mit Zeiten ab Beginn der Aufnahme und die Stelle, an der das naechste
    /// Stueck beginnt.
    public struct SliceResult: Equatable, Sendable {
        public let segments: [TranscriptSegment]
        public let next: Double
    }

    /// Segmente eines Stuecks aufraeumen und einordnen.
    /// - `sliceStart`/`sliceLength`: Lage des Stuecks in der Aufnahme (Sekunden)
    /// - `isLast`: das Stueck reicht bis zum Ende der Aufnahme
    /// Weg fallen leere und erfundene Segmente, Segmente ohne Dauer und die dritte und jede weitere woertliche
    /// Wiederholung in Folge (Whisper haengt bei Rauschen manchmal in einer Schleife). Hoert das letzte Segment am Rand
    /// des Stuecks auf, beginnt das naechste Stueck an seinem Anfang – der abgeschnittene Satz wird neu erkannt.
    public static func place(_ raw: [WhisperRawSegment], sliceStart: Double, sliceLength: Double, isLast: Bool) -> SliceResult {
        var kept: [WhisperRawSegment] = []
        var repeats = 0
        for seg in raw.sorted(by: { $0.start < $1.start }) {
            let text = clean(seg.text)
            guard !text.isEmpty, seg.start.isFinite, seg.end.isFinite, seg.end > seg.start, seg.start >= 0,
                  seg.start < sliceLength + edgeSeconds, !isInvented(text, noSpeech: seg.noSpeech) else { continue }
            if let last = kept.last, form(last.text) == form(text) {
                repeats += 1
                if repeats >= 2 { continue }
            } else {
                repeats = 0
            }
            kept.append(WhisperRawSegment(start: seg.start, end: min(seg.end, sliceLength), text: text, noSpeech: seg.noSpeech))
        }
        let end = sliceStart + sliceLength
        var next = end
        if !isLast, let last = kept.last, last.end >= sliceLength - edgeSeconds, last.start >= minAdvance {
            // letzter Satz reicht bis an den Rand: im naechsten Stueck noch einmal
            kept.removeLast()
            next = sliceStart + last.start
        }
        let segments = kept.map { TranscriptSegment(start: sliceStart + $0.start, duration: max(0.1, $0.end - $0.start), text: $0.text) }
        return SliceResult(segments: segments, next: next)
    }

    /// Stuecke einer Aufnahme der Laenge `duration` ab `from`: Beginn und Laenge des naechsten Stuecks, nil am Ende
    public static func slice(from: Double, duration: Double) -> (start: Double, length: Double, isLast: Bool)? {
        guard duration.isFinite, duration > 0, from < duration - 0.5 else { return nil }
        let start = max(0, from)
        let length = min(sliceSeconds, duration - start)
        return (start, length, start + length >= duration - 0.01)
    }

    /// Anteil 0 ... 1 fuer die Anzeige
    public static func progress(position: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Stelle, an der eine unterbrochene Erkennung weitermacht: Ende des letzten fertigen Abschnitts
    public static func resumePosition(_ sections: [TranscriptSection]) -> Double {
        max(0, sections.last?.end ?? 0)
    }

    /// Fertige Abschnitte und neue Segmente zusammenfuehren (beim Weitermachen): Abschnitte bleiben, die Segmente
    /// danach werden zu neuen Abschnitten.
    public static func merge(_ sections: [TranscriptSection], with segments: [TranscriptSegment]) -> [TranscriptSection] {
        let from = resumePosition(sections)
        let later = segments.filter { $0.start >= from - 0.01 }
        return sections + TranscriptSections.build(later)
    }
}
