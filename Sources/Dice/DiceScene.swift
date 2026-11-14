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
/// one unit = one die edge. The table holds `DiceScene.maxDice` dice; single-die mode uses die 0
/// only (the others stay hidden with no physics body). Everything that touches physics runs on
/// SceneKit's render thread inside the SCNSceneRendererDelegate callbacks; the main thread talks
/// to it through `lock`. Walls, floor, lights and camera are shared.
final class DiceScene: NSObject, SCNSceneRendererDelegate, SCNPhysicsContactDelegate {
    static let maxDice = 5

    enum Command {
        case place(position: SCNVector3, orientation: SCNQuaternion?, velocity: SCNVector3, angular: SCNVector4, held: Bool)
        case hold
        case release(velocity: SCNVector3, angular: SCNVector4)
        case returnTo(SCNVector3, duration: TimeInterval, style: ReturnStyle)
        case hideNow
        /// Kinematic animations (physics body removed while they run, restored after unless parked).
        case flipTo(face: Int, label: String)  // loaded die / demo forcing: hop and flip onto a face
        case wobble                            // bored die fidgets in place
        case shuffleHome(to: CGPoint)          // bored die (or busted hand) hops toward the Dock
        /// Glide to a spot, face-up `face` with no yaw if given, at visual `scale`. `park: true`
        /// leaves it without a physics body (a kept die in the row); otherwise it rests on the table.
        case slide(to: SCNVector3, face: Int?, scale: CGFloat, duration: TimeInterval, park: Bool, name: String)
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
        var park = false
        init(_ name: String, duration: TimeInterval, events: [(k: Double, sound: String, volume: Float)] = [],
             step: @escaping (SCNNode, Double) -> Void) {
            self.name = name; self.duration = duration; self.events = events; self.step = step
        }
    }

    enum Mode {
        case idle      // at rest on the table (or hidden)
        case held
        case rolling
        case returning(from: SCNVector3, to: SCNVector3, start: TimeInterval?, duration: TimeInterval, style: ReturnStyle)
        case scripted(Script)
        case parked    // kept in the row: visible, no physics body
    }

    /// One die: its nodes, materials, and its own motion and rest tracking.
    final class Die {
        let index: Int
        let node = SCNNode()          // carries the physics body; never scaled
        let visual = SCNNode()        // carries the geometry; scaled for cues and animations
        var blob: SCNNode?
        var materials: [SCNMaterial] = []
        // Main thread: the look this die wears now, and whether the scoring glow is on.
        var look = DiePalette.classic
        var glowOn = false
        // Floor under the die (written on main, read on the render thread under the lock):
        // shadow offset factor (1 follows the key light, 0 centred) and opacity factor.
        var blobShift: CGFloat = 1
        var blobStrength: CGFloat = 1
        // Render-thread state
        var mode = Mode.idle
        var quiet: TimeInterval = 0
        var rollStart: TimeInterval = 0
        var lastPosLog: TimeInterval = 0
        var rollEpoch = 0
        var heldScaleAtReturn: CGFloat = 1
        var shotAxis = simd_float3(1, 0, 0)
        var seenKicks = 0
        var shakeFrames = 0
        var prevVelocity: SCNVector3?
        var lastHitTime: TimeInterval = 0
        var lastWallContact: TimeInterval = 0
        var lastDieContact: TimeInterval = 0
        var lastBounce: [String: TimeInterval] = [:]
        let jostlePhase = Double.random(in: 0..<(2 * .pi))
        // Shared with the main thread (guarded by the scene's lock)
        var queue: [Command] = []
        var epoch = 0
        var published = SCNVector3(0, 0, 0.5)
        var offset = CGPoint.zero
        init(index: Int) { self.index = index }
    }

    // Tuning
    static let gravity: CGFloat = 40
    static let liftZ: CGFloat = 1.7          // die centre while held (bottom face ~1.2 above the table)
    static let ceilingZ: CGFloat = 3.2
    static let heldSeparation: CGFloat = 1.3   // held dice closer than this are pushed apart
    static let heldPushGain: CGFloat = 24      // units/s of push per unit of overlap
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
    let dice: [Die]
    /// Die 0's node (single-die mode).
    var dieNode: SCNNode { dice[0].node }
    private let lightNode = SCNNode()
    private var nodeIndex: [ObjectIdentifier: Int] = [:]
    let halfW: CGFloat
    let halfH: CGFloat
    let cameraHeight: CGFloat
    let useBlobShadow: Bool

    // Shared with the main thread.
    private let lock = NSLock()
    private var target = CGPoint.zero
    private var heldScaleTarget: CGFloat = 1
    private var shakeKicks = 0
    private var wakeChecksValue = false

    // Render-thread state shared by all dice.
    private var lastTime: TimeInterval?
    private var lastSimTime: TimeInterval?
    private var lastAnyHit: TimeInterval = 0
    private var lastOverlapLog: [Int: TimeInterval] = [:]
    /// Face maps for one look: the diffuse textures, and the emission maps if the look has them.
    /// Material order +z, +x, -z, -x, +y, -y.
    struct FaceMaps {
        let diffuse: [CGImage]
        let emission: [CGImage]?
    }
    private var textureCache: [String: FaceMaps] = [:]
    /// Emission maps with the scoring glow as background, for looks that have emission maps.
    private var washCache: [String: [CGImage]] = [:]
    private var floorCache: [String: CGImage] = [:]
    private(set) var palette = DiePalette.classic
    /// Pip style for all dice: plain for the single die, constellation for Hot Hand.
    private(set) var pipStyle = PipStyle.plain
    /// Hot Hand's special die: always gold, its 1 face is the wild ring. nil outside the game.
    private(set) var specialDie: Int?

    /// Main-thread callbacks. `index` is the die.
    var onSettled: ((_ index: Int, _ face: Int, _ seconds: TimeInterval, _ epoch: Int) -> Void)?
    var onReturned: ((_ index: Int, _ epoch: Int) -> Void)?
    /// A scripted animation finished (name: "flip", "wobble", "shuffle", or a slide's name).
    var onScriptDone: ((_ index: Int, _ name: String, _ epoch: Int) -> Void)?
    /// A settled die was knocked moving again (only reported while wake checks are on).
    var onWoke: ((_ index: Int) -> Void)?
    /// A collision worth a sound, or a script sound event.
    var onSound: ((_ name: String, _ volume: Float, _ detail: String) -> Void)?

    init(halfWidth: CGFloat, halfHeight: CGFloat, blobShadow: Bool) {
        halfW = halfWidth
        halfH = halfHeight
        useBlobShadow = blobShadow
        let halfFov = Self.fieldOfView / 2 * .pi / 180
        cameraHeight = halfHeight / tan(halfFov)
        dice = (0..<Self.maxDice).map { Die(index: $0) }
        super.init()
        build()
    }

    // MARK: Main-thread API

    /// Die 0's epoch (single-die mode).
    var epoch: Int { epoch(of: 0) }

    func epoch(of i: Int) -> Int { lock.lock(); defer { lock.unlock() }; return dice[i].epoch }

    @discardableResult
    func send(_ c: Command, to i: Int = 0) -> Int {
        lock.lock(); defer { lock.unlock() }
        dice[i].queue.append(c)
        dice[i].epoch += 1
        return dice[i].epoch
    }

    /// The cursor target for held dice (each held die adds its own offset).
    func setTarget(_ p: CGPoint) {
        lock.lock(); target = p; lock.unlock()
    }

    func setOffset(_ p: CGPoint, for i: Int) {
        lock.lock(); dice[i].offset = p; lock.unlock()
    }

    /// A shake reversal while held: every held die tumbles energetically for a moment.
    func shakeKick() {
        lock.lock(); shakeKicks += 1; lock.unlock()
    }

    /// Report settled dice that get knocked moving again (game mode: dice hit each other).
    var wakeChecks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return wakeChecksValue }
        set { lock.lock(); wakeChecksValue = newValue; lock.unlock() }
    }

    /// Visual cue while held: < 1 when letting go would put the dice away.
    func setHeldScale(_ s: CGFloat) {
        lock.lock(); heldScaleTarget = s; lock.unlock()
    }

    /// Die 0's position (single-die mode).
    var publishedPosition: SCNVector3 { position(of: 0) }

    func position(of i: Int) -> SCNVector3 {
        lock.lock(); defer { lock.unlock() }
        return dice[i].published
    }

    func clampXY(_ p: CGPoint, margin: CGFloat = 0.6) -> CGPoint {
        CGPoint(x: min(max(p.x, -halfW + margin), halfW - margin),
                y: min(max(p.y, -halfH + margin), halfH - margin))
    }

    /// The face up right now, read from the presentation transform.
    func faceUpNow(_ i: Int) -> Int { Self.faceUp(dice[i].node.presentation.worldTransform) }

    // MARK: Looks (main thread; SceneKit property changes are safe here inside a transaction)

    private static let faceOrder = [1, 2, 6, 5, 3, 4]

    private func textures(for p: DiePalette, wild: Bool = false) -> FaceMaps {
        let key = "\(p.name)-\(pipStyle.rawValue)\(wild ? "-wild" : "")"
        if let t = textureCache[key] { return t }
        let style = pipStyle
        let t = FaceMaps(diffuse: Self.faceOrder.map { DieArt.texture(value: $0, px: 512, palette: p, style: style, wild: wild) },
                         emission: p.emissive ? Self.faceOrder.compactMap { DieArt.emissionTexture(value: $0, px: 512, palette: p, style: style) } : nil)
        textureCache[key] = t
        return t
    }

    private func washed(for p: DiePalette) -> [CGImage] {
        let key = "\(p.name)-\(pipStyle.rawValue)"
        if let t = washCache[key] { return t }
        let c = DieArt.scoreGlow.components ?? [1, 1, 1, 1], k = DieArt.scoreGlowIntensity
        let wash = CGColor(colorSpace: DieArt.sRGB, components: [c[0] * k, c[1] * k, c[2] * k, 1])!
        let style = pipStyle
        let t = Self.faceOrder.compactMap { DieArt.emissionTexture(value: $0, px: 512, palette: p, style: style, wash: wash) }
        washCache[key] = t
        return t
    }

    private func floorImage(for p: DiePalette) -> CGImage {
        let key = p.floor.halo == nil ? "shadow" : p.name
        if let t = floorCache[key] { return t }
        let t = DieArt.floorImage(p)
        floorCache[key] = t
        return t
    }

    /// Build the Hot Hand textures ahead of time (launch, style change), so starting a game
    /// inside the event tap does not draw them there. `table` is the chosen style's look.
    func warmTextures(table: DiePalette = .classic) {
        let saved = pipStyle
        pipStyle = .constellation
        for p in [DiePalette.classic, .friday13, table] {
            _ = textures(for: p)
            if p.emissive { _ = washed(for: p) }
        }
        _ = textures(for: .gold, wild: true)
        pipStyle = saved
        _ = textures(for: table)
        _ = floorImage(for: table)
    }

    /// Make one die the special (gold, wild) die, or none. Re-skins everything.
    func setSpecialDie(_ i: Int?) {
        guard i != specialDie else { return }
        specialDie = i
        applySkin(palette)
        dlog("SCENE special die -> \(i.map(String.init) ?? "none")")
    }

    /// Switch every die between plain and constellation pips (keeps the palette).
    func setPipStyle(_ style: PipStyle) {
        guard style != pipStyle else { return }
        pipStyle = style
        applySkin(palette)
        dlog("SCENE pip style -> \(style.rawValue)")
    }

    /// Dress every die in a look: textures, emission, material finish, corner radius and the
    /// floor (shadow or halo). The special die stays gold whatever the table look.
    func applySkin(_ p: DiePalette) {
        palette = p
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for die in dice {
            // The special die is gold whatever the table palette (never black or red).
            let special = die.index == specialDie
            let dp = special ? DiePalette.gold : p
            die.look = dp
            let maps = textures(for: dp, wild: special)
            let f = dp.finish
            for (i, m) in die.materials.enumerated() {
                m.diffuse.contents = maps.diffuse[i]
                m.lightingModel = f.lighting == .lambert ? .lambert : .blinn
                m.specular.contents = NSColor(cgColor: f.specular)
                m.shininess = f.shininess
                switch f.reflection {
                case .none:
                    m.reflective.contents = nil
                case .gold:
                    m.reflective.contents = DieArt.goldReflection()
                    m.reflective.intensity = 0.55
                    m.fresnelExponent = 1.2
                case let .rim(color, exponent, intensity):
                    // Uniform "environment" weighted by fresnel: shows only at grazing angles,
                    // i.e. on the chamfers and the side faces as the die tumbles.
                    m.reflective.contents = NSColor(cgColor: color)
                    m.reflective.intensity = intensity
                    m.fresnelExponent = exponent
                }
            }
            applyEmission(die)
            if let box = die.visual.geometry as? SCNBox, box.chamferRadius != dp.chamfer { box.chamferRadius = dp.chamfer }
            if let blob = die.blob, let plane = blob.geometry as? SCNPlane {
                plane.width = dp.floor.size
                plane.height = dp.floor.size
                plane.firstMaterial?.diffuse.contents = floorImage(for: dp)
                lock.lock()
                die.blobShift = dp.floor.follows ? 1 : 0
                die.blobStrength = dp.floor.halo == nil ? dp.floor.shadow : 1
                lock.unlock()
            }
        }
        SCNTransaction.commit()
        dlog("SCENE skin -> \(p.name) (\(pipStyle.rawValue) pips, chamfer \(p.chamfer), \(p.emissive ? "emission map" : "no emission")\(p.floor.halo != nil ? ", halo" : "")\(specialDie.map { ", die \($0) gold+wild" } ?? ""))")
    }

    /// The emission slot: the look's emission map (or nothing), or the scoring glow on top.
    /// Looks with an emission map get the glow as a washed map, since the slot holds one thing.
    private func applyEmission(_ die: Die) {
        let special = die.index == specialDie
        let maps = textures(for: die.look, wild: special)
        let wash = die.glowOn && maps.emission != nil ? washed(for: die.look) : nil
        for (i, m) in die.materials.enumerated() {
            if let w = wash {
                m.emission.contents = w[i]
                m.emission.intensity = 1
            } else if let e = maps.emission {
                m.emission.contents = e[i]
                m.emission.intensity = 1
            } else if die.glowOn {
                m.emission.contents = NSColor(cgColor: DieArt.scoreGlow)
                m.emission.intensity = DieArt.scoreGlowIntensity
            } else {
                m.emission.contents = NSColor.black
                m.emission.intensity = 0
            }
        }
    }

    /// The loaded die's wink: die 0's 6 face (material index 2) loses its pips for a moment
    /// (and their light, for looks that give off light; a rim stays).
    func setWink(_ closed: Bool) {
        let die = dice[0]
        let m = die.materials[2]
        let p = die.look
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        if closed {
            m.diffuse.contents = DieArt.texture(value: 6, px: 512, palette: p, pips: false, style: pipStyle)
            if p.emissive { m.emission.contents = DieArt.emissionTexture(value: 6, px: 512, palette: p, pips: false, style: pipStyle) }
        } else {
            let maps = textures(for: p)
            m.diffuse.contents = maps.diffuse[2]
            if let e = maps.emission { m.emission.contents = e[2] }
        }
        SCNTransaction.commit()
    }

    /// A soft warm glow (scoring dice), animated (looks with an emission map switch maps instead).
    func setGlow(_ on: Bool, for i: Int) {
        let die = dice[i]
        guard die.glowOn != on else { return }
        die.glowOn = on
        SCNTransaction.begin()
        SCNTransaction.animationDuration = on ? 0.18 : 0.45
        applyEmission(die)
        SCNTransaction.commit()
    }

    /// Dim a die a little (bust slump): 1 = normal, smaller = darker. Animated.
    func setDim(_ level: CGFloat, for i: Int) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        for m in dice[i].materials { m.multiply.contents = NSColor(white: level, alpha: 1) }
        // A halo is light from the die, so it slumps with it (a shadow is unaffected in practice).
        if dice[i].look.floor.halo != nil || level == 1 {
            dice[i].blob?.geometry?.firstMaterial?.multiply.contents = NSColor(white: level, alpha: 1)
        }
        SCNTransaction.commit()
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

        // Lights: ambient fill, shadow-casting key that follows die 0 (tight shadow frustum),
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

        // Dice: chamfered boxes, six DieArt textures each. SCNBox material order (verified
        // empirically): +z, +x, -z, -x, +y, -y. Values: +z=1 -z=6, +x=2 -x=5, +y=3 -y=4.
        // Each die has its own geometry and materials (so one can glow or dim alone).
        for die in dice {
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
            die.materials = box.materials
            // Geometry lives on a child node. Only the child is ever scaled (drop-zone cue,
            // return animations): scaling a node that carries a dynamic physics body makes
            // SceneKit push the node's stale model transform into the body (a teleport).
            die.visual.geometry = box
            die.visual.castsShadow = true
            die.node.addChildNode(die.visual)
            die.node.name = "die \(die.index)"
            die.node.isHidden = true
            die.node.position = SCNVector3(0, 0, 0.5)
            scene.rootNode.addChildNode(die.node)
            nodeIndex[ObjectIdentifier(die.node)] = die.index
            // Only die 0 has a body at start; game dice get theirs when placed.
            if die.index == 0 { die.node.physicsBody = makeBody() }
            if useBlobShadow {
                let blob = SCNNode()
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
                die.blob = blob
            }
        }

        // Floor: a static slab whose top is z = 0, plus a visual plane that only shows the shadow.
        let floorShape = SCNBox(width: halfW * 2 + 8, height: halfH * 2 + 8, length: 4, chamferRadius: 0)
        let floorBody = SCNNode()
        floorBody.position = SCNVector3(0, 0, -2)
        floorBody.physicsBody = staticBody(SCNPhysicsShape(geometry: floorShape, options: nil),
                                           restitution: 0.6, friction: 0.8, category: Self.catFloor)
        scene.rootNode.addChildNode(floorBody)

        if !useBlobShadow {
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
        b.collisionBitMask = Self.catWall | Self.catFloor | Self.catDie
        b.contactTestBitMask = Self.catWall | Self.catDie
        b.allowsResting = true
        return b
    }

    /// Body for a kept die sitting in the row: static, die-sized (at its kept scale), and in
    /// the die category, so thrown dice knock against it and it counts as a die-on-die hit.
    private func parkedBody(scale: CGFloat) -> SCNPhysicsBody {
        let s = max(0.5, scale)
        let shape = SCNPhysicsShape(geometry: SCNBox(width: s, height: s, length: s, chamferRadius: 0), options: nil)
        let b = SCNPhysicsBody(type: .static, shape: shape)
        b.restitution = Self.restitution
        b.friction = Self.friction
        b.categoryBitMask = Self.catDie
        b.collisionBitMask = Self.catDie
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
        let work: [(Die, [Command], Int, CGPoint)] = dice.map { d in
            let c = d.queue
            d.queue.removeAll()
            return (d, c, d.epoch, d.offset)
        }
        let tgt = target
        let cue = heldScaleTarget
        let kicks = shakeKicks
        lock.unlock()

        for (die, commands, ep, offset) in work {
            for c in commands { apply(c, to: die, time: time, epoch: ep) }
            update(die, time: time, dt: dt, epoch: ep, target: tgt, offset: offset, cue: cue, kicks: kicks)
        }
    }

    private func update(_ die: Die, time: TimeInterval, dt: TimeInterval, epoch ep: Int,
                        target tgt: CGPoint, offset: CGPoint, cue: CGFloat, kicks: Int) {
        let node = die.node, visual = die.visual
        switch die.mode {
        case .held:
            guard let body = node.physicsBody else { break }
            let p = node.presentation.position
            // Each die in a handful sits on its own offset, wandering a little so they jostle.
            var jx: CGFloat = 0, jy: CGFloat = 0
            if offset != .zero {
                jx = 0.18 * CGFloat(sin(time * 3.3 + die.jostlePhase))
                jy = 0.18 * CGFloat(cos(time * 2.7 + die.jostlePhase * 1.7))
            }
            let goal = SCNVector3(tgt.x + offset.x + jx, tgt.y + offset.y + jy, Self.liftZ)
            let (v, w) = ThrowController.heldStep(position: p, target: goal,
                                                  angular: angularVector(body.angularVelocity), dt: dt)
            // The follow sets velocity outright, which cancels the solver's own separation, so
            // a handful would sink into itself. Push held neighbours apart here instead.
            var push = SCNVector3(0, 0, 0)
            for other in dice where other.index != die.index && !other.node.isHidden {
                guard case .held = other.mode else { continue }
                let d = p - other.node.presentation.position
                let len = d.length
                if len < Self.heldSeparation, len > 0.001 {
                    push = push + d * ((Self.heldSeparation - len) / len * Self.heldPushGain)
                }
            }
            body.velocity = SCNVector3(v.x + push.x, v.y + push.y, v.z)
            if kicks != die.seenKicks {
                die.seenKicks = kicks
                die.shakeFrames = 24
                body.angularVelocity = axisAngle(ThrowController.randomSpin(CGFloat.random(in: 26...36)))
            } else if die.shakeFrames > 0 {
                die.shakeFrames -= 1          // keep tumbling freely while shaking
            } else {
                body.angularVelocity = axisAngle(w)
            }
            let cur = visual.scale.x
            if abs(cur - cue) > 0.002 {
                let n = cur + (cue - cur) * min(1, CGFloat(dt) * 14)
                visual.scale = SCNVector3(n, n, n)
            }
        case .rolling:
            if visual.scale.x < 0.999 {
                let n = visual.scale.x + (1 - visual.scale.x) * min(1, CGFloat(dt) * 14)
                visual.scale = SCNVector3(n, n, n)
            }
            // Long-roll safety: after 6 s, bleed energy so it always settles.
            if time - die.rollStart > 6, let body = node.physicsBody {
                body.velocity = body.velocity * 0.9
                body.angularVelocity = axisAngle(angularVector(body.angularVelocity) * 0.9)
            }
        case let .returning(from, to, start, duration, style):
            let s = start ?? time
            if start == nil { die.mode = .returning(from: from, to: to, start: s, duration: duration, style: style) }
            let k = min(1, (time - s) / duration)
            if style == .trash {
                // Twist and crumple into the Trash.
                let kk = CGFloat(k)
                let e = kk * kk * (3 - 2 * kk)
                node.position = from + (to - from) * e
                let sc = max(0.04, (1 - 0.96 * e) * die.heldScaleAtReturn)
                let wob = 0.18 * sin(CGFloat(time - s) * 45) * (1 - kk)
                visual.scale = SCNVector3(sc * (1 + wob), sc * (1 - wob), sc)
                node.simdOrientation = simd_quatf(angle: Float(22 * dt), axis: simd_float3(0, 0, 1)) * node.simdOrientation
            } else if style == .shot {
                // Accelerating (ease-in), a small hop toward the viewer mid-flight, tumbling
                // forward faster and faster, and shrinking mostly at the end.
                let kk = CGFloat(k)
                let e = kk * kk
                var p = from + (to - from) * e
                p.z += 0.9 * sin(.pi * kk)
                node.position = p
                let sc = (1 - 0.85 * kk * kk * kk) * die.heldScaleAtReturn
                visual.scale = SCNVector3(sc, sc, sc)
                let omega = Float(16 + 34 * kk)              // rad/s
                node.simdOrientation = simd_quatf(angle: omega * Float(dt), axis: die.shotAxis) * node.simdOrientation
            } else {
                let e = CGFloat(k * k * (3 - 2 * k))
                node.position = from + (to - from) * e
                let sc = (1 - 0.85 * e) * die.heldScaleAtReturn
                visual.scale = SCNVector3(sc, sc, sc)
            }
            if k >= 1 {
                node.isHidden = true
                die.blob?.isHidden = true
                die.mode = .idle
                let i = die.index
                DispatchQueue.main.async { [weak self] in self?.onReturned?(i, ep) }
            }
        case let .scripted(script):
            let s = script.start ?? time
            if script.start == nil { script.start = s }
            let k = min(1, (time - s) / script.duration)
            script.step(node, k)
            while let ev = script.events.first, ev.k <= k {
                script.events.removeFirst()
                emitSound(ev.sound, ev.volume, "\(script.name) event (die \(die.index))")
            }
            if k >= 1 {
                if script.park {
                    // A kept die is a solid, immovable obstacle: live dice bounce off the row.
                    node.physicsBody = parkedBody(scale: die.visual.scale.x)
                    node.physicsBody!.resetTransform()
                    die.mode = .parked
                } else {
                    node.physicsBody = makeBody()
                    node.physicsBody!.resetTransform()
                    node.physicsBody!.velocity = SCNVector3(0, 0, 0)
                    node.physicsBody!.angularVelocity = SCNVector4(0, 0, 1, 0)
                    die.mode = .idle
                }
                let name = script.name, i = die.index
                dlog("SCENE die \(i) script \(name) done at \(node.position.short)\(script.park ? " (parked)" : "")")
                DispatchQueue.main.async { [weak self] in self?.onScriptDone?(i, name, ep) }
            }
        case .idle, .parked:
            break
        }
    }

    private func apply(_ c: Command, to die: Die, time: TimeInterval, epoch: Int) {
        let node = die.node
        switch c {
        case let .place(position, orientation, velocity, angular, held):
            // A parked die carries a static body; anything not dynamic is replaced.
            if node.physicsBody?.type != .dynamic { node.physicsBody = makeBody() }
            die.visual.scale = SCNVector3(1, 1, 1)
            node.position = position
            if let q = orientation { node.orientation = q }
            node.isHidden = false
            die.blob?.isHidden = false
            node.physicsBody!.resetTransform()
            node.physicsBody!.velocity = velocity
            node.physicsBody!.angularVelocity = angular
            die.mode = held ? .held : .rolling
            die.quiet = 0
            die.prevVelocity = nil
            die.rollStart = time
            die.rollEpoch = epoch
            dlog("SCENE die \(die.index) place at \(position.short) v=\(velocity.short) |w|=\(String(format: "%.1f", angular.w)) mode=\(held ? "held" : "rolling")")
        case .hold:
            if node.physicsBody?.type != .dynamic {
                let p = node.presentation.position
                node.position = p
                node.physicsBody = makeBody()
                node.physicsBody!.resetTransform()
            }
            die.mode = .held
            die.quiet = 0
            dlog("SCENE die \(die.index) hold from \(node.presentation.position.short)")
        case let .release(velocity, angular):
            guard let body = node.physicsBody else { break }
            body.velocity = velocity
            body.angularVelocity = angular
            die.mode = .rolling
            die.quiet = 0
            die.prevVelocity = nil
            die.rollStart = time
            die.rollEpoch = epoch
            dlog("SCENE die \(die.index) release from \(node.presentation.position.short) v=\(velocity.short) |w|=\(String(format: "%.1f", angular.w))")
        case let .returnTo(to, duration, style):
            let from = node.presentation.position
            let q = node.presentation.orientation
            die.heldScaleAtReturn = die.visual.presentation.scale.x
            node.physicsBody = nil       // no physics while it flies into the tile
            node.position = from
            node.orientation = q
            let d = to - from
            let axis = simd_float3(Float(-d.y), Float(d.x), 0)    // ẑ × direction: tumble toward the Dock
            die.shotAxis = simd_length(axis) > 1e-4 ? simd_normalize(axis) : simd_float3(1, 0, 0)
            die.mode = .returning(from: from, to: to, start: nil, duration: duration, style: style)
            dlog(String(format: "SCENE die %d return (%@) from %@ to %@ over %.2f s", die.index, style.rawValue, from.short, to.short, duration))
        case .hideNow:
            node.physicsBody = nil
            node.isHidden = true
            die.blob?.isHidden = true
            die.visual.scale = SCNVector3(1, 1, 1)
            die.mode = .idle
        case let .flipTo(face, label):
            startScript(makeFlip(die, to: face), on: die, "flip onto \(face) (\(label))")
        case .wobble:
            startScript(makeWobble(die), on: die, "bored wobble")
        case let .shuffleHome(to):
            startScript(makeShuffle(die, to: to), on: die, "shuffle toward \(String(format: "(%.1f, %.1f)", to.x, to.y))")
        case let .slide(to, face, scale, duration, park, name):
            let s = makeSlide(die, to: to, face: face, scale: scale, duration: duration, name: name)
            s.park = park
            startScript(s, on: die, "slide to \(to.short)\(park ? ", park" : "")", keepScale: true)
        }
    }

    // MARK: Scripted animations (render thread)

    private func startScript(_ script: Script, on die: Die, _ label: String, keepScale: Bool = false) {
        let node = die.node
        let p = node.presentation.position
        let q = node.presentation.simdOrientation
        node.physicsBody = nil
        node.position = p
        node.simdOrientation = q
        if !keepScale { die.visual.scale = SCNVector3(1, 1, 1) }
        node.isHidden = false
        die.blob?.isHidden = false
        die.mode = .scripted(script)
        dlog(String(format: "SCENE die %d script %@ (%@) from %@ over %.2f s", die.index, script.name, label, p.short, script.duration))
    }

    private static func quat(_ q: SCNQuaternion) -> simd_quatf {
        simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
    }

    /// Hop straight up, turn onto `face` (keeping a random yaw), land.
    private func makeFlip(_ die: Die, to face: Int) -> Script {
        let p0 = die.node.presentation.position
        let q0 = die.node.presentation.simdOrientation
        let yaw = simd_quatf(angle: Float.random(in: 0..<(2 * .pi)), axis: simd_float3(0, 0, 1))
        let q1 = yaw * Self.quat(Self.orientation(faceUp: face))
        return Script("flip", duration: 0.55, events: [(k: 1.0, sound: "tokFloor", volume: 0.8)]) { node, k in
            let kk = CGFloat(k)
            node.position = SCNVector3(p0.x, p0.y, 0.5 + 1.3 * sin(.pi * kk))
            let e = Float(k * k * (3 - 2 * k))
            node.simdOrientation = simd_slerp(q0, q1, e)
        }
    }

    /// Rock a little about a random horizontal axis and settle back exactly.
    private func makeWobble(_ die: Die) -> Script {
        let p0 = die.node.presentation.position
        let q0 = die.node.presentation.simdOrientation
        let a = Float.random(in: 0..<(2 * .pi))
        let axis = simd_float3(cos(a), sin(a), 0)
        return Script("wobble", duration: 0.8, events: [(k: 0.35, sound: "tokFloor", volume: 0.35), (k: 0.95, sound: "tokFloor", volume: 0.3)]) { node, k in
            let ang = Float(0.24 * sin(2 * .pi * 2.5 * k) * (1 - k))
            node.simdOrientation = k >= 1 ? q0 : simd_quatf(angle: ang, axis: axis) * q0
            node.position = SCNVector3(p0.x, p0.y, p0.z + CGFloat(0.12 * abs(Double(ang))))
        }
    }

    /// Small rolling hops (a quarter turn each) toward the target, stopping at the table edge.
    private func makeShuffle(_ die: Die, to target: CGPoint) -> Script {
        let p0 = die.node.presentation.position
        let q0 = die.node.presentation.simdOrientation
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

    /// Glide (with a small lift) to a spot, turning square to the viewer if a face is given.
    private func makeSlide(_ die: Die, to: SCNVector3, face: Int?, scale: CGFloat, duration: TimeInterval, name: String) -> Script {
        let p0 = die.node.presentation.position
        let q0 = die.node.presentation.simdOrientation
        let q1 = face.map { Self.quat(Self.orientation(faceUp: $0)) } ?? q0
        let s0 = die.visual.presentation.scale.x
        let visual = die.visual
        return Script(name, duration: duration) { node, k in
            let e = CGFloat(k * k * (3 - 2 * k))
            var p = p0 + (to - p0) * e
            p.z += 0.5 * sin(.pi * CGFloat(k))
            node.position = p
            node.simdOrientation = simd_slerp(q0, q1, Float(e))
            let sc = s0 + (scale - s0) * e
            visual.scale = SCNVector3(sc, sc, sc)
        }
    }

    private func emitSound(_ name: String, _ volume: Float, _ detail: String) {
        DispatchQueue.main.async { [weak self] in self?.onSound?(name, volume, detail) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        let dt = lastSimTime.map { min(max(time - $0, 0), 0.05) } ?? (1.0 / 60.0)
        lastSimTime = time
        lock.lock()
        let wakes = wakeChecksValue
        lock.unlock()
        var lightSet = false
        for die in dice {
            simulate(die, time: time, dt: dt, wakes: wakes)
            if !lightSet, !useBlobShadow, !die.node.isHidden {
                aimLight(at: die.node.presentation.position)
                lightSet = true
            }
        }
        if isDebug { logOverlaps(time) }
    }

    /// Debug only: report dice whose bodies are interpenetrating, so a real pass-through
    /// shows up in the log.
    private func logOverlaps(_ time: TimeInterval) {
        for a in dice where a.node.physicsBody != nil && !a.node.isHidden {
            for b in dice where b.index > a.index && b.node.physicsBody != nil && !b.node.isHidden {
                let d = (a.node.presentation.position - b.node.presentation.position).length
                // Each cube contains a ball of half its size, so centres closer than the mean
                // size mean the cubes intersect. 0.94 leaves room for solver slop.
                let limit = 0.94 * (a.visual.scale.x + b.visual.scale.x) / 2
                let key = a.index * 16 + b.index
                if d < limit, time - (lastOverlapLog[key] ?? 0) > 0.25 {
                    lastOverlapLog[key] = time
                    var held = false
                    if case .held = a.mode, case .held = b.mode { held = true }
                    dlog(String(format: "SCENE OVERLAP die %d / die %d centres %.2f apart (limit %.2f)%@", a.index, b.index, d, limit,
                                held ? " in the held handful" : ""))
                }
            }
        }
    }

    private func simulate(_ die: Die, time: TimeInterval, dt: TimeInterval, wakes: Bool) {
        let node = die.node
        var p = node.presentation.position

        // Safety net: never let it leave the table volume.
        if case .returning = die.mode {} else if !node.isHidden, let body = node.physicsBody {
            let c = clampXY(CGPoint(x: p.x, y: p.y), margin: 0.5)
            let zOK = p.z > 0.2 && p.z < Self.ceilingZ
            if abs(c.x - p.x) > 0.25 || abs(c.y - p.y) > 0.25 || !zOK {
                let fixed = SCNVector3(c.x, c.y, min(max(p.z, 0.6), Self.liftZ))
                dlog("SCENE die \(die.index) out of bounds at \(p.short); put back at \(fixed.short)")
                node.position = fixed
                body.resetTransform()
                body.velocity = SCNVector3(0, 0, 0)
                p = fixed
            }
        }

        lock.lock()
        die.published = p
        let shift = die.blobShift, strength = die.blobStrength
        lock.unlock()

        if !node.isHidden, let blob = die.blob {
            let hgt = max(0, p.z - 0.5)
            let s = 1 + 0.45 * hgt
            blob.scale = SCNVector3(s, s, 1)
            blob.position = SCNVector3(p.x + shift * (0.1 + 0.12 * hgt), p.y - shift * (0.12 + 0.15 * hgt), 0.002)
            blob.opacity = max(0.25, 0.85 - 0.3 * hgt) * strength
        }

        // Game mode: a settled die knocked by another one starts rolling again.
        if wakes, case .idle = die.mode, !node.isHidden, let body = node.physicsBody,
           body.velocity.length > 0.6 || abs(body.angularVelocity.w) > 1.5 {
            die.mode = .rolling
            die.quiet = 0
            die.prevVelocity = nil
            let i = die.index
            dlog("SCENE die \(i) knocked moving again at \(p.short)")
            DispatchQueue.main.async { [weak self] in self?.onWoke?(i) }
        }

        guard case .rolling = die.mode, let body = node.physicsBody else { return }
        if time - die.lastPosLog > 0.25 {
            die.lastPosLog = time
            dlog(String(format: "SCENE die %d rolling t=%.2f pos=%@ |v|=%.2f |w|=%.2f",
                        die.index, time - die.rollStart, p.short, body.velocity.length, abs(body.angularVelocity.w)))
        }
        // Hit strength from the change in velocity beyond what gravity explains (SceneKit's
        // contact impulse reads 0). Thresholded and rate-limited so settling does not buzz.
        let vel = body.velocity
        if let pv = die.prevVelocity {
            let expected = SCNVector3(pv.x, pv.y, pv.z - Self.gravity * CGFloat(dt))
            let dv = (vel - expected).length
            let now = ProcessInfo.processInfo.systemUptime
            if dv > 2.0, now - die.lastHitTime > 0.045, now - lastAnyHit > 0.025, !(vel.length < 0.6 && dv < 3.5) {
                die.lastHitTime = now
                lastAnyHit = now
                let wall = now - die.lastWallContact < 0.06
                let other = now - die.lastDieContact < 0.06
                // Small dynamic range: a hard hit is only a little louder than a gentle one.
                let strength = Float(min(1, max(0, (dv - 2.0) / 18.0)))
                var vol = 0.55 + 0.45 * strength.squareRoot()
                if other { vol *= 0.8 }
                let kind = other ? "die" : (wall ? "wall" : "floor")
                emitSound(wall || other ? "tokWall" : "tokFloor", vol, String(format: "die %d %@ hit dv=%.1f", die.index, kind, dv))
            }
        }
        die.prevVelocity = vel
        let v = body.velocity.length
        let w = abs(body.angularVelocity.w)
        if body.isResting || (v < Self.restLinear && w < Self.restAngular && p.z < 0.75) {
            die.quiet += dt
        } else {
            die.quiet = 0
        }
        if die.quiet >= Self.restHold || body.isResting {
            let face = Self.faceUp(node.presentation.worldTransform)
            let secs = time - die.rollStart
            let ep = die.rollEpoch
            die.mode = .idle
            body.velocity = SCNVector3(0, 0, 0)
            body.angularVelocity = SCNVector4(0, 0, 1, 0)
            dlog(String(format: "SCENE die %d settled: face %d up after %.2f s at %@ (resting=%@)",
                        die.index, face, secs, p.short, body.isResting ? "yes" : "no"))
            let i = die.index
            DispatchQueue.main.async { [weak self] in self?.onSettled?(i, face, secs, ep) }
        }
    }

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        let ia = nodeIndex[ObjectIdentifier(contact.nodeA)]
        let ib = nodeIndex[ObjectIdentifier(contact.nodeB)]
        let now = ProcessInfo.processInfo.systemUptime
        if let a = ia, let b = ib {
            // Die against die: mark both for the hit sound; only rolling dice count.
            for i in [a, b] { if case .rolling = dice[i].mode { dice[i].lastDieContact = now } }
            return
        }
        guard let i = ia ?? ib else { return }
        let die = dice[i]
        let other = ia != nil ? contact.nodeB : contact.nodeA
        guard let name = other.name else { return }
        // A held die pressed against the edge is not a bounce: no log, no sound.
        guard case .rolling = die.mode else { return }
        die.lastWallContact = now
        if now - (die.lastBounce[name] ?? 0) > 0.15 {
            die.lastBounce[name] = now
            dlog(String(format: "SCENE die %d bounce off %@ (impulse %.1f) at %@", i, name, contact.collisionImpulse,
                        die.node.presentation.position.short))
        }
    }
}
