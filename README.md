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

Rep counting is experimental and implemented in `SmartBell/Backend/RepTracking.swift`. Bicep curls use gyro-angle excursion and return because inertial height is too drift-prone to gate curl counting; shoulder presses use a position-led press, require angle excursion, detect the top reversal, and count on the controlled return. After a detected rep return, the app rebases relative position and displayed angles for the next cycle. Thresholds and timing limits are configurable per exercise and need tuning against labeled recordings from the actual sensor mounting. Sensor Readings shows experimental relative XYZ position, estimated by integrating gyro rates as a quaternion, applying stationary accelerometer tilt correction, rotating acceleration, subtracting gravity, and double-integrating. World Z is aligned to the initial gravity direction. Position can drift significantly within a rep; a large or implausible height reading means the estimate has diverged, not that the dumbbell traveled that distance.

## Prototype scope

Includes bicep curls and shoulder presses, user-entered weight, demo sensor, and local workout history. Newly saved sessions show rep counts as unavailable until rep analysis is implemented. It does not prescribe weight or upload personal data. BLE protocol configuration is intentionally easy to adjust in source.
