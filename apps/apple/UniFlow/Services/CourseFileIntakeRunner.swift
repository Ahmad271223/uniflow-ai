import SwiftUI
import UniFlowCore

/// Datei-Eingang auf dem Geraet (Auftrag des Inhabers vom 18.11.2026): neue Kurs-PDFs gehen einmal an den Eingang und
/// werden dort geordnet (`CourseFileIntake` im Kern, Server app/intake_api.py + app/intake_server.py,
/// docs/DATEI-EINGANG-2026-11-18.md).
///
/// Schalter ueber den Build, nicht ueber den Code (Entscheidung des Inhabers 18.11.2026): im App-Store-Build AUS, nur
/// in einem eigenen Test-Build fuer zwei Tester AN. Die Build-Einstellung `UF_INTAKE_OFFERED` (project.yml, Debug und
/// Release "NO") landet als `UFIntakeOffered` in der Info.plist; der Test-Build setzt sie beim Bauen auf YES
/// (`xcodebuild … UF_INTAKE_OFFERED=YES`).
///
/// Entscheidung des Inhabers 18.11.2026 abends ("das soll direkt geschehen, wir schreiben das in die AGBs"): wo der Build
/// den Eingang anbietet, ist er von selbst AN, ohne Zustimmungs-Dialog; Grundlage ist der Absatz in Nutzungsbedingungen und
/// Datenschutzerklaerung, der Schalter in den Einstellungen schaltet ihn jederzeit AUS (Widerspruch). Weiter nur mit
/// StudiNow-Konto, nur im WLAN, nie in der Demo und nie unter XCTest. Die Texte sind ein Entwurf: vor einer Veroeffentlichung im App Store mit dem Inhaber
/// abstimmen (auch die Datenschutzerklaerung braucht dann einen Absatz).
enum CourseFileIntakeSetting {
    /// Schluessel in der Info.plist (aus der Build-Einstellung `UF_INTAKE_OFFERED`)
    static let infoKey = "UFIntakeOffered"

    /// Reine Regel: nur ein ausdrueckliches YES schaltet ein. Fehlt der Eintrag, ist er leer oder steht noch
    /// "$(UF_INTAKE_OFFERED)" darin (Einstellung nicht aufgeloest), bleibt der Eingang aus.
    static func offered(info: Any?) -> Bool {
        if let b = info as? Bool { return b }
        guard let s = info as? String else { return false }
        return ["yes", "true", "1"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Schalter des Builds: aus = nirgends sichtbar, nichts wird geschickt. Tests setzen ihn von Hand.
    static var isOffered = offered(info: Bundle.main.object(forInfoDictionaryKey: infoKey))

    static let key = "studinow.courseFileIntake.v1"
    static let consentKey = "studinow.courseFileIntake.v1.consentAt"

    /// Eingeschaltet = Build bietet es an UND der Nutzer hat es nicht ausgeschaltet (ohne Eintrag: an, 18.11.2026)
    static func isOn(_ d: UserDefaults = .standard) -> Bool { isOffered && ((d.object(forKey: key) as? Bool) ?? true) }

    static func set(_ on: Bool, _ d: UserDefaults = .standard, now: Date = Date()) {
        d.set(on, forKey: key)
        if on { d.set(now, forKey: consentKey) } else { d.removeObject(forKey: consentKey) }
    }

    static let cardTitle = "Kursdateien teilen"
    static let title = "Neue Kursdateien an StudiNow schicken"
    static let short = "Neue Vorlesungen, Übungen, Skripte und Altklausuren gehen einmal an StudiNow und werden dort nach Hochschule, Studiengang, Semester und Modul geordnet. Ohne deinen Namen, nur im WLAN. Ausschalten geht jederzeit hier."
    static let consentTitle = "Kursdateien an StudiNow schicken?"
    /// Abgeglichen mit dem, was wirklich geht (`CourseFileIntake.Meta`, `AccountCourseFileIntake`, app/intake_api.py)
    static let consentPoints = [
        "Was: neue PDFs aus deinen Kursen – Vorlesungen, Übungen, Lösungen, Skripte und Altklausuren.",
        "Dazu nur Angaben zum Kurs: Hochschule, Studiengang (falls gewählt), Semester, Modul, Kursname und -nummer, Dateiname, Art der Datei, Woche und Seitenzahl.",
        "Wohin: an StudiNow. Dort werden die Dateien nach Hochschule, Studiengang, Semester und Modul geordnet.",
        "Jede Datei geht nur einmal hoch. Hat StudiNow sie schon, geht sie nicht noch einmal hoch.",
        "Nie gesendet: dein Name, deine Notizen und Markierungen, eigene Dokumente und Organisatorisches.",
        "Dein StudiNow-Konto prüft StudiNow nur beim Annehmen (höchstens 300 Dateien am Tag). Bei den Dateien steht nicht, wer sie geschickt hat.",
        "Listen mit Namen, Matrikelnummern oder Noten erkennt StudiNow am Dateinamen und an den ersten Seiten und schickt sie nicht. Das klappt meistens, aber nicht immer – zum Beispiel nicht bei eingescannten Listen.",
        "Nur im WLAN. Ausschalten geht jederzeit hier in den Einstellungen.",
    ]
    static let agree = "Zustimmen und einschalten"
    static let cancel = "Nicht jetzt"
}

enum CourseFileIntakeRunner {
    /// Konto-Anschluss des offenen Datenbereichs (gesetzt vom `ContainerManager`)
    @MainActor static weak var link: StudoraAccountLink?

    /// Alles, was erfuellt sein muss, bevor auch nur eine Anfrage an den Dienst geht
    struct Conditions: Equatable {
        var offered: Bool
        var consented: Bool
        var underTest: Bool
        var demo: Bool
        var onWiFi: Bool
        var signedIn: Bool

        var allowed: Bool { offered && consented && !underTest && !demo && onWiFi && signedIn }
    }

    /// Einzige Stelle, die einen Lauf startet: ohne `allowed` geht nichts an `transport` (nil = nicht gelaufen)
    static func send(_ ctx: LocalContext, transport: CourseFileIntake.Transport, when c: Conditions,
                     shouldStop: @escaping @Sendable () -> Bool = { Task.isCancelled }) async throws -> CourseFileIntake.Report? {
        guard c.allowed else { return nil }
        return try await CourseFileIntake.run(ctx, transport: transport, shouldStop: shouldStop)
    }

    /// Nach dem Abgleich (`StudIPSync.autoPlan`): neue Dateien schicken, wenn alles passt. Fehler bleiben still, der
    /// naechste Abgleich versucht es wieder. Ohne Build-Schalter oder Zustimmung wird nicht einmal die Datenbank geoeffnet.
    nonisolated static func afterSync(host: LocalBackendHost) async {
        guard CourseFileIntakeSetting.isOn(), !StudIPSync.isUnderTest(), !(await host.demoActive()),
              let backend = try? await host.backend(), await DocIndexPrewarm.onWiFi(),
              let account = await MainActor.run(body: { link?.account }), await account.isSignedIn else { return }
        let ctx = backend.context
        let uni = try? await ctx.database.withConnection { try CourseFileIntake.university($0) }
        // an den StudiNow-Dienst; der reicht ueber das private Netz an den Eingang weiter (keine eigene Domain)
        let transport = AccountCourseFileIntake(account: account, university: uni)
        let c = Conditions(offered: CourseFileIntakeSetting.isOffered, consented: CourseFileIntakeSetting.isOn(), underTest: false,
                           demo: false, onWiFi: true, signedIn: true)
        _ = try? await send(ctx, transport: transport, when: c)
    }
}

// MARK: - Einstellungen

/// Karte unter "Uni-Zugang & Abgleich" (der Eingang laeuft nach dem Abgleich): nur im Test-Build
/// (`CourseFileIntakeSetting.isOffered`), nur mit angemeldetem StudiNow-Konto, nie in der Demo
struct CourseFileIntakeCard: View {
    @Environment(\.ufStudoraAccount) private var link
    @Environment(\.ufDemoActive) private var demo

    var body: some View {
        if CourseFileIntakeSetting.isOffered, !demo, StudoraAccountLink.available, let link { SignedIn(link: link) }
    }

    private struct SignedIn: View {
        @ObservedObject var link: StudoraAccountLink

        var body: some View {
            if link.user != nil {
                UFCard {
                    UFCardHead(CourseFileIntakeSetting.cardTitle, icon: "upload")
                    CourseFileIntakeRow()
                }
            }
        }
    }
}

/// Schalter: aus, bis der Nutzer im Dialog zustimmt. Der Dialog laeuft ueber `UFOverlay` wie die anderen Dialoge der
/// Einstellungen (Hochschule wechseln, Daten loeschen): ein `.sheet` an dieser Zeile blieb im Bereich "Uni-Zugang &
/// Abgleich" nach "Nicht jetzt" offen (EinstellungenKlarAppTests).
struct CourseFileIntakeRow: View {
    @EnvironmentObject private var overlay: UFOverlay
    @State private var on = CourseFileIntakeSetting.isOn()

    var body: some View {
        if CourseFileIntakeSetting.isOffered {
            VStack(alignment: .leading, spacing: 6) {
                // an ohne Rueckfrage (Standard ist an, 18.11.2026); aus = Widerspruch, gemerkt
                Toggle(isOn: Binding(get: { on }, set: { want in
                    CourseFileIntakeSetting.set(want)
                    on = CourseFileIntakeSetting.isOn()
                })) {
                    Text(CourseFileIntakeSetting.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(UF.accent)
                .accessibilityIdentifier("intake.toggle")
                Text(CourseFileIntakeSetting.short).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Zustimmung in einem anderen Fenster oder nach dem Dialog: Schalter folgt der Einstellung
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let now = CourseFileIntakeSetting.isOn()
                if now != on { on = now }
            }
        }
    }
}

/// Dialog vor dem Einschalten (ueber `UFOverlay`); schliesst sich selbst
struct CourseFileIntakeConsentDialog: View {
    var done: () -> Void = {}
    @Environment(\.ufClose) private var close

    var body: some View {
        CourseFileIntakeConsent(agree: {
            CourseFileIntakeSetting.set(true)
            done()
            close()
        }, cancel: {
            done()
            close()
        })
    }
}

/// Inhalt der Zustimmung: was, was dazu, wohin, was nie, nur WLAN
struct CourseFileIntakeConsent: View {
    let agree: () -> Void
    let cancel: () -> Void

    var body: some View {
        UFDialog(CourseFileIntakeSetting.consentTitle, icon: "upload") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(CourseFileIntakeSetting.consentPoints, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").ufFont(14, 700).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                        Text(p).ufFont(14).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } foot: {
            UFButton(CourseFileIntakeSetting.cancel, kind: .ghost) { cancel() }
                .accessibilityIdentifier("intake.consent.cancel")
            UFButton(CourseFileIntakeSetting.agree, kind: .primary) { agree() }
                .accessibilityIdentifier("intake.consent.agree")
        }
    }
}
