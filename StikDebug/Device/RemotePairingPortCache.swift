//
//  RemotePairingPortCache.swift
//  StikDebug
//

import Foundation

/// Where the port cache keeps its value: UserDefaults in the app, a dictionary in tests.
protocol PortCacheStore: AnyObject {
    func integer(forKey defaultName: String) -> Int
    func set(_ value: Int, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PortCacheStore {}

/// The RemotePairing port a tunnel to this device reached during this boot.
///
/// The device picks the port at boot, so a port that worked stays right until the next boot, and
/// later tunnels can skip the Bonjour discovery (up to 5 s for every tunnel: main, debug, heartbeat,
/// remote server). A failed connect forgets it.
final class RemotePairingPortCache {
    static let portKey = "RemotePairingVerifiedPort"
    static let bootKey = "RemotePairingVerifiedPortBoot"

    private let store: PortCacheStore
    private let bootTime: () -> Int
    private let lock = NSLock()

    init(store: PortCacheStore, bootTime: @escaping () -> Int) {
        self.store = store
        self.bootTime = bootTime
    }

    /// The port a tunnel reached during this boot, if any.
    func port() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        let boot = bootTime()
        guard boot != 0, store.integer(forKey: Self.bootKey) == boot,
              let port = UInt16(exactly: store.integer(forKey: Self.portKey)), port != 0 else { return nil }
        return port
    }

    func remember(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard port != 0 else { return }
        store.set(Int(port), forKey: Self.portKey)
        store.set(bootTime(), forKey: Self.bootKey)
    }

    /// A connect to `port` failed: forget it if it is the cached one.
    func forget(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if store.integer(forKey: Self.portKey) == Int(port) {
            store.removeObject(forKey: Self.portKey)
            store.removeObject(forKey: Self.bootKey)
        }
    }

    /// One tunnel to this device. With a cached port, connect to it without a discovery; if that
    /// fails, forget it, discover again and retry once. Without one, discover and connect once.
    /// A port that connected is remembered. `attempt` gets the port and where it came from.
    func connect<T>(discover: () -> (port: UInt16, source: String),
                    attempt: (UInt16, String) -> Result<T, Error>) -> Result<T, Error> {
        if let cached = port() {
            let first = attempt(cached, "Verified this boot")
            if case .success = first { return first }
            forget(cached)
            let found = discover()
            let second = attempt(found.port, found.source)
            if case .success = second { remember(found.port) }
            return second
        }
        let found = discover()
        let result = attempt(found.port, found.source)
        if case .success = result { remember(found.port) }
        return result
    }
}
