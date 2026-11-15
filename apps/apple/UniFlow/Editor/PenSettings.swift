import SwiftUI

// Einstellungen je Stift und eigene Stifte (Wunsch des Inhabers 14.11.2026: "Stift duenner machen ... wie ihre
// Stift-Einstellungen usw., abgucken, besser machen, komplett"). Eigene kleine Typen (`ViewTypeDepthAppTests`):
// - `PenSettingsPanel`: Staerke stufenlos (Schieber, "−"/"+", Zahl), Deckkraft, Glaettung als Stufenregler, Vorschau,
//   "Zurücksetzen", "Als eigenen Stift merken". Erscheint im Feld "Farbe und Stärke" (`EditorToolAttributes`, ein
//   `.ufPopover`), damit am Mac kein zweites Blatt ueber dem ersten liegt.
// - `PenPresetChips`: die eigenen Stifte in der Werkzeugleiste (antippen nimmt ihn, lange druecken: Entfernen).
// Linienart (gepunktet/gestrichelt) gibt es bewusst nicht: PencilKit kennt keine Strichmuster. Nachbauen hiesse,
// jeden Strich beim Absetzen in viele Einzelstriche zu zerlegen - waehrend des Schreibens saehe er anders aus, der
// Radierer naehme einzelne Stuecke, und im Abgleich mit Browser und iPhone waeren es viele Striche statt einer.

/// Texte (fuer Tests an einer Stelle)
@MainActor
enum PenSettingsText {
    static let open = "Einstellungen …"
    static let reset = "Zurücksetzen"
    static let remember = "Als eigenen Stift merken"
    static let remove = "Entfernen"
    static let toFineliner = "Zum Fineliner"
    static let smoothingScope = "Gilt für alle Stifte auf diesem iPad."

    /// Was den Stift ausmacht (welcher fein schreibt)
    static func character(_ t: EditorToolState.Tool) -> String {
        switch t {
        case .pen: return "Wird breiter, je fester du aufdrückst – wie ein Kugelschreiber."
        case .fineliner: return "Fein und immer gleich breit, egal wie fest du drückst – am besten für kleine Schrift."
        case .marker: return "Durchscheinend zum Hervorheben, liegt unter der Schrift."
        default: return ""
        }
    }

    static let penAtMinimum = "Dünner geht der Stift nicht. Für feinste Schrift nimm den Fineliner: ab 0,5 und immer gleich breit."

    /// "0,88", "2", "2,25"
    static func width(_ w: CGFloat) -> String {
        var s = String(format: "%.2f", Double(w))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    static func preset(_ p: EditorToolState.PenPreset) -> String {
        let t = p.toolValue?.title ?? "Stift"
        let name = EditorToolState.colors(for: p.toolValue ?? .pen).first { PaletteSync.sameColor($0.hex, p.style.hex) }?.name ?? "eigene Farbe"
        return "Eigener Stift: \(t), \(name), \(width(p.style.width))"
    }
}

/// Einstellungen eines Stifts (Stift, Fineliner, Textmarker)
struct PenSettingsPanel: View {
    @ObservedObject var tools: EditorToolState
    let tool: EditorToolState.Tool
    let back: () -> Void
    @AppStorage(PencilSmoothing.key) private var smoothing = PencilSmoothing.standard.rawValue

    private var range: ClosedRange<CGFloat> { EditorToolState.sliderRange(tool) }

    var body: some View {
        let s = tools.style(tool)
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(PenSettingsText.character(tool)).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            PenStrokePreview(style: s, tool: tool)
            widthRows(s)
            opacityRows(s)
            smoothingRows
            presetRows
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Button(action: back) { Label("Zurück", systemImage: "chevron.left").ufFont(13.6, 600) }
                .buttonStyle(.plain).foregroundStyle(UF.accentText)
                .accessibilityIdentifier("pen.settings.back")
            Spacer()
            Text(tool.title).ufFont(13.6, 650).foregroundStyle(UF.text)
            Spacer()
            Button(PenSettingsText.reset) { tools.resetStyle(tool) }
                .ufFont(13.6, 600).buttonStyle(.plain).foregroundStyle(UF.accentText)
                .accessibilityIdentifier("pen.settings.reset")
        }
    }

    @ViewBuilder private func widthRows(_ s: EditorToolState.Style) -> some View {
        HStack(spacing: 10) {
            Text("Stärke").ufFont(13.6, 600).foregroundStyle(UF.text)
            Spacer()
            stepButton("minus", up: false, s.width).accessibilityIdentifier("pen.settings.thinner")
            Text(PenSettingsText.width(s.width)).ufFont(14.5, 650).monospacedDigit().foregroundStyle(UF.text)
                .frame(minWidth: 44)
                .accessibilityIdentifier("pen.settings.width")
            stepButton("plus", up: true, s.width).accessibilityIdentifier("pen.settings.thicker")
        }
        HStack { Slider(value: Binding(get: { Double(min(max(s.width, range.lowerBound), range.upperBound)) },
                                       set: { tools.setWidth(CGFloat($0), for: tool) }),
                        in: Double(range.lowerBound)...Double(range.upperBound)).tint(UF.accent) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stärke")
            .accessibilityValue(PenSettingsText.width(s.width))
            .accessibilityAdjustableAction { dir in
                tools.setWidth(EditorToolState.steppedWidth(s.width, up: dir == .increment, for: tool), for: tool)
            }
            .accessibilityIdentifier("pen.settings.widthSlider")
        if tool == .pen, s.width <= range.lowerBound + 0.001 {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(UF.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PenSettingsText.penAtMinimum).ufFont(12.8).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Button(PenSettingsText.toFineliner) { tools.select(.fineliner) }
                        .ufFont(12.8, 650).buttonStyle(.plain).foregroundStyle(UF.accentText)
                        .accessibilityIdentifier("pen.settings.toFineliner")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.accentSoft))
        }
    }

    private func stepButton(_ icon: String, up: Bool, _ w: CGFloat) -> some View {
        Button { tools.setWidth(EditorToolState.steppedWidth(w, up: up, for: tool), for: tool) } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(UF.surface2))
        }
        .buttonStyle(.plain)
        .foregroundStyle(UF.text)
        .disabled(up ? w >= range.upperBound - 0.001 : w <= range.lowerBound + 0.001)
        .accessibilityLabel(up ? "Dicker" : "Dünner")
    }

    @ViewBuilder private func opacityRows(_ s: EditorToolState.Style) -> some View {
        HStack {
            Text("Deckkraft").ufFont(13.6, 600).foregroundStyle(UF.text)
            Spacer()
            Text("\(Int((s.alpha * 100).rounded())) %").ufFont(14.5, 650).monospacedDigit().foregroundStyle(UF.text)
        }
        Slider(value: Binding(get: { Double(s.alpha) }, set: { tools.setOpacity(CGFloat($0), for: tool) }), in: 0.1...1)
            .tint(UF.accent)
            .accessibilityLabel("Deckkraft")
            .accessibilityValue("\(Int((s.alpha * 100).rounded())) Prozent")
            .accessibilityIdentifier("pen.settings.opacity")
    }

    /// Glaettung als Stufenregler (Aus, Leicht, Normal), fuer alle Stifte dieses Geraets (`PencilSmoothing`)
    @ViewBuilder private var smoothingRows: some View {
        let levels = PencilSmoothing.options
        let index = levels.firstIndex { $0.value == smoothing } ?? levels.count - 1
        HStack {
            Text(PencilSmoothing.title).ufFont(13.6, 600).foregroundStyle(UF.text)
            Spacer()
            Text(levels[index].label).ufFont(14.5, 650).foregroundStyle(UF.text)
        }
        HStack { Slider(value: Binding(get: { Double(index) }, set: { smoothing = levels[min(levels.count - 1, max(0, Int($0.rounded())))].value }),
                        in: 0...Double(levels.count - 1), step: 1).tint(UF.accent) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PencilSmoothing.title)
            .accessibilityValue(levels[index].label)
            // VoiceOver: eine Stufe je Wischen (der Schieber selbst schob 10 % und rastete wieder ein)
            .accessibilityAdjustableAction { dir in
                let next = dir == .increment ? index + 1 : index - 1
                if levels.indices.contains(next) { smoothing = levels[next].value }
            }
            .accessibilityIdentifier("pen.settings.smoothing")
        HStack {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, l in
                Text(l.label).ufFont(11.5, i == index ? 650 : 500).foregroundStyle(i == index ? UF.text : UF.muted)
                if i < levels.count - 1 { Spacer() }
            }
        }
        .accessibilityHidden(true)
        Text(PenSettingsText.smoothingScope).ufFont(11.5).foregroundStyle(UF.muted)
    }

    @ViewBuilder private var presetRows: some View {
        UF.line.frame(height: 1)
        Button {
            tools.addPreset(from: tool)
        } label: {
            Label(PenSettingsText.remember, systemImage: "plus.circle").ufFont(13.6, 600)
        }
        .buttonStyle(.plain)
        .foregroundStyle(UF.accentText)
        .disabled(tools.presets.count >= EditorToolState.presetLimit)
        .accessibilityIdentifier("pen.settings.remember")
        if !tools.presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tools.presets) { p in
                    HStack(spacing: 10) {
                        PenPresetDot(preset: p)
                        Text(PenSettingsText.preset(p).replacingOccurrences(of: "Eigener Stift: ", with: "")).ufFont(12.8).foregroundStyle(UF.text)
                        Spacer()
                        Button { tools.removePreset(p.id) } label: { Image(systemName: "trash").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(UF.bad)
                            .accessibilityLabel("\(PenSettingsText.remove): \(PenSettingsText.preset(p))")
                            .accessibilityIdentifier("pen.preset.remove.\(p.id)")
                    }
                }
            }
        }
    }
}

/// Probestrich in Farbe, Staerke und Deckkraft, so gross wie auf der Seite in Seitenbreite (1 Seitenpunkt = 1,38
/// Bildschirmpunkte); der Stift wird in der Mitte etwas breiter (Druck), Fineliner bleibt gleich
struct PenStrokePreview: View {
    let style: EditorToolState.Style
    let tool: EditorToolState.Tool
    static let pageScale: CGFloat = 1.38

    var body: some View {
        Canvas { ctx, size in
            let color = Color(uiColor: UIColor(hex: style.hex) ?? .black).opacity(Double(style.alpha) * (tool == .marker ? 0.45 : 1))
            let n = 60
            var last: CGPoint?
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: 12 + t * (size.width - 24), y: size.height / 2 + sin(t * .pi * 3) * size.height * 0.22)
                if let a = last {
                    let pressure: CGFloat = tool == .pen ? 0.8 + 0.45 * sin(t * .pi) : 1
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: p)
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(0.5, style.width * Self.pageScale * pressure), lineCap: .round))
                }
                last = p
            }
        }
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.line, lineWidth: 1))
        .accessibilityLabel("Vorschau")
        .accessibilityIdentifier("pen.settings.preview")
    }
}

/// Punkt eines eigenen Stifts: Farbe, darunter ein Strich in seiner Staerke
struct PenPresetDot: View {
    let preset: EditorToolState.PenPreset

    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(Color(uiColor: UIColor(hex: preset.style.hex) ?? .black).opacity(Double(preset.style.alpha)))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(UF.lineStrong, lineWidth: 1))
            Capsule().fill(UF.text).frame(width: 14, height: min(5, max(1, preset.style.width * (preset.toolValue == .marker ? 0.2 : 0.8))))
        }
    }
}

/// Die eigenen Stifte in der Werkzeugleiste (zwischen den Stiften und dem Lineal)
struct PenPresetChips: View {
    @ObservedObject var tools: EditorToolState
    var onPick: (EditorToolState.Tool) -> Void = { _ in }

    var body: some View {
        ForEach(tools.presets) { p in
            let active = tools.isActive(p)
            Button {
                if let t = p.toolValue { onPick(t) }
                tools.applyPreset(p.id)
            } label: {
                PenPresetDot(preset: p).frame(width: 36, height: EditorToolbar.hitSide)
            }
            .buttonStyle(EditorToolButtonStyle(selected: active))
            .contextMenu {
                Button(role: .destructive) { tools.removePreset(p.id) } label: { Label(PenSettingsText.remove, systemImage: "trash") }
            }
            .accessibilityLabel(PenSettingsText.preset(p))
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("toolbar.preset.\(p.id)")
        }
    }
}
