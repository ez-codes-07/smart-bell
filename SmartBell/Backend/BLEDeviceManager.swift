import Foundation
import simd
import Combine
import CoreBluetooth

@MainActor
final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var state = "Bluetooth is off"
    @Published private(set) var devices: [CBPeripheral] = []
    @Published private(set) var isConnected = false
    @Published private(set) var latestSample: MotionSample?
    /// Low-passed, gyro-bias-corrected sample (0.25 s behind `latestSample`).
    @Published private(set) var filteredSample: MotionSample?
    @Published private(set) var isStill = true
    /// True until the sensor has been held still long enough to calibrate "up",
    /// gravity, and gyro bias. Position and angles stay at zero meanwhile.
    @Published private(set) var isCalibrating = true
    /// Raw samples discarded as physically impossible (e.g. garbled BLE lines).
    @Published private(set) var rejectedSampleCount = 0
    /// Automatic gyro correction (scale, axis signs, axis order) learned by comparing
    /// gyro rotation with accelerometer tilt across movements; saved on the phone.
    @Published private(set) var gyroCorrectionSummary = GyroCorrection.identity.summary
    @Published private(set) var gyroCalibrationStatus = "Watching for tilting movements"
    @Published private(set) var gyroCorrectionMessage: String?
    /// Gyro vs gravity tilt disagreement (degrees) at the last stop; large values mean
    /// the gyro scale, units, or axes do not match the accelerometer.
    @Published private(set) var tiltCheckDegrees: Double?
    /// Set when the position estimate is physically implausible (speed above the
    /// limit, or farther from start than an arm can reach): the sensor data are
    /// inconsistent and position should not be trusted.
    @Published private(set) var positionWarning: String?
    /// Raw-sample recording for offline diagnosis (exported as CSV).
    @Published private(set) var isRecording = false
    @Published private(set) var recordedSampleCount = 0
    @Published private(set) var recordingFileURL: URL?
    private var recordedSamples: [MotionSample] = []
    private let maximumRecordedSamples = 12_000 // 2 minutes at 100 Hz
    @Published private(set) var integratedGyroAngles = IntegratedGyroAngles()
    @Published private(set) var estimatedPosition = PositionEstimate()
    @Published private(set) var verticalPosition = 0.0
    @Published private(set) var repCount = 0
    /// True only during a workout session (between Start and Finish/Discard).
    @Published private(set) var isCountingReps = false
    @Published private(set) var repTrackingProgress = RepTrackingProgress()
    @Published private(set) var usingDemo = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var lastSampleDate: Date?
    @Published var errorMessage: String?

    private let configuration = BLEConfiguration()
    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var demoTimer: Timer?
    private var demoClock = 0.0
    private var demoPhase = 0.0
    private var sampleArrivalTimes: [Date] = []
    private let standardGravity = 9.80665
    private var packetBuffer = Data()
    private var previousDecodedTimestamp: TimeInterval?
    private var gyroIntegrator = GyroscopeIntegrator()
    private var positionCalculator = PositionCalculator()
    /// FFT low-pass (~2 Hz) applied before angles, position, and rep counting. It
    /// removes sensor noise and hand tremor, at a 0.25 s processing delay.
    private var motionFilter = MotionSampleLowPassFilter()
    /// Learns gyro bias and noise at start-up, then flags stillness from the
    /// filtered stream so position and angles hold when the dumbbell is at rest.
    private var stillnessDetector = StillnessDetector()
    private var gyroCalibrator = GyroAxisCalibrator()
    private var gyroCorrection = GyroCorrection.identity
    private static let gyroCorrectionKey = "SmartBell.gyroCorrection"
    private var repTracker = ExerciseRepTracker()

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.gyroCorrectionKey),
           let saved = try? JSONDecoder().decode(GyroCorrection.self, from: data) {
            gyroCorrection = saved
            gyroCorrectionSummary = saved.summary
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Forgets the learned gyro correction and recalibrates.
    func resetGyroCorrection() {
        gyroCorrection = .identity
        UserDefaults.standard.removeObject(forKey: Self.gyroCorrectionKey)
        gyroCorrectionSummary = gyroCorrection.summary
        gyroCorrectionMessage = nil
        resetIntegratedAngles()
    }

    func scan() {
        guard central.state == .poweredOn else { state = "Turn on Bluetooth to scan"; return }
        devices.removeAll()
        state = "Searching for Smart Bell…"
        let serviceFilter = configuration.serviceUUID.map { [CBUUID(string: $0)] }
        central.scanForPeripherals(withServices: serviceFilter, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        resetIntegratedAngles()
        state = "Connecting to \(peripheral.name ?? "device")…"
        connectedPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        stopDemo()
        if let connectedPeripheral { central.cancelPeripheralConnection(connectedPeripheral) }
        isConnected = false
        state = "Disconnected"
    }

    func startDemo() {
        disconnect()
        resetIntegratedAngles()
        usingDemo = true
        isConnected = true
        state = "Demo sensor connected"
        demoClock = Date.timeIntervalSinceReferenceDate
        demoPhase = 0
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitDemoSample() }
        }
    }

    func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil
        if usingDemo { usingDemo = false; isConnected = false; state = "Disconnected" }
    }

    /// User-requested re-zero of displayed position and angles. The rep tracker
    /// restarts its baseline here too, so a rep in progress is not counted.
    func zeroPositionAndAngles() {
        positionCalculator.zeroPosition()
        positionWarning = nil
        gyroIntegrator.reset()
        estimatedPosition = positionCalculator.position
        verticalPosition = positionCalculator.verticalPosition
        integratedGyroAngles = gyroIntegrator.angles
        if isCountingReps {
            repTracker.rebaseForNextRep(position: estimatedPosition, verticalPosition: verticalPosition,
                                        angles: integratedGyroAngles)
            repTrackingProgress = repTracker.progress
        }
    }

    /// Starts counting reps for a workout session. Reps are only counted between
    /// this call and `stopRepCounting()`; outside a workout, motion is never counted.
    func startRepCounting(for exercise: Exercise) {
        repTracker.reset(for: exercise)
        repCount = 0
        repTrackingProgress = repTracker.progress
        isCountingReps = true
    }

    /// Ends the workout's rep counting (call after reading `repCount` to save it).
    func startRecording() {
        recordedSamples.removeAll(keepingCapacity: true)
        recordedSampleCount = 0
        recordingFileURL = nil
        isRecording = true
    }

    /// Stops recording and writes the raw samples, exactly as received, to a CSV file
    /// ready to share: t_s,dt_s,ax,ay,az,gx,gy,gz (m/s², °/s).
    func stopRecording() {
        isRecording = false
        guard !recordedSamples.isEmpty else { return }
        let start = recordedSamples[0].timestamp
        var csv = "t_s,dt_s,ax,ay,az,gx,gy,gz\n"
        csv.reserveCapacity(recordedSamples.count * 64)
        for sample in recordedSamples {
            csv += String(format: "%.4f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                          sample.timestamp - start, sample.deltaTime,
                          sample.ax, sample.ay, sample.az, sample.gx, sample.gy, sample.gz)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartbell-raw-\(formatter.string(from: Date())).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            recordingFileURL = url
        } catch {
            errorMessage = "Could not save recording: \(error.localizedDescription)"
        }
    }

    func stopRepCounting() {
        isCountingReps = false
        repCount = 0
        repTrackingProgress = RepTrackingProgress()
    }

    private func resetIntegratedAngles() {
        motionFilter.reset()
        stillnessDetector.reset()
        gyroCalibrator.reset()
        filteredSample = nil
        isStill = true
        isCalibrating = true
        rejectedSampleCount = 0
        tiltCheckDegrees = nil
        positionWarning = nil
        gyroIntegrator.reset()
        integratedGyroAngles = gyroIntegrator.angles
        positionCalculator.reset()
        estimatedPosition = positionCalculator.position
        verticalPosition = positionCalculator.verticalPosition
    }

    private func emitDemoSample() {
        let now = Date.timeIntervalSinceReferenceDate
        let t = now - demoClock
        // Physically consistent demo: after 1.5 s still (so gyro bias and noise can be
        // learned, like a real start-up), repeat a 2.0 s rep that lifts 0.35 m while
        // rotating 40° about the sensor Y axis, then pause 0.6 s. Accelerometer and
        // gyro values are derived from that motion so integration stays meaningful.
        let repDuration = 2.0, pauseDuration = 0.6, lift = 0.35, swingDegrees = 40.0
        var theta = 0.0, rate = 0.0, verticalAcceleration = 0.0
        if t >= 1.5 {
            demoPhase += 0.01
            let cycleTime = demoPhase.truncatingRemainder(dividingBy: repDuration + pauseDuration)
            if cycleTime < repDuration {
                let w = 2 * Double.pi / repDuration
                theta = swingDegrees * 0.5 * (1 - cos(w * cycleTime))
                rate = swingDegrees * 0.5 * w * sin(w * cycleTime)
                verticalAcceleration = lift * 0.5 * w * w * cos(w * cycleTime)
            }
        }
        let thetaRadians = theta * .pi / 180
        let specificForce = standardGravity + verticalAcceleration
        publish(MotionSample(timestamp: t, deltaTime: 0.01,
                             ax: -specificForce * sin(thetaRadians), ay: 0,
                             az: specificForce * cos(thetaRadians),
                             gx: 0, gy: rate, gz: 0))
    }

    private func parse(_ data: Data) {
        // Firmware uses newline-delimited CSV. Buffer notifications because BLE may split or
        // coalesce lines depending on the negotiated MTU and connection timing.
        packetBuffer.append(data)
        let newline = Data([0x0A])
        while let lineRange = packetBuffer.range(of: newline) {
            let line = packetBuffer.subdata(in: packetBuffer.startIndex..<lineRange.lowerBound)
            packetBuffer.removeSubrange(packetBuffer.startIndex..<lineRange.upperBound)
            parseLine(line)
        }
        if packetBuffer.count > 256 { packetBuffer.removeAll(keepingCapacity: true) }
    }

    private func parseLine(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard (fields.count == 6 || fields.count == 7),
              let ax = Double(fields[0]), let ay = Double(fields[1]), let az = Double(fields[2]),
              let gx = Double(fields[3]), let gy = Double(fields[4]), let gz = Double(fields[5]),
              [ax, ay, az, gx, gy, gz].allSatisfy({ $0.isFinite }) else { return }

        let timestamp = Date.timeIntervalSinceReferenceDate
        let deltaTime: TimeInterval
        if fields.count == 7 {
            // Seventh field is dt_s: seconds between successive sensor sample reads.
            guard let deltaSeconds = Double(fields[6]), deltaSeconds.isFinite,
                  deltaSeconds > 0, deltaSeconds <= 1 else { return }
            deltaTime = deltaSeconds
        } else if let previousDecodedTimestamp {
            // Backward compatibility with the previous six-field firmware format.
            deltaTime = max(timestamp - previousDecodedTimestamp, 0.000001)
        } else {
            deltaTime = 0.01
        }
        previousDecodedTimestamp = timestamp
        publish(MotionSample(timestamp: timestamp, deltaTime: deltaTime, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz))
    }

    private func publish(_ sample: MotionSample) {
        // Drop physically impossible readings (beyond the sensor's ±16 g / ±2000 °/s
        // full scale), e.g. a garbled BLE line: one bad value would otherwise be held
        // across the filter window and corrupt calibration.
        let limitAcceleration = 16 * standardGravity
        guard abs(sample.ax) <= limitAcceleration, abs(sample.ay) <= limitAcceleration, abs(sample.az) <= limitAcceleration,
              abs(sample.gx) <= 2000, abs(sample.gy) <= 2000, abs(sample.gz) <= 2000 else {
            rejectedSampleCount += 1
            return
        }
        defer { recordArrival(of: sample) }
        // Raw samples feed the diagnostics list and recordings. Angles, position, and
        // rep counting use the gyro-corrected, FFT low-passed, bias-corrected stream.
        let filtered = motionFilter.add(gyroCorrection.apply(to: sample))
        let (corrected, still) = stillnessDetector.process(filtered, filterIsWarmedUp: motionFilter.isWarmedUp)
        isCalibrating = !stillnessDetector.isLearned
        if stillnessDetector.isLearned && !positionCalculator.isCalibrated {
            // Calibration just succeeded: define "up" from the validated still period.
            positionCalculator.calibrate(gravity: stillnessDetector.learnedGravity)
            gyroIntegrator.reset()
        }
        if stillnessDetector.isLearned {
            if let update = gyroCalibrator.observe(corrected, isStill: still) {
                adoptGyroCorrection(GyroCorrection(matrix: update.matrix * gyroCorrection.matrix))
                return
            }
            gyroCalibrationStatus = gyroCalibrator.status
        }
        // At rest, treat rotation as exactly zero so angles do not creep from noise.
        let motion = still
            ? MotionSample(timestamp: corrected.timestamp, deltaTime: corrected.deltaTime,
                           ax: corrected.ax, ay: corrected.ay, az: corrected.az, gx: 0, gy: 0, gz: 0)
            : corrected
        filteredSample = motion
        isStill = still
        integratedGyroAngles = gyroIntegrator.add(motion)
        estimatedPosition = positionCalculator.add(motion, isStill: still)
        tiltCheckDegrees = positionCalculator.tiltErrorAtLastStop
        let distanceFromStart = (estimatedPosition.x * estimatedPosition.x + estimatedPosition.y * estimatedPosition.y
                                 + estimatedPosition.z * estimatedPosition.z).squareRoot()
        if positionCalculator.divergenceResets > 0 || distanceFromStart > 2.0 {
            positionWarning = "Position has diverged (\(positionCalculator.divergenceResets) speed resets, "
                + String(format: "%.1f m from start). ", distanceFromStart)
                + "The gyro and accelerometer data disagree. Do a few tilt-and-hold movements so Gyro auto-correction can fix it; if it persists, record a CSV."
        }
        verticalPosition = positionCalculator.verticalPosition
        if isCountingReps {
            updateRepCount(with: motion)
        }
    }

    /// Sample-rate bookkeeping, latest raw sample, and recording.
    private func recordArrival(of sample: MotionSample) {
        let now = Date()
        sampleCount += 1
        lastSampleDate = now
        sampleArrivalTimes.append(now)
        sampleArrivalTimes.removeAll { now.timeIntervalSince($0) > 2.0 }
        if let first = sampleArrivalTimes.first, sampleArrivalTimes.count > 1 {
            let elapsed = now.timeIntervalSince(first)
            sampleRate = elapsed > 0 ? Double(sampleArrivalTimes.count - 1) / elapsed : 0
        }
        latestSample = sample
        if isRecording {
            recordedSamples.append(sample)
            recordedSampleCount = recordedSamples.count
            if recordedSamples.count >= maximumRecordedSamples { stopRecording() }
        }
    }

    /// Applies a newly learned gyro correction, saves it, and recalibrates (hold still).
    private func adoptGyroCorrection(_ correction: GyroCorrection) {
        gyroCorrection = correction
        if let data = try? JSONEncoder().encode(correction) {
            UserDefaults.standard.set(data, forKey: Self.gyroCorrectionKey)
        }
        gyroCorrectionSummary = correction.summary
        gyroCorrectionMessage = "Gyro correction applied: \(correction.summary). Recalibrating; hold the sensor still."
        resetIntegratedAngles()
    }

    /// Runs the rep tracker on one processed sample. Only called during a workout.
    private func updateRepCount(with motion: MotionSample) {
        let updatedRepCount = repTracker.update(sample: motion, position: estimatedPosition,
                                                verticalPosition: verticalPosition, angles: integratedGyroAngles)
        if repTracker.isReadyForNextRep {
            // The counted rep's lowering has finished. Its bottom was a moment of zero
            // velocity: use it to remove drift even when the user never pauses long
            // enough to be detected as still, and start the next rep's baseline there.
            // Displayed position and angles keep their session-start origin; only the
            // rep tracker's baseline moves (re-zeroing the display made a held
            // dumbbell appear to snap back to zero).
            let restPosition = positionCalculator.correctDrift(atRestPointSecondsAgo: repTracker.secondsSinceRepBottom)
            estimatedPosition = positionCalculator.position
            verticalPosition = positionCalculator.verticalPosition
            repTracker.rebaseForNextRep(position: restPosition, verticalPosition: restPosition.z,
                                        angles: repTracker.anglesAtRepBottom)
        }
        repCount = updatedRepCount
        repTrackingProgress = repTracker.progress
    }
}

extension BLEDeviceManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: self.state = "Bluetooth ready"
            case .poweredOff: self.state = "Bluetooth is off"
            case .unauthorized: self.state = "Bluetooth permission needed"
            case .unsupported: self.state = "Bluetooth unavailable on this device"
            case .resetting: self.state = "Bluetooth is resetting"
            default: self.state = "Bluetooth state unknown"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
            guard name.localizedCaseInsensitiveContains(self.configuration.deviceNamePrefix) || self.configuration.deviceNamePrefix.isEmpty else { return }
            if !self.devices.contains(where: { $0.identifier == peripheral.identifier }) { self.devices.append(peripheral) }
            self.state = "Found \(self.devices.count) device\(self.devices.count == 1 ? "" : "s")"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in self.isConnected = true; self.usingDemo = false; self.state = "Connected · looking for motion data" }
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.isConnected = false; self.state = "Could not connect"; self.errorMessage = error?.localizedDescription }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.isConnected = false; self.state = "Device disconnected"; self.errorMessage = error?.localizedDescription }
    }
}

extension BLEDeviceManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { self.errorMessage = error.localizedDescription; return }
            let expected = self.configuration.serviceUUID.map { CBUUID(string: $0) }
            peripheral.services?.filter { expected == nil || $0.uuid == expected }.forEach {
                let characteristicFilter = self.configuration.characteristicUUID.map { [CBUUID(string: $0)] }
                peripheral.discoverCharacteristics(characteristicFilter, for: $0)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { self.errorMessage = error.localizedDescription; return }
            let expected = self.configuration.characteristicUUID.map { CBUUID(string: $0) }
            service.characteristics?.filter { expected == nil || $0.uuid == expected }.forEach { characteristic in
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    self.notifyCharacteristics.append(characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in self.parse(data) }
    }
}
