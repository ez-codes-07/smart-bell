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

/// Tuning for the position estimator. Provisional: tune against hardware recordings.
struct PositionConfiguration {
    /// Fraction of the tilt error toward measured gravity corrected per still sample.
    var stillTiltCorrectionRate = 0.1
    /// Fraction per still sample by which the gravity-magnitude reference follows
    /// the measured magnitude (absorbs accelerometer scale/bias error).
    var stillGravityFollowRate = 0.02
    /// A movement longer than this without any stillness is abandoned: velocity is
    /// reset so an undetected stop cannot drift forever.
    var maximumMovementDuration = 15.0
}

/// Relative position from motion samples that have already been FFT low-passed
/// and gyro-bias corrected, with a stillness flag from `StillnessDetector`.
///
/// While moving: rotate acceleration into a gravity-aligned world frame, subtract
/// gravity, and integrate twice. When stillness begins: velocity must truly be zero,
/// so whatever velocity remains is integration error. Assuming that error grew
/// linearly over the movement, it displaced position by v·T/2, which is removed
/// before velocity is zeroed. While still: position holds, and orientation tilt and
/// the gravity reference are corrected from the measured gravity direction.
struct PositionCalculator {
    let configuration: PositionConfiguration
    private var worldFromInitialSensor: simd_double3x3?
    private var orientationFromCurrentSensor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var previousGyroRate: SIMD3<Double>?
    private var gravityMagnitude = 9.80665
    private var previousLinearAcceleration: SIMD3<Double>?
    private var velocity = SIMD3<Double>(repeating: 0)
    private var movementDuration = 0.0
    private var worldPosition = SIMD3<Double>(repeating: 0)
    /// Recent (sample interval, velocity, movement duration), newest last, so a
    /// zero-velocity point identified slightly after the fact can be applied.
    private var recentStates: [(dt: Double, velocity: SIMD3<Double>, movementDuration: Double,
                                position: SIMD3<Double>)] = []
    private let recentStateCapacity = 300
    private(set) var position = PositionEstimate()

    /// Position along the gravity-aligned world Z axis established at startup.
    var verticalPosition: Double {
        position.z
    }

    init(configuration: PositionConfiguration = PositionConfiguration()) {
        self.configuration = configuration
    }

    mutating func add(_ sample: MotionSample, isStill: Bool) -> PositionEstimate {
        let sensorAcceleration = SIMD3<Double>(sample.ax, sample.ay, sample.az)
        let dt = sample.deltaTime
        let dtIsValid = dt.isFinite && dt > 0 && dt <= 0.1

        // Define world Z as the initial gravity/up direction, independent of how
        // the sensor is mounted. The sensor is assumed still at startup.
        if worldFromInitialSensor == nil {
            let magnitude = simd_length(sensorAcceleration)
            worldFromInitialSensor = magnitude > 0.1
                ? Self.rotationAligning(sensorAcceleration / magnitude, to: SIMD3<Double>(0, 0, 1))
                : matrix_identity_double3x3
            if magnitude > 0.1 { gravityMagnitude = magnitude }
        }

        // Integrate body rates as a quaternion so simultaneous axis rotations do
        // not rely on treating gyro-integrated Euler angles as independent.
        let gyroRate = SIMD3<Double>(sample.gx, sample.gy, sample.gz) * (Double.pi / 180)
        if let previousGyroRate, dtIsValid {
            let averageRate = (previousGyroRate + gyroRate) * 0.5
            let angularSpeed = simd_length(averageRate)
            if angularSpeed > 1e-9 {
                let deltaRotation = simd_quatd(angle: angularSpeed * dt, axis: averageRate / angularSpeed)
                orientationFromCurrentSensor = simd_normalize(orientationFromCurrentSensor * deltaRotation)
            }
        }
        previousGyroRate = gyroRate

        let alignment = worldFromInitialSensor!
        var rotationSensorToWorld = alignment * simd_double3x3(orientationFromCurrentSensor)

        if isStill {
            // Gently pull accumulated gyro tilt toward the measured gravity direction.
            // Yaw is unobservable without a magnetometer but does not affect world Z.
            let measured = rotationSensorToWorld * sensorAcceleration
            let measuredLength = simd_length(measured)
            if measuredLength > 0.1 {
                let fullCorrection = Self.rotationAligning(measured / measuredLength, to: SIMD3<Double>(0, 0, 1))
                let partial = simd_slerp(simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), simd_quatd(fullCorrection),
                                         configuration.stillTiltCorrectionRate)
                let correctionInInitialSensor = alignment.transpose * simd_double3x3(partial) * alignment
                orientationFromCurrentSensor = simd_normalize(
                    simd_quatd(correctionInInitialSensor * simd_double3x3(orientationFromCurrentSensor)))
                rotationSensorToWorld = alignment * simd_double3x3(orientationFromCurrentSensor)
                gravityMagnitude += (measuredLength - gravityMagnitude) * configuration.stillGravityFollowRate
            }

            if movementDuration > 0 {
                // Remove the displacement caused by the residual velocity error.
                worldPosition -= velocity * (movementDuration / 2)
                movementDuration = 0
            }
            velocity = SIMD3<Double>(repeating: 0)
            previousLinearAcceleration = SIMD3<Double>(repeating: 0)
            recordState(dt: dtIsValid ? dt : 0.01)
            publishPosition()
            return position
        }

        let linearAcceleration = rotationSensorToWorld * sensorAcceleration - SIMD3<Double>(0, 0, gravityMagnitude)
        if let previousLinearAcceleration, dtIsValid {
            // Trapezoidal integration, first to velocity and then to position.
            let previousVelocity = velocity
            velocity += (previousLinearAcceleration + linearAcceleration) * (0.5 * dt)
            worldPosition += (previousVelocity + velocity) * (0.5 * dt)
            movementDuration += dt
            if movementDuration > configuration.maximumMovementDuration {
                velocity = SIMD3<Double>(repeating: 0)
                movementDuration = 0
            }
        }
        previousLinearAcceleration = linearAcceleration
        recordState(dt: dtIsValid ? dt : 0.01)
        publishPosition()
        return position
    }

    mutating func reset() {
        self = PositionCalculator(configuration: configuration)
    }

    /// Makes the current position the origin (a user-requested re-zero), keeping
    /// orientation, gravity, and any movement in progress.
    mutating func zeroPosition() {
        for index in recentStates.indices { recentStates[index].position -= worldPosition }
        worldPosition = SIMD3<Double>(repeating: 0)
        publishPosition()
    }

    /// Removes drift using a moment `secondsAgo` in the past when the dumbbell was
    /// at rest (the bottom of a rep), even if it never stayed still long enough to be
    /// detected. Any velocity estimated there was integration error: its linear-growth
    /// displacement up to that moment (v·T/2) and its constant effect since
    /// (v·secondsAgo) are removed, and the drift clock restarts from that moment.
    /// The position origin is unchanged (still the start); returns the corrected
    /// position at the rest point, for callers that track per-rep travel.
    @discardableResult
    mutating func correctDrift(atRestPointSecondsAgo secondsAgo: Double) -> PositionEstimate {
        // Already still: the still-time correction has been applied and position is
        // held, so the current position is the rest point.
        guard movementDuration > 0, !recentStates.isEmpty else {
            recentStates.removeAll()
            return position
        }
        var index = recentStates.count - 1
        var elapsed = 0.0
        while index > 0 && elapsed + recentStates[index].dt <= secondsAgo {
            elapsed += recentStates[index].dt
            index -= 1
        }
        let state = recentStates[index]
        var restPosition = state.position
        if state.movementDuration > 0 {
            restPosition -= state.velocity * (state.movementDuration / 2)
            worldPosition -= state.velocity * (state.movementDuration / 2 + elapsed)
            velocity -= state.velocity
            movementDuration = elapsed
        }
        recentStates.removeAll()
        publishPosition()
        return PositionEstimate(x: restPosition.x, y: restPosition.y, z: restPosition.z)
    }

    private mutating func recordState(dt: Double) {
        recentStates.append((dt, velocity, movementDuration, worldPosition))
        if recentStates.count > recentStateCapacity { recentStates.removeFirst(recentStates.count - recentStateCapacity) }
    }

    private mutating func publishPosition() {
        position = PositionEstimate(x: worldPosition.x, y: worldPosition.y, z: worldPosition.z)
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
