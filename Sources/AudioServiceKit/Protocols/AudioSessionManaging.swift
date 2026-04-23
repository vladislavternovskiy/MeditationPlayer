//
//  AudioSessionManaging.swift
//  AudioServiceKit
//
//  Protocol abstraction for audio session validation and engine recovery
//

import Foundation
import AudioServiceCore

/// Protocol for audio session validation and engine recovery
///
/// SDK does NOT manage audio session category — app developer does.
/// This protocol provides:
/// - Session validation (read-only check)
/// - Engine recovery (setActive for engine restart)
/// - Startup validation (check at init)
protocol AudioSessionManaging: Actor {
    /// Ensure audio session is active (engine recovery)
    /// - Throws: AudioPlayerError if activation fails
    func ensureSessionActive() async throws

    /// Validate current audio session state without modifying it
    /// - Returns: Validation result indicating session health
    func validateSession() async -> SessionValidationResult

    /// Validate session at player startup
    /// - Throws: AudioPlayerError if session category is incompatible
    func validateAtStartup() async throws
}
