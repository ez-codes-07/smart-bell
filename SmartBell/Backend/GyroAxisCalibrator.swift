import Foundation
import simd

/// A correction applied to raw gyro readings: corrected = matrix · measured.
/// The matrix is a signed axis permutation times a uniform scale, which covers a
/// wrong range/scale, a flipped axis sign, and swapped axes.
struct GyroCorrection: Equatable, Codable {
    /// Row-major 3×3 matrix.
    var rows: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    static let identity = GyroCorrection()

    var matrix: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(rows[0], rows[1], rows[2]),
                              SIMD3(rows[3], rows[4], rows[5]),
                              SIMD3(rows[6], rows[7], rows[8])])
    }

    init() {}

    init(matrix: simd_double3x3) {
        let t = matrix.transpose // columns of the transpose are the rows
        rows = [t.columns.0.x, t.columns.0.y, t.columns.0.z,
                t.columns.1.x, t.columns.1.y, t.columns.1.z,
                t.columns.2.x, t.columns.2.y, t.columns.2.z]
    }

    var isIdentity: Bool { self == .identity }

    func apply(to sample: MotionSample) -> MotionSample {
        let corrected = matrix * SIMD3(sample.gx, sample.gy, sample.gz)
        return MotionSample(timestamp: sample.timestamp, deltaTime: sample.deltaTime,
                            ax: sample.ax, ay: sample.ay, az: sample.az,
                            gx: corrected.x, gy: corrected.y, gz: corrected.z)
    }

    /// Human-readable description, e.g. "gx = 8.00 × measured gy; gy = −8.00 × measured gx; …".
    var summary: String {
        guard !isIdentity else { return "None (gyro and accelerometer agree)" }
        let names = ["gx", "gy", "gz"]
        return (0..<3).map { row in
            let values = rows[(row * 3)..<(row * 3 + 3)]
            guard let column = values.indices.max(by: { abs(rows[$0]) < abs(rows[$1]) }) else { return "" }
            let factor = rows[column]
            return String(format: "%@ = %+.2f × measured %@", names[row], factor, names[column - row * 3])
        }.joined(separator: "; ")
    }
}

/// Learns a `GyroCorrection` from ordinary use. Each movement between two still
/// poses gives the sensor-frame gravity direction before and after (from the
/// accelerometer) and the gyro samples in between. A correct gyro, integrated over
/// the movement, rotates the "before" gravity onto the "after" one. Every signed
/// axis permutation (48) is tried, each with its best uniform scale; a candidate is
/// adopted only if it clearly beats the current gyro on several movements.
struct GyroAxisCalibrator {
    struct Segment {
        var gravityBefore: SIMD3<Double>
        var gravityAfter: SIMD3<Double>
        var rates: [SIMD3<Double>] // °/s, already bias-corrected
        var intervals: [Double]
    }

    /// Movements are only useful if they change the tilt (rotation about the
    /// vertical is invisible to the accelerometer).
    var minimumTiltChange = 20.0 // degrees
    var maximumSegmentDuration = 10.0 // seconds
    var maximumSegments = 8
    /// Adoption requires this many movements, with tilt changes adding up to this much.
    var minimumSegments = 3
    var minimumTotalTiltChange = 90.0
    /// The current gyro must be clearly wrong, and the candidate clearly right
    /// (mean end-of-movement tilt error, degrees).
    var currentErrorThreshold = 10.0
    var candidateErrorThreshold = 6.0
    var requiredImprovementFactor = 3.0

    private(set) var segments: [Segment] = []
    private(set) var lastCurrentError: Double?
    private(set) var lastBestError: Double?
    private var activeRates: [SIMD3<Double>] = []
    private var activeIntervals: [Double] = []
    private var gravityAtMovementStart: SIMD3<Double>?
    private var wasStill = true
    private var stillAcceleration = SIMD3<Double>(repeating: 0)

    var status: String {
        guard !segments.isEmpty else { return "Watching for tilting movements" }
        let total = segments.map { Self.angleDegrees($0.gravityBefore, $0.gravityAfter) }.reduce(0, +)
        var text = String(format: "%d movement%@ collected (%.0f° of tilt)", segments.count,
                          segments.count == 1 ? "" : "s", total)
        if let current = lastCurrentError {
            text += String(format: "; gyro/gravity mismatch %.1f° per movement", current)
        }
        return text
    }

    mutating func reset() {
        self = GyroAxisCalibrator()
    }

    /// Feed every calibrated sample: the filtered, bias-corrected gyro (not zeroed
    /// at rest), the filtered acceleration, and the stillness flag. Returns a new
    /// correction (to compose with the current one) when one should be adopted.
    mutating func observe(_ sample: MotionSample, isStill: Bool) -> GyroCorrection? {
        let acceleration = SIMD3(sample.ax, sample.ay, sample.az)
        defer { wasStill = isStill }
        if isStill {
            // Smooth the at-rest gravity estimate (filtered samples are already low-passed).
            stillAcceleration = wasStill ? stillAcceleration * 0.8 + acceleration * 0.2 : acceleration
            guard !wasStill, let before = gravityAtMovementStart else { return nil }
            // Movement just ended.
            gravityAtMovementStart = nil
            let segment = Segment(gravityBefore: before, gravityAfter: acceleration,
                                  rates: activeRates, intervals: activeIntervals)
            activeRates = []
            activeIntervals = []
            let duration = segment.intervals.reduce(0, +)
            guard duration <= maximumSegmentDuration,
                  Self.angleDegrees(segment.gravityBefore, segment.gravityAfter) >= minimumTiltChange else { return nil }
            segments.append(segment)
            if segments.count > maximumSegments { segments.removeFirst(segments.count - maximumSegments) }
            return evaluate()
        }
        if wasStill {
            gravityAtMovementStart = stillAcceleration
            activeRates = []
            activeIntervals = []
        }
        if gravityAtMovementStart != nil {
            activeRates.append(SIMD3(sample.gx, sample.gy, sample.gz))
            activeIntervals.append(sample.deltaTime.isFinite && sample.deltaTime > 0 && sample.deltaTime <= 0.1
                                   ? sample.deltaTime : 0.01)
            if activeIntervals.reduce(0, +) > maximumSegmentDuration { gravityAtMovementStart = nil }
        }
        return nil
    }

    private mutating func evaluate() -> GyroCorrection? {
        let currentError = Self.meanError(segments, matrix: matrix_identity_double3x3)
        lastCurrentError = currentError
        let totalTilt = segments.map { Self.angleDegrees($0.gravityBefore, $0.gravityAfter) }.reduce(0, +)
        guard segments.count >= minimumSegments, totalTilt >= minimumTotalTiltChange,
              currentError > currentErrorThreshold else {
            lastBestError = nil
            return nil
        }

        // Best scale for each signed axis permutation; prefer simpler candidates
        // (closest to identity) when errors tie within 1°.
        var best: (matrix: simd_double3x3, error: Double, cost: Int)?
        for candidate in Self.signedPermutations {
            let (scale, error) = Self.bestScale(segments, base: candidate.matrix)
            let entry = (candidate.matrix * scale, error, candidate.cost)
            if let current = best {
                if error < current.error - 1 || (abs(error - current.error) <= 1 && entry.2 < current.cost) {
                    best = entry
                }
            } else {
                best = entry
            }
        }
        guard let best else { return nil }
        lastBestError = best.error
        guard best.error <= candidateErrorThreshold, currentError >= best.error * requiredImprovementFactor else { return nil }
        segments = []
        return GyroCorrection(matrix: best.matrix)
    }

    // MARK: - Math

    /// All 48 signed permutation matrices, with a cost (axes moved + signs flipped).
    private static let signedPermutations: [(matrix: simd_double3x3, cost: Int)] = {
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var result: [(simd_double3x3, Int)] = []
        for permutation in permutations {
            for signs in 0..<8 {
                var rows = [SIMD3<Double>](repeating: SIMD3(repeating: 0), count: 3)
                var cost = 0
                for row in 0..<3 {
                    let sign: Double = (signs >> row) & 1 == 1 ? -1 : 1
                    var vector = SIMD3<Double>(repeating: 0)
                    vector[permutation[row]] = sign
                    rows[row] = vector
                    if permutation[row] != row { cost += 1 }
                    if sign < 0 { cost += 1 }
                }
                result.append((simd_double3x3(rows: rows), cost))
            }
        }
        return result
    }()

    /// Coarse log-spaced search over 0.05–20, then golden-section refinement.
    private static func bestScale(_ segments: [Segment], base: simd_double3x3) -> (Double, Double) {
        var bestLog = 0.0
        var bestError = Double.infinity
        let low = log(0.05), high = log(20.0)
        for step in 0...40 {
            let value = low + (high - low) * Double(step) / 40
            let error = meanError(segments, matrix: base * exp(value))
            if error < bestError { bestError = error; bestLog = value }
        }
        var a = bestLog - (high - low) / 40, b = bestLog + (high - low) / 40
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<20 {
            let c = b - ratio * (b - a), d = a + ratio * (b - a)
            if meanError(segments, matrix: base * exp(c)) < meanError(segments, matrix: base * exp(d)) { b = d } else { a = c }
        }
        let refined = (a + b) / 2
        let refinedError = meanError(segments, matrix: base * exp(refined))
        return refinedError < bestError ? (exp(refined), refinedError) : (exp(bestLog), bestError)
    }

    /// Mean angle (degrees) between measured end gravity and the start gravity
    /// carried through the gyro-integrated rotation, with `matrix` applied to rates.
    private static func meanError(_ segments: [Segment], matrix: simd_double3x3) -> Double {
        guard !segments.isEmpty else { return 0 }
        var total = 0.0
        for segment in segments {
            var orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            for (rate, dt) in zip(segment.rates, segment.intervals) {
                let omega = matrix * rate * (Double.pi / 180)
                let speed = simd_length(omega)
                if speed > 1e-9 {
                    orientation = simd_normalize(orientation * simd_quatd(angle: speed * dt, axis: omega / speed))
                }
            }
            // Gravity is fixed in the world, so in the sensor frame it rotates by the
            // inverse of the sensor's rotation.
            let predicted = orientation.inverse.act(segment.gravityBefore)
            total += angleDegrees(predicted, segment.gravityAfter)
        }
        return total / Double(segments.count)
    }

    static func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 1e-9, lb > 1e-9 else { return 0 }
        return acos(min(max(simd_dot(a, b) / (la * lb), -1), 1)) * 180 / .pi
    }
}
