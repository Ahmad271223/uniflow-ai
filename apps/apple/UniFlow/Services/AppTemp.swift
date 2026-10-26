import Foundation
import UniFlowCore

/// Kurzlebige Dateien fuer das Teilen-Menue (PDF mit Notizen, Loesung, Original herunterladen, Ansehen in einer
/// anderen App) je Container: `tmp/uniflow-teilen/<Container-UUID>/<Zweck>/<UUID>/<Name>`. Vorher lagen sie im
/// gemeinsamen tmp-Ordner aller Konten und blieben nach "Konto löschen" bzw. "Daten dieser Hochschule löschen" liegen.
/// Jeder neue Export eines Zwecks ersetzt den vorigen; der Start leert alles aus frueheren Laeufen (`purgeAtLaunch`),
/// das Loeschen eines Containers seinen Ordner (`remove`).
enum AppTemp {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-teilen", isDirectory: true) }

    /// Ordner eines Containers (ohne Container: eigener Ordner, der beim naechsten Start verschwindet)
    static func folder(container: UUID?) -> URL {
        root.appendingPathComponent(container?.uuidString ?? "ohne-container", isDirectory: true)
    }

    /// Neuer, leerer Ordner fuer eine Datei dieses Zwecks; der vorige desselben Zwecks wird entfernt
    static func fresh(_ purpose: String, container: UUID? = ActiveContainer.current?.layout.identifier) throws -> URL {
        let fm = FileManager.default
        let base = folder(container: container).appendingPathComponent(purpose, isDirectory: true)
        try? fm.removeItem(at: base)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Datei `name` in einem neuen Ordner, bereinigt wie die Ablage der Abgleiche (`StudIPImport.safeFileName`: kein
    /// Pfadtrenner, kein "..", keine versteckte Datei, Endung bleibt). Namen kommen ungeprueft aus Stud.IP bzw. Learnweb.
    static func file(_ purpose: String, name: String, container: UUID? = ActiveContainer.current?.layout.identifier) throws -> URL {
        try fresh(purpose, container: container).appendingPathComponent(StudIPImport.safeFileName(name))
    }

    /// Alles eines Containers ("Konto löschen", "Daten dieser Hochschule löschen")
    static func remove(container: UUID) {
        try? FileManager.default.removeItem(at: folder(container: container))
    }

    /// Beim Start: Reste frueherer Laeufe, auch die Ordner aus der Zeit vor `AppTemp` (export, share, solution-share)
    static func purgeAtLaunch() {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        for old in ["export", "share", "solution-share"] {
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(old, isDirectory: true))
        }
    }
}
