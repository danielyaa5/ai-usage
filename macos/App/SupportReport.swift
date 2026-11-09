import AppKit
import AIUsageKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Only fixed app state is included. Raw provider output, account names, paths and usage totals stay local.
@MainActor
enum SupportDiagnostics {
    static func snapshot(model: AppModel) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AI Usage"
        let local = model.local
        let history = HistoryProvider.allCases.filter(local.selected.contains).map(\.displayName).joined(separator: ", ")
        var lines = [
            "\(app) \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Widget source: \(model.source.rawValue)",
            "Setup in progress: \(model.setup != nil)",
            "Menu bar icon enabled: \(model.showMenuBarIcon)",
        ]
        if model.source == .local {
            lines += ["Connected history sources: " + (history.isEmpty ? "None" : history),
                      "Claude Desktop connected: \(local.claudeDesktop != nil)",
                      "Claude terminal receiver enabled: \(local.statusLineEnabled)",
                      "OpenAI connected: \(local.chatConnected)",
                      "Google quota connected: \(local.googleQuotaConnected)"]
            #if CLAUDE_QUOTA_TEST
            lines.append("Automatic Claude quota: " + local.claudeLive.label)
            #endif
        }
        return lines.joined(separator: "\n")
    }
}

enum SupportKind: String, CaseIterable { case bug, feedback
    var title: String { self == .bug ? "Report a bug" : "Send feedback" }
}
struct SupportImage: Identifiable {
    let id = UUID()
    let data: Data
    var preview: NSImage { NSImage(data: data) ?? NSImage() }
    static func read(_ url: URL) throws -> SupportImage {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw SupportFailure.image }
        // Encode pixels only: strip source filenames, location and other image metadata.
        for quality in [0.82, 0.65, 0.45] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw SupportFailure.image }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= 1_000_000 { return SupportImage(data: data as Data) }
        }
        throw SupportFailure.image
    }
}
enum SupportFailure: LocalizedError { case image, delivery, rateLimit
    var errorDescription: String? {
        switch self {
        case .image: return "Couldn't prepare this screenshot. Choose a smaller PNG or JPEG."
        case .delivery: return "We couldn't confirm delivery. Check your connection and try again. Your report and screenshots are still here."
        case .rateLimit: return "Too many reports were sent recently. Wait a minute and try again. Your report is still here."
        }
    }
}
/// Refuse redirects so report contents cannot be forwarded to a different service.
final class SupportTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func send(_ body: Data, to endpoint: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: SupportTransport(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 429 { throw SupportFailure.rateLimit }
        guard status == 200, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else { throw SupportFailure.delivery }
    }
}
@MainActor final class SupportDraft: ObservableObject {
    @Published var kind: SupportKind = .bug
    @Published var summary = ""
    @Published var details = ""
    @Published var email = ""
    @Published var includeDiagnostics = true
    @Published var images: [SupportImage] = []
    @Published var busy = false
    @Published var sent = false
    @Published var message = ""
    @Published private(set) var diagnostics = ""
    private var reference = UUID().uuidString
    private var attemptedBody: Data?
    static var endpoint: URL {
        #if CLAUDE_QUOTA_TEST
        // Only a separately signed test copy can point reports at the local test receiver.
        if let port = Bundle.main.object(forInfoDictionaryKey: "AIUsageSupportTestPort") as? NSNumber,
           (1024...65535).contains(port.intValue) {
            return URL(string: "http://127.0.0.1:\(port.intValue)/report")!
        }
        #endif
        return URL(string: "https://cloud-media-shrinker-support.cloud-media-shrinker-dy.workers.dev/report")!
    }
    var validationMessage: String? {
        let title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(3...120).contains(title.utf16.count) || title.contains(where: { $0.isNewline }) { return "Enter a summary of 3–120 characters on one line." }
        if !(10...10000).contains(body.utf16.count) { return "Add a description of 10–10,000 characters (currently \(body.utf16.count))." }
        if reply.count > 254 || (!reply.isEmpty && reply.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil) { return "Enter a valid reply email, or leave the optional email field empty." }
        if images.count > 3 { return "Attach no more than three screenshots." }
        return nil
    }

    func payload() throws -> Data {
        var fields: [String: Any] = ["app": "AI Usage", "id": reference, "kind": kind.rawValue, "summary": summary.trimmingCharacters(in: .whitespacesAndNewlines), "details": details.trimmingCharacters(in: .whitespacesAndNewlines), "replyTo": email.trimmingCharacters(in: .whitespacesAndNewlines), "attachments": images.map { ["content": $0.data.base64EncodedString()] }]
        if includeDiagnostics { fields["diagnostics"] = diagnostics }
        return try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
    }
    func prepareForDisplay(model: AppModel) {
        if sent { reset() }
        if attemptedBody == nil && !busy { diagnostics = SupportDiagnostics.snapshot(model: model) }
    }
    func addImages() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.png, .jpeg]; picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
        guard picker.runModal() == .OK else { return }
        guard images.count + picker.urls.count <= 3 else { message = "You can attach up to three screenshots. Remove one before adding another."; return }
        do { let added = try picker.urls.map(SupportImage.read); images += added; message = "" } catch { message = error.localizedDescription }
    }
    func send() async {
        guard !busy, !sent else { return }
        if let validationMessage { message = validationMessage; return }
        busy = true; message = "Sending…"
        defer { busy = false }
        do {
            var body = try payload()
            if let attemptedBody, attemptedBody != body { reference = UUID().uuidString; body = try payload() }
            attemptedBody = body
            try await SupportTransport.send(body, to: Self.endpoint)
            sent = true; message = "Report sent. Thank you!"
        } catch { message = (error as? SupportFailure)?.localizedDescription ?? SupportFailure.delivery.localizedDescription }
    }
    private func reset() {
        kind = .bug; summary = ""; details = ""; email = ""; images = []; sent = false; message = ""; includeDiagnostics = true
        diagnostics = ""; reference = UUID().uuidString; attemptedBody = nil
    }
}
struct SupportReportView: View {
    @ObservedObject var draft: SupportDraft
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.kind.title).font(.title.bold())
            Text("Send privately to support@danielyakobian.com.").foregroundStyle(.secondary)
            if draft.sent {
                Label(draft.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline).padding(.vertical, 24)
                HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Report type", selection: $draft.kind) { ForEach(SupportKind.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        Text("Summary (required, 3–120 characters)").font(.headline)
                        TextField("A short description", text: $draft.summary).textFieldStyle(.roundedBorder).accessibilityIdentifier("support-summary")
                        Text(draft.kind == .bug ? "What happened? Include what you expected and steps to reproduce it." : "What would you like to improve?").font(.headline)
                        TextEditor(text: $draft.details).frame(height: 105).border(Color.secondary.opacity(0.3)).accessibilityLabel("Report details")
                        Text("Required: 10–10,000 characters. Email and screenshots are optional.").font(.caption).foregroundStyle(.secondary)
                        TextField("Your email (optional, so we can reply)", text: $draft.email).textFieldStyle(.roundedBorder).accessibilityIdentifier("support-email")
                        HStack { Text("Screenshots").font(.headline); Spacer(); Button("Add screenshots…") { draft.addImages() }.disabled(draft.images.count >= 3) }
                        Text("Up to 3 PNG or JPEG images. Review screenshots for private information before sending.").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(draft.images.enumerated()), id: \.element.id) { index, image in
                                VStack {
                                    Image(nsImage: image.preview).resizable().scaledToFit().frame(width: 140, height: 85)
                                    Button("Remove screenshot \(index + 1)") { draft.images.removeAll { $0.id == image.id } }.font(.caption)
                                }
                            }
                        }
                        Toggle("Include app diagnostics", isOn: $draft.includeDiagnostics)
                        Text("App and macOS versions, widget settings and which sources are connected.").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Review diagnostics") { Text(draft.diagnostics).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                        Text("Cloudflare and Resend deliver the report when you choose Send report.").font(.caption).foregroundStyle(.secondary)
                    }.padding(2).disabled(draft.busy)
                }
                if !draft.message.isEmpty { Text(draft.message).font(.callout).foregroundStyle(draft.busy ? Color.secondary : Color.red).accessibilityIdentifier("support-status") }
                HStack { Spacer(); Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(draft.busy); Button("Send report") { Task { await draft.send() } }.buttonStyle(.borderedProminent).disabled(draft.busy) }
            }
        }.padding(24).frame(width: 550, height: draft.sent ? 200 : 500)
            .interactiveDismissDisabled(draft.busy)
    }
}
