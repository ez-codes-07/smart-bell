import Foundation

struct MotionAnalyzer {
    private(set) var repCount = 0
    private(set) var cue: FormCue = .ready
    private(set) var lastRep: RepRecord?
    private(set) var latestAngularSpeed = 0.0
    private(set) var calibrationProgress = 0
    private(set) var isCalibrated = false
    private(set) var calibrationRanges: [Double] = []
    private(set) var calibrationDurations: [Double] = []
    private(set) var calibrationAcceleration: [Double] = []

    var requiredCalibrationReps = 3
    var minPeakSpeed = 28.0
    var minRepInterval = 0.75

    private var previousAxisSpeed = 0.0
    private var previousDelta = 0.0
    private var previousPeakTime: TimeInterval?
    private var previousTimestamp: TimeInterval?
    private var accumulatedRange = 0.0
    private var estimatedAngle = 0.0
    private var angleMinimum = 0.0
    private var angleMaximum = 0.0
    private var accumulatedAccelerationMotion = 0.0
    private var activeAxis: Int?

    mutating func reset() {
        repCount = 0; cue = .ready; lastRep = nil
        calibrationProgress = 0; isCalibrated = false
        calibrationRanges.removeAll(); calibrationDurations.removeAll()
        calibrationAcceleration.removeAll()
        previousAxisSpeed = 0; previousDelta = 0; previousPeakTime = nil
        previousTimestamp = nil; accumulatedRange = 0; activeAxis = nil
        estimatedAngle = 0; angleMinimum = 0; angleMaximum = 0
        accumulatedAccelerationMotion = 0
    }

    mutating func beginCalibration() {
        reset(); cue = .calibrating
    }

    mutating func process(_ sample: MotionSample, calibrating: Bool) {
        let values = [sample.gx, sample.gy, sample.gz]
        let strongestAxis = values.indices.max(by: { abs(values[$0]) < abs(values[$1]) }) ?? 1
        if activeAxis == nil && abs(values[strongestAxis]) >= minPeakSpeed * 0.25 { activeAxis = strongestAxis }
        let axis = activeAxis ?? strongestAxis
        let signedSpeed = values[axis]
        latestAngularSpeed = sample.gyroMagnitude
        if let previousTimestamp {
            let dt = min(max(sample.timestamp - previousTimestamp, 0), 0.1)
            accumulatedRange += sample.gyroMagnitude * dt
            accumulatedAccelerationMotion += abs(sample.accelerationMagnitude - 9.80665) * dt
            estimatedAngle += signedSpeed * dt
            angleMinimum = min(angleMinimum, estimatedAngle)
            angleMaximum = max(angleMaximum, estimatedAngle)
        }

        // Count one rep per same-direction angular-velocity peak. Calibration and tracking
        // share this detector; its thresholds are deliberately exposed above for tuning.
        let delta = signedSpeed - previousAxisSpeed
        let isPeak = previousDelta > 0 && delta <= 0 && previousAxisSpeed >= minPeakSpeed
        if isPeak {
            let peakTime = sample.timestamp
            if let previousPeakTime {
                let duration = peakTime - previousPeakTime
                if duration >= minRepInterval && duration <= 12 {
                    // Gyroscope integration provides a short-window angular excursion estimate,
                    // not a drift-free world-space position. Keep it bounded to this rep.
                    let range = angleMaximum - angleMinimum
                    let accelerationMotion = accumulatedAccelerationMotion
                    if calibrating && !isCalibrated {
                        calibrationRanges.append(range)
                        calibrationDurations.append(duration)
                        calibrationAcceleration.append(accelerationMotion)
                        calibrationProgress = calibrationRanges.count
                        if calibrationRanges.count >= requiredCalibrationReps {
                            isCalibrated = true
                            cue = .ready
                        } else { cue = .calibrating }
                    } else if isCalibrated {
                        repCount += 1
                        let baseRange = calibrationRanges.reduce(0, +) / Double(max(calibrationRanges.count, 1))
                        let baseDuration = calibrationDurations.reduce(0, +) / Double(max(calibrationDurations.count, 1))
                        let baseAcceleration = calibrationAcceleration.reduce(0, +) / Double(max(calibrationAcceleration.count, 1))
                        let result: FormCue
                        if range < baseRange * 0.72 { result = .shortRange }
                        else if range > baseRange * 1.5 || (baseAcceleration > 0.02 && (accelerationMotion < baseAcceleration * 0.35 || accelerationMotion > baseAcceleration * 2.0)) { result = .changed }
                        else if abs(duration - baseDuration) > baseDuration * 0.45 { result = .slow }
                        else { result = .good }
                        cue = result
                        lastRep = RepRecord(duration: duration, intensity: latestAngularSpeed, range: range, accelerationMotion: accelerationMotion, cue: result.rawValue)
                    }
                }
            }
            self.previousPeakTime = peakTime
            accumulatedRange = 0
            accumulatedAccelerationMotion = 0
            angleMinimum = estimatedAngle
            angleMaximum = estimatedAngle
        }
        previousDelta = delta
        previousAxisSpeed = signedSpeed
        previousTimestamp = sample.timestamp
    }
}
