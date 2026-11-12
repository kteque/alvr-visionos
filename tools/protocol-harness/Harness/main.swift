// Protocol harness for the visionOS client: the real ALVRClient/EventHandler.swift against a scripted streamer
// (FakeCore.swift) and a render-loop model (DisplaySim.swift). Linux, no Mac, no headset.
//
//   protocol_harness list
//   protocol_harness run <scenario> [--out DIR] [--echo]
// Exit codes: 0 pass, 1 fail (checks), 42 the client called exit() (a finding), anything else = crash (signal).

import Foundation
import AppleShims

// MARK: - The streamer script

enum Phase {
    /// no game: the host's green idle frame at 30 fps (docs/ARCHITECTURE.md)
    case idle(seconds: Double)
    /// a game at `fps` with +-jitterMs cadence noise; frames carry the pose sampled `poseAgeMs` before they are sent
    case game(seconds: Double, fps: Double, jitterMs: Double = 1, poseAgeMs: Double = 30)
    /// a free-running game or paced output: frame k leaves at k / fps + noise (uniform +-arrivalJitterMs, not accumulating), and with
    /// probability `spikeProb` a frame is held back by `spikeMs` (a Wi-Fi hiccup). Compare `.game`, whose jitter accumulates.
    case stream(seconds: Double, fps: Double, arrivalJitterMs: Double, spikeProb: Double = 0, spikeMs: Double = 0, poseAgeMs: Double = 30)
    /// the system switches the display rate and the render thread stalls for `stallMs` (the field showed an 80 ms interval)
    case switchDisplay(hz: Double, stallMs: Double)
    /// the game stops presenting: the host sends nothing (tools/host/src/pipeline.rs: empty boundary left empty)
    case stall(seconds: Double)
    /// the network stalls (Wi-Fi hiccup): the host keeps encoding at `fps` and sends, but nothing reaches the client for `seconds`,
    /// then everything held arrives at once (the headset log 2026-11-12: gaps of 4-7 s, then frames 0.3-2 s old, 0 packets lost)
    case netStall(seconds: Double, fps: Double)
    /// the link dies for `seconds` (client_core's keepalive ends the stream, the streamer is unreachable), then the streamer is found again
    case networkLoss(seconds: Double)
    /// fault injection: the statistics send inside client_core's alvr_report_submit blocks for `seconds` while it holds the statistics mutex
    /// (what a dead link would do to a blocking send); the host keeps streaming normally
    case coreBlock(seconds: Double)
    /// irregular presents: gaps drawn uniformly from minMs...maxMs
    case irregular(seconds: Double, minMs: Double, maxMs: Double, poseAgeMs: Double = 30)
    /// the encoder is rebuilt with another size (new parameter sets, same connection)
    case reconfigure(width: UInt32, height: UInt32)
    /// the streamer ends the stream and starts a new one (game exit / restart)
    case restart(gapSeconds: Double)
    /// visionOS reports the app in the background for a while
    case background(seconds: Double)
    /// the client enters its immersive space (render loop starts) at this point of the script
    case enterImmersive
    /// the decoder session dies under the client (VideoToolbox returns kVTInvalidSessionErr, as after a pause)
    case invalidateDecoder
    /// every decode fails until the connection is rebuilt (positive control for the client's reconnect rule)
    case breakDecoder
}

struct Scenario {
    let name: String
    let about: String
    var enterBeforeStream = true
    var phases: [Phase]
    /// checks: the stream must show new frames this many seconds after the last phase began (0 = skip)
    var settleWindow: Double = 3
    var minNewFraction: Double = 0.8
    var maxReconnects = 0
    var minReconnects = 0
    var expectExit = false
    /// the display's real rate (the system decides 90 or 100 Hz, the app does not) and the rate the streamer negotiated
    var displayHz = 90.0
    var hintHz = 90.0
    /// pacing checks: repeated ticks over the tail must stay under this share (1 = not checked)
    var maxRepeatFraction = 1.0
    /// the client's refresh rate after the stream started must equal the negotiated one (hintHz)
    var expectClientRateFollowsHint = false
    /// shown-frame age after the last display switch (settled: from 3 s on) must stay under this many ms (0 = not checked)
    var maxSettledAgeMs = 0.0
    /// link-loss policy: nil = not checked; true = the client must have left the immersive space (once) and come back; false = it must have stayed
    var expectLeave: Bool? = nil
    /// the render thread must never wait longer than this between two display ticks (0 = not checked)
    var maxTickGapMs = 0.0
}

let game90 = Phase.game(seconds: 6, fps: 90)

let scenarios: [Scenario] = [
    Scenario(name: "cold_idle_to_game", about: "headset waits, stream starts on the idle frame, a game starts",
             phases: [.idle(seconds: 6), .game(seconds: 8, fps: 90)]),
    Scenario(name: "enter_after_stream", about: "the stream runs before the immersive space opens",
             enterBeforeStream: false, phases: [.idle(seconds: 3), .enterImmersive, .idle(seconds: 3), .game(seconds: 8, fps: 90)]),
    Scenario(name: "fps_drop", about: "90 -> 45 -> 30 -> 90 fps",
             phases: [game90, .game(seconds: 6, fps: 45), .game(seconds: 6, fps: 30), .game(seconds: 6, fps: 90)]),
    Scenario(name: "stall_1s", about: "the game stops presenting for 1 s",
             phases: [game90, .stall(seconds: 1), game90]),
    Scenario(name: "stall_6s", about: "the game stops presenting for 6 s (loading screen)",
             phases: [game90, .stall(seconds: 6), game90]),
    Scenario(name: "stall_35s", about: "the game stops presenting for 35 s (long load)",
             phases: [game90, .stall(seconds: 35), .game(seconds: 8, fps: 90)]),
    Scenario(name: "choke", about: "the game chokes: 6 fps with 700 ms old poses for 5 s, then recovers",
             phases: [game90, .game(seconds: 5, fps: 6, jitterMs: 40, poseAgeMs: 700), .game(seconds: 8, fps: 90)]),
    Scenario(name: "net_stall_2s", about: "the network holds every frame for 2 s, then flushes them (host fine, 100 fps)",
             phases: [game90, .netStall(seconds: 2, fps: 100), game90]),
    Scenario(name: "net_stall_7s", about: "the network holds every frame for 7 s, then flushes them",
             phases: [game90, .netStall(seconds: 7, fps: 100), game90]),
    Scenario(name: "net_stall_storm", about: "five network stalls (0.5-4 s) in 25 s, each flushed as a burst",
             phases: [game90, .netStall(seconds: 0.5, fps: 100), .game(seconds: 1, fps: 100), .netStall(seconds: 4, fps: 100), .game(seconds: 1, fps: 100),
                      .netStall(seconds: 1.5, fps: 100), .game(seconds: 0.5, fps: 100), .netStall(seconds: 3, fps: 100), .game(seconds: 1, fps: 100),
                      .netStall(seconds: 2, fps: 100), game90], displayHz: 100, hintHz: 100),
    // Link loss: the client must not die. It stays in the immersive space and the stream resumes by itself when the streamer is back;
    // only after EventHandler.leaveStreamAfter (60 s) without a stream does it go to the Entry window (the core keeps listening, auto-connect re-enters).
    Scenario(name: "loss_3s", about: "the link dies for 3 s: the client stays in the immersive space and the stream resumes",
             phases: [game90, .networkLoss(seconds: 3), .game(seconds: 8, fps: 90)], expectLeave: false),
    Scenario(name: "loss_25s", about: "the link dies for 25 s: still in the immersive space, the stream resumes",
             phases: [game90, .networkLoss(seconds: 25), .game(seconds: 8, fps: 90)], expectLeave: false),
    Scenario(name: "loss_flap", about: "the link flaps: 2 s up, 35 s down, three times: never leaves (each return resets the timer)",
             phases: [game90, .networkLoss(seconds: 35), .game(seconds: 2, fps: 90), .networkLoss(seconds: 35), .game(seconds: 2, fps: 90),
                      .networkLoss(seconds: 35), .game(seconds: 8, fps: 90)], expectLeave: false),
    Scenario(name: "loss_75s", about: "the link dies for 75 s: the client leaves the immersive space after 60 s, re-enters when the streamer is back",
             phases: [game90, .networkLoss(seconds: 75), .game(seconds: 8, fps: 90)], expectLeave: true),
    // Fault injection: a core call that blocks while it holds client_core's statistics mutex (see docs/VISIONOS_CLIENT_HARDENING.md, finding F1)
    Scenario(name: "core_block_2s", about: "alvr_report_submit blocks 2 s under the core's statistics mutex: the render thread must keep ticking",
             phases: [game90, .coreBlock(seconds: 2), .game(seconds: 6, fps: 90)], maxTickGapMs: 100),
    Scenario(name: "irregular", about: "irregular cadence, 8-90 ms gaps for 15 s",
             phases: [game90, .irregular(seconds: 15, minMs: 8, maxMs: 90), .game(seconds: 6, fps: 90)]),
    Scenario(name: "reconfigure", about: "the encoder is rebuilt with a new size mid-stream",
             phases: [game90, .reconfigure(width: 3200, height: 2880), .game(seconds: 8, fps: 90)]),
    Scenario(name: "restart", about: "the streamer ends the stream and starts a new one",
             phases: [game90, .restart(gapSeconds: 1), .idle(seconds: 3), .game(seconds: 8, fps: 90)]),
    Scenario(name: "restart_storm", about: "five stream restarts one second apart",
             phases: [game90, .restart(gapSeconds: 0.3), .game(seconds: 1, fps: 90), .restart(gapSeconds: 0.3),
                      .game(seconds: 1, fps: 90), .restart(gapSeconds: 0.3), .game(seconds: 1, fps: 90),
                      .restart(gapSeconds: 0.3), .game(seconds: 1, fps: 90), .restart(gapSeconds: 0.3), .game(seconds: 8, fps: 90)]),
    Scenario(name: "decoder_dies", about: "the decoder session becomes invalid mid-stream",
             phases: [game90, .invalidateDecoder, .game(seconds: 8, fps: 90)]),
    Scenario(name: "decoder_broken", about: "frames arrive but never decode: the client must reconnect once (control)",
             phases: [game90, .breakDecoder, .game(seconds: 36, fps: 90)], settleWindow: 0, maxReconnects: 1, minReconnects: 1),
    Scenario(name: "background_blip", about: "visionOS reports background for 0.3 s mid-stream",
             phases: [game90, .background(seconds: 0.3), game90]),
    // Pacing (repeats at the display): the lab reproduction of the headset's repeated frames. Tail = the last phase after 1 s.
    Scenario(name: "pace_paced_100", about: "output paced to a 100 Hz display (frame generation), small jitter",
             phases: [game90, .stream(seconds: 20, fps: 100, arrivalJitterMs: 0.5)], displayHz: 100, hintHz: 100, maxRepeatFraction: 0.02),
    Scenario(name: "pace_free98_100", about: "free-running 98 fps game into a 100 Hz display, 1.5 ms arrival jitter, rare 6 ms hiccups",
             phases: [game90, .stream(seconds: 25, fps: 98, arrivalJitterMs: 1.5, spikeProb: 0.01, spikeMs: 6)], displayHz: 100, hintHz: 100, maxRepeatFraction: 0.05),
    Scenario(name: "pace_free95_100", about: "free-running 95 fps (Dead Space range) into a 100 Hz display",
             phases: [game90, .stream(seconds: 25, fps: 95, arrivalJitterMs: 2.0, spikeProb: 0.01, spikeMs: 6)], displayHz: 100, hintHz: 100, maxRepeatFraction: 0.08),
    Scenario(name: "pace_free98_90", about: "free-running 98 fps into a 90 Hz display (stream above the display rate)",
             phases: [game90, .stream(seconds: 25, fps: 98, arrivalJitterMs: 1.5, spikeProb: 0.01, spikeMs: 6)], displayHz: 90, hintHz: 100, maxRepeatFraction: 0.05),
    Scenario(name: "pace_90_on_100", about: "paced 90 fps stream on a display the system runs at 100 Hz (the night logs)",
             phases: [game90, .stream(seconds: 25, fps: 90, arrivalJitterMs: 0.5)], displayHz: 100, hintHz: 90, maxRepeatFraction: 0.15),
    Scenario(name: "pace_game95_j3", about: "free-running 95 fps game, frame gaps 1/95 s +-3 ms accumulating, 100 Hz display",
             phases: [game90, .game(seconds: 25, fps: 95, jitterMs: 3)], displayHz: 100, hintHz: 100),
    Scenario(name: "pace_game97_j2", about: "free-running 97 fps game, +-2 ms, 100 Hz display",
             phases: [game90, .game(seconds: 25, fps: 97, jitterMs: 2)], displayHz: 100, hintHz: 100),
    Scenario(name: "pace_game98_j4", about: "free-running 98 fps game, +-4 ms, 100 Hz display",
             phases: [game90, .game(seconds: 25, fps: 98, jitterMs: 4)], displayHz: 100, hintHz: 100),
    Scenario(name: "rate_follows_hint", about: "the stream negotiates 100 Hz: the client's refresh rate (display-link and criteria request) follows it, not the 90 default",
             phases: [game90, .stream(seconds: 6, fps: 100, arrivalJitterMs: 0.5)], displayHz: 100, hintHz: 100, expectClientRateFollowsHint: true),
    // Display rate switches (the system decides) with a render-thread stall. The host follows the headset: a second stream phase at the new rate.
    Scenario(name: "sw_100_90_s80", about: "100 -> 90 Hz with an 80 ms render stall, the host follows at once (paced 100 then 90 fps)",
             phases: [game90, .stream(seconds: 8, fps: 100, arrivalJitterMs: 0.5), .switchDisplay(hz: 90, stallMs: 80), .stream(seconds: 12, fps: 90, arrivalJitterMs: 0.5)],
             displayHz: 100, hintHz: 100, maxSettledAgeMs: 14),
    Scenario(name: "sw_100_90_lag1s", about: "100 -> 90 Hz with an 80 ms stall, the host keeps 100 fps for 1 s before following",
             phases: [game90, .stream(seconds: 8, fps: 100, arrivalJitterMs: 0.5), .switchDisplay(hz: 90, stallMs: 80), .stream(seconds: 1, fps: 100, arrivalJitterMs: 0.5), .stream(seconds: 11, fps: 90, arrivalJitterMs: 0.5)],
             displayHz: 100, hintHz: 100, maxSettledAgeMs: 14),
    Scenario(name: "sw_90_100_s80", about: "90 -> 100 Hz with an 80 ms stall, the host follows at once",
             phases: [game90, .stream(seconds: 8, fps: 90, arrivalJitterMs: 0.5), .switchDisplay(hz: 100, stallMs: 80), .stream(seconds: 12, fps: 100, arrivalJitterMs: 0.5)],
             displayHz: 90, hintHz: 90, maxSettledAgeMs: 14),
    Scenario(name: "sw_100_96_s40", about: "100 -> 96 Hz with a 40 ms stall",
             phases: [game90, .stream(seconds: 8, fps: 100, arrivalJitterMs: 0.5), .switchDisplay(hz: 96, stallMs: 40), .stream(seconds: 12, fps: 96, arrivalJitterMs: 0.5)],
             displayHz: 100, hintHz: 100, maxSettledAgeMs: 14),
    Scenario(name: "sw_rapid", about: "100 -> 90 -> 100 -> 96 within 6 s with stalls, the host follows each",
             phases: [game90, .stream(seconds: 6, fps: 100, arrivalJitterMs: 0.5), .switchDisplay(hz: 90, stallMs: 60), .stream(seconds: 2, fps: 90, arrivalJitterMs: 0.5),
                      .switchDisplay(hz: 100, stallMs: 60), .stream(seconds: 2, fps: 100, arrivalJitterMs: 0.5), .switchDisplay(hz: 96, stallMs: 40), .stream(seconds: 12, fps: 96, arrivalJitterMs: 0.5)],
             displayHz: 100, hintHz: 100, maxSettledAgeMs: 14),
    Scenario(name: "background_real", about: "the wearer leaves the app: background for 3 s (the client must exit)",
             phases: [game90, .background(seconds: 3), game90], expectExit: true),
]

// MARK: - Host thread

final class Host: @unchecked Sendable {
    var frameIndex: UInt32 = 0
    var rng = SystemRandomNumberGenerator()
    let t0 = CACurrentMediaTime()

    func sleep(_ s: Double) { if s > 0 { usleep(UInt32(s * 1e6)) } }

    func sendFrame(poseAgeMs: Double) {
        let core = FakeCore.shared
        let isIdr = core.takeIdrRequest()
        // the server re-sends DecoderConfig with every IDR it encodes on request (server_core/src/connection.rs:1198-1204)
        if isIdr && frameIndex > 0 { core.sendDecoderConfig() }
        let stamp = core.newestTracking(olderThan: poseAgeMs / 1000) ?? UInt64(CACurrentMediaTime() * 1e9)
        core.lock.lock(); let cfg = core.configId; core.lock.unlock()
        frameIndex &+= 1
        DisplaySim.shared.noteSent(frameIndex)
        core.deliver(HostFrame(index: frameIndex, timestamp: stamp, isIdr: isIdr, configId: cfg, lossBefore: false))
    }

    func run(_ phase: Phase) {
        switch phase {
        case .idle(let s):
            HarnessLog.shared.event("phase", ["kind": "idle", "s": "\(s)"])
            if FakeCore.shared.conn == .idle { FakeCore.shared.hud("ALVR 20.14.1\nhostname: harness\nIP: 127.0.0.1\nThe stream will begin soon\nPlease wait...\n"); FakeCore.shared.startStreaming() }
            cadence(seconds: s, gap: { 1.0 / 30 }, poseAgeMs: 30)
        case .game(let s, let fps, let jit, let age):
            HarnessLog.shared.event("phase", ["kind": "game", "s": "\(s)", "fps": "\(fps)", "pose_age_ms": "\(age)"])
            if FakeCore.shared.conn == .idle { FakeCore.shared.startStreaming() }
            cadence(seconds: s, gap: { 1.0 / fps + Double.random(in: -jit...jit) / 1000 }, poseAgeMs: age)
        case .stream(let s, let fps, let jit, let spikeProb, let spikeMs, let age):
            HarnessLog.shared.event("phase", ["kind": "stream", "s": "\(s)", "fps": "\(fps)", "jitter_ms": "\(jit)"])
            if FakeCore.shared.conn == .idle { FakeCore.shared.startStreaming() }
            let t0 = CACurrentMediaTime()
            var k = 0.0
            while CACurrentMediaTime() - t0 < s {
                var at = t0 + k / fps + Double.random(in: -jit...jit) / 1000
                if spikeProb > 0 && Double.random(in: 0..<1) < spikeProb { at += spikeMs / 1000 }
                k += 1
                let now = CACurrentMediaTime()
                if at > now { sleep(at - now) }
                sendFrame(poseAgeMs: age)
            }
        case .netStall(let s, let fps):
            HarnessLog.shared.event("phase", ["kind": "net_stall", "s": "\(s)", "fps": "\(fps)"])
            if FakeCore.shared.conn == .idle { FakeCore.shared.startStreaming() }
            let core = FakeCore.shared
            var held: [HostFrame] = []
            let t0 = CACurrentMediaTime()
            var k = 0.0
            while CACurrentMediaTime() - t0 < s {
                let at = t0 + k / fps; k += 1
                let now = CACurrentMediaTime()
                if at > now { sleep(at - now) }
                let isIdr = core.takeIdrRequest()
                if isIdr && frameIndex > 0 { core.sendDecoderConfig() }
                let stamp = core.newestTracking(olderThan: 0.03) ?? UInt64(CACurrentMediaTime() * 1e9)
                core.lock.lock(); let cfg = core.configId; core.lock.unlock()
                frameIndex &+= 1
                DisplaySim.shared.noteSent(frameIndex)
                held.append(HostFrame(index: frameIndex, timestamp: stamp, isIdr: isIdr, configId: cfg, lossBefore: false))
            }
            for f in held { core.deliver(f); usleep(300) }   // the burst: a line-rate flush, 0.3 ms apart
        case .networkLoss(let s):
            HarnessLog.shared.event("phase", ["kind": "network_loss", "s": "\(s)"])
            FakeCore.shared.stopStreaming("network_lost")
            sleep(s)
            FakeCore.shared.startStreaming()
        case .coreBlock(let s):
            HarnessLog.shared.event("phase", ["kind": "core_block", "s": "\(s)"])
            coreBlockUntil = CACurrentMediaTime() + s
            cadence(seconds: s + 0.5, gap: { 1.0 / 90 }, poseAgeMs: 30)
        case .irregular(let s, let lo, let hi, let age):
            HarnessLog.shared.event("phase", ["kind": "irregular", "s": "\(s)"])
            cadence(seconds: s, gap: { Double.random(in: lo...hi) / 1000 }, poseAgeMs: age)
        case .switchDisplay(let hz, let stallMs):
            HarnessLog.shared.event("phase", ["kind": "switch_display", "hz": "\(hz)", "stall_ms": "\(stallMs)"])
            DisplaySim.shared.switchDisplay(hz: hz, stallMs: stallMs)
        case .stall(let s):
            HarnessLog.shared.event("phase", ["kind": "stall", "s": "\(s)"])
            sleep(s)
        case .reconfigure(let w, let h):
            HarnessLog.shared.event("phase", ["kind": "reconfigure"])
            FakeCore.shared.reconfigure(width: w, height: h)
        case .restart(let gap):
            HarnessLog.shared.event("phase", ["kind": "restart"])
            FakeCore.shared.stopStreaming("host_restart")
            sleep(gap)
            FakeCore.shared.startStreaming()
        case .background(let s):
            HarnessLog.shared.event("phase", ["kind": "background", "s": "\(s)"])
            UIApplication.shared.applicationState = .background
            sleep(s)
            UIApplication.shared.applicationState = .active
        case .enterImmersive:
            DisplaySim.shared.start()
        case .breakDecoder:
            HarnessLog.shared.event("phase", ["kind": "break_decoder"])
            HarnessDecoder.broken = true
        case .invalidateDecoder:
            HarnessLog.shared.event("phase", ["kind": "invalidate_decoder"])
            objc_sync_enter(EventHandler.shared.frameQueueLock)
            EventHandler.shared.vtDecompressionSession?.invalidated = true
            objc_sync_exit(EventHandler.shared.frameQueueLock)
        }
    }

    func cadence(seconds: Double, gap: () -> Double, poseAgeMs: Double) {
        let end = CACurrentMediaTime() + seconds
        var next = CACurrentMediaTime()
        while next < end {
            let now = CACurrentMediaTime()
            if next > now { sleep(next - now) }
            sendFrame(poseAgeMs: poseAgeMs)
            next += max(0.002, gap())
        }
    }
}

// MARK: - Verdict

struct Verdict: Codable {
    var scenario: String
    var pass: Bool
    var failures: [String]
    var metrics: [String: Double]
    var clientLines: [String: Int]
    var harnessEvents: [String: Int]
}

func evaluate(_ sc: Scenario, lastPhaseStart: Double, end: Double) -> Verdict {
    let ds = DisplaySim.shared
    ds.lock.lock(); let ticks = ds.ticks; ds.lock.unlock()
    let st = HarnessStats.shared
    let core = FakeCore.shared
    var m: [String: Double] = [:]
    var fails: [String] = []

    let settleFrom = lastPhaseStart + 1.0
    let tail = ticks.filter { $0.t >= settleFrom && $0.t <= end }
    let newTail = Double(tail.filter { $0.shown == .new }.count)
    m["tail_ticks"] = Double(tail.count)
    m["tail_new_fraction"] = tail.isEmpty ? 0 : newTail / Double(tail.count)
    let repTail = Double(tail.filter { $0.shown == .repeated }.count)
    m["tail_repeated_fraction"] = tail.isEmpty ? 0 : repTail / Double(tail.count)
    m["client_refresh_rate"] = Double(refreshRate)
    m["blank_ticks"] = Double(ticks.filter { $0.shown == .blank }.count)
    m["repeated_ticks"] = Double(ticks.filter { $0.shown == .repeated }.count)
    m["new_ticks"] = Double(ticks.filter { $0.shown == .new }.count)
    var run = 0, worst = 0
    var firstNew: Double? = nil
    for t in ticks {
        if t.shown == .new { if firstNew == nil { firstNew = t.t }; run = 0 } else { run += 1; worst = max(worst, run) }
    }
    m["first_new_frame_s"] = firstNew ?? -1
    m["worst_not_new_run_ticks"] = Double(worst)
    // frame age at display (host send -> tick) around the display switches
    func ageStats(_ from: Double, _ to: Double, _ key: String) {
        let a = ticks.filter { $0.t >= from && $0.t < to }.compactMap { $0.ageMs }.sorted()
        if a.isEmpty { return }
        m[key + "_mean"] = a.reduce(0, +) / Double(a.count)
        m[key + "_p95"] = a[min(a.count - 1, Int(Double(a.count) * 0.95))]
    }
    ageStats(settleFrom, end, "age_tail")
    ds.lock.lock(); let sw = ds.switchTimes; ds.lock.unlock()
    if let first = sw.first {
        ageStats(first - 5, first - 0.5, "age_before")
        ageStats(first, first + 1, "age_0_1s")
        ageStats(first + 1, first + 3, "age_1_3s")
        ageStats(first + 3, end, "age_settled")
        m["picked_catchup_drops"] = Double(EventHandler.shared.catchUpDrops)
    }
    if sc.maxSettledAgeMs > 0, let a = m["age_settled_mean"], a > sc.maxSettledAgeMs {
        fails.append(String(format: "frames shown after the switch are %.1f ms old on average (want <= %.1f ms)", a, sc.maxSettledAgeMs))
    }
    core.lock.lock()
    m["idr_requests"] = Double(core.idrRequestTimes.count)
    m["reconnects"] = Double(core.reconnects)
    m["frames_decoded_reported"] = Double(core.framesDecodedReported)
    m["submits"] = Double(core.submits)
    core.lock.unlock()
    st.lock.lock()
    m["decoded_frames"] = Double(st.decodedFrames)
    m["decode_errors"] = Double(st.decodeErrors.values.reduce(0, +))
    let clientLines = st.clientCounters
    let events = st.counters
    st.lock.unlock()

    if sc.settleWindow > 0 && (m["tail_new_fraction"] ?? 0) < sc.minNewFraction {
        fails.append(String(format: "after the last transition only %.0f%% of display ticks showed a new frame (want >= %.0f%%)",
                            (m["tail_new_fraction"] ?? 0) * 100, sc.minNewFraction * 100))
    }
    if sc.expectClientRateFollowsHint && abs(Double(refreshRate) - sc.hintHz) > 0.01 {
        fails.append(String(format: "the client's refresh rate is %.0f Hz but the stream negotiated %.0f Hz", Double(refreshRate), sc.hintHz))
    }
    if (m["tail_repeated_fraction"] ?? 0) > sc.maxRepeatFraction {
        fails.append(String(format: "%.1f%% of display ticks repeated a frame (want <= %.1f%%)", (m["tail_repeated_fraction"] ?? 0) * 100, sc.maxRepeatFraction * 100))
    }
    if Int(m["reconnects"] ?? 0) < sc.minReconnects {
        fails.append("the client did not reconnect although its decoder never recovered")
    }
    do {
        var worstGap = 0.0, prev: Double? = nil
        for t in ticks { if let p = prev { worstGap = max(worstGap, (t.t - p) * 1000) }; prev = t.t }
        m["max_tick_gap_ms"] = worstGap
        if sc.maxTickGapMs > 0 && worstGap > sc.maxTickGapMs {
            fails.append(String(format: "the render thread waited %.0f ms between two display ticks (want <= %.0f ms)", worstGap, sc.maxTickGapMs))
        }
    }
    if let want = sc.expectLeave {
        let left = Int(HarnessStats.shared.get("ui_left_immersive"))
        m["ui_left_immersive"] = Double(left)
        if want && left < 1 { fails.append("the link was lost for a long time and the client never left the immersive space") }
        if !want && left > 0 { fails.append("a short link loss made the client leave the immersive space") }
        if want && !EventHandler.shared.renderStarted { fails.append("the client did not come back into the stream after the link returned") }
    }
    if sc.expectExit {
        fails.append("the client did not exit although the app stayed in the background")
    }
    if Int(m["reconnects"] ?? 0) > sc.maxReconnects {

        fails.append("the client tore the connection down \(Int(m["reconnects"]!)) time(s) (fatal decoder error)")
    }
    return Verdict(scenario: sc.name, pass: fails.isEmpty, failures: fails, metrics: m, clientLines: clientLines, harnessEvents: events)
}

// MARK: - Main

let args = CommandLine.arguments
func argValue(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if args.count < 2 || args[1] == "list" {
    for s in scenarios { Swift.print("\(s.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(s.about)") }
    Glibc.exit(0)
}
guard args[1] == "run", args.count >= 3, let sc = scenarios.first(where: { $0.name == args[2] }) else {
    Swift.print("usage: protocol_harness list | run <scenario> [--out DIR] [--echo]")
    Glibc.exit(3)
}
let outDir = argValue("--out") ?? "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
HarnessLog.shared.open(path: "\(outDir)/\(sc.name).log")
HarnessLog.shared.echo = args.contains("--echo")

var lastPhaseStart = 0.0
func writeVerdict(_ v: Verdict) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(v) {
        FileManager.default.createFile(atPath: "\(outDir)/\(sc.name).json", contents: d)
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
HarnessLog.shared.onFinish = {
    // the client called exit(): record what was seen up to there
    var v = evaluate(sc, lastPhaseStart: lastPhaseStart, end: HarnessLog.shared.now())
    if sc.expectExit {
        v.failures = []
    } else {
        v.failures = ["the client called exit() itself"]
    }
    v.pass = sc.expectExit
    writeVerdict(v)
}

// ALVRClientApp.swift:128-130 (scene active): initialise the core, start the event thread
if ProcessInfo.processInfo.environment["HARNESS_OLD_PICK"] == "1" { EventHandler.catchUpPick = false }   // the pick before the catch-up rule
// The SwiftUI side (ALVRClientApp / EntryControls), modelled: leaving dismisses the immersive space and shows the Entry window;
// with auto-connect on, the next connected state (the streamer is found again) opens the immersive space.
EventHandler.shared.onLeaveStream = {
    HarnessStats.shared.count("ui_left_immersive")
    HarnessLog.shared.event("ui_left_immersive")
    EventHandler.shared.renderStarted = false      // MetalClientSystem: the layer is invalidated, the loop ends
    DisplaySim.shared.stop()
    Thread { // auto-connect, the edge disconnected -> connected
        while true {
            usleep(100_000)
            if EventHandler.shared.connectionState == .connected && !EventHandler.shared.renderStarted {
                usleep(800_000)  // openImmersiveSpace
                HarnessLog.shared.event("ui_entered_immersive")
                DisplaySim.shared.start()
                return
            }
        }
    }.start()
}
EventHandler.shared.initializeAlvr()
EventHandler.shared.start()

Thread {
    let host = Host()
    DisplaySim.shared.displayHz = sc.displayHz
    FakeCore.shared.refreshRateHint = Float(sc.hintHz)
    if sc.enterBeforeStream { DisplaySim.shared.start() }
    usleep(500_000)
    for (i, p) in sc.phases.enumerated() {
        if i == sc.phases.count - 1 { lastPhaseStart = HarnessLog.shared.now() }
        host.run(p)
    }
    let end = HarnessLog.shared.now()
    DisplaySim.shared.stop()
    usleep(200_000)
    let v = evaluate(sc, lastPhaseStart: lastPhaseStart, end: end)
    HarnessLog.shared.event("verdict", ["pass": "\(v.pass)"])
    writeVerdict(v)
    Glibc.exit(v.pass ? 0 : 1)
}.start()

dispatchMain()
