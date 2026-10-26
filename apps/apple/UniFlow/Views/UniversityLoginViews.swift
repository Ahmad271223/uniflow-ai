import SwiftUI
import UniFlowCore

/// Leiste unter der Anmeldeseite einer Hochschule: Schalter "Auf diesem iPad merken" (Standard an) mit Erklaerung.
/// Die App fuellt beim naechsten Mal nur vor; "Anmelden" tippt der Mensch selbst (Entscheidung des Inhabers).
struct UniversityRememberBar: View {
    @ObservedObject var autofill: UniversityLoginAutofill

    var body: some View {
        VStack(alignment: .leading, spacing: 4.8) {
            Toggle(isOn: $autofill.remember) {
                Text("Auf diesem iPad merken").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("login.remember")
            Text(Self.explanation(remember: autofill.remember, login: "\(autofill.service.name) · \(autofill.university.profile.short)",
                                  fallback: autofill.fallbackLoginName))
                .ufFont(12.8).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.remember.info")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    /// `fallback`: Dienst derselben Hochschule, dessen gemerkte Zugangsdaten hier ohne eigene vorausgefuellt werden
    /// (LUH-QIS: "Stud.IP"); nur bei eingeschaltetem Schalter.
    static func explanation(remember: Bool, login: String, fallback: String? = nil) -> String {
        guard remember else {
            return "UniFlow merkt sich nichts von dieser Seite und füllt nichts vor. Bereits gemerkte Zugangsdaten (\(login)) wurden von diesem iPad entfernt."
        }
        let base = "Beim Tippen auf „Anmelden“ merkt sich UniFlow Benutzername und Passwort (\(login)) – nur im Schlüsselbund dieses iPads, nicht in iCloud und nie auf einem Server. Beim nächsten Mal stehen sie schon im Formular; anmelden tippst du selbst."
        guard let fallback else { return base }
        return base + " Solange hier nichts gemerkt ist, füllt UniFlow die gemerkten Zugangsdaten der \(fallback)-Anmeldung vor."
    }
}
