// Live analysis of a Smart Bell plugged into this computer over USB.
//
// The ESP32 firmware (SERIAL_FULL_RATE = true) prints every sample as
// "ax,ay,az,gx,gy,gz,dt_s" at 921600 baud. This tool reads that stream, runs each
// sample through the app's exact processing (filter, stillness/calibration, gyro
// auto-correction, position), prints a status line twice a second plus events, and
// saves the raw samples as a CSV that tools/replay can re-run.
//
// Build and run from the repository root:
//   swiftc -O -o /tmp/smartbell-live tools/live/main.swift \
//     SmartBell/Backend/MotionFilter.swift SmartBell/Backend/PositionCalculator.swift \
//     SmartBell/Backend/GyroAxisCalibrator.swift SmartBell/Backend/Models.swift
//   /tmp/smartbell-live /dev/cu.usbserial-XXXX [seconds] [output.csv]
// Use "-" instead of a port to read the same CSV format from standard input.
import Foundation
import simd

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: smartbell-live <serial-port | -> [seconds] [output.csv]")
    exit(1)
}
let source = arguments[1]
let duration = arguments.count >= 3 ? Double(arguments[2]) ?? 60 : 60
let outputPath = arguments.count >= 4 ? arguments[3]
    : FileManager.default.currentDirectoryPath + "/smartbell-live-\(Int(Date().timeIntervalSince1970)).csv"

// MARK: - Serial port

func openSerialPort(_ path: String, baud: speed_t) -> Int32 {
    let descriptor = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard descriptor >= 0 else {
        print("cannot open \(path): \(String(cString: strerror(errno)))")
        exit(1)
    }
    _ = fcntl(descriptor, F_SETFL, 0) // back to blocking reads
    var settings = termios()
    tcgetattr(descriptor, &settings)
    cfmakeraw(&settings)
    cfsetispeed(&settings, baud)
    cfsetospeed(&settings, baud)
    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
    // Return from read() as soon as any data arrives, or after 0.2 s.
    withUnsafeMutablePointer(to: &settings.c_cc) { pointer in
        pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 2
        }
    }
    tcsetattr(descriptor, TCSANOW, &settings)
    tcflush(descriptor, TCIFLUSH)
    return descriptor
}

let descriptor: Int32 = source == "-" ? STDIN_FILENO : openSerialPort(source, baud: 921_600)

// MARK: - Pipeline (same as BLEDeviceManager.publish, outside a workout)

var filter = MotionSampleLowPassFilter()
var stillness = StillnessDetector()
var integrator = GyroscopeIntegrator()
var position = PositionCalculator()
var calibrator = GyroAxisCalibrator()
var gyroCorrection = GyroCorrection.identity
var angles = IntegratedGyroAngles()
var pos = PositionEstimate()
var still = true
var wasStill = true
var csv = "t_s,dt_s,ax,ay,az,gx,gy,gz\n"
var sampleCount = 0, rejected = 0, malformed = 0
var elapsed = 0.0
var lastStatus = 0.0
var recentRaw: [MotionSample] = []
let wallStart = Date()

func event(_ text: String) {
    print(String(format: "[%6.2f s] ", elapsed) + text)
}

func process(_ sample: MotionSample) {
    let limit = 16 * 9.80665
    guard abs(sample.ax) <= limit, abs(sample.ay) <= limit, abs(sample.az) <= limit,
          abs(sample.gx) <= 2000, abs(sample.gy) <= 2000, abs(sample.gz) <= 2000 else {
        rejected += 1
        event("rejected impossible sample")
        return
    }
    let filtered = filter.add(gyroCorrection.apply(to: sample))
    let (corrected, isStill) = stillness.process(filtered, filterIsWarmedUp: filter.isWarmedUp)
    if stillness.isLearned && !position.isCalibrated {
        position.calibrate(gravity: stillness.learnedGravity)
        integrator.reset()
        let g = stillness.learnedGravity
        event(String(format: "CALIBRATED: up = sensor (%+.2f, %+.2f, %+.2f) m/s², |g| %.2f; %d window(s) rejected for movement",
                     g.x, g.y, g.z, simd_length(g), stillness.rejectedCalibrations))
        event(String(format: "  gyro bias (%+.2f, %+.2f, %+.2f) °/s; still limits gyro %.2f °/s, accel %.3f m/s²",
                     stillness.gyroBias.x, stillness.gyroBias.y, stillness.gyroBias.z,
                     stillness.gyroLimit, stillness.accelerationLimit))
    }
    if stillness.isLearned, let update = calibrator.observe(corrected, isStill: isStill) {
        gyroCorrection = GyroCorrection(matrix: update.matrix * gyroCorrection.matrix)
        event("GYRO CORRECTION adopted: \(gyroCorrection.summary). Recalibrating: hold still.")
        filter.reset(); stillness.reset(); position.reset(); integrator.reset(); calibrator.reset()
        pos = PositionEstimate(); angles = IntegratedGyroAngles(); still = true; wasStill = true
        return
    }
    still = isStill
    let motion = isStill
        ? MotionSample(timestamp: corrected.timestamp, deltaTime: corrected.deltaTime,
                       ax: corrected.ax, ay: corrected.ay, az: corrected.az, gx: 0, gy: 0, gz: 0)
        : corrected
    angles = integrator.add(motion)
    let previous = pos
    pos = position.add(motion, isStill: isStill)
    let jump = simd_length(SIMD3(pos.x - previous.x, pos.y - previous.y, pos.z - previous.z))
    // Fast movement legitimately changes position by centimetres per sample, so only
    // report the step applied by the drift correction when a movement ends.
    if isStill && !wasStill && jump > 0.02 { event(String(format: "drift correction at stop moved position %.3f m", jump)) }
    if stillness.isLearned && isStill != wasStill {
        if isStill {
            event(String(format: "STILL   pos (%+.3f, %+.3f, %+.3f) m  angles (%+.1f, %+.1f, %+.1f)°  tilt check %@",
                         pos.x, pos.y, pos.z, angles.x, angles.y, angles.z,
                         position.tiltErrorAtLastStop.map { String(format: "%.1f°", $0) } ?? "—"))
        } else {
            event("MOVING")
        }
    }
    wasStill = isStill
}

func printStatus() {
    let window = recentRaw.suffix(50)
    let rate = window.count > 1 ? Double(window.count - 1) / max(window.dropFirst().map(\.deltaTime).reduce(0, +), 1e-9) : 0
    let raw = recentRaw.last
    let state = !stillness.isLearned ? "calibrating (hold still)" : (still ? "still" : "moving")
    print(String(format: "  %5.1fs %5.0fHz %-24@ pos (%+6.3f, %+6.3f, %+6.3f) m  ang (%+6.1f, %+6.1f, %+6.1f)°  raw a(%+5.2f,%+5.2f,%+5.2f) g(%+6.1f,%+6.1f,%+6.1f)%@",
                 elapsed, rate, state as NSString, pos.x, pos.y, pos.z, angles.x, angles.y, angles.z,
                 raw?.ax ?? 0, raw?.ay ?? 0, raw?.az ?? 0, raw?.gx ?? 0, raw?.gy ?? 0, raw?.gz ?? 0,
                 position.divergenceResets > 0 ? " DIVERGED(\(position.divergenceResets))" : ""))
}

// MARK: - Read loop

print("Reading \(source) for \(Int(duration)) s. Hold the sensor still until it reports CALIBRATED.")
var buffer = [UInt8](repeating: 0, count: 4096)
var pending = Data()
while Date().timeIntervalSince(wallStart) < duration {
    let count = read(descriptor, &buffer, buffer.count)
    if count < 0 { print("read error: \(String(cString: strerror(errno)))"); break }
    if count == 0 {
        if source == "-" { break } // end of input
        continue
    }
    pending.append(contentsOf: buffer[0..<count])
    while let newline = pending.firstIndex(of: 0x0A) {
        let lineData = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { continue }
        let fields = line.split(separator: ",").compactMap { Double($0) }
        guard fields.count == 7, fields.allSatisfy(\.isFinite), fields[6] > 0, fields[6] <= 1 else {
            if !line.hasPrefix("ax,") { malformed += 1; if malformed <= 5 { event("non-data line: \(line.prefix(80))") } }
            continue
        }
        let sample = MotionSample(timestamp: elapsed, deltaTime: fields[6], ax: fields[0], ay: fields[1], az: fields[2],
                                  gx: fields[3], gy: fields[4], gz: fields[5])
        elapsed += fields[6]
        sampleCount += 1
        recentRaw.append(sample)
        if recentRaw.count > 200 { recentRaw.removeFirst(recentRaw.count - 200) }
        csv += String(format: "%.4f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n", sample.timestamp, sample.deltaTime,
                      sample.ax, sample.ay, sample.az, sample.gx, sample.gy, sample.gz)
        process(sample)
        if elapsed - lastStatus >= 0.5 { printStatus(); lastStatus = elapsed }
    }
}

try? csv.write(toFile: outputPath, atomically: true, encoding: .utf8)
print(String(format: "\nDone: %d samples (%.1f s of sensor time), %d rejected, %d non-data lines. Saved %@",
             sampleCount, elapsed, rejected, malformed, outputPath))
print("gyro correction: \(gyroCorrection.summary)")
print("calibrator: \(calibrator.status)")
