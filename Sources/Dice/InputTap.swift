import CoreGraphics
import Foundation

enum TapDecision {
    case pass
    case swallow
    /// Let it through, but rewritten to another type (used to show the Dock ordinary cursor motion).
    case passAs(CGEventType)
}

protocol InputTapHandler: AnyObject {
    /// Called on the main thread for left mouse down/dragged/up and right mouse down/up.
    /// `location` is global, top-left origin (CG/AX space).
    /// `time` is the event's own timestamp converted to the ProcessInfo.systemUptime clock.
    /// `flags` are the event's modifier flags (Option at mouse-up loads the die).
    func handleTapEvent(_ type: CGEventType, at location: CGPoint, time: TimeInterval, flags: CGEventFlags) -> TapDecision
}

/// The one CGEventTap. Session level, head insert, active (can swallow). Left-button events, plus
/// right down/up so a right-click on the die can recall it; every other right-click passes untouched.
final class InputTap {
    weak var handler: InputTapHandler?
    private(set) var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var disableCount = 0

    var isInstalled: Bool { port != nil }
    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Returns true if the tap exists after the call.
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: inputTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        port = p
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        dlog("TAP created: session tap, head insert, default (active); enabled=\(CGEvent.tapIsEnabled(tap: p))")
        return true
    }

    /// Re-enable if the system turned us off. Called from the retry timer as a safety net.
    func ensureEnabled() {
        guard let p = port, !CGEvent.tapIsEnabled(tap: p) else { return }
        CGEvent.tapEnable(tap: p, enable: true)
        dlog("TAP was disabled (found by timer); re-enabled -> \(CGEvent.tapIsEnabled(tap: p))")
    }

    /// CGEventTimestamp is documented as nanoseconds but has been mach ticks on some systems.
    /// Pick whichever reading lands near systemUptime; log the choice once.
    private var timeUnit: Double?
    private func eventTime(_ e: CGEvent) -> TimeInterval {
        let raw = Double(e.timestamp)
        let now = ProcessInfo.processInfo.systemUptime
        if timeUnit == nil {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let ticks = Double(tb.numer) / Double(tb.denom) / 1e9
            let asNs = raw / 1e9, asTicks = raw * ticks
            timeUnit = abs(asNs - now) <= abs(asTicks - now) ? 1e-9 : ticks
            dlog(String(format: "TAP event timestamp units: %@ (as ns %.3f, as ticks %.3f, uptime %.3f)",
                        timeUnit == 1e-9 ? "nanoseconds" : "mach ticks", asNs, asTicks, now))
        }
        let t = raw * timeUnit!
        return abs(t - now) < 1 ? t : now     // never trust a wild value
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            disableCount += 1
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            dlog("TAP disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") (#\(disableCount)); re-enabled")
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            guard let handler else { return Unmanaged.passUnretained(event) }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let decision = handler.handleTapEvent(type, at: event.location, time: eventTime(event), flags: event.flags)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if ms > 30 { dlog("TAP WARNING: handler took \(String(format: "%.1f", ms)) ms for \(type.name)") }
            switch decision {
            case .pass: return Unmanaged.passUnretained(event)
            case .swallow: return nil
            case let .passAs(newType):
                event.type = newType
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

extension CGEventType {
    var name: String {
        switch self {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseDragged: return "leftMouseDragged"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .mouseMoved: return "mouseMoved"
        case .tapDisabledByTimeout: return "tapDisabledByTimeout"
        case .tapDisabledByUserInput: return "tapDisabledByUserInput"
        default: return "type\(rawValue)"
        }
    }
}
