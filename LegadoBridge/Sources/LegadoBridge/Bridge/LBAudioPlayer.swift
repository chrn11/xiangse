import Foundation
import AVFoundation

/// 简易音频播放器（直链 / 内存 Data）
@objc public final class LBAudioPlayer: NSObject {
    @objc public static let shared = LBAudioPlayer()

    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?

    @objc public private(set) var isPlaying = false
    @objc public private(set) var duration: TimeInterval = 0
    @objc public private(set) var currentTime: TimeInterval = 0
    @objc public private(set) var currentURL: String?

    private override init() {
        super.init()
    }

    @objc(prepareWithURL:)
    public func prepare(urlString: String) -> Bool {
        stop()
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        currentURL = trimmed
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DebugLogger.shared.log("[LBAudioPlayer] session: \(error)")
        }
        if trimmed.hasPrefix("file://") || trimmed.hasPrefix("/") {
            let fileURL = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : url
            do {
                let p = try AVAudioPlayer(contentsOf: fileURL)
                p.prepareToPlay()
                player = p
                duration = p.duration
                return true
            } catch {
                DebugLogger.shared.log("[LBAudioPlayer] file: \(error)")
                return false
            }
        }
        avPlayer = AVPlayer(url: url)
        duration = 0
        return true
    }

    /// Core / 调用方简写
    @discardableResult
    public func prepare(url: String) -> Bool {
        prepare(urlString: url)
    }

    @objc(prepareWithData:)
    public func prepare(data: Data) -> Bool {
        stop()
        currentURL = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.prepareToPlay()
            player = p
            duration = p.duration
            return true
        } catch {
            DebugLogger.shared.log("[LBAudioPlayer] data: \(error)")
            return false
        }
    }

    @objc public func play() {
        if let player {
            player.play()
            isPlaying = true
            duration = player.duration
            currentTime = player.currentTime
            return
        }
        avPlayer?.play()
        isPlaying = true
    }

    @objc public func pause() {
        player?.pause()
        avPlayer?.pause()
        isPlaying = false
        currentTime = player?.currentTime ?? currentTime
    }

    @objc public func stop() {
        player?.stop()
        player = nil
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
    }

    @objc(seekToTime:)
    public func seek(to time: TimeInterval) {
        if let player {
            player.currentTime = min(max(0, time), player.duration)
            currentTime = player.currentTime
            return
        }
        let cm = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cm)
        currentTime = time
    }

    @objc public func refreshProgress() {
        if let player {
            currentTime = player.currentTime
            duration = player.duration
            isPlaying = player.isPlaying
        }
    }
}
