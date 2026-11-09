import SwiftUI
import CoreBluetooth

struct SmartBellRootView: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            WorkoutView().tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
            SensorReadingsView().tabItem { Label("Sensor Readings", systemImage: "waveform.path.ecg") }
            DeviceView().tabItem { Label("Device", systemImage: "dot.radiowaves.left.and.right") }
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }.tint(Color(red: 0.12, green: 0.35, blue: 0.28))
    }
}

enum Palette {
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
                        MetricCard(title: "TOTAL REPS", value: store.sessions.compactMap(\.reps).isEmpty ? "—" : "\(store.sessions.compactMap(\.reps).reduce(0, +))", icon: "repeat")
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
    @State private var phase: WorkoutPhase = .setup
    @State private var sessionStart: Date?
    @State private var savedMessage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .setup: setupPanel
                    case .active: activePanel
                    }
                }.padding(20)
            }.background(Palette.paper).navigationTitle("Workout")
        }
        .alert("Workout saved", isPresented: $savedMessage) { Button("Done", role: .cancel) {} }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Let’s get set up").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Choose the movement and enter the dumbbell weight. Rep counting and position analysis are being rebuilt.").foregroundStyle(.secondary)
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
                sessionStart = Date(); phase = .active
            } label: { Label("Start workout", systemImage: "play.fill").frame(maxWidth: .infinity).padding(17) }
                .buttonStyle(.borderedProminent).tint(Palette.green).font(.headline).disabled(!device.isConnected || Double(weight) == nil)
        }
    }

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(exercise.rawValue).font(.title2.bold())
            HStack(spacing: 12) {
                MetricCard(title: "REP COUNT", value: "Unavailable", icon: "repeat")
                MetricCard(title: "WEIGHT KG", value: weight, icon: "dumbbell.fill")
            }
            Text("Rep counting and position-path analysis are not currently active.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 15))
            dataCard
            Button("Finish and save workout") { finishWorkout(); phase = .setup }.buttonStyle(.bordered).tint(.red)
            Button("Discard workout") { sessionStart = nil; phase = .setup }.buttonStyle(.bordered)
        }
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Circle().fill(device.isConnected ? .green : .red).frame(width: 8, height: 8); Text(device.state).font(.subheadline.weight(.semibold)) }
            if let s = device.latestSample {
                Text(String(format: "Accel  %.2f  %.2f  %.2f m/s²", s.ax, s.ay, s.az)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(String(format: "Gyro   %.1f  %.1f  %.1f °/s", s.gx, s.gy, s.gz)).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else { Text("Waiting for sensor samples").font(.caption).foregroundStyle(.secondary) }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
    }

    private func finishWorkout() {
        guard let start = sessionStart else { return }
        let session = WorkoutSession(date: Date(), exercise: exercise.rawValue, weight: Double(weight) ?? 0,
                                     reps: nil, sets: 1, duration: Date().timeIntervalSince(start))
        store.save(session); sessionStart = nil; savedMessage = true
    }
}

private enum WorkoutPhase { case setup, active }

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
                        VStack(alignment: .leading, spacing: 3) { Text(device.state).font(.headline); Text(device.usingDemo ? "Simulated sensor stream" : "BMX160 motion sensor over ESP32 BLE").font(.subheadline).foregroundStyle(.secondary) }
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
                            Text(String(format: "Acceleration  %.2f, %.2f, %.2f m/s²", sample.ax, sample.ay, sample.az)).font(.caption.monospaced())
                            Text(String(format: "Gyroscope  %.1f, %.1f, %.1f °/s", sample.gx, sample.gy, sample.gz)).font(.caption.monospaced())
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
                    }
                    Text("BLE packet setup").font(.headline)
                    Text("The decoder accepts newline-delimited UTF-8 CSV: ax,ay,az,gx,gy,gz,dt_s. Acceleration is in m/s², angular velocity is in degrees per second, and dt_s is the measured interval in seconds. Service and characteristic UUIDs are discovered automatically. Update BLEConfiguration and the packet decoder if your ESP32 firmware differs.").font(.footnote).foregroundStyle(.secondary)
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
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.reps.map { "\($0) reps" } ?? "Reps unavailable").font(.subheadline.bold())
                Text("\(session.weight.formatted()) kg").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 15))
    }
}
