import SwiftUI
import UniFlowCore

// KI-Start (Feinschliff 04.11.2026): die Hilfe ohne KI, der Dokument-Waehler fuer den Kontext und die reinen
// Entscheidungen der Seite (Anordnung der Aktionen, angehaengtes Dokument). Nichts hier spricht mit einem Dienst.

// MARK: - Hilfe ohne KI (0 Credits)

/// Inhalt der Aktion "Hilfe" auf KI-Start: feste Texte, keine KI-Anfrage, 0 Credits. Nennt nur, was die App heute
/// kann (die Modi der KI-Hilfe in `AIPromptTexts.tutorModes`, Karteikarten, Wochentest) – keine Vorlesungsaufnahme,
/// kein Import von Webseiten.
enum AIHelpContent {
    struct Section: Equatable {
        let title: String
        let icon: String
        let items: [String]
    }

    static let title = "So hilft dir die KI-Hilfe"
    static let costLine = "ohne KI · 0 Credits"

    /// "Was die KI-Hilfe kann": ein Punkt je Modus der KI-Hilfe im Editor (und die zwei Aktionen hier)
    static let can = Section(title: "Was die KI-Hilfe kann", icon: "sparkles", items: [
        "Eine Seite oder eine Markierung erklären – auf Wunsch so einfach wie möglich",
        "Eine Aufgabe Schritt für Schritt lösen – oder nur Hinweise geben, ohne die Lösung zu verraten",
        "Deine eigene Lösung prüfen: was stimmt, wo der Fehler liegt",
        "Fachbegriffe der Seite kurz definieren",
        "Eine Seite zusammenfassen und sagen, was du danach können musst",
        "Karteikarten aus Seiten vorschlagen – du siehst jede Karte, bevor sie gespeichert wird",
        "Einen Wochentest mit 15 Aufgaben zu einer Lehrwoche erstellen",
    ])

    /// "So faengst du an": fuenf Beispiel-Fragen, die beim Antippen ins Feld kommen
    static let examples: [String] = [
        "Erkläre mir diese Seite so einfach wie möglich.",
        "Was muss ich nach dieser Vorlesung können? Nenne 3 Punkte.",
        "Löse Aufgabe 1 Schritt für Schritt.",
        "Gib mir nur Hinweise zu Aufgabe 2, keine fertige Lösung.",
        "Welche Fachbegriffe kommen hier vor? Definiere sie kurz.",
    ]

    static let start = Section(title: "So fängst du an", icon: "pencil", items: [
        "Wähle oben ein Modul und hänge ein Dokument an – die KI liest dann dessen erste Seite.",
        "Im Editor liest die KI-Hilfe die offene Seite oder deinen markierten Text.",
        "Antworten bleiben unter „Zuletzt“ auf diesem Gerät.",
    ])

    /// "Ohne Unterlagen": der Weg zu den Dateien fuehrt ueber den Abgleich mit der Hochschule (berechnet, nicht `let`:
    /// folgt `UFReleaseUniversities.shipped`, sonst friert der erste Zugriff im Prozess den Stand ein)
    static var without: Section { Section(title: "Ohne Unterlagen", icon: "sync", items: [
        UFReleaseUniversities.isShipped(.hildesheim) ? "Noch keine Dokumente? Verbinde in den Einstellungen Stud.IP (an der Uni Hildesheim: Learnweb)."
            : "Noch keine Dokumente? Verbinde in den Einstellungen \(UFReleaseUniversities.filePlatforms).",
        "Der Abgleich holt die Kursdateien in deine Bibliothek; danach wählst du hier eines als Kontext.",
        "Eigene PDFs kommen über „Dokumente & Notizen“ dazu.",
    ]) }

    static var sections: [Section] { [can, start, without] }

    /// Alle sichtbaren Texte (fuer den Ehrlichkeits-Test: keine Versprechen ohne Funktion)
    static var allText: String {
        ([title, costLine] + sections.flatMap { [$0.title] + $0.items } + examples).joined(separator: "\n")
    }
}

/// Antwortkarte der Aktion "Hilfe": drei Abschnitte mit Aufzaehlung, dazwischen die Beispiel-Fragen als Chips
/// (`example` setzt den Text ins Feld), unten der Weg zu den Einstellungen. Schliesst wie eine Antwort.
struct AIHelpCard: View {
    let example: (String) -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        UFCard {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 7.2) {
                    UFIcon("life-buoy", size: 18).foregroundStyle(CommunityPalette.lavender.fg)
                    Text(AIHelpContent.title).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                UFBadge(AIHelpContent.costLine, tone: .neutral)
                UFButton(nil, icon: "x", kind: .ghost, size: .small, action: close)
                    .accessibilityLabel("Hilfe schließen")
                    .accessibilityIdentifier("ai.start.help.close")
            }
            .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 14) {
                section(AIHelpContent.can)
                VStack(alignment: .leading, spacing: 8) {
                    section(AIHelpContent.start)
                    UFFlexWrap(gap: 6, rowGap: 6) {
                        ForEach(Array(AIHelpContent.examples.enumerated()), id: \.offset) { i, text in
                            UFChip(text: text, icon: "sparkles") { example(text) }
                                .accessibilityLabel("Beispiel: \(text)")
                                .accessibilityIdentifier("ai.start.help.example.\(i)")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    section(AIHelpContent.without)
                    UFButton("Einstellungen öffnen", icon: "settings", size: .small, action: openSettings)
                        .accessibilityIdentifier("ai.start.help.settings")
                }
            }
        }
        .accessibilityIdentifier("ai.start.help")
    }

    private func section(_ s: AIHelpContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                UFIcon(s.icon, size: 14).foregroundStyle(UF.accentText)
                Text(s.title).ufFont(14.5, 650).foregroundStyle(UF.text)
            }
            ForEach(Array(s.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(UF.accent).frame(width: 5, height: 5).offset(y: -2).accessibilityHidden(true)
                    Text(item).ufFont(13.76).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Dokument anhaengen

/// Waehler fuer den Kontext einer Frage: die lesbaren Dokumente des gewaehlten Moduls (zuletzt geoeffnete zuerst,
/// hoechstens 40), je Zeile Titel, Art und Seitenzahl; das angehaengte hat ein Haekchen. Antippen haengt an und
/// schliesst den Dialog.
struct AIDocumentPicker: View {
    @Environment(\.ufClose) private var close
    let documents: [JSONValue]
    let selected: String
    let pick: (JSONValue) -> Void

    /// Zweite Zeile einer Datei: Art, Seiten, zuletzt geoeffnet
    static func subtitle(_ f: JSONValue) -> String {
        var parts: [String] = []
        if let t = f.s("doc_type"), let label = LibraryStyle.typeFolders.first(where: { $0.0 == t })?.1 { parts.append(label) }
        if let n = f.i("page_count"), n > 0 { parts.append(n == 1 ? "1 Seite" : "\(n) Seiten") }
        if f.s("last_opened") != nil { parts.append("zuletzt geöffnet") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        UFDialog("Dokument anhängen", icon: "file-text") {
            if documents.isEmpty {
                UFEmpty(icon: "file-text", text: "Kein geladenes PDF in diesem Modul. Nach dem Abgleich mit der Hochschule stehen die Kursdateien hier.", small: true)
            } else {
                Text("Die KI liest die erste Seite des Dokuments als Kontext deiner Frage.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(documents.prefix(40).enumerated()), id: \.offset) { i, f in
                            row(f, index: i)
                            if i < min(documents.count, 40) - 1 { Rectangle().fill(UF.line).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        } foot: {
            UFButton("Abbrechen", kind: .ghost) { close() }.accessibilityIdentifier("ai.start.picker.cancel")
        }
        .accessibilityIdentifier("ai.start.picker")
    }

    private func row(_ f: JSONValue, index: Int) -> some View {
        let on = f.s("id") == selected
        let title = AIStartView.title(f)
        let sub = Self.subtitle(f)
        return Button {
            pick(f)
            close()
        } label: {
            HStack(spacing: 10) {
                UFIcon("file-text", size: 16).foregroundStyle(on ? UF.accentText : UF.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).ufFont(14.5, on ? 650 : 500, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    if !sub.isEmpty { Text(sub).ufFont(12.8, lh: 1.3).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if on { UFIcon("check", size: 16).foregroundStyle(UF.accentText) }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(sub.isEmpty ? title : "\(title). \(sub)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("ai.start.picker.\(index)")
    }
}

// MARK: - Reine Entscheidungen der Seite

/// Das Dokument, das einer Frage als Kontext anhaengt: Titel und der Grund, wenn es die Vorgabe ist (zuletzt
/// geoeffnet bzw. neuestes Dokument des Moduls); nach "Entfernen" oder ohne Dokumente nichts
struct AIAttachment: Equatable {
    let id: String
    let title: String
    /// "zuletzt geöffnet" / "neuestes Dokument" fuer die Vorgabe, sonst nil (vom Nutzer gewaehlt)
    let hint: String?

    var label: String { hint.map { "\(title) · \($0)" } ?? title }
}

extension AIStartView {
    /// Anordnung der Aktionen ueber dem Frage-Feld
    enum ActionsLayout: Equatable {
        /// kompakte, umrandete Pillen in einer Reihe, die bei Bedarf auf zwei Zeilen umbricht
        case row
        /// eine Spalte in voller Breite (schmal oder sehr grosse Schrift): nichts wird gekuerzt
        case stack
    }

    static func actionsLayout(width: CGFloat, typeSize: DynamicTypeSize) -> ActionsLayout {
        if typeSize.isAccessibilitySize { return .stack }
        return width < 520 ? .stack : .row
    }

    /// Das angehaengte Dokument zu `fileID` aus den lesbaren Dokumenten (`documents(_:module:)`, Vorgabe zuerst)
    static func attachment(fileID: String, documents: [JSONValue]) -> AIAttachment? {
        guard !fileID.isEmpty, let f = documents.first(where: { $0.s("id") == fileID }), let id = f.s("id") else { return nil }
        let isDefault = documents.first?.s("id") == id
        let hint = isDefault ? (f.s("last_opened") != nil ? "zuletzt geöffnet" : "neuestes Dokument") : nil
        return AIAttachment(id: id, title: title(f), hint: hint)
    }
}
