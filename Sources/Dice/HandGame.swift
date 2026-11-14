import AppKit
import SceneKit

/// Hot Hand: a hidden five-dice push-your-luck game (Option-drag the Dice tile off the Dock).
/// Four ivory dice and one gold "special" die whose 1 face is wild. Scoring rules live in
/// Scoring.swift (pure); this file is the turn flow, wired into the app's existing gestures.
final class HandGame {
    enum Phase: String {
        case holding    // the handful is in the hand
        case rolling    // thrown dice are moving
        case scoring    // scored dice glow and slide into the kept row
        case waiting    // everything at rest: grab to throw again, right-click/drop to bank
        case ending     // dice on their way home
    }

    /// The special die: always gold, its 1 face is the wild.
    static let special = 4

    var phase = Phase.holding
    var live: [Int] = [0, 1, 2, 3, 4]            // dice in play (not kept)
    var kept: [Int] = []                          // dice in the row, in slot order
    var faces: [Int: Int] = [:]                   // last known face of each die
    var thrown: [Int] = []                        // dice of the current throw
    var settled: [Int: Int] = [:]                 // die -> face, current throw
    var lastThrow: (dice: [Int], result: HandScoring.Throw, keptFromIt: [Int])?
    var turnTotal = 0
    var throwCount = 0
    var hotHands = 0
    var pending: Set<Int> = []                    // dice whose animation we are waiting for
    var endKind = ""
    var flipsPending = 0
    var rowX0: CGFloat = 0                        // scene x of row slot 0
    var rowY: CGFloat = 0                         // scene y of the row
    var boredTimer: Timer?
    var scoreCheck: DispatchWorkItem?
    var demoForceFaces: [Int: Int]?               // DEMO-ONLY: die -> face for this throw
}

extension AppDelegate {
    static let rowSpacing: CGFloat = 1.0
    static let keptScale: CGFloat = 0.82

    func gameLog(_ s: @autoclosure () -> String) { dlog("GAME " + s()) }

    // MARK: Geometry

    /// Loose handful offsets (scene units) for `n` dice: a ring, randomly turned.
    func handOffsets(_ n: Int) -> [CGPoint] {
        guard n > 1 else { return [.zero] }
        // Neighbours sit about 1.35 apart, so dice tumbling in the hand just clear each other.
        let r: CGFloat = 1.35 / (2 * sin(.pi / CGFloat(n)))
        let a0 = CGFloat.random(in: 0..<(2 * .pi))
        return (0..<n).map { k in
            let a = a0 + 2 * .pi * CGFloat(k) / CGFloat(n)
            return CGPoint(x: r * cos(a), y: r * sin(a))
        }
    }

    func rowSlot(_ k: Int) -> SCNVector3 {
        guard let g = game else { return SCNVector3(0, 0, 0.41) }
        return SCNVector3(g.rowX0 + CGFloat(k) * Self.rowSpacing, g.rowY, 0.5 * Self.keptScale)
    }

    /// Lay out the kept row once per turn: near the Dock edge, centred above the Dice tile,
    /// above a permanently shown Dock, with room on the right for the pill.
    func layoutRow(_ g: HandGame, _ o: OverlayWindow) {
        let tp = tilePoint()
        let s = Coords.cgRect(fromAppKit: o.screenFrame)
        let fixedDock = !dock.prefs.autohide && dropZone().dockShowing
        let yCG = fixedDock ? (dock.stripRect?.minY ?? s.maxY) - 34 : s.maxY - 40
        let a = o.sceneXY(fromCG: CGPoint(x: tp.x, y: yCG))
        var x0 = a.x - 2 * Self.rowSpacing
        let maxX = o.dice.halfW - 0.7 - 2.6
        if x0 + 4 * Self.rowSpacing > maxX { x0 = maxX - 4 * Self.rowSpacing }
        x0 = max(x0, -o.dice.halfW + 0.7)
        g.rowX0 = x0
        g.rowY = a.y
        gameLog(String(format: "row laid out at scene x %.2f..%.2f, y %.2f (tile %@, Dock %@)", x0, x0 + 4 * Self.rowSpacing, a.y,
                       fmt(tp), fixedDock ? "always shown" : "hidden/autohide"))
    }

    func pillAnchor() -> CGPoint {
        guard let o = overlay else { return .zero }
        let p = rowSlot(4)
        return o.localPoint(fromScene: SCNVector3(p.x + 0.75, p.y, p.z))
    }

    /// The game die (among `ids`) under a CG point, nearest first.
    func gameHit(_ p: CGPoint, among ids: [Int]) -> Int? {
        guard let o = overlay else { return nil }
        var best: (Int, CGFloat)?
        for i in ids {
            let c = o.dieCircle(i)
            let d = hypot(p.x - c.center.x, p.y - c.center.y)
            if d <= c.radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    func updatePill() {
        guard let g = game, let o = overlay else { return }
        if !o.hud.pillVisible { o.hud.showPill(at: pillAnchor(), value: 0) }
        o.hud.setPillValue(g.turnTotal)
    }

    // MARK: Start, grab, throw

    func startGame(at p: CGPoint, time: TimeInterval) {
        if state == .rolling || state == .resting || state == .held {
            overlay?.dice.send(.hideNow)
            gameLog("single die put away for the game")
        }
        if state == .trashed { cancelTrashTimer("Hot Hand started") }
        let o = ensureOverlay()
        let g = HandGame()
        game = g
        if let f = dock.tileFrame { lastTilePoint = CGPoint(x: f.midX, y: f.midY) }
        o.dice.wakeChecks = true
        o.dice.setPipStyle(.constellation)
        o.dice.setSpecialDie(HandGame.special)
        appliedPalette = ""
        refreshSkin("Hot Hand start")
        layoutRow(g, o)
        let t = o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin)
        o.dice.setTarget(t)
        o.dice.setHeldScale(1)
        let offs = handOffsets(g.live.count)
        for (k, i) in g.live.enumerated() {
            o.dice.setOffset(offs[k], for: i)
            o.dice.send(.place(position: SCNVector3(t.x + offs[k].x, t.y + offs[k].y, DiceScene.liftZ),
                               orientation: DiceScene.randomOrientation(), velocity: SCNVector3(0, 0, 0),
                               angular: SCNVector4(0, 0, 1, 0), held: true), to: i)
        }
        thrower.begin(p, at: time)
        show(o)
        setState(.game, "Hot Hand: Option-pull, five dice in hand (die \(HandGame.special) is the gold wild die)")
        beginHoldTracking()
        g.phase = .holding
        gameLog("turn starts; banked total \(bankedTotal)")
    }

    /// Mouse-down during a game. nil = not on a game die (the Dock checks follow).
    func gameMouseDown(_ p: CGPoint, time: TimeInterval) -> TapDecision? {
        guard let g = game else { return nil }
        if g.phase == .holding {
            gameLog("stale hold (missed mouse-up?); throwing first")
            gameRelease(at: p, time: time, option: false)
        }
        if let i = gameHit(p, among: g.live) {
            if g.phase == .waiting {
                dlog("TAP down \(fmt(p)) SWALLOW: on live game die \(i)")
                gesture = .holding(source: "game", drags: 0)
                _ = gameGrab(at: p, time: time, reason: "mouse down on die \(i)")
            } else {
                dlog("TAP down \(fmt(p)) SWALLOW: on game die \(i), but the dice are busy (\(g.phase.rawValue)); ignored")
            }
            return .swallow
        }
        if let i = gameHit(p, among: g.kept) {
            if g.phase == .waiting {
                dlog("TAP down \(fmt(p)) SWALLOW: on kept die \(i) (a click may hand it back)")
                gesture = .keptPress(die: i)
            } else {
                dlog("TAP down \(fmt(p)) SWALLOW: on kept die \(i), busy (\(g.phase.rawValue)); ignored")
            }
            return .swallow
        }
        return nil
    }

    @discardableResult
    func gameGrab(at p: CGPoint, time: TimeInterval, reason: String) -> Bool {
        guard let g = game, let o = overlay, g.phase == .waiting, !g.live.isEmpty else {
            gameLog("grab ignored (\(reason)): phase \(game?.phase.rawValue ?? "none")")
            return false
        }
        g.boredTimer?.invalidate()
        let t = o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin)
        o.dice.setTarget(t)
        o.dice.setHeldScale(1)
        let offs = handOffsets(g.live.count)
        for (k, i) in g.live.enumerated() {
            o.dice.setOffset(offs[k], for: i)
            o.dice.send(.hold, to: i)
        }
        thrower.begin(p, at: time)
        show(o)
        g.phase = .holding
        beginHoldTracking()
        gameLog("handful of \(g.live.count) gathered \(g.live) (\(reason))")
        return true
    }

    func gameRelease(at p: CGPoint, time: TimeInterval, option: Bool) {
        guard let g = game, let o = overlay, g.phase == .holding else { return }
        if !demoInjecting { demoTimer?.invalidate() }
        thrower.add(p, at: time)
        endHoldTracking()
        if option { gameLog("Option at release ignored: the loaded die is off in game mode") }
        let z = dropZone().classify(p)
        switch z.kind {
        case .trash:
            gameLog("handful dropped on the Trash (\(z.why)): turn forfeited, \(g.turnTotal) lost")
            sound.play("crumple", volume: 0.5, detail: "Hot Hand forfeited to the Trash")
            g.turnTotal = 0
            endTurn(kind: "trash") { _ in .trash }
            return
        case .dock:
            gameLog("handful dropped on the Dock (\(z.why)): bank")
            gameBank(reason: "handful dropped on the Dock", heldStyle: .drop)
            return
        case .none:
            break
        }
        let (v, w, desc) = thrower.releaseVelocity(edgePoints: o.edgePoints, at: time)
        let centre = o.dice.clampXY(o.sceneXY(fromCG: p, atHeight: DiceScene.liftZ), margin: AppDelegate.heldMargin)
        g.thrown = g.live
        g.settled = [:]
        g.throwCount += 1
        g.phase = .rolling
        if let f = demoPendingForce {
            g.demoForceFaces = f
            demoPendingForce = nil
            gameLog("DEMO-ONLY: this throw will be forced to \(f.sorted { $0.key < $1.key }.map { "die \($0.key)=\($0.value)" })")
        }
        for i in g.thrown {
            // Slightly different velocities and spins so the handful scatters.
            let ang = CGFloat.random(in: -0.18...0.18)
            let sp = CGFloat.random(in: 0.85...1.15)
            let dp = o.dice.position(of: i)
            let spread = SCNVector3(dp.x - centre.x, dp.y - centre.y, 0) * 1.6
            let vi = SCNVector3((v.x * cos(ang) - v.y * sin(ang)) * sp, (v.x * sin(ang) + v.y * cos(ang)) * sp, v.z) + spread
            let wi = axisAngle(angularVector(w) + ThrowController.randomSpin(CGFloat.random(in: 5...10)))
            o.dice.send(.release(velocity: vi, angular: wi), to: i)
        }
        gameLog("THROW #\(g.throwCount) of the turn: \(g.thrown.count) dice \(g.thrown); \(desc)")
        snapshot("game-throw-\(g.throwCount)", after: 0.12)
    }

    // MARK: Settling and scoring

    func gameSettled(_ i: Int, face: Int, epoch: Int) {
        guard let g = game, let o = overlay else { return }
        guard g.phase == .rolling, g.thrown.contains(i) else {
            gameLog("settle of die \(i) on \(face) ignored (phase \(g.phase.rawValue))")
            return
        }
        guard epoch == o.dice.epoch(of: i) else { gameLog("settle of die \(i) stale (epoch \(epoch))"); return }
        g.settled[i] = face
        g.faces[i] = face
        gameLog("die \(i) settled on \(face)\(i == HandGame.special && face == 1 ? " (WILD)" : "") (\(g.settled.count)/\(g.thrown.count))")
        if g.settled.count == g.thrown.count {
            g.scoreCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let g = self.game, g.phase == .rolling, g.settled.count == g.thrown.count else { return }
                self.scoreThrow()
            }
            g.scoreCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func gameWoke(_ i: Int) {
        guard let g = game, g.phase == .rolling, g.settled[i] != nil else { return }
        g.settled[i] = nil
        g.scoreCheck?.cancel()
        gameLog("die \(i) knocked moving again; waiting for it to settle")
    }

    func scoreThrow() {
        guard let g = game, let o = overlay, g.phase == .rolling else { return }
        var faces = g.thrown.map { o.dice.faceUpNow($0) }
        for (k, i) in g.thrown.enumerated() where g.settled[i] != nil && faces[k] != g.settled[i] {
            gameLog("die \(i) face re-read as \(faces[k]) (settled as \(g.settled[i]!))")
        }
        if let forced = g.demoForceFaces {
            g.demoForceFaces = nil
            var flips = 0
            for (k, i) in g.thrown.enumerated() {
                if let f = forced[i], faces[k] != f {
                    o.dice.send(.flipTo(face: f, label: "DEMO-ONLY forced face"), to: i)
                    flips += 1
                }
            }
            if flips > 0 {
                g.flipsPending = flips
                gameLog("DEMO-ONLY: flipping \(flips) dice onto forced faces before scoring")
                return
            }
        }
        faces = g.thrown.map { o.dice.faceUpNow($0) }
        for (k, i) in g.thrown.enumerated() { g.faces[i] = faces[k] }
        let wildIdx = g.thrown.firstIndex(of: HandGame.special).flatMap { faces[$0] == 1 ? $0 : nil }
        let t = HandScoring.score(faces, wild: wildIdx)
        gameLog("SCORE throw #\(g.throwCount): dice \(g.thrown) faces \(faces)\(wildIdx != nil ? " (gold die shows the WILD)" : "") -> \(t.points) [\(t.parts.joined(separator: ", "))]")
        if t.bust { bust(); return }

        g.phase = .scoring
        let scoringDice = t.scoring.map { g.thrown[$0] }
        for i in scoringDice { o.dice.setGlow(true, for: i) }
        snapshot("game-scoring-glow-\(g.throwCount)", after: 0.3)
        let pts = scoringDice.map { o.localPoint(fromScene: o.dice.position(of: $0)) }
        let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count) + 34)
        o.hud.floatText("+\(t.points)", at: c)
        g.turnTotal += t.points
        updatePill()
        gameLog("kept \(scoringDice) (+\(t.points)); turn total \(g.turnTotal)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let g = self.game, g.phase == .scoring, let o = self.overlay else { return }
            for i in scoringDice { o.dice.setGlow(false, for: i) }
            for i in scoringDice {
                let slot = g.kept.count
                g.kept.append(i)
                g.live.removeAll { $0 == i }
                g.pending.insert(i)
                o.dice.send(.slide(to: self.rowSlot(slot), face: g.faces[i], scale: Self.keptScale, duration: 0.42,
                                   park: true, name: "keep"), to: i)
            }
            g.lastThrow = (dice: g.thrown, result: t, keptFromIt: scoringDice)
        }
    }

    func gameScriptDone(_ i: Int, _ name: String, epoch: Int) {
        guard let g = game, let o = overlay else { return }
        guard epoch == o.dice.epoch(of: i) else { gameLog("script \(name) on die \(i) stale (epoch \(epoch))"); return }
        switch name {
        case "flip":
            g.flipsPending -= 1
            if g.flipsPending == 0 { scoreThrow() }
        case "keep", "unkeep", "back", "row":
            g.pending.remove(i)
            if g.pending.isEmpty { afterSlides() }
        case "shuffle":
            let s = o.sceneXY(fromCG: tilePoint())
            o.dice.send(.returnTo(SCNVector3(s.x, s.y, 0.6), duration: 0.15, style: .drop), to: i)
        default:
            break
        }
    }

    func afterSlides() {
        guard let g = game, let o = overlay else { return }
        switch g.phase {
        case .scoring:
            if HandScoring.isHotHand(keptTotal: g.kept.count) {
                g.hotHands += 1
                gameLog("HOT HAND: all five kept; all five come back into play, turn total \(g.turnTotal) carries on (banking still allowed)")
                sound.play("pop", volume: 0.35, detail: "hot hand: all five back")
                for (k, i) in g.kept.enumerated() {
                    let slot = rowSlot(k)
                    let to = SCNVector3(slot.x + CGFloat.random(in: -0.15...0.15), slot.y + 2.4 + CGFloat.random(in: 0...0.5), 0.5)
                    g.pending.insert(i)
                    o.dice.send(.slide(to: to, face: nil, scale: 1, duration: 0.45, park: false, name: "back"), to: i)
                }
                g.live = g.kept
                g.kept = []
                g.lastThrow = nil
                snapshot("game-hot-hand", after: 0.25)
                return
            }
            enterWaiting()
        case .waiting:
            enterWaiting()
        default:
            break
        }
    }

    func enterWaiting() {
        guard let g = game, let o = overlay else { return }
        g.phase = .waiting
        gameLog("waiting: live \(g.live), kept \(g.kept), turn \(g.turnTotal); grab to throw, right-click or drop on the Dock to bank")
        // Everything is at rest: pause rendering (the pill is Core Animation and needs none).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let g = self.game, g.phase == .waiting, g.pending.isEmpty else { return }
            o.playing = false
        }
        g.boredTimer?.invalidate()
        g.boredTimer = Timer.scheduledTimer(withTimeInterval: boredAfter, repeats: false) { [weak self] _ in
            guard let self, self.game?.phase == .waiting else { return }
            self.gameBank(reason: "bored: untouched for \(Int(self.boredAfter)) s", heldStyle: .shot)
        }
        snapshot("game-waiting-\(g.throwCount)-\(g.hotHands)", after: 0.7)
        if isDemo { demoGameNext(after: 1.3) }
    }

    // MARK: Hand back, bank, bust, end

    func gameHandBack(_ i: Int) {
        guard let g = game, let o = overlay, g.phase == .waiting else { gameLog("hand back of die \(i) ignored: not waiting"); return }
        guard let lt = g.lastThrow, let k = lt.dice.firstIndex(of: i), lt.keptFromIt.contains(i), g.kept.contains(i) else {
            gameLog("hand back of die \(i) refused: kept on an earlier throw (locked)")
            return
        }
        let still = lt.keptFromIt.filter { g.kept.contains($0) }.count
        guard HandScoring.canRelease(k, from: lt.result, stillKept: still) else {
            let why = lt.result.loose.contains(k) ? "it is the only die still kept from that throw" : "it is part of a set"
            gameLog("hand back of die \(i) refused: \(why)")
            return
        }
        let face = g.faces[i] ?? 0
        let val = HandScoring.singleValue((i == HandGame.special && face == 1) ? 1 : face)
        g.turnTotal -= val
        updatePill()
        let slotX = rowSlot(g.kept.firstIndex(of: i) ?? 0).x
        g.kept.removeAll { $0 == i }
        g.live.append(i)
        o.playing = true
        g.pending.insert(i)
        o.dice.send(.slide(to: SCNVector3(slotX, g.rowY + 2.3, 0.5), face: nil, scale: 1, duration: 0.4, park: false, name: "unkeep"), to: i)
        for (k2, j) in g.kept.enumerated() {
            g.pending.insert(j)
            o.dice.send(.slide(to: rowSlot(k2), face: g.faces[j], scale: Self.keptScale, duration: 0.3, park: true, name: "row"), to: j)
        }
        gameLog("HAND BACK die \(i) (\(face)\(i == HandGame.special && face == 1 ? ", wild as 1" : ""), -\(val)): turn \(g.turnTotal); live \(g.live)")
    }

    /// Right-click on any game die banks the turn. Returns true if it was on a die (swallow).
    func gameRightClick(_ p: CGPoint) -> Bool {
        guard let g = game, let i = gameHit(p, among: g.live + g.kept) else { return false }
        dlog("TAP right-down \(fmt(p)) SWALLOW: right-click on game die \(i) -> bank")
        if g.phase == .waiting || g.phase == .holding {
            gameBank(reason: "right-click on die \(i)", heldStyle: .shot)
        } else {
            gameLog("right-click while \(g.phase.rawValue): ignored")
        }
        return true
    }

    func gameBank(reason: String, heldStyle: DiceScene.ReturnStyle) {
        guard let g = game, g.phase != .ending else { return }
        if g.phase == .rolling || g.phase == .scoring { gameLog("banking mid-throw (\(g.phase.rawValue)): that throw is abandoned") }
        if g.turnTotal > 0 {
            bankedTotal += g.turnTotal
            gameLog("BANK \(g.turnTotal) (\(reason)) -> banked total \(bankedTotal)")
        } else {
            gameLog("BANK nothing (\(reason)): no points this turn; the dice go home")
        }
        let held = Set(g.live)
        let wasHolding = g.phase == .holding
        endTurn(kind: "bank") { i in (wasHolding && held.contains(i)) ? heldStyle : .shot }
    }

    func endTurn(kind: String, style: (Int) -> DiceScene.ReturnStyle) {
        guard let g = game, let o = overlay else { return }
        g.phase = .ending
        g.endKind = kind
        g.boredTimer?.invalidate()
        g.scoreCheck?.cancel()
        endHoldTracking()
        o.hud.hidePill()
        let target: CGPoint = kind == "trash" ? (dock.trashFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? tilePoint()) : tilePoint()
        let s = o.sceneXY(fromCG: target)
        show(o)
        var styles: [DiceScene.ReturnStyle] = []
        for i in 0..<DiceScene.maxDice {
            let st = style(i)
            styles.append(st)
            let from = o.dice.position(of: i)
            let dist = Double(hypot(s.x - from.x, s.y - from.y))
            let dur = st == .shot ? 0.25 + 0.10 * min(1, dist / 30) : (st == .trash ? 0.34 : 0.15)
            g.pending.insert(i)
            o.dice.send(.returnTo(SCNVector3(s.x, s.y, 0.6), duration: dur + Double(i) * 0.04, style: st), to: i)
        }
        returnStyle = styles.contains(.shot) ? .shot : (styles.first ?? .drop)
        gameLog("turn ends (\(kind)): dice head \(kind == "trash" ? "into the Trash" : "home") (\(styles.map(\.rawValue)))")
        snapshot("game-ending-\(kind)", after: 0.1)
    }

    func bust() {
        guard let g = game, let o = overlay else { return }
        g.phase = .ending
        g.endKind = "bust"
        gameLog("BUST: the throw scored nothing; turn total \(g.turnTotal) lost")
        for i in 0..<DiceScene.maxDice { o.dice.setDim(0.6, for: i) }
        sound.play("thunk", volume: 0.35, detail: "bust")
        if o.hud.pillVisible { o.hud.setPillValue(0, duration: 0.7) }
        g.turnTotal = 0
        snapshot("game-bust-slump", after: 0.55)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self, let g = self.game, let o = self.overlay, g.endKind == "bust" else { return }
            o.hud.hidePill()
            let tile = o.sceneXY(fromCG: self.tilePoint())
            for i in 0..<DiceScene.maxDice {
                g.pending.insert(i)
                o.dice.send(.shuffleHome(to: tile), to: i)
            }
            self.returnStyle = .drop
            self.gameLog("bust: dice shuffle home")
        }
    }

    func gameReturned(_ i: Int, epoch: Int) {
        guard let g = game, g.phase == .ending else { return }
        g.pending.remove(i)
        if g.pending.isEmpty { finishGame() }
    }

    func finishGame() {
        guard let g = game, let o = overlay else { return }
        let kind = g.endKind
        o.playing = false
        o.orderOut(nil)
        o.hud.hidePill()
        for i in 0..<DiceScene.maxDice {
            o.dice.setDim(1, for: i)
            o.dice.setGlow(false, for: i)
        }
        o.dice.wakeChecks = false
        o.dice.setSpecialDie(nil)
        o.dice.setPipStyle(.plain)
        game = nil
        appliedPalette = ""
        gameLog("over (\(kind)): banked total \(bankedTotal)")
        if kind == "trash" {
            setState(.trashed, "Hot Hand forfeited to the Trash; back in 5 s")
            trashTimer?.invalidate()
            trashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.restoreFromTrash("5 s elapsed")
            }
        } else {
            if kind == "bank" {
                if returnStyle == .shot { sound.play("bigThunk", volume: 0.5, detail: "Hot Hand dice land in the Dock") }
                else { sound.play("thunk", volume: 0.45, detail: "Hot Hand dice land in the Dock") }
            } else {
                sound.play("thunk", volume: 0.4, detail: "busted dice back in the Dock")
            }
            setState(.docked, "Hot Hand turn over (\(kind))")
        }
        refreshSkin("Hot Hand over")
        if isDemo { demoGameNext(after: 1.5) }
    }

    /// Screen change mid-game: bank what the turn holds, hide everything, no animation.
    func gameAbortForScreenChange() {
        guard let g = game, let o = overlay else { return }
        if g.turnTotal > 0 {
            bankedTotal += g.turnTotal
            gameLog("screens changed: banked \(g.turnTotal) -> \(bankedTotal)")
        }
        g.boredTimer?.invalidate()
        for i in 0..<DiceScene.maxDice {
            o.dice.send(.hideNow, to: i)
            o.dice.setDim(1, for: i)
            o.dice.setGlow(false, for: i)
        }
        o.hud.hidePill()
        o.dice.wakeChecks = false
        o.dice.setSpecialDie(nil)
        o.dice.setPipStyle(.plain)
        game = nil
    }

    // MARK: Demo (DEMO-ONLY): a full game walkthrough through the real handlers

    func demoGameStart() {
        gameLog("DEMO game walkthrough begins (all forcing below is DEMO-ONLY)")
        demoGameQueue = [
            ("Option-pull, first throw forced 1,5,3,4,2 (150: a 1 and a 5)", { [weak self] in
                self?.demoOptionPullAndThrow(force: [0: 1, 1: 5, 2: 3, 3: 4, 4: 2]) }),
            ("click the kept 5 to hand it back", { [weak self] in self?.demoClickKept(face: 5) }),
            ("second throw forced to three 3s and a 6", { [weak self] in
                self?.demoThrowLive(force: [1: 6, 2: 3, 3: 3, 4: 3]) }),
            ("bank by right-click on a die", { [weak self] in self?.demoRightClickDie() }),
            ("Option-pull, throw forced to a bust 2,3,4,6,2", { [weak self] in
                self?.demoOptionPullAndThrow(force: [0: 2, 1: 3, 2: 4, 3: 6, 4: 2]) }),
            ("Option-pull, throw forced 1,1,1,5,5 (hot hand)", { [weak self] in
                self?.demoOptionPullAndThrow(force: [0: 1, 1: 1, 2: 1, 3: 5, 4: 5]) }),
            ("throw again: gold wild + a pair of 4s", { [weak self] in
                self?.demoThrowLive(force: [4: 1, 0: 4, 1: 4, 2: 2, 3: 3]) }),
            ("bank by dropping the handful on the Dock", { [weak self] in self?.demoDropHandOnDock() }),
        ]
        demoGameNext(after: 0.5)
    }

    func demoGameNext(after delay: TimeInterval) {
        guard isDemo else { return }
        guard !demoGameQueue.isEmpty else {
            if demoGameRunning {
                demoGameRunning = false
                gameLog("DEMO game walkthrough complete: banked total \(bankedTotal)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    if self?.state == .docked { self?.popOut(reason: "demo after game") }
                }
            }
            return
        }
        demoGameRunning = true
        let (label, action) = demoGameQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.gameLog("DEMO step: \(label)")
            action()
        }
    }

    private func demoScreen() -> CGRect { Coords.cgRect(fromAppKit: dockScreen().frame) }

    func demoOptionPullAndThrow(force: [Int: Int]) {
        let screen = demoScreen()
        let tileX = dock.tileFrame?.midX ?? screen.midX
        let start = CGPoint(x: tileX, y: screen.maxY - 6)
        let mid = CGPoint(x: tileX - 140, y: screen.maxY - 330)
        let dir = CGVector(dx: -0.55, dy: -0.83)
        demoPendingForce = force
        demoForceTileHit = true
        demoDrag("option-pull", from: start, duration: 0.8, pause: 0, downFlags: .maskAlternate, dragFlags: .maskAlternate) { t in
            if t < 0.5 {
                let k = CGFloat(t / 0.5), e = k * k * (3 - 2 * k)
                return CGPoint(x: start.x + (mid.x - start.x) * e, y: start.y + (mid.y - start.y) * e)
            }
            let u = CGFloat(t - 0.5)
            return CGPoint(x: mid.x + dir.dx * 1700 * u, y: mid.y + dir.dy * 1700 * u)
        }
        demoForceTileHit = false
        snapshot("game-handful", after: 0.4)
    }

    func demoThrowLive(force: [Int: Int]) {
        guard let g = game, let i = g.live.first, let o = overlay else { return }
        let from = o.dieCircle(i).center
        let screen = demoScreen()
        let c = CGPoint(x: screen.midX, y: screen.midY)
        let d = hypot(c.x - from.x, c.y - from.y)
        let dir = CGVector(dx: (c.x - from.x) / max(d, 1), dy: (c.y - from.y) / max(d, 1))
        demoPendingForce = force
        demoDrag("game-throw", from: from, duration: 0.35, pause: 0) { t in
            let w = min(1, t / 0.12)
            return CGPoint(x: from.x + dir.dx * 1500 * CGFloat(t) * w, y: from.y + dir.dy * 1500 * CGFloat(t) * w)
        }
    }

    func demoClickKept(face: Int) {
        guard let g = game, let o = overlay, let i = g.kept.first(where: { g.faces[$0] == face }) else {
            gameLog("DEMO: no kept die showing \(face)")
            return
        }
        let p = o.dieCircle(i).center
        let d1 = inject(.leftMouseDown, p), d2 = inject(.leftMouseUp, p)
        gameLog("DEMO: clicked kept die \(i) (\(face)) at \(fmt(p)): \(describe(d1)) / \(describe(d2))")
    }

    func demoRightClickDie() {
        guard let g = game, let o = overlay, let i = g.kept.first ?? g.live.first else { return }
        let p = o.dieCircle(i).center
        let d1 = inject(.rightMouseDown, p), d2 = inject(.rightMouseUp, p)
        gameLog("DEMO: right-clicked die \(i) at \(fmt(p)): \(describe(d1)) / \(describe(d2))")
    }

    func demoDropHandOnDock() {
        guard let g = game, let i = g.live.first, let o = overlay else { return }
        let from = o.dieCircle(i).center
        let screen = demoScreen()
        let tileX = dock.tileFrame?.midX ?? screen.midX
        let target = CGPoint(x: max(screen.minX + 120, tileX - 220), y: screen.maxY - 8)
        demoDrag("game-dock-drop", from: from, duration: 0.6, pause: 0.35) { t in
            let k = CGFloat(min(1, t / 0.5)), e = k * k * (3 - 2 * k)
            return CGPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e)
        }
        snapshot("game-cue-dock-drop", after: 0.75)
    }
}
