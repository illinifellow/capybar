/// OBS on demand: OBS runs only while some app watches "OBS Virtual Camera". The camera
/// extension stays installed without OBS, so an app opening it marks the device as running
/// somewhere; capybar then launches OBS hidden and turns its virtual camera on. OBS's own feed
/// marks the device as running as well, so the end of watching is read from the extension's
/// stream stop messages in the unified log: on each one capybar turns the virtual camera off for
/// a moment and, if the device then reads idle, quits OBS; otherwise it turns the camera back on.
import AppKit
import CoreMediaIO

private let OBS_BUNDLE_IDENTIFIER = "com.obsproject.obs-studio"
private let VIRTUAL_CAMERA_NAME = "OBS Virtual Camera"
private let OBS_START_TIMEOUT_SECONDS = 30.0

private var obsLaunching = false
private var ownStopUntil = Date.distantPast
private var logStream: Process?

/// Reads a CoreMediaIO property of a device. @returns Its value, or nil when absent.
private func cmioProperty<T>(_ object: CMIOObjectID, _ selector: Int, _ initial: T) -> T? {
    var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var value = initial
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &used, &value) == 0 else { return nil }
    return value
}

/// Whether any client streams "OBS Virtual Camera". @returns nil when the device is missing.
private func virtualCameraRunningSomewhere() -> Bool? {
    var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0 else { return nil }
    var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0 else { return nil }
    for device in devices where (cmioProperty(device, kCMIOObjectPropertyName, "" as CFString) as String?) == VIRTUAL_CAMERA_NAME {
        return cmioProperty(device, kCMIODevicePropertyDeviceIsRunningSomewhere, UInt32(0)).map { $0 != 0 }
    }
    return nil
}

private func runningObs() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: OBS_BUNDLE_IDENTIFIER).first }

/// Launches OBS hidden (tray mode, out of the Dock) and turns its virtual camera on once
/// obs-websocket answers.
private func launchObs() {
    guard !obsLaunching, runningObs() == nil else { return }
    obsLaunching = true
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-j", "-b", OBS_BUNDLE_IDENTIFIER, "--args", "--minimize-to-tray", "--disable-shutdown-check"]
    try? open.run()
    Task { @MainActor in
        let deadline = Date().addingTimeInterval(OBS_START_TIMEOUT_SECONDS)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let session = ObsSession()
            let ready = await session.open()
            session.close()
            if ready { break }
        }
        obsLaunching = false
        CameraLoopKey.shared.refresh()
    }
}

/// After a client stopped watching: checks whether anyone else still watches and quits OBS if not.
private func checkWatchers() {
    guard runningObs() != nil, !obsLaunching else { return }
    Task { @MainActor in
        let session = ObsSession()
        guard await session.open() else { return }
        ownStopUntil = Date().addingTimeInterval(2)
        await session.request("StopVirtualCam")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if virtualCameraRunningSomewhere() == true {
            await session.request("StartVirtualCam")
            session.close()
            return
        }
        session.close()
        // terminate() asks OBS to quit through Apple Events, which OBS answers with a refusal; SIGTERM runs its normal shutdown.
        if let pid = runningObs()?.processIdentifier { kill(pid, SIGTERM) }
    }
}

/// Starts watching: a one-second poll for a client while OBS is down, and the extension's log for
/// stream stops while it is up.
func startObsOnDemand() {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        if runningObs() == nil, virtualCameraRunningSomewhere() == true { launchObs() }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["stream", "--style", "compact", "--predicate", "process CONTAINS \"camera-extension\" AND eventMessage CONTAINS \"stopStream release\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let text = String(decoding: handle.availableData, as: UTF8.self)
        guard text.contains("stopStream release") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard Date() > ownStopUntil else { return }
            checkWatchers()
        }
    }
    try? process.run()
    logStream = process
}
