import Foundation

// Uni-Mail "Mit KI verbessern" (13.11.2026, Inhaber: "ab Pro AI, Pro hat 50 KI-Mails"): die StudiNow-KI verbessert
// Rechtschreibung, Grammatik und Stil einer selbst geschriebenen E-Mail. Texte wie app/ai.py MAIL_INSTRUCTION / mail_prompt
// (tests/test_mail_rewrite.py prueft die Gleichheit). Aufgabe `mail` beim Dienst (app/ai_relay.py): Recht Pro AI bzw.
// Probe, Kontingent ai_mail (50 je Monat), keine Credits. Gesendet wird nie von hier: der Vorschlag ersetzt den Text
// erst mit "Übernehmen", abgeschickt wird wie immer nur ueber "Senden" und dessen Rueckfrage.

public enum MailRewrite {
    /// `ai.MAIL_INSTRUCTION`
    public static let system = "Du verbesserst E-Mails von Studierenden an ihre Hochschule (Lehrende, Pruefungsamt, Kommilitonen). Korrigiere Rechtschreibung, Grammatik und Zeichensetzung und mache den Stil klar, freundlich und passend hoeflich (Anrede und Gruss passend zum Empfaenger). Behalte Inhalt, Sprache, Du- oder Sie-Form, Namen, Daten, Zahlen, Links und die Absicht genau bei; erfinde nichts dazu und lass nichts Wichtiges weg. Halte die Laenge etwa gleich. Antworte NUR mit dem verbesserten Text der E-Mail, ohne Betreff, ohne Erklaerung, ohne Anfuehrungszeichen und ohne Markdown."
    /// `ai.MAIL_TEXT_MAX` / `ai.MAIL_SUBJECT_MAX`
    public static let textMax = 8000
    public static let subjectMax = 300
    /// Aufgabe der StudiNow-KI (`ai_relay._tasks`)
    public static let task = "mail"

    /// `ai.mail_prompt(subject, text)`: Betreff nur als Zusammenhang, der Text als Material (kein Auftrag)
    public static func prompt(subject: String, text: String) -> String {
        let s = String(subject.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(subjectMax))
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textMax))
        return ["Verbessere diese E-Mail.", "Betreff (nur zum Verstehen): " + (s.isEmpty ? "(kein Betreff)" : s),
                "TEXT DER E-MAIL. " + AIPromptTexts.untrusted + ":", "<<<", t, ">>>"].joined(separator: "\n")
    }

    /// Antwort der KI bereinigen: Code-Zaeune, ein vorangestelltes "Betreff: …" und umschliessende Anfuehrungszeichen
    /// weg; leer bleibt leer (dann zeigt die App einen Fehler statt eines leeren Vorschlags)
    public static func clean(_ answer: String) -> String {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first.hasPrefix("betreff:") || first.hasPrefix("subject:") {
            lines.removeFirst()
        }
        var out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("„", "“"), ("“", "”")] where out.count >= 2 && out.hasPrefix(open) && out.hasSuffix(close) {
            out = String(out.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// Fehlertexte fuer die App (Codes des Dienstes)
    public static func message(code: String?, fallback: String) -> String {
        switch code {
        case "quota_exhausted": return "Du hast diesen Monat alle 50 KI-Mails genutzt. Am 1. gibt es neue."
        case "plan_required", "payment_required": return "E-Mails mit KI verbessern gibt es mit StudiNow Pro AI."
        default: return fallback
        }
    }
}
