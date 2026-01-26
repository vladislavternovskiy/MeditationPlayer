import Foundation

/// Result of audio session state validation
///
/// SDK validates audio session state without modifying it.
/// App developer receives this information to decide how to respond.
///
/// **Usage:**
/// ```swift
/// let result = await sessionManager.validateSessionState()
/// switch result {
/// case .valid:
///     // Session is correctly configured
/// case .categoryChanged(let current, let expected):
///     // Warn developer: category was changed externally
/// }
/// ```
public enum SessionValidationResult: Sendable, Equatable {
    /// Audio session is correctly configured for playback
    case valid

    /// Audio session category was changed externally
    /// - Parameters:
    ///   - current: Current category raw value (e.g., "AVAudioSessionCategoryRecord")
    ///   - expected: Expected category raw value (e.g., "AVAudioSessionCategoryPlayback")
    case categoryChanged(current: String, expected: String)
}
