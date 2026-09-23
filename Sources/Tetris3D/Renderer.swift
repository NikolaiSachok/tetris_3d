import MetalKit
import simd
import TetrisCore

/// Draws the scene: shadow map → HDR MSAA scene → bloom chain → tone-mapped composite.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private static let sampleCount = 4
    private static let hdrFormat = MTLPixelFormat.rgba16Float
    private static let shadowMapSize = 2048
    private static let framesInFlight = 3
    private static let maxInstances = 1024

    private let controller: GameController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: Renderer.framesInFlight)
    private var frameIndex = 0
    private weak var view: MTKView?
    private var lastTargetTimestamp: CFTimeInterval?
    private var frameDelta: Float = 0

    private let shadowPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let panelPipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState
    private let blockPipeline: MTLRenderPipelineState
    private let ghostPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let nebulaPipeline: MTLComputePipelineState
    private let prefilterPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState

    private let depthWrite: MTLDepthStencilState
    private let depthReadOnly: MTLDepthStencilState
    private let depthIgnore: MTLDepthStencilState

    private let cubeVertices: MTLBuffer
    private let cubeIndices: MTLBuffer
    private let cubeIndexCount: Int
    private let panel: (vertices: MTLBuffer, indices: MTLBuffer)
    private let floor: (vertices: MTLBuffer, indices: MTLBuffer)

    private var instanceBuffers: [MTLBuffer] = []
    private var particleBuffers: [MTLBuffer] = []
    private let shadowMap: MTLTexture

    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var hdr: MTLTexture?
    private var nebula: MTLTexture?
    private var bloomDown: [MTLTexture] = []
    private var bloomUp: [MTLTexture] = []

    init(view: MTKView, controller: GameController) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.controller = controller
        self.device = device
        self.queue = queue

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        // Frames are driven by a display link so the simulation advances by exact vsync intervals
        // (targetTimestamp deltas). Sampling the wall clock when the callback happens to run jitters by ±20%
        // per frame, which shows up as micro-judder on everything that moves.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let fn = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return fn
        }

        func scenePipeline(_ vertex: String, _ fragment: String?, blended: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try function(vertex)
            desc.fragmentFunction = try fragment.map(function)
            desc.rasterSampleCount = Renderer.sampleCount
            desc.colorAttachments[0].pixelFormat = Renderer.hdrFormat
            desc.depthAttachmentPixelFormat = .depth32Float
            if blended {
                // Premultiplied alpha; shaders that output alpha 0 become purely additive.
                let color = desc.colorAttachments[0]!
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.vertexFunction = try function("shadowVertex")
        shadowDesc.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDesc)

        backgroundPipeline = try scenePipeline("fullscreenVertex", "backgroundFragment", blended: false)
        panelPipeline = try scenePipeline("envVertex", "envFragment", blended: false)
        floorPipeline = try scenePipeline("envVertex", "envFragment", blended: true)
        blockPipeline = try scenePipeline("blockVertex", "blockFragment", blended: false)
        ghostPipeline = try scenePipeline("blockVertex", "blockFragment", blended: true)
        particlePipeline = try scenePipeline("particleVertex", "particleFragment", blended: true)

        let compositeDesc = MTLRenderPipelineDescriptor()
        compositeDesc.vertexFunction = try function("fullscreenVertex")
        compositeDesc.fragmentFunction = try function("compositeFragment")
        compositeDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDesc)

        nebulaPipeline = try device.makeComputePipelineState(function: function("nebulaKernel"))
        prefilterPipeline = try device.makeComputePipelineState(function: function("bloomPrefilter"))
        downsamplePipeline = try device.makeComputePipelineState(function: function("bloomDownsample"))
        upsamplePipeline = try device.makeComputePipelineState(function: function("bloomUpsample"))

        func depthState(write: Bool, compare: MTLCompareFunction) -> MTLDepthStencilState {
            let desc = MTLDepthStencilDescriptor()
            desc.isDepthWriteEnabled = write
            desc.depthCompareFunction = compare
            return device.makeDepthStencilState(descriptor: desc)!
        }
        depthWrite = depthState(write: true, compare: .less)
        depthReadOnly = depthState(write: false, compare: .less)
        depthIgnore = depthState(write: false, compare: .always)

        func upload(_ mesh: MeshData) -> (vertices: MTLBuffer, indices: MTLBuffer) {
            let vertices = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            let indices = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            return (vertices, indices)
        }
        let cube = MeshData.roundedCube()
        (cubeVertices, cubeIndices) = upload(cube)
        cubeIndexCount = cube.indices.count
        let environment = MeshData.environment()
        panel = upload(environment.panel)
        floor = upload(environment.floor)

        for _ in 0..<Renderer.framesInFlight {
            instanceBuffers.append(device.makeBuffer(length: MemoryLayout<Instance>.stride * Renderer.maxInstances,
                                                     options: .storageModeShared)!)
            particleBuffers.append(device.makeBuffer(length: MemoryLayout<Particle>.stride * ParticleSystem.capacity,
                                                     options: .storageModeShared)!)
        }

        let shadowDesc2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Renderer.shadowMapSize,
                                                                   height: Renderer.shadowMapSize, mipmapped: false)
        shadowDesc2.usage = [.renderTarget, .shaderRead]
        shadowDesc2.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowDesc2)!

        super.init()

        let link = view.displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.view = view
    }

    @objc private func step(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        frameDelta = lastTargetTimestamp.map { Float(min(target - $0, 1.0 / 20)) } ?? 0
        lastTargetTimestamp = target
        view?.draw()
    }

    // MARK: - Resize

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)

        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int = 1,
                     usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            if samples > 1 {
                desc.textureType = .type2DMultisample
                desc.sampleCount = samples
            }
            desc.usage = usage
            desc.storageMode = storage
            return device.makeTexture(descriptor: desc)!
        }

        msaaColor = texture(Renderer.hdrFormat, width, height, samples: Renderer.sampleCount, usage: .renderTarget,
                            storage: .memoryless)
        msaaDepth = texture(.depth32Float, width, height, samples: Renderer.sampleCount, usage: .renderTarget,
                            storage: .memoryless)
        hdr = texture(Renderer.hdrFormat, width, height, usage: [.renderTarget, .shaderRead])
        nebula = texture(Renderer.hdrFormat, max(width / 4, 1), max(height / 4, 1), usage: [.shaderRead, .shaderWrite])

        bloomDown = []
        bloomUp = []
        var w = width / 2, h = height / 2
        while bloomDown.count < 7, w >= 8, h >= 8 {
            bloomDown.append(texture(Renderer.hdrFormat, w, h, usage: [.shaderRead, .shaderWrite]))
            w /= 2
            h /= 2
        }
        for level in bloomDown.dropLast() {
            bloomUp.append(texture(Renderer.hdrFormat, level.width, level.height, usage: [.shaderRead, .shaderWrite]))
        }

        controller.updateLayout(project: { [camera = camera(for: size)] world in
            let clip = camera.viewProj * SIMD4(world, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            let scale = view.bounds.width > 0 ? Float(size.width / view.bounds.width) : 2
            return CGPoint(x: CGFloat((ndc.x * 0.5 + 0.5) * Float(size.width) / scale),
                           y: CGFloat((0.5 - ndc.y * 0.5) * Float(size.height) / scale))
        })
    }

    // MARK: - Camera & light

    private struct Camera {
        var eye: SIMD3<Float>
        var viewProj: float4x4
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    private func camera(for size: CGSize, shake: SIMD3<Float> = .zero) -> Camera {
        let aspect = Float(size.width / max(size.height, 1))
        let fovY: Float = 30 * .pi / 180
        let halfTan = tan(fovY / 2)
        let distance = max(12.9 / halfTan, 14.4 / (halfTan * aspect))
        let target = SIMD3<Float>(0, -0.6, 0) + shake
        let eye = target + normalize(SIMD3<Float>(0, 0.17, 1)) * distance
        let view = float4x4.lookAt(eye: eye, target: target, up: [0, 1, 0])
        let projection = float4x4.perspective(fovY: fovY, aspect: aspect, near: 1, far: distance + 80)
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        return Camera(eye: eye, viewProj: projection * view, right: right, up: up)
    }

    private static let lightDirection = normalize(SIMD3<Float>(-0.5, 0.72, 0.62))

    private static let lightViewProj: float4x4 = {
        let view = float4x4.lookAt(eye: lightDirection * 40, target: .zero, up: [0, 1, 0])
        return float4x4.orthographic(left: -17, right: 17, bottom: -17, top: 17, near: 15, far: 70) * view
    }()

    // MARK: - Frame

    func draw(in view: MTKView) {
        controller.tick(dt: frameDelta)
        frameDelta = 0 // Consumed: extra draws (e.g. during live resize) must not advance time again.

        guard let msaaColor, let msaaDepth, let hdr, let nebula, !bloomDown.isEmpty else { return }
        inFlight.wait()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let scene = controller.scene
        let (opaque, ghost) = scene.buildInstances(game: controller.game, ghostStyle: controller.ghostStyle)
        let particles = scene.particles.gpuParticles()
        let instanceBuffer = instanceBuffers[frameIndex]
        let particleBuffer = particleBuffers[frameIndex]
        frameIndex = (frameIndex + 1) % Renderer.framesInFlight

        let instances = Array((opaque + ghost).prefix(Renderer.maxInstances))
        let opaqueCount = min(opaque.count, instances.count)
        instances.withUnsafeBytes { instanceBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if !particles.isEmpty {
            particles.withUnsafeBytes { particleBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }

        let size = view.drawableSize
        let camera = camera(for: size, shake: scene.shakeOffset)
        var frame = FrameUniforms(
            viewProj: camera.viewProj,
            lightViewProj: Renderer.lightViewProj,
            cameraPos: SIMD4(camera.eye, scene.time),
            lightDir: SIMD4(Renderer.lightDirection, 3.2),
            accent: SIMD4(scene.accent, scene.danger),
            viewport: SIMD4(Float(size.width), Float(size.height), scene.flash, 0),
            cameraRight: SIMD4(camera.right, 0),
            cameraUp: SIMD4(camera.up, 0)
        )

        // 1. Shadow map.
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.label = "Shadow"
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(depthWrite)
            encoder.setDepthBias(1.5, slopeScale: 2.5, clamp: 0.01)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(cubeVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            drawCubes(encoder, count: opaqueCount, first: 0)
            encoder.endEncoding()
        }

        // 2. Quarter-resolution nebula for the backdrop.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Nebula"
            encoder.setBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            dispatch(encoder, nebulaPipeline, inputs: [], output: nebula)
            encoder.endEncoding()
        }

        // 3. HDR scene.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = msaaColor
        scenePass.colorAttachments[0].resolveTexture = hdr
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.depthAttachment.texture = msaaDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "Scene"
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentTexture(shadowMap, index: 0)

            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setFragmentTexture(nebula, index: 1)
            encoder.setDepthStencilState(depthIgnore)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            for (pipeline, mesh, kind) in [(floorPipeline, floor, Int32(1)), (panelPipeline, panel, Int32(0))] {
                var kind = kind
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                encoder.setFragmentBytes(&kind, length: MemoryLayout<Int32>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
                                              indexBuffer: mesh.indices, indexBufferOffset: 0)
            }

            encoder.setRenderPipelineState(blockPipeline)
            encoder.setVertexBuffer(cubeVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            drawCubes(encoder, count: opaqueCount, first: 0)

            encoder.setDepthStencilState(depthReadOnly)
            if instances.count > opaqueCount {
                encoder.setRenderPipelineState(ghostPipeline)
                drawCubes(encoder, count: instances.count - opaqueCount, first: opaqueCount)
            }

            if !particles.isEmpty {
                encoder.setCullMode(.none)
                encoder.setRenderPipelineState(particlePipeline)
                encoder.setVertexBuffer(particleBuffer, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
            }
            encoder.endEncoding()
        }

        // 4. Bloom.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Bloom"
            dispatch(encoder, prefilterPipeline, inputs: [hdr], output: bloomDown[0])
            for i in 1..<bloomDown.count {
                dispatch(encoder, downsamplePipeline, inputs: [bloomDown[i - 1]], output: bloomDown[i])
            }
            for i in stride(from: bloomUp.count - 1, through: 0, by: -1) {
                let low = i == bloomUp.count - 1 ? bloomDown[i + 1] : bloomUp[i + 1]
                dispatch(encoder, upsamplePipeline, inputs: [low, bloomDown[i]], output: bloomUp[i])
            }
            encoder.endEncoding()
        }

        // 5. Tone-mapped composite into the drawable.
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else {
            commandBuffer.commit()
            return
        }
        pass.colorAttachments[0].loadAction = .dontCare
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Composite"
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentTexture(hdr, index: 0)
            encoder.setFragmentTexture(bloomUp.first ?? bloomDown[0], index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawCubes(_ encoder: MTLRenderCommandEncoder, count: Int, first: Int) {
        guard count > 0 else { return }
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: cubeIndexCount, indexType: .uint16,
                                      indexBuffer: cubeIndices, indexBufferOffset: 0, instanceCount: count,
                                      baseVertex: 0, baseInstance: first)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                          inputs: [MTLTexture], output: MTLTexture) {
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in inputs.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setTexture(output, index: inputs.count)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        let grid = MTLSize(width: (output.width + 7) / 8, height: (output.height + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
    }
}

enum RendererError: Error {
    case noMetal
    case missingFunction(String)
}
