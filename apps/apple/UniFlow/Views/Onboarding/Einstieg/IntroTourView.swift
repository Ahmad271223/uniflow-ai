import SwiftUI

// Rundgang (neuer Einstieg, Schritt 2): vier Seiten mit je einem Bild aus kleinen App-Ausschnitten (erfundene
// Beispiele), Titel und einem Satz. Oben Fortschritt und "Überspringen", unten "Weiter". Nur was StudiNow heute kann;
// KI-Karteikarten mit dem Zusatz "mit Pro AI".

/// Eine Seite des Rundgangs
enum IntroTourPage: Int, CaseIterable, Identifiable {
    case uni, exams, plan, notes

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .uni: return "Deine Hochschule kommt zu dir"
        case .exams: return "Prüfungen immer im Blick"
        case .plan: return "Ein Lernplan, der mitdenkt"
        case .notes: return "Schreiben, markieren, wiederholen"
        }
    }

    var text: String {
        switch self {
        case .uni:
            return UFDevice.adapt("Kurse, Dateien, Stundenplan und Noten holt StudiNow selbst von Stud.IP und QIS – geordnet nach Fächern, direkt auf dein iPad.")
        case .exams:
            return "Klausurtermine aus QIS landen automatisch im Kalender. Fehlt einer, trägst du ihn mit zwei Tipps ein."
        case .plan:
            return "Der Smart Planner verteilt Lernzeit auf deine freien Stunden – passend zu Prüfungen und Lernzielen."
        case .notes:
            return UFDevice.adapt("Notizen mit dem Apple Pencil direkt im Skript, dazu Karteikarten zum Wiederholen – mit Pro AI auch aus deinen Unterlagen.")
        }
    }
}

/// Der Rundgang: Seiten nacheinander; `onDone` nach der letzten Seite oder bei "Überspringen"
struct IntroTourView: View {
    var start: IntroTourPage = .uni
    let onDone: () -> Void
    @State private var page: IntroTourPage?

    private var current: IntroTourPage { page ?? start }

    var body: some View {
        IntroTourLayout(page: current, onBack: current == .uni ? nil : { go(-1) }, onNext: { go(1) }, onSkip: onDone)
    }

    private func go(_ step: Int) {
        guard let next = IntroTourPage(rawValue: current.rawValue + step) else {
            if step > 0 { onDone() }
            return
        }
        withAnimation(UFMotion.animation(reduce: !UFMotion.moves)) { page = next }
    }
}

/// Aufbau einer Seite des Rundgangs
struct IntroTourLayout: View {
    let page: IntroTourPage
    var onBack: (() -> Void)?
    let onNext: () -> Void
    let onSkip: () -> Void

    private var last: Bool { page == IntroTourPage.allCases.last }

    var body: some View {
        VStack(spacing: 0) {
            IntroTopBar(count: IntroTourPage.allCases.count, index: page.rawValue, onBack: onBack, onSkip: last ? nil : onSkip)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        IntroTourArt(page: page)
                            .frame(maxWidth: IntroStyle.column, minHeight: 300, maxHeight: min(420, geo.size.height * 0.52))
                            .id(page)
                            .transition(.opacity)
                        Text(page.title).ufFont(30, 700, em: -0.02).foregroundStyle(UF.text)
                            .multilineTextAlignment(.center).padding(.top, 34)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("intro.tour.title")
                        Text(page.text).ufFont(17).foregroundStyle(UF.text2)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 520).padding(.top, 10)
                    }
                    .padding(.horizontal, 24).padding(.top, 20)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            IntroCTA(title: last ? "Los geht’s" : "Weiter", action: onNext)
                .accessibilityIdentifier("intro.tour.next")
                .padding(.horizontal, 24).padding(.bottom, 28).padding(.top, 8)
        }
        .background(UF.bg.ignoresSafeArea())
    }
}

/// Helle Buehne des Rundgangs (Akzent-Schimmer statt der Nachtfarben)
struct IntroSoftStage: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IntroStyle.stageRadius, style: .continuous).fill(UF.surface2)
            GeometryReader { geo in
                let s = max(geo.size.width, geo.size.height)
                ZStack {
                    RadialGradient(colors: [UF.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: s * 0.7)
                    RadialGradient(colors: [IntroStyle.teal.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: s * 0.6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: IntroStyle.stageRadius, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

/// Bild einer Seite
struct IntroTourArt: View {
    let page: IntroTourPage

    var body: some View {
        ZStack {
            IntroSoftStage()
            IntroArtFit {
                switch page {
                case .uni: IntroArtUni()
                case .exams: IntroArtExams()
                case .plan: IntroArtPlan()
                case .notes: IntroArtNotes()
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// iPhone (13.11.2026): Die Bilder des Rundgangs sind aus festen Kacheln gebaut und zusammen rund 560 pt breit; schmal
/// schoben sie die ganze Seite (auch Titel und Text) ueber den Rand. Am iPhone wird das Bild als Ganzes verkleinert,
/// am iPad und am Mac bleibt es unveraendert.
struct IntroArtFit<Content: View>: View {
    @ViewBuilder let content: Content

    /// Breite, fuer die die Bilder gezeichnet sind
    static var design: CGFloat { 560 }

    /// Verkleinerung bei dieser Breite (reine Funktion fuer Tests)
    static func scale(width: CGFloat) -> CGFloat { width <= 0 ? 1 : min(1, width / design) }

    var body: some View {
        if UFCompact.phoneLayouts {
            GeometryReader { g in
                content
                    .frame(width: Self.design)
                    .scaleEffect(Self.scale(width: g.size.width))
                    .frame(width: g.size.width, height: g.size.height)
            }
        } else {
            content
        }
    }
}

/// Stud.IP und QIS fliessen in StudiNow: zwei Quellen links, die Fächer rechts
struct IntroArtUni: View {
    var body: some View {
        HStack(spacing: 22) {
            VStack(spacing: 14) {
                IntroSourcePill(icon: "folder", title: "Stud.IP", detail: "Kurse · Dateien")
                IntroSourcePill(icon: "graduation", title: "QIS", detail: "Noten · Prüfungen")
                IntroSourcePill(icon: "calendar", title: "Stundenplan", detail: "Termine · Räume")
            }
            UFIcon("arrow-right", size: 26).foregroundStyle(UF.accent)
            IntroTile(width: 250) {
                IntroTileHead(icon: "book", title: "Deine Fächer")
                IntroModuleLine(color: Color(hex: 0x4f5bd5), name: "Analysis I", files: "12 Dateien · 2 neu")
                IntroModuleLine(color: Color(hex: 0x0ea5e9), name: "Technische Mechanik", files: "8 Dateien")
                IntroModuleLine(color: Color(hex: 0x16a34a), name: "Programmieren", files: "5 Dateien · 1 neu")
            }
        }
        .padding(24)
    }
}

struct IntroSourcePill: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            UFIcon(icon, size: 16).foregroundStyle(UF.accentText)
                .frame(width: 32, height: 32).background(Circle().fill(UF.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).ufFont(13.6, 650).foregroundStyle(UF.text)
                Text(detail).ufFont(11.2).foregroundStyle(UF.muted)
            }
        }
        .padding(.vertical, 8).padding(.leading, 8).padding(.trailing, 14)
        .frame(width: 180, alignment: .leading)
        .background(Capsule().fill(UF.surface))
        .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

struct IntroModuleLine: View {
    let color: Color
    let name: String
    let files: String

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).ufFont(12.8, 600).foregroundStyle(UF.text)
                Text(files).ufFont(11.2).foregroundStyle(UF.muted)
            }
        }
    }
}

/// Klausuren mit Countdown, eine "aus QIS", eine "von dir"
struct IntroArtExams: View {
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            IntroExamCard(module: "Lineare Algebra", date: "Mo, 8. Feb.", days: 12, source: "aus QIS", color: Color(hex: 0x4f5bd5))
                .rotationEffect(.degrees(-3))
            IntroExamCard(module: "Programmieren", date: "Do, 18. Feb.", days: 22, source: "von dir", color: Color(hex: 0x16a34a))
                .rotationEffect(.degrees(2.5)).offset(y: 26)
        }
        .padding(24)
    }
}

struct IntroExamCard: View {
    let module: String
    let date: String
    let days: Int
    let source: String
    let color: Color

    var body: some View {
        IntroTile(width: 210) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(module).ufFont(13.6, 650).foregroundStyle(UF.text)
            }
            Text(date).ufFont(12.8).foregroundStyle(UF.text2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(days)").ufFont(38, 700, em: -0.03).foregroundStyle(UF.text)
                Text("Tage").ufFont(13.12).foregroundStyle(UF.muted)
            }
            UFBadge(source, tone: source == "aus QIS" ? .ok : .neutral, icon: source == "aus QIS" ? "check" : "pen")
        }
    }
}

/// Wochenstreifen mit Lernbloecken
struct IntroArtPlan: View {
    private let days = ["Mo", "Di", "Mi", "Do", "Fr"]
    private let blocks: [[(Color, CGFloat)]] = [
        [(Color(hex: 0x4f5bd5), 46), (Color(hex: 0x16a34a), 30)],
        [(Color(hex: 0x0ea5e9), 60)],
        [(Color(hex: 0x4f5bd5), 34), (Color(hex: 0x0ea5e9), 30)],
        [(Color(hex: 0x16a34a), 52)],
        [(Color(hex: 0x4f5bd5), 40), (Color(hex: 0x16a34a), 24)],
    ]

    var body: some View {
        IntroTile(width: 420) {
            HStack {
                IntroTileHead(icon: "calendar", title: "Diese Woche")
                Spacer()
                UFBadge("4 h 20 min geplant", tone: .accent)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(days.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text(days[i]).ufFont(11.84, 600).foregroundStyle(UF.muted)
                        ForEach(blocks[i].indices, id: \.self) { j in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(blocks[i][j].0.opacity(0.85))
                                .frame(height: blocks[i][j].1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
    }
}

/// Skript mit Pencil-Strich und Karteikarte daneben
struct IntroArtNotes: View {
    var body: some View {
        ZStack {
            IntroTile(width: 250) {
                IntroTileHead(icon: "file-text", title: "Vorlesung 5.pdf", tint: UF.bad)
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(UF.surface2).frame(width: [190, 160, 200, 120, 170][i], height: 7)
                }
                IntroPencilStroke().frame(width: 180, height: 34)
            }
            .rotationEffect(.degrees(-4)).offset(x: -95, y: -10)
            IntroTile(width: 220) {
                IntroTileHead(icon: "cards", title: "Karteikarte", tint: Color(hex: 0x8b5cf6))
                Text("Wann ist eine Matrix invertierbar?").ufFont(13.6, 600).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Wenn ihre Determinante nicht 0 ist.").ufFont(12.16).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .rotationEffect(.degrees(3)).offset(x: 120, y: 30)
        }
        .padding(24)
    }
}

/// Handschriftlicher Unterstrich (Bild)
struct IntroPencilStroke: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 4, y: 22))
            p.addCurve(to: CGPoint(x: 176, y: 16), control1: CGPoint(x: 60, y: 8), control2: CGPoint(x: 120, y: 34))
        }
        .stroke(Color(hex: 0xf59e0b).opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
    }
}
