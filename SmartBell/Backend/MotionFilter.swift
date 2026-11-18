import Accelerate
import Foundation
import simd

/// Zero-phase FFT filtering of a fixed-length window. The window is mirrored
/// (even extension) before the transform so the periodic signal the FFT assumes
/// has no jump at the window edges; the spectrum is multiplied by per-bin gains
/// and the first half of the inverse transform is the filtered window.
final class MirroredFFTFilter {
    let windowLength: Int
    let transformLength: Int
    private let log2Length: vDSP_Length
    private let fftSetup: FFTSetupD
    private var extended: [Double]
    private var real: [Double]
    private var imaginary: [Double]

    init(windowLength: Int) {
        precondition(windowLength >= 16 && windowLength.nonzeroBitCount == 1,
                     "windowLength must be a power of two of at least 16")
        self.windowLength = windowLength
        transformLength = windowLength * 2
        log2Length = vDSP_Length(transformLength.trailingZeroBitCount)
        guard let fftSetup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create FFT setup for length \(transformLength)")
        }
        self.fftSetup = fftSetup
        extended = Array(repeating: 0, count: transformLength)
        real = Array(repeating: 0, count: windowLength)
        imaginary = Array(repeating: 0, count: windowLength)
    }

    deinit {
        vDSP_destroy_fftsetupD(fftSetup)
    }

    /// Frequency in Hz of each gain bin, from DC (index 0) to Nyquist (index windowLength).
    func binFrequencies(sampleRate: Double) -> [Double] {
        let binWidth = sampleRate / Double(transformLength)
        return (0...windowLength).map { Double($0) * binWidth }
    }

    /// Filters `signal` in place: FFT → multiply by `gains` → IFFT.
    /// `gains` has windowLength + 1 entries (see `binFrequencies`).
    func apply(_ gains: [Double], to signal: inout [Double]) {
        precondition(signal.count == windowLength && gains.count == windowLength + 1)
        for index in 0..<windowLength {
            extended[index] = signal[index]
            extended[transformLength - 1 - index] = signal[index]
        }

        let halfLength = windowLength
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPDoubleSplitComplex(realp: realPointer.baseAddress!,
                                                  imagp: imaginaryPointer.baseAddress!)
                extended.withUnsafeBufferPointer { extendedPointer in
                    extendedPointer.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self,
                                                                    capacity: halfLength) {
                        vDSP_ctozD($0, 2, &split, 1, vDSP_Length(halfLength))
                    }
                }

                vDSP_fft_zripD(fftSetup, &split, 1, log2Length, FFTDirection(kFFTDirection_Forward))

                // Packed real-FFT layout: realp[0] = DC, imagp[0] = Nyquist,
                // then bins 1..<N/2 as complex pairs.
                realPointer[0] *= gains[0]
                imaginaryPointer[0] *= gains[halfLength]
                for bin in 1..<halfLength {
                    realPointer[bin] *= gains[bin]
                    imaginaryPointer[bin] *= gains[bin]
                }

                vDSP_fft_zripD(fftSetup, &split, 1, log2Length, FFTDirection(kFFTDirection_Inverse))

                extended.withUnsafeMutableBufferPointer { extendedPointer in
                    extendedPointer.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self,
                                                                    capacity: halfLength) {
                        vDSP_ztocD(&split, 1, $0, 2, vDSP_Length(halfLength))
                    }
                }
            }
        }

        // vDSP's packed real forward+inverse round trip scales by 2 × transform length.
        let scale = 1 / Double(2 * transformLength)
        for index in 0..<windowLength { signal[index] = extended[index] * scale }
    }

    /// 0 at or below `start`, 1 at or above `end`, with a smooth half-cosine between.
    static func raisedCosineStep(_ value: Double, from start: Double, to end: Double) -> Double {
        if value <= start { return 0 }
        if value >= end { return 1 }
        return 0.5 - 0.5 * cos(Double.pi * (value - start) / (end - start))
    }
}

/// Tuning for the motion low-pass filter applied before angle integration and rep
/// counting. Provisional: experiment with the cutoff against labeled recordings.
struct MotionLowPassConfiguration {
    /// Sliding-window length in samples (power of two); 256 is about 2.6 s at 100 Hz.
    var windowLength = 256
    /// Full gain below `passFrequency`, zero above `stopFrequency`, with a smooth
    /// raised-cosine roll-off between (half gain at the midpoint, 2 Hz by default).
    /// Rep motion sits well below 2 Hz; hand tremor is typically about 4–12 Hz.
    var passFrequency = 1.5
    var stopFrequency = 2.5
    /// Samples are emitted this many samples behind the newest one, where the
    /// finite-window edge effects have mostly settled (0.25 s at 100 Hz). This is the
    /// app's processing delay. In synthetic tests the error was ~2–3% of peak at 25
    /// samples, about the same as at 50; at 10–15 samples it rose to 8–16%.
    var outputLagSamples = 25
    /// Extra samples, beyond the lag, during which a "still" sample is emitted at
    /// start-up. The edge between the pre-filled history and the first real samples
    /// rings briefly; with strong tremor that ringing integrates into a false angle.
    var warmUpSamples = 50
    var nominalSampleInterval = 0.01
}

/// FFT low-pass of all six sensor channels (FFT → zero bins above the cutoff → IFFT).
/// Each call returns the filtered sample from `outputLagSamples` ago, keeping that
/// sample's own timestamp and sensor interval.
struct MotionSampleLowPassFilter {
    let configuration: MotionLowPassConfiguration
    private let filter: MirroredFFTFilter
    private var channels: [[Double]]
    private var timestamps: [TimeInterval]
    private var intervals: [TimeInterval]
    private var writeIndex = 0
    private var isPrimed = false
    private var receivedSamples = 0
    private var initialAcceleration = (x: 0.0, y: 0.0, z: 0.0)
    private var scratch: [Double]
    private var gains: [Double] = []
    private var gainSampleRate = 0.0

    init(configuration: MotionLowPassConfiguration = MotionLowPassConfiguration()) {
        precondition(configuration.outputLagSamples >= 0 &&
                     configuration.outputLagSamples < configuration.windowLength)
        self.configuration = configuration
        filter = MirroredFFTFilter(windowLength: configuration.windowLength)
        channels = Array(repeating: Array(repeating: 0, count: configuration.windowLength), count: 6)
        timestamps = Array(repeating: 0, count: configuration.windowLength)
        intervals = Array(repeating: configuration.nominalSampleInterval, count: configuration.windowLength)
        scratch = Array(repeating: 0, count: configuration.windowLength)
    }

    mutating func add(_ sample: MotionSample) -> MotionSample {
        let window = configuration.windowLength
        let values = [sample.ax, sample.ay, sample.az, sample.gx, sample.gy, sample.gz]
        let interval = sample.deltaTime.isFinite && sample.deltaTime > 0 && sample.deltaTime <= 0.1
            ? sample.deltaTime : configuration.nominalSampleInterval
        if !isPrimed {
            // Pre-fill acceleration with the first sample so start-up has no artificial
            // step from zero (gravity alone is ~9.8 m/s²). Pre-fill gyro with zero, the
            // rate of a still sensor: holding one tremor- or noise-laden reading across
            // the window would integrate into a large false angle.
            for channel in 0..<3 { channels[channel] = Array(repeating: values[channel], count: window) }
            for channel in 3..<6 { channels[channel] = Array(repeating: 0, count: window) }
            timestamps = Array(repeating: sample.timestamp, count: window)
            intervals = Array(repeating: interval, count: window)
            initialAcceleration = (sample.ax, sample.ay, sample.az)
            isPrimed = true
        }
        receivedSamples += 1
        for channel in 0..<6 { channels[channel][writeIndex] = values[channel] }
        timestamps[writeIndex] = sample.timestamp
        intervals[writeIndex] = interval
        writeIndex = (writeIndex + 1) % window

        let meanInterval = intervals.reduce(0, +) / Double(window)
        updateGainsIfNeeded(sampleRate: 1 / meanInterval)

        let readIndex = window - 1 - configuration.outputLagSamples
        let ringIndex = (writeIndex + readIndex) % window
        if receivedSamples <= configuration.outputLagSamples + configuration.warmUpSamples {
            // Warm-up: report a still sensor until enough real history has arrived.
            return MotionSample(timestamp: timestamps[ringIndex], deltaTime: intervals[ringIndex],
                                ax: initialAcceleration.x, ay: initialAcceleration.y, az: initialAcceleration.z,
                                gx: 0, gy: 0, gz: 0)
        }
        var filtered = [Double](repeating: 0, count: 6)
        for channel in 0..<6 {
            for index in 0..<window { scratch[index] = channels[channel][(writeIndex + index) % window] }
            filter.apply(gains, to: &scratch)
            filtered[channel] = scratch[readIndex]
        }
        return MotionSample(timestamp: timestamps[ringIndex], deltaTime: intervals[ringIndex],
                            ax: filtered[0], ay: filtered[1], az: filtered[2],
                            gx: filtered[3], gy: filtered[4], gz: filtered[5])
    }

    /// False while start-up "still" placeholders are being emitted.
    var isWarmedUp: Bool {
        receivedSamples > configuration.outputLagSamples + configuration.warmUpSamples
    }

    mutating func reset() {
        self = MotionSampleLowPassFilter(configuration: configuration)
    }

    private mutating func updateGainsIfNeeded(sampleRate: Double) {
        guard gains.isEmpty || abs(sampleRate - gainSampleRate) > gainSampleRate * 0.01 else { return }
        gainSampleRate = sampleRate
        gains = filter.binFrequencies(sampleRate: sampleRate).map {
            1 - MirroredFFTFilter.raisedCosineStep($0, from: configuration.passFrequency, to: configuration.stopFrequency)
        }
    }
}

/// Tuning for stillness detection. Limits are learned from the sensor's own
/// filtered signal at start-up rather than fixed; the ranges only bound that learning.
struct StillnessConfiguration {
    /// Filtered samples, after the low-pass warm-up, used to learn gyro bias, gravity,
    /// and the at-rest signal level. With the warm-up, hold the sensor still for about
    /// the first 1.5 s.
    var learningSamples = 75
    /// Stillness requires every filtered sample in this window to be within limits
    /// (0.3 s at 100 Hz). A single quiet instant mid-rep is not enough.
    var windowSamples = 30
    /// Limit = this multiple of the largest at-rest deviation seen while learning.
    /// Tremor left over after filtering is part of that level, so it does not block
    /// stillness detection.
    var restLevelMultiplier = 3.0
    var gyroLimitRange = 0.3...10.0          // °/s
    var accelerationLimitRange = 0.02...0.5  // m/s² deviation of |a| from gravity
    /// Fraction per still sample by which gyro bias and gravity follow measurements.
    var stillAdaptationRate = 0.01
    /// Largest per-axis gyro bias (°/s) accepted from start-up learning.
    var maximumInitialGyroBias = 5.0
}

/// Decides whether the sensor is still from the FFT low-passed stream, and learns
/// gyro bias. Bias is first estimated at start-up, then refined whenever the sensor
/// is still, so integrated angles stop creeping at rest.
struct StillnessDetector {
    let configuration: StillnessConfiguration
    private(set) var gyroBias = SIMD3<Double>(repeating: 0)
    private(set) var gyroLimit = 1.0
    private(set) var accelerationLimit = 0.1
    private(set) var isLearned = false
    private var gravityMagnitude = 9.80665
    private var learningGyro: [SIMD3<Double>] = []
    private var learningAccelerationMagnitude: [Double] = []
    private var quietRun = 0

    init(configuration: StillnessConfiguration = StillnessConfiguration()) {
        self.configuration = configuration
    }

    /// Takes a low-passed sample; returns it with gyro bias removed and whether the
    /// sensor is still. Until start-up learning finishes, reports a still sensor with
    /// zero rotation.
    mutating func process(_ filtered: MotionSample, filterIsWarmedUp: Bool) -> (sample: MotionSample, isStill: Bool) {
        let measuredGyro = SIMD3(filtered.gx, filtered.gy, filtered.gz)
        guard isLearned else {
            if filterIsWarmedUp { learn(gyro: measuredGyro, accelerationMagnitude: filtered.accelerationMagnitude) }
            return (MotionSample(timestamp: filtered.timestamp, deltaTime: filtered.deltaTime,
                                 ax: filtered.ax, ay: filtered.ay, az: filtered.az, gx: 0, gy: 0, gz: 0), true)
        }
        let corrected = measuredGyro - gyroBias
        let accelerationDeviation = abs(filtered.accelerationMagnitude - gravityMagnitude)
        let quiet = simd_length(corrected) <= gyroLimit && accelerationDeviation <= accelerationLimit
        quietRun = quiet ? quietRun + 1 : 0
        let isStill = quietRun >= configuration.windowSamples

        if isStill {
            let rate = configuration.stillAdaptationRate
            gyroBias += (measuredGyro - gyroBias) * rate
            gravityMagnitude += (filtered.accelerationMagnitude - gravityMagnitude) * rate
        }
        return (MotionSample(timestamp: filtered.timestamp, deltaTime: filtered.deltaTime,
                             ax: filtered.ax, ay: filtered.ay, az: filtered.az,
                             gx: corrected.x, gy: corrected.y, gz: corrected.z), isStill)
    }

    mutating func reset() {
        self = StillnessDetector(configuration: configuration)
    }

    private mutating func learn(gyro: SIMD3<Double>, accelerationMagnitude: Double) {
        learningGyro.append(gyro)
        learningAccelerationMagnitude.append(accelerationMagnitude)
        guard learningGyro.count >= configuration.learningSamples else { return }

        let count = Double(learningGyro.count)
        // Clamp to a plausible MEMS gyro bias so movement during start-up is not
        // mistaken for a large bias (still-time refinement corrects it later).
        let meanGyro = learningGyro.reduce(SIMD3<Double>(repeating: 0), +) / count
        let biasLimit = configuration.maximumInitialGyroBias
        gyroBias = simd_clamp(meanGyro, SIMD3(repeating: -biasLimit), SIMD3(repeating: biasLimit))
        gravityMagnitude = learningAccelerationMagnitude.reduce(0, +) / count

        // Largest at-rest deviation: filtered noise plus any leftover tremor.
        let gyroRestLevel = learningGyro.map { simd_length($0 - gyroBias) }.max() ?? 0
        let accelerationRestLevel = learningAccelerationMagnitude.map { abs($0 - gravityMagnitude) }.max() ?? 0
        gyroLimit = Self.clamp(configuration.restLevelMultiplier * gyroRestLevel, to: configuration.gyroLimitRange)
        accelerationLimit = Self.clamp(configuration.restLevelMultiplier * accelerationRestLevel,
                                       to: configuration.accelerationLimitRange)
        isLearned = true
        learningGyro = []
        learningAccelerationMagnitude = []
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
