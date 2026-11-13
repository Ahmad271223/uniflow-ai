import SwiftUI
import UniFlowCore

/// Hinweis "KI-Hilfe: Was wird gesendet?" vor der ersten Anfrage an die StudiNow-KI (06.11.2026, App Store Review
/// Guideline 5.1.2(i)): was gesendet wird, an wen (StudiNow-Dienst, OpenAI, Claude ueber Amazon Bedrock), Link zur
/// Datenschutzerklaerung, "Okay, los" / "Abbrechen". Gezeigt von `AIConsentCenter`, Texte aus `AIConsentText`
/// (UniFlowCore). Seit 13.11.2026 kurz (Wunsch des Inhabers): zuerst nur `AIConsentText.short` (was und an wen in zwei
/// Saetzen), die ausfuehrlichen Abschnitte erst nach "Genauer ansehen". Scrollt, damit er auch bei grosser Schrift ganz
/// lesbar bleibt.
struct AIConsentSheet: View {
    let decide: (Bool) -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 9.6) {
                        UFIcon("sparkles", size: 20).foregroundStyle(UF.accent)
                        Text(AIConsentText.title).ufFont(19.2, 700, lh: 1.25).foregroundStyle(UF.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    paragraph(AIConsentText.short)
                    if showDetails {
                        section(AIConsentText.whatHeading, icon: "file-text") {
                            bullets(AIConsentText.what)
                            paragraph(AIConsentText.never, color: UF.text2)
                        }
                        section(AIConsentText.whereHeading, icon: "share") {
                            paragraph(AIConsentText.service)
                            bullets(AIConsentText.recipients)
                            paragraph(AIConsentText.processors, color: UF.text2)
                        }
                        paragraph(AIConsentText.revoke, color: UF.muted)
                    } else {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showDetails = true } } label: {
                            HStack(spacing: 6) {
                                Text(AIConsentText.details)
                                UFIcon("chevron-down", size: 13)
                            }
                            .ufFont(14.5, 600).foregroundStyle(UF.accent)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aiConsent.details")
                    }
                    if let url = URL(string: AIConsentText.privacyURL) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                UFIcon("info", size: 14)
                                Text(AIConsentText.privacyLink).underline()
                            }
                            .ufFont(14.5, 600).foregroundStyle(UF.accent)
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("aiConsent.privacy")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            UFFlexWrap(gap: 9.6) {
                UFButton(AIConsentText.cancel) { decide(false) }
                    .accessibilityIdentifier("aiConsent.cancel")
                UFButton(AIConsentText.accept, icon: "check", kind: .primary) { decide(true) }
                    .accessibilityIdentifier("aiConsent.accept")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(UF.surface)
        .accessibilityIdentifier("aiConsent.sheet")
    }

    private func paragraph(_ text: String, color: Color = UF.text) -> some View {
        Text(text).ufFont(14.5, lh: 1.5).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(UF.accent).accessibilityHidden(true)
                    Text(item).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(14.5, lh: 1.45)
            }
        }
    }

    private func section<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7.2) {
                UFIcon(icon, size: 15).foregroundStyle(UF.accent)
                Text(title).ufFont(15.2, 650).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
