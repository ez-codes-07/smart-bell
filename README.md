# Smart Bell

Smart Bell is a native SwiftUI iOS app for dumbbell motion experiments using a BMX160 sensor connected to an ESP32 over Bluetooth Low Energy.

## Open and run

Open `SmartBell.xcodeproj` in Xcode, select the **SmartBell** scheme, choose an iPhone simulator or device, then Run. The deployment target is iOS 26. No third-party packages are required. BLE hardware use requires a physical iPhone; the **Device → Try demo sensor** option streams simulated motion data for simulator use.

## Current BLE assumptions

The Arduino sketch is at `hardware/smartbell-esp32.ino`. It targets a 100 Hz sample loop, advertises as `SmartBell`, and sends newline-terminated UTF-8 CSV notifications. The app discovers GATT services and notify/indicate characteristics automatically. The current seven-field packet is:

```text
ax,ay,az,gx,gy,gz,dt_s
```

Acceleration is in m/s², angular velocity is in degrees per second, and `dt_s` is the measured interval between sensor reads in seconds (nominally `0.010000` at 100 Hz). The app stores this value with each sample. It also accepts the older six-field packet and estimates its interval from phone arrival times. The ESP32 scheduler targets 100 Hz, but the actual interval may vary; use `dt_s` for timing calculations. The sketch uses DFRobot's `DFRobot_BMX160` Arduino library and the I²C address/pins currently set in the source; confirm these against your module and board.

The BLE service and characteristic UUIDs are defined in the Arduino sketch. The app currently discovers them automatically. If you configure UUID filtering, update `BLEConfiguration` in `SmartBell/Backend/Models.swift`.


## Motion analysis limits

Rep counting is unavailable. Sensor Readings includes experimental per-axis gyro angle integration and relative XYZ position. Position is calculated by composing Z-Y-X rotation matrices from integrated gyro rates, transforming the estimated world gravity into sensor coordinates with the rotation transpose, subtracting it from measured acceleration, rotating linear acceleration into the starting frame, and double-integrating. The estimator assumes a stationary start and uses a gyro/acceleration threshold for gravity adaptation and zero-velocity updates; this can suppress slow movement and does not eliminate drift during motion. It is a demonstration, not a dependable measured path, and needs validation against labeled recordings.

## Prototype scope

Includes bicep curls and shoulder presses, user-entered weight, demo sensor, and local workout history. Newly saved sessions show rep counts as unavailable until rep analysis is implemented. It does not prescribe weight or upload personal data. BLE protocol configuration is intentionally easy to adjust in source.
