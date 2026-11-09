import SwiftUI

struct SensorReadingsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var recentSamples: [MotionSample] = []
    @State private var positionTrail: [PositionEstimate] = []
    @State private var clock = Date()

    private var latest: MotionSample? { device.latestSample }
    private var sampleAge: TimeInterval? { device.lastSampleDate.map { clock.timeIntervalSince($0) } }
    private var streamIsFresh: Bool { (sampleAge ?? .infinity) < 1.5 }

    var body: some View {
        NavigationStack {
            ScrollView { contentSections.padding(20) }
                .background(Palette.paper)
                .navigationTitle("Sensor Readings")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: device.latestSample) { _, sample in
            guard let sample else { return }
            recentSamples.insert(sample, at: 0)
            if recentSamples.count > 12 { recentSamples.removeLast(recentSamples.count - 12) }
        }
        .onChange(of: device.estimatedPosition) { _, position in
            if positionTrail.isEmpty {
                positionTrail.append(PositionEstimate())
            }
            positionTrail.append(position)
            if positionTrail.count > 600 {
                positionTrail.removeFirst(positionTrail.count - 600)
            }
        }
        .onChange(of: device.state) { _, state in
            if state.hasPrefix("Connecting") || state == "Demo sensor connected" {
                positionTrail.removeAll(keepingCapacity: true)
            }
        }
        .task {
            while !Task.isCancelled {
                clock = Date()
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    break
                }
            }
        }
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleSection
            connectionSection
            summarySection
            latestSection
            recentSamplesSection
            Text("Axis and rate values are raw diagnostics. Check firmware units and packet mapping before interpreting them.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sensor Readings").font(.system(size: 29, weight: .bold, design: .rounded))
            Text("Temporary diagnostics for checking the ESP32 motion stream.").foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        HStack(spacing: 12) {
            Circle().fill(streamIsFresh ? .green : .gray.opacity(0.45)).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.state).font(.headline)
                Text(device.usingDemo ? "Demo stream" : (device.isConnected ? "ESP32 BLE stream" : "No active sensor stream"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var summarySection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DiagnosticCard(title: "SAMPLE RATE", value: String(format: "%.1f Hz", device.sampleRate), icon: "waveform.path")
                DiagnosticCard(title: "SAMPLES", value: "\(device.sampleCount)", icon: "number")
            }
            HStack(spacing: 12) {
                DiagnosticCard(title: "LAST SAMPLE", value: ageLabel, icon: "clock")
                DiagnosticCard(title: "ACCEL MAG", value: latest.map { String(format: "%.2f m/s²", $0.accelerationMagnitude) } ?? "—", icon: "move.3d")
            }
            HStack(spacing: 12) {
                DiagnosticCard(title: "SENSOR ΔT", value: deltaTimeLabel, icon: "timer")
                DiagnosticCard(title: "GYRO MAG", value: latest.map { String(format: "%.1f °/s", $0.gyroMagnitude) } ?? "—", icon: "gyroscope")
            }
        }
    }

    @ViewBuilder
    private var latestSection: some View {
        if let sample = latest {
            latestSampleCard(sample)
        } else {
            waitingCard
        }
    }

    private func latestSampleCard(_ sample: MotionSample) -> some View {
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
            gyroAnglesSection
            positionSection(sample)
        }
        .padding(17).background(.white, in: RoundedRectangle(cornerRadius: 17))
    }

    private var gyroAnglesSection: some View {
        Group {
            Divider().padding(.vertical, 2)
            Text("INTEGRATED GYRO ANGLES · RELATIVE")
                .font(.caption.weight(.bold)).tracking(1.0).foregroundStyle(.secondary)
            AxisAngleReading(label: "X", value: device.integratedGyroAngles.x)
            AxisAngleReading(label: "Y", value: device.integratedGyroAngles.y)
            AxisAngleReading(label: "Z", value: device.integratedGyroAngles.z)
            Text("Calculated by integrating gyro rate over each sample interval. Small gyro bias accumulates as drift, so these are not reliable absolute orientation angles.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func positionSection(_ sample: MotionSample) -> some View {
        Group {
            Divider().padding(.vertical, 2)
            Text("ESTIMATED POSITION · RELATIVE TO START")
                .font(.caption.weight(.bold)).tracking(1.0).foregroundStyle(.secondary)
            PositionAxisReading(label: "X", value: device.estimatedPosition.x)
            PositionAxisReading(label: "Y", value: device.estimatedPosition.y)
            PositionAxisReading(label: "Z", value: device.estimatedPosition.z)
            InteractivePositionPlot(points: positionTrail)
            Text("Experimental double integration with stationary gravity correction and zero-velocity updates. Slow movement may be treated as still, and position estimates can still drift.")
                .font(.caption).foregroundStyle(.secondary)
            Text(String(format: "Sample interval Δt · %.6f s", sample.deltaTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for sensor samples").font(.headline)
            Text("Connect to the ESP32 or start Demo mode from the Device tab. Once data arrives, the raw axes will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }

    private var recentSamplesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT SAMPLES").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            if recentSamples.isEmpty {
                Text("No samples received yet.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(Array(recentSamples.enumerated()), id: \.offset) { index, sample in
                    recentSampleRow(index: index, sample: sample)
                    if index < recentSamples.count - 1 { Divider() }
                }
            }
        }
        .padding(17).background(.white, in: RoundedRectangle(cornerRadius: 17))
    }

    private func recentSampleRow(index: Int, sample: MotionSample) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", device.sampleCount - index))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Text(String(format: "ACC m/s² · X:%+.2f Y:%+.2f Z:%+.2f", sample.ax, sample.ay, sample.az))
                .foregroundStyle(Palette.green)
            Text(String(format: "GYRO °/s · X:%+.0f Y:%+.0f Z:%+.0f", sample.gx, sample.gy, sample.gz))
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    private var ageLabel: String {
        guard let age = sampleAge else { return "—" }
        return age < 1 ? String(format: "%.0f ms", age * 1000) : String(format: "%.1f s", age)
    }

    private var deltaTimeLabel: String {
        guard let sample = latest else { return "—" }
        return String(format: "%.6f s", sample.deltaTime)
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

private struct AxisAngleReading: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text("\(label) angle").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.2f°", value))
                .font(.system(.body, design: .monospaced).weight(.semibold))
        }
    }
}

private struct PositionAxisReading: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text("\(label) position").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.4f m", value))
                .font(.system(.body, design: .monospaced).weight(.semibold))
        }
    }
}

private struct InteractivePositionPlot: View {
    let points: [PositionEstimate]
    @State private var azimuth = -Double.pi / 4
    @State private var elevation = Double.pi / 6
    @State private var dragStartAzimuth = -Double.pi / 4
    @State private var dragStartElevation = Double.pi / 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxCoordinate = points.reduce(0.05) { current, point in
                    max(current, max(abs(point.x), max(abs(point.y), abs(point.z))))
                }
                let scale = min(size.width, size.height) * 0.34 / (maxCoordinate * 1.55)

                func project(_ point: PositionEstimate) -> CGPoint {
                    let horizontalX = cos(azimuth) * point.x - sin(azimuth) * point.y
                    let horizontalY = sin(azimuth) * point.x + cos(azimuth) * point.y
                    let vertical = cos(elevation) * point.z - sin(elevation) * horizontalY
                    return CGPoint(x: center.x + horizontalX * scale,
                                   y: center.y - vertical * scale)
                }

                let axisLength = maxCoordinate * 0.8
                let origin = project(PositionEstimate())
                let axes: [(String, PositionEstimate, Color)] = [
                    ("X", PositionEstimate(x: axisLength), .red),
                    ("Y", PositionEstimate(y: axisLength), .green),
                    ("Z", PositionEstimate(z: axisLength), .blue)
                ]
                for (label, endpoint, color) in axes {
                    let end = project(endpoint)
                    var axis = Path()
                    axis.move(to: origin)
                    axis.addLine(to: end)
                    context.stroke(axis, with: .color(color.opacity(0.75)), lineWidth: 1.5)
                    context.draw(Text(label).font(.caption.bold()).foregroundColor(color),
                                 at: CGPoint(x: end.x + 8, y: end.y))
                }

                if points.count > 1 {
                    var path = Path()
                    path.move(to: project(points[0]))
                    for point in points.dropFirst() {
                        path.addLine(to: project(point))
                    }
                    context.stroke(path, with: .color(Palette.green),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if let current = points.last {
                    let point = project(current)
                    let marker = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    context.fill(marker, with: .color(Palette.ink))
                }
            }
            .frame(height: 230)
            .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        azimuth = dragStartAzimuth + value.translation.width * 0.01
                        elevation = min(max(dragStartElevation + value.translation.height * 0.01,
                                            -Double.pi / 2.5), Double.pi / 2.5)
                    }
                    .onEnded { _ in
                        dragStartAzimuth = azimuth
                        dragStartElevation = elevation
                    }
            )

            HStack {
                Text("Drag to rotate · X red · Y green · Z blue")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    azimuth = -Double.pi / 4
                    elevation = Double.pi / 6
                    dragStartAzimuth = azimuth
                    dragStartElevation = elevation
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
                .accessibilityLabel("Reset plot view")
            }
        }
    }
}
