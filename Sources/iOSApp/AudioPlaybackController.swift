import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var activeChunkID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress = 0.0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var playlistSessionID: UUID?
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var resumeMessage: String?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var remainingChunks: [PhoneRecordingChunk] = []
    private var playlistDirectory: URL?
    private var interruptionObserver: NSObjectProtocol?
    private var audioObservers: [NSObjectProtocol] = []
    private let positions: PlaybackPositionStore
    private var activeHash: String?
    private var playlistIDs: [UUID] = []
    private var lastPositionSave: TimeInterval = 0

    init(positions: PlaybackPositionStore? = nil) {
        self.positions = positions ?? PlaybackPositionStore()
        super.init()
        audioObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.savePosition() }
        })
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if rawType == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        }
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            audioObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player != nil else { return }
                    self.stop()
                    self.errorMessage = "系统音频服务已中断，请点按重新播放；录音文件已保留"
                }
            })
        }
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.pause() }
        })
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func toggleSession(chunks: [PhoneRecordingChunk], directory: URL, allowGaps: Bool = false) {
        do {
            let ordered = try RecordingSessionPlan.orderedChunks(chunks, allowGaps: allowGaps)
            if RecordingSessionPlan.matchesPlaylist(sessionID: playlistSessionID, orderedIDs: playlistIDs, chunks: ordered), let player {
                player.isPlaying ? pause() : resume()
                return
            }
            stop()
            playlistIDs = ordered.map(\.id)
            remainingChunks = ordered
            playlistDirectory = directory
            playlistSessionID = ordered.first?.sessionID
            playNextChunk()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func seek(to fraction: Double) {
        guard let player, fraction.isFinite else { return }
        player.currentTime = min(1, max(0, fraction)) * player.duration
        currentTime = player.currentTime
        progress = min(1, max(0, fraction))
        if fraction <= 0 { savePosition() }
        if fraction <= 0 { resumeMessage = "已回到开头" }
    }

    func finishSeeking() { savePosition() }

    func setPlaybackRate(_ rate: Float) {
        guard [Float(0.75), 1, 1.25, 1.5, 2].contains(rate) else { return }
        playbackRate = rate
        player?.enableRate = true
        player?.rate = rate
    }

    func skip(seconds: TimeInterval) {
        guard let player, player.duration > 0 else { return }
        seek(to: (player.currentTime + seconds) / player.duration)
        savePosition()
    }

    func toggle(chunk: PhoneRecordingChunk, url: URL) {
        if activeChunkID == chunk.id, let player {
            player.isPlaying ? pause() : resume()
            return
        }
        play(chunk: chunk, url: url)
    }

    func stop() {
        remainingChunks = []
        playlistSessionID = nil
        playlistDirectory = nil
        playlistIDs = []
        stopCurrentPlayer()
    }

    private func stopCurrentPlayer() {
        savePosition()
        player?.stop()
        player = nil
        activeChunkID = nil
        activeHash = nil
        isPlaying = false
        progress = 0
        currentTime = 0
        duration = 0
        invalidateTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func isActive(_ chunk: PhoneRecordingChunk) -> Bool {
        activeChunkID == chunk.id
    }
    func isPlayingPlaylist(_ chunks: [PhoneRecordingChunk]) -> Bool {
        isPlaying && RecordingSessionPlan.matchesPlaylist(sessionID: playlistSessionID, orderedIDs: playlistIDs, chunks: chunks)
    }

    private func play(chunk: PhoneRecordingChunk, url: URL, preservingPlaylist: Bool = false) {
        if preservingPlaylist { stopCurrentPlayer() } else { stop() }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            let saved = positions.position(for: chunk.id, sha256: chunk.sha256, duration: player.duration)
            player.currentTime = saved
            guard player.play() else { throw PlaybackError.couldNotStart }

            self.player = player
            activeChunkID = chunk.id
            activeHash = chunk.sha256
            currentTime = saved
            progress = player.duration > 0 ? saved / player.duration : 0
            resumeMessage = saved > 0 ? "已从上次位置继续，可点“回到开头”重置" : positions.lastError
            duration = player.duration
            isPlaying = true
            errorMessage = nil
            beginTimer()
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    private func playNextChunk() {
        guard let directory = playlistDirectory, !remainingChunks.isEmpty else {
            stop()
            return
        }
        let chunk = remainingChunks.removeFirst()
        play(chunk: chunk, url: directory.appendingPathComponent(chunk.filename), preservingPlaylist: true)
    }

    private func pause() {
        player?.pause()
        savePosition()
        isPlaying = false
        invalidateTimer()
    }

    private func resume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard player?.play() == true else {
            errorMessage = PlaybackError.couldNotStart.localizedDescription
            return
        }
        isPlaying = true
        beginTimer()
    }

    private func beginTimer() {
        invalidateTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if ProcessInfo.processInfo.systemUptime - self.lastPositionSave >= 10 { self.savePosition() }
            }
        }
    }

    private func invalidateTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func savePosition() {
        guard let player, let id = activeChunkID, let activeHash else { return }
        positions.remember(id: id, sha256: activeHash, seconds: player.currentTime, duration: player.duration)
        lastPositionSave = ProcessInfo.processInfo.systemUptime
        if let error = positions.lastError { resumeMessage = error }
    }

    private func handlePlaybackFinished(playerID: ObjectIdentifier, successfully: Bool) {
        guard let player, ObjectIdentifier(player) == playerID else { return }
        if !successfully {
            errorMessage = "本段播放异常，已停止连播；请检查该分段"
            stop()
        } else if playlistSessionID != nil {
            playNextChunk()
        } else {
            stop()
        }
    }

    private func handleDecodeError(
        playerID: ObjectIdentifier,
        errorDescription: String?
    ) {
        guard let player, ObjectIdentifier(player) == playerID else { return }
        errorMessage = errorDescription ?? "音频解码失败"
        stop()
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.handlePlaybackFinished(playerID: playerID, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleDecodeError(
                playerID: playerID,
                errorDescription: errorDescription
            )
        }
    }
}

private enum PlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? { "无法开始播放这段录音" }
}
