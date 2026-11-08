import Foundation

struct MotionSample: Equatable {
    let timestamp: TimeInterval
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

enum FormCue: String {
    case ready = "Ready when you are"
    case good = "Rep matched your calibration"
    case shortRange = "Short range of motion"
    case changed = "Movement differed from calibration"
    case slow = "Rep speed changed"
    case calibrating = "Calibrating your movement…"
}

struct RepRecord: Codable, Identifiable {
    var id = UUID()
    var duration: Double
    var intensity: Double
    var range: Double
    var accelerationMotion: Double
    var cue: String
}

struct WorkoutSession: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var exercise: String
    var weight: Double
    var reps: Int
    var sets: Int
    var duration: TimeInterval
}

struct BLEConfiguration {
    // Fill these UUIDs in when the ESP32 GATT service is finalized. Nil means discover services and notify characteristics.
    var serviceUUID: String? = nil
    var characteristicUUID: String? = nil
    var deviceNamePrefix = "SmartBell"
}
