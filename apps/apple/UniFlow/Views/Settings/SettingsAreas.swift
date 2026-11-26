import SwiftUI

// Gliederung der Einstellungen (Auftrag des Inhabers 17.11.2026: "mach Einstellungen übersichtlicher").
// Vorher: fuenf Reiter, davon "Zugang & Darstellung" mit rund zwoelf Karten untereinander (am iPad quer ueber sechs
// Bildschirme, am iPhone acht). Jetzt wenige Bereiche mit sprechenden Namen, das Haeufige oben, Seltenes unter
// "Erweitert" zugeklappt. Breit (iPad, Mac): links die Liste der Bereiche, rechts der Inhalt. Schmal (iPhone, schmales
// Fenster, sehr grosse Schrift): eine Liste der Bereiche, Antippen oeffnet die Unterseite, "Einstellungen" fuehrt zurueck.
// Die bisherigen Sprungziele `UFRoute.settings(tab:)` bleiben gueltig (`SettingsArea.resolve`).

enum SettingsArea: String, CaseIterable, Identifiable {
    case account, uni, look, modules, plan, community, help, advanced

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .account: return "user"
        case .uni: return "graduation"
        case .look: return "sun"
        case .modules: return "book"
        case .plan: return "clock"
        case .community: return "users"
        case .help: return "life-buoy"
        case .advanced: return "settings"
        }
    }

    /// Name in der Liste und ueber dem Inhalt. `editor`: Geraet mit Editor (iPad, Mac; am iPhone keine Stift-Zeilen);
    /// `withTests`: eigener Server mit Wochentests (nur Entwicklung); `mac`: am Mac schreibt die Maus, kein Stift
    func title(editor: Bool, withTests: Bool = false, mac: Bool = UFDevice.isMac) -> String {
        switch self {
        case .account: return "Konto & Tarif"
        case .uni: return "Uni-Zugang & Abgleich"
        case .look: return !editor ? "Darstellung" : mac ? "Darstellung & Schreiben" : "Darstellung & Stift"
        case .modules: return withTests ? "Module & Wochentests" : "Module"
        case .plan: return "Lernzeit & Verfügbarkeit"
        case .community: return "Austausch"
        case .help: return "Hilfe & Rechtliches"
        case .advanced: return "Erweitert"
        }
    }

    /// ein kurzer Satz: was in dem Bereich steht
    func sub(editor: Bool, mac: Bool = UFDevice.isMac) -> String {
        switch self {
        case .account: return "Tarif, Anmeldung und Freunde einladen."
        case .uni: return "Anmeldung an der Hochschule, Abgleich, Semester und Erinnerungen."
        case .look:
            guard editor else { return "Hell oder dunkel." }
            return mac ? "Hell oder dunkel, Maus und Trackpad, Schreibhand und Werkzeugleiste." : "Hell oder dunkel, Stift, Schreibhand und Werkzeugleiste."
        case .modules: return "Fächer anlegen und Kurse zuordnen."
        case .plan: return "Lernkombination, Lernzeiten und Sperrzeiten."
        case .community: return "Pseudonym, Lerngruppen und Sperrliste."
        case .help: return "Support, Nutzungsbedingungen, Datenschutz und Impressum."
        case .advanced: return "KI-Vorarbeit und selten Gebrauchtes."
        }
    }

    /// Bereiche in ihrer Reihenfolge. `hasData`: Einstellungen und Module sind geladen (sonst fehlen "Module" und
    /// "Lernzeit" wie bisher). "Lernzeit & Verfügbarkeit" gibt es nur mit Lernkalender (`LearnCalendar.enabled`).
    static func visible(hasData: Bool, learnCalendar: Bool = LearnCalendar.enabled) -> [SettingsArea] {
        allCases.filter { area in
            switch area {
            case .modules: return hasData
            case .plan: return hasData && learnCalendar
            default: return true
            }
        }
    }

    /// Sprungziel (`UFRoute.settings(tab:)`) -> Bereich. Die frueheren Reiter bleiben gueltig: "account", "modules",
    /// "plan", "advanced", dazu "dev" (eigener Server, jetzt unter "Erweitert") und "diag" (Diagnose, ebenfalls
    /// "Erweitert"). nil = Startseite der Einstellungen: kein Ziel, ein unbekanntes oder ein ausgeblendetes (z. B.
    /// "plan" ohne Lernkalender, "dev" im Release-Build).
    static func resolve(_ tab: String?, visible: [SettingsArea], ownServer: Bool) -> SettingsArea? {
        guard let tab else { return nil }
        let area: SettingsArea?
        switch tab {
        case "dev": area = ownServer ? .advanced : nil
        case "diag": area = .advanced
        default: area = SettingsArea(rawValue: tab)
        }
        guard let area, visible.contains(area) else { return nil }
        return area
    }

    /// Kennung des Eintrags in der Liste der Bereiche (breit und schmal dieselbe)
    var identifier: String { "settings.area.\(rawValue)" }
}

/// Breit: Liste der Bereiche links neben dem Inhalt (Knoepfe mit Icon, mindestens 44 pt hoch, aktiv in Akzentfarbe)
struct SettingsAreaNav: View {
    let areas: [SettingsArea]
    let current: SettingsArea?
    var withTests = false
    let select: (SettingsArea) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3.2) {
            ForEach(areas) { area in
                let on = area == current
                Button { select(area) } label: {
                    HStack(spacing: 9.6) {
                        UFIcon(area.icon, size: 16)
                        Text(area.title(editor: UFEditorAvailability.available, withTests: withTests))
                            .ufFont(14.5, on ? 600 : 500).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(on ? UF.accentText : UF.text2)
                    .padding(.vertical, 10.4).padding(.horizontal, 12.8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(on ? UF.accentSoft : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(area.identifier)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Schmal: Startseite der Einstellungen als eine Karte mit einer Zeile je Bereich (Icon, Name, ein Satz, Pfeil)
struct SettingsAreaList: View {
    let areas: [SettingsArea]
    var withTests = false
    let select: (SettingsArea) -> Void

    var body: some View {
        UFCard(padded: false) {
            ForEach(Array(areas.enumerated()), id: \.element) { i, area in
                if i > 0 { SettingsDivider().padding(.leading, 52) }
                Button { select(area) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        UFIcon(area.icon, size: 20).foregroundStyle(UF.accentText).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.title(editor: UFEditorAvailability.available, withTests: withTests))
                                .ufFont(15.5, 600).foregroundStyle(UF.text).multilineTextAlignment(.leading)
                            Text(area.sub(editor: UFEditorAvailability.available))
                                .ufFont(12.8).foregroundStyle(UF.muted).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(area.identifier)
            }
        }
    }
}

/// Schmal, auf einer Unterseite: zurueck zur Liste der Bereiche (zusaetzlich zum Pfeil der Kopfzeile, `ufLocalBack`)
struct SettingsBackLink: View {
    let action: () -> Void

    static let title = "Einstellungen"

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                UFIcon("chevron-left", size: 16)
                Text(Self.title).ufFont(14.5, 600)
            }
            .foregroundStyle(UF.accentText)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zurück zu den Einstellungen")
        .accessibilityIdentifier("settings.back")
    }
}

/// Hinweis oben in "Konto & Tarif", solange Stud.IP nicht verbunden ist: viele Stellen der App springen mit
/// `.settings(tab: "account")` hierher und meinen die Anmeldung an der Hochschule (frueher derselbe Reiter); der
/// Knopf fuehrt in einem Schritt zu "Uni-Zugang & Abgleich". In der Demo (ohne Hochschule) fehlt er.
struct SettingsUniAccessHint: View {
    let open: () -> Void
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo

    static func title(_ phase: StudIPSync.Phase) -> String? {
        switch phase {
        case .signedOut: return "Stud.IP ist noch nicht verbunden"
        case .needsLogin: return "Stud.IP: Anmeldung nötig"
        default: return nil
        }
    }

    static let text = "Uni-Zugang, Stud.IP und QIS stehen unter „Uni-Zugang & Abgleich“."
    static let button = "Uni-Zugang öffnen"

    var body: some View {
        if !demo, studip.offersStudIP, let title = Self.title(studip.phase) {
            SettingsNotice(title, text: UFUniversityScope.settingsHint(studip.university), tone: .info) {
                UFButton(Self.button, icon: "arrow-right", kind: .primary, size: .small, action: open)
                    .accessibilityIdentifier("settings.account.openUni")
            }
        }
    }
}
