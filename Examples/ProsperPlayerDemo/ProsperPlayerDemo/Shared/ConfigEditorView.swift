//
//  ConfigEditorView.swift
//  ProsperPlayerDemo
//
//  Editable configuration UI for PlayerConfiguration
//

import SwiftUI
import AudioServiceCore

/// Editable configuration UI
///
/// Allows users to modify PlayerConfiguration parameters and apply changes.
/// Use this in demos where configuration control is part of the learning experience.
struct ConfigEditorView: View {
    
    @Binding var config: PlayerConfiguration
    let onApply: (PlayerConfiguration) async throws -> Void
    
    @State private var crossfadeDuration: Double
    @State private var fadeCurve: FadeCurve
    @State private var repeatMode: RepeatMode
    @State private var repeatCount: String
    @State private var volume: Double
    @State private var isApplying: Bool = false
    @State private var errorMessage: String?
    
    init(
        config: Binding<PlayerConfiguration>,
        onApply: @escaping (PlayerConfiguration) async throws -> Void
    ) {
        self._config = config
        self.onApply = onApply
        
        // Initialize state from config
        _crossfadeDuration = State(initialValue: config.wrappedValue.crossfadeDuration)
        _fadeCurve = State(initialValue: config.wrappedValue.fadeCurve)
        _repeatMode = State(initialValue: config.wrappedValue.repeatMode)
        _repeatCount = State(initialValue: config.wrappedValue.repeatCount.map { "\($0)" } ?? "")
        _volume = State(initialValue: Double(config.wrappedValue.volume))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            
            crossfadeSection
            playbackModeSection
            audioSection
            
            if let error = errorMessage {
                errorSection(error)
            }
            
            applyButton
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }
    
    // MARK: - Sections
    
    private var header: some View {
        Label("Edit Configuration", systemImage: "slider.horizontal.3")
            .font(.headline)
            .foregroundStyle(.blue)
    }
    
    private var crossfadeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Crossfade", icon: "waveform.path.ecg")
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(crossfadeDuration, specifier: "%.1f") sec")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                
                Slider(value: $crossfadeDuration, in: 0...30, step: 0.5)
                    .tint(.blue)
                
                Text("0 = instant switch, 30 = slow blend")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            )
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Fade Curve")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("Fade Curve", selection: $fadeCurve) {
                    Text("Linear").tag(FadeCurve.linear)
                    Text("Equal Power").tag(FadeCurve.equalPower)
                    Text("Logarithmic").tag(FadeCurve.logarithmic)
                    Text("Exponential").tag(FadeCurve.exponential)
                    Text("S-Curve").tag(FadeCurve.sCurve)
                }
                .pickerStyle(.menu)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            )
        }
    }
    
    private var playbackModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Playback Mode", icon: "repeat")
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Repeat Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("Repeat Mode", selection: $repeatMode) {
                    Text("Off").tag(RepeatMode.off)
                    Text("Single Track").tag(RepeatMode.singleTrack)
                    Text("Playlist").tag(RepeatMode.playlist)
                }
                .pickerStyle(.segmented)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            )
            
            if repeatMode != .off {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repeat Count")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        TextField("∞ (infinite)", text: $repeatCount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        
                        Text("Empty = infinite loop")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemBackground))
                )
            }
        }
    }
    
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Audio", icon: "speaker.wave.2")
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(volume * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                
                Slider(value: $volume, in: 0...1, step: 0.05)
                    .tint(.blue)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            )
        }
    }
    
    private func errorSection(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }
    
    private var applyButton: some View {
        Button(action: { Task { await applyChanges() } }) {
            HStack {
                if isApplying {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                
                Text(isApplying ? "Applying..." : "Apply Changes")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isApplying || !hasChanges)
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
    }
    
    // MARK: - Actions
    
    private func applyChanges() async {
        errorMessage = nil
        isApplying = true
        defer { isApplying = false }
        
        // Build new configuration
        let parsedRepeatCount: Int? = repeatCount.isEmpty ? nil : Int(repeatCount)
        
        let newConfig = PlayerConfiguration(
            crossfadeDuration: crossfadeDuration,
            fadeCurve: fadeCurve,
            repeatMode: repeatMode,
            repeatCount: parsedRepeatCount,
            volume: Float(volume)
        )
        
        // Validate
        do {
            try newConfig.validate()
        } catch {
            errorMessage = "Invalid configuration: \(error.localizedDescription)"
            return
        }
        
        // Apply via callback
        do {
            try await onApply(newConfig)
            config = newConfig // Update binding
            errorMessage = nil
        } catch {
            errorMessage = "Failed to apply: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Computed Properties
    
    private var hasChanges: Bool {
        let parsedRepeatCount: Int? = repeatCount.isEmpty ? nil : Int(repeatCount)
        
        return crossfadeDuration != config.crossfadeDuration ||
               fadeCurve != config.fadeCurve ||
               repeatMode != config.repeatMode ||
               parsedRepeatCount != config.repeatCount ||
               abs(Float(volume) - config.volume) > 0.01
    }
}

// MARK: - Settings Button Component

/// Button that shows configuration editor in a sheet
struct ConfigEditorButton: View {
    
    @Binding var config: PlayerConfiguration
    let onApply: (PlayerConfiguration) async throws -> Void
    
    @State private var showingEditor = false
    
    var body: some View {
        Button(action: { showingEditor = true }) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(.blue)
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                ScrollView {
                    ConfigEditorView(config: $config, onApply: onApply)
                        .padding()
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingEditor = false
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }
}

// MARK: - Preview

#Preview("Config Editor") {
    struct PreviewWrapper: View {
        @State private var config = PlayerConfiguration.demoDefault
        
        var body: some View {
            ScrollView {
                ConfigEditorView(config: $config) { newConfig in
                    print("Applied: \(newConfig)")
                }
                .padding()
            }
        }
    }
    
    return PreviewWrapper()
}

#Preview("Config Editor Button") {
    struct PreviewWrapper: View {
        @State private var config = PlayerConfiguration.demoDefault
        
        var body: some View {
            ConfigEditorButton(config: $config) { newConfig in
                print("Applied: \(newConfig)")
            }
            .padding()
        }
    }
    
    return PreviewWrapper()
}
