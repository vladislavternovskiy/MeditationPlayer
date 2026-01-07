//
//  OverlayConfiguration.swift
//  AudioServiceCore
//
//  Created on 2025-10-09.
//  Feature #4: Overlay Player
//

import Foundation

/// Configuration for overlay audio playback.
///
/// Overlay player provides an independent audio layer that plays alongside the main track
/// without interference. Perfect for ambient sounds (rain, ocean), timer bells, or sound effects.
///
/// ## Example: Infinite Rain Loop
/// ```swift
/// var config = OverlayConfiguration.ambient
/// config.loopMode = .infinite
/// config.volume = 0.3
/// config.fadeInDuration = 2.0
/// config.fadeOutDuration = 2.0
///
/// try await service.playOverlay(url: rainURL, configuration: config)
/// ```
///
/// ## Example: Bell Every 5 Minutes (3 times)
/// ```swift
/// let config = OverlayConfiguration.bell(times: 3, interval: 300)
/// try await service.playOverlay(url: bellURL, configuration: config)
///
/// // Timeline:
/// // 0:00  → fadeIn → DING → fadeOut → [5 min silence]
/// // 5:00  → fadeIn → DING → fadeOut → [5 min silence]
/// // 10:00 → fadeIn → DING → fadeOut
/// ```
///
/// - SeeAlso: `AudioPlayerService.playOverlay(url:configuration:)`
public struct OverlayConfiguration: Sendable, Equatable {

  // MARK: - Loop Behavior

  /// Loop mode determines how many times the overlay audio repeats.
  public var loopMode: LoopMode

  /// Delay before starting the next loop iteration (in seconds).
  ///
  /// Used for timer bells or periodic sounds. The delay represents silence between iterations.
  ///
  /// ## Example:
  /// ```swift
  /// config.loopMode = .count(3)
  /// config.loopDelay = 300.0  // 5 minutes between bells
  /// ```
  ///
  /// **Default:** `0.0` (no delay between loops)
  ///
  /// **Valid Range:** `>= 0.0`
  public var loopDelay: TimeInterval

  // MARK: - Volume

  /// Overlay volume level, independent from main track volume.
  ///
  /// **Default:** `1.0` (full volume)
  ///
  /// **Valid Range:** `0.0...1.0`
  /// - `0.0` = Silent
  /// - `1.0` = Full volume
  public var volume: Float

  // MARK: - Fade Settings

  /// Duration of fade-in effect when overlay starts (in seconds).
  ///
  /// **Default:** `0.0` (no fade-in)
  ///
  /// **Valid Range:** `>= 0.0`
  public var fadeInDuration: TimeInterval

  /// Duration of fade-out effect when overlay stops (in seconds).
  ///
  /// **Default:** `0.0` (no fade-out)
  ///
  /// **Valid Range:** `>= 0.0`
  public var fadeOutDuration: TimeInterval

  /// Fade curve algorithm for volume transitions.
  ///
  /// **Default:** `.linear`
  ///
  /// - SeeAlso: `FadeCurve` for available curve types
  public var fadeCurve: FadeCurve

  /// Use a normalized buffer
  public var normalized: Bool

  // MARK: - Initialization

  /// Creates a new overlay configuration with default values.
  ///
  /// ## Defaults:
  /// - `loopMode`: `.once`
  /// - `loopDelay`: `0.0`
  /// - `volume`: `1.0`
  /// - `fadeInDuration`: `0.0`
  /// - `fadeOutDuration`: `0.0`
  /// - `fadeCurve`: `.linear`
  public init(
    loopMode: LoopMode = .once,
    loopDelay: TimeInterval = 0.0,
    volume: Float = 1.0,
    fadeInDuration: TimeInterval = 0.0,
    fadeOutDuration: TimeInterval = 0.0,
    fadeCurve: FadeCurve = .linear,
    normalized: Bool = true
  ) {
    self.loopMode = loopMode
    self.loopDelay = loopDelay
    self.volume = volume
    self.fadeInDuration = fadeInDuration
    self.fadeOutDuration = fadeOutDuration
    self.fadeCurve = fadeCurve
    self.normalized = normalized
  }

  // MARK: - Validation

  /// Validates all configuration parameters.
  ///
  /// ## Validation Rules:
  /// - `volume`: Must be in range `0.0...1.0`
  /// - `loopDelay`: Must be `>= 0.0`
  /// - `fadeInDuration`: Must be `>= 0.0`
  /// - `fadeOutDuration`: Must be `>= 0.0`
  /// - `loopMode`: If `.count(n)`, then `n > 0`
  ///
  /// - Returns: `true` if all parameters are valid, `false` otherwise
  public var isValid: Bool {
    guard volume >= 0.0 && volume <= 1.0 else { return false }
    guard loopDelay >= 0.0 else { return false }
    guard fadeInDuration >= 0.0 else { return false }
    guard fadeOutDuration >= 0.0 else { return false }

    // Validate loop count if specified
    if case .count(let times) = loopMode {
      guard times > 0 else { return false }
    }

    return true
  }
}

// MARK: - Loop Mode

public extension OverlayConfiguration {
  /// Determines how many times the overlay audio repeats.
  enum LoopMode: Sendable, Equatable {
    /// Play audio file once and stop.
    case once

    /// Repeat audio a specific number of times.
    ///
    /// - Parameter times: Number of repetitions (must be > 0)
    ///
    /// ## Example:
    /// ```swift
    /// config.loopMode = .count(3)  // Play 3 times total
    /// ```
    case count(Int)

    /// Loop audio indefinitely until explicitly stopped.
    ///
    /// ## Example:
    /// ```swift
    /// config.loopMode = .infinite  // Continuous playback
    /// ```
    case infinite
  }
}

// MARK: - Preset Configurations

public extension OverlayConfiguration {
  /// Default configuration (Spotify-inspired)
  ///
  /// Balanced settings for general-purpose overlay audio.
  /// Smooth fades with subtle background volume.
  ///
  /// ## Settings:
  /// - Loop: Once (play file once)
  /// - Volume: 60% (balanced mix)
  /// - Fade in: 1 second
  /// - Fade out: 1 second
  /// - Fade curve: Linear
  ///
  /// ## Example:
  /// ```swift
  /// try await service.playOverlay(url: ambientURL, configuration: .default)
  /// ```
  static var `default`: Self {
    Self(
      loopMode: .once,
      loopDelay: 0.0,
      volume: 0.6,
      fadeInDuration: 1.0,
      fadeOutDuration: 1.0,
      fadeCurve: .linear
    )
  }

  /// Preset configuration for ambient sounds (rain, ocean, forest).
  ///
  /// Continuous background atmosphere with smooth transitions.
  ///
  /// ## Settings:
  /// - Loop: Infinite
  /// - Volume: 30% (subtle background)
  /// - Fade in: 2 seconds
  /// - Fade out: 2 seconds
  ///
  /// ## Example:
  /// ```swift
  /// try await service.playOverlay(url: rainURL, configuration: .ambient)
  /// ```
  static var ambient: Self {
    Self(
      loopMode: .infinite,
      loopDelay: 0.0,
      volume: 0.3,
      fadeInDuration: 2.0,
      fadeOutDuration: 2.0,
      fadeCurve: .linear
    )
  }

  /// Preset configuration for timer bells or periodic sounds.
  ///
  /// Distinct, clearly separated sound events with fades.
  ///
  /// ## Settings:
  /// - Loop: Specified number of times
  /// - Delay: Specified interval between rings
  /// - Volume: 50% (clearly audible)
  /// - Fade in: 0.5 seconds
  /// - Fade out: 0.5 seconds
  ///
  /// ## Example:
  /// ```swift
  /// let config = OverlayConfiguration.bell(times: 3, interval: 300)
  /// try await service.playOverlay(url: bellURL, configuration: config)
  /// // Rings at 0:00, 5:00, 10:00
  /// ```
  ///
  /// - Parameters:
  ///   - times: Number of times to ring the bell (must be > 0)
  ///   - interval: Time between rings in seconds
  ///
  /// - Returns: Configured overlay for bell timer
  static func bell(times: Int, interval: TimeInterval) -> Self {
    Self(
      loopMode: .count(times),
      loopDelay: interval,
      volume: 0.5,
      fadeInDuration: 0.5,
      fadeOutDuration: 0.5,
      fadeCurve: .linear
    )
  }
}
