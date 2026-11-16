//
//  JITSessionPage.swift
//  StikDebug
//

import SwiftUI

/// The running JIT sessions and the one whose page is open.
///
/// Kept in one shared object rather than in HomeView's state, so the page and the Home capsule
/// follow a session whichever HomeView is on screen.
final class JITSessionBoard: ObservableObject {
    static let shared = JITSessionBoard()

    final class Session: ObservableObject, Identifiable {
        let id = UUID()
        let bundleID: String?
        let appName: String
        /// A script run from Shortcuts: its page is the script log, as before, and it never closes by itself.
        let showsScriptOnly: Bool
        @Published fileprivate(set) var script: RunJSViewModel?
        @Published var showLog = false

        fileprivate init(bundleID: String?, appName: String, showsScriptOnly: Bool) {
            self.bundleID = bundleID
            self.appName = appName
            self.showsScriptOnly = showsScriptOnly
        }
    }

    /// Sessions that have started and not ended, oldest first. The newest shows in the capsule.
    @Published private(set) var running: [Session] = []
    /// The session whose page is open.
    @Published var page: Session?

    /// A session starts (main queue).
    func begin(bundleID: String?, appName: String) -> Session {
        let session = Session(bundleID: bundleID, appName: appName, showsScriptOnly: false)
        running.append(session)
        return session
    }

    /// The session's script is about to run: its page opens, as the script log did.
    func attach(_ model: RunJSViewModel, to session: Session) {
        session.script = model
        page = session
    }

    /// A script run from Shortcuts: its log opens, as before.
    func showScript(_ model: RunJSViewModel) {
        let session = Session(bundleID: nil, appName: model.scriptName, showsScriptOnly: true)
        session.script = model
        page = session
    }

    /// The capsule's View Log: the session's page, at its log.
    func showLog(of session: Session) {
        session.showLog = session.script != nil
        page = session
    }

    /// The debug session ended (main queue). A completed page shows the result and closes by
    /// itself; a failed one stays open under the failure alert, as the log did.
    func finish(_ session: Session, success: Bool) {
        running.removeAll { $0 === session }
        guard let model = session.script else { return }
        model.finishWatch(success: success)
        scheduleClose(of: session)
    }

    /// The log of a session that has ended meanwhile was closed.
    func logClosed(_ session: Session) {
        scheduleClose(of: session)
    }

    private func scheduleClose(of session: Session) {
        guard page === session, let model = session.script, !session.showsScriptOnly,
              let delay = model.watch.closeDelay(logOpen: session.showLog) else { return }
        close(session, after: delay)
    }

    private func close(_ session: Session, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.page === session, !session.showLog else { return }
            // An alert on top would be dismissed with the page; wait until it is gone.
            if AlertPresenter.isShowingAlert {
                self.close(session, after: 1)
                return
            }
            self.page = nil
        }
    }
}

/// What the page and the capsule say for each phase.
enum JITSessionText {
    static var enabledTitle: String {
        "JIT Enabled".localized
    }

    static func appQuitTitle(appName: String) -> String {
        String(format: "%@ Quit".localized, appName)
    }

    /// The Home note once a session ended because its app exited.
    static func appQuitNotice(appName: String) -> String {
        String(format: "%@ quit. The JIT session has ended.".localized, appName)
    }

    /// The line under the title; nil where the title says it all.
    static func detail(for phase: JITSessionWatch.Phase, appName: String) -> String? {
        switch phase {
        case .waiting:
            return String(format: "The script is waiting for %@. This finishes by itself.".localized, appName)
        case .finishing:
            return "Finishing...".localized
        case .appQuit:
            return "The JIT session has ended.".localized
        case .scriptError:
            return "The script stopped with an error. View Log has the details.".localized
        case .starting, .enabled, .failed:
            return nil
        }
    }
}

// MARK: - The page

struct JITSessionPage: View {
    @ObservedObject var session: JITSessionBoard.Session
    let close: () -> Void

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", action: close)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model = session.script {
            if session.showsScriptOnly {
                RunJSView(model: model)
            } else {
                JITSessionStatusView(session: session, model: model)
            }
        } else {
            ProgressView()
        }
    }
}

private struct JITSessionStatusView: View {
    @ObservedObject var session: JITSessionBoard.Session
    @ObservedObject var model: RunJSViewModel

    var body: some View {
        let phase = model.watch.phase(at: Date())
        VStack(spacing: 14) {
            Spacer()
            if phase == .starting {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 6)
            }
            Text(title(for: phase))
                .font(.title2.weight(.semibold))
                .foregroundStyle(color(for: phase))
                .multilineTextAlignment(.center)
            if let detail = JITSessionText.detail(for: phase, appName: session.appName) {
                HStack(spacing: 8) {
                    if phase == .finishing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
            Button("View Log".localized) { session.showLog = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .navigationTitle(session.appName)
        .navigationDestination(isPresented: $session.showLog) {
            RunJSView(model: model)
        }
        .onChange(of: session.showLog) { _, open in
            if !open { JITSessionBoard.shared.logClosed(session) }
        }
    }

    private func title(for phase: JITSessionWatch.Phase) -> String {
        switch phase {
        case .starting:
            return String(format: "Starting JIT for %@".localized, session.appName)
        case .waiting, .finishing, .enabled:
            return JITSessionText.enabledTitle
        case .appQuit:
            return JITSessionText.appQuitTitle(appName: session.appName)
        case .failed:
            return String(format: "JIT failed for %@".localized, session.appName)
        case .scriptError:
            return "Script Error".localized
        }
    }

    private func color(for phase: JITSessionWatch.Phase) -> Color {
        switch phase {
        case .waiting, .finishing, .enabled: return .green
        case .failed, .scriptError: return .red
        case .starting, .appQuit: return .primary
        }
    }
}

// MARK: - The Home capsule

/// The running session at the bottom of Home: the spinner while it starts, then "JIT Enabled",
/// what the script waits for, and View Log.
struct JITSessionCapsule: View {
    @ObservedObject var session: JITSessionBoard.Session
    let showLog: () -> Void

    var body: some View {
        if let model = session.script, !session.showsScriptOnly {
            JITSessionCapsuleContent(session: session, model: model, showLog: showLog)
        } else {
            JITSessionStartingCapsule(appName: session.appName)
        }
    }
}

private struct JITSessionCapsuleContent: View {
    @ObservedObject var session: JITSessionBoard.Session
    @ObservedObject var model: RunJSViewModel
    let showLog: () -> Void

    var body: some View {
        let phase = model.watch.phase(at: Date())
        switch phase {
        case .starting, .failed, .scriptError:
            JITSessionStartingCapsule(appName: session.appName)
        case .waiting, .finishing, .enabled, .appQuit:
            let title = phase == .appQuit
                ? JITSessionText.appQuitTitle(appName: session.appName)
                : JITSessionText.enabledTitle
            let detail = JITSessionText.detail(for: phase, appName: session.appName)
            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(phase == .appQuit ? Color.primary : Color.green)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("View Log".localized, action: showLog)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
            .shadow(radius: 4)
            .padding(.horizontal, 20)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The capsule HomeView showed while a session starts: a spinner and "Starting JIT for <app>".
private struct JITSessionStartingCapsule: View {
    let appName: String

    var body: some View {
        let message = String(format: "Starting JIT for %@".localized, appName)
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .foregroundStyle(.primary)
        .shadow(radius: 4)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}
