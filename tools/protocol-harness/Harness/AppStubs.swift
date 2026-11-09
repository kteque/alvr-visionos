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

// MARK: - VideoHandler (decoder stand-in)

/// The harness's NAL layout (FakeCore writes it): start code, NAL type byte (0x26 IDR, 0x02 P), config id, frame index.
enum FakeNal {
    static let idrType: UInt8 = 0x26
    static let pType: UInt8 = 0x02
    static let configType: UInt8 = 0x40

    static func frame(isIdr: Bool, configId: UInt32, index: UInt32) -> [UInt8] {
        [0, 0, 0, 1, isIdr ? idrType : pType] + le(configId) + le(index)
    }
    static func config(configId: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
        [0, 0, 0, 1, configType] + le(configId) + le(width) + le(height)
    }
    static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    static func readLe(_ b: UnsafeMutableBufferPointer<UInt8>, _ at: Int) -> UInt32 {
        guard b.count >= at + 4 else { return 0 }
        return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}

struct VideoHandler {
    /// VideoHandler.swift:125-194: a session per config; nil (and a "format fail" line) when the config bytes are unusable.
    static func createVideoDecoder(initialNals: UnsafeMutableBufferPointer<UInt8>, codec: Int) -> (VTDecompressionSession?, CMFormatDescription?) {
        guard initialNals.count >= 17, initialNals[4] == FakeNal.configType else {
            print("format fail?! -12712")
            HarnessLog.shared.event("decoder_create_failed", ["bytes": "\(initialNals.count)"])
            return (nil, nil)
        }
        let fmt = CMFormatDescription(width: Int(FakeNal.readLe(initialNals, 9)), height: Int(FakeNal.readLe(initialNals, 13)),
                                      configId: FakeNal.readLe(initialNals, 5))
        print(fmt)
        // VideoHandler.swift:185 applyRefreshRate (HARNESS_OLD_RATE=1: the 1.3.6 behaviour, the device default whatever the stream negotiated)
        refreshRate = ProcessInfo.processInfo.environment["HARNESS_OLD_RATE"] == "1" ? defaultRefreshRate
            : EventHandler.effectiveRefreshRate(setting: "Default", negotiated: EventHandler.shared.negotiatedRefreshRate, deviceDefault: defaultRefreshRate)
        HarnessLog.shared.event("decoder_created", ["config": "\(fmt.configId)", "size": "\(fmt.width)x\(fmt.height)"])
        return (VTDecompressionSession(format: fmt), fmt)
    }

    /// VideoHandler.swift:592-625. The VideoToolbox call is synchronous (flags 0): the output handler runs before
    /// VTDecompressionSessionDecodeFrame returns, on the caller's thread (client_core's video receive thread).
    static func feedVideoIntoDecoder(decompressionSession: VTDecompressionSession, nals: UnsafeMutableBufferPointer<UInt8>, timestamp: UInt64, videoFormat: CMFormatDescription, codec: Int, callback: @escaping (_ imageBuffer: CVImageBuffer?) -> Void) {
        let (status, image) = HarnessDecoder.decode(session: decompressionSession, nals: nals, timestamp: timestamp)

        // If the decoder is failing somehow, request an IDR and get back on track (VideoHandler.swift:609-618)
        if status < 0 && EventHandler.shared.framesSinceLastIDR > Int(refreshRate) * 2 {
            EventHandler.shared.framesSinceLastIDR = 0
            EventHandler.shared.resetEncoding()
        }
        callback(image)
    }
}

/// How the stand-in decoder behaves (scenario knobs).
final class HarnessDecoder {
    nonisolated(unsafe) static var pFrameMs = 4.0
    nonisolated(unsafe) static var idrFrameMs = 12.0
    /// true: a P frame whose reference was never decoded fails (status < 0, no picture), like VideoToolbox on a broken chain
    nonisolated(unsafe) static var strictReferences = true
    /// true: every decode fails until the next connection (a decoder the client cannot fix by itself)
    nonisolated(unsafe) static var broken = false

    static func decode(session: VTDecompressionSession, nals: UnsafeMutableBufferPointer<UInt8>, timestamp: UInt64) -> (OSStatus, CVImageBuffer?) {
        guard nals.count >= 13 else { return (kVTVideoDecoderBadDataErr, nil) }
        let isIdr = nals[4] == FakeNal.idrType
        let configId = FakeNal.readLe(nals, 5)
        let index = FakeNal.readLe(nals, 9)
        usleep(UInt32((isIdr ? idrFrameMs : pFrameMs) * 1000))

        var status: OSStatus = noErr
        if broken {
            status = kVTVideoDecoderBadDataErr
        } else if session.invalidated {
            status = kVTInvalidSessionErr
        } else if configId != session.format.configId {
            status = kVTVideoDecoderBadDataErr // a frame of another stream configuration fed to the old session
        } else if !isIdr && strictReferences && (session.lastDecodedIndex.map { $0 &+ 1 != index } ?? true) {
            status = kVTVideoDecoderBadDataErr // reference picture missing
        }
        if status != noErr {
            session.errorCount += 1
            HarnessStats.shared.decodeError(status: status)
            return (status, nil)
        }
        session.lastDecodedIndex = index
        session.decodedCount += 1
        HarnessStats.shared.decoded(index: index, isIdr: isIdr)
        return (noErr, CVImageBuffer(frameIndex: index, timestamp: timestamp))
    }
}
