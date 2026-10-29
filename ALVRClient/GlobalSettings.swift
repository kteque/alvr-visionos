//
//  GlobalSettings.swift
//
// Client-side settings and defaults
//

import Foundation
import SwiftUI
import simd

struct GlobalSettings: Codable {
    var keepSteamVRCenter: Bool = false
    var showHandsOverlaid: Bool = false
    var disablePersistentSystemOverlays: Bool = true
    var enableDoubleTapForHands: Bool = false
    var streamFPS: String = "Default"
    var chromaKeyEnabled: Bool = false
    var chromaKeyFromStreamer: Bool = true
    var chromaKeyDistRangeMin: Float = 0.35
    var chromaKeyDistRangeMax: Float = 0.7
    var chromaKeyColorR: Float = 16.0 / 255.0
    var chromaKeyColorG: Float = 124.0 / 255.0
    var chromaKeyColorB: Float = 16.0 / 255.0
    var dismissWindowOnEnter: Bool = true
    var emulatedPinchInteractions: Bool = false
    /// Floor height offset in centimetres, added to whatever height the headset reports; positive raises the
    /// player in the game. 0 = the headset's reading as is.
    var heightOffsetCm: Int = 0
    /// On: hands also appear as controllers (pose, and a pinch is the trigger). Off: the hand skeleton only.
    var handsAsControllers: Bool = true
    /// Enter the streamer as soon as the connection is up, without pressing Enter.
    var autoConnect: Bool = false
    var targetHandsAtRoundtripLatency = false
    var showFaceTrackingDebug = false
    var lastUsedAppVersion = "never launched"
    var chaperoneDistanceCm: Int = 0
    var showPerformanceHud: Bool = false
    var claimControllerHomeButton: Bool = true
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.keepSteamVRCenter = try container.decodeIfPresent(Bool.self, forKey: .keepSteamVRCenter) ?? self.keepSteamVRCenter
        self.showHandsOverlaid = try container.decodeIfPresent(Bool.self, forKey: .showHandsOverlaid) ?? self.showHandsOverlaid
        self.disablePersistentSystemOverlays = try container.decodeIfPresent(Bool.self, forKey: .disablePersistentSystemOverlays) ?? self.disablePersistentSystemOverlays
        self.enableDoubleTapForHands = try container.decodeIfPresent(Bool.self, forKey: .enableDoubleTapForHands) ?? self.enableDoubleTapForHands
        self.streamFPS = try container.decodeIfPresent(String.self, forKey: .streamFPS) ?? self.streamFPS
        self.chromaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyEnabled) ?? self.chromaKeyEnabled
        self.chromaKeyFromStreamer = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyFromStreamer) ?? self.chromaKeyFromStreamer
        self.chromaKeyDistRangeMin = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMin) ?? self.chromaKeyDistRangeMin
        self.chromaKeyDistRangeMax = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMax) ?? self.chromaKeyDistRangeMax
        self.chromaKeyColorR = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorR) ?? self.chromaKeyColorR
        self.chromaKeyColorG = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorG) ?? self.chromaKeyColorG
        self.chromaKeyColorB = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorB) ?? self.chromaKeyColorB
        self.dismissWindowOnEnter = try container.decodeIfPresent(Bool.self, forKey: .dismissWindowOnEnter) ?? self.dismissWindowOnEnter
        self.emulatedPinchInteractions = try container.decodeIfPresent(Bool.self, forKey: .emulatedPinchInteractions) ?? self.emulatedPinchInteractions
        self.heightOffsetCm = try container.decodeIfPresent(Int.self, forKey: .heightOffsetCm) ?? self.heightOffsetCm
        self.handsAsControllers = try container.decodeIfPresent(Bool.self, forKey: .handsAsControllers) ?? self.handsAsControllers
        self.autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? self.autoConnect
        self.targetHandsAtRoundtripLatency = try container.decodeIfPresent(Bool.self, forKey: .targetHandsAtRoundtripLatency) ?? self.targetHandsAtRoundtripLatency
        self.showFaceTrackingDebug = try container.decodeIfPresent(Bool.self, forKey: .showFaceTrackingDebug) ?? self.showFaceTrackingDebug
        self.lastUsedAppVersion = try container.decodeIfPresent(String.self, forKey: .lastUsedAppVersion) ?? self.lastUsedAppVersion
        self.chaperoneDistanceCm = try container.decodeIfPresent(Int.self, forKey: .chaperoneDistanceCm) ?? self.chaperoneDistanceCm
        self.showPerformanceHud = try container.decodeIfPresent(Bool.self, forKey: .showPerformanceHud) ?? self.showPerformanceHud
        self.claimControllerHomeButton = try container.decodeIfPresent(Bool.self, forKey: .claimControllerHomeButton) ?? self.claimControllerHomeButton
    }
}

extension GlobalSettings {
    /// Tangent CEILING (left, right, up, down) for one eye, not a wearer's window: a generous per-edge box that covers the wearers measured so far
    /// with about 2 degrees of margin (docs/FOV_CLIENT_CEILING.md in the AirFrameXR repo: the author's either-gaze 100 % box 1.03 / 0.74 / 0.71 / 0.62 and a
    /// second wearer's following-gaze box 0.93 / 0.67 / 0.68 / 0.80). The per-person restriction lives on the PC (the streamer's Advanced window, the
    /// profile button): the streamer can only go DOWN from what is declared here, so this box is what bounds it. The declare path circumscribes the
    /// canted views, which multiplies these by about 1.017: the host sees about 1.05 / 0.80 / 0.76 / 0.87 (check config\airframexr_views.json).
    /// Given as outer / inner / up / down; the right eye mirrors it, so outer and inner swap. Nothing is settable on the headset: a wearer who sees
    /// black beyond an edge needs a larger constant here (a rebuild), one who sees less restricts on the PC.
    /// CALIBRATION BUILD (branch `calibration`, temporary): no ceiling at all, the headset declares its drawable's own tangents (about 1.79 / 1.02 / 1.22 / 1.02),
    /// so the FoV sweep (fov_sweep.exe, docs/FOV_CALIBRATION.md) can reach any wearer's visible edge. Run it with the streamer's override and
    /// stream fit unticked. The released client (branch airframexr-client) declares the ceiling 1.03 / 0.79 / 0.75 / 0.86 instead.
    static func visibleFovTangents(isLeftEye: Bool) -> simd_float4 {
        let outerInnerUpDown = simd_float4(10.0, 10.0, 10.0, 10.0)
        return isLeftEye ? outerInnerUpDown : simd_float4(outerInnerUpDown.y, outerInnerUpDown.x, outerInnerUpDown.z, outerInnerUpDown.w)
    }
}

extension GlobalSettingsStore {
    static let sampleData: GlobalSettingsStore =
    GlobalSettingsStore()
}

class GlobalSettingsStore: ObservableObject {
    @Published var settings: GlobalSettings = GlobalSettings()
    
    init() {
        try? load()
    }

    private static func fileURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        .appendingPathComponent("globalsettings.data")
    }
    
    func load() throws {
        let fileURL = try Self.fileURL()
        guard let data = try? Data(contentsOf: fileURL) else {
            return self.settings = GlobalSettings()
        }
        let globalSettings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        self.settings = globalSettings
    }
    
    func save(settings: GlobalSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let outfile = try Self.fileURL()
        try data.write(to: outfile)
    }
}
