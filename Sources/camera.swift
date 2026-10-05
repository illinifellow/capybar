/// Camera loop through OBS: OBS runs hidden with its virtual camera on, showing the scene
/// CAMERA_SCENE_NAME with the live camera input LIVE_INPUT_NAME and, above it, the media input
/// LOOP_INPUT_NAME, normally hidden. Pressing the microphone key starts an OBS recording of the
/// live picture into LOOP_DIRECTORY. Released after a long press, the recording stops and plays
/// in a loop over the live camera, so every app using "OBS Virtual Camera" sees it; released
/// after a short one, the recording is thrown away. While the loop plays, the next long press of
/// any length is ignored and a quick double press deletes it, bringing the live picture back. Talks to obs-websocket v5 on
/// OBS_WEBSOCKET_URL with the password from the login keychain (service KEYCHAIN_SERVICE,
/// account KEYCHAIN_ACCOUNT).
import AppKit
import AVFoundation
import CryptoKit

private let OBS_WEBSOCKET_URL = URL(string: "ws://127.0.0.1:4455")!
private let CAMERA_SCENE_NAME = "Scene"
private let LIVE_INPUT_NAME = "capybar camera"
private let LOOP_INPUT_NAME = "capybar loop"
private let LOOP_CROSSFADE_SECONDS = 0.5
private let KEYCHAIN_SERVICE = "capybar"
private let KEYCHAIN_ACCOUNT = "obs-websocket-password"
private let LOOP_DIRECTORY = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/capybar/loops")

/// Reads the obs-websocket password from the login keychain. @returns It, or nil when absent.
private func obsWebsocketPassword() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

/// A short-lived obs-websocket v5 session: connects, authenticates, sends requests in order and
/// closes. Errors are printed to stderr.
final class ObsSession {
    private let task = URLSession.shared.webSocketTask(with: OBS_WEBSOCKET_URL)
    private var requestNumber = 0

    /// Connects and identifies. @returns Whether the session is ready for requests.
    func open() async -> Bool {
        task.resume()
        guard let hello = await receive(), let data = hello["d"] as? [String: Any] else { return false }
        var identify: [String: Any] = ["rpcVersion": 1]
        if let authentication = data["authentication"] as? [String: String], let challenge = authentication["challenge"], let salt = authentication["salt"] {
            guard let password = obsWebsocketPassword() else { report("obs-websocket password missing in the keychain"); return false }
            let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
            identify["authentication"] = Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
        }
        await send(["op": 1, "d": identify])
        return await receive()?["op"] as? Int == 2
    }

    /// Sends one request and waits for its response. @returns The response data, or nil on failure.
    @discardableResult
    func request(_ type: String, _ data: [String: Any] = [:]) async -> [String: Any]? {
        requestNumber += 1
        let identifier = "capybar-\(requestNumber)"
        await send(["op": 6, "d": ["requestType": type, "requestId": identifier, "requestData": data]])
        while let message = await receive() {
            guard message["op"] as? Int == 7, let body = message["d"] as? [String: Any], body["requestId"] as? String == identifier else { continue }
            if let status = body["requestStatus"] as? [String: Any], status["result"] as? Bool != true {
                report("obs \(type) failed: \(status["comment"] ?? status["code"] ?? "")")
                return nil
            }
            return body["responseData"] as? [String: Any] ?? [:]
        }
        return nil
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    private func send(_ object: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }

    private func receive() async -> [String: Any]? {
        guard case .string(let text)? = try? await task.receive() else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func report(_ message: String) { FileHandle.standardError.write("\(message)\n".data(using: .utf8)!) }
}

/// Makes sure the scene holds the live camera (the first real camera, never OBS's own virtual one)
/// and the hidden loop player, both stretched to the canvas, and that recordings land in
/// LOOP_DIRECTORY.
/// @param session An open session. @returns The scene item id of the loop player, or nil.
private func prepareScene(_ session: ObsSession) async -> Int? {
    let inputs = (await session.request("GetInputList"))?["inputs"] as? [[String: Any]] ?? []
    let names = Set(inputs.compactMap { $0["inputName"] as? String })
    if !names.contains(LIVE_INPUT_NAME) {
        await session.request("CreateInput", ["sceneName": CAMERA_SCENE_NAME, "inputName": LIVE_INPUT_NAME, "inputKind": "macos-avcapture", "inputSettings": [:], "sceneItemEnabled": true])
    }
    let liveSettings = (await session.request("GetInputSettings", ["inputName": LIVE_INPUT_NAME]))?["inputSettings"] as? [String: Any] ?? [:]
    if (liveSettings["device"] as? String ?? "").isEmpty {
        let devices = (await session.request("GetInputPropertiesListPropertyItems", ["inputName": LIVE_INPUT_NAME, "propertyName": "device"]))?["propertyItems"] as? [[String: Any]] ?? []
        if let camera = devices.first(where: { !($0["itemValue"] as? String ?? "").isEmpty && !($0["itemName"] as? String ?? "").contains("OBS") }) {
            await session.request("SetInputSettings", ["inputName": LIVE_INPUT_NAME, "inputSettings": ["device": camera["itemValue"]!]])
        }
    }
    if !names.contains(LOOP_INPUT_NAME) {
        await session.request("CreateInput", ["sceneName": CAMERA_SCENE_NAME, "inputName": LOOP_INPUT_NAME, "inputKind": "ffmpeg_source", "inputSettings": ["is_local_file": true, "looping": true, "restart_on_activate": true, "close_when_inactive": true], "sceneItemEnabled": false])
    }
    if (await session.request("GetVirtualCamStatus"))?["outputActive"] as? Bool != true { await session.request("StartVirtualCam") }
    try? FileManager.default.createDirectory(at: LOOP_DIRECTORY, withIntermediateDirectories: true)
    await session.request("SetProfileParameter", ["parameterCategory": "SimpleOutput", "parameterName": "FilePath", "parameterValue": LOOP_DIRECTORY.path])
    guard let video = await session.request("GetVideoSettings"), let width = video["baseWidth"], let height = video["baseHeight"] else { return nil }
    let canvas: [String: Any] = ["positionX": 0, "positionY": 0, "alignment": 5, "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsAlignment": 0, "boundsWidth": width, "boundsHeight": height]
    for name in [LIVE_INPUT_NAME, LOOP_INPUT_NAME] {
        if let item = (await session.request("GetSceneItemId", ["sceneName": CAMERA_SCENE_NAME, "sourceName": name]))?["sceneItemId"] as? Int {
            await session.request("SetSceneItemTransform", ["sceneName": CAMERA_SCENE_NAME, "sceneItemId": item, "sceneItemTransform": canvas])
            if name == LOOP_INPUT_NAME { return item }
        }
    }
    return nil
}

/// Stops the recording. OBS refuses StopRecord while a recording is still starting, so a very
/// short press retries for up to two seconds. @returns The recorded file, or nil.
private func stopRecording(_ session: ObsSession) async -> String? {
    for _ in 0..<20 {
        if let path = (await session.request("StopRecord"))?["outputPath"] as? String { return path }
        if (await session.request("GetRecordStatus"))?["outputActive"] as? Bool == false { return nil }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return nil
}

/// OBS answers StopRecord before its writer has flushed the file; waits (at most three seconds)
/// until the file has a size that holds for a tenth of a second.
private func waitUntilWritten(_ path: String) async {
    var previous: UInt64 = 0
    for _ in 0..<30 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        if size > 0 && size == previous { return }
        previous = size
    }
}

/// Makes a recording loop without a visible seam: the clip starts LOOP_CROSSFADE_SECONDS in, and
/// its last LOOP_CROSSFADE_SECONDS fade into its own first ones, so the last frame leads straight
/// into the first. Clips shorter than four fades are returned as they are.
/// @param path The finished recording. @returns The seamless file next to it, or `path` on failure.
private func makeSeamless(_ path: String) async -> String {
    let source = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let duration = try? await source.load(.duration), let track = try? await source.loadTracks(withMediaType: .video).first,
          let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) else { return path }
    let fade = CMTime(seconds: LOOP_CROSSFADE_SECONDS, preferredTimescale: 600)
    guard duration.seconds >= LOOP_CROSSFADE_SECONDS * 4 else { return path }
    let composition = AVMutableComposition()
    guard let body = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let head = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return path }
    let length = duration - fade
    let fadeStart = length - fade
    do {
        try body.insertTimeRange(CMTimeRange(start: fade, end: duration), of: track, at: .zero)
        try head.insertTimeRange(CMTimeRange(start: .zero, duration: fade), of: track, at: fadeStart)
    } catch { return path }
    let bodyLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: body)
    bodyLayer.setTransform(transform, at: .zero)
    bodyLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: fadeStart, duration: fade))
    let headLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: head)
    headLayer.setTransform(transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: length)
    instruction.layerInstructions = [bodyLayer, headLayer]
    let video = AVMutableVideoComposition()
    video.instructions = [instruction]
    video.renderSize = size
    video.frameDuration = CMTime(value: 1, timescale: 30)
    let output = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("seamless.mov")
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return path }
    export.videoComposition = video
    do { try await export.export(to: output, as: .mov) } catch { return path }
    return output.path
}

/// Hides the loop player, detaches its file and deletes every recording in LOOP_DIRECTORY.
private func discardLoop(_ session: ObsSession, loopItem: Int) async {
    await session.request("SetSceneItemEnabled", ["sceneName": CAMERA_SCENE_NAME, "sceneItemId": loopItem, "sceneItemEnabled": false])
    await session.request("SetInputSettings", ["inputName": LOOP_INPUT_NAME, "inputSettings": ["local_file": ""]])
    for file in (try? FileManager.default.contentsOfDirectory(at: LOOP_DIRECTORY, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: file)
    }
}

/// The OBS side of one press of the microphone key. Steps run one after another, each over its
/// own obs-websocket session, so a release always finds the recording its press started.
@MainActor
final class CameraLoopKey {
    static let shared = CameraLoopKey()
    private var queue: Task<Void, Never>?
    private var loopWasShowing = false
    /// Whether the loop is on the virtual camera, as last learnt from OBS; read by the key handler
    /// to tell a double press that clears the loop from a press that toggles the microphone.
    private(set) var loopShowing = false
    private var recordingStarted = false

    private func enqueue(_ step: @escaping @MainActor (ObsSession, Int) async -> Void, completion: @escaping () -> Void = {}) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            let session = ObsSession()
            if await session.open(), let loopItem = await prepareScene(session) { await step(session, loopItem) }
            session.close()
            completion()
        }
    }

    /// The key went down: notes whether a loop is playing and, if none is, starts recording.
    func pressed() {
        enqueue { [self] session, loopItem in
            let state = await session.request("GetSceneItemEnabled", ["sceneName": CAMERA_SCENE_NAME, "sceneItemId": loopItem])
            loopWasShowing = state?["sceneItemEnabled"] as? Bool ?? false
            loopShowing = loopWasShowing
            recordingStarted = false
            if !loopWasShowing {
                if (await session.request("GetRecordStatus"))?["outputActive"] as? Bool == true { _ = await stopRecording(session) }
                await discardLoop(session, loopItem: loopItem)
                recordingStarted = await session.request("StartRecord") != nil
            }
        }
    }

    /// The key came up. After a long press the fresh recording plays in a loop; after a short one
    /// it is thrown away. Nothing happens while a loop was already playing.
    /// @param long Whether the key was held for at least LONG_PRESS_SECONDS.
    /// @param completion Called on the main thread once OBS answered or the attempt failed.
    func released(long: Bool, completion: @escaping () -> Void = {}) {
        enqueue({ [self] session, loopItem in
            guard !loopWasShowing, recordingStarted else { return }
            let path = await stopRecording(session)
            if let path { await waitUntilWritten(path) }
            guard long, let path else { await discardLoop(session, loopItem: loopItem); return }
            let loop = await makeSeamless(path)
            await session.request("SetInputSettings", ["inputName": LOOP_INPUT_NAME, "inputSettings": ["local_file": loop]])
            await session.request("SetSceneItemEnabled", ["sceneName": CAMERA_SCENE_NAME, "sceneItemId": loopItem, "sceneItemEnabled": true])
            await session.request("TriggerMediaInputAction", ["inputName": LOOP_INPUT_NAME, "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART"])
            loopShowing = true
        }, completion: completion)
    }

    /// A double press while the loop plays: deletes it and brings the live picture back.
    /// @param completion Called on the main thread once OBS answered or the attempt failed.
    func clearLoop(completion: @escaping () -> Void = {}) {
        enqueue({ [self] session, loopItem in
            await discardLoop(session, loopItem: loopItem)
            loopShowing = false
        }, completion: completion)
    }

    /// Learns from OBS whether a loop is playing (at capybar start).
    func refresh() {
        enqueue { [self] session, loopItem in
            loopShowing = (await session.request("GetSceneItemEnabled", ["sceneName": CAMERA_SCENE_NAME, "sceneItemId": loopItem]))?["sceneItemEnabled"] as? Bool ?? false
        }
    }
}
