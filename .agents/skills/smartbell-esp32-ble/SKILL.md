---
name: smartbell-esp32-ble
description: Integrate or debug the Smart Bell ESP32 Bluetooth Low Energy connection and BMI160 sensor packet decoder.
---

# Smart Bell ESP32 BLE integration

Read [project context](../../context/PROJECT_CONTEXT.md) before changing BLE behavior.

- Treat the current device name, GATT UUIDs, packet layout, and units as provisional until checked against the ESP32 firmware. The UUID fields live in `BLEConfiguration`; the decoder is in `BLEDeviceManager`.
- Keep CoreBluetooth discovery, connection state, notification subscription, packet decoding, and UI presentation separate.
- Validate packet length, numeric values, units, and sample timing. BLE notifications may be binary or may split/aggregate payloads; adapt decoding to the actual firmware framing instead of assuming each notification is one CSV record.
- Preserve clear Bluetooth-off, scanning, connected, disconnected, permission, and malformed-data states.
- Keep Demo mode available when changing the hardware path so UI and analysis can still be exercised without the ESP32.
