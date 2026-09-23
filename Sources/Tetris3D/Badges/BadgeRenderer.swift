import CoreGraphics
import MetaGame
import Metal
import simd

// GPU-visible structs, mirroring the MSL structs in BadgeShaders.swift.

struct BadgeInstance {
    var model: float4x4
    var color: SIMD4<Float>
    /// x emissive, y edge glow, z white-hot flash, w locked.
    var params: SIMD4<Float>
}

struct BadgeLook {
    var tint: SIMD4<Float>
    var plate: SIMD4<Float>
    var sweep: SIMD4<Float>
    var rimDir: SIMD4<Float>
    var grid: SIMD4<Float>
}

private struct BadgePost {
    var bloom: Float
    var exposure: Float
}

/// How a badge is posed and lit in one frame; `rest` is the still image.
struct BadgePose {
    /// Radians about the vertical axis.
    var yaw: Float = 0
    /// Radians about the horizontal axis.
    var pitch: Float = 0
    var scale: Float = 1
    /// 0...1, turns the emblem white-hot.
    var flash: Float = 0
    /// Multiplier on the emblem's emission.
    var glow: Float = 1
    /// Position of the light sweep across the badge (badge units, along the diagonal) and its strength.
    var sweep: Float = 0
    var sweepStrength: Float = 0

    static let rest = BadgePose()
}

/// Renders achievement badges offscreen: a medallion plate with a voxel emblem of the game's rounded cubes, lit by a
/// key and a rim light with shadow-mapped self-shadowing, in HDR with a small bloom, tone-mapped (ACES) to
/// premultiplied sRGB with a transparent background. Still images are cached; `BadgeLiveView` draws animated
/// frames through the same path.
@MainActor
final class BadgeRenderer {
    static let shared: BadgeRenderer? = {
        do {
            return try BadgeRenderer()
        } catch {
            print("Badge renderer unavailable: \(error)")
            return nil
        }
    }()

    /// Output pixels are rendered at twice their size and box-filtered down.
    private static let supersampling = 2
    private static let sampleCount = 4
    private static let hdrFormat = MTLPixelFormat.rgba16Float
    static let outputFormat = MTLPixelFormat.bgra8Unorm
    private static let shadowMapSize = 1024

    // Plate geometry, in emblem cells.
    private static let plateInradius: Float = 5.9
    private static let plateCorner: Float = 0.9
    private static let plateBevel: Float = 0.35
    private static let plateThickness: Float = 1.0
    private static let neonInset: Float = 0.62
    /// Emblems are scaled to fit this many cells across.
    private static let emblemCells: Float = 7

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let shadowPipeline: MTLRenderPipelineState
    private let platePipeline: MTLRenderPipelineState
    private let cubePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let prefilterPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let depthWrite: MTLDepthStencilState
    private let cube: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let plate: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let shadowMap: MTLTexture

    private var emblems: [EmblemKey: Emblem] = [:]
    private var targets: [Int: Targets] = [:]
    private var images: [ImageKey: CGImage] = [:]

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: shaderSource + badgeShaderSource, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let fn = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return fn
        }
        func scenePipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try function("badgeVertex")
            desc.fragmentFunction = try function(fragment)
            desc.rasterSampleCount = BadgeRenderer.sampleCount
            desc.colorAttachments[0].pixelFormat = BadgeRenderer.hdrFormat
            desc.depthAttachmentPixelFormat = .depth32Float
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.vertexFunction = try function("badgeShadowVertex")
        shadowDesc.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDesc)
        platePipeline = try scenePipeline("badgePlateFragment")
        cubePipeline = try scenePipeline("badgeCubeFragment")

        let compositeDesc = MTLRenderPipelineDescriptor()
        compositeDesc.vertexFunction = try function("fullscreenVertex")
        compositeDesc.fragmentFunction = try function("badgeCompositeFragment")
        compositeDesc.colorAttachments[0].pixelFormat = BadgeRenderer.outputFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDesc)

        prefilterPipeline = try device.makeComputePipelineState(function: function("bloomPrefilter"))
        downsamplePipeline = try device.makeComputePipelineState(function: function("bloomDownsample"))
        upsamplePipeline = try device.makeComputePipelineState(function: function("bloomUpsample"))

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.isDepthWriteEnabled = true
        depthDesc.depthCompareFunction = .less
        depthWrite = device.makeDepthStencilState(descriptor: depthDesc)!

        func upload(_ mesh: MeshData) -> (vertices: MTLBuffer, indices: MTLBuffer, count: Int) {
            let vertices = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            let indices = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            return (vertices, indices, mesh.indices.count)
        }
        cube = upload(MeshData.roundedCube())
        plate = upload(BadgeRenderer.plateMesh())

        let shadowDesc2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                   width: BadgeRenderer.shadowMapSize,
                                                                   height: BadgeRenderer.shadowMapSize, mipmapped: false)
        shadowDesc2.usage = [.renderTarget, .shaderRead]
        shadowDesc2.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowDesc2)!

        #if DEBUG
        BadgeContactSheet.renderIfRequested(with: self)
        #endif
    }

    // MARK: - Still images

    private struct ImageKey: Hashable {
        var achievement: Achievement
        var unlocked: Bool
        var pixels: Int
    }

    /// The badge at rest, `pixels` wide and high. Rendered once, then cached.
    func image(_ achievement: Achievement, unlocked: Bool, pixels: Int) -> CGImage? {
        let key = ImageKey(achievement: achievement, unlocked: unlocked, pixels: max(pixels, 16))
        if let image = images[key] { return image }
        let image = render(achievement, unlocked: unlocked, pose: .rest, pixels: key.pixels)
        images[key] = image
        return image
    }

    /// Renders one frame synchronously and reads it back.
    func render(_ achievement: Achievement, unlocked: Bool, pose: BadgePose, pixels: Int) -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: BadgeRenderer.outputFormat, width: pixels,
                                                            height: pixels, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        let bytesPerRow = pixels * 4
        guard let output = device.makeTexture(descriptor: desc),
              let readback = device.makeBuffer(length: bytesPerRow * pixels, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        encode(achievement, unlocked: unlocked, pose: pose, into: output, commandBuffer: commandBuffer)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: pixels, height: pixels, depth: 1), to: readback,
                      destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * pixels)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let data = Data(bytes: readback.contents(), count: bytesPerRow * pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - Frame encoding

    /// Encodes one badge frame into `output` (a square `outputFormat` texture), cleared to transparent.
    func encode(_ achievement: Achievement, unlocked: Bool, pose: BadgePose, into output: MTLTexture,
                commandBuffer: MTLCommandBuffer) {
        let targets = targets(for: output.width)
        let emblem = emblem(achievement, unlocked: unlocked)
        let badge = BadgeRenderer.poseMatrix(pose)

        var instances = [BadgeInstance(model: badge, color: .zero, params: .zero)]
        let params = unlocked
            ? SIMD4<Float>(0.3 * pose.glow, 0.35 * pose.glow, pose.flash, 0)
            : SIMD4<Float>(0, 0, 0, 1)
        for cube in emblem.cubes {
            let color = unlocked ? cube.color : SIMD3<Float>(0.13, 0.135, 0.15)
            instances.append(BadgeInstance(model: badge * cube.transform, color: SIMD4(color, 1), params: params))
        }
        guard let instanceBuffer = instances.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { return }

        let tint = achievement.badgeTint
        var frame = BadgeRenderer.frameUniforms(accent: unlocked ? tint * 0.35 : [0.04, 0.045, 0.06])
        var look = BadgeLook(
            tint: SIMD4(tint, unlocked ? 1 : 0),
            plate: SIMD4(BadgeRenderer.plateInradius, BadgeRenderer.plateCorner, BadgeRenderer.plateBevel,
                         BadgeRenderer.neonInset),
            sweep: SIMD4(pose.sweep, pose.sweepStrength, 0, 0),
            rimDir: SIMD4(normalize(SIMD3<Float>(0.75, 0.45, -0.35)), 0),
            grid: SIMD4(emblem.gridOrigin.x, emblem.gridOrigin.y, emblem.cellSize, 0)
        )

        // 1. Shadow map from the key light.
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.label = "Badge Shadow"
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(depthWrite)
            encoder.setDepthBias(1.5, slopeScale: 2.5, clamp: 0.01)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            drawBadge(encoder, instanceCount: instances.count)
            encoder.endEncoding()
        }

        // 2. HDR scene, supersampled and multisampled, on a transparent background.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = targets.msaaColor
        scenePass.colorAttachments[0].resolveTexture = targets.hdr
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scenePass.depthAttachment.texture = targets.msaaDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "Badge Scene"
            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&look, length: MemoryLayout<BadgeLook>.stride, index: 1)
            encoder.setFragmentTexture(shadowMap, index: 0)
            encoder.setRenderPipelineState(platePipeline)
            encoder.setVertexBuffer(plate.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: plate.count, indexType: .uint16,
                                          indexBuffer: plate.indices, indexBufferOffset: 0)
            if instances.count > 1 {
                encoder.setRenderPipelineState(cubePipeline)
                encoder.setVertexBuffer(cube.vertices, offset: 0, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: cube.count, indexType: .uint16,
                                              indexBuffer: cube.indices, indexBufferOffset: 0,
                                              instanceCount: instances.count - 1, baseVertex: 0, baseInstance: 1)
            }
            encoder.endEncoding()
        }

        // 3. Bloom (the game's kernels).
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Badge Bloom"
            dispatch(encoder, prefilterPipeline, inputs: [targets.hdr], output: targets.bloomDown[0])
            for i in 1..<targets.bloomDown.count {
                dispatch(encoder, downsamplePipeline, inputs: [targets.bloomDown[i - 1]], output: targets.bloomDown[i])
            }
            for i in stride(from: targets.bloomUp.count - 1, through: 0, by: -1) {
                let low = i == targets.bloomUp.count - 1 ? targets.bloomDown[i + 1] : targets.bloomUp[i + 1]
                dispatch(encoder, upsamplePipeline, inputs: [low, targets.bloomDown[i]], output: targets.bloomUp[i])
            }
            encoder.endEncoding()
        }

        // 4. Resolve, tone-map and premultiply into the output.
        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = output
        compositePass.colorAttachments[0].loadAction = .dontCare
        compositePass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass) {
            encoder.label = "Badge Composite"
            var post = BadgePost(bloom: 0.35, exposure: 1.0)
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentBytes(&post, length: MemoryLayout<BadgePost>.stride, index: 0)
            encoder.setFragmentTexture(targets.hdr, index: 0)
            encoder.setFragmentTexture(targets.bloomUp.first ?? targets.bloomDown[0], index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private func drawBadge(_ encoder: MTLRenderCommandEncoder, instanceCount: Int) {
        encoder.setVertexBuffer(plate.vertices, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: plate.count, indexType: .uint16,
                                      indexBuffer: plate.indices, indexBufferOffset: 0)
        guard instanceCount > 1 else { return }
        encoder.setVertexBuffer(cube.vertices, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: cube.count, indexType: .uint16,
                                      indexBuffer: cube.indices, indexBufferOffset: 0,
                                      instanceCount: instanceCount - 1, baseVertex: 0, baseInstance: 1)
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

    // MARK: - Camera & lights

    private static let keyLight = normalize(SIMD3<Float>(-0.45, 0.7, 0.6))

    private static func frameUniforms(accent: SIMD3<Float>) -> FrameUniforms {
        let fovY: Float = 20 * .pi / 180
        let distance = 8.0 / tan(fovY / 2)
        let target = SIMD3<Float>(0, 0, 0.4)
        let eye = target + normalize(SIMD3<Float>(0.2, 0.3, 1)) * distance
        let view = float4x4.lookAt(eye: eye, target: target, up: [0, 1, 0])
        let projection = float4x4.perspective(fovY: fovY, aspect: 1, near: distance - 12, far: distance + 12)
        let lightView = float4x4.lookAt(eye: keyLight * 30, target: .zero, up: [0, 1, 0])
        let lightProjection = float4x4.orthographic(left: -8.5, right: 8.5, bottom: -8.5, top: 8.5, near: 18, far: 42)
        return FrameUniforms(
            viewProj: projection * view,
            lightViewProj: lightProjection * lightView,
            cameraPos: SIMD4(eye, 0),
            lightDir: SIMD4(keyLight, 3.0),
            accent: SIMD4(accent, 0),
            viewport: .zero,
            cameraRight: .zero,
            cameraUp: .zero
        )
    }

    private static func poseMatrix(_ pose: BadgePose) -> float4x4 {
        let cy = cos(pose.yaw), sy = sin(pose.yaw)
        let cx = cos(pose.pitch), sx = sin(pose.pitch)
        let yaw = float4x4(columns: ([cy, 0, -sy, 0], [0, 1, 0, 0], [sy, 0, cy, 0], [0, 0, 0, 1]))
        let pitch = float4x4(columns: ([1, 0, 0, 0], [0, cx, sx, 0], [0, -sx, cx, 0], [0, 0, 0, 1]))
        return yaw * pitch * float4x4(diagonal: SIMD4(pose.scale, pose.scale, pose.scale, 1))
    }

    // MARK: - Emblems

    private struct EmblemKey: Hashable {
        var achievement: Achievement
        var unlocked: Bool
    }

    private struct Emblem {
        var cubes: [(transform: float4x4, color: SIMD3<Float>)]
        var cellSize: Float
        var gridOrigin: SIMD2<Float>
    }

    private func emblem(_ achievement: Achievement, unlocked: Bool) -> Emblem {
        let key = EmblemKey(achievement: achievement, unlocked: unlocked)
        if let emblem = emblems[key] { return emblem }
        let design = achievement.isSecret && !unlocked ? BadgeDesign.secret : achievement.badgeDesign
        let emblem = BadgeRenderer.layout(design)
        emblems[key] = emblem
        return emblem
    }

    /// Places the design's cubes on the plate: centred, scaled to fit, one cube deep plus relief.
    private static func layout(_ design: BadgeDesign) -> Emblem {
        let width = Float(design.rows.map(\.count).max() ?? 0)
        let height = Float(design.rows.count)
        let cell = min(1, emblemCells / max(width, height, 1))
        var cubes: [(transform: float4x4, color: SIMD3<Float>)] = []
        for (row, line) in design.rows.enumerated() {
            for (column, code) in line.enumerated() {
                guard let color = BadgeDesign.color(code) else { continue }
                let center = SIMD2<Float>(Float(column) - (width - 1) / 2, (height - 1) / 2 - Float(row)) * cell
                for level in 0..<(code.isUppercase ? 2 : 1) {
                    let transform = float4x4(columns: (
                        [cell, 0, 0, 0],
                        [0, cell, 0, 0],
                        [0, 0, cell, 0],
                        [center.x, center.y, cell * (0.5 + Float(level)), 1]
                    ))
                    cubes.append((transform, color))
                }
            }
        }
        // Grid lines fall between cells, so a grid origin sits on a cell centre.
        let origin = SIMD2<Float>(-(width - 1) / 2, (height - 1) / 2) * cell
        return Emblem(cubes: cubes, cellSize: cell, gridOrigin: origin)
    }

    // MARK: - Plate mesh

    /// A pointy-top hexagonal medallion with rounded corners and a rounded bevel on both faces; the front face is at
    /// z = 0. Matches `badgePlateDistance` in the shader.
    private static func plateMesh() -> MeshData {
        let a = plateInradius, rc = plateCorner, rb = plateBevel, depth = plateThickness
        let arcSteps = 8, bevelSteps = 6

        // Outline: six corner arcs; the straight edges join consecutive arcs.
        var outline: [(point: SIMD2<Float>, normal: SIMD2<Float>)] = []
        for corner in 0..<6 {
            let cornerAngle = (30 + 60 * Float(corner)) * .pi / 180
            let center = SIMD2(cos(cornerAngle), sin(cornerAngle)) * (a - rc) / cos(.pi / 6)
            for step in 0...arcSteps {
                let angle = (60 * Float(corner) + 60 * Float(step) / Float(arcSteps)) * .pi / 180
                let normal = SIMD2(cos(angle), sin(angle))
                outline.append((center + normal * rc, normal))
            }
        }

        // Profile around the rim, from the front face's edge to the back face's edge.
        var profile: [(inset: Float, z: Float, lateral: Float, facing: Float)] = []
        for step in 0...bevelSteps {
            let theta = Float(step) / Float(bevelSteps) * .pi / 2
            profile.append((rb * (1 - sin(theta)), -rb + rb * cos(theta), sin(theta), cos(theta)))
        }
        for step in 0...bevelSteps {
            let theta = .pi / 2 + Float(step) / Float(bevelSteps) * .pi / 2
            profile.append((rb * (1 - sin(theta)), -depth + rb + rb * cos(theta), sin(theta), cos(theta)))
        }

        var mesh = MeshData()
        func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
        func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> UInt16 {
            mesh.vertices.append(Vertex(position: SIMD4(p, 1), normal: SIMD4(normalize(n), 0)))
            return UInt16(mesh.vertices.count - 1)
        }
        // Orients each triangle to face along its vertex normals (counter-clockwise front faces).
        func triangle(_ i: UInt16, _ j: UInt16, _ k: UInt16) {
            let a = mesh.vertices[Int(i)], b = mesh.vertices[Int(j)], c = mesh.vertices[Int(k)]
            let face = cross(xyz(b.position - a.position), xyz(c.position - a.position))
            mesh.indices += dot(face, xyz(a.normal + b.normal + c.normal)) >= 0 ? [i, j, k] : [i, k, j]
        }

        var rings: [[UInt16]] = []
        for p in profile {
            rings.append(outline.map { o in
                let xy = o.point - o.normal * p.inset
                return vertex(SIMD3(xy, p.z), SIMD3(o.normal * p.lateral, p.facing))
            })
        }
        let count = outline.count
        for r in 0..<(rings.count - 1) {
            for i in 0..<count {
                let j = (i + 1) % count
                triangle(rings[r][i], rings[r][j], rings[r + 1][j])
                triangle(rings[r][i], rings[r + 1][j], rings[r + 1][i])
            }
        }
        for (ring, z, facing) in [(rings[0], Float(0), Float(1)), (rings[rings.count - 1], -depth, Float(-1))] {
            let center = vertex([0, 0, z], [0, 0, facing])
            let flat = ring.map { index in
                vertex(xyz(mesh.vertices[Int(index)].position), [0, 0, facing])
            }
            for i in 0..<count {
                triangle(center, flat[i], flat[(i + 1) % count])
            }
        }
        return mesh
    }

    // MARK: - Render targets

    @MainActor
    private final class Targets {
        let msaaColor: MTLTexture
        let msaaDepth: MTLTexture
        let hdr: MTLTexture
        let bloomDown: [MTLTexture]
        let bloomUp: [MTLTexture]

        init(device: MTLDevice, pixels: Int) {
            func texture(_ format: MTLPixelFormat, _ size: Int, samples: Int = 1, usage: MTLTextureUsage,
                         storage: MTLStorageMode = .private) -> MTLTexture {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size,
                                                                    mipmapped: false)
                if samples > 1 {
                    desc.textureType = .type2DMultisample
                    desc.sampleCount = samples
                }
                desc.usage = usage
                desc.storageMode = storage
                return device.makeTexture(descriptor: desc)!
            }
            let size = pixels * BadgeRenderer.supersampling
            msaaColor = texture(BadgeRenderer.hdrFormat, size, samples: BadgeRenderer.sampleCount, usage: .renderTarget,
                                storage: .memoryless)
            msaaDepth = texture(.depth32Float, size, samples: BadgeRenderer.sampleCount, usage: .renderTarget,
                                storage: .memoryless)
            hdr = texture(BadgeRenderer.hdrFormat, size, usage: [.renderTarget, .shaderRead])
            var down: [MTLTexture] = []
            var level = size / 2
            while down.count < 5, level >= 8 {
                down.append(texture(BadgeRenderer.hdrFormat, level, usage: [.shaderRead, .shaderWrite]))
                level /= 2
            }
            bloomDown = down
            bloomUp = down.dropLast().map { texture(BadgeRenderer.hdrFormat, $0.width, usage: [.shaderRead, .shaderWrite]) }
        }
    }

    /// Targets are shared by every badge of the same size: frames execute in queue order, so reuse is safe.
    private func targets(for pixels: Int) -> Targets {
        if let targets = targets[pixels] { return targets }
        let made = Targets(device: device, pixels: pixels)
        targets[pixels] = made
        return made
    }
}
