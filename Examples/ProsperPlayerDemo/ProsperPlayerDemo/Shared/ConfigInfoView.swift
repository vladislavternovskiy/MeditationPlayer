//
//  ConfigInfoView.swift
//  ProsperPlayerDemo
//
//  Displays current PlayerConfiguration in read-only format
//

import SwiftUI
import AudioServiceCore

/// Read-only display of current PlayerConfiguration
///
/// Shows all configuration parameters in a formatted, easy-to-read layout.
/// Use this to help users understand why the demo behaves a certain way.
struct ConfigInfoView: View {
    
    let config: PlayerConfiguration
    let showTitle: Bool
    
    init(config: PlayerConfiguration, showTitle: Bool = true) {
        self.config = config
        self.showTitle = showTitle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showTitle {
                header
            }
            
            crossfadeSection
            playbackModeSection
            audioSettingsSection
            
            if showAdvanced {
                advancedSection
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }
    
    // MARK: - Sections
    
    private var header: some View {
        Label("Current Configuration", systemImage: "gearshape.fill")
            .font(.headline)
            .foregroundStyle(.blue)
    }
    
    private var crossfadeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Crossfade", icon: "waveform.path.ecg")
            
            configRow(
                label: "Duration",
                value: formatDuration(config.crossfadeDuration),
                icon: "timer"
            )
            
            configRow(
                label: "Curve",
                value: formatFadeCurve(config.fadeCurve),
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }
    
    private var playbackModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Playback Mode", icon: "repeat")
            
            configRow(
                label: "Repeat Mode",
                value: formatRepeatMode(config.repeatMode),
                icon: "arrow.triangle.2.circlepath"
            )
            
            if config.repeatMode != .off {
                configRow(
                    label: "Repeat Count",
                    value: formatRepeatCount(config.repeatCount),
                    icon: "number"
                )
            }
        }
    }
    
    private var audioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Audio", icon: "speaker.wave.2")
            
            configRow(
                label: "Volume",
                value: formatVolume(config.volume),
                icon: "speaker.wave.3"
            )
        }
    }
    
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Advanced", icon: "wrench.and.screwdriver")

            configRow(
                label: "Audio Session",
                value: "App-managed",
                icon: "waveform.circle"
            )
        }
    }
    
    // MARK: - Helper Views
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.top, 4)
    }
    
    private func configRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            
            Spacer()
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
        )
    }
    
    // MARK: - Formatters
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration == 0 {
            return "Instant (no fade)"
        }
        return String(format: "%.1f sec", duration)
    }
    
    private func formatFadeCurve(_ curve: FadeCurve) -> String {
        switch curve {
        case .linear:
            return "Linear"
        case .equalPower:
            return "Equal Power (default)"
        case .logarithmic:
            return "Logarithmic"
        case .exponential:
            return "Exponential"
        case .sCurve:
            return "S-Curve"
        }
    }
    
    private func formatRepeatMode(_ mode: RepeatMode) -> String {
        switch mode {
        case .off:
            return "Off (play once)"
        case .singleTrack:
            return "Single Track Loop"
        case .playlist:
            return "Playlist Loop"
        }
    }
    
    private func formatRepeatCount(_ count: Int?) -> String {
        guard let count = count else {
            return "∞ (infinite)"
        }
        if count == 0 {
            return "0 (play once)"
        }
        return "\(count) times"
    }
    
    private func formatVolume(_ volume: Float) -> String {
        let percentage = Int(volume * 100)
        return "\(percentage)%"
    }
    
    // MARK: - Computed Properties

    private var showAdvanced: Bool {
        false // Audio session is always app-managed now
    }
}

// MARK: - Info Button Component

/// Button that shows configuration in a sheet
struct ConfigInfoButton: View {
    
    let config: PlayerConfiguration
    @State private var showingConfig = false
    
    var body: some View {
        Button(action: { showingConfig = true }) {
            Image(systemName: "info.circle")
                .font(.title3)
                .foregroundStyle(.blue)
        }
        .sheet(isPresented: $showingConfig) {
            NavigationStack {
                ScrollView {
                    ConfigInfoView(config: config)
                        .padding()
                }
                .navigationTitle("Configuration")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingConfig = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Preview

#Preview("Config Info View") {
    ConfigInfoView(
        config: PlayerConfiguration(
            crossfadeDuration: 8.0,
            fadeCurve: .equalPower,
            repeatMode: .playlist,
            repeatCount: 3,
            volume: 0.75
        )
    )
    .padding()
}

#Preview("Config Info Button") {
    ConfigInfoButton(
        config: .demoDefault
    )
    .padding()
}
