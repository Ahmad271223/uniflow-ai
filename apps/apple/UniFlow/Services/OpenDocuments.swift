import Foundation
import UniFlowCore

/// Verzeichnis der Dokumente, die gerade zum Schreiben offen sind, je Container (P0-6, docs/PENCILKIT-ANALYSE-PLAN.md
/// B11). Mehrere Fenster (Stage Manager, Split View mit zwei Szenen) laufen im selben Prozess; zwei `DocumentStore`
/// fuer dieselbe Datei schrieben in dasselbe Journal, jeder mit seinem eigenen Stand im Speicher, und ueberschrieben sich
/// gegenseitig ganze Seiten.
///
/// Entscheidung: das zweite Fenster oeffnet nur zum Ansehen, statt denselben Store zu teilen. Ein geteilter Store
/// braeuchte zwei Editoren auf einer Seite: `onPagesChanged` gibt es nur einmal (der zuletzt geladene Editor bekaeme
/// alle Meldungen), jede Canvas schickt die ganze Zeichnung ihrer Seite, und die drei-Wege-Regel der Umrechnung hielte
/// die Striche des anderen Fensters, die in der eigenen Canvas fehlen, fuer geloescht. Das waere ein Umbau am
/// Eingabeweg (nur mit Geraetetest).
///
/// - Ist das Dokument im anderen Fenster gerade zu sehen, bleibt es dort beschreibbar; hier nur ansehen mit Hinweis.
/// - Ist es dort nicht zu sehen (Fenster im Hintergrund, Dokument weggeschaltet, Store wird gerade abgebaut), uebernimmt
///   das neue Fenster: der alte Store sichert Ausstehendes ins Journal und schreibt danach nichts mehr
///   (`DocumentStore.handOver`).
/// - Alte Fassungen (S7) sind ohnehin nur zum Ansehen und zaehlen nicht.
/// Gehalten wird schwach: ein abgebauter Store gibt das Dokument ohne weiteren Aufruf frei.
@MainActor
final class OpenDocuments {
    static let shared = OpenDocuments()

    enum Claim {
        /// frei: dieser Store schreibt
        case granted
        /// in einem anderen Fenster offen und zu sehen: nur ansehen
        case shownElsewhere
        /// in einem anderen Store offen, der nicht zu sehen ist: er gibt ab, danach schreibt dieser
        case takeOver(DocumentStore)
    }

    private final class Holder {
        weak var store: DocumentStore?
        init(_ store: DocumentStore) { self.store = store }
    }

    private var holders: [String: Holder] = [:]

    /// Schluessel: Container (Ordner der Daten), Datenquelle (lokal oder PC-Server) und Datei
    nonisolated static func key(root: URL, namespace: DataSourceNamespace, fileID: String) -> String {
        root.standardizedFileURL.path + "|" + namespace.id + "|" + fileID
    }

    func claim(_ key: String, by store: DocumentStore) -> Claim {
        if let current = holders[key]?.store, current !== store, !current.released {
            if current.isShown { return .shownElsewhere }
            holders[key] = Holder(store)
            return .takeOver(current)
        }
        holders[key] = Holder(store)
        return .granted
    }

    func release(_ key: String, by store: DocumentStore) {
        if holders[key]?.store === store { holders[key] = nil }
    }

    /// Store, der das Dokument gerade zum Schreiben haelt (Tests)
    func holder(_ key: String) -> DocumentStore? { holders[key]?.store }
}
