import Foundation
import Combine
import CoreBluetooth

@MainActor
final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var state = "Bluetooth is off"
    @Published private(set) var devices: [CBPeripheral] = []
    @Published private(set) var isConnected = false
    @Published private(set) var latestSample: MotionSample?
    @Published private(set) var usingDemo = false
    @Published var errorMessage: String?

    private let configuration = BLEConfiguration()
    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var demoTimer: Timer?
    private var demoClock = 0.0
    private var demoPhase = 0.0

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
        usingDemo = true
        isConnected = true
        state = "Demo sensor connected"
        demoClock = Date.timeIntervalSinceReferenceDate
        demoPhase = 0
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitDemoSample() }
        }
    }

    func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil
        if usingDemo { usingDemo = false; isConnected = false; state = "Disconnected" }
    }

    private func emitDemoSample() {
        let now = Date.timeIntervalSinceReferenceDate
        let t = now - demoClock
        // Smooth, exercise-like cycles with gravity direction changing over each repetition.
        demoPhase += 0.025 * 2 * .pi / 2.4
        let phase = demoPhase.truncatingRemainder(dividingBy: 2 * .pi)
        let envelope = max(0, sin(phase))
        let sample = MotionSample(timestamp: t, ax: 0.18 * sin(phase), ay: 0.10 * cos(phase), az: 1.0 - 0.50 * envelope,
                                  gx: 0, gy: 115 * cos(phase), gz: 5 * sin(phase))
        latestSample = sample
    }

    private func parse(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        // Default demo firmware contract: one UTF-8 CSV row `ax,ay,az,gx,gy,gz` (g and degrees/sec).
        // Timestamp is supplied by the phone on receipt. Replace this decoder for binary packets as needed.
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count >= 6, let ax = Double(parts[0]), let ay = Double(parts[1]), let az = Double(parts[2]),
              let gx = Double(parts[3]), let gy = Double(parts[4]), let gz = Double(parts[5]) else { return }
        latestSample = MotionSample(timestamp: Date.timeIntervalSinceReferenceDate, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz)
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
