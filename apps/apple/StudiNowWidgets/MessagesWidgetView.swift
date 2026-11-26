import SwiftUI
import WidgetKit
#if UF_WIDGET_VIEWS_IN_TESTS
@testable import UniFlow                     // nur im Testbundle: Datenformat aus der App (WidgetShared)
#endif

// Widget "Nachrichten" (26.11.2026, docs/KALENDER-COUNTDOWN-NACHRICHTEN-2026-11-26.md): Zahl der ungelesenen
// Stud.IP- bzw. Learnweb-/Moodle-Nachrichten, wahlweise mit Uni-Mail, und die neuesten Absender und Betreffe.
// Sperrbildschirm: Zahl und Absender, Betreff nur mit dem Schalter in der App; ein Textanfang steht nur im
// Schnappschuss, wenn er eingeschaltet ist. Betreff und Text sind `privacySensitive` (gesperrt ausgeblendet).
// Auch in den App-Tests eingebunden (project.yml): WidgetSnapshotAppTests zeichnet jede Groesse.

extension WUI {
    static let messagesURL = URL(string: "uniflow://#/messages")
    static let uniMailURL = URL(string: "uniflow://#/unimail")

    /// "1 ungelesene Nachricht", "3 ungelesene Nachrichten", "Keine ungelesenen Nachrichten"
    static func unreadText(_ n: Int) -> String {
        n == 0 ? "Keine ungelesenen Nachrichten" : n == 1 ? "1 ungelesene Nachricht" : "\(n) ungelesene Nachrichten"
    }
}

struct MessagesEntry: TimelineEntry {
    let date: Date
    let data: HomeWidgetData?
}

struct MessagesWidgetView: View {
    let entry: MessagesEntry
    /// nur fuer die Testbilder (WidgetSnapshotAppTests); im Widget gilt die Familie aus der Umgebung
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    private var m: HomeWidgetData.Messages? { entry.data?.messages }

    /// Antippen: die Nachrichten der Quelle; nur Uni-Mail ungelesen: Uni-Mail
    private var tapURL: URL? {
        if let m, m.unread == 0, (m.mailUnread ?? 0) > 0 { return WUI.uniMailURL }
        return WUI.messagesURL
    }

    var body: some View {
        Group {
            if entry.data == nil {
                empty("StudiNow öffnen", "Nach dem Abgleich stehen hier deine ungelesenen Nachrichten.")
            } else if m == nil {
                empty("Keine Nachrichten", "Verbinde Stud.IP oder Uni-Mail in StudiNow, dann stehen hier neue Nachrichten.")
            } else if let m {
                content(m)
            }
        }
        .widgetURL(tapURL)
    }

    @ViewBuilder private func empty(_ title: String, _ text: String) -> some View {
        switch family {
        case .accessoryInline: Text(title)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "envelope").font(.title3)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(title).font(.headline).widgetAccentable()
                Text(text).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default: WidgetEmpty(icon: "envelope", title: title, text: text)
        }
    }

    @ViewBuilder private func content(_ m: HomeWidgetData.Messages) -> some View {
        switch family {
        case .accessoryInline:
            Label(m.total == 0 ? "Keine neuen Nachrichten" : WUI.unreadText(m.total), systemImage: "envelope")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: m.total > 0 ? "envelope.badge" : "envelope.open").font(.system(size: 12)).widgetAccentable()
                    Text("\(m.total)").font(.system(size: 18, weight: .bold)).minimumScaleFactor(0.6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WUI.unreadText(m.total))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label(m.total == 0 ? "Alles gelesen" : WUI.unreadText(m.total), systemImage: "envelope")
                    .font(.caption.weight(.semibold)).widgetAccentable().lineLimit(1)
                ForEach(Array(m.lines.prefix(m.lockSubjects ? 1 : 2).enumerated()), id: \.offset) { _, l in
                    Text(l.sender).font(.caption).lineLimit(1)
                    if m.lockSubjects { Text(l.subject).font(.caption2).lineLimit(1).privacySensitive() }
                }
                if m.lines.isEmpty, let f = m.fetchedAt { Text("Stand \(WUI.time(f))").font(.caption2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium, .systemLarge:
            HStack(alignment: .top, spacing: 14) {
                count(m).frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    if m.lines.isEmpty {
                        Text("Alles gelesen").font(.caption.weight(.semibold))
                        Text("Neue Nachrichten erscheinen hier nach dem nächsten Abgleich.").font(.caption2).foregroundStyle(WUI.muted).lineLimit(3)
                    }
                    ForEach(Array(m.lines.prefix(family == .systemLarge ? HomeWidgetData.messageLines : 3).enumerated()), id: \.offset) { _, l in
                        Link(destination: (l.isMail ? WUI.uniMailURL : WUI.messagesURL) ?? URL(fileURLWithPath: "/")) { line(l, preview: true) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                count(m)
                Spacer(minLength: 0)
                if let l = m.lines.first { line(l, preview: false) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Kopf: Briefumschlag, grosse Zahl, darunter die Quellen ("Stud.IP 2 · Uni-Mail 1") bzw. der Stand
    private func count(_ m: HomeWidgetData.Messages) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "envelope.fill").font(.caption.weight(.semibold)).foregroundStyle(WUI.accent).widgetAccentable()
                Text("Nachrichten").font(.caption2.weight(.bold)).foregroundStyle(WUI.accent).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.75)
            }
            Text("\(m.total)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
                .accessibilityLabel(WUI.unreadText(m.total))
            Text("ungelesen").font(.caption2).foregroundStyle(WUI.muted)
                .accessibilityHidden(true)
            if let mail = m.mailUnread {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(m.source) \(m.unread)")
                    Text("Uni-Mail \(mail)")
                }
                .font(.caption2).foregroundStyle(WUI.muted).lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(m.source): \(m.unread), Uni-Mail: \(mail)")
            } else if let f = m.fetchedAt, m.total == 0 {
                Text("Stand \(WUI.time(f))").font(.caption2).foregroundStyle(WUI.muted)
            }
        }
    }

    private func line(_ l: HomeWidgetData.MessageLine, preview: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(l.isMail ? WUI.muted : WUI.accent).frame(width: 6, height: 6).widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                // feste Farben: in einem Link faerbt WidgetKit sonst alles in der Akzentfarbe
                Text(l.isMail ? "\(l.sender) · Uni-Mail" : l.sender).font(.caption.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                Text(l.subject).font(.caption2).foregroundStyle(Color.secondary).lineLimit(preview && l.preview == nil ? 2 : 1).privacySensitive()
                if preview, let p = l.preview { Text(p).font(.caption2).foregroundStyle(WUI.muted).lineLimit(1).privacySensitive() }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension HomeWidgetData {
    /// Beispiel fuer die Widget-Galerie (erfundene Nachrichten)
    static func sampleMessages(now: Date) -> HomeWidgetData {
        var d = HomeWidgetData.sample(now: now)
        d.messages = .init(source: "Stud.IP", unread: 2, mailUnread: 1, lines: [
            .init(sender: "Lehrende", subject: "Blatt 5 ist online", preview: nil, sentAt: now.addingTimeInterval(-1800), isMail: false),
            .init(sender: "Stud.IP", subject: "Raumänderung Tutorium am Donnerstag", preview: nil, sentAt: now.addingTimeInterval(-7200), isMail: false),
            .init(sender: "Prüfungsamt", subject: "Anmeldezeitraum beginnt", preview: nil, sentAt: nil, isMail: true),
        ], lockSubjects: false, fetchedAt: now)
        return d
    }
}
