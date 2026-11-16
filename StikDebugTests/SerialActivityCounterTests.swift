//
//  SerialActivityCounterTests.swift
//  StikDebugTests
//

import Foundation
import Testing
@testable import StikDebug

struct SerialActivityCounterTests {
    @Test func aSlowStartNeverBlocksTheCaller() {
        let queue = DispatchQueue(label: "test.keepalive")
        var starts = 0
        let counter = SerialActivityCounter(queue: queue) { count in
            if count == 1 { Thread.sleep(forTimeInterval: 2); starts += 1 }   // activating the audio session
        }
        let before = Date()
        counter.increment()
        counter.increment()
        #expect(Date().timeIntervalSince(before) < 0.05)
        queue.sync {}
        #expect(starts == 1)
    }

    @Test func startsAndStopsStayBalancedAndInOrder() {
        let queue = DispatchQueue(label: "test.keepalive.balance")
        var seen: [Int] = []
        let counter = SerialActivityCounter(queue: queue) { seen.append($0) }
        counter.increment()
        counter.increment()
        counter.decrement()
        counter.decrement()
        counter.decrement()
        queue.sync {}
        #expect(seen == [1, 2, 1, 0, 0])

        let group = DispatchGroup()
        for _ in 0..<50 {
            DispatchQueue.global().async(group: group) { counter.increment(); counter.decrement() }
        }
        group.wait()
        #expect(queue.sync { counter.valueOnQueue } == 0)
    }
}
