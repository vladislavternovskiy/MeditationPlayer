//
//  ProsperPlayerDemoApp.swift
//  ProsperPlayerDemo
//
//  Created by vasyl on 23.10.2025.
//

import SwiftUI
import AVFoundation
import AudioServiceKit
import AudioServiceCore

@main
struct ProsperPlayerDemoApp: App {
    // Create service at App level (like MeditationDemo v4.1.0)
    @State private var audioService: AudioPlayerService?
    @State private var isInitializing = true

    var body: some Scene {
        WindowGroup {
            Group {
                if let audioService = audioService {
                    ContentView()
                        .environment(\.audioService, audioService)
                } else if isInitializing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Initializing Audio Engine...")
                            .font(.headline)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.red)
                        Text("Failed to initialize audio service")
                            .font(.headline)
                        Text("Please restart the app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                // Configure audio session (app responsibility)
                // SDK validates but does NOT set category
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback)
                    try session.setActive(true)
                } catch {
                    print("❌ Failed to configure audio session: \(error)")
                }

                // Initialize audio service at App level
                // This ensures remote commands are set up early in app lifecycle
                do {
                    let config = PlayerConfiguration()
                    audioService = try await AudioPlayerService(configuration: config)
                    isInitializing = false
                } catch {
                    print("❌ Failed to initialize AudioPlayerService: \(error)")
                    isInitializing = false
                }
            }
        }
    }
}

// MARK: - Environment Key for AudioPlayerService

private struct AudioServiceKey: EnvironmentKey {
    static let defaultValue: AudioPlayerService? = nil
}

extension EnvironmentValues {
    var audioService: AudioPlayerService? {
        get { self[AudioServiceKey.self] }
        set { self[AudioServiceKey.self] = newValue }
    }
}
