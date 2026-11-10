// Pacing rig client: the visionOS client's protocol layer (ALVRClient/EventHandler.swift, unchanged) on the REAL alvr_client_core,
// receiving a real stream from the real streamer over the network. The decoder is a stand-in (counter picture, modelled decode
// time), the render thread is DisplaySim (the same model as the protocol harness). See docs/VISIONOS_PERFORMANCE_PLAN.md section C.
//
//   rig_client --out DIR [--seconds N] [--display-hz 100] [--switch t:hz[:stall_ms]]... [--view-width W --view-height H (declared per eye)] [--yaw-amp 0.5 --yaw-hz 0.25] [--decode-ms 5] [--decode-sd-ms 1]
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

func writeReport() {
    let ds = DisplaySim.shared
    ds.lock.lock(); let ticks = ds.ticks; let sw = ds.switchTimes; ds.lock.unlock()
    var csv = "t,shown,frame\n"
    for t in ticks { csv += String(format: "%.4f,%@,%d\n", t.t, "\(t.shown)", Int(t.frameIndex ?? 0)) }
    try? csv.write(toFile: "\(outDir)/ticks.csv", atomically: true, encoding: .utf8)
    let n = Double(max(ticks.count, 1))
    let new = Double(ticks.filter { $0.shown == .new }.count), rep = Double(ticks.filter { $0.shown == .repeated }.count)
    let blank = Double(ticks.filter { $0.shown == .blank }.count)
    var m: [String: Double] = ["ticks": n, "new": new, "repeated": rep, "blank": blank, "new_fraction": new / n, "switches": Double(sw.count),
                               "decoded_frames": Double(HarnessStats.shared.get("decoded")), "catchup_drops": Double(EventHandler.shared.catchUpDrops)]
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
