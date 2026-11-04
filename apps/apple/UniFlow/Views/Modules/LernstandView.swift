import SwiftUI
import UniFlowCore

/// Texte zum Lernstand je Modul (docs/LERNSTAND-2026-11-04.md): Feld `mastery` aus GET /api/modules und
/// /api/modules/{id} ({score, reason, tests, cards, tasks_done, tasks_total} oder null). Gerechnet wird nur im Kern
/// (Mastery.swift, dieselbe Zahl wie am PC); hier nur die Beschriftung. Dieselben Texte wie app/static/mastery.js
/// (packages/shared-contracts/fixtures/mastery/cases.json, LernstandAppTests).
enum LernstandText {
    /// Hinweis ohne Lernstand: was ihn hebt
    static let hint = "Steigt mit Wochentests, bewerteten Karteikarten und erledigten Aufgaben."

    /// 0…100 oder nil (null, fehlendes Feld, alter Server)
    static func score(_ m: JSONValue?) -> Int? {
        guard let m, !m.isNull, let s = m["score"]?.double, s.isFinite else { return nil }
        return max(0, min(100, Int(s.rounded())))
    }

    /// "Lernstand 64 %" (geschuetztes Leerzeichen vor dem Prozent) oder "noch kein Lernstand"
    static func label(_ m: JSONValue?) -> String {
        score(m).map { "Lernstand \($0)\u{00A0}%" } ?? "noch kein Lernstand"
    }

    /// Unterzeile: die Begruendung ("3 Wochentests, 42 Karten, 12 von 20 Aufgaben"), ohne Lernstand der Hinweis
    static func sub(_ m: JSONValue?) -> String {
        score(m) == nil ? hint : (m?["reason"]?.string ?? "")
    }

    /// Ein Satz fuer VoiceOver: "Lernstand 64 Prozent, 3 Wochentests" bzw. "noch kein Lernstand, steigt mit …"
    static func accessibility(_ m: JSONValue?) -> String {
        let head = score(m).map { "Lernstand \($0) Prozent" } ?? "noch kein Lernstand"
        let s = sub(m)
        return s.isEmpty ? head : "\(head), \(s)"
    }
}

/// Ring mit "Lernstand 64 %" und der Begruendung als Unterzeile (Modulkarte, Modulseite); klein nur Ring und Zahl
/// (Uebersicht, Modulliste). Ohne Lernstand grau mit dem Hinweis, was ihn hebt. Schrift skaliert mit den
/// Bedienungshilfen (ufFont), VoiceOver liest Zahl und Begruendung als einen Satz.
struct LernstandBadge: View {
    enum Size { case small, medium }
    let m: JSONValue?
    var color: Color = UF.accent
    var size: Size = .medium

    var body: some View {
        let score = LernstandText.score(m)
        let tint = score == nil ? UF.muted : color
        HStack(spacing: size == .small ? 6.4 : 9.6) {
            LernstandRing(percent: Double(score ?? 0), color: tint, lineWidth: size == .small ? 3 : 4)
                .frame(width: size == .small ? 18 : 36, height: size == .small ? 18 : 36)
            VStack(alignment: .leading, spacing: 1.6) {
                Text(LernstandText.label(m)).ufFont(size == .small ? 12.8 : 13.6, 700)
                    .foregroundStyle(score == nil ? UF.muted : UF.text).monospacedDigit()
                if size == .medium {
                    Text(LernstandText.sub(m)).ufFont(12.8).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LernstandText.accessibility(m))
        .accessibilityIdentifier("lernstand")
    }
}

/// Offener Ring: Spur in --line, Bogen in Modulfarbe von oben im Uhrzeigersinn
struct LernstandRing: View {
    let percent: Double
    var color: Color = UF.accent
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(UF.line, lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0, min(100, percent)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(UF.motion(.easeInOut(duration: 0.3)), value: percent)
        }
    }
}
