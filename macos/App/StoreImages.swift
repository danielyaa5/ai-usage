import AppKit
import AIUsageKit
import SwiftUI
import WidgetKit

/// Reproducible App Store artwork. Render only the real setup view and fictional widget readings.
@MainActor
enum StoreImages {
    static func render(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(sampleSetup: true)
        model.beginSetup()
        let setupImage = try capture(model, file: "setup-tools.png", in: folder)
        model.editSetup { journey in
            journey.toggle(.claude)
            journey.toggle(.antigravity)
            journey.advance()
        }
        _ = try capture(model, file: "setup-claude.png", in: folder)
        model.finishSetup()
        _ = try capture(model, file: "connections.png", in: folder)
        let now = Date()
        let local = UsageSummary.localSample(range:"7d",now:now)
        let entry = UsageEntry(date:now,summary:local,fetchedAt:now,error:nil,server:SharedStore.demoURL,vendor:nil,isSample:true)
        for page in 1...3 {
            let view = StoreScene(page:page, setup:setupImage, entry:entry)
            let renderer = ImageRenderer(content:view.frame(width:960,height:600).environment(\.colorScheme,page == 3 ? .dark : .light))
            renderer.scale = 1.5
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let names = ["01-desktop-usage","02-connect-history","03-plan-limits"]
            try data.write(to:folder.appendingPathComponent(names[page-1]+".png"),options:.atomic)
        }
    }

    private static func capture(_ model: AppModel, file: String, in folder: URL) throws -> NSImage {
        let controller = NSHostingController(rootView: SettingsView(model: model).environment(\.colorScheme, .light))
        let window = NSWindow(contentViewController: controller)
        window.title = "AI Usage"
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(SettingsView.initialSize)
        window.displayIfNeeded()
        let content = controller.view
        content.layoutSubtreeIfNeeded()
        guard let capture = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
        content.cacheDisplay(in: content.bounds, to: capture)
        guard let data = capture.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: folder.appendingPathComponent(file), options: .atomic)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(capture)
        return image
    }
}

private struct StoreScene: View {
    let page: Int
    let setup: NSImage
    let entry: UsageEntry
    private var dark: Bool { page == 3 }
    private var ink: Color { dark ? .white : Color(red:0.08,green:0.13,blue:0.14) }
    private var background: Color {
        switch page {
        case 1: return Color(red:0.87,green:0.93,blue:0.91)
        case 2: return Color(red:0.93,green:0.93,blue:0.89)
        default: return Color(red:0.09,green:0.13,blue:0.16)
        }
    }
    var body: some View {
        ZStack {
            background
            HStack(spacing:22) {
                VStack(alignment:.leading,spacing:18) {
                    Label("AI Usage",systemImage:"chart.bar.fill").font(.system(size:16,weight:.semibold))
                    Spacer()
                    Text(["Your AI usage, on this Mac.","Choose the tools you use.","See what’s left."][page-1])
                        .font(.system(size:52,weight:.bold)).tracking(-2).fixedSize(horizontal:false,vertical:true)
                    Text(["Requests, tokens and estimated API value in a desktop widget.",
                          "Set up each connection, then add a widget for your usage or remaining quota.",
                          "See when your Claude, ChatGPT and Google limits reset, right on your desktop."][page-1])
                        .font(.system(size:18)).foregroundStyle(ink.opacity(0.76)).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Text(page == 2 ? "Local setup" : "Sample widget data")
                        .font(.system(size:12,weight:.medium)).foregroundStyle(ink.opacity(0.67))
                }.frame(width:318,alignment:.leading)
                Spacer(minLength: 0)
                if page == 2 {
                    Image(nsImage:setup).resizable().aspectRatio(contentMode:.fit)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius:12))
                        .shadow(color:.black.opacity(0.13),radius:16,y:9)
                } else {
                    VStack(spacing:16) {
                        if page == 1 {
                            WidgetCard(family:.systemMedium) { UsageWidgetView(entry:entry,family:.systemMedium) }
                            WidgetCard(family:.systemMedium) { LimitsWidgetView(entry:entry,family:.systemMedium) }
                        } else {
                            WidgetCard(family:.systemLarge) { LimitsWidgetView(entry:entry,family:.systemLarge) }
                        }
                    }.scaleEffect(1.12).frame(maxWidth:.infinity)
                }
            }.foregroundStyle(ink).padding(.horizontal,44).padding(.vertical,38)
        }
    }
}
