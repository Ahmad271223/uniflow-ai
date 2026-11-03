import SwiftUI
import UniFlowCore

// Oberflaeche des Korrektur-Modus im Dokument (`Editor/CorrectionMode.swift`): Leiste oben mit "Korrektur senden" /
// "Verwerfen", Randnotiz setzen, Begleittext; Banner einer empfangenen Korrektur. Die Liste der Korrekturen und der
// Posteingang ("Deine Lösung hat einen Korrekturhinweis …") gehoeren zur Community-Oberflaeche.

/// Stelle, an der gerade eine Randnotiz gesetzt wird
struct CorrectionNotePlacement: Identifiable, Equatable {
    let id = UUID()
    let info: CorrectionPageInfo
    let x: Double
    let y: Double
}

/// Leiste des Korrektur-Modus
struct CorrectionBar: View {
    @ObservedObject var session: CorrectionSession
    let send: () async -> Void
    let editMessage: () -> Void
    let pause: () -> Void
    let discard: () -> Void

    private var targetName: String {
        let n = session.target.displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? CommunityDiscussion.anonymousName : n
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline").foregroundStyle(UF.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("Korrektur: Lösung von \(targetName)").font(.caption).bold()
                Text(session.summary + (session.draft.note.isEmpty ? "" : " · mit Nachricht")).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Werkzeug", selection: $session.placingNote) {
                Label("Markieren", systemImage: "highlighter").tag(false)
                Label("Randnotiz", systemImage: "text.bubble").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .accessibilityIdentifier("correction.tool")
            Button("Nachricht", action: editMessage)
                .buttonStyle(.bordered).controlSize(.small)
            Button("Verwerfen", role: .destructive, action: discard)
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("correction.discard")
            Button { pause() } label: { Image(systemName: "pause.circle") }
                .help("Später weitermachen (Entwurf bleibt gespeichert)")
                .accessibilityLabel("Später weitermachen")
            if session.sending {
                ProgressView().controlSize(.small)
            } else {
                Button("Korrektur senden") { Task { await send() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!session.canSend)
                    .accessibilityIdentifier("correction.send")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UF.info.opacity(0.5), lineWidth: 1))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("correctionBar")
    }
}

/// Hinweis ueber einer empfangenen Korrektur (beim Ersteller)
struct ShownCorrectionBanner: View {
    let correction: CommunityCorrection
    /// fremde Korrektur: liegt ueber der korrigierten Loesung (nicht ueber den eigenen Notizen)
    var onSolution = false
    /// an mich gerichtet: auf diesem Geraet ignorieren
    var ignore: (() -> Void)?
    let close: () -> Void

    private var detail: String {
        CorrectionTexts.summary(correction) + " (Nadeln antippen). "
            + (onSolution ? "Die Lösung selbst bleibt unverändert." : "Deine Notizen bleiben unverändert.")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(UF.warn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Korrekturhinweis von \(correction.displayName)").font(.caption).bold()
                if !correction.note.isEmpty { Text(correction.note).font(.caption).lineLimit(3) }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let ignore {
                Button("Ignorieren", action: ignore).buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("shownCorrection.ignore")
            }
            Button("Ausblenden", action: close).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UF.warn.opacity(0.6), lineWidth: 1))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shownCorrection")
    }
}

/// Dialoge des Korrektur-Modus: Randnotiz setzen, Randnotiz ansehen/loeschen, Begleittext, Verwerfen
struct CorrectionDialogs: ViewModifier {
    let correction: CorrectionSession?
    @Binding var notePlacement: CorrectionNotePlacement?
    @Binding var noteText: String
    @Binding var openedNote: CommunityCorrection.Note?
    @Binding var editingMessage: Bool
    @Binding var message: String
    @Binding var confirmDiscard: Bool
    let discard: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Randnotiz", isPresented: Binding(get: { notePlacement != nil }, set: { if !$0 { notePlacement = nil } })) {
                TextField("Was sollte hier anders sein?", text: $noteText)
                Button("Setzen") {
                    if let p = notePlacement { correction?.addNote(x: p.x, y: p.y, text: noteText, on: p.info) }
                    noteText = ""
                    notePlacement = nil
                }
                Button("Abbrechen", role: .cancel) { noteText = ""; notePlacement = nil }
            } message: { Text("Die Notiz erscheint an dieser Stelle als Nadel.") }
            .alert("Randnotiz", isPresented: Binding(get: { openedNote != nil }, set: { if !$0 { openedNote = nil } })) {
                if let n = openedNote, correction?.note(id: n.id) != nil {
                    Button("Löschen", role: .destructive) { correction?.removeNote(id: n.id); openedNote = nil }
                }
                Button("OK", role: .cancel) { openedNote = nil }
            } message: { Text(openedNote?.text ?? "") }
            .alert("Nachricht an den Ersteller", isPresented: $editingMessage) {
                TextField("Optional", text: $message, axis: .vertical)
                Button("Übernehmen") { correction?.setMessage(message) }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("Steht über deiner Korrektur. Höchstens \(CommunityCorrections.maxText) Zeichen.") }
            .confirmationDialog("Korrektur verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Verwerfen", role: .destructive, action: discard)
            } message: { Text("Markierungen und Randnotizen dieser Korrektur werden gelöscht. Es wurde nichts gesendet.") }
    }
}
