//
//  BackgroundAudioManager.swift
//  StikDebug
//

import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    // All state below lives on this queue, and every request returns at once: activating the audio session and
    // starting the engine can take seconds, and must not hold up the main thread or the caller.
    private let queue = DispatchQueue(label: "com.stik.keepalive.audio", qos: .userInitiated)
    /// Set at the end of init (before `shared` is handed out), never changed.
    private var counter: SerialActivityCounter!

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isRunning = false
    private var healthCheckTimer: DispatchSourceTimer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        counter = SerialActivityCounter(queue: queue) { [weak self] count in
            self?.refreshRunningState(activityCount: count)
        }
    }

    func configurationDidChange() {
        queue.async {
            self.refreshRunningState(activityCount: self.counter.valueOnQueue)
        }
    }

    func requestStart() {
        counter.increment()
    }

    func requestStop() {
        counter.decrement()
    }

    /// On the queue.
    private func refreshRunningState(activityCount: Int) {
        let shouldRun = activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveAudio")
        guard shouldRun != isRunning else {
            if shouldRun {
                recoverIfNeeded()
            }
            return
        }

        isRunning = shouldRun
        if shouldRun {
            startEngine()
            startHealthCheck()
        } else {
            healthCheckTimer?.cancel()
            healthCheckTimer = nil
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// On the queue.
    private func startEngine() {
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)

            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            scheduleSilence()
            try engine.start()
            player.play()
        } catch {
            LogManager.shared.addErrorLog("BackgroundAudioManager: \(error.localizedDescription)")
        }
    }

    private func scheduleSilence() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // PCM buffer is zero-initialized — pure silence
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    // Runs every 2 seconds to reclaim the session if continuous game audio
    // holds it and the interruption-ended notification never fires.
    private func startHealthCheck() {
        healthCheckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.recoverIfNeeded()
        }
        timer.resume()
        healthCheckTimer = timer
    }

    /// On the queue.
    private func recoverIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            // Session still held by the game — will retry next tick
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }

        queue.async {
            guard self.isRunning else { return }
            // Best-effort immediate resume; health check will cover failures.
            try? AVAudioSession.sharedInstance().setActive(true)
            if !self.engine.isRunning { try? self.engine.start() }
            self.player.play()
        }
    }

    @objc private func handleMediaServicesReset() {
        queue.async {
            guard self.isRunning else { return }
            self.engine = AVAudioEngine()
            self.player = AVAudioPlayerNode()
            self.startEngine()
        }
    }
}
