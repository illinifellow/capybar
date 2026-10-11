/// The mirror: a floating picture-in-picture window with the current camera's picture, flipped
/// as a mirror flips, for a look at oneself before a call. A left click on the capybara opens
/// and closes it; the camera runs only while it is open. The camera is the one macOS prefers
/// (`AVCaptureDevice.systemPreferredCamera`, the last one chosen in any app, Continuity Camera
/// included). The window floats over every app and Space, is dragged by its picture and keeps
/// its place between openings. Camera access is asked on the first opening; refused, the
/// Camera pane of System Settings opens instead.
import AppKit
import AVFoundation

private let MIRROR_WIDTH = 360.0
private let MIRROR_CORNER_RADIUS = 12.0
/// Gap between the window and the menu bar or the screen's right edge on the first opening.
private let MIRROR_MARGIN = 12.0
private let MIRROR_AUTOSAVE_NAME = "capybarMirror"
private let CAMERA_SETTINGS_URL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

/// Owns the capture session and runs it on its own queue, as AVFoundation asks: starting and
/// stopping block until the camera answers. Only that queue touches the session after start.
private final class CameraFeed: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "\(BUNDLE_IDENTIFIER).mirror")

    /// Connects the camera and starts the picture.
    /// @param cameraIdentifier `uniqueID` of the device to show.
    /// @param started Runs on the main thread once the picture runs, with false when the camera could not be connected.
    func start(_ cameraIdentifier: String, started: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let camera = AVCaptureDevice(uniqueID: cameraIdentifier) else {
                logFailure("mirror: camera \(cameraIdentifier) is gone")
                return performOnMain { started(false) }
            }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                logFailure("mirror: camera \(camera.localizedName) could not be connected: \(error)")
                return performOnMain { started(false) }
            }
            session.commitConfiguration()
            session.startRunning()
            performOnMain { started(true) }
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

/// The window and its picture; one per process.
@MainActor private final class Mirror {
    private let feed = CameraFeed()
    private var panel: NSPanel?

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Opens the mirror on the current camera, asking for camera access first when macOS has not been answered yet.
    func open() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: show()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { granted in performOnMain { granted ? mirror.show() : mirror.openCameraSettings() } }
        default: openCameraSettings()
        }
    }

    /// Closes the window and stops the camera.
    func close() {
        panel?.orderOut(nil)
        feed.stop()
    }

    private func openCameraSettings() {
        logFailure("mirror: camera access is refused; opening System Settings > Privacy & Security > Camera")
        NSWorkspace.shared.open(CAMERA_SETTINGS_URL)
    }

    private func show() {
        guard let camera = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) else {
            return logFailure("mirror: no camera is connected")
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let aspect = NSSize(width: Double(dimensions.width), height: Double(dimensions.height))
        panel.contentAspectRatio = aspect
        let height = panel.frame.width * aspect.height / aspect.width
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: panel.frame.width, height: height), display: false)
        feed.start(camera.uniqueID) { [weak self] running in
            guard running, let panel = self?.panel, let layer = panel.contentView?.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer,
                  let connection = layer.connection else { return }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MIRROR_WIDTH, height: MIRROR_WIDTH * 9 / 16),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = MIRROR_CORNER_RADIUS
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: feed.session)
        preview.videoGravity = .resizeAspectFill
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(preview)
        panel.contentView = content
        preview.frame = content.bounds
        if !panel.setFrameUsingName(MIRROR_AUTOSAVE_NAME), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - MIRROR_MARGIN, y: visible.maxY - MIRROR_MARGIN))
        }
        panel.setFrameAutosaveName(MIRROR_AUTOSAVE_NAME)
        return panel
    }
}

@MainActor private let mirror = Mirror()

/// Answers a left click on the capybara: opens the mirror, or closes it when open.
@MainActor func toggleMirror() {
    mirror.isOpen ? mirror.close() : mirror.open()
}
