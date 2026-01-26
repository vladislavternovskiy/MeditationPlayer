import Foundation
import AudioServiceCore

/// Delegate protocol for audio session lifecycle events
///
/// Implement this protocol to receive notifications when audio session
/// state changes externally (e.g., another component changes category,
/// system interruption occurs).
///
/// SDK does NOT manage AVAudioSession category — it validates state
/// and notifies through this delegate. App developer decides how to respond.
///
/// **Example:**
/// ```swift
/// class MySessionHandler: AudioPlayerSessionDelegate {
///     func audioPlayerSessionCategoryDidChange(
///         validation: SessionValidationResult
///     ) async {
///         // Restore your audio session configuration
///         try? AVAudioSession.sharedInstance().setCategory(.playback)
///         try? await player.resume()
///     }
/// }
///
/// let handler = MySessionHandler()
/// player.sessionDelegate = handler
/// ```
public protocol AudioPlayerSessionDelegate: AnyObject, Sendable {

    /// Called when audio session category was changed by external code
    ///
    /// SDK pauses all playback (nodes + overlay) when this happens.
    /// App developer should restore session configuration and resume if needed.
    ///
    /// - Parameter validation: Current session validation result with details
    func audioPlayerSessionCategoryDidChange(
        validation: SessionValidationResult
    ) async
}
