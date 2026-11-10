// The app-side neighbours of ALVRClient/EventHandler.swift, reduced to what the protocol layer touches. Where a stand-in
// replaces code whose behaviour matters (WorldTracker's tracking send, VideoHandler's decode call) it follows the real code's
// control flow line for line and names the lines it mirrors; everything else is inert.

import Foundation
import AppleShims

// MARK: - Globals the client reads

let renderWidth = Int(1888)          // MetalClientSystem.swift:26
let renderHeight = Int(1824)         // MetalClientSystem.swift:27
let defaultRefreshRate = Float(90.0) // VideoHandler.swift:17 (no AV1 hardware decoder => 90)
var refreshRate = defaultRefreshRate // VideoHandler.swift:18

// MARK: - print / exit: the client's own calls land in the harness log

/// Shadows Swift.print for the client sources compiled into this module: every line is timestamped and counted.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let line = items.map { "\($0)" }.joined(separator: separator)
    HarnessLog.shared.client(line)
}

/// Shadows Glibc.exit for the client sources: a self-exit is a finding, not the end of the harness's bookkeeping.
func exit(_ code: Int32) -> Never {
    HarnessLog.shared.event("client_exit", ["code": "\(code)"])
    HarnessLog.shared.finishAndExit(code: 42)
}

// MARK: - WorldTracker (tracking uplink only)

final class WorldTracker {
    nonisolated(unsafe) static let shared = WorldTracker()
    static let deviceIdHead: UInt64 = alvr_path_string_to_id("/user/head")
    static let deviceIdLeftHand: UInt64 = alvr_path_string_to_id("/user/hand/left")
    static let deviceIdRightHand: UInt64 = alvr_path_string_to_id("/user/hand/right")

    var leftControllerBatteryPercent: Float = 1.0
    var leftControllerBatteryIsCharging = false
    var rightControllerBatteryPercent: Float = 1.0
    var rightControllerBatteryIsCharging = false
    var leftHapticsStart = 0.0, leftHapticsEnd = 0.0
    var leftHapticsFreq: Float = 0, leftHapticsAmplitude: Float = 0
    var rightHapticsStart = 0.0, rightHapticsEnd = 0.0
    var rightHapticsFreq: Float = 0, rightHapticsAmplitude: Float = 0
    var needsRecenterTrigger = false

    func initializeAr() async {}

    /// WorldTracker.swift:3553-3580: dummy view params + one head motion, stamped with `targetTimestamp`.
    func sendFakeTracking(viewFovs: [AlvrFov], targetTimestamp: Double) {
        if viewFovs.isEmpty { return }
        let targetTimestampNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        let viewFovsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { viewFovsPtr.deallocate() }
        viewFovsPtr[0] = AlvrViewParams(pose: AlvrPose(), fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: AlvrPose(), fov: viewFovs[1])
        var motion = AlvrDeviceMotion()
        motion.device_id = WorldTracker.deviceIdHead
        alvr_send_view_params(UnsafePointer(viewFovsPtr))
        var motions = [motion]
        alvr_send_tracking(targetTimestampNS, &motions, 1, nil, nil)
        print("Sending fake tracking...")
    }

    /// WorldTracker.swift:3533-3550
    func sendViewParams(viewTransforms: [simd_float4x4], viewFovs: [AlvrFov]) {
        let p = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { p.deallocate() }
        p[0] = AlvrViewParams(pose: AlvrPose(), fov: viewFovs[0])
        p[1] = AlvrViewParams(pose: AlvrPose(), fov: viewFovs[1])
        alvr_send_view_params(UnsafePointer(p))
    }

    /// WorldTracker.swift:2578 sendTracking, reduced to its protocol effects: lastRequestedTimestamp is written on the
    /// caller's thread (:3393) and the send is enqueued on EventHandler.outgoingWorker (:3510-3514).
    func sendTracking(reportedTargetTimestamp: Double) {
        let reportedTargetTimestampNS = UInt64(reportedTargetTimestamp * Double(NSEC_PER_SEC))
        EventHandler.shared.lastRequestedTimestamp = reportedTargetTimestampNS
        EventHandler.shared.outgoingWorker.enqueue {
            var motion = AlvrDeviceMotion()
            motion.device_id = WorldTracker.deviceIdHead
            var motions = [motion]
            alvr_send_tracking_and_face_data(reportedTargetTimestampNS, &motions, 1, nil, nil, nil)
        }
    }
}

// MARK: - Inert neighbours

final class SteamControllerManager {
    enum Owner { case streaming }
    nonisolated(unsafe) static let shared = SteamControllerManager()
    func stopAll() {}
    func stop(_ o: Owner) {}
    func start(_ o: Owner) {}
}

final class InputDebugSession {
    nonisolated(unsafe) static let shared = InputDebugSession()
    func suspend() {}
    func resume() {}
}

enum Settings { static func clearSettingsCache() {} }

// MARK: - VideoHandler (decoder stand-in for a REAL stream)

/// Real HEVC / H.264 Annex B frames from client_core: nothing is decoded, the picture is a counter. The decode time is modelled.
enum RigNal {
    /// true when an Annex B buffer holds an IDR/IRAP slice (HEVC types 16...21, H.264 type 5).
    static func isIdr(_ b: UnsafeMutableBufferPointer<UInt8>, codec: Int) -> Bool {
        var i = 0
        while i + 4 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && (b[i + 2] == 1 || (b[i + 2] == 0 && b[i + 3] == 1)) {
                let h = i + (b[i + 2] == 1 ? 3 : 4)
                if h < b.count {
                    if codec == 1 { let t = (b[h] >> 1) & 0x3f; if t >= 16 && t <= 21 { return true } }
                    else if codec == 0 { if (b[h] & 0x1f) == 5 { return true } }
                }
                i = h
            } else { i += 1 }
        }
        return false
    }
    static func fnv(_ b: UnsafeMutableBufferPointer<UInt8>) -> UInt32 {
        var h: UInt32 = 2166136261
        for x in b { h = (h ^ UInt32(x)) &* 16777619 }
        return h
    }
}

struct VideoHandler {
    static func createVideoDecoder(initialNals: UnsafeMutableBufferPointer<UInt8>, codec: Int) -> (VTDecompressionSession?, CMFormatDescription?) {
        guard initialNals.count >= 8 else {
            print("format fail?! -12712")
            HarnessLog.shared.event("decoder_created_failed", ["bytes": "\(initialNals.count)"])
            return (nil, nil)
        }
        let fmt = CMFormatDescription(width: RigConfig.width, height: RigConfig.height, configId: RigNal.fnv(initialNals))
        print(fmt)
        refreshRate = EventHandler.effectiveRefreshRate(setting: "Default", negotiated: EventHandler.shared.negotiatedRefreshRate, deviceDefault: defaultRefreshRate)
        HarnessLog.shared.event("decoder_created", ["config": "\(fmt.configId)", "bytes": "\(initialNals.count)", "codec": "\(codec)"])
        return (VTDecompressionSession(format: fmt), fmt)
    }

    static func feedVideoIntoDecoder(decompressionSession: VTDecompressionSession, nals: UnsafeMutableBufferPointer<UInt8>, timestamp: UInt64, videoFormat: CMFormatDescription, codec: Int, callback: @escaping (_ imageBuffer: CVImageBuffer?) -> Void) {
        let (status, image) = HarnessDecoder.decode(session: decompressionSession, nals: nals, timestamp: timestamp, codec: codec)
        if status < 0 && EventHandler.shared.framesSinceLastIDR > Int(refreshRate) * 2 {
            EventHandler.shared.framesSinceLastIDR = 0
            EventHandler.shared.resetEncoding()
        }
        callback(image)
    }
}

enum RigConfig {
    nonisolated(unsafe) static var width = 1280
    nonisolated(unsafe) static var height = 1120
    nonisolated(unsafe) static var decodeMs = 5.0
    nonisolated(unsafe) static var decodeSdMs = 1.0
}

final class HarnessDecoder {
    nonisolated(unsafe) static var counter: UInt32 = 0
    static func gauss() -> Double {
        let u1 = Double.random(in: 1e-9..<1), u2 = Double.random(in: 0..<1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    static func decode(session: VTDecompressionSession, nals: UnsafeMutableBufferPointer<UInt8>, timestamp: UInt64, codec: Int) -> (OSStatus, CVImageBuffer?) {
        guard nals.count >= 5 else { return (kVTVideoDecoderBadDataErr, nil) }
        let isIdr = RigNal.isIdr(nals, codec: codec)
        let ms = max(0.5, RigConfig.decodeMs + RigConfig.decodeSdMs * gauss()) * (isIdr ? 2.0 : 1.0)
        usleep(UInt32(ms * 1000))
        counter &+= 1
        session.decodedCount += 1
        HarnessStats.shared.decoded(index: counter, isIdr: isIdr)
        return (noErr, CVImageBuffer(frameIndex: counter, timestamp: timestamp))
    }
}
