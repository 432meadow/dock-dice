import AppKit
import ApplicationServices
import SceneKit

// MARK: - Debug logging

let env = ProcessInfo.processInfo.environment
let isDemo = env["DICE_DEMO"] == "1"
let isDebug = env["DICE_DEBUG"] == "1" || isDemo
private let logStart = ProcessInfo.processInfo.systemUptime
private let logLock = NSLock()

func dlog(_ message: @autoclosure () -> String) {
    guard isDebug else { return }
    let line = String(format: "[Dice %8.3f] ", ProcessInfo.processInfo.systemUptime - logStart) + message() + "\n"
    logLock.lock()
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logLock.unlock()
}

enum DieState: String {
    case docked, held, rolling, resting, returning
    case trashed     // eaten by the Trash; the tile stays empty for a few seconds
    case game        // Hot Hand: five dice out (HandGame.swift); single-die paths stand aside
}

/// Owns the state machine and wires the tap, the Dock locator, the overlay, the tile and sound together.
final class AppDelegate: NSObject, NSApplicationDelegate, InputTapHandler {
    var state: DieState = .docked
    let dock = DockLocator()
    let tap = InputTap()
    let thrower = ThrowController()
    var tile: DockTileRenderer!
    var sound: SoundBoard!
    var overlay: OverlayWindow?
    var lastFace = 5
    var lastTilePoint: CGPoint?          // CG space; where the die last left / should return
    var trustedLast: Bool?
    var tapFailLogged = false
    var pollTimer: Timer?
    var heldTileTimer: Timer?
    var settleCount = 0
    // shadowOnly rendered no shadow over the transparent window (checked on screen), so the blob
    // shadow is the default. DICE_SHADOW=shadowonly brings back the spec's first approach for testing.
    let blobShadow = env["DICE_SHADOW"] != "shadowonly"
    /// Held target stays this far (scene units) from the screen edges, so a tumbling held die
    /// (half-diagonal ~0.71) rests near the edge without rattling against the wall.
    static let heldMargin: CGFloat = 0.8
    let snapshotDir = env["DICE_SNAPSHOT_DIR"]
    /// While holding the die in the drop zone, let drags through as mouseMoved so an autohidden
    /// Dock may reveal. On by default; DICE_REVEAL_DOCK=0 turns it off without a rebuild.
    let revealDock = env["DICE_REVEAL_DOCK"] != "0"

    enum Gesture {
        case none
        case dockPress(start: CGPoint, drags: Int)
        case holding(source: String, drags: Int)
        case keptPress(die: Int)     // Hot Hand: mouse down on a kept die (click hands it back)
    }
    var gesture = Gesture.none
    var rightClickOnDie = false         // swallowed right-down; swallow its right-up too
    var heldZone = DropZone.Kind.none   // drop-zone cue state while held
    var revealActive = false            // drags currently passed as mouseMoved
    var revealCount = 0
    var dockShowingWhileHeld: Bool?
    var returnStyle = DiceScene.ReturnStyle.drop
    var scriptRunning = false

    // Easter eggs
    var fridayOverride: Bool? = {
        switch env["DICE_FRIDAY13"] { case "1": return true; case "0": return false; default: return nil }
    }()
    var fridayActive = false
    var goldActive = false
    var appliedPalette = ""
    var naturalSixes = 0
    var rollLoaded = false
    var demoForceSix = false
    var trashTimer: Timer?
    let boredAfter: TimeInterval = Double(env["DICE_BORED_AFTER"] ?? "") ?? 180
    var boredTimer: Timer?
    var boredStage = 0

    // Hot Hand (HandGame.swift)
    var game: HandGame?
    var dockPressOption = false
    var demoForceTileHit = false          // DEMO-ONLY: treat the next Dock press as our tile
    var demoPendingForce: [Int: Int]?     // DEMO-ONLY: die index -> face to force on the next game throw
    var demoGameQueue: [(String, () -> Void)] = []
    var demoGameRunning = false
    static var bankedKey: String { isDemo ? "handBanked.demo" : "handBanked" }   // demo never touches the real score
    var bankedTotal: Int {
        get { UserDefaults.standard.integer(forKey: Self.bankedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bankedKey); tile?.setBadge(newValue) }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        dlog("LAUNCH pid=\(getpid()) bundle=\(Bundle.main.bundlePath) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) demo=\(isDemo) shadow=\(blobShadow ? "blob" : "shadowOnly")")
        dlog("LAUNCH \(DiceScene.selfCheck())")
        let sc = HandScoring.selfCheck()
        dlog("LAUNCH Hot Hand scoring self-check \(sc.ok ? "OK" : "FAILED") (\(sc.lines.count) cases)")
        for line in sc.lines { dlog("LAUNCH   score \(line)") }
        let zc = DropZone.selfCheck()
        dlog("LAUNCH drop-zone self-check \(zc.ok ? "OK" : "FAILED") (band depth \(Int(DropZone.bandDepth)) pt); reveal-Dock rewrite \(revealDock ? "ON" : "OFF (DICE_REVEAL_DOCK=0)")")
        for line in zc.lines { dlog("LAUNCH   zone \(line)") }
        dlog("LAUNCH bored after \(Int(boredAfter)) s (wobble gap \(String(format: "%.1f", boredGap(20))) s, shuffle after \(String(format: "%.1f", boredGap(60))) s); Friday13 override=\(fridayOverride.map { $0 ? "on" : "off" } ?? "none (date)")")
        sound = SoundBoard()
        tile = DockTileRenderer()
        refreshSkin("launch")
        tile.showFace(lastFace, palette: currentPalette())
        if isDemo { UserDefaults.standard.set(0, forKey: Self.bankedKey) }
        tile.setBadge(bankedTotal)
        dlog("GAME banked total at launch: \(bankedTotal) (key \(Self.bankedKey))")
        tap.handler = self

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        dlog("AX AXIsProcessTrustedWithOptions(prompt: true) -> \(trusted)")
        trustedLast = trusted
        tryStartTap(reason: "launch")
        dock.refresh(reason: "launch")
        if isDemo && !trusted { simulateHiddenDock() }
        prewarmOverlay("launch")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged),
                                               name: .NSCalendarDayChanged, object: nil)
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.popOut(reason: "demo start") }
        }
    }

    func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != trustedLast {
            dlog("AX trust changed: \(trustedLast.map(String.init) ?? "?") -> \(trusted)")
            trustedLast = trusted
        }
        if !tap.isInstalled { tryStartTap(reason: "retry timer") } else { tap.ensureEnabled() }
        dock.refresh(reason: "timer")
        refreshSkin("poll")
    }

    func tryStartTap(reason: String) {
        guard !tap.isInstalled else { return }
        if tap.start() {
            dlog("MODE gesture: event tap installed (\(reason)); AX trusted=\(AXIsProcessTrusted())")
            tapFailLogged = false
        } else if !tapFailLogged {
            tapFailLogged = true
            dlog("MODE fallback: CGEvent.tapCreate returned nil (\(reason)); AX trusted=\(AXIsProcessTrusted()). Click the Dock icon to pop/recall. Retrying every 2 s.")
        }
    }

    @objc func screensChanged() {
        dlog("SCREENS changed: recalling die (instant) and dropping overlay for refit")
        if state == .game { gameAbortForScreenChange() }
        if state != .docked && state != .trashed {
            overlay?.dice.send(.hideNow)
            finishDocking(reason: "screen parameters changed", sound: false)
        }
        overlay?.orderOut(nil)
        overlay = nil
        appliedPalette = ""
        dock.refresh(reason: "screen change")
        DispatchQueue.main.async { [weak self] in self?.prewarmOverlay("screen change") }
    }

    /// Build the overlay, scene and textures ahead of time (hidden), so the first pull never does
    /// that work inside the event-tap callback (it took ~83 ms there and stalled the tap).
    func prewarmOverlay(_ why: String) {
        let t0 = ProcessInfo.processInfo.systemUptime
        let o = ensureOverlay()     // (SCNView.prepare(_:) hung here at launch, so it is not used)
        o.dice.warmTextures()
        dlog(String(format: "OVERLAY prewarmed (%@) in %.0f ms", why, (ProcessInfo.processInfo.systemUptime - t0) * 1000))
    }

    @objc func dayChanged() { refreshSkin("calendar day changed") }

    // MARK: Dock integration

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let mouse = Coords.cg(fromAppKit: NSEvent.mouseLocation)
        dlog("REOPEN (Dock click reached the Dock, so the tap did not swallow it: tap installed=\(tap.isInstalled)) state=\(state.rawValue) mouse=\(fmt(mouse))")
        switch state {
        case .game:
            gameBank(reason: "Dock icon click (reopen)", heldStyle: .shot)
        case .docked:
            // Without AX the tile frame is unknown; a real Dock click leaves the mouse on the tile.
            if dock.tileFrame == nil, dockEdgeBand().contains(mouse) { lastTilePoint = mouse }
            popOut(reason: "Dock icon click (reopen)")
        case .trashed:
            restoreFromTrash("Dock icon click (reopen)")
        default:
            returnToDock(reason: "Dock icon click (reopen)", style: .shot)
        }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Recall Die", action: #selector(recallFromMenu), keyEquivalent: "")
        item.target = self
        item.isEnabled = state != .docked && state != .returning
        menu.addItem(item)
        let snd = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self
        snd.state = sound.enabled ? .on : .off
        snd.isEnabled = !sound.forcedMute
        menu.addItem(snd)
        if bankedTotal > 0 {
            let reset = NSMenuItem(title: "Reset Score", action: #selector(resetScore), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        return menu
    }

    @objc func resetScore() {
        dlog("GAME score reset from \(bankedTotal) (Dock menu)")
        bankedTotal = 0
    }

    @objc func recallFromMenu() {
        if state == .game { gameBank(reason: "Dock menu Recall Die", heldStyle: .shot); return }
        if state == .trashed { restoreFromTrash("Dock menu Recall Die") } else { returnToDock(reason: "Dock menu Recall Die", style: .shot) }
    }

    @objc func toggleSound() { sound.enabled.toggle() }

    // MARK: State

    func setState(_ s: DieState, _ why: String) {
        guard s != state else { return }
        let old = state
        dlog("STATE \(state.rawValue) -> \(s.rawValue) (\(why))")
        state = s
        if s == .docked { tile.showFace(lastFace, palette: currentPalette()) } else { tile.showEmptySlot() }
        if old == .resting { cancelBored("left resting: \(s.rawValue)") }
        switch s {
        case .resting:
            scheduleBored()
            sound.idle(after: 3, "die resting")
        case .docked, .trashed:
            sound.idle(after: 1.5, "die \(s.rawValue)")
        case .held, .rolling, .game:
            sound.wake("die \(s.rawValue)")
        case .returning:
            break
        }
    }

    /// The screen holding the Dock tile.
    func dockScreen() -> NSScreen {
        if let f = dock.tileFrame {
            // A hidden Dock's tile sits just off the screen edge, so allow some slack.
            let c = Coords.appKit(fromCG: CGPoint(x: f.midX, y: f.midY))
            if let s = NSScreen.screens.first(where: { $0.frame.contains(c) }) { return s }
            if let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -100, dy: -100).contains(c) }) { return s }
        }
        if let p = lastTilePoint {
            let c = Coords.appKit(fromCG: p)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(c) }) { return s }
        }
        let o = dock.prefs.orientation
        if let s = NSScreen.screens.first(where: {
            switch o {
            case "left": return $0.visibleFrame.minX > $0.frame.minX
            case "right": return $0.visibleFrame.maxX < $0.frame.maxX
            default: return $0.visibleFrame.minY > $0.frame.minY
            }
        }) { return s }
        return NSScreen.screens.first!
    }

    func ensureOverlay() -> OverlayWindow {
        let screen = dockScreen()
        if let o = overlay, o.screenFrame == screen.frame { return o }
        overlay?.orderOut(nil)
        let tileSize = dock.tileFrame?.width ?? dock.prefs.tileSize
        let edge = min(max(tileSize * 0.8, 44), 72)
        let o = OverlayWindow(screen: screen, edgePoints: edge, blobShadow: blobShadow)
        o.dice.onSettled = { [weak self] i, face, secs, ep in
            guard let self else { return }
            if self.game != nil { self.gameSettled(i, face: face, epoch: ep) } else if i == 0 { self.settled(face: face, seconds: secs, epoch: ep) }
        }
        o.dice.onReturned = { [weak self] i, ep in
            guard let self else { return }
            if self.game != nil { self.gameReturned(i, epoch: ep) } else if i == 0 { self.returned(epoch: ep) }
        }
        o.dice.onScriptDone = { [weak self] i, name, ep in
            guard let self else { return }
            if self.game != nil { self.gameScriptDone(i, name, epoch: ep) } else if i == 0 { self.scriptDone(name, epoch: ep) }
        }
        o.dice.onWoke = { [weak self] i in self?.gameWoke(i) }
        o.dice.onSound = { [weak self] name, vol, detail in self?.sound.play(name, volume: vol, detail: detail) }
        overlay = o
        appliedPalette = ""
        dlog(String(format: "OVERLAY created on screen %@ (AppKit) edgePoints=%.1f (tile %.0f) table=%.1fx%.1f units cameraHeight=%.2f",
                    fmt(screen.frame), edge, tileSize, o.dice.halfW * 2, o.dice.halfH * 2, o.dice.cameraHeight))
        refreshSkin("overlay created")
        return o
    }

    /// Where the tile is (CG). Falls back to the last known point, then the Dock edge centre.
    func tilePoint() -> CGPoint {
        dock.refreshTileFrame()
        if let f = dock.tileFrame { return CGPoint(x: f.midX, y: f.midY) }
        if let p = lastTilePoint { return p }
        let s = dockScreen().frame
        let a: CGPoint
        switch dock.prefs.orientation {
        case "left": a = CGPoint(x: s.minX + 30, y: s.midY)
        case "right": a = CGPoint(x: s.maxX - 30, y: s.midY)
        default: a = CGPoint(x: s.midX, y: s.minY + 30)
        }
        return Coords.cg(fromAppKit: a)
    }

    /// The drop zone (Dock and Trash) for the current Dock geometry.
    func dropZone() -> DropZone {
        var z = DropZone(screen: Coords.cgRect(fromAppKit: dockScreen().frame),
                         orientation: dock.prefs.orientation,
                         list: dock.listFrame,
                         strip: dock.stripRect,
                         tileSize: dock.tileFrame.map { min($0.width, $0.height) } ?? dock.prefs.tileSize)
        z.trash = dock.trashFrame
        return z
    }

    /// Demo without AX: inject a hidden bottom Dock shaped like the user's (list 1030 pt wide,
    /// centred, our tile 858 pt from its left end, the Trash at its right end, all below the edge).
    func simulateHiddenDock() {
        let s = Coords.cgRect(fromAppKit: dockScreen().frame)
        let list = CGRect(x: s.midX - 515, y: s.maxY, width: 1030, height: 61)
        let tileRect = CGRect(x: list.minX + 858, y: s.maxY, width: 49, height: 61)
        let trash = CGRect(x: list.maxX - 52, y: s.maxY, width: 49, height: 61)
        dock.simulate(list: list, tile: tileRect, trash: trash, reason: "demo, AX untrusted: Dock treated as hidden")
    }

    // MARK: Looks (Friday the 13th, hot-streak gold)

    func isFriday13Now() -> Bool {
        if let o = fridayOverride { return o }
        let c = Calendar.current.dateComponents([.weekday, .day], from: Date())
        return c.weekday == 6 && c.day == 13
    }

    /// Gold (hot streak) is a single-die egg: off in game mode.
    func currentPalette() -> DiePalette {
        (goldActive && game == nil) ? .gold : (fridayActive ? .friday13 : .classic)
    }

    func refreshSkin(_ why: String) {
        let f = isFriday13Now()
        if f != fridayActive {
            fridayActive = f
            dlog("FRIDAY13 \(f ? "ON: black die, red pips" : "off") (\(why); override=\(fridayOverride.map { $0 ? "on" : "off" } ?? "none"))")
        }
        let p = currentPalette()
        guard p.name != appliedPalette else { return }
        appliedPalette = p.name
        dlog("SKIN -> \(p.name) (\(why))")
        if let o = overlay {
            o.dice.applySkin(p)
            o.hud.applyPalette(p)
            pulseRender(0.15)
        }
        if state == .docked, tile != nil { tile.showFace(lastFace, palette: p) }
    }

    /// Wake rendering briefly so a change shows on a paused (resting) die.
    func pulseRender(_ seconds: TimeInterval) {
        guard let o = overlay, o.isVisible else { return }
        o.playing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.scriptRunning else { return }
            if self.state == .resting || (self.state == .game && self.game?.phase == .waiting) { self.overlay?.playing = false }
        }
    }

    // MARK: Actions

    func show(_ o: OverlayWindow) {
        if !o.isVisible {
            o.orderFrontRegardless()
            dlog("OVERLAY ordered front")
        }
        o.playing = true
    }

    func popOut(reason: String) {
        let o = ensureOverlay()
        let tp = tilePoint()
        lastTilePoint = tp
        let start = o.dice.clampXY(o.sceneXY(fromCG: tp), margin: 0.7)
        let (v, w) = ThrowController.popVelocity(from: start)
        show(o)
        o.dice.send(.place(position: SCNVector3(start.x, start.y, 1.0), orientation: DiceScene.randomOrientation(),
                           velocity: v, angular: w, held: false))
        setState(.rolling, "pop out: \(reason); tile at \(fmt(tp)); random start orientation")
    }

    func pull(at p: CGPoint, time: TimeInterval = ThrowController.now, reason: String) {
        if state == .trashed { cancelTrashTimer("die pulled out of the tile") }
        let o = ensureOverlay()
        if let f = dock.tileFrame { lastTilePoint = CGPoint(x: f.midX, y: f.midY) }
        let t = o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin)
        o.dice.setTarget(t)
        o.dice.setHeldScale(1)
        thrower.begin(p, at: time)
        show(o)
        o.dice.send(.place(position: SCNVector3(t.x, t.y, DiceScene.liftZ), orientation: DiceScene.randomOrientation(),
                           velocity: SCNVector3(0, 0, 0), angular: SCNVector4(0, 0, 1, 0), held: true))
        setState(.held, "pull from Dock: \(reason)")
        beginHoldTracking()
    }

    func grab(at p: CGPoint, time: TimeInterval = ThrowController.now, reason: String) {
        guard let o = overlay else { return }
        scriptRunning = false
        o.dice.setTarget(o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin))
        o.dice.setHeldScale(1)
        thrower.begin(p, at: time)
        show(o)
        o.dice.send(.hold)
        setState(.held, "grab: \(reason)")
        beginHoldTracking()
    }

    /// Moves the held die; returns the drop-zone kind for this point (used by the tap for the
    /// reveal rewrite). Logs only when the verdict changes. Also detects shakes.
    @discardableResult
    func moveHeld(to p: CGPoint, time: TimeInterval = ThrowController.now) -> DropZone.Kind {
        guard let o = overlay else { return .none }
        let z = dropZone().classify(p)
        let nearZone = z.kind != .none || distanceToDockEdge(p) < DropZone.bandDepth + 110
        let step = thrower.add(p, at: time, shakeAllowed: !nearZone)
        if step.reversal {
            if step.shaking {
                o.dice.shakeKick()
                sound.play("rattle", volume: Float.random(in: 0.3...0.4), detail: "shake reversal \(step.count) in 0.6 s")
                dlog("SHAKE reversal (\(step.count) within 0.6 s) at \(fmt(p)) -> rattle + tumble")
            } else {
                dlog("SHAKE reversal (\(step.count) within 0.6 s) at \(fmt(p)): not yet a shake")
            }
        }
        o.dice.setTarget(o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin))
        if z.kind != heldZone {
            let die = o.dice.publishedPosition
            let want = o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ)
            dlog(String(format: "HOLD die at scene (%.2f, %.2f), cursor target (%.2f, %.2f)", die.x, die.y, want.x, want.y))
            heldZone = z.kind
            o.dice.setHeldScale(z.kind == .none ? 1 : (z.kind == .trash ? 0.72 : 0.8))
            switch z.kind {
            case .none: dlog("CUE OFF at \(fmt(p)) [\(z.why)]")
            case .dock: dlog("CUE ON: letting go here docks the die at \(fmt(p)) [\(z.why)]")
            case .trash: dlog("CUE ON (Trash): letting go here feeds the die to the Trash at \(fmt(p)) [\(z.why)]")
            }
        }
        return z.kind
    }

    func releaseHeld(at p: CGPoint, time: TimeInterval = ThrowController.now, option: Bool = false) {
        guard let o = overlay, state == .held else { return }
        if !demoInjecting { demoTimer?.invalidate() }
        thrower.add(p, at: time)
        endHoldTracking()
        let z = dropZone().classify(p)
        let die = o.dice.publishedPosition
        let want = o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ)
        dlog(String(format: "RELEASE die at scene (%.2f, %.2f), cursor target (%.2f, %.2f): offset %.2f units",
                    die.x, die.y, want.x, want.y, hypot(die.x - want.x, die.y - want.y)))
        switch z.kind {
        case .trash:
            dlog("RELEASE at \(fmt(p)) TRASH: \(z.why)")
            feedTrash()
            return
        case .dock:
            dlog("RELEASE at \(fmt(p)) DROP on Dock: \(z.why); tileFrame=\(dock.tileFrame.map(fmt) ?? "unknown")")
            returnToDock(reason: "dropped on the Dock", style: .drop)
            return
        case .none:
            break
        }
        let (v, w, desc) = thrower.releaseVelocity(edgePoints: o.edgePoints, at: time)
        rollLoaded = option
        dlog("RELEASE at \(fmt(p)) THROW (\(z.why)): \(desc)\(option ? "; LOADED: Option held at mouse-up, this roll will land on 6" : "")")
        o.dice.send(.release(velocity: v, angular: w))
        setState(.rolling, "released")
        snapshot("rolling", after: 0.2)
    }

    /// drop = short shrink (hand drop); shot = fast accelerating flight with spin (right-click,
    /// Recall, tile click); trash is handled by feedTrash().
    func returnToDock(reason: String, style: DiceScene.ReturnStyle) {
        if state == .trashed { restoreFromTrash(reason); return }
        guard state != .docked, state != .returning, let o = overlay else {
            dlog("RECALL ignored (\(reason)): state=\(state.rawValue)")
            return
        }
        endHoldTracking()
        scriptRunning = false
        let tp = tilePoint()
        let s = o.sceneXY(fromCG: tp)
        let from = o.dice.publishedPosition
        let dist = hypot(s.x - from.x, s.y - from.y)
        let duration = style == .shot ? 0.25 + 0.10 * min(1, Double(dist) / 30) : 0.15
        show(o)
        returnStyle = style
        o.dice.send(.returnTo(SCNVector3(s.x, s.y, 0.6), duration: duration, style: style))
        setState(.returning, String(format: "%@: %@; to tile %@ (%.1f units, %.2f s)",
                                    style == .shot ? "shoot home" : "drop into Dock", reason, fmt(tp), dist, duration))
        if style == .shot { snapshot("shot-mid", after: duration * 0.5) }
    }

    func feedTrash() {
        guard let o = overlay else { return }
        let target = dock.trashFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? tilePoint()
        let s = o.sceneXY(fromCG: target)
        show(o)
        returnStyle = .trash
        o.dice.send(.returnTo(SCNVector3(s.x, s.y, 0.6), duration: 0.34, style: .trash))
        sound.play("crumple", volume: 0.5, detail: "die eaten by the Trash")
        setState(.returning, "into the Trash at \(fmt(target))")
    }

    func returned(epoch: Int) {
        guard let o = overlay, epoch == o.dice.epoch, state == .returning else {
            dlog("RETURNED callback stale (epoch \(epoch)); ignored")
            return
        }
        if returnStyle == .trash {
            o.playing = false
            o.orderOut(nil)
            dlog("OVERLAY ordered out")
            setState(.trashed, "the Trash ate it; back in 5 s (click the tile to restore now)")
            trashTimer?.invalidate()
            trashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.restoreFromTrash("5 s elapsed")
            }
            return
        }
        finishDocking(reason: "return animation finished (\(returnStyle.rawValue))", sound: true)
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.state == .docked { self?.popOut(reason: "demo") }
            }
        }
    }

    func cancelTrashTimer(_ why: String) {
        if trashTimer != nil { dlog("TRASH timer cancelled (\(why))") }
        trashTimer?.invalidate()
        trashTimer = nil
    }

    func restoreFromTrash(_ why: String) {
        guard state == .trashed else { return }
        cancelTrashTimer(why)
        setState(.docked, "back from the Trash: \(why)")
        sound.play("pop", volume: 0.45, detail: "die pops back into its tile")
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.state == .docked { self?.popOut(reason: "demo") }
            }
        }
    }

    func finishDocking(reason: String, sound playSound: Bool) {
        overlay?.playing = false
        overlay?.orderOut(nil)
        dlog("OVERLAY ordered out")
        if playSound {
            if returnStyle == .shot { sound.play("bigThunk", volume: 0.5, detail: "shot lands in the Dock") }
            else { sound.play("thunk", volume: 0.45, detail: "die lands in the Dock") }
        }
        setState(.docked, reason)
    }

    func settled(face: Int, seconds: TimeInterval, epoch: Int) {
        guard let o = overlay, epoch == o.dice.epoch, state == .rolling else {
            dlog("SETTLED callback stale (face \(face), epoch \(epoch), state \(state.rawValue)); ignored")
            return
        }
        if (rollLoaded || demoForceSix) && face != 6 {
            dlog("\(rollLoaded ? "LOADED" : "DEMO forced six"): settled on \(face) after \(String(format: "%.2f", seconds)) s -> deliberate hop-and-flip onto 6")
            scriptRunning = true
            o.dice.send(.flipTo(face: 6, label: rollLoaded ? "loaded" : "demo forced, counts as natural"))
            return
        }
        finishSettle(face: face, seconds: seconds)
    }

    func finishSettle(face: Int, seconds: TimeInterval) {
        guard let o = overlay else { return }
        lastFace = face
        settleCount += 1
        let loaded = rollLoaded
        let forced = demoForceSix
        rollLoaded = false
        demoForceSix = false

        // Hot streak: three natural sixes in a row -> gold for the next roll.
        var chime = false
        if loaded {
            if naturalSixes > 0 { dlog("STREAK reset by loaded roll (was \(naturalSixes))") }
            naturalSixes = 0
            if goldActive { goldActive = false; dlog("GOLD off: loaded roll") }
        } else {
            naturalSixes = face == 6 ? naturalSixes + 1 : 0
            if goldActive {
                if face == 6 { dlog("GOLD stays: another natural six (streak \(naturalSixes))") }
                else { goldActive = false; dlog("GOLD off: rolled \(face)") }
            } else if naturalSixes >= 3 {
                goldActive = true
                chime = true
                dlog("HOT STREAK: \(naturalSixes) natural sixes in a row -> gold for the next roll")
            }
        }
        dlog("ROLLED \(face)  (roll #\(settleCount), \(String(format: "%.2f", seconds)) s\(loaded ? ", LOADED" : "")\(forced ? ", demo-forced six counted as natural" : ""); natural-six streak \(naturalSixes))")
        o.playing = false
        setState(.resting, String(format: "settled after %.2f s", seconds))
        refreshSkin("roll settled")
        if chime {
            sound.play("chime", volume: 0.5, detail: "hot streak")
            snapshot("gold", after: 0.3)
        }
        if loaded { wink() }
        snapshot("settled-\(settleCount)-face\(face)-\(currentPalette().name)", after: 0.05)
        if isDemo { DispatchQueue.main.asyncAfter(deadline: .now() + (loaded ? 2.2 : 1.5)) { [weak self] in self?.demoNext() } }
    }

    /// The loaded die winks: the 6's pips blink off for ~150 ms, with a blip.
    func wink() {
        guard let o = overlay else { return }
        o.playing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.state == .resting else { return }
            o.dice.setWink(true)
            self.sound.play("blip", volume: 0.4, detail: "wink")
            dlog("WINK: pips closed")
            self.snapshot("wink-closed", after: 0.03)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                o.dice.setWink(false)
                dlog("WINK: pips open")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.state == .resting, !self.scriptRunning else { return }
                    o.playing = false
                }
            }
        }
    }

    func scriptDone(_ name: String, epoch: Int) {
        guard let o = overlay, epoch == o.dice.epoch else {
            dlog("SCRIPT \(name) done callback stale (epoch \(epoch)); ignored")
            return
        }
        scriptRunning = false
        switch name {
        case "flip":
            guard state == .rolling else { return }
            finishSettle(face: 6, seconds: 0)
        case "wobble":
            dlog("BORED wobble \(boredStage) finished; rendering paused again")
            if state == .resting { o.playing = false }
        case "shuffle":
            guard state == .resting else { return }
            returnToDock(reason: "bored: shuffled home by itself", style: .drop)
        default:
            break
        }
    }

    // MARK: Bored die

    func boredGap(_ seconds: TimeInterval) -> TimeInterval {
        max(1.5, seconds * boredAfter / 180)
    }

    func scheduleBored() {
        boredTimer?.invalidate()
        boredStage = 0
        boredTimer = Timer.scheduledTimer(withTimeInterval: boredAfter, repeats: false) { [weak self] _ in self?.boredStep() }
    }

    func cancelBored(_ why: String) {
        if boredStage > 0 { dlog("BORED reset at stage \(boredStage) (\(why))") }
        boredTimer?.invalidate()
        boredTimer = nil
        boredStage = 0
    }

    func boredStep() {
        guard state == .resting, let o = overlay else { return }
        boredStage += 1
        switch boredStage {
        case 1, 2:
            dlog("BORED stage \(boredStage): wobble (resting untouched)")
            scriptRunning = true
            o.playing = true
            o.dice.send(.wobble)
            let next = boredStage == 1 ? boredGap(20) : boredGap(60)
            boredTimer = Timer.scheduledTimer(withTimeInterval: next, repeats: false) { [weak self] _ in self?.boredStep() }
        default:
            let tp = tilePoint()
            dlog("BORED stage \(boredStage): shuffling home toward the tile at \(fmt(tp))")
            sound.wake("bored shuffle")
            scriptRunning = true
            o.playing = true
            o.dice.send(.shuffleHome(to: o.sceneXY(fromCG: tp)))
        }
    }

    func beginHoldTracking() {
        heldZone = .none
        revealActive = false
        revealCount = 0
        dockShowingWhileHeld = dropZone().dockShowing
        dlog("HOLD tracking: Dock \(dockShowingWhileHeld! ? "shown" : "hidden"), list=\(dock.listFrame.map(fmt) ?? "unknown"), tile=\(dock.tileFrame.map(fmt) ?? "unknown"), trash=\(dock.trashFrame.map(fmt) ?? "unknown")")
        heldTileTimer?.invalidate()
        heldTileTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dock.refreshTileFrame()
            let showing = self.dropZone().dockShowing
            if showing != self.dockShowingWhileHeld {
                dlog("DOCK \(showing ? "REVEALED" : "hid again") while holding: list=\(self.dock.listFrame.map(fmt) ?? "?") tile=\(self.dock.tileFrame.map(fmt) ?? "?") (reveal rewrite \(self.revealActive ? "active" : "inactive"), \(self.revealCount) drags rewritten so far)")
                self.dockShowingWhileHeld = showing
            }
        }
    }

    func endHoldTracking() {
        heldTileTimer?.invalidate()
        heldTileTimer = nil
        if revealCount > 0 { dlog("REVEAL summary: \(revealCount) drags passed as mouseMoved during this hold") }
        revealActive = false
        revealCount = 0
        heldZone = .none
    }

    // MARK: Tap decisions (main thread, must be fast)

    /// The band along the Dock's edge of its screen, deep enough for a shown or magnified Dock (CG).
    /// Used on mouse-down to catch a click on a just-revealed Dock before the cached strip updates.
    func dockEdgeBand() -> CGRect {
        let s = Coords.cgRect(fromAppKit: dockScreen().frame)
        let depth = max(dock.prefs.tileSize, dock.prefs.magnification ? dock.prefs.largeSize : 0) + 40
        switch dock.prefs.orientation {
        case "left": return CGRect(x: s.minX, y: s.minY, width: depth, height: s.height)
        case "right": return CGRect(x: s.maxX - depth, y: s.minY, width: depth, height: s.height)
        default: return CGRect(x: s.minX, y: s.maxY - depth, width: s.width, height: depth)
        }
    }

    /// Distance (pt) from a CG point to the Dock's edge of the Dock screen.
    func distanceToDockEdge(_ p: CGPoint) -> CGFloat {
        let s = Coords.cgRect(fromAppKit: dockScreen().frame)
        switch dock.prefs.orientation {
        case "left": return p.x - s.minX
        case "right": return s.maxX - p.x
        default: return s.maxY - p.y
        }
    }

    func dieHit(_ p: CGPoint) -> (hit: Bool, note: String) {
        guard state == .rolling || state == .resting, let o = overlay else { return (false, "die \(state.rawValue)") }
        let c = o.dieCircle()
        let d = hypot(p.x - c.center.x, p.y - c.center.y)
        return (d <= c.radius, String(format: "d=%.0f %@ r=%.0f", d, d <= c.radius ? "<=" : ">", c.radius))
    }

    func handleTapEvent(_ type: CGEventType, at p: CGPoint, time: TimeInterval, flags: CGEventFlags) -> TapDecision {
        switch type {
        case .leftMouseDown:
            if !demoInjecting, demoTimer?.isValid == true {
                dlog("TAP down: real input during a demo gesture; demo gesture cancelled")
                demoTimer?.invalidate()
            }
            if state == .held {
                dlog("TAP down: stale held state (missed mouse-up?); releasing first")
                releaseHeld(at: p, time: time)
            }
            gesture = .none
            dockPressOption = false
            if state == .game, let d = gameMouseDown(p, time: time) { return d }
            let die = dieHit(p)
            if die.hit {
                dlog("TAP down \(fmt(p)) SWALLOW: on die (\(die.note))")
                gesture = .holding(source: "die", drags: 0)
                grab(at: p, time: time, reason: "mouse down on die")
                return .swallow
            }
            guard let strip = dock.stripRect else {
                dlog("TAP down \(fmt(p)) PASS: \(die.note); Dock strip unknown (AX trusted=\(AXIsProcessTrusted()))")
                return .pass
            }
            // The cached strip can be stale (autohide slides the Dock in, magnification grows it),
            // so a click in the Dock-side edge band of the Dock's screen is also checked.
            let inStrip = strip.contains(p)
            let inBand = dockEdgeBand().contains(p)
            guard inStrip || inBand else {
                dlog("TAP down \(fmt(p)) PASS: \(die.note); outside Dock strip \(fmt(strip)) and edge band")
                return .pass
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let hit = dock.hitTest(p)
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            let via = inStrip ? "cached strip" : "edge band (strip stale)"
            let forced = isDemo && demoInjecting && demoForceTileHit && !hit.isOurs
            if hit.isOurs || forced {
                dockPressOption = flags.contains(.maskAlternate)
                dlog(String(format: "TAP down %@ SWALLOW: our Dock tile via %@ (%.1f ms) %@%@%@", fmt(p), via, ms, hit.detail,
                            forced ? " [DEMO-ONLY: tile hit forced]" : "", dockPressOption ? " with Option" : ""))
                gesture = .dockPress(start: p, drags: 0)
                return .swallow
            }
            dlog(String(format: "TAP down %@ PASS: via %@, not our tile (%.1f ms) %@", fmt(p), via, ms, hit.detail))
            return .pass

        case .leftMouseDragged:
            switch gesture {
            case .none:
                return .pass
            case let .dockPress(start, drags):
                let dist = hypot(p.x - start.x, p.y - start.y)
                if dist > 6 {
                    let option = dockPressOption || flags.contains(.maskAlternate)
                    if state == .game {
                        dlog(String(format: "TAP drag SWALLOW: moved %.1f pt from tile during a game -> gather the live dice at %@", dist, fmt(p)))
                        gesture = gameGrab(at: p, time: time, reason: "drag off tile") ? .holding(source: "game", drags: drags + 1) : .none
                    } else if option {
                        dlog(String(format: "TAP drag SWALLOW: moved %.1f pt (> 6) from tile with Option -> Hot Hand: pull five dice at %@", dist, fmt(p)))
                        gesture = .holding(source: "game", drags: drags + 1)
                        startGame(at: p, time: time)
                    } else {
                        dlog(String(format: "TAP drag SWALLOW: moved %.1f pt (> 6) from tile after %d drags -> pull die out at %@", dist, drags + 1, fmt(p)))
                        gesture = .holding(source: "dock", drags: drags + 1)
                        pull(at: p, time: time, reason: "drag off tile")
                    }
                } else {
                    gesture = .dockPress(start: start, drags: drags + 1)
                }
                return .swallow
            case let .holding(source, drags):
                if drags == 0 { dlog("TAP drag SWALLOW: first drag while holding (from \(source)) at \(fmt(p))") }
                gesture = .holding(source: source, drags: drags + 1)
                let zone = moveHeld(to: p, time: time)
                let reveal = revealDock && zone != .none
                if reveal != revealActive {
                    revealActive = reveal
                    dlog(reveal ? "REVEAL ON: drags in the drop zone now pass through as mouseMoved at \(fmt(p)) (Dock \(dropZone().dockShowing ? "shown" : "hidden"))"
                                : "REVEAL OFF at \(fmt(p)): drags swallowed again")
                }
                if reveal {
                    revealCount += 1
                    return .passAs(.mouseMoved)
                }
                return .swallow
            case .keptPress:
                return .swallow
            }

        case .leftMouseUp:
            switch gesture {
            case .none:
                return .pass
            case let .dockPress(_, drags):
                gesture = .none
                dlog("TAP up \(fmt(p)) SWALLOW: click on our tile without drag (\(drags) small drags); state=\(state.rawValue)")
                switch state {
                case .docked: popOut(reason: "tile click")
                case .trashed: restoreFromTrash("tile click")
                case .game: gameBank(reason: "tile click", heldStyle: .shot)
                default: returnToDock(reason: "tile click while die out", style: .shot)
                }
                return .swallow
            case let .holding(source, drags):
                gesture = .none
                let option = flags.contains(.maskAlternate)
                dlog("TAP up \(fmt(p)) SWALLOW: release (from \(source), \(drags) drags handled)\(option ? " with Option" : "")")
                if state == .game { gameRelease(at: p, time: time, option: option) } else { releaseHeld(at: p, time: time, option: option) }
                return .swallow
            case let .keptPress(die):
                gesture = .none
                dlog("TAP up \(fmt(p)) SWALLOW: click on kept die \(die)")
                gameHandBack(die)
                return .swallow
            }

        case .rightMouseDown:
            rightClickOnDie = false
            if state == .game {
                if gameRightClick(p) { rightClickOnDie = true; return .swallow }
                dlog("TAP right-down \(fmt(p)) PASS: not on a game die; Dock menu and other right-clicks untouched")
                return .pass
            }
            let die = dieHit(p)
            if die.hit {
                rightClickOnDie = true
                dlog("TAP right-down \(fmt(p)) SWALLOW: right-click on die (\(die.note)) -> shoot home")
                returnToDock(reason: "right-click on die", style: .shot)
                return .swallow
            }
            dlog("TAP right-down \(fmt(p)) PASS: not on die (\(die.note)); Dock menu and other right-clicks untouched")
            return .pass

        case .rightMouseUp:
            if rightClickOnDie {
                rightClickOnDie = false
                dlog("TAP right-up \(fmt(p)) SWALLOW: matching up of the die right-click")
                return .swallow
            }
            return .pass

        default:
            return .pass
        }
    }

    // MARK: Demo mode (no permission needed): drives handleTapEvent with synthetic events

    var demoStep = 0
    var demoTimer: Timer?
    var demoInjecting = false
    /// DICE_DEMO_STEPS=step,step,... runs only those steps (names as below).
    let demoSteps = env["DICE_DEMO_STEPS"].map { $0.split(separator: ",").map(String.init) } ??
        ["throw", "pause-throw", "shake", "loaded", "right-click", "hand-drop", "trash",
         "six", "six", "six", "natural", "natural", "friday-off", "throw", "friday-on", "bored"]

    func inject(_ type: CGEventType, _ p: CGPoint, flags: CGEventFlags = []) -> TapDecision {
        demoInjecting = true
        defer { demoInjecting = false }
        let t0 = ProcessInfo.processInfo.systemUptime
        let d = handleTapEvent(type, at: p, time: ThrowController.now, flags: flags)
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        if ms > 30 { dlog(String(format: "TAP WARNING (demo-injected): handler took %.1f ms for %@", ms, type.name)) }
        return d
    }

    func describe(_ d: TapDecision) -> String {
        switch d {
        case .pass: return "pass"
        case .swallow: return "swallow"
        case let .passAs(t): return "pass as \(t.name)"
        }
    }

    /// Synthetic left-drag: down at `from`, drags along `path(t)` for `duration` s at 60 Hz, then no
    /// events for `pause` s (a cursor held still sends none), then up at the last point.
    func demoDrag(_ label: String, from: CGPoint, duration: TimeInterval, pause: TimeInterval,
                          upFlags: CGEventFlags = [], downFlags: CGEventFlags = [], dragFlags: CGEventFlags = [],
                          path: @escaping (TimeInterval) -> CGPoint) {
        let d0 = inject(.leftMouseDown, from, flags: downFlags)
        dlog("DEMO \(label): synthetic leftMouseDown at \(fmt(from)) -> \(describe(d0))")
        let t0 = ThrowController.now
        var last = from
        var lastDecision = ""
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = ThrowController.now - t0
            if t < duration {
                last = path(t)
                let d = self.describe(self.inject(.leftMouseDragged, last, flags: dragFlags))
                if d != lastDecision { dlog("DEMO \(label): synthetic drags at \(fmt(last)) -> \(d)"); lastDecision = d }
            } else if t >= duration + pause {
                timer.invalidate()
                let d = self.inject(.leftMouseUp, last, flags: upFlags)
                dlog("DEMO \(label): synthetic leftMouseUp at \(fmt(last)) after \(Int(pause * 1000)) ms pause\(upFlags.contains(.maskAlternate) ? " with Option" : "") -> \(self.describe(d))")
            }
        }
    }

    func demoNext() {
        guard isDemo, state == .resting, let o = overlay else { return }
        let name = demoStep < demoSteps.count ? demoSteps[demoStep] : "throw"
        demoStep += 1
        if demoStep == demoSteps.count + 1 { dlog("DEMO walkthrough complete; plain throws from here on") }
        let start = o.dieCircle().center
        let screen = Coords.cgRect(fromAppKit: o.screenFrame)
        let bounds = screen.insetBy(dx: 60, dy: 60)
        func clampPt(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let centre = CGPoint(x: screen.midX, y: screen.midY)
        let angle = atan2(centre.y - start.y, centre.x - start.x) + CGFloat.random(in: -1.0...1.0)
        let dir = CGVector(dx: cos(angle), dy: sin(angle))
        let speed = CGFloat.random(in: 1400...2400)
        let throwPath: (TimeInterval) -> CGPoint = { t in
            let w = min(1, t / 0.12)
            return clampPt(CGPoint(x: start.x + dir.dx * speed * CGFloat(t) * w, y: start.y + dir.dy * speed * CGFloat(t) * w))
        }
        dlog("DEMO step \(demoStep)/\(demoSteps.count): \(name) (die at \(fmt(start)))")

        switch name {
        case "throw", "natural":
            demoDrag(name, from: start, duration: 0.3, pause: 0, path: throwPath)
        case "pause-throw":
            demoDrag(name, from: start, duration: 0.25, pause: 0.15, path: throwPath)
        case "loaded":
            demoDrag(name, from: start, duration: 0.3, pause: 0, upFlags: .maskAlternate, path: throwPath)
        case "six":
            demoForceSix = true
            dlog("DEMO forcing this roll to land on 6 (flip if needed), counted as a natural six")
            demoDrag(name, from: start, duration: 0.3, pause: 0, path: throwPath)
        case "shake":
            // Zigzag: 40 pt amplitude, 140 ms period (a reversal every 70 ms, ~1800 pt/s peak), then let go.
            let s0 = clampPt(start)
            demoDrag(name, from: start, duration: 0.5, pause: 0) { t in
                CGPoint(x: s0.x + 40 * sin(2 * .pi * t / 0.14), y: s0.y + 12 * sin(2 * .pi * t / 0.28))
            }
        case "right-click":
            let d1 = inject(.rightMouseDown, start)
            dlog("DEMO right-click: synthetic rightMouseDown -> \(describe(d1))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                dlog("DEMO right-click: synthetic rightMouseUp -> \(self.describe(self.inject(.rightMouseUp, start)))")
                let away = CGPoint(x: screen.midX, y: screen.minY + 200)
                dlog("DEMO right-click away from die at \(fmt(away)) -> \(self.describe(self.inject(.rightMouseDown, away))) / \(self.describe(self.inject(.rightMouseUp, away)))")
            }
        case "hand-drop", "trash":
            // The hand drop lands ~300 pt away from our tile (like the user's real drops), so a die
            // that jumped to the tile's x instead of staying under the cursor would show in the log.
            let tileX = dock.tileFrame?.midX ?? screen.midX
            let x = name == "trash" ? (dock.trashFrame?.midX ?? screen.maxX - 100) : max(screen.minX + 120, tileX - 300)
            let target = CGPoint(x: x, y: screen.maxY - 8)
            dlog("DEMO \(name): carry the die to \(fmt(target)) (Dock \(dropZone().dockShowing ? "shown" : "hidden"))")
            demoDrag(name, from: start, duration: 0.6, pause: 0.35) { t in
                let k = CGFloat(min(1, t / 0.5))
                let e = k * k * (3 - 2 * k)
                return CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            }
            snapshot("cue-\(name)", after: 0.75)
        case "friday-off", "friday-on":
            fridayOverride = name == "friday-on"
            refreshSkin("demo \(name)")
            snapshot("skin-\(name)", after: 0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.demoNext() }
        case "game":
            demoGameStart()
        case "bored":
            dlog("DEMO waiting for boredom: untouched for \(Int(boredAfter)) s, wobble, wobble, then shuffle home")
        default:
            break
        }
    }

    // MARK: Debug snapshots (DICE_SNAPSHOT_DIR)

    func snapshot(_ name: String, after delay: TimeInterval) {
        guard let dir = snapshotDir else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let o = self?.overlay, o.isVisible else { return }
            let img = o.scnView.snapshot()
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: url)
            let p = o.dice.publishedPosition
            dlog(String(format: "SNAPSHOT %@ %dx%d die at scene (%.2f, %.2f)", url.path, rep.pixelsWide, rep.pixelsHigh, p.x, p.y))
        }
    }
}
