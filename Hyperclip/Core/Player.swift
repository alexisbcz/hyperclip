import AVFoundation
import Observation

/// The editor's player: the current time, play and pause, and playing just a clip.
@Observable
final class Player {
    let avPlayer = AVPlayer()
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var url: URL?
    /// Playing a clip stops at its end.
    private(set) var stopAt: Double?

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?

    init() {
        avPlayer.actionAtItemEnd = .pause
        observer = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
            MainActor.assumeIsolated { Player.tick(time.seconds) }
        }
        rateObserver = avPlayer.observe(\.rate) { player, _ in
            let playing = player.rate != 0
            Task { @MainActor in Player.current?.isPlaying = playing }
        }
        Player.current = self
    }

    /// The one player, for the time observer's callback.
    private static weak var current: Player?

    private static func tick(_ seconds: Double) {
        guard let player = current, seconds.isFinite else { return }
        player.time = seconds
        if let stop = player.stopAt, seconds >= stop {
            player.avPlayer.pause()
            player.stopAt = nil
        }
    }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        stopAt = nil
        time = 0
        duration = 0
        let item = AVPlayerItem(url: url)
        avPlayer.replaceCurrentItem(with: item)
        Task {
            if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite { duration = seconds }
        }
    }

    func unload() {
        avPlayer.replaceCurrentItem(with: nil)
        url = nil
    }

    func toggle() {
        if isPlaying {
            avPlayer.pause()
        } else {
            if duration > 0, time >= duration - 0.05 { seek(to: 0) }
            avPlayer.play()
        }
    }

    func pause() { avPlayer.pause() }

    func seek(to seconds: Double, precise: Bool = true) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        time = target
        if let stop = stopAt, target >= stop { stopAt = nil }
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func step(by seconds: Double) { seek(to: time + seconds) }

    /// Plays from the start of a range and stops at its end.
    func play(_ range: ClosedRange<Double>) {
        seek(to: range.lowerBound)
        stopAt = range.upperBound
        avPlayer.play()
    }
}
