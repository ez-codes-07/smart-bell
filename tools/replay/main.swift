// Replays a raw Smart Bell recording (Sensor Readings → Record → Share CSV) through
// the app's exact processing pipeline and prints what the app would have shown.
//
// Build and run from the repository root:
//   swiftc -O -o /tmp/smartbell-replay tools/replay/main.swift \
//     SmartBell/Backend/MotionFilter.swift SmartBell/Backend/PositionCalculator.swift \
//     SmartBell/Backend/RepTracking.swift SmartBell/Backend/Models.swift
//   /tmp/smartbell-replay recording.csv [print-every-n-samples]
import Foundation

guard CommandLine.arguments.count >= 2,
      let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    print("usage: smartbell-replay <recording.csv> [print-every-n-samples]")
    exit(1)
}
let printEvery = CommandLine.arguments.count >= 3 ? Int(CommandLine.arguments[2]) ?? 10 : 10

var samples: [MotionSample] = []
for line in text.split(separator: "\n").dropFirst() {
    let f = line.split(separator: ",").compactMap { Double($0) }
    guard f.count == 8 else { continue }
    samples.append(MotionSample(timestamp: f[0], deltaTime: f[1], ax: f[2], ay: f[3], az: f[4], gx: f[5], gy: f[6], gz: f[7]))
}
guard !samples.isEmpty else { print("no samples parsed"); exit(1) }

// Raw stream summary: catches unit, rate, and range problems before any processing.
let dts = samples.map(\.deltaTime)
let duration = samples.last!.timestamp - samples.first!.timestamp
let accelMagnitudes = samples.map(\.accelerationMagnitude)
let maxAxisAccel = samples.map { max(abs($0.ax), abs($0.ay), abs($0.az)) }.max()!
let maxGyro = samples.map { max(abs($0.gx), abs($0.gy), abs($0.gz)) }.max()!
let first = samples.prefix(100)
print(String(format: "samples %d over %.2f s (%.1f Hz by arrival); dt_s mean %.4f min %.4f max %.4f",
             samples.count, duration, Double(samples.count - 1) / max(duration, 1e-9),
             dts.reduce(0, +) / Double(dts.count), dts.min()!, dts.max()!))
print(String(format: "first 1 s at rest? |a| mean %.3f m/s² (expect ~9.81), gyro mean (%.3f, %.3f, %.3f) °/s",
             first.map(\.accelerationMagnitude).reduce(0, +) / Double(first.count),
             first.map(\.gx).reduce(0, +) / Double(first.count),
             first.map(\.gy).reduce(0, +) / Double(first.count),
             first.map(\.gz).reduce(0, +) / Double(first.count)))
print(String(format: "|a| range %.2f–%.2f m/s²; largest single-axis accel %.2f m/s² (±2 g clips at ~19.6); largest gyro %.1f °/s",
             accelMagnitudes.min()!, accelMagnitudes.max()!, maxAxisAccel, maxGyro))
let clipped = samples.filter { max(abs($0.ax), abs($0.ay), abs($0.az)) > 19.3 }.count
if clipped > 0 { print("WARNING: \(clipped) samples near the ±2 g accelerometer limit (possible clipping)") }

// Same pipeline as BLEDeviceManager.publish (outside a workout).
var filter = MotionSampleLowPassFilter()
var stillness = StillnessDetector()
var integrator = GyroscopeIntegrator()
var position = PositionCalculator()
var previous = PositionEstimate()
var wasStill = true
print("\nt_s     still  pos x/y/z (m)              angles x/y/z (°)        tilt check")
for (index, sample) in samples.enumerated() {
    let filtered = filter.add(sample)
    let (corrected, still) = stillness.process(filtered, filterIsWarmedUp: filter.isWarmedUp)
    let motion = still
        ? MotionSample(timestamp: corrected.timestamp, deltaTime: corrected.deltaTime,
                       ax: corrected.ax, ay: corrected.ay, az: corrected.az, gx: 0, gy: 0, gz: 0)
        : corrected
    let angles = integrator.add(motion)
    let pos = position.add(motion, isStill: still)
    let jump = ((pos.x - previous.x) * (pos.x - previous.x) + (pos.y - previous.y) * (pos.y - previous.y)
                + (pos.z - previous.z) * (pos.z - previous.z)).squareRoot()
    if jump > 0.02 {
        print(String(format: "  JUMP %.3f m at t=%.2f (%@)", jump, motion.timestamp,
                     still && !wasStill ? "stillness began: drift correction" : "during motion"))
    }
    if index % printEvery == 0 || still != wasStill {
        print(String(format: "%6.2f  %@  %+7.3f %+7.3f %+7.3f    %+7.1f %+7.1f %+7.1f    %@",
                     motion.timestamp, still ? "still " : "moving", pos.x, pos.y, pos.z,
                     angles.x, angles.y, angles.z,
                     position.tiltErrorAtLastStop.map { String(format: "%.1f°", $0) } ?? "—"))
    }
    previous = pos
    wasStill = still
}
print("speed-limit resets (estimate diverged): \(position.divergenceResets)")
print(String(format: "\nlearned: gyro bias (%.3f, %.3f, %.3f) °/s, still limits gyro %.2f °/s accel %.3f m/s²",
             stillness.gyroBias.x, stillness.gyroBias.y, stillness.gyroBias.z,
             stillness.gyroLimit, stillness.accelerationLimit))
