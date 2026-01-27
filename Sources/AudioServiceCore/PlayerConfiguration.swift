import Foundation

/// Repeat mode for playback
public enum RepeatMode: Sendable, Equatable {
    /// Play once, no repeat
    case off

    /// Loop current track with fade in/out
    case singleTrack

    /// Loop entire playlist
    case playlist
}

/// Simplified player configuration with automatic fade calculations
/// Replaces AudioConfiguration with more intuitive API
///
/// **Audio Session:** App must configure `AVAudioSession` before creating player.
/// SDK validates session state at init and recovers engine if needed.
///
/// ```swift
/// // 1. App configures session (required)
/// let session = AVAudioSession.sharedInstance()
/// try session.setCategory(.playback)
/// try session.setActive(true)
///
/// // 2. Create player
/// let config = PlayerConfiguration(crossfadeDuration: 5.0)
/// let player = try await AudioPlayerService(configuration: config)
/// ```
public struct PlayerConfiguration: Sendable {

    // MARK: - Crossfade Settings

    /// Crossfade duration between tracks (Spotify-style)
    ///
    /// Both tracks fade simultaneously over the full duration:
    /// - Outgoing track: fade OUT from 1.0 to 0.0 over `crossfadeDuration`
    /// - Incoming track: fade IN from 0.0 to 1.0 over `crossfadeDuration`
    /// - Total overlap: equals `crossfadeDuration`
    ///
    /// Valid range: 0.0-30.0 seconds (0.0 = instant switch, no crossfade)
    public let crossfadeDuration: TimeInterval

    /// Fade curve algorithm
    public let fadeCurve: FadeCurve

    // MARK: - Playback Mode

    /// Repeat mode for playback (default: .off)
    /// - .off: Play once, no repeat
    /// - .singleTrack: Loop current track with fade in/out
    /// - .playlist: Loop entire playlist
    public let repeatMode: RepeatMode

    /// Number of times to repeat playlist
    /// - nil: Infinite repeats (loop forever)
    /// - 0: Play once (same as repeatMode = .off)
    /// - N: Loop N times then stop
    public let repeatCount: Int?

    // MARK: - Audio Settings

    /// Volume level (0.0 = silent, 1.0 = maximum)
    /// Standard AVFoundation audio range
    public let volume: Float

    // MARK: - Initialization

    public init(
        crossfadeDuration: TimeInterval = 10.0,
        fadeCurve: FadeCurve = .equalPower,
        repeatMode: RepeatMode = .off,
        repeatCount: Int? = nil,
        volume: Float = 1.0
    ) {
        self.crossfadeDuration = max(0.0, min(30.0, crossfadeDuration))
        self.fadeCurve = fadeCurve
        self.repeatMode = repeatMode
        self.repeatCount = repeatCount
        self.volume = max(0.0, min(1.0, volume))
    }

    // MARK: - Default Configuration

    /// Default configuration with sensible defaults
    public static let `default` = PlayerConfiguration()

    // MARK: - Validation

    /// Validate configuration values
    /// - Throws: ConfigurationError if invalid
    public func validate() throws {
        // Crossfade duration range check
        if crossfadeDuration < 0.0 || crossfadeDuration > 30.0 {
            throw ConfigurationError.invalidCrossfadeDuration(crossfadeDuration)
        }

        // Volume range check
        if volume < 0.0 || volume > 1.0 {
            throw ConfigurationError.invalidVolume(volume)
        }

        // RepeatCount validation
        if let count = repeatCount, count < 0 {
            throw ConfigurationError.invalidRepeatCount(count)
        }
    }
}

// MARK: - Configuration Errors

public enum ConfigurationError: Error, LocalizedError {
    case invalidCrossfadeDuration(TimeInterval)
    case invalidVolume(Float)
    case invalidRepeatCount(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCrossfadeDuration(let duration):
            return "Crossfade duration must be between 0.0 and 30.0 seconds (got \(duration))"
        case .invalidVolume(let volume):
            return "Volume must be between 0.0 and 1.0 (got \(volume))"
        case .invalidRepeatCount(let count):
            return "Repeat count must be >= 0 or nil for infinite (got \(count))"
        }
    }
}
