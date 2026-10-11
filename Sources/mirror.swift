/// The mirror: a floating picture-in-picture window with a camera's picture, flipped as a mirror
/// flips, for a look at oneself before a call. It is drawn after QuickTime's picture in picture:
/// no title bar, rounded corners, a shadow, controls shown only while the pointer is over it (a
/// close cross and the camera menu), dragged by its picture and settling into the nearest
/// corner of the screen when let go, resized from its edges in the camera's proportions.
/// (macOS's own picture in picture refuses a live camera here: `isPictureInPicturePossible`
/// stays false with frames flowing, measured 2026-10-11, and it takes no custom controls.)
/// A left click on the capybara opens and closes it; the camera runs only while it is open, and
/// the window keeps its place between openings. Camera access is asked on the first opening;
/// refused, the Camera pane of System Settings opens instead.
///
/// The camera: the one chosen in the window's camera menu (kept under the defaults key
/// MIRROR_CAMERA_KEY) while it is available, otherwise the Mac's built-in camera, otherwise the
/// camera macOS prefers. The open mirror moves to the chosen camera when it appears and away
/// from any camera that disappears or fails.
import AppKit
import AVFoundation

private let MIRROR_WIDTH = 360.0
private let MIRROR_CORNER_RADIUS = 10.0
/// Gap between the window and the screen's edges in the corner it settles into.
private let MIRROR_MARGIN = 16.0
private let MIRROR_SETTLE_SECONDS = 0.2
private let MIRROR_AUTOSAVE_NAME = "capybarMirror"
private let MIRROR_CAMERA_KEY = "mirrorCamera"
private let CONTROL_SIZE = 26.0
private let CONTROL_INSET = 8.0
private let CONTROL_FADE_SECONDS = 0.15
private let CONTROL_FILL = NSColor.black.withAlphaComponent(0.55)
private let CAMERA_SETTINGS_URL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
private let CAMERA_DEVICE_TYPES: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]

/// A camera the feed runs, described in values that may cross threads.
private struct RunningCamera: Sendable {
    let uniqueID: String
    let width: Int32
    let height: Int32
}

/// The cameras connected now, in discovery order.
private func connectedCameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: CAMERA_DEVICE_TYPES, mediaType: .video, position: .unspecified).devices.filter(\.isConnected)
}

/// The cameras to try, best first, as `uniqueID`s: the chosen one, the built-in one, the one
/// macOS prefers, then any.
private func cameraCandidates() -> [String] {
    let cameras = connectedCameras()
    let chosen = UserDefaults.standard.string(forKey: MIRROR_CAMERA_KEY).flatMap { name in cameras.first { $0.localizedName == name } }
    let ordered = [chosen, cameras.first { $0.deviceType == .builtInWideAngleCamera }, AVCaptureDevice.systemPreferredCamera, cameras.first]
    var seen = Set<String>()
    return ordered.compactMap { $0?.uniqueID }.filter { seen.insert($0).inserted }
}

/// Owns the capture session and runs it on its own queue, as AVFoundation asks: starting and
/// stopping block until the camera answers. Only that queue touches the session after start.
private final class CameraFeed: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "\(BUNDLE_IDENTIFIER).mirror")

    /// Runs the first camera of `candidates` that connects and starts; each failure is logged.
    /// @param candidates `uniqueID`s, best first.
    /// @param started Runs on the main thread with the camera running, or nil when none would run.
    func start(_ candidates: [String], started: @escaping @MainActor @Sendable (RunningCamera?) -> Void) {
        queue.async { [self] in
            session.stopRunning()
            for identifier in candidates {
                guard let camera = AVCaptureDevice(uniqueID: identifier) else { continue }
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
                    session.addInput(input)
                    session.commitConfiguration()
                } catch {
                    session.commitConfiguration()
                    logFailure("mirror: camera \(camera.localizedName) could not be connected: \(error)")
                    continue
                }
                session.startRunning()
                guard session.isRunning else {
                    logFailure("mirror: camera \(camera.localizedName) connected but would not start")
                    continue
                }
                let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
                let running = RunningCamera(uniqueID: identifier, width: dimensions.width, height: dimensions.height)
                return performOnMain { started(running) }
            }
            session.inputs.forEach(session.removeInput)
            logFailure("mirror: no camera would start among \(candidates.count) tried")
            performOnMain { started(nil) }
        }
    }

    /// Stops the picture and lets the camera go, so its light goes out.
    func stop() {
        queue.async { [self] in
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
        }
    }
}

/// Builds a round control over the picture. @param symbol SF Symbol name. @param label Its tooltip and accessibility name.
@MainActor private func makeControl(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
    let button = NSButton(image: image ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.contentTintColor = .white
    button.wantsLayer = true
    button.layer?.cornerRadius = CONTROL_SIZE / 2
    button.layer?.backgroundColor = CONTROL_FILL.cgColor
    button.toolTip = label
    return button
}

/// The window's content: the picture, rounded, with its controls in the top corners while the
/// pointer is over it. Dragging the picture moves the window; letting go settles it into a corner.
private final class MirrorView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    private let closeButton: NSButton
    private let cameraButton: NSButton
    private let settle: @MainActor () -> Void
    private var dragOffset: NSPoint?

    /// @param session The session whose picture to show. @param closeButton Top left. @param cameraButton Top right.
    /// @param settle Runs when a drag ends.
    init(session: AVCaptureSession, closeButton: NSButton, cameraButton: NSButton, settle: @escaping @MainActor () -> Void) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        self.closeButton = closeButton
        self.cameraButton = cameraButton
        self.settle = settle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MIRROR_CORNER_RADIUS
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        for control in [closeButton, cameraButton] {
            control.alphaValue = 0
            addSubview(control)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("MirrorView is built in code") }

    override func layout() {
        super.layout()
        preview.frame = bounds
        let top = bounds.maxY - CONTROL_SIZE - CONTROL_INSET
        closeButton.frame = NSRect(x: CONTROL_INSET, y: top, width: CONTROL_SIZE, height: CONTROL_SIZE)
        cameraButton.frame = NSRect(x: bounds.maxX - CONTROL_SIZE - CONTROL_INSET, y: top, width: CONTROL_SIZE, height: CONTROL_SIZE)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { fadeControls(to: 1) }
    override func mouseExited(with event: NSEvent) { fadeControls(to: 0) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        dragOffset = NSPoint(x: pointer.x - window.frame.minX, y: pointer.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOffset else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pointer.x - dragOffset.x, y: pointer.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return }
        dragOffset = nil
        settle()
    }

    private func fadeControls(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CONTROL_FADE_SECONDS
            closeButton.animator().alphaValue = alpha
            cameraButton.animator().alphaValue = alpha
        }
    }
}

/// The window and its picture; one per process.
@MainActor private final class Mirror: NSObject, NSWindowDelegate {
    private let feed = CameraFeed()
    private var panel: NSPanel?
    private var view: MirrorView?
    private var running: RunningCamera?

    var isOpen: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification, AVCaptureSession.runtimeErrorNotification] {
            center.addObserver(self, selector: #selector(camerasChanged), name: name, object: nil)
        }
    }

    /// Opens the mirror, asking for camera access first when macOS has not been answered yet.
    func open() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: show()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { granted in performOnMain { granted ? mirror.show() : mirror.openCameraSettings() } }
        default: openCameraSettings()
        }
    }

    /// Closes the window and stops the camera.
    @objc func close() {
        panel?.orderOut(nil)
        running = nil
        feed.stop()
    }

    /// Lists the connected cameras under the camera button, the running one ticked.
    @objc private func showCameraMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for camera in connectedCameras() {
            let item = NSMenuItem(title: camera.localizedName, action: #selector(chooseCamera), keyEquivalent: "")
            item.target = self
            item.representedObject = camera.localizedName
            item.state = camera.uniqueID == running?.uniqueID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    /// Keeps the chosen camera for every later opening and switches the picture to it.
    @objc private func chooseCamera(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: MIRROR_CAMERA_KEY)
        show()
    }

    /// Restarts the open mirror when the best camera is no longer the one running: the chosen
    /// camera appeared, the running one went away, or the session failed.
    @objc private func camerasChanged(_ notification: Notification) {
        let isRuntimeError = notification.name == AVCaptureSession.runtimeErrorNotification
        performOnMain { [self] in
            guard isOpen else { return }
            if isRuntimeError || cameraCandidates().first != running?.uniqueID { show() }
        }
    }

    /// Settles the window into the corner of its screen nearest its centre.
    private func settleIntoCorner() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let x = frame.midX < visible.midX ? visible.minX + MIRROR_MARGIN : visible.maxX - frame.width - MIRROR_MARGIN
        let y = frame.midY < visible.midY ? visible.minY + MIRROR_MARGIN : visible.maxY - frame.height - MIRROR_MARGIN
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MIRROR_SETTLE_SECONDS
            panel.animator().setFrame(NSRect(x: x, y: y, width: frame.width, height: frame.height), display: true)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { settleIntoCorner() }

    private func openCameraSettings() {
        logFailure("mirror: camera access is refused; opening System Settings > Privacy & Security > Camera")
        NSWorkspace.shared.open(CAMERA_SETTINGS_URL)
    }

    private func show() {
        let candidates = cameraCandidates()
        guard !candidates.isEmpty else { return logFailure("mirror: no camera is connected") }
        if panel == nil { makePanel() }
        feed.start(candidates) { [weak self] camera in
            guard let self, let panel, let camera else { return }
            running = camera
            let aspect = NSSize(width: Double(camera.width), height: Double(camera.height))
            panel.contentAspectRatio = aspect
            let height = panel.frame.width * aspect.height / aspect.width
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: panel.frame.width, height: height), display: true)
            if let connection = view?.preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            panel.orderFrontRegardless()
            settleIntoCorner()
        }
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MIRROR_WIDTH, height: MIRROR_WIDTH * 9 / 16),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let view = MirrorView(session: feed.session,
                              closeButton: makeControl(symbol: "xmark", label: "Close", target: self, action: #selector(close)),
                              cameraButton: makeControl(symbol: "video.fill", label: "Camera", target: self, action: #selector(showCameraMenu)),
                              settle: { [weak self] in self?.settleIntoCorner() })
        panel.contentView = view
        if !panel.setFrameUsingName(MIRROR_AUTOSAVE_NAME), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - MIRROR_MARGIN, y: visible.maxY - MIRROR_MARGIN))
        }
        panel.setFrameAutosaveName(MIRROR_AUTOSAVE_NAME)
        self.panel = panel
        self.view = view
    }
}

@MainActor private let mirror = Mirror()

/// Answers a left click on the capybara: opens the mirror, or closes it when open.
@MainActor func toggleMirror() {
    mirror.isOpen ? mirror.close() : mirror.open()
}
