import SwiftUI
import AIUsageKit

private extension SetupJourney.Step {
    var title: String {
        switch self { case .tools: "Choose tools"; case .connections: "Connect tools"; case .widget: "Add widget" }
    }
}

struct SetupRail: View {
    let step: SetupJourney.Step
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SetupJourney.Step.allCases.enumerated()), id: \.element) { index, item in
                let current = SetupJourney.Step.allCases.firstIndex(of: step) ?? 0
                HStack(spacing: 9) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : item == step ? "circle.inset.filled" : "circle")
                        .foregroundStyle(index < current ? .green : item == step ? Color.accentColor : .secondary)
                        .font(.system(size: 17, weight: .semibold))
                    Text(item.title).fontWeight(item == step ? .semibold : .regular)
                        .foregroundStyle(item == step ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 7).fill(item == step ? Color.accentColor.opacity(0.10) : .clear))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title), \(item == step ? "current step" : index < current ? "complete" : "upcoming")")
                if index < SetupJourney.Step.allCases.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.26)).frame(width: 1, height: 17).padding(.leading, 18)
                }
            }
            Spacer()
        }.padding(.horizontal, 9).padding(.top, 26)
    }
}

struct GuidedContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var local: LocalSources
    let journey: SetupJourney
    var body: some View {
        switch journey.step {
        case .tools:
            Text("Which tools do you use?").font(.system(size: 27, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Choose the tools you’d like to see in your desktop widgets.").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(HistoryProvider.allCases, id: \.self) { provider in
                    let selected = journey.tools.contains(provider)
                    Button { model.editSetup { $0.toggle(provider) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider.symbol).font(.title2).foregroundStyle(provider.tint).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName).font(.headline)
                                Text(provider == .codex ? "Codex history and ChatGPT limits" :
                                     provider == .claude ? "Desktop plan limits and Claude Code history" : "Antigravity history and Google quota")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                        }.padding(.vertical, 13).padding(.horizontal, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("choose-" + provider.rawValue)
                    if provider != .antigravity { Divider() }
                }
            }
            Button("Preview with sample data") {
                model.setSource(.demo)
                if model.source == .demo { model.finishSetup(page: .widgets) }
            }.buttonStyle(.link)
        case .connections:
            if let provider = journey.provider {
                if journey.tools.count > 1 {
                    Text("Tool \(journey.index + 1) of \(journey.tools.count)").font(.caption).foregroundStyle(.secondary)
                }
                ProviderHeader(provider: provider, title: "Connect " + provider.displayName)
                QuotaConnection(provider: provider, local: local)
                Divider()
                HistoryConnection(provider: provider, local: local)
            }
        case .widget:
            WidgetSettings(model: model, guided: true)
        }
    }
}

struct SetupFooter: View {
    @ObservedObject var model: AppModel
    @ObservedObject var local: LocalSources
    let journey: SetupJourney
    var body: some View {
        HStack {
            if journey.step == .tools {
                Button("Set up later") { model.finishSetup() }.buttonStyle(.link)
            } else {
                Button("Back") { model.editSetup { $0.back() } }
            }
            Spacer()
            switch journey.step {
            case .tools:
                Button("Continue") { model.editSetup { $0.advance() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(journey.tools.isEmpty)
            case .connections:
                if hasStartedConnection {
                    Button(journey.index + 1 < journey.tools.count ? "Next tool" : "Continue to widget") { model.editSetup { $0.advance() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip this tool for now") { model.editSetup { $0.advance() } }.buttonStyle(.bordered)
                }
            case .widget:
                Button("Done") { model.finishSetup() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 23).padding(.vertical, 12)
    }
    private var hasStartedConnection: Bool {
        guard let provider = journey.provider else { return false }
        return local.selected.contains(provider) ||
            (provider == .claude && (local.claudeDesktop != nil || local.statusLineEnabled)) ||
            (provider == .codex && (local.chatConnected || local.accountBusy)) ||
            (provider == .antigravity && local.googleQuotaConnected)
    }
}
