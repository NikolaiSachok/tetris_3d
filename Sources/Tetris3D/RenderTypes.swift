import simd

// GPU-visible structs. Layouts mirror the MSL structs in Shaders.swift (all float4-aligned).

struct Vertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}

enum BlockStyle: Float {
    case block = 0, ghost = 1, frameVertical = 2, frameHorizontal = 3
}

struct Instance {
    /// xyz world centre, w yaw in radians.
    var position: SIMD4<Float>
    var scale: SIMD4<Float>
    /// rgb albedo, a opacity.
    var color: SIMD4<Float>
    /// x emissive, y style, z edge glow, w white-hot flash.
    var params: SIMD4<Float>

    init(center: SIMD3<Float>, scale: SIMD3<Float> = .one, yaw: Float = 0, color: SIMD3<Float>, opacity: Float = 1,
         style: BlockStyle = .block, emissive: Float = 0, edgeGlow: Float = 0, flash: Float = 0) {
        position = SIMD4(center, yaw)
        self.scale = SIMD4(scale, 0)
        self.color = SIMD4(color, opacity)
        params = SIMD4(emissive, style.rawValue, edgeGlow, flash)
    }
}

struct FrameUniforms {
    var viewProj: float4x4
    var lightViewProj: float4x4
    /// w: time in seconds.
    var cameraPos: SIMD4<Float>
    /// Direction towards the light, w: intensity.
    var lightDir: SIMD4<Float>
    /// Level colour, w: danger (how close the stack is to the top).
    var accent: SIMD4<Float>
    /// xy: pixels, z: flash, w: unused.
    var viewport: SIMD4<Float>
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
}

struct Particle {
    /// xyz position, w size.
    var position: SIMD4<Float>
    /// rgb HDR colour, a intensity.
    var color: SIMD4<Float>
}
