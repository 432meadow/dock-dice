import Foundation
import SceneKit

/// Held-follow behaviour (pure, called on the render thread) and release velocity
/// (cursor history kept on the main thread).
final class ThrowController {
    // Held follow tuning
    static let followGain: CGFloat = 22          // 1/s: velocity = gain * distance
    static let followMaxSpeed: CGFloat = 90      // units/s
    static let heldSpinFactor: CGFloat = 0.35    // fraction of pure rolling spin while dragged
    static let heldSpinBlend: CGFloat = 0.15     // per-step blend toward desired spin (extra damping)
    // Release tuning
    static let releaseWindow: TimeInterval = 0.10
    static let releaseMaxSpeed: CGFloat = 45     // units/s
    static let releaseSpinFactor: CGFloat = 0.6
    static let slowSpeed: CGFloat = 3            // below this a release is a "hop"

    private var samples: [(t: TimeInterval, p: CGPoint)] = []

    // Shake detection: quick reversals of cursor direction above a speed floor.
    static let shakeSpeedFloor: CGFloat = 450      // pt/s between consecutive samples
    static let shakeWindow: TimeInterval = 0.6
    static let shakeReversals = 3
    static let shakeReleaseGrace: TimeInterval = 0.35   // a release this soon after a reversal is "after a shake"
    static let throwStroke: TimeInterval = 0.12     // final stroke at least this long counts as a real throw
    private var lastDir: CGVector?
    private var reversals: [TimeInterval] = []

    struct ShakeStep {
        let reversal: Bool
        let count: Int            // reversals within the window
        var shaking: Bool { count >= ThrowController.shakeReversals - 1 }
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func begin(_ p: CGPoint, at t: TimeInterval = ThrowController.now) {
        samples = [(t, p)]
        lastDir = nil
        reversals = []
    }

    /// Adds a cursor sample; reports whether it reversed direction (for the rattle and tumble).
    @discardableResult
    /// `shakeAllowed: false` (cursor in or approaching the drop zone) records the sample but
    /// counts no reversals, so up-and-down approaches to the Dock edge are not a shake.
    func add(_ p: CGPoint, at t: TimeInterval = ThrowController.now, shakeAllowed: Bool = true) -> ShakeStep {
        var reversal = false
        if !shakeAllowed {
            lastDir = nil
            reversals.removeAll()
        } else if let prev = samples.last, t - prev.t >= 0.004 {
            let dt = CGFloat(t - prev.t)
            let v = CGVector(dx: (p.x - prev.p.x) / dt, dy: (p.y - prev.p.y) / dt)
            let speed = hypot(v.dx, v.dy)
            if speed > Self.shakeSpeedFloor {
                let dir = CGVector(dx: v.dx / speed, dy: v.dy / speed)
                if let ld = lastDir, dir.dx * ld.dx + dir.dy * ld.dy < -0.3 {
                    reversals.append(t)
                    reversal = true
                }
                lastDir = dir
            }
        }
        reversals.removeAll { t - $0 > Self.shakeWindow }
        samples.append((t, p))
        samples.removeAll { t - $0.t > Self.retain + 0.05 }
        return ShakeStep(reversal: reversal, count: reversals.count)
    }

    /// Release velocity source: the strongest motion in the retained ~0.3 s of samples.
    /// Every sub-window of 50–100 ms (pairs of samples) is measured; its speed is scaled down by how
    /// long before the release it ended (1.0 at release, 0.4 at 0.3 s ago), and the best scaled one
    /// wins. So a throw that ends in a brief pause, or a late trackpad mouse-up, still flies, while a
    /// die held still for the whole window still just hops.
    static let subWindowMin: TimeInterval = 0.050   // spans several events, so one noisy pair can't set the peak
    static let subWindowMax: TimeInterval = 0.100
    static let retain: TimeInterval = 0.30
    static let ageFalloff: CGFloat = 0.6      // scale = 1 - ageFalloff * age / retain

    func cursorVelocity(at t: TimeInterval, since: TimeInterval? = nil) -> (CGVector, String) {
        let kept = samples.filter { t - $0.t <= Self.retain + 0.0001 && $0.t >= (since ?? -1) - 0.0001 }
        var best = CGVector.zero, bestScore: CGFloat = 0
        var bestInfo = ""
        if kept.count >= 2 {
            for i in 1..<kept.count {
                for j in stride(from: i - 1, through: 0, by: -1) {
                    let dt = kept[i].t - kept[j].t
                    if dt > Self.subWindowMax { break }
                    if dt < Self.subWindowMin { continue }
                    let v = CGVector(dx: (kept[i].p.x - kept[j].p.x) / dt, dy: (kept[i].p.y - kept[j].p.y) / dt)
                    let age = max(0, t - kept[i].t)
                    let scale = max(0.2, 1 - Self.ageFalloff * CGFloat(age / Self.retain))
                    let score = hypot(v.dx, v.dy) * scale
                    if score > bestScore {
                        bestScore = score
                        best = CGVector(dx: v.dx * scale, dy: v.dy * scale)
                        bestInfo = String(format: "peak %.0f pt/s over %.0f ms ending %.0f ms before release, x%.2f",
                                          hypot(v.dx, v.dy), dt * 1000, age * 1000, scale)
                    }
                }
            }
        }
        let summary = String(format: "%d samples in last %.0f ms; ", kept.count, Self.retain * 1000)
            + (bestInfo.isEmpty ? "no movement" : bestInfo)
        return (best, summary)
    }

    /// Release: linear = averaged cursor velocity in scene units (clamped); angular = rolling spin
    /// proportional to speed plus a random part. Slow releases still hop.
    func releaseVelocity(edgePoints e: CGFloat, at t: TimeInterval) -> (SCNVector3, SCNVector4, String) {
        // After a shake, only the final stroke (since the last reversal) can carry a throw, and only
        // if it lasted long enough to be a deliberate stroke rather than half a shake.
        let recent = reversals.filter { t - $0 <= Self.shakeWindow }
        let afterShake = recent.count >= Self.shakeReversals - 1 && (recent.last.map { t - $0 <= Self.shakeReleaseGrace } ?? false)
        let since = afterShake ? recent.last : nil
        let (cv, info) = cursorVelocity(at: t, since: since)
        var v = SCNVector3(cv.dx / e, -cv.dy / e, 0)          // CG y is down; scene y is up
        v = v.clamped(Self.releaseMaxSpeed)
        var desc = String(format: "cursor %.0f,%.0f pt/s (%@) -> %.1f u/s", cv.dx, cv.dy, info, v.length)
        if afterShake, let last = since {
            let stroke = t - last
            if stroke < Self.throwStroke {
                v = v * 0.25
                desc += String(format: "; AFTER SHAKE (%d reversals): final stroke %.0f ms < %.0f ms, not a throw -> damped to %.1f u/s",
                                recent.count, stroke * 1000, Self.throwStroke * 1000, v.length)
            } else {
                desc += String(format: "; AFTER SHAKE (%d reversals): final stroke %.0f ms counts as a throw", recent.count, stroke * 1000)
            }
        }
        let speed = v.length
        if speed < Self.slowSpeed {
            v = v + SCNVector3(CGFloat.random(in: -1.5...1.5), CGFloat.random(in: -1.5...1.5), 0)
            v.z = CGFloat.random(in: 5...7)
            desc += " (slow: hop)"
        } else {
            v.z = 1.0
        }
        let roll = SCNVector3(-v.y, v.x, 0) * (Self.releaseSpinFactor / 0.5)   // ẑ × v, ω = v / r
        var w = roll + Self.randomSpin(CGFloat.random(in: 4...9))
        if afterShake {
            w = w + Self.randomSpin(CGFloat.random(in: 16...26))
            v.z = max(v.z, CGFloat.random(in: 4...6))
            desc += "; extra shake spin"
        }
        return (v, axisAngle(w), desc)
    }

    /// One step of the held follow: stiff clamped velocity toward the target, and spin about ẑ × v
    /// blended so it calms down when the cursor stops.
    static func heldStep(position p: SCNVector3, target: SCNVector3, angular w: SCNVector3, dt: TimeInterval)
        -> (SCNVector3, SCNVector3) {
        let v = ((target - p) * followGain).clamped(followMaxSpeed)
        let desired = SCNVector3(-v.y, v.x, 0) * (heldSpinFactor / 0.5)
        let blend = min(1, heldSpinBlend * CGFloat(dt * 60))
        let newW = (w + (desired - w) * blend).clamped(30)
        return (v, newW)
    }

    /// Pop out of the Dock: a short toss toward the screen centre with random spin.
    static func popVelocity(from p: CGPoint) -> (SCNVector3, SCNVector4) {
        let d = CGVector(dx: -p.x, dy: -p.y)
        let l = max(sqrt(d.dx * d.dx + d.dy * d.dy), 0.001)
        let speed = CGFloat.random(in: 7...10)
        let v = SCNVector3(d.dx / l * speed, d.dy / l * speed, 6)
        let roll = SCNVector3(-v.y, v.x, 0) * (0.5 / 0.5)
        return (v, axisAngle(roll + randomSpin(CGFloat.random(in: 6...10))))
    }

    static func randomSpin(_ magnitude: CGFloat) -> SCNVector3 {
        var r: SCNVector3
        repeat {
            r = SCNVector3(CGFloat.random(in: -1...1), CGFloat.random(in: -1...1), CGFloat.random(in: -1...1))
        } while r.length < 0.2 || r.length > 1
        return r * (magnitude / r.length)
    }
}
