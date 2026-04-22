import MediaPlayer
import AudioServiceCore
import OSLog

/// Manager for handling remote control commands and Now Playing info
///
/// Provides customization through `RemoteCommandDelegate`:
/// - Custom command handlers
/// - Custom Now Playing info
/// - Configure which commands are enabled
///
/// **Example:**
/// ```swift
/// let player = try await AudioPlayerService()
/// player.remoteCommands.delegate = myDelegate
/// ```
///
/// All operations are @MainActor isolated for thread safety.
@MainActor
final class RemoteCommandManager {
    private static let logger = Logger(category: "RemoteCommand")
    
    // MARK: - Properties
    
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingCenter: MPNowPlayingInfoCenter
    
    /// Delegate for customizing remote command behavior
    weak var delegate: RemoteCommandDelegate?
    
    // Store handlers for delegate callback integration
    private var playHandler: (@Sendable () async -> Void)?
    private var pauseHandler: (@Sendable () async -> Void)?
    private var stopHandler: (@Sendable () async -> Void)?
    private var togglePlayPauseHandler: (@Sendable () async -> Void)?
    private var skipForwardHandler: (@Sendable (TimeInterval) async -> Void)?
    private var skipBackwardHandler: (@Sendable (TimeInterval) async -> Void)?
    private var nextTrackHandler: (@Sendable () async -> Void)?
    private var previousTrackHandler: (@Sendable () async -> Void)?
    private var seekToHandler: (@Sendable (TimeInterval) async -> Void)?
    private var changePlaybackRateHandler: (@Sendable (Float) async -> Void)?
    
    // Current track for delegate callbacks
    private var currentTrack: Track.Metadata?
    private var currentPosition: PlaybackPosition = PlaybackPosition(currentTime: 0, duration: 0)
    
    // MARK: - Initialization
    
    init() {
        self.commandCenter = MPRemoteCommandCenter.shared()
        self.nowPlayingCenter = MPNowPlayingInfoCenter.default()
        Self.logger.info("[RemoteCommand] Initialized")
    }
    
    // MARK: - Setup Commands
    
    func setupCommands(
        playHandler: @escaping @Sendable () async -> Void,
        pauseHandler: @escaping @Sendable () async -> Void,
        skipForwardHandler: @escaping @Sendable (TimeInterval) async -> Void,
        skipBackwardHandler: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        // Store handlers
        self.playHandler = playHandler
        self.pauseHandler = pauseHandler
        self.skipForwardHandler = skipForwardHandler
        self.skipBackwardHandler = skipBackwardHandler
        
        // Configure commands based on delegate or defaults
        configureCommands()
    }
    
    /// Reconfigure commands (call after changing delegate)
    func reconfigure() {
        removeCommands()
        configureCommands()
    }
    
    private func configureCommands() {
        Self.logger.info("[RemoteCommand] Setting up commands...")
        
        let enabledCommands = delegate?.remoteCommandEnabledCommands() ?? .standard
        let skipIntervals = delegate?.remoteCommandSkipIntervals() ?? (forward: 15.0, backward: 15.0)
        let playbackRates = delegate?.remoteCommandSupportedPlaybackRates() ?? [0.5, 1.0, 1.5, 2.0]
        
        // Play command
        commandCenter.playCommand.isEnabled = enabledCommands.contains(.play)
        if enabledCommands.contains(.play) {
            commandCenter.playCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandlePlay() ?? true
                    if shouldUseDefault {
                        await self.playHandler?()
                    }
                }
                return .success
            }
        }
        
        // Pause command
        commandCenter.pauseCommand.isEnabled = enabledCommands.contains(.pause)
        if enabledCommands.contains(.pause) {
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandlePause() ?? true
                    if shouldUseDefault {
                        await self.pauseHandler?()
                    }
                }
                return .success
            }
        }
        
        // Stop command
        commandCenter.stopCommand.isEnabled = enabledCommands.contains(.stop)
        if enabledCommands.contains(.stop) {
            commandCenter.stopCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleStop() ?? true
                    if shouldUseDefault {
                        await self.stopHandler?()
                    }
                }
                return .success
            }
        }
        
        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = enabledCommands.contains(.togglePlayPause)
        if enabledCommands.contains(.togglePlayPause) {
            commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleTogglePlayPause() ?? true
                    if shouldUseDefault {
                        await self.togglePlayPauseHandler?()
                    }
                }
                return .success
            }
        }
        
        // Skip forward command
        commandCenter.skipForwardCommand.isEnabled = enabledCommands.contains(.skipForward)
        if enabledCommands.contains(.skipForward) {
            commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipIntervals.forward)]
            commandCenter.skipForwardCommand.addTarget { [weak self] event in
                if let skipEvent = event as? MPSkipIntervalCommandEvent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleSkipForward(skipEvent.interval) ?? true
                        if shouldUseDefault {
                            await self.skipForwardHandler?(skipEvent.interval)
                        }
                    }
                }
                return .success
            }
        }
        
        // Skip backward command
        commandCenter.skipBackwardCommand.isEnabled = enabledCommands.contains(.skipBackward)
        if enabledCommands.contains(.skipBackward) {
            commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipIntervals.backward)]
            commandCenter.skipBackwardCommand.addTarget { [weak self] event in
                if let skipEvent = event as? MPSkipIntervalCommandEvent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleSkipBackward(skipEvent.interval) ?? true
                        if shouldUseDefault {
                            await self.skipBackwardHandler?(skipEvent.interval)
                        }
                    }
                }
                return .success
            }
        }
        
        // Next track command
        commandCenter.nextTrackCommand.isEnabled = enabledCommands.contains(.nextTrack)
        if enabledCommands.contains(.nextTrack) {
            commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleNextTrack() ?? true
                    if shouldUseDefault {
                        await self.nextTrackHandler?()
                    }
                }
                return .success
            }
        }
        
        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = enabledCommands.contains(.previousTrack)
        if enabledCommands.contains(.previousTrack) {
            commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldUseDefault = await self.delegate?.remoteCommandShouldHandlePreviousTrack() ?? true
                    if shouldUseDefault {
                        await self.previousTrackHandler?()
                    }
                }
                return .success
            }
        }
        
        // Seek to position command
        commandCenter.changePlaybackPositionCommand.isEnabled = enabledCommands.contains(.seekTo)
        if enabledCommands.contains(.seekTo) {
            commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleSeekTo(positionEvent.positionTime) ?? true
                        if shouldUseDefault {
                            await self.seekToHandler?(positionEvent.positionTime)
                        }
                    }
                }
                return .success
            }
        }
        
        // Change playback rate command
        commandCenter.changePlaybackRateCommand.isEnabled = enabledCommands.contains(.changePlaybackRate)
        if enabledCommands.contains(.changePlaybackRate) {
            commandCenter.changePlaybackRateCommand.supportedPlaybackRates = playbackRates.map { NSNumber(value: $0) }
            commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
                if let rateEvent = event as? MPChangePlaybackRateCommandEvent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let shouldUseDefault = await self.delegate?.remoteCommandShouldHandleChangePlaybackRate(rateEvent.playbackRate) ?? true
                        if shouldUseDefault {
                            await self.changePlaybackRateHandler?(rateEvent.playbackRate)
                        }
                    }
                }
                return .success
            }
        }
        
        // Disable unsupported seek commands (different from changePlaybackPositionCommand)
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        
        Self.logger.info("[RemoteCommand] Commands setup completed. Enabled: \(enabledCommands.rawValue)")
    }
    
    func removeCommands() {
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackRateCommand.removeTarget(nil)
        
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
    }
    
    // MARK: - Extended Handlers Setup
    
    /// Set additional handlers for commands not covered by basic setup
    func setExtendedHandlers(
        stopHandler: (@Sendable () async -> Void)? = nil,
        togglePlayPauseHandler: (@Sendable () async -> Void)? = nil,
        nextTrackHandler: (@Sendable () async -> Void)? = nil,
        previousTrackHandler: (@Sendable () async -> Void)? = nil,
        seekToHandler: (@Sendable (TimeInterval) async -> Void)? = nil,
        changePlaybackRateHandler: (@Sendable (Float) async -> Void)? = nil
    ) {
        self.stopHandler = stopHandler
        self.togglePlayPauseHandler = togglePlayPauseHandler
        self.nextTrackHandler = nextTrackHandler
        self.previousTrackHandler = previousTrackHandler
        self.seekToHandler = seekToHandler
        self.changePlaybackRateHandler = changePlaybackRateHandler
    }
    
    // MARK: - Now Playing Info
    
    func updateNowPlayingInfo(
        title: String?,
        artist: String?,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        playbackRate: Double
    ) {
        // Check delegate for custom info first
        if let track = currentTrack {
            currentPosition = PlaybackPosition(currentTime: elapsedTime, duration: duration)
            if let customInfo = delegate?.remoteCommandNowPlayingInfo(for: track, position: currentPosition) {
                nowPlayingCenter.nowPlayingInfo = customInfo
                Self.logger.info("[RemoteCommand] Using delegate's custom Now Playing info")
                return
            }
        }
        
        Self.logger.info("[RemoteCommand] updateNowPlayingInfo:")
        Self.logger.info("  title: \(title ?? "nil"), artist: \(artist ?? "nil")")
        Self.logger.info("  duration: \(duration), elapsed: \(elapsedTime), rate: \(playbackRate)")
        
        var nowPlayingInfo = [String: Any]()
        
        if let title = title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        
        if let artist = artist {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        
        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
        Self.logger.info("[RemoteCommand] Now playing info updated")
    }
    
    func updatePlaybackPosition(
        elapsedTime: TimeInterval,
        playbackRate: Double
    ) {
        // Check delegate for custom info first
        if let track = currentTrack {
            currentPosition = PlaybackPosition(currentTime: elapsedTime, duration: currentPosition.duration)
            if let customInfo = delegate?.remoteCommandNowPlayingInfo(for: track, position: currentPosition) {
                nowPlayingCenter.nowPlayingInfo = customInfo
                return
            }
        }
        
        guard var info = nowPlayingCenter.nowPlayingInfo else { return }
        
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        
        nowPlayingCenter.nowPlayingInfo = info
    }
    
    func clearNowPlayingInfo() {
        currentTrack = nil
        nowPlayingCenter.nowPlayingInfo = nil
    }
    
    // MARK: - Helper Methods for Protocol Conformance
    
    func updateNowPlayingInfo(track: Track.Metadata) {
        currentTrack = track
        updateNowPlayingInfo(
            title: track.title,
            artist: track.artist,
            duration: track.duration,
            elapsedTime: 0,
            playbackRate: 0
        )
    }
    
    func updateNowPlayingPlaybackRate(_ rate: Float) {
        // Check delegate for custom info first
        if let track = currentTrack {
            if let customInfo = delegate?.remoteCommandNowPlayingInfo(for: track, position: currentPosition) {
                nowPlayingCenter.nowPlayingInfo = customInfo
                return
            }
        }
        
        guard var info = nowPlayingCenter.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(rate)
        nowPlayingCenter.nowPlayingInfo = info
    }
    
    func updateNowPlayingPosition(_ position: PlaybackPosition) {
        currentPosition = position
        updatePlaybackPosition(
            elapsedTime: position.currentTime,
            playbackRate: 1.0
        )
    }
}

// MARK: - RemoteCommandManaging Conformance

extension RemoteCommandManager: RemoteCommandManaging {
    func updateNowPlaying(track: Track.Metadata) async {
        updateNowPlayingInfo(track: track)
    }
    
    func updatePlaybackRate(_ rate: Float) async {
        updateNowPlayingPlaybackRate(rate)
    }
    
    func clearNowPlaying() async {
        clearNowPlayingInfo()
    }
    
    func updatePlaybackPosition(_ position: PlaybackPosition) async {
        updateNowPlayingPosition(position)
    }
}
