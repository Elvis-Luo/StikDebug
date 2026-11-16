//
//  CellularWindowTests.swift
//  StikDebugTests
//

import Foundation
import Testing
@testable import StikDebug

/// A fake device for CellularWindowEngine, on a fake clock: the engine's sleep() advances it and runs
/// scheduled events. With cellular as the active network the RemotePairing service refuses connections
/// over the VPN; in Airplane Mode nothing gets through; after Airplane Mode turns off, connections are
/// accepted until cellular is the active network again (`cellularReturnDelay`); joined Wi-Fi always works.
private final class FakeDevice: WindowEnvironment {
    private(set) var t: Double = 0
    private var events: [(at: Double, seq: Int, action: () -> Void)] = []
    private var seq = 0

    var airplane = false
    var cellularBackAt: Double?
    var cellularReturnDelay: Double = 6
    var wifiJoined = false
    var vpn = true
    let realPort: UInt16 = 56482

    enum Shortcut { case installed, failsWithError, neverAnswers }
    var shortcut = Shortcut.installed
    private(set) var shortcutRuns = 0
    private(set) var openedTunnels = 0
    private(set) var mainInstalled = false
    weak var engine: CellularWindowEngine?

    func schedule(at time: Double, _ action: @escaping () -> Void) {
        seq += 1
        events.append((time, seq, action))
    }

    private func advance(to target: Double) {
        while let next = events.filter({ $0.at <= target }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            events.removeAll { $0.seq == next.seq }
            t = max(t, next.at)
            next.action()
        }
        t = max(t, target)
    }

    var cellularActive: Bool { !airplane && !wifiJoined && (cellularBackAt.map { t >= $0 } ?? true) }
    var accepts: Bool { vpn && (wifiJoined || (!airplane && !cellularActive)) }

    func now() -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + t) }
    func sleep(_ seconds: TimeInterval) { advance(to: t + max(0, seconds)) }
    func log(_ message: String) {}
    func vpnUp() -> Bool { vpn }
    func resolvePort() -> UInt16 { realPort }

    func path() -> PathSnapshot {
        if wifiJoined {
            return PathSnapshot(satisfied: true, wifi: true, wired: false, cellular: false, interfaces: ["en0", "pdp_ip0"])
        }
        if airplane || !cellularActive {
            return PathSnapshot(satisfied: false, wifi: false, wired: false, cellular: false, interfaces: ["utun7"])
        }
        return PathSnapshot(satisfied: true, wifi: false, wired: false, cellular: true, interfaces: ["pdp_ip0", "utun7"], expensive: true)
    }

    func probe(port: UInt16, timeout: TimeInterval) -> ProbeResult {
        if !vpn || airplane {
            advance(to: t + timeout)
            return .timeout
        }
        return accepts && port == realPort ? .connected : .refused
    }

    func runShortcut() {
        shortcutRuns += 1
        let start = t
        switch shortcut {
        case .installed:
            schedule(at: start + 0.3) { self.airplane = true }
            schedule(at: start + 1.3) {
                self.airplane = false
                self.cellularBackAt = self.t + self.cellularReturnDelay
            }
            schedule(at: start + 1.6) { self.engine?.shortcutReturned(error: nil) }
        case .failsWithError:
            schedule(at: start + 0.8) { self.engine?.shortcutReturned(error: "Shortcuts: not found") }
        case .neverAnswers:
            break
        }
    }

    func openTunnels(port: UInt16, count: Int, request: String) -> Int {
        let acceptedAtStart = accepts && port == realPort
        advance(to: t + 0.4)
        guard acceptedAtStart, accepts else { return 0 }
        openedTunnels += count
        return count
    }

    func installMainTunnel(request: String) -> Bool {
        mainInstalled = true
        return true
    }
}

private func makeEngine(_ device: FakeDevice) -> CellularWindowEngine {
    let engine = CellularWindowEngine(env: device)
    device.engine = engine
    return engine
}

struct CellularWindowEngineTests {
    @Test func cellularOnlyRunsTheShortcutAndOpensTunnelsInTheWindow() {
        let device = FakeDevice()
        let outcome = makeEngine(device).run(request: "A")
        #expect(outcome == .opened(8, viaShortcut: true))
        #expect(device.shortcutRuns == 1)
        #expect(device.openedTunnels == 8)
        #expect(device.mainInstalled)
    }

    @Test func joinedWiFiNeedsNoWindow() {
        let device = FakeDevice()
        device.wifiJoined = true
        #expect(makeEngine(device).run(request: "A") == .notNeeded("not cellular only: \(device.path().text)"))
        #expect(device.shortcutRuns == 0)
    }

    @Test func vpnDownNeedsNoWindow() {
        let device = FakeDevice()
        device.vpn = false
        guard case .notNeeded = makeEngine(device).run(request: "A") else {
            Issue.record("expected notNeeded")
            return
        }
        #expect(device.shortcutRuns == 0)
    }

    @Test func aWindowStillOpenIsUsedWithoutTheShortcut() {
        let device = FakeDevice()
        let engine = makeEngine(device)
        #expect(engine.run(request: "A") == .opened(8, viaShortcut: true))
        // A second request while cellular is not yet the active network again.
        #expect(engine.run(request: "B") == .opened(8, viaShortcut: false))
        #expect(device.shortcutRuns == 1)
    }

    @Test func requestJudgedDuringAirplaneModeWaitsAndUsesThatWindow() {
        let device = FakeDevice()
        device.airplane = true
        device.schedule(at: 1) {
            device.airplane = false
            device.cellularBackAt = device.t + 6
        }
        #expect(makeEngine(device).run(request: "B") == .opened(8, viaShortcut: false))
        #expect(device.shortcutRuns == 0)
    }

    @Test func missingShortcutFallsBack() {
        let device = FakeDevice()
        device.shortcut = .failsWithError
        #expect(makeEngine(device).run(request: "A") == .shortcutMissing("Shortcuts: not found"))
        #expect(device.openedTunnels == 0)
    }

    @Test func shortcutThatNeverAnswersFailsAfterTwentySecondsWithoutCallingItMissing() {
        let device = FakeDevice()
        device.shortcut = .neverAnswers
        let started = device.t
        guard case .failed = makeEngine(device).run(request: "A") else {
            Issue.record("expected failed")
            return
        }
        #expect(device.t - started >= 20 && device.t - started < 22)
    }

    @Test func slowShortcutsStillOpensTheWindow() {
        // Shortcuts starts cold: Airplane Mode toggles after 12 s and the callback comes at 15 s.
        let device = FakeDevice()
        device.shortcut = .neverAnswers
        let engine = makeEngine(device)
        device.schedule(at: 12) { device.airplane = true }
        device.schedule(at: 13) {
            device.airplane = false
            device.cellularBackAt = device.t + 6
        }
        device.schedule(at: 15) { engine.shortcutReturned(error: nil) }
        #expect(engine.run(request: "A") == .opened(8, viaShortcut: true))
    }

    @Test func noConnectionInTheWindowFails() {
        let device = FakeDevice()
        device.cellularReturnDelay = 0
        guard case .failed = makeEngine(device).run(request: "A") else {
            Issue.record("expected failed")
            return
        }
        #expect(device.openedTunnels == 0)
    }

    @Test func wifiJoiningDuringTheWindowGoesOnAsBefore() {
        let device = FakeDevice()
        device.cellularReturnDelay = 0
        device.schedule(at: 4) { device.wifiJoined = true }
        let outcome = makeEngine(device).run(request: "A")
        switch outcome {
        case .notNeeded, .opened:
            break
        default:
            Issue.record("unexpected \(outcome)")
        }
    }
}

struct CellularTunnelPoolTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func tunnelsGoOnlyToTheirOwnRequest() {
        let pool = TunnelPool<Int>(lifetime: 120)
        pool.add(1, request: "A", at: start)
        pool.add(2, request: "A", at: start)
        pool.add(3, request: "B", at: start)
        #expect(pool.take(for: "A", now: start)?.handle == 1)
        #expect(pool.take(for: "A", now: start)?.left == 0)
        #expect(pool.take(for: "A", now: start) == nil)
        #expect(pool.count(for: "B") == 1)
    }

    @Test func staleTunnelsAreDropped() {
        let pool = TunnelPool<Int>(lifetime: 120)
        pool.add(1, request: "A", at: start)
        pool.add(2, request: "A", at: start.addingTimeInterval(100))
        #expect(pool.take(for: "A", now: start.addingTimeInterval(121))?.handle == 2)
        #expect(pool.dropStale(now: start.addingTimeInterval(121)) == [1])
    }

    @Test func windowMainTunnelIsKeptForTheGraceAndOnCellular() {
        let installed = start
        #expect(MainTunnelPolicy.keepWindowTunnel(installedAt: installed, now: start.addingTimeInterval(30), cellularOnly: false))
        #expect(!MainTunnelPolicy.keepWindowTunnel(installedAt: installed, now: start.addingTimeInterval(95), cellularOnly: false))
        #expect(MainTunnelPolicy.keepWindowTunnel(installedAt: installed, now: start.addingTimeInterval(400), cellularOnly: true))
        #expect(!MainTunnelPolicy.keepWindowTunnel(installedAt: nil, now: start, cellularOnly: true))
    }
}

struct CellularRequestRegistryTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func secondRequestWhileTheFirstStillWaitsIsADuplicate() {
        let registry = RequestRegistry()
        #expect(registry.begin(id: "A1", target: "com.example.app", now: start) == .proceed)
        #expect(registry.begin(id: "A1", target: "com.example.app", now: start) == .proceed)
        #expect(registry.begin(id: "A2", target: "com.example.app", now: start.addingTimeInterval(1)) == .duplicate(of: "A1"))
        #expect(registry.begin(id: "B1", target: "com.example.other", now: start.addingTimeInterval(1)) == .proceed)
        registry.finish("A1", success: true, now: start.addingTimeInterval(20))
        #expect(registry.begin(id: "A3", target: "com.example.app", now: start.addingTimeInterval(30)) == .proceed)
    }

    @Test func aRelaunchWhileTheFirstSessionRunsGoesOn() {
        // A script that keeps running after its app crashed must not block the app's next request.
        let registry = RequestRegistry()
        _ = registry.begin(id: "A1", target: "app", now: start)
        registry.markSession("A1")
        #expect(registry.begin(id: "A2", target: "app", now: start.addingTimeInterval(10)) == .proceed)
    }

    @Test func aBusyRequestStopsBlockingAfterTheLimit() {
        let registry = RequestRegistry(busyLimit: 120)
        _ = registry.begin(id: "A1", target: "app", now: start)
        #expect(registry.begin(id: "A2", target: "app", now: start.addingTimeInterval(121)) == .proceed)
    }

    @Test func failureAlertIsSuppressedWhenReplacedOrAlreadyServed() {
        let registry = RequestRegistry(busyLimit: 120)
        _ = registry.begin(id: "A1", target: "app", now: start)
        registry.finish("A1", success: false, now: start.addingTimeInterval(5))
        _ = registry.begin(id: "A2", target: "app", now: start.addingTimeInterval(6))
        #expect(registry.alertSuppression(for: "A1") != nil)   // replaced by A2
        #expect(registry.alertSuppression(for: "A2") == nil)

        registry.markSession("A2")
        _ = registry.begin(id: "B1", target: "other", now: start)
        #expect(registry.alertSuppression(for: "B1") == nil)

        // While another request for the app has its debugger attached, a failure is not alerted.
        let attached = RequestRegistry()
        _ = attached.begin(id: "D1", target: "app", now: start)
        attached.markSession("D1")
        #expect(attached.begin(id: "D2", target: "app", now: start.addingTimeInterval(10)) == .proceed)
        attached.finish("D2", success: false, now: start.addingTimeInterval(15))
        #expect(attached.alertSuppression(for: "D2")?.contains("already has its debugger") == true)
        attached.finish("D1", success: true, now: start.addingTimeInterval(20))
        #expect(attached.alertSuppression(for: "D2") == nil)

        // A separate request that fails shortly after an earlier one succeeded is alerted.
        let separate = RequestRegistry(busyLimit: 120)
        _ = separate.begin(id: "E1", target: "app", now: start)
        separate.markSession("E1")
        separate.finish("E1", success: true, now: start.addingTimeInterval(10))
        _ = separate.begin(id: "E2", target: "app", now: start.addingTimeInterval(30))
        separate.finish("E2", success: false, now: start.addingTimeInterval(40))
        #expect(separate.alertSuppression(for: "E2") == nil)

        // An old success for the same app says nothing about a request much later.
        let later = RequestRegistry(busyLimit: 120)
        _ = later.begin(id: "C1", target: "app", now: start)
        later.finish("C1", success: true, now: start.addingTimeInterval(10))
        _ = later.begin(id: "C2", target: "app", now: start.addingTimeInterval(600))
        later.finish("C2", success: false, now: start.addingTimeInterval(610))
        #expect(later.alertSuppression(for: "C2") == nil)
    }
}
