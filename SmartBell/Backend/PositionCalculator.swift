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

struct PositionCalculator {
    private let standardGravity = 9.80665
    private let stationaryGyroThreshold = 3.0 // degrees/second
    private let stationaryAccelerationTolerance = 0.4 // m/s² from 1 g
    private var worldFromInitialSensor: simd_double3x3?
    private var orientationFromCurrentSensor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var previousGyroRate: SIMD3<Double>?
    private var gravityInWorld: SIMD3<Double>?
    private var previousLinearAcceleration: SIMD3<Double>?
    private var velocity = SIMD3<Double>(repeating: 0)
    private(set) var position = PositionEstimate()

    /// Position along the gravity-aligned world Z axis established at startup.
    var verticalPosition: Double {
        position.z
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

        let rotationSensorToInitialSensor = simd_double3x3(orientationFromCurrentSensor)
        let rotationSensorToWorld = worldFromInitialSensor! * rotationSensorToInitialSensor
        let worldAcceleration = rotationSensorToWorld * sensorAcceleration

        // Establish the initial gravity estimate after aligning world Z.
        if gravityInWorld == nil {
            gravityInWorld = worldAcceleration
            previousLinearAcceleration = SIMD3<Double>(repeating: 0)
            return position
        }

        let appearsStationary = sample.gyroMagnitude < stationaryGyroThreshold &&
            abs(sample.accelerationMagnitude - standardGravity) < stationaryAccelerationTolerance
        if appearsStationary {
            // Correct accumulated gyro tilt from measured gravity while still.
            // This constrains roll/pitch drift before the next movement; yaw remains
            // unobservable without a magnetometer, but does not change world Z.
            let measuredGravityDirection = simd_normalize(worldAcceleration)
            let correctionInWorld = Self.rotationAligning(
                measuredGravityDirection,
                to: SIMD3<Double>(0, 0, 1)
            )
            let alignment = worldFromInitialSensor!
            let correctionInInitialSensor = alignment.transpose * correctionInWorld * alignment
            let correctedOrientation = correctionInInitialSensor * simd_double3x3(orientationFromCurrentSensor)
            orientationFromCurrentSensor = simd_normalize(simd_quatd(correctedOrientation))
            let correctedWorldAcceleration = alignment * correctedOrientation * sensorAcceleration

            // Adapt gravity and apply a zero-velocity update while still.
            let gravityFollowRate = 0.02
            gravityInWorld = gravityInWorld! * (1 - gravityFollowRate) + correctedWorldAcceleration * gravityFollowRate
            previousLinearAcceleration = SIMD3<Double>(repeating: 0)
            velocity = SIMD3<Double>(repeating: 0)
            return position
        }

        // Transform world gravity back into sensor coordinates with Rᵀ, subtract it
        // there, then rotate the gravity-free acceleration into the world frame.
        let gravityInSensor = rotationSensorToWorld.transpose * gravityInWorld!
        let linearAcceleration = rotationSensorToWorld * (sensorAcceleration - gravityInSensor)
        if let previousLinearAcceleration {
            let dt = sample.deltaTime
            guard dt.isFinite, dt > 0, dt <= 0.1 else {
                self.previousLinearAcceleration = linearAcceleration
                return position
            }

            // Trapezoidal integration, first to velocity and then to position.
            let previousVelocity = velocity
            velocity += (previousLinearAcceleration + linearAcceleration) * (0.5 * dt)
            let displacement = (previousVelocity + velocity) * (0.5 * dt)
            position.x += displacement.x
            position.y += displacement.y
            position.z += displacement.z
        }
        previousLinearAcceleration = linearAcceleration
        return position
    }

    mutating func reset() {
        worldFromInitialSensor = nil
        orientationFromCurrentSensor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        previousGyroRate = nil
        gravityInWorld = nil
        previousLinearAcceleration = nil
        velocity = SIMD3<Double>(repeating: 0)
        position = PositionEstimate()
    }

    /// Starts a fresh relative-position segment while preserving attitude and gravity references.
    mutating func rebasePosition() {
        position = PositionEstimate()
        velocity = SIMD3<Double>(repeating: 0)
        previousLinearAcceleration = SIMD3<Double>(repeating: 0)
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
