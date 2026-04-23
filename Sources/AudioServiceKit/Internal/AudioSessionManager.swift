import AVFoundation
import AudioServiceCore

/// Singleton actor managing AVAudioSession observation and engine recovery.
///
/// **Design Rationale**:
/// - AVAudioSession is a **GLOBAL system resource** (one per process)
/// - SDK does NOT manage audio session category/options — app developer does
/// - SDK validates session state and recovers its own AVAudioEngine
/// - Singleton pattern prevents configuration conflicts
///
/// **App Developer Responsibility:**
/// ```swift
/// // Configure session BEFORE creating player
/// let session = AVAudioSession.sharedInstance()
/// try session.setCategory(.playback)
/// try session.setActive(true)
///
/// let player = try await AudioPlayerService(configuration: config)
/// ```
actor AudioSessionManager {
    // MARK: - Singleton

    /// Shared instance - AVAudioSession is global, so manager must be too
    static let shared = AudioSessionManager()

    // MARK: - Properties

    private let session: AVAudioSession

    // Activation state
    private var isActive = false
    private var isActivating = false  // Reentrancy guard for ensureSessionActive()

    // Notification observers setup flag
    private var observersSetup = false

    // Logger
    private static let logger = Logger.session

    // Callbacks for handling session events
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private var routeChangeHandler: (@Sendable (AVAudioSession.RouteChangeReason) -> Void)?
    private var mediaServicesResetHandler: (@Sendable () -> Void)?

    // MARK: - Initialization

    private init() {
        self.session = AVAudioSession.sharedInstance()

        // Setup observers in a detached task (init is nonisolated)
        Task { [weak self] in
            await self?.setupNotificationObserversOnce()
        }
    }

    // MARK: - Startup Validation

    /// Validate audio session at player initialization.
    ///
    /// Checks that app has configured a playback-compatible category.
    /// Throws if session is incompatible, logs warnings for suboptimal config.
    ///
    /// - Throws: AudioPlayerError if session category is incompatible
    func validateAtStartup() throws {
        let result = validateSessionState()
        if case .categoryChanged(let current, _) = result {
            Self.logger.error("❌ INCOMPATIBLE CATEGORY: \(current)")
            Self.logger.error("")
            Self.logger.error("Audio session category '\(current)' does not support playback.")
            Self.logger.error("")
            Self.logger.error("Configure audio session before creating AudioPlayerService:")
            Self.logger.error("")
            Self.logger.error("  let session = AVAudioSession.sharedInstance()")
            Self.logger.error("  try session.setCategory(.playback)  // or .playAndRecord")
            Self.logger.error("  try session.setActive(true)")
            Self.logger.error("")

            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Audio session category '\(current)' is incompatible with playback. Use .playback, .playAndRecord, or .multiRoute. See console for instructions."
            )
        }

        // Warn about suboptimal configuration
        let category = session.category
        let categoryOptions = session.categoryOptions

        Self.logger.info("✅ Session validation passed: category=\(category.rawValue)")

        if category == .playAndRecord && !categoryOptions.contains(.defaultToSpeaker) {
            Self.logger.warning("⚠️ Using .playAndRecord without .defaultToSpeaker")
            Self.logger.warning("  Audio may route to earpiece instead of speaker")
        }

        if !categoryOptions.contains(.allowBluetoothA2DP) && category != .playback {
            Self.logger.warning("⚠️ Bluetooth A2DP not enabled in category options")
            Self.logger.warning("  Audio may not route to Bluetooth devices")
        }
    }

    // MARK: - Session Validation

    /// Validate current audio session state without modifying it.
    ///
    /// SDK does not manage AVAudioSession — it only observes and reports.
    /// Returns validation result that callers use to warn developers
    /// or decide whether to proceed with playback.
    ///
    /// Always validates — checks that category is compatible with playback.
    ///
    /// - Returns: Validation result indicating session health
    func validateSessionState() -> SessionValidationResult {
        let category = session.category
        let compatibleCategories: [AVAudioSession.Category] = [
            .playback,
            .playAndRecord,
            .multiRoute
        ]

        if !compatibleCategories.contains(category) {
            Self.logger.warning("⚠️ Session category incompatible: \(category.rawValue)")
            return .categoryChanged(
                current: category.rawValue,
                expected: AVAudioSession.Category.playback.rawValue
            )
        }

        return .valid
    }

    // MARK: - Session Activation (Engine Recovery)

    /// Ensure audio session is active for engine operation.
    ///
    /// SDK does not manage session category — that's the app's job.
    /// But SDK needs session active to run AVAudioEngine.
    /// This is emergency recovery, not session management.
    ///
    /// - Throws: AudioPlayerError if activation fails
    func ensureSessionActive() throws {
        // Already active - skip
        guard !isActive else { return }

        // Reentrancy guard - prevent concurrent activation attempts
        guard !isActivating else {
            Self.logger.warning("WARNING: Concurrent ensureSessionActive() blocked")
            return
        }

        isActivating = true
        defer { isActivating = false }

        do {
            try session.setActive(true)
            isActive = true
            Self.logger.info("Session activated for engine recovery")
        } catch {
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Failed to activate audio session: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Event Handlers

    func setInterruptionHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.interruptionHandler = handler
    }

    func setRouteChangeHandler(_ handler: @escaping @Sendable (AVAudioSession.RouteChangeReason) -> Void) {
        self.routeChangeHandler = handler
    }

    func setMediaServicesResetHandler(_ handler: @escaping @Sendable () -> Void) {
        self.mediaServicesResetHandler = handler
    }

    // MARK: - Notification Observers

    /// Setup notification observers once (called from init)
    private func setupNotificationObserversOnce() {
        guard !observersSetup else { return }
        observersSetup = true
        // Interruption notifications
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Extract data synchronously (Notification is not Sendable)
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            let shouldResume: Bool?
            if type == .ended,
               let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = nil
            }

            // Now send Sendable data to actor
            Task {
                await self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }

        // Route change notifications
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Extract data synchronously (Notification is not Sendable)
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }

            // Now send Sendable data to actor
            Task {
                await self?.handleRouteChange(reason: reason)
            }
        }

        // Media services reset notifications
        // This fires when audio services crash/restart (rare but critical)
        // Also fires when external AVAudioPlayer interferes with our AVAudioEngine
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.handleMediaServicesReset()
            }
        }
    }

    // MARK: - Interruption Handling

    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool?) {
        switch type {
        case .began:
            // Interruption began (phone call, alarm, etc.)
            Self.logger.warning("[INTERRUPTION] ⚠️ BEGAN - pausing playback")
            interruptionHandler?(false)

        case .ended:
            // Interruption ended
            if let shouldResume = shouldResume {
                Self.logger.info("[INTERRUPTION] ✅ ENDED - shouldResume: \(shouldResume)")
                interruptionHandler?(shouldResume)
            } else {
                // No resume option provided - don't auto-resume
                // This handles Siri pause case
                Self.logger.info("[INTERRUPTION] ⏸️ ENDED - no shouldResume option (Siri case)")
                interruptionHandler?(false)
            }

        @unknown default:
            Self.logger.warning("[INTERRUPTION] Unknown type: \(type.rawValue)")
            break
        }
    }

    // MARK: - Route Change Handling

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        routeChangeHandler?(reason)
    }

    // MARK: - Media Services Reset Handling

    private func handleMediaServicesReset() {
        Self.logger.error("CRITICAL: Media services were reset!")
        Self.logger.error("This may happen when:")
        Self.logger.error("  - Audio services crash/restart")
        Self.logger.error("  - External AVAudioPlayer interferes with our engine")
        Self.logger.error("  - System audio reconfiguration")

        // Reset our internal state flags
        isActive = false
        isActivating = false

        // Notify the service to recover engine
        mediaServicesResetHandler?()
    }

    // MARK: - Current Route Info

    func getCurrentRoute() -> String {
        let route = session.currentRoute
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
        return outputs.isEmpty ? "No output" : outputs
    }

    func isHeadphonesConnected() -> Bool {
        let route = session.currentRoute
        return route.outputs.contains { output in
            output.portType == .headphones ||
            output.portType == .bluetoothA2DP ||
            output.portType == .bluetoothHFP ||
            output.portType == .bluetoothLE
        }
    }
}

// MARK: - AudioSessionManaging Conformance

extension AudioSessionManager: AudioSessionManaging {
    /// Validate session state (protocol conformance wrapper)
    func validateSession() async -> SessionValidationResult {
        validateSessionState()
    }
}
