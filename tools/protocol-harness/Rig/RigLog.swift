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

