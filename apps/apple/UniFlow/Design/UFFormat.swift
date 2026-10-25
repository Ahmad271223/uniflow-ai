import SwiftUI
import UniFlowCore

/// Formatierungen aus app/static/core.js (fmtMin, fmtShort, shortName, Begruessung) – gleiche Ausgaben wie im Web.
enum UFFmt {
    /// fmtMin: 45 -> "45 min", 60 -> "1 h", 90 -> "1 h 30 min"
    static func min(_ m: Int) -> String {
        m >= 60 ? "\(m / 60) h" + (m % 60 != 0 ? " \(m % 60) min" : "") : "\(m) min"
    }

    static func min(_ m: Double?) -> String { min(Int((m ?? 0).rounded())) }

    /// shortName: lange Modulnamen wie im Web kuerzen
    static func shortName(_ s: String?) -> String {
        (s ?? "")
            .replacingOccurrences(of: "Mathematik für die Ingenieurwissenschaften", with: "Mathematik")
            .replacingOccurrences(of: "Elektrotechnische Grundlagen der Informatik", with: "Elektrotechnik")
            .replacingOccurrences(of: "Datenstrukturen und Algorithmen", with: "Datenstrukturen & Algorithmen")
            .replacingOccurrences(of: "Grundlagen digitaler Systeme", with: "Digitale Systeme")
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate(pattern)
        return f
    }

    private static let shortF = formatter("EEEddMM")          // "Mo., 27.10."
    private static let longTodayF = formatter("EEEEdMMMM")    // "Sonntag, 25. Oktober"
    private static let dateF = formatter("ddMMyyyy")          // "27.10.2026"

    /// fmtShort: Wochentag kurz, Tag und Monat zweistellig
    static func short(_ iso: String?) -> String {
        guard let d = Fmt.date(iso) else { return iso ?? "" }
        return shortF.string(from: d)
    }

    /// fmtDate: TT.MM.JJJJ
    static func date(_ iso: String?) -> String {
        guard let d = Fmt.date(iso) else { return iso ?? "" }
        return dateF.string(from: d)
    }

    static func longToday(_ d: Date = Date()) -> String { longTodayF.string(from: d) }

    /// Begruessung wie viewDashboard: vor 11 Uhr, vor 18 Uhr, danach
    static func greeting(_ d: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: d)
        return h < 11 ? "Guten Morgen" : h < 18 ? "Guten Tag" : "Guten Abend"
    }

    static func todayISO() -> String { Fmt.isoDay(Date()) }

    /// DAYS[(getDay()+6)%7]: Mo…So zum ISO-Datum
    static func weekdayShort(_ iso: String?) -> String {
        guard let d = Fmt.date(iso) else { return "" }
        let w = Calendar(identifier: .gregorian).component(.weekday, from: d)   // 1 = Sonntag
        return ShellState.days[(w + 5) % 7]
    }
}

/// Laden/Fehler wie route() in app.js: Platzhalter-Balken beim Laden, Karte "Server nicht erreichbar" mit
/// "Jetzt neu laden" und "Diagnose" bei Netzfehlern, sonst Karte "Fehler".
struct UFRemote<Content: View>: View {
    @ObservedObject var data: RemoteData
    @EnvironmentObject private var router: UFRouter
    @ViewBuilder var content: (JSONValue) -> Content

    var body: some View {
        switch data.state {
        case .loading:
            UFContent {
                UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16)
                HStack(spacing: 16) { ForEach(0..<3, id: \.self) { _ in UFSkeleton().frame(height: 120) } }
            }
        case .failed(let message):
            let offline = data.failedOffline
            UFContent {
                UFCard {
                    HStack(spacing: 7.2) { UFIcon("alert", size: 18); Text(offline ? "Server nicht erreichbar" : "Fehler").font(UF.h2) }
                        .foregroundStyle(UF.text)
                    Text(offline
                         ? "Die App holt ihre Daten vom UniFlow-Server auf deinem PC. Der Server startet gerade neu oder wurde beendet."
                         : message)
                        .font(UF.body).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                    HStack(spacing: 9.6) {
                        UFButton("Jetzt neu laden", icon: "refresh", kind: .primary) { Task { await data.load() } }
                        UFButton("Diagnose") { router.go(.settings(tab: "diag")) }
                    }
                }
                .frame(maxWidth: 600)
            }
        case .loaded(let value, let offlineSince):
            VStack(spacing: 0) {
                if let offlineSince {
                    HStack(spacing: 6) { UFIcon("alert", size: 14); Text("Offline – Stand \(Fmt.relative(offlineSince))") }
                        .font(UF.small).foregroundStyle(UF.warn)
                        .frame(maxWidth: .infinity).padding(6).background(UF.warnSoft)
                }
                content(value)
            }
        }
    }
}

/// .skeleton – Platzhalter mit wanderndem Verlauf
struct UFSkeleton: View {
    @State private var phase: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: UF.rSm)
                .fill(LinearGradient(stops: [.init(color: UF.surface2, location: 0.25), .init(color: UF.line, location: 0.5),
                                             .init(color: UF.surface2, location: 0.75)],
                                     startPoint: UnitPoint(x: phase, y: 0.5), endPoint: UnitPoint(x: phase + 1, y: 0.5)))
                .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = -1 } }
                .frame(width: g.size.width, height: g.size.height)
        }
        .frame(minHeight: 14)
    }
}
