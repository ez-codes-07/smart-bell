import Accelerate
import Foundation
import simd

/// Per-axis gyro integration, in degrees. These are accumulated sensor-axis angles,
/// not a drift-corrected 3D orientation.
struct IntegratedGyroAngles: Equatable {
    var x = 0.0
    var y = 0.0
    var z = 0.0
}

struct GyroscopeIntegrator {
    private(set) var angles = IntegratedGyroAngles()
    private var previousRate: (x: Double, y: Double, z: Double)?

    mutating func add(_ sample: MotionSample) -> IntegratedGyroAngles {
        let rate = (x: sample.gx, y: sample.gy, z: sample.gz) // degrees/second

        if let previousRate,
           sample.deltaTime.isFinite, sample.deltaTime > 0, sample.deltaTime <= 0.1 {
            // Trapezoidal integration: average adjacent angular rates over this sample interval.
            angles.x += (previousRate.x + rate.x) * 0.5 * sample.deltaTime
            angles.y += (previousRate.y + rate.y) * 0.5 * sample.deltaTime
            angles.z += (previousRate.z + rate.z) * 0.5 * sample.deltaTime
        }
        previousRate = rate
        return angles
    }

    mutating func reset() {
        angles = IntegratedGyroAngles()
        previousRate = nil
    }
}

/// Relative inertial position, initialized at (0, 0, 0) on the first sample.
struct PositionEstimate: Equatable {
    var x = 0.0
    var y = 0.0
    var z = 0.0
}

/// Tuning for the frequency-domain position estimator. All values are provisional:
/// defaults were chosen against synthetic curl motion with injected noise and bias,
/// and must be re-tuned against labeled hardware recordings.
struct FrequencyDomainPositionConfiguration {
    /// Sliding-window length in samples. Must be a power of two. 1024 samples is
    /// about 10 s at 100 Hz, enough to hold several repetitions.
    var windowLength = 1024
    /// Band-pass edges in Hz. Content below `highPassStop` (gravity residue, bias,
    /// and slow tilt drift) is removed; content above `lowPassStop` (sensor noise,
    /// vibration, and hand tremor at roughly 4–12 Hz) is removed. Raised-cosine ramps between start/stop limit ringing.
    var highPassStop = 0.10
    var highPassPass = 0.25
    var lowPassPass = 1.5
    var lowPassStop = 2.5
    /// The newest samples of a finite window are the least reliable after filtering,
    /// so position is read this many samples before the newest one (0.5 s at 100 Hz).
    /// Smaller values reduce latency but overstate fast movements.
    var outputLagSamples = 50
    /// Apply the FFT high-pass to velocity as well as to acceleration. Off by
    /// default: it understated rep travel in synthetic tests.
    var highPassVelocity = false
    /// Order of the least-squares polynomial removed from each window's position
    /// (0 = mean only, 1 = also unknown start velocity, 2 = also residual
    /// acceleration bias). This replaces a mirrored FFT high-pass at the position
    /// stage, which smears the slope discontinuity created by mirroring.
    var positionDetrendOrder = 1
    /// Pre-fills the window and replaces missing or implausible `deltaTime` values.
    var nominalSampleInterval = 0.01
}

/// Estimates relative position by rotating acceleration into a gravity-aligned
/// world frame, then band-pass filtering a sliding window with FFT/IFFT and double
/// integrating it (see `FrequencyDomainDoubleIntegrator`).
///
/// There is no stationary threshold or zero-velocity update: drift-causing
/// low-frequency content (sensor bias, residual gravity from gyro tilt drift) is
/// removed by the high-pass edge instead, high-frequency noise by the low-pass
/// edge, and integration constants by a per-window detrend. The trade-off is that
/// the output is a band-limited, zero-mean displacement over the window, delayed by
/// `outputLagSamples`; slow or held offsets decay away.
struct PositionCalculator {
    private let configuration: FrequencyDomainPositionConfiguration
    private var worldFromInitialSensor: simd_double3x3?
    private var orientationFromCurrentSensor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var previousGyroRate: SIMD3<Double>?
    private var gravityInWorld: SIMD3<Double>?
    private var history: AccelerationHistory
    private let integrator: FrequencyDomainDoubleIntegrator
    private var filteredPosition = SIMD3<Double>(repeating: 0)
    private var rebaseOffset = SIMD3<Double>(repeating: 0)
    private(set) var position = PositionEstimate()

    /// Position along the gravity-aligned world Z axis established at startup.
    var verticalPosition: Double {
        position.z
    }

    init(configuration: FrequencyDomainPositionConfiguration = FrequencyDomainPositionConfiguration()) {
        precondition(configuration.windowLength >= 64 && configuration.windowLength.nonzeroBitCount == 1,
                     "windowLength must be a power of two of at least 64")
        self.configuration = configuration
        history = AccelerationHistory(capacity: configuration.windowLength,
                                      nominalSampleInterval: configuration.nominalSampleInterval)
        integrator = FrequencyDomainDoubleIntegrator(configuration: configuration)
    }

    mutating func add(_ sample: MotionSample) -> PositionEstimate {
        let sensorAcceleration = SIMD3<Double>(sample.ax, sample.ay, sample.az)

        // Define world Z as the initial gravity/up direction, independent of how
        // the sensor is mounted. The sensor should be motionless at startup.
        if worldFromInitialSensor == nil {
            let magnitude = simd_length(sensorAcceleration)
            worldFromInitialSensor = magnitude > 0.1
                ? Self.rotationAligning(sensorAcceleration / magnitude, to: SIMD3<Double>(0, 0, 1))
                : matrix_identity_double3x3
        }

        // Integrate body rates as a quaternion so simultaneous axis rotations do
        // not rely on treating gyro-integrated Euler angles as independent.
        let rateScale = Double.pi / 180
        let gyroRate = SIMD3<Double>(sample.gx, sample.gy, sample.gz) * rateScale
        if let previousGyroRate,
           sample.deltaTime.isFinite, sample.deltaTime > 0, sample.deltaTime <= 0.1 {
            let averageRate = (previousGyroRate + gyroRate) * 0.5
            let angularSpeed = simd_length(averageRate)
            if angularSpeed > 1e-9 {
                let deltaRotation = simd_quatd(angle: angularSpeed * sample.deltaTime,
                                               axis: averageRate / angularSpeed)
                orientationFromCurrentSensor = simd_normalize(orientationFromCurrentSensor * deltaRotation)
            }
        }
        self.previousGyroRate = gyroRate

        let rotationSensorToWorld = worldFromInitialSensor! * simd_double3x3(orientationFromCurrentSensor)
        let worldAcceleration = rotationSensorToWorld * sensorAcceleration

        // A fixed startup gravity reference is enough: any residual (gyro tilt
        // drift, accelerometer bias) is slow and is removed by the high-pass edge.
        if gravityInWorld == nil {
            gravityInWorld = worldAcceleration
        }
        history.append(worldAcceleration - gravityInWorld!, deltaTime: sample.deltaTime)

        let readIndex = configuration.windowLength - 1 - configuration.outputLagSamples
        let sampleRate = 1 / history.meanSampleInterval
        filteredPosition = SIMD3<Double>(
            integrator.displacement(of: history.chronological(axis: 0), sampleRate: sampleRate, readIndex: readIndex),
            integrator.displacement(of: history.chronological(axis: 1), sampleRate: sampleRate, readIndex: readIndex),
            integrator.displacement(of: history.chronological(axis: 2), sampleRate: sampleRate, readIndex: readIndex)
        )
        let relative = filteredPosition - rebaseOffset
        position = PositionEstimate(x: relative.x, y: relative.y, z: relative.z)
        return position
    }

    mutating func reset() {
        worldFromInitialSensor = nil
        orientationFromCurrentSensor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        previousGyroRate = nil
        gravityInWorld = nil
        history.reset()
        filteredPosition = SIMD3<Double>(repeating: 0)
        rebaseOffset = SIMD3<Double>(repeating: 0)
        position = PositionEstimate()
    }

    /// Starts a fresh relative-position segment while preserving attitude, gravity,
    /// and the filter window. The current filtered position becomes the new origin.
    mutating func rebasePosition() {
        rebaseOffset = filteredPosition
        position = PositionEstimate()
    }

    private static func rotationAligning(_ source: SIMD3<Double>, to target: SIMD3<Double>) -> simd_double3x3 {
        let axis = simd_cross(source, target)
        let cosine = simd_dot(source, target)
        let sineSquared = simd_dot(axis, axis)

        if sineSquared < 1e-12 {
            if cosine >= 0 { return matrix_identity_double3x3 }
            return simd_double3x3(rows: [
                SIMD3<Double>(1, 0, 0),
                SIMD3<Double>(0, -1, 0),
                SIMD3<Double>(0, 0, -1)
            ])
        }

        let skew = simd_double3x3(rows: [
            SIMD3<Double>(0, -axis.z, axis.y),
            SIMD3<Double>(axis.z, 0, -axis.x),
            SIMD3<Double>(-axis.y, axis.x, 0)
        ])
        return matrix_identity_double3x3 + skew + (skew * skew) * ((1 - cosine) / sineSquared)
    }
}

/// Fixed-length ring buffer of gravity-free world acceleration. It starts filled
/// with zeros, matching the assumption that the sensor is still at startup.
private struct AccelerationHistory {
    private let capacity: Int
    private let nominalSampleInterval: Double
    private var axes: [[Double]]
    private var intervals: [Double]
    private var intervalSum: Double
    private var writeIndex = 0

    init(capacity: Int, nominalSampleInterval: Double) {
        self.capacity = capacity
        self.nominalSampleInterval = nominalSampleInterval
        axes = Array(repeating: Array(repeating: 0, count: capacity), count: 3)
        intervals = Array(repeating: nominalSampleInterval, count: capacity)
        intervalSum = nominalSampleInterval * Double(capacity)
    }

    /// The FFT assumes uniform sampling, so the window's mean interval is used.
    var meanSampleInterval: Double {
        intervalSum / Double(capacity)
    }

    mutating func append(_ acceleration: SIMD3<Double>, deltaTime: Double) {
        axes[0][writeIndex] = acceleration.x
        axes[1][writeIndex] = acceleration.y
        axes[2][writeIndex] = acceleration.z
        let interval = deltaTime.isFinite && deltaTime > 0 && deltaTime <= 0.1 ? deltaTime : nominalSampleInterval
        intervalSum += interval - intervals[writeIndex]
        intervals[writeIndex] = interval
        writeIndex = (writeIndex + 1) % capacity
    }

    /// Oldest-to-newest samples for one axis.
    func chronological(axis: Int) -> ArraySlice<Double> {
        axes[axis][writeIndex...] + axes[axis][..<writeIndex]
    }

    mutating func reset() {
        self = AccelerationHistory(capacity: capacity, nominalSampleInterval: nominalSampleInterval)
    }
}

/// Band-pass filtering and double integration of a uniformly sampled window using
/// real FFT/IFFT filtering. Each filter pass mirrors the window (even extension)
/// so the periodic signal the FFT assumes has no jump at the window edges.
///
/// Pipeline: acceleration → FFT band-pass → IFFT → integrate → velocity →
/// (FFT high-pass → IFFT) → integrate → position → remove least-squares polynomial.
/// The band-pass removes bias, gravity residue, and noise; the velocity high-pass
/// and position detrend remove the unknown integration constants and drift ramps.
final class FrequencyDomainDoubleIntegrator {
    private let configuration: FrequencyDomainPositionConfiguration
    private let windowLength: Int
    private let filter: MirroredFFTFilter
    private var signal: [Double]
    private var bandPassGains: [Double] = []
    private var highPassGains: [Double] = []
    private var gainSampleRate = 0.0

    init(configuration: FrequencyDomainPositionConfiguration) {
        self.configuration = configuration
        windowLength = configuration.windowLength
        filter = MirroredFFTFilter(windowLength: windowLength)
        signal = Array(repeating: 0, count: windowLength)
    }

    /// Returns the displacement (in the acceleration's length unit) at `readIndex`
    /// of the window, where index 0 is the oldest sample.
    func displacement<C: Collection>(of acceleration: C, sampleRate: Double, readIndex: Int) -> Double
    where C.Element == Double {
        precondition(acceleration.count == windowLength)
        updateGainsIfNeeded(sampleRate: sampleRate)
        let dt = 1 / sampleRate

        for (index, value) in acceleration.enumerated() { signal[index] = value }
        filter.apply(bandPassGains, to: &signal)
        integrateSignal(dt: dt)            // velocity
        if configuration.highPassVelocity { filter.apply(highPassGains, to: &signal) }
        integrateSignal(dt: dt)            // position
        return signal[readIndex] - polynomialFit(order: configuration.positionDetrendOrder, at: readIndex)
    }

    /// Least-squares polynomial fit of `signal` (order 0–2), evaluated at `index`.
    /// Uses a centered, normalized abscissa for numerical stability.
    private func polynomialFit(order: Int, at index: Int) -> Double {
        let order = min(max(order, 0), 2)
        let center = Double(windowLength - 1) / 2
        var normal = simd_double3x3(0)
        var moments = SIMD3<Double>(repeating: 0)
        for sampleIndex in 0..<windowLength {
            let u = (Double(sampleIndex) - center) / center
            let basis = SIMD3<Double>(1, order >= 1 ? u : 0, order >= 2 ? u * u : 0)
            normal += simd_double3x3(columns: (basis * basis.x, basis * basis.y, basis * basis.z))
            moments += basis * signal[sampleIndex]
        }
        // Unused orders have zero basis entries; give them a unit diagonal so the
        // normal matrix stays invertible and their coefficients solve to zero.
        for unused in stride(from: order + 1, to: 3, by: 1) { normal[unused, unused] = 1 }
        let coefficients = normal.inverse * moments
        let u = (Double(index) - center) / center
        return coefficients.x + coefficients.y * u + coefficients.z * u * u
    }

    /// Cumulative trapezoidal integral of `signal`, starting from zero.
    private func integrateSignal(dt: Double) {
        var previous = signal[0]
        signal[0] = 0
        for index in 1..<windowLength {
            let current = signal[index]
            signal[index] = signal[index - 1] + (previous + current) * 0.5 * dt
            previous = current
        }
    }

    /// Per-bin gains, from DC (index 0) to Nyquist (index windowLength).
    /// DC is always zero, which removes constant offsets and integration constants.
    private func updateGainsIfNeeded(sampleRate: Double) {
        guard bandPassGains.isEmpty || abs(sampleRate - gainSampleRate) > gainSampleRate * 0.01 else { return }
        gainSampleRate = sampleRate
        let frequencies = filter.binFrequencies(sampleRate: sampleRate)
        highPassGains = frequencies.map {
            MirroredFFTFilter.raisedCosineStep($0, from: configuration.highPassStop, to: configuration.highPassPass)
        }
        bandPassGains = zip(frequencies, highPassGains).map { frequency, highPass in
            highPass * (1 - MirroredFFTFilter.raisedCosineStep(frequency, from: configuration.lowPassPass, to: configuration.lowPassStop))
        }
    }
}
