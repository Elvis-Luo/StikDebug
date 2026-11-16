//
//  CellularWindowCore.swift
//  StikDebug
//
//  The decisions behind enabling JIT on cellular through an Airplane Mode window. Foundation only,
//  so the tests can drive it with a fake network and clock; CellularWindow.swift supplies the real
//  network, probe, shortcut and tunnels.
//
//  Why a window: with cellular as the only network, iOS makes the cellular interface the delegate of
//  LocalDevVPN's utun, and the RemotePairing service refuses connections that arrive on it. Right after
//  Airplane Mode turns off, before cellular is the primary network again, connections go through, and
//  tunnels opened then keep working.
//

import Foundation

// MARK: - Network path

struct PathSnapshot: Equatable {
    var satisfied: Bool
    var wifi: Bool
    var wired: Bool
    var cellular: Bool
    var interfaces: [String]
    var expensive: Bool = false

    /// Over cellular and neither Wi-Fi nor wired: the actual path, so Wi-Fi switched on but not joined counts.
    var cellularOnly: Bool { satisfied && cellular && !wifi && !wired }
    /// Joined to Wi-Fi or wired: a new connect to 10.7.0.1 works without a window.
    var joined: Bool { satisfied && (wifi || wired) }
    /// No usable network (Airplane Mode on, or the radios coming back after it): a window may be in progress.
    var unsatisfied: Bool { !satisfied }

    var text: String {
        "status=\(satisfied ? "satisfied" : "unsatisfied") wifi=\(wifi) wired=\(wired) cellular=\(cellular) "
            + "expensive=\(expensive) interfaces=[\(interfaces.joined(separator: ","))]"
    }
}

enum ProbeResult: Equatable, CustomStringConvertible {
    case connected, refused, timeout, other(Int32)

    var description: String {
        switch self {
        case .connected: return "connected"
        case .refused: return "refused"
        case .timeout: return "timeout"
        case .other(let code): return "errno \(code)"
        }
    }
}

// MARK: - Window

/// What the window needs from the world. The app uses NWPathMonitor, a TCP probe, the Shortcuts URL and idevice;
/// the tests use fakes driven by a fake clock (sleep advances it).
protocol WindowEnvironment: AnyObject {
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
    func path() -> PathSnapshot
    /// The VPN tunnel (LocalDevVPN) is up. It cannot start in Airplane Mode, so it has to be up before the shortcut runs.
    func vpnUp() -> Bool
    func resolvePort() -> UInt16
    func probe(port: UInt16, timeout: TimeInterval) -> ProbeResult
    /// Starts the shortcut; its x-success / x-error come back through CellularWindowEngine.shortcutReturned.
    func runShortcut()
    /// Opens `count` tunnels at once for `request` and adds them to its pool; returns how many opened.
    func openTunnels(port: UInt16, count: Int, request: String) -> Int
    /// Makes one of `request`'s tunnels the main tunnel.
    func installMainTunnel(request: String) -> Bool
    func log(_ message: String)
}

enum WindowOutcome: Equatable, CustomStringConvertible {
    /// Not cellular only, Wi-Fi joined meanwhile, or LocalDevVPN not up: go on as before.
    case notNeeded(String)
    /// Tunnels opened for this request (count). `viaShortcut` is false when 10.7.0.1 already answered.
    case opened(Int, viaShortcut: Bool)
    /// The shortcut is not installed or failed (x-error or x-cancel).
    case shortcutMissing(String)
    /// No connect got through.
    case failed(String)

    var description: String {
        switch self {
        case .notNeeded(let why): return "notNeeded(\(why))"
        case .opened(let count, let viaShortcut): return "opened(\(count)\(viaShortcut ? "" : ", without the shortcut"))"
        case .shortcutMissing(let why): return "shortcutMissing(\(why))"
        case .failed(let why): return "failed(\(why))"
        }
    }
}

/// One request's window. Run one at a time (Airplane Mode is one switch); the app runs them on a serial queue.
final class CellularWindowEngine {
    struct Timing {
        var tunnelsPerRequest = 8
        var networkSettleLimit: TimeInterval = 30
        /// How long Shortcuts may take to come back (a cold start can be slow).
        var callbackLimit: TimeInterval = 20
        var afterCallbackLimit: TimeInterval = 25
        var probeInterval: TimeInterval = 0.35
        var probeTimeout: TimeInterval = 0.4
        var pathCheckInterval: TimeInterval = 1.5
        var waitForReturn: TimeInterval = 8
    }

    let env: WindowEnvironment
    var timing: Timing
    private let lock = NSLock()
    private var callbackDate: Date?
    private var shortcutError: String?

    init(env: WindowEnvironment, timing: Timing = Timing()) {
        self.env = env
        self.timing = timing
    }

    /// x-success (error nil) or x-error / x-cancel of the shortcut.
    func shortcutReturned(error: String?) {
        lock.lock()
        if let error { shortcutError = error } else { callbackDate = env.now() }
        lock.unlock()
        env.log(error.map { "Shortcuts returned an error: \($0)" } ?? "Shortcuts returned (Airplane Mode on and off done)")
    }

    private func callbackState() -> (Date?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (callbackDate, shortcutError)
    }

    func run(request: String) -> WindowOutcome {
        let tag = "[\(request.prefix(8))]"
        var network = env.path()
        var knownPort: UInt16?
        // Airplane Mode on, or its radios coming back (another request's window a moment ago): not a verdict. Wait for
        // the network; meanwhile, if the device answers (that window is still open), open this request's tunnels now.
        if network.unsatisfied {
            env.log("\(tag) no usable network yet (\(network.text)): a window may be in progress; waiting")
            let start = env.now()
            while network.unsatisfied, env.now().timeIntervalSince(start) < timing.networkSettleLimit {
                if env.vpnUp() {
                    let resolved = knownPort ?? env.resolvePort()
                    knownPort = resolved
                    if env.probe(port: resolved, timeout: timing.probeTimeout) == .connected {
                        env.log("\(tag) 10.7.0.1:\(resolved) answers while the network comes back: using that window")
                        if let opened = openTunnels(request: request, port: resolved, tag: tag) {
                            return .opened(opened, viaShortcut: false)
                        }
                    }
                }
                env.sleep(0.5)
                network = env.path()
            }
            env.log("\(tag) network after \(Int(env.now().timeIntervalSince(start))) s: \(network.text)")
        }
        guard network.cellularOnly else { return .notNeeded("not cellular only: \(network.text)") }
        env.log("\(tag) cellular only (\(network.text))")
        guard env.vpnUp() else {
            return .notNeeded("LocalDevVPN's tunnel is not up; it has to start before Airplane Mode")
        }
        let port = knownPort ?? env.resolvePort()

        // Still open from an earlier window: this request opens its own tunnels right away.
        if env.probe(port: port, timeout: 1) == .connected {
            env.log("\(tag) 10.7.0.1:\(port) answers already: opening this request's tunnels without the shortcut")
            if let opened = openTunnels(request: request, port: port, tag: tag) {
                return .opened(opened, viaShortcut: false)
            }
        }

        lock.lock()
        callbackDate = nil
        shortcutError = nil
        lock.unlock()
        env.log("\(tag) 10.7.0.1:\(port) refused; running the shortcut")
        env.runShortcut()

        let launched = env.now()
        var lastResult: ProbeResult?
        var probes = 0
        var lastSummary = launched
        var lastPathCheck = launched
        while true {
            let (callback, error) = callbackState()
            if let error { return .shortcutMissing(error) }
            let now = env.now()
            if callback == nil, now.timeIntervalSince(launched) > timing.callbackLimit {
                // Not proof that the shortcut is missing (a missing one comes back through x-error):
                // report a failed window, which offers Try Again.
                return .failed("Shortcuts did not come back within \(Int(timing.callbackLimit)) s")
            }
            if let callback, now.timeIntervalSince(callback) > timing.afterCallbackLimit {
                return .failed("no connect got through in the \(Int(timing.afterCallbackLimit)) s after the shortcut "
                               + "(\(probes) probes, last: \(lastResult.map { "\($0)" } ?? "-"))")
            }
            let result = env.probe(port: port, timeout: timing.probeTimeout)
            probes += 1
            if result != lastResult || now.timeIntervalSince(lastSummary) > 2 {
                let phase = callback.map { String(format: "%.1f s after the shortcut", now.timeIntervalSince($0)) } ?? "shortcut running"
                env.log(String(format: "%@ probe %d at %.1f s (%@): %@", tag, probes, now.timeIntervalSince(launched), phase, "\(result)"))
                lastResult = result
                lastSummary = now
            }
            if result == .connected {
                if let opened = openTunnels(request: request, port: port, tag: tag) {
                    waitForShortcutReturn()
                    return .opened(opened, viaShortcut: true)
                }
            } else if callback != nil, now.timeIntervalSince(lastPathCheck) > timing.pathCheckInterval {
                // Airplane Mode off brings the Wi-Fi radio back; if it joins a network, a new connect works anyway.
                lastPathCheck = now
                let path = env.path()
                if path.joined { return .notNeeded("Wi-Fi joined during the window (\(path.text))") }
            }
            env.sleep(timing.probeInterval)
        }
    }

    private func openTunnels(request: String, port: UInt16, tag: String) -> Int? {
        env.log("\(tag) window open: opening \(timing.tunnelsPerRequest) tunnels at once")
        let opened = env.openTunnels(port: port, count: timing.tunnelsPerRequest, request: request)
        env.log("\(tag) \(opened) of \(timing.tunnelsPerRequest) tunnels opened")
        guard opened > 0 else { return nil }
        _ = env.installMainTunnel(request: request)
        return opened
    }

    private func waitForShortcutReturn() {
        let until = env.now().addingTimeInterval(timing.waitForReturn)
        while env.now() < until {
            let (callback, error) = callbackState()
            if callback != nil || error != nil { return }
            env.sleep(0.2)
        }
    }
}

// MARK: - Tunnels

/// Window tunnels, each belonging to the request whose window opened it. Only that request takes them.
final class TunnelPool<Handle> {
    let lifetime: TimeInterval
    private let lock = NSLock()
    private var entries: [(handle: Handle, opened: Date, request: String)] = []

    init(lifetime: TimeInterval = 120) {
        self.lifetime = lifetime
    }

    func add(_ handle: Handle, request: String, at date: Date) {
        lock.lock()
        entries.append((handle, date, request))
        lock.unlock()
    }

    /// One of `request`'s tunnels, and how many it has left. Never another request's.
    func take(for request: String, now: Date) -> (handle: Handle, left: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.request == request && now.timeIntervalSince($0.opened) <= lifetime }) else {
            return nil
        }
        let entry = entries.remove(at: index)
        return (entry.handle, entries.filter { $0.request == request }.count)
    }

    func count(for request: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.request == request }.count
    }

    /// Removes and returns tunnels older than `lifetime` (the caller closes them).
    func dropStale(now: Date) -> [Handle] {
        lock.lock()
        defer { lock.unlock() }
        let stale = entries.filter { now.timeIntervalSince($0.opened) > lifetime }.map(\.handle)
        entries.removeAll { now.timeIntervalSince($0.opened) > lifetime }
        return stale
    }
}

/// Whether startTunnel keeps a main tunnel a window installed instead of connecting anew (which on cellular would be
/// refused): for `grace` seconds after it was installed, and for as long as the path is cellular only.
enum MainTunnelPolicy {
    static let grace: TimeInterval = 90

    static func keepWindowTunnel(installedAt: Date?, now: Date, cellularOnly: Bool) -> Bool {
        guard let installedAt else { return false }
        return now.timeIntervalSince(installedAt) < grace || cellularOnly
    }
}

// MARK: - Requests

/// External JIT requests by target app. A second request for an app whose earlier request is still
/// waiting (window, connection, launch; not yet attached) is a duplicate: the app asked again while
/// StikDebug was working, and it is dropped. Once the debugger is attached, a new request for that app
/// is a new launch and goes on. A failure alert is not shown for a request that a newer request for
/// the same app replaced, or while another request for that app has its debugger attached.
final class RequestRegistry {
    enum State: Equatable { case waiting, session, done(success: Bool) }
    struct Entry {
        let id: String
        let target: String
        let started: Date
        var state: State
        var finished: Date?
    }
    enum Begin: Equatable { case proceed, duplicate(of: String) }

    /// A waiting request older than this no longer blocks a new one for the same app.
    let busyLimit: TimeInterval
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(busyLimit: TimeInterval = 120) {
        self.busyLimit = busyLimit
    }

    func begin(id: String, target: String, now: Date) -> Begin {
        lock.lock()
        defer { lock.unlock() }
        if entries.contains(where: { $0.id == id }) { return .proceed } // the same request handed over again
        if let busy = entries.last(where: { $0.target == target && $0.state == .waiting && $0.finished == nil
                                             && now.timeIntervalSince($0.started) < busyLimit }) {
            return .duplicate(of: busy.id)
        }
        entries.append(Entry(id: id, target: target, started: now, state: .waiting))
        entries.removeAll { entry in entry.finished.map { now.timeIntervalSince($0) > 3600 } ?? false }
        return .proceed
    }

    /// The debugger is attached (or the session is running) for this request.
    func markSession(_ id: String) {
        update(id) { $0.state = .session }
    }

    func finish(_ id: String, success: Bool, now: Date) {
        update(id) { entry in
            entry.state = .done(success: success)
            entry.finished = now
        }
    }

    func state(of id: String) -> State? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.id == id }?.state
    }

    /// nil when the failure alert should show; otherwise why not.
    func alertSuppression(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let mine = entries.first(where: { $0.id == id }) else { return nil }
        if let newer = entries.last(where: { $0.target == mine.target && $0.id != id && $0.started > mine.started }) {
            return "superseded by \(newer.id.prefix(8))"
        }
        // Only a debugger attached right now counts; a session that has ended says nothing about this one.
        if let other = entries.first(where: { $0.target == mine.target && $0.id != id && $0.state == .session }) {
            return "\(mine.target) already has its debugger from \(other.id.prefix(8))"
        }
        return nil
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.id == id }) { change(&entries[index]) }
        lock.unlock()
    }
}
