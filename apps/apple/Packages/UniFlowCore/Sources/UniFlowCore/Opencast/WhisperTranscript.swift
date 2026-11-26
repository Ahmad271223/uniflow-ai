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

    /// Steuerzeichen von Whisper (`<|de|>`, `<|0.00|>`) und Anmerkungen in eckigen Klammern (`[BLANK_AUDIO]`, `[Musik]`,
    /// `[Präsidentin]` – so etwas sagt niemand, Whisper schreibt es bei Stille) sowie doppelte Leerzeichen entfernen
    public static func clean(_ text: String) -> String {
        var s = text
        for pattern in ["<\\|[^|>]*\\|>", "\\[[\\p{L}_ ]{2,24}\\]"] {
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
    /// `vocabulary`: die Fachwoerter, die Whisper als Hilfe bekommen hat (`WhisperVocabulary`) – ein Segment, das nur
    /// diese Liste nachspricht (kommt bei Stille vor), faellt weg.
    public static func place(_ raw: [WhisperRawSegment], sliceStart: Double, sliceLength: Double, isLast: Bool,
                             vocabulary: [String] = []) -> SliceResult {
        var kept: [WhisperRawSegment] = []
        var repeats = 0
        for seg in raw.sorted(by: { $0.start < $1.start }) {
            let text = clean(seg.text)
            guard !text.isEmpty, seg.start.isFinite, seg.end.isFinite, seg.end > seg.start, seg.start >= 0,
                  seg.start < sliceLength + edgeSeconds, !isInvented(text, noSpeech: seg.noSpeech),
                  !WhisperVocabulary.isEcho(text, terms: vocabulary) else { continue }
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

/// Schonung des Geraets (1.0.8, Rueckmeldung des Inhabers vom iPad 25.11.2026: "iPad wird heiß"): die Erkennung rechnet
/// minutenlang mit voller Kraft. Zwischen zwei Stuecken legt die App je nach Waerme des Geraets eine Pause ein; bei
/// "kritisch" wartet sie, bis es kuehler ist. Stufen wie `ProcessInfo.ThermalState`: 0 normal, 1 warm, 2 heiss, 3 kritisch.
public enum WhisperPacing {
    /// Pause vor dem naechsten Stueck in Sekunden
    public static func pause(level: Int) -> Double {
        switch level {
        case ..<1: return 0
        case 1: return 4
        case 2: return 20
        default: return 30
        }
    }

    /// Erst weitermachen, wenn das Geraet wieder kuehler ist?
    public static func mustCool(level: Int) -> Bool { level >= 3 }

    /// So oft wird beim Warten nachgesehen (Sekunden) und so lange hoechstens gewartet
    public static let checkEvery = 5.0
    public static let maxWait = 600.0
}

/// Fachwoerter-Hilfe (1.0.8): Whisper schreibt Namen und Fachbegriffe eher richtig ("Taylor-Polynom" statt
/// "Teilor-Polynom"), wenn es sie vorher als Text gesehen hat. Die Woerter kommen aus den Vorlesungen und Skripten des
/// Moduls (Seitentexte der Skriptsuche, `page_texts`) – ohne KI, auf dem Geraet. Hier nur das Auswaehlen; die App macht
/// daraus die Vorgabe fuer das Modell (`WhisperEngine`).
public enum WhisperVocabulary {
    /// So viele Begriffe hoechstens; die Vorgabe fuer Whisper fasst rund 220 Wortteile, die App kuerzt bei Bedarf weiter
    public static let maxTerms = 60
    /// So viele Seiten werden hoechstens gelesen (neueste Dateien zuerst)
    public static let maxPages = 1500

    /// Woerter, die in fast jedem Skript stehen und die Whisper ohnehin kennt (zusaetzlich zu `ScriptSearch.stop`)
    static let common: Set<String> = Set("""
        abbildung abschnitt allgemein anhang anmerkung annahme antwort anwendung anwendungen aussage bedeutung bedingung
        beispiele bereich beweis bezeichnung bild dabei damit daraus daher datei datum department dozent einführung
        einleitung ende ergebnis ergebnisse erklärung fakultät fall fälle folge folgerung folien form formel frage fragen
        gliederung grundlagen hannover hildesheim hochschule idee inhalt inhaltsverzeichnis institut interpretation leibniz
        literatur methode methoden motivation nummer prof professor prüfung quelle quellen rechnung regel sommersemester
        skript stelle tabelle teil thema themen überblick übersicht übungen universität vergleich version voraussetzung
        vorgehen wiederholung wintersemester ziel ziele zusammenfassung zusatz author chapter example examples figure lecture
        notes page proof remark section slide slides table theorem university
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Woerter eines Textes in Schreibweise des Skripts: Buchstaben und Ziffern, Bindestriche im Wort bleiben
    /// ("Taylor-Polynom"). Eine Silbentrennung am Zeilenende wird zusammengefuegt ("Mittel-\nwertsatz").
    static func words(_ text: String) -> [String] {
        let u = Array(ScriptSearch.normalize(text).unicodeScalars)
        let letters = CharacterSet.letters, digits = CharacterSet.decimalDigits, lower = CharacterSet.lowercaseLetters
        func wordChar(_ s: Unicode.Scalar) -> Bool { letters.contains(s) || digits.contains(s) }
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var i = 0
        func flush() {
            if !cur.isEmpty { out.append(String(cur)) }
            cur = String.UnicodeScalarView()
        }
        while i < u.count {
            let s = u[i]
            if wordChar(s) {
                cur.append(s)
            } else if (s == "-" || s == "\u{2010}" || s == "\u{2011}"), !cur.isEmpty {
                // Bindestrich im Wort oder Trennung am Zeilenende
                var j = i + 1
                var newline = false
                while j < u.count, u[j] == "\n" || u[j] == "\r" || (newline && (u[j] == " " || u[j] == "\t")) {
                    newline = true
                    j += 1
                }
                if j < u.count, wordChar(u[j]) {
                    if !(newline && lower.contains(u[j])) { cur.append("-") }
                    i = j
                    continue
                }
                flush()
            } else {
                flush()
            }
            i += 1
        }
        flush()
        return out
    }

    /// Gewicht eines Wortes als Fachbegriff, nil = keiner. Hoch: zusammengesetzte Begriffe mit Bindestrich, Namen und
    /// Fremdwoerter (an der Schreibweise erkannt), Abkuerzungen, sehr lange Zusammensetzungen; normal: uebrige Hauptwoerter.
    static func weight(_ word: String) -> Double? {
        let lower = word.lowercased()
        guard word.count <= 40, !ScriptSearch.stop.contains(lower), !common.contains(lower) else { return nil }
        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 {
            guard parts.count <= 4, parts.allSatisfy({ $0.count >= 2 }),
                  parts.contains(where: { $0.count >= 3 && isUpper($0.unicodeScalars.first) && hasLetters($0, atLeast: 3) }),
                  !parts.allSatisfy({ ScriptSearch.stop.contains($0.lowercased()) || common.contains($0.lowercased()) }) else { return nil }
            return 3
        }
        let scalars = Array(word.unicodeScalars)
        guard scalars.allSatisfy({ CharacterSet.letters.contains($0) }), isUpper(scalars.first) else { return nil }
        let uppers = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        if uppers == scalars.count { return (2...6).contains(scalars.count) ? 2 : nil }      // Abkuerzung (FFT, LGS)
        guard scalars.count >= 5 else { return nil }
        if uppers >= 2 { return 2.5 }                                                          // LaTeX, PyTorch
        if looksForeign(lower) { return 2.5 }
        return scalars.count >= 12 ? 2 : 1
    }

    private static func isUpper(_ s: Unicode.Scalar?) -> Bool { s.map(CharacterSet.uppercaseLetters.contains) ?? false }
    private static func hasLetters(_ s: String, atLeast n: Int) -> Bool {
        s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= n
    }

    /// Schreibweise, die im Deutschen selten ist (Namen, Englisch): y, x, q, é, "ou", Endung -ing, c ohne h oder k danach
    static func looksForeign(_ lower: String) -> Bool {
        if lower.contains(where: { "yxqéèê".contains($0) }) || lower.contains("ou") || lower.hasSuffix("ing") { return true }
        let c = Array(lower)
        for (i, ch) in c.enumerated() where ch == "c" {
            let next = i + 1 < c.count ? c[i + 1] : " "
            if next != "h" && next != "k" { return true }
        }
        return false
    }

    /// Gemeinsame Form gebeugter Woerter ("Polynome", "Polynoms" -> "polynom")
    static func stem(_ word: String) -> String {
        let l = word.lowercased()
        for suffix in ["es", "en", "e", "s", "n"] where l.hasSuffix(suffix) && l.count - suffix.count >= 4 {
            return String(l.dropLast(suffix.count))
        }
        return l
    }

    /// Die Fachbegriffe aus Seitentexten, wichtigste zuerst. Ein Begriff muss mehrmals vorkommen (ein einzelner Treffer
    /// ist oft ein Lesefehler der PDF); gebeugte Formen zaehlen zusammen, es bleibt die haeufigste Schreibweise.
    public static func terms(from texts: [String], limit: Int = maxTerms) -> [String] {
        Array(WhisperGlossary(pages: texts).top.prefix(max(0, limit)))
    }

    static let leadGerman = "Wichtige Begriffe der Vorlesung"
    static let leadEnglish = "Key terms of the lecture"

    /// Die Vorgabe fuer Whisper als ein Satz in der Sprache der Aufnahme; "" ohne Begriffe
    public static func prompt(terms: [String], language: String) -> String {
        guard !terms.isEmpty else { return "" }
        return (language == "en" ? leadEnglish : leadGerman) + ": " + terms.joined(separator: ", ") + "."
    }

    /// Spricht ein erkannter Satz nur die Vorgabe nach? Bei Stille gibt Whisper manchmal die Wortliste zurueck.
    public static func isEcho(_ text: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let f = WhisperSlices.form(text)
        guard !f.isEmpty else { return false }
        if f.contains(WhisperSlices.form(leadGerman)) || f.contains(WhisperSlices.form(leadEnglish)) { return true }
        var hits = 0, covered = 0
        for t in terms {
            let tf = WhisperSlices.form(t)
            if !tf.isEmpty, f.contains(tf) {
                hits += 1
                covered += tf.count
            }
        }
        return hits >= 4 && Double(covered) >= 0.7 * Double(f.count)
    }
}

/// Fachbegriffe eines Moduls, nach Seiten geordnet. Whisper nimmt je Stueck nur rund zehn Begriffe als Vorgabe an (der
/// Rahmen von WhisperKit ist klein, siehe `WhisperEngine.maxPromptTokens`), ein Semester hat hunderte. Darum liest das
/// Glossar im Skript mit: zu dem, was zuletzt gesagt wurde, sucht es die passenden Seiten und nimmt deren Begriffe fuer
/// das naechste Stueck; ohne Treffer die wichtigsten des ganzen Moduls.
public struct WhisperGlossary: Sendable {
    /// So viele Begriffe je Stueck (die App kuerzt auf die Wortteile, die in die Vorgabe passen)
    public static let termsPerSlice = 12
    /// So viele gemeinsame Woerter muss eine Seite mit dem Gesagten haben, um als "hier sind wir" zu gelten
    static let minShared = 4

    struct Page: Sendable {
        /// Fachbegriffe der Seite (Schreibweise des Moduls), wichtigste zuerst
        let terms: [String]
        /// Wortstaemme der Seite zum Wiederfinden
        let stems: Set<String>
    }

    let pages: [Page]
    /// Seltenheit je Wortstamm (seltene Woerter sagen mehr darueber, welche Seite gemeint ist)
    let rarity: [String: Double]
    /// Die wichtigsten Begriffe des ganzen Moduls, wichtigste zuerst
    public let top: [String]

    public var isEmpty: Bool { top.isEmpty }

    /// Wortstaemme eines Textes zum Vergleichen: Woerter ab fuenf Buchstaben ohne Allerweltswoerter
    static func stems(_ text: String) -> Set<String> {
        var out = Set<String>()
        for word in WhisperVocabulary.words(text) where word.count >= 5 {
            let lower = word.lowercased()
            if ScriptSearch.stop.contains(lower) || WhisperVocabulary.common.contains(lower) { continue }
            out.insert(WhisperVocabulary.stem(word))
        }
        return out
    }

    public init(pages texts: [String]) {
        struct Group { var weight: Double; var forms: [String: Int] }
        var groups: [String: Group] = [:]
        var perPage: [[String]] = []          // Staemme der gewichteten Woerter je Seite, in Reihenfolge
        for text in texts {
            var seen: [String] = []
            for word in WhisperVocabulary.words(text) {
                guard let w = WhisperVocabulary.weight(word) else { continue }
                let key = WhisperVocabulary.stem(word)
                var g = groups[key] ?? Group(weight: w, forms: [:])
                g.weight = max(g.weight, w)
                g.forms[word, default: 0] += 1
                groups[key] = g
                if !seen.contains(key) { seen.append(key) }
            }
            perPage.append(seen)
        }
        // gueltige Begriffe: mehrmals im Modul; Schreibweise = die haeufigste
        var best: [String: (term: String, score: Double, weight: Double)] = [:]
        for (key, g) in groups {
            let count = g.forms.values.reduce(0, +)
            guard count >= (g.weight >= 2 ? 2 : 3) else { continue }
            let term = g.forms.sorted { ($0.value, -$0.key.count, $1.key) > ($1.value, -$1.key.count, $0.key) }[0].key
            best[key] = (term, log2(1 + Double(count)) * g.weight, g.weight)
        }
        top = best.values.sorted { ($0.score, $1.term) > ($1.score, $0.term) }.map(\.term)

        var df: [String: Int] = [:]
        var built: [Page] = []
        for (i, text) in texts.enumerated() {
            let stems = Self.stems(text)
            for st in stems { df[st, default: 0] += 1 }
            // auf der Seite zaehlen nur besondere Begriffe (Namen, Zusammensetzungen, Abkuerzungen)
            let special = perPage[i].compactMap { best[$0] }.filter { $0.weight >= 2 }
                .sorted { ($0.score, $1.term) > ($1.score, $0.term) }.map(\.term)
            built.append(Page(terms: special, stems: stems))
        }
        pages = built
        let n = Double(max(1, texts.count))
        rarity = df.mapValues { log(1 + n / Double($0)) }
    }

    /// Begriffe fuer das naechste Stueck. `text`: was zuletzt erkannt wurde (leer am Anfang). Zuerst die Begriffe der
    /// Seite, die am besten dazu passt, dann die der Seite danach (die Vorlesung geht weiter), dann die der zweitbesten
    /// Seite, zum Auffuellen die wichtigsten des Moduls.
    public func terms(after text: String, limit: Int = termsPerSlice) -> [String] {
        guard limit > 0 else { return [] }
        var out: [String] = []
        func add(_ terms: [String]) {
            for t in terms where out.count < limit && !out.contains(t) { out.append(t) }
        }
        let said = Self.stems(text)
        if said.count >= Self.minShared {
            var hits: [(index: Int, score: Double)] = []
            for (i, page) in pages.enumerated() where !page.terms.isEmpty || i + 1 < pages.count {
                let shared = said.intersection(page.stems)
                guard shared.count >= Self.minShared else { continue }
                hits.append((i, shared.reduce(0) { $0 + (rarity[$1] ?? 0) }))
            }
            hits.sort { ($0.score, $1.index) > ($1.score, $0.index) }
            if let first = hits.first {
                add(pages[first.index].terms)
                if first.index + 1 < pages.count { add(pages[first.index + 1].terms) }
                if hits.count > 1 { add(pages[hits[1].index].terms) }
            }
        }
        add(top)
        return out
    }
}
