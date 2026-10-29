// erzeugt von tools/gen-swift-ai-texts.py, nicht von Hand aendern
// Quelle: app/ai.py und app/chatgpt_login.py

/// Feste Texte der KI wie in app/ai.py (byte-gleich; Vertrag packages/shared-contracts/ai/contract.json).
enum AIPromptTexts {
    /// `ai.SYSTEM`
    static let system = #"Du bist ein Lerncoach fuer ein Informatik-/Elektrotechnik-Studium (Leibniz Universitaet Hannover, 1. Semester). Antworte ausschliesslich mit gueltigem JSON, ohne Erklaertext, ohne Markdown-Zaeune."#

    /// `ai.TUTOR_SYSTEM`
    static let tutorSystem = #"Du bist ein geduldiger Tutor fuer ein Informatik-/Elektrotechnik-Studium im ersten Semester (Leibniz Universitaet Hannover). Antworte auf Deutsch, klar strukturiert in Markdown, mit kurzen Absaetzen und Formeln als Text. Beziehe dich konkret auf den gegebenen Seiteninhalt."#

    /// `ai.TUTOR_MODES` in der Reihenfolge von Python
    static let tutorModes: [(key: String, text: String)] = [
        (#"explain"#, #"Erklaere den markierten Text bzw. die Formel verstaendlich. Erst einfach, dann etwas genauer, mit einem kleinen Beispiel."#),
        (#"explain_simple"#, #"Erklaere so einfach wie moeglich, als waere ich Anfaenger. Keine Fachbegriffe ohne Erklaerung."#),
        (#"summary"#, #"Fasse die Seite in 5-8 Stichpunkten zusammen und nenne, was man danach koennen muss."#),
        (#"steps"#, #"Loese die Aufgabe (markierter Text oder Seiteninhalt) Schritt fuer Schritt. Erklaere jeden Schritt kurz."#),
        (#"hints"#, #"Gib NUR Hinweise zur Loesung der Aufgabe, keine fertige Loesung. Maximal 3 Hinweise, vom allgemeinen zum konkreten."#),
        (#"check"#, #"Pruefe meine Loesung (unter 'Meine Loesung'). Sage, was richtig ist, wo Fehler sind und wie man sie behebt. Gib am Ende eine Einschaetzung in Punkten von 10."#),
        (#"similar"#, #"Erstelle eine aehnliche Uebungsaufgabe mit gleichem Schwierigkeitsgrad und gib die Loesung getrennt darunter an."#),
        (#"terms"#, #"Definiere die Fachbegriffe auf dieser Seite kurz und praezise (Begriff: Definition)."#),
        (#"flashcards"#, #"Erstelle 6-10 Karteikarten aus dem Seiteninhalt. Antworte NUR mit JSON: [{"question": "...", "answer": "..."}]"#),
    ]

    /// `ai.ANALYSIS_FIELDS`
    static let analysisFields = #"""
Gib ein JSON-Objekt mit genau diesen Feldern zurueck:
{
  "doc_type": "vorlesung" | "uebung" | "loesung" | "skript" | "organisatorisch" | "klausur" | "sonstiges",
  "title": "kurzer sprechender Titel (max. 60 Zeichen)",
  "topics": ["Thema 1", "Thema 2", ...],              // 2-6 Stichworte
  "difficulty": 1-5,                                   // 1 = sehr leicht, 5 = sehr schwer, fuer Erstsemester
  "est_minutes": Zahl,                                 // realistische Lernzeit in Minuten zum Durcharbeiten
  "summary": "2-3 Saetze: worum geht es, was muss man danach koennen",
  "prerequisites": ["Vorwissen 1", ...]                // optional, kann leer sein
}
"""#

    /// `ai.WEEK_TEST_DIFFICULTY` (Entscheidung des Inhabers vom 29.10.2026) in der Reihenfolge von Python
    static let weekTestDifficulty: [(level: String, count: Int)] = [(#"leicht"#, 4), (#"mittel"#, 6), (#"schwer"#, 5)]

    /// `ai.WEEK_TEST_TOTAL`
    static let weekTestTotal = 15

    /// `ai.WEEK_TEST_TYPES`
    static let weekTestTypes = [#"mc"#, #"short"#, #"calc"#]
}

/// Konstanten von Sign in with ChatGPT wie app/chatgpt_login.py (oeffentlich: die App baut damit die Rueckleitung)
public enum ChatGPTConstants {
    public static let authURL = #"https://auth.openai.com/api/accounts/authorize"#
    public static let tokenURL = #"https://auth.openai.com/api/accounts/oauth/token"#
    public static let issuer = #"https://auth.openai.com"#
    public static let jwksURL = #"https://auth.openai.com/.well-known/jwks.json"#
    public static let resource = #"https://api.openai.com/v1"#
    public static let responsesURL = #"https://api.openai.com/v1/responses"#
    public static let modelsURL = #"https://api.openai.com/v1/models"#
    public static let usageHelpURL = #"https://chatgpt.com/#settings"#
    public static let scope = #"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"#
    public static let usageScope = #"chatgpt.tokens.use.direct"#
    public static let firstClientID = #"dynamic_agent_client"#
    public static let agentName = #"Studora"#
    public static let callbackPath = #"/auth/callback"#
    /// Sekunden bis zum Abbruch einer Anmeldung
    public static let flowTimeout: Double = 600
    /// Zugriffstoken so viele Sekunden vor Ablauf erneuern
    public static let refreshMargin: Double = 60
}
