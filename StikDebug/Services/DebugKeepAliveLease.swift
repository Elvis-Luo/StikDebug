//
//  DebugKeepAliveLease.swift
//  StikDebug
//

import Foundation
import UIKit

/// Keeps StikDebug running while a debug session needs it: a background task, the silent
/// audio and the background location, each reference-counted by its manager.
///
/// It never blocks its caller or the main thread: the background task is begun and ended directly (both calls are
/// thread-safe), the audio starts and stops on its own queue (BackgroundAudioManager), and the location through
/// main.async, where its CLLocationManager lives. Starts and stops stay balanced, since each queue runs them in order.
final class DebugKeepAliveLease {
    private let stateLock = NSLock()
    private var isActive = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        activate()
    }

    func invalidate() {
        stateLock.lock()
        guard isActive else {
            stateLock.unlock()
            return
        }
        isActive = false
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        stateLock.unlock()

        BackgroundAudioManager.shared.requestStop()
        DispatchQueue.main.async {
            BackgroundLocationManager.shared.requestStop()
        }
        if taskID != .invalid {
            Self.application.endBackgroundTask(taskID)
        }
    }

    private func activate() {
        stateLock.lock()
        guard !isActive else {
            stateLock.unlock()
            return
        }
        isActive = true
        stateLock.unlock()

        BackgroundAudioManager.shared.requestStart()
        DispatchQueue.main.async {
            BackgroundLocationManager.shared.requestStart()
        }
        let taskID = Self.application.beginBackgroundTask(withName: "StikDebugDebugSession") { [weak self] in
            LogManager.shared.addWarningLog("Debug session background task expired")
            self?.invalidate()
        }
        stateLock.lock()
        if isActive {
            backgroundTaskID = taskID
            stateLock.unlock()
        } else {
            // Invalidated while the task was being begun: end it now.
            stateLock.unlock()
            if taskID != .invalid { Self.application.endBackgroundTask(taskID) }
        }
    }

    /// beginBackgroundTask and endBackgroundTask may be called from any thread.
    private static var application: UIApplication {
        UIApplication.shared
    }
}
