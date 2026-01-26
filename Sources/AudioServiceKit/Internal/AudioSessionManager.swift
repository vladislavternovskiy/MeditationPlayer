import AVFoundation
import AudioServiceCore

/// Singleton actor managing global AVAudioSession configuration and lifecycle.
///
/// **Design Rationale**:
/// - AVAudioSession is a **GLOBAL system resource** (one per process)
/// - Multiple AudioPlayerService instances must share the same session
/// - Singleton pattern prevents configuration conflicts and error -50
///
/// **Usage**:
/// ```swift
/// // Automatically used by AudioPlayerService instances
/// let player1 = AudioPlayerService()
/// let player2 = AudioPlayerService()
/// // Both use AudioSessionManager.shared internally
/// ```
actor AudioSessionManager {
    // MARK: - Singleton

    /// Shared instance - AVAudioSession is global, so manager must be too
    static let shared = AudioSessionManager()

    // MARK: - Properties

    private let session: AVAudioSession

    // Session management mode (set during configure)
    private var mode: AudioSessionMode = .managed

    // Configuration state
    private var isConfigured = false
    private var configuredOptions: AVAudioSession.CategoryOptions?

    // Activation state
    private var isActive = false
    private var isActivating = false  // Reentrancy guard for activate()

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

    // MARK: - Configuration

    /// Configure AVAudioSession with specified options.
    /// - Parameters:
    ///   - options: Category options for audio session
    ///   - mode: Session management mode (.managed or .external)
    ///   - force: Force reconfiguration even if already configured (for media services reset)
    /// - Throws: AudioPlayerError if configuration fails
    ///
    /// **Important**: Can only be called once. Subsequent calls with different options will log a warning.
    func configure(options: [AVAudioSession.CategoryOptions], mode: AudioSessionMode = .managed, force: Bool = false) throws {
        // Store mode for later use
        self.mode = mode
        
        // Combine array into single OptionSet
        let categoryOptions = options.reduce(into: AVAudioSession.CategoryOptions()) { result, option in
            result.formUnion(option)
        }
        
        // External mode: validate instead of configure
        if mode == .external {
            Self.logger.info("🔍 External mode: Validating audio session (not configuring)")
            try validateExternalSession()
            isConfigured = true
            configuredOptions = categoryOptions
            return
        }

        // Already configured - check for conflicts (unless force)
        guard !isConfigured || force else {
            if let existingOptions = configuredOptions, existingOptions != categoryOptions {
                Self.logger.warning("WARNING: Attempting to reconfigure with different options!")
                Self.logger.warning("Existing: \(existingOptions.rawValue), New: \(categoryOptions.rawValue)")
                Self.logger.warning("Using existing configuration (first wins)")
            } else {
                Self.logger.debug("⏭️ Already configured, skipping")
            }
            return
        }

        // CRITICAL: Set flag IMMEDIATELY after guard to prevent race condition
        // If we set it after setCategory(), two concurrent calls could both pass guard
        // and both try to configure AVAudioSession → Error -50
        isConfigured = true
        configuredOptions = categoryOptions

        Self.logger.info("🔧 Configuration started with options: \(categoryOptions.rawValue)")
        Self.logger.debug("Current state: category=\(session.category.rawValue), mode=\(session.mode.rawValue), active=\(session.isOtherAudioPlaying)")

        do {
            // MARK: Advanced Configuration for Maximum Stability
            // NOTE: Apple docs say setCategory() CAN be called on active session
            // DO NOT deactivate before configure - it can interfere with other audio

            // 1. Set preferred buffer duration (larger = more stable, higher latency)
            // 0.02s (20ms) provides excellent stability while keeping latency acceptable
            // For meditation/ambient apps, latency is less critical than stability
            let preferredBufferDuration: TimeInterval = 0.02
            Self.logger.debug("⏳ Step 1/4: Setting buffer duration...")
            do {
                try session.setPreferredIOBufferDuration(preferredBufferDuration)
                Self.logger.debug("Step 1/4: Buffer duration set successfully")
            } catch {
                Self.logger.error("Step 1/4 FAILED: \(error.localizedDescription)")
                throw error
            }

            // 2. Set preferred sample rate to avoid resampling
            // 44100 Hz is standard for most audio files
            let preferredSampleRate: Double = 44100.0
            Self.logger.debug("⏳ Step 2/4: Setting sample rate...")
            do {
                try session.setPreferredSampleRate(preferredSampleRate)
                Self.logger.debug("Step 2/4: Sample rate set successfully")
            } catch {
                Self.logger.error("Step 2/4 FAILED: \(error.localizedDescription)")
                throw error
            }

            // 3. Minimize interruptions from system alerts (iOS 14.5+)
            if #available(iOS 14.5, *) {
                Self.logger.debug("⏳ Step 3/4: Setting prefersNoInterruptionsFromSystemAlerts...")
                do {
                    try session.setPrefersNoInterruptionsFromSystemAlerts(true)
                    Self.logger.debug("Step 3/4: prefersNoInterruptionsFromSystemAlerts set successfully")
                } catch {
                    Self.logger.error("Step 3/4 FAILED: \(error.localizedDescription)")
                    throw error
                }
            }

            // 4. Set category to .playback for music playback (lock screen controls)
            // CRITICAL: This MUST succeed - user's audioSessionOptions MUST be applied
            Self.logger.info("⏳ Step 4/4: Setting category .playback with options \(categoryOptions.rawValue)...")
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: categoryOptions
                )
                Self.logger.info("Step 4/4: Category set successfully")
            } catch {
                Self.logger.error("Step 4/4 FAILED: \(error.localizedDescription)")
                Self.logger.error("Category: .playback, mode: .default, options: \(categoryOptions.rawValue)")
                throw error
            }

            // 5. Validate actual vs preferred settings
            let actualBufferDuration = session.ioBufferDuration
            let actualSampleRate = session.sampleRate

            Self.logger.info("Configuration:")
            Self.logger.debug("  Preferred buffer: \(preferredBufferDuration)s")
            Self.logger.debug("  Actual buffer: \(actualBufferDuration)s")
            Self.logger.debug("  Preferred sample rate: \(preferredSampleRate) Hz")
            Self.logger.debug("  Actual sample rate: \(actualSampleRate) Hz")

            if abs(actualBufferDuration - preferredBufferDuration) > 0.005 {
                Self.logger.warning("  WARNING: Buffer duration mismatch (difference > 5ms)")
            }

            if abs(actualSampleRate - preferredSampleRate) > 100 {
                Self.logger.warning("  WARNING: Sample rate mismatch (difference > 100 Hz)")
            }

            Self.logger.info("Configured successfully")
        } catch {
            // Configuration failed - rollback flag
            isConfigured = false
            configuredOptions = nil
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Failed to configure audio session: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - External Mode Validation
    
    /// Validate audio session configuration in external mode
    /// - Throws: AudioPlayerError if session incompatible
    private func validateExternalSession() throws {
        let category = session.category
        let categoryOptions = session.categoryOptions
        
        Self.logger.info("📋 Validating external audio session:")
        Self.logger.info("  Category: \(category.rawValue)")
        Self.logger.info("  Options: \(categoryOptions.rawValue)")
        Self.logger.info("  Active: \(session.isOtherAudioPlaying)")
        
        // Check 1: Category must be compatible with playback
        let compatibleCategories: [AVAudioSession.Category] = [
            .playback,
            .playAndRecord,
            .multiRoute
        ]
        
        guard compatibleCategories.contains(category) else {
            Self.logger.error("❌ INCOMPATIBLE CATEGORY: \(category.rawValue)")
            Self.logger.error("")
            Self.logger.error("Audio session category '\(category.rawValue)' does not support playback.")
            Self.logger.error("")
            Self.logger.error("To fix this issue, configure audio session before creating AudioPlayerService:")
            Self.logger.error("")
            Self.logger.error("let session = AVAudioSession.sharedInstance()")
            Self.logger.error("try session.setCategory(.playback)  // or .playAndRecord")
            Self.logger.error("try session.setActive(true)")
            Self.logger.error("")
            Self.logger.error("Then create player:")
            Self.logger.error("let player = try await AudioPlayerService(")
            Self.logger.error("    configuration: PlayerConfiguration(audioSessionMode: .external)")
            Self.logger.error(")")
            Self.logger.error("")
            
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Audio session category '\(category.rawValue)' is incompatible with playback. Use .playback or .playAndRecord. See console for detailed instructions."
            )
        }
        
        // Check 2: Warn if session not active (not critical, but suboptimal)
        if !session.isOtherAudioPlaying {
            Self.logger.warning("⚠️ Audio session is not active")
            Self.logger.warning("  Recommendation: Call session.setActive(true) before creating player")
            Self.logger.warning("  This is not critical, but may cause audio routing issues")
        }
        
        // Check 3: Warn about suboptimal options
        if category == .playAndRecord && !categoryOptions.contains(.defaultToSpeaker) {
            Self.logger.warning("⚠️ Using .playAndRecord without .defaultToSpeaker")
            Self.logger.warning("  Audio may route to earpiece instead of speaker")
            Self.logger.warning("  Recommendation: Add .defaultToSpeaker option")
        }
        
        // Check 4: Warn about missing Bluetooth support (critical for route changes)
        let hasBluetoothSupport = categoryOptions.contains(.allowBluetoothA2DP)
        
        if !hasBluetoothSupport {
            Self.logger.error("")
            Self.logger.error("⚠️ ⚠️ BLUETOOTH NOT ENABLED ⚠️ ⚠️")
            Self.logger.error("")
            Self.logger.error("Your audio session does NOT support Bluetooth devices!")
            Self.logger.error("")
            Self.logger.error("Issues you may experience:")
            Self.logger.error("  ❌ Audio won't route to Bluetooth headphones/speakers")
            Self.logger.error("  ❌ Connecting Bluetooth device won't switch audio")
            Self.logger.error("  ❌ User will only hear audio from iPhone speaker")
            Self.logger.error("")
            Self.logger.error("To fix, choose one of these configurations:")
            Self.logger.error("")
            Self.logger.error("Option 1: .playback category (recommended for music/meditation)")
            Self.logger.error("let session = AVAudioSession.sharedInstance()")
            Self.logger.error("try session.setCategory(")
            Self.logger.error("    .playback,")
            Self.logger.error("    options: [")
            Self.logger.error("        .allowBluetoothA2DP   // High-quality Bluetooth audio")
            Self.logger.error("    ]")
            Self.logger.error(")")
            Self.logger.error("try session.setActive(true)")
            Self.logger.error("")
            Self.logger.error("Option 2: .playAndRecord category (if you need recording)")
            Self.logger.error("try session.setCategory(")
            Self.logger.error("    .playAndRecord,")
            Self.logger.error("    options: [")
            Self.logger.error("        .defaultToSpeaker,    // REQUIRED: Route to speaker, not earpiece")
            Self.logger.error("        .allowBluetoothA2DP   // High-quality Bluetooth audio")
            Self.logger.error("    ]")
            Self.logger.error(")")
            Self.logger.error("try session.setActive(true)")
            Self.logger.error("")
            Self.logger.error("Then create player with external mode.")
            Self.logger.error("")
        } else {
            Self.logger.info("✅ Bluetooth support detected")
            Self.logger.info("  • .allowBluetoothA2DP: High-quality Bluetooth ✅")
        }
        
        
        Self.logger.info("")
        Self.logger.info("✅ External session validation passed")
        Self.logger.info("  SDK will use app-managed audio session")
    }
    
    // MARK: - Dynamic Options Update (For Testing)

    /// Update audio session category options dynamically
    /// **WARNING:** This may cause route changes and affect lock screen controls!
    /// - Parameter options: New category options to apply
    /// - Throws: AudioPlayerError if update fails
    func updateCategoryOptions(_ options: [AVAudioSession.CategoryOptions]) throws {
        let categoryOptions = options.reduce(into: AVAudioSession.CategoryOptions()) { result, option in
            result.formUnion(option)
        }

        Self.logger.warning("⚠️ Dynamically updating category options...")
        Self.logger.warning("  Old: \(configuredOptions?.rawValue ?? 0)")
        Self.logger.warning("  New: \(categoryOptions.rawValue)")
        Self.logger.warning("  This may cause audio route change and lock screen controls may disappear!")

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: categoryOptions
            )
            configuredOptions = categoryOptions
            Self.logger.info("✅ Category options updated successfully")
        } catch {
            Self.logger.error("❌ Failed to update category options: \(error.localizedDescription)")
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Failed to update category options: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Activation

    func activate() throws {
        guard isConfigured else {
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Session must be configured before activation"
            )
        }
        
        // External mode: skip activation (app manages it)
        if mode == .external {
            Self.logger.debug("🔍 External mode: Skipping activation (app-managed)")
            Self.logger.info("  App is responsible for calling session.setActive(true)")
            Self.logger.info("  If audio doesn't route to Bluetooth/headphones:")
            Self.logger.info("    1. Ensure session is active before creating player")
            Self.logger.info("    2. Reactivate session on route changes if needed")
            isActive = true  // Mark as active to pass guards
            return
        }

        // Already active - skip
        guard !isActive else { return }

        // Reentrancy guard - prevent concurrent activation attempts
        // Critical for multithreading safety with rapid route changes
        guard !isActivating else {
            Self.logger.warning("WARNING: Concurrent activate() blocked - already activating")
            return
        }

        isActivating = true
        defer { isActivating = false }

        do {
            try session.setActive(true)
            isActive = true
            Self.logger.info("Session activated successfully")
        } catch {
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Failed to activate audio session: \(error.localizedDescription)"
            )
        }
    }

    /// Validate current audio session state without modifying it
    ///
    /// SDK does not manage AVAudioSession — it only observes and reports.
    /// Returns validation result that callers can use to warn developers
    /// or decide whether to proceed with playback.
    ///
    /// - Returns: Validation result indicating session health
    func validateSessionState() -> SessionValidationResult {
        if mode == .managed {
            let current = session.category
            if current != .playback {
                Self.logger.warning("⚠️ Session category mismatch: \(current.rawValue) ≠ playback")
                return .categoryChanged(
                    current: current.rawValue,
                    expected: AVAudioSession.Category.playback.rawValue
                )
            }
        }
        // External mode: app manages category, we don't validate it
        return .valid
    }

    /// ⚠️ DEPRECATED - DO NOT USE!
    /// This method should NEVER be called in production code.
    /// Following Apple's AVAudioPlayer pattern: activate once, never deactivate.
    /// iOS manages session lifecycle automatically.
    /// 
    /// Deactivating a singleton session affects ALL AudioPlayerService instances.
    /// Only kept for potential emergency scenarios (not currently used).
    @available(*, deprecated, message: "Do not use - violates singleton pattern. Session should stay active.")
    func _internalDeactivateDeprecated() throws {
        guard isActive else { return }

        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
        } catch {
            throw AudioPlayerError.sessionConfigurationFailed(
                reason: "Failed to deactivate audio session: \(error.localizedDescription)"
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

        // Notify the service to reconfigure and restart
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
    /// Ensure audio session is active (activate if needed)
    func ensureActive() async throws {
        try activate()
    }

    /// Deactivate audio session (not used in production, kept for protocol)
    func deactivate() async throws {
        // Intentionally empty - session should stay active
        // Following Apple's AVAudioPlayer pattern
    }
    
    /// Validate session state (protocol conformance wrapper)
    func validateSession() async -> SessionValidationResult {
        validateSessionState()
    }
}
