import AppKit

/// A listen-only event tap. Unlike NSEvent global monitors it also sees events
/// over this app's own windows, such as the expanded section dividers.
@MainActor
final class EventTap {
    typealias Handler = @MainActor (CGEventType, CGEvent) -> Void

    private let mask: CGEventMask
    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallbackMonitor: Any?

    init(types: [CGEventType], handler: @escaping Handler) {
        self.mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        self.handler = handler
    }

    func start() {
        guard tap == nil, fallbackMonitor == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated {
                    me.receive(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )
        if let tap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            self.source = source
        } else {
            // Without permission for a tap, fall back to a global monitor.
            let eventMask = NSEvent.EventTypeMask(rawValue: UInt64(mask))
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
                guard let cgEvent = event.cgEvent else { return }
                MainActor.assumeIsolated {
                    self?.handler(cgEvent.type, cgEvent)
                }
            }
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
        }
        tap = nil
        source = nil
        fallbackMonitor = nil
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        handler(type, event)
    }
}
