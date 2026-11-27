#if DEBUG
import AppKit
import SwiftUI
import PortlaneCore

/// Renders the native views with fixture data for comparison against the Pen masters.
@MainActor
enum DebugPreviews {
    private static var menuWindow: NSWindow?
    /// Hosts the actual menu content in a native popover for interactive layout checks.
    static func showMenuHarness(model: PortlaneModel) {
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 460, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lane Menu Check"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuPreviewHarness(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        menuWindow = window
    }

    static func write(model: PortlaneModel, directory: String) {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let windowSize = NSSize(width: 960, height: 620)
            try render(MainWindow(model: model), size: windowSize, scheme: .light, to: output.appending(path: "main-light.png"))
            try render(MainWindow(model: model), size: windowSize, scheme: .dark, to: output.appending(path: "main-dark.png"))
            try render(MainWindow(model: model), size: NSSize(width: 720, height: 500),
                       scheme: .light, to: output.appending(path: "main-narrow.png"))
            let localSession = model.externalSessions.first { $0.rules.count > 1 }
            if let session = localSession {
                model.selection = .external(session.id)
                try render(MainWindow(model: model), size: windowSize, scheme: .light, to: output.appending(path: "external.png"))
                model.selection = model.store.tunnels.first.map { .managed($0.id) }
            }
            for kind in ForwardingKind.allCases {
                let sample = Tunnel(name: L10n.text("Development", "开发环境"), host: "dev-gateway",
                                    forwardings: [DemoContent.rule(kind)])
                let editor = TunnelEditor(request: .init(tunnel: sample), model: model)
                try render(editor, size: NSSize(width: 758, height: 646), scheme: .light,
                           to: output.appending(path: "editor-\(kind.rawValue).png"))
            }
            let menuSize = NSSize(width: 362, height: 398)
            try render(LaneMenuBar(model: model), size: menuSize, scheme: .light, fitHeight: true,
                       to: output.appending(path: "menu-bar.png"))
            if let session = localSession {
                try render(LaneMenuBar(model: model, previewExpandedSession: session.id), size: menuSize, scheme: .light,
                           fitHeight: true, to: output.appending(path: "menu-overflow.png"))
            }
            for tunnel in model.store.tunnels { try model.store.remove(tunnel.id) }
            try render(LaneMenuBar(model: model), size: menuSize, scheme: .light, fitHeight: true,
                       to: output.appending(path: "menu-discovery-light.png"))
            if let session = localSession {
                try render(LaneMenuBar(model: model, previewExpandedSession: session.id), size: menuSize, scheme: .dark,
                           fitHeight: true, to: output.appending(path: "menu-discovery-dark-expanded.png"))
            }
            let icon = ImageRenderer(content: LaneGlyph(size: 822)
                .frame(width: 1024, height: 1024).environment(\.colorScheme, .light))
            if let image = icon.cgImage,
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: output.appending(path: "icon.png"))
            }
        } catch {
            NSLog("Lane: %@", error.localizedDescription)
        }
    }

    /// Use a hosting window so native text fields and buttons lay out as they do in the app.
    private static func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme,
                                              fitHeight: Bool = false, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: content
            .frame(width: size.width, height: fitHeight ? nil : size.height, alignment: .top)
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true })
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if fitHeight {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let renderSize = NSSize(width: size.width, height: ceil(view.fittingSize.height))
            window.setContentSize(renderSize)
            view.frame = NSRect(origin: .zero, size: renderSize)
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        window.close()
    }
}

/// Keeps the menu's popover open while its own disclosure controls change the content height.
private struct MenuPreviewHarness: View {
    let model: PortlaneModel
    @State private var showingMenu = false

    var body: some View {
        Button("Open Menu") { showingMenu.toggle() }
            .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                LaneMenuBar(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
    }
}
#endif
