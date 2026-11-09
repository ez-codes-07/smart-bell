import SwiftUI

struct SensorReadingsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var recentSamples: [MotionSample] = []
    @State private var clock = Date()
    private let clockTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var latest: MotionSample? { device.latestSample }
    private var sampleAge: TimeInterval? { device.lastSampleDate.map { clock.timeIntervalSince($0) } }
    private var streamIsFresh: Bool { (sampleAge ?? .infinity) < 1.5 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Sensor Readings").font(.system(size: 29, weight: .bold, design: .rounded))
                        Text("Temporary diagnostics for checking the ESP32 motion stream.").foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Circle().fill(streamIsFresh ? .green : .gray.opacity(0.45)).frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.state).font(.headline)
                            Text(device.usingDemo ? "Demo stream" : (device.isConnected ? "ESP32 BLE stream" : "No active sensor stream"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 12) {
                        DiagnosticCard(title: "SAMPLE RATE", value: String(format: "%.1f Hz", device.sampleRate), icon: "waveform.path")
                        DiagnosticCard(title: "SAMPLES", value: "\(device.sampleCount)", icon: "number")
                    }
                    HStack(spacing: 12) {
                        DiagnosticCard(title: "LAST SAMPLE", value: ageLabel, icon: "clock")
                        DiagnosticCard(title: "ACCEL MAG", value: latest.map { String(format: "%.2f m/s²", $0.accelerationMagnitude) } ?? "—", icon: "move.3d")
                    }

                    if let sample = latest {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("LATEST SAMPLE").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                            Text("Accelerometer · m/s²").font(.subheadline.weight(.semibold))
                            AxisReading(label: "X", value: sample.ax, unit: "m/s²", scale: 20)
                            AxisReading(label: "Y", value: sample.ay, unit: "m/s²", scale: 20)
                            AxisReading(label: "Z", value: sample.az, unit: "m/s²", scale: 20)
                            Divider().padding(.vertical, 2)
                            Text("Gyroscope · °/s").font(.subheadline.weight(.semibold))
                            AxisReading(label: "X", value: sample.gx, unit: "°/s", scale: 250)
                            AxisReading(label: "Y", value: sample.gy, unit: "°/s", scale: 250)
                            AxisReading(label: "Z", value: sample.gz, unit: "°/s", scale: 250)
                        }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 17))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Waiting for sensor samples").font(.headline)
                            Text("Connect to the ESP32 or start Demo mode from the Device tab. Once data arrives, the raw axes will appear here.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 17))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("RECENT SAMPLES").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                        if recentSamples.isEmpty {
                            Text("No samples received yet.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                        } else {
                            ForEach(Array(recentSamples.enumerated()), id: \.offset) { index, sample in
                                HStack(spacing: 8) {
                                    Text(String(format: "%02d", device.sampleCount - index)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                                    Text(String(format: "A (m/s²)  %+.2f  %+.2f  %+.2f", sample.ax, sample.ay, sample.az)).foregroundStyle(Palette.green)
                                    Text(String(format: "Gyro (°/s)  %+.0f  %+.0f  %+.0f", sample.gx, sample.gy, sample.gz)).foregroundStyle(Palette.ink)
                                }.font(.system(size: 11, weight: .medium, design: .monospaced))
                                if index < recentSamples.count - 1 { Divider() }
                            }
                        }
                    }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 17))

                    Text("Axis and rate values are raw diagnostics. Check firmware units and packet mapping before interpreting them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Palette.paper).navigationTitle("Sensor Readings").navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: device.latestSample) { _, sample in
            guard let sample else { return }
            recentSamples.insert(sample, at: 0)
            if recentSamples.count > 12 { recentSamples.removeLast(recentSamples.count - 12) }
        }
        .onReceive(clockTimer) { clock = $0 }
    }

    private var ageLabel: String {
        guard let age = sampleAge else { return "—" }
        return age < 1 ? String(format: "%.0f ms", age * 1000) : String(format: "%.1f s", age)
    }
}

private struct DiagnosticCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: icon).foregroundStyle(Palette.green)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).minimumScaleFactor(0.75).lineLimit(1)
            Text(title).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 92, alignment: .leading).padding(15).background(.white, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct AxisReading: View {
    let label: String
    let value: Double
    let unit: String
    let scale: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 14)
            GeometryReader { proxy in
                let width = proxy.size.width
                let extent = min(abs(value) / scale, 1) * width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.06))
                    Rectangle().fill(Color.gray.opacity(0.25)).frame(width: 1).offset(x: width / 2)
                    Capsule().fill(Palette.green).frame(width: max(3, extent), height: 8)
                        .offset(x: value < 0 ? width / 2 - extent : width / 2)
                }
            }.frame(height: 12)
            Text(String(format: "%+.2f %@", value, unit)).font(.caption.monospacedDigit()).frame(width: 84, alignment: .trailing)
        }
    }
}
