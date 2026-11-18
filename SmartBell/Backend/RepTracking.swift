import Foundation

struct RepTrackingProgress: Equatable {
    var phase = "Waiting for motion"
    var positionLabel = "Position"
    var positionExcursion = 0.0
    var positionThreshold = 0.0
    var angleExcursion = 0.0
    var angleThreshold = 0.0
}

struct BicepCurlRepTrackingConfiguration {
    var minimumAngleExcursion = 15.0 // degrees, combined across X/Y/Z
    var angleReturnFraction = 0.40
    var angleReturnTolerance = 6.0 // degrees from the starting angle
    var minimumDuration = 0.45
    var maximumDuration = 6.0
}

struct ShoulderPressRepTrackingConfiguration {
    var minimumPositionExcursion = 0.10 // meters, larger press stroke
    var minimumAngleExcursion = 20.0 // degrees, combined X/Y/Z
    var positionReturnFraction = 0.50
    var angleReturnFraction = 0.60
    var minimumDuration = 0.60
    var maximumDuration = 8.0
}

/// Counts a curl from gyro-angle excursion and return. Position is omitted because
/// the inertial height estimate is not reliable enough to gate a curl.
struct BicepCurlRepTracker {
    var configuration = BicepCurlRepTrackingConfiguration()
    private(set) var progress = RepTrackingProgress(
        phase: "Ready for curl",
        angleThreshold: 15
    )

    private var baselineAngles: IntegratedGyroAngles?
    private var isMoving = false
    private var elapsed = 0.0
    private var peakAngle = 0.0

    mutating func reset() {
        baselineAngles = nil
        clearCycle()
        progress = RepTrackingProgress(phase: "Ready for curl",
                                       angleThreshold: configuration.minimumAngleExcursion)
    }

    mutating func rebaseForNextRep(angles: IntegratedGyroAngles) {
        baselineAngles = angles
        clearCycle()
        updateProgress(phase: "Ready for curl", angleExcursion: 0)
    }

    mutating func update(sample: MotionSample, angles: IntegratedGyroAngles) -> Bool {
        guard RepTrackingSignal.isUsable(sample, angles: angles) else { return false }
        guard let baselineAngles else {
            self.baselineAngles = angles
            return false
        }

        let angleExcursion = RepTrackingSignal.angleDistance(angles, from: baselineAngles)
        updateProgress(phase: isMoving ? "Curling" : "Ready for curl",
                       angleExcursion: angleExcursion)

        if !isMoving {
            guard angleExcursion >= configuration.minimumAngleExcursion * 0.25 else { return false }
            isMoving = true
            elapsed = sample.deltaTime
            peakAngle = angleExcursion
            updateProgress(phase: "Curling", angleExcursion: angleExcursion)
            return false
        }

        elapsed += sample.deltaTime
        peakAngle = max(peakAngle, angleExcursion)

        if elapsed > configuration.maximumDuration {
            rebase(angles: angles)
            return false
        }

        let reachedAngleThreshold = peakAngle >= configuration.minimumAngleExcursion
        let angleReturning = angleExcursion < peakAngle * 0.8
        updateProgress(phase: angleReturning ? "Returning to bottom" : "Curling",
                       angleExcursion: angleExcursion)
        let returnedToAngleBaseline = angleExcursion <= max(configuration.angleReturnTolerance,
                                                             peakAngle * configuration.angleReturnFraction)

        if reachedAngleThreshold && elapsed >= configuration.minimumDuration && returnedToAngleBaseline {
            rebase(angles: angles)
            return true
        }
        return false
    }

    private mutating func rebase(angles: IntegratedGyroAngles) {
        baselineAngles = angles
        clearCycle()
        updateProgress(phase: "Ready for curl", angleExcursion: 0)
    }

    private mutating func updateProgress(phase: String, angleExcursion: Double) {
        progress = RepTrackingProgress(phase: phase, angleExcursion: angleExcursion,
                                       angleThreshold: configuration.minimumAngleExcursion)
    }

    private mutating func clearCycle() {
        isMoving = false
        elapsed = 0
        peakAngle = 0
    }
}

/// Tracks a shoulder press as a position-led upward stroke, top reversal, and
/// controlled return. Angle excursion confirms that the sensor rotated through
/// a meaningful press rather than merely translating.
struct ShoulderPressRepTracker {
    var configuration = ShoulderPressRepTrackingConfiguration()
    private(set) var progress = RepTrackingProgress(
        phase: "Ready for press",
        positionLabel: "Position travel",
        positionThreshold: 0.10,
        angleThreshold: 20
    )

    private enum Phase: Equatable {
        case waiting
        case pressing
        case lowering
    }

    private var phase = Phase.waiting
    private var baselinePosition: PositionEstimate?
    private var baselineAngles: IntegratedGyroAngles?
    private var elapsed = 0.0
    private var peakPosition = 0.0
    private var peakAngle = 0.0

    mutating func reset() {
        baselinePosition = nil
        baselineAngles = nil
        phase = .waiting
        elapsed = 0
        peakPosition = 0
        peakAngle = 0
        progress = RepTrackingProgress(phase: "Ready for press", positionLabel: "Position travel",
                                       positionThreshold: configuration.minimumPositionExcursion,
                                       angleThreshold: configuration.minimumAngleExcursion)
    }

    mutating func rebaseForNextRep(position: PositionEstimate, angles: IntegratedGyroAngles) {
        baselinePosition = position
        baselineAngles = angles
        phase = .waiting
        elapsed = 0
        peakPosition = 0
        peakAngle = 0
        updateProgress(phase: "Ready for press", positionExcursion: 0, angleExcursion: 0)
    }

    mutating func update(sample: MotionSample, position: PositionEstimate, angles: IntegratedGyroAngles) -> Bool {
        guard RepTrackingSignal.isUsable(sample, position: position, angles: angles) else { return false }
        guard let baselinePosition, let baselineAngles else {
            self.baselinePosition = position
            self.baselineAngles = angles
            return false
        }

        let positionExcursion = RepTrackingSignal.positionDistance(position, from: baselinePosition)
        let angleExcursion = RepTrackingSignal.angleDistance(angles, from: baselineAngles)
        updateProgress(phase: phaseLabel, positionExcursion: positionExcursion, angleExcursion: angleExcursion)

        if phase == .waiting {
            if RepTrackingSignal.isStationary(sample) {
                self.baselinePosition = position
                self.baselineAngles = angles
                updateProgress(phase: "Ready for press", positionExcursion: 0, angleExcursion: 0)
                return false
            }
            // A press is position-led, with angle change required as confirmation.
            guard positionExcursion >= configuration.minimumPositionExcursion * 0.45,
                  angleExcursion >= configuration.minimumAngleExcursion * 0.4 else { return false }
            phase = .pressing
            elapsed = sample.deltaTime
            peakPosition = positionExcursion
            peakAngle = angleExcursion
            updateProgress(phase: "Pressing up", positionExcursion: positionExcursion, angleExcursion: angleExcursion)
            return false
        }

        elapsed += sample.deltaTime
        peakPosition = max(peakPosition, positionExcursion)
        peakAngle = max(peakAngle, angleExcursion)

        if elapsed > configuration.maximumDuration {
            rebase(position: position, angles: angles)
            return false
        }

        let reachedPressRange = peakPosition >= configuration.minimumPositionExcursion &&
            peakAngle >= configuration.minimumAngleExcursion
        guard reachedPressRange else {
            if RepTrackingSignal.isStationary(sample) { rebase(position: position, angles: angles) }
            return false
        }

        // Require both signals to turn downward from their peak before accepting
        // a return. This filters out pauses and small oscillations near the bottom.
        if phase == .pressing,
           positionExcursion <= peakPosition * 0.88,
           angleExcursion <= peakAngle * 0.92 {
            phase = .lowering
        }
        updateProgress(phase: phaseLabel, positionExcursion: positionExcursion, angleExcursion: angleExcursion)

        let returnedFromPress = phase == .lowering &&
            positionExcursion <= peakPosition * configuration.positionReturnFraction &&
            angleExcursion <= peakAngle * configuration.angleReturnFraction

        if returnedFromPress && elapsed >= configuration.minimumDuration {
            rebase(position: position, angles: angles)
            return true
        }
        return false
    }

    private mutating func rebase(position: PositionEstimate, angles: IntegratedGyroAngles) {
        baselinePosition = position
        baselineAngles = angles
        phase = .waiting
        elapsed = 0
        peakPosition = 0
        peakAngle = 0
        updateProgress(phase: "Ready for press", positionExcursion: 0, angleExcursion: 0)
    }

    private var phaseLabel: String {
        switch phase {
        case .waiting: return "Ready for press"
        case .pressing: return "Pressing up"
        case .lowering: return "Lowering"
        }
    }

    private mutating func updateProgress(phase: String, positionExcursion: Double, angleExcursion: Double) {
        progress = RepTrackingProgress(phase: phase, positionLabel: "Position travel",
                                       positionExcursion: positionExcursion,
                                       positionThreshold: configuration.minimumPositionExcursion,
                                       angleExcursion: angleExcursion,
                                       angleThreshold: configuration.minimumAngleExcursion)
    }
}

/// Selects and runs the exercise-specific detector used by the active workout.
struct ExerciseRepTracker {
    private enum Algorithm {
        case bicepCurl(BicepCurlRepTracker)
        case shoulderPress(ShoulderPressRepTracker)
    }

    private var algorithm: Algorithm = .bicepCurl(BicepCurlRepTracker())
    private(set) var count = 0

    var progress: RepTrackingProgress {
        switch algorithm {
        case .bicepCurl(let tracker): return tracker.progress
        case .shoulderPress(let tracker): return tracker.progress
        }
    }

    mutating func reset(for exercise: Exercise) {
        count = 0
        switch exercise {
        case .bicepCurl:
            var tracker = BicepCurlRepTracker()
            tracker.reset()
            algorithm = .bicepCurl(tracker)
        case .shoulderPress:
            var tracker = ShoulderPressRepTracker()
            tracker.reset()
            algorithm = .shoulderPress(tracker)
        }
    }

    mutating func rebaseForNextRep(position: PositionEstimate, verticalPosition: Double, angles: IntegratedGyroAngles) {
        switch algorithm {
        case .bicepCurl(var tracker):
            tracker.rebaseForNextRep(angles: angles)
            algorithm = .bicepCurl(tracker)
        case .shoulderPress(var tracker):
            tracker.rebaseForNextRep(position: position, angles: angles)
            algorithm = .shoulderPress(tracker)
        }
    }

    @discardableResult
    mutating func update(
        sample: MotionSample,
        position: PositionEstimate,
        verticalPosition: Double,
        angles: IntegratedGyroAngles
    ) -> Int {
        let completedRep: Bool
        switch algorithm {
        case .bicepCurl(var tracker):
            completedRep = tracker.update(sample: sample, angles: angles)
            algorithm = .bicepCurl(tracker)
        case .shoulderPress(var tracker):
            completedRep = tracker.update(sample: sample, position: position, angles: angles)
            algorithm = .shoulderPress(tracker)
        }
        if completedRep { count += 1 }
        return count
    }
}

private enum RepTrackingSignal {
    static func isUsable(_ sample: MotionSample, angles: IntegratedGyroAngles) -> Bool {
        let values = [sample.timestamp, sample.deltaTime, angles.x, angles.y, angles.z]
        return values.allSatisfy(\.isFinite) && sample.deltaTime > 0 && sample.deltaTime <= 0.1
    }

    static func isUsable(_ sample: MotionSample, verticalPosition: Double) -> Bool {
        let values = [sample.timestamp, sample.deltaTime, verticalPosition]
        return values.allSatisfy(\.isFinite) && sample.deltaTime > 0 && sample.deltaTime <= 0.1
    }

    static func isUsable(_ sample: MotionSample, verticalPosition: Double, angles: IntegratedGyroAngles) -> Bool {
        let values = [sample.timestamp, sample.deltaTime, sample.ax, sample.ay, sample.az,
                      sample.gx, sample.gy, sample.gz, verticalPosition,
                      angles.x, angles.y, angles.z]
        return values.allSatisfy(\.isFinite) && sample.deltaTime > 0 && sample.deltaTime <= 0.1
    }

    static func isUsable(_ sample: MotionSample, position: PositionEstimate, angles: IntegratedGyroAngles) -> Bool {
        let values = [sample.timestamp, sample.deltaTime, sample.ax, sample.ay, sample.az,
                      sample.gx, sample.gy, sample.gz, position.x, position.y, position.z,
                      angles.x, angles.y, angles.z]
        return values.allSatisfy(\.isFinite) && sample.deltaTime > 0 && sample.deltaTime <= 0.1
    }

    static func isStationary(_ sample: MotionSample) -> Bool {
        sample.gyroMagnitude < 3.0 && abs(sample.accelerationMagnitude - 9.80665) < 0.4
    }

    static func positionDistance(_ lhs: PositionEstimate, from rhs: PositionEstimate) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    static func angleDistance(_ lhs: IntegratedGyroAngles, from rhs: IntegratedGyroAngles) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}
