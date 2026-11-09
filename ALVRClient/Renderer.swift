//
//  Renderer.swift
//
// Stuff for the MetalClientSystem rendering
//
// Notable portions include:
// - Pipeline setup for different color formats and compiled Metal constants (rebuildRenderPipelines)
//
import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
let alignedPlaneUniformSize = (MemoryLayout<PlaneUniform>.size + 0xFF) & -0x100

let maxBuffersInFlight = 6
let maxPlanesDrawn = 512

enum RendererError: Error {
    case badVertexDescriptor
}

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let panel_depth: Float = 1

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-panel_depth, -panel_depth, -panel_depth,
                                       panel_depth, -panel_depth, -panel_depth,
                                       -panel_depth, panel_depth, -panel_depth,
                                       panel_depth, panel_depth, -panel_depth,
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

let hudQuadVertices: [Float] = [
    -0.5, -0.5, 0.0,
     0.5, -0.5, 0.0,
    -0.5,  0.5, 0.0,
     0.5,  0.5, 0.0,
     0.0,  1.0,
     1.0,  1.0,
     0.0,  0.0,
     1.0,  0.0
]
                                       
let unitVectorXYZVertices:[Float] = [0.0, 0.0, 0.0,
                                       1.0, 0.0, 0.0,
                                       0.01,0.0,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 1.0, 0.0,
                                       0.0,0.01,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 0.0, 1.0,
                                       0.0,0.0,0.01,
                                       
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

func NonlinearToLinearRGB(_ color: simd_float3) -> simd_float3 {
    let DIV12: Float = 1.0 / 12.92;
    let DIV1: Float = 1.0 / 1.055;
    let THRESHOLD: Float = 0.04045;
    let GAMMA = simd_float3(repeating: 2.4);
        
    let condition = simd_float3(color.x < THRESHOLD ? 1.0 : 0.0, color.y < THRESHOLD ? 1.0 : 0.0, color.z < THRESHOLD ? 1.0 : 0.0);
    let lowValues = color * DIV12;
    let highValues = pow((color + 0.055) * DIV1, GAMMA);
    return condition * lowValues + (1.0 - condition) * highValues;
}

class Renderer {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var pipelineState: MTLRenderPipelineState
    var depthStateAlways: MTLDepthStencilState
    var depthStateGreater: MTLDepthStencilState

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>

    let layerRenderer: LayerRenderer?
    var metalTextureCache: CVMetalTextureCache!
    let mtlVertexDescriptor: MTLVertexDescriptor
    let mtlVertexDescriptorNoUV: MTLVertexDescriptor
    var videoFramePipelineState_YpCbCrBiPlanar: MTLRenderPipelineState!
    var videoFramePipelineState_SecretYpCbCrFormats: MTLRenderPipelineState!
    // The ring between the declared frame and the edge of the view (chroma key on only): see videoFrameBorderVertexShader
    var videoBorderPipelineState_YpCbCrBiPlanar: MTLRenderPipelineState!
    var videoBorderPipelineState_SecretYpCbCrFormats: MTLRenderPipelineState!
    var videoBorderPipelineState: MTLRenderPipelineState? // the one matching the frame being drawn
    var videoFrameDepthPipelineState: MTLRenderPipelineState!
    var fullscreenQuadBuffer:MTLBuffer!
    var unitVectorXYZBuffer:MTLBuffer!
    /// Steam Controller body wireframe. Built on first use rather than at init,
    /// because the overwhelmingly common case is that no Steam Controller is
    /// connected and nothing ever asks to draw it.
    private var ibexMeshBufferStorage:MTLBuffer?
    private var ibexMeshBuildAttempted = false
    var ibexMeshVertexCount: Int = 0

    /// Uploads `IbexModel`'s decimated shell on first call. Returns nil if the
    /// resource is missing, and does not retry — a missing bundle resource will
    /// not fix itself, and retrying every frame would spam the log.
    func ibexMeshBuffer() -> MTLBuffer? {
        if ibexMeshBuildAttempted { return ibexMeshBufferStorage }
        ibexMeshBuildAttempted = true
        let verts = IbexModel.wireframeVertices
        guard !verts.isEmpty else { return nil }
        verts.withUnsafeBytes {
            ibexMeshBufferStorage = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        ibexMeshVertexCount = IbexModel.wireframeVertexCount
        print("Renderer: Ibex wireframe uploaded, \(ibexMeshVertexCount) verts")
        return ibexMeshBufferStorage
    }
    var hudPipelineState: MTLRenderPipelineState!
    var hudQuadBuffer: MTLBuffer!
    var depthStateAlwaysNoWrite: MTLDepthStencilState!
    var encodingGamma: Float = 1.0
    var lastReconfigureTime: Double = 0.0
    
    var drawPlanesWithInformedColors: Bool = false
    var fadeInOverlayAlpha: Float = 0.0
    var coolPulsingColorsTime: Float = 0.0
    private let chaperoneSystem = ChaperoneSystem()
#if CHAPERONE_PROFILE
    private var chaperoneProfileAccumMs: Double = 0.0
    private var chaperoneProfileSamples: Int = 0
    private var chaperoneProfileLastLog: Double = 0.0
    private var chaperoneProfileWindow: [Double] = []
    private let chaperoneProfileWindowSize: Int = 120
#endif
    var reprojectedFramesInARow: Int = 0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    var currentYuvTransform: simd_float4x4 = matrix_identity_float4x4
    
    // Was curious if it improved; it's still juddery.
    var useApplesReprojection = false
    
    var hdrEnabled = false
    var currentRenderColorFormat = renderColorFormatSDR
    var currentDrawableRenderColorFormat = renderColorFormatDrawableSDR
    
    //
    // Chroma keying shader vars
    //
    // chromaKeyParams.lerpDistRange is used to decide the amount of color to be used from either foreground or background
    // if the current distance from pixel color to chromaKey is smaller then lerpDistRange.x we use background,
    // if the current distance from pixel color to chromaKey is bigger then lerpDistRange.y we use foreground,
    // else, we alpha blend them
    // playing with this variable will decide how much the foreground and background blend together
    // The key is the client's own, or the streamer's (see ChromaKeyParams.current)
    var chromaKeyParams = ChromaKeyParams()
    var chromaKeyEnabled: Bool { return chromaKeyParams.enabled }
    
    init(_ layerRenderer: LayerRenderer?) {
        self.layerRenderer = layerRenderer
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            //self.layerRenderer?.renderQuality = .init(1.0)
        }
#endif

        encodingGamma = EventHandler.shared.encodingGamma
        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }
        
        self.device = layerRenderer?.device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = self.device.makeCommandQueue()!

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let planeUniformBufferSize = alignedPlaneUniformSize * maxPlanesDrawn
        self.dynamicPlaneUniformBuffer = self.device.makeBuffer(length:planeUniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicPlaneUniformBuffer.label = "PlaneUniformBuffer"
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents()).bindMemory(to:PlaneUniform.self, capacity:1)
        
        mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
        mtlVertexDescriptorNoUV = Renderer.buildMetalVertexDescriptorNoUV()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        do {
            hudPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                          mtlVertexDescriptor: mtlVertexDescriptor,
                                                                          colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                          depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                          viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                          vertexShaderName: "hudVertexShader",
                                                                          fragmentShaderName: "hudFragmentShader")
        } catch {
            fatalError("Unable to compile HUD render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptorAlways = MTLDepthStencilDescriptor()
        depthStateDescriptorAlways.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptorAlways.isDepthWriteEnabled = true
        self.depthStateAlways = device.makeDepthStencilState(descriptor:depthStateDescriptorAlways)!
        let depthStateDescriptorAlwaysNoWrite = MTLDepthStencilDescriptor()
        depthStateDescriptorAlwaysNoWrite.depthCompareFunction = .always
        depthStateDescriptorAlwaysNoWrite.isDepthWriteEnabled = false
        self.depthStateAlwaysNoWrite = device.makeDepthStencilState(descriptor: depthStateDescriptorAlwaysNoWrite)!
        
        let depthStateDescriptorGreater = MTLDepthStencilDescriptor()
        depthStateDescriptorGreater.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptorGreater.isDepthWriteEnabled = true
        self.depthStateGreater = device.makeDepthStencilState(descriptor:depthStateDescriptorGreater)!
        
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &metalTextureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        hudQuadVertices.withUnsafeBytes {
            hudQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        unitVectorXYZVertices.withUnsafeBytes {
            unitVectorXYZBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
        
        rebuildRenderPipelines()

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    /// Pipeline rebuilds off the render thread, one at a time. The first frames of every stream ask for one on several
    /// consecutive frames (views declared, gamma, YUV transform: `encodingGamma` only changes once a rebuild has run), and
    /// each request used to start its own thread, so several rebuilds wrote the same pipeline properties at once. Now a
    /// request while one is queued is folded into it; a request while one runs queues exactly one more.
    private let pipelineRebuildQueue = DispatchQueue(label: "Rebuild Render Pipelines", qos: .userInitiated)
    private let pipelineRebuildLock = NSLock()
    private var pipelineRebuildQueued = false

    func requestPipelineRebuild() {
        pipelineRebuildLock.lock()
        if pipelineRebuildQueued {
            pipelineRebuildLock.unlock()
            return
        }
        pipelineRebuildQueued = true
        pipelineRebuildLock.unlock()
        pipelineRebuildQueue.async {
            self.pipelineRebuildLock.lock()
            self.pipelineRebuildQueued = false
            self.pipelineRebuildLock.unlock()
            self.rebuildRenderPipelines()
        }
    }

    func rebuildRenderPipelines() {
        print("rebuildRenderPipelines")

        encodingGamma = EventHandler.shared.encodingGamma
        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }

        // Everything below builds the *video frame* pipelines, and both of its
        // inputs only exist once a streamer has told us about the stream:
        // `settings` comes from the session config, and `streamEvent` from
        // STREAMING_STARTED. The renderer can legitimately be running before
        // either arrives — the offline input debug space brings it up with no
        // server at all — so this is a normal state, not a failure.
        //
        // Nothing is lost by deferring: there are no video frames to draw yet,
        // the pipeline states are implicitly-unwrapped optionals that stay nil
        // until used, and the first IPD report after streaming goes active
        // re-enters this function (see the `lastIpd == -1` branch in
        // renderFrame) and builds them for real.
        guard let settings = Settings.getAlvrSettings(),
              let streamEvent = EventHandler.shared.streamEvent else {
            print("rebuildRenderPipelines: no stream yet, deferring video pipelines")
            return
        }

        let foveationVars = FFR.calculateFoveationVars(alvrEvent: streamEvent.STREAMING_STARTED, foveationSettings: settings.video.foveated_encoding)
        videoFramePipelineState_YpCbCrBiPlanar = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "YpCbCrBiPlanar"
        )
        videoFramePipelineState_SecretYpCbCrFormats = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "SecretYpCbCrFormats"
        )
        videoBorderPipelineState_YpCbCrBiPlanar = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "YpCbCrBiPlanar",
                            vertexName: "videoFrameBorderVertexShader",
                            fragmentPrefix: "videoFrameBorderFragmentShader_"
        )
        videoBorderPipelineState_SecretYpCbCrFormats = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "SecretYpCbCrFormats",
                            vertexName: "videoFrameBorderVertexShader",
                            fragmentPrefix: "videoFrameBorderFragmentShader_"
        )
        
        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        
        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
    }

    // Vertex descriptor with float3 position and float2 UVs
    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }
    
    // Vertex descriptor without any UV info
    class func buildMetalVertexDescriptorNoUV() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    // Generic render pipeline, used for the wireframe rendering.
    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             mtlVertexDescriptor: MTLVertexDescriptor,
                                             colorFormat: MTLPixelFormat,
                                             depthFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: vertexShaderName)
        let fragmentFunction = library?.makeFunction(name: fragmentShaderName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Copy/"passthrough" pipeline for transferring from an offscreen MTLTexture
    // to the final MTLTexture.
    func buildCopyPipelineWithDevice(device: MTLDevice,
                                             colorFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vrrScreenSize: MTLSize?,
                                             vrrPhysSize: MTLSize?,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()
        
        let fragmentConstants = MTLFunctionConstantValues()
        let settings = ALVRClientApp.gStore.settings
        chromaKeyParams = ChromaKeyParams.current(settings)

        var mutVrrScreenSize = simd_float2(Float(vrrScreenSize?.width ?? 1), Float(vrrScreenSize?.height ?? 1))
        var mutVrrPhysSize = simd_float2(Float(vrrPhysSize?.width ?? 1), Float(vrrPhysSize?.height ?? 1))
        chromaKeyParams.setFunctionConstants(fragmentConstants)
        fragmentConstants.setConstantValue(&mutVrrScreenSize, type: .float2, index: ALVRFunctionConstant.vrrScreenSize.rawValue)
        fragmentConstants.setConstantValue(&mutVrrPhysSize, type: .float2, index: ALVRFunctionConstant.vrrPhysSize.rawValue)

        let vertexFunction = try! library?.makeFunction(name: vertexShaderName, constantValues: fragmentConstants)
        let fragmentFunction = try! library?.makeFunction(name: fragmentShaderName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptorNoUV

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Depth-only renderer, for correcting after overlay render just so Apple's compositor isn't annoying about it
    class func buildRenderPipelineForVideoFrameDepthWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          depthFormat: MTLPixelFormat,
                                                          viewCount: Int) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
        let fragmentFunction = library?.makeFunction(name: "videoFrameDepthFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameDepthRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Video frame renderer, incl my own YCbCr stage and/or Apple's 48 private YCbCr texture formats.
    func buildRenderPipelineForVideoFrameWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          viewCount: Int,
                                                          foveationVars: FoveationVars,
                                                          variantName: String,
                                                          vertexName: String = "videoFrameVertexShader",
                                                          fragmentPrefix: String = "videoFrameFragmentShader_") throws -> MTLRenderPipelineState {
        

        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: vertexName)
        let fragmentConstants = FFR.makeFunctionConstants(foveationVars)
        
        let settings = ALVRClientApp.gStore.settings
        chromaKeyParams = ChromaKeyParams.current(settings)

        chromaKeyParams.setFunctionConstants(fragmentConstants)
        fragmentConstants.setConstantValue(&encodingGamma, type: .float, index: ALVRFunctionConstant.encodingGamma.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.0, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform0.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.1, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform1.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.2, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform2.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.3, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform3.rawValue)
        
        let fragmentFunction = try library?.makeFunction(name: fragmentPrefix + variantName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameRenderPipeline_" + variantName
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Advances the uniform buffer for the next frame, values can be written to `uniforms`
    // after this is called.
    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }
    
    // Advances the Plane uniform buffer, values can be written to `planeUniforms`
    // after this is called.
    private func selectNextPlaneUniformBuffer() {
        /// Update the state of our uniform buffers before rendering

        planeUniformBufferIndex = (planeUniformBufferIndex + 1) % maxPlanesDrawn
        planeUniformBufferOffset = alignedPlaneUniformSize * planeUniformBufferIndex
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents() + planeUniformBufferOffset).bindMemory(to:PlaneUniform.self, capacity:1)
    }

    // Writes FOV/tangents/etc information to the uniform buffer.
    private func updateGameStateForVideoFrame(_ whichIdx: Int, drawable: LayerRenderer.Drawable?, viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        let settings = ALVRClientApp.gStore.settings
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let realTangents = realViewTangents[viewIndex]
            let sentTangents = sentViewTangents[viewIndex]
            
            var framePoseNoTranslation = framePose
            var simdDeviceAnchorNoTranslation = simdDeviceAnchor
            framePoseNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            simdDeviceAnchorNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            let viewMatrix = (simdDeviceAnchor * viewTransforms[viewIndex]).inverse
            let viewMatrixFrame = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation * viewTransforms[viewIndex]).inverse
            var projection = matrix_identity_float4x4
            if #available(visionOS 2.0, *), drawable != nil {
#if XCODE_BETA_16
                projection = drawable!.computeProjection(viewIndex: viewIndex)
#else
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
#endif
            }
            else {
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
            }
            return Uniforms(projectionMatrix: projection, modelViewMatrixFrame: viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: sentTangents)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if viewTransforms.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
    }
    
    // MARK: - Read-only telemetry (branch additional_telemetry): `[tele]` lines in the streamer's log, no state written, no behaviour change
    var teleLastVsync: Double = 0
    var teleWindowStart: Double = 0
    var teleCount = 0
    var teleSum: Double = 0
    var teleMin: Double = .infinity
    var teleMax: Double = 0
    var teleGeometryLogged = false   // reset when streaming stops, so each stream start logs the geometry again (the first drawable comes before the client's log connection exists)
    var teleLate = 0                 // display intervals over 15 ms in the window (a skipped refresh at 100 Hz)
    var teleMisses = 0               // frames whose submission ended after the compositor's rendering deadline
    var teleMinSlack: Double = .infinity
    var teleDropsPrev = 0
    var teleLastWindowMean: Double = 0
    // what each tick showed (EventHandler.pollFrameForDisplay): fresh frame / the last one again because visionOS skipped its submission / reprojected after the wait / nothing
    var telePickFresh = 0, telePickResubmit = 0, telePickReproj = 0, telePickNone = 0
    var teleDepthSum = 0, teleDepthMax = 0, teleDepthTicks = 0      // frames queued when the pick began
    var teleFreshLate = 0                                           // fresh picks that had to wait (the frame arrived after the pick began)
    var teleWaitSum: Double = 0, teleWaitMax: Double = 0           // that wait, seconds
    var teleAgeSum: Double = 0, teleAgeMax: Double = 0             // fresh picks: how long the frame sat in the queue before this tick, seconds
    var teleFreshWithQueued = 0                                     // resubmits where a fresh frame was waiting (the rule at EventHandler.pollFrameForDisplay)
    var teleLastThermal: Int = -1

    /// After `endSubmission`: how long before (positive) or after (negative) the compositor's rendering deadline this frame's submission ended.
    func teleSubmitted(deadline: LayerRenderer.Clock.Instant) {
        let slack = LayerRenderer.Clock().now.duration(to: deadline).timeInterval
        teleMinSlack = min(teleMinSlack, slack)
        if slack < 0 { teleMisses += 1 }
    }

    /// After the pick: which kind it was, the queue depth when it began, the wait, the age of a fresh frame.
    func telePick(_ pick: EventHandler.DisplayPick, depth: Int, waited: Double) {
        teleDepthSum += depth; teleDepthMax = max(teleDepthMax, depth); teleDepthTicks += 1
        switch pick {
        case .fresh(let f):
            telePickFresh += 1
            let age = CACurrentMediaTime() - f.enqueuedAt
            teleAgeSum += age; teleAgeMax = max(teleAgeMax, age)
            if waited > 0.0005 { teleFreshLate += 1; teleWaitSum += waited; teleWaitMax = max(teleWaitMax, waited) }
        case .resubmit:
            telePickResubmit += 1
            if depth > 0 { teleFreshWithQueued += 1 }
        case .reprojected: telePickReproj += 1; teleWaitSum += waited; teleWaitMax = max(teleWaitMax, waited)
        case .none: telePickNone += 1
        }
    }

    func teleLog(_ line: String) {
        ("[tele] " + line).withCString { alvr_log(UInt8(ALVR_LOG_LEVEL_ERROR.rawValue), $0) }
    }

    /// Once at the first drawable (sizes, viewports, rate map), then every 10 s: the display interval seen between presentation times (mean / min /
    /// max, so a switch between 90, 96 and 100 Hz shows), the thermal state, the decoder's refresh target. Called once per rendered frame with that frame's drawable.
    func logTelemetry(drawable: LayerRenderer.Drawable, vsyncTime: Double) {
        let now = CACurrentMediaTime()
        if teleLastVsync > 0 {
            let d = vsyncTime - teleLastVsync
            if d > 0 && d < 0.1 {
                teleCount += 1; teleSum += d; teleMin = min(teleMin, d); teleMax = max(teleMax, d)
                if d > 0.015 { teleLate += 1 }
            }
        }
        teleLastVsync = vsyncTime
        if teleWindowStart == 0 { teleWindowStart = now }

        let streaming = EventHandler.shared.alvrInitialized && EventHandler.shared.streamingActive
        if !streaming { teleGeometryLogged = false }
        if streaming && !teleGeometryLogged {
            teleGeometryLogged = true
            let tex = drawable.colorTextures.first
            teleLog(String(format: "drawable color %ldx%ld layers %ld views %ld", tex?.width ?? 0, tex?.height ?? 0, tex?.arrayLength ?? 0, drawable.views.count))
            for i in 0..<drawable.views.count {
                let v = drawable.views[i].textureMap.viewport
                teleLog(String(format: "view %d viewport %.0fx%.0f at %.0f,%.0f", i, v.width, v.height, v.originX, v.originY))
            }
            if let vrr = drawable.rasterizationRateMaps.first {
                for layer in 0..<vrr.layerCount {
                    let p = vrr.physicalSize(layer: layer)
                    teleLog(String(format: "ratemap layer %d screen %.0fx%.0f physical %ldx%ld", layer, vrr.screenSize.width, vrr.screenSize.height, p.width, p.height))
                }
            } else {
                teleLog("ratemap none")
            }
        }

        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let thermalChanged = thermal != teleLastThermal
        if (now - teleWindowStart >= 10.0 && teleCount > 0) || thermalChanged {
            let mean = teleCount > 0 ? teleSum / Double(teleCount) : 0
            teleLog(String(format: "display interval mean %.3f ms (%.1f Hz) min %.3f max %.3f over %d frames, %d over 15 ms; deadline misses %d, min slack %.2f ms; thermal %d; stream target %.0f Hz",
                           mean * 1000, mean > 0 ? 1.0 / mean : 0, teleMin.isFinite ? teleMin * 1000 : 0, teleMax * 1000, teleCount, teleLate, teleMisses, teleMinSlack.isFinite ? teleMinSlack * 1000 : 0, thermal, refreshRate))
            objc_sync_enter(EventHandler.shared.frameQueueLock)
            let dropsTotal = EventHandler.shared.queueOverflowDrops
            objc_sync_exit(EventHandler.shared.frameQueueLock)
            teleLog("queue overflow drops \(dropsTotal - teleDropsPrev) in the window (decoded frames discarded, the queue holds 2)")
            teleDropsPrev = dropsTotal
            let ticks = max(telePickFresh + telePickResubmit + telePickReproj + telePickNone, 1)
            teleLog(String(format: "pick over %d ticks: fresh %d, resubmit %d (%d with a fresh frame queued), reprojected %d, none %d; queue depth at pick mean %.2f max %d; fresh frames that arrived after the pick began %d (wait mean %.2f ms max %.2f incl. reprojected); fresh frame age in queue mean %.2f ms max %.2f",
                           ticks, telePickFresh, telePickResubmit, teleFreshWithQueued, telePickReproj, telePickNone,
                           teleDepthTicks > 0 ? Double(teleDepthSum) / Double(teleDepthTicks) : 0, teleDepthMax,
                           teleFreshLate, (teleFreshLate + telePickReproj) > 0 ? teleWaitSum / Double(teleFreshLate + telePickReproj) * 1000 : 0, teleWaitMax * 1000,
                           telePickFresh > 0 ? teleAgeSum / Double(telePickFresh) * 1000 : 0, teleAgeMax * 1000))
            telePickFresh = 0; telePickResubmit = 0; telePickReproj = 0; telePickNone = 0; teleDepthSum = 0; teleDepthMax = 0; teleDepthTicks = 0
            teleFreshLate = 0; teleWaitSum = 0; teleWaitMax = 0; teleAgeSum = 0; teleAgeMax = 0; teleFreshWithQueued = 0
            if teleLastWindowMean > 0 && mean > 0 && abs(mean - teleLastWindowMean) / teleLastWindowMean > 0.03 {
                teleLog(String(format: "DISPLAY RATE CHANGED %.1f Hz -> %.1f Hz", 1.0 / teleLastWindowMean, 1.0 / mean))
            }
            if mean > 0 { teleLastWindowMean = mean }
            teleLastThermal = thermal
            teleWindowStart = now; teleCount = 0; teleSum = 0; teleMin = .infinity; teleMax = 0; teleLate = 0; teleMisses = 0; teleMinSlack = .infinity
        }
    }

    // Checks if eye tracking was secretly added, maybe, hard to know really.
    func checkEyes(drawable: LayerRenderer.Drawable) {
        print("begin -----")
        print(drawable.colorTextures.first?.width as Any, drawable.colorTextures.first?.height as Any)
        //print(drawable.views[0].transform - EventHandler.shared.viewTransforms[0])
        //print(drawable.views[1].transform - EventHandler.shared.viewTransforms[1])
        if let vrr = drawable.rasterizationRateMaps.first {
            let eyeCenterX = Float(vrr.screenSize.width) / 2.0
            let eyeCenterY = Float(vrr.screenSize.height) / 2.0
            let physSizeL = vrr.physicalSize(layer: 0)
            let physCoordsL = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 0)
            
            let physSizeR = vrr.physicalSize(layer: 1)
            let physCoordsR = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 1)
            
            print(physSizeL, physSizeR, vrr.screenSize.width, vrr.screenSize.height, ":::", Float(physCoordsL.x) / Float(physSizeL.width), Float(physCoordsL.y) / Float(physSizeL.height), ":::", Float(physCoordsR.x) / Float(physSizeR.width), Float(physCoordsR.y) / Float(physSizeR.height))
        }
        
        print("end -------")
    }
    
    // Adjust view transforms for debugging various issues.
    func fixTransform(_ transform: simd_float4x4) -> simd_float4x4 {
        //var out = matrix_identity_float4x4
        //out.columns.3 = transform.columns.3
        //out.columns.3.w = 1.0
        return transform.translationOnly() // TODO: undo this when we fix canted views in 20.15
    }
    
    // Adjusts view tangents for debugging various issues.
    func fixTangents(_ tangents: simd_float4) -> simd_float4 {
        return tangents
    }
    
    func renderToDrawable(_ drawable: LayerRenderer.Drawable) {
        
    }

    // Render the frame, only used in MetalClientSystem renderer.
    func renderFrame() {
        /// Per frame updates hare
        EventHandler.shared.framesRendered += 1
        EventHandler.shared.totalFramesRendered += 1
        var streamingActiveForFrame = EventHandler.shared.streamingActive
        var isReprojected = false
        
        var queuedFrame:QueuedFrame? = nil
        
        guard let frame = layerRenderer!.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }

        frame.startUpdate()
        frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        
        roundTripRenderTime = CACurrentMediaTime() - lastRoundTripRenderTimestamp
        lastRoundTripRenderTimestamp = CACurrentMediaTime()

        // Locked pick (EventHandler.pollFrameForDisplay): the stream stop clears the last frame from the events thread
        let telePickStart = CACurrentMediaTime()
        let telePickDepth = EventHandler.shared.queueDepth()
        let telePicked = EventHandler.shared.pollFrameForDisplay(timeout: 0.005)
        if streamingActiveForFrame { telePick(telePicked, depth: telePickDepth, waited: CACurrentMediaTime() - telePickStart) }
        switch telePicked {
        case .resubmit(let f):
            queuedFrame = f
            EventHandler.shared.framesRendered -= 1
            isReprojected = false
        case .fresh(let f):
            queuedFrame = f
        case .reprojected(let f):
            queuedFrame = f
            EventHandler.shared.framesRendered -= 1
            isReprojected = true
        case .none:
            break
        }
        
        if queuedFrame == nil && streamingActiveForFrame {
            streamingActiveForFrame = false
        }
        let renderingStreaming = streamingActiveForFrame && queuedFrame != nil
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

#if XCODE_BETA_26
        // MTLSize(width: 4338, height: 3478, depth: 1) MTLSize(width: 1888, height: 1792, depth: 1) by default
        // MTLSize(width: 6262, height: 5020, depth: 1) MTLSize(width: 2496, height: 2432, depth: 1) at 1.0 render quality
        var mainDrawable = LayerRenderer.Drawable()
        var drawables: [LayerRenderer.Drawable] = []
        if #available(visionOS 26.0, *) {
            drawables = frame.queryDrawables()
            if drawables.isEmpty {
                if queuedFrame != nil {
                    EventHandler.shared.publishShownFrame(queuedFrame)
                }
                return
            }
            mainDrawable = drawables[0]
            //print(drawable.rasterizationRateMaps[0].screenSize, drawable.rasterizationRateMaps[0].physicalSize(layer: 0))
        }
        else {
            guard let _drawable = frame.queryDrawable() else {
                if queuedFrame != nil {
                    EventHandler.shared.publishShownFrame(queuedFrame)
                }
                return
            }
            mainDrawable = _drawable
            drawables = [_drawable]
        }
#else
        guard let _drawable = frame.queryDrawable() else {
            if queuedFrame != nil {
                EventHandler.shared.publishShownFrame(queuedFrame)
            }
            return
        }
        var mainDrawable = _drawable
        var drawables: [LayerRenderer.Drawable] = [_drawable]
#endif
        
        let nalViewsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { nalViewsPtr.deallocate() }
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid /*&& EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp*/ {
            alvr_report_compositor_start(queuedFrame!.timestamp, nalViewsPtr)
            queuedFrame = QueuedFrame(imageBuffer: queuedFrame!.imageBuffer, timestamp: queuedFrame!.timestamp, viewParamsValid: true, viewParams: [nalViewsPtr[0], nalViewsPtr[1]])
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let settings = ALVRClientApp.gStore.settings
            var ipd = mainDrawable.views.count > 1 ? simd_length(mainDrawable.views[0].transform.columns.3 - mainDrawable.views[1].transform.columns.3) : 0.063
#if targetEnvironment(simulator)
            ipd = 0.063
            print(EventHandler.shared.lastIpd)
#endif
            // The FoV sliders are read when the view config is sent: at the first frame after Enter, and again if they changed
            // since (leaving and entering again on the same connection).
            let fovScaleH = max(fovScaleRange.lowerBound, min(fovScaleRange.upperBound, settings.fovScaleH))
            let fovScaleV = max(fovScaleRange.lowerBound, min(fovScaleRange.upperBound, settings.fovScaleV))
            let fovScaleChanged = EventHandler.shared.lastFovScale != simd_float2(fovScaleH, fovScaleV)
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 || fovScaleChanged {
                print("Send view config")
                
                if EventHandler.shared.lastIpd != -1 {
                    if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                        print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                    }
                    else {
                        print("FoV scale changed:", fovScaleH, fovScaleV)
                    }
                }
                else {
                    print("IPD is", ipd)
                    EventHandler.shared.framesRendered = 0
                    lastReconfigureTime = CACurrentMediaTime()
                    
                    requestPipelineRebuild()
                }
                
                // TODO: Fix tangents to fill entire FoV if canting ever becomes more intense like PFD was
                let tangentsLeft = mainDrawable.gimmeTangents(viewIndex: 0)
                let tangentsRight = mainDrawable.gimmeTangents(viewIndex: 1)
                let transformLeft = mainDrawable.views[0].transform
                let transformRight = mainDrawable.views[1].transform
                // Declare the frustum the compositor asks for, per eye, as the stock app does at FoV Scale 1. The lens window depends on the
                // wearer's fit and no visionOS API reports it (the render-context stencil mask covers the whole texture in full immersion),
                // so the client never cuts: an uncalibrated wearer sees the whole panel. Tightening is the streamer's (the wearer's calibrated
                // rectangle, sent to the game as absolute tangents). 1.2.0-1.3.1 cut to a fixed box and left black bars for wider fits.
                let limitedTangentsLeft = tangentsLeft
                let limitedTangentsRight = tangentsRight
                // FoV sliders (horizontal and vertical, 0.6 to 1.4): a factor per axis on what is declared, so the streamer renders, encodes and sends
                // less (or more) angle at the same pixel count. 1.0 = the compositor's whole frustum, as the stock app. Equal values give exactly the
                // old single FoV Scale result (see declaredFovAngles).
                let leftAngles = declaredFovAngles(tangents: limitedTangentsLeft, scaleH: fovScaleH, scaleV: fovScaleV)
                let rightAngles = mainDrawable.views.count > 1 ? declaredFovAngles(tangents: limitedTangentsRight, scaleH: fovScaleH, scaleV: fovScaleV) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                
                let (leftFovCorrected, tangentsLeftCorrected, transformLeftCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: leftFov, viewTransform: transformLeft, fovPostScale: 1.0)
                let (rightFovCorrected, tangentsRightCorrected, transformRightCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: rightFov, viewTransform: transformRight, fovPostScale: 1.0)
                
                EventHandler.shared.viewFovs = [leftFovCorrected, rightFovCorrected]
                EventHandler.shared.viewTransforms = [fixTransform(transformLeftCorrected), mainDrawable.views.count > 1 ? fixTransform(transformRightCorrected) : fixTransform(transformLeftCorrected)]
                EventHandler.shared.lastIpd = ipd
                EventHandler.shared.lastFovScale = simd_float2(fovScaleH, fovScaleV)
                
                // Wait, is this correct?
                if mainDrawable.views.count > 1 {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsRight]
                }
                else {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsLeft]
                }
                
                
                WorldTracker.shared.sendViewParams(viewTransforms:  EventHandler.shared.viewTransforms, viewFovs: EventHandler.shared.viewFovs)
            }
            
            var needsPipelineRebuild = false
            if EventHandler.shared.encodingGamma != encodingGamma {
                needsPipelineRebuild = true
            }
            
            if CACurrentMediaTime() - lastReconfigureTime > 1.0 && chromaKeyParams.wantsRebuild(for: settings) {
                lastReconfigureTime = CACurrentMediaTime()
                needsPipelineRebuild = true
            }
            
            if let videoFormat = EventHandler.shared.videoFormat {
                let nextYuvTransform = VideoHandler.getYUVTransformForVideoFormat(videoFormat)
                if nextYuvTransform != currentYuvTransform {
                    needsPipelineRebuild = true
                }
                currentYuvTransform = nextYuvTransform
            }
            
            if needsPipelineRebuild {
                lastReconfigureTime = CACurrentMediaTime()
                requestPipelineRebuild()
            }
        }
        
        //checkEyes(drawable: mainDrawable)
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid {
            print("aaaaaaaa bad view params")
        }
        
        let vsyncTime = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.presentationTime).timeInterval
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        logTelemetry(drawable: mainDrawable, vsyncTime: vsyncTime)
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized && EventHandler.shared.lastIpd != -1 {
            if #available(visionOS 2.0, *) {
                EventHandler.shared.viewTransforms = [fixTransform(mainDrawable.views[0].transform), mainDrawable.views.count > 1 ? fixTransform(mainDrawable.views[1].transform) : fixTransform(mainDrawable.views[0].transform)]
            }
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms

            let targetTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))//LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval

            if !ALVRClientApp.gStore.settings.targetHandsAtRoundtripLatency {
                if #available(visionOS 2.0, *) {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
                }
                else {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.renderingDeadline).timeInterval
                }
            }

            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
        }
        else {
#if DEBUG_ALVR_TRACKING
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms

            let targetTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))//LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
            
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
#endif
        }
        
        let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)
        
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            if EventHandler.shared.alvrInitialized, let submitted = queuedFrame, EventHandler.shared.markSubmitted(submitted.timestamp) {
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                
                //let currentTimeNs = UInt64(commandBuffer.gpuEndTime * Double(NSEC_PER_SEC))
                //let actualRenderTimeNs = UInt64((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * Double(NSEC_PER_SEC))
                //print((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0)
                
                //print("Finished:", queuedFrame!.timestamp)
                // A frame finished after its presentation time has no vsync queue left (0, not a wrapped ~1.8e19 ns that would
                // pin the head-prediction average at its cap for the next statistics window)
                alvr_report_submit(submitted.timestamp, vsyncTimeNs > currentTimeNs ? vsyncTimeNs - currentTimeNs : 0)
            }
        }

        // List of reasons to not display a frame
        var frameIsSuitableForDisplaying = true
        //print(EventHandler.shared.lastIpd, WorldTracker.shared.worldTrackingAddedOriginAnchor, EventHandler.shared.framesRendered)
        if EventHandler.shared.lastIpd == -1 || EventHandler.shared.framesRendered < Int(refreshRate) {
            // Don't show frame if we haven't sent the view config and received frames
            // with that config applied.
            frameIsSuitableForDisplaying = false
            print("IPD is bad, no frame", EventHandler.shared.framesRendered)
        }
        if !WorldTracker.shared.worldTrackingAddedOriginAnchor && EventHandler.shared.framesRendered < 300 {
            // Don't show frame if we haven't figured out our origin yet.
            frameIsSuitableForDisplaying = false
            print("Origin is bad, no frame")
        }
        if EventHandler.shared.videoFormat == nil {
            frameIsSuitableForDisplaying = false
            print("Missing video format, no frame")
        }
        
        if !(renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil) {
            // Things to do once if no frame is rendering (show the wireframe)
            if EventHandler.shared.totalFramesRendered > 300 {
                fadeInOverlayAlpha += 0.02
            }
        }
        else {
            // Things to do if a frame is rendering (fade wireframe, or show wireframe is reprojection is too long)
            fadeInOverlayAlpha -= 0.01
            if fadeInOverlayAlpha < 0.0 {
                fadeInOverlayAlpha = 0.0
            }
            
            if isReprojected && useApplesReprojection {
                LayerRenderer.Clock().wait(until: mainDrawable.frameTiming.renderingDeadline)
            }
            
            if isReprojected {
                reprojectedFramesInARow += 1
                if reprojectedFramesInARow > Int(refreshRate) {
                    fadeInOverlayAlpha += 0.02
                }
            }
            else {
                reprojectedFramesInARow = 0
                fadeInOverlayAlpha -= 0.02
            }
        }

        
        for drawable in drawables {
            drawable.deviceAnchor = deviceAnchor
            
            // TODO: check layerRenderer.configuration.layout == .layered ?
            let viewports = drawable.views.map { $0.textureMap.viewport }
            let rasterizationRateMap = drawable.rasterizationRateMaps.first
            let viewTransforms = drawable.views.map { $0.transform }
            let sentViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.sentViewTangents[idx] }
            let realViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.realViewTangents[idx] }
            let nearZ =  Double(drawable.depthRange.y)
            let farZ = Double(drawable.depthRange.x)
            let simdDeviceAnchor = WorldTracker.shared.floorCorrectionTransform.asFloat4x4() * (deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4)
            let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
            
#if DEBUG_ALVR_TRACKING
            WorldTracker.shared.lockDebuggables()
            
            let headDebug = (simdDeviceAnchor.columns.3.asFloat3() - simdDeviceAnchor.columns.2.asFloat3()).asFloat4x4() * simdDeviceAnchor.orientationOnly().asFloat4x4()
            WorldTracker.shared.addDebuggablePose(headDebug, 0.1)
            
            for transform in viewTransforms {
                let mat = headDebug * transform
                WorldTracker.shared.addDebuggablePose(mat, 0.05)
            }
            
            WorldTracker.shared.unlockDebuggables()
#endif
            
            if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
                //print("render")
                if let encoder = beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable) {
                    renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                    endRenderStreamingFrame(renderEncoder: encoder)
                }
                renderStreamingFrameOverlays(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
            }
            else
            {
                reprojectedFramesInARow = 0;

                let noFramePose = simdDeviceAnchor
                // TODO: draw a cool loading logo
                renderNothing(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
                
                renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
                renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
            }
            
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        
        coolPulsingColorsTime += 0.005
        if coolPulsingColorsTime > 4.0 {
            coolPulsingColorsTime = 0.0
        }
        
        if fadeInOverlayAlpha > 1.0 {
            fadeInOverlayAlpha = 1.0
        }
        if fadeInOverlayAlpha < 0.0 {
            fadeInOverlayAlpha = 0.0
        }
        
        commandBuffer.commit()
        frame.endSubmission()
        teleSubmitted(deadline: timing.renderingDeadline)
        
        EventHandler.shared.publishShownFrame(queuedFrame)
        EventHandler.shared.lastQueuedFramePose = framePreviouslyPredictedPose
    }
    
    // Pulse the wireframe between cyan and blue.
    func coolPulsingColor() -> simd_float4 {
        // Color picked from the ALVR logo
        let lightColor = simd_float4(0.05624, 0.73124, 0.75999, 1.0)
        let darkColor = simd_float4(0.01305, 0.26223, 0.63828, 1.0)
        var switchingFnT: Float = 0.0 // hold on light
        
        if coolPulsingColorsTime >= 1.0 && coolPulsingColorsTime < 2.0 {
            switchingFnT = coolPulsingColorsTime - 1.0 // light -> dark
        }
        else if coolPulsingColorsTime >= 2.0 && coolPulsingColorsTime < 3.0 {
            switchingFnT = 1.0 // hold on dark
        }
        else if coolPulsingColorsTime >= 3.0 && coolPulsingColorsTime < 4.0 {
            switchingFnT = coolPulsingColorsTime - 2.0 // dark -> light
        }

        var switchingFn = sin(switchingFnT * Float.pi * 0.5)
        if coolPulsingColorsTime >= 4.0 {
            switchingFn = 0.0
        }
        return simd_mix(lightColor, darkColor, simd_float4(repeating: switchingFn))
    }
    
    // Can draw planes with debug colors, or with a subtle transparency change based on the type.
    func planeToColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        var subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            switch(plane.classification) {
                case .ceiling: // #62ea80
                    return simd_float4(0.3843137254901961, 0.9176470588235294, 0.5019607843137255, 1.0) * subtleChange * planeAlpha
                case .door: // #1a5ff4
                    return simd_float4(0.10196078431372549, 0.37254901960784315, 0.9568627450980393, 1.0) * subtleChange * planeAlpha
                case .floor: // #bf6505
                    return simd_float4(0.7490196078431373, 0.396078431372549, 0.0196078431372549, 1.0) * subtleChange * planeAlpha
                case .seat: // #ef67af
                    return simd_float4(0.9372549019607843, 0.403921568627451, 0.6862745098039216, 1.0) * subtleChange * planeAlpha
                case .table: // #c937d3
                    return simd_float4(0.788235294117647, 0.21568627450980393, 0.8274509803921568, 1.0) * subtleChange * planeAlpha
                case .wall: // #dced5e
                    return simd_float4(0.8627450980392157, 0.9294117647058824, 0.3686274509803922, 1.0) * subtleChange * planeAlpha
                case .window: // #4aefce
                    return simd_float4(0.2901960784313726, 0.9372549019607843, 0.807843137254902, 1.0) * subtleChange * planeAlpha
                case .unknown: // #0e576b
                    return simd_float4(0.054901960784313725, 0.3411764705882353, 0.4196078431372549, 1.0) * subtleChange * planeAlpha
                case .undetermined: // #749606
                    return simd_float4(0.4549019607843137, 0.5882352941176471, 0.023529411764705882, 1.0) * subtleChange * planeAlpha
                default:
                    return simd_float4(1.0, 0.0, 0.0, 1.0) * subtleChange * planeAlpha // red
            }
        }
        else {
            if plane.classification == .ceiling {
                subtleChange *= 0.4
            }
            else if plane.classification == .wall {
                subtleChange *= 0.1
            }
            else if plane.classification == .floor {
                subtleChange *= 0.2
            }
            else if plane.classification == .seat {
                subtleChange *= 0.5
            }
            else {
                subtleChange = 0.01
            }
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    // Line color for a given ARKit Plane
    func planeToLineColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        let subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            return planeToColor(plane: plane)
        }
        else {
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    // Only renders the frame depth, used to correct depth after the overlay is rendered
    // because Apple's Metal renderer is kinda weird about it.
    func renderStreamingFrameDepth(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?) {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
        // With a chroma key the clear is transparent and the ring outside the declared frame is drawn by renderStreamingFrame (black where the
        // frame's edge is picture, transparent where it is the key colour); without one the clear is the opaque black.
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: chromaKeyEnabled ? 0.0 : 1.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.000000001
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rerender depth"
        
        renderEncoder.pushDebugGroup("Draw ALVR Frame Depth")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Clears the render target, nothing more nothing less.
    func renderNothing(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rendering Nothing"
        
        renderEncoder.pushDebugGroup("Draw Nothing")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
    }
    
    // Renders a wireframe overlay on top of the existing video frame (or nothing)
    func renderOverlay(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4],  nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4)
    {
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Plane Render Encoder"
        renderEncoder.pushDebugGroup("Draw planes")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        WorldTracker.shared.lockPlaneAnchors()
        
        var firstBind = true
        if fadeInOverlayAlpha > 0.0 {
            // Render planes
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 1.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.fill)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
            
            // Render lines
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToLineColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
        }
        
        WorldTracker.shared.unlockPlaneAnchors()
        
        WorldTracker.shared.lockDebuggables()
        
        // Render lines
        for i in 0..<WorldTracker.shared.debuggableMats.count {
            let matTransform = WorldTracker.shared.debuggableMats[i]
            let basisColors = [simd_float4(1.0, 0.0, 0.0, 1.0), simd_float4(0.0, 1.0, 0.0, 1.0), simd_float4(0.0, 0.0, 1.0, 1.0)]
            let basisScaleFactor: Float = WorldTracker.shared.debuggableScales[i]
            let basisScale = simd_float3x3(basisScaleFactor).asFloat4x4()
            
            for i in 0..<3 {
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
                
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = (matTransform.columns.3.asFloat3()).asFloat4x4() * (basisScale * matTransform.orientationOnly().asFloat4x4())
                self.planeUniforms[0].planeColor = basisColors[i]
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 3*i, vertexCount: 3)
            }
        }

        // Render solid bodies (currently only the Steam Controller shell).
        if !WorldTracker.shared.debuggableMeshes.isEmpty, let meshBuffer = ibexMeshBuffer(), ibexMeshVertexCount > 0 {
            for (matTransform, color) in WorldTracker.shared.debuggableMeshes {
                renderEncoder.setVertexBuffer(meshBuffer, offset: 0, index: VertexAttribute.position.rawValue)
                // Texcoords are unused by the plane fragment shader, which is
                // flat-coloured — bind the position buffer again rather than
                // carrying a second one purely to satisfy the descriptor.
                renderEncoder.setVertexBuffer(meshBuffer, offset: 0, index: VertexAttribute.texcoord.rawValue)

                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = matTransform
                self.planeUniforms[0].planeColor = color
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }

                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ibexMeshVertexCount)
            }
        }

        WorldTracker.shared.debuggableMats = []
        WorldTracker.shared.debuggableScales = []
        WorldTracker.shared.debuggableMeshes = []
        WorldTracker.shared.unlockDebuggables()
        
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    // Renders the chaperone proximity overlay on top of the existing video frame.
    func renderChaperone(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Chaperone Render Encoder"
        renderEncoder.pushDebugGroup("Draw chaperone")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        let planesSnapshot = WorldTracker.shared.snapshotPlaneData()
#if CHAPERONE_PROFILE
        let profileStart = CACurrentMediaTime()
#endif
        let output = chaperoneSystem.update(planes: planesSnapshot,
                                            headPose: simdDeviceAnchor,
                                            leftHandPose: WorldTracker.shared.lastLeftHandPose,
                                            rightHandPose: WorldTracker.shared.lastRightHandPose,
                                            worldFromSteamVR: WorldTracker.shared.worldTrackingSteamVRTransform,
                                            chaperoneDistanceCm: ALVRClientApp.gStore.settings.chaperoneDistanceCm,
                                            now: CACurrentMediaTime(),
                                            leftControllerPresent: WorldTracker.shared.leftControllerPose != nil,
                                            rightControllerPresent: WorldTracker.shared.rightControllerPose != nil) { isLeft, amplitude, duration in
            WorldTracker.shared.enqueueHapticsPulse(isLeft: isLeft, amplitude: amplitude, duration: duration)
        }

#if CHAPERONE_PROFILE
        let elapsedMs = (CACurrentMediaTime() - profileStart) * 1000.0
        chaperoneProfileAccumMs += elapsedMs
        chaperoneProfileSamples += 1
        chaperoneProfileWindow.append(elapsedMs)
        if chaperoneProfileWindow.count > chaperoneProfileWindowSize {
            chaperoneProfileWindow.removeFirst(chaperoneProfileWindow.count - chaperoneProfileWindowSize)
        }
        let now = CACurrentMediaTime()
        if now - chaperoneProfileLastLog > 2.0 {
            chaperoneProfileLastLog = now
            let avg = chaperoneProfileAccumMs / Double(max(1, chaperoneProfileSamples))
            let maxSample = chaperoneProfileWindow.max() ?? 0.0
            var median: Double = 0.0
            if !chaperoneProfileWindow.isEmpty {
                let sorted = chaperoneProfileWindow.sorted()
                median = sorted[sorted.count / 2]
            }
            let recomputeSamples = max(1, output.profile.recomputeSamples)
            let recomputePct = Int((Double(output.profile.recomputeTrue) / Double(recomputeSamples)) * 100.0)
            let avgRenderables = Double(output.profile.renderableCount) / Double(recomputeSamples)
            print("[ChaperoneProfile] avg=\(String(format: "%.3f", avg))ms median=\(String(format: "%.3f", median))ms max=\(String(format: "%.3f", maxSample))ms samples=\(chaperoneProfileSamples) planes=\(planesSnapshot.count) recompute=\(recomputePct)% exact=\(output.profile.exactProximityChecks) renderables=\(String(format: "%.1f", avgRenderables)) interval=\(output.profile.recomputeIntervalFrames)")
            chaperoneProfileAccumMs = 0.0
            chaperoneProfileSamples = 0
        }
#endif

        var firstBind = true
        for (plane, planeColor) in output.renderables {
            let faces = plane.geometry.meshFaces

            // VRR can't do lines
            if faces.primitive != GeometryElement.Primitive.triangle {
                continue
            }

            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)

            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeColor
            self.planeUniforms[0].planeDoProximity = 1.0
            if firstBind {
                renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                firstBind = false
            } else {
                renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            }
            
            renderEncoder.setTriangleFillMode(.fill)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    
    // Sets up rendering a video frame, including uniforms
    func beginRenderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) -> (any MTLRenderCommandEncoder)? {
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = whichIdx == 0 ? .clear : .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        // With a chroma key the clear is transparent and the ring outside the declared frame is drawn by renderStreamingFrame (black where the
        // frame's edge is picture, transparent where it is the key colour); without one the clear is the opaque black.
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: chromaKeyEnabled ? 0.0 : 1.0)
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Primary Render Encoder"
        renderEncoder.pushDebugGroup("Draw ALVR Frames")
        
        guard let queuedFrame = queuedFrame else {
            renderEncoder.endEncoding()
            return nil
        }
        
        // https://cs.android.com/android/platform/superproject/main/+/main:external/webrtc/sdk/objc/components/renderer/metal/RTCMTLNV12Renderer.mm;l=108;drc=a81e9c82fc3fbc984f0f110407d1e44c9c01958a
        let pixelBuffer = queuedFrame.imageBuffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let formatStr = VideoHandler.coreVideoPixelFormatToStr[format, default: "unknown"]
        
        if VideoHandler.isFormatSecret(format) {
            renderEncoder.setRenderPipelineState(videoFramePipelineState_SecretYpCbCrFormats)
            videoBorderPipelineState = videoBorderPipelineState_SecretYpCbCrFormats
        }
        else {
            renderEncoder.setRenderPipelineState(videoFramePipelineState_YpCbCrBiPlanar)
            videoBorderPipelineState = videoBorderPipelineState_YpCbCrBiPlanar
        }
        
        //print("Pixel format \(formatStr) (\(format))")
        let textureTypes = VideoHandler.getTextureTypesForFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        
        for i in 0...1 {
            var textureOut:CVMetalTexture! = nil
            var err:OSStatus = 0
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
            
            if textureTypes[i] == MTLPixelFormat.invalid {
                break
            }
            
            err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, textureTypes[i],
                    width, height, i, &textureOut);
            
            if err != 0 {
                fatalError("CVMetalTextureCacheCreateTextureFromImage \(err)")
            }
            guard let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                fatalError("CVMetalTextureGetTexture")
            }
            if !((metalTexture.debugDescription?.contains("decompressedPixelFormat") ?? true) || (metalTexture.debugDescription?.contains("isCompressed = 1") ?? true)) && EventHandler.shared.totalFramesRendered % 90*5 == 0 {
                print("NO COMPRESSION ON VT FRAME!!!! AAAAAAAAA go file feedback again :(")
            }
            renderEncoder.setFragmentTexture(metalTexture, index: i)
        }
        
        // Snoop for pixel formats
        /*for idx in 620..<0xFFFF {
            guard let format = MTLPixelFormat.init(rawValue: UInt(idx)) else {
                continue
            }
            do {
                var desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.invalid, width: 1, height:1, mipmapped: false)
                desc.pixelFormat = format
                for line in desc.debugDescription.split(separator: "\n") {
                    if line.contains("pixelFormat") {
                        print(idx, line)
                        break
                    }
                }
            }
            catch {
                continue
            }
        }*/
        
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        return renderEncoder
    }
    
    // Actually do the video frame render.
    func renderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderEncoder: any MTLRenderCommandEncoder, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: whichIdx*4, vertexCount: 4)
        
        // The ring outside the declared frame, only when the chroma key is on (otherwise the clear is already opaque black). The frame's textures and
        // uniforms are bound; the ring and the frame do not overlap.
        if chromaKeyEnabled, let borderPipeline = videoBorderPipelineState {
            renderEncoder.setRenderPipelineState(borderPipeline)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 10)
        }
    }
    
    // Finish video frame encoding.
    func endRenderStreamingFrame(renderEncoder: any MTLRenderCommandEncoder) {
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Render an overlay on top of the video frame.
    func renderStreamingFrameOverlays(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        if fadeInOverlayAlpha > 0.0 || WorldTracker.shared.debuggableMats.count > 0 || WorldTracker.shared.debuggableMeshes.count > 0 {
            // Not super kosher--we need the depth to be correct for the video frame box, but we can't have the view
            // outside of the video frame box be 0.0 depth or it won't get rastered by the compositor at all.
            // So we re-render the frame depth.
            renderOverlay(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        }
        if ALVRClientApp.gStore.settings.chaperoneDistanceCm > 0 || chaperoneSystem.hasActiveState {
            renderChaperone(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, rasterizationRateMap: rasterizationRateMap, simdDeviceAnchor: simdDeviceAnchor)
        }
        renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
    }
}
