import Foundation
import MetricKit
import UIKit

/// Fehlersuche "die App friert ein" am Geraet (Meldung des Inhabers 23.11.2026: "konnte kurz KI öffnen, keine
/// Handbewegung, nicht schreiben" - in einer Aufnahme mit Instruments nicht nachzustellen).
///
/// Laeuft nur, wenn das Ablauf-Protokoll an ist (`StiftSpur.isOn`, Schalter-Datei per Kabel). Zwei Teile:
/// - Waechter: ein eigener Thread fragt alle 0,1 s beim Hauptthread an; antwortet der laenger als `limit` nicht, steht
///   in `StiftSpur.txt` "HAENGER …" mit Dauer und der letzten Zeile davor (was gerade lief).
/// - MetricKit: Berichte von iOS ueber Haenger, zu hohe Rechenlast und Abstuerze mit Aufrufstapel (nur Adressen und
///   Namen der Programmteile, kein Inhalt) landen als JSON in `Library/Application Support/Diagnose/`.
/// Nichts davon verlaesst das Geraet; gelesen wird es per Kabel (`xcrun devicectl device copy from ...`).
final class HaengerSpur: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = HaengerSpur()
    /// ab so langer Stille des Hauptthreads gilt es als Haenger
    static let limit: TimeInterval = 0.4

    private let lock = NSLock()
    private var started = false
    private var lastPong = CACurrentMediaTime()
    private var stalledSince: CFTimeInterval?
    private var stallLine = ""

    static var directory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnose", isDirectory: true)
    }

    /// Beim Start der App; ohne Ablauf-Protokoll ohne Wirkung
    func start() {
        guard StiftSpur.isOn else { return }
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        MXMetricManager.shared.add(self)
        let t = Thread { [weak self] in self?.watch() }
        t.name = "HaengerSpur"
        t.qualityOfService = .utility
        t.start()
        StiftSpur.log("Haenger-Waechter an (Grenze \(Self.limit) s)")
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 0.1)
            DispatchQueue.main.async { [weak self] in self?.pong() }
            let now = CACurrentMediaTime()
            lock.lock()
            let silent = now - lastPong
            if silent > Self.limit, stalledSince == nil {
                stalledSince = lastPong
                stallLine = StiftSpur.lastLine ?? "-"
            }
            lock.unlock()
        }
    }

    private func pong() {
        let now = CACurrentMediaTime()
        lock.lock()
        let since = stalledSince
        let before = stallLine
        stalledSince = nil
        lastPong = now
        lock.unlock()
        if let since {
            StiftSpur.log(String(format: "HAENGER %.2f s (Hauptthread antwortete nicht); zuletzt davor: %@", now - since, String(before.prefix(160))))
        }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "diagnose") }
        StiftSpur.log("MetricKit: \(payloads.count) Bericht(e) von iOS gespeichert (Haenger \(payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }), Rechenlast \(payloads.reduce(0) { $0 + ($1.cpuExceptionDiagnostics?.count ?? 0) }), Abstuerze \(payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }))")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "messwerte") }
    }

    private func save(_ data: Data, kind: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.directory.appendingPathComponent("\(kind)-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).json"), options: .atomic)
    }
}
