import Darwin

// Real-time DSP building blocks. Everything here runs on the audio render thread, so it never
// allocates, locks or goes through generics (unspecialized generics are slow in debug builds).

enum DSP {
    static let twoPi = Float.pi * 2

    static func midiToHz(_ note: Float) -> Float { 440 * exp2f((note - 69) / 12) }

    /// Per-sample multiplier that decays a value by 1/e over `time` seconds.
    static func decayCoefficient(_ time: Float, sampleRate: Float) -> Float {
        time <= 0 ? 0 : expf(-1 / (time * sampleRate))
    }

    /// Band-limited step correction for saw/square discontinuities.
    @inline(__always)
    static func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}

enum SynthWave: UInt8, Sendable {
    case sine, triangle, saw, square

    /// One sample at `phase` (0..<1) advancing by `inc` cycles per sample.
    @inline(__always)
    func sample(_ phase: Float, _ inc: Float) -> Float {
        switch self {
        case .sine:
            return sinf(phase * DSP.twoPi)
        case .triangle:
            return 1 - 4 * fabsf(phase - 0.5)
        case .saw:
            return 2 * phase - 1 - DSP.polyBLEP(phase, inc)
        case .square:
            var half = phase + 0.5
            if half >= 1 { half -= 1 }
            return (phase < 0.5 ? 1 : -1) + DSP.polyBLEP(phase, inc) - DSP.polyBLEP(half, inc)
        }
    }
}

extension DSP {
    /// xorshift32 white noise in -1...1.
    struct NoiseSource {
        var state: UInt32

        init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }

        @inline(__always)
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(Int32(bitPattern: state)) * (1 / 2_147_483_648)
        }
    }

    /// Topology-preserving state-variable filter (Zavalishin/Simper): stable under fast cutoff modulation.
    struct SVFilter {
        enum Mode: UInt8, Sendable { case off, lowpass, highpass, bandpass }

        struct Coefficients {
            var k: Float = 2
            var a1: Float = 1
            var a2: Float = 0
            var a3: Float = 0

            /// `resonance` 0...1; 0.3 is roughly Butterworth.
            init(cutoff: Float, resonance: Float, sampleRate: Float) {
                let fc = fminf(fmaxf(cutoff, 20), sampleRate * 0.45)
                let g = tanf(Float.pi * fc / sampleRate)
                k = 2 - 2 * fminf(fmaxf(resonance, 0), 0.96)
                a1 = 1 / (1 + g * (g + k))
                a2 = g * a1
                a3 = g * a2
            }

            init() {}
        }

        var ic1: Float = 0
        var ic2: Float = 0

        @inline(__always)
        mutating func process(_ v0: Float, _ c: Coefficients, _ mode: Mode) -> Float {
            let v3 = v0 - ic2
            let v1 = c.a1 * ic1 + c.a2 * v3
            let v2 = ic2 + c.a2 * ic1 + c.a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            switch mode {
            case .off: return v0
            case .lowpass: return v2
            case .bandpass: return v1
            case .highpass: return v0 - c.k * v1 - v2
            }
        }
    }

    /// Linear attack, exponential decay to sustain, exponential release. Times are 1/e time constants
    /// (the level is ~1% after 4.6× the time), except attack which is the linear ramp length.
    struct Envelope {
        enum Stage: UInt8 { case attack, decay, release, done }

        private(set) var stage = Stage.attack
        private(set) var level: Float = 0
        private var attackStep: Float
        private var decayCoef: Float
        private var sustain: Float
        private var releaseCoef: Float

        static let silence: Float = 0.0001

        init(attack: Float, decay: Float, sustain: Float, release: Float, sampleRate: Float) {
            attackStep = 1 / (fmaxf(attack, 0.001) * sampleRate)
            decayCoef = DSP.decayCoefficient(fmaxf(decay, 0.001), sampleRate: sampleRate)
            self.sustain = sustain
            releaseCoef = DSP.decayCoefficient(fmaxf(release, 0.003), sampleRate: sampleRate)
        }

        var isReleasing: Bool { stage == .release || stage == .done }

        mutating func noteOff() {
            if stage != .done { stage = .release }
        }

        /// Fast fade used when a voice is stolen; short enough to free the slot quickly, long enough not to click.
        mutating func kill(sampleRate: Float) {
            releaseCoef = DSP.decayCoefficient(0.006, sampleRate: sampleRate)
            noteOff()
        }

        @inline(__always)
        mutating func next() -> Float {
            switch stage {
            case .attack:
                level += attackStep
                if level >= 1 {
                    level = 1
                    stage = .decay
                }
            case .decay:
                level = sustain + (level - sustain) * decayCoef
                if sustain == 0, level < Envelope.silence { stage = .done }
            case .release:
                level *= releaseCoef
                if level < Envelope.silence {
                    level = 0
                    stage = .done
                }
            case .done:
                level = 0
            }
            return level
        }
    }

    /// One-pole parameter smoother (volumes, fades) to avoid zipper noise.
    struct Smoothed {
        var value: Float
        var target: Float
        private let coef: Float

        init(_ value: Float, time: Float, sampleRate: Float) {
            self.value = value
            target = value
            coef = DSP.decayCoefficient(time, sampleRate: sampleRate)
        }

        @inline(__always)
        mutating func next() -> Float {
            value = target + (value - target) * coef
            return value
        }
    }

    /// Fixed-length circular buffer: reading gives the sample written `length` samples ago.
    struct DelayLine {
        private let buffer: UnsafeMutablePointer<Float>
        let length: Int
        private var index = 0

        init(length: Int) {
            self.length = max(length, 1)
            buffer = .allocate(capacity: self.length)
            buffer.initialize(repeating: 0, count: self.length)
        }

        func deallocate() { buffer.deallocate() }

        @inline(__always)
        var output: Float { buffer[index] }

        @inline(__always)
        mutating func push(_ x: Float) {
            buffer[index] = x
            index += 1
            if index == length { index = 0 }
        }
    }

    /// Schroeder allpass used to thicken the reverb input.
    struct Allpass {
        private var line: DelayLine
        private let gain: Float

        init(length: Int, gain: Float) {
            line = DelayLine(length: length)
            self.gain = gain
        }

        func deallocate() { line.deallocate() }

        @inline(__always)
        mutating func process(_ x: Float) -> Float {
            let delayed = line.output
            let w = x + gain * delayed
            line.push(w)
            return delayed - gain * w
        }
    }

    /// Four-line feedback delay network with a Hadamard mix and damped feedback: a smooth, dark hall.
    struct Reverb {
        private var d0, d1, d2, d3: DelayLine
        private var a0, a1: Allpass
        private var damp: (Float, Float, Float, Float) = (0, 0, 0, 0)
        private let feedback: Float = 0.83
        private let damping: Float = 0.32

        init(sampleRate: Float) {
            let scale = sampleRate / 48000
            func len(_ n: Float) -> Int { Int(n * scale) }
            d0 = DelayLine(length: len(2531))
            d1 = DelayLine(length: len(3079))
            d2 = DelayLine(length: len(3583))
            d3 = DelayLine(length: len(4211))
            a0 = Allpass(length: len(347), gain: 0.6)
            a1 = Allpass(length: len(113), gain: 0.6)
        }

        func deallocate() {
            for line in [d0, d1, d2, d3] { line.deallocate() }
            a0.deallocate()
            a1.deallocate()
        }

        @inline(__always)
        mutating func process(_ input: Float) -> (Float, Float) {
            let x = a1.process(a0.process(input))
            let o0 = d0.output, o1 = d1.output, o2 = d2.output, o3 = d3.output
            damp.0 += damping * (o0 - damp.0)
            damp.1 += damping * (o1 - damp.1)
            damp.2 += damping * (o2 - damp.2)
            damp.3 += damping * (o3 - damp.3)
            let s = feedback * 0.5
            d0.push(x + s * (damp.0 + damp.1 + damp.2 + damp.3))
            d1.push(x + s * (damp.0 - damp.1 + damp.2 - damp.3))
            d2.push(-x + s * (damp.0 + damp.1 - damp.2 - damp.3))
            d3.push(-x + s * (damp.0 - damp.1 - damp.2 + damp.3))
            return ((o0 + o2) * 0.5, (o1 + o3) * 0.5)
        }
    }

    /// Stereo ping-pong echo with a darkening feedback path.
    struct PingPongDelay {
        private var left: DelayLine
        private var right: DelayLine
        private var lpL: Float = 0
        private var lpR: Float = 0
        private let feedback: Float = 0.42

        init(time: Float, sampleRate: Float) {
            left = DelayLine(length: Int(time * sampleRate))
            right = DelayLine(length: Int(time * sampleRate))
        }

        func deallocate() {
            left.deallocate()
            right.deallocate()
        }

        @inline(__always)
        mutating func process(_ input: Float) -> (Float, Float) {
            let l = left.output, r = right.output
            lpL += 0.45 * (l - lpL)
            lpR += 0.45 * (r - lpR)
            left.push(input + feedback * lpR)
            right.push(feedback * lpL)
            return (l, r)
        }
    }

    /// Master bus protection: a peak limiter (1 ms attack, slow release) followed by a soft-knee
    /// clipper, so the output can never exceed ±1 however many sounds pile up.
    struct Limiter {
        private var envelope: Float = 0
        private var gain: Float = 1
        private let attack: Float
        private let release: Float
        private let threshold: Float = 0.8

        init(sampleRate: Float) {
            attack = DSP.decayCoefficient(0.001, sampleRate: sampleRate)
            release = DSP.decayCoefficient(0.2, sampleRate: sampleRate)
        }

        @inline(__always)
        mutating func process(_ l: inout Float, _ r: inout Float) {
            let peak = fmaxf(fabsf(l), fabsf(r))
            envelope = peak > envelope ? peak : envelope * release + peak * (1 - release)
            let target = envelope > threshold ? threshold / envelope : 1
            gain = target + (gain - target) * (target < gain ? attack : release)
            l = Limiter.softClip(l * gain)
            r = Limiter.softClip(r * gain)
        }

        /// Identity below 0.8, then a tanh knee that approaches (and never exceeds) 1.
        @inline(__always)
        static func softClip(_ x: Float) -> Float {
            let a = fabsf(x)
            guard a > 0.8 else { return x }
            let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
            return x < 0 ? -y : y
        }
    }
}
