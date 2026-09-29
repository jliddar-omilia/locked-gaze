import AppKit
import AVFoundation
import CoreImage
import CoreVideo

struct PreviewFrame {
    let original: CGImage
    let corrected: CGImage
    let status: String
}

// Convert while the pool buffers are retained; only the newest display frame waits.
final class PreviewRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ original: CVPixelBuffer, _ corrected: CVPixelBuffer, status: String) -> PreviewFrame? {
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(original), height: CVPixelBufferGetHeight(original))
        guard let left = context.createCGImage(CIImage(cvPixelBuffer: original), from: rect),
              let right = context.createCGImage(CIImage(cvPixelBuffer: corrected), from: rect) else { return nil }
        return PreviewFrame(original: left, corrected: right, status: status)
    }
}

@MainActor
final class PreviewApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let original = NSImageView()
    private let corrected = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "Choose a camera, then click Start Preview. Your video stays on this Mac.")
    private let cameras = NSPopUpButton()
    private let toggle = NSButton(title: "Start Preview", target: nil, action: nil)
    private let correction = NSButton(checkboxWithTitle: "Eye-contact correction", target: nil, action: nil)
    private let renderer = PreviewRenderer()
    private var closing = false
    private var frameCount = 0
    private var intervalStart = ProcessInfo.processInfo.systemUptime
    private var fps = 0.0
    private lazy var display = LatestFrameWorker<PreviewFrame>(queue: .main) { [weak self] frame in
        MainActor.assumeIsolated { self?.present(frame) }
    }
    private lazy var camera: CameraSession = {
        let renderer = self.renderer
        let display = self.display
        return CameraSession(preview: { input, output, status in
            if let frame = renderer.render(input, output, status: status) { display.submit(frame) }
        })
    }()
    private lazy var lifecycle = CameraLifecycle(prepare: {}, start: { [unowned self] in
        guard let models = Bundle.main.resourceURL?.appendingPathComponent("Models") else {
            throw GazeError.message("Model resources are missing. Rebuild the preview.")
        }
        self.display.begin()
        self.frameCount = 0
        self.fps = 0
        self.intervalStart = ProcessInfo.processInfo.systemUptime
        try await self.camera.start(models: models, sourceID: self.cameras.selectedItem?.representedObject as? String)
    }, stop: { [unowned self] in
        self.display.stop()
        await self.camera.stop()
        // Drain any already-scheduled main-queue display before a later begin().
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        self.original.image = nil
        self.corrected.image = nil
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Locked Gaze Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Locked Gaze — Local Preview"
        window.minSize = NSSize(width: 780, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Locked Gaze · Local Preview")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Compare your original camera feed with eye-contact correction. Nothing is recorded or uploaded.")
        subtitle.textColor = .secondaryLabelColor
        cameras.addItem(withTitle: "Automatic (System Preferred)")
        for device in CameraSession.availableCameras() {
            cameras.addItem(withTitle: device.localizedName)
            cameras.lastItem?.representedObject = device.uniqueID
        }
        cameras.toolTip = "Stop preview to change the source camera."
        cameras.setAccessibilityLabel("Source camera")
        toggle.target = self; toggle.action = #selector(togglePreview)
        correction.state = .on
        correction.target = self; correction.action = #selector(changeCorrection)
        let controls = NSStackView(views: [cameras, toggle, correction])
        controls.spacing = 16
        let images = NSStackView(views: [pane("Original", view: original), pane("Correction preview", view: corrected)])
        images.distribution = .fillEqually; images.spacing = 16
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.setAccessibilityLabel("Preview status")
        let footer = NSTextField(labelWithString: "Local preview only — this does not create a camera in Zoom or Teams.")
        footer.textColor = .secondaryLabelColor; footer.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, subtitle, controls, images, status, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            images.widthAnchor.constraint(equalTo: stack.widthAnchor),
            images.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        lifecycle.onChange = { [weak self] in self?.refresh() }
        camera.onFailure = { [weak self] error in
            guard let self else { return }
            Task { if await self.lifecycle.failed(error) { self.status.stringValue = error.localizedDescription } }
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.async { self.smokeTest() }
        }
    }

    private func pane(_ title: String, view: NSImageView) -> NSView {
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.black.cgColor
        view.setAccessibilityLabel(title)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func present(_ frame: PreviewFrame) {
        guard !closing else { return }
        original.image = NSImage(cgImage: frame.original, size: .zero)
        corrected.image = NSImage(cgImage: frame.corrected, size: .zero)
        frameCount += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - intervalStart
        if elapsed >= 1 { fps = Double(frameCount) / elapsed; frameCount = 0; intervalStart = ProcessInfo.processInfo.systemUptime }
        status.stringValue = String(format: "%.1f fps · %@", fps, frame.status)
    }

    private func refresh() {
        let state = lifecycle.state
        toggle.isEnabled = !closing && (state == .idle || state == .active)
        cameras.isEnabled = !closing && state == .idle
        switch state {
        case .idle: toggle.title = "Start Preview"; status.stringValue = "Stopped. Camera released."
        case .starting: toggle.title = "Starting…"; status.stringValue = "Loading models and opening camera…"
        case .active: toggle.title = "Stop Preview"; status.stringValue = "Waiting for camera frames…"
        case .stopping: toggle.title = "Stopping…"; status.stringValue = "Releasing camera…"
        }
    }
    @objc private func togglePreview() {
        let enabled = lifecycle.state == .idle
        Task {
            do { try await lifecycle.setEnabled(enabled) }
            catch { if !closing { status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func changeCorrection() { camera.setPreviewCorrection(correction.state == .on) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closing else { return .terminateLater }
        closing = true; refresh()
        Task { await lifecycle.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // Exercises real models + native processing + both image views, without opening a camera.
    private func smokeTest() {
        do {
            let models = try ModelStore(directory: Bundle.main.resourceURL!.appendingPathComponent("Models"))
            let pipeline = LGFramePipeline(models: models)
            func buffer() throws -> CVPixelBuffer {
                var value: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess, let value else {
                    throw GazeError.message("Synthetic buffer allocation failed")
                }
                CVPixelBufferLockBaseAddress(value, [])
                memset(CVPixelBufferGetBaseAddress(value), 0, CVPixelBufferGetDataSize(value))
                CVPixelBufferUnlockBaseAddress(value, [])
                return value
            }
            let input = try buffer(), output = try buffer()
            try pipeline.processPixelBuffer(input, into: output)
            guard let frame = renderer.render(input, output, status: pipeline.lastStatus) else {
                throw GazeError.message("Preview rendering failed")
            }
            present(frame)
            precondition(original.image != nil && corrected.image != nil)
            precondition(pipeline.lastStatus == "bypass")
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            precondition(window.frame.width <= 1120, "Frame images must not expand the window")
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw GazeError.message("Cannot capture synthetic preview layout")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/locked-gaze-preview-smoke.png"))
            }
            print("PASS: preview model loading, synthetic native processing, two image views, no camera or extension")
            fflush(stdout)
            NSApp.terminate(nil)
        } catch { fputs("Preview smoke test failed: \(error)\n", stderr); exit(1) }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = PreviewApp()
    application.delegate = delegate
    application.run()
}
