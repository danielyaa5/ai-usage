import SwiftUI
import WidgetKit
import AIUsageKit

struct SettingsView: View {
    static let initialSize = NSSize(width: 780, height: 548)
    @ObservedObject var model: AppModel
    @ObservedObject private var local: LocalSources
    @State private var showsPrivacy = false

    init(model: AppModel) {
        self.model = model
        self.local = model.local
    }

    var body: some View {
        let journey = model.showsSetup ? model.setup : nil
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let journey { SetupRail(step: journey.step) } else { connectionsRail }
                Button("Contact support…") { model.openSupport() }
                    .buttonStyle(.link).font(.callout)
                    .padding(.horizontal, 19).padding(.bottom, 8)
                    .accessibilityIdentifier("contact-support")
                Button("Privacy policy") { showsPrivacy = true }
                    .buttonStyle(.link).font(.callout)
                    .padding(.horizontal, 19).padding(.bottom, 14)
            }
            .frame(width: 192).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let journey { GuidedContent(model: model, local: local, journey: journey) }
                        else {
                            switch model.settingsPage {
                            case .connections: connections
                            case .widgets: WidgetSettings(model: model)
                            case .menuBar: MenuBarSettings(model: model)
                            case .advanced: AdvancedSettings(model: model, local: local)
                            }
                        }
                        if let notice = local.notice {
                            HStack(alignment: .firstTextBaseline) {
                                Text(notice).font(.callout).textSelection(.enabled)
                                Spacer()
                                Button("Dismiss") { local.notice = nil }.buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                .id(journey.map { "setup-\($0.step.rawValue)-\($0.index)" } ?? "\(model.settingsPage)-\(model.settingsProvider.rawValue)")
                Divider()
                if let journey { SetupFooter(model: model, local: local, journey: journey) }
                else { refreshFooter }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 690, idealWidth: Self.initialSize.width, maxWidth: .infinity,
               minHeight: 470, idealHeight: Self.initialSize.height, maxHeight: .infinity)
        .sheet(isPresented: $model.showsSupport) {
            SupportReportView(draft: model.supportDraft) { model.showsSupport = false }
        }
        .sheet(isPresented: $showsPrivacy) { PrivacyPolicyView() }
    }

    private var connectionsRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connections").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 10).padding(.bottom, 5).accessibilityAddTraits(.isHeader)
            ForEach(HistoryProvider.allCases, id: \.self) { provider in
                let selected = model.settingsPage == .connections && model.settingsProvider == provider
                Button {
                    model.settingsProvider = provider
                    model.settingsPage = .connections
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(local.connectionColor(provider)).frame(width: 9, height: 9).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName).fontWeight(.medium)
                            Text(local.connectionLabel(provider)).font(.caption)
                                .foregroundStyle(selected ? Color.white.opacity(0.88) : Color.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
                .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("nav-" + provider.rawValue)
            }
            Divider().padding(.vertical, 9)
            navigation("Widgets", "square.grid.2x2", .widgets)
            navigation("Menu Bar", "menubar.rectangle", .menuBar)
            navigation("Advanced", "gearshape", .advanced)
            Spacer()
            Button {
                model.beginSetup()
            } label: {
                Label(model.source == .local ? "Guided setup" : "Set up this Mac", systemImage: "list.number").padding(8)
            }
            .buttonStyle(.plain).accessibilityIdentifier("run-guided-setup")
            .help("Choose tools and connect them on this Mac")
        }.padding(.horizontal, 9).padding(.vertical, 21)
    }

    private func navigation(_ title: String, _ icon: String, _ page: SettingsPage) -> some View {
        let selected = model.settingsPage == page
        return Button { model.settingsPage = page } label: {
            HStack(spacing: 9) { Image(systemName: icon); Text(title); Spacer() }
                .padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var connections: some View {
        let provider = model.settingsProvider
        ProviderHeader(provider: provider, title: provider.displayName)
        Divider()
        if model.source != .local {
            Text(model.source == .demo ? "Your widgets are showing sample data." : "Your widgets are reading your dashboard.")
                .foregroundStyle(.secondary)
            Button("Use This Mac") { model.setSource(.local) }.buttonStyle(.borderedProminent)
        } else {
            HistoryConnection(provider: provider, local: local)
            Divider()
            QuotaConnection(provider: provider, local: local)
        }
    }

    private var refreshFooter: some View {
        HStack {
            if model.refreshing { ProgressView().controlSize(.small); Text("Reading usage…") }
            else if let date = model.lastAttempt { Text("Last checked \(date.formatted(date: .omitted, time: .shortened))") }
            Spacer()
            Button("Refresh now") { model.refresh() }.disabled(model.refreshing)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 10)
    }
}

struct WidgetSettings: View {
    @ObservedObject var model: AppModel
    var guided = false
    @State private var totals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(guided ? "Add your widget" : "Widgets").font(.system(size: 27, weight: .bold)).accessibilityAddTraits(.isHeader)
            Picker("Widget preview", selection: $totals) {
                Text("Plan limits").tag(false)
                Text("Usage totals").tag(true)
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
            Text(model.source == .demo ? "Preview · Sample data" : "Preview · Current readings").font(.caption).foregroundStyle(.secondary)
            WidgetCard(family: .systemMedium) {
                if totals { UsageWidgetView(entry: model.entry(), family: .systemMedium) }
                else { LimitsWidgetView(entry: model.entry(), family: .systemMedium) }
            }
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AI Usage"
            Text("Control-click your desktop, choose Edit Widgets and search for \(name). Add \(totals ? "AI usage totals" : "AI plan limits").")
                .fixedSize(horizontal: false, vertical: true)
            Text(totals ? "Control-click the placed widget to choose its time period." :
                    "For one provider’s limits and seven-day usage, add a medium or larger widget and choose its plan in Edit Widget.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var local: LocalSources
    @State private var address = ""
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Text("Advanced").font(.system(size: 27, weight: .bold)).accessibilityAddTraits(.isHeader)
            .onAppear { address = SharedStore.loadConfig().server?.absoluteString ?? "" }
        VStack(alignment: .leading, spacing: 10) {
            Text("Widget data").font(.headline)
            Picker("Source", selection: Binding(get: { model.source }, set: model.setSource)) {
                Text("This Mac").tag(SharedStore.Source.local)
                Text("Dashboard").tag(SharedStore.Source.dashboard)
                Text("Demo").tag(SharedStore.Source.demo)
            }.labelsHidden().pickerStyle(.segmented)
            switch model.source {
            case .dashboard:
                TextField("Dashboard address", text: $address, prompt: Text("my-mac.local:8796"))
                    .textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save and read", action: save)
                Button("Use Google quota on this Mac") {
                    if !local.googleQuotaConnected { local.notice = local.connectGoogleQuota() }
                    if local.googleQuotaConnected { model.setSource(.local); model.settingsProvider = .antigravity; model.settingsPage = .connections }
                }
                if let issue = model.limits?.error { Text(issue).font(.callout).foregroundStyle(.secondary) }
            case .demo:
                Text("The widgets show fictional readings.").foregroundStyle(.secondary)
                Button("Preview sample widgets") { model.settingsPage = .widgets }
            case .local:
                Text("Your widgets use the tools you connect on this Mac.").foregroundStyle(.secondary)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 11) {
            Text("Preferences").font(.headline)
            Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { value in
                do { try LoginItem.set(value); openAtLogin = LoginItem.isEnabled }
                catch { local.notice = "Couldn’t change Open at login. Check Login Items in System Settings." }
            }))
        }
    }
    private func save() { local.notice = model.setServer(address) }
}
