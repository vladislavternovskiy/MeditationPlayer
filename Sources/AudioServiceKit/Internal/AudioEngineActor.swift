@preconcurrency import AVFoundation
import AudioServiceCore

/// Actor that isolates AVAudioEngine for thread-safe access
actor AudioEngineActor {
    // MARK: - Audio Engine Components

    private let engine: AVAudioEngine

    // Dual player setup for crossfading
    private let playerNodeA: AVAudioPlayerNode
    private let playerNodeB: AVAudioPlayerNode
    private let mixerNodeA: AVAudioMixerNode
    private let mixerNodeB: AVAudioMixerNode

    // Overlay player nodes (always attached, ready for use)
    // nonisolated(unsafe): Safe because nodes are created once, attached once,
    // then transferred to OverlayPlayerActor where they're exclusively accessed
    private nonisolated(unsafe) let playerNodeC: AVAudioPlayerNode
    private nonisolated(unsafe) let mixerNodeC: AVAudioMixerNode

    // Sound effects player nodes (always attached, ready for use)
    // nonisolated(unsafe): Safe because nodes are created once, attached once,
    // then transferred to SoundEffectsPlayerActor where they're exclusively accessed
    internal nonisolated(unsafe) let playerNodeD: AVAudioPlayerNode
    internal nonisolated(unsafe) let mixerNodeD: AVAudioMixerNode

    // Track which player is currently active
    private var activePlayer: PlayerNode = .a

    // Currently loaded audio files
    private var audioFileA: AVAudioFile?
    private var audioFileB: AVAudioFile?

    // Playback state
    private var isEngineRunning = false

    // Playback offset tracking for accurate seeking
    private var playbackOffsetA: AVAudioFramePosition = 0
    private var playbackOffsetB: AVAudioFramePosition = 0

    // Audio file cache for performance
    private let cache = AudioFileCache()

    // Crossfade task management
    private var activeCrossfadeTask: Task<Void, Never>?
    private var crossfadeProgressContinuation: AsyncStream<CrossfadeProgress>.Continuation?
    
    // Fade-in task management (for initial playback fade-in)
    private var activeFadeInTask: Task<Void, Never>?

    /// Is crossfade currently in progress
    var isCrossfading: Bool { activeCrossfadeTask != nil }
    
    /// Cancellation flag for crossfade operations
    private var isCrossfadeCancelled: Bool = false

    // Volume management
    /// Target volume set by user (0.0-1.0)
    /// Crossfade curves are scaled to this target for smooth volume changes
    private var targetVolume: Float = 1.0
    
    // MARK: - Natural Playback End Detection
    
    /// Generation counter for schedule callbacks
    /// Incremented on each new schedule, callbacks check if their generation matches current
    /// This prevents stale callbacks (from previous schedules) from triggering false natural-end events
    private var scheduleGenerationA: UInt64 = 0
    private var scheduleGenerationB: UInt64 = 0
    
    /// Continuation for signaling natural playback end to subscribers
    private var playbackEndContinuation: AsyncStream<PlayerNode>.Continuation?
    
    // Logger
    private static let logger = Logger.engine

    // MARK: - Overlay Player

    /// Overlay player for independent ambient audio
    /// 
    /// **Architecture Note:**
    /// Overlay system follows clean actor separation (OverlayPlayerActor receives nodes from outside).
    /// Main player system (playerA/B, mixerA/B) is embedded directly in AudioEngineActor for:
    /// - Zero await overhead on position tracking (60 FPS)
    /// - Simpler state management for complex crossfade logic
    /// - Historical reasons (evolved from v1.0 monolithic design)
    /// 
    /// This creates architectural inconsistency (technical debt) but maintains performance.
    /// **Future v4.0:** Consider extracting MainPlayerActor if position tracking can tolerate async overhead.
    internal var overlayPlayer: OverlayPlayerActor?

    /// Current overlay configuration (persists across playOverlay calls)
    private var overlayConfiguration: OverlayConfiguration = .default

    // MARK: - Initialization

    init() {
        self.engine = AVAudioEngine()
        self.playerNodeA = AVAudioPlayerNode()
        self.playerNodeB = AVAudioPlayerNode()
        self.mixerNodeA = AVAudioMixerNode()
        self.mixerNodeB = AVAudioMixerNode()
        self.playerNodeC = AVAudioPlayerNode()
        self.mixerNodeC = AVAudioMixerNode()
        self.playerNodeD = AVAudioPlayerNode()
        self.mixerNodeD = AVAudioMixerNode()
    }

    // MARK: - Setup

    func setup() throws {
        try setupAudioGraph()
    }

    private func setupAudioGraph() throws {
        // Attach all nodes to engine
        engine.attach(playerNodeA)
        engine.attach(playerNodeB)
        engine.attach(mixerNodeA)
        engine.attach(mixerNodeB)

        // Attach overlay nodes (always ready for use)
        engine.attach(playerNodeC)
        engine.attach(mixerNodeC)

        // Attach sound effects nodes (always ready for use)
        engine.attach(playerNodeD)
        engine.attach(mixerNodeD)

        // Use explicit stereo format (2 channels)
        // CRITICAL: With .playAndRecord category, outputNode may return mono (1ch)
        // We force stereo to ensure compatibility with all audio files
        // AVAudioMixerNode will automatically convert mono files to stereo if needed
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AudioPlayerError.engineStartFailed(reason: "Failed to create stereo audio format")
        }

        // 🔍 DIAGNOSTIC: Log engine format
        Self.logger.debug(" Setup format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        // Connect player A: playerA -> mixerA -> mainMixer
        engine.connect(playerNodeA, to: mixerNodeA, format: format)
        engine.connect(mixerNodeA, to: engine.mainMixerNode, format: format)

        // Connect player B: playerB -> mixerB -> mainMixer
        engine.connect(playerNodeB, to: mixerNodeB, format: format)
        engine.connect(mixerNodeB, to: engine.mainMixerNode, format: format)

        // Connect overlay player C: playerC -> mixerC -> mainMixer
        engine.connect(playerNodeC, to: mixerNodeC, format: format)
        engine.connect(mixerNodeC, to: engine.mainMixerNode, format: format)

        // Connect sound effects player D: playerD -> mixerD -> mainMixer
        // All sound effect buffers are converted to stereo in SoundEffect.init
        engine.connect(playerNodeD, to: mixerNodeD, format: format)
        engine.connect(mixerNodeD, to: engine.mainMixerNode, format: format)

        // Set initial volumes
        mixerNodeA.volume = 0.0
        mixerNodeB.volume = 0.0
        mixerNodeC.volume = 0.0  // Overlay starts silent
        engine.mainMixerNode.volume = 1.0
    }

    // MARK: - Engine Control

    func prepare() throws {
        // Ensure nodes are attached before preparing
        guard engine.outputNode.engine != nil else {
            throw AudioPlayerError.engineStartFailed(
                reason: "Audio engine not properly initialized - nodes not attached"
            )
        }

        // CRITICAL: Must prepare AFTER nodes are connected and AFTER audio session is active
        engine.prepare()
    }

    func start() throws {
        // CRITICAL: Check ACTUAL engine state, not just our flag
        // iOS can stop engine due to inactivity even if isEngineRunning=true
        if engine.isRunning {
            isEngineRunning = true  // Sync flag with reality
            return
        }

        try engine.start()
        isEngineRunning = true
    }

    func stop() {
        Self.logger.debug("→ stop()")

        guard isEngineRunning else { return }

        // Increment generations to invalidate any pending callbacks
        scheduleGenerationA &+= 1
        scheduleGenerationB &+= 1
        
        playerNodeA.stop()
        playerNodeB.stop()
        engine.stop()
        Self.logger.debug("← stop() completed: isEngineRunning=\(isEngineRunning)")

        isEngineRunning = false
    }

    /// Reset engine running state after media services reset
    /// Call this when audio services crash - engine.isRunning may be stale
    func resetEngineRunningState() {
        isEngineRunning = false
    }

    func pause() {
        Self.logger.debug("→ pause()")
        Self.logger.debug("  activePlayer: \(activePlayer), playerA.isPlaying: \(playerNodeA.isPlaying), playerB.isPlaying: \(playerNodeB.isPlaying)")

        // 1. Capture current position in offset before pausing
        // This ensures position is preserved for accurate resume
        if let current = getCurrentPosition() {
            let sampleRate = getActiveAudioFile()?.fileFormat.sampleRate ?? 44100
            let currentFrame = AVAudioFramePosition(current.currentTime * sampleRate)

            if activePlayer == .a {
                playbackOffsetA = currentFrame
            } else {
                playbackOffsetB = currentFrame
            }
        }

        
        Self.logger.debug("← pause() completed")

        // 2. Pause BOTH players (safe during crossfade)
        playerNodeA.pause()
        Self.logger.debug("→ play()")
        Self.logger.debug("  activePlayer: \(activePlayer), playerA.isPlaying: \(playerNodeA.isPlaying), playerB.isPlaying: \(playerNodeB.isPlaying)")
        
        let player = getActivePlayerNode()
        Self.logger.debug("  Using player: \(player === playerNodeA ? "A" : "B")")

        playerNodeB.pause()
    }

    func play() {
        let player = getActivePlayerNode()
        guard let file = getActiveAudioFile() else { return }

        // Get saved offset
        let offset = activePlayer == .a ? playbackOffsetA : playbackOffsetB
        // Prevents crash when offset >= file.length (negative remainingFrames)
        guard offset < file.length else {
            Logger.audio.error("Cannot play: offset (\(offset)) >= file.length (\(file.length))")
            Logger.audio.error("This may indicate corrupted test file or invalid state")
            return
        }
        // AVFoundation quirk: isPlaying may be unreliable after pause()
        // Strategy: If player is not playing AND we have an offset, it's a resume
        let needsReschedule = true//!player.isPlaying && offset > 0

        if needsReschedule {
            // Resume from saved position
            // Stop player completely to clear any stale state
            player.stop()
            
            // Increment generation to invalidate any pending callbacks
            let currentActivePlayer = activePlayer
            let generation: UInt64
            if currentActivePlayer == .a {
                scheduleGenerationA &+= 1
                generation = scheduleGenerationA
            } else {
                scheduleGenerationB &+= 1
                generation = scheduleGenerationB
            }

            // Reschedule from offset (like seek) with natural end detection
            let remainingFrames = AVAudioFrameCount(file.length - offset)
            if remainingFrames > 0 {
                player.scheduleSegment(
                    file,
                    startingFrame: offset,
                    frameCount: remainingFrames,
                    at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.handlePlaybackCompletion(for: currentActivePlayer, generation: generation)
                    }
                }
            }
        }

        // Play (either fresh scheduled buffer or continue)
        player.play()
        
        Self.logger.debug("← play() completed: player.isPlaying=\(player.isPlaying)")

    }

    /// Stop both players completely and reset volumes
    func stopBothPlayers() async {
        // 🔍 DIAGNOSTIC: Log before stopping
        let playerAPlaying = playerNodeA.isPlaying
        let playerBPlaying = playerNodeB.isPlaying
        let mixerAVol = mixerNodeA.volume
        let mixerBVol = mixerNodeB.volume
        Self.logger.debug("[STOP_DIAGNOSTIC] stopBothPlayers: playerA.isPlaying=\(playerAPlaying), playerB.isPlaying=\(playerBPlaying), mixerA.vol=\(mixerAVol), mixerB.vol=\(mixerBVol)")

        // Cancel active crossfade if running
        await cancelActiveCrossfade()

        // Increment generations to invalidate any pending callbacks
        scheduleGenerationA &+= 1
        scheduleGenerationB &+= 1
        
        playerNodeA.stop()
        playerNodeB.stop()
        mixerNodeA.volume = 0.0
        mixerNodeB.volume = 0.0
        Self.logger.debug("[STOP_DIAGNOSTIC] stopBothPlayers: DONE - players stopped, mixers reset to 0")

        // Only stop engine if overlay is not active
        // Overlay uses the same engine - stopping it would kill overlay audio
        if isEngineRunning && overlayPlayer == nil {
            engine.stop()
            isEngineRunning = false
        } else if overlayPlayer != nil {
            Self.logger.debug("[STOP_DIAGNOSTIC] Engine kept running for active overlay")
        }
    }

    /// Cancel active crossfade and cleanup
    func cancelActiveCrossfade() async {
        guard let task = activeCrossfadeTask else { return }

        // Cancel task
        isCrossfadeCancelled = true
        task.cancel()
        Self.logger.info("[ROLLBACK] Waiting for crossfade Task to complete...")
        _ = await task.value  // Block until Task finishes (prevents zombie Task)
        Self.logger.info("[ROLLBACK] Crossfade Task completed")
        activeCrossfadeTask = nil

        // Report idle state
        crossfadeProgressContinuation?.yield(.idle)
        crossfadeProgressContinuation?.finish()
        crossfadeProgressContinuation = nil

        // Quick cleanup: reset volumes
        mixerNodeA.volume = 0.0
        mixerNodeB.volume = 0.0
    }

    /// Pause active crossfade task and cleanup (preserves mixer volumes for resume)
    /// - Note: Similar to cancelActiveCrossfade() but WITHOUT resetting mixer volumes
    /// - Note: Used when pause() is called during active crossfade
    func pauseCrossfadeTask() async {
        guard let task = activeCrossfadeTask else { return }

        // Cancel task
        isCrossfadeCancelled = true
        task.cancel()
        Self.logger.info("[PAUSE] Waiting for crossfade Task to complete...")
        _ = await task.value  // Block until Task finishes (prevents zombie Task)
        Self.logger.info("[PAUSE] Crossfade Task completed")
        activeCrossfadeTask = nil

        // Report idle state
        crossfadeProgressContinuation?.yield(.idle)
        crossfadeProgressContinuation?.finish()
        crossfadeProgressContinuation = nil

        // NOTE: Mixer volumes are NOT reset - preserved for smooth resume
        Self.logger.debug("[PAUSE] Crossfade task paused, volumes preserved: A=\(mixerNodeA.volume), B=\(mixerNodeB.volume)")
    }


    /// Cancel crossfade and stop inactive player
    /// - Note: Used when stop() is called during crossfade
    /// - Note: Leaves active mixer volume unchanged for subsequent fadeout
    func cancelCrossfadeAndStopInactive() async {
        // 1. Cancel crossfade task
        guard let task = activeCrossfadeTask else { return }

        isCrossfadeCancelled = true
        task.cancel()
        Self.logger.info("[ROLLBACK] Waiting for crossfade Task to complete...")
        _ = await task.value  // Block until Task finishes (prevents zombie Task)
        Self.logger.info("[ROLLBACK] Crossfade Task completed")
        activeCrossfadeTask = nil

        // Report cancellation
        crossfadeProgressContinuation?.yield(.idle)
        crossfadeProgressContinuation?.finish()
        crossfadeProgressContinuation = nil

        // 2. Stop inactive player (was fading in, no longer needed)
        let inactivePlayer = getInactivePlayerNode()
        inactivePlayer.stop()

        // 3. Reset inactive mixer to 0
        getInactiveMixerNode().volume = 0.0

        // 4. Active mixer volume is LEFT UNCHANGED
        // stopWithFade() will fade it out from current volume to 0
    }

    /// Rollback crossfade transaction - restore active player to normal state
    /// - Parameter rollbackDuration: Duration to restore active volume (default: 0.5s)
    /// - Returns: Current volume of active mixer before rollback (for smooth transition)
    func rollbackCrossfade(rollbackDuration: TimeInterval = 0.5) async -> Float {
        // 1. Get current volumes before cancellation
        let activeMixer = getActiveMixerNode()
        let inactiveMixer = getInactiveMixerNode()
        let currentActiveVolume = activeMixer.volume
        let currentInactiveVolume = inactiveMixer.volume

        Self.logger.info("[ROLLBACK] → rollbackCrossfade(duration: \(rollbackDuration)s)")
        Self.logger.info("[ROLLBACK] Current volumes: active=\(currentActiveVolume), inactive=\(currentInactiveVolume), target=\(targetVolume)")

        // 2. Cancel crossfade task
        guard let task = activeCrossfadeTask else {
            // No active crossfade, just return current volume
            Self.logger.info("[ROLLBACK] No active crossfade task - returning current volume")
            return currentActiveVolume
        }

        isCrossfadeCancelled = true
        task.cancel()
        Self.logger.info("[ROLLBACK] Waiting for crossfade Task to complete...")
        _ = await task.value  // Block until Task finishes (prevents zombie Task)
        Self.logger.info("[ROLLBACK] Crossfade Task completed")
        activeCrossfadeTask = nil

        // Report cancellation
        crossfadeProgressContinuation?.yield(.idle)
        crossfadeProgressContinuation?.finish()
        crossfadeProgressContinuation = nil

        // 3. RESTORE active to normal, fade out inactive
        // Requirement: "ЗАЛИШАЄМО в активному плеєрі трек з позицією ДО початку скасованого crossfade"
        // Active: fade BACK to targetVolume (restore normal playback)
        // Inactive: fade to 0.0 (cancel the transition)
        // CRITICAL: Parallel execution to avoid audio artifacts
        // Sequential fades cause temporary volume spike (e.g., 0.65 + 0.45 = 1.1)

        Self.logger.info("[ROLLBACK] Starting PARALLEL fades...")

        // Capture actor properties for closures
        let capturedTargetVolume = targetVolume

        // Execute both fades in parallel
        async let activeFade: Void = {
            if currentActiveVolume < capturedTargetVolume {
                Self.logger.info("[ROLLBACK] ACTIVE fade: \(currentActiveVolume) → \(capturedTargetVolume) (\(rollbackDuration)s)")
                await self.fadeVolume(
                    mixer: activeMixer,
                    from: currentActiveVolume,
                    to: capturedTargetVolume,
                    duration: rollbackDuration,
                    curve: .linear
                )
                Self.logger.info("[ROLLBACK] Active fade completed")
            } else {
                Self.logger.info("[ROLLBACK] Active already at target - skipping")
            }
        }()

        async let inactiveFade: Void = {
            if currentInactiveVolume > 0.0 {
                Self.logger.info("[ROLLBACK] INACTIVE fade: \(currentInactiveVolume) → 0.0 (\(rollbackDuration)s)")
                await self.fadeVolume(
                    mixer: inactiveMixer,
                    from: currentInactiveVolume,
                    to: 0.0,
                    duration: rollbackDuration,
                    curve: .linear
                )
                Self.logger.info("[ROLLBACK] Inactive fade completed")
            } else {
                Self.logger.info("[ROLLBACK] Inactive already silent - skipping")
            }
        }()

        // Wait for both fades to complete
        _ = await (activeFade, inactiveFade)
        Self.logger.info("[ROLLBACK] Parallel fades completed")

        // 5. Stop inactive player and reset
        Self.logger.info("[ROLLBACK] Stopping inactive player...")
        await stopInactivePlayer()
        inactiveMixer.volume = 0.0
        Self.logger.info("[ROLLBACK] ← rollbackCrossfade() completed")

        return currentActiveVolume
    }

    /// Fast-forward crossfade - complete to inactive player (for skip operations)
    /// Active mixer fades to 0.0, Inactive mixer fades to targetVolume, then switch active
    /// - Parameter duration: Duration to complete the fast-forward (default: 0.3s)
    /// - Returns: Current volume of active mixer before fast-forward
    func fastForwardCrossfade(duration: TimeInterval = 0.3) async -> Float {
        Self.logger.info("[FAST-FORWARD] → fastForwardCrossfade(duration: \(duration)s)")
        
        // 1. Get current volumes
        let activeMixer = getActiveMixerNode()
        let inactiveMixer = getInactiveMixerNode()
        let currentActiveVolume = activeMixer.volume
        let currentInactiveVolume = inactiveMixer.volume
        
        Self.logger.info("[FAST-FORWARD] Current volumes: active=\(currentActiveVolume), inactive=\(currentInactiveVolume), target=\(targetVolume)")
        
        // 2. Cancel crossfade task
        guard let task = activeCrossfadeTask else {
            Self.logger.info("[FAST-FORWARD] No active crossfade task")
            return currentActiveVolume
        }
        
        isCrossfadeCancelled = true
        task.cancel()
        Self.logger.info("[FAST-FORWARD] Waiting for crossfade Task to complete...")
        _ = await task.value
        Self.logger.info("[FAST-FORWARD] Crossfade Task completed")
        activeCrossfadeTask = nil
        
        // Report cancellation
        crossfadeProgressContinuation?.yield(.idle)
        crossfadeProgressContinuation?.finish()
        crossfadeProgressContinuation = nil
        
        // 3. COMPLETE to inactive player (parallel fades)
        Self.logger.info("[FAST-FORWARD] Starting PARALLEL fades...")
        
        let capturedTargetVolume = targetVolume
        
        async let activeFade: Void = {
            if currentActiveVolume > 0.0 {
                Self.logger.info("[FAST-FORWARD] ACTIVE fade: \(currentActiveVolume) → 0.0 (\(duration)s)")
                await self.fadeVolume(
                    mixer: activeMixer,
                    from: currentActiveVolume,
                    to: 0.0,
                    duration: duration,
                    curve: .equalPower
                )
                Self.logger.info("[FAST-FORWARD] Active fade completed")
            }
        }()
        
        async let inactiveFade: Void = {
            if currentInactiveVolume < capturedTargetVolume {
                Self.logger.info("[FAST-FORWARD] INACTIVE fade: \(currentInactiveVolume) → \(capturedTargetVolume) (\(duration)s)")
                await self.fadeVolume(
                    mixer: inactiveMixer,
                    from: currentInactiveVolume,
                    to: capturedTargetVolume,
                    duration: duration,
                    curve: .equalPower
                )
                Self.logger.info("[FAST-FORWARD] Inactive fade completed")
            }
        }()
        
        _ = await (activeFade, inactiveFade)
        
        Self.logger.info("[FAST-FORWARD] Parallel fades completed, switching active player")
        
        // 4. Switch active player (inactive becomes active)
        switchActivePlayer()
        
        Self.logger.info("[FAST-FORWARD] ← fastForwardCrossfade() completed")
        return currentActiveVolume
    }


    // MARK: - Crossfade Pause/Resume Support

    /// Crossfade state snapshot for pause/resume
    struct CrossfadeState {
        let activeMixerVolume: Float
        let inactiveMixerVolume: Float
        let activePlayerPosition: TimeInterval
        let inactivePlayerPosition: TimeInterval
        let activePlayer: PlayerNode
    }

    /// Get current crossfade state for pausing
    /// - Note: Can be called even when isCrossfading=false to capture final state
    func getCrossfadeState() -> CrossfadeState? {
        let currentActivePlayer = activePlayer  // Capture BEFORE reading volumes
        let activeMixer = getActiveMixerNode()
        let inactiveMixer = getInactiveMixerNode()

        Self.logger.debug("[GET_STATE] Reading: activePlayer=\(currentActivePlayer), activeMixer=\(activeMixer.volume), inactiveMixer=\(inactiveMixer.volume), mixerA=\(mixerNodeA.volume), mixerB=\(mixerNodeB.volume)")

        // Get positions from both players
        let activePos = getPlayerPosition(for: currentActivePlayer)
        let inactivePos = getPlayerPosition(for: currentActivePlayer == .a ? .b : .a)

        return CrossfadeState(
            activeMixerVolume: activeMixer.volume,
            inactiveMixerVolume: inactiveMixer.volume,
            activePlayerPosition: activePos,
            inactivePlayerPosition: inactivePos,
            activePlayer: currentActivePlayer
        )
    }

    /// Get position for specific player
    private func getPlayerPosition(for player: PlayerNode) -> TimeInterval {
        let file = player == .a ? audioFileA : audioFileB
        guard let file = file else { return 0.0 }

        let playerNode = player == .a ? playerNodeA : playerNodeB
        let offset = player == .a ? playbackOffsetA : playbackOffsetB
        let fileSampleRate = file.fileFormat.sampleRate

        if playerNode.isPlaying {
            guard let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return Double(offset) / fileSampleRate
            }
            // FIX: playerTime.sampleTime is in engine sample rate, not file sample rate
            let playerSampleRate = playerTime.sampleRate
            let playerTimeInSeconds = Double(playerTime.sampleTime) / playerSampleRate
            let offsetInSeconds = Double(offset) / fileSampleRate
            return offsetInSeconds + playerTimeInSeconds
        } else {
            return Double(offset) / fileSampleRate
        }
    }

    /// Pause both players during crossfade
    func pauseBothPlayersDuringCrossfade() {
        playerNodeA.pause()
        playerNodeB.pause()
    }

    /// Resume crossfade from paused state
    /// - Parameters:
    ///   - duration: Remaining crossfade duration (or quick finish duration)
    ///   - curve: Fade curve to use
    ///   - startVolumes: Starting volumes (from paused state)
    /// - Returns: AsyncStream for progress observation
    func resumeCrossfadeFromState(
        duration: TimeInterval,
        curve: FadeCurve,
        startVolumes: (active: Float, inactive: Float)
    ) async -> AsyncStream<CrossfadeProgress> {
        // Create progress stream
        let (stream, continuation) = AsyncStream.makeStream(
            of: CrossfadeProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        crossfadeProgressContinuation = continuation

        // Create crossfade task
        let task = Task {
            await self.executeResumeCrossfade(
                duration: duration,
                curve: curve,
                startVolumes: startVolumes,
                progress: continuation
            )

            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            self.cleanupCrossfade(continuation: continuation)
        }

        activeCrossfadeTask = task
        return stream
    }

    /// Execute resumed crossfade with custom start volumes
    private func executeResumeCrossfade(
        duration: TimeInterval,
        curve: FadeCurve,
        startVolumes: (active: Float, inactive: Float),
        progress: AsyncStream<CrossfadeProgress>.Continuation
    ) async {
        let startTime = Date()
        progress.yield(CrossfadeProgress(
            phase: .preparing,
            duration: duration,
            elapsed: 0
        ))

        let activePlayer = getActivePlayerNode()
        let inactivePlayer = getInactivePlayerNode()

        guard !isCrossfadeCancelled else {
            progress.yield(.idle)
            return
        }

        // Resume both players
        activePlayer.play()
        inactivePlayer.play()

        guard !isCrossfadeCancelled else {
            activePlayer.pause()
            inactivePlayer.pause()
            progress.yield(.idle)
            return
        }
        await fadeFromVolumesWithProgress(
            duration: duration,
            curve: curve,
            startVolumes: startVolumes,
            startTime: startTime,
            progress: progress
        )

        guard !isCrossfadeCancelled else {
            progress.yield(.idle)
            return
        }
        progress.yield(CrossfadeProgress(
            phase: .switching,
            duration: duration,
            elapsed: Date().timeIntervalSince(startTime)
        ))
        progress.yield(CrossfadeProgress(
            phase: .cleanup,
            duration: duration,
            elapsed: Date().timeIntervalSince(startTime)
        ))
        progress.yield(.idle)
    }

    /// Fade from specific start volumes to final state
    private func fadeFromVolumesWithProgress(
        duration: TimeInterval,
        curve: FadeCurve,
        startVolumes: (active: Float, inactive: Float),
        startTime: Date,
        progress: AsyncStream<CrossfadeProgress>.Continuation
    ) async {
        let activeMixer = getActiveMixerNode()
        let inactiveMixer = getInactiveMixerNode()

        let stepsPerSecond: Int
        if duration < 1.0 {
            stepsPerSecond = 100
        } else if duration < 5.0 {
            stepsPerSecond = 50
        } else if duration < 15.0 {
            stepsPerSecond = 30
        } else {
            stepsPerSecond = 20
        }

        let steps = Int(duration * Double(stepsPerSecond))
        let stepTime = duration / Double(steps)

        for i in 0...steps {
            guard !isCrossfadeCancelled else { return }

            let stepProgress = Float(i) / Float(steps)
            let elapsed = Date().timeIntervalSince(startTime)

            // Report progress
            progress.yield(CrossfadeProgress(
                phase: .fading(progress: Double(stepProgress)),
                duration: duration,
                elapsed: elapsed
            ))

            // Calculate target volumes for this step
            // Fade out from startVolumes.active to 0
            // Fade in from startVolumes.inactive to targetVolume
            let targetActiveVolume: Float = 0.0
            let targetInactiveVolume = targetVolume

            let currentActiveVolume = startVolumes.active + (targetActiveVolume - startVolumes.active) * curve.volume(for: stepProgress)
            let currentInactiveVolume = startVolumes.inactive + (targetInactiveVolume - startVolumes.inactive) * curve.volume(for: stepProgress)

            activeMixer.volume = currentActiveVolume
            inactiveMixer.volume = currentInactiveVolume

            do {
                try await Task.sleep(nanoseconds: UInt64(stepTime * 1_000_000_000))
            } catch is CancellationError {
                Self.logger.debug("[FADE_DEBUG] Crossfade: CANCELLED during sleep at step \(i)/\(steps)")
                return
            } catch {
                // Handle other errors (unlikely but required by Swift)
                Self.logger.error("[FADE_DEBUG] Crossfade: Unexpected error during sleep: \(error)")
                return
            }
        }

        // Ensure final volumes (if not cancelled)
        if !isCrossfadeCancelled {
            activeMixer.volume = 0.0
            inactiveMixer.volume = targetVolume
        }
    }

    // MARK: - Cleanup & Reset

    /// Complete async reset - clears all state including overlay
    func fullReset() async {
        // Stop both players
        await stopBothPlayers()

        // Stop engine
        engine.stop()
        isEngineRunning = false

        // Clear files
        audioFileA = nil
        audioFileB = nil

        // Reset offsets
        playbackOffsetA = 0
        playbackOffsetB = 0

        // Stop overlay
        await stopOverlay()

        // Reset to player A
        activePlayer = .a
    }

    // Note: No deinit needed - AVFoundation automatically cleans up engine and nodes
    // when actor deinitializes. Explicit deinit would require nonisolated(unsafe)
    // access to actor-isolated properties, which is unsafe in Swift 6 strict concurrency.

    // MARK: - Audio File Loading

    func loadAudioFile(track: Track) async throws -> Track {
        let file = try await cache.get(url: track.url, priority: .userInitiated)

        // Extract duration for logging
        let fileDuration = Double(file.length) / file.fileFormat.sampleRate
        let durationMinutes = Int(fileDuration / 60)
        let durationSeconds = Int(fileDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%d:%02d", durationMinutes, durationSeconds)
        
        // 🎵 [LoadFile] Log which player and file
        let targetPlayer = activePlayer == .a ? "A" : "B"
        Self.logger.info("🎵 [LoadFile] Player \(targetPlayer): \"\(track.url.lastPathComponent)\" (\(durationString))")

        // Store in active player's slot
        switch activePlayer {
        case .a:
            audioFileA = file
        case .b:
            audioFileB = file
        }

        // Extract metadata from audio file
        let format = AudioFormat(
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            bitDepth: 32,
            isInterleaved: file.fileFormat.isInterleaved
        )

        // Create metadata - preserve user-provided title/artist, update duration/format from file
        let metadata = Track.Metadata(
            title: track.metadata?.title ?? track.url.lastPathComponent,  // Use user title or fallback to filename
            artist: track.metadata?.artist,  // Preserve user artist (can be nil)
            duration: fileDuration,  // Always update from file
            format: format  // Always update from file
        )

        // Return track with metadata filled
        var updatedTrack = track
        updatedTrack.metadata = metadata
        return updatedTrack
    }

    // MARK: - Playback Control

    // MARK: Primitives (Single Responsibility)

    /// Reset playback offset for active player
    private func resetActivePlaybackOffset() {
        if activePlayer == .a {
            playbackOffsetA = 0
        } else {
            playbackOffsetB = 0
        }
    }

    /// Schedule active audio file on active player node with natural end detection
    /// Uses `.dataPlayedBack` callback type for reliable end-of-playback notification
    private func scheduleActiveFile() {
        guard let file = getActiveAudioFile() else { return }
        let player = getActivePlayerNode()
        let currentActivePlayer = activePlayer
        
        // Increment generation for this new schedule
        // This invalidates any pending callbacks from previous schedules
        let generation: UInt64
        if currentActivePlayer == .a {
            scheduleGenerationA &+= 1
            generation = scheduleGenerationA
        } else {
            scheduleGenerationB &+= 1
            generation = scheduleGenerationB
        }
        
        // Schedule with dataPlayedBack - only fires when audio actually finishes
        // (accounts for downstream latency and device playback delay)
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Completion on audio render thread - hop to actor
            Task { [weak self] in
                await self?.handlePlaybackCompletion(for: currentActivePlayer, generation: generation)
            }
        }
    }
    
    /// Handle playback completion callback from AVAudioPlayerNode
    /// Uses generation counter to filter out stale callbacks from previous schedules
    private func handlePlaybackCompletion(for player: PlayerNode, generation: UInt64) {
        // Check if this callback is from the current schedule generation
        let currentGeneration = player == .a ? scheduleGenerationA : scheduleGenerationB
        
        guard generation == currentGeneration else {
            Self.logger.debug("[PLAYBACK_END] Ignoring stale completion for player \(player) - generation \(generation) != current \(currentGeneration)")
            return
        }
        
        // Check if this player is still active (crossfade might have switched)
        guard player == activePlayer else {
            Self.logger.debug("[PLAYBACK_END] Ignoring completion for player \(player) - no longer active")
            return
        }
        
        Self.logger.info("[PLAYBACK_END] Natural playback end detected for player \(player)")
        playbackEndContinuation?.yield(player)
    }

    /// Start playback on active player node
    private func playActivePlayer() {
        getActivePlayerNode().play()
    }

    /// Set active mixer volume
    private func setActiveMixerVolume(_ volume: Float) {
        getActiveMixerNode().volume = volume
    }

    // MARK: Compositions (for backward compatibility)

    /// Schedule file and start playback with optional fade-in

    func scheduleFile(fadeIn: Bool = false, fadeInDuration: TimeInterval = 3.0, fadeCurve: FadeCurve = .equalPower) {
        // Use primitives
        resetActivePlaybackOffset()
        scheduleActiveFile()

        // Set initial volume for fade in
        if fadeIn {
            setActiveMixerVolume(0.0)
            // Store fade-in task so it can be cancelled if needed (e.g., skip during fade-in)
            activeFadeInTask = Task {
                // Use actor method to avoid data races
                // Fade to targetVolume (not 1.0) to respect user's volume setting
                await self.fadeActiveMixer(
                    from: 0.0,
                    to: targetVolume,
                    duration: fadeInDuration,
                    curve: fadeCurve
                )
                // Clear task reference after completion
                self.activeFadeInTask = nil
            }
        } else {
            setActiveMixerVolume(targetVolume)
        }

        playActivePlayer()
    }

    // MARK: - Seeking (REALLY FIXED)

    func seek(to time: TimeInterval) throws {
        guard let file = getActiveAudioFile() else {
            throw AudioPlayerError.invalidState(
                current: "no file loaded",
                attempted: "seek"
            )
        }

        let player = getActivePlayerNode()
        let mixer = getActiveMixerNode()
        let sampleRate = file.fileFormat.sampleRate

        // Calculate target frame
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        let maxFrame = file.length - 1
        let clampedFrame = max(0, min(targetFrame, maxFrame))

        // Save state BEFORE stopping
        let wasPlaying = player.isPlaying
        let currentVolume = mixer.volume
        let currentActivePlayer = activePlayer
        
        // Stop player completely (clears buffers)
        player.stop()

        // CRITICAL: Store playback offset for position tracking
        // Increment generation to invalidate any pending callbacks from previous schedule
        let generation: UInt64
        if currentActivePlayer == .a {
            playbackOffsetA = clampedFrame
            scheduleGenerationA &+= 1
            generation = scheduleGenerationA
        } else {
            playbackOffsetB = clampedFrame
            scheduleGenerationB &+= 1
            generation = scheduleGenerationB
        }

        // Schedule from new position with natural end detection
        player.scheduleSegment(
            file,
            startingFrame: clampedFrame,
            frameCount: AVAudioFrameCount(file.length - clampedFrame),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handlePlaybackCompletion(for: currentActivePlayer, generation: generation)
            }
        }

        // Restore volume BEFORE playing
        mixer.volume = currentVolume

        // Resume playback if was playing
        if wasPlaying {
            player.play()
        }
    }

    // MARK: - Volume Control

    func setVolume(_ volume: Float) {
        // Store target volume for crossfade scaling
        targetVolume = max(0.0, min(1.0, volume))

        // Set volume on main mixer (global)
        engine.mainMixerNode.volume = targetVolume

        // If NOT crossfading, update active mixer to target volume
        // During crossfade, fadeWithProgress() handles volume scaling
        if !isCrossfading {
            getActiveMixerNode().volume = targetVolume
        }
    }

    /// Get current target volume
    /// - Returns: Target volume level (0.0-1.0)
    func getTargetVolume() -> Float {
        return targetVolume
    }

    /// Get current active mixer volume
    /// - Returns: Actual volume of active mixer node (0.0-1.0)
    /// - Note: This is different from targetVolume (mainMixer.volume)
    /// - Note: During crossfade, active mixer may have different volume than target
    func getActiveMixerVolume() -> Float {
        let mixerNode = getActiveMixerNode()
        let vol = mixerNode.volume
        let mixerName = (mixerNode === mixerNodeA) ? "MixerA" : "MixerB"
        Self.logger.debug("[STOP_DIAGNOSTIC] getActiveMixerVolume: \(mixerName).volume = \(vol)")
        return vol
    }

    func fadeVolume(
        mixer: AVAudioMixerNode,
        from: Float,
        to: Float,
        duration: TimeInterval,
        curve: FadeCurve = .equalPower,
        checkCancellation: Bool = true
    ) async {
        let mixerName = (mixer === mixerNodeA) ? "MixerA" : "MixerB"
        let playerNode = getActivePlayerNode()
        let isPlayingStart = playerNode.isPlaying
        Self.logger.debug("[FADE_DEBUG] \(mixerName): from=\(from) → to=\(to), duration=\(duration)s, curve=\(curve)")
        Self.logger.debug("[FADE_CALLSTACK] \(Thread.callStackSymbols.prefix(7).joined(separator: "\n"))")
        Self.logger.debug("[STOP_DIAGNOSTIC] fadeVolume START: mixer=\(mixerName), playerIsPlaying=\(isPlayingStart), currentMixerVol=\(mixer.volume)")

        // FIXED Issue #9: Adaptive step sizing for efficient fading
        // Short fades need high frequency updates for smoothness
        // Long fades can use lower frequency to reduce CPU usage
        let stepsPerSecond: Int
        if duration < 1.0 {
            stepsPerSecond = 100  // 10ms - ultra smooth for quick fades
        } else if duration < 5.0 {
            stepsPerSecond = 50   // 20ms - smooth
        } else if duration < 15.0 {
            stepsPerSecond = 30   // 33ms - balanced
        } else {
            stepsPerSecond = 20   // 50ms - efficient for long fades (30s fade: 600 steps vs 3000)
        }

        let steps = Int(duration * Double(stepsPerSecond))
        let stepTime = duration / Double(steps)

        Self.logger.debug("[FADE_DEBUG] \(mixerName): steps=\(steps), stepTime=\(stepTime*1000)ms, stepsPerSecond=\(stepsPerSecond)")

        // 🔍 DIAGNOSTIC: Check if player stops during fade
        var wasPlayingDuringFade = isPlayingStart
        var loggedSteps: Set<Int> = []
        for i in 0..<5 {
            loggedSteps.insert(i)
            loggedSteps.insert(steps - i)
        }
        // 🔍 Also log every 10% progress for stop fade diagnostic
        for percent in [10, 20, 30, 40, 50, 60, 70, 80, 90] {
            let stepIndex = (steps * percent) / 100
            loggedSteps.insert(stepIndex)
        }

        for i in 0...steps {
            // FIXED Issue #10A: Check for task cancellation on every step
            // If fade is interrupted (pause/stop/skip) → abort gracefully
            // Checks both crossfade cancellation and Task cancellation (for fade-in)
            // Only check cancellation if requested (crossfade fades check, simple fades don't)
            guard !checkCancellation || (!isCrossfadeCancelled && !Task.isCancelled) else {
                Self.logger.debug("[FADE_DEBUG] \(mixerName): CANCELLED at step \(i)/\(steps) (crossfade=\(isCrossfadeCancelled), task=\(Task.isCancelled))")
                return // Exit immediately without throwing
            }

            let progress = Float(i) / Float(steps)

            // Calculate volume based on curve type
            // Formula: from + (to - from) * curve automatically handles direction
            // No need for inverseVolume - it would double-invert for fade-out
            let curveValue = curve.volume(for: progress)

            // Apply curve to the range [from, to]
            let newVolume = from + (to - from) * curveValue
            mixer.volume = newVolume

            // 🔍 DIAGNOSTIC: Check if player is still playing
            let isPlayingNow = playerNode.isPlaying
            if !isPlayingNow && wasPlayingDuringFade {
                Self.logger.debug("[STOP_DIAGNOSTIC] Player STOPPED during fade at step \(i)/\(steps), progress=\(progress)")
                wasPlayingDuringFade = false
            }
            if loggedSteps.contains(i) {
                Self.logger.debug("[FADE_DEBUG] \(mixerName): step[\(i)/\(steps)] progress=\(progress) curveValue=\(curveValue) volume=\(newVolume), playerPlaying=\(isPlayingNow)")
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(stepTime * 1_000_000_000))
            } catch is CancellationError {
                Self.logger.debug("[FADE_DEBUG] \(mixerName): CANCELLED during sleep at step \(i)/\(steps)")
                return
            } catch {
                // Handle other errors (unlikely but required by Swift)
                Self.logger.error("[FADE_DEBUG] \(mixerName): Unexpected error during sleep: \(error)")
                return
            }
        }

        // Ensure final volume is exact (only if not cancelled)
        let isPlayingEnd = playerNode.isPlaying
        if !checkCancellation || !isCrossfadeCancelled {
            mixer.volume = to
            Self.logger.debug("[FADE_DEBUG] \(mixerName): COMPLETE - final volume=\(to)")
            Self.logger.debug("[STOP_DIAGNOSTIC] fadeVolume END: mixer=\(mixerName), playerIsPlaying=\(isPlayingEnd), finalMixerVol=\(mixer.volume)")
        } else {
            Self.logger.debug("[FADE_DEBUG] \(mixerName): CANCELLED before completion")
            Self.logger.debug("[STOP_DIAGNOSTIC] fadeVolume CANCELLED: mixer=\(mixerName), playerIsPlaying=\(isPlayingEnd)")
        }
    }

    // MARK: - Natural Playback End Stream
    
    /// Create AsyncStream for natural playback end notifications
    /// Subscribers receive PlayerNode when audio naturally finishes (not on manual stop)
    func playbackEndStream() -> AsyncStream<PlayerNode> {
        AsyncStream { continuation in
            self.playbackEndContinuation = continuation
            
            continuation.onTermination = { @Sendable _ in
                // Note: Can't clear continuation here due to actor isolation
                // It will be replaced on next subscription
            }
        }
    }

    // MARK: - Playback Position

    func getCurrentPosition() -> PlaybackPosition? {
        guard let file = getActiveAudioFile() else { return nil }

        let player = getActivePlayerNode()
        let offset = activePlayer == .a ? playbackOffsetA : playbackOffsetB
        let fileSampleRate = file.fileFormat.sampleRate

        // Calculate duration using file's sample rate
        let duration = Double(file.length) / fileSampleRate

        if player.isPlaying {
            // Player is playing - use offset + playerTime for accurate tracking
            guard let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else {
                // Fallback to offset if times unavailable
                let currentTime = Double(offset) / fileSampleRate
                return PlaybackPosition(currentTime: currentTime, duration: duration)
            }

            // CRITICAL FIX: playerTime.sampleTime is counted at ENGINE sample rate (44100 Hz),
            // NOT file sample rate (e.g., 24000 Hz). Use playerTime.sampleRate for conversion.
            let playerSampleRate = playerTime.sampleRate
            let playerTimeInSeconds = Double(playerTime.sampleTime) / playerSampleRate
            let offsetInSeconds = Double(offset) / fileSampleRate
            let currentTime = offsetInSeconds + playerTimeInSeconds

            return PlaybackPosition(currentTime: currentTime, duration: duration)
        } else {
            // Player is paused - use ONLY offset (last known position)
            // playerTime.sampleTime may be stale or reset after pause
            let currentTime = Double(offset) / fileSampleRate
            return PlaybackPosition(currentTime: currentTime, duration: duration)
        }
    }

    // MARK: - Synchronized Crossfade (NEW)

    /// Prepare secondary player without starting playback
    func prepareSecondaryPlayer() {
        Self.logger.debug("→ prepareSecondaryPlayer()")
        guard let file = getInactiveAudioFile() else {
            Self.logger.debug("  No inactive file, returning")
            Self.logger.debug("← prepareSecondaryPlayer() completed (no file)")
            return
        }

        let player = getInactivePlayerNode()
        let mixer = getInactiveMixerNode()

        // Reset offset for new file
        if activePlayer == .a {
            playbackOffsetB = 0
            Self.logger.debug("  Reset playbackOffsetB = 0")
        } else {
            playbackOffsetA = 0
            Self.logger.debug("  Reset playbackOffsetA = 0")
        }

        // Set volume to 0 for fade in
        mixer.volume = 0.0
        Self.logger.debug("  Set mixer.volume = 0.0")

        // Schedule file but DON'T play yet
        player.scheduleFile(file, at: nil)
        Self.logger.debug("  Scheduled file on player")
        Self.logger.debug("← prepareSecondaryPlayer() completed")
    }

    /// Prepare loop on secondary player without starting playback
    func prepareLoopOnSecondaryPlayer() {
        guard let file = getActiveAudioFile() else { return }

        let player = getInactivePlayerNode()
        let mixer = getInactiveMixerNode()

        // Reset offset for loop (starts from beginning)
        if activePlayer == .a {
            playbackOffsetB = 0
        } else {
            playbackOffsetA = 0
        }

        // Set volume to 0 for fade in
        mixer.volume = 0.0

        // Schedule same file but DON'T play yet
        player.scheduleFile(file, at: nil)
    }

    /// Calculate synchronized start time for secondary player
    private func getSyncedStartTime() -> AVAudioTime? {
        let activePlayer = getActivePlayerNode()

        guard let lastRenderTime = activePlayer.lastRenderTime else {
            return nil
        }
        // Prevents timing glitches with complex audio files or high system load
        // Larger buffer = more stable playback, especially with Bluetooth/AirPods
        // Trade-off: Slightly higher latency, but critical for artifact-free audio
        let bufferSamples: AVAudioFramePosition = 8192  // Was: 2048 → 4096 → 8192

        let startSampleTime = lastRenderTime.sampleTime + bufferSamples

        return AVAudioTime(
            sampleTime: startSampleTime,
            atRate: lastRenderTime.sampleRate
        )
    }

    /// Perform synchronized crossfade between active and inactive players
    /// Returns async stream for progress observation
    func performSynchronizedCrossfade(
        duration: TimeInterval,
        curve: FadeCurve
    ) async -> AsyncStream<CrossfadeProgress> {
        Self.logger.debug("→ performSynchronizedCrossfade(duration: \(duration), curve: \(curve))")
        Self.logger.debug("  activePlayer: \(activePlayer), playerA.isPlaying: \(playerNodeA.isPlaying), playerB.isPlaying: \(playerNodeB.isPlaying)")

        // Create progress stream with buffering to prevent loss of .idle state
        let (stream, continuation) = AsyncStream.makeStream(
            of: CrossfadeProgress.self,
            bufferingPolicy: .bufferingNewest(1)  // Keep last value if consumer is slow
        )
        crossfadeProgressContinuation = continuation

        // Reset cancellation flag for new crossfade
        isCrossfadeCancelled = false
        
        // Create and store crossfade task
        // Task runs asynchronously and sends progress updates through continuation
        let task = Task {
            await self.executeCrossfade(
                duration: duration,
                curve: curve,
                progress: continuation
            )

            // CRITICAL: Small delay to ensure .idle state is delivered to all observers
            // Before closing the stream. Without this, race condition may prevent UI from
            // receiving the final .idle update, causing it to be stuck at "Crossfading 0%"
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            // Cleanup after crossfade completes
            self.cleanupCrossfade(continuation: continuation)
        }

        activeCrossfadeTask = task
        // Task continues running asynchronously and generates updates
        return stream
    }

    /// Cleanup crossfade state after completion
    private func cleanupCrossfade(continuation: AsyncStream<CrossfadeProgress>.Continuation) {
        activeCrossfadeTask = nil
        continuation.finish()
        crossfadeProgressContinuation = nil
    }

    /// Execute crossfade with progress reporting
    private func executeCrossfade(
        duration: TimeInterval,
        curve: FadeCurve,
        progress: AsyncStream<CrossfadeProgress>.Continuation
    ) async {
        let startTime = Date()
        progress.yield(CrossfadeProgress(
            phase: .preparing,
            duration: duration,
            elapsed: 0
        ))

        let inactivePlayer = getInactivePlayerNode()

        guard !isCrossfadeCancelled else {
            progress.yield(.idle)
            return
        }

        // Get synchronized start time
        let syncTime = getSyncedStartTime()

        // Start inactive player
        if let syncTime = syncTime {
            inactivePlayer.play(at: syncTime)
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        } else {
            inactivePlayer.play()
        }

        guard !isCrossfadeCancelled else {
            inactivePlayer.stop()
            progress.yield(.idle)
            return
        }
        let fadeTask = Task {
            await self.fadeWithProgress(
                duration: duration,
                curve: curve,
                startTime: startTime,
                progress: progress
            )
        }

        await fadeTask.value

        guard !isCrossfadeCancelled else {
            progress.yield(.idle)
            return
        }
        progress.yield(CrossfadeProgress(
            phase: .switching,
            duration: duration,
            elapsed: Date().timeIntervalSince(startTime)
        ))
        progress.yield(CrossfadeProgress(
            phase: .cleanup,
            duration: duration,
            elapsed: Date().timeIntervalSince(startTime)
        ))
        progress.yield(.idle)
    }

    /// Fade with progress reporting
    private func fadeWithProgress(
        duration: TimeInterval,
        curve: FadeCurve,
        startTime: Date,
        progress: AsyncStream<CrossfadeProgress>.Continuation
    ) async {
        let activeMixer = getActiveMixerNode()
        let inactiveMixer = getInactiveMixerNode()

        let stepsPerSecond: Int
        if duration < 1.0 {
            stepsPerSecond = 100
        } else if duration < 5.0 {
            stepsPerSecond = 50
        } else if duration < 15.0 {
            stepsPerSecond = 30
        } else {
            stepsPerSecond = 20
        }

        let steps = Int(duration * Double(stepsPerSecond))
        let stepTime = duration / Double(steps)

        for i in 0...steps {
            guard !isCrossfadeCancelled else { return }

            let stepProgress = Float(i) / Float(steps)
            let elapsed = Date().timeIntervalSince(startTime)

            // Report progress
            progress.yield(CrossfadeProgress(
                phase: .fading(progress: Double(stepProgress)),
                duration: duration,
                elapsed: elapsed
            ))

            // Calculate volumes scaled to target volume
            // This ensures crossfade respects user's volume setting
            let fadeOutValue = curve.inverseVolume(for: stepProgress) * targetVolume
            let fadeInValue = curve.volume(for: stepProgress) * targetVolume

            activeMixer.volume = fadeOutValue
            inactiveMixer.volume = fadeInValue

            do {
                try await Task.sleep(nanoseconds: UInt64(stepTime * 1_000_000_000))
            } catch is CancellationError {
                Self.logger.debug("[FADE_DEBUG] Crossfade: CANCELLED during sleep at step \(i)/\(steps)")
                return
            } catch {
                // Handle other errors (unlikely but required by Swift)
                Self.logger.error("[FADE_DEBUG] Crossfade: Unexpected error during sleep: \(error)")
                return
            }
            
            // Check cancellation after sleep for faster response
            guard !isCrossfadeCancelled else { return }
        }

        // Ensure final volumes (if not cancelled)
        if !isCrossfadeCancelled {
            activeMixer.volume = 0.0
            inactiveMixer.volume = targetVolume  // Use target, not 1.0
        }
    }

    /// Reset inactive mixer volume to 0
    func resetInactiveMixer() {
        getInactiveMixerNode().volume = 0.0
    }

    // MARK: - Helper Methods

    func getActivePlayerNode() -> AVAudioPlayerNode {
        return activePlayer == .a ? playerNodeA : playerNodeB
    }

    /// Get active player's playing state (Sendable)
    func isActivePlayerPlaying() -> Bool {
        return getActivePlayerNode().isPlaying
    }

    /// 🧪 DIAGNOSTIC: Get engine running state (for lock screen debugging)
    func getEngineRunningState() -> Bool {
        return isEngineRunning
    }


    private func getActiveMixerNode() -> AVAudioMixerNode {
        return activePlayer == .a ? mixerNodeA : mixerNodeB
    }

    private func getActiveAudioFile() -> AVAudioFile? {
        return activePlayer == .a ? audioFileA : audioFileB
    }

    private func getInactivePlayerNode() -> AVAudioPlayerNode {
        return activePlayer == .a ? playerNodeB : playerNodeA
    }

    private func getInactiveMixerNode() -> AVAudioMixerNode {
        return activePlayer == .a ? mixerNodeB : mixerNodeA
    }

    private func getInactiveAudioFile() -> AVAudioFile? {
        return activePlayer == .a ? audioFileB : audioFileA
    }

    // MARK: - Public Helper Methods

    /// Fade the active mixer volume (for seek and fade-out)
    func fadeActiveMixer(
        from: Float,
        to: Float,
        duration: TimeInterval,
        curve: FadeCurve = .equalPower
    ) async {
        let mixer = getActiveMixerNode()
        let mixerName = (mixer === mixerNodeA) ? "MixerA" : "MixerB"
        Self.logger.debug("[STOP_DIAGNOSTIC] fadeActiveMixer: mixer=\(mixerName), from=\(from), to=\(to), currentMixerVol=\(mixer.volume), duration=\(duration)s")
        await fadeVolume(
            mixer: mixer,
            from: from,
            to: to,
            duration: duration,
            curve: curve
        )
    }
    
    /// Cancel active fade-in task if running
    /// 
    /// Called before operations that conflict with fade-in:
    /// - Crossfade (skip during fade-in)
    /// - Seek (fade-out before seek)
    /// - Stop (fade-out before stop)
    func cancelActiveFadeIn() {
        if let task = activeFadeInTask {
            Self.logger.debug("[FADE_IN] Cancelling active fade-in task")
            task.cancel()
            activeFadeInTask = nil
        }
    }

    /// Switch the active player (used after crossfade completes)
    /// NOTE: For track replacement, files are already loaded correctly.
    /// For loop, both players have the same file, so no copying needed.
    func switchActivePlayer() {
        Self.logger.debug("→ switchActivePlayer()")
        Self.logger.debug("  BEFORE: activePlayer=\(activePlayer), playerA.isPlaying=\(playerNodeA.isPlaying), playerB.isPlaying=\(playerNodeB.isPlaying)")

        // Simply switch the active flag - files are already in correct slots
        activePlayer = activePlayer == .a ? .b : .a

        Self.logger.debug("  AFTER: activePlayer=\(activePlayer), playerA.isPlaying=\(playerNodeA.isPlaying), playerB.isPlaying=\(playerNodeB.isPlaying)")
        
        // 📊 [PlayerState] Snapshot after switch
        let activeFile = activePlayer == .a ? audioFileA?.url.lastPathComponent : audioFileB?.url.lastPathComponent
        let inactiveFile = activePlayer == .a ? audioFileB?.url.lastPathComponent : audioFileA?.url.lastPathComponent
        let activePlayerName = activePlayer == .a ? "A" : "B"
        let inactivePlayerName = activePlayer == .a ? "B" : "A"
        Self.logger.info("📊 [PlayerState] Active: \(activePlayerName)(\(activeFile ?? "none")) | Inactive: \(inactivePlayerName)(\(inactiveFile ?? "none"))")
        
        Self.logger.debug("← switchActivePlayer() completed")
    }

    /// Switch the active player AND set new active mixer to full volume
    /// Use this for non-crossfade scenarios (pause + skip, pause + load playlist)
    func switchActivePlayerWithVolume() {
        // Switch the active flag
        activePlayer = activePlayer == .a ? .b : .a
        // During pause, prepareSecondaryPlayer() sets mixer.volume = 0.0
        // When we switch without crossfade, we need to restore full volume
        let activeMixer = getActiveMixerNode()
        activeMixer.volume = 1.0
    }

    // MARK: - Simple Fade Operations (for Pause/Resume/Skip)

    /// Fade out active player to volume 0.0
    /// - Parameter checkCancellation: If true, checks isCrossfadeCancelled flag (for crossfade). If false, ignores flag (for simple pause/resume).
    func fadeOutActivePlayer(duration: TimeInterval, curve: FadeCurve = .linear, checkCancellation: Bool = false) async {
        let mixer = getActiveMixerNode()
        let currentVolume = mixer.volume
        await fadeVolume(
            mixer: mixer,
            from: currentVolume,
            to: 0.0,
            duration: duration,
            curve: curve,
            checkCancellation: checkCancellation
        )
    }

    /// Fade in active player from volume 0.0 to targetVolume
    /// - Parameter checkCancellation: If true, checks isCrossfadeCancelled flag (for crossfade). If false, ignores flag (for simple pause/resume).
    func fadeInActivePlayer(duration: TimeInterval, curve: FadeCurve = .linear, checkCancellation: Bool = false) async {
        let mixer = getActiveMixerNode()
        await fadeVolume(
            mixer: mixer,
            from: 0.0,
            to: targetVolume,
            duration: duration,
            curve: curve,
            checkCancellation: checkCancellation
        )
    }

    /// Start playback with fade in effect
    /// Note: Schedules, plays, and waits for fade to complete (using primitives)
    func playWithFadeIn(duration: TimeInterval, curve: FadeCurve = .linear) async {
        guard getActiveAudioFile() != nil else { return }

        // Use primitives for clean composition
        setActiveMixerVolume(0.0)
        scheduleActiveFile()
        playActivePlayer()

        // Fade in and WAIT for completion (key difference from scheduleFile)
        await fadeInActivePlayer(duration: duration, curve: curve)
    }

    /// Load audio file on primary (active) player
    /// Alias for loadAudioFile for consistency with loadAudioFileOnSecondaryPlayer naming
    func loadAudioFileOnPrimaryPlayer(track: Track) async throws -> Track {
        return try await loadAudioFile(track: track)
    }

    /// Preload audio file into cache for future use
    /// Call this before skipToNext/Previous to enable instant playback
    func preloadTrack(url: URL) async {
        await cache.preload(url: url)
    }

    /// Load audio file on the secondary player (for replace/next track)
    func loadAudioFileOnSecondaryPlayer(track: Track) async throws -> Track {
        let file = try await cache.get(url: track.url, priority: .userInitiated)

        // Extract duration for logging
        let fileDuration = Double(file.length) / file.fileFormat.sampleRate
        let durationMinutes = Int(fileDuration / 60)
        let durationSeconds = Int(fileDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%d:%02d", durationMinutes, durationSeconds)
        
        // 🎵 [LoadFile] Log which player and file
        let targetPlayer = activePlayer == .a ? "B" : "A"  // Secondary = opposite of active
        Self.logger.info("🎵 [LoadFile] Player \(targetPlayer): \"\(track.url.lastPathComponent)\" (\(durationString))")

        // Check sample rate mismatch (potential audio quality issue)
        if let activeFile = getActiveAudioFile() {
            let activeSR = activeFile.fileFormat.sampleRate
            let secondarySR = file.fileFormat.sampleRate
            if activeSR != secondarySR {
                Self.logger.warning("⚠️ [LoadFile] FORMAT MISMATCH: Active=\(Int(activeSR))Hz, Secondary=\(Int(secondarySR))Hz - may cause crackling")
            }
        }

        // Store in inactive player's slot
        switch activePlayer {
        case .a:
            audioFileB = file
        case .b:
            audioFileA = file
        }

        // Extract metadata from audio file
        let format = AudioFormat(
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            bitDepth: 32,
            isInterleaved: file.fileFormat.isInterleaved
        )

        // Create metadata - preserve user-provided title/artist, update duration/format from file
        let metadata = Track.Metadata(
            title: track.metadata?.title ?? track.url.lastPathComponent,  // Use user title or fallback to filename
            artist: track.metadata?.artist,  // Preserve user artist (can be nil)
            duration: fileDuration,  // Always update from file
            format: format  // Always update from file
        )

        // Return track with metadata filled
        var updatedTrack = track
        updatedTrack.metadata = metadata
        return updatedTrack
    }

    /// Load audio file on secondary player with timeout protection
    /// 
    /// Wraps blocking file I/O with timeout to prevent hangs on corrupted/slow files.
    /// 
    /// - Parameters:
    ///   - track: Track to load
    ///   - timeout: Maximum time to wait for file load
    ///   - onProgress: Optional progress callback for events
    /// - Returns: Track with metadata filled
    /// - Throws: AudioEngineError.fileLoadTimeout if timeout exceeded
    func loadAudioFileOnSecondaryPlayerWithTimeout(
        track: Track,
        timeout: Duration,
        onProgress: (@Sendable (PlayerEvent) -> Void)? = nil
    ) async throws -> Track {

        let start = ContinuousClock.now

        // Notify start
        onProgress?(.fileLoadStarted(track.url))

        // Create timeout task
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            throw AudioEngineError.fileLoadTimeout(track.url, timeout)
        }

        // Create load task (wrap async I/O)
        let loadTask = Task {
            try await self.loadAudioFileOnSecondaryPlayer(track: track)
        }

        // Race: whichever completes first
        let result: Track
        do {
            result = try await loadTask.value
            timeoutTask.cancel()
        } catch {
            loadTask.cancel()
            timeoutTask.cancel()

            if error is AudioEngineError {
                // Timeout error
                onProgress?(.fileLoadTimeout(track.url))
                throw error
            } else {
                // Load error
                onProgress?(.fileLoadError(track.url, error))
                throw error
            }
        }

        // Measure duration
        let duration = ContinuousClock.now - start
        onProgress?(.fileLoadCompleted(track.url, duration: duration))

        return result
    }

    /// Stop the currently active player
    func stopActivePlayer() {
        // Increment generation to invalidate any pending callbacks for active player
        if activePlayer == .a {
            scheduleGenerationA &+= 1
        } else {
            scheduleGenerationB &+= 1
        }
        
        let player = getActivePlayerNode()
        player.stop()
    }

    /// Stop the currently inactive player (used after crossfade)
    func stopInactivePlayer() async {
        let player = getInactivePlayerNode()
        let mixer = getInactiveMixerNode()
        let playerName = player === playerNodeA ? "A" : "B"
        let inactiveFile = player === playerNodeA ? audioFileA?.url.lastPathComponent : audioFileB?.url.lastPathComponent
        
        Self.logger.info("⏹️ [Stop Inactive] Player \(playerName): \"\(inactiveFile ?? "none")\"")
        Self.logger.debug("[STOP_INACTIVE] Starting: player=\(playerName), mixerVol=\(mixer.volume), isPlaying=\(player.isPlaying)")
        // Even if mixer.volume is already 0.0, this ensures smooth buffer cleanup
        if mixer.volume > 0.01 {
            await fadeVolume(
                mixer: mixer,
                from: mixer.volume,
                to: 0.0,
                duration: 0.02,  // 20ms - imperceptible but eliminates clicks
                curve: .linear,
                checkCancellation: false  // Cleanup shouldn't be interrupted
            )
        }

        // Small delay to ensure fade completes before stop
        Self.logger.debug("[STOP_INACTIVE] Sleeping 25ms before stop...")
        try? await Task.sleep(nanoseconds: 25_000_000)  // 25ms

        // CRITICAL: Full cleanup to prevent memory leaks
        Self.logger.debug("[STOP_INACTIVE] Calling player.stop()...")
        player.stop()  // Stop playback
        Self.logger.debug("[STOP_INACTIVE] Calling player.reset()...")
        player.reset()  // Clear all scheduled buffers
        mixer.volume = 0.0  // Reset volume
        
        // Reset playback offset for inactive player to prevent position tracking bugs
        if activePlayer == .a {
            playbackOffsetB = 0
            Self.logger.debug("[STOP_INACTIVE] Reset playbackOffsetB = 0")
        } else {
            playbackOffsetA = 0
            Self.logger.debug("[STOP_INACTIVE] Reset playbackOffsetA = 0")
        }
        
        Self.logger.debug("[STOP_INACTIVE] Completed: isPlaying=\(player.isPlaying)")
    }

    /// Clear inactive file reference to free memory
    func clearInactiveFile() {
        if activePlayer == .a {
            audioFileB = nil
        } else {
            audioFileA = nil
        }
    }

    // MARK: - Overlay Player Control

    /// Start overlay playback with specified configuration
    /// - Parameters:
    ///   - url: Local file URL for overlay audio
    ///   - configuration: Overlay playback configuration
    /// - Throws: AudioPlayerError if file invalid or playback fails
    func startOverlay(url: URL, configuration: OverlayConfiguration) async throws {
        // 1. Stop existing overlay if any
        if overlayPlayer != nil {
            await stopOverlay()
        }

        // 2. Create overlay player actor with pre-attached nodes
        // Nodes (playerNodeC, mixerNodeC) are already attached and connected during setup
        // This ensures overlay doesn't interrupt main playback
        overlayPlayer = try OverlayPlayerActor(
            player: playerNodeC,
            mixer: mixerNodeC,
            configuration: configuration
        )

        // 3. Load file and start playback
        // Engine is already running, overlay just plays on its own channel
        try await overlayPlayer?.load(url: url)
        try await overlayPlayer?.play()
    }

    /// Stop overlay playback with fade-out
    func stopOverlay() async {
        guard let player = overlayPlayer else { return }

        await player.stop()
        overlayPlayer = nil
    }

    /// Pause overlay playback
    func pauseOverlay() async {
        await overlayPlayer?.pause()
    }

    /// Resume overlay playback
    func resumeOverlay() async {
        guard let player = overlayPlayer else { return }
        await player.resume()
    }

    /// Set overlay volume independently
    /// - Parameter volume: Volume level (0.0-1.0)
    func setOverlayVolume(_ volume: Float) async {
        await overlayPlayer?.setVolume(volume)
    }

    /// Get current overlay configuration
    /// - Returns: Current overlay configuration or nil if never set
    func getOverlayConfiguration() -> OverlayConfiguration? {
        return overlayConfiguration
    }

    /// Set overlay configuration
    /// - Parameter configuration: New configuration to use for overlay
    /// - Note: Takes effect on next playOverlay() call
    func setOverlayConfiguration(_ configuration: OverlayConfiguration) {
        overlayConfiguration = configuration
    }

    // MARK: - Global Control

    /// Pause both main player and overlay
    /// Useful for phone call interruptions or user pause action
    func pauseAll() async {
        // Pause main player (synchronous)
        pause()

        // Pause overlay if active
        await pauseOverlay()
    }

    /// Resume both main player and overlay
    /// Restore playback after interruption
    func resumeAll() async {
        // Resume main player (synchronous)
        play()

        // Resume overlay if active
        await resumeOverlay()
    }

    /// Stop both main player and overlay completely
    /// Emergency stop or full reset scenario
    func stopAll() async {
        // Stop main player system
        await stopBothPlayers()

        // Stop overlay system
        await stopOverlay()
    }

    /// Get current overlay state
    /// - Returns: Current overlay state, or `.idle` if no overlay loaded
    func getOverlayState() async -> OverlayState {
        guard let player = overlayPlayer else {
            return .idle
        }
        return await player.getState()
    }

    // MARK: - Sound Effects Player Creation

    /// Create sound effects player actor with pre-attached nodes
    /// Nodes (playerNodeD, mixerNodeD) are already attached and connected during setup
    /// - Parameter cacheLimit: Maximum number of cached sound effects (default: 10)
    /// - Returns: Initialized SoundEffectsPlayerActor
    func createSoundEffectsPlayer(cacheLimit: Int = 10) -> SoundEffectsPlayerActor {
        return SoundEffectsPlayerActor(
            player: playerNodeD,
            mixer: mixerNodeD,
            cacheLimit: cacheLimit
        )
    }
}

// MARK: - Player Node Enum

internal enum PlayerNode {
    case a
    case b
}

// MARK: - Errors

/// Errors specific to AudioEngineActor operations
internal enum AudioEngineError: Error, LocalizedError {
    /// File load operation timed out
    /// - Parameters:
    ///   - url: File URL that timed out
    ///   - timeout: Timeout duration that was exceeded
    case fileLoadTimeout(URL, Duration)

    var errorDescription: String? {
        switch self {
        case .fileLoadTimeout(let url, let timeout):
            return "File load timeout after \(timeout.formatted()): \(url.lastPathComponent)"
        }
    }
}
