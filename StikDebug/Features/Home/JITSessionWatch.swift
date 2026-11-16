//
//  JITSessionWatch.swift
//  StikDebug
//

import Foundation

/// The state of a running JIT session, as the session page and the Home capsule show it.
///
/// It only watches: the script's continue commands, their answers, and how the debug session
/// ended. Some scripts wait in a continue until the app does something (UTM's script waits for
/// the first VM to start); that wait is shown as "JIT enabled" instead of an endless spinner.
struct JITSessionWatch: Equatable {
    /// A continue still outstanding after this long means the debugger is attached and the script
    /// waits for the app. Scripts that finish on their own answer their continues within a couple of seconds.
    static let waitingDelay: TimeInterval = 4
    /// How long a completed session shows its result before its page closes.
    static let enabledShownFor: TimeInterval = 1.5

    enum Phase: Equatable {
        case starting   // launching, attaching, first commands
        case waiting    // attached; the script waits for the app
        case finishing  // the wait is over; the script is finishing
        case enabled    // the debug session completed
        case appQuit    // the app exited (W or X answer to a continue)
        case failed     // the debug session failed
        case scriptError // the script stopped with an exception
    }

    private(set) var continueSince: Date?
    private(set) var reachedWaiting = false
    private(set) var targetExited = false
    private(set) var scriptError = false
    /// How the debug session ended; nil while it runs.
    private(set) var finished: Bool?

    /// A GDB remote continue: c, c<addr>, C<sig>[;addr], vCont;c..., vCont;C....
    static func isContinue(_ command: String) -> Bool {
        if command.hasPrefix("vCont;") {
            let action = command.dropFirst(6).first
            return action == "c" || action == "C"
        }
        guard let first = command.first, first == "c" || first == "C" else { return false }
        return command.dropFirst().allSatisfy { $0.isHexDigit || $0 == ";" }
    }

    mutating func continueStarted(at time: Date) {
        continueSince = time
    }

    mutating func continueEnded(response: String?, at time: Date) {
        if let since = continueSince, time.timeIntervalSince(since) >= Self.waitingDelay {
            reachedWaiting = true
        }
        continueSince = nil
        // W<status>: the app exited; X<signal>: it was killed.
        if let first = response?.first, first == "W" || first == "X" {
            targetExited = true
        }
    }

    mutating func finish(success: Bool) {
        finished = success
    }

    /// The script threw. JIT may not be on, so the page shows the error and stays open.
    mutating func scriptFailed() {
        scriptError = true
    }

    func phase(at now: Date) -> Phase {
        if finished == false { return .failed }
        if scriptError { return .scriptError }
        if targetExited { return .appQuit }
        if finished == true { return .enabled }
        if let since = continueSince {
            // Once the script has waited for the app, a later continue (a script that keeps
            // continuing after each breakpoint) means it waits again.
            if reachedWaiting || now.timeIntervalSince(since) >= Self.waitingDelay { return .waiting }
        }
        if reachedWaiting { return .finishing }
        return .starting
    }

    /// When the page closes by itself after the session ended. nil keeps it open: a failed
    /// session (its alert shows as before), a script error, or while the log is open.
    func closeDelay(logOpen: Bool) -> TimeInterval? {
        guard finished == true, !scriptError, !logOpen else { return nil }
        return targetExited ? 0 : Self.enabledShownFor
    }
}
