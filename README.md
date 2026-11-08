# Smart Bell

Smart Bell is a native SwiftUI iOS app for tracking dumbbell repetitions using a Bosch BMI160 inertial sensor connected to an ESP32 over Bluetooth Low Energy.

## Open and run

Open `SmartBell.xcodeproj` in Xcode, select the **SmartBell** scheme, choose an iPhone simulator or device, then Run. The deployment target is iOS 17. No third-party packages are required. BLE hardware use requires a physical iPhone; the **Device → Try demo sensor** option streams simulated motion data for simulator use.

## Current BLE assumptions

The ESP32 should advertise a local name containing `SmartBell`. The app discovers GATT services and notify/indicate characteristics automatically. The default sample decoder expects UTF-8 text rows containing six comma-separated values:

```text
ax,ay,az,gx,gy,gz
```

Acceleration is in g; angular velocity is in degrees per second. The phone timestamps each received sample. Update `BLEConfiguration` in `SmartBell/Backend/Models.swift` with service and characteristic UUIDs when finalized, and adapt `parse(_:)` in `SmartBell/Backend/BLEDeviceManager.swift` for the actual packet encoding, units, and timestamps. The ESP32 should send reasonably frequent samples (about 50 Hz or higher) and notify the app.

## Motion analysis limits

The current prototype detects same-direction angular-velocity peaks and compares short-window integrated gyro angular excursion, acceleration activity, and rep duration against three calibration reps. The workout view shows the angular excursion estimate in degrees. This is a relative movement signature, not a drift-free 3D dumbbell trajectory or medical form assessment. Integrating IMU acceleration to estimate position drifts quickly; reliable path/form classification needs real sensor recordings, known mounting orientation, exercise-specific signal processing, and validation against labeled movements.

## Prototype scope

Includes bicep curls and shoulder presses, user-entered weight, guided calibration, rep/set tracking, rest timer, demo sensor, and local workout history. It does not prescribe weight or upload personal data. BLE protocol configuration and algorithm thresholds are intentionally easy to adjust in source.
