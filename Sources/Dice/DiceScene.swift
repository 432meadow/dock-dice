import AppKit
import SceneKit
import simd

// MARK: - Small vector helpers (SCNVector3 components are CGFloat on macOS)

extension SCNVector3 {
    static func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: SCNVector3, s: CGFloat) -> SCNVector3 { SCNVector3(a.x * s, a.y * s, a.z * s) }
    var length: CGFloat { sqrt(x * x + y * y + z * z) }
    func clamped(_ maxLen: CGFloat) -> SCNVector3 {
        let l = length
        return l > maxLen && l > 0 ? self * (maxLen / l) : self
    }
    var short: String { String(format: "(%.2f, %.2f, %.2f)", x, y, z) }
}

/// Axis-angle (SceneKit's angularVelocity form) <-> plain angular velocity vector.
func angularVector(_ v: SCNVector4) -> SCNVector3 {
    let axis = SCNVector3(v.x, v.y, v.z)
    let l = axis.length
    return l > 1e-6 ? axis * (v.w / l) : SCNVector3(0, 0, 0)
}

func axisAngle(_ w: SCNVector3) -> SCNVector4 {
    let l = w.length
    return l > 1e-6 ? SCNVector4(w.x / l, w.y / l, w.z / l, l) : SCNVector4(0, 0, 1, 0)
}

/// The tabletop. x/y are screen axes (origin at the screen centre), +z points at the viewer,
/// one unit = one die edge. Everything that touches physics runs on SceneKit's render thread
/// inside the SCNSceneRendererDelegate callbacks; the main thread talks to it through `lock`.
final class DiceScene: NSObject, SCNSceneRendererDelegate, SCNPhysicsContactDelegate {
    enum Command {
        case place(position: SCNVector3, orientation: SCNQuaternion?, velocity: SCNVector3, angular: SCNVector4, held: Bool)
        case hold
        case release(velocity: SCNVector3, angular: SCNVector4)
        case returnTo(SCNVector3, duration: TimeInterval, style: ReturnStyle)
        case hideNow
        /// Kinematic animations (physics body removed while they run, restored after).
        case flipToSix(naturalLabel: String)   // loaded die / forced demo six: hop and flip onto 6
        case wobble                            // bored die fidgets in place
        case shuffleHome(to: CGPoint)          // bored die hops toward the Dock
    }

    enum ReturnStyle: String {
        case drop    // hand drop: short shrink
        case shot    // right-click / Recall: fast accelerating flight with spin
        case trash   // dropped on the Trash: twisting crumple into it
    }

    /// A kinematic animation stepped on the render thread. `k` runs 0...1.
    final class Script {
        let name: String
        let duration: TimeInterval
        var start: TimeInterval?
        let step: (SCNNode, Double) -> Void
        var events: [(k: Double, sound: String, volume: Float)]
        init(_ name: String, duration: TimeInterval, events: [(k: Double, sound: String, volume: Float)] = [],
             step: @escaping (SCNNode, Double) -> Void) {
            self.name = name; self.duration = duration; self.events = events; self.step = step
        }
    }

    private enum Mode {
        case idle
        case held
        case rolling
        case returning(from: SCNVector3, to: SCNVector3, start: TimeInterval?, duration: TimeInterval, style: ReturnStyle)
        case scripted(Script)
    }

    // Tuning
    static let gravity: CGFloat = 40
    static let liftZ: CGFloat = 1.7          // die centre while held (bottom face ~1.2 above the table)
    static let ceilingZ: CGFloat = 3.2
    static let restitution: CGFloat = 0.45
    static let friction: CGFloat = 0.6
    static let angularDamping: CGFloat = 0.2
    static let linearDamping: CGFloat = 0.1
    static let restLinear: CGFloat = 0.08
    static let restAngular: CGFloat = 0.15
    static let restHold: TimeInterval = 0.3
    static let fieldOfView: CGFloat = 25

    // Physics categories
    private static let catDie = 1, catWall = 2, catFloor = 4

    let scene = SCNScene()
    let cameraNode = SCNNode()
    let dieNode = SCNNode()            // carries the physics body; never scaled
    private let dieVisual = SCNNode()  // carries the geometry; scaled for cues and animations
    private let lightNode = SCNNode()
    private let blobNode: SCNNode?
    let halfW: CGFloat
    let halfH: CGFloat
    let cameraHeight: CGFloat
    let useBlobShadow: Bool

    // Shared with the main thread.
    private let lock = NSLock()
    private var queue: [Command] = []
    private var target = CGPoint.zero
    private var published = SCNVector3(0, 0, 0.5)
    private var epochValue = 0
    private var heldScaleTarget: CGFloat = 1
    private var shakeKicks = 0

    // Render-thread state.
    private var mode = Mode.idle
    private var quiet: TimeInterval = 0
    private var lastTime: TimeInterval?
    private var lastSimTime: TimeInterval?
    private var rollStart: TimeInterval = 0
    private var lastPosLog: TimeInterval = 0
    private var lastBounce: [String: TimeInterval] = [:]
    private var rollEpoch = 0
    private var heldScaleAtReturn: CGFloat = 1
    private var shotAxis = simd_float3(1, 0, 0)
    private var seenKicks = 0
    private var shakeFrames = 0
    private var prevVelocity: SCNVector3?
    private var lastHitTime: TimeInterval = 0
    private var lastWallContact: TimeInterval = 0
    private var textureCache: [String: [CGImage]] = [:]
    private(set) var palette = DiePalette.classic

    /// Main-thread callbacks.
    var onSettled: ((_ face: Int, _ seconds: TimeInterval, _ epoch: Int) -> Void)?
    var onReturned: ((_ epoch: Int) -> Void)?
    /// A scripted animation finished (name: "flip", "wobble", "shuffle").
    var onScriptDone: ((_ name: String, _ epoch: Int) -> Void)?
    /// A collision worth a sound: kind "wall"/"floor", strength 0...1. Also script sound events.
    var onSound: ((_ name: String, _ volume: Float, _ detail: String) -> Void)?

    init(halfWidth: CGFloat, halfHeight: CGFloat, blobShadow: Bool) {
        halfW = halfWidth
        halfH = halfHeight
        useBlobShadow = blobShadow
        let halfFov = Self.fieldOfView / 2 * .pi / 180
        cameraHeight = halfHeight / tan(halfFov)
        blobNode = blobShadow ? SCNNode() : nil
        super.init()
        build()
    }

    // MARK: Main-thread API

    var epoch: Int { lock.lock(); defer { lock.unlock() }; return epochValue }

    @discardableResult
    func send(_ c: Command) -> Int {
        lock.lock(); defer { lock.unlock() }
        queue.append(c)
        epochValue += 1
        return epochValue
    }

    func setTarget(_ p: CGPoint) {
        lock.lock(); target = p; lock.unlock()
    }

    /// A shake reversal while held: tumble the die energetically for a moment.
    func shakeKick() {
        lock.lock(); shakeKicks += 1; lock.unlock()
    }

    // MARK: Looks (main thread; SceneKit property changes are safe here inside a transaction)

    private func textures(for p: DiePalette) -> [CGImage] {
        if let t = textureCache[p.name] { return t }
        let t = [1, 2, 6, 5, 3, 4].map { DieArt.texture(value: $0, px: 512, palette: p) }
        textureCache[p.name] = t
        return t
    }

    func applySkin(_ p: DiePalette) {
        palette = p
        let tex = textures(for: p)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (i, m) in (dieVisual.geometry?.materials ?? []).enumerated() {
            m.diffuse.contents = tex[i]
            switch p.name {
            case "gold":
                m.specular.contents = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.48, alpha: 1)
                m.shininess = 0.8
                m.reflective.contents = DieArt.goldReflection()
                m.reflective.intensity = 0.55
                m.fresnelExponent = 1.2
            case "friday13":
                // Tight highlight only: a broad one washes the black top face out to grey.
                m.specular.contents = NSColor(white: 0.2, alpha: 1)
                m.shininess = 1.0
                m.reflective.contents = nil
            default:
                m.specular.contents = NSColor(white: 0.35, alpha: 1)
                m.shininess = 0.35
                m.reflective.contents = nil
            }
        }
        SCNTransaction.commit()
        dlog("SCENE skin -> \(p.name)")
    }

    /// The loaded die's wink: the 6 face (material index 2) loses its pips for a moment.
    func setWink(_ closed: Bool) {
        guard let m = dieVisual.geometry?.materials[2] else { return }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        m.diffuse.contents = closed ? DieArt.texture(value: 6, px: 512, palette: palette, pips: false) : textures(for: palette)[2]
        SCNTransaction.commit()
    }

    /// Visual cue while held: < 1 when letting go would put the die away.
    func setHeldScale(_ s: CGFloat) {
        lock.lock(); heldScaleTarget = s; lock.unlock()
    }

    var publishedPosition: SCNVector3 {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    func clampXY(_ p: CGPoint, margin: CGFloat = 0.6) -> CGPoint {
        CGPoint(x: min(max(p.x, -halfW + margin), halfW - margin),
                y: min(max(p.y, -halfH + margin), halfH - margin))
    }

    // MARK: Build

    private func build() {
        let world = scene.physicsWorld
        world.gravity = SCNVector3(0, 0, -Self.gravity)
        world.timeStep = 1.0 / 120.0
        world.contactDelegate = self

        // Camera: straight down -z, height chosen so z = 0 maps exactly onto the window.
        let cam = SCNCamera()
        cam.fieldOfView = Self.fieldOfView
        cam.projectionDirection = .vertical
        cam.zNear = 1
        cam.zFar = Double(cameraHeight + 20)
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 0, cameraHeight)
        scene.rootNode.addChildNode(cameraNode)

        // Lights: ambient fill, shadow-casting key that follows the die (tight shadow frustum),
        // and a soft omni from near the camera for the specular glint.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 420
        ambient.light!.color = NSColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 820
        key.castsShadow = !useBlobShadow
        key.shadowMode = .deferred
        key.shadowColor = NSColor(white: 0, alpha: 0.38)
        key.shadowRadius = 5
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.automaticallyAdjustsShadowProjection = false
        key.orthographicScale = 2.5
        key.zNear = 1
        key.zFar = 40
        lightNode.light = key
        scene.rootNode.addChildNode(lightNode)
        aimLight(at: SCNVector3(0, 0, 0.5))

        let glint = SCNNode()
        glint.light = SCNLight()
        glint.light!.type = .omni
        glint.light!.intensity = 250
        glint.position = SCNVector3(-halfW * 0.3, halfH * 0.4, cameraHeight * 0.6)
        scene.rootNode.addChildNode(glint)

        // Die: chamfered box, six DieArt textures. SCNBox material order (verified empirically):
        // +z, +x, -z, -x, +y, -y. Values: +z=1 -z=6, +x=2 -x=5, +y=3 -y=4 (opposites sum to 7).
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.12)
        box.chamferSegmentCount = 6
        box.materials = [1, 2, 6, 5, 3, 4].map { v in
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = DieArt.texture(value: v, px: 512)
            m.diffuse.mipFilter = .linear
            m.specular.contents = NSColor(white: 0.35, alpha: 1)
            m.shininess = 0.35
            return m
        }
        // Geometry lives on a child node. Only the child is ever scaled (drop-zone cue, return
        // animations): scaling a node that carries a dynamic physics body makes SceneKit push the
        // node's stale model transform into the body, which teleported the held die.
        dieVisual.geometry = box
        dieVisual.castsShadow = true
        dieNode.addChildNode(dieVisual)
        dieNode.isHidden = true
        dieNode.position = SCNVector3(0, 0, 0.5)
        scene.rootNode.addChildNode(dieNode)
        dieNode.physicsBody = makeBody()

        // Floor: a static slab whose top is z = 0, plus a visual plane that only shows the shadow.
        let floorShape = SCNBox(width: halfW * 2 + 8, height: halfH * 2 + 8, length: 4, chamferRadius: 0)
        let floorBody = SCNNode()
        floorBody.position = SCNVector3(0, 0, -2)
        floorBody.physicsBody = staticBody(SCNPhysicsShape(geometry: floorShape, options: nil),
                                           restitution: 0.6, friction: 0.8, category: Self.catFloor)
        scene.rootNode.addChildNode(floorBody)

        if let blob = blobNode {
            let plane = SCNPlane(width: 1.5, height: 1.5)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = DieArt.blobShadow(px: 256)
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            plane.materials = [m]
            blob.geometry = plane
            blob.castsShadow = false
            blob.isHidden = true
            blob.renderingOrder = -1
            scene.rootNode.addChildNode(blob)
        } else {
            let plane = SCNPlane(width: halfW * 2 + 2, height: halfH * 2 + 2)
            let m = SCNMaterial()
            m.lightingModel = .shadowOnly
            m.diffuse.contents = NSColor.black
            plane.materials = [m]
            let floorVis = SCNNode(geometry: plane)
            floorVis.castsShadow = false
            floorVis.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(floorVis)
        }

        // Walls just outside the screen edges, and a ceiling above lift height.
        let t: CGFloat = 4, h: CGFloat = 12
        func wall(_ name: String, _ w: CGFloat, _ hh: CGFloat, _ l: CGFloat, _ pos: SCNVector3) {
            let n = SCNNode()
            n.name = name
            n.position = pos
            n.physicsBody = staticBody(SCNPhysicsShape(geometry: SCNBox(width: w, height: hh, length: l, chamferRadius: 0), options: nil),
                                       restitution: 0.9, friction: 0.3, category: Self.catWall)
            scene.rootNode.addChildNode(n)
        }
        wall("left wall", t, halfH * 2 + 2 * t, h, SCNVector3(-halfW - t / 2, 0, h / 2 - 1))
        wall("right wall", t, halfH * 2 + 2 * t, h, SCNVector3(halfW + t / 2, 0, h / 2 - 1))
        wall("bottom wall", halfW * 2 + 2 * t, t, h, SCNVector3(0, -halfH - t / 2, h / 2 - 1))
        wall("top wall", halfW * 2 + 2 * t, t, h, SCNVector3(0, halfH + t / 2, h / 2 - 1))
        wall("ceiling", halfW * 2 + 2 * t, halfH * 2 + 2 * t, t, SCNVector3(0, 0, Self.ceilingZ + t / 2))
    }

    private func makeBody() -> SCNPhysicsBody {
        let shape = SCNPhysicsShape(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0), options: nil)
        let b = SCNPhysicsBody(type: .dynamic, shape: shape)
        b.mass = 1
        b.restitution = Self.restitution
        b.friction = Self.friction
        b.rollingFriction = 0
        b.angularDamping = Self.angularDamping
        b.damping = Self.linearDamping
        b.continuousCollisionDetectionThreshold = 0.3
        b.categoryBitMask = Self.catDie
        b.collisionBitMask = Self.catWall | Self.catFloor
        b.contactTestBitMask = Self.catWall
        b.allowsResting = true
        return b
    }

    private func staticBody(_ shape: SCNPhysicsShape, restitution: CGFloat, friction: CGFloat, category: Int) -> SCNPhysicsBody {
        let b = SCNPhysicsBody(type: .static, shape: shape)
        b.restitution = restitution
        b.friction = friction
        b.categoryBitMask = category
        b.collisionBitMask = Self.catDie
        return b
    }

    /// Orientation that puts the given face toward the viewer (+z).
    static func orientation(faceUp v: Int) -> SCNQuaternion {
        func q(_ axis: SCNVector3, _ angle: CGFloat) -> SCNQuaternion {
            let s = sin(angle / 2)
            return SCNQuaternion(axis.x * s, axis.y * s, axis.z * s, cos(angle / 2))
        }
        switch v {
        case 6: return q(SCNVector3(1, 0, 0), .pi)
        case 2: return q(SCNVector3(0, 1, 0), -.pi / 2)
        case 5: return q(SCNVector3(0, 1, 0), .pi / 2)
        case 3: return q(SCNVector3(1, 0, 0), .pi / 2)
        case 4: return q(SCNVector3(1, 0, 0), -.pi / 2)
        default: return SCNQuaternion(0, 0, 0, 1)
        }
    }

    /// Uniformly random orientation (Shoemake), so no spawn biases the result.
    static func randomOrientation() -> SCNQuaternion {
        let u1 = CGFloat.random(in: 0..<1), u2 = CGFloat.random(in: 0..<(2 * .pi)), u3 = CGFloat.random(in: 0..<(2 * .pi))
        let a = sqrt(1 - u1), b = sqrt(u1)
        return SCNQuaternion(a * sin(u2), a * cos(u2), b * sin(u3), b * cos(u3))
    }

    /// The face whose local axis has the largest +z component in world space.
    static func faceUp(_ m: SCNMatrix4) -> Int {
        // SceneKit matrices are row-vector: row 1 = local x axis in world, row 2 = y, row 3 = z.
        let candidates: [(CGFloat, Int)] = [(m.m13, 2), (-m.m13, 5), (m.m23, 3), (-m.m23, 4), (m.m33, 1), (-m.m33, 6)]
        return candidates.max(by: { $0.0 < $1.0 })!.1
    }

    /// Debug self-check of the face table: orientation(faceUp:) and faceUp() must agree.
    static func selfCheck() -> String {
        let n = SCNNode()
        var bad: [String] = []
        for v in 1...6 {
            n.orientation = orientation(faceUp: v)
            let got = faceUp(n.worldTransform)
            if got != v { bad.append("\(v)->\(got)") }
        }
        return bad.isEmpty ? "face table self-check OK (1..6 round-trip)" : "face table self-check FAILED: \(bad)"
    }

    private func aimLight(at p: SCNVector3) {
        // Light from upper-left and slightly in front, so the shadow falls down-right.
        lightNode.position = SCNVector3(p.x - 3, p.y + 4, 14)
        lightNode.look(at: SCNVector3(p.x, p.y, 0))
    }

    // MARK: Render-thread callbacks

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime.map { min(max(time - $0, 0), 0.05) } ?? (1.0 / 60.0)
        lastTime = time

        lock.lock()
        let commands = queue
        queue.removeAll()
        let tgt = target
        let ep = epochValue
        let cue = heldScaleTarget
        let kicks = shakeKicks
        lock.unlock()

        for c in commands { apply(c, time: time, epoch: ep) }

        switch mode {
        case .held:
            guard let body = dieNode.physicsBody else { break }
            let p = dieNode.presentation.position
            let goal = SCNVector3(tgt.x, tgt.y, Self.liftZ)
            let (v, w) = ThrowController.heldStep(position: p, target: goal,
                                                  angular: angularVector(body.angularVelocity), dt: dt)
            body.velocity = v
            if kicks != seenKicks {
                seenKicks = kicks
                shakeFrames = 24
                body.angularVelocity = axisAngle(ThrowController.randomSpin(CGFloat.random(in: 26...36)))
            } else if shakeFrames > 0 {
                shakeFrames -= 1          // keep tumbling freely while shaking
            } else {
                body.angularVelocity = axisAngle(w)
            }
            let cur = dieVisual.scale.x
            if abs(cur - cue) > 0.002 {
                let n = cur + (cue - cur) * min(1, CGFloat(dt) * 14)
                dieVisual.scale = SCNVector3(n, n, n)
            }
        case .rolling:
            if dieVisual.scale.x < 0.999 {
                let n = dieVisual.scale.x + (1 - dieVisual.scale.x) * min(1, CGFloat(dt) * 14)
                dieVisual.scale = SCNVector3(n, n, n)
            }
            // Long-roll safety: after 6 s, bleed energy so it always settles.
            if time - rollStart > 6, let body = dieNode.physicsBody {
                body.velocity = body.velocity * 0.9
                body.angularVelocity = axisAngle(angularVector(body.angularVelocity) * 0.9)
            }
        case let .returning(from, to, start, duration, style):
            let s = start ?? time
            if start == nil { mode = .returning(from: from, to: to, start: s, duration: duration, style: style) }
            let k = min(1, (time - s) / duration)
            if style == .trash {
                // Twist and crumple into the Trash.
                let kk = CGFloat(k)
                let e = kk * kk * (3 - 2 * kk)
                dieNode.position = from + (to - from) * e
                let sc = max(0.04, (1 - 0.96 * e) * heldScaleAtReturn)
                let wob = 0.18 * sin(CGFloat(time - s) * 45) * (1 - kk)
                dieVisual.scale = SCNVector3(sc * (1 + wob), sc * (1 - wob), sc)
                dieNode.simdOrientation = simd_quatf(angle: Float(22 * dt), axis: simd_float3(0, 0, 1)) * dieNode.simdOrientation
            } else if style == .shot {
                // Accelerating (ease-in), a small hop toward the viewer mid-flight, tumbling
                // forward faster and faster, and shrinking mostly at the end.
                let kk = CGFloat(k)
                let e = kk * kk
                var p = from + (to - from) * e
                p.z += 0.9 * sin(.pi * kk)
                dieNode.position = p
                let sc = 1 - 0.85 * kk * kk * kk
                dieVisual.scale = SCNVector3(sc, sc, sc)
                let omega = Float(16 + 34 * kk)              // rad/s
                dieNode.simdOrientation = simd_quatf(angle: omega * Float(dt), axis: shotAxis) * dieNode.simdOrientation
            } else {
                let e = CGFloat(k * k * (3 - 2 * k))
                dieNode.position = from + (to - from) * e
                let sc = (1 - 0.85 * e) * heldScaleAtReturn
                dieVisual.scale = SCNVector3(sc, sc, sc)
            }
            if k >= 1 {
                dieNode.isHidden = true
                blobNode?.isHidden = true
                mode = .idle
                let ep2 = ep
                DispatchQueue.main.async { [weak self] in self?.onReturned?(ep2) }
            }
        case let .scripted(script):
            let s = script.start ?? time
            if script.start == nil { script.start = s }
            let k = min(1, (time - s) / script.duration)
            script.step(dieNode, k)
            while let ev = script.events.first, ev.k <= k {
                script.events.removeFirst()
                emitSound(ev.sound, ev.volume, "\(script.name) event")
            }
            if k >= 1 {
                dieNode.physicsBody = makeBody()
                dieNode.physicsBody!.resetTransform()
                dieNode.physicsBody!.velocity = SCNVector3(0, 0, 0)
                dieNode.physicsBody!.angularVelocity = SCNVector4(0, 0, 1, 0)
                mode = .idle
                let name = script.name, ep2 = ep
                dlog("SCENE script \(name) done at \(dieNode.position.short)")
                DispatchQueue.main.async { [weak self] in self?.onScriptDone?(name, ep2) }
            }
        case .idle:
            break
        }
    }

    private func apply(_ c: Command, time: TimeInterval, epoch: Int) {
        switch c {
        case let .place(position, orientation, velocity, angular, held):
            if dieNode.physicsBody == nil { dieNode.physicsBody = makeBody() }
            dieVisual.scale = SCNVector3(1, 1, 1)
            dieNode.position = position
            if let q = orientation { dieNode.orientation = q }
            dieNode.isHidden = false
            blobNode?.isHidden = false
            dieNode.physicsBody!.resetTransform()
            dieNode.physicsBody!.velocity = velocity
            dieNode.physicsBody!.angularVelocity = angular
            mode = held ? .held : .rolling
            quiet = 0
            prevVelocity = nil
            rollStart = time
            rollEpoch = epoch
            dlog("SCENE place at \(position.short) v=\(velocity.short) |w|=\(String(format: "%.1f", angular.w)) mode=\(held ? "held" : "rolling")")
        case .hold:
            if dieNode.physicsBody == nil { dieNode.physicsBody = makeBody() }
            mode = .held
            quiet = 0
            dlog("SCENE hold from \(dieNode.presentation.position.short)")
        case let .release(velocity, angular):
            guard let body = dieNode.physicsBody else { break }
            body.velocity = velocity
            body.angularVelocity = angular
            mode = .rolling
            quiet = 0
            prevVelocity = nil
            rollStart = time
            rollEpoch = epoch
            dlog("SCENE release from \(dieNode.presentation.position.short) v=\(velocity.short) |w|=\(String(format: "%.1f", angular.w))")
        case let .returnTo(to, duration, style):
            let from = dieNode.presentation.position
            let q = dieNode.presentation.orientation
            heldScaleAtReturn = dieVisual.presentation.scale.x
            dieNode.physicsBody = nil       // no physics while it flies into the tile
            dieNode.position = from
            dieNode.orientation = q
            let d = to - from
            let axis = simd_float3(Float(-d.y), Float(d.x), 0)    // ẑ × direction: tumble toward the Dock
            shotAxis = simd_length(axis) > 1e-4 ? simd_normalize(axis) : simd_float3(1, 0, 0)
            mode = .returning(from: from, to: to, start: nil, duration: duration, style: style)
            dlog(String(format: "SCENE return (%@) from %@ to %@ over %.2f s", style.rawValue, from.short, to.short, duration))
        case .hideNow:
            dieNode.physicsBody = nil
            dieNode.isHidden = true
            blobNode?.isHidden = true
            mode = .idle
        case let .flipToSix(label):
            startScript(makeFlipToSix(), "flip onto 6 (\(label))")
        case .wobble:
            startScript(makeWobble(), "bored wobble")
        case let .shuffleHome(to):
            startScript(makeShuffle(to: to), "bored shuffle toward \(String(format: "(%.1f, %.1f)", to.x, to.y))")
        }
    }

    // MARK: Scripted animations (render thread)

    private func startScript(_ script: Script, _ label: String) {
        let p = dieNode.presentation.position
        let q = dieNode.presentation.simdOrientation
        dieNode.physicsBody = nil
        dieNode.position = p
        dieNode.simdOrientation = q
        dieVisual.scale = SCNVector3(1, 1, 1)
        dieNode.isHidden = false
        blobNode?.isHidden = false
        mode = .scripted(script)
        dlog(String(format: "SCENE script %@ (%@) from %@ over %.2f s", script.name, label, p.short, script.duration))
    }

    private static func quat(_ q: SCNQuaternion) -> simd_quatf {
        simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
    }

    /// Hop straight up, turn onto 6 (keeping a random yaw), land.
    private func makeFlipToSix() -> Script {
        let p0 = dieNode.presentation.position
        let q0 = dieNode.presentation.simdOrientation
        let yaw = simd_quatf(angle: Float.random(in: 0..<(2 * .pi)), axis: simd_float3(0, 0, 1))
        let q1 = yaw * Self.quat(Self.orientation(faceUp: 6))
        return Script("flip", duration: 0.55, events: [(k: 1.0, sound: "tokFloor", volume: 0.8)]) { node, k in
            let kk = CGFloat(k)
            node.position = SCNVector3(p0.x, p0.y, 0.5 + 1.3 * sin(.pi * kk))
            let e = Float(k * k * (3 - 2 * k))
            node.simdOrientation = simd_slerp(q0, q1, e)
        }
    }

    /// Rock a little about a random horizontal axis and settle back exactly.
    private func makeWobble() -> Script {
        let p0 = dieNode.presentation.position
        let q0 = dieNode.presentation.simdOrientation
        let a = Float.random(in: 0..<(2 * .pi))
        let axis = simd_float3(cos(a), sin(a), 0)
        return Script("wobble", duration: 0.8, events: [(k: 0.35, sound: "tokFloor", volume: 0.35), (k: 0.95, sound: "tokFloor", volume: 0.3)]) { node, k in
            let ang = Float(0.24 * sin(2 * .pi * 2.5 * k) * (1 - k))
            node.simdOrientation = k >= 1 ? q0 : simd_quatf(angle: ang, axis: axis) * q0
            node.position = SCNVector3(p0.x, p0.y, p0.z + CGFloat(0.12 * abs(Double(ang))))
        }
    }

    /// Small rolling hops (a quarter turn each) toward the target, stopping at the table edge.
    private func makeShuffle(to target: CGPoint) -> Script {
        let p0 = dieNode.presentation.position
        let q0 = dieNode.presentation.simdOrientation
        let t = clampXY(target, margin: 0.6)
        let d = CGVector(dx: t.x - p0.x, dy: t.y - p0.y)
        let dist = max(0.01, hypot(d.dx, d.dy))
        let hops = max(1, min(30, Int(ceil(dist / 1.0))))
        let step = CGVector(dx: d.dx / CGFloat(hops), dy: d.dy / CGFloat(hops))
        let axis = simd_normalize(simd_float3(Float(-d.dy), Float(d.dx), 0) + simd_float3(0, 0, 1e-6))
        let hopDur = 0.3
        let events = (1...hops).map { (k: Double($0) / Double(hops), sound: "tokFloor", volume: Float(0.5)) }
        return Script("shuffle", duration: hopDur * Double(hops), events: events) { node, k in
            let g = k * Double(hops)
            let i = min(Double(hops - 1), floor(g))
            let u = g - i
            let eu = u * u * (3 - 2 * u)
            let along = CGFloat(i + eu)
            node.position = SCNVector3(p0.x + step.dx * along, p0.y + step.dy * along,
                                       0.5 + 0.45 * CGFloat(sin(.pi * u)))
            node.simdOrientation = simd_quatf(angle: Float(.pi / 2 * (i + eu)), axis: axis) * q0
        }
    }

    private func emitSound(_ name: String, _ volume: Float, _ detail: String) {
        DispatchQueue.main.async { [weak self] in self?.onSound?(name, volume, detail) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        var p = dieNode.presentation.position

        // Safety net: never let it leave the table volume.
        if case .returning = mode {} else if !dieNode.isHidden, let body = dieNode.physicsBody {
            let c = clampXY(CGPoint(x: p.x, y: p.y), margin: 0.5)
            let zOK = p.z > 0.2 && p.z < Self.ceilingZ
            if abs(c.x - p.x) > 0.25 || abs(c.y - p.y) > 0.25 || !zOK {
                let fixed = SCNVector3(c.x, c.y, min(max(p.z, 0.6), Self.liftZ))
                dlog("SCENE out of bounds at \(p.short); put back at \(fixed.short)")
                dieNode.position = fixed
                body.resetTransform()
                body.velocity = SCNVector3(0, 0, 0)
                p = fixed
            }
        }

        lock.lock(); published = p; lock.unlock()
        let dt = lastSimTime.map { min(max(time - $0, 0), 0.05) } ?? (1.0 / 60.0)
        lastSimTime = time

        if !dieNode.isHidden {
            if let blob = blobNode {
                let hgt = max(0, p.z - 0.5)
                let s = 1 + 0.45 * hgt
                blob.scale = SCNVector3(s, s, 1)
                blob.position = SCNVector3(p.x + 0.1 + 0.12 * hgt, p.y - 0.12 - 0.15 * hgt, 0.002)
                blob.opacity = max(0.25, 0.85 - 0.3 * hgt)
            } else {
                aimLight(at: p)
            }
        }

        guard case .rolling = mode, let body = dieNode.physicsBody else { return }
        if time - lastPosLog > 0.25 {
            lastPosLog = time
            dlog(String(format: "SCENE rolling t=%.2f pos=%@ |v|=%.2f |w|=%.2f",
                        time - rollStart, p.short, body.velocity.length, abs(body.angularVelocity.w)))
        }
        // Hit strength from the change in velocity beyond what gravity explains (SceneKit's
        // contact impulse reads 0). Thresholded and rate-limited so settling does not buzz.
        let vel = body.velocity
        if let pv = prevVelocity {
            let expected = SCNVector3(pv.x, pv.y, pv.z - Self.gravity * CGFloat(dt))
            let dv = (vel - expected).length
            let now = ProcessInfo.processInfo.systemUptime
            if dv > 2.0, now - lastHitTime > 0.045, !(vel.length < 0.6 && dv < 3.5) {
                lastHitTime = now
                let wall = now - lastWallContact < 0.06
                // Small dynamic range: a hard hit is only a little louder than a gentle one.
                let strength = Float(min(1, max(0, (dv - 2.0) / 18.0)))
                let vol = 0.55 + 0.45 * strength.squareRoot()
                emitSound(wall ? "tokWall" : "tokFloor", vol, String(format: "%@ hit dv=%.1f", wall ? "wall" : "floor", dv))
            }
        }
        prevVelocity = vel
        let v = body.velocity.length
        let w = abs(body.angularVelocity.w)
        if body.isResting || (v < Self.restLinear && w < Self.restAngular && p.z < 0.75) {
            quiet += dt
        } else {
            quiet = 0
        }
        if quiet >= Self.restHold || body.isResting {
            let face = Self.faceUp(dieNode.presentation.worldTransform)
            let secs = time - rollStart
            let ep = rollEpoch
            mode = .idle
            body.velocity = SCNVector3(0, 0, 0)
            body.angularVelocity = SCNVector4(0, 0, 1, 0)
            dlog(String(format: "SCENE settled: face %d up after %.2f s at %@ (resting=%@)",
                        face, secs, p.short, body.isResting ? "yes" : "no"))
            DispatchQueue.main.async { [weak self] in self?.onSettled?(face, secs, ep) }
        }
    }

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        let other = contact.nodeA === dieNode ? contact.nodeB : contact.nodeA
        guard let name = other.name else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A held die pressed against the edge is not a bounce: no log, no sound.
        guard case .rolling = mode else { return }
        lastWallContact = now
        if now - (lastBounce[name] ?? 0) > 0.15 {
            lastBounce[name] = now
            dlog(String(format: "SCENE bounce off %@ (impulse %.1f) at %@", name, contact.collisionImpulse,
                        dieNode.presentation.position.short))
        }
    }
}
