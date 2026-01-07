//
//  AVAudioPCMBuffer+Processing.swift
//  ProsperPlayer
//
//  Created by Vladyslav Ternovskyi on 07.01.2026.
//

@preconcurrency import AVFoundation
import os.log

enum EBUR128NormalizationError: Error {
    case emptyBuffer
    case unsupportedFormat(String)
    case converterInitFailed
    case conversionFailed
}

// MARK: - Public API

extension AVAudioPCMBuffer {

    /// Returns a new buffer resampled to `sampleRate` as Float32, non-interleaved.
    func resampled(to sampleRate: Double = 44_100) throws -> AVAudioPCMBuffer {
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: format.channelCount,
                                      interleaved: false)!
        return try AudioBufferConverter.convert(self, to: outFormat)
    }

    /// Normalizes to Integrated Loudness (LUFS) and Maximum True Peak (dBTP) using an offline
    /// BS.1770/EBU R128 style measurement + oversampled true-peak limiting.
    ///
    /// - Parameters:
    ///   - targetIntegratedLUFS: e.g. -16.0
    ///   - maxTruePeakDBTP: e.g. -1.0
    ///   - outputSampleRate: e.g. 44_100
    ///   - maxIterations: allows small correction after limiting
    func normalizedEBUR128(
        targetIntegratedLUFS: Double = -13.0,
        maxTruePeakDBTP: Double = -1.0,
        outputSampleRate: Double = 44_100,
        maxIterations: Int = 3,
        loudnessToleranceLU: Double = 0.1
    ) throws -> AVAudioPCMBuffer {

        guard frameLength > 0 else { throw EBUR128NormalizationError.emptyBuffer }

        // Ensure Float32 @ 44.1kHz (as requested).
        var working = try self.resampled(to: outputSampleRate)

        for _ in 0..<maxIterations {
            let currentLUFS = try BS1770Meter.integratedLUFS(of: working)
            if currentLUFS.isNaN || currentLUFS.isInfinite { break }

            let gainDB = targetIntegratedLUFS - currentLUFS
            AudioDSP.applyGain(in: working, gainDB: gainDB)

            working = try TruePeakLimiter.limit(buffer: working,
                                                ceilingDBTP: maxTruePeakDBTP,
                                                oversampleFactor: 4)

            let afterLUFS = try BS1770Meter.integratedLUFS(of: working)
            let afterTP = try TruePeakMeter.truePeakDBTP(of: working, oversampleFactor: 4)

            if abs(afterLUFS - targetIntegratedLUFS) <= loudnessToleranceLU && afterTP <= maxTruePeakDBTP {
                break
            }
        }

        return working
    }
}

// MARK: - Conversion

private enum AudioBufferConverter {

    static func convert(_ buffer: AVAudioPCMBuffer, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: outFormat) else {
            throw EBUR128NormalizationError.converterInitFailed
        }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let estimatedFrames = Int(ceil(Double(buffer.frameLength) * ratio))
        let outCapacity = AVAudioFrameCount(max(estimatedFrames + 4096, 4096))

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw EBUR128NormalizationError.conversionFailed
        }

        var didProvideInput = false
        var error: NSError?

        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error { throw error }
        return outBuffer
    }
}

// MARK: - Loudness Meter (BS.1770 integrated, gated)

private enum BS1770Meter {

    /// Integrated loudness (LUFS) using:
    /// - K-weighting filter
    /// - 400 ms blocks with 75% overlap (100 ms step)
    /// - absolute gate at -70 LUFS
    /// - relative gate at -10 LU below the ungated average of gated blocks
    static func integratedLUFS(of buffer: AVAudioPCMBuffer) throws -> Double {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let floatData = buffer.floatChannelData
        else { throw EBUR128NormalizationError.unsupportedFormat("Expected Float32 non-interleaved buffer.") }

        let sr = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        // Typical mono/stereo case: weight 1.0 each channel (LFE exclusion requires layout-aware mapping).
        let weights = Array(repeating: 1.0, count: channels)

        let coeffs = KWeightingCoefficients(sampleRate: sr)
        var states = Array(repeating: KWeightingState(), count: channels)

        // 400 ms window with 100 ms step (75% overlap).
        let window = max(1, Int((sr * 0.4).rounded()))
        let step = max(1, Int((sr * 0.1).rounded()))

        // If shorter than one 400ms window, fall back to ungated loudness over the whole buffer.
        if frames < window {
            let energy = try meanSquareEnergyOverWholeSignal(floatData: floatData,
                                                             frames: frames,
                                                             channels: channels,
                                                             weights: weights,
                                                             coeffs: coeffs,
                                                             states: &states)
            return energyToLUFS(energy)
        }

        var ring = Array(repeating: 0.0, count: window)
        var ringIndex = 0
        var runningSum = 0.0

        var blockEnergies: [Double] = []
        blockEnergies.reserveCapacity(max(1, frames / step))

        for i in 0..<frames {
            var s = 0.0
            for ch in 0..<channels {
                let x = Double(floatData[ch][i])
                let y = coeffs.process(x, state: &states[ch])
                s += weights[ch] * (y * y)
            }

            runningSum -= ring[ringIndex]
            ring[ringIndex] = s
            runningSum += s
            ringIndex = (ringIndex + 1) % window

            if i >= window - 1 {
                let blockIndex = i - (window - 1)
                if blockIndex % step == 0 {
                    blockEnergies.append(runningSum / Double(window))
                }
            }
        }

        // Absolute gate at -70 LUFS.
        let absGated = blockEnergies.filter { energyToLUFS($0) >= -70.0 }
        guard !absGated.isEmpty else { return -Double.infinity }

        let absMean = absGated.reduce(0.0, +) / Double(absGated.count)

        // Relative gate: -10 LU => energy factor 10^(-10/10) = 0.1
        let relativeThreshold = absMean * pow(10.0, -10.0 / 10.0)
        let relGated = absGated.filter { $0 >= relativeThreshold }
        guard !relGated.isEmpty else { return -Double.infinity }

        let gatedMean = relGated.reduce(0.0, +) / Double(relGated.count)
        return energyToLUFS(gatedMean)
    }

    private static func meanSquareEnergyOverWholeSignal(
        floatData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frames: Int,
        channels: Int,
        weights: [Double],
        coeffs: KWeightingCoefficients,
        states: inout [KWeightingState]
    ) throws -> Double {
        guard frames > 0 else { return 0.0 }
        var sum = 0.0
        for i in 0..<frames {
            var s = 0.0
            for ch in 0..<channels {
                let x = Double(floatData[ch][i])
                let y = coeffs.process(x, state: &states[ch])
                s += weights[ch] * (y * y)
            }
            sum += s
        }
        return sum / Double(frames)
    }

    // BS.1770 loudness calibration uses -0.691 offset (energy -> LUFS).
    private static func energyToLUFS(_ e: Double) -> Double {
        guard e > 0 else { return -Double.infinity }
        return 10.0 * log10(e) - 0.691
    }
}

// MARK: - K-weighting (sample-rate aware)

private struct KWeightingCoefficients {
    let b: [Double] // b0..b4
    let a: [Double] // a0..a4

    /// Sample-rate aware coefficient derivation (used by libebur128/FFmpeg for BS.1770).
    init(sampleRate fs: Double) {
        // Shelving stage
        var f0 = 1681.974450955533
        let G = 3.999843853973347
        var Q = 0.7071752369554196

        var K = tan(Double.pi * f0 / fs)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)

        let a0 = 1.0 + K / Q + K * K
        let pb0 = (Vh + Vb * K / Q + K * K) / a0
        let pb1 = 2.0 * (K * K - Vh) / a0
        let pb2 = (Vh - Vb * K / Q + K * K) / a0
        let pa0 = 1.0
        let pa1 = 2.0 * (K * K - 1.0) / a0
        let pa2 = (1.0 - K / Q + K * K) / a0

        // RLB high-pass stage
        f0 = 38.13547087602444
        Q = 0.5003270373238773
        K = tan(Double.pi * f0 / fs)

        let rb0 = 1.0, rb1 = -2.0, rb2 = 1.0
        let ra0 = 1.0
        let ra1 = 2.0 * (K * K - 1.0) / (1.0 + K / Q + K * K)
        let ra2 = (1.0 - K / Q + K * K) / (1.0 + K / Q + K * K)

        // Convolution => 4th order IIR
        let b0 = pb0 * rb0
        let b1 = pb0 * rb1 + pb1 * rb0
        let b2 = pb0 * rb2 + pb1 * rb1 + pb2 * rb0
        let b3 = pb1 * rb2 + pb2 * rb1
        let b4 = pb2 * rb2

        let a0c = pa0 * ra0
        let a1c = pa0 * ra1 + pa1 * ra0
        let a2c = pa0 * ra2 + pa1 * ra1 + pa2 * ra0
        let a3c = pa1 * ra2 + pa2 * ra1
        let a4c = pa2 * ra2

        self.b = [b0, b1, b2, b3, b4]
        self.a = [a0c, a1c, a2c, a3c, a4c]
    }

    func process(_ x: Double, state: inout KWeightingState) -> Double {
        let y = (b[0] * x
                 + b[1] * state.x1
                 + b[2] * state.x2
                 + b[3] * state.x3
                 + b[4] * state.x4
                 - a[1] * state.y1
                 - a[2] * state.y2
                 - a[3] * state.y3
                 - a[4] * state.y4) / a[0]

        state.x4 = state.x3; state.x3 = state.x2; state.x2 = state.x1; state.x1 = x
        state.y4 = state.y3; state.y3 = state.y2; state.y2 = state.y1; state.y1 = y
        return y
    }
}

private struct KWeightingState {
    var x1 = 0.0, x2 = 0.0, x3 = 0.0, x4 = 0.0
    var y1 = 0.0, y2 = 0.0, y3 = 0.0, y4 = 0.0
}

// MARK: - Gain

private enum AudioDSP {
    static func applyGain(in buffer: AVAudioPCMBuffer, gainDB: Double) {
        guard let data = buffer.floatChannelData else { return }
        let gain = Float(pow(10.0, gainDB / 20.0))
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<frames {
                ptr[i] *= gain
            }
        }
    }
}

// MARK: - True Peak metering + limiting

private enum TruePeakMeter {

    static func truePeakDBTP(of buffer: AVAudioPCMBuffer, oversampleFactor: Int) throws -> Double {
        let osr = buffer.format.sampleRate * Double(oversampleFactor)
        let osFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: osr,
                                     channels: buffer.format.channelCount,
                                     interleaved: false)!
        let osBuffer = try AudioBufferConverter.convert(buffer, to: osFormat)

        guard let data = osBuffer.floatChannelData else { return -Double.infinity }
        let channels = Int(osBuffer.format.channelCount)
        let frames = Int(osBuffer.frameLength)

        var maxAbs: Float = 0
        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<frames {
                maxAbs = max(maxAbs, abs(ptr[i]))
            }
        }

        guard maxAbs > 0 else { return -Double.infinity }
        return 20.0 * log10(Double(maxAbs))
    }
}

private enum TruePeakLimiter {

    /// Offline, oversampled, peak-linked limiter (single-band).
    static func limit(buffer: AVAudioPCMBuffer, ceilingDBTP: Double, oversampleFactor: Int) throws -> AVAudioPCMBuffer {
        let ceiling = Float(pow(10.0, ceilingDBTP / 20.0))

        // Upsample
        let osr = buffer.format.sampleRate * Double(oversampleFactor)
        let osFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: osr,
                                     channels: buffer.format.channelCount,
                                     interleaved: false)!
        var osBuffer = try AudioBufferConverter.convert(buffer, to: osFormat)

        guard let data = osBuffer.floatChannelData else { return buffer }
        let channels = Int(osBuffer.format.channelCount)
        let frames = Int(osBuffer.frameLength)

        // Peak link across channels
        var peak = Array(repeating: Float(0), count: frames)
        for i in 0..<frames {
            var m: Float = 0
            for ch in 0..<channels {
                m = max(m, abs(data[ch][i]))
            }
            peak[i] = m
        }

        // Forward lookahead window (offline non-causal gain)
        let lookaheadSeconds = 0.001 // 1 ms
        let lookahead = max(1, Int((osr * lookaheadSeconds).rounded()))
        let futureMax = SlidingWindow.maxForward(peak, window: lookahead)

        // Desired gain to enforce ceiling
        var gDesired = Array(repeating: Float(1), count: frames)
        for i in 0..<frames {
            let fm = max(futureMax[i], 1e-9)
            gDesired[i] = min(1.0, ceiling / fm)
        }

        // Smooth gain (but never exceed desired gain => guarantees ceiling in the oversampled domain)
        let attack = 0.0005
        let release = 0.050
        let attackCoeff = Float(exp(-1.0 / (attack * osr)))
        let releaseCoeff = Float(exp(-1.0 / (release * osr)))

        var g: Float = 1.0
        for i in 0..<frames {
            let target = gDesired[i]
            if target < g {
                g = attackCoeff * g + (1 - attackCoeff) * target
            } else {
                g = releaseCoeff * g + (1 - releaseCoeff) * target
            }

            g = min(g, target) // hard safety clamp

            if g < 1.0 {
                for ch in 0..<channels {
                    data[ch][i] *= g
                }
            }
        }

        // Downsample back
        let limited = try AudioBufferConverter.convert(osBuffer, to: buffer.format)

        // Safety: if resampling introduced a tiny overshoot, run once more.
        let tp = try TruePeakMeter.truePeakDBTP(of: limited, oversampleFactor: oversampleFactor)
        if tp > ceilingDBTP {
            return try limit(buffer: limited, ceilingDBTP: ceilingDBTP, oversampleFactor: oversampleFactor)
        }

        return limited
    }
}

private enum SlidingWindow {
    /// out[i] = max(x[i...i+window-1]) (window shrinks near the end)
    static func maxForward(_ x: [Float], window: Int) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }

        let w = max(1, window)
        var out = Array(repeating: Float(0), count: n)

        var dq: [Int] = []
        dq.reserveCapacity(min(n, w))
        var head = 0

        @inline(__always) func push(_ idx: Int) {
            while dq.count > head, x[idx] >= x[dq[dq.count - 1]] {
                dq.removeLast()
            }
            dq.append(idx)
        }

        let initialEnd = min(n, w)
        for idx in 0..<initialEnd { push(idx) }
        out[0] = x[dq[head]]

        if n == 1 { return out }

        for i in 1..<n {
            while dq.count > head, dq[head] < i { head += 1 }

            let newIdx = i + w - 1
            if newIdx < n { push(newIdx) }

            if head > 1024 {
                dq.removeFirst(head)
                head = 0
            }

            out[i] = (dq.count > head) ? x[dq[head]] : 0
        }

        return out
    }
}
