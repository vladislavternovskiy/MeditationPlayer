//
//  AudioSessionManaging.swift
//  AudioServiceKit
//
//  Protocol abstraction for audio session management
//

import Foundation
import AudioServiceCore

/// Protocol for managing AVAudioSession lifecycle
///
/// Abstracts audio session operations to enable dependency injection
/// and unit testing with mock implementations.
///
/// **Responsibility:** Audio session activation and validation only.
/// SDK does NOT manage audio session category — it validates and reports.
protocol AudioSessionManaging: Actor {
    /// Activate audio session
    /// - Throws: AudioPlayerError if activation fails
    func activate() async throws

    /// Ensure audio session is active (activate if needed)
    /// - Throws: AudioPlayerError if activation fails
    func ensureActive() async throws

    /// Deactivate audio session
    /// - Throws: AudioPlayerError if deactivation fails
    func deactivate() async throws

    /// Validate current audio session state without modifying it
    /// - Returns: Validation result indicating session health
    func validateSession() async -> SessionValidationResult
}
