import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private static let onlineURL = URL(string: "https://danielyakobian.com/ai-usage/privacy/")!
    private static let sections: [String] = {
        guard let url = Bundle.main.url(forResource: "privacy", withExtension: "md"),
              let policy = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return policy.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("# ") }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Usage privacy policy").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    #if CLAUDE_QUOTA_TEST
                    Text("Automatic Claude quota in this test").font(.headline)
                    Text("If you connect Claude, Claude Code contacts Anthropic to sign you in and retrieve plan limits. AI Usage keeps the percentages, reset times and time of the reading on this Mac. The quota check skips transcript scanning and sends no model prompt.")
                    #endif
                    ForEach(Self.sections, id: \.self) { section in
                        if section.hasPrefix("## ") {
                            Text(String(section.dropFirst(3))).font(.headline).accessibilityAddTraits(.isHeader)
                        } else {
                            let text = section.hasPrefix("- ") ? String(section.dropFirst(2)) : section
                            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Divider()
            HStack {
                Link("View online", destination: Self.onlineURL)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 540, height: 425)
    }
}
