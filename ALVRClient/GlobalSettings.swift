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
    var streamFPS: String = "Default"
    var chromaKeyEnabled: Bool = false
    var chromaKeyFromStreamer: Bool = true
    var chromaKeyDistRangeMin: Float = 0.35
    var chromaKeyDistRangeMax: Float = 0.7
    var chromaKeyColorR: Float = 16.0 / 255.0
    var chromaKeyColorG: Float = 124.0 / 255.0
    var chromaKeyColorB: Float = 16.0 / 255.0
    var dismissWindowOnEnter: Bool = true
    /// Floor height offset in centimetres, added to whatever height the headset reports; positive raises the
    /// player in the game. 0 = the headset's reading as is.
    var heightOffsetCm: Int = 0
    /// Enter the streamer as soon as the connection is up, without pressing Enter.
    var autoConnect: Bool = false
    /// FoV scale per axis (0.6 to 1.4) on the field of view declared to the streamer; 1.0 = the compositor's whole frustum.
    /// Horizontal scales the left and right edges, vertical the top and bottom edges.
    var fovScaleH: Float = 1.0
    var fovScaleV: Float = 1.0
    /// False = "Default FoV" is on: both axes are 1.0 and the sliders are hidden. Turning it on resets both to 1.0.
    var fovCustom: Bool = false
    var targetHandsAtRoundtripLatency = false
    var showFaceTrackingDebug = false
    var lastUsedAppVersion = "never launched"
    var chaperoneDistanceCm: Int = 0
    var claimControllerHomeButton: Bool = true
    /// Translation correction through the compositor (test build): the distance in cm of the plane the picture is treated as lying on, so
    /// that visionOS corrects the head's movement since the frame was rendered (position as well as rotation). 0 = off (the 1.3.9 way:
    /// our own rotation-only warp, depth at infinity). Near objects swim a little when the plane is far from them.
    var translationPlaneCm: Int = 300
    
    private enum LegacyKeys: String, CodingKey { case fovRenderScale }

    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.keepSteamVRCenter = try container.decodeIfPresent(Bool.self, forKey: .keepSteamVRCenter) ?? self.keepSteamVRCenter
        self.showHandsOverlaid = try container.decodeIfPresent(Bool.self, forKey: .showHandsOverlaid) ?? self.showHandsOverlaid
        self.disablePersistentSystemOverlays = try container.decodeIfPresent(Bool.self, forKey: .disablePersistentSystemOverlays) ?? self.disablePersistentSystemOverlays
        self.streamFPS = try container.decodeIfPresent(String.self, forKey: .streamFPS) ?? self.streamFPS
        self.chromaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyEnabled) ?? self.chromaKeyEnabled
        self.chromaKeyFromStreamer = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyFromStreamer) ?? self.chromaKeyFromStreamer
        self.chromaKeyDistRangeMin = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMin) ?? self.chromaKeyDistRangeMin
        self.chromaKeyDistRangeMax = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMax) ?? self.chromaKeyDistRangeMax
        self.chromaKeyColorR = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorR) ?? self.chromaKeyColorR
        self.chromaKeyColorG = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorG) ?? self.chromaKeyColorG
        self.chromaKeyColorB = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorB) ?? self.chromaKeyColorB
        self.dismissWindowOnEnter = try container.decodeIfPresent(Bool.self, forKey: .dismissWindowOnEnter) ?? self.dismissWindowOnEnter
        self.heightOffsetCm = try container.decodeIfPresent(Int.self, forKey: .heightOffsetCm) ?? self.heightOffsetCm
        self.autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? self.autoConnect
        // Before 1.3.6 one uniform factor (fovRenderScale) covered both axes: it becomes both, so nothing changes for existing installs.
        let legacyFovScale = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Float.self, forKey: .fovRenderScale) ?? 1.0
        self.fovScaleH = try container.decodeIfPresent(Float.self, forKey: .fovScaleH) ?? legacyFovScale
        self.fovScaleV = try container.decodeIfPresent(Float.self, forKey: .fovScaleV) ?? legacyFovScale
        // A value saved by an earlier build that is not 1.0 keeps its sliders showing (never silently reset).
        self.fovCustom = try container.decodeIfPresent(Bool.self, forKey: .fovCustom) ?? (self.fovScaleH != 1.0 || self.fovScaleV != 1.0)
        self.targetHandsAtRoundtripLatency = try container.decodeIfPresent(Bool.self, forKey: .targetHandsAtRoundtripLatency) ?? self.targetHandsAtRoundtripLatency
        self.showFaceTrackingDebug = try container.decodeIfPresent(Bool.self, forKey: .showFaceTrackingDebug) ?? self.showFaceTrackingDebug
        self.lastUsedAppVersion = try container.decodeIfPresent(String.self, forKey: .lastUsedAppVersion) ?? self.lastUsedAppVersion
        self.chaperoneDistanceCm = try container.decodeIfPresent(Int.self, forKey: .chaperoneDistanceCm) ?? self.chaperoneDistanceCm
        self.claimControllerHomeButton = try container.decodeIfPresent(Bool.self, forKey: .claimControllerHomeButton) ?? self.claimControllerHomeButton
        self.translationPlaneCm = try container.decodeIfPresent(Int.self, forKey: .translationPlaneCm) ?? self.translationPlaneCm
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
