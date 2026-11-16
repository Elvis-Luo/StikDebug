//
//  CellularWindow.swift
//  StikDebug
//
//  Enabling JIT on cellular, app side. Off unless turned on in Settings. When a JIT request comes in
//  and the only network is cellular, StikDebug runs the user's Airplane Mode shortcut (Airplane Mode
//  on, a second, off) and connects in the seconds after Airplane Mode turns off, when the RemotePairing
//  service accepts connections over the VPN tunnel. It opens all the tunnels the request needs at that
//  moment (CellularWindowCore.swift decides; this file supplies NWPathMonitor, a TCP probe, the
//  Shortcuts URL and the idevice tunnels). Steps are logged with the prefix [cellular-window].
//

import Darwin
import Foundation
import Network
import UIKit

final class CellularWindow {
    static let shared = CellularWindow()

    static let enabledKey = "cellularAirplaneWindow"
    static let shortcutNameKey = "cellularAirplaneShortcutName"
    static let defaultShortcutName = "StikDebug Airplane Mode"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var shortcutName: String {
        let name = (UserDefaults.standard.string(forKey: shortcutNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultShortcutName : name
    }

    /// External JIT requests by app: duplicates, and whether a failure alert should show.
    let registry = RequestRegistry()

    /// Windows run one at a time on this queue (Airplane Mode is one switch).
    private let queue = DispatchQueue(label: "com.stik.cellular-window", qos: .userInitiated)
    private let environment = AppWindowEnvironment()
    private lazy var engine = CellularWindowEngine(env: environment)
    private let lock = NSLock()
    private var waiting = 0
    private var hintShown = false

    static func log(_ message: String) {
        LogManager.shared.addInfoLog("[cellular-window] \(message)")
    }

    /// Runs this request's window if it needs one; calls back on the main queue once the request can go on.
    func run(request: String, completion: @escaping (WindowOutcome) -> Void) {
        lock.lock()
        waiting += 1
        let ahead = waiting - 1
        lock.unlock()
        if ahead > 0 {
            Self.log("[\(request.prefix(8))] waiting for \(ahead) earlier window(s) to finish")
        }
        queue.async {
            // Keeps StikDebug running while Shortcuts is in front.
            let lease = DebugKeepAliveLease()
            let outcome = self.engine.run(request: request)
            lease.invalidate()
            self.lock.lock()
            self.waiting -= 1
            self.lock.unlock()
            Self.log("[\(request.prefix(8))] outcome: \(outcome)")
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// From stikjit://cellular-window (x-success) or stikjit://cellular-window-failed (x-error, x-cancel).
    func shortcutReturned(error: String?) {
        engine.shortcutReturned(error: error)
    }

    /// Shown once per launch when the shortcut is missing or failed. Calls back once it is dismissed.
    func showMissingShortcutHint(detail: String, then done: @escaping () -> Void) {
        guard !hintShown else {
            done()
            return
        }
        hintShown = true
        let message = String(
            format: "On cellular, StikDebug connects in the few seconds after Airplane Mode turns off. In the Shortcuts app, create a shortcut named “%@” that turns Airplane Mode on, waits 1 second and turns it off, run it once and allow it. StikDebug continues without it this time.\n(%@)".localized,
            Self.shortcutName, detail
        )
        Self.whenActive {
            showAlert(title: "Airplane Mode Shortcut Needed".localized, message: message, showOk: true) { _ in done() }
        }
    }

    /// No connection got through in the window: try again, or end the request (`retry` is true for Try Again).
    static func showFailedAlert(detail: String, then done: @escaping (_ retry: Bool) -> Void) {
        let message = String(
            format: "StikDebug could not connect in the seconds after Airplane Mode turned off, so JIT was not enabled. Try again, or join any Wi-Fi network first.\n(%@)".localized,
            detail
        )
        whenActive {
            showAlert(
                title: "Couldn't Connect on Cellular".localized,
                message: message,
                showOk: true,
                showTryAgain: true,
                primaryButtonText: "Try Again".localized
            ) { retry in done(retry) }
        }
    }

    /// Runs `show` now if StikDebug is in front, or once it comes to the front: an alert asked for
    /// while Shortcuts or the requesting app is in front would be dropped and leave the request hanging.
    static func whenActive(_ show: @escaping () -> Void) {
        if UIApplication.shared.applicationState == .active {
            show()
            return
        }
        final class Token: @unchecked Sendable { var value: NSObjectProtocol? }
        let token = Token()
        token.value = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                             object: nil, queue: .main) { _ in
            if let value = token.value { NotificationCenter.default.removeObserver(value) }
            token.value = nil
            show()
        }
    }

    static func shortcutURL() -> URL? {
        // ASCII only: CharacterSet.alphanumerics includes non-ASCII letters, which would stay unencoded.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let name = shortcutName.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(name)"
                   + "&x-success=stikjit://cellular-window"
                   + "&x-error=stikjit://cellular-window-failed"
                   + "&x-cancel=stikjit://cellular-window-failed")
    }

    // MARK: - Network

    /// The path in use. Wi-Fi switched on but not joined is not in use, so it counts as cellular only.
    static func pathSnapshot() -> PathSnapshot {
        let monitor = NWPathMonitor()
        let monitorQueue = DispatchQueue(label: "com.stik.cellular-window.path")
        let done = DispatchSemaphore(value: 0)
        var snapshot = PathSnapshot(satisfied: false, wifi: false, wired: false, cellular: false, interfaces: ["no path within 0.5 s"])
        monitor.pathUpdateHandler = { path in
            snapshot = PathSnapshot(satisfied: path.status == .satisfied,
                                    wifi: path.usesInterfaceType(.wifi),
                                    wired: path.usesInterfaceType(.wiredEthernet),
                                    cellular: path.usesInterfaceType(.cellular),
                                    interfaces: path.availableInterfaces.map(\.name),
                                    expensive: path.isExpensive)
            done.signal()
        }
        monitor.start(queue: monitorQueue)
        _ = done.wait(timeout: .now() + 0.5)
        monitor.cancel()
        return monitorQueue.sync { snapshot }
    }

    /// A tunnel interface is up with an address in 10.7.0.0/16, where LocalDevVPN puts its tunnel.
    static func vpnTunnelUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name).hasPrefix("utun"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = UInt32(bigEndian: UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
            if ip >> 16 == 0x0A07 { return true }
        }
        return false
    }

    /// A plain TCP connect to the device's address and `port`, closed right away.
    static func probe(port: UInt16, timeout: TimeInterval) -> ProbeResult {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard DeviceConnectionContext.defaultTargetIPAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return .other(EINVAL)
        }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .other(errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return .connected }
        guard errno == EINPROGRESS else { return errno == ECONNREFUSED ? .refused : .other(errno) }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return .timeout }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        if error == 0 { return .connected }
        return error == ECONNREFUSED ? .refused : .other(error)
    }
}

/// The real world for CellularWindowEngine.
private final class AppWindowEnvironment: WindowEnvironment {
    func now() -> Date { Date() }

    func sleep(_ seconds: TimeInterval) { usleep(useconds_t(max(0, seconds) * 1_000_000)) }

    func path() -> PathSnapshot { CellularWindow.pathSnapshot() }

    func vpnUp() -> Bool { CellularWindow.vpnTunnelUp() }

    func resolvePort() -> UInt16 {
        let port = RemotePairingPortResolver.resolve()
        CellularWindow.log("RemotePairing port \(RemotePairingPortResolver.lastAttemptDescription)")
        return port
    }

    func probe(port: UInt16, timeout: TimeInterval) -> ProbeResult {
        CellularWindow.probe(port: port, timeout: timeout)
    }

    func runShortcut() {
        guard let url = CellularWindow.shortcutURL() else {
            CellularWindow.shared.shortcutReturned(error: "could not build the Shortcuts URL")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened { CellularWindow.shared.shortcutReturned(error: "the Shortcuts app could not be opened") }
            }
        }
    }

    func openTunnels(port: UInt16, count: Int, request: String) -> Int {
        JITEnableContext.shared.fillSpareTunnels(port: port, count: count, request: request)
    }

    func installMainTunnel(request: String) -> Bool {
        guard JITEnableContext.shared.installWindowMainTunnel(request: request) else { return false }
        DispatchQueue.main.async { TunnelManager.shared.markConnectedByWindow() }
        return true
    }

    func log(_ message: String) { CellularWindow.log(message) }
}
