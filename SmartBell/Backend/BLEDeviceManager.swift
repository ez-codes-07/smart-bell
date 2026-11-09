import Foundation
import Combine
import CoreBluetooth

@MainActor
final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var state = "Bluetooth is off"
    @Published private(set) var devices: [CBPeripheral] = []
    @Published private(set) var isConnected = false
    @Published private(set) var latestSample: MotionSample?
    @Published private(set) var integratedGyroAngles = IntegratedGyroAngles()
    @Published private(set) var estimatedPosition = PositionEstimate()
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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
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

    private func resetIntegratedAngles() {
        gyroIntegrator.reset()
        integratedGyroAngles = gyroIntegrator.angles
        positionCalculator.reset()
        estimatedPosition = positionCalculator.position
    }

    private func emitDemoSample() {
        let now = Date.timeIntervalSinceReferenceDate
        let t = now - demoClock
        // Smooth, exercise-like cycles with gravity direction changing over each repetition.
        demoPhase += 0.01 * 2 * .pi / 2.4
        let phase = demoPhase.truncatingRemainder(dividingBy: 2 * .pi)
        let envelope = max(0, sin(phase))
        let sample = MotionSample(timestamp: t, deltaTime: 0.01, ax: 0.18 * sin(phase) * standardGravity, ay: 0.10 * cos(phase) * standardGravity, az: (1.0 - 0.50 * envelope) * standardGravity,
                                  gx: 0, gy: 115 * cos(phase), gz: 5 * sin(phase))
        publish(sample)
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
        integratedGyroAngles = gyroIntegrator.add(sample)
        estimatedPosition = positionCalculator.add(sample)
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
