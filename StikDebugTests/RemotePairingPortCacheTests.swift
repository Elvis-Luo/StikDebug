//
//  RemotePairingPortCacheTests.swift
//  StikDebugTests
//

import Foundation
import Testing
@testable import StikDebug

private final class MemoryStore: PortCacheStore {
    var values: [String: Int] = [:]
    func integer(forKey defaultName: String) -> Int { values[defaultName] ?? 0 }
    func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

private struct ConnectFailed: Error {}

private final class FakeDevice {
    var openPort: UInt16 = 56482
    var bonjourPort: UInt16 = 56482
    var discoveries = 0
    var attempts: [(port: UInt16, source: String)] = []

    func connect(_ cache: RemotePairingPortCache) -> Result<UInt16, Error> {
        cache.connect(
            discover: { self.discoveries += 1; return (self.bonjourPort, "Bonjour") },
            attempt: { port, source in
                self.attempts.append((port, source))
                return port == self.openPort ? .success(port) : .failure(ConnectFailed())
            }
        )
    }
}

struct RemotePairingPortCacheTests {
    @Test func laterTunnelsUseTheVerifiedPortWithoutBonjour() throws {
        let cache = RemotePairingPortCache(store: MemoryStore(), bootTime: { 1000 })
        let device = FakeDevice()
        #expect(try device.connect(cache).get() == 56482)
        #expect(device.discoveries == 1)
        for _ in 0..<3 { _ = device.connect(cache) }   // debug, heartbeat, remote server
        #expect(device.discoveries == 1)
        #expect(device.attempts.dropFirst().allSatisfy { $0.source == "Verified this boot" })
    }

    @Test func aStalePortIsForgottenRediscoveredAndRetriedOnce() throws {
        let cache = RemotePairingPortCache(store: MemoryStore(), bootTime: { 1000 })
        cache.remember(50000)
        let device = FakeDevice()
        #expect(try device.connect(cache).get() == 56482)
        #expect(device.attempts.map(\.port) == [50000, 56482])
        #expect(device.discoveries == 1)
        #expect(cache.port() == 56482)

        cache.remember(50000)
        device.openPort = 1
        device.attempts = []
        device.discoveries = 0
        if case .success = device.connect(cache) { Issue.record("connected with nothing open") }
        #expect(device.attempts.count == 2 && device.discoveries == 1)
        #expect(cache.port() == nil)

        device.attempts = []
        _ = device.connect(cache)
        #expect(device.attempts.count == 1)   // without a cache, no retry (as before)
    }

    @Test func aNewBootStartsWithoutACache() {
        var boot = 1000
        let cache = RemotePairingPortCache(store: MemoryStore(), bootTime: { boot })
        cache.remember(56482)
        #expect(cache.port() == 56482)
        boot = 2000
        #expect(cache.port() == nil)
        cache.remember(56482)
        cache.forget(49152)
        #expect(cache.port() == 56482)
        cache.forget(56482)
        #expect(cache.port() == nil)
        cache.remember(0)
        #expect(cache.port() == nil)
    }
}
