// The render thread, reduced to its protocol and frame-selection behaviour: MetalClientSystem.renderLoop
// (MetalClientSystem.swift:58-93) + Renderer.renderFrame (Renderer.swift:668-1046) without Metal. The shared-state
// accesses keep the real code's locking (or lack of it), so ThreadSanitizer sees the same races. Each block names the
// lines it mirrors; when the real code changes, change this file with it.

import Foundation
import AppleShims

final class DisplaySim: @unchecked Sendable {
    static let shared = DisplaySim()

    var displayHz = 90.0
    var gpuMs = Double(ProcessInfo.processInfo.environment["HARNESS_GPU_MS"] ?? "") ?? 6.0
    var ipd: Float = 0.063
    private var thread: Thread? = nil
    private var running = false

    // what the wearer saw, one entry per display tick
    enum Shown { case blank, new, repeated }
    struct Tick { let t: Double; let shown: Shown; let frameIndex: UInt32?; let ageMs: Double?; let depth: Int }   // depth: decoded frames waiting when the tick picked
    let lock = NSLock()
    var ticks: [Tick] = []
    // when the host sent each frame (frame age at the display tick = tick time - this)
    var sentAt: [UInt32: Double] = [:]
    func noteSent(_ index: UInt32) { lock.lock(); sentAt[index] = HarnessLog.shared.now(); lock.unlock() }
    // a display rate switch (the system picks 90/96/100 Hz) with the render thread stalled for `stallMs` at that moment
    var pendingStallMs = 0.0
    var switchTimes: [Double] = []
    func switchDisplay(hz: Double, stallMs: Double) {
        lock.lock(); switchTimes.append(HarnessLog.shared.now()); lock.unlock()
        displayHz = hz
        pendingStallMs = stallMs
    }

    func start() {
        running = true
        // Renderer.swift:279-280
        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
        HarnessLog.shared.event("render_started")
        let t = Thread { [self] in loop() }
        t.name = "Render Thread"
        thread = t
        t.start()
    }

    func stop() { running = false }

    private func loop() {
        // MetalClientSystem.swift:68
        EventHandler.shared.handleHeadsetRemovedOrReentry()
        var period = 1.0 / displayHz
        var nextVsync = CACurrentMediaTime() + period
        while running && EventHandler.shared.renderStarted {
            if abs(1.0 / displayHz - period) > 1e-9 {
                // the compositor's schedule follows the new rate from the next frame (and the stall, if any, delays it)
                period = 1.0 / displayHz
                nextVsync = CACurrentMediaTime() + period + pendingStallMs / 1000
                if pendingStallMs > 0 { usleep(UInt32(pendingStallMs * 1000)); pendingStallMs = 0 }
            }
            // queryNextFrame/predictTiming + Clock.wait(until: optimalInputTime): optimal input ~ one period before presentation
            let optimalInput = nextVsync - period
            let now = CACurrentMediaTime()
            if optimalInput > now { usleep(UInt32((optimalInput - now) * 1e6)) }
            renderFrame(presentation: nextVsync)
            nextVsync += period
            let late = CACurrentMediaTime() - nextVsync
            if late > 0 { // a missed frame: the compositor moves on to the next vsync
                let skip = (late / period).rounded(.up)
                nextVsync += skip * period
                HarnessStats.shared.count("missed_vsync")
            }
        }
    }

    private func renderFrame(presentation vsyncTime: Double) {
        let eh = EventHandler.shared
        // Renderer.swift:670-673
        eh.framesRendered += 1
        eh.totalFramesRendered += 1
        var streamingActiveForFrame = eh.streamingActive
        var isReprojected = false
        var pickedFresh = false
        var queuedFrame: QueuedFrame? = nil

        // Renderer.swift:688-702: the pick is EventHandler.pollFrameForDisplay (client code, compiled in)
        objc_sync_enter(eh.frameQueueLock); let depthAtPick = eh.frameQueue.count; objc_sync_exit(eh.frameQueueLock)
        let pickStart = CACurrentMediaTime()
        let pick = eh.pollFrameForDisplay(timeout: 0.005)
        HarnessStats.shared.count("pick_wait_ms_total", by: Int((CACurrentMediaTime() - pickStart) * 1e3))
        switch pick {
        case .resubmit(let f):
            HarnessStats.shared.count("pick_resubmit")
            queuedFrame = f
            eh.framesRendered -= 1
            isReprojected = false
        case .fresh(let f):
            HarnessStats.shared.count("pick_fresh")
            pickedFresh = true
            queuedFrame = f
        case .reprojected(let f):
            HarnessStats.shared.count("pick_reprojected")
            queuedFrame = f
            eh.framesRendered -= 1
            isReprojected = true
        case .none:
            HarnessStats.shared.count("pick_none")
        }
        if queuedFrame == nil && streamingActiveForFrame { streamingActiveForFrame = false }
        let renderingStreaming = streamingActiveForFrame && queuedFrame != nil

        // Renderer.swift:753-756
        if queuedFrame != nil && !queuedFrame!.viewParamsValid {
            let p = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
            defer { p.deallocate() }
            alvr_report_compositor_start(queuedFrame!.timestamp, p)
            queuedFrame = QueuedFrame(imageBuffer: queuedFrame!.imageBuffer, timestamp: queuedFrame!.timestamp, viewParamsValid: true, viewParams: [p[0], p[1]])
        }

        // Renderer.swift:758-818: first frame of a stream declares the views (and starts a pipeline rebuild: not modelled)
        if eh.alvrInitialized && streamingActiveForFrame {
            if abs(eh.lastIpd - ipd) > 0.001 {
                print("Send view config")
                if eh.lastIpd == -1 {
                    print("IPD is", ipd)
                    eh.framesRendered = 0
                }
                eh.lastIpd = ipd
                WorldTracker.shared.sendViewParams(viewTransforms: eh.viewTransforms, viewFovs: eh.viewFovs)
            }
        }

        // Renderer.swift:848-850
        objc_sync_enter(eh.frameQueueLock)
        eh.framesSinceLastDecode += 1
        objc_sync_exit(eh.frameQueueLock)

        // Renderer.swift:866-893: tracking for this presentation
        if eh.alvrInitialized && eh.lastIpd != -1 {
            WorldTracker.shared.sendTracking(reportedTargetTimestamp: vsyncTime)
        }

        // Renderer.swift:903-913: the command buffer's completed handler runs on another thread after the GPU work
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        let submitted = queuedFrame
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + gpuMs / 1000) {
            if eh.alvrInitialized, let submitted, eh.markSubmitted(submitted.timestamp) {
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                alvr_report_submit(submitted.timestamp, vsyncTimeNs > currentTimeNs ? vsyncTimeNs - currentTimeNs : 0)
            }
        }

        // Renderer.swift:920-938
        var frameIsSuitableForDisplaying = true
        if eh.lastIpd == -1 || eh.framesRendered < Int(refreshRate) { frameIsSuitableForDisplaying = false }
        if eh.videoFormat == nil { frameIsSuitableForDisplaying = false }

        let shown: Shown
        if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
            // only a frame taken from the queue is new: a resubmit shows the previous picture again, like a reprojection
            shown = pickedFresh ? .new : .repeated
        } else {
            shown = .blank
        }
        lock.lock()
        let nowT = HarnessLog.shared.now()
        var ageMs: Double? = nil
        if shown == .new, let i = queuedFrame?.imageBuffer.frameIndex, let sent = sentAt[i] { ageMs = (nowT - sent) * 1000 }
        ticks.append(Tick(t: nowT, shown: shown, frameIndex: queuedFrame?.imageBuffer.frameIndex, ageMs: ageMs, depth: depthAtPick))
        lock.unlock()

        // the frame's own CPU cost before endSubmission (encode + commit)
        usleep(1000)

        // Renderer.swift:1044-1045
        eh.publishShownFrame(queuedFrame)
        eh.lastQueuedFramePose = nil
    }
}
