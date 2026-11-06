import Foundation
import SwiftUI

/// Lineal in der geteilten Ansicht (Skript und Blatt nebeneinander, 06.11.2026): Apples Palette gilt fuer beide
/// Dokumente, ihr Lineal-Knopf schaltete das Lineal deshalb auf beiden Seiten ein. Jetzt waehlt man, wo es liegt:
/// links, rechts oder auf beiden. Ohne zweites Dokument liegt es wie immer auf dem einen Dokument.
enum RulerTarget: String, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "Links"
        case .right: return "Rechts"
        case .both: return "Beide"
        }
    }
}

@MainActor
final class RulerChoice: ObservableObject {
    static let shared = RulerChoice()
    static let defaultsKey = "editor.rulerTarget"

    /// Wo das Lineal in der geteilten Ansicht liegt (gemerkt)
    @Published var target: RulerTarget {
        didSet {
            defaults.set(target.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: .ufRulerChoiceChanged, object: nil)
        }
    }
    /// Lineal in der Palette eingeschaltet (vom Hauptdokument gemeldet)
    @Published var rulerOn = false
    /// Zweites Dokument offen, und ob das Hauptdokument links steht (Linkshaender: rechts)
    @Published private(set) var splitActive = false
    private(set) var primaryIsLeft = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        target = RulerTarget(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .left
    }

    func setSplit(_ active: Bool, primaryIsLeft: Bool) {
        guard active != splitActive || primaryIsLeft != self.primaryIsLeft else { return }
        splitActive = active
        self.primaryIsLeft = primaryIsLeft
        NotificationCenter.default.post(name: .ufRulerChoiceChanged, object: nil)
    }

    /// Bekommt dieses Dokument das Lineal? `primary` = Hauptdokument (besitzt die Palette).
    func applies(primary: Bool) -> Bool {
        guard splitActive else { return primary }
        let isLeft = primary == primaryIsLeft
        switch target {
        case .both: return true
        case .left: return isLeft
        case .right: return !isLeft
        }
    }
}

extension Notification.Name {
    static let ufRulerChoiceChanged = Notification.Name("uf.rulerChoiceChanged")
}

/// Kleine Leiste "Lineal: Links · Rechts · Beide", nur in der geteilten Ansicht und nur bei eingeschaltetem Lineal
struct RulerTargetBar: View {
    @ObservedObject var choice: RulerChoice

    var body: some View {
        if choice.splitActive && choice.rulerOn {
            HStack(spacing: 8) {
                Image(systemName: "ruler").accessibilityHidden(true)
                Text("Lineal").font(.subheadline.weight(.semibold))
                Picker("Lineal", selection: $choice.target) {
                    ForEach(RulerTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityIdentifier("ruler.target")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lineal auf welcher Seite")
            .transition(.opacity)
        }
    }
}
