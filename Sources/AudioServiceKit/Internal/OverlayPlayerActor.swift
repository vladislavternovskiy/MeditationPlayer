//
//  OverlayPlayerActor.swift
//  AudioServiceKit
//
//  Created on 2025-10-09.
//  Overlay Player
//

@preconcurrency import AVFoundation
import AudioServiceCore
import os.log

/// Actor-isolated overlay audio player with independent lifecycle and looping support.
///
/// `OverlayPlayerActor` manages a dedicated audio playback chain (player + mixer) that operates
/// independently from the main crossfade system. Perfect for ambient sounds, timer bells, or effects.
///
/// ## Features:
/// - Independent volume control
/// - Configurable looping (once, N times, infinite)
/// - Loop delay support (pause between iterations)
/// - Per-iteration fade control
/// - Hot file swapping with crossfade
/// - State-based lifecycle management
///
/// ## Architecture:
/// ```
/// OverlayPlayerActor
///     ├─ AVAudioPlayerNode (schedules buffers)
///     └─ AVAudioMixerNode (independent volume)
/// ```
///
/// ## Example: Infinite Rain Loop
/// ```swift
/// let overlay = OverlayPlayerActor(
///     player: playerNode,
///     mixer: mixerNode,
///     configuration: .ambient
/// )
///
/// try await overlay.load(url: rainURL)
/// try await overlay.play()
/// // Plays continuously with smooth fades
/// ```
///
/// - SeeAlso: `OverlayConfiguration`, `OverlayState`
actor OverlayPlayerActor {

  // MARK: - Audio Nodes

  /// Player node owned by this actor
  private let player: AVAudioPlayerNode

  /// Mixer node for independent volume control
  private let mixer: AVAudioMixerNode

  // MARK: - State

  /// Current playback state
  private var state: OverlayState = .idle

  /// Loaded audio file
  private var audioFile: AVAudioFile?

  /// Loaded audio buffer (loaded into RAM)
  private var buffer: AVAudioPCMBuffer?

  /// Current configuration
  private var configuration: OverlayConfiguration

  /// Current loop iteration count (0-based)
  private var loopCount: Int = 0

  /// Active loop cycle task
  private var loopTask: Task<Void, Never>?

  /// Continuation for buffer completion synchronization
  private var completionContinuation: CheckedContinuation<Void, Never>?

  // MARK: - Initialization

  /// Creates a new overlay player actor.
  ///
  /// - Parameters:
  ///   - player: AVAudioPlayerNode for buffer scheduling
  ///   - mixer: AVAudioMixerNode for volume control
  ///   - configuration: Playback configuration
  ///
  /// - Throws: `AudioPlayerError.invalidConfiguration` if configuration is invalid
  init(
    player: AVAudioPlayerNode,
    mixer: AVAudioMixerNode,
    configuration: OverlayConfiguration
  ) throws {
    self.player = player
    self.mixer = mixer
    self.configuration = configuration

    // Validate configuration
    guard configuration.isValid else {
      throw AudioPlayerError.invalidConfiguration(
        reason: "Invalid OverlayConfiguration: volume must be 0.0-1.0, durations >= 0.0, loop count > 0"
      )
    }

    // Set initial volume
    mixer.volume = 0.0
  }

  // MARK: - Public API

  /// Load audio file for overlay playback.
  ///
  /// ## State Transition:
  /// `idle` → `preparing` → `idle` (ready)
  ///
  /// - Parameter url: Local file URL for audio file
  /// - Throws:
  ///   - `AudioPlayerError.invalidState` if not in idle state
  ///   - `AudioPlayerError.fileLoadError` if file cannot be loaded
  func load(url: URL) async throws {
    guard state == .idle else {
      throw AudioPlayerError.invalidState(
        current: state.description,
        attempted: "load"
      )
    }

    state = .preparing
    Logger.audio.info("[Overlay] Loading file: \(url.lastPathComponent)")

    do {
      let file = try AVAudioFile(forReading: url)
      let duration = Double(file.length) / file.fileFormat.sampleRate
      audioFile = file
      state = .idle  // Ready to play
      guard let directBuffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: AVAudioFrameCount(file.length)
      ) else {
          throw AudioPlayerError.fileLoadFailed(reason: "Cannot create audio buffer for \(url.lastPathComponent)")
      }
      try file.read(into: directBuffer)

      if configuration.normalized {
        buffer = try directBuffer.normalizedEBUR128()
      } else {
        buffer = directBuffer
      }
      Logger.audio.info("[Overlay] File loaded: \(url.lastPathComponent) (\(String(format: "%.2f", duration))s, \(file.length) frames @ \(Int(file.fileFormat.sampleRate))Hz)")
    } catch {
      state = .idle
      Logger.audio.error("[Overlay] Failed to load file: \(error.localizedDescription)")
      throw AudioPlayerError.fileLoadFailed(reason: "Failed to load file at \(url.path): \(error.localizedDescription)")
    }
  }

  /// Start overlay playback with configured loop cycle.
  ///
  /// ## State Transition:
  /// `idle` → `playing`
  ///
  /// ## Behavior:
  /// - Starts loop cycle based on `configuration.loopMode`
  /// - Applies fades on each loop iteration (smooth transitions)
  /// - Respects `configuration.loopDelay` between iterations
  ///
  /// - Throws:
  ///   - `AudioPlayerError.invalidState` if not in idle state
  ///   - `AudioPlayerError.invalidState` if no file loaded
  func play() async throws {
    guard state == .idle else {
      throw AudioPlayerError.invalidState(
        current: state.description,
        attempted: "play"
      )
    }

    guard audioFile != nil else {
      throw AudioPlayerError.invalidState(
        current: "no file loaded",
        attempted: "play"
      )
    }

    Logger.audio.info("[Overlay] ▶️ Starting playback (loopMode: \(String(describing: configuration.loopMode)), fadeIn: \(String(format: "%.2f", configuration.fadeInDuration))s, fadeOut: \(String(format: "%.2f", configuration.fadeOutDuration))s)")
    state = .playing
    loopCount = 0

    // Start loop cycle
    loopTask = Task {
      await self.loopCycle()
    }
  }

  /// Stop overlay playback with graceful fade-out.
  ///
  /// ## State Transition:
  /// `playing`/`paused` → `stopping` → `idle`
  ///
  /// ## Behavior:
  /// - Cancels active loop cycle (including delay)
  /// - Applies `configuration.fadeOutDuration` if configured
  /// - Adds micro-fade to prevent audio clicks
  /// - Cleans up player and mixer state
  func stop() async {
    Logger.audio.info("[Overlay] ⏹️ Stopping playback...")
    
    // 1. Set state FIRST - loopCycle will exit
    state = .stopping

    // 2. Cancel loop task
    loopTask?.cancel()
    loopTask = nil
    Logger.audio.debug("[Overlay] Loop task cancelled")

    // 3. Fade down mixer (general stop fade, NOT loop fade!)
    if mixer.volume > 0 && configuration.fadeOutDuration > 0 {
      Logger.audio.debug("[Overlay] 🔻 Stop fade out (\(String(format: "%.2f", configuration.fadeOutDuration))s)")
      await fadeVolume(
        from: mixer.volume,
        to: 0.0,
        duration: configuration.fadeOutDuration
      )
    } else {
      // Instant stop without fade
      mixer.volume = 0.0
      Logger.audio.debug("[Overlay] Volume set to 0.0 (instant stop)")
    }

    // 4. Stop player (after fade!)
    player.stop()
    player.reset()
    Logger.audio.debug("[Overlay] Player stopped and reset")

    // 5. Cleanup
    state = .idle
    Logger.audio.info("[Overlay] ✅ Stopped (state: idle)")
  }

  /// Pause overlay playback.
  ///
  /// ## State Transition:
  /// `playing` → `paused`
  ///
  /// ## Behavior:
  /// - Pauses player node immediately
  /// - Loop cycle continues in background
  /// - Call `resume()` to continue playback
  func pause() {
    guard state == .playing else { return }

    player.pause()
    state = .paused
  }

  /// Resume overlay playback from paused state.
  ///
  /// ## State Transition:
  /// `paused` → `playing`
  ///
  /// ## Behavior:
  /// - Resumes player node immediately
  /// - Loop cycle continues from where it was paused
  func resume() {
    guard state == .paused else { return }

    player.play()
    state = .playing
  }

  /// Replace current overlay file with crossfade transition.
  ///
  /// ## Behavior:
  /// - Cancels active loop cycle (including delay)
  /// - Fades out current file (1 second)
  /// - Loads new file
  /// - Starts playback with fade in
  ///
  /// ## Example:
  /// ```swift
  /// // Replace rain with ocean during playback
  /// try await overlay.replaceFile(url: oceanURL)
  /// // Smooth crossfade, no interruption
  /// ```
  ///
  /// - Parameter url: New audio file URL
  /// - Throws: `AudioPlayerError.fileLoadError` if file cannot be loaded
  func replaceFile(url: URL) async throws {
    // Cancel loop task (including delay)
    loopTask?.cancel()
    loopTask = nil

    // Fade out current (1 second fixed)
    if mixer.volume > 0 {
      await fadeVolume(from: mixer.volume, to: 0.0, duration: 1.0)
    }

    // Stop player
    player.stop()
    player.reset()

    // Load new file
    state = .preparing
    do {
      let file = try AVAudioFile(forReading: url)
      audioFile = file
      state = .idle
    } catch {
      state = .idle
      throw AudioPlayerError.fileLoadFailed(reason: "Failed to load file at \(url.path): \(error.localizedDescription)")
    }

    // Start playback
    try await play()
  }

  /// Set overlay volume independently from main player.
  ///
  /// ## Behavior:
  /// - Updates `configuration.volume`
  /// - Applies immediately to mixer node
  /// - Clamped to range `0.0...1.0`
  ///
  /// - Parameter volume: Target volume level (0.0 = silent, 1.0 = full)
  func setVolume(_ volume: Float) {
    let clamped = max(0.0, min(1.0, volume))
    configuration.volume = clamped
    mixer.volume = clamped
  }

  /// Set loop mode dynamically during playback.
  ///
  /// ## Behavior:
  /// - Updates `configuration.loopMode`
  /// - Takes effect on next loop iteration (current iteration completes)
  /// - Can change `.once` to `.infinite` while playing
  ///
  /// ## Example:
  /// ```swift
  /// // Start with limited loops
  /// try await overlay.play()  // plays 3 times
  ///
  /// // User toggles "infinite loop" in UI
  /// await overlay.setLoopMode(.infinite)  // continues forever
  /// ```
  ///
  /// - Parameter mode: New loop mode (`.once`, `.count(n)`, `.infinite`)
  func setLoopMode(_ mode: OverlayConfiguration.LoopMode) {
    configuration.loopMode = mode
  }

  /// Set loop delay dynamically during playback.
  ///
  /// ## Behavior:
  /// - Updates `configuration.loopDelay`
  /// - Takes effect on next loop iteration (current delay completes if active)
  /// - Useful for adjusting timer intervals in real-time
  ///
  /// ## Example:
  /// ```swift
  /// // User adjusts "delay between sounds" slider
  /// await overlay.setLoopDelay(15.0)  // 15 seconds between iterations
  /// ```
  ///
  /// - Parameter delay: Delay in seconds (must be >= 0.0)
  func setLoopDelay(_ delay: TimeInterval) {
    let clamped = max(0.0, delay)
    configuration.loopDelay = clamped
  }

  /// Get current playback state.
  ///
  /// - Returns: Current `OverlayState`
  func getState() -> OverlayState {
    return state
  }

  // MARK: - Loop Cycle

  /// Main loop cycle - handles iterations with delays and fades.
  ///
  /// ## Algorithm:
  /// ```
  /// while shouldContinue:
  ///   1. Fade in (if configured)
  ///   2. Schedule buffer
  ///   3. Wait for completion
  ///   4. Fade out (if configured)
  ///   5. Increment counter
  ///   6. Check if should continue
  ///   7. Apply delay (cancellable)
  /// ```
  private func loopCycle() async {
    Logger.audio.debug("[Overlay] ➡️ Loop cycle started")
    let cycleStartTime = Date()
    
    while shouldContinueLooping() {
      // Check cancellation and state before each iteration
      guard !Task.isCancelled && state == .playing else { 
        Logger.audio.debug("[Overlay] Loop cycle cancelled (isCancelled: \(Task.isCancelled), state: \(state.description))")
        break 
      }

      let iterationStartTime = Date()
      Logger.audio.info("[Overlay] ➡️ Iteration \(loopCount + 1) started")

      // 1. Fade in on each iteration (smooth entry)
      if configuration.fadeInDuration > 0 {
        Logger.audio.debug("[Overlay] 🔺 Fade in (\(String(format: "%.2f", configuration.fadeInDuration))s)")
        await fadeVolume(
          from: 0.0,
          to: configuration.volume,
          duration: configuration.fadeInDuration
        )
        Logger.audio.debug("[Overlay] ✅ Fade in complete")
      } else if loopCount == 0 {
        // First iteration without fade - set volume directly
        mixer.volume = configuration.volume
        Logger.audio.debug("[Overlay] Volume set directly: \(String(format: "%.2f", configuration.volume))")
      }

      guard !Task.isCancelled && state == .playing else { 
        Logger.audio.debug("[Overlay] Cancelled after fade in")
        break 
      }

      // 2. Schedule and play buffer
      let scheduleTime = Date()
      scheduleBuffer()
      player.play()
      Logger.audio.info("[Overlay] 🎵 Buffer scheduled and player started")

      // 3. Wait for playback to finish
      let waitStartTime = Date()
      Logger.audio.debug("[Overlay] ⏳ Waiting for playback to complete...")
      await waitForPlaybackEnd()
      let completionTime = Date()
      let playbackDuration = completionTime.timeIntervalSince(waitStartTime)
      Logger.audio.info("[Overlay] ✅ Playback completion callback received (after \(String(format: "%.3f", playbackDuration))s)")

      guard !Task.isCancelled && state == .playing else { 
        Logger.audio.debug("[Overlay] Cancelled after playback end")
        break 
      }

      // 3.5. Buffer safety delay - wait for audio hardware to finish rendering
      // AVAudioPlayerNode completion callback fires when last frame leaves the player node,
      // but audio hardware still has 300-500ms of audio in its internal buffers.
      // Without this delay, fade-out would cut off the last ~1 second of audio.
      Logger.audio.debug("[Overlay] ⏸️ Buffer safety delay (600ms) - waiting for hardware to finish rendering...")
      try? await Task.sleep(nanoseconds: 600_000_000)  // 600ms safety margin
      Logger.audio.debug("[Overlay] ✅ Buffer safety delay completed")

      guard !Task.isCancelled && state == .playing else { 
        Logger.audio.debug("[Overlay] Cancelled after buffer delay")
        break 
      }

      // 4. Fade out on each iteration (smooth exit)
      if configuration.fadeOutDuration > 0 {
        Logger.audio.debug("[Overlay] 🔻 Fade out (\(String(format: "%.2f", configuration.fadeOutDuration))s)")
        await fadeVolume(
          from: configuration.volume,
          to: 0.0,
          duration: configuration.fadeOutDuration
        )
        Logger.audio.debug("[Overlay] ✅ Fade out complete")
      }

      // 5. Increment loop counter
      loopCount += 1
      let iterationDuration = Date().timeIntervalSince(iterationStartTime)
      Logger.audio.info("[Overlay] ✅ Iteration \(loopCount) completed (\(String(format: "%.3f", iterationDuration))s total)")

      // 6. Check if should continue
      if !shouldContinueLooping() {
        Logger.audio.debug("[Overlay] No more iterations, exiting loop")
        break
      }

      // 7. Apply loop delay (cancellable)
      if configuration.loopDelay > 0 {
        guard !Task.isCancelled && state == .playing else { break }
        Logger.audio.debug("[Overlay] ⏸️ Loop delay: \(String(format: "%.2f", configuration.loopDelay))s")
        try? await Task.sleep(nanoseconds: UInt64(configuration.loopDelay * 1_000_000_000))
        guard !Task.isCancelled && state == .playing else { break }
      }
    }

    let cycleDuration = Date().timeIntervalSince(cycleStartTime)
    Logger.audio.info("[Overlay] ✅ Loop cycle completed (\(String(format: "%.3f", cycleDuration))s total, \(loopCount) iteration(s))")

    // Loop cycle completed
    await stop()
  }

  /// Check if should continue looping based on mode.
  private func shouldContinueLooping() -> Bool {
    switch configuration.loopMode {
    case .once:
      return loopCount < 1
    case .count(let times):
      return loopCount < times
    case .infinite:
      return true
    }
  }

  /// Check if current iteration is the last one.
  private func isLastLoop() -> Bool {
    switch configuration.loopMode {
    case .once:
      return loopCount == 0
    case .count(let times):
      return loopCount == times - 1
    case .infinite:
      return false
    }
  }

  // MARK: - Volume Fade

  /// Fade mixer volume with adaptive step sizing.
  ///
  /// ## Algorithm:
  /// Uses adaptive step frequency based on duration for optimal smoothness vs CPU usage:
  /// - `< 1.0s`: 100 steps/sec (10ms) - ultra smooth for quick fades
  /// - `< 5.0s`: 50 steps/sec (20ms) - smooth
  /// - `< 15.0s`: 30 steps/sec (33ms) - balanced
  /// - `>= 15.0s`: 20 steps/sec (50ms) - efficient for long fades
  ///
  /// - Parameters:
  ///   - from: Starting volume (0.0...1.0)
  ///   - to: Target volume (0.0...1.0)
  ///   - duration: Fade duration in seconds
  ///   - curve: Fade curve algorithm (default: uses `configuration.fadeCurve`)
  private func fadeVolume(
    from: Float,
    to: Float,
    duration: TimeInterval,
    curve: FadeCurve? = nil
  ) async {
    // Use config curve if not specified
    let fadeCurve = curve ?? configuration.fadeCurve

    // Adaptive step sizing (copied from AudioEngineActor)
    let stepsPerSecond: Int
    if duration < 1.0 {
      stepsPerSecond = 100  // 10ms
    } else if duration < 5.0 {
      stepsPerSecond = 50   // 20ms
    } else if duration < 15.0 {
      stepsPerSecond = 30   // 33ms
    } else {
      stepsPerSecond = 20   // 50ms
    }

    let steps = Int(duration * Double(stepsPerSecond))
    let stepTime = duration / Double(steps)

    for i in 0...steps {
      // Check cancellation
      guard !Task.isCancelled else { return }

      let progress = Float(i) / Float(steps)

      // Calculate volume based on curve
      // Formula: from + (to - from) * curve automatically handles direction
      // No need for inverseVolume - it would double-invert for fade-out
      let curveValue = fadeCurve.volume(for: progress)

      // Apply curve to range [from, to]
      let newVolume = from + (to - from) * curveValue
      mixer.volume = newVolume

      try? await Task.sleep(nanoseconds: UInt64(stepTime * 1_000_000_000))
    }

    // Ensure final volume (if not cancelled)
    if !Task.isCancelled {
      mixer.volume = to
    }
  }

  // MARK: - Buffer Scheduling

  /// Schedule audio buffer for playback.
  ///
  /// ## Behavior:
  /// - Schedules entire file at once (no progressive loading)
  /// - Sets up completion callback to signal `waitForPlaybackEnd()`
  /// - Callback executes on audio thread - uses Task to hop back to actor
    private func scheduleBuffer() {
      guard let sourceBuffer = buffer else { return }

      let nodeFormat = player.outputFormat(forBus: 0)

      // Debug once if needed
      if sourceBuffer.format.channelCount != nodeFormat.channelCount ||
          sourceBuffer.format.sampleRate != nodeFormat.sampleRate {
        Logger.audio.warning("""
        [Overlay] Format mismatch. buffer=\(sourceBuffer.format), node=\(nodeFormat).
        Converting to node format.
        """)
      }

      let playableBuffer: AVAudioPCMBuffer
      do {
        playableBuffer = try convertBufferIfNeeded(sourceBuffer, to: nodeFormat)
      } catch {
        Logger.audio.error("[Overlay] Buffer conversion failed: \(error.localizedDescription)")
        // Fallback: do NOT schedule the mismatched buffer (would crash).
        // If you prefer, you can early-return here.
        return
      }

      player.scheduleBuffer(playableBuffer, at: nil, options: []) { [weak self] in
        guard let self else { return }
        Task { await self.signalPlaybackEnd() }
      }
    }

    private func convertBufferIfNeeded(
      _ buffer: AVAudioPCMBuffer,
      to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
      // Exact match: return as-is
      if buffer.format.channelCount == targetFormat.channelCount,
         buffer.format.sampleRate == targetFormat.sampleRate,
         buffer.format.commonFormat == targetFormat.commonFormat,
         buffer.format.isInterleaved == targetFormat.isInterleaved {
        return buffer
      }

      guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
        throw NSError(domain: "OverlayPlayerActor", code: -1, userInfo: [
          NSLocalizedDescriptionKey: "Cannot create AVAudioConverter from \(buffer.format) to \(targetFormat)"
        ])
      }

      let ratio = targetFormat.sampleRate / buffer.format.sampleRate
      let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

      guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
        throw NSError(domain: "OverlayPlayerActor", code: -2, userInfo: [
          NSLocalizedDescriptionKey: "Cannot allocate output buffer for target format \(targetFormat)"
        ])
      }

      var error: NSError?
      var didProvideInput = false

      converter.convert(to: outBuffer, error: &error) { _, outStatus in
        if didProvideInput {
          outStatus.pointee = .endOfStream
          return nil
        } else {
          didProvideInput = true
          outStatus.pointee = .haveData
          return buffer
        }
      }

      if let error { throw error }
      return outBuffer
    }


  /// Wait for buffer playback to complete.
  ///
  /// ## Implementation:
  /// Uses `CheckedContinuation` to suspend until audio callback signals completion.
  /// This pattern allows synchronous-style code in async context.
  private func waitForPlaybackEnd() async {
    await withCheckedContinuation { continuation in
      completionContinuation = continuation
    }
  }

  /// Signal that playback completed (called from audio callback).
  ///
  /// ## Thread Safety:
  /// Called via Task from audio thread callback, ensuring actor isolation.
  private func signalPlaybackEnd() {
    Logger.audio.debug("[Overlay] 🔔 Completion callback fired (from audio thread)")
    completionContinuation?.resume()
    completionContinuation = nil
  }
}
