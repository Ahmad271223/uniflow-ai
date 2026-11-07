import Foundation

/// Prompts des Dokument-Index, byte-gleich mit `page_prompt`/`SYSTEM` in app/doc_index.py
/// (packages/shared-contracts/fixtures/doc-index/cases.json, DocIndexTests). Fremde Texte sind Material (`untrusted`).
public enum DocIndexPrompts {
    public static let system = "Du bist ein genauer Bibliothekar fuer Lernunterlagen eines Informatik-/Elektrotechnik-Studiums. "
        + "Du beschreibst, was auf einer Seite steht, erfindest nichts und antwortest ausschliesslich mit JSON nach dem Schema. "
        + AIPromptTexts.mathStyleJSON

    /// so viel Seitentext geht in den Prompt (Codepunkte, wie `text.strip()[:9000]`)
    public static let textChars = 9000

    public static func page(course: String, fileName: String, page: Int, pageCount: Int, text: String, withImage: Bool,
                            withSolutions: Bool = false) -> String {
        var parts = ["Kurs: \(course)", "Datei: \(fileName), Seite \(page) von \(pageCount)", "",
                     "AUFGABE: Erstelle den Index dieser Seite. Liste JEDES Element in Lesereihenfolge (order 1..n) mit Art "
                     + "(skizze, diagramm, tabelle, formel, definition, satz, beispiel, aufgabe, text), kurzem Titel, einer kurzen "
                     + "Erklaerung (1-2 Saetze, Formeln mit Unicode-Zeichen), Lage auf der Seite (oben, mitte, unten, links, rechts, ganz) und "
                     + "uncertain=true, wenn du dir nicht sicher bist. Gehoert ein Element zu einer Aufgabe, nenne sie in task (z. B. \"Aufgabe 3b\"). "
                     + "Fuer jede Aufgabe auf der Seite: unter tasks, was genau verlangt ist (asks), knapp."]
        parts.append(withSolutions ? "Loesungen: solution ausfuellen (nachvollziehbar, kurz)." : "KEINE Loesungen: solution bleibt null.")
        parts.append("summary: 1-2 Saetze, worum es auf der Seite geht. terms: bis zu 12 Fachbegriffe der Seite.")
        if withImage {
            parts += ["", "Das Bild zeigt die Seite; der Text darunter ist die Textebene der PDF (kann unvollstaendig sein)."]
        }
        let content = PyText.slice(PyText.strip(text), 0, textChars)
        parts += ["", "SEITENTEXT. \(AIPromptTexts.untrusted):", "<<<", content.isEmpty ? "[kein Text extrahierbar]" : content, ">>>"]
        return parts.joined(separator: "\n")
    }
}

/// KI fuer den Dokument-Index: Text, dazu wahlweise das Bild der Seite (JPEG) und die Bitte um das sparsame Modell
/// (Vorwaermen im Hintergrund). Eine KI ohne Bilder antwortet nur auf den Text.
public protocol DocIndexAI: Sendable {
    /// Antworttext (JSON nach `schema`); wirft `AIError`
    func index(system: String, prompt: String, imageJPEG: Data?, schema: JSONValue, small: Bool) async throws -> String
    /// Name des Modells, das zuletzt geantwortet hat (fuer den Datensatz), leer wenn unbekannt
    var modelName: String { get async }
}

/// Jede `AIProvider`-KI (Text) als Index-KI: Bild und Modellwunsch werden nicht gesendet
public struct TextDocIndexAI: DocIndexAI {
    public let provider: AIProvider
    public init(_ provider: AIProvider) { self.provider = provider }

    public func index(system: String, prompt: String, imageJPEG: Data?, schema: JSONValue, small: Bool) async throws -> String {
        try await provider.answer(system: system, prompt: prompt, schema: schema.isNull ? nil : schema)
    }

    public var modelName: String { get async { "" } }
}

/// Index-KI ueber das ChatGPT-Abo des Nutzers mit Bildern: Text-Anfragen ohne Modellwunsch gehen durch
/// `ChatGPTSession.complete` (mit dessen Modellwechsel); Anfragen mit Bild oder mit dem sparsamen Modell baut sie selbst
/// aus den oeffentlichen Teilen (Zugriffstoken, Kopfzeilen, Anfrageform, Ereignisstrom) und sendet sie ueber denselben
/// Transport. Das Bild geht als `input_image` (data-URL, JPEG) mit; gespeichert wird es nirgends.
public final class ChatGPTVisionAI: DocIndexAI, @unchecked Sendable {
    public let session: ChatGPTSession
    private let http: AIHTTPTransport
    private let lock = NSLock()
    private var lastModel = ""

    public init(session: ChatGPTSession, http: AIHTTPTransport) {
        self.session = session
        self.http = http
    }

    public var modelName: String {
        get async {
            let l = lock.withLock { lastModel }
            return l.isEmpty ? await session.status.model : l
        }
    }

    /// Sparsame Modelle fuer das Vorwaermen: aus der Liste des Abos (Katalogreihenfolge) eines mit "luna", "mini" oder
    /// "nano", sonst der feste Kandidat; nie ein vom Konto abgelehntes
    public static func smallModel(listed: [String], rejected: Set<String>) -> String? {
        let small = listed.filter { id in ["luna", "mini", "nano"].contains { id.lowercased().contains($0) } } + ["gpt-6-luna"]
        return small.first { !rejected.contains($0) }
    }

    /// Anfrage an die Responses API mit Text und Bild: `input` als Liste mit `input_text` und `input_image`
    public static func body(model: String, system: String, prompt: String, imageJPEG: Data?, schema: JSONValue) -> JSONValue {
        // `.null` = freie Antwort ohne Schema (KI-Hilfe mit Bild)
        var body = ChatGPTProtocol.responsesBody(model: model, system: system, prompt: prompt, schema: schema.isNull ? nil : schema)
        guard let image = imageJPEG else { return body }
        let content: [JSONValue] = [["type": "input_text", "text": .string(prompt)],
                                    ["type": "input_image", "detail": "high", "image_url": .string("data:image/jpeg;base64," + image.base64EncodedString())]]
        body["input"] = [["role": "user", "content": .array(content)]]
        return body
    }

    public func index(system: String, prompt: String, imageJPEG: Data?, schema: JSONValue, small: Bool) async throws -> String {
        let status = await session.status
        guard status.enabledForAI else { throw AIError("chatgpt_not_enabled", "KI über ChatGPT ist nicht verbunden.") }
        if imageJPEG == nil, !small {
            let text = try await session.complete(system: system, prompt: prompt, schema: schema.isNull ? nil : schema)
            lock.withLock { lastModel = "" }
            return text
        }
        let token = try await session.accessToken()
        var models = [status.model]
        if small, let s = Self.smallModel(listed: (try? await session.models()) ?? [], rejected: Set(await session.rejectedModels)), s != status.model {
            models.insert(s, at: 0)
        }
        for (i, model) in models.enumerated() {
            let r: (status: Int, body: Data)
            do {
                r = try await http.send(AIHTTPRequest(method: "POST", url: ChatGPTConstants.responsesURL, headers: ChatGPTProtocol.requestHeaders(token: token),
                                                      body: Self.body(model: model, system: system, prompt: prompt, imageJPEG: imageJPEG, schema: schema).serialized()))
            } catch {
                throw ChatGPTProtocol.error(status: 0)
            }
            // das sparsame Modell abgelehnt: mit dem Modell der Sitzung weiter
            if ChatGPTSession.isModelRejection(status: r.status, body: r.body), i < models.count - 1 { continue }
            guard (200..<300).contains(r.status) else {
                throw ChatGPTProtocol.error(status: r.status, detail: ChatGPTSession.errorText(String(decoding: r.body.prefix(600), as: UTF8.self)))
            }
            let streamed = try ChatGPTProtocol.streamedText(r.body)
            lock.withLock { lastModel = streamed.model.isEmpty ? model : streamed.model }
            return streamed.text
        }
        throw ChatGPTProtocol.error(status: 0)
    }
}
