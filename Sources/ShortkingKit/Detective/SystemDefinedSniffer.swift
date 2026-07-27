import AppKit
import CoreGraphics
import Foundation

/// Live, named attribution at press time.
///
/// When WindowServer matches a Carbon hotkey it posts an `NSSystemDefined`
/// (`NX_SYSDEFINED`, type 14) event **to the registering process**, with
/// `subtype == 6` for key down, `9` for key up, and the hotkey identifier in
/// `data1`. Attaching a listen-only per-pid tap to each suspect and pressing the key
/// therefore names the owner outright: exactly one process receives it.
///
/// Because `data1` is the malloc'd `HotButtonData` pointer, it is a stable
/// per-registration identity for that process's lifetime — which is what lets
/// Shortking distinguish "Raycast has three hotkeys" from "Raycast has one".
///
/// Two constraints shape the design: this needs Input Monitoring and cannot work
/// under App Sandbox, and N taps for N processes is heavy. So it is an on-demand,
/// time-bounded capture over a *suspect set*, never an always-on watch over every
/// running process.
public final class SystemDefinedSniffer {

    /// One observed hotkey delivery.
    public struct Delivery: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var pid: Int32
        public var ownerName: String
        public var bundleID: String?
        /// 6 = key down, 9 = key up.
        public var subtype: Int
        /// The registration identity — the pointer WindowServer hands back.
        public var hotKeyID: Int
        public var receivedAt: Date

        public var isKeyDown: Bool { subtype == SystemDefinedSniffer.hotKeyDownSubtype }
    }

    /// `NX_SYSDEFINED`. Not exposed as a `CGEventType` case, so it is spelled out.
    public static let systemDefinedRawType: UInt32 = 14
    public static let hotKeyDownSubtype = 6
    public static let hotKeyUpSubtype = 9

    private struct Attachment {
        var port: CFMachPort
        var source: CFRunLoopSource
        var context: Unmanaged<SnifferContext>
    }

    private var attachments: [Int32: Attachment] = [:]
    public private(set) var isCapturing = false

    public init() {}

    deinit {
        // Skipping this would leak a Mach port and a run-loop source per tapped
        // process for the life of the app.
        teardown()
    }

    /// The processes worth tapping.
    ///
    /// Tapping every running process would be both slow and rude. The suspect set is
    /// the union of: processes with a key-related event tap, processes whose
    /// binaries import hotkey-registration symbols, and the frontmost app.
    public static func suspects(
        eventTaps: [EventTapInfo],
        capabilityClaims: [Claim],
        runningApps: [RunningApp]
    ) -> [RunningApp] {
        var pids = Set<Int32>()

        for tap in eventTaps where EventTapScanner.masksKeyEvents(tap.eventMask) {
            pids.insert(tap.tappingPID)
        }

        var bundleIDs = Set<String>()
        for claim in capabilityClaims where claim.status == .capability {
            if let bundleID = claim.owner?.bundleID { bundleIDs.insert(bundleID) }
            if let pid = claim.owner?.pid { pids.insert(pid) }
        }

        return runningApps.filter { app in
            if pids.contains(app.pid) { return true }
            if let bundleID = app.bundleID, bundleIDs.contains(bundleID) { return true }
            return app.isActive
        }
    }

    /// Attaches listen-only taps to each app and calls `onDelivery` on the main
    /// queue whenever one of them receives a hotkey delivery.
    ///
    /// Returns the pids successfully tapped. An individual pid refusing a tap is not
    /// an error — some processes cannot be tapped — but if *nothing* can be tapped,
    /// Input Monitoring is missing and the caller should say so rather than showing
    /// an empty result.
    @discardableResult
    public func start(
        apps: [RunningApp],
        onDelivery: @escaping (Delivery) -> Void
    ) -> [Int32] {
        stop()

        var attached: [Int32] = []
        let mask = CGEventMask(EventTapScanner.systemDefinedMask)

        for app in apps {
            let context = SnifferContext(
                pid: app.pid,
                ownerName: app.name,
                bundleID: app.bundleID,
                handler: onDelivery
            )
            let boxed = Unmanaged.passRetained(context)

            guard let port = CGEvent.tapCreateForPid(
                pid: pid_t(app.pid),
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: shortkingSniffCallback,
                userInfo: boxed.toOpaque()
            ) else {
                boxed.release()
                continue
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                boxed.release()
                continue
            }

            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            attachments[app.pid] = Attachment(port: port, source: source, context: boxed)
            attached.append(app.pid)
        }

        isCapturing = !attached.isEmpty
        Log.detective.info("systemDefined sniffer attached to \(attached.count) processes")
        return attached
    }

    public func stop() {
        teardown()
        isCapturing = false
    }

    private func teardown() {
        for (_, attachment) in attachments {
            CGEvent.tapEnable(tap: attachment.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), attachment.source, .commonModes)
            CFMachPortInvalidate(attachment.port)
            attachment.context.release()
        }
        attachments = [:]
    }
}

/// The per-tap box handed to the C callback through `userInfo`.
final class SnifferContext {
    let pid: Int32
    let ownerName: String
    let bundleID: String?
    let handler: (SystemDefinedSniffer.Delivery) -> Void

    init(
        pid: Int32,
        ownerName: String,
        bundleID: String?,
        handler: @escaping (SystemDefinedSniffer.Delivery) -> Void
    ) {
        self.pid = pid
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.handler = handler
    }

    func handle(event: CGEvent) {
        // Reading `.subtype` on an event that is not system-defined raises, so this
        // guard is load-bearing rather than defensive style.
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined else { return }

        let subtype = Int(nsEvent.subtype.rawValue)
        guard subtype == SystemDefinedSniffer.hotKeyDownSubtype
            || subtype == SystemDefinedSniffer.hotKeyUpSubtype else { return }

        let delivery = SystemDefinedSniffer.Delivery(
            pid: pid,
            ownerName: ownerName,
            bundleID: bundleID,
            subtype: subtype,
            hotKeyID: nsEvent.data1,
            receivedAt: Date()
        )

        let handler = self.handler
        DispatchQueue.main.async { handler(delivery) }
    }
}

/// The C callback. Listen-only, so the event is always passed through unchanged.
private func shortkingSniffCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    if type.rawValue == SystemDefinedSniffer.systemDefinedRawType {
        let context = Unmanaged<SnifferContext>.fromOpaque(userInfo).takeUnretainedValue()
        context.handle(event: event)
    }

    return Unmanaged.passUnretained(event)
}
