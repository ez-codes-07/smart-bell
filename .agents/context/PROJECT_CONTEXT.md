# Smart Bell project context

## Product

Smart Bell is a native iOS app for dumbbell workout tracking. An inertial sensor attached to the dumbbell streams motion data through an ESP32 over Bluetooth LE. The project currently calls the sensor BMX160 in code; confirm the exact module/model and firmware units with the team before treating that label as final.

## App layout

- `SmartBell/SmartBellApp.swift`: app entry point and shared observable managers.
- `SmartBell/ContentView.swift`: Home, Workout, Device, and History tabs and workout flow.
- `SmartBell/SensorReadingsView.swift`: temporary diagnostics tab for raw axes, recent samples, sample count/rate, and last-sample age.
- `SmartBell/Backend/BLEDeviceManager.swift`: CoreBluetooth scan/connect/notify handling and simulated sample source.
- `SmartBell/Backend/PositionCalculator.swift`: per-axis gyro display integration plus an experimental quaternion-based relative position estimator, gravity-aligned world Z, stationary accelerometer tilt correction and gravity adaptation, zero-velocity updates, and double integration.
- `SmartBell/Backend/RepTracking.swift`: exercise-specific experimental rep algorithms for bicep curls and shoulder presses. Curls use gyro-angle excursion/return because the inertial height estimate is too drift-prone; presses use a position-led stroke, angle confirmation, top reversal, and return.
- `SmartBell/Backend/Models.swift`: motion samples (including sensor delta time), exercise, and workout data types plus BLE configuration.
- `SmartBell/Backend/WorkoutStore.swift`: local workout persistence via UserDefaults.
- `SmartBell.xcodeproj`: iOS app project. The target uses automatic code signing; each developer selects their own Team in Xcode for device deployment.
- `hardware/smartbell-esp32.ino`: Arduino ESP32 firmware sketch using the DFRobot BMX160 library over I²C.

## Current BLE assumptions

The ESP32 sketch targets 100 Hz and advertises as `SmartBell`. It sends newline-delimited CSV `ax,ay,az,gx,gy,gz,dt_s`: acceleration in m/s², angular velocity in degrees per second, and measured sample interval in seconds. The app buffers newline-delimited notifications and stores `dt_s` as seconds; it retains compatibility with six-field CSV by estimating delta time from phone arrival. The target sample interval is 0.010000 s, but the transmitted value reports the measured interval. Service and characteristic UUIDs are declared in the sketch; the app discovers them unless UUID filters are configured. Verify units, I²C address/pins, library behavior, and BLE framing against the actual board and firmware.

## Current product behavior and limits

The app currently supports exercise and weight selection, local workout history, BLE status, a 100 Hz nominal demo stream, exercise-specific experimental rep counting, and Sensor Readings with raw axes, angles, and relative XYZ position. At rep completion, relative position and displayed angles are rebased for the next cycle. Position can drift within a rep; thresholds are provisional and require labeled sensor recordings. Do not claim accuracy or medical-grade assessment.

## Development notes

Open `SmartBell.xcodeproj` in Xcode and run the SmartBell scheme. The deployment target is iOS 26.0. The README documents the provisional packet format. Product and hardware backlog items are listed in `PROJECT_TODO.md`. Whenever source files are added or moved, update the explicit project file references and source build phase. Keep the demo path usable while firmware integration is incomplete.
