//
//  ExternalModeDemo.swift
//  ProsperPlayerDemo
//
//  Demo for External Audio Session Mode
//  Shows: App-managed audio session with validation
//

import SwiftUI
import AVFoundation
import AudioServiceKit
import AudioServiceCore

struct ExternalModeDemo: View {
    
    // MARK: - State
    
    @State private var playerState: PlayerState = .idle
    @State private var currentTrack: String = "No track"
    @State private var errorMessage: String?
    @State private var audioService: AudioPlayerService?
    @State private var selectedScenario: Scenario = .playback
    @State private var sessionConfigured: Bool = false
    @State private var validationLogs: [String] = []
    
    enum Scenario: String, CaseIterable, Identifiable {
        case playback = "Option 1: .playback"
        case playAndRecord = "Option 2: .playAndRecord"
        case missingBluetooth = "❌ Missing Bluetooth"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .playback: return "music.note"
            case .playAndRecord: return "mic.and.music.note"
            case .missingBluetooth: return "exclamationmark.triangle"
            }
        }
        
        var description: String {
            switch self {
            case .playback:
                return "Recommended for music/meditation apps. Uses .playback category with Bluetooth support."
            case .playAndRecord:
                return "For apps needing recording. Uses .playAndRecord with .defaultToSpeaker (REQUIRED)."
            case .missingBluetooth:
                return "Intentionally missing Bluetooth options - shows validation error logging."
            }
        }
        
        var color: Color {
            switch self {
            case .playback: return .blue
            case .playAndRecord: return .green
            case .missingBluetooth: return .red
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // Header
                    headerSection
                    
                    // Scenario Selector
                    scenarioSection
                    
                    // Session Info
                    sessionInfoSection
                    
                    // Validation Logs
                    if !validationLogs.isEmpty {
                        logsSection
                    }
                    
                    // Progress
                    if audioService != nil {
                        ProgressCard(service: audioService)
                    }
                    
                    // Controls
                    controlsSection
                    
                    // Error
                    if let error = errorMessage {
                        errorSection(error)
                    }
                }
                .padding()
            }
            .navigationTitle("External Mode Demo")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Listen to state updates
                guard let service = audioService else { return }
                
                for await state in await service.stateUpdates {
                    await MainActor.run {
                        playerState = state
                    }
                }
            }
        }
    }
    
    // MARK: - View Components
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "gear.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.purple)
            
            Text("External Audio Session Mode")
                .font(.headline)
            
            Text("App manages AVAudioSession before creating player")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Select Scenario", systemImage: "list.bullet.circle")
                .font(.headline)
                .foregroundStyle(.purple)
            
            ForEach(Scenario.allCases) { scenario in
                scenarioButton(scenario)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.purple.opacity(0.1))
        )
    }
    
    private func scenarioButton(_ scenario: Scenario) -> some View {
        Button {
            selectedScenario = scenario
            sessionConfigured = false
            validationLogs = []
            errorMessage = nil
            // Reset service when changing scenario
            audioService = nil
        } label: {
            HStack {
                Image(systemName: scenario.icon)
                    .font(.title2)
                    .foregroundStyle(scenario.color)
                    .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(scenario.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(scenario.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                if selectedScenario == scenario {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(scenario.color)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selectedScenario == scenario ? scenario.color.opacity(0.1) : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedScenario == scenario ? scenario.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio Session Info", systemImage: "waveform.circle")
                .font(.headline)
                .foregroundStyle(.purple)
            
            if sessionConfigured {
                let session = AVAudioSession.sharedInstance()
                
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(title: "Category", value: session.category.rawValue)
                    infoRow(title: "Options", value: formatOptions(session.categoryOptions))
                    infoRow(title: "Active", value: session.isOtherAudioPlaying ? "Yes" : "No")
                }
            } else {
                Text("Session not configured yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4)
        )
    }
    
    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title + ":")
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .font(.system(.body, design: .monospaced))
        }
    }
    
    private func formatOptions(_ options: AVAudioSession.CategoryOptions) -> String {
        var result: [String] = []
        if options.contains(.mixWithOthers) { result.append(".mixWithOthers") }
        if options.contains(.duckOthers) { result.append(".duckOthers") }
        if options.contains(.allowBluetooth) { result.append(".allowBluetooth") }
        if options.contains(.allowBluetoothA2DP) { result.append(".allowBluetoothA2DP") }
        if options.contains(.allowAirPlay) { result.append(".allowAirPlay") }
        if options.contains(.defaultToSpeaker) { result.append(".defaultToSpeaker") }
        return result.isEmpty ? "[]" : result.joined(separator: ", ")
    }
    
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Validation Logs", systemImage: "doc.text")
                .font(.headline)
                .foregroundStyle(.purple)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(validationLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(log.contains("❌") || log.contains("⚠️") ? .red : .primary)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4)
        )
    }
    
    private var controlsSection: some View {
        VStack(spacing: 12) {
            // Configure Session button
            Button {
                configureSession()
            } label: {
                Label("1. Configure Audio Session", systemImage: "gear")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(sessionConfigured ? Color.green.opacity(0.2) : Color.blue)
                    )
                    .foregroundStyle(sessionConfigured ? .green : .white)
            }
            .disabled(sessionConfigured)
            
            // Create Player button
            Button {
                Task { await createPlayer() }
            } label: {
                Label("2. Create Player (External Mode)", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(audioService != nil ? Color.green.opacity(0.2) : Color.purple)
                    )
                    .foregroundStyle(audioService != nil ? .green : .white)
            }
            .disabled(!sessionConfigured || audioService != nil)
            
            // Play button
            Button {
                Task { await playTrack() }
            } label: {
                Label("3. Play Track", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green)
                    )
                    .foregroundStyle(.white)
            }
            .disabled(audioService == nil || playerState == .playing)
            
            // Stop button
            if playerState == .playing || playerState == .paused {
                Button {
                    Task { await stopPlayback() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red)
                        )
                        .foregroundStyle(.white)
                }
            }
            
            // Reset button
            if sessionConfigured {
                Button {
                    resetDemo()
                } label: {
                    Label("Reset Demo", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange)
                        )
                        .foregroundStyle(.white)
                }
            }
        }
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
    
    private func configureSession() {
        validationLogs = []
        errorMessage = nil
        
        let session = AVAudioSession.sharedInstance()
        
        do {
            switch selectedScenario {
            case .playback:
                // Option 1: Simple playback (matches SDK managed mode)
                try session.setCategory(
                    .playback,
                    options: [.allowBluetoothA2DP]
                )
                validationLogs.append("✅ Set category: .playback")
                validationLogs.append("✅ Options: [.allowBluetoothA2DP] (high-quality Bluetooth)")
                
            case .playAndRecord:
                // Option 2: Recording + playback
                try session.setCategory(
                    .playAndRecord,
                    options: [
                        .defaultToSpeaker,
                        .allowBluetoothA2DP
                    ]
                )
                validationLogs.append("✅ Set category: .playAndRecord")
                validationLogs.append("✅ Options: [.defaultToSpeaker, .allowBluetoothA2DP] (high-quality Bluetooth)")
                validationLogs.append("ℹ️  .defaultToSpeaker routes to speaker, not earpiece")
                
            case .missingBluetooth:
                // Scenario 3: Intentionally missing Bluetooth
                try session.setCategory(.playback)
                validationLogs.append("❌ Set category: .playback")
                validationLogs.append("❌ Options: [] (NO BLUETOOTH!)")
                validationLogs.append("⚠️  SDK will show error on player creation")
            }
            
            try session.setActive(true)
            validationLogs.append("✅ Session activated")
            
            sessionConfigured = true
            
        } catch {
            errorMessage = "Failed to configure session: \(error.localizedDescription)"
            validationLogs.append("❌ ERROR: \(error.localizedDescription)")
        }
    }
    
    private func createPlayer() async {
        validationLogs.append("")
        validationLogs.append("Creating player (session managed by app)...")

        do {
            let config = PlayerConfiguration(
                crossfadeDuration: 0.0,
                volume: 0.8
            )
            
            audioService = try await AudioPlayerService(configuration: config)
            validationLogs.append("✅ Player created successfully")
            
            if selectedScenario == .missingBluetooth {
                validationLogs.append("")
                validationLogs.append("⚠️  Check Xcode console for detailed error logs!")
                validationLogs.append("⚠️  SDK showed Logger.error() messages about missing Bluetooth")
            } else {
                validationLogs.append("✅ Validation passed - session is compatible")
            }
            
        } catch {
            errorMessage = "Failed to create player: \(error.localizedDescription)"
            validationLogs.append("❌ ERROR: \(error.localizedDescription)")
        }
    }
    
    private func playTrack() async {
        guard let service = audioService else { return }
        
        // Load audio file
        guard let url = Bundle.main.url(forResource: "stage1_intro_music", withExtension: "mp3") else {
            errorMessage = "Audio file not found"
            return
        }
        
        guard let track = Track(
            url: url,
            title: "Opening Meditation",
            artist: "Peaceful Sounds"
        ) else {
            errorMessage = "Failed to create track"
            return
        }
        
        currentTrack = track.metadata?.title ?? "Opening Meditation"
        
        do {
            try await service.loadPlaylist([track])
            validationLogs.append("✅ Track loaded and playing")
        } catch {
            errorMessage = "Failed to play: \(error.localizedDescription)"
            validationLogs.append("❌ ERROR: \(error.localizedDescription)")
        }
    }
    
    private func stopPlayback() async {
        guard let service = audioService else { return }
        await service.stopAll()
        validationLogs.append("⏹️  Playback stopped")
    }
    
    private func resetDemo() {
        sessionConfigured = false
        validationLogs = []
        errorMessage = nil
        audioService = nil
        currentTrack = "No track"
        
        // Deactivate session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Ignore
        }
    }
}

#Preview {
    ExternalModeDemo()
}
