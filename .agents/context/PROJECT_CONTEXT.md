# Smart Bell project context

## Product

Smart Bell is a native iOS app for dumbbell workout tracking. An inertial sensor attached to the dumbbell streams motion data through an ESP32 over Bluetooth LE. The project currently calls the sensor BMX160 in code; confirm the exact module/model and firmware units with the team before treating that label as final.

## App layout

- `SmartBell/SmartBellApp.swift`: app entry point and shared observable managers.
- `SmartBell/ContentView.swift`: Home, Workout, Device, and History tabs and workout flow.
- `SmartBell/SensorReadingsView.swift`: temporary diagnostics tab for raw axes, recent samples, sample count/rate, and last-sample age.
- `SmartBell/Backend/BLEDeviceManager.swift`: CoreBluetooth scan/connect/notify handling and simulated sample source.
- `SmartBell/Backend/MotionAnalyzer.swift`: calibration, angular-velocity peak segmentation, rep timing, angular excursion estimate, and simple consistency cues.
- `SmartBell/Backend/Models.swift`: motion, exercise, rep, and workout data types plus BLE configuration.
- `SmartBell/Backend/WorkoutStore.swift`: local workout persistence via UserDefaults.
- `SmartBell.xcodeproj`: iOS app project. The target uses automatic code signing; each developer selects their own Team in Xcode for device deployment.

## Current BLE assumptions

The app looks for a peripheral whose name contains `SmartBell`, discovers services/notify characteristics unless UUIDs are configured, and currently decodes UTF-8 CSV in this order: `ax,ay,az,gx,gy,gz`. Assumed units are acceleration in g and angular velocity in degrees per second. The phone timestamps samples on receipt. These are placeholders, not a confirmed ESP32 protocol. Verify advertising name, GATT UUIDs, units, data framing, sample rate, timestamps, and packet ordering against the firmware.

## Current product behavior and limits

The app supports bicep curls and shoulder presses, user-entered weight, three-rep calibration, three sets with ten reps per set, a rest timer, local history, BLE status, a simulator-friendly demo stream, and the Sensor Readings tab. Rep detection currently uses repeating same-direction gyro peaks. It estimates a short-window angular excursion and compares acceleration activity and timing against calibration. This is not a drift-free 3D trajectory or validated form classifier. Do not claim accuracy or medical-grade assessment.

## Development notes

Open `SmartBell.xcodeproj` in Xcode and run the SmartBell scheme. The deployment target is iOS 26.0. The README documents the provisional packet format. Product and hardware backlog items are listed in `PROJECT_TODO.md`. Whenever source files are added or moved, update the explicit project file references and source build phase. Keep the demo path usable while firmware integration is incomplete.
