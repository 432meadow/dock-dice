import AppKit
import SceneKit

/// Transparent, click-through, full-screen window holding the SCNView. Never key, never main.
final class OverlayWindow: NSWindow {
    let scnView: SCNView
    let dice: DiceScene
    let edgePoints: CGFloat
    let screenFrame: CGRect     // AppKit space

    init(screen: NSScreen, edgePoints: CGFloat, blobShadow: Bool) {
        self.edgePoints = edgePoints
        screenFrame = screen.frame
        dice = DiceScene(halfWidth: screenFrame.width / edgePoints / 2,
                         halfHeight: screenFrame.height / edgePoints / 2,
                         blobShadow: blobShadow)
        scnView = SCNView(frame: NSRect(origin: .zero, size: screenFrame.size), options: nil)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // above Dock and menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        scnView.wantsLayer = true
        scnView.layer?.isOpaque = false
        scnView.layer?.backgroundColor = NSColor.clear.cgColor
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = false
        scnView.isPlaying = false
        scnView.allowsCameraControl = false
        scnView.scene = dice.scene
        scnView.pointOfView = dice.cameraNode
        scnView.delegate = dice
        contentView = scnView
        setFrame(screenFrame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var playing: Bool {
        get { scnView.isPlaying }
        set { if scnView.isPlaying != newValue { scnView.isPlaying = newValue; dlog("RENDER isPlaying = \(newValue)") } }
    }

    // MARK: Coordinates (CG global <-> scene)

    /// Scene x/y on the z = 0 plane under a global CG point.
    func sceneXY(fromCG p: CGPoint) -> CGPoint {
        let a = Coords.appKit(fromCG: p)
        return CGPoint(x: (a.x - screenFrame.midX) / edgePoints, y: (a.y - screenFrame.midY) / edgePoints)
    }

    func cgPoint(fromSceneXY s: CGPoint) -> CGPoint {
        Coords.cg(fromAppKit: CGPoint(x: s.x * edgePoints + screenFrame.midX, y: s.y * edgePoints + screenFrame.midY))
    }

    /// Unproject the cursor onto the plane at height z (perspective about the screen centre).
    func sceneXY(fromCG p: CGPoint, atHeight z: CGFloat) -> CGPoint {
        let s = sceneXY(fromCG: p)
        let k = (dice.cameraHeight - z) / dice.cameraHeight
        return CGPoint(x: s.x * k, y: s.y * k)
    }

    /// The die's projected screen circle (CG space).
    func dieCircle() -> (center: CGPoint, radius: CGFloat) {
        let p = dice.publishedPosition
        let k = dice.cameraHeight / (dice.cameraHeight - p.z)
        return (cgPoint(fromSceneXY: CGPoint(x: p.x * k, y: p.y * k)), 0.8 * k * edgePoints)
    }

    func containsCG(_ p: CGPoint) -> Bool { screenFrame.contains(Coords.appKit(fromCG: p)) }
}
