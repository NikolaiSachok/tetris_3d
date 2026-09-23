import simd

/// CPU-simulated sparks, dust and drop trails, uploaded as billboards every frame.
struct ParticleSystem {
    static let capacity = 6000

    private struct Spark {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var color: SIMD3<Float>
        var size: Float
        var life: Float
        var maxLife: Float
        var gravity: Float
        var drag: Float
    }

    private var sparks: [Spark] = []
    private var rng = SystemRandomNumberGenerator()

    var isEmpty: Bool { sparks.isEmpty }

    mutating func update(dt: Float) {
        for i in sparks.indices.reversed() {
            sparks[i].life -= dt
            if sparks[i].life <= 0 {
                sparks.swapAt(i, sparks.count - 1)
                sparks.removeLast()
                continue
            }
            sparks[i].velocity.y -= sparks[i].gravity * dt
            sparks[i].velocity *= exp(-sparks[i].drag * dt)
            sparks[i].position += sparks[i].velocity * dt
            if sparks[i].position.y < Layout.floorY + 0.05, sparks[i].velocity.y < 0 {
                sparks[i].position.y = Layout.floorY + 0.05
                sparks[i].velocity.y *= -0.35
                sparks[i].velocity.x *= 0.7
                sparks[i].velocity.z *= 0.7
            }
        }
    }

    func gpuParticles() -> [Particle] {
        sparks.map { spark in
            let t = spark.life / spark.maxLife
            // Hot white core that cools into the block colour, then fades.
            let heat = SIMD3<Float>.mix(spark.color, SIMD3(repeating: 1), max(0, t - 0.6) * 2)
            return Particle(position: SIMD4(spark.position, spark.size * (0.4 + 0.6 * t)),
                            color: SIMD4(heat * 5, min(1, t * 2)))
        }
    }

    mutating func emitBurst(at center: SIMD3<Float>, color: SIMD3<Float>, strength: Float) {
        let count = 14 + Int(strength * 4)
        for _ in 0..<count {
            let direction = normalize(SIMD3<Float>(random(-1, 1), random(-0.4, 1.2), random(-0.2, 1.4)))
            add(Spark(position: center + SIMD3(random(-0.4, 0.4), random(-0.4, 0.4), random(-0.4, 0.4)),
                      velocity: direction * random(3, 9 + strength * 2),
                      color: color, size: random(0.05, 0.14), life: 0, maxLife: random(0.6, 1.4),
                      gravity: 14, drag: 1.6))
        }
    }

    mutating func emitTrail(from start: SIMD3<Float>, to end: SIMD3<Float>, color: SIMD3<Float>) {
        let length = distance(start, end)
        let count = Int(length * 3)
        guard count > 0 else { return }
        for i in 0..<count {
            let t = Float(i) / Float(count)
            add(Spark(position: .mix(end, start, t) + SIMD3(random(-0.35, 0.35), 0, random(-0.3, 0.3)),
                      velocity: SIMD3(random(-0.2, 0.2), random(1, 3), random(-0.2, 0.2)),
                      color: color, size: random(0.04, 0.09), life: 0, maxLife: random(0.15, 0.45) * (1 - t * 0.6),
                      gravity: 0, drag: 3))
        }
    }

    mutating func emitDust(at point: SIMD3<Float>, color: SIMD3<Float>) {
        for _ in 0..<10 {
            let angle = random(0, 2 * .pi)
            add(Spark(position: point + SIMD3(random(-0.45, 0.45), 0, random(-0.3, 0.3)),
                      velocity: SIMD3(cos(angle) * random(1, 4), random(0.5, 2.5), sin(angle) * random(0.5, 2)),
                      color: SIMD3.mix(color, SIMD3(repeating: 1), 0.3), size: random(0.04, 0.08), life: 0,
                      maxLife: random(0.25, 0.5), gravity: 9, drag: 4))
        }
    }

    private mutating func add(_ spark: Spark) {
        guard sparks.count < ParticleSystem.capacity else { return }
        var spark = spark
        spark.life = spark.maxLife
        sparks.append(spark)
    }

    private mutating func random(_ low: Float, _ high: Float) -> Float {
        Float.random(in: low...high, using: &rng)
    }
}
