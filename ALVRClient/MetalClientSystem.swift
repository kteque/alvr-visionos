//
//  MetalClientSystem.swift
//
// MetalClientSystem owns the CompositorLayer render loop.
//

import CompositorServices
import Metal
import QuartzCore   // CACurrentMediaTime for the double-tap timing
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

// Render target description shared by the renderer and the capabilities sent to the streamer.
let renderWidth = Int(1888)
let renderHeight = Int(1824)
let renderColorFormatSDR = MTLPixelFormat.bgra8Unorm_srgb
var renderColorFormatHDR = MTLPixelFormat.rgba16Float
let renderColorFormatDrawableSDR = renderColorFormatSDR
var renderColorFormatDrawableHDR = MTLPixelFormat.rgba16Float
let renderColorFormatVisionOS2HDR = MTLPixelFormat.rgba16Float
let renderColorFormatDrawableVisionOS2HDR = MTLPixelFormat.rgba16Float
let renderDepthFormat = MTLPixelFormat.depth16Unorm
let renderViewCount = 2

class MetalClientSystem {

    var renderer: Renderer;
    let layerRenderer: LayerRenderer

    init(_ layerRenderer: LayerRenderer) {
        self.renderer = Renderer(layerRenderer)
        self.layerRenderer = layerRenderer
    }

    func startRenderLoop() {
        Task(priority: .userInteractive) {
            renderer.rebuildRenderPipelines()
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }
    
    func renderLoop() {
    
        layerRenderer.waitUntilRunning()
        
        EventHandler.shared.handleHeadsetRemovedOrReentry()
        let timeSinceLastLoop = CACurrentMediaTime()
        while EventHandler.shared.renderStarted {
            if layerRenderer.state == .invalidated && EventHandler.shared.leaveRequested {
                // the app left the space itself (link lost): no alvr_pause, no exit(0), the Entry window is back
                print("Layer is invalidated: left on a lost link")
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetRemoved()
                WorldTracker.shared.resetPlayspace()
                EventHandler.shared.renderStarted = false
                EventHandler.shared.leaveRequested = false
                break
            } else if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                //EventHandler.shared.stop()
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetRemoved()
                WorldTracker.shared.resetPlayspace()
                alvr_pause()

                // visionOS sometimes sends these invalidated things really fkn late...
                // But generally, we want to exit fully when the user exits.
                if CACurrentMediaTime() - timeSinceLastLoop < 1.0 {
                    exit(0)
                }
                break
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                //EventHandler.shared.handleHeadsetRemovedOrReentry()
                continue
            } else {
                autoreleasepool {
                    renderer.renderFrame()
                }
            }
        }
    }
}
