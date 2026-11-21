import CoreGraphics
import Foundation

/// Obergrenzen fuer den Arbeitsspeicher je Geraeteklasse (Auftrag des Inhabers 20.11.2026: "iPads duerfen nie wegen
/// Arbeitsspeicher abstuerzen"; Messung und Begruendung in docs/SPEICHER-STAND.md).
///
/// Zwei Klassen nach dem eingebauten Arbeitsspeicher (`ProcessInfo.physicalMemory`):
/// - **klein** (bis 4 GB: iPad 7 bis 10, iPad Air 3 und 4, iPad mini 5 und 6, iPhones bis 4 GB): iPadOS beendet eine App
///   dort ab grob 1,4 bis 1,8 GB (3 GB) bzw. 2 bis 2,8 GB (4 GB). Geplant wird mit 1 GB.
/// - **gross** (ab 6 GB, auch der Mac): alles wie bisher, keine der Grenzen hier greift.
///
/// Die Werte der kleinen Klasse sind so gewaehlt, dass sich der uebliche Fall (A4-Skript, Folien) nicht aendert:
/// Sie greifen nur bei Seiten groesser als A4 und bei Dokumenten mit vielen eingefuegten Fotos.
struct MemoryBudget: Equatable {
    /// Die Zeichenflaeche zeigt bis zum 4-fachen Zoom die ganze Seite (`PageInkView.wholePageZoom`) - aber nur, solange
    /// Seitenflaeche x Zoom^2 (Seitenpunkte^2) hoechstens so gross ist; darueber zeigt sie wie ueber dem 4-fachen nur
    /// den sichtbaren Teil (`PageInkView.inkLayout`). `.infinity`: ohne Grenze, wie bis 1.0.7.
    ///
    /// Gemessen (Simulator, Kacheln von PencilKit als IOSurface, 2x-Bildschirm): voll beschriebene A0-Seite bei
    /// Zoomstufe 3 der Zeichenflaeche 1154 MB, bei Stufe 4 2052 MB (A4 bei Stufe 4: 120 MB).
    var wholePageInkArea: CGFloat
    /// Dekodierte Bilder der Notizen (`DocumentStore.images`), die gerade keine Seite zeigt: hoechstens so viele Byte
    /// bleiben im Speicher, die aeltesten fallen heraus und laden beim naechsten Anzeigen neu. `.max`: ohne Grenze.
    ///
    /// Gemessen (Simulator): 30 Fotos aus der Kamera in einem Dokument halten 451 MB (15 MB je Foto, 2400 x 1800).
    var idleNoteImageBytes: Int

    /// Geraete ab 6 GB: keine Grenze, alles wie bis 1.0.7
    static let standard = MemoryBudget(wholePageInkArea: .infinity, idleNoteImageBytes: .max)

    /// Geraete bis 4 GB.
    /// - Ganze Seite: A4 beim 4-fachen (595 x 842 x 16 = 8,0 Mio.) und Folien 16:9 (960 x 540 x 16 = 8,3 Mio.) bleiben
    ///   wie bisher; A3 ab Stufe 3, A2 ab Stufe 3, A1 und A0 ab Stufe 1,5 zeigen den Ausschnitt. Auf einem
    ///   2x-Bildschirm kostet eine Zeichenflaeche damit hoechstens 36 Mio. Bildpunkte (144 MB).
    /// - Bilder: 96 MB entsprechen rund sechs Fotos, die gerade nicht im Bild sind.
    static let small = MemoryBudget(wholePageInkArea: 9_000_000, idleNoteImageBytes: 96 * 1024 * 1024)

    /// Bis zu diesem eingebauten Arbeitsspeicher gilt die kleine Klasse. 4-GB-Geraete melden knapp 4 GiB, 6-GB-Geraete
    /// rund 5,6 GiB: die Grenze liegt dazwischen.
    static let smallDeviceMemory: UInt64 = 4_608 * 1024 * 1024

    static func forDevice(physicalMemory: UInt64) -> MemoryBudget {
        physicalMemory <= smallDeviceMemory ? .small : .standard
    }

    /// Grenzen dieses Geraets. Tests setzen eine andere Klasse und danach wieder `forDevice`.
    static var current = forDevice(physicalMemory: ProcessInfo.processInfo.physicalMemory)
}
