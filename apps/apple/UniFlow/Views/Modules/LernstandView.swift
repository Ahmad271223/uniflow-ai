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

/// Kachel "Lernstand" im Stil einer Kennzahl-Karte (Neugestaltung 04.11.2026): Symbolkachel, Titel, Begruendung
/// ("3 Wochentests, 42 Karten, 12 von 20 Aufgaben") und rechts der Ring mit der Prozentzahl, auf einem leisen Verlauf
/// aus der Modulfarbe in die Kartenflaeche (nur UF-Farben gemischt, darum hell wie dunkel). Ohne Lernstand ruhig grau
/// mit dem Hinweis, was ihn hebt. `.card`: Modulseite; `.inline`: Modulkarten und Modulzeilen der Uebersicht. Schrift
/// und Ring wachsen mit Dynamic Type; VoiceOver liest einen Satz wie `LernstandBadge`.
struct LernstandTile: View {
    enum Style { case card, inline }
    let m: JSONValue?
    var color: Color = UF.accent
    var style: Style = .card
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let score = LernstandText.score(m)
        let has = score != nil
        let big = style == .card
        let radius: CGFloat = big ? UF.r : 10
        let ring = min(UFScaledFont.scaled(big ? 58 : 44, typeSize), big ? 92 : 72)
        HStack(alignment: .center, spacing: big ? 14 : 10) {
            iconTile(has: has, big: big)
            VStack(alignment: .leading, spacing: big ? 2 : 1) {
                Text(has ? "Lernstand" : LernstandText.label(m))
                    .ufFont(big ? 15.2 : 13.6, 650, lh: 1.3)
                    .foregroundStyle(has ? UF.text : UF.text2)
                Text(LernstandText.sub(m))
                    .ufFont(big ? 13.12 : 12.48, lh: 1.35)
                    .foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                LernstandRing(percent: Double(score ?? 0), color: has ? color : UF.lineStrong, lineWidth: big ? 5 : 4)
                Text(score.map { "\($0)\u{00A0}%" } ?? "–")
                    .ufFont(big ? 13.6 : 11.2, 700, lh: 1)
                    .monospacedDigit()
                    .foregroundStyle(has ? UF.text : UF.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, big ? 7 : 5)
            }
            .frame(width: ring, height: ring)
        }
        .padding(big ? 14 : 10)
        .background(RoundedRectangle(cornerRadius: radius).fill(wash(has)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(has ? Color.mix(color, 0.22, UF.line) : UF.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LernstandText.accessibility(m))
        .accessibilityIdentifier("lernstand")
    }

    /// Symbolkachel: Stern auf einer Flaeche in der Modulfarbe, ohne Lernstand grau
    private func iconTile(has: Bool, big: Bool) -> some View {
        let side: CGFloat = big ? 40 : 30
        let r: CGFloat = big ? 11 : 8
        return RoundedRectangle(cornerRadius: r)
            .fill(has ? Color.mix(color, 0.2, UF.surface) : UF.surface2)
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(has ? Color.mix(color, 0.4, UF.surface) : UF.line, lineWidth: 1))
            .overlay(UFIcon("star", size: big ? 19 : 15).foregroundStyle(has ? Color.mix(color, 0.72, UF.text) : UF.muted))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    /// leiser Verlauf: oben links ein Hauch Modulfarbe, unten rechts die Kartenflaeche
    private func wash(_ has: Bool) -> LinearGradient {
        LinearGradient(colors: has ? [Color.mix(color, 0.13, UF.surface), Color.mix(color, 0.03, UF.surface)]
                                   : [UF.surface2, Color.mix(UF.surface2, 0.4, UF.surface)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
