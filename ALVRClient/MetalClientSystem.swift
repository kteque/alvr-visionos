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
        
        layerRenderer.onSpatialEvent = { eventCollection in
            for event in eventCollection {
                WorldTracker.handleSpatialEvent(event)
            }
        }
        
        EventHandler.shared.handleHeadsetRemovedOrReentry()
        let timeSinceLastLoop = CACurrentMediaTime()
        while EventHandler.shared.renderStarted {
            if layerRenderer.state == .invalidated {
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

extension WorldTracker {
    static func handleSpatialEvent(_ event: SpatialEventCollection.Event) {
        var isInProgressPinch = false
        var isRight = false
        if event.id.hashValue == WorldTracker.shared.leftSelectionRayId {
            isInProgressPinch = true
        }
        else if event.id.hashValue == WorldTracker.shared.rightSelectionRayId {
            isInProgressPinch = true
            isRight = true
        }
        
        /*if #available(visionOS 2.0, *) {
            print(event.chirality, event.phase, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
        }*/
        
        if event.kind == .indirectPinch && event.phase == .active {
            if !isInProgressPinch {
            
                // If we have chiralities, assign based on them
                if #available(visionOS 2.0, *) {
                    if event.chirality == .none {
                        if WorldTracker.shared.leftSelectionRayId != -1 {
                            isRight = true
                        }
                    }
                    else {
                        isRight = event.chirality == .right
                    }
                }
                else {
                    if WorldTracker.shared.leftSelectionRayId != -1 {
                        isRight = true
                    }
                }
                
                if isRight && WorldTracker.shared.rightSelectionRayId != -1 {
                    print("THIRD HAND??? early fallback")
                    
                    WorldTracker.shared.leftSelectionRayId = -1
                    WorldTracker.shared.rightSelectionRayId = -1
                    isRight = false
                    
                    print(event, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
                    return
                }
                
                if isRight {
                    WorldTracker.shared.rightSelectionRayId = event.id.hashValue
                }
                else if WorldTracker.shared.leftSelectionRayId == -1 {
                    WorldTracker.shared.leftSelectionRayId = event.id.hashValue
                }
                else {
                    print("THIRD HAND???")
                    print(event, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
                    return
                }
            }
            
            if !isInProgressPinch {
                // a pinch begins: a second one within 0.9 s of a short first one is a double tap (sent as A / X by the tracker, WorldTracker.pinchBeganAt)
                let h = isRight ? 1 : 0
                let now = CACurrentMediaTime()
                let w = WorldTracker.shared
                if w.pinchEndedAt[h] > w.pinchBeganAt[h] && now - w.pinchEndedAt[h] < 0.9 && w.pinchEndedAt[h] - w.pinchBeganAt[h] < 0.6 {
                    w.doubleTapUntil[h] = now + 0.15
                }
                w.pinchBeganAt[h] = now
            }
            if isRight {
                WorldTracker.shared.rightIsPinching = true
            }
            else {
                WorldTracker.shared.leftIsPinching = true
            }
        }
        else if event.kind == .indirectPinch {
            if event.id.hashValue == WorldTracker.shared.leftSelectionRayId {
                WorldTracker.shared.leftIsPinching = false
                WorldTracker.shared.leftSelectionRayId = -1
                WorldTracker.shared.pinchEndedAt[0] = CACurrentMediaTime()
            }
            else if event.id.hashValue == WorldTracker.shared.rightSelectionRayId {
                WorldTracker.shared.rightIsPinching = false
                WorldTracker.shared.rightSelectionRayId = -1
                WorldTracker.shared.pinchEndedAt[1] = CACurrentMediaTime()
            }
            return
        }
        
        //print(event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId, event.inputDevicePose)
    
        // For eyes: inputDevicePose is the pinch connect location, and the selection ray is
        // the eye center plus the gaze
        // For AssistiveTouch mouse: inputDevicePose is locked to the last plane the device was on, and
        // the selection ray is some random pose?
        // For keyboard accessibility touch: inputDevicePose is some random place, selectionRay is 0,0,0
        
        // selectionRay origin + direction
        if let ray = event.selectionRay {
            let origin = simd_float3(ray.origin)
            let direction = simd_normalize(simd_float3(ray.direction))
            let pos = origin + direction
            
            WorldTracker.shared.testPosition = pos
            if isRight {
                WorldTracker.shared.rightSelectionRayOrigin = origin
                WorldTracker.shared.rightSelectionRayDirection = direction
            }
            else {
                WorldTracker.shared.leftSelectionRayOrigin = origin
                WorldTracker.shared.leftSelectionRayDirection = direction
            }
        }
        
        // inputDevicePose
        if let inputPose = event.inputDevicePose {
            let pos = simd_float3(inputPose.pose3D.position)
            let rot = simd_quatf(inputPose.pose3D.rotation)
            //WorldTracker.shared.testPosition = pos
            
            // Started a pinch and have a start position
            if !isInProgressPinch {
                if isRight {
                    WorldTracker.shared.rightPinchStartPosition = pos
                    WorldTracker.shared.rightPinchCurrentPosition = pos
                    WorldTracker.shared.rightPinchStartAngle = rot
                    WorldTracker.shared.rightPinchCurrentAngle = rot
                }
                else {
                    WorldTracker.shared.leftPinchStartPosition = pos
                    WorldTracker.shared.leftPinchCurrentPosition = pos
                    WorldTracker.shared.leftPinchStartAngle = rot
                    WorldTracker.shared.leftPinchCurrentAngle = rot
                }
                
            }
            else {
                if isRight {
                    WorldTracker.shared.rightPinchCurrentPosition = pos
                    WorldTracker.shared.rightPinchCurrentAngle = rot
                }
                else {
                    WorldTracker.shared.leftPinchCurrentPosition = pos
                    WorldTracker.shared.leftPinchCurrentAngle = rot
                }
            }
        }
        else {
            // Just in case
            if !isInProgressPinch {
                if isRight {
                    WorldTracker.shared.rightPinchStartPosition = simd_float3()
                    WorldTracker.shared.rightPinchCurrentPosition = simd_float3()
                    WorldTracker.shared.rightPinchStartAngle = simd_quatf()
                    WorldTracker.shared.rightPinchCurrentAngle = simd_quatf()
                }
                else {
                    WorldTracker.shared.leftPinchStartPosition = simd_float3()
                    WorldTracker.shared.leftPinchCurrentPosition = simd_float3()
                    WorldTracker.shared.leftPinchStartAngle = simd_quatf()
                    WorldTracker.shared.leftPinchCurrentAngle = simd_quatf()
                }
                
            }
        }
    }
}
