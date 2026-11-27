import SwiftUI
import UniFlowCore

// Was StudiNow an einer Hochschule (noch) nicht anbindet, zeigt die Oberflaeche nicht halb (Auftrag des Inhabers
// 26.11.2026 zur Uni Goettingen, docs/GOETTINGEN-2026-11-26.md): keine Karte "QIS verbinden", keine leere Liste
// "Bescheinigungen", kein Studienverlauf, der auf einen Notenspiegel wartet, den es in der App nicht gibt. Stattdessen
// fehlt der Menuepunkt bzw. steht eine ruhige Karte da, die sagt, wo es die Sache gibt, mit einem Knopf dorthin.
// Die Regeln sind reine Funktionen (GoettingenAppTests); die Hochschule kommt aus dem Hochschul-Profil.

enum UFUniversityScope {
    /// Hochschule des offenen Containers (nil ohne Container: eigener Server, vor der Hochschulwahl)
    static var current: UniversityKey? { ActiveContainer.current?.key.university }

    /// Liest die App an dieser Hochschule Noten aus einem Portal (QIS, LSF, HISinOne)? Uni Goettingen: nein (aus FlexNow 2
    /// nur die angemeldeten Pruefungen, seit 27.11.2026, `FlexNowConnection`)
    static func readsGrades(_ u: UniversityKey?) -> Bool { u.map { $0.profile.gradeLayout != nil } ?? true }

    /// Studienverlauf: braucht den Notenspiegel (Studiengang, Pruefungsordnung) und einen Modulkatalog der Hochschule
    static func offersStudyPlan(_ u: UniversityKey?) -> Bool { readsGrades(u) }

    /// Bescheinigungen aus dem Portal der Hochschule
    static func offersCertificates(_ u: UniversityKey?) -> Bool { u.map { CertificatePortal.isOffered($0) } ?? true }

    /// Adresse eines Dienstes aus der Dienste-Liste des Profils ("flexnow", "ecampus")
    static func serviceURL(_ key: String, _ u: UniversityKey?) -> URL? {
        u?.profile.services.first { $0.key == key }.flatMap { URL(string: $0.url) }
    }

    /// Woher Pruefungstermine von selbst kommen (Einstieg): an der LUH aus QIS; an der Uni Goettingen nur aus
    /// Ankuendigungen in Stud.IP (FlexNow nennt bei den angemeldeten Pruefungen keinen Termin)
    static func examSource(_ u: UniversityKey? = current) -> String { readsGrades(u) ? "QIS" : "Stud.IP" }

    /// Zeile "fertig" im Einstieg, wenn noch kein Pruefungstermin bekannt ist
    static func examsLater(_ u: UniversityKey? = current) -> String {
        readsGrades(u) ? "Prüfungstermine ergänzt QIS" : "Prüfungstermine trägst du selbst ein"
    }

    /// Hinweis in den Einstellungen, wo der Uni-Zugang steht (ohne "QIS", wo es keines gibt)
    static func settingsHint(_ u: UniversityKey?) -> String {
        u == .luh || u == nil ? "Uni-Zugang, Stud.IP und QIS stehen unter „Uni-Zugang & Abgleich“."
            : "Uni-Zugang und Stud.IP stehen unter „Uni-Zugang & Abgleich“."
    }

    /// Aufzeichnungen an der Uni Goettingen: Mediacast ist nicht angebunden
    static let mediacastHint = "Keine Videos zu diesem Modul. Videos im Reiter „Medien“ eines Kurses (Mediacast) zeigt StudiNow noch nicht – öffne sie in Stud.IP. Videodateien aus den Kursordnern erscheinen hier."

    // Texte fuer die Uni Goettingen (einfach, ohne Versprechen)
    static func gradesTitle(_ u: UniversityKey) -> String { "Noten (\(u.profile.gradesSource))" }

    static func gradesText(_ u: UniversityKey) -> String {
        "Die \(u.profile.name) führt Noten und Prüfungsanmeldungen in \(u.profile.gradesSource). StudiNow liest dort bisher nur deine angemeldeten Prüfungen, die Noten noch nicht – deine Noten siehst du dort im Browser."
    }

    static func servicesSub(_ u: UniversityKey) -> String {
        "Alle Dienste der \(u.profile.name) an einem Ort. Kurse, Dateien und Stundenplan kommen aus Stud.IP, angemeldete Prüfungen aus \(u.profile.gradesSource); Noten liest StudiNow dort noch nicht."
    }

    static func studyPlanTitle(_ u: UniversityKey) -> String { "Den Studienverlauf gibt es für die \(u.profile.short) noch nicht" }

    /// Hinweis fuer eine neue Hochschule mit Teil-Anbindung (Inhaber 26.11.2026 zu Goettingen in 1.0.8: „mit Verweis …,
    /// dass aktuell nur folgende Funktionen vorhanden sind und bei technischer Moeglichkeit, welche wir aktuell pruefen,
    /// nachgezogen werden“). Nur, was wirklich gebaut ist; kein Datum. Bei der Hochschulwahl, in den Einstellungen und
    /// auf „Uni & Noten“. nil: Hochschule ohne Hinweis
    static func newNotice(_ u: UniversityKey?) -> (title: String, have: String, missing: String)? {
        guard u == .goettingen else { return nil }
        return ("Universität Göttingen – neu in StudiNow",
                "Schon dabei: Stud.IP mit Kursen, Dateien, Stundenplan, Terminen, Nachrichten, Ankündigungen und Lehrenden, dazu das Schwarze Brett und der Speiseplan der Mensen (noch ohne Preise). Aus FlexNow liest StudiNow deine angemeldeten Prüfungen mit Abmeldefrist. Alle Lernfunktionen von StudiNow – Editor, Notizen, Karteikarten und je nach Tarif die KI – gehen wie an jeder anderen Hochschule.",
                "Noch nicht dabei: Noten (FlexNow), Bescheinigungen und Vorlesungsverzeichnis (eCampus), Uni-Mail und Vorlesungsaufzeichnungen. Wir prüfen gerade, wie wir sie technisch anbinden können, und ergänzen sie, sobald das möglich ist.")
    }

    static func studyPlanText(_ u: UniversityKey) -> String {
        "Für den Studienverlauf liest StudiNow Studiengang und Leistungen aus dem Notenspiegel der Hochschule. An der \(u.profile.name) liegen sie in \(u.profile.gradesSource); das ist noch nicht angebunden."
    }
}

/// Kasten „neu in StudiNow: schon dabei / noch nicht dabei“ (`UFUniversityScope.newNotice`); ohne Hinweis leer
struct UFUniversityNewNotice: View {
    let university: UniversityKey?
    var identifier = "university.newnotice"

    var body: some View {
        if let n = UFUniversityScope.newNotice(university) {
            VStack(alignment: .leading, spacing: 6.4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UFIcon("info", size: 15).foregroundStyle(UF.infoText)
                    Text(n.title).ufFont(14.4, 650).foregroundStyle(UF.infoText).fixedSize(horizontal: false, vertical: true)
                }
                Text(n.have).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                Text(n.missing).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.infoSoft))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
    }
}

/// Ruhige Karte "gibt es hier noch nicht" mit einem Knopf zur Seite der Hochschule (oeffnet im Browser des Systems)
struct UFNotOfferedCard: View {
    let icon: String
    let title: String
    let text: String
    /// Beschriftung und Ziel des Knopfs; nil: ohne Knopf
    var link: (title: String, url: URL)? = nil
    var identifier = "university.notoffered"
    @Environment(\.openURL) private var openURL
    @Environment(\.ufCompact) private var compact

    var body: some View {
        UFCard {
            UFCardHead(title, icon: icon, wrap: true)
            Text(text).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            if let link {
                if compact {
                    UFWideButton(link.title, icon: "arrow-right") { openURL(link.url) }.padding(.top, 10)
                } else {
                    UFButton(link.title, icon: "arrow-right", size: .small) { openURL(link.url) }.padding(.top, 10)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
