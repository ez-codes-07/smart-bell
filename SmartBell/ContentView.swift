import SwiftUI
import CoreBluetooth
import AudioToolbox
import UIKit

struct SmartBellRootView: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            WorkoutView().tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
            DeviceView().tabItem { Label("Device", systemImage: "dot.radiowaves.left.and.right") }
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }.tint(Color(red: 0.12, green: 0.35, blue: 0.28))
    }
}

private enum Palette {
    static let ink = Color(red: 0.10, green: 0.16, blue: 0.14)
    static let green = Color(red: 0.12, green: 0.35, blue: 0.28)
    static let mint = Color(red: 0.84, green: 0.93, blue: 0.88)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.94)
}

struct HomeView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @EnvironmentObject private var store: WorkoutStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SMART BELL").font(.caption.weight(.bold)).tracking(2).foregroundStyle(Palette.green)
                        Text("Train with\nmore awareness.").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                        Text("Track your reps and movement with your smart dumbbell.").font(.body).foregroundStyle(.secondary)
                    }.padding(.top, 16)
                    HStack(spacing: 12) {
                        MetricCard(title: "WORKOUTS", value: "\(store.sessions.count)", icon: "calendar")
                        MetricCard(title: "TOTAL REPS", value: "\(store.sessions.reduce(0) { $0 + $1.reps })", icon: "repeat")
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("SMART BELL DEVICE").font(.caption.weight(.bold)).tracking(1.2)
                            Text(device.state).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(device.isConnected ? .green : .gray.opacity(0.4)).frame(width: 12, height: 12)
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECENT WORKOUTS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                        if store.sessions.isEmpty {
                            Text("Your completed workouts will appear here.").foregroundStyle(.secondary).padding(.vertical, 16)
                        } else {
                            ForEach(store.sessions.prefix(3)) { session in SessionRow(session: session) }
                        }
                    }
                }.padding(20)
            }.background(Palette.paper).navigationTitle("Smart Bell").navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MetricCard: View {
    let title: String; let value: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).foregroundStyle(Palette.green)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(title).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct WorkoutView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @EnvironmentObject private var store: WorkoutStore
    @State private var exercise: Exercise = .bicepCurl
    @State private var weight = "10"
    @State private var analyzer = MotionAnalyzer()
    @State private var phase: WorkoutPhase = .setup
    @State private var sessionStart: Date?
    @State private var savedMessage = false
    @State private var setNumber = 1
    @State private var setReps = 0
    @State private var restSeconds = 60
    @State private var soundEnabled = UserDefaults.standard.object(forKey: "smartbell.sound") as? Bool ?? true
    @State private var hapticsEnabled = UserDefaults.standard.object(forKey: "smartbell.haptics") as? Bool ?? true

    private let targetSets = 3
    private let targetReps = 10
    private let restTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .setup: setupPanel
                    case .calibration: calibrationPanel
                    case .active, .rest: activePanel
                    case .finished: finishedPanel
                    }
                }.padding(20)
            }.background(Palette.paper).navigationTitle("Workout")
        }
        .onChange(of: device.latestSample) { _, sample in
            guard let sample else { return }
            switch phase {
            case .calibration:
                analyzer.process(sample, calibrating: true)
            case .active:
                let prior = analyzer.repCount
                analyzer.process(sample, calibrating: false)
                if analyzer.repCount > prior {
                    setReps += 1
                    if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    if soundEnabled { AudioServicesPlaySystemSound(1104) }
                    if setReps >= targetReps { phase = setNumber >= targetSets ? .finished : .rest; restSeconds = 60 }
                }
            default: break
            }
        }
        .onReceive(restTimer) { _ in if phase == .rest && restSeconds > 0 { restSeconds -= 1 } }
        .alert("Workout saved", isPresented: $savedMessage) { Button("Done", role: .cancel) {} }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Let’s get set up").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Choose the movement and enter the dumbbell weight.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                Text("EXERCISE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                ForEach(Exercise.allCases) { item in
                    Button { exercise = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol).font(.title2).frame(width: 35).foregroundStyle(Palette.green)
                            Text(item.rawValue).font(.headline).foregroundStyle(Palette.ink)
                            Spacer()
                            if exercise == item { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                        }.padding(16).background(exercise == item ? Palette.mint : .white, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("DUMBBELL WEIGHT (KG)").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                TextField("e.g. 10", text: $weight).keyboardType(.decimalPad).font(.title2.weight(.semibold)).padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            if !device.isConnected {
                HStack(spacing: 8) { Image(systemName: "info.circle"); Text("Connect your Smart Bell or use Demo mode on the Device tab.") }.font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                analyzer.beginCalibration(); setNumber = 1; setReps = 0; sessionStart = nil; phase = .calibration
            } label: { Label("Calibrate movement", systemImage: "scope").frame(maxWidth: .infinity).padding(17) }
                .buttonStyle(.borderedProminent).tint(Palette.green).font(.headline).disabled(!device.isConnected || Double(weight) == nil)
            VStack(alignment: .leading, spacing: 12) {
                Text("FEEDBACK").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Toggle("Rep sound", isOn: $soundEnabled).onChange(of: soundEnabled) { _, v in UserDefaults.standard.set(v, forKey: "smartbell.sound") }
                Toggle("Haptic feedback", isOn: $hapticsEnabled).onChange(of: hapticsEnabled) { _, v in UserDefaults.standard.set(v, forKey: "smartbell.haptics") }
            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate your movement").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Secure the sensor to the dumbbell. Hold it still, then perform three slow, controlled reps of your selected exercise.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Sensor attached firmly", systemImage: "checkmark.circle.fill")
                Label("Start from a comfortable position", systemImage: "figure.stand")
                Label("Move at a steady, controlled pace", systemImage: "metronome")
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(min(analyzer.calibrationProgress, 3))").font(.system(size: 44, weight: .bold, design: .rounded))
                Text("/ 3 calibration reps").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(analyzer.calibrationProgress, 3)), total: 3).tint(Palette.green)
            if analyzer.isCalibrated {
                Label("Calibration complete", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.green).font(.headline)
                Button("Start workout") { sessionStart = Date(); phase = .active }.buttonStyle(.borderedProminent).tint(Palette.green)
            } else {
                Text("Waiting for movement…").foregroundStyle(.secondary)
                Button("Cancel") { analyzer.reset(); phase = .setup }.buttonStyle(.bordered)
            }
            dataCard
        }
    }

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(exercise.rawValue).font(.title2.bold()); Spacer(); Text("SET \(setNumber) OF \(targetSets)").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Palette.green) }
            if phase == .rest {
                VStack(spacing: 8) {
                    Text("REST").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                    Text("\(restSeconds / 60):\(String(format: "%02d", restSeconds % 60))").font(.system(size: 52, weight: .bold, design: .rounded))
                    Button("Start next set") { setNumber += 1; setReps = 0; phase = .active }
                        .buttonStyle(.borderedProminent).tint(Palette.green).disabled(restSeconds > 0)
                }.frame(maxWidth: .infinity).padding(22).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
            HStack(spacing: 12) {
                MetricCard(title: "REPS", value: "\(setReps) / \(targetReps)", icon: "repeat")
                MetricCard(title: "WEIGHT KG", value: weight, icon: "dumbbell.fill")
            }
            HStack(spacing: 12) {
                MetricCard(title: "REP SPEED", value: analyzer.lastRep.map { String(format: "%.1fs", $0.duration) } ?? "—", icon: "speedometer")
                MetricCard(title: "GYRO °/S", value: String(format: "%.0f", analyzer.latestAngularSpeed), icon: "gyroscope")
            }
            HStack(spacing: 12) {
                MetricCard(title: "PATH EXCURSION", value: analyzer.lastRep.map { String(format: "%.0f°", $0.range) } ?? "—", icon: "point.topleft.down.to.point.bottomright.curvepath")
                MetricCard(title: "ACCEL MOTION", value: analyzer.lastRep.map { String(format: "%.2f", $0.accelerationMotion) } ?? "—", icon: "waveform.path")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("MOVEMENT CHECK").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Text(analyzer.cue.rawValue).font(.title3.weight(.semibold)).foregroundStyle(Palette.green)
                Text("Compares movement with your calibration. This is an estimate, not a medical form assessment.").font(.footnote).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint, in: RoundedRectangle(cornerRadius: 16))
            dataCard
            Button("Finish and save workout") { finishWorkout() }.buttonStyle(.bordered).tint(.red)
        }
    }

    private var finishedPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Palette.green)
            Text("Workout complete").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("\(analyzer.repCount) reps · \(exercise.rawValue) · \(weight) kg").foregroundStyle(.secondary)
            Button("Save workout") { finishWorkout(); phase = .setup }.buttonStyle(.borderedProminent).tint(Palette.green)
            Button("Discard") { analyzer.reset(); phase = .setup }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Circle().fill(device.isConnected ? .green : .red).frame(width: 8, height: 8); Text(device.state).font(.subheadline.weight(.semibold)) }
            if let s = device.latestSample {
                Text(String(format: "Accel  %.2f  %.2f  %.2f g", s.ax, s.ay, s.az)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(String(format: "Gyro   %.1f  %.1f  %.1f °/s", s.gx, s.gy, s.gz)).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else { Text("Waiting for sensor samples").font(.caption).foregroundStyle(.secondary) }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
    }

    private func finishWorkout() {
        guard let start = sessionStart else { return }
        let session = WorkoutSession(date: Date(), exercise: exercise.rawValue, weight: Double(weight) ?? 0,
                                     reps: analyzer.repCount, sets: max(setNumber, 1), duration: Date().timeIntervalSince(start))
        store.save(session); sessionStart = nil; savedMessage = true
        analyzer.reset()
    }
}

private enum WorkoutPhase { case setup, calibration, active, rest, finished }

struct DeviceView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Connect your sensor").font(.system(size: 29, weight: .bold, design: .rounded))
                    Text("Turn on the ESP32 and make sure it is advertising over Bluetooth.").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Image(systemName: device.isConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(device.isConnected ? .green : Palette.green)
                        VStack(alignment: .leading, spacing: 3) { Text(device.state).font(.headline); Text(device.usingDemo ? "Simulated sensor stream" : "BMI160 motion sensor over ESP32 BLE").font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    if device.isConnected && !device.usingDemo {
                        Button("Disconnect", role: .destructive) { device.disconnect() }.buttonStyle(.bordered)
                    } else {
                        Button { device.scan() } label: { Label("Scan for Smart Bell", systemImage: "magnifyingglass").frame(maxWidth: .infinity).padding(15) }.buttonStyle(.borderedProminent).tint(Palette.green)
                        Button { device.startDemo() } label: { Label("Try demo sensor", systemImage: "play.fill").frame(maxWidth: .infinity).padding(15) }.buttonStyle(.bordered)
                    }
                    if !device.devices.isEmpty {
                        Text("AVAILABLE DEVICES").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                        ForEach(device.devices, id: \.identifier) { peripheral in
                            Button { device.connect(peripheral) } label: {
                                HStack { Image(systemName: "dumbbell.fill"); Text(peripheral.name ?? "Smart Bell"); Spacer(); Image(systemName: "chevron.right") }
                                    .padding(16).foregroundStyle(Palette.ink).background(.white, in: RoundedRectangle(cornerRadius: 13))
                            }
                        }
                    }
                    if let sample = device.latestSample {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("LIVE SENSOR DATA").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                            Text(String(format: "Acceleration  %.3f, %.3f, %.3f g", sample.ax, sample.ay, sample.az)).font(.caption.monospaced())
                            Text(String(format: "Gyroscope  %.1f, %.1f, %.1f °/s", sample.gx, sample.gy, sample.gz)).font(.caption.monospaced())
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
                    }
                    Text("BLE packet setup").font(.headline)
                    Text("The default decoder expects newline-delimited UTF-8 CSV: ax,ay,az,gx,gy,gz (g and degrees per second). Service and characteristic UUIDs are discovered automatically. Update BLEConfiguration and the packet decoder to match your ESP32 firmware.").font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Palette.paper).navigationTitle("Device")
                .alert("Bluetooth issue", isPresented: Binding(get: { device.errorMessage != nil }, set: { if !$0 { device.errorMessage = nil } })) {
                    Button("OK", role: .cancel) { device.errorMessage = nil }
                } message: { Text(device.errorMessage ?? "") }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: WorkoutStore
    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No workouts yet", systemImage: "figure.strengthtraining.traditional", description: Text("Finish a Smart Bell workout and it will be saved here."))
                } else {
                    List(store.sessions) { session in SessionRow(session: session).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                        .listStyle(.plain)
                }
            }.background(Palette.paper).navigationTitle("History")
        }
    }
}

private struct SessionRow: View {
    let session: WorkoutSession
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.strengthtraining.traditional").font(.title2).foregroundStyle(Palette.green).frame(width: 44, height: 44).background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(session.exercise).font(.headline)
                Text(session.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text("\(session.sets) sets · \(Int(session.duration / 60)) min").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) { Text("\(session.reps) reps").font(.subheadline.bold()); Text("\(session.weight.formatted()) kg").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 15))
    }
}
