//
//  AVAudioPCMBuffer+Processing.swift
//  ProsperPlayer
//
//  Created by Vladyslav Ternovskyi on 07.01.2026.
//

@preconcurrency import AVFoundation
import Accelerate
import os.log

public extension AVAudioPCMBuffer {

    // MARK: - Types

    struct LoudnessNormalizationResult: Sendable {
        public let output: AVAudioPCMBuffer
        public let inputIntegratedLUFS: Float
        public let inputTruePeakDBTP: Float
        public let appliedGainDB: Float
        public let outputEstimatedIntegratedLUFS: Float
        public let outputEstimatedTruePeakDBTP: Float
        public let limitedByTruePeak: Bool
    }

    enum LoudnessNormalizationError: Error {
        case unsupportedFormat
        case conversionFailed(String)
        case silenceOrNoGatedBlocks
    }

    // MARK: - Public API

    /// Loudness-normalize to EBU R128 / ITU-R BS.1770 integrated loudness (LUFS) with a true-peak ceiling (dBTP).
    ///
    /// - Important:
    ///   This performs *linear gain* only. If the true-peak ceiling constrains the gain, output loudness can end up
    ///   lower than the target (a true-peak limiter is required to satisfy both simultaneously in all cases).
    ///
    /// - Parameters:
    ///   - targetIntegratedLUFS: Target integrated loudness, e.g. `-16`.
    ///   - truePeakLimitDBTP: True-peak ceiling, e.g. `-1`.
    ///   - loudnessMeasurementSampleRate: Sample rate used for LUFS measurement (default 48 kHz).
    ///   - truePeakMeasurementSampleRate: Sample rate used for true-peak measurement (default 192 kHz).
    func normalizeEBUR128(
        targetIntegratedLUFS: Float = -16.0,
        truePeakLimitDBTP: Float = -1.0,
        loudnessMeasurementSampleRate: Double = 48_000,
        truePeakMeasurementSampleRate: Double = 192_000
    ) throws -> LoudnessNormalizationResult {

        // 1) Measure integrated loudness (LUFS) on 48 kHz float, K-weighted + gated.
        let lufs = try measureIntegratedLUFS(measurementSampleRate: loudnessMeasurementSampleRate)

        // 2) Measure true peak (dBTP) using 192 kHz upsampled peak.
        let tp = try measureTruePeakDBTP(measurementSampleRate: truePeakMeasurementSampleRate)

        // 3) Compute gain needed for loudness target.
        let gainDBForLoudness = targetIntegratedLUFS - lufs
        let gainForLoudness = Self.dbToLinear(gainDBForLoudness)

        // Predict TP after gain (linear scaling => dB adds).
        let predictedTP = tp + gainDBForLoudness

        // 4) If TP would exceed ceiling, cap the gain.
        let limitedByTP = predictedTP > truePeakLimitDBTP
        let finalGainDB: Float
        if limitedByTP {
            finalGainDB = truePeakLimitDBTP - tp
        } else {
            finalGainDB = gainDBForLoudness
        }
        let finalGain = Self.dbToLinear(finalGainDB)

        // 5) Apply gain to original format buffer.
        let out = try applyingLinearGain(finalGain)

        return LoudnessNormalizationResult(
            output: out,
            inputIntegratedLUFS: lufs,
            inputTruePeakDBTP: tp,
            appliedGainDB: finalGainDB,
            outputEstimatedIntegratedLUFS: lufs + finalGainDB,
            outputEstimatedTruePeakDBTP: tp + finalGainDB,
            limitedByTruePeak: limitedByTP
        )
    }

    // MARK: - Integrated LUFS (EBU R128 / BS.1770 gating)

    private func measureIntegratedLUFS(measurementSampleRate: Double) throws -> Float {
        let measured = try convertedToFloat32NonInterleaved(sampleRate: measurementSampleRate)
        let filtered = try measured.kWeighted48kInPlaceCopy()

        let sr = filtered.format.sampleRate
        let frameCount = Int(filtered.frameLength)
        let channels = Int(filtered.format.channelCount)

        // Gating blocks: 400 ms with 75% overlap => 100 ms step.
        let blockSize = Int((0.400 * sr).rounded()) // nearest sample
        let stepSize  = Int((0.100 * sr).rounded()) // 25% of block duration

        guard blockSize > 0, stepSize > 0, frameCount >= blockSize else {
            throw LoudnessNormalizationError.silenceOrNoGatedBlocks
        }
        guard let chData = filtered.floatChannelData else {
            throw LoudnessNormalizationError.unsupportedFormat
        }

        let weights = channelWeightsForITU1770(channelCount: channels)

        // For each block j, compute SumWeightedMS[j] = Σ_i Gi * meanSquare(block(i,j))
        var sumWeightedMS: [Float] = []
        sumWeightedMS.reserveCapacity((frameCount - blockSize) / stepSize + 1)

        var start = 0
        while start + blockSize <= frameCount {
            var sum: Float = 0

            for ch in 0..<channels {
                let ptr = chData[ch].advanced(by: start)

                var ms: Float = 0
                vDSP_measqv(ptr, 1, &ms, vDSP_Length(blockSize))

                sum += weights[ch] * ms
            }

            sumWeightedMS.append(sum)
            start += stepSize
        }

        func blockLUFS(_ ms: Float) -> Float {
            guard ms > 0 else { return -.infinity }
            return -0.691 + 10.0 * log10f(ms)
        }

        // Absolute gate Γa = -70 LKFS (≈ LUFS).
        let gammaA: Float = -70.0
        let blockLufs = sumWeightedMS.map(blockLUFS)
        let jAbs = blockLufs.indices.filter { blockLufs[$0] > gammaA }

        guard !jAbs.isEmpty else {
            throw LoudnessNormalizationError.silenceOrNoGatedBlocks
        }

        func gatedIntegratedLUFS(indices: [Int]) -> Float {
            var avg: Float = 0
            let inv = 1.0 as Float / Float(indices.count)
            for j in indices { avg += sumWeightedMS[j] * inv }
            guard avg > 0 else { return -.infinity }
            return -0.691 + 10.0 * log10f(avg)
        }

        // Relative gate Γr = L_abs - 10.
        let lAbs = gatedIntegratedLUFS(indices: jAbs)
        let gammaR = lAbs - 10.0

        let jFinal = blockLufs.indices.filter { blockLufs[$0] > gammaA && blockLufs[$0] > gammaR }
        guard !jFinal.isEmpty else {
            // If relative gate removes everything, fall back to absolute-gated loudness.
            return lAbs
        }

        return gatedIntegratedLUFS(indices: jFinal)
    }

    /// K-weighting filter per ITU-R BS.1770 (48 kHz coefficients), applied in-place on a copy.
    private func kWeighted48kInPlaceCopy() throws -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        guard abs(sr - 48_000) < 0.5 else {
            // This method expects the buffer already converted to 48 kHz.
            throw LoudnessNormalizationError.conversionFailed("Expected 48 kHz for K-weighting coefficients.")
        }
        let copy = try copiedBuffer()

        guard let chData = copy.floatChannelData else {
            throw LoudnessNormalizationError.unsupportedFormat
        }

        // Stage 1 coefficients (Table 1, 48 kHz)
        var s1 = Biquad(
            b0:  1.53512485958697,
            b1: -2.69169618940638,
            b2:  1.19839281085285,
            a1: -1.69065929318241,
            a2:  0.73248077421585
        )

        // Stage 2 coefficients (Table 2, 48 kHz)
        var s2 = Biquad(
            b0:  1.0,
            b1: -2.0,
            b2:  1.0,
            a1: -1.99004745483398,
            a2:  0.99007225036621
        )

        let channels = Int(copy.format.channelCount)
        let n = Int(copy.frameLength)

        for ch in 0..<channels {
            // Each channel needs its own filter state.
            var f1 = s1
            var f2 = s2

            let ptr = chData[ch]
            for i in 0..<n {
                let x = ptr[i]
                let y1 = f1.process(x)
                let y2 = f2.process(y1)
                ptr[i] = y2
            }
        }

        return copy
    }

    private func channelWeightsForITU1770(channelCount: Int) -> [Float] {
        // BS.1770-5 Table 3: L,R,C = 1.0; Ls,Rs = 1.41; LFE excluded.
        // We apply a pragmatic mapping for common layouts:
        // 1ch: [L]
        // 2ch: [L, R]
        // 5ch: [L, R, C, Ls, Rs]
        // 6ch: [L, R, C, LFE(0), Ls, Rs]
        switch channelCount {
        case 1:
            return [1.0]
        case 2:
            return [1.0, 1.0]
        case 5:
            return [1.0, 1.0, 1.0, 1.41, 1.41]
        case 6:
            return [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]
        default:
            // Fallback: treat all channels equally (not fully standard for multichannel).
            return Array(repeating: 1.0, count: channelCount)
        }
    }

    // MARK: - True Peak (dBTP)

    private func measureTruePeakDBTP(measurementSampleRate: Double) throws -> Float {
        let measured = try convertedToFloat32NonInterleaved(sampleRate: measurementSampleRate)

        guard let chData = measured.floatChannelData else {
            throw LoudnessNormalizationError.unsupportedFormat
        }

        let channels = Int(measured.format.channelCount)
        let n = Int(measured.frameLength)

        var maxAbs: Float = 0
        for ch in 0..<channels {
            var localMax: Float = 0
            vDSP_maxmgv(chData[ch], 1, &localMax, vDSP_Length(n))
            maxAbs = max(maxAbs, localMax)
        }

        // Convert to dBTP (full scale == 1.0).
        return Self.linearToDB(max(maxAbs, 1e-12))
    }

    // MARK: - Gain application

    private func applyingLinearGain(_ gain: Float) throws -> AVAudioPCMBuffer {
        // Work in Float32 for safe scaling, then convert back to original format if needed.
        let float = try convertedToFloat32NonInterleaved(sampleRate: format.sampleRate)
        guard let chData = float.floatChannelData else {
            throw LoudnessNormalizationError.unsupportedFormat
        }

        let channels = Int(float.format.channelCount)
        let n = Int(float.frameLength)

        for ch in 0..<channels {
            var g = gain
            vDSP_vsmul(chData[ch], 1, &g, chData[ch], 1, vDSP_Length(n))
        }

        // If original is already Float32 non-interleaved at the same SR, return directly.
        if format.commonFormat == .pcmFormatFloat32,
           format.isInterleaved == false,
           abs(format.sampleRate - float.format.sampleRate) < 0.5,
           format.channelCount == float.format.channelCount {
            return float
        }

        // Otherwise convert back to the original format.
        return try float.converted(to: format)
    }

    // MARK: - Conversions / copying

    private func convertedToFloat32NonInterleaved(sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: format.channelCount,
            interleaved: false
        ) else {
            throw LoudnessNormalizationError.unsupportedFormat
        }
        return try converted(to: outFormat)
    }

    private func copiedBuffer() throws -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw LoudnessNormalizationError.conversionFailed("Failed to allocate copy buffer.")
        }
        out.frameLength = frameLength

        if let src = floatChannelData, let dst = out.floatChannelData, format.commonFormat == .pcmFormatFloat32 {
            let channels = Int(format.channelCount)
            let n = Int(frameLength)
            for ch in 0..<channels {
                dst[ch].assign(from: src[ch], count: n)
            }
            return out
        }

        // Fallback: convert to same format via AVAudioConverter.
        return try converted(to: format)
    }

    private func converted(to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: format, to: outFormat) else {
            throw LoudnessNormalizationError.conversionFailed("AVAudioConverter init failed.")
        }
        converter.sampleRateConverterQuality = .max

        let ratio = outFormat.sampleRate / format.sampleRate
        let outCapacity = AVAudioFrameCount((Double(frameLength) * ratio).rounded(.up)) + 8

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw LoudnessNormalizationError.conversionFailed("Failed to allocate output buffer.")
        }

        var error: NSError?
        var inputConsumed = false

        while true {
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .endOfStream
                    return nil
                } else {
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return self
                }
            })

            if let error { throw LoudnessNormalizationError.conversionFailed(error.localizedDescription) }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                // We feed the whole buffer in one shot; output is now in outBuffer.
                return outBuffer
            case .error:
                throw LoudnessNormalizationError.conversionFailed("AVAudioConverter error.")
            @unknown default:
                throw LoudnessNormalizationError.conversionFailed("AVAudioConverter unknown status.")
            }
        }
    }

    // MARK: - DSP helpers

    private struct Biquad {
        let b0: Float
        let b1: Float
        let b2: Float
        let a1: Float
        let a2: Float

        // Direct Form I/II state
        private var x1: Float = 0
        private var x2: Float = 0
        private var y1: Float = 0
        private var y2: Float = 0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = Float(b0)
            self.b1 = Float(b1)
            self.b2 = Float(b2)
            self.a1 = Float(a1)
            self.a2 = Float(a2)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    private static func dbToLinear(_ db: Float) -> Float {
        powf(10.0, db / 20.0)
    }

    private static func linearToDB(_ linear: Float) -> Float {
        20.0 * log10f(linear)
    }
}
