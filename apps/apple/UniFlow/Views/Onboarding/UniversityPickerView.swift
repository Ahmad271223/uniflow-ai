import SwiftUI
import UniFlowCore

/// Schritt "Hochschule wählen" nach der Tarifwahl (docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 1): die Hochschulen, die
/// dieser Build anbietet (`UFReleaseUniversities`; Version 1.0 nur die LUH, HsH und Uni Hildesheim mit 1.0.1). Nichts ist
/// vorausgewaehlt, nichts wird aus E-Mail oder Name geraten. Danach oeffnet die App den Container dieser Hochschule
/// (ContainerManager); wechseln geht nur in den Einstellungen.
struct UniversityPickerView: View {
    let onChoose: (UniversityKey) -> Void
    @State private var selection: UniversityKey?

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                UFLogoMark(size: 52)
                Text("Hochschule wählen").ufFont(28.8, 700, em: -0.02).foregroundStyle(UF.text).padding(.top, 19.2)
                Text("An welcher Hochschule studierst du? StudiNow richtet danach die passenden Zugänge ein.")
                    .ufFont(16).foregroundStyle(UF.text2).padding(.top, 6.4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12.8) {
                    ForEach(Self.choices(), id: \.self) { u in
                        UniversityOption(university: u, selected: selection == u) { selection = u }
                    }
                }
                .padding(.top, 22.4)
                if UFReleaseUniversities.moreToCome {
                    Text(Self.moreNote)
                        .ufFont(13.12).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 9.6)
                        .accessibilityIdentifier("university.more")
                }
                HStack {
                    Spacer()
                    UFButton("Weiter", icon: "arrow-right", kind: .primary) { if let selection { onChoose(selection) } }
                        .disabled(selection == nil)
                        .accessibilityIdentifier("university.continue")
                }
                .padding(.top, 22.4)
                Text(Self.note)
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
        }
    }

    static let note = UFDevice.adapt("Die Daten jeder Hochschule bleiben auf diesem iPad getrennt: eigene Datenbank, eigene Dateien und Notizen, eigene Anmeldungen. Wechseln kannst du später in den Einstellungen.")
    /// Solange dieser Build nicht alle bekannten Hochschulen anbietet (1.0: nur die LUH)
    static let moreNote = "Weitere Hochschulen folgen mit einem Update."

    /// Hochschulen zur Wahl beim ersten Start: nur die ausgelieferten dieses Builds (Release 1.0: Leibniz Universität Hannover)
    static func choices() -> [UniversityKey] { UFReleaseUniversities.choices() }
}

/// Auswahlkarte einer Hochschule mit dem, was die App fuer sie heute kann (ehrlich, "folgt" fuer Fehlendes)
struct UniversityOption: View {
    let university: UniversityKey
    let selected: Bool
    var current = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12.8) {
                ZStack {
                    Circle().strokeBorder(selected ? UF.accent : UF.lineStrong, lineWidth: selected ? 6 : 1.5)
                }
                .frame(width: 20, height: 20)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3.2) {
                    HStack(spacing: 8) {
                        Text(university.profile.name).ufFont(16, 650).foregroundStyle(UF.text)
                        if current { UFBadge("aktuell", tone: .ok, icon: "check") }
                    }
                    Text(Self.services(university))
                        .ufFont(13.12).foregroundStyle(UF.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14.4)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(selected ? UF.accentSoft : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(selected ? UF.accent : UF.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: UF.r))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("university.\(university.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Was die App fuer diese Hochschule heute kann
    static func services(_ u: UniversityKey) -> String {
        switch u {
        case .luh:
            return UFDevice.adapt("Stud.IP: Kurse, Ordner, neue Dateien, Stundenplan und Aufzeichnungen direkt auf dieses iPad. QIS: Notenspiegel. Anmeldung mit deiner LUH-ID auf den Seiten der Universität.")
        case .hildesheim:
            return UFDevice.adapt("Learnweb: Kurse und Dateien direkt auf dieses iPad. LSF: Stundenplan und Notenspiegel. Anmeldung mit deinem UNI-Account auf den Seiten der Universität.")
        case .hsh:
            return UFDevice.adapt("Moodle: Kurse, Dateien und Fristen direkt auf dieses iPad. Campusmanagement: Stundenplan, Leistungen und angemeldete Prüfungen. Anmeldung mit deinem SSO-Account auf den Seiten der Hochschule.")
        }
    }
}

#Preview("Hochschule wählen") {
    UniversityPickerView { _ in }
}
