// A stand-in for alvr_client_core (ALVR v20.14.1, ALVR/alvr/client_core) plus a scripted streamer behind it.
//
// The C entry points the client calls are exported under their real names (@_cdecl), so ALVRClient/EventHandler.swift
// links against them unchanged. What matters for transitions is modelled on the real code:
//   - the video receive thread (client_core/src/connection.rs:317-367): IDR clears the corrupted flag, loss sets it and
//     requests an IDR, a `false` from the decoder callback sets it and requests an IDR; the callback runs on that thread
//     while the core holds its decoder_callback mutex, so a slow callback stalls packet draining;
//   - the unread-packet cap (MAX_UNREAD_PACKETS = 10, connection.rs:64): overflow is packet loss;
//   - set_decoder_input_callback requests an IDR (lib.rs:343-346);
//   - report_fatal_decoder_error tears the connection down (lib.rs:358-363), StreamingStopped follows, then the
//     streamer reconnects (StreamingStarted + DecoderConfig again).
// The streamer side (frame cadence, timestamps, IDRs on request) is a script: see Scenario in main.swift.

import Foundation
import AppleShims

// MARK: - Log and stats

final class HarnessLog: @unchecked Sendable {
    static let shared = HarnessLog()
    private let lock = NSLock()
    private var out: FileHandle? = nil
    let t0 = CACurrentMediaTime()
    var echo = false
    var onFinish: (() -> Void)? = nil

    func open(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        out = FileHandle(forWritingAtPath: path)
    }
    func now() -> Double { CACurrentMediaTime() - t0 }
    private func write(_ s: String) {
        lock.lock()
        out?.write((s + "\n").data(using: .utf8)!)
        if echo { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        lock.unlock()
    }
    func client(_ line: String) {
        HarnessStats.shared.clientLine(line)
        write(String(format: "%9.3f client  ", now()) + line)
    }
    func event(_ name: String, _ fields: [String: String] = [:]) {
        HarnessStats.shared.count(name)
        let f = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        write(String(format: "%9.3f harness ", now()) + name + (f.isEmpty ? "" : " " + f))
    }
    func finishAndExit(code: Int32) -> Never {
        onFinish?()
        lock.lock()
        try? out?.synchronize()
        lock.unlock()
        Glibc.exit(code)
    }
}

final class HarnessStats: @unchecked Sendable {
    static let shared = HarnessStats()
    let lock = NSLock()
    var counters: [String: Int] = [:]
    var clientCounters: [String: Int] = [:]
    var decodeErrors: [Int32: Int] = [:]
    var lastDecodedIndex: UInt32 = 0
    var decodedFrames = 0
    var decodedIdrs = 0

    /// client lines worth counting: (counter, prefix)
    static let clientPatterns: [(String, String)] = [
        ("handle_spike", "Handle spike!"), ("request_idr_5s", "Request IDR"), ("kick_alvr", "Kick ALVR"),
        ("force_reset_decoder", "Force reset decoder"), ("resetting_encoder", "Resetting encoder"),
        ("decode_overrun", "Handle decode overrun"), ("app_background_exit", "App in background"),
        ("event_thread_mia", "Event thread is MIA"), ("create_decoder", "create decoder"),
        ("streaming_started", "streaming started"), ("streaming_stopped", "streaming stopped"),
        ("format_fail", "format fail"), ("bad_view_params", "aaaaaaaa bad view params"),
    ]

    func clientLine(_ line: String) {
        lock.lock()
        for (k, p) in HarnessStats.clientPatterns where line.hasPrefix(p) { clientCounters[k, default: 0] += 1 }
        lock.unlock()
    }
    func count(_ name: String, by n: Int = 1) { lock.lock(); counters[name, default: 0] += n; lock.unlock() }
    func get(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[name] ?? 0 }
    func getClient(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return clientCounters[name] ?? 0 }
    func decodeError(status: Int32) { lock.lock(); decodeErrors[status, default: 0] += 1; lock.unlock() }
    func decoded(index: UInt32, isIdr: Bool) {
        lock.lock()
        decodedFrames += 1
        if isIdr { decodedIdrs += 1 }
        lastDecodedIndex = index
        lock.unlock()
    }
}

// MARK: - The core

struct HostFrame {
    let index: UInt32
    let timestamp: UInt64
    let isIdr: Bool
    let configId: UInt32
    var lossBefore: Bool
}

final class FakeCore: @unchecked Sendable {
    static let shared = FakeCore()

    let lock = NSCondition()
    var events: [AlvrEvent] = []
    var callback: (@convention(c) (AlvrVideoFrameData) -> Bool)? = nil
    var initialized = false
    var resumed = false

    // connection
    enum Conn { case idle, streaming, disconnecting }
    var conn: Conn = .idle
    var reconnectDelay = 1.5
    var reconnects = 0

    // stream configuration the streamer currently encodes
    var configId: UInt32 = 1
    var width: UInt32 = 3552
    var height: UInt32 = 3200
    var hudMessage = "ALVR 20.14.1\nhostname: harness\nIP: 127.0.0.1\nThe stream will begin soon\nPlease wait...\n"

    // IDR requests from the client side of the core (loss, saturation, callback install)
    var idrRequested = true
    var idrRequestTimes: [Double] = []

    // the receive queue between the network and the video thread
    var rxQueue: [HostFrame] = []
    let rxCap = 10 // MAX_UNREAD_PACKETS
    var avoidVideoGlitching = false

    // tracking uplink as the streamer sees it: (arrival time, target timestamp)
    var tracking: [(Double, UInt64)] = []
    var viewParamsCount = 0

    // statistics the client reports
    var framesDecodedReported = 0
    var compositorStarts = 0
    var submits = 0
    var lastSubmitTs: UInt64 = 0

    private var videoThread: Thread? = nil

    func push(_ e: AlvrEvent) {
        lock.lock(); events.append(e); lock.unlock()
    }

    func requestIdr(_ why: String) {
        lock.lock()
        idrRequested = true
        idrRequestTimes.append(HarnessLog.shared.now())
        lock.unlock()
        HarnessLog.shared.event("idr_request", ["why": why])
    }

    // MARK: streamer -> client

    /// connection.rs:229 + :507-512: StreamingStarted, then DecoderConfig.
    var refreshRateHint: Float = 90

    func startStreaming() {
        lock.lock()
        guard conn != .streaming else { lock.unlock(); return }
        conn = .streaming
        rxQueue.removeAll()
        idrRequested = true
        lock.unlock()
        var s = AlvrEvent()
        s.STREAMING_STARTED = StreamingStarted_Body(tag: AlvrEvent_Tag(ALVR_EVENT_STREAMING_STARTED.rawValue), view_width: width, view_height: height,
                                                    refresh_rate_hint: refreshRateHint, encoding_gamma: 1.5, enable_foveated_encoding: true, enable_hdr: false)
        push(s)
        sendDecoderConfig()
        HarnessLog.shared.event("host_streaming_started", ["config": "\(configId)"])
        startVideoThread()
    }

    func sendDecoderConfig() {
        var d = AlvrEvent()
        d.DECODER_CONFIG = DecoderConfig_Body(tag: AlvrEvent_Tag(ALVR_EVENT_DECODER_CONFIG.rawValue), codec: AlvrCodec(ALVR_CODEC_HEVC.rawValue))
        push(d)
    }

    /// The streamer rebuilds its encoder (new size => new VPS/SPS/PPS) and sends a new DecoderConfig on the same connection.
    func reconfigure(width w: UInt32, height h: UInt32) {
        lock.lock()
        configId += 1
        width = w
        height = h
        idrRequested = true
        lock.unlock()
        sendDecoderConfig()
        HarnessLog.shared.event("host_reconfigure", ["config": "\(configId)", "size": "\(w)x\(h)"])
    }

    /// connection.rs:590-598: the connection ends, StreamingStopped is queued.
    func stopStreaming(_ why: String) {
        lock.lock()
        guard conn == .streaming || conn == .disconnecting else { lock.unlock(); return }
        conn = .idle
        rxQueue.removeAll()
        lock.broadcast()
        lock.unlock()
        var e = AlvrEvent()
        e.tag = AlvrEvent_Tag(ALVR_EVENT_STREAMING_STOPPED.rawValue)
        push(e)
        HarnessLog.shared.event("host_streaming_stopped", ["why": why])
    }

    func hud(_ message: String) {
        lock.lock(); hudMessage = message; lock.unlock()
        var e = AlvrEvent()
        e.tag = AlvrEvent_Tag(ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue)
        push(e)
    }

    /// The network delivers one frame into the receive queue; overflow drops the oldest (the next one carries the loss).
    func deliver(_ f: HostFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard conn == .streaming else { return }
        var f = f
        if rxQueue.count >= rxCap {
            rxQueue.removeFirst()
            f.lossBefore = true
            HarnessStats.shared.count("rx_overflow")
        }
        rxQueue.append(f)
        lock.signal()
    }

    /// The streamer's view of the IDR flag: true once per request (the next frame it encodes is an IDR).
    func takeIdrRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let r = idrRequested
        idrRequested = false
        return r
    }

    func newestTracking(olderThan age: Double) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        let now = HarnessLog.shared.now()
        return tracking.last(where: { now - $0.0 >= age })?.1
    }

    // MARK: the video receive thread (connection.rs:317-367)

    private func startVideoThread() {
        lock.lock()
        if videoThread != nil { lock.unlock(); return }
        let t = Thread { [self] in videoLoop() }
        t.name = "client_core video receive"
        videoThread = t
        lock.unlock()
        t.start()
    }

    private func videoLoop() {
        var streamCorrupted = true
        while true {
            lock.lock()
            while rxQueue.isEmpty && conn == .streaming {
                _ = lock.wait(until: Date(timeIntervalSinceNow: 0.5)) // STREAMING_RECV_TIMEOUT
            }
            if conn != .streaming {
                videoThread = nil
                lock.unlock()
                return
            }
            let f = rxQueue.removeFirst()
            lock.unlock()

            if f.isIdr {
                streamCorrupted = false
            } else if f.lossBefore {
                streamCorrupted = true
                requestIdr("packet_loss")
            }
            if !streamCorrupted || !avoidVideoGlitching {
                let bytes = FakeNal.frame(isIdr: f.isIdr, configId: f.configId, index: f.index)
                let submitted: Bool = bytes.withUnsafeBufferPointer { p in
                    guard let cb = callback else { return false }
                    let started = CACurrentMediaTime()
                    let r = cb(AlvrVideoFrameData(callback_context: nil, timestamp_ns: f.timestamp, buffer_ptr: p.baseAddress, buffer_size: UInt64(p.count)))
                    let ms = (CACurrentMediaTime() - started) * 1000
                    if ms > 30 { HarnessLog.shared.event("callback_slow", ["ms": String(format: "%.1f", ms), "frame": "\(f.index)"]) }
                    return r
                }
                if !submitted {
                    streamCorrupted = true
                    requestIdr("decoder_saturation")
                }
            } else {
                requestIdr("waiting_for_idr")
            }
        }
    }

    // MARK: client -> core

    func fatal(_ message: String) {
        HarnessLog.shared.event("fatal_decoder_error", ["message": message])
        lock.lock()
        let wasStreaming = conn == .streaming
        if wasStreaming { conn = .disconnecting }
        lock.unlock()
        guard wasStreaming else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            stopStreaming("fatal_decoder_error")
            DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [self] in
                lock.lock(); reconnects += 1; lock.unlock()
                HarnessDecoder.broken = false // a new connection, a new decoder
                HarnessLog.shared.event("host_reconnect")
                startStreaming()
            }
        }
    }
}

// MARK: - C API (names and signatures from CAlvr/alvr_client_core.h)

private func writeCString(_ s: String, _ buf: UnsafeMutablePointer<CChar>?) -> UInt64 {
    let bytes = Array(s.utf8) + [0]
    if let buf { bytes.withUnsafeBufferPointer { p in p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf.update(from: $0, count: bytes.count) } } }
    return UInt64(bytes.count)
}

@_cdecl("alvr_initialize") func h_alvr_initialize(_ caps: AlvrClientCapabilities) {
    FakeCore.shared.initialized = true
    HarnessLog.shared.event("core_initialize", ["w": "\(caps.default_view_width)", "h": "\(caps.default_view_height)"])
}
@_cdecl("alvr_initialize_logging") func h_alvr_initialize_logging() {}
@_cdecl("alvr_destroy") func h_alvr_destroy() { HarnessLog.shared.event("core_destroy") }
@_cdecl("alvr_resume") func h_alvr_resume() { FakeCore.shared.resumed = true }
@_cdecl("alvr_pause") func h_alvr_pause() { FakeCore.shared.resumed = false; HarnessLog.shared.event("core_pause") }

@_cdecl("alvr_poll_event") func h_alvr_poll_event(_ out: UnsafeMutablePointer<AlvrEvent>?) -> Bool {
    let c = FakeCore.shared
    c.lock.lock()
    defer { c.lock.unlock() }
    guard !c.events.isEmpty, let out else { return false }
    out.pointee = c.events.removeFirst()
    return true
}

@_cdecl("alvr_hud_message") func h_alvr_hud_message(_ buf: UnsafeMutablePointer<CChar>?) -> UInt64 {
    FakeCore.shared.lock.lock(); let m = FakeCore.shared.hudMessage; FakeCore.shared.lock.unlock()
    return writeCString(m, buf)
}
@_cdecl("alvr_get_server_version") func h_alvr_get_server_version(_ buf: UnsafeMutablePointer<CChar>?) -> UInt64 { writeCString("20.14.1", buf) }
@_cdecl("alvr_hostname") func h_alvr_hostname(_ buf: UnsafeMutablePointer<CChar>?) -> UInt64 { writeCString("1234.client", buf) }
@_cdecl("alvr_mdns_service") func h_alvr_mdns_service(_ buf: UnsafeMutablePointer<CChar>?) -> UInt64 { writeCString("_alvr._tcp.local", buf) }
@_cdecl("alvr_protocol_id") func h_alvr_protocol_id(_ buf: UnsafeMutablePointer<CChar>?) -> UInt64 { writeCString("20.14.1", buf) }
@_cdecl("alvr_path_string_to_id") func h_alvr_path_string_to_id(_ path: UnsafePointer<CChar>?) -> UInt64 {
    guard let path else { return 0 }
    var h: UInt64 = 1469598103934665603
    for b in String(cString: path).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h
}
@_cdecl("alvr_log") func h_alvr_log(_ level: UInt8, _ message: UnsafePointer<CChar>?) {
    HarnessLog.shared.event("alvr_log", ["level": "\(level)", "msg": message.map { String(cString: $0) } ?? ""])
}

@_cdecl("alvr_get_decoder_config") func h_alvr_get_decoder_config(_ out: UnsafeMutablePointer<CChar>?) -> UInt64 {
    let c = FakeCore.shared
    c.lock.lock()
    let bytes = FakeNal.config(configId: c.configId, width: c.width, height: c.height)
    c.lock.unlock()
    if let out { bytes.withUnsafeBufferPointer { p in p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { out.update(from: $0, count: bytes.count) } } }
    return UInt64(bytes.count)
}

@_cdecl("alvr_set_decoder_input_callback") func h_alvr_set_decoder_input_callback(_ ctx: UnsafeMutableRawPointer?, _ cb: (@convention(c) (AlvrVideoFrameData) -> Bool)?) {
    let c = FakeCore.shared
    c.lock.lock(); c.callback = cb; c.lock.unlock()
    c.requestIdr("callback_installed")
}

/// client_core's statistics_manager mutex (lib.rs: report_frame_decoded, report_compositor_start, report_submit, send_tracking all take it).
/// `coreBlockUntil` models report_submit's statistics send blocking (a dead link). Stock v20.14.1 sends while it holds the mutex
/// (HARNESS_CORE_STOCK=1); with patches/client_core-statistics-send-outside-lock.patch, which the app build applies, the mutex is
/// released first (the default here). This file is a model: it does not show that the patched Rust code behaves so.
let coreStatsLock = NSLock()
let coreStock = ProcessInfo.processInfo.environment["HARNESS_CORE_STOCK"] == "1"
nonisolated(unsafe) var coreBlockUntil = 0.0
func coreStatsBlockIfInjected() {
    let left = coreBlockUntil - CACurrentMediaTime()
    if left > 0 { usleep(UInt32(left * 1e6)) }
}
@_cdecl("alvr_report_frame_decoded") func h_alvr_report_frame_decoded(_ ts: UInt64) {
    let c = FakeCore.shared
    coreStatsLock.lock()
    c.lock.lock(); c.framesDecodedReported += 1; c.lock.unlock()
    coreStatsLock.unlock()
}
@_cdecl("alvr_report_fatal_decoder_error") func h_alvr_report_fatal_decoder_error(_ message: UnsafePointer<CChar>?) {
    FakeCore.shared.fatal(message.map { String(cString: $0) } ?? "")
}
@_cdecl("alvr_report_compositor_start") func h_alvr_report_compositor_start(_ ts: UInt64, _ out: UnsafeMutablePointer<AlvrViewParams>?) {
    let c = FakeCore.shared
    coreStatsLock.lock(); defer { coreStatsLock.unlock() }
    c.lock.lock(); c.compositorStarts += 1; c.lock.unlock()
    if let out {
        out[0] = AlvrViewParams()
        out[1] = AlvrViewParams()
    }
}
@_cdecl("alvr_report_submit") func h_alvr_report_submit(_ ts: UInt64, _ vsyncQueue: UInt64) {
    let c = FakeCore.shared
    coreStatsLock.lock()
    c.lock.lock(); c.submits += 1; c.lastSubmitTs = ts; c.lock.unlock()
    if coreStock { coreStatsBlockIfInjected() }   // stock: statistics_sender.send_header under the statistics_manager lock
    coreStatsLock.unlock()
    if !coreStock { coreStatsBlockIfInjected() }  // patched: the send happens after the mutex is released
}

@_cdecl("alvr_send_battery") func h_alvr_send_battery(_ id: UInt64, _ g: Float, _ p: Bool) {}
@_cdecl("alvr_send_playspace") func h_alvr_send_playspace(_ w: Float, _ h: Float) {}
@_cdecl("alvr_send_view_params") func h_alvr_send_view_params(_ v: UnsafePointer<AlvrViewParams>?) {
    let c = FakeCore.shared
    c.lock.lock(); c.viewParamsCount += 1; c.lock.unlock()
}

private func recordTracking(_ ts: UInt64) {
    let c = FakeCore.shared
    coreStatsLock.lock(); coreStatsLock.unlock()   // send_tracking reads the pipeline latency under the same mutex
    c.lock.lock()
    c.tracking.append((HarnessLog.shared.now(), ts))
    if c.tracking.count > 4096 { c.tracking.removeFirst(c.tracking.count - 2048) }
    c.lock.unlock()
}

@_cdecl("alvr_send_tracking") func h_alvr_send_tracking(_ ts: UInt64, _ motions: UnsafePointer<AlvrDeviceMotion>?, _ count: UInt64,
                                                       _ hands: UnsafePointer<UnsafePointer<AlvrPose>?>?, _ gaze: UnsafePointer<UnsafePointer<AlvrPose>?>?) {
    recordTracking(ts)
}
@_cdecl("alvr_send_tracking_and_face_data") func h_alvr_send_tracking_and_face_data(_ ts: UInt64, _ motions: UnsafePointer<AlvrDeviceMotion>?, _ count: UInt64,
                                                                                   _ hands: UnsafePointer<UnsafePointer<AlvrPose>?>?, _ gaze: UnsafePointer<UnsafePointer<AlvrPose>?>?,
                                                                                   _ face: UnsafePointer<Float>?) {
    recordTracking(ts)
}
