//
//  JITSessionWatchTests.swift
//  StikDebugTests
//

import Foundation
import Testing
@testable import StikDebug

struct JITSessionWatchTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func scriptWaitingForTheAppShowsJITEnabledThenCloses() {
        var watch = JITSessionWatch()
        #expect(watch.phase(at: at(0)) == .starting)
        watch.continueStarted(at: at(1))
        #expect(watch.phase(at: at(3)) == .starting)
        #expect(watch.phase(at: at(5.5)) == .waiting)
        watch.continueEnded(response: "T05thread:56fd73;", at: at(12))
        #expect(watch.phase(at: at(12)) == .finishing)
        #expect(watch.closeDelay(logOpen: false) == nil)
        watch.finish(success: true)
        #expect(watch.phase(at: at(18)) == .enabled)
        #expect(watch.closeDelay(logOpen: false) == JITSessionWatch.enabledShownFor)
        #expect(watch.closeDelay(logOpen: true) == nil)
    }

    @Test func appExitingWhileWaitingClosesAtOnce() {
        var watch = JITSessionWatch()
        watch.continueStarted(at: at(0))
        #expect(watch.phase(at: at(10)) == .waiting)
        watch.continueEnded(response: "W00", at: at(22))
        #expect(watch.phase(at: at(22)) == .appQuit)
        watch.finish(success: true)
        #expect(watch.phase(at: at(23)) == .appQuit)
        #expect(watch.closeDelay(logOpen: false) == 0)

        var killed = JITSessionWatch()
        killed.continueStarted(at: at(0))
        killed.continueEnded(response: "X09", at: at(1))
        killed.finish(success: true)
        #expect(killed.phase(at: at(2)) == .appQuit)
        #expect(killed.closeDelay(logOpen: false) == 0)
    }

    @Test func quickScriptsNeverShowTheWait() {
        var watch = JITSessionWatch()
        for (begin, end) in [(0.0, 0.1), (0.2, 0.3), (5.0, 7.0)] {
            watch.continueStarted(at: at(begin))
            #expect(watch.phase(at: at(end)) == .starting)
            watch.continueEnded(response: "T05thread:56a042;", at: at(end))
        }
        #expect(watch.phase(at: at(7.5)) == .starting)
        watch.finish(success: true)
        #expect(watch.phase(at: at(8)) == .enabled)
        #expect(watch.closeDelay(logOpen: false) == JITSessionWatch.enabledShownFor)
    }

    @Test func failedSessionStaysOpen() {
        var watch = JITSessionWatch()
        watch.continueStarted(at: at(0))
        watch.finish(success: false)
        #expect(watch.phase(at: at(1)) == .failed)
        #expect(watch.closeDelay(logOpen: false) == nil)
    }

    @Test func scriptErrorKeepsThePageOpen() {
        var watch = JITSessionWatch()
        watch.scriptFailed()
        #expect(watch.phase(at: at(1)) == .scriptError)
        // The debug session itself still reports success.
        watch.finish(success: true)
        #expect(watch.phase(at: at(2)) == .scriptError)
        #expect(watch.closeDelay(logOpen: false) == nil)

        var failed = JITSessionWatch()
        failed.scriptFailed()
        failed.finish(success: false)
        #expect(failed.phase(at: at(1)) == .failed)
    }

    @Test func aScriptThatKeepsContinuingStaysWaiting() {
        var watch = JITSessionWatch()
        watch.continueStarted(at: at(0))
        #expect(watch.phase(at: at(5)) == .waiting)
        watch.continueEnded(response: "T05thread:1;", at: at(30))
        #expect(watch.phase(at: at(30)) == .finishing)
        // The next breakpoint is handled and the script continues again at once.
        watch.continueStarted(at: at(30.1))
        #expect(watch.phase(at: at(30.2)) == .waiting)
        #expect(watch.phase(at: at(40)) == .waiting)
    }

    @Test func onlyContinueCommandsAreWatched() {
        for command in ["c", "C05", "c1234abcd", "vCont;c", "vCont;c:56fd73", "vCont;C05:56fd73"] {
            #expect(JITSessionWatch.isContinue(command), "\(command)")
        }
        for command in ["vAttach;8e1f", "m1234c108c,4", "D", "P20=90104c2301000000;thread:56fd73;", "qC", "vCont?",
                        "vCont;S05:56a042", "_M40000000,rx", "QStartNoAckMode", ""] {
            #expect(!JITSessionWatch.isContinue(command), "\(command)")
        }
    }
}
