import AppKit
import ApplicationServices

/// The one place coordinates are converted. Event and AX coordinates are global with a top-left
/// origin at the primary screen's top-left ("CG space"). AppKit is bottom-left ("AppKit space").
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func appKit(fromCG p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static func cg(fromAppKit p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Dock preferences (readable without any permission).
struct DockPrefs {
    var tileSize: CGFloat = 64
    var magnification = false
    var largeSize: CGFloat = 64
    var orientation = "bottom"
    var autohide = false

    static func read() -> DockPrefs {
        var p = DockPrefs()
        let app = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(app)
        if let v = CFPreferencesCopyAppValue("tilesize" as CFString, app) as? NSNumber { p.tileSize = CGFloat(v.doubleValue) }
        if let v = CFPreferencesCopyAppValue("magnification" as CFString, app) as? NSNumber { p.magnification = v.boolValue }
        if let v = CFPreferencesCopyAppValue("largesize" as CFString, app) as? NSNumber { p.largeSize = CGFloat(v.doubleValue) }
        if let v = CFPreferencesCopyAppValue("orientation" as CFString, app) as? String { p.orientation = v }
        if let v = CFPreferencesCopyAppValue("autohide" as CFString, app) as? NSNumber { p.autohide = v.boolValue }
        return p
    }
}

extension AXError {
    var name: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete(timeout/IPC)"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled(not trusted)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(rawValue))"
        }
    }
}

/// Accessibility queries against the Dock. All results are in CG space.
final class DockLocator {
    struct Hit {
        let isOurs: Bool
        let detail: String
    }

    private var app: AXUIElement?
    private var pid: pid_t = 0
    private var tileElement: AXUIElement?
    private var lastSummary = ""
    private var dumpedTree = false

    /// Frame of the Dock's AXList, inflated for magnification. nil when unknown.
    private(set) var stripRect: CGRect?
    /// Frame of our Dock item. nil when unknown.
    private(set) var tileFrame: CGRect?
    /// Raw (uninflated) frame of the Dock's AXList. Off-screen when an autohidden Dock is hidden.
    private(set) var listFrame: CGRect?
    private var listElement: AXUIElement?
    /// Frame of the Dock's Trash item (subrole AXTrashDockItem). nil when unknown.
    private(set) var trashFrame: CGRect?
    private var trashElement: AXUIElement?
    /// Demo only: geometry injected because AX is not trusted. Real AX data replaces it once trusted.
    private(set) var simulated = false
    private(set) var prefs = DockPrefs.read()

    let ourURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let ourName = "Dice"

    // MARK: AX plumbing

    private func dockApplication() -> AXUIElement? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            if app != nil || pid != -1 { dlog("DOCK: com.apple.dock is not running") }
            app = nil; pid = -1
            return nil
        }
        if app == nil || running.processIdentifier != pid {
            pid = running.processIdentifier
            let a = AXUIElementCreateApplication(pid)
            let err = AXUIElementSetMessagingTimeout(a, 0.2)
            app = a
            tileElement = nil
            dlog("DOCK: pid \(pid); AX app element created; messaging timeout 0.2 s -> \(err.name)")
        }
        return app
    }

    private func attr(_ e: AXUIElement, _ name: String) -> (AnyObject?, AXError) {
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return (err == .success ? v : nil, err)
    }

    private func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name).0 as? String }

    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute).0, let sv = attr(e, kAXSizeAttribute).0,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private func children(_ e: AXUIElement) -> ([AXUIElement], AXError) {
        let (v, err) = attr(e, kAXChildrenAttribute)
        return ((v as? [AXUIElement]) ?? [], err)
    }

    private func urlPath(_ e: AXUIElement) -> String? {
        guard let v = attr(e, kAXURLAttribute).0 else { return nil }
        if let u = v as? URL { return u.resolvingSymlinksInPath().standardizedFileURL.path }
        if let s = v as? String, let u = URL(string: s) { return u.resolvingSymlinksInPath().standardizedFileURL.path }
        return nil
    }

    private func describe(_ e: AXUIElement) -> String {
        let role = string(e, kAXRoleAttribute) ?? "?"
        let sub = string(e, kAXSubroleAttribute) ?? "-"
        let title = string(e, kAXTitleAttribute) ?? "-"
        let url = urlPath(e) ?? "noAXURL"
        return "role=\(role) subrole=\(sub) title=\"\(title)\" url=\(url)"
    }

    /// Is this element our Dock item? Primary test is AXURL against our bundle URL; fallback AXTitle.
    private func matchesUs(_ e: AXUIElement) -> (Bool, String) {
        let ourPath = ourURL.path
        if let path = urlPath(e) {
            let a = path.hasSuffix("/") ? String(path.dropLast()) : path
            let b = ourPath.hasSuffix("/") ? String(ourPath.dropLast()) : ourPath
            return (a == b, a == b ? "AXURL matches our bundle" : "AXURL \(a) != ours \(b)")
        }
        let title = string(e, kAXTitleAttribute)
        if title == ourName { return (true, "no AXURL; AXTitle == \"\(ourName)\" (fallback)") }
        return (false, "no AXURL; AXTitle \"\(title ?? "nil")\" != \"\(ourName)\"")
    }

    // MARK: Public

    /// Refresh the strip rect and our tile frame. Cheap enough for a 2 s timer.
    func refresh(reason: String) {
        prefs = DockPrefs.read()
        if simulated && !AXIsProcessTrusted() { return }
        simulated = false
        guard AXIsProcessTrusted() else {
            stripRect = nil; tileFrame = nil; tileElement = nil; listFrame = nil; listElement = nil
            summarize("AX not trusted: Dock strip and tile frame unknown (prefs tilesize=\(Int(prefs.tileSize)) orientation=\(prefs.orientation))", reason)
            return
        }
        guard let app = dockApplication() else { stripRect = nil; tileFrame = nil; return }
        let (kids, err) = children(app)
        guard err == .success else {
            stripRect = nil; tileFrame = nil
            summarize("Dock AXChildren failed: \(err.name)", reason)
            return
        }
        guard let list = kids.first(where: { string($0, kAXRoleAttribute) == (kAXListRole as String) }) else {
            stripRect = nil; tileFrame = nil
            summarize("no AXList among Dock children: [\(kids.map { string($0, kAXRoleAttribute) ?? "?" }.joined(separator: ", "))]", reason)
            return
        }
        guard let listFrame = frame(list) else {
            stripRect = nil; tileFrame = nil
            summarize("AXList has no frame", reason)
            return
        }
        stripRect = inflate(listFrame)
        self.listFrame = listFrame
        listElement = list

        let (items, _) = children(list)
        if !dumpedTree {
            dumpedTree = true
            dlog("DOCK TREE: AXList frame=\(fmt(listFrame)) items=\(items.count)")
            for (i, it) in items.enumerated() {
                dlog("DOCK TREE:   [\(i)] \(describe(it)) frame=\(frame(it).map(fmt) ?? "nil")")
            }
        }
        var found: AXUIElement?
        var why = "no item matched"
        for it in items {
            let (ours, w) = matchesUs(it)
            if ours { found = it; why = w; break }
        }
        tileElement = found
        tileFrame = found.flatMap(frame)
        trashElement = items.first { string($0, kAXSubroleAttribute) == "AXTrashDockItem" }
        trashFrame = trashElement.flatMap(frame)
        if let found, !dumpedOurs {
            dumpedOurs = true
            var names: CFArray?
            AXUIElementCopyAttributeNames(found, &names)
            dlog("DOCK TREE: our item \(describe(found)); attributes: \((names as? [String])?.joined(separator: ",") ?? "?")")
        }
        summarize("strip=\(fmt(stripRect!)) (list \(fmt(listFrame))) items=\(items.count) ourTile=\(tileFrame.map(fmt) ?? "NOT FOUND") [\(why)] trash=\(trashFrame.map(fmt) ?? "not found")", reason)
    }
    private var dumpedOurs = false

    /// Re-query only our item's frame (used while the die is held: magnification moves it).
    func refreshTileFrame() {
        guard AXIsProcessTrusted() else { return }
        if simulated { refresh(reason: "AX became trusted; dropping simulated geometry"); return }
        if let el = tileElement, let f = frame(el) {
            if f != tileFrame { tileFrame = f }
            if let le = listElement, let lf = frame(le), lf != listFrame {
                listFrame = lf
                stripRect = inflate(lf)
            }
            if let te = trashElement, let tf = frame(te) { trashFrame = tf }
        } else {
            refresh(reason: "tile frame re-query")
        }
    }

    /// Element under the point: is it our Dock tile? One AX round trip (bounded by the 0.2 s timeout).
    func hitTest(_ p: CGPoint) -> Hit {
        guard let app = dockApplication() else { return Hit(isOurs: false, detail: "Dock not running") }
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el)
        guard err == .success, var e = el else {
            return Hit(isOurs: false, detail: "AXUIElementCopyElementAtPosition -> \(err.name)")
        }
        // Climb to the AXDockItem if the hit landed on a sub-element.
        var hops = 0
        while string(e, kAXRoleAttribute) != (kAXDockItemRole as String), hops < 3 {
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success,
                  let pe = parent, CFGetTypeID(pe) == AXUIElementGetTypeID() else { break }
            e = pe as! AXUIElement
            hops += 1
        }
        let (ours, why) = matchesUs(e)
        if ours {
            tileElement = e
            if let f = frame(e) { tileFrame = f }
        }
        return Hit(isOurs: ours, detail: "\(describe(e)) hops=\(hops) -> \(why)")
    }

    /// Demo mode without AX: use the user's real hidden-Dock geometry so the drop-zone path runs.
    func simulate(list: CGRect, tile: CGRect, trash: CGRect, reason: String) {
        simulated = true
        listFrame = list
        stripRect = inflate(list)
        tileFrame = tile
        trashFrame = trash
        dlog("DOCK SIMULATED (\(reason)): list=\(fmt(list)) strip=\(fmt(stripRect!)) tile=\(fmt(tile)) trash=\(fmt(trash))")
    }

    private func inflate(_ r: CGRect) -> CGRect {
        var out = r.insetBy(dx: -8, dy: -8)
        if prefs.magnification {
            let extra = max(0, prefs.largeSize - prefs.tileSize)
            switch prefs.orientation {
            case "left": out.size.width += extra
            case "right": out.origin.x -= extra; out.size.width += extra
            default: out.origin.y -= extra; out.size.height += extra
            }
        }
        return out
    }

    private func summarize(_ s: String, _ reason: String) {
        if s != lastSummary {
            lastSummary = s
            dlog("DOCK (\(reason)): \(s)")
        }
    }
}

func fmt(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}

func fmt(_ p: CGPoint) -> String {
    String(format: "(%.0f,%.0f)", p.x, p.y)
}

/// Where a released die counts as "dropped on the Dock". Pure geometry in CG space, so it can be
/// self-checked. Two parts:
///  - the Dock strip, when the Dock is actually showing;
///  - a band along the Dock's screen edge, across the strip's extent plus one tile each side,
///    which works even when an autohidden Dock never slides in (we swallow the drags it would see).
struct DropZone {
    static let bandDepth: CGFloat = 40

    let screen: CGRect        // Dock screen, CG space
    let orientation: String   // "bottom" | "left" | "right"
    let list: CGRect?         // raw AXList frame
    let strip: CGRect?        // inflated strip
    let tileSize: CGFloat
    var trash: CGRect? = nil

    enum Kind: String { case none, dock, trash }

    var dockShowing: Bool {
        guard let l = list else { return false }
        switch orientation {
        case "left": return l.maxX > screen.minX + l.width * 0.5
        case "right": return l.minX < screen.maxX - l.width * 0.5
        default: return l.minY < screen.maxY - l.height * 0.5
        }
    }

    var band: CGRect {
        let d = Self.bandDepth
        switch orientation {
        case "left", "right":
            let lo = list.map { $0.minY - tileSize } ?? screen.minY
            let hi = list.map { $0.maxY + tileSize } ?? screen.maxY
            let x = orientation == "left" ? screen.minX : screen.maxX - d
            return CGRect(x: x, y: lo, width: d, height: hi - lo).intersection(screen)
        default:
            let lo = list.map { $0.minX - tileSize } ?? screen.minX
            let hi = list.map { $0.maxX + tileSize } ?? screen.maxX
            return CGRect(x: lo, y: screen.maxY - d, width: hi - lo, height: d).intersection(screen)
        }
    }

    /// Trash first (it takes priority), then the general Dock drop zone.
    func classify(_ p: CGPoint) -> (kind: Kind, why: String) {
        if let t = trash {
            if dockShowing, t.insetBy(dx: -6, dy: -6).contains(p) { return (.trash, "over the shown Trash \(fmt(t))") }
            let b = band
            let alongEdge: Bool
            switch orientation {
            case "left", "right": alongEdge = p.y >= t.minY && p.y <= t.maxY
            default: alongEdge = p.x >= t.minX && p.x <= t.maxX
            }
            if b.contains(p), alongEdge { return (.trash, "in the edge band within the Trash's span \(fmt(t)) (Dock \(dockShowing ? "shown" : "hidden"))") }
        }
        let c = check(p)
        return (c.inside ? .dock : .none, c.why)
    }

    func check(_ p: CGPoint) -> (inside: Bool, why: String) {
        let shown = dockShowing
        if shown, let s = strip, s.contains(p) { return (true, "over the shown Dock strip \(fmt(s))") }
        let b = band
        if b.contains(p) { return (true, "in the Dock edge band \(fmt(b)) (Dock \(shown ? "shown" : "hidden"))") }
        return (false, "outside drop zone: band \(fmt(b)), Dock \(shown ? "shown, strip \(strip.map(fmt) ?? "-")" : "hidden")")
    }

    /// Launch self-check against frames recorded on a real screen (1710x1107, Dock bottom,
    /// autohide) plus mirrored left/right Docks.
    static func selfCheck() -> (ok: Bool, lines: [String]) {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        func inflate(_ r: CGRect) -> CGRect { r.insetBy(dx: -8, dy: -8) }
        let hidden = CGRect(x: 340, y: 1107, width: 1030, height: 61)   // strip (332,1099 1046x77)
        let shown = CGRect(x: 340, y: 1048, width: 1030, height: 61)    // strip (332,1040 1046x77)
        let leftHidden = CGRect(x: -61, y: 300, width: 61, height: 500)
        let leftShown = CGRect(x: 0, y: 300, width: 61, height: 500)
        let rightHidden = CGRect(x: 1710, y: 300, width: 61, height: 500)
        let cases: [(String, String, CGRect, CGPoint, Bool)] = [
            ("bottom hidden, at our tile's x near edge", "bottom", hidden, CGPoint(x: 1222, y: 1100), true),
            ("bottom hidden, very bottom pixel", "bottom", hidden, CGPoint(x: 1222, y: 1106), true),
            ("bottom hidden, 47 pt above edge", "bottom", hidden, CGPoint(x: 1222, y: 1060), false),
            ("bottom hidden, within one tile past left end", "bottom", hidden, CGPoint(x: 300, y: 1100), true),
            ("bottom hidden, beyond left end", "bottom", hidden, CGPoint(x: 200, y: 1100), false),
            ("bottom shown, over another app's icon", "bottom", shown, CGPoint(x: 600, y: 1060), true),
            ("bottom shown, above the strip", "bottom", shown, CGPoint(x: 1222, y: 1000), false),
            ("left hidden, at edge", "left", leftHidden, CGPoint(x: 10, y: 500), true),
            ("left hidden, outside list span", "left", leftHidden, CGPoint(x: 10, y: 100), false),
            ("left hidden, 60 pt in", "left", leftHidden, CGPoint(x: 60, y: 500), false),
            ("left shown, over strip", "left", leftShown, CGPoint(x: 55, y: 500), true),
            ("right hidden, at edge", "right", rightHidden, CGPoint(x: 1705, y: 500), true),
            ("right hidden, 110 pt in", "right", rightHidden, CGPoint(x: 1600, y: 500), false),
        ]
        var ok = true
        var lines: [String] = []
        // Trash cases: hidden Trash (1318,1107 49x61), shown (1318,1048 49x61).
        let trashCases: [(String, CGRect, CGRect, CGPoint, Kind)] = [
            ("bottom hidden, under the Trash", hidden, CGRect(x: 1318, y: 1107, width: 49, height: 61), CGPoint(x: 1340, y: 1100), .trash),
            ("bottom hidden, under our tile (not Trash)", hidden, CGRect(x: 1318, y: 1107, width: 49, height: 61), CGPoint(x: 1222, y: 1100), .dock),
            ("bottom shown, over the Trash", shown, CGRect(x: 1318, y: 1048, width: 49, height: 61), CGPoint(x: 1340, y: 1075), .trash),
            ("bottom hidden, above band under Trash x", hidden, CGRect(x: 1318, y: 1107, width: 49, height: 61), CGPoint(x: 1340, y: 1050), .none),
        ]
        for (name, list, t, p, want) in trashCases {
            var z = DropZone(screen: screen, orientation: "bottom", list: list, strip: inflate(list), tileSize: 49)
            z.trash = t
            let got = z.classify(p)
            if got.kind != want { ok = false }
            lines.append("\(got.kind == want ? "ok  " : "FAIL") \(name) \(fmt(p)) -> \(got.kind.rawValue) [\(got.why)]")
        }
        for (name, o, list, p, want) in cases {
            let z = DropZone(screen: screen, orientation: o, list: list, strip: inflate(list), tileSize: 49)
            let got = z.check(p)
            if got.inside != want { ok = false }
            lines.append("\(got.inside == want ? "ok  " : "FAIL") \(name) \(fmt(p)) -> \(got.inside) [\(got.why)]")
        }
        return (ok, lines)
    }
}
