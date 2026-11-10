// Pacing rig client: the visionOS client's protocol layer (ALVRClient/EventHandler.swift, unchanged) on the REAL alvr_client_core,
// receiving a real stream from the real streamer over the network. The decoder is a stand-in (counter picture, modelled decode
// time), the render thread is DisplaySim (the same model as the protocol harness). See docs/VISIONOS_PERFORMANCE_PLAN.md section C.
//
//   rig_client --out DIR [--seconds N] [--display-hz 100] [--switch t:hz[:stall_ms]]... [--view-width W --view-height H (declared per eye)] [--yaw-amp 0.5 --yaw-hz 0.25] [--miss-rate 0.0022] [--storm t0_s:peak:tau_s[:stall_ms]]... [--strict-deadline 0] [--decode-ms 5] [--decode-sd-ms 1]
//              [--gpu-ms 4] [--net-ms 2.5 --net-sd-ms 1] [--hiccup t:ms]... [--hiccup-rate N/min --hiccup-ms lo:hi] [--seed N] [--echo] [--width W --height H]

import Foundation
import AppleShims

let args = CommandLine.arguments
func argValue(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func argValues(_ k: String) -> [String] { args.enumerated().filter { $0.element == k && $0.offset + 1 < args.count }.map { args[$0.offset + 1] } }

let outDir = argValue("--out") ?? "."
let seconds = Double(argValue("--seconds") ?? "") ?? 60
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
HarnessLog.shared.open(path: "\(outDir)/rig_client.log")
HarnessLog.shared.echo = args.contains("--echo")
if let v = argValue("--net-ms").flatMap(Double.init) { RigNet.meanMs = v }
if let v = argValue("--net-sd-ms").flatMap(Double.init) { RigNet.sdMs = v }
if let v = argValue("--seed").flatMap(UInt64.init) { RigNet.seed = v }
for h in argValues("--hiccup") { let p = h.split(separator: ":").map { Double($0) ?? 0 }; if p.count == 2 { RigNet.scripted.append((p[0], p[1])) } }
RigNet.scripted.sort { $0.t < $1.t }
if let v = argValue("--hiccup-rate").flatMap(Double.init) { RigNet.ratePerMin = v }
if let v = argValue("--hiccup-ms") { let p = v.split(separator: ":").map { Double($0) ?? 0 }; if p.count == 2 { RigNet.randLoMs = p[0]; RigNet.randHiMs = p[1] } }
if let v = argValue("--view-width").flatMap(Int.init) { renderWidth = v / 2; RigConfig.width = v }
if let v = argValue("--view-height").flatMap(Int.init) { renderHeight = v / 2; RigConfig.height = v }
if let v = argValue("--yaw-amp").flatMap(Double.init) { RigPose.yawAmp = v }
if let v = argValue("--yaw-hz").flatMap(Double.init) { RigPose.yawHz = v }
if let v = argValue("--decode-ms").flatMap(Double.init) { RigConfig.decodeMs = v }
if let v = argValue("--decode-sd-ms").flatMap(Double.init) { RigConfig.decodeSdMs = v }
if let v = argValue("--gpu-ms").flatMap(Double.init) { DisplaySim.shared.gpuMs = v }
if let v = argValue("--width").flatMap(Int.init) { RigConfig.width = v }
if let v = argValue("--height").flatMap(Int.init) { RigConfig.height = v }
DisplaySim.shared.displayHz = Double(argValue("--display-hz") ?? "") ?? 100
// field model: the display keeps its rate, the render thread misses deadlines (baseline + storms); --strict-deadline 0 keeps the harness's old rule
DisplaySim.shared.strictDeadline = (argValue("--strict-deadline") ?? "1") != "0"
if let v = argValue("--miss-rate").flatMap(Double.init) { RigMisses.baseRate = v }
for st in argValues("--storm") { let p = st.split(separator: ":").map { Double($0) ?? 0 }; if p.count >= 3 { RigMisses.storms.append((p[0], p[1], p[2], p.count > 3 ? p[3] : 0)) } }
RigMisses.storms.sort { $0.t0 < $1.t0 }
DisplaySim.shared.extraCostMs = { RigMisses.shared.extraCostMs() }

func writeReport() {
    let ds = DisplaySim.shared
    ds.lock.lock(); let ticks = ds.ticks; let sw = ds.switchTimes; ds.lock.unlock()
    var csv = "t,shown,frame,bytes\n"
    for t in ticks { csv += String(format: "%.4f,%@,%d,%d\n", t.t, "\(t.shown)", Int(t.frameIndex ?? 0), RigFrames.shared.size(t.frameIndex ?? 0)) }
    // the window where game content was on screen: from the first to the last tick that showed a content-sized frame
    let content = ticks.enumerated().filter { RigFrames.shared.size($0.element.frameIndex ?? 0) >= RigFrames.contentBytes }.map { $0.offset }
    try? csv.write(toFile: "\(outDir)/ticks.csv", atomically: true, encoding: .utf8)
    // per-10 s windows in the form of the client's own `display interval` line (presentation-time gaps, misses): comparable with the field logs
    var wcsv = "t_start,mean_ms,min_ms,max_ms,frames,over15,misses\n"
    if ticks.count > 2 {
        var i = 0
        while i < ticks.count - 1 {
            let t0w = ticks[i].t; var gaps: [Double] = []; var miss = 0; var j = i
            while j < ticks.count - 1 && ticks[j].t < t0w + 10 { gaps.append((ticks[j + 1].vsync - ticks[j].vsync) * 1000); if ticks[j].missed { miss += 1 }; j += 1 }
            if !gaps.isEmpty && ticks[j].t >= t0w + 9.9 {
                wcsv += String(format: "%.1f,%.3f,%.3f,%.1f,%d,%d,%d\n", t0w, gaps.reduce(0, +) / Double(gaps.count), gaps.min()!, gaps.max()!, gaps.count + 1, gaps.filter { $0 > 15 }.count, miss)
            }
            i = max(j, i + 1)
        }
    }
    try? wcsv.write(toFile: "\(outDir)/windows.csv", atomically: true, encoding: .utf8)
    let n = Double(max(ticks.count, 1))
    let new = Double(ticks.filter { $0.shown == .new }.count), rep = Double(ticks.filter { $0.shown == .repeated }.count)
    let blank = Double(ticks.filter { $0.shown == .blank }.count)
    var m: [String: Double] = ["ticks": n, "new": new, "repeated": rep, "blank": blank, "new_fraction": new / n, "switches": Double(sw.count),
                               "decoded_frames": Double(HarnessStats.shared.get("decoded")), "catchup_drops": Double(EventHandler.shared.catchUpDrops)]
    if let a = content.first, let b = content.last, b > a {
        let w = Array(ticks[a...b]); let wn = Double(w.count)
        m["win_ticks"] = wn; m["win_s"] = w.last!.t - w.first!.t
        m["win_new"] = Double(w.filter { $0.shown == .new }.count); m["win_new_fraction"] = m["win_new"]! / wn
        m["win_repeated_fraction"] = Double(w.filter { $0.shown == .repeated }.count) / wn
        m["win_blank_fraction"] = Double(w.filter { $0.shown == .blank }.count) / wn
        // doubled intervals: a new frame followed by a tick without one, counted per 1000 ticks, and the longest run of ticks without a new frame
        var run = 0, worst = 0, gaps = 0
        for t in w { if t.shown == .new { if run >= 1 { gaps += 1 }; run = 0 } else { run += 1; worst = max(worst, run) } }
        m["win_new_gaps_per_1000"] = Double(gaps) / wn * 1000; m["win_worst_run_ticks"] = Double(worst)
        // new frames per display vsync: the compositor's updates in the window (presentation-time span over the median interval) that showed a new frame;
        // a missed deadline skips vsyncs, which the share of rendered ticks does not see
        let gapsMs = (1..<w.count).map { w[$0].vsync - w[$0 - 1].vsync }.sorted()
        if !gapsMs.isEmpty {
            let period = gapsMs[gapsMs.count / 2]
            let vsyncs = ((w.last!.vsync - w.first!.vsync) / period).rounded() + 1
            m["win_vsyncs"] = vsyncs
            m["win_new_per_vsync"] = m["win_new"]! / vsyncs
            m["win_skipped_vsync_per_1000"] = (vsyncs - wn) / vsyncs * 1000
        }
        // frame age at display: the tick's presentation time minus the presentation time the frame's pose was predicted for (client clock only)
        let ages = w.filter { $0.shown == .new && $0.frameTs > 0 }.map { ($0.vsync - Double($0.frameTs) / 1e9) * 1000 }.sorted()
        if !ages.isEmpty {
            func q(_ f: Double) -> Double { ages[min(ages.count - 1, Int(Double(ages.count) * f))] }
            m["win_age_p50_ms"] = q(0.5); m["win_age_p95_ms"] = q(0.95); m["win_age_p99_ms"] = q(0.99); m["win_age_max_ms"] = ages.last!
        }
        // age of a fresh frame in the queue (decoded -> picked), the field's `fresh frame age in queue`: the latency a margin or a pick policy costs
        let qages = w.filter { $0.shown == .new }.compactMap { t -> Double? in
            guard let d = RigFrames.shared.decodedTime(t.frameIndex ?? 0) else { return nil }; return (t.pickT - d) * 1000 }.sorted()
        if !qages.isEmpty {
            m["win_queue_age_mean_ms"] = qages.reduce(0, +) / Double(qages.count)
            m["win_queue_age_p95_ms"] = qages[min(qages.count - 1, Int(Double(qages.count) * 0.95))]
        }
        // repeats by cause (per 1000 ticks): the pick's result when it had nothing new, and the render thread's missed deadlines (doubled intervals)
        m["win_pick_resubmit_per_1000"] = Double(w.filter { $0.pick == 2 }.count) / wn * 1000
        m["win_pick_reprojected_per_1000"] = Double(w.filter { $0.pick == 3 }.count) / wn * 1000
        m["win_pick_none_per_1000"] = Double(w.filter { $0.pick == 0 }.count) / wn * 1000
        m["win_missed_deadline_per_1000"] = Double(w.filter { $0.missed }.count) / wn * 1000
        // worst second: the lowest share of new frames in any 100 consecutive ticks
        if w.count >= 100 { var best = 1.0; var cnt = w[0..<100].filter { $0.shown == .new }.count
            for i in 100..<w.count { cnt += (w[i].shown == .new ? 1 : 0) - (w[i - 100].shown == .new ? 1 : 0); best = min(best, Double(cnt) / 100) }
            m["win_worst_100tick_new_fraction"] = best }
    }
    let st = HarnessStats.shared
    st.lock.lock(); for (k, v) in st.counters { m["ev_" + k] = Double(v) }; m["decoded_frames"] = Double(st.decodedFrames); st.lock.unlock()
    if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
        FileManager.default.createFile(atPath: "\(outDir)/rig_summary.json", contents: d)
        FileHandle.standardOutput.write(d); FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
HarnessLog.shared.onFinish = { HarnessLog.shared.event("client_exit_called"); writeReport() }

EventHandler.shared.initializeAlvr()
var hn = [CChar](repeating: 0, count: 256)
_ = alvr_hostname(&hn)
Swift.print("rig client hostname: \(String(cString: hn))")
HarnessLog.shared.event("hostname", ["name": String(cString: hn)])
EventHandler.shared.start()

Thread {
    var sched: [(Double, Double, Double)] = []
    for s in argValues("--switch") {
        let p = s.split(separator: ":").map { Double($0) ?? 0 }
        if p.count >= 2 { sched.append((p[0], p[1], p.count > 2 ? p[2] : 0)) }
    }
    sched.sort { $0.0 < $1.0 }
    DisplaySim.shared.start()
    let t0 = CACurrentMediaTime()
    var lastStat = t0
    var i = 0
    while CACurrentMediaTime() - t0 < seconds {
        usleep(100_000)
        let el = CACurrentMediaTime() - t0
        if i < sched.count && el >= sched[i].0 { DisplaySim.shared.switchDisplay(hz: sched[i].1, stallMs: sched[i].2); i += 1 }
        if CACurrentMediaTime() - lastStat >= 5 {
            lastStat = CACurrentMediaTime()
            let ds = DisplaySim.shared
            ds.lock.lock(); let tk = ds.ticks.suffix(500); ds.lock.unlock()
            let n = Double(max(tk.count, 1))
            let f = Double(tk.filter { $0.shown == .new }.count) / n
            Swift.print(String(format: "[rig %5.0fs] streaming=%@ decoded=%d new=%.0f%% (last %d ticks)", el, "\(EventHandler.shared.streamingActive)", HarnessStats.shared.decodedFrames, f * 100, tk.count))
        }
    }
    DisplaySim.shared.stop()
    usleep(200_000)
    writeReport()
    Glibc.exit(0)
}.start()
dispatchMain()
