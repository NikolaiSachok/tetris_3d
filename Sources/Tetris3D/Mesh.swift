import simd

struct MeshData {
    var vertices: [Vertex] = []
    var indices: [UInt16] = []

    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>) {
        let base = UInt16(vertices.count)
        for p in [a, b, c, d] {
            vertices.append(Vertex(position: SIMD4(p, 1), normal: SIMD4(normal, 0)))
        }
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    /// A cube with rounded (bevelled) edges, centred at the origin.
    /// Vertices are packed densely in the bevel region so the rounding stays smooth.
    static func roundedCube(halfSize h: Float = 0.47, radius r: Float = 0.1, bevelSteps m: Int = 4) -> MeshData {
        var samples: [Float] = []
        for k in stride(from: m, through: 0, by: -1) {
            samples.append(-(h - r) - r * tan(Float(k) / Float(m) * .pi / 4))
        }
        for k in 0...m {
            samples.append((h - r) + r * tan(Float(k) / Float(m) * .pi / 4))
        }

        var mesh = MeshData()
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]),
            ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]),
            ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
            ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        let count = samples.count
        for face in faces {
            let base = UInt16(mesh.vertices.count)
            for sv in samples {
                for su in samples {
                    let p = face.n * h + face.u * su + face.v * sv
                    let inner = simd_clamp(p, SIMD3(repeating: -(h - r)), SIMD3(repeating: h - r))
                    let normal = normalize(p - inner)
                    mesh.vertices.append(Vertex(position: SIMD4(inner + normal * r, 1), normal: SIMD4(normal, 0)))
                }
            }
            for j in 0..<(count - 1) {
                for i in 0..<(count - 1) {
                    let a = base + UInt16(j * count + i)
                    let b = a + 1
                    let c = a + UInt16(count) + 1
                    let d = a + UInt16(count)
                    mesh.indices += [a, b, c, a, c, d]
                }
            }
        }
        return mesh
    }

    /// Back panel of the well plus the floor it stands on.
    static func environment() -> (panel: MeshData, floor: MeshData) {
        var panel = MeshData()
        let z = Layout.panelZ
        panel.addQuad([-5.1, -10.2, z], [5.1, -10.2, z], [5.1, 10.9, z], [-5.1, 10.9, z], normal: [0, 0, 1])

        var floor = MeshData()
        let y = Layout.floorY
        floor.addQuad([-45, y, 25], [45, y, 25], [45, y, -35], [-45, y, -35], normal: [0, 1, 0])
        return (panel, floor)
    }
}

/// World-space layout shared by the scene builder and the renderer.
enum Layout {
    static let panelZ: Float = -0.8
    static let floorY: Float = -10.95
    static let holdX: Float = -9.6
    static let nextX: Float = 9.6
    static let previewTopY: Float = 7.6

    /// World centre of a board cell.
    static func position(x: Float, y: Float) -> SIMD3<Float> {
        SIMD3(x - 4.5, y - 9.5, 0)
    }
}
