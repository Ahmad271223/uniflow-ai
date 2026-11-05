import SwiftUI
import UniFlowCore

// Oberflaeche zu "Bildschirm fixieren" (docs/FIXIEREN-ABPAUSEN-2026-11-05.md): Abzeichen "Ansicht fixiert", die
// Sperre beim Abpausen mit dem Schloss in der Ecke und die Erklaerung beim ersten Mal.

/// Texte an einer Stelle (auch fuer Tests)
enum FreezeTexts {
    static let fixView = "Ansicht fixieren"
    static let releaseView = "Ansicht lösen"
    static let trace = "Zum Abpausen einfrieren"
    static let badge = "Ansicht fixiert"
    static let release = "Lösen"
    static let brightness = "Helligkeit auf Maximum"
    static let contrast = "Kontrast für Abpausen"
    static let unlockAction = "Entsperren"
    static let introTitle = "Bildschirm fixieren"
    static let viewExplain = "Zoom, Scrollen und Seitenwechsel sind gesperrt, der Apple Pencil schreibt weiter. "
        + "Gut für genaue technische Zeichnungen. Lösen über das Abzeichen oben oder ⌘L."
    static let traceExplain = "Die Seite füllt den Bildschirm im aktuellen Zoom, alle Leisten verschwinden und keine Berührung "
        + "wirkt mehr – auch nicht der Stift oder Papier, das darauf liegt. Der Bildschirm bleibt an. "
        + "Entsperren: das Schloss in der Ecke etwa zwei Sekunden halten oder Esc drücken."
    static let lockLabel = "Abpausen-Sperre"
    static let lockHint = "Zum Entsperren etwa zwei Sekunden gedrückt halten."
}

/// Abzeichen ueber der Seite, solange die Ansicht fixiert ist
struct FreezeBadge: View {
    let release: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption)
            Text(FreezeTexts.badge).font(.caption).bold()
            Button(FreezeTexts.release, action: release)
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("doc.freeze.release")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(UF.accent.opacity(0.5), lineWidth: 1))
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: FreezeTexts.release, release)
        .accessibilityIdentifier("doc.freeze.badge")
    }
}

/// Sperre beim Abpausen: nimmt jede Beruehrung an und tut nichts (Papier, Hand, Stift); nur das Schloss in der Ecke
/// entsperrt nach etwa zwei Sekunden Halten. Esc und die VoiceOver-Aktion "Entsperren" entsperren sofort.
struct TraceLockOverlay: View {
    @ObservedObject var freeze: EditorFreezeSession
    /// Ecke des Schlosses (gegenueber der Schreibhand: Rechtshaender oben links)
    var leading = false

    var body: some View {
        ZStack(alignment: leading ? .topLeading : .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .gesture(DragGesture(minimumDistance: 0))
                .accessibilityHidden(true)
            lockButton.padding(18)
        }
        .ignoresSafeArea()
        .background {
            // Tastatur: Esc entsperrt
            Button("") { freeze.unlock() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var lockButton: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.35))
            Circle()
                .trim(from: 0, to: freeze.holding ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(freeze.holding ? .linear(duration: EditorFreeze.unlockHoldDuration) : .easeOut(duration: 0.15),
                           value: freeze.holding)
            Image(systemName: freeze.holding ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 48, height: 48)
        .opacity(freeze.holding ? 0.95 : 0.3)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !freeze.holding { freeze.holdBegan() } }
                .onEnded { _ in freeze.holdEnded() }
        )
        .accessibilityElement()
        .accessibilityLabel(FreezeTexts.lockLabel)
        .accessibilityHint(FreezeTexts.lockHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: FreezeTexts.unlockAction) { freeze.unlock() }
        .accessibilityIdentifier("doc.freeze.unlock")
    }
}

/// Erklaerung beim ersten Mal: beide Stufen, Helligkeit und Kontrast, dann starten
struct FreezeIntroDialog: View {
    @Binding var maxBrightness: Bool
    @Binding var contrast: Bool
    let start: (EditorFreeze.Mode) -> Void
    let cancel: () -> Void

    var body: some View {
        UFDialog(FreezeTexts.introTitle) {
            VStack(alignment: .leading, spacing: 14) {
                explain(FreezeTexts.fixView, icon: "lock", FreezeTexts.viewExplain)
                explain(FreezeTexts.trace, icon: "lock.rectangle", FreezeTexts.traceExplain)
                if !PDFEditorController.isMac {
                    Toggle(FreezeTexts.brightness, isOn: $maxBrightness)
                        .accessibilityHint("Beim Abpausen; danach wieder wie vorher.")
                }
                Toggle(FreezeTexts.contrast, isOn: $contrast)
                    .accessibilityHint("Weißer Hintergrund ohne Seitenschatten.")
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen", action: cancel)
            UFButton(FreezeTexts.fixView) { start(.view) }
            UFButton(FreezeTexts.trace, kind: .primary) { start(.trace) }
        }
        .accessibilityIdentifier("doc.freeze.intro")
    }

    private func explain(_ title: String, icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(UF.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).bold().foregroundStyle(UF.text)
                Text(text)
            }
        }
    }
}

/// Meldet nach oben, dass ein Dokument zum Abpausen eingefroren ist (die Bibliothek blendet dann ihre Reiter aus)
struct EditorTracingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
