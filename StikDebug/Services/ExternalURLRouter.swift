//
//  ExternalURLRouter.swift
//  StikDebug
//

import Foundation

/// Hands URLs opened in StikDebug to HomeView.
///
/// While a sheet is in front (a running script's log, for example), HomeView's own onOpenURL is not
/// called, so an enable-jit request from another app was lost. Every onOpenURL hands the URL here
/// instead; it is posted once, and HomeView takes it with onReceive, which still works behind a sheet.
final class ExternalURLRouter {
    static let shared = ExternalURLRouter()
    static let notification = Notification.Name("StikDebugExternalURL")

    /// Several handlers see the same URL; within this many seconds it is handled once.
    private static let duplicateWindow: TimeInterval = 2

    private let lock = NSLock()
    private var recent: [(url: String, at: Date)] = []

    func handle(_ url: URL) {
        let now = Date()
        lock.lock()
        recent.removeAll { now.timeIntervalSince($0.at) > Self.duplicateWindow }
        let isDuplicate = recent.contains { $0.url == url.absoluteString }
        if !isDuplicate {
            recent.append((url.absoluteString, now))
        }
        lock.unlock()
        guard !isDuplicate else { return }

        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.notification, object: url)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.notification, object: url)
            }
        }
    }
}
