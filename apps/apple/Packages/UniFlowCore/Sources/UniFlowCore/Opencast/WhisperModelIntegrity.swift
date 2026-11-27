import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Pruefsummen der Sprachmodelle fuer die Mitschrift (Sicherheitspruefung 27.11.2026): WhisperKit laedt die Modelle von
// Hugging Face (`argmaxinc/whisperkit-coreml`, Zweig main) ohne Pruefung. Die App vergleicht jede Datei mit dieser Liste,
// bevor CoreML sie oeffnet; weicht etwas ab, wird der Ordner geloescht und das Modell nicht benutzt.
// Erzeugt aus der Dateiliste des Repos zum Stand 0f63a7800b00dd0226abd051b906c246e1907482 (Groesse und SHA-256; LFS-Dateien laut Hugging Face,
// kleine Dateien selbst geladen und gerechnet). Aendert Hugging Face ein Modell, muss diese Liste neu erzeugt werden.

public enum WhisperModelIntegrity {
    public static let revision = "0f63a7800b00dd0226abd051b906c246e1907482"

    public struct Entry: Sendable, Equatable { public let sha256: String; public let size: Int64 }

    /// Variante (Ordnername) -> Pfad im Ordner -> Pruefsumme
    public static let manifest: [String: [String: Entry]] = [
        "openai_whisper-large-v3-v20240930_626MB": [
            "AudioEncoder.mlmodelc/analytics/coremldata.bin": Entry(sha256: "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95", size: 243),
            "AudioEncoder.mlmodelc/coremldata.bin": Entry(sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3", size: 348),
            "AudioEncoder.mlmodelc/metadata.json": Entry(sha256: "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669", size: 1922),
            "AudioEncoder.mlmodelc/model.mil": Entry(sha256: "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442", size: 934263),
            "AudioEncoder.mlmodelc/weights/weight.bin": Entry(sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1", size: 421968768),
            "MelSpectrogram.mlmodelc/analytics/coremldata.bin": Entry(sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce", size: 243),
            "MelSpectrogram.mlmodelc/coremldata.bin": Entry(sha256: "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130", size: 329),
            "MelSpectrogram.mlmodelc/metadata.json": Entry(sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f", size: 1850),
            "MelSpectrogram.mlmodelc/model.mil": Entry(sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463", size: 10143),
            "MelSpectrogram.mlmodelc/weights/weight.bin": Entry(sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49", size: 373376),
            "TextDecoder.mlmodelc/analytics/coremldata.bin": Entry(sha256: "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8", size: 243),
            "TextDecoder.mlmodelc/coremldata.bin": Entry(sha256: "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9", size: 633),
            "TextDecoder.mlmodelc/metadata.json": Entry(sha256: "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052", size: 4924),
            "TextDecoder.mlmodelc/model.mil": Entry(sha256: "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754", size: 217177),
            "TextDecoder.mlmodelc/weights/weight.bin": Entry(sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db", size: 203199860),
            "config.json": Entry(sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1", size: 1149),
            "generation_config.json": Entry(sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6", size: 2767),
        ],
        "openai_whisper-small_216MB": [
            "AudioEncoder.mlmodelc/analytics/coremldata.bin": Entry(sha256: "0c33d98d0f2046b711d75041260eb53fd0ca1c3226930a779fe9082bc4763449", size: 243),
            "AudioEncoder.mlmodelc/coremldata.bin": Entry(sha256: "bb991927256c8b71c8f5df3eb652bd0d67d933d7c36da4e53a5eb15a0a635ca1", size: 347),
            "AudioEncoder.mlmodelc/metadata.json": Entry(sha256: "cc5b8143fddf32493a28fbd9cdda8222a862912162a665f40290f94dcbf5b4b5", size: 1942),
            "AudioEncoder.mlmodelc/model.mil": Entry(sha256: "885cd28872db8a8e471ee49c1438aa0f55bb43bec1fbeb82e89096bac61d52b4", size: 353690),
            "AudioEncoder.mlmodelc/model.mlmodel": Entry(sha256: "21680c8556cfc807eb68ae78cf498b15d805b6e655350909bd6a7a0b54b2daeb", size: 293185),
            "AudioEncoder.mlmodelc/weights/weight.bin": Entry(sha256: "dfbda1e30a5cea269ea93e2ec69d78a6c5070c0b27982690f02d23e71fecb2d6", size: 62057344),
            "MelSpectrogram.mlmodelc/analytics/coremldata.bin": Entry(sha256: "c4f367993f0198e9858a4d89fb054318982c91a9bb5946e29231421c2f1100b9", size: 243),
            "MelSpectrogram.mlmodelc/coremldata.bin": Entry(sha256: "806321f1034184a10b04dc50816219dec8ae9789698712050c81edecb9bb5aa7", size: 328),
            "MelSpectrogram.mlmodelc/metadata.json": Entry(sha256: "6a95b18553edd73f018fe954d203d9c3cfa70dfa596d140c20f519ca471fe6be", size: 1878),
            "MelSpectrogram.mlmodelc/model.mil": Entry(sha256: "7877c0f519a97a7c0dc1e0e9f8ae316bd864afcb2cffa89c770184b07e7767c9", size: 10134),
            "MelSpectrogram.mlmodelc/weights/weight.bin": Entry(sha256: "801024dbc7a89c677be1f8b285de3409e35f7d1786c9c8d9d0d6842ac57a1c83", size: 354080),
            "TextDecoder.mlmodelc/analytics/coremldata.bin": Entry(sha256: "7883317b9bd8a263bd395091bfd1ebbd098826dc7c75569dcaa870691ab46554", size: 243),
            "TextDecoder.mlmodelc/coremldata.bin": Entry(sha256: "ab598c8f928071a2eee05cdc2163acea3b8d6c7d69b66b31a93dac6681c26a79", size: 633),
            "TextDecoder.mlmodelc/metadata.json": Entry(sha256: "8bea59efa6a97b0fd5c9237a1ecb5d1c2d00b1c19970c04b2f3cef0d411cad70", size: 4935),
            "TextDecoder.mlmodelc/model.mil": Entry(sha256: "62f97fc5ba7a452d5394d48657b8c245137115a749c16680fc3b159a106d1bd2", size: 618369),
            "TextDecoder.mlmodelc/model.mlmodel": Entry(sha256: "2dac33b92f19491a71d67460384b95d56489b226f46c6074c17f3e81479bcca6", size: 518452),
            "TextDecoder.mlmodelc/weights/weight.bin": Entry(sha256: "2be2985330071f8188e1c2ab029e1b69d6e8c42865c8d58b20b8d41856da9ed3", size: 153130482),
            "config.json": Entry(sha256: "12f8d45c3e5da28148d88d257684e77296e4d922009e1bc5289b05b756859422", size: 1456),
            "generation_config.json": Entry(sha256: "169e76633bb28ac383cdfaad2527e662d0d532a15f8437ce94c02c10bc713b71", size: 2779),
        ],
    ]

    /// Abweichungen eines geladenen Modellordners (leer = alles passt): fehlende Datei, falsche Groesse, falsche
    /// Pruefsumme, unbekannte Datei in einem `.mlmodelc`-Ordner. Unbekannte Variante: eine Meldung.
    public static func problems(variant: String, folder: URL, fileManager: FileManager = .default) -> [String] {
        guard let expected = manifest[variant] else { return ["Unbekanntes Modell \(variant)"] }
        var out: [String] = []
        for (rel, e) in expected.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(rel)
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
                out.append("fehlt: \(rel)"); continue
            }
            if size != e.size { out.append("Größe: \(rel)"); continue }
            guard let hash = sha256(of: url) else { out.append("nicht lesbar: \(rel)"); continue }
            if hash != e.sha256 { out.append("Prüfsumme: \(rel)") }
        }
        // Nichts Fremdes in den Modell-Ordnern, die CoreML oeffnet
        if let walk = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walk {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                if rel.contains(".mlmodelc/"), expected[rel] == nil { out.append("unbekannt: \(rel)") }
            }
        }
        return out
    }

    /// SHA-256 einer Datei in Stuecken (Modelle sind mehrere hundert MB gross)
    public static func sha256(of url: URL) -> String? {
        #if canImport(CryptoKit)
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try h.read(upToCount: 4 << 20) ?? Data() } catch { return nil }   // am Ende: nil oder leer
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}
