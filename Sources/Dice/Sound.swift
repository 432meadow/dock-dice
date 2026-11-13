import AVFoundation
import Foundation

/// Every sound is synthesised once at launch into PCM buffers (no audio files, nothing to license).
/// A small pool of player nodes plays them. The engine runs only while the die is out and busy:
/// it is started on demand and stopped a few seconds after the die docks or comes to rest,
/// so the audio hardware is not held awake.
final class SoundBoard {
    static let sampleRate = 44100.0
    /// Overall level: a quiet background detail at normal system volume.
    static let masterLevel: Float = 0.3
    private static let defaultsKey = "soundEnabled"

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundBoard.sampleRate, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [String: [AVAudioPCMBuffer]] = [:]
    private var stopWork: DispatchWorkItem?
    private var wantIdle = true      // the die is docked/resting: the engine should not stay up
    let forcedMute = env["DICE_MUTE"] == "1"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            dlog("SOUND setting -> \(enabled ? "on" : "off") (saved)")
            if !audible { stopEngine(reason: "sound turned off") }
        }
    }

    private var audible: Bool { enabled && !forcedMute }

    init() {
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true])
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let t0 = ProcessInfo.processInfo.systemUptime
        for (name, variants) in Self.catalog() { buffers[name] = variants.map { Self.buffer($0, format) } }
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = Self.masterLevel
        dlog(String(format: "SOUND board ready: %d sounds synthesised in %.0f ms; setting %@%@",
                    buffers.count, (ProcessInfo.processInfo.systemUptime - t0) * 1000,
                    enabled ? "on" : "off", forcedMute ? ", DICE_MUTE=1 (muted: sounds are logged only)" : ""))
    }

    /// The die is out: make sure the engine can play.
    func wake(_ why: String) {
        wantIdle = false
        stopWork?.cancel()
        stopWork = nil
        startIfNeeded(why)
    }

    private func startIfNeeded(_ why: String) {
        guard audible, !engine.isRunning else { return }
        do {
            try engine.start()
            dlog("SOUND engine started (\(why))")
        } catch {
            dlog("SOUND engine failed to start: \(error)")
        }
    }

    /// The die is docked or resting: stop the engine after a grace period.
    func idle(after seconds: TimeInterval, _ why: String) {
        wantIdle = true
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopEngine(reason: why) }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func stopEngine(reason: String) {
        guard engine.isRunning else { return }
        players.forEach { $0.stop() }
        engine.stop()
        dlog("SOUND engine stopped (\(reason))")
    }

    /// Main thread only.
    func play(_ name: String, volume: Float, detail: String = "") {
        let v = min(max(volume, 0), 1)
        guard let variants = buffers[name], let buf = variants.randomElement() else { return }
        let note = detail.isEmpty ? "" : " [\(detail)]"
        guard audible else {
            dlog(String(format: "SOUND %@ vol %.2f (muted%@)%@", name, v, forcedMute ? ": DICE_MUTE=1" : ": setting off", note))
            return
        }
        startIfNeeded("play \(name)")
        guard engine.isRunning else { return }
        if wantIdle { idle(after: 2, "after \(name) while idle") }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        p.stop()
        p.volume = v
        p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        p.play()
        dlog(String(format: "SOUND %@ vol %.2f%@", name, v, note))
    }

    // MARK: Synthesis
    //
    // Palette: a wooden die on a felt-lined table heard from across a quiet room. Low, round tones
    // with 2-6 ms fade-ins (no click transients), every sound low-passed (4th-order at <= 1.8 kHz)
    // so almost nothing is left above 2 kHz.

    /// Name -> variants, used by init and by the offline analysis harness.
    static func catalog() -> [(String, [[Float]])] {
        [
            ("tokWall", [190.0, 225, 260, 300, 345].map { tok(freq: $0, floor: false) }),
            ("tokFloor", [160.0, 185, 210, 240, 270].map { tok(freq: $0, floor: true) }),
            ("rattle", (0..<4).map { _ in rattle() }),
            ("thunk", [thunk(big: false)]),
            ("bigThunk", [thunk(big: true)]),
            ("crumple", [crumple()]),
            ("pop", [pop()]),
            ("blip", [blip()]),
            ("chime", [chime()]),
        ]
    }

    private static func buffer(_ samples: [Float], _ format: AVAudioFormat) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        let ch = b.floatChannelData![0]
        for i in 0..<samples.count { ch[i] = samples[i] }
        return b
    }

    private static func n(_ seconds: Double) -> Int { Int(seconds * sampleRate) }
    private static func noise() -> Float { Float.random(in: -1...1) }

    /// RBJ biquad low-pass, applied `passes` times (2 passes = 4th order).
    static func lowpass(_ x: [Float], cutoff: Double, passes: Int = 2) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let cw = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 - cw) / 2 / a0, b1 = (1 - cw) / a0, b2 = (1 - cw) / 2 / a0
        let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
        var y = x
        for _ in 0..<passes {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let xi = Double(y[i])
                let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                y[i] = Float(yi)
            }
        }
        return y
    }

    /// Normalise to a peak level, with a short fade-out so nothing ends on a click.
    static func finish(_ x: [Float], peak: Float, cutoff: Double) -> [Float] {
        var y = lowpass(x, cutoff: cutoff)
        let fade = min(y.count / 4, n(0.01))
        for i in 0..<fade { y[y.count - 1 - i] *= Float(i) / Float(fade) }
        let m = y.map { abs($0) }.max() ?? 1
        let k = m > 0 ? peak / m : 1
        return y.map { $0 * k }
    }

    /// Smooth attack (raised-cosine over `attack` s) times exponential decay.
    private static func shape(_ t: Double, attack: Double, tau: Double) -> Double {
        let a = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
        return a * exp(-max(0, t - attack) / tau)
    }

    /// Soft "tok": a damped low tone, a faint wooden overtone (walls only), a trace of dark noise.
    static func tok(freq f: Double, floor: Bool) -> [Float] {
        let dur = 0.12
        let tau = floor ? 0.014 : 0.017          // ~40-70 ms to near silence
        var out = [Float](repeating: 0, count: n(dur))
        var lp: Float = 0
        for i in 0..<out.count {
            let t = Double(i) / sampleRate
            let e = shape(t, attack: 0.003, tau: tau)
            var s = sin(2 * .pi * f * t) * e
            if !floor { s += 0.18 * sin(2 * .pi * f * 2.4 * t) * shape(t, attack: 0.003, tau: tau * 0.5) }
            lp += 0.05 * (noise() - lp)
            s += 0.12 * Double(lp) * shape(t, attack: 0.002, tau: 0.008)
            out[i] = Float(s)
        }
        return finish(out, peak: floor ? 0.55 : 0.7, cutoff: floor ? 900 : 1500)
    }

    /// Muffled rattle: a few very soft low toks close together, like dice in a cupped hand.
    static func rattle() -> [Float] {
        let dur = 0.09
        var out = [Float](repeating: 0, count: n(dur))
        var t0 = 0.0
        for _ in 0..<Int.random(in: 3...4) {
            let f = Double.random(in: 260...420)
            let a = Double.random(in: 0.5...1.0)
            let start = n(t0)
            for j in 0..<n(0.05) where start + j < out.count {
                let t = Double(j) / sampleRate
                out[start + j] += Float(a * sin(2 * .pi * f * t) * shape(t, attack: 0.003, tau: 0.008))
            }
            t0 += Double.random(in: 0.006...0.016)
        }
        var lp: Float = 0
        for i in 0..<out.count {
            lp += 0.03 * (noise() - lp)
            out[i] += 0.15 * lp * Float(shape(Double(i) / sampleRate, attack: 0.004, tau: 0.03))
        }
        return finish(out, peak: 0.4, cutoff: 800)
    }

    /// Pillowy landing in the Dock: a soft low sweep and a dark "fwump" of air. `big` (the
    /// shoot-home) is fuller and longer, not louder.
    static func thunk(big: Bool) -> [Float] {
        let dur = big ? 0.42 : 0.32
        let f0 = big ? 100.0 : 115.0, f1 = big ? 58.0 : 72.0, tau = big ? 0.1 : 0.07
        var out = [Float](repeating: 0, count: n(dur))
        var phase = 0.0, lp: Float = 0
        for i in 0..<out.count {
            let t = Double(i) / sampleRate
            let f = f1 + (f0 - f1) * exp(-t / 0.06)
            phase += 2 * .pi * f / sampleRate
            var s = sin(phase) * shape(t, attack: 0.006, tau: tau)
            // Soft 2nd harmonic so laptop speakers (little output below ~150 Hz) still carry it;
            // the shoot-home gets more of it: fuller, not louder.
            s += (big ? 0.5 : 0.35) * sin(phase * 2) * shape(t, attack: 0.008, tau: tau * 0.6)
            lp += 0.02 * (noise() - lp)
            s += 0.6 * Double(lp) * shape(t, attack: 0.005, tau: 0.04)
            out[i] = Float(s)
        }
        return finish(out, peak: 0.6, cutoff: 500)
    }

    /// Quiet paper rustle: overlapping soft grains of dark noise, swelling and fading.
    static func crumple() -> [Float] {
        let dur = 0.6
        var out = [Float](repeating: 0, count: n(dur))
        for _ in 0..<45 {
            let u = Double.random(in: 0...1)
            let t0 = dur * (0.05 + 0.75 * u * u * (3 - 2 * u))
            let len = Double.random(in: 0.012...0.035)
            let amp = Float.random(in: 0.3...1.0)
            let start = n(t0)
            for j in 0..<n(len) where start + j < out.count {
                let x = Double(j) / Double(n(len))
                out[start + j] += amp * noise() * Float(sin(.pi * x))
            }
        }
        return finish(out, peak: 0.35, cutoff: 1700)
    }

    /// Soft "bloop" as the die pops back into its tile.
    static func pop() -> [Float] {
        let dur = 0.2
        var out = [Float](repeating: 0, count: n(dur))
        var phase = 0.0
        for i in 0..<out.count {
            let t = Double(i) / sampleRate
            let f = 220 + 200 * min(1, t / 0.06)
            phase += 2 * .pi * f / sampleRate
            out[i] = Float(sin(phase) * shape(t, attack: 0.005, tau: 0.045))
        }
        return finish(out, peak: 0.5, cutoff: 1200)
    }

    /// Tiny soft pip for the wink.
    static func blip() -> [Float] {
        let dur = 0.14
        return finish((0..<n(dur)).map { i in
            let t = Double(i) / sampleRate
            return Float(sin(2 * .pi * 880 * t) * shape(t, attack: 0.004, tau: 0.03))
        }, peak: 0.35, cutoff: 1500)
    }

    /// Mellow kalimba-like two-note chime (E5, B5): soft attack, gentle decay, no bright partials.
    static func chime() -> [Float] {
        let dur = 1.3
        var out = [Float](repeating: 0, count: n(dur))
        let notes: [(Double, Double)] = [(0, 659.3), (0.13, 987.8)]
        for i in 0..<out.count {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (start, f) in notes where t >= start {
                let u = t - start
                s += sin(2 * .pi * f * u) * shape(u, attack: 0.006, tau: 0.32)
                s += 0.12 * sin(2 * .pi * f * 2 * u) * shape(u, attack: 0.006, tau: 0.1)
            }
            out[i] = Float(s)
        }
        return finish(out, peak: 0.5, cutoff: 1800)
    }
}
