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
    private var gyroIntegrator = GyroscopeIntegrator()
    private var gravityInWorld: SIMD3<Double>?
    private var previousLinearAcceleration: SIMD3<Double>?
    private var velocity = SIMD3<Double>(repeating: 0)
    private(set) var position = PositionEstimate()

    mutating func add(_ sample: MotionSample) -> PositionEstimate {
        let angles = gyroIntegrator.add(sample)
        let radiansPerDegree = Double.pi / 180
        let roll = angles.x * radiansPerDegree
        let pitch = angles.y * radiansPerDegree
        let yaw = angles.z * radiansPerDegree

        // Sensor-frame vector -> starting/world frame, using the chosen Z-Y-X convention.
        let rotationX = simd_double3x3(rows: [
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, cos(roll), -sin(roll)),
            SIMD3<Double>(0, sin(roll), cos(roll))
        ])
        let rotationY = simd_double3x3(rows: [
            SIMD3<Double>(cos(pitch), 0, sin(pitch)),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(-sin(pitch), 0, cos(pitch))
        ])
        let rotationZ = simd_double3x3(rows: [
            SIMD3<Double>(cos(yaw), -sin(yaw), 0),
            SIMD3<Double>(sin(yaw), cos(yaw), 0),
            SIMD3<Double>(0, 0, 1)
        ])
        let sensorAcceleration = SIMD3<Double>(sample.ax, sample.ay, sample.az)
        let rotationSensorToWorld = rotationZ * rotationY * rotationX
        let worldAcceleration = rotationSensorToWorld * sensorAcceleration

        // Establish gravity from the first sample; this assumes the sensor starts still.
        if gravityInWorld == nil {
            gravityInWorld = worldAcceleration
            previousLinearAcceleration = SIMD3<Double>(repeating: 0)
            return position
        }

        let appearsStationary = sample.gyroMagnitude < stationaryGyroThreshold &&
            abs(sample.accelerationMagnitude - standardGravity) < stationaryAccelerationTolerance
        if appearsStationary {
            // Adapt the gravity estimate while still and apply a zero-velocity update.
            let gravityFollowRate = 0.02
            gravityInWorld = gravityInWorld! * (1 - gravityFollowRate) + worldAcceleration * gravityFollowRate
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
        gyroIntegrator.reset()
        gravityInWorld = nil
        previousLinearAcceleration = nil
        velocity = SIMD3<Double>(repeating: 0)
        position = PositionEstimate()
    }
}
