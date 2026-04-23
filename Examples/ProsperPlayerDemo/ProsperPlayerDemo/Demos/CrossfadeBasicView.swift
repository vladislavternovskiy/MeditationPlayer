//
//  CrossfadeBasicView.swift
//  ProsperPlayerDemo
//
//  Basic crossfade demo - seamless transitions between tracks
//  Core SDK functionality: dual-player architecture with automatic crossfades
//

import SwiftUI
import AudioServiceKit
import AudioServiceCore
import AVFAudio

struct CrossfadeBasicView: View {

    // MARK: - Environment

    @Environment(\.audioService) private var audioService

    // MARK: - State (MV pattern)

    @State private var playerState: PlayerState = .finished
    @State private var currentTrack: String = "No track"
    @State private var errorMessage: String?
    @State private var tracks: [Track] = []
    @State private var crossfadeDuration: Double = 5.0
    @State private var volume: Double = 0.8
    
    // Experimental testing state
    @State private var hasMixWithOthers: Bool = false
    @State private var testMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Header
                    headerSection

                    // Progress
                    ProgressCard(service: audioService)
                        .id(audioService != nil ? "service-\(ObjectIdentifier(audioService!))" : "no-service")

                    // Track Info
                    trackInfoSection

                    // Configuration
                    ConfigurationView(
                        crossfadeDuration: $crossfadeDuration,
                        volume: $volume
                    )

                    // Controls
                    controlsSection

                    #if DEBUG
                    // Experimental Tests
                    experimentalTestsSection
                    #endif

                    // Info
                    infoSection

                    // Error
                    if let error = errorMessage {
                        errorSection(error)
                    }
                }
                .padding()
            }
            .navigationTitle("Basic Crossfade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ConfigToolbarButtons(service: audioService, mode: .readOnly)
                }
            }
            .task {
                await loadResources()
                
                // AsyncStream: Reactive state updates (v3.1+)
                // Start AFTER loadResources completes to avoid race condition
                guard let service = audioService else { return }
                
                // Launch concurrent tasks for state and track updates
                async let stateTask: Void = {
                    for await state in await service.stateUpdates {
                        await MainActor.run {
                            playerState = state
                        }
                    }
                }()
                
                async let trackTask: Void = {
                    for await metadata in await service.trackUpdates {
                        await MainActor.run {
                            if let metadata = metadata {
                                currentTrack = metadata.title ?? "Track"
                            } else {
                                currentTrack = "No track"
                            }
                        }
                    }
                }()
                
                _ = await (stateTask, trackTask)
            }
            .onChange(of: crossfadeDuration) { _, newValue in
                Task {
                    await updateConfiguration()
                }
            }
            .onChange(of: volume) { _, newValue in
                Task {
                    await updateConfiguration()
                }
            }
        }
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Seamless transitions between tracks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var trackInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Playback Info", systemImage: "music.note.list")
                .font(.headline)
                .foregroundStyle(.purple)

            HStack {
                Text("Current:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(currentTrack)
                    .fontWeight(.medium)
            }

            HStack {
                Text("State:")
                    .foregroundStyle(.secondary)
                Spacer()
                stateLabel
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4)
        )
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch playerState {
        case .idle:
            Label("Idle", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .preparing:
            Label("Preparing", systemImage: "hourglass")
                .foregroundStyle(.orange)
        case .playing:
            Label("Playing", systemImage: "play.fill")
                .foregroundStyle(.green)
        case .paused:
            Label("Paused", systemImage: "pause.fill")
                .foregroundStyle(.orange)
        case .fadingOut:
            Label("Fading Out", systemImage: "speaker.wave.1")
                .foregroundStyle(.orange)
        case .finished:
            Label("Finished", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 12) {
            Label("Controls", systemImage: "play.circle")
                .font(.headline)
                .foregroundStyle(.purple)

            Button(action: { Task { await play() } }) {
                Label("Play Playlist (3 tracks)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(playerState == .playing || audioService == nil || tracks.isEmpty)

            Button(action: { Task { await stop() } }) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(playerState == .finished)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4)
        )
    }

    #if DEBUG
    private var experimentalTestsSection: some View {
        VStack(spacing: 12) {
            Label("⚠️ Experimental Tests", systemImage: "flask.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                Text("Current Audio Session Options:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(hasMixWithOthers ? "✅ .mixWithOthers" : "❌ Empty []")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(hasMixWithOthers ? .green : .blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Test 1: Toggle .mixWithOthers
            Button(action: { Task { await toggleMixWithOthers() } }) {
                Label(
                    hasMixWithOthers ? "Remove .mixWithOthers" : "Add .mixWithOthers",
                    systemImage: hasMixWithOthers ? "minus.circle" : "plus.circle"
                )
                .frame(maxWidth: .infinity)
                .padding()
                .background(hasMixWithOthers ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(audioService == nil)

            // Test 2: Simulate developer recording
            Button(action: { Task { await simulateDeveloperRecording() } }) {
                Label("Simulate Developer Recording", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(audioService == nil)

            if let message = testMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("📋 Test Instructions:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Start playback with Play button")
                Text("2. Check lock screen - controls should appear ✅")
                Text("3. Tap 'Add .mixWithOthers' - do controls disappear? 🤔")
                Text("4. Tap 'Remove .mixWithOthers' - do controls return? 🤔")
                Text("5. Tap 'Simulate Recording' - test defensive recovery")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 2)
                )
        )
    }
    #endif

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How it works", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)

            Text("Dual-player crossfade architecture:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("• Two AVAudioPlayers working together")
                Text("• Track 1 fades out while Track 2 fades in")
                Text("• Seamless gapless transitions")
                Text("• Adjust crossfade duration with slider")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.blue.opacity(0.1))
        )
    }

    private func errorSection(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.1))
        )
    }

    // MARK: - Business Logic

    private func loadResources() async {
        // Load audio files with meaningful metadata for lock screen
        let trackData: [(file: String, title: String, artist: String)] = [
            ("stage1_intro_music", "Opening Meditation", "Peaceful Sounds"),
            ("stage2_practice_music", "Deep Practice Session", "Mindful Music"),
            ("stage3_closing_music", "Closing Reflection", "Calm Melodies")
        ]

        for (fileName, title, artist) in trackData {
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "mp3") else {
                continue
            }

            if let track = Track(url: url, title: title, artist: artist) {
                tracks.append(track)
            }
        }

        guard !tracks.isEmpty else {
            errorMessage = "Audio files not found"
            return
        }

        // Audio service now comes from App-level Environment
        // Just update its configuration
        guard let service = audioService else {
            errorMessage = "Audio service not available"
            return
        }

        do {
            let config = PlayerConfiguration(
                crossfadeDuration: crossfadeDuration,
                repeatMode: .playlist,
                repeatCount: nil,
                volume: Float(volume)
            )
            try await service.updateConfiguration(config)
        } catch {
            errorMessage = "Failed to update configuration: \(error.localizedDescription)"
        }
    }

    private func updateConfiguration() async {
        guard let service = audioService else { return }

        let config = PlayerConfiguration(
            crossfadeDuration: crossfadeDuration,
            repeatMode: .playlist,
            repeatCount: nil,
            volume: Float(volume)
        )

        do {
            try await service.updateConfiguration(config)
        } catch {
            errorMessage = "Failed to update config: \(error.localizedDescription)"
        }
    }

    private func play() async {
        guard let service = audioService, !tracks.isEmpty else { return }

        do {
            try await service.loadPlaylist(tracks)
            try await service.startPlaying(fadeDuration: 2.0)
            // ✅ State updates via AsyncStream (no manual polling needed)
            await updateTrackInfo()
            errorMessage = nil
        } catch {
            errorMessage = "Play error: \(error.localizedDescription)"
        }
    }

    private func stop() async {
        guard let service = audioService else { return }

        await service.stop()
        // ✅ State updates via AsyncStream (no manual polling needed)
        currentTrack = "No track"
    }

    private func updateTrackInfo() async {
        guard let service = audioService else { return }

        if let metadata = await service.currentTrack {
            if let title = metadata.title {
                currentTrack = title
            } else {
                currentTrack = "Track"
            }
        }
    }

    // MARK: - Experimental Tests

    #if DEBUG
    private func toggleMixWithOthers() async {
        // Audio session options are now app-managed
        // Use AVAudioSession.sharedInstance().setCategory() directly
        testMessage = "⚠️ Session options are now app-managed. Use AVAudioSession directly."
        Task {
            try? await Task.sleep(for: .seconds(3))
            testMessage = nil
        }
    }

    private func simulateDeveloperRecording() async {
        testMessage = "Simulating developer changing category to .record..."

        // Simulate external developer code changing audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            
            testMessage = "⚠️ Category changed to .record! SDK should recover via MediaServicesReset."
            
            // Clear message after 5 seconds
            Task {
                try? await Task.sleep(for: .seconds(5))
                testMessage = nil
            }
        } catch {
            testMessage = "❌ Simulation failed: \(error.localizedDescription)"
        }
    }
    #endif
}

#Preview {
    CrossfadeBasicView()
}
