import Foundation

struct MotionSample: Equatable {
    let timestamp: TimeInterval
    /// Sensor sampling interval in seconds. The hardware CSV sends this as dt_s.
    let deltaTime: TimeInterval
    let ax: Double, ay: Double, az: Double
    let gx: Double, gy: Double, gz: Double

    var accelerationMagnitude: Double { sqrt(ax * ax + ay * ay + az * az) }
    var gyroMagnitude: Double { sqrt(gx * gx + gy * gy + gz * gz) }
}

enum Exercise: String, CaseIterable, Identifiable, Codable {
    case bicepCurl = "Bicep curl"
    case shoulderPress = "Shoulder press"
    var id: String { rawValue }
    var symbol: String { self == .bicepCurl ? "figure.strengthtraining.traditional" : "figure.arms.open" }
}

struct WorkoutSession: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var exercise: String
    var weight: Double
    var reps: Int?
    var sets: Int
    var duration: TimeInterval
}

struct BLEConfiguration {
    // Fill these UUIDs in when the ESP32 GATT service is finalized. Nil means discover services and notify characteristics.
    var serviceUUID: String? = nil
    var characteristicUUID: String? = nil
    var deviceNamePrefix = "SmartBell"
}
